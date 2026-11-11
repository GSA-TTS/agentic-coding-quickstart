"""MSB backend adapter — subprocess-calling lifecycle side (ADR-0040m).

The read side (detection + version floor) lives in ``backends.py``; this module
owns the mutating/lifecycle verbs the seam drives — ``create``, ``list``,
``exec`` (readiness probe + agent launch), ``stop``, ``remove``, ``copy``, and
``ports`` — plus the in-guest ``kit_exec``/``provision_substrate`` (both driven
via ``msb exec``) — by invoking the ``msb`` CLI as a subprocess. The adapter reports
outcomes and never decides trust: sandbox identity, agent, and workspace
authority stay host-side in the seam (``cli.py`` + ``state.py``), per ADR-0040m
§trust ownership.

Reconciliation with the real msb 0.7.11 CLI: the image is *positional* on
``create``, the workspace is a ``--volume HOST:POSIX-GUEST`` mapping, memory/cpus
are ``-m``/``-c``, and there is NO ``secret``/``kit-apply``/``substrate-provision``/
``provider-credential``/``github-scope``/``rotate`` subcommand. Secrets therefore
live in the acq secret store (:mod:`acq_py.secretstore`, shared with the Bash
adapter) and reach a sandbox as ``--secret ENV@HOST`` bindings: on ``create``,
and on running sandboxes through ``msb modify --secret`` / ``--secret-rm``. msb
reads each bound value from its own environment, so a secret VALUE reaches the
msb child only through that environment mapping, never argv or output.
``usai-rotate-api-key`` stores the new key and re-feeds running sandboxes the
same way.

The ``msb`` executable is overridable via ``ACQ_MSB_BIN`` for reproducible,
offline contract vectors. ``__stub__`` routes to the bundled deterministic fake
``acq_py._stub_msb``; any other value is parsed as a command line. This is an
internal test seam, never a secret, never written to acq output.
"""

from __future__ import annotations

import hashlib
import json
import ntpath
import os
import posixpath
import re
import subprocess
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import NamedTuple

from . import (
    errors,
    hostexec,
    kits,
    msb_options,
    provider_creds,
    provider_input,
    publish,
    secretstore,
    state,
    timeouts,
    userdirs,
)
from .secretstore import Scope

STUB_SENTINEL = "__stub__"

# Guest sizing defaults (ADR-0011): msb defaults a sandbox to 512 MiB / 1 vCPU
# with no swap, so acq requests a larger fixed default, tunable via env.
DEFAULT_MEMORY = "4G"
DEFAULT_CPUS = "2"

# Exec-ready gate budget (seconds): `msb create` returns 0 even on async boot
# failure, so readiness is proven by a successful `msb exec` (ADR-0011).
DEFAULT_READY_TIMEOUT_S = 30.0
READY_TIMEOUT_ENV = "ACQ_MSB_READY_TIMEOUT"


def ready_timeout_s() -> float:
    """The exec-ready budget in seconds, read when needed (never at import).

    A malformed or non-finite override falls back to the default with a stderr
    warning instead of crashing every command or making the wait unbounded.
    """
    return timeouts.env_seconds(READY_TIMEOUT_ENV, DEFAULT_READY_TIMEOUT_S)


# Budget (seconds) for one in-guest kit-install or substrate step. A cold Nix
# install of an agent can take many minutes, so the default is generous; the
# point is that a step that hangs (a prompt nobody can answer) ends with a stable
# ``timeout`` error instead of blocking acq forever.
DEFAULT_KIT_TIMEOUT_S = 1800.0
KIT_TIMEOUT_ENV = "ACQ_MSB_KIT_TIMEOUT"

# Non-interactive git guards for in-guest kit and substrate steps, the same
# values Bash's adapter appends (``_acq_msb_env_tokens_with_guards_into``): git
# must fail rather than prompt for credentials no one can type (the prompt would
# be hidden, since the step's output is captured).
GIT_GUARD_ENV = ("GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=/bin/false", "SSH_ASKPASS=/bin/false")


def kit_timeout_s() -> float:
    """The per-step kit/substrate budget in seconds, read when needed."""
    return timeouts.env_seconds(KIT_TIMEOUT_ENV, DEFAULT_KIT_TIMEOUT_S)


# Module-local seam for the host OS class. ``_guest_path`` reads this instead of
# ``os.name`` so the Windows-only translation is testable on a POSIX host without
# mutating the process-wide ``os`` module (``msb.os`` is ``os``).
WINDOWS = os.name == "nt"


def _guest_path(host: str) -> str:
    """Translate a native host path into its POSIX guest form (ADR-0029).

    msb's ``--volume HOST:GUEST`` maps a native host source to a distinct POSIX
    guest destination; the same POSIX form is the ``-w``/``--workdir`` start
    directory. On POSIX the two forms are identical. On Windows the host prefix is
    classified with ``ntpath.splitroot`` and each family maps to a guest form that
    is never a drive path and never a leading ``//`` (whose meaning is
    implementation-defined in the guest):

    * drive (``C:\\Users\\me\\proj``) -> ``/c/Users/me/proj``;
    * UNC (``\\\\server\\share\\proj`` — the form ``os.path.realpath`` yields for a
      mapped network drive) -> ``/unc/server/share/proj``, namespaced under
      ``/unc`` so a share named after a guest system directory (``\\\\home\\...``)
      can never shadow the agent HOME (``DEFAULT_GUEST_WORKSPACE``);
    * extended-length (``\\\\?\\C:\\...`` and ``\\\\?\\UNC\\server\\share\\...``) —
      ``realpath`` returns these for >MAX_PATH and trailing-dot/space paths; the
      ``\\\\?\\`` prefix is a Win32 signal, not a path component, so it is stripped
      before the same drive/UNC translation above.

    A device path (``\\\\.\\PIPE\\x``) names a device, not a filesystem directory,
    and has no POSIX guest form, so it fails closed rather than emitting a bogus
    mount. The Bash adapter aligns on the same ``/unc/`` UNC form (``common.sh``
    ``canonicalize_path`` re-namespaces ``cygpath -u``'s ``//server/share`` output).
    """
    if not WINDOWS:
        return host
    drive, root, tail = ntpath.splitroot(host)
    if drive.startswith("\\\\.\\"):
        raise MsbError(
            errors.VALIDATION_FAILED,
            f"cannot mount a Windows device path: {host}",
            "pass a filesystem directory, not a device path",
        )
    if drive.startswith("\\\\?\\"):
        rest = drive[4:]  # strip the extended-length prefix
        if rest.upper().startswith("UNC\\"):
            return "/unc/" + (rest[4:] + root + tail).replace("\\", "/")
        if len(rest) == 2 and rest[1] == ":" and rest[0].isalpha():
            return "/" + rest[0].lower() + (root + tail).replace("\\", "/")
        raise MsbError(
            errors.VALIDATION_FAILED,
            f"cannot translate an unknown extended-length path: {host}",
            "pass a plain drive or UNC path instead",
        )
    if drive.startswith("\\\\"):
        return "/unc/" + (drive[2:] + root + tail).replace("\\", "/")
    if len(drive) == 2 and drive[1] == ":" and drive[0].isalpha():
        return "/" + drive[0].lower() + (root + tail).replace("\\", "/")
    return host.replace("\\", "/")


def workspace_override() -> str | None:
    """Canonicalize the operator's start directory without changing mount roots."""
    value = os.environ.get("ACQ_MSB_WORKSPACE", "")
    if not value:
        return None
    if WINDOWS:
        # Keep guest POSIX paths intact; resolve native paths on the host first.
        return _guest_path(os.path.realpath(value) if ntpath.splitdrive(value)[0] else value)
    return _guest_path(os.path.realpath(value))


def start_directory(name: str) -> str | None:
    """Use the current guest override, then the separately recorded guest path."""
    return workspace_override() or (state.record_read("msb", name) or {}).get("guest_workspace")


