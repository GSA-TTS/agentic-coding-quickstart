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
``provider-credential``/``github-scope``/``rotate`` subcommand. The secret verbs
(``secret_set``/``secret_has``/``secret_rm``/``secret_ls``) and the credential
verbs (``provider_credential_set``/``github_scope``/``rotate_key``) therefore fail
closed with ``unsupported_capability`` (msb's secrets are per-sandbox ``--secret
ENV@HOST`` bindings, a provider-credential concern that lands with a later slice).
A secret VALUE never crosses this boundary.

The ``msb`` executable is overridable via ``ACQ_MSB_BIN`` for reproducible,
offline contract vectors. ``__stub__`` routes to the bundled deterministic fake
``acq_py._stub_msb``; any other value is parsed as a command line. This is an
internal test seam, never a secret, never written to acq output.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys

from . import errors

STUB_SENTINEL = "__stub__"

# Guest sizing defaults (ADR-0011): msb defaults a sandbox to 512 MiB / 1 vCPU
# with no swap, so acq requests a larger fixed default, tunable via env.
DEFAULT_MEMORY = "4G"
DEFAULT_CPUS = "2"

# Exec-ready gate budget (seconds): `msb create` returns 0 even on async boot
# failure, so readiness is proven by a successful `msb exec` (ADR-0011).
READY_TIMEOUT_S = float(os.environ.get("ACQ_MSB_READY_TIMEOUT", "30"))


def _guest_path(host: str) -> str:
    """Translate a native host path into its POSIX guest form (ADR-0029).

    msb's ``--volume HOST:GUEST`` maps a native host source to a distinct POSIX
    guest destination; the same POSIX form is the ``-w``/``--workdir`` start
    directory. On POSIX the two forms are identical. On Windows a drive-form path
    (``C:\\Users\\me\\proj``) becomes the microVM's POSIX form (``/c/Users/me/proj``)
    so the guest side is never a drive path. A UNC path (``\\\\server\\share\\proj``
    — the form ``os.path.realpath`` yields for a mapped network drive) becomes
    ``/server/share/proj``: the guest has no drive or UNC vocabulary, so the server
    name is just the first path component and the leading double backslash collapses
    to a single slash (never a leading ``//``, whose meaning is
    implementation-defined in the guest). This mirrors the Bash adapter's
    ``canonicalize_path`` (``cygpath -u``); the native Python adapter is not under
    MSYS, so it computes the form directly.
    """
    if os.name == "nt":
        if host.startswith("\\\\"):
            # UNC form: the leading double backslash is the server prefix, not two
            # separators — collapse it to one slash so the server name is the first
            # component instead of an empty component (``//server``).
            return "/" + host[2:].replace("\\", "/")
        drive, sep, rest = host.partition(":")
        if sep and len(drive) == 1 and drive.isalpha():
            return "/" + drive.lower() + rest.replace("\\", "/")
        return host.replace("\\", "/")
    return host


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
        return [sys.executable, "-m", "acq_py._stub_msb"]
    if override:
        return shlex.split(override)
    return ["msb"]


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
# subcommands, so those obligations fail closed (``unsupported``). Secrets on msb
# are per-sandbox ``--secret ENV@HOST`` bindings on create/start plus
# ``--secret-rm`` on ``modify`` — a provider-credential concern that lands with a
# later slice, not a standalone key/value store. ``kit-apply`` is implemented
# in-guest via ``msb exec`` (no ``kit-apply`` subcommand), so it stays required.
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
            "secret-write": "unsupported",  # no `secret` subcommand on msb
            "secret-rm": "unsupported",
            "secret-list": "unsupported",
            "key-rotate": "unsupported",  # no `rotate` subcommand on msb
            "key-present": "unsupported",
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
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            [*msb_command(), *argv],
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        # A missing msb binary must never surface as an uncaught traceback
        # (ADR-0040m stable error vocabulary): fail closed with a code the seam
        # can map, not a raw OSError.
        raise MsbError(
            errors.BACKEND_NOT_FOUND,
            "the msb backend CLI could not be run",
            "install msb and retry",
        ) from exc


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


