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
proxy-table mechanics msb has no equivalent of (``key_present``, ``secret_ls``,
raw-placeholder removal, and the ``kit.allowedSources`` revocation via
``sbx settings``). sbx HAS a ``secret`` subcommand (``set``/``ls``/``rm``), so the
secret verbs work here (value on stdin), while ``create`` maps to the positional
``sbx create AGENT [PATH] --name N -t IMAGE`` form and rotation (no ``rotate``
subcommand) fails closed with ``unsupported_capability``.

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
#
# Reconcile with the real sbx 0.50.1 CLI: sbx HAS a ``secret`` subcommand with
# ``set``/``ls``/``rm`` (so ``secret-list`` is required, not msb-only), but it has
# NO ``rotate`` subcommand (``key-rotate`` is unsupported) and no ``kit-source-revoke``
# subcommand — the kit ``allowedSources`` allowlist is managed via
# ``sbx settings get/set kit.allowedSources``, which ``kit_source_revoked`` drives.
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
            "secret-list": "required",  # sbx has `secret ls`
            "key-rotate": "unsupported",  # no `rotate` subcommand on sbx
            "key-present": "required",  # sbx-only (via `secret ls --json`)
            "kit-source-revoke": "required",  # sbx-only (via `sbx settings`)
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
    """Return running sandbox names, or ``None`` if ``sbx ls --json`` failed.

    The real ``sbx ls`` has no ``--running`` flag (only ``--format``/``--json``/
    ``-q``), so running state is derived from ``sbx ls --json``, whose entries
    carry a ``status`` field. A wrong-shape or unparseable listing is ``None``
    (the caller treats it as "cannot determine", never as "all stopped").
    """
    proc = _run(["ls", "--json"])
    if proc.returncode != 0:
        return None
    try:
        doc = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(doc, list):
        return None
    return [
        entry["name"]
        for entry in doc
        if isinstance(entry, dict) and entry.get("status") == "running" and isinstance(entry.get("name"), str)
    ]


def exists(name: str) -> bool:
    names = list_names()
    return names is not None and name in names


def create(
    name: str,
    image: str,
    workspace: str,
    memory: str | None = None,
    cpus: str | None = None,
    agent: str | None = None,
) -> None:
    """Create a sandbox. Raises :class:`SbxError` on backend failure.

    Reconciles with the real sbx 0.50.1 ``create AGENT [PATH] --name N -t IMAGE``:
    the agent and workspace path are *positional*, the name is ``--name``, and the
    container image is ``-t/--template``. ``memory``/``cpus`` are accepted for
    signature parity with :mod:`acq_py.msb` but not forwarded (sbx derives guest
    sizing from its templates).
    """
    argv = ["create"]
    if agent:
        argv.append(agent)
    argv.append(workspace)
    argv += ["--name", name]
    argv += ["-t", image]
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

# ``sbx secret …`` takes a sandbox scope as the ``--sandbox NAME`` flag; the
# GLOBAL scope is the DEFAULT (no flag) on ``set``/``rm`` (the real sbx dropped
# the ``-g``/``--global`` flag on those verbs). ``secret ls`` still takes ``-g``.
_GLOBAL_SCOPE = "global"


def _secret_scope_argv(scope: str) -> list[str]:
    """Encode a scope for ``sbx secret set/rm`` (global is the default, no flag)."""
    return [] if scope == _GLOBAL_SCOPE else ["--sandbox", scope]