class MsbError(Exception):
    """A backend-native failure the seam maps to a stable error code.

    ``remediation`` (when present) is stable acq-authored prose only. Raw backend
    stderr is never stored or surfaced: ADR-0040m makes raw backend text a
    non-portable field, and the envelope forbids it entirely.
    """

    def __init__(self, code: str, message: str, remediation: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


def msb_command() -> list[str]:
    """Resolve the msb CLI argv (an internal test seam; default ``msb``)."""
    override = os.environ.get("ACQ_MSB_BIN")
    if override == STUB_SENTINEL:
        return [sys.executable, "-P", "-m", "acq_py._stub_msb"]
    if override:
        return hostexec.override_command(override)
    return hostexec.command("msb")


# ---------------------------------------------------------------------------
# Capability record (ADR-0040m). A declaration, not a proof: conformance is
# asserted by the Tier-1 subprocess vectors and, for host-enforcement
# capabilities, by a Tier-3 live transcript.
# ---------------------------------------------------------------------------

# The declared capability map. Support levels: ``required`` (implemented and
# conformance-asserted), ``optional`` (declared but not part of the shipped
# surface), ``unsupported`` (fails closed with ``unsupported_capability``).
#
# Reconcile with the real msb 0.7.11 CLI: msb has NO standalone ``secret``
# subcommand and no ``provider-credential``/``github-scope``/``rotate``
# subcommands. The secret capabilities are served from the acq secret store and
# delivered as ``--secret ENV@HOST`` bindings (create) and ``msb modify
# --secret``/``--secret-rm`` (running sandboxes), as the Bash adapter does.
# ``key-present`` stays unsupported: it is the sbx obligation to check a
# backend-held proxy table, and msb holds none (``secret has`` on msb is answered
# from the store and the binding table, :func:`secret_has`). ``kit-apply`` is
# implemented in-guest via ``msb exec`` (no ``kit-apply`` subcommand).
def capability_record(version: str | None = None) -> dict:
    return {
        "backend": "msb",
        "version": version,
        "capabilities": {
            "detect": "required",
            "version": "required",
            "provision": "required",
            "list": "required",
            "exec": "required",
            "attach": "required",
            "shell": "required",
            "stop": "required",
            "remove": "required",
            "copy": "required",
            "ports": "required",
            "kit-apply": "required",
            "secret-write": "required",  # acq store + --secret ENV@HOST bindings
            "secret-rm": "required",  # acq store + msb modify --secret-rm
            "secret-list": "required",  # listed from the acq store
            "key-rotate": "required",  # acq store + msb modify --secret re-feed
            "key-present": "unsupported",  # sbx-only proxy-table obligation
            "kit-source-revoke": "unsupported",
            "start": "required",  # msb-only
            "restart": "required",  # msb-only
            "provenance": "required",
            "doctor": "required",
        },
    }


def _run(
    argv: list[str],
    *,
    timeout: float | None = None,
    input_text: str | None = None,
    secret_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    # Output is captured, so the child must never read the user's terminal: a
    # command that prompts would hang with the prompt hidden, or swallow typed
    # input. Without ``input_text`` its stdin is the null device.
    #
    # ``secret_env`` holds bound secret values (``--secret ENV@HOST`` makes msb
    # read ENV from its own environment). They go only into the child's
    # environment mapping, which ``ps`` and /proc/PID/cmdline do not show; argv
    # names the variable, never the value.
    #
    # msb reads and writes UTF-8 whatever the host's code page, so its streams
    # are UTF-8 here too: with the locale encoding, a Windows ANSI code page
    # would fail on, or garble, a name such as "Łukasz", and a call that
    # succeeded would be reported as failed. Output bytes that are not UTF-8
    # become U+FFFD. Input is checked strictly first (see
    # hostexec.utf8_input_ok), because replacing a character would silently
    # send a different value.
    env = {**os.environ, **secret_env} if secret_env else None
    if not hostexec.utf8_input_ok(input_text):
        raise MsbError(
            errors.VALIDATION_FAILED,
            "the input for msb cannot be encoded as UTF-8",
            "check the value for stray bytes and retry",
        )
    # A bounded call that times out on Windows also ends what msb started (an
    # msb server it auto-started, say): see hostexec.run_captured.
    try:
        return hostexec.run_captured([*msb_command(), *argv], timeout=timeout, input_text=input_text, env=env)
    except OSError as exc:
        # A missing (or non-executable) msb binary must never surface as an
        # uncaught traceback (ADR-0040m stable error vocabulary): fail closed with
        # a code the seam can map, not a raw OSError.
        raise cli_unavailable() from exc


def cli_unavailable() -> MsbError:
    """The stable error for an msb CLI that cannot be started at all.

    Covers a binary missing from PATH, removed after detection, or not
    executable (``FileNotFoundError``/``PermissionError`` and other ``OSError``
    from process creation). The message never echoes the resolved path.
    """
    return MsbError(
        errors.BACKEND_NOT_FOUND,
        "the msb backend CLI could not be run",
        "install msb and retry",
    )


def _list(argv: list[str], timeout: float | None) -> subprocess.CompletedProcess:
    """Run one ``msb list`` call, always bounded.

    With an explicit ``timeout`` a call that outlasts it raises
    ``subprocess.TimeoutExpired`` for the caller to report. Without one it is
    bounded by :func:`timeouts.list_timeout_s` and a call that outlasts that
    raises :class:`MsbError` (``timeout``).
    """
    if timeout is not None:
        return _run(argv, timeout=timeout)
    budget = timeouts.list_timeout_s()
    try:
        return _run(argv, timeout=budget)
    except subprocess.TimeoutExpired:
        raise MsbError(
            errors.TIMEOUT,
            f"'msb list' did not answer within {budget:g}s",
            f"check that msb responds ('msb list'); set {timeouts.LIST_TIMEOUT_ENV} to a larger number of "
            "seconds if it is only slow, then retry",
        ) from None


def list_names(*, timeout: float | None = None) -> list[str] | None:
    """Return sandbox names (one per line), or ``None`` if ``msb list`` failed.

    The call is bounded (see :func:`_list`)."""
    proc = _list(["list", "-q"], timeout)
    if proc.returncode != 0:
        return None
    return [line for line in proc.stdout.splitlines() if line]


def running_names(*, timeout: float | None = None) -> list[str] | None:
    """Return running sandbox names, or ``None`` if ``msb list`` failed.

    The call is bounded (see :func:`_list`): an explicit ``timeout`` raises
    ``subprocess.TimeoutExpired``.
    """
    proc = _list(["list", "--running", "-q"], timeout)
    if proc.returncode != 0:
        return None
    return [line for line in proc.stdout.splitlines() if line]


def exists(name: str) -> bool:
    names = list_names()
    return names is not None and name in names


# ---------------------------------------------------------------------------
# Create-time egress policy (ADR-0018, ADR-0019, ADR-0038m §46). msb fixes a
# sandbox's network rules at create, so the policy is computed here, before
# `msb create` runs, and any failure to compute it refuses the create. This
# mirrors the Bash adapter (acq.backends/msb.sh, acq_backend_provision):
#
#   strict   -> --net-default-egress deny + `allow@dns` + the kits' own hosts
#   balanced -> strict + the vendored sbx "balanced" baseline (the default)
#   open     -> the kits' own hosts, no deny-default; refused unless
#               ACQ_NETWORK_TIER_CONFIRM_OPEN=1 (testing only, never GFE)
#
# Egress only: ingress keeps msb's default so published ports stay reachable
# (ADR-0019). `--tls-intercept` is always emitted: from msb 0.7.3 a hostname
# allow rule only matches traffic msb can inspect, so without interception
# every allowed host would be unreachable. Interception is also what lets msb
# swap a bound ``--secret`` placeholder for the real value on the wire. The Bash
# opt-out ACQ_MSB_NO_TLS_INTERCEPT is deliberately ignored here: turning it off
# would leave the policy unusable and the credentials unsubstituted, not looser.
#
# Deliberate tightenings against the Bash adapter, all in the refuse direction:
# an invalid tier, a relative/missing/malformed/empty baseline file, and a
# malformed host are refused here, where Bash falls back to `balanced` or skips
# the entry.
# ---------------------------------------------------------------------------

NETWORK_TIERS = ("strict", "balanced", "open")

# A packaged copy of acq.backends/msb-balanced-hosts.txt (a test keeps the two
# identical) so the Python package needs no Bash tree at runtime.
# ACQ_MSB_BALANCED_HOSTS_FILE points at a site-specific list, as in Bash.
BALANCED_HOSTS_FILE = Path(__file__).resolve().with_name("msb-balanced-hosts.txt")

# One DNS label: ASCII letters, digits, `_`, and inner `-`. A target is TWO OR
# MORE labels joined by `.`, optionally led by msb's `*.` suffix wildcard. The
# two-label floor matters: msb reads a single-label target as a group keyword
# (`any`, `public`, `private`, `multicast`, `host`, `dns`), so `allow@any` would
# reopen all egress, and `*.com` is a suffix msb itself refuses. Every value is a
# single argv element appended to `allow@`, so a target can never become a flag
# or split into extra arguments; this check also keeps out whitespace and
# anything msb would misparse.
_LABEL = r"[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?"
_TARGET_RE = re.compile(rf"(?:\*\.)?{_LABEL}(?:\.{_LABEL})+")
_PORT_RE = re.compile(r"[1-9][0-9]{0,4}")


def _policy_error(message: str, remediation: str) -> MsbError:
    return MsbError(errors.VALIDATION_FAILED, message, remediation)


def network_tier() -> str:
    """Resolve the egress tier (strict|balanced|open; default balanced).

    ``ACQ_NETWORK_TIER`` wins. The deprecated ``ACQ_MSB_BALANCED_EGRESS`` alias
    is honored only when the tier is unset, and maps to a tier that is never
    looser than before: on -> balanced, off/empty -> strict. An unknown value
    is refused rather than replaced, so a typo cannot widen egress.
    """
    raw = os.environ.get("ACQ_NETWORK_TIER", "")
    if not raw and "ACQ_MSB_BALANCED_EGRESS" in os.environ:
        alias = os.environ["ACQ_MSB_BALANCED_EGRESS"].lower()
        raw = "strict" if alias in ("", "0", "false", "no", "off") else "balanced"
        print(
            f"acq: notice: ACQ_MSB_BALANCED_EGRESS is deprecated; using ACQ_NETWORK_TIER={raw}",
            file=sys.stderr,
        )
    tier = (raw or "balanced").lower()
    if tier not in NETWORK_TIERS:
        raise _policy_error(
            f"invalid ACQ_NETWORK_TIER {raw!r} (expected strict, balanced, or open)",
            "set ACQ_NETWORK_TIER to strict, balanced, or open",
        )
    return tier


def _egress_target(host: str, source: str) -> str:
    """Translate one allowlist host into an msb ``--net-rule`` target.

    ``**.h`` (sbx multi-label glob) becomes msb's suffix form ``*.h``; ``crl*.h``
    (an intra-label glob msb cannot express) is broadened to ``*.h``; anything
    else is an exact host. A single label (``any``, ``public``, ``host``, ...,
    which msb reads as a group keyword) and a single-label suffix such as
    ``*.com`` are refused.
    """
    if host.startswith("**."):
        target = "*." + host[3:]
    elif host.startswith("crl*."):
        target = "*." + host[5:]
    else:
        target = host
    if not _TARGET_RE.fullmatch(target):
        raise _policy_error(
            f"cannot compute the egress policy: invalid host {host!r} in {source}",
            "fix the allowlist entry; acq refuses to create a sandbox it cannot restrict",
        )
    return target


# One kit's contribution to the egress policy: a built-in kit's name (its
# allowlist comes from the vetted table), or a fetched kit's name and the
# ``caps.network.allow`` read from its own spec at the pinned commit.
EgressKit = str | tuple[str, Sequence[str]]


def _kit_rules(egress_kits: Sequence[EgressKit]) -> list[str]:
    """``--net-rule allow@HOST`` for each kit's allowlist (port stripped, as Bash)."""
    if kits.KIT_NETWORK_ALLOW_REF != kits.CONTROL_PLANE_REF:
        raise _policy_error(
            "cannot compute the egress policy: the kit network allowlist was derived "
            f"at {kits.KIT_NETWORK_ALLOW_REF}, not the pinned control plane {kits.CONTROL_PLANE_REF}",
            "re-derive kits.KIT_NETWORK_ALLOW from the pinned kit specs",
        )
    flags: list[str] = []
    for entry in egress_kits:
        allow: tuple[str, ...] | None
        if isinstance(entry, tuple):
            kit, allow = entry[0], tuple(entry[1])
        else:
            kit, allow = entry, kits.KIT_NETWORK_ALLOW.get(entry)
        if allow is None:
            raise _policy_error(
                f"cannot compute the egress policy: no network allowlist is known for kit {kit!r}",
                "select a built-in kit (check ACQ_PROVIDER_KITS)",
            )
        for entry in allow:
            target = _egress_target(entry.split(":", 1)[0], f"kit '{kit}'")
            flags += ["--net-rule", f"allow@{target}"]
    return flags


def _balanced_rules() -> list[str]:
    """``--net-rule`` tokens for the vendored sbx "balanced" baseline (ADR-0018).

    Each ``host[:port]`` line becomes ``allow@TARGET[:tcp:PORT]``. A missing,
    unreadable, malformed, or empty list refuses the create.
    """
    remediation = "restore the balanced host list, or set ACQ_NETWORK_TIER=strict"
    try:
        # A relative override resolves against the cwd, which may be a mounted
        # workspace the agent can write. Refused with Bash's shared wording.
        path = userdirs.path_override("ACQ_MSB_BALANCED_HOSTS_FILE") or BALANCED_HOSTS_FILE
    except userdirs.UserDirError as exc:
        raise _policy_error(exc.message, exc.remediation) from None
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise _policy_error(f"cannot read the balanced egress host list {str(path)!r}", remediation) from exc
    flags: list[str] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        host, sep, port = line.rpartition(":")
        if not sep:
            host, port = line, ""
        target = _egress_target(host, f"{path.name} line {lineno}")
        if not port:
            flags += ["--net-rule", f"allow@{target}"]
        elif _PORT_RE.fullmatch(port) and int(port) <= 65535:
            flags += ["--net-rule", f"allow@{target}:tcp:{port}"]
        else:
            raise _policy_error(
                f"cannot compute the egress policy: invalid port {port!r} in {path.name} line {lineno}",
                remediation,
            )
    if not flags:
        raise _policy_error(f"the balanced egress host list {str(path)!r} has no entries", remediation)
    return flags


def egress_flags(egress_kits: Sequence[EgressKit]) -> list[str]:
    """The ``msb create`` egress flags for a sandbox carrying ``egress_kits``.

    Raises :class:`MsbError` (``validation_failed``) when the policy cannot be
    computed, so the caller refuses the create instead of booting a sandbox
    with unrestricted egress.
    """
    tier = network_tier()
    if tier == "open" and os.environ.get("ACQ_NETWORK_TIER_CONFIRM_OPEN") != "1":
        raise _policy_error(
            "ACQ_NETWORK_TIER=open disables deny-by-default egress and is refused without confirmation",
            "set ACQ_NETWORK_TIER_CONFIRM_OPEN=1 (testing only; never GFE), or use strict or balanced",
        )
    flags = _kit_rules(egress_kits)
    if tier == "open":
        print("acq: WARNING: ACQ_NETWORK_TIER=open; sandbox egress is UNRESTRICTED", file=sys.stderr)
    else:
        baseline = _balanced_rules() if tier == "balanced" else []
        flags += ["--net-default-egress", "deny", "--net-rule", "allow@dns", *baseline]
    if not os.environ.get("ACQ_MSB_NO_TLS_INTERCEPT"):
        flags.append("--tls-intercept")
        flags += msb_options.upstream_ca_flags()
    return flags


def create(
    name: str,
    image: str,
    workspace: str,
    memory: str | None = None,
    cpus: str | None = None,
    guest_workspace: str | None = None,
    *,
    egress_kits: Sequence[EgressKit],
    kit_flags: list[str] | None = None,
    clone_source: str | None = None,
    extra_workspaces: list[str] | None = None,
    workspace_read_only: bool = False,
) -> list[str]:
    """Create a sandbox; returns its ``ENV@HOST`` secret bindings (non-secret).

    Raises :class:`MsbError` on backend failure.

    Reconciles with the real msb 0.7.11 ``create``: the image is *positional*
    (``msb create --name X IMAGE``), the workspace is a ``--volume
    HOST:POSIX-GUEST`` mapping (distinct host source vs guest destination, never
    the same path twice), the start directory is ``-w`` (the same POSIX guest
    form), and memory/cpus are ``-m``/``-c``. ``workspace`` is a native host path;
    ``guest_workspace`` overrides the derived POSIX guest form (ADR-0029,
    ADR-0038m §4 host/guest path types are distinct).

    ``egress_kits`` names the kits whose allowlists form the egress policy, or
    carries a fetched kit's own allowlist (see :func:`egress_flags`). It is required so no caller can create a sandbox
    without one; the policy is computed before msb is invoked. ``kit_flags`` are
    the kits' other create-time flags (the read-only host-config mount, the
    startup script, CA trust), built by :mod:`acq_py.kit_msb`.

    The guest gets ``ACQ_WORKSPACE`` (the guest path of the workspace) on every
    create, and ``ACQ_CLONE=1`` when ``clone_source`` is set: then the host
    directory mounted at that guest path is the scratch clone
    (:mod:`acq_py.msb_clone`, ADR-0027), not ``workspace`` itself. Kits key on
    the two variables to act on the clone and never on the real checkout.

    Every secret the sandbox can be injected with (:func:`secret_bindings`) is
    bound as ``--secret ENV@HOST``; the values travel only in the child's
    environment mapping. The bindings are recorded host-side so a later
    ``secret rm`` knows which sandboxes hold them.
    """
    pull = msb_options.pull_flags()
    egress = egress_flags(egress_kits)
    planned, secret_env = secret_bindings(name)
    secret_flags = [token for bound in planned for token in ("--secret", bound.binding.flag)]
    guest = guest_workspace or _guest_path(workspace)
    start = start_directory(name) or guest
    argv = [
        "create",
        "--name",
        name,
        "--volume",
        f"{clone_source or workspace}:{guest}" + (":ro" if workspace_read_only else ""),
        "-w",
        start,
        "--env",
        f"ACQ_WORKSPACE={guest}",
    ]
    for spec in extra_workspaces or []:
        path = spec.removesuffix(":ro")
        suffix = ":ro" if spec.endswith(":ro") else ""
        argv += ["--volume", f"{path}:{_guest_path(path)}{suffix}"]
    if clone_source:
        argv += ["--env", "ACQ_CLONE=1"]
    argv += msb_options.sizing(
        os.environ.get("ACQ_MSB_MEMORY", DEFAULT_MEMORY) if memory is None else memory,
        os.environ.get("ACQ_MSB_CPUS", DEFAULT_CPUS) if cpus is None else cpus,
    )
    argv += pull
    argv += msb_options.dns_flags()
    argv += egress
    argv += kit_flags or []
    argv += secret_flags
    argv.append(image)  # positional image (last)
    try:
        proc = _run(argv, secret_env=secret_env)
    finally:
        secret_env.clear()
    if proc.returncode != 0:
        # `failure` is the ADR-0038m usage/failure minimum's generic
        # operational-failure code (no ADR-0040m code describes a backend command
        # returning nonzero); the raw backend stderr is deliberately not surfaced.
        raise MsbError(
            errors.FAILURE,
            f"msb create failed for sandbox '{name}'",
            "check msb logs and retry",
        )
    try:
        _held_write(HeldRecord(name, {b.binding.env: b.entry() for b in planned}, complete=True))
    except MsbError:
        # Untracked bindings could never be revoked by `secret rm`: do not keep
        # a sandbox acq cannot account for.
        _run(["remove", "--force", name])
        raise
    return [bound.binding.flag for bound in planned]


def exec_ready(name: str) -> bool:
    """True when ``msb exec NAME -- true`` succeeds (the exec-ready gate).

    A ``TimeoutExpired`` from the probe is treated as "not ready yet": the caller
    polls until its overall deadline and then surfaces the stable ``timeout``
    code, never a traceback.
    """
    try:
        proc = _run(["exec", name, "--", "true"], timeout=5)
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0


def _guest_step(name: str, user: str, step: list[str]) -> bool:
    """Run one in-guest kit/substrate step non-interactively; True on success.

    Mirrors Bash's kit exec path: stdin is the null device (see :func:`_run`),
    the git prompt guards are set, and the step is bounded by
    :func:`kit_timeout_s`. A step that overruns raises :class:`MsbError`
    (``timeout``).
    """
    argv = ["exec", "-u", user]
    for token in GIT_GUARD_ENV:
        argv += ["-e", token]
    argv += [name, "--", *step]
    budget = kit_timeout_s()
    try:
        proc = _run(argv, timeout=budget)
    except subprocess.TimeoutExpired as exc:
        raise MsbError(
            errors.TIMEOUT,
            f"an in-guest setup step for sandbox '{name}' did not finish within {budget:g}s",
            f"check network access from the sandbox, or raise {KIT_TIMEOUT_ENV}, then retry",
        ) from exc
    return proc.returncode == 0


def kit_exec(name: str, flags: list[str], argv: list[str]) -> bool:
    """Run one in-guest kit step (``msb exec FLAGS NAME -- ARGV``); True on success.

    The kit engine (:mod:`acq_py.kit_msb`) builds ``flags``: the guest user, the
    kit environment and the git prompt guards. As for every kit step, stdin is
    the null device, output is captured, and the step is bounded by
    :func:`kit_timeout_s`; an overrun raises :class:`MsbError` (``timeout``).
    acq never runs kit code on the host (ADR-0038m §46): the argv is pinned kit
    data that msb runs in the guest.
    """
    budget = kit_timeout_s()
    try:
        proc = _run(["exec", *flags, name, "--", *argv], timeout=budget)
    except subprocess.TimeoutExpired as exc:
        raise MsbError(
            errors.TIMEOUT,
            f"an in-guest kit step for sandbox '{name}' did not finish within {budget:g}s",
            f"check network access from the sandbox, or raise {KIT_TIMEOUT_ENV}, then retry",
        ) from exc
    return proc.returncode == 0


def guest_output(name: str, argv: list[str]) -> str:
    """Run a read-only probe in the guest as the agent user; its stdout, or "" on failure.

    Used for the attach-time provider key check (:func:`provider_input.check_keys`):
    the probe's own output carries its verdict, so an exec failure or overrun
    reads as "no status", which that check treats as a refusal.
    """
    try:
        proc = _run(["exec", "-u", "agent", name, "--", *argv], timeout=60)
    except subprocess.TimeoutExpired:
        return ""
    return proc.stdout or ""


def call(argv: list[str], *, timeout: float) -> subprocess.CompletedProcess | None:
    """One bounded ``msb ARGV`` call whose outcome the caller judges, or ``None``.

    ``None`` means msb did not answer within ``timeout`` or could not be run at
    all. Output is captured and never surfaced as is (see :class:`MsbError`).
    Used by the host ssh-agent forward (:mod:`acq_py.ssh_agent`), whose guest
    probes must keep the exact argv the Bash adapter uses.
    """
    try:
        return _run(argv, timeout=timeout)
    except (MsbError, subprocess.TimeoutExpired):
        return None


def guest_probe(name: str, argv: list[str]) -> str:
    """Run a read-only probe in the guest as the image's default user; its stdout, or "" on failure.

    For checks that must work before the agent user exists (the kit
    prerequisite check, :func:`kit_msb.check_prereqs`). An exec failure, an
    overrun or an msb that cannot be run reads as "no answer", and the caller
    treats that as nothing to report, as Bash does.
    """
    try:
        proc = _run(["exec", name, "--", *argv], timeout=60)
    except (subprocess.TimeoutExpired, MsbError, OSError):
        return ""
    return proc.stdout or "" if proc.returncode == 0 else ""


def provision_substrate(name: str, steps: list[tuple[str, list[str]]]) -> None:
    """Provision addressable substrate gaps in-guest (ADR-0030 "bring-your-own
    image contract"): create the agent user and bootstrap single-user Nix +
    devenv + direnv before the agent install.

    Each step is ``(user, argv)``: the seam decides which guest user runs it
    (root creates the agent user, as Bash's ``_acq_msb_ensure_agent_user`` does
    with ``-u 0``; the agent user runs its own single-user installs). The steps
    are data sourced from the pinned control plane (never a secret, never a
    credential) and run in-guest via the backend seam; acq never executes them on
    the host. Raises :class:`MsbError` on backend failure or timeout.
    """
    # Reconciles with the real msb 0.7.11 CLI: there is NO `substrate-provision`
    # subcommand. Each bootstrap step runs in-guest via `msb exec -u USER NAME -- …`.
    for user, step in steps:
        if not _guest_step(name, user, step):
            raise MsbError(
                errors.FAILURE,
                f"could not provision the substrate for sandbox '{name}'",
                "check msb logs and retry",
            )


def stop(name: str) -> None:
    # A stopped sandbox can no longer serve its post-hoc tunnels (ADR-0015), so
    # they are stopped first, whatever the stop's outcome, as in Bash.
    publish.teardown(name)
    proc = _run(["stop", name])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"msb stop failed for sandbox '{name}'",
            "check msb logs and retry",
        )


def remove(name: str) -> None:
    publish.teardown(name)
    proc = _run(["remove", "--force", name])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"msb remove failed for sandbox '{name}'",
            "check msb logs and retry",
        )
    publish.forget_host_key(name)
    held_forget(name)