def create(
    name: str,
    image: str,
    workspace: str,
    memory: str | None = None,
    cpus: str | None = None,
    guest_workspace: str | None = None,
) -> None:
    """Create a sandbox. Raises :class:`MsbError` on backend failure.

    Reconciles with the real msb 0.7.11 ``create``: the image is *positional*
    (``msb create --name X IMAGE``), the workspace is a ``--volume
    HOST:POSIX-GUEST`` mapping (distinct host source vs guest destination, never
    the same path twice), the start directory is ``-w`` (the same POSIX guest
    form), and memory/cpus are ``-m``/``-c``. ``workspace`` is a native host path;
    ``guest_workspace`` overrides the derived POSIX guest form (ADR-0029,
    ADR-0038m §4 host/guest path types are distinct).
    """
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
    argv.append(image)  # positional image (last)
    proc = _run(argv)
    if proc.returncode != 0:
        # `failure` is the ADR-0038m usage/failure minimum's generic
        # operational-failure code (no ADR-0040m code describes a backend command
        # returning nonzero); the raw backend stderr is deliberately not surfaced.
        raise MsbError(
            errors.FAILURE,
            f"msb create failed for sandbox '{name}'",
            "check msb logs and retry",
        )


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


def kit_apply(name: str, kit: str, install_cmd: list[str]) -> None:
    """Apply a kit in-guest (ADR-0040m ``kit-apply``): run the kit's pinned
    install command inside the sandbox as the unprivileged ``agent`` user.

    acq never executes kit code on the host (ADR-0038m §46): the install command
    is data sourced from the pinned control plane and is forwarded verbatim to the
    backend, which runs it in-guest. The argv is the ``nix profile install
    …#<agent>`` install — it carries no credential — so nothing sensitive crosses
    the boundary. Raises :class:`MsbError` on backend failure.

    Idempotency is a host-authoritative concern (the seam short-circuits a re-apply
    of an already-applied kit via :func:`acq_py.kits.kit_applied_read`); the
    backend re-runs a genuinely idempotent install when asked, and the host record
    is the durable "already applied" signal.
    """
    # Reconciles with the real msb 0.7.11 CLI: there is NO `kit-apply` subcommand.
    # The pinned install command runs in-guest via `msb exec -u agent NAME -- …`.
    proc = _run(["exec", "-u", "agent", name, "--", *install_cmd])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"could not apply kit '{kit}' to sandbox '{name}'",
            "check msb logs and retry",
        )


