"""MSB backend adapter — subprocess-calling lifecycle + secret side (ADR-0040m).

The read side (detection + version floor) lives in ``backends.py``; this module
owns the mutating/lifecycle verbs the seam drives — ``create``, ``list``,
``exec`` (readiness probe + agent launch), ``stop``, ``remove``, ``copy``, and
``ports`` — plus the secret verbs ``secret_set``/``secret_has``/``secret_rm``/
``secret_ls`` — by invoking the ``msb`` CLI as a subprocess. The adapter reports
outcomes and never decides trust: sandbox identity, agent, and workspace
authority stay host-side in the seam (``cli.py`` + ``state.py``), per ADR-0040m
§trust ownership. A secret VALUE crosses the adapter boundary only as the child's
stdin — never argv, never output.

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


def create(name: str, image: str, workspace: str, memory: str | None = None, cpus: str | None = None) -> None:
    """Create a sandbox. Raises :class:`MsbError` on backend failure."""
    argv = [
        "create",
        "--name",
        name,
        "--image",
        image,
        "--volume",
        f"{workspace}:{workspace}",
    ]
    if memory:
        argv += ["--memory", memory]
    if cpus:
        argv += ["--cpus", cpus]
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
        argv += ["-w", workspace]
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

# ``msb secret …`` takes the scope as either the ``--global`` flag or a leading
# positional sandbox name; a global scope is encoded as the flag so a sandbox
# whose name happens to be ``--global`` can never be confused with the flag.
_GLOBAL_SCOPE = "global"


def _secret_scope_argv(scope: str) -> list[str]:
    """Encode a scope as the ``msb secret …`` argv token (non-secret)."""
    return ["--global"] if scope == _GLOBAL_SCOPE else [scope]


def secret_set(scope: str, service: str, value: str, *, timeout: float | None = None) -> None:
    """Store a secret for ``(scope, service)``. The value travels on stdin only.

    Raises :class:`MsbError` on a backend failure. ``value`` is never logged or
    echoed; the raw backend stderr is deliberately not surfaced (ADR-0040m: raw
    backend text is never a portable field).
    """
    proc = _run(["secret", "set", *_secret_scope_argv(scope), service], input_text=value, timeout=timeout)
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"could not store secret '{service}' for scope '{scope}'",
            "check backend logs and retry",
        )


def secret_has(scope: str, service: str) -> bool:
    """True when a secret for ``(scope, service)`` is present; False when absent.

    Tri-state at the caller's level: presence is a bool, but a backend that
    *cannot answer* raises :class:`MsbError` (``backend_not_found`` from a missing
    binary, ``failure`` from an unexpected exit status) so the seam never
    conflates "the backend is down" with "the secret is absent" (ADR-0040m: fail
    closed, but with the accurate code).

    There is no dedicated `secret has` capability: on msb, presence is read
    through the ``secret-list`` capability (ADR-0040m's ``key_present`` obligation
    is sbx-only), so ``secret has`` is a thin exit-status predicate over
    ``msb secret has``.
    """
    proc = _run(["secret", "has", *_secret_scope_argv(scope), service])
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    raise MsbError(
        errors.FAILURE,
        f"could not query secret '{service}' for scope '{scope}'",
        "check backend logs and retry",
    )


def secret_rm(scope: str, service: str) -> None:
    """Remove a secret for ``(scope, service)``. Raises :class:`MsbError` on failure.

    The seam (:func:`cli.run_secret_rm`) checks presence first and reports
    ``secret_missing`` for an absent secret; a nonzero exit here is a generic
    backend failure, not a missing-secret signal (mirrors the sandbox
    exists-then-remove pattern).
    """
    proc = _run(["secret", "rm", *_secret_scope_argv(scope), service])
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"could not remove secret '{service}' for scope '{scope}'",
            "check backend logs and retry",
        )


def secret_ls(scope: str | None = None) -> list[dict]:
    """Return ``[{scope, service, value_state}, …]`` — never a value.

    ``scope`` is an optional filter (``"global"`` or a sandbox name); ``None``
    lists every scope. An inspect that *fails* or returns unparseable output, or a
    wrong-shape document *or entry*, raises :class:`MsbError` with
    ``secret_unreadable`` so the seam fails closed rather than swallowing the
    store status as an empty list (ADR-0038m §48 drops
    "inspection-failure-as-empty").
    """
    argv = ["secret", "ls"]
    if scope is not None:
        argv += _secret_scope_argv(scope)
    proc = _run(argv)
    if proc.returncode != 0:
        raise MsbError(
            errors.SECRET_UNREADABLE,
            "could not read the secret store",
            "check backend logs and retry",
        )
    try:
        doc = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        raise MsbError(
            errors.SECRET_UNREADABLE,
            "could not parse the secret store listing",
            "the backend returned an unreadable secret list; check backend logs and retry",
        )
    if not isinstance(doc, list):
        raise MsbError(
            errors.SECRET_UNREADABLE,
            "could not parse the secret store listing",
            "the backend returned an unexpected secret-list shape; check backend logs and retry",
        )
    out: list[dict] = []
    for entry in doc:
        # A wrong-shape *entry* (non-dict, or missing scope/service) fails closed
        # too — never silently dropped (ADR-0038m §48 drops
        # "inspection-failure-as-empty"; a partially-readable listing is treated as
        # unreadable, not as an empty result). NOTE: ``ports()`` still skips
        # individual wrong-shape port entries; it should be aligned to fail closed
        # the same way in a later pass (left unchanged here to keep this slice
        # focused on the secret surface).
        if not isinstance(entry, dict) or "scope" not in entry or "service" not in entry:
            raise MsbError(
                errors.SECRET_UNREADABLE,
                "could not parse the secret store listing",
                "the backend returned an unexpected secret-list entry; check backend logs and retry",
            )
        out.append(
            {
                "scope": entry["scope"],
                "service": entry["service"],
                "value_state": entry.get("value_state", "set"),
            }
        )
    return out


# ---------------------------------------------------------------------------
# Provider-credential / github-scope / rotation verbs (ADR-0040m secret-write,
# key-rotate; ADR-0012, ADR-0013). A credential VALUE crosses the adapter
# boundary only as the child's stdin (never argv, never output). The destination
# pin (key_env + hosts) and the per-sandbox scope are host-side authority
# (``provider_creds``); these verbs only move the value.
# ---------------------------------------------------------------------------

def provider_credential_set(provider: str, key_env: str, hosts: list[str], value: str) -> None:
    """Store a provider credential value, pinned to ``key_env`` + ``hosts``.

    The value travels on stdin only; ``key_env`` and ``hosts`` are non-secret
    identifiers carried on argv so the backend binds the credential to its
    destination. Raises :class:`MsbError` on a backend failure; ``value`` is
    never logged or echoed.
    """
    proc = _run(
        ["provider-credential", "set", provider, key_env, "--host", ",".join(hosts)],
        input_text=value,
    )
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"could not store the credential for provider '{provider}'",
            "check backend logs and retry",
        )


def github_scope(sandbox: str, value: str) -> None:
    """Store a sandbox-scoped GitHub token (ADR-0013); value travels on stdin only.

    The token is bound to ``sandbox`` (never global) and never logged or echoed.
    """
    proc = _run(["github-scope", sandbox], input_text=value)
    if proc.returncode != 0:
        raise MsbError(
            errors.FAILURE,
            f"could not store the scoped GitHub token for sandbox '{sandbox}'",
            "check backend logs and retry",
        )


def rotate_key(value: str) -> None:
    """Rotate the USAi key: validate the new key, then replace the old (ADR-0012).

    The backend validates the new key against the provider before storing it, so
    the old key is only ever replaced after the new one is confirmed. The new key
    travels on stdin only and is never echoed. Failure maps to the stable
    rotation codes (ADR-0040m): ``provider_unreachable`` / ``provider_auth_failed``
    when the provider cannot be reached or rejects the new key, else ``failure``.
    """
    proc = _run(["rotate"], input_text=value)
    if proc.returncode == 0:
        return
    if proc.returncode == 2:
        raise MsbError(
            errors.PROVIDER_UNREACHABLE,
            "the USAi provider endpoint could not be reached during rotation; the old key was left in place",
            "check network/proxy access to the provider, then retry",
        )
    if proc.returncode == 3:
        raise MsbError(
            errors.PROVIDER_AUTH_FAILED,
            "the USAi provider rejected the new key during rotation; the old key was left in place",
            "mint a valid key and retry",
        )
    raise MsbError(
        errors.FAILURE,
        "the USAi key rotation failed",
        "check backend logs and retry",
    )
