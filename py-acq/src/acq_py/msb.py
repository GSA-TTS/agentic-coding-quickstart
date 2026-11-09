"""MSB backend adapter — subprocess-calling lifecycle side (ADR-0040m).

The read side (detection + version floor) lives in ``backends.py``; this module
owns the mutating/lifecycle verbs the seam drives — ``create``, ``list``,
``exec`` (readiness probe + agent launch), ``stop``, ``remove``, ``copy``, and
``ports`` — plus the in-guest ``kit_apply``/``provision_substrate`` (both driven
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
``github_scope`` and ``rotate_key`` still fail closed with
``unsupported_capability``.

The ``msb`` executable is overridable via ``ACQ_MSB_BIN`` for reproducible,
offline contract vectors. ``__stub__`` routes to the bundled deterministic fake
``acq_py._stub_msb``; any other value is parsed as a command line. This is an
internal test seam, never a secret, never written to acq output.
"""

from __future__ import annotations

import json
import ntpath
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

from . import errors, hostexec, kits, provider_creds, secretstore, timeouts
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
            "key-rotate": "unsupported",  # no `rotate` subcommand on msb
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
    env = {**os.environ, **secret_env} if secret_env else None
    try:
        if input_text is None:
            return subprocess.run(
                [*msb_command(), *argv],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env,
            )
        return subprocess.run(
            [*msb_command(), *argv],
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
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


def list_names() -> list[str] | None:
    """Return sandbox names (one per line), or ``None`` if ``msb list`` failed."""
    proc = _run(["list", "-q"])
    if proc.returncode != 0:
        return None
    return [line for line in proc.stdout.splitlines() if line]


def running_names() -> list[str] | None:
    """Return running sandbox names, or ``None`` if ``msb list`` failed."""
    proc = _run(["list", "--running", "-q"])
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


def _kit_rules(egress_kits: list[str]) -> list[str]:
    """``--net-rule allow@HOST`` for each kit's allowlist (port stripped, as Bash)."""
    if kits.KIT_NETWORK_ALLOW_REF != kits.CONTROL_PLANE_REF:
        raise _policy_error(
            "cannot compute the egress policy: the kit network allowlist was derived "
            f"at {kits.KIT_NETWORK_ALLOW_REF}, not the pinned control plane {kits.CONTROL_PLANE_REF}",
            "re-derive kits.KIT_NETWORK_ALLOW from the pinned kit specs",
        )
    flags: list[str] = []
    for kit in egress_kits:
        allow = kits.KIT_NETWORK_ALLOW.get(kit)
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
    path = Path(os.environ.get("ACQ_MSB_BALANCED_HOSTS_FILE") or BALANCED_HOSTS_FILE)
    remediation = "restore the balanced host list, or set ACQ_NETWORK_TIER=strict"
    if not path.is_absolute():
        # A relative override resolves against the cwd, which may be a mounted
        # workspace the agent can write.
        raise _policy_error(
            f"ACQ_MSB_BALANCED_HOSTS_FILE must be an absolute path, not {str(path)!r}",
            "set ACQ_MSB_BALANCED_HOSTS_FILE to an absolute path",
        )
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


def egress_flags(egress_kits: list[str]) -> list[str]:
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
    flags.append("--tls-intercept")
    return flags


def create(
    name: str,
    image: str,
    workspace: str,
    memory: str | None = None,
    cpus: str | None = None,
    guest_workspace: str | None = None,
    *,
    egress_kits: list[str],
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

    ``egress_kits`` names the kits whose allowlists form the egress policy
    (see :func:`egress_flags`). It is required so no caller can create a sandbox
    without one; the policy is computed before msb is invoked.

    Every secret the sandbox can be injected with (:func:`secret_bindings`) is
    bound as ``--secret ENV@HOST``; the values travel only in the child's
    environment mapping.
    """
    egress = egress_flags(egress_kits)
    secret_flags, secret_env = secret_bindings(name)
    guest = guest_workspace or _guest_path(workspace)
    argv = [
        "create",
        "--name",
        name,
        "--volume",
        f"{workspace}:{guest}",
        "-w",
        guest,
    ]
    if memory:
        argv += ["-m", memory]
    if cpus:
        argv += ["-c", cpus]
    argv += egress
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
    return secret_flags[1::2]


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


def kit_apply(name: str, kit: str, install_cmd: list[str]) -> None:
    """Apply a kit in-guest (ADR-0040m ``kit-apply``): run the kit's pinned
    install command inside the sandbox as the unprivileged ``agent`` user.

    acq never executes kit code on the host (ADR-0038m §46): the install command
    is data sourced from the pinned control plane and is forwarded verbatim to the
    backend, which runs it in-guest. The argv is the ``nix profile install
    …#<agent>`` install — it carries no credential — so nothing sensitive crosses
    the boundary. The step never reads the user's terminal, runs with the git
    prompt guards, and is time-bounded (:func:`_guest_step`). Raises
    :class:`MsbError` on backend failure or timeout.

    Idempotency is a host-authoritative concern (the seam short-circuits a re-apply
    of an already-applied kit via :func:`acq_py.kits.kit_applied_read`); the
    backend re-runs a genuinely idempotent install when asked, and the host record
    is the durable "already applied" signal.
    """
    # Reconciles with the real msb 0.7.11 CLI: there is NO `kit-apply` subcommand.
    # The pinned install command runs in-guest via `msb exec -u agent NAME -- …`.
    if not _guest_step(name, "agent", install_cmd):
        raise MsbError(
            errors.FAILURE,
            f"could not apply kit '{kit}' to sandbox '{name}'",
            "check msb logs and retry",
        )


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
    proc = _run(["stop", name])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"msb stop failed for sandbox '{name}'",
            "check msb logs and retry",
        )


def remove(name: str) -> None:
    proc = _run(["remove", "--force", name])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"msb remove failed for sandbox '{name}'",
            "check msb logs and retry",
        )


def _run_stream(argv: list[str], *, json_mode: bool) -> int:
    """Run a backend command with the child's exit status as the return value.

    In ``json_mode`` the child's stdout is routed to stderr (fd 2) so the CLI's
    stdout stays a single JSON document (ADR-0038m §2); otherwise stdio is
    inherited so the child renders directly (and a TTY would attach normally).
    Passing the fd directly keeps this working when ``sys.stderr`` has been
    replaced by a harness object without a usable fileno(). A CLI that cannot be
    started raises :class:`MsbError` (``backend_not_found``), as :func:`_run` does.
    """
    if json_mode:
        try:
            stdout: int | None = sys.stderr.fileno()
        except (AttributeError, OSError, ValueError):
            stdout = 2
    else:
        stdout = None
    try:
        return subprocess.run([*msb_command(), *argv], stdout=stdout).returncode
    except OSError as exc:
        raise cli_unavailable() from exc


def launch(name: str, workspace: str | None, agent: str | None, *, json_mode: bool = False) -> int:
    """Launch the recorded agent (or a login shell) in the foreground.

    Runs as the unprivileged ``agent`` user in the recorded workspace (ADR-0011),
    with the child's exit status as this function's return value (child-status
    propagation, ADR-0038m §1). Interactive PTY allocation and ssh-agent
    forwarding are the attach slice's concern; the deterministic non-interactive
    path runs ``msb exec`` without a PTY and never blocks on stdin.
    """
    if agent and agent != "shell":
        command = [agent]
    else:
        command = ["/bin/sh", "-l"]
    return exec_command(name, command, workspace=workspace, json_mode=json_mode)


def exec_command(name: str, command: list[str], *, workspace: str | None = None, json_mode: bool = False) -> int:
    """Run an explicit command non-interactively (``acq exec``); returns its status.

    Mirrors :func:`launch` but forwards an arbitrary ``command`` verbatim after the
    ``--`` separator (ADR-0038m §4 "exec argv after ``--`` is opaque").
    """
    argv = ["exec", "-u", "agent"]
    if workspace:
        # `-w` is the POSIX *guest* start directory (ADR-0029): the adapter owns
        # the host->guest translation, so the native host path the seam passed is
        # converted to its guest form here (never a drive path).
        argv += ["-w", _guest_path(workspace)]
    argv += [name, "--", *command]
    return _run_stream(argv, json_mode=json_mode)


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
                    # TODO(publish): post-hoc `--publish` mappings (ADR-0015) must
                    # carry origin="post-hoc"; only create-time `-p` mappings read
                    # from `msb inspect` are "create".
                    "origin": "create",
                }
            )
    return out


# ---------------------------------------------------------------------------
# Credential bindings (Bash `_acq_msb_service_binding`, `_acq_msb_bind_one`,
# `_acq_msb_bind_secrets_into`). msb keeps no secret store: each secret lives in
# the acq secret store and is bound per sandbox as ``--secret ENV@HOST``. msb
# reads ENV from its own environment and swaps the guest's placeholder for the
# value on the wire to HOST. So a value only ever travels in the msb child's
# environment mapping; argv carries the variable name and host, never the value,
# and no function here returns, logs or raises with a value (ADR-0038m user
# story #7 "no secret exposure").
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


class SecretBinding(NamedTuple):
    """Where one service's secret is injected: the env var msb reads and the
    comma-separated hosts it is substituted for. Never carries a value."""

    env: str
    host: str

    @property
    def flag(self) -> str:
        return f"{self.env}@{self.host}"


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

    The single table for create, re-feed, unbind, ``secret has`` and ``secret
    ls``. An endpoint recorded by ``acq secret set SVC --host H --env E`` wins
    (the sandbox's own record first, then the global one); otherwise ``github``
    has its fixed hosts and a provider its pinned destination
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


def _bind_candidates(name: str) -> list[str]:
    """Services a new sandbox may bind, in Bash's order: github, the services
    with a recorded endpoint (this sandbox's and global), then the providers."""
    out = ["github"]
    for service in secretstore.meta_list(name) + provider_creds.provider_ids():
        if service not in out:
            out.append(service)
    return out


def secret_bindings(name: str) -> tuple[list[str], dict[str, str]]:
    """``(["--secret", "ENV@HOST", ...], {ENV: value})`` for sandbox ``name``.

    A service is bound when it has a binding and a value resolves for it, the
    sandbox's own value taking precedence over the global one. The first service
    to claim an env var keeps it. The caller passes the mapping only as the msb
    child's environment and clears it afterwards.
    """
    flags: list[str] = []
    env: dict[str, str] = {}
    for service in _bind_candidates(name):
        binding = service_binding(service, name)
        if binding is None or binding.env in env:
            continue
        value = secretstore.resolve(service, name)
        if value:
            env[binding.env] = value
            flags += ["--secret", binding.flag]
        value = None
    return flags, env


def secret_preflight(scope: Scope | str, service: str, host: str = "", env: str = "") -> None:
    """Refuse, before anything is stored, a secret msb could never inject.

    An explicit ``--host``/``--env`` must be bindable; without them the service
    needs a recorded endpoint, a fixed one (github) or a provider pin. Storing a
    value msb cannot bind would report a credential the sandbox never receives.
    """
    sc = secretstore.as_scope(scope)
    if host or env:
        if not _binding_ok(env, host):
            raise MsbError(
                errors.VALIDATION_FAILED,
                f"msb cannot bind '{service}' as {env}@{host}",
                "use an upper-case env var name that is not process-critical (e.g. API_KEY) "
                "and plain DNS hosts; nothing was stored",
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


def _running_targets(scope: Scope) -> list[str]:
    """The running sandboxes a change in ``scope`` reaches: the named sandbox
    (if it is running) or every running sandbox for the global scope."""
    names = running_names()
    if names is None:
        raise MsbError(
            errors.FAILURE,
            "could not list running sandboxes to update their credentials",
            "check that msb works ('msb list'), then retry",
        )
    if scope.sandbox is not None:
        return [scope.sandbox] if scope.sandbox in names else []
    return names


def _has_own_value(service: str, sandbox: str) -> bool:
    """True when ``sandbox`` holds its own value for ``service`` (which a global
    change must leave alone: the sandbox scope takes precedence)."""
    return secretstore.name_ok(sandbox) and secretstore.exists(service, sandbox)


def _modify(name: str, flags: list[str], secret_env: dict[str, str] | None = None) -> bool:
    try:
        proc = _run(["modify", name, *flags], secret_env=secret_env)
    finally:
        if secret_env:
            secret_env.clear()
    return proc.returncode == 0


def _refeed(service: str, scope: Scope) -> None:
    """Push ``service``'s current value to the running sandboxes ``scope``
    reaches (``msb modify NAME --secret ENV@HOST``), so a new or changed secret
    applies without a recreate. Raises :class:`MsbError` naming any sandbox that
    could not be updated."""
    if _live_refeed_off():
        return
    failed: list[str] = []
    for sandbox in _running_targets(scope):
        if scope.is_global and _has_own_value(service, sandbox):
            continue
        binding = service_binding(service, sandbox)
        value = secretstore.resolve(service, sandbox)
        if binding is not None and value:
            if not _modify(sandbox, ["--secret", binding.flag], {binding.env: value}):
                failed.append(sandbox)
        value = None
    if failed:
        raise MsbError(
            errors.FAILURE,
            f"could not apply '{service}' to running sandbox(es): {', '.join(failed)}",
            "re-run the command, or recreate those sandboxes to bind the stored value",
        )


def secret_feed(scope: Scope | str, service: str, value: str, host: str = "", env: str = "") -> None:
    """After the acq store write: re-feed running sandboxes from the store.

    ``value`` is not used: each sandbox gets the value that takes precedence for
    it, read back from the store (a sandbox with its own value keeps it when a
    global value changes).
    """
    del value
    _refeed(service, secretstore.as_scope(scope))


def _unbind_flags(scope: Scope, service: str, sandbox: str) -> tuple[list[str], dict[str, str] | None] | None:
    """The ``msb modify`` flags that take ``scope``'s value for ``service`` out
    of ``sandbox``, or None when it is not bound there.

    Removing a sandbox's own value falls back to the global one when that can be
    bound (the sandbox keeps a working credential); otherwise the binding goes.
    """
    current = service_binding(service, sandbox)
    if current is None:
        return None
    if not scope.is_global:
        fallback = service_binding(service, None)
        value = secretstore.resolve(service, None)
        if fallback is not None and value:
            drop = ["--secret-rm", current.env] if fallback.env != current.env else []
            return [*drop, "--secret", fallback.flag], {fallback.env: value}
    return ["--secret-rm", current.env], None


def secret_unbind(scope: Scope | str, service: str) -> None:
    """Before the store entry is deleted: unbind it from running sandboxes.

    Best effort, as in Bash: msb may refuse to remove a binding a sandbox never
    had, so a sandbox that cannot be updated is named in a warning and the
    removal from the store goes ahead.
    """
    sc = secretstore.as_scope(scope)
    if _live_refeed_off():
        return
    failed: list[str] = []
    for sandbox in _running_targets(sc):
        if sc.is_global and _has_own_value(service, sandbox):
            continue
        plan = _unbind_flags(sc, service, sandbox)
        if plan is not None and not _modify(sandbox, *plan):
            failed.append(sandbox)
    if failed:
        print(
            f"acq: warning: could not unbind '{service}' from running sandbox(es) {', '.join(failed)}; "
            "it stays injected there until they are recreated or removed",
            file=sys.stderr,
        )


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
    """Unbind from running sandboxes, then delete the store value and endpoint."""
    sc = secretstore.as_scope(scope)
    secret_unbind(sc, service)
    secretstore.delete(secretstore.key_for(service, sc.sandbox))
    secretstore.meta_delete(service, sc.sandbox)


def _ls_entry(sandbox: str | None, service: str) -> dict:
    binding = service_binding(service, sandbox)
    return {
        "scope": "global" if sandbox is None else sandbox,
        "service": service,
        "value_state": "unreadable" if secretstore.unreadable(service, sandbox) else "set",
        "binding": binding.flag if binding is not None else None,
    }


def secret_ls(scope: Scope | str | None = None) -> list[dict]:
    """``secret-list``: the acq store's entries, never a value.

    Each entry is ``{scope, service, value_state, binding}``; ``binding`` is the
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
                out.append({"scope": "?", "service": service, "value_state": "set", "binding": None})
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
    """Store a provider credential in the acq store and bind it where it runs.

    The value goes to the global store entry for ``provider``; running sandboxes
    without their own value are re-fed ``--secret KEY_ENV@HOSTS``, and new ones
    bind it at create from the recorded pin. Raises :class:`MsbError`.
    """
    host = ",".join(hosts)
    if not _binding_ok(key_env, host):
        raise MsbError(
            errors.VALIDATION_FAILED,
            f"msb cannot bind provider '{provider}' as {key_env}@{host}",
            "use an upper-case env var name and plain DNS hosts",
        )
    secretstore.store(secretstore.key_for(provider), value)
    value = ""
    if _live_refeed_off():
        return
    failed: list[str] = []
    for sandbox in _running_targets(secretstore.GLOBAL):
        if _has_own_value(provider, sandbox):
            continue
        current = secretstore.resolve(provider, None)
        if current and not _modify(sandbox, ["--secret", f"{key_env}@{host}"], {key_env: current}):
            failed.append(sandbox)
        current = None
    if failed:
        raise MsbError(
            errors.FAILURE,
            f"stored the '{provider}' credential, but could not apply it to running sandbox(es): {', '.join(failed)}",
            "re-run the command, or recreate those sandboxes",
        )


def github_scope(sandbox: str, value: str) -> None:
    """GitHub per-sandbox scoping fails closed on msb (no ``github-scope`` subcommand).

    The token is never read or placed on argv; the refusal happens before the value
    crosses the boundary. Raises :class:`MsbError` with ``unsupported_capability``.
    """
    raise MsbError(
        errors.UNSUPPORTED,
        f"GitHub token scoping is not supported on the msb backend for sandbox '{sandbox}'",
        f"to bind a token to this sandbox only, use 'acq secret set {sandbox} github' (value on stdin)",
    )


def rotate_key(value: str) -> None:
    """USAi key rotation fails closed on msb (no ``rotate`` subcommand, ADR-0012).

    The new key is never read or placed on argv. Raises :class:`MsbError` with
    ``unsupported_capability``.
    """
    raise MsbError(
        errors.UNSUPPORTED,
        "USAi key rotation is not supported on the msb backend",
        "store the new key with 'acq secret set -g usai' (value on stdin); running sandboxes are re-fed",
    )
