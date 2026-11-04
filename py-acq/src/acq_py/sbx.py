"""SBX backend adapter — subprocess-calling lifecycle + secret + kit-source side.

The read side (detection + version floor) lives in ``backends.py``; this module
owns the mutating/lifecycle verbs the seam drives — ``create``, ``list``,
``exec`` (readiness probe + agent launch), ``stop``, ``remove``, ``copy``, and
``ports`` — plus the secret verbs ``secret_set``/``secret_rm`` and the sbx-only
obligations ``key_present``, ``kit_source_revoked``, and raw-placeholder removal —
by invoking the ``sbx`` CLI as a subprocess. The adapter reports outcomes and never
decides trust: sandbox identity, agent, and workspace authority stay host-side in
the seam (``cli.py`` + ``state.py``), per ADR-0040m §trust ownership. A secret VALUE
crosses the adapter boundary only as the child's stdin — never argv, never output.

This mirrors ``msb.py``'s ``_run``/``_run_stream`` + stdin-value discipline. The
command names differ where the two backends genuinely differ (``ls``/``rm``/``cp``/
``ports`` vs msb's ``list``/``remove``/``copy``/``inspect``), and sbx adds
proxy-table mechanics msb has no equivalent of (``key_present``, raw-placeholder
removal, and the ``kit.allowedSources`` revocation). The real sbx ``create``
translation (positional agent, ``--template`` image, ``--env`` workspace markers)
is a Tier-3 live concern and is not synthesized here; the offline vectors drive the
deterministic ``__stub__`` instead.

The ``sbx`` executable is overridable via ``ACQ_SBX_BIN`` for reproducible, offline
contract vectors. ``__stub__`` routes to the bundled deterministic fake
``acq_py._stub_sbx``; any other value is parsed as a command line. This is an
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

# Exec-ready gate budget (seconds). sbx's ``create`` returns 0 even on async boot
# failure, so readiness is proven by a successful ``sbx exec`` (mirrors msb).
READY_TIMEOUT_S = float(os.environ.get("ACQ_SBX_READY_TIMEOUT", "30"))


class SbxError(Exception):
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


def sbx_command() -> list[str]:
    """Resolve the sbx CLI argv (an internal test seam; default ``sbx``)."""
    override = os.environ.get("ACQ_SBX_BIN")
    if override == STUB_SENTINEL:
        return [sys.executable, "-m", "acq_py._stub_sbx"]
    if override:
        return shlex.split(override)
    return ["sbx"]


def _run(
    argv: list[str],
    *,
    timeout: float | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            [*sbx_command(), *argv],
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise SbxError(
            errors.BACKEND_NOT_FOUND,
            "the sbx backend CLI could not be run",
            "install sbx and retry",
        ) from exc


# ---------------------------------------------------------------------------
# Capability record (ADR-0040m). A declaration, not a proof: conformance is
# asserted by the Tier-1 subprocess vectors and, for host-enforcement
# capabilities, by a Tier-3 live transcript.
# ---------------------------------------------------------------------------

# The declared capability map. Support levels: ``required`` (implemented and
# conformance-asserted), ``optional`` (declared but not part of the shipped
# surface), ``unsupported`` (fails closed with ``unsupported_capability``).
# ``secret-list``/``start`` are msb-only obligations; ``key-present``/
# ``kit-source-revoke`` are sbx-only (ADR-0040m).
def capability_record(version: str | None = None) -> dict:
    return {
        "backend": "sbx",
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
            "kit-apply": "unsupported",  # deferred to the kit-apply slice
            "secret-write": "required",
            "secret-rm": "required",
            "secret-list": "unsupported",  # msb-only (secret_ls)
            "key-rotate": "required",
            "key-present": "required",  # sbx-only
            "kit-source-revoke": "required",  # sbx-only
            "start": "unsupported",  # msb-only
            "restart": "unsupported",  # msb-only
            "provenance": "required",
            "doctor": "required",
        },
    }


# ---------------------------------------------------------------------------
# Lifecycle verbs.
# ---------------------------------------------------------------------------

def list_names() -> list[str] | None:
    """Return sandbox names (one per line), or ``None`` if ``sbx ls -q`` failed."""
    proc = _run(["ls", "-q"])
    if proc.returncode != 0:
        return None
    return [line for line in proc.stdout.splitlines() if line]


def running_names() -> list[str] | None:
    """Return running sandbox names, or ``None`` if ``sbx ls --running -q`` failed."""
    proc = _run(["ls", "--running", "-q"])
    if proc.returncode != 0:
        return None
    return [line for line in proc.stdout.splitlines() if line]


def exists(name: str) -> bool:
    names = list_names()
    return names is not None and name in names


def create(name: str, image: str, workspace: str, memory: str | None = None, cpus: str | None = None) -> None:
    """Create a sandbox. Raises :class:`SbxError` on backend failure.

    ``memory``/``cpus`` are accepted for signature parity with :mod:`acq_py.msb`
    but are not forwarded: sbx derives guest sizing from its templates. The real
    sbx create translation (positional agent, ``--template`` image) is a Tier-3
    concern; the stub models ``--image``/``--volume`` for the offline vectors.
    """
    argv = [
        "create",
        "--name",
        name,
        "--image",
        image,
        "--volume",
        f"{workspace}:{workspace}",
    ]
    proc = _run(argv)
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"sbx create failed for sandbox '{name}'",
            "check sbx logs and retry",
        )


def exec_ready(name: str) -> bool:
    """True when ``sbx exec NAME -- true`` succeeds (the exec-ready gate)."""
    try:
        proc = _run(["exec", name, "--", "true"], timeout=5)
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0


def stop(name: str) -> None:
    proc = _run(["stop", name])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"sbx stop failed for sandbox '{name}'",
            "check sbx logs and retry",
        )


def remove(name: str) -> None:
    proc = _run(["rm", "--force", name])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"sbx remove failed for sandbox '{name}'",
            "check sbx logs and retry",
        )


def _run_stream(argv: list[str], *, json_mode: bool) -> int:
    """Run a backend command with the child's exit status as the return value.

    Mirrors :func:`acq_py.msb._run_stream`: in ``json_mode`` the child's stdout is
    routed to stderr so the CLI's stdout stays a single JSON document.
    """
    if json_mode:
        try:
            stdout: object = sys.stderr.fileno()
        except (AttributeError, OSError, ValueError):
            stdout = 2
    else:
        stdout = None
    return subprocess.run([*sbx_command(), *argv], stdout=stdout).returncode


def launch(name: str, workspace: str | None, agent: str | None, *, json_mode: bool = False) -> int:
    """Launch the recorded agent (or a login shell) in the foreground.

    sbx's agent templates bake the unprivileged ``agent`` user, so there is no
    ``-u`` flag to pass (unlike msb). The child's exit status is this function's
    return value (ADR-0038m §1).
    """
    if agent and agent != "shell":
        command = [agent]
    else:
        command = ["/bin/sh", "-l"]
    return exec_command(name, command, workspace=workspace, json_mode=json_mode)


def exec_command(name: str, command: list[str], *, workspace: str | None = None, json_mode: bool = False) -> int:
    """Run an explicit command non-interactively (``acq exec``); returns its status.

    ``workspace`` is accepted for parity but not forwarded: sbx mounts the recorded
    workspace at create time and the agent templates cd into it, so there is no
    per-exec ``-w`` flag. The command after ``--`` is forwarded verbatim
    (ADR-0038m §4).
    """
    argv = ["exec", name, "--", *command]
    return _run_stream(argv, json_mode=json_mode)


def copy(src: str, dst: str) -> int:
    """Invoke ``sbx cp SRC DST``; return its exit status (status preservation)."""
    proc = _run(["cp", src, dst])
    return proc.returncode


def ports(name: str) -> list[dict]:
    """Return a sandbox's *declared* host/guest port mappings (ADR-0038m §ports).

    Reads create-time mappings from ``sbx ports NAME --format json`` (backend
    authority, host-side). A ports call that *fails* or returns unparseable
    output raises :class:`SbxError` so the seam fails closed rather than
    swallowing the backend status as an empty list (ADR-0038m §48 drops
    "inspection-failure-as-empty").
    """
    proc = _run(["ports", name, "--format", "json"])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not read declared ports for sandbox '{name}'",
            "check sbx logs and retry",
        )
    try:
        doc = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        raise SbxError(
            errors.FAILURE,
            f"could not parse declared ports for sandbox '{name}'",
            "the backend returned an unreadable ports result; check sbx logs and retry",
        )
    if not isinstance(doc, dict):
        raise SbxError(
            errors.FAILURE,
            f"could not parse declared ports for sandbox '{name}'",
            "the backend returned an unexpected ports shape; check sbx logs and retry",
        )
    entries = doc.get("ports")
    if entries is None:
        return []
    if not isinstance(entries, list):
        raise SbxError(
            errors.FAILURE,
            f"could not parse declared ports for sandbox '{name}'",
            "the backend returned an unexpected ports shape; check sbx logs and retry",
        )
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
    return out


# ---------------------------------------------------------------------------
# Secret verbs. The value is the one thing that must NEVER cross the CLI/adapter
# boundary except on the child's stdin (ADR-0038m §user story #7).
# ---------------------------------------------------------------------------

# ``sbx secret …`` takes the scope as either the ``--global`` flag or a leading
# positional sandbox name (mirrors msb).
_GLOBAL_SCOPE = "global"


def _secret_scope_argv(scope: str) -> list[str]:
    return ["--global"] if scope == _GLOBAL_SCOPE else [scope]


def secret_set(scope: str, service: str, value: str, *, timeout: float | None = None) -> None:
    """Store a secret for ``(scope, service)``. The value travels on stdin only."""
    proc = _run(["secret", "set", *_secret_scope_argv(scope), service], input_text=value, timeout=timeout)
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not store secret '{service}' for scope '{scope}'",
            "check backend logs and retry",
        )


def secret_rm(scope: str, service: str) -> None:
    """Remove a managed secret for ``(scope, service)``. Raises on backend failure."""
    proc = _run(["secret", "rm", *_secret_scope_argv(scope), service])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not remove secret '{service}' for scope '{scope}'",
            "check backend logs and retry",
        )


def key_present(scope: str, service: str) -> bool:
    """sbx-only ``key_present`` obligation (ADR-0040m): is the sbx key present?

    Reports presence, never the value. On sbx there is no ``secret-list``
    capability (that obligation is msb-only), so presence is a thin exit-status
    predicate over ``sbx secret has`` (which reads the proxy table). Tri-state at
    the caller's level: presence is a bool, but a backend that *cannot answer*
    raises :class:`SbxError` so the seam never conflates "the backend is down"
    with "the secret is absent".
    """
    proc = _run(["secret", "has", *_secret_scope_argv(scope), service])
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    raise SbxError(
        errors.FAILURE,
        f"could not query secret '{service}' for scope '{scope}'",
        "check backend logs and retry",
    )


def secret_rm_raw(placeholder: str) -> None:
    """sbx-only raw-placeholder removal (ADR-0038m §48).

    Removes a raw placeholder from sbx's custom-secrets table via
    ``sbx secret rm --placeholder TOKEN``. It is backend-specific and leaves the
    acq store unchanged: it never rewrites host-held records, and the placeholder
    is never a secret value.
    """
    proc = _run(["secret", "rm", "--placeholder", placeholder])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not remove raw placeholder '{placeholder}' from the sbx proxy table",
            "check backend logs and retry",
        )


# ---------------------------------------------------------------------------
# Provider-credential / github-scope / rotation verbs. A credential VALUE crosses
# the adapter boundary only as the child's stdin (never argv, never output).
# ---------------------------------------------------------------------------

def provider_credential_set(provider: str, key_env: str, hosts: list[str], value: str) -> None:
    """Store a provider credential value, pinned to ``key_env`` + ``hosts``.

    The value travels on stdin only; ``key_env`` and ``hosts`` are non-secret
    identifiers carried on argv. The real sbx translation (``secret set-custom``)
    is a Tier-3 concern; the stub models the neutral verb for the offline vectors.
    """
    proc = _run(
        ["provider-credential", "set", provider, key_env, "--host", ",".join(hosts)],
        input_text=value,
    )
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not store the credential for provider '{provider}'",
            "check backend logs and retry",
        )


def github_scope(sandbox: str, value: str) -> None:
    """Store a sandbox-scoped GitHub token (ADR-0013); value travels on stdin only."""
    proc = _run(["github-scope", sandbox], input_text=value)
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not store the scoped GitHub token for sandbox '{sandbox}'",
            "check backend logs and retry",
        )


def rotate_key(value: str) -> None:
    """Rotate the USAi key: validate the new key, then replace the old (ADR-0012).

    Mirrors :func:`acq_py.msb.rotate_key`'s exit-code mapping to the stable
    rotation codes (ADR-0040m): ``provider_unreachable`` / ``provider_auth_failed``
    when the provider cannot be reached or rejects the new key, else ``failure``.
    """
    proc = _run(["rotate"], input_text=value)
    if proc.returncode == 0:
        return
    if proc.returncode == 2:
        raise SbxError(
            errors.PROVIDER_UNREACHABLE,
            "the USAi provider endpoint could not be reached during rotation; the old key was left in place",
            "check network/proxy access to the provider, then retry",
        )
    if proc.returncode == 3:
        raise SbxError(
            errors.PROVIDER_AUTH_FAILED,
            "the USAi provider rejected the new key during rotation; the old key was left in place",
            "mint a valid key and retry",
        )
    raise SbxError(
        errors.FAILURE,
        "the USAi key rotation failed",
        "check backend logs and retry",
    )


# ---------------------------------------------------------------------------
# Kit-source revocation (sbx-only, ADR-0040m ``kit_source_revoked``).
# ---------------------------------------------------------------------------

def _owner_prefix(repo: str) -> str:
    """sbx's ``kit.allowedSources`` is owner-granular: ``host/owner/``."""
    parts = [p for p in repo.split("/") if p]
    if len(parts) >= 2:
        return "/".join(parts[:2]) + "/"
    return repo + "/"


def kit_source_revoked(repo: str) -> str:
    """Revoke a trusted kit source from sbx's ``kit.allowedSources``.

    sbx's allowlist is owner-granular and acq only ever *unions* onto it, so a
    source removed from the acq registry stays fetchable until the owner prefix is
    dropped here. Returns the revoked owner prefix (the "revoked ref") on success;
    raises :class:`SbxError` on any inability to revoke — never a quiet 0.
    """
    proc = _run(["kit-source-revoke", repo])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not revoke kit source '{repo}' from the sbx backend",
            "check sbx logs and retry",
        )
    revoked = proc.stdout.strip()
    return revoked or _owner_prefix(repo)