def remove_derived_volumes(name: str) -> None:
    """Best-effort cleanup of kit disks after the sandbox is confirmed gone.

    Bash uses the same prefix match, including its documented overlap when one
    sandbox name is another sandbox's name followed by a hyphen.
    """
    try:
        proc = _run(["volume", "ls", "-q"])
        if proc.returncode != 0:
            return
        volumes = [v for v in proc.stdout.splitlines() if v.startswith(f"acq-{name}-")]
        for volume in volumes:
            if _run(["volume", "rm", volume]).returncode != 0:
                print(f"acq(msb): warning: could not remove derived volume: {volume}", file=sys.stderr)
    except MsbError:
        return


def _run_stream(argv: list[str], *, json_mode: bool) -> int:
    """Run a backend command in the foreground; return its shell-style exit status.

    In ``json_mode`` the child's stdout is routed to stderr (fd 2) so the CLI's
    stdout stays a single JSON document (ADR-0038m §2); otherwise stdio is
    inherited so the child renders directly. Passing the fd directly keeps this
    working when ``sys.stderr`` has been replaced by a harness object without a
    usable fileno(). A child killed by a signal reports ``128 + N``, and Ctrl-C
    is left to the child (see :func:`acq_py.hostexec.run_foreground`). A CLI
    that cannot be started raises :class:`MsbError` (``backend_not_found``), as
    :func:`_run` does.
    """
    if json_mode:
        try:
            stdout: int | None = sys.stderr.fileno()
        except (AttributeError, OSError, ValueError):
            stdout = 2
    else:
        stdout = None
    try:
        return hostexec.run_foreground([*msb_command(), *argv], stdout=stdout)
    except OSError as exc:
        raise cli_unavailable() from exc