def provision_substrate(name: str, steps: list[list[str]]) -> None:
    """Provision addressable substrate gaps in-guest (ADR-0030 "bring-your-own
    image contract"): bootstrap single-user Nix + devenv + direnv and create the
    agent user before the agent install.

    The steps are data sourced from the pinned control plane (never a secret,
    never a credential) and run in-guest via the backend seam; acq never executes
    them on the host. Raises :class:`MsbError` on backend failure.
    """
    # Reconciles with the real msb 0.7.11 CLI: there is NO `substrate-provision`
    # subcommand. Each bootstrap step runs in-guest via `msb exec -u agent NAME -- …`.
    for step in steps:
        proc = _run(["exec", "-u", "agent", name, "--", *step])
        if proc.returncode != 0:
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
    replaced by a harness object without a usable fileno().
    """
    if json_mode:
        try:
            stdout: object = sys.stderr.fileno()
        except (AttributeError, OSError, ValueError):
            stdout = 2
    else:
        stdout = None
    return subprocess.run([*msb_command(), *argv], stdout=stdout).returncode


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
    except (json.JSONDecodeError, ValueError):
        raise MsbError(
            errors.FAILURE,
            f"could not parse declared ports for sandbox '{name}'",
            "the backend returned an unreadable inspect result; check msb logs and retry",
        )

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
# Secret verbs (ADR-0040m `secret-write/rm`, `secret-list`). The value is the one
# thing that must NEVER cross the CLI/adapter boundary except on the child's
# stdin: scope and service are non-secret identifiers carried on argv, while the
# value itself is passed via stdin (never argv) and never echoed, logged, or
# returned by any of these functions (ADR-0038m §user story #7 "no secret
# exposure").
# ---------------------------------------------------------------------------

def _secret_unsupported(verb: str) -> MsbError:
    """The fail-closed refusal for every secret verb on msb (ADR-0040m).

    msb 0.7.11 has no standalone ``secret`` subcommand and no secret store: secrets
    are per-sandbox ``--secret ENV@HOST`` bindings on create/start plus
    ``--secret-rm`` on ``modify``, whose destination host comes from the
    provider-credential binding (a later slice). Until that slice lands, a secret
    request fails closed with ``unsupported_capability`` rather than inventing a
    backend store msb does not have.
    """
    return MsbError(
        errors.UNSUPPORTED,
        f"secret {verb} is not supported on the msb backend",
        "msb has no standalone secret store; per-sandbox --secret ENV@HOST bindings land with the provider-credential slice",
    )


# ``msb secret …`` takes the scope as either the ``--global`` flag or a leading
# positional sandbox name; a global scope is encoded as the flag so a sandbox
# whose name happens to be ``--global`` can never be confused with the flag.
_GLOBAL_SCOPE = "global"


def _secret_scope_argv(scope: str) -> list[str]:
    """Encode a scope as the ``msb secret …`` argv token (non-secret)."""
    return ["--global"] if scope == _GLOBAL_SCOPE else [scope]


def secret_set(scope: str, service: str, value: str, *, timeout: float | None = None) -> None:
    """``secret-write`` fails closed on msb (no ``secret`` subcommand, ADR-0040m).

    The value is never read, logged, or placed on argv: the refusal happens before
    the value crosses the boundary. Raises :class:`MsbError` with
    ``unsupported_capability``.
    """
    raise _secret_unsupported("set")


def secret_has(scope: str, service: str) -> bool:
    """True when a secret for ``(scope, service)`` is present; False when absent.

    Tri-state at the caller's level: presence is a bool, but a backend that
    *cannot answer* raises :class:`MsbError` (``backend_not_found`` from a missing
    binary, ``failure`` from an unexpected exit status) so the seam never
    conflates "the backend is down" with "the secret is absent" (ADR-0040m: fail
    closed, but with the accurate code).

    There is no dedicated `secret has` capability on msb: msb has no standalone
    secret store, so presence cannot be answered and fails closed with
    ``unsupported_capability`` (never a silent "absent").
    """
    raise _secret_unsupported("has")


def secret_rm(scope: str, service: str) -> None:
    """Remove a secret for ``(scope, service)``. Raises :class:`MsbError` on failure.

    The seam (:func:`cli.run_secret_rm`) checks presence first and reports
    ``secret_missing`` for an absent secret; a nonzero exit here is a generic
    backend failure, not a missing-secret signal (mirrors the sandbox
    exists-then-remove pattern). On msb the whole store is unsupported, so this
    fails closed with ``unsupported_capability`` before any removal.
    """
    raise _secret_unsupported("rm")


def secret_ls(scope: str | None = None) -> list[dict]:
    """``secret-list`` fails closed on msb (no ``secret`` subcommand, ADR-0040m).

    Raises :class:`MsbError` with ``unsupported_capability``. The listing never
    returns a value, and on msb it never returns a listing at all.
    """
    raise _secret_unsupported("ls")


# ---------------------------------------------------------------------------
# Provider-credential / github-scope / rotation verbs (ADR-0040m secret-write,
# key-rotate; ADR-0012, ADR-0013). A credential VALUE crosses the adapter
# boundary only as the child's stdin (never argv, never output). The destination
# pin (key_env + hosts) and the per-sandbox scope are host-side authority
# (``provider_creds``); these verbs only move the value.
# ---------------------------------------------------------------------------

def provider_credential_set(provider: str, key_env: str, hosts: list[str], value: str) -> None:
    """Provider-credential binding fails closed on msb (no equivalent subcommand).

    The value is never read or placed on argv. msb binds provider credentials as
    per-sandbox ``--secret ENV@HOST`` references (a later slice); there is no
    ``provider-credential`` subcommand, so this raises :class:`MsbError` with
    ``unsupported_capability``.
    """
    raise MsbError(
        errors.UNSUPPORTED,
        f"provider-credential storage is not supported on the msb backend for provider '{provider}'",
        "msb binds provider credentials via --secret ENV@HOST at create/start (provider-credential slice)",
    )


def github_scope(sandbox: str, value: str) -> None:
    """GitHub per-sandbox scoping fails closed on msb (no ``github-scope`` subcommand).

    The token is never read or placed on argv; the refusal happens before the value
    crosses the boundary. Raises :class:`MsbError` with ``unsupported_capability``.
    """
    raise MsbError(
        errors.UNSUPPORTED,
        f"GitHub token scoping is not supported on the msb backend for sandbox '{sandbox}'",
        "msb binds GitHub credentials via --secret GITHUB_TOKEN@github.com,... at create/start (provider-credential slice)",
    )


def rotate_key(value: str) -> None:
    """USAi key rotation fails closed on msb (no ``rotate`` subcommand, ADR-0012).

    The new key is never read or placed on argv. Raises :class:`MsbError` with
    ``unsupported_capability``.
    """
    raise MsbError(
        errors.UNSUPPORTED,
        "USAi key rotation is not supported on the msb backend",
        "rotation is a provider-credential operation with no msb subcommand equivalent",
    )