def _secret_list_docs() -> list[dict]:
    """Run ``sbx secret ls --json`` and flatten its object envelope.

    The real ``sbx secret ls --json`` returns an OBJECT, not a list:
    ``{secrets: [], custom_secrets: [], shadowed_services: [], env_only_count: 0}``.
    Each ``secrets``/``custom_secrets`` entry is ``{scope, type, name, secret:
    "(stored)"}`` — the value is never present. This flattens those entries into
    ``{scope, service, value_state}``. An inspect that *fails* or returns
    unparseable/wrong-shape output raises :class:`SbxError` with
    ``secret_unreadable`` (ADR-0038m §48 drops "inspection-failure-as-empty").
    """
    proc = _run(["secret", "ls", "--json"])
    if proc.returncode != 0:
        raise SbxError(
            errors.SECRET_UNREADABLE,
            "could not read the secret store",
            "check backend logs and retry",
        )
    try:
        doc = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        raise SbxError(
            errors.SECRET_UNREADABLE,
            "could not parse the secret store listing",
            "the backend returned an unreadable secret list; check backend logs and retry",
        )
    if not isinstance(doc, dict):
        raise SbxError(
            errors.SECRET_UNREADABLE,
            "could not parse the secret store listing",
            "the backend returned an unexpected secret-list shape; check backend logs and retry",
        )
    out: list[dict] = []
    for key in ("secrets", "custom_secrets"):
        entries = doc.get(key)
        if entries is None:
            # `custom_secrets` may be absent on older sbx; `secrets` is always
            # present. A missing `secrets` key is a wrong shape, not an empty list.
            if key == "secrets":
                raise SbxError(
                    errors.SECRET_UNREADABLE,
                    "could not parse the secret store listing",
                    "the backend returned an unexpected secret-list shape; check backend logs and retry",
                )
            continue
        if not isinstance(entries, list):
            raise SbxError(
                errors.SECRET_UNREADABLE,
                "could not parse the secret store listing",
                "the backend returned an unexpected secret-list shape; check backend logs and retry",
            )
        for entry in entries:
            if not isinstance(entry, dict):
                raise SbxError(
                    errors.SECRET_UNREADABLE,
                    "could not parse the secret store listing",
                    "the backend returned an unexpected secret-list entry; check backend logs and retry",
                )
            scope = entry.get("scope")
            service = entry.get("name") or entry.get("service") or entry.get("env")
            if scope is None or service is None:
                raise SbxError(
                    errors.SECRET_UNREADABLE,
                    "could not parse the secret store listing",
                    "the backend returned an unexpected secret-list entry; check backend logs and retry",
                )
            out.append({"scope": scope, "service": service, "value_state": "set"})
    return out


def secret_set(scope: str, service: str, value: str, *, timeout: float | None = None) -> None:
    """Store a secret for ``(scope, service)``. The value travels on stdin only.

    Reconciles with the real sbx ``secret set SERVICE [--sandbox NAME]``: the
    service is the sole positional, the value is read from stdin, and the global
    scope is the default (no flag). The real sbx prompts "Overwrite? (y/N)" when
    the secret already exists (it has no stdin ``--force``), which would consume
    the piped value as the answer — so presence is pre-checked and an existing
    secret fails closed (never piped into the prompt).
    """
    if key_present(scope, service):
        raise SbxError(
            errors.FAILURE,
            f"secret '{service}' already exists in scope '{scope}'",
            f"remove it first (e.g. 'acq secret rm -g {service}'), then re-set",
        )
    proc = _run(["secret", "set", *_secret_scope_argv(scope), service], input_text=value, timeout=timeout)
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not store secret '{service}' for scope '{scope}'",
            "check backend logs and retry",
        )


def secret_rm(scope: str, service: str) -> None:
    """Remove a managed secret for ``(scope, service)``. Raises on backend failure.

    Reconciles with the real sbx ``secret rm SERVICE [--sandbox NAME] -f`` (the
    ``-f`` suppresses the interactive confirm prompt).
    """
    proc = _run(["secret", "rm", *_secret_scope_argv(scope), service, "-f"])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not remove secret '{service}' for scope '{scope}'",
            "check backend logs and retry",
        )


def secret_ls(scope: str | None = None) -> list[dict]:
    """``secret-list`` on sbx (``sbx secret ls --json``): scope/service/value_state.

    ``scope`` is an optional filter (``"global"`` or a sandbox name); ``None``
    lists every scope. Never returns a value.

    NOTE: the scope filter is applied CLIENT-SIDE — the adapter lists all scopes
    once and filters, rather than passing ``-g``/``--sandbox`` to ``sbx secret
    ls``. This keeps ``key_present`` (which also reads the full list) and
    ``secret_ls`` on the same single listing, and avoids the set/rm-vs-ls scope
    asymmetry (set/rm use a global default with no flag; ``ls`` has ``-g``).
    """
    docs = _secret_list_docs()
    if scope is None:
        return docs
    return [d for d in docs if d["scope"] == scope]