# The agent user's home in the guest. With ``-u agent`` msb does not set HOME,
# so ``~``-relative logic would resolve against root's home.
AGENT_HOME = "/home/agent"
# Fallback when the agent's passwd shell cannot be read or is not a plain path.
DEFAULT_SHELL = "/bin/sh"
_SAFE_SHELL = re.compile(r"/[A-Za-z0-9._/-]*")
# Trimmed in the guest, as Bash does, so only the shell field crosses: the rest
# of the entry (the comment field in particular) may hold any bytes at all.
_AGENT_SHELL_SCRIPT = (
    '{ getent passwd agent 2>/dev/null || grep "^agent:" /etc/passwd 2>/dev/null; }'
    " | head -n1 | cut -d: -f7"
)


def agent_shell(name: str) -> str:
    """The agent user's passwd shell in ``name``, or :data:`DEFAULT_SHELL`.

    msb's interactive default is the base image's own entrypoint, and it exports
    neither the passwd shell nor ``SHELL``, so the session is told explicitly
    (Bash: ``_acq_msb_agent_passwd_shell``). The value comes from the guest, so
    only a word-safe absolute path is accepted.
    """
    try:
        proc = _run(["exec", "-u", "root", name, "--", "sh", "-c", _AGENT_SHELL_SCRIPT], timeout=10)
    except (MsbError, subprocess.TimeoutExpired):
        return DEFAULT_SHELL
    # Guest output that is not UTF-8 arrives with U+FFFD in it, which the
    # word-safe check below refuses.
    lines = (proc.stdout or "").splitlines() if proc.returncode == 0 else []
    shell = lines[0].strip() if lines else ""
    return shell if _SAFE_SHELL.fullmatch(shell) else DEFAULT_SHELL


# Writes the forwarded identity into the agent's global git config, so tools
# that read git config rather than GIT_* variables see it too. The values arrive
# as environment variables, never spliced into the script.
_GIT_GLOBAL_CONFIG_SCRIPT = (
    '[ -n "${ACQ_GIT_USER_NAME:-}" ] && git config --global user.name "$ACQ_GIT_USER_NAME" 2>/dev/null || true\n'
    '[ -n "${ACQ_GIT_USER_EMAIL:-}" ] && git config --global user.email "$ACQ_GIT_USER_EMAIL" 2>/dev/null || true\n'
)


def apply_git_global_config(name: str, entries: list[str]) -> None:
    """Set the agent's global git ``user.name``/``user.email`` from ``entries``.

    ``entries`` are ``ACQ_GIT_USER_NAME=...``/``ACQ_GIT_USER_EMAIL=...``, the
    host's own global values. Best effort, as Bash's
    ``_acq_msb_apply_host_git_global_config``: nothing runs without entries, and
    a failure is ignored, because the session still carries the identity as
    ``GIT_*`` variables.
    """
    if not entries:
        return
    argv = ["exec", "-u", "agent", "-e", f"HOME={AGENT_HOME}"]
    for entry in entries:
        argv += ["-e", entry]
    argv += [name, "--", "sh", "-c", _GIT_GLOBAL_CONFIG_SCRIPT]
    try:
        _run(argv, timeout=30)
    except (MsbError, subprocess.TimeoutExpired):
        pass


def _session(
    name: str,
    command: list[str],
    *,
    workspace: str | None,
    env: list[str],
    tty: bool,
    json_mode: bool,
) -> int:
    """Run ``command`` as ``agent`` in the workspace with ``env``; ``-t`` if ``tty``."""
    argv = ["exec", "-t"] if tty else ["exec"]
    argv += ["-u", "agent"]
    workspace = start_directory(name) or workspace
    if workspace:
        # `-w` is the POSIX *guest* start directory (ADR-0029): the adapter owns
        # the host->guest translation, so the native host path the seam passed is
        # converted to its guest form here (never a drive path).
        argv += ["-w", _guest_path(workspace)]
    for entry in env:
        argv += ["-e", entry]
    argv += [name, "--", *command]
    return _run_stream(argv, json_mode=json_mode)


def launch(
    name: str,
    workspace: str | None,
    agent: str | None,
    *,
    json_mode: bool = False,
    env: list[str] | None = None,
    tty: bool | None = None,
    agent_args: list[str] | None = None,
) -> int:
    """Launch the recorded agent (or a login shell) in the foreground.

    Runs as the unprivileged ``agent`` user in the recorded workspace (ADR-0011),
    with the child's exit status as this function's return value (child-status
    propagation, ADR-0038m §1). When stdin is a terminal (or ``tty`` says so) the
    session gets a PTY (``msb exec -t``) and the host's TERM/COLORTERM; without
    one it runs without a PTY, as a pipe or CI job needs. ``env`` is the
    seam's session environment (git identity, a forwarded ssh-agent socket).
    """
    interactive = hostexec.stdin_is_tty() if tty is None else tty
    shell = agent_shell(name)
    command = [agent] if agent and agent != "shell" else [shell, "-l"]
    if agent and agent != "shell":
        command += agent_args or []
    session = [f"HOME={AGENT_HOME}", f"SHELL={shell}"]
    if interactive:
        session += hostexec.terminal_env()
    return _session(
        name, command, workspace=workspace, env=[*session, *(env or [])], tty=interactive, json_mode=json_mode
    )


def exec_command(
    name: str,
    command: list[str],
    *,
    workspace: str | None = None,
    json_mode: bool = False,
    env: list[str] | None = None,
) -> int:
    """Run an explicit command non-interactively (``acq exec``); returns its status.

    Like :func:`launch` but without a PTY, forwarding ``command`` verbatim after
    the ``--`` separator (ADR-0038m §4 "exec argv after ``--`` is opaque").
    """
    session = [f"HOME={AGENT_HOME}", *(env or [])]
    return _session(name, command, workspace=workspace, env=session, tty=False, json_mode=json_mode)


def copy(src: str, dst: str) -> int:
    """Invoke ``msb copy SRC DST``; return its exit status (status preservation).

    The two arguments are forwarded verbatim — the seam (``cli.py``) has already
    validated the host/guest path types, so the adapter never re-interprets which
    side is the sandbox reference (ADR-0040m: the adapter translates, the seam
    validates).
    """
    proc = _run(["copy", src, dst])
    return proc.returncode


def ports(name: str) -> list[dict]:
    """Return a sandbox's *declared* host/guest port mappings (ADR-0038m §ports).

    Reads create-time mappings from ``msb inspect NAME --format json`` (backend
    authority, host-side). This reports declarations, never listener health. An
    inspect that *succeeds* with no ``ports`` key is a legitimate empty result; an
    inspect that *fails* (non-zero exit), returns unparseable output, or returns a
    wrong-shape document raises :class:`MsbError` so the seam fails closed rather
    than swallowing the backend status as an empty list (ADR-0038m §48 drops
    "inspection-failure-as-empty").
    """
    proc = _run(["inspect", name, "--format", "json"])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"could not read declared ports for sandbox '{name}'",
            "check msb logs and retry",
        )
    try:
        doc = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        raise MsbError(
            errors.FAILURE,
            f"could not parse declared ports for sandbox '{name}'",
            "the backend returned an unreadable inspect result; check msb logs and retry",
        ) from exc

    def _bad_shape() -> MsbError:
        return MsbError(
            errors.FAILURE,
            f"could not parse declared ports for sandbox '{name}'",
            "the backend returned an unexpected inspect shape; check msb logs and retry",
        )

    # Traverse the msb inspect shape defensively: a wrong shape at any
    # intermediate level (non-dict active_config/network, a top-level list) must
    # fail closed, not raise an uncaught AttributeError. Absence of a level is a
    # legitimate empty result (an older inspect shape).
    if not isinstance(doc, dict):
        raise _bad_shape()
    active_config = doc.get("active_config")
    if active_config is None:
        return []
    if not isinstance(active_config, dict):
        raise _bad_shape()
    network = active_config.get("network")
    if network is None:
        return []
    if not isinstance(network, dict):
        raise _bad_shape()
    entries = network.get("ports")
    if entries is None:
        entries = []
    if not isinstance(entries, list):
        raise _bad_shape()
    out: list[dict] = []
    for entry in entries:
        if isinstance(entry, dict) and "host_port" in entry and "guest_port" in entry:
            out.append(
                {
                    "host_port": entry["host_port"],
                    "guest_port": entry["guest_port"],
                    "origin": "create",
                }
            )
    # The post-hoc tunnels acq recorded (ADR-0015); msb knows nothing of them.
    return out + publish.posthoc_ports(name)


def publish_ports(name: str, mappings: list[str]) -> list[dict]:
    """``acq ports NAME --publish H:G...``: open and record one tunnel per mapping (ADR-0015).

    The mappings are validated by the caller. Raises :class:`MsbError`.
    """

    def authorize(pub: Path) -> bool:
        return _run(["ssh", "authorize", "--file", str(pub)], timeout=60).returncode == 0

    def run(argv: list[str]) -> int:
        return hostexec.run_captured(argv, timeout=60).returncode

    try:
        tunnels = publish.publish_posthoc(name, mappings, msb_command(), authorize, run)
    except publish.PublishError as exc:
        raise MsbError(exc.code, exc.message, exc.remediation) from exc
    except subprocess.TimeoutExpired as exc:
        raise MsbError(errors.TIMEOUT, f"a host command did not finish while publishing a port of '{name}'",
                       "check that msb and ssh-keygen respond, then retry") from exc
    except OSError as exc:
        raise MsbError(
            errors.FAILURE,
            f"could not open a port tunnel for sandbox '{name}': {exc.strerror or exc}",
            "check that msb and the OpenSSH client run, and that the acq state directory is writable",
        ) from exc
    return [{**t.mapping(), "serve_port": t.serve_port} for t in tunnels]


# ---------------------------------------------------------------------------
# Read-only host-config mount checks (ADR-0035; Bash
# `_acq_msb_ro_mount_recorded_readonly` and `_acq_msb_host_config_mount_probe`).
# Enforcement of `:ro` is msb's, on the host. What acq checks is that msb
# RECORDED this sandbox's mount as read-only, read from the host with `msb
# inspect` (a guest cannot forge it), plus a guest probe that can only make acq
# stricter: a guest root controls the probe's tools, so its "denied" answer
# proves nothing on its own, while a "writable" answer is taken at face value.
# ---------------------------------------------------------------------------

RO_INSPECT_RETRIES_ENV = "ACQ_MSB_RO_INSPECT_RETRIES"
RO_INSPECT_SLEEP_ENV = "ACQ_MSB_RO_INSPECT_RETRY_SLEEP"


class _NotReady(Exception):
    """``msb inspect`` reports no active config yet (retried)."""


def _norm_guest(path: object) -> str | None:
    if not isinstance(path, str) or not path.startswith("/"):
        return None
    return posixpath.normpath("/" + path.lstrip("/"))


def _inspect_mounts(raw: str) -> list[tuple[str, dict]]:
    """``(guest, mount)`` pairs from ``msb inspect`` JSON; raises ``ValueError`` with a reason."""
    try:
        doc = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ValueError("msb inspect output is not valid JSON") from exc
    if not isinstance(doc, dict):
        raise ValueError("msb inspect output has an unexpected shape (not an object)")
    active = doc.get("active_config")
    if active is None:
        raise _NotReady("msb reports no active config for the sandbox yet (active_config is null)")
    if not isinstance(active, dict) or not isinstance(active.get("mounts"), list):
        raise ValueError("msb inspect active_config has no mounts list")
    out: list[tuple[str, dict]] = []
    for mount in active["mounts"]:
        if not isinstance(mount, dict):
            raise ValueError("msb inspect lists a mount with an unexpected shape")
        if mount.get("guest") is None:
            continue
        guest = _norm_guest(mount.get("guest"))
        if guest is None:
            raise ValueError("msb inspect lists a mount with an unexpected guest path")
        out.append((guest, mount))
    return out


def _check_ro_mount(entries: list[tuple[str, dict]], guest_dir: str, host_dirs: list[str]) -> None:
    """Raise ``ValueError`` unless ``guest_dir`` is exactly one read-only Bind of ``host_dirs``."""
    target = _norm_guest(guest_dir) or guest_dir
    same = [m for g, m in entries if g == target]
    if len(same) != 1:
        raise ValueError(f"msb lists {'no' if not same else 'more than one'} mount at {guest_dir}")
    mount = same[0]
    opts = mount.get("options")
    if mount.get("type") != "Bind":
        raise ValueError(f"the mount at {guest_dir} is not a Bind mount")
    if not isinstance(opts, dict) or opts.get("readonly") is not True:
        raise ValueError(f"msb does not record the mount at {guest_dir} as read-only")
    host = mount.get("host")
    if not isinstance(host, str) or not host:
        raise ValueError(f"the mount at {guest_dir} has no host path")
    if os.path.realpath(host) not in {os.path.realpath(h) for h in host_dirs}:
        raise ValueError(f"the mount at {guest_dir} is not backed by this sandbox's acq host config directory")
    for guest, other in entries:
        if other is mount:
            continue
        if guest == "/" or target.startswith(guest + "/") or guest.startswith(target + "/"):
            other_opts = other.get("options")
            if not isinstance(other_opts, dict) or other_opts.get("readonly") is not True:
                raise ValueError(f"another mount ({guest}) that is not read-only overlaps {guest_dir}")


def ro_mount_recorded(name: str, guest_dir: str, host_dirs: list[str]) -> tuple[str, str]:
    """Whether msb recorded ``guest_dir`` as this sandbox's read-only Bind of ``host_dirs``.

    Returns ``("ok", "")``, ``("missing", reason)`` when msb's record does not
    show that mount, or ``("unknown", reason)`` when it could not be read. A
    null ``active_config`` right after boot is retried
    (:data:`RO_INSPECT_RETRIES_ENV`, default 3, one second apart); anything else
    fails closed at once. The inspect JSON is never printed.
    """
    raw = os.environ.get(RO_INSPECT_RETRIES_ENV, "")
    tries = max(1, int(raw)) if raw.isascii() and raw.isdigit() else 3
    reason = "msb reports no active config for the sandbox yet"
    for attempt in range(tries):
        if attempt:
            time.sleep(timeouts.env_seconds(RO_INSPECT_SLEEP_ENV, 1.0))
        try:
            proc = _run(["inspect", name, "--format", "json"], timeout=30)
        except subprocess.TimeoutExpired:
            return "unknown", "'msb inspect' did not answer, so the recorded mount could not be read"
        if proc.returncode != 0:
            return "unknown", "'msb inspect' failed, so the recorded mount could not be read"
        try:
            _check_ro_mount(_inspect_mounts(proc.stdout or ""), guest_dir, host_dirs)
        except _NotReady as exc:
            reason = str(exc)
            continue
        except ValueError as exc:
            return "missing", str(exc)
        return "ok", ""
    return "unknown", reason


# Exit 2 only when guest root's write succeeded. A failed redirection on the
# special builtin ':' ends some shells with status 2, so it runs in a subshell.
_RO_WRITE_PROBE = (
    '_dir=$1; _tmp="$_dir/.acq-ro-probe.$$"; '
    'if ( : > "$_tmp" ) 2>/dev/null; then rm -f "$_tmp" 2>/dev/null; exit 2; fi; exit 0'
)


def ro_mount_guest_probe(name: str, guest_dir: str) -> int:
    """DIAGNOSTIC: 0 present and not writable by guest root, 1 not confirmed, 2 writable.

    Both checks run as guest root: at create the probe runs before the kits
    set up the agent user, which a custom image may not have yet.
    """
    try:
        present = _run(["exec", name, "-u", "0", "--", "sh", "-c", 'test -d "$1" && test -x "$1"', "sh", guest_dir],
                       timeout=30)
        if present.returncode != 0:
            return 1
        write = _run(["exec", name, "-u", "0", "--", "sh", "-c", _RO_WRITE_PROBE, "sh", guest_dir], timeout=30)
    except subprocess.TimeoutExpired:
        return 1
    if write.returncode == 2:
        return 2
    return 0 if write.returncode == 0 else 1


# ---------------------------------------------------------------------------
# Credential bindings (Bash `_acq_msb_service_binding`, `_acq_msb_bind_one`,
# `_acq_msb_bind_secrets_into`). msb keeps no secret store: each secret lives in
# the acq secret store and is bound per sandbox as ``--secret ENV@HOST``. msb
# reads ENV from its own environment and swaps the guest's placeholder for the
# value on the wire to HOST. So a value only ever travels in the msb child's
# environment mapping; argv carries the variable name and host, never the value,
# and no function here returns, logs or raises with a value (ADR-0038m, and
# ordinary-user story 7 "no secret exposure" in docs/spec/acq-v1.md).
#
# Which sandbox holds which binding is recorded host-side (one small record per
# sandbox, names and hosts only), because revocation must reach exactly the
# sandboxes that hold a binding: msb offers no binding listing acq can rely on.
# ---------------------------------------------------------------------------

# GitHub's token is bound to the REST API and both git-transport hosts, so API
# calls and HTTPS clone/push are all substituted. A fixed table: unlike Bash
# (ACQ_MSB_GITHUB_HOST), no environment variable can redirect the token.
GITHUB_TOKEN_ENV = "GITHUB_TOKEN"  # nosec B105 # an env var name, not a value
GITHUB_HOSTS = "github.com,api.github.com,codeload.github.com"

# Set (non-empty) to make set/rm store-only, with no `msb modify` against
# running sandboxes (Bash parity; a verifier seeding a throwaway global key must
# not rebind, or unbind, the user's own live sandbox).
NO_LIVE_REFEED_ENV = "ACQ_SECRET_NO_LIVE_REFEED"

# One destination host (an optional :port allowed), as Bash's
# `_acq_provider_fact_safe_host` accepts: no scheme, path, wildcard or `..`.
_BIND_HOST_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9.:-]*")

HELD_SCHEMA = 1
_HELD_UNSAFE_RE = re.compile(r"[^A-Za-z0-9._-]")


class SecretBinding(NamedTuple):
    """Where one service's secret is injected: the env var msb reads and the
    comma-separated hosts it is substituted for. Never carries a value."""

    env: str
    host: str

    @property
    def flag(self) -> str:
        return f"{self.env}@{self.host}"


class BoundSecret(NamedTuple):
    """One binding a sandbox holds: the service, its binding, and whether the
    value came from the sandbox's own store entry (else the global one)."""

    service: str
    binding: SecretBinding
    own: bool

    def entry(self) -> dict:
        return {"service": self.service, "host": self.binding.host, "scope": "sandbox" if self.own else "global"}


def _binding_ok(env: str, host: str) -> bool:
    """True when ``ENV@HOST`` is safe to bind: an upper-case env name that is not
    process-critical (PATH, LD_PRELOAD, ... would hand the value to the msb child
    as that variable) and one or more plain hosts."""
    if not provider_creds.key_env_ok(env):
        return False
    parts = host.split(",")
    return all(_BIND_HOST_RE.fullmatch(part) and ".." not in part for part in parts)


def service_binding(service: str, sandbox: str | None = None) -> SecretBinding | None:
    """The binding msb uses for ``service`` in ``sandbox`` (None = global), or None.

    The single table for create, re-feed, ``secret has`` and ``secret ls``. An
    endpoint recorded by ``acq secret set SVC --host H --env E`` wins (the
    sandbox's own record first, then the global one); otherwise ``github`` has
    its fixed hosts and a provider its pinned destination
    (:func:`provider_creds.provider_env_hosts`). Anything else, or an unsafe
    mapping, has no binding: it is never guessed.
    """
    meta = secretstore.meta_resolve(service, sandbox)
    if meta is not None and meta.host and meta.env:
        found: SecretBinding | None = SecretBinding(meta.env, meta.host)
    elif service == "github":
        found = SecretBinding(GITHUB_TOKEN_ENV, GITHUB_HOSTS)
    else:
        pinned = provider_creds.provider_env_hosts(service)
        found = SecretBinding(*pinned) if pinned else None
    if found is None or not _binding_ok(found.env, found.host):
        return None
    return found


# --- host-side record of the bindings each sandbox holds -------------------
#
# A record is written for every sandbox acq creates, even one with no bindings,
# so a missing record means "unknown" (a sandbox created by Bash, by msb
# directly, or before records existed), never "holds nothing". A record acq
# starts for an unknown sandbox (when it re-feeds one) is ``complete: false``
# and lists in ``services`` the services whose binding acq itself set or
# cleared there; for any other service that sandbox is still unknown.


@dataclass
class HeldRecord:
    """What acq knows about the bindings sandbox ``name`` holds (no values)."""

    name: str
    bindings: dict[str, dict] = field(default_factory=dict)
    complete: bool = False
    services: list[str] = field(default_factory=list)

    def knows(self, service: str) -> bool:
        """True when acq knows whether this sandbox holds ``service``."""
        return self.complete or service in self.services

    def note(self, service: str) -> None:
        if service not in self.services:
            self.services.append(service)

    def save(self) -> None:
        _held_write(self)


def held_path(name: str) -> Path:
    digest = hashlib.sha256(name.encode("utf-8")).hexdigest()[:8]
    return state.state_dir() / "msb-secret-bindings" / f"{_HELD_UNSAFE_RE.sub('_', name)}.{digest}.json"


def _held_entry_ok(env: object, entry: object) -> bool:
    return (
        isinstance(env, str) and provider_creds.key_env_ok(env) and isinstance(entry, dict)
        and all(isinstance(entry.get(k), str) for k in ("service", "host", "scope"))
    )