def key_present(scope: str, service: str) -> bool:
    """sbx-only ``key_present`` obligation (ADR-0040m): is the sbx key present?

    Reports presence, never the value. sbx has no ``secret has`` subcommand, so
    presence is a predicate over the ``secret ls --json`` listing. Tri-state at the
    caller's level: presence is a bool, but a backend that *cannot answer* raises
    :class:`SbxError` so the seam never conflates "the backend is down" with "the
    secret is absent".
    """
    for entry in _secret_list_docs():
        if entry["scope"] == scope and entry["service"] == service:
            return True
    return False


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
    """Store a destination-pinned provider credential; value travels on stdin only.

    Reconciles with the real sbx 0.51.0 ``secret set-custom``: sbx added a
    ``--value-stdin`` flag (v0.51.0) that reads the secret value from stdin,
    keeping it out of shell history and the process list. The provider's ``hosts``
    list maps to repeated ``--host`` flags and ``key_env`` maps to ``--env``; the
    value is piped on the child's stdin only (never argv, never output), per
    ADR-0038m §7 "never in argv". The secret is global (the ``set-custom``
    default — no ``--sandbox`` flag), matching the host-side binding's
    destination-pinned (not sandbox-pinned) authority. An already-present entry
    is the backend's own fail-closed error (``set-custom`` has no overwrite
    prompt to consume the piped value), surfaced as a stable ``failure`` code.
    """
    argv = ["secret", "set-custom"]
    for host in hosts:
        argv += ["--host", host]
    argv += ["--env", key_env, "--value-stdin"]
    proc = _run(argv, input_text=value)
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not store provider credential '{key_env}' for provider '{provider}'",
            "check backend logs and retry",
        )


def github_scope(sandbox: str, value: str) -> None:
    """Store a sandbox-scoped GitHub token (ADR-0013); value travels on stdin only.

    Reconciles with the real sbx ``secret set github --sandbox NAME`` (github is a
    built-in sbx service); the token is bound to ``sandbox`` (never global). The
    same "Overwrite?" pre-check as :func:`secret_set` applies (the value must never
    be consumed by the prompt).
    """
    if key_present(sandbox, "github"):
        raise SbxError(
            errors.FAILURE,
            f"GitHub token already exists for sandbox '{sandbox}'",
            f"remove it first (acq secret rm {sandbox} github), then re-scope",
        )
    proc = _run(["secret", "set", "--sandbox", sandbox, "github"], input_text=value)
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not store the scoped GitHub token for sandbox '{sandbox}'",
            "check backend logs and retry",
        )


def rotate_key(value: str) -> None:
    """USAi key rotation fails closed on sbx (no ``rotate`` subcommand, ADR-0012).

    The new key is never read or placed on argv. Raises :class:`SbxError` with
    ``unsupported_capability``.
    """
    raise SbxError(
        errors.UNSUPPORTED,
        "USAi key rotation is not supported on the sbx backend",
        "rotation is a provider-credential operation with no sbx subcommand equivalent",
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

    sbx has no ``kit-source-revoke`` subcommand: the allowlist lives under
    ``sbx settings`` as a JSON array at ``kit.allowedSources``, so revocation is a
    read-modify-write of that setting (owner-granular, ``host/owner/``). acq only
    ever *unions* onto the allowlist, so a source removed from the acq registry
    stays fetchable until the owner prefix is dropped here. Returns the revoked
    owner prefix (the "revoked ref") on success; raises :class:`SbxError` on any
    inability to revoke — never a quiet 0.
    """
    prefix = _owner_prefix(repo)
    proc = _run(["settings", "get", "kit.allowedSources"])
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not read sbx kit.allowedSources to revoke '{repo}'",
            "check sbx logs and retry",
        )
    try:
        sources = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        raise SbxError(
            errors.FAILURE,
            f"could not parse sbx kit.allowedSources to revoke '{repo}'",
            "check sbx logs and retry",
        )
    if not isinstance(sources, list):
        raise SbxError(
            errors.FAILURE,
            f"could not parse sbx kit.allowedSources to revoke '{repo}'",
            "check sbx logs and retry",
        )
    if prefix in sources:
        desired = json.dumps([s for s in sources if s != prefix])
        proc = _run(["settings", "set", "kit.allowedSources", desired])
        if proc.returncode != 0:
            raise SbxError(
                errors.FAILURE,
                f"could not write sbx kit.allowedSources to revoke '{repo}'",
                "check sbx logs and retry",
            )
    return prefix