def held_read(name: str) -> HeldRecord:
    """The record for ``name``; an unknown (not complete, empty) one when absent.

    A record that exists but cannot be read, or carries an invalid env name,
    raises :class:`MsbError`: treating it as known-empty would let ``secret rm``
    skip a sandbox that still holds a credential.
    """
    try:
        raw = held_path(name).read_text(encoding="utf-8")
    except FileNotFoundError:
        return HeldRecord(name)
    except OSError as exc:
        raise _held_unreadable(name) from exc
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise _held_unreadable(name) from exc
    if not isinstance(doc, dict) or doc.get("schema") != HELD_SCHEMA or doc.get("sandbox") != name:
        raise _held_unreadable(name)
    bindings, complete, services = doc.get("bindings"), doc.get("complete"), doc.get("services")
    if not isinstance(bindings, dict) or not isinstance(complete, bool) or not isinstance(services, list):
        raise _held_unreadable(name)
    if not all(_held_entry_ok(k, v) for k, v in bindings.items()) or not all(isinstance(s, str) for s in services):
        raise _held_unreadable(name)
    return HeldRecord(name, bindings, complete, services)


def _held_unreadable(name: str) -> MsbError:
    return MsbError(
        errors.STATE_SCHEMA_UNSUPPORTED,
        f"cannot read the record of the secrets bound to sandbox '{name}'",
        f"remove the sandbox with 'acq rm {name}' (or repair the record under msb-secret-bindings), then retry",
    )


def _fsync_dir(directory: Path) -> None:
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return  # not supported for directories on this platform (Windows)
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _held_write(rec: HeldRecord) -> None:
    """Write ``rec`` durably (temp file, fsync, rename, fsync the directory)."""
    path = held_path(rec.name)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    doc = {"schema": HELD_SCHEMA, "sandbox": rec.name, "complete": rec.complete,
           "services": rec.services, "bindings": rec.bindings}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(doc, sort_keys=True))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        tmp.unlink(missing_ok=True)
        raise MsbError(
            errors.FAILURE,
            f"could not record the secrets bound to sandbox '{rec.name}'",
            "check that the acq state directory is writable, then retry",
        ) from exc
    _fsync_dir(path.parent)


def held_forget(name: str) -> None:
    """Drop ``name``'s record (the sandbox is gone)."""
    try:
        held_path(name).unlink(missing_ok=True)
    except OSError:
        pass


# --- create ------------------------------------------------------------------

def _bind_candidates(name: str) -> list[str]:
    """Services a new sandbox may bind, in Bash's order: github, the services
    with a recorded endpoint (this sandbox's and global), then the providers.

    The providers honour provider selection (Bash ``acq_provider_delivery_ids``):
    the registered ones, the usai anchor only while its kit is selected, and
    those the sandbox's recorded provider facts name. An explicitly empty
    ``ACQ_PROVIDER_KITS`` binds no provider unless its facts were recorded.
    """
    try:
        providers = provider_input.delivery_ids("msb", name)
    except provider_input.ProviderInputError as exc:
        raise MsbError(exc.code, exc.message, exc.remediation) from exc
    out = ["github"]
    for service in secretstore.meta_list(name) + providers:
        if service not in out:
            out.append(service)
    return out


def _has_own_value(service: str, sandbox: str) -> bool:
    """True when ``sandbox`` holds its own value for ``service`` (which a global
    change must leave alone: the sandbox scope takes precedence)."""
    return secretstore.name_ok(sandbox) and secretstore.exists(service, sandbox)


def secret_bindings(name: str) -> tuple[list[BoundSecret], dict[str, str]]:
    """The bindings a new sandbox ``name`` gets, and ``{ENV: value}`` for them.

    A service is bound when it has a binding and a value resolves for it, the
    sandbox's own value taking precedence over the global one. The first service
    to claim an env var keeps it. The caller passes the mapping only as the msb
    child's environment and clears it afterwards.
    """
    planned: list[BoundSecret] = []
    env: dict[str, str] = {}
    try:
        providers = provider_input.delivery_ids("msb", name)
    except provider_input.ProviderInputError as exc:
        raise MsbError(exc.code, exc.message, exc.remediation) from exc
    for service in _bind_candidates(name):
        binding = service_binding(service, name)
        if binding is None or binding.env in env:
            continue
        value = secretstore.resolve(service, name)
        # Bash falls back to CI's exported provider key after the store lookup;
        # passing the gate must also produce a live binding at create.
        if not value and service in providers and service not in provider_input.HOST_SERVICES:
            value = os.environ.get(binding.env)
        if value:
            env[binding.env] = value
            planned.append(BoundSecret(service, binding, _has_own_value(service, name)))
    return planned, env


# --- start (resume a stopped sandbox) ---------------------------------------------
#
# `msb start` re-reads the `--secret ENV@HOST` bindings the sandbox holds and
# needs every ENV in its own environment: msb keeps no value across a stop. The
# values come from the acq store, as at create, and travel only in the child's
# environment mapping. `secret set` re-feeds running sandboxes only, so once the
# sandbox starts again :func:`reconcile_bindings` binds what changed meanwhile.


def _start_secret_missing(name: str, env: str, service: str) -> MsbError:
    unreadable = secretstore.unreadable(service, name)
    return MsbError(
        errors.SECRET_UNREADABLE if unreadable else errors.SECRET_MISSING,
        f"sandbox '{name}' binds {env} for '{service}', but no value for '{service}' can be read "
        "from the acq secret store, so msb cannot start it",
        f"store it again with 'acq secret set -g {service}' (or 'acq secret set {name} {service}'), then retry",
    )


def _start_env(name: str) -> dict[str, str]:
    """``{ENV: value}`` for every binding ``msb start`` looks up in its environment.

    A recorded binding gets the value that takes precedence for its service now
    (the sandbox's own, else the global one). For a sandbox acq has no complete
    record of, every binding a new sandbox would get is passed as well, as Bash
    does, since msb may hold any of them. A recorded binding with no readable
    value raises: msb would refuse to start, and dropping the binding instead
    could revoke a credential that is only unreadable for now.
    """
    rec = held_read(name)
    out: dict[str, str] = {}
    if not rec.complete:
        _planned, out = secret_bindings(name)
    for env, entry in rec.bindings.items():
        value = secretstore.resolve(entry["service"], name)
        if not value:
            # A provider bound from CI's environment must remain startable.
            # Reuse create's resolver only for the identical recorded binding.
            planned, available = secret_bindings(name)
            if any(bound.service == entry["service"] and bound.binding == SecretBinding(env, entry["host"])
                   for bound in planned):
                value = available.get(env)
            available.clear()
        if not value:
            out.clear()
            raise _start_secret_missing(name, env, entry["service"])
        out[env] = value
    return out


def start(name: str) -> None:
    """``msb start NAME`` with the sandbox's bound secrets in the child's environment only.

    Raises :class:`MsbError` when a bound secret has no value or msb fails.
    Missing bindings are applied while stopped: msb cannot add them while running.
    """
    # msb can rotate a running binding, but adding one requires a stopped guest.
    failed = reconcile_bindings(name)
    if failed:
        raise MsbError(errors.FAILURE, f"could not bind credentials before starting '{name}': {', '.join(failed)}",
                       "check msb logs, then retry the start")
    secret_env = _start_env(name)
    try:
        proc = _run(["start", name], secret_env=secret_env)
    finally:
        secret_env.clear()
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"msb start failed for sandbox '{name}'",
            "check msb logs and retry",
        )


def reconcile_bindings(name: str) -> list[str]:
    """Bind, before starting sandbox ``name``, what the store gained while it was stopped.

    Each binding a new sandbox would get (:func:`secret_bindings`) that the
    record does not show is added with ``msb modify`` (:func:`_put`, which first
    removes a binding it replaces). One whose only change is its scope is just
    recorded: ``msb start`` receives the value that takes precedence.
    Nothing is unbound here; that is ``secret rm``'s job. Returns the services
    that could not be bound.
    """
    rec = held_read(name)
    planned, values = secret_bindings(name)
    failed: list[str] = []
    try:
        for bound in planned:
            entry = rec.bindings.get(bound.binding.env)
            if entry == bound.entry():
                continue
            if entry is not None and entry["service"] == bound.service and entry["host"] == bound.binding.host:
                rec.bindings[bound.binding.env] = bound.entry()
                rec.note(bound.service)
                rec.save()
            elif not _put(rec, bound, values[bound.binding.env]):
                failed.append(bound.service)
    finally:
        values.clear()
    return failed


def held_flags(name: str) -> list[str]:
    """The ``ENV@HOST`` bindings the record shows for ``name`` (no values)."""
    return sorted(f"{env}@{entry['host']}" for env, entry in held_read(name).bindings.items())


# --- secret set ----------------------------------------------------------------

def _env_claim_problem(service: str, env: str, sandbox: str | None) -> str | None:
    """Why ``service`` may not bind ``env`` (another service's variable), or None."""
    owner = provider_creds.key_env_owner(env)
    if owner is not None and owner != service:
        return f"{env} is reserved for '{owner}'"
    for provider in provider_creds.provider_ids():
        pinned = provider_creds.provider_env_hosts(provider) if provider != service else None
        if pinned is not None and pinned[0] == env:
            return f"{env} is the credential variable of provider '{provider}'"
    for other in secretstore.meta_list(sandbox):
        bound = service_binding(other, sandbox) if other != service else None
        if bound is not None and bound.env == env:
            return f"{env} is already bound for '{other}'"
    return None


def secret_preflight(scope: Scope | str, service: str, host: str = "", env: str = "") -> None:
    """Refuse, before anything is stored, a secret msb could never inject.

    An explicit ``--host``/``--env`` must be bindable and must not take another
    service's variable (reserved names, provider variables, or a variable a
    recorded endpoint already uses). Without them the service needs a recorded
    endpoint, a fixed one (github) or a provider pin. Storing a value msb cannot
    bind would report a credential the sandbox never receives.
    """
    sc = secretstore.as_scope(scope)
    if host or env:
        problem = None if _binding_ok(env, host) else (
            "use an upper-case env var name that is not process-critical (e.g. API_KEY) and plain DNS hosts"
        )
        claim = _env_claim_problem(service, env, sc.sandbox) if problem is None else None
        if problem is not None or claim is not None:
            raise MsbError(
                errors.VALIDATION_FAILED,
                f"msb cannot bind '{service}' as {env}@{host}" + (f": {claim}" if claim else ""),
                f"{problem or 'choose a different --env'}; nothing was stored",
            )
        return
    if service_binding(service, sc.sandbox) is None:
        raise MsbError(
            errors.VALIDATION_FAILED,
            f"'{service}' has no endpoint mapping, so msb cannot inject it",
            f"pass the destination and env var, e.g. acq secret set -g {service} "
            "--host api.example.com --env API_KEY; nothing was stored",
        )


def _live_refeed_off() -> bool:
    return bool(os.environ.get(NO_LIVE_REFEED_ENV))


def _running_targets(scope: Scope, timeout: float | None = None) -> list[str]:
    """The running sandboxes a change in ``scope`` reaches: the named sandbox
    (if it is running) or every running sandbox for the global scope. Raises
    ``subprocess.TimeoutExpired`` past ``timeout`` seconds."""
    names = running_names(timeout=timeout)
    if names is None:
        raise MsbError(
            errors.FAILURE,
            "could not list running sandboxes to update their credentials",
            "check that msb works ('msb list'), then retry",
        )
    if scope.sandbox is not None:
        return [scope.sandbox] if scope.sandbox in names else []
    return names


def _modify(name: str, flags: list[str], secret_env: dict[str, str] | None = None, timeout: float | None = None) -> bool:
    """``msb modify NAME FLAGS``; raises ``subprocess.TimeoutExpired`` past ``timeout`` seconds."""
    try:
        proc = _run(["modify", name, *flags], secret_env=secret_env, timeout=timeout)
    finally:
        if secret_env:
            secret_env.clear()
    return proc.returncode == 0


def _drop(rec: HeldRecord, env: str, timeout: float | None = None) -> bool:
    """``msb modify NAME --secret-rm ENV`` and forget it in the record."""
    if not _modify(rec.name, ["--secret-rm", env], timeout=timeout):
        return False
    entry = rec.bindings.pop(env, None)
    if entry is not None:
        rec.note(entry["service"])
    rec.save()
    return True


def _put(rec: HeldRecord, bound: BoundSecret, value: str, timeout: float | None = None) -> bool:
    """Bind ``bound`` in sandbox ``rec.name`` and record it.

    A binding is never replaced in place: if the variable is bound to other
    hosts, or this service is bound under another variable, those are removed
    first with their own ``--secret-rm``. Adding the same variable to the same
    hosts rotates the value. Each msb call is bounded by ``timeout`` seconds
    (``subprocess.TimeoutExpired``).
    """
    env = bound.binding.env
    stale = [e for e, v in rec.bindings.items() if v["service"] == bound.service and e != env]
    if env in rec.bindings and rec.bindings[env].get("host") != bound.binding.host:
        stale.append(env)
    for old in stale:
        if not _drop(rec, old, timeout):
            return False
    if not _modify(rec.name, ["--secret", bound.binding.flag], {env: value}, timeout):
        return False
    rec.bindings[env] = bound.entry()
    rec.note(bound.service)
    rec.save()
    return True


def _selection_withholds(service: str, sandbox: str) -> bool:
    """True when a re-feed must not hand ``sandbox`` the provider credential
    ``service``: the sandbox was created with a provider selection that leaves
    the provider out (``--no-provider-kits``, or an explicit list without its
    kit), and it holds no binding for it.

    The selection test is the one a create applies (:func:`_bind_candidates`)
    under the recorded selection. Only a recorded selection counts: a service
    that is not a provider, or a sandbox with no recorded selection (one from
    before it was recorded), is never withheld here. A sandbox that already
    holds a binding for the service is re-fed: that grants nothing new, keeps
    it from running on a stale value, and matches what ``msb start`` passes it
    (:func:`_start_env` feeds every held binding). Raises :class:`MsbError`
    when the recorded selection, the provider facts or the binding record
    cannot be read.
    """
    if service not in provider_creds.provider_ids():
        return False
    try:
        if kits.provider_selection_read("msb", sandbox) is None:
            return False
        with kits.recorded_provider_selection("msb", sandbox):
            if service in _bind_candidates(sandbox):
                return False
    except kits.ProviderSelectionError as exc:
        raise MsbError(errors.VALIDATION_FAILED, str(exc), f"recreate sandbox '{sandbox}' so a valid selection "
                       "is recorded") from exc
    return not any(entry["service"] == service for entry in held_read(sandbox).bindings.values())


def _refeed(service: str, scope: Scope) -> None:
    """Push ``service``'s current value to the running sandboxes ``scope``
    reaches. Existing bindings rotate live; a new binding needs a restart.

    A sandbox with its own value is left alone on a global change, as is one
    whose recorded provider selection leaves the provider out and that holds
    no binding for it (:func:`_selection_withholds`; noted on stderr for a
    change scoped to that sandbox), and a variable already bound there for
    another service keeps its first claim (warned). Raises :class:`MsbError`
    naming every sandbox that could not be updated, including one whose value,
    binding or recorded selection could not be resolved.
    """
    if _live_refeed_off():
        return
    failed: list[str] = []
    for sandbox in _running_targets(scope):
        if scope.is_global and _has_own_value(service, sandbox):
            continue
        try:
            if _selection_withholds(service, sandbox):
                if not scope.is_global:
                    print(
                        f"acq: note: '{service}' is stored for sandbox '{sandbox}', but it will not reach that "
                        "sandbox: its provider selection excludes the provider (recreate it to change the selection)",
                        file=sys.stderr,
                    )
                continue
        except MsbError as exc:
            failed.append(f"{sandbox} ({exc.message})")
            continue
        binding = service_binding(service, sandbox)
        value = secretstore.resolve(service, sandbox)
        rec = held_read(sandbox)
        holder = rec.bindings.get(binding.env) if binding is not None else None
        if binding is None or not value:
            failed.append(f"{sandbox} (no injectable value)")
        elif holder is not None and holder["service"] != service:
            print(
                f"acq: warning: '{service}' was not applied to sandbox '{sandbox}': "
                f"{binding.env} is already bound there for '{holder['service']}'",
                file=sys.stderr,
            )
        elif not _put(rec, BoundSecret(service, binding, _has_own_value(service, sandbox)), value):
            failed.append(sandbox)
    if failed:
        raise MsbError(
            errors.FAILURE,
            f"could not apply '{service}' to running sandbox(es): {', '.join(failed)}",
            "check msb logs for failures; a new credential requires a restart: "
            "run 'acq stop NAME && acq start NAME'; start will bind the stored credential",
        )


def secret_feed(scope: Scope | str, service: str, value: str, host: str = "", env: str = "") -> None:
    """After the acq store write: re-feed running sandboxes from the store.

    ``value`` is not used: each sandbox gets the value that takes precedence for
    it, read back from the store (a sandbox with its own value keeps it when a
    global value changes).
    """
    del value
    _refeed(service, secretstore.as_scope(scope))


# --- secret rm -------------------------------------------------------------------

def _sweep_unknown(rec: HeldRecord, scope: Scope, service: str) -> bool:
    """Best-effort unbind of ``service`` from a sandbox acq has no knowledge of.

    Returns True when the sandbox is confirmed not to hold the removed value:
    the variable is recorded for another service, or ``msb modify --secret-rm``
    succeeded. msb returns success even if the variable was never bound; a
    non-zero exit is a real failure and is not a confirmation.

    On a global removal a sandbox with its own value is not assumed to hold it:
    a global set by the Bash ``acq`` overwrites a sandbox's own binding, so the
    sandbox may hold the global token. Its own value is re-asserted instead (a
    remove, then a separate add of the sandbox's value, then recorded); if either
    call fails the sandbox stays unconfirmed.
    """
    guess = service_binding(service, rec.name)
    if guess is None:
        return False
    if guess.env in rec.bindings:
        rec.note(service)
        rec.save()
        return True
    if not _modify(rec.name, ["--secret-rm", guess.env]):
        return False
    if scope.is_global and _has_own_value(service, rec.name):
        value = secretstore.resolve(service, rec.name)
        if not value or not _put(rec, BoundSecret(service, guess, True), value):
            return False
        return True
    rec.note(service)
    rec.save()
    return True


def _rebind_global(rec: HeldRecord, service: str) -> None:
    """After a sandbox value is removed, bind the global value in a separate call.

    If that fails the sandbox is left without the credential (warned), never
    with the removed value.
    """
    fallback = service_binding(service, None)
    value = secretstore.resolve(service, None)
    if fallback is not None and value and fallback.env not in rec.bindings:
        if not _put(rec, BoundSecret(service, fallback, False), value):
            print(
                f"acq: warning: removed '{service}' from sandbox '{rec.name}', but could not bind the "
                f"global value there; a new credential requires a restart: run 'acq stop {rec.name} && "
                f"acq start {rec.name}'; start will bind the stored global value",
                file=sys.stderr,
            )


def _unbind_one(scope: Scope, service: str, sandbox: str) -> str:
    """Take ``scope``'s binding of ``service`` out of ``sandbox``.

    Returns ``ok``, ``failed`` (a recorded binding could not be removed) or
    ``unconfirmed`` (acq has no record of what the sandbox holds, and could not
    confirm it does not hold this binding).
    """
    rec = held_read(sandbox)
    wanted = "global" if scope.is_global else "sandbox"
    envs = [e for e, v in rec.bindings.items() if v["service"] == service and v["scope"] == wanted]
    for env in envs:
        if not _drop(rec, env):
            return "failed"
    removed = bool(envs)
    if not rec.knows(service):
        if not _sweep_unknown(rec, scope, service):
            return "unconfirmed"
        removed = removed or not (scope.is_global and _has_own_value(service, sandbox))
    if removed and not scope.is_global:
        _rebind_global(rec, service)
    return "ok"


# ``secret rm --accept-unconfirmed`` is honoured by this adapter (the neutral
# seam refuses the flag for a backend without it).
ACCEPT_UNCONFIRMED = True


def secret_unbind(scope: Scope | str, service: str, *, accept_unconfirmed: list[str] | None = None) -> list[str]:
    """Before the store entry is deleted: unbind it from every sandbox that may hold it.

    A sandbox with a record is unbound exactly where the record shows the
    binding (stopped ones included). A sandbox msb lists without a record (or
    whose record does not cover this service) is unknown and gets a best-effort
    ``--secret-rm``. If a recorded binding cannot be removed, or an unknown
    sandbox cannot be confirmed unbound, this raises ``unbind_failed`` naming
    them, and the caller keeps the store entry so the removal can be retried.

    ``accept_unconfirmed`` names unknown sandboxes the user accepts leaving
    unconfirmed after a real remove failure or an unresolved endpoint mapping.
    Removing an absent variable succeeds in msb. Only those are accepted, with
    a stderr note; they are returned. A recorded binding that fails is never accepted.
    """
    sc = secretstore.as_scope(scope)
    if service_binding(service, sc.sandbox) is None:
        print(
            f"acq: warning: '{service}' has no msb binding to resolve (no endpoint mapping or provider pin); "
            "sandboxes acq has no record for cannot be checked for it",
            file=sys.stderr,
        )
    if _live_refeed_off():
        return []
    names = list_names()
    if names is None:
        raise MsbError(
            errors.FAILURE,
            "could not list sandboxes to unbind the secret from",
            "check that msb works ('msb list'), then retry",
        )
    targets = names if sc.is_global else [n for n in names if n == sc.sandbox]
    outcome = {sandbox: _unbind_one(sc, service, sandbox) for sandbox in targets}
    failed = [n for n, o in outcome.items() if o == "failed"]
    accepted = [n for n, o in outcome.items() if o == "unconfirmed" and n in (accept_unconfirmed or [])]
    unconfirmed = [n for n, o in outcome.items() if o == "unconfirmed" and n not in accepted]
    if failed or unconfirmed:
        parts = [f"could not unbind '{service}' from sandbox(es): {', '.join(failed)}"] if failed else []
        if unconfirmed:
            parts.append(
                f"could not confirm '{service}' is unbound from sandbox(es) acq has no binding record for: "
                f"{', '.join(unconfirmed)}"
            )
        raise MsbError(
            errors.UNBIND_FAILED,
            "; ".join(parts) + "; it is still stored in the acq secret store",
            "retry the removal; remove a sandbox that stays unreachable or unconfirmed ('acq rm NAME' or "
            "'msb remove NAME'), or accept an unconfirmed one with --accept-unconfirmed NAME",
        )
    if accepted:
        print(
            f"acq: note: accepted that '{service}' could not be confirmed unbound from sandbox(es) "
            f"{', '.join(accepted)}; it may still be injected there until they are removed",
            file=sys.stderr,
        )
    return accepted


def secret_set(scope: Scope | str, service: str, value: str, *, timeout: float | None = None) -> None:
    """Store and bind a secret: preflight, acq store write, then re-feed.

    ``acq secret set`` drives the same three steps through the neutral seam.
    """
    del timeout
    sc = secretstore.as_scope(scope)
    secret_preflight(sc, service)
    secretstore.set_secret(service, sc.sandbox, value)
    secret_feed(sc, service, "")


def secret_has(scope: Scope | str, service: str) -> bool:
    """``secret has``: can msb inject ``service`` into ``scope``?

    True when the service has a binding and a value resolves for it, the
    sandbox's own value first, then the global one (a sandbox can be injected
    with a global secret). A value stored where it cannot be read, or one with no
    binding, is not injectable.
    """
    sc = secretstore.as_scope(scope)
    return service_binding(service, sc.sandbox) is not None and secretstore.has(service, sc.sandbox)


def secret_rm(scope: Scope | str, service: str) -> None:
    """Unbind from the sandboxes holding it, then delete the store value and endpoint."""
    sc = secretstore.as_scope(scope)
    secret_unbind(sc, service)
    secretstore.delete(secretstore.key_for(service, sc.sandbox))
    secretstore.meta_delete(service, sc.sandbox)


# --- secret ls -------------------------------------------------------------------

def _ls_entry(sandbox: str | None, service: str) -> dict:
    binding = service_binding(service, sandbox)
    return {
        "scope": "global" if sandbox is None else sandbox,
        "scope_kind": "global" if sandbox is None else "sandbox",
        "service": service,
        "value_state": "unreadable" if secretstore.unreadable(service, sandbox) else "set",
        "binding": binding.flag if binding is not None else None,
    }


def secret_ls(scope: Scope | str | None = None) -> list[dict]:
    """``secret-list``: the acq store's entries, never a value.

    Each entry is ``{scope, scope_kind, service, value_state, binding}``;
    ``scope_kind`` is ``global``, ``sandbox``, or ``unknown`` for a legacy key,
    so a sandbox named ``global`` reads as a sandbox. ``binding`` is the
    ``ENV@HOST`` msb would use (None when it has none). ``scope`` filters by
    scope kind, so a sandbox named ``global`` is never listed as global. A
    legacy multi-dot key (scope ``?``) is listed only when unfiltered.
    """
    want = None if scope is None else secretstore.as_scope(scope)
    out: list[dict] = []
    for key in secretstore.list_keys():
        decoded = secretstore.decode_key(key)
        if decoded is None or not decoded[1]:
            continue
        raw_scope, service = decoded
        if raw_scope == "?":
            if want is None:
                out.append({"scope": "?", "scope_kind": "unknown", "service": service, "value_state": "set", "binding": None})
            continue
        sandbox = None if raw_scope == "-g" else raw_scope
        if want is None or want.sandbox == sandbox:
            out.append(_ls_entry(sandbox, service))
    return out


# ---------------------------------------------------------------------------
# Provider-credential / github-scope / rotation verbs (ADR-0040m secret-write,
# key-rotate; ADR-0012, ADR-0013). The destination pin (key_env + hosts) and the
# per-sandbox scope are host-side authority (``provider_creds``).
# ---------------------------------------------------------------------------

def provider_credential_set(provider: str, key_env: str, hosts: list[str], value: str) -> None:
    """Pin a provider's destination, store its credential, and bind it.

    The pin is recorded first, so create, re-feed and ``secret rm`` all resolve
    the same binding (:func:`service_binding`); then the value goes to the
    global store entry for ``provider`` and running sandboxes without their own
    value are re-fed. A ``--host``/``--env`` record for the provider that names
    a different destination is refused rather than silently overridden either
    way. Raises :class:`MsbError`.
    """
    host = ",".join(hosts)
    if not _binding_ok(key_env, host):
        raise MsbError(
            errors.VALIDATION_FAILED,
            f"msb cannot bind provider '{provider}' as {key_env}@{host}",
            "use an upper-case env var name and plain DNS hosts",
        )
    recorded = secretstore.meta_resolve_exact(provider, None)
    if recorded is not None and (recorded.env, recorded.host) != (key_env, host):
        raise MsbError(
            errors.VALIDATION_FAILED,
            f"'{provider}' already has a recorded endpoint {recorded.env}@{recorded.host}, "
            f"which differs from {key_env}@{host}",
            f"remove it with 'acq secret rm -g {provider}', then pin the provider again; nothing was changed",
        )
    try:
        provider_creds.set_binding(provider, key_env, hosts)
    except state.StateSchemaError as exc:
        raise MsbError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"remove or repair the unreadable provider-credential binding for '{provider}', then retry",
        ) from exc
    secretstore.store(secretstore.key_for(provider), value)
    _refeed(provider, secretstore.GLOBAL)


def github_scope(sandbox: str, value: str) -> None:
    """Store a GitHub token for ``sandbox`` only and bind it (ADR-0013).

    The same path as ``acq secret set SANDBOX github``: the value goes to the
    acq secret store under the sandbox scope and a running sandbox is re-fed;
    a new one binds it at create. Raises :class:`MsbError`.
    """
    secret_set(secretstore.sandbox_scope(sandbox), "github", value)


# --- usai-rotate-api-key (ADR-0012) ------------------------------------------
#
# Rotation is a store write plus a re-feed (plan default: no provider probe; the
# attach-time key check is the verdict). ``commands/creds.py`` runs the
# preflight, writes the new key to the acq store, then calls the re-feed, which
# reads the key back from the store exactly as ``secret set -g`` re-feeds it.


def rotate_preflight(*, primary: bool = True) -> dict | None:
    """Refuse a rotation msb could never deliver, before anything is stored.

    Returns None: unlike sbx, msb has no listing of its own to read here, so
    it never reports itself as not re-fed at this stage."""
    del primary  # the same on msb whether it is the active backend or not
    if service_binding(provider_creds.USAI_PROVIDER_ID) is None:
        raise MsbError(
            errors.VALIDATION_FAILED,
            "the USAi key has no usable msb binding (its recorded endpoint or provider pin is invalid)",
            "check it with 'acq secret ls -g' and 'acq provider-credential ls'; nothing was changed",
        )
    return None


def _rotate_key_holders() -> list[str] | None:
    """The sandboxes whose binding record says they hold the USAi key, read
    from acq's own records; None when a record cannot be read. A name that is
    not a string is reported as ``?``."""
    directory = state.state_dir() / "msb-secret-bindings"
    try:
        records = sorted(directory.glob("*.json"))
        docs = [json.loads(path.read_text(encoding="utf-8")) for path in records]
    except (OSError, ValueError):
        return None
    holders: list[str] = []
    for doc in docs:
        bindings = doc.get("bindings") if isinstance(doc, dict) else None
        if not isinstance(bindings, dict):
            return None
        if any(isinstance(e, dict) and e.get("service") == provider_creds.USAI_PROVIDER_ID for e in bindings.values()):
            name = doc.get("sandbox")
            holders.append(name if isinstance(name, str) else "?")
    return holders


def rotate_holds_key() -> bool | None:
    """Whether any sandbox acq recorded holds the USAi key, read from acq's own
    binding records without running msb. None when a record cannot be read.

    Used only for an msb that fails acq's version check, and any msb command
    opens (and may one-way migrate) msb's catalog (ADR-0032), so acq cannot ask
    msb which sandboxes still exist. Every record therefore counts, including
    one left by a sandbox removed outside acq: that fails safe (the rotation
    exits 1 rather than claim nothing holds the key), and
    :func:`rotate_stale_hint` tells the user how to clear such a record."""
    holders = _rotate_key_holders()
    return None if holders is None else bool(holders)


def rotate_stale_hint() -> str | None:
    """How to clear a binding record left by a sandbox removed outside acq,
    naming the sandboxes whose records hold the USAi key (None when there are
    none, or they cannot be read)."""
    holders = _rotate_key_holders()
    if not holders:
        return None
    return (
        f"acq's records say {', '.join(holders)} hold the USAi key; if one of them was removed outside acq, its "
        "record is stale: once msb passes acq's version check, 'acq --backend msb rm NAME' clears it"
    )


def _rotate_timed_out(what: str, budget: float) -> str:
    """Why a rotation's msb call failed when it outlasted its budget (never a value)."""
    return f"'{what}' timed out after {budget:g}s"


def _rotate_one(service: str, sandbox: str, budget: float) -> str | None:
    """Re-feed the stored global key to one running sandbox.

    Returns None when it was re-fed, ``"kept"`` when the sandbox has its own
    value, ``"skipped"`` when its recorded provider selection leaves usai out
    and it holds no usai binding (:func:`_selection_withholds`), or the variable is bound there for another service (warned, as
    :func:`_refeed` does), or the reason it was not re-fed. Each
    msb call is bounded by ``budget`` seconds, and one that times out counts as
    a failure. Any failure is confined to this sandbox.
    """
    try:
        if _has_own_value(service, sandbox):
            return "kept"
        if _selection_withholds(service, sandbox):
            return "skipped"
        binding = service_binding(service, sandbox)
        value = secretstore.resolve(service, sandbox)
        if binding is None or not value:
            return "no injectable value"
        rec = held_read(sandbox)
        holder = rec.bindings.get(binding.env)
        if holder is not None and holder["service"] != service:
            print(
                f"acq: warning: the new '{service}' key was not applied to sandbox '{sandbox}': "
                f"{binding.env} is bound there for '{holder['service']}'",
                file=sys.stderr,
            )
            return "skipped"
        if not _put(rec, BoundSecret(service, binding, False), value, budget):
            return "msb modify failed"
    except subprocess.TimeoutExpired:
        return _rotate_timed_out("msb modify", budget)
    except (MsbError, secretstore.SecretStoreError) as exc:
        return exc.message
    return None


def rotate_refeed(value: str, *, primary: bool = True) -> dict:
    """Push the stored global USAi key to every running sandbox.

    ``value`` is not used: each sandbox gets the key read back from the acq
    store, and a sandbox with its own ``usai`` value keeps it (``kept_own``).
    ``primary`` makes no difference on msb, whose re-feed never creates
    anything beyond the bindings ``secret set -g usai`` would. Stopped
    sandboxes are not re-fed (``acq start`` passes them the stored key).
    Every msb call is bounded (:func:`timeouts.rotate_timeout_s`), as on sbx,
    since it runs under the usai provider lock.
    Returns ``{backend, refed, kept_own, not_refed}``; a sandbox that did not
    receive the key is listed in ``not_refed`` with the reason, and the rest
    are still re-fed. Raises :class:`MsbError` only when the running sandboxes
    cannot be listed (or the listing times out).
    """
    del value, primary
    service = provider_creds.USAI_PROVIDER_ID
    budget = timeouts.rotate_timeout_s()
    out: dict = {"backend": "msb", "refed": [], "kept_own": [], "not_refed": []}
    try:
        targets = [] if _live_refeed_off() else _running_targets(secretstore.GLOBAL, budget)
    except subprocess.TimeoutExpired:
        raise MsbError(
            errors.TIMEOUT,
            _rotate_timed_out("msb list", budget),
            f"check that msb responds ('msb list'); set {timeouts.ROTATE_TIMEOUT_ENV} to a larger number of "
            "seconds if it is only slow, then re-run 'acq usai-rotate-api-key' with the same key",
        ) from None
    for sandbox in targets:
        problem = _rotate_one(service, sandbox, budget)
        if problem is None:
            out["refed"].append(sandbox)
        elif problem == "kept":
            out["kept_own"].append(sandbox)
        elif problem != "skipped":
            out["not_refed"].append(f"{sandbox} ({problem})")
    return out
