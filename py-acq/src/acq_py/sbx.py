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
``sbx settings``). sbx HAS a ``secret`` subcommand (``set``/``set-custom``/``ls``/
``rm``), so the secret verbs work here (value on stdin): sbx's built-in services
through ``secret set``, every other endpoint (usai, providers, ``--host``) through
``secret set-custom --value-stdin`` (sbx >= 0.51.0). ``create`` maps to the positional
``sbx create AGENT [PATH] --name N -t IMAGE`` form. sbx has no ``rotate``
subcommand: ``usai-rotate-api-key`` re-sets the key with ``secret set-custom
--placeholder P --value-stdin``, keeping each entry's placeholder.

The ``sbx`` executable is overridable via ``ACQ_SBX_BIN`` for reproducible, offline
contract vectors. ``__stub__`` routes to the bundled deterministic fake
``acq_py._stub_sbx``; any other value is parsed as a command line. This is an
internal test seam, never a secret, never written to acq output.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import NamedTuple

from . import backends, errors, hostexec, kits, provider_creds, secretstore, timeouts
from .secretstore import Scope

STUB_SENTINEL = "__stub__"

# Exec-ready gate budget (seconds). sbx's ``create`` returns 0 even on async boot
# failure, so readiness is proven by a successful ``sbx exec`` (mirrors msb).
DEFAULT_READY_TIMEOUT_S = 30.0
READY_TIMEOUT_ENV = "ACQ_SBX_READY_TIMEOUT"


def ready_timeout_s() -> float:
    """The exec-ready budget in seconds, read when needed (never at import).

    A malformed or non-finite override falls back to the default with a stderr
    warning instead of crashing every command or making the wait unbounded.
    """
    return timeouts.env_seconds(READY_TIMEOUT_ENV, DEFAULT_READY_TIMEOUT_S)


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
        return [sys.executable, "-P", "-m", "acq_py._stub_sbx"]
    if override:
        return hostexec.override_command(override)
    return hostexec.command("sbx")


def _run(
    argv: list[str],
    *,
    timeout: float | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess:
    """Run sbx with its output captured.

    With no ``input_text`` the child's stdin is ``/dev/null``: its output is
    captured, so a prompt it printed (``Remove? (y/N)``) would be invisible
    while it waited on the user's terminal. It sees end-of-input instead.
    """
    try:
        if input_text is None:
            return subprocess.run(
                [*sbx_command(), *argv],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        return subprocess.run(
            [*sbx_command(), *argv],
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except OSError as exc:
        # Mirrors msb._run: a missing or non-executable sbx binary fails closed
        # with a stable code, never a raw OSError traceback.
        raise cli_unavailable() from exc


def cli_unavailable() -> SbxError:
    """The stable error for an sbx CLI that cannot be started at all (see msb)."""
    return SbxError(
        errors.BACKEND_NOT_FOUND,
        "the sbx backend CLI could not be run",
        "install sbx and retry",
    )


# ---------------------------------------------------------------------------
# Capability record (ADR-0040m). A declaration, not a proof: conformance is
# asserted by the Tier-1 subprocess vectors and, for host-enforcement
# capabilities, by a Tier-3 live transcript.
# ---------------------------------------------------------------------------

# The declared capability map. Support levels: ``required`` (implemented and
# conformance-asserted), ``optional`` (declared but not part of the shipped
# surface), ``unsupported`` (fails closed with ``unsupported_capability``).
#
# Reconcile with the real sbx CLI: sbx HAS a ``secret`` subcommand with
# ``set``/``ls``/``rm`` (so ``secret-list`` is required, not msb-only), but it has
# NO ``rotate`` subcommand (``key-rotate`` is served by ``secret set-custom
# --placeholder``, version-gated like any custom endpoint) and no ``kit-source-revoke``
# subcommand — the kit ``allowedSources`` allowlist is managed via
# ``sbx settings get/set kit.allowedSources``, which ``kit_source_revoked`` drives.
# ``secret-write`` for a built-in service works from the global floor, but a
# custom endpoint (``secret set`` for usai, a provider or ``--host``) and
# ``provider-credential set`` are version-gated to sbx >= 0.51.0: their value
# path is ``secret set-custom --value-stdin``, which only exists from 0.51.0 (see
# ``backends.CAPABILITY_FLOORS``).
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
            "kit-apply": "required",  # `create --kit` and `kit add` (acq_py.kit_sbx)
            "secret-write": "required",
            "secret-rm": "required",
            "secret-list": "required",  # sbx has `secret ls`
            "key-rotate": "required",  # secret set-custom --placeholder (sbx >= 0.51.0)
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

def list_names(*, timeout: float | None = None) -> list[str] | None:
    """Return sandbox names (one per line), or ``None`` if ``sbx ls -q`` failed.

    With a ``timeout``, a call that outlasts it raises ``subprocess.TimeoutExpired``."""
    proc = _run(["ls", "-q"], timeout=timeout)
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
    kit_flags: list[str] | None = None,
) -> None:
    """Create a sandbox. Raises :class:`SbxError` on backend failure.

    Reconciles with the real sbx 0.50.1 ``create AGENT [PATH] --name N -t IMAGE``:
    the agent and workspace path are *positional*, the name is ``--name``, and the
    container image is ``-t/--template``. ``memory``/``cpus`` are accepted for
    signature parity with :mod:`acq_py.msb` but not forwarded (sbx derives guest
    sizing from its templates). ``kit_flags`` are the ``--kit DIR`` pairs
    :func:`acq_py.kit_sbx.prepare` built; sbx applies those kits itself.
    """
    argv = ["create"]
    if agent:
        argv.append(agent)
    argv.append(workspace)
    argv += ["--name", name]
    argv += ["-t", image]
    argv += kit_flags or []
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


# ``kit_add`` outcomes (Bash ``_acq_sbx_kit_add``).
KIT_ADD_OK = 0
KIT_ADD_FAILED = 1
KIT_ADD_RECREATE = 3

# sbx 0.38 refuses ``kit add`` of a kit that declares setup.startup; these are
# the phrasings Bash matches (``_acq_sbx_kit_add``). Its stderr is classified
# only, never shown: raw backend text is not part of acq's output.
_RECREATE_PHRASES = ("setup.startup", "declares startup", "can only be used when creating a new sandbox",
                     "create a new sandbox", "recreate the sandbox")


def _refused_for_recreate(err: str) -> bool:
    if any(p in err for p in _RECREATE_PHRASES):
        return True
    start = err.find("startup")
    return start >= 0 and "recreate" in err[start:]


def kit_add(name: str, kit_dir: str) -> int:
    """``sbx kit add NAME DIR``: :data:`KIT_ADD_OK`, :data:`KIT_ADD_RECREATE` or :data:`KIT_ADD_FAILED`."""
    if not kit_dir:
        return KIT_ADD_FAILED
    proc = _run(["kit", "add", name, kit_dir])
    if proc.returncode == 0:
        return KIT_ADD_OK
    return KIT_ADD_RECREATE if _refused_for_recreate(proc.stderr or "") else KIT_ADD_FAILED


def exec_capture(name: str, script: str, timeout: float = 30) -> str | None:
    """``sbx exec NAME -- sh -c SCRIPT`` with stdin closed: its stdout (CRs dropped), or ``None``."""
    try:
        proc = _run(["exec", name, "--", "sh", "-c", script], timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    if proc.returncode != 0:
        return None
    return (proc.stdout or "").replace("\r", "")


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
    """Run a backend command in the foreground; return its shell-style exit status.

    Mirrors :func:`acq_py.msb._run_stream`: in ``json_mode`` the child's stdout is
    routed to stderr so the CLI's stdout stays a single JSON document, a child
    killed by a signal reports ``128 + N``, Ctrl-C is left to the child, and a
    CLI that cannot be started raises :class:`SbxError` (``backend_not_found``).
    """
    if json_mode:
        try:
            stdout: int | None = sys.stderr.fileno()
        except (AttributeError, OSError, ValueError):
            stdout = 2
    else:
        stdout = None
    try:
        return hostexec.run_foreground([*sbx_command(), *argv], stdout=stdout)
    except OSError as exc:
        raise cli_unavailable() from exc


# The agent user's home, passed explicitly so a session sees it on every
# template. SHELL is not set: the template's own value applies.
AGENT_HOME = "/home/agent"
# What ``acq shell`` runs, as Bash's ``acq_backend_shell`` does
# (``sbx exec -it NAME bash``): the sbx agent templates ship bash.
SHELL_COMMAND = ("bash",)


def _session(name: str, command: list[str], *, env: list[str], tty: bool, json_mode: bool) -> int:
    """Run ``command`` in ``name`` with ``env``; ``-it`` (stdin and a PTY) if ``tty``."""
    argv = ["exec", "-it"] if tty else ["exec"]
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
) -> int:
    """Launch the recorded agent (or a login shell) in the foreground.

    sbx's agent templates bake the unprivileged ``agent`` user, so there is no
    ``-u`` flag to pass (unlike msb). When stdin is a terminal (or ``tty`` says
    so) the session gets stdin and a PTY (``sbx exec -it``) and the host's
    TERM/COLORTERM. The child's exit status is this function's return value
    (ADR-0038m §1). ``workspace`` is accepted for parity (see
    :func:`exec_command`).
    """
    interactive = hostexec.stdin_is_tty() if tty is None else tty
    command = [agent] if agent and agent != "shell" else list(SHELL_COMMAND)
    session = [f"HOME={AGENT_HOME}"]
    if interactive:
        session += hostexec.terminal_env()
    return _session(name, command, env=[*session, *(env or [])], tty=interactive, json_mode=json_mode)


def exec_command(
    name: str,
    command: list[str],
    *,
    workspace: str | None = None,
    json_mode: bool = False,
    env: list[str] | None = None,
) -> int:
    """Run an explicit command non-interactively (``acq exec``); returns its status.

    ``workspace`` is accepted for parity but not forwarded: sbx mounts the recorded
    workspace at create time and the agent templates cd into it, so there is no
    per-exec ``-w`` flag. The command after ``--`` is forwarded verbatim
    (ADR-0038m §4).
    """
    session = [f"HOME={AGENT_HOME}", *(env or [])]
    return _session(name, command, env=session, tty=False, json_mode=json_mode)


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
    except (json.JSONDecodeError, ValueError) as exc:
        raise SbxError(
            errors.FAILURE,
            f"could not parse declared ports for sandbox '{name}'",
            "the backend returned an unreadable ports result; check sbx logs and retry",
        ) from exc
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

# sbx's built-in proxy services (Bash ``_ACQ_SBX_BUILTIN_SERVICES``). Only these
# go through ``sbx secret set SERVICE``: sbx accepts any service name there, but
# only a built-in one is mapped to an endpoint, so any other name would be
# stored and never injected. Every other service (usai, a registered provider,
# or an explicit ``--host``) is a custom secret, bound to its hosts and env var
# with ``sbx secret set-custom``.
BUILTIN_SERVICES = frozenset(("anthropic", "github", "gitlab", "google-cloud", "openai", "aws", "azure"))

# ``sbx secret …`` takes a sandbox scope as the ``--sandbox NAME`` flag; the
# GLOBAL scope is the DEFAULT (no flag) on ``set``/``set-custom``/``rm`` (the
# real sbx dropped ``-g``/``--global`` on those verbs). Scopes are typed
# (:class:`secretstore.Scope`), so a sandbox named ``global`` gets
# ``--sandbox global``; a bare string is accepted from older callers.
_GLOBAL_SCOPE = secretstore.GLOBAL

# How the sbx listing labels the global scope. ``sbx secret ls --json`` reports
# ``"global"`` (the sbx 0.51.0 live qualification removed a global secret by
# matching that label), presumably the same string a sandbox named ``global``
# gets. Its table output prints ``(global)``, which no acq sandbox name can be,
# so that label is unambiguous and accepted too.
_GLOBAL_LABEL = "global"
_GLOBAL_TABLE_LABEL = "(global)"

_ENV_NAME_FIRST = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
_ENV_NAME_REST = _ENV_NAME_FIRST | frozenset("0123456789")


def _secret_scope_argv(scope: Scope | str) -> list[str]:
    """Encode a scope for ``sbx secret set/set-custom/rm`` (global is the default, no flag)."""
    sc = secretstore.as_scope(scope)
    return [] if sc.sandbox is None else ["--sandbox", sc.sandbox]


class _Entry(NamedTuple):
    """One row of ``sbx secret ls --json``. Never carries a value."""

    table: str  # "service" (``secrets``) or "custom" (``custom_secrets``)
    label: str  # the listing's scope string
    key: str  # the service name, or a custom secret's env var
    placeholder: str  # custom secrets only ("" when absent)
    targets: frozenset[str] = frozenset()  # custom secrets' hosts, lower-cased (empty when unlisted)


# Custom env var -> the host sets a row's ``targets`` may carry, or ``None`` to
# match the env var alone (nothing recorded which hosts it was bound to).
_Envs = dict[str, set[frozenset[str]] | None]


def _host_set(hosts: object) -> frozenset[str]:
    """A host list (list, or a comma/space-separated string) as a lower-cased set."""
    if isinstance(hosts, str):
        hosts = hosts.replace(",", " ").split()
    if not isinstance(hosts, list):
        return frozenset()
    return frozenset(h.strip().lower() for h in hosts if isinstance(h, str) and h.strip())


def _listing_unreadable(detail: str) -> SbxError:
    return SbxError(
        errors.SECRET_UNREADABLE,
        "could not parse the secret store listing",
        f"the backend returned {detail}; check backend logs and retry",
    )


def _entry_from(table: str, entry: object) -> _Entry:
    if not isinstance(entry, dict):
        raise _listing_unreadable("an unexpected secret-list entry")
    scope = entry.get("scope")
    if table == "service":
        key = entry.get("name") or entry.get("service") or entry.get("env")
    else:
        key = entry.get("env") or entry.get("name")
    if not isinstance(scope, str) or not isinstance(key, str) or not scope or not key:
        raise _listing_unreadable("an unexpected secret-list entry")
    placeholder = entry.get("placeholder") if table == "custom" else ""
    targets = _host_set(entry.get("targets")) if table == "custom" else frozenset()
    return _Entry(table, scope, key, placeholder if isinstance(placeholder, str) else "", targets)


def _read_listing(*, timeout: float | None = None) -> list[_Entry]:
    """Run ``sbx secret ls --json`` and parse both of its tables.

    The real ``sbx secret ls --json`` returns an OBJECT, not a list:
    ``{secrets: [], custom_secrets: [], shadowed_services: [], env_only_count: 0}``.
    The two entry shapes differ (verified against sbx 0.51.0):

    * ``secrets`` entries are ``{scope, type, name, secret: "(stored)"}``;
    * ``custom_secrets`` entries are ``{scope, targets, env, placeholder,
      secret: "(masked)"}``: keyed by ``env``, removed by ``placeholder``.

    In both, the value is never present. An inspect that *fails* or returns
    unparseable/wrong-shape output raises :class:`SbxError` with
    ``secret_unreadable`` (ADR-0038m §48 drops "inspection-failure-as-empty").
    With a ``timeout``, a call that outlasts it raises ``subprocess.TimeoutExpired``.
    """
    proc = _run(["secret", "ls", "--json"], timeout=timeout)
    if proc.returncode != 0:
        raise SbxError(
            errors.SECRET_UNREADABLE,
            "could not read the secret store",
            "check backend logs and retry",
        )
    try:
        doc = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        raise SbxError(
            errors.SECRET_UNREADABLE,
            "could not parse the secret store listing",
            "the backend returned an unreadable secret list; check backend logs and retry",
        ) from exc
    if not isinstance(doc, dict):
        raise _listing_unreadable("an unexpected secret-list shape")
    out: list[_Entry] = []
    for key, table in (("secrets", "service"), ("custom_secrets", "custom")):
        entries = doc.get(key)
        if entries is None:
            # `custom_secrets` may be absent on older sbx; `secrets` is always
            # present. A missing `secrets` key is a wrong shape, not an empty list.
            if key == "secrets":
                raise _listing_unreadable("an unexpected secret-list shape")
            continue
        if not isinstance(entries, list):
            raise _listing_unreadable("an unexpected secret-list shape")
        out.extend(_entry_from(table, entry) for entry in entries)
    return out


class _Scopes:
    """Map the listing's scope labels onto typed scopes.

    sbx labels both the global scope and a sandbox named ``global`` as
    ``"global"``. Such a label is read as the global scope unless sbx has a
    sandbox named ``global`` (or its sandbox list cannot be read); then it is
    ambiguous, and a caller that needs to know fails closed rather than act on
    the wrong scope's entry. Asking for the sandbox named ``global`` always sees
    a ``"global"`` label as ambiguous.
    """

    def __init__(self, *, timeout: float | None = None) -> None:
        self._global_sandbox: bool | None = None
        self._timeout = timeout

    def _global_sandbox_exists(self) -> bool:
        if self._global_sandbox is None:
            names = list_names(timeout=self._timeout)
            self._global_sandbox = names is None or _GLOBAL_LABEL in names
        return self._global_sandbox

    def match(self, label: str, want: Scope) -> bool | None:
        """True or False, or None when the label cannot be told apart."""
        if label == _GLOBAL_TABLE_LABEL:
            return want.is_global
        if want.is_global:
            if label != _GLOBAL_LABEL:
                return False
            return None if self._global_sandbox_exists() else True
        if label != want.sandbox:
            return False
        return None if label == _GLOBAL_LABEL else True

    def kind(self, label: str) -> str:
        """``scope_kind`` for ``secret ls``: ``global``, ``sandbox`` or ``unknown``."""
        if label == _GLOBAL_TABLE_LABEL:
            return "global"
        if label == _GLOBAL_LABEL:
            return "unknown" if self._global_sandbox_exists() else "global"
        return "sandbox"


def _ambiguous(service: str, outcome: str = "nothing was changed") -> SbxError:
    return SbxError(
        errors.FAILURE,
        f"sbx's secret listing cannot tell a global '{service}' entry from one "
        "scoped to the sandbox named 'global'",
        f"{outcome}; check 'sbx secret ls' and remove the entry with sbx "
        "directly ('sbx secret rm SERVICE [--sandbox global] -f', or "
        "'acq secret rm <placeholder>' for a custom secret)",
    )


def _env_name_ok(name: object) -> bool:
    return (
        isinstance(name, str) and bool(name)
        and name[0] in _ENV_NAME_FIRST and set(name) <= _ENV_NAME_REST
    )


def _provider_binding(service: str) -> tuple[str, str] | None:
    """``(hosts, key_env)`` a provider binds to (Bash ``_acq_service_hosts_env``).

    Read from acq's credential-bindings registry (every pinned host,
    comma-joined), falling back to the shipped usai trust anchor. A malformed
    registry fails closed rather than binding a credential to a guessed host.
    """
    try:
        bindings = provider_creds.list_bindings()
    except (ValueError, OSError) as exc:
        raise SbxError(
            errors.VALIDATION_FAILED,
            "the provider-credential bindings cannot be read",
            f"fix {provider_creds.BINDINGS_ENV} (or unset it) and retry",
        ) from exc
    for binding in bindings:
        if binding.get("provider") != service:
            continue
        hosts, key_env = binding.get("hosts"), binding.get("key_env")
        if (
            not isinstance(hosts, list) or not hosts or not _env_name_ok(key_env)
            or not all(isinstance(h, str) and provider_creds.host_ok(h) for h in hosts)
        ):
            raise SbxError(
                errors.VALIDATION_FAILED,
                f"the provider-credential binding for '{service}' is malformed",
                f"re-pin it with 'acq provider-credential set {service} KEY_ENV --host HOST'",
            )
        return ",".join(hosts), str(key_env)
    if service == provider_creds.USAI_PROVIDER_ID:
        return provider_creds.USAI_PROVIDER_HOST, provider_creds.USAI_PROVIDER_KEY_ENV
    return None


def _route(service: str, host: str, env: str) -> tuple[str, str] | None:
    """``None`` for sbx's native service route, else the custom ``(hosts, env)``.

    An explicit ``--host`` wins over every compiled-in or registered binding,
    built-ins included (a self-hosted GitLab must not be bound to gitlab.com).
    """
    if host or env:
        # A host part starting with "-" would read as a flag in sbx's argv.
        if not host or not _env_name_ok(env) or any(not h or h.startswith("-") for h in host.split(",")):
            raise SbxError(
                errors.VALIDATION_FAILED,
                f"invalid custom endpoint for '{service}': it needs --host HOST (DNS names) and --env ENV",
                "nothing was stored; give both, or neither for a built-in service",
            )
        return host, env
    if service in BUILTIN_SERVICES:
        return None
    binding = _provider_binding(service)
    if binding is None:
        raise SbxError(
            errors.VALIDATION_FAILED,
            f"'{service}' is not a built-in sbx service and has no host/env mapping",
            "nothing was stored; give --host HOST --env ENV, or pin the provider with "
            "'acq provider-credential set'",
        )
    return binding


def _want_env(envs: _Envs, env: str, hosts: str | None) -> None:
    """Add a custom env var, pinned to ``hosts`` (comma-separated) when known."""
    if hosts is None or not _host_set(hosts):
        envs[env] = None
    elif env not in envs or envs[env] is not None:
        allowed = envs.setdefault(env, set())
        if allowed is not None:
            allowed.add(_host_set(hosts))


def _wanted(scope: Scope, service: str, *, removal: bool) -> tuple[str | None, _Envs]:
    """What carries ``service`` in sbx's table: ``(native name or None, custom env vars)``.

    The endpoint sidecar recorded for exactly this scope wins (it is what was
    actually bound); a provider adds its registry env var. Each custom env var
    is pinned to the hosts recorded with it, so another host's secret under the
    same env var is neither reported as injectable nor removed. A native entry
    counts as injectable only for a built-in; removal also clears a stray
    native entry of the same name (sbx would never inject it). A service acq
    does not model matches a raw sbx entry by that name, native or custom.
    """
    envs: _Envs = {}
    meta = secretstore.meta_resolve_exact(service, scope.sandbox)
    if meta is not None and meta.env:
        _want_env(envs, meta.env, meta.host)
    if service in BUILTIN_SERVICES:
        return service, envs
    binding = _provider_binding(service)
    if binding is not None:
        _want_env(envs, binding[1], binding[0])
    elif not envs:
        return service, {service: None}
    return (service if removal else None), envs


def _custom_hit(entry: _Entry, envs: _Envs) -> bool:
    """A custom row carries a wanted env var, and every one of its ``targets``
    is among the hosts recorded for it (a subset, so a row per host and one row
    for all of them both match). Where no hosts were recorded, the env var alone
    matches. A row with no ``targets`` for an env var pinned to hosts fails
    closed: acq cannot tell which host it serves, so it must never be reported
    as injectable or have its placeholder removed as if it were this one."""
    if entry.key not in envs:
        return False
    allowed = envs[entry.key]
    if allowed is None:
        return True
    if not entry.targets:
        raise SbxError(
            errors.SECRET_UNREADABLE,
            f"sbx lists a custom secret for ${entry.key} with no target hosts, so acq cannot tell "
            "whether it is the one bound to the recorded hosts",
            "nothing was changed; check 'sbx secret ls' and, if it is yours, remove it with "
            "'acq secret rm PLACEHOLDER' (the placeholder sbx lists for it)",
        )
    return any(entry.targets <= hosts for hosts in allowed)


def _match(
    listing: list[_Entry], scopes: _Scopes, want: Scope, native: str | None, envs: _Envs
) -> tuple[list[_Entry], list[_Entry]]:
    """``(found, ambiguous)``: the entries for ``want`` that carry
    ``native``/``envs``, and those whose ``global`` label might be ``want``'s."""
    found: list[_Entry] = []
    ambiguous: list[_Entry] = []
    for entry in listing:
        hit = entry.key == native if entry.table == "service" else _custom_hit(entry, envs)
        if not hit:
            continue
        matched = scopes.match(entry.label, want)
        if matched is None:
            ambiguous.append(entry)
        elif matched:
            found.append(entry)
    return found, ambiguous


def _find(scope: Scope, service: str, *, removal: bool) -> tuple[list[_Entry], list[_Entry]]:
    """``(found, ambiguous)`` entries for ``service`` in exactly ``scope``.

    An ambiguous native entry is kept for removal: ``sbx secret rm SERVICE
    [--sandbox S]`` names the scope itself, so sbx removes that scope's entry or
    fails, and never another scope's. An ambiguous custom entry is refused: its
    placeholder might be the other scope's secret. Presence fails closed on
    any ambiguity.
    """
    found, ambiguous = _match(_read_listing(), _Scopes(), scope, *_wanted(scope, service, removal=removal))
    if ambiguous and (not removal or any(entry.table == "custom" for entry in ambiguous)):
        raise _ambiguous(service)
    return found, ambiguous


def _require_set_custom() -> None:
    """``set-custom --value-stdin`` only exists from sbx 0.51.0; refuse older."""
    problem = backends.check_capability_floor(backends.BACKENDS["sbx"], "secret-set-custom")
    if problem is not None:
        raise SbxError(problem.code, problem.message, problem.remediation)


def _rm_hint(scope: Scope, service: str, entry: _Entry) -> str:
    if entry.table == "custom" and entry.placeholder:
        return f"acq secret rm {entry.placeholder}"
    return f"acq secret rm -g {service}" if scope.is_global else f"acq secret rm {scope.sandbox} {service}"


def secret_preflight(scope: Scope | str, service: str, host: str = "", env: str = "") -> None:
    """Refuse a ``secret set`` sbx cannot be fed, before anything is stored.

    Picks the route (:func:`_route`), so a service sbx would store but never
    inject is refused, and the custom route is refused below sbx 0.51.0. The
    real sbx prompts "Overwrite? (y/N)" when the secret already exists (it has
    no stdin ``--force``), which would consume the piped value as the answer, so
    an existing entry fails closed here. For a built-in name taking the custom
    route, a native entry of that name counts too: left in place, sbx would keep
    injecting the token to its own endpoint.
    """
    sc = secretstore.as_scope(scope)
    route = _route(service, host, env)
    if route is not None:
        _require_set_custom()
    native = service if route is None or service in BUILTIN_SERVICES else None
    # Any host: a same-env custom secret in this scope may make sbx refuse or prompt.
    envs: _Envs = {} if route is None else {route[1]: None}
    found, ambiguous = _match(_read_listing(), _Scopes(), sc, native, envs)
    if ambiguous:
        raise _ambiguous(service)
    if found:
        hints = "', '".join(_rm_hint(sc, service, entry) for entry in found)
        raise SbxError(
            errors.FAILURE,
            f"secret '{service}' already exists in scope {sc.describe()}",
            f"remove it first ('{hints}'), then re-set",
        )


def secret_feed(
    scope: Scope | str, service: str, value: str, host: str = "", env: str = "", *, timeout: float | None = None
) -> None:
    """Feed a value already in the acq store to sbx's proxy (stdin only).

    A built-in goes through ``sbx secret set [--sandbox S] SERVICE``; a custom
    endpoint through ``sbx secret set-custom [--sandbox S] --host H… --env E
    --value-stdin``. Either way the value is the child's stdin, never argv.
    :func:`secret_preflight` runs first.
    """
    sc = secretstore.as_scope(scope)
    route = _route(service, host, env)
    if route is None:
        argv = ["secret", "set", *_secret_scope_argv(sc), service]
    else:
        argv = ["secret", "set-custom", *_secret_scope_argv(sc)]
        for one in route[0].split(","):
            if one:
                argv += ["--host", one]
        argv += ["--env", route[1], "--value-stdin"]
    proc = _run(argv, input_text=value, timeout=timeout)
    if proc.returncode != 0:
        raise SbxError(
            errors.FAILURE,
            f"could not feed secret '{service}' to sbx for {sc.describe()}",
            "check backend logs and retry",
        )


def secret_set(
    scope: Scope | str, service: str, value: str, host: str = "", env: str = "", *, timeout: float | None = None
) -> None:
    """Store a secret in sbx's own table only: :func:`secret_preflight` then
    :func:`secret_feed`. ``acq secret set`` writes the acq store first and calls
    those two itself."""
    secret_preflight(scope, service, host, env)
    secret_feed(scope, service, value, host, env, timeout=timeout)


def secret_rm(scope: Scope | str, service: str) -> None:
    """Remove ``(scope, service)`` from sbx's table. Raises on backend failure.

    A native entry goes through ``sbx secret rm SERVICE [--sandbox S] -f``; a
    custom one is found by its env var and removed with ``sbx secret rm
    --placeholder P [--sandbox S] -f``. ``-f`` suppresses sbx's confirm prompt
    and stdin is ``/dev/null``, so no prompt can wait unseen. Nothing to remove
    is a no-op; a custom entry behind an ambiguous ``global`` label fails closed
    (see :func:`_find`). Identical removals run once; one that fails on rows
    only an ambiguous ``global`` label matched says so, since a retry cannot help.
    """
    sc = secretstore.as_scope(scope)
    found, ambiguous = _find(sc, service, removal=True)
    plans: dict[tuple[str, ...], bool] = {}  # argv -> only ambiguous rows need it
    for entry, unsure in [(e, False) for e in found] + [(e, True) for e in ambiguous]:
        if entry.table == "service":
            argv = ("secret", "rm", *_secret_scope_argv(sc), entry.key, "-f")
        elif entry.placeholder:
            argv = ("secret", "rm", "--placeholder", entry.placeholder, *_secret_scope_argv(sc), "-f")
        else:
            raise SbxError(
                errors.FAILURE,
                f"sbx listed no placeholder for the custom secret '{entry.key}' ({sc.describe()})",
                "check 'sbx secret ls' and remove it with sbx directly",
            )
        plans[argv] = plans.get(argv, True) and unsure
    for argv, unsure in plans.items():
        if _run(list(argv)).returncode == 0:
            continue
        if unsure:
            raise _ambiguous(service, "the acq secret store entry was kept")
        raise SbxError(
            errors.FAILURE,
            f"could not remove secret '{service}' for {sc.describe()}",
            "check backend logs and retry",
        )


def secret_ls(scope: Scope | str | None = None) -> list[dict]:
    """``secret-list`` on sbx (``sbx secret ls --json``), never a value.

    Each entry is ``{scope, scope_kind, service, value_state}``: a custom
    secret is listed by its env var, and ``scope_kind`` is ``global``,
    ``sandbox``, or ``unknown`` for a ``global`` label sbx cannot tell apart
    (see :class:`_Scopes`). ``scope`` filters (``None`` lists every scope).

    NOTE: the filter is applied CLIENT-SIDE on one full listing, the same one
    ``secret has``/``rm`` read, rather than passing ``-g``/``--sandbox`` to
    ``sbx secret ls``.
    """
    scopes = _Scopes()
    want = None if scope is None else secretstore.as_scope(scope)
    out: list[dict] = []
    for entry in _read_listing():
        label = _GLOBAL_LABEL if entry.label == _GLOBAL_TABLE_LABEL else entry.label
        kind = scopes.kind(entry.label)
        if want is not None and (label != want.label or kind == ("sandbox" if want.is_global else "global")):
            continue
        out.append({"scope": label, "scope_kind": kind, "service": entry.key, "value_state": "set"})
    return out


def key_present(scope: Scope | str, service: str) -> bool:
    """sbx-only ``key_present`` obligation (ADR-0040m): does sbx hold an
    injectable ``service`` entry in exactly ``scope``?

    Reports presence, never the value. sbx has no ``secret has`` subcommand, so
    presence is a predicate over the ``secret ls --json`` listing, matched by
    name for a built-in and by env var for a custom secret. A backend that
    *cannot answer* (or an ambiguous ``global`` label) raises :class:`SbxError`,
    so "the backend is down" is never conflated with "the secret is absent".
    """
    return any(_find(secretstore.as_scope(scope), service, removal=False))


# The neutral ``secret`` seam (commands/secret.py): presence in sbx's own table,
# the "can inject" predicate, and removal from sbx after the acq store entry.
def secret_present(scope: Scope | str, service: str) -> bool:
    """Anything ``secret rm`` would remove for exactly this scope."""
    return any(_find(secretstore.as_scope(scope), service, removal=True))


def secret_has(scope: Scope | str, service: str) -> bool:
    """Can sbx inject ``service`` here? A sandbox scope falls back to global.

    An ambiguous ``global`` hit while asking for the sandbox named ``global``
    is injectable either way (it is that sandbox's entry or the global one).
    """
    sc = secretstore.as_scope(scope)
    listing, scopes = _read_listing(), _Scopes()
    if not sc.is_global:
        found, ambiguous = _match(listing, scopes, sc, *_wanted(sc, service, removal=False))
        if found or ambiguous:
            return True
    found, ambiguous = _match(listing, scopes, _GLOBAL_SCOPE, *_wanted(_GLOBAL_SCOPE, service, removal=False))
    if ambiguous:
        raise _ambiguous(service)
    return bool(found)


def secret_unbind(scope: Scope | str, service: str) -> None:
    secret_rm(scope, service)


def secret_rm_raw(placeholder: str) -> None:
    """sbx-only raw-placeholder removal (ADR-0038m §48).

    Removes a raw placeholder from sbx's custom-secrets table via
    ``sbx secret rm --placeholder TOKEN -f`` (stdin ``/dev/null``, so sbx's
    confirm prompt can never wait unseen). It is backend-specific and leaves the
    acq store unchanged: it never rewrites host-held records, and the
    placeholder is never a secret value.
    """
    proc = _run(["secret", "rm", "--placeholder", placeholder, "-f"])
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
    destination-pinned (not sandbox-pinned) authority.

    The same existence pre-check as :func:`secret_preflight` applies: a global
    custom secret already bound to ``key_env`` fails closed before the value is
    piped, so the value is never consumed by an overwrite prompt.
    """
    found, ambiguous = _match(_read_listing(), _Scopes(), _GLOBAL_SCOPE, None, {key_env: None})
    if ambiguous:
        raise _ambiguous(key_env)
    if found:
        hint = f"acq secret rm {found[0].placeholder}" if found[0].placeholder else "sbx secret ls, then sbx secret rm --placeholder <placeholder> -f"
        raise SbxError(
            errors.FAILURE,
            f"provider credential '{key_env}' already exists for provider '{provider}'",
            f"remove the existing sbx custom secret first ({hint}), then re-set",
        )
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


def custom_secret_placeholders(scope: Scope | str, env: str) -> list[str]:
    """Placeholders of the custom secrets sbx still lists for ``env`` in exactly
    ``scope``, for any host (an ambiguous ``global`` label included; ``""`` for
    a row without one). Empty when there are none. Raises :class:`SbxError`
    when the listing cannot be read."""
    found, ambiguous = _match(_read_listing(), _Scopes(), secretstore.as_scope(scope), None, {env: None})
    return [entry.placeholder for entry in found + ambiguous]


def github_scope(sandbox: str, value: str) -> None:
    """Store a GitHub token for ``sandbox`` only (ADR-0013); stdin only, never argv.

    The same path as ``acq secret set SANDBOX github``: :func:`secret_preflight`
    (an existing entry is refused before anything is stored), then the acq
    secret store (the source of truth), then :func:`secret_feed` to sbx's proxy
    for that sandbox (never global). Raises :class:`SbxError` or
    :class:`secretstore.SecretStoreError`.
    """
    scope = secretstore.sandbox_scope(sandbox)
    secret_preflight(scope, "github")
    secretstore.set_secret("github", sandbox, value)
    secret_feed(scope, "github", value)


# --- usai-rotate-api-key (ADR-0012, ADR-0008) ---------------------------------
#
# Rotation is a store write plus a re-feed (plan default: no provider probe; the
# attach-time key check is the verdict). ``commands/creds.py`` runs the
# preflight, writes the new key to the acq store, then calls the re-feed. sbx
# keeps the value in its own proxy table, so the re-feed sets it there again,
# keeping each entry's placeholder: a running sandbox was injected with that
# placeholder at create, and a new placeholder would leave it unresolvable
# (ADR-0008). The value is the child's stdin only.


def _rotate_route() -> tuple[list[str], str]:
    """``(hosts, env)`` the global USAi key is bound to: the endpoint recorded
    with ``acq secret set -g usai --host H --env E`` when there is one, else the
    provider binding (the shipped trust anchor by default)."""
    service = provider_creds.USAI_PROVIDER_ID
    meta = secretstore.meta_resolve_exact(service, None)
    if meta is not None and meta.host and meta.env:
        return meta.host.split(","), meta.env
    hosts, env = _provider_binding(service) or (provider_creds.USAI_PROVIDER_HOST, provider_creds.USAI_PROVIDER_KEY_ENV)
    return hosts.split(","), env


def _rotate_timed_out(what: str, budget: float) -> SbxError:
    """A rotation's sbx call that outlasted its budget. Names the call, never a value."""
    return SbxError(
        errors.TIMEOUT,
        f"'{what}' timed out after {budget:g}s",
        f"check that sbx responds (it may be waiting on 'sbx login'); set {timeouts.ROTATE_TIMEOUT_ENV} "
        "to a larger number of seconds if it is only slow",
    )


def _rotate_listing(budget: float) -> list[_Entry]:
    """``sbx secret ls --json`` for a rotation, bounded by ``budget`` seconds."""
    try:
        return _read_listing(timeout=budget)
    except subprocess.TimeoutExpired:
        raise _rotate_timed_out("sbx secret ls", budget) from None


def _rotate_envs(hosts: list[str], env: str) -> _Envs:
    """The custom secrets that carry the USAi key: ``env`` bound to ``hosts``."""
    return {env: {_host_set(hosts)}}


def _rotate_plan(hosts: list[str], env: str, listing: list[_Entry], budget: float) -> tuple[list[_Entry], list[_Entry]]:
    """``(global rows, sandbox rows)``: the custom secrets in ``listing`` that
    carry the USAi key for ``env`` and ``hosts``. Refuses, before anything
    changes, a listing acq cannot act on safely: an ambiguous ``global`` label,
    a row without a usable placeholder, or more than one global row (acq cannot
    tell which one the sandboxes were injected with)."""
    envs = _rotate_envs(hosts, env)
    scopes = _Scopes(timeout=budget)
    rows: tuple[list[_Entry], list[_Entry]] = ([], [])
    for entry in listing:
        if entry.table != "custom" or not _custom_hit(entry, envs):
            continue
        try:
            is_global = scopes.match(entry.label, _GLOBAL_SCOPE)
        except subprocess.TimeoutExpired:
            raise _rotate_timed_out("sbx ls", budget) from None
        if is_global is None:
            raise _ambiguous(provider_creds.USAI_PROVIDER_ID)
        if not entry.placeholder or entry.placeholder.startswith("-"):
            raise _listing_unreadable(f"a custom secret for ${env} without a usable placeholder")
        rows[0 if is_global else 1].append(entry)
    if len(rows[0]) > 1:
        raise SbxError(
            errors.FAILURE,
            f"sbx lists {len(rows[0])} global custom secrets for ${env}, so acq cannot tell which "
            "one your sandboxes use",
            "keep the one your sandboxes were injected with and remove the others with 'acq secret rm "
            f"PLACEHOLDER' (placeholders: {', '.join(e.placeholder for e in rows[0])}); a sandbox left with a "
            "removed placeholder is recovered by the ADR-0008 rebind or a recreate. Then re-run; nothing was changed",
        )
    return rows


_UNLISTED_REMEDIATION = (
    "once 'sbx secret ls --json' works again, re-run 'acq usai-rotate-api-key' with the same key "
    "to re-feed the sbx sandboxes"
)


def rotate_preflight(*, primary: bool = True) -> dict | None:
    """Refuse a rotation sbx could not take, before anything is stored: a
    listing :func:`_rotate_plan` refuses, or sbx below 0.51.0 (no
    ``--value-stdin``) when it is the active backend or holds the key.

    When sbx is not the active backend and its secret list cannot be read
    (``sbx secret ls`` fails, times out, or returns something unreadable), the
    rotation still goes ahead on the active backend, as Bash rotates msb and
    fails only the sbx propagation: the result returned here reports sbx as not
    re-fed, and the command exits 1. Otherwise None. As the active backend, an
    unreadable list refuses the rotation.
    """
    budget = timeouts.rotate_timeout_s()
    hosts, env = _rotate_route()
    try:
        listing = _rotate_listing(budget)
    except SbxError as exc:
        if primary:
            raise
        return {"backend": "sbx", "refed": [], "kept_own": [],
                "not_refed": [f"any sandbox holding the key (acq could not read sbx's secret list: {exc.message})"],
                "remediation": _UNLISTED_REMEDIATION}
    globals_, sandbox_rows = _rotate_plan(hosts, env, listing, budget)
    if primary or globals_ or sandbox_rows:
        _require_set_custom()
    return None


def rotate_holds_key() -> bool | None:
    """Whether sbx lists a custom secret for the USAi key's env var (None when
    the listing cannot be read in time). Used for an sbx below acq's floor,
    which acq otherwise does not drive."""
    env = _rotate_route()[1]
    try:
        return any(e.table == "custom" and _custom_hit(e, {env: None})
                   for e in _rotate_listing(timeouts.rotate_timeout_s()))
    except SbxError:
        return None


def rotate_stale_hint() -> str | None:
    """None: :func:`rotate_holds_key` reads sbx's own listing, not an acq
    record that a sandbox removed outside acq could leave behind."""
    return None


def _set_custom(sandbox: str | None, hosts: list[str], env: str, placeholder: str, value: str, budget: float) -> bool:
    """``sbx secret set-custom`` for one entry, keeping its placeholder; stdin only.
    Raises ``subprocess.TimeoutExpired`` past ``budget`` seconds."""
    argv = ["secret", "set-custom"] + ([] if sandbox is None else ["--sandbox", sandbox])
    for host in hosts:
        argv += ["--host", host]
    argv += ["--env", env] + (["--placeholder", placeholder] if placeholder else []) + ["--value-stdin"]
    return _run(argv, input_text=value, timeout=budget).returncode == 0


def _kept_placeholder(sandbox: str | None, envs: _Envs, placeholder: str, budget: float) -> bool:
    """After a ``set-custom``: sbx lists exactly one custom secret carrying the
    USAi key (the same env var and hosts :func:`_rotate_plan` matched) in that
    scope, and it has ``placeholder`` (any one, for a new global entry). A new
    or duplicated placeholder would leave running sandboxes resolving a
    placeholder sbx no longer maps to the new key (ADR-0008). A secret for the
    same env var on other hosts is a different secret and is not counted."""
    scope = _GLOBAL_SCOPE if sandbox is None else secretstore.sandbox_scope(sandbox)
    scopes = _Scopes(timeout=budget)
    listing = _rotate_listing(budget)
    try:
        rows = [e for e in listing if e.table == "custom" and _custom_hit(e, envs) and scopes.match(e.label, scope)]
    except subprocess.TimeoutExpired:
        raise _rotate_timed_out("sbx ls", budget) from None
    return len(rows) == 1 and (not placeholder or rows[0].placeholder == placeholder)


class _Rotation(NamedTuple):
    """What every entry's re-set shares (never the value, so a repr cannot show it)."""

    envs: _Envs  # the custom secrets that carry the USAi key
    env: str
    budget: float  # seconds allowed for each sbx call


def _rotate_entry(rot: _Rotation, sandbox: str | None, hosts: list[str], placeholder: str, value: str) -> str | None:
    """Re-set one entry and confirm its placeholder; None, or why it failed."""
    try:
        if not _set_custom(sandbox, hosts, rot.env, placeholder, value, rot.budget):
            return "sbx secret set-custom failed"
        if not _kept_placeholder(sandbox, rot.envs, placeholder, rot.budget):
            return "sbx did not keep a single entry with its placeholder"
    except subprocess.TimeoutExpired:
        return _rotate_timed_out("sbx secret set-custom", rot.budget).message
    except SbxError as exc:
        return exc.message
    return None


_GLOBAL_ENTRY = "the global USAi secret (used by every sbx sandbox without its own entry)"


def rotate_refeed(value: str, *, primary: bool = True) -> dict:
    """Set the new USAi key in every sbx entry that carries it.

    The global entry is updated in place (it serves every sandbox without an
    entry of its own); when there is none, the primary backend creates it, as
    ``secret set -g usai`` would, and propagation from the other backend leaves
    sbx alone. A sandbox-scoped entry is updated too, unless that sandbox has
    its own ``usai`` value in the acq store (``kept_own``): an entry acq did not
    store is a copy of the global key, such as the ADR-0008 rebind. Each entry
    is re-read afterwards to confirm sbx kept one entry with its placeholder.
    Every sbx call is bounded (:func:`timeouts.rotate_timeout_s`); one that
    times out counts as that entry's failure.
    Returns ``{backend, refed, kept_own, not_refed}``, plus ``global``
    (``updated`` or ``created``) when the global entry took the new key; one
    entry's failure is listed in ``not_refed`` and the others are still re-set.
    """
    budget = timeouts.rotate_timeout_s()
    hosts, env = _rotate_route()
    globals_, sandbox_rows = _rotate_plan(hosts, env, _rotate_listing(budget), budget)
    rot = _Rotation(_rotate_envs(hosts, env), env, budget)
    out: dict = {"backend": "sbx", "refed": [], "kept_own": [], "not_refed": []}
    if globals_ or sandbox_rows or primary:
        _require_set_custom()
    if globals_ or primary:
        row = globals_[0] if globals_ else None
        problem = _rotate_entry(rot, None, sorted(row.targets) if row else hosts, row.placeholder if row else "", value)
        if problem is None:
            out["global"] = "updated" if row else "created"
        else:
            out["not_refed"].append(f"{_GLOBAL_ENTRY} ({problem})")
    service = provider_creds.USAI_PROVIDER_ID
    for row in sandbox_rows:
        try:
            own = secretstore.name_ok(row.label) and secretstore.exists(service, row.label)
        except secretstore.SecretStoreError as exc:
            out["not_refed"].append(f"sandbox {row.label} ({exc.message})")
            continue
        if own:
            out["kept_own"].append(row.label)
            continue
        problem = _rotate_entry(rot, row.label, sorted(row.targets), row.placeholder, value)
        if problem is None:
            out["refed"].append(row.label)
        else:
            out["not_refed"].append(f"sandbox {row.label} ({problem})")
    return out


# ---------------------------------------------------------------------------
# Kit-source revocation (sbx-only, ADR-0040m ``kit_source_revoked``).
# ---------------------------------------------------------------------------

def _read_allowed_sources() -> list | None:
    """``sbx settings get kit.allowedSources`` as a list, or ``None`` if unreadable."""
    proc = _run(["settings", "get", "kit.allowedSources"])
    if proc.returncode != 0:
        return None
    try:
        sources = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        return None
    return sources if isinstance(sources, list) else None


def _grants(sources: list, prefix: str) -> bool:
    """True when ``sources`` lists ``prefix`` in any letter case (GitHub ignores case)."""
    key = prefix.casefold()
    return any(isinstance(s, str) and s.casefold() == key for s in sources)


def _revoke_failed(repo: str, prefix: str, reason: str, desired: str | None = None) -> SbxError:
    """The loud half of the fail-closed contract: what is still permitted, and how to fix it.

    Mirrors Bash ``_acq_sbx_kit_source_revoke_failed``. The source stays
    registered, because the sbx backend could still fetch kits from that owner.
    """
    if desired is not None:
        fix = f"run: sbx settings set kit.allowedSources '{desired}'"
    else:
        fix = (
            "review 'sbx settings get kit.allowedSources', remove "
            f"'{prefix}', then run 'sbx settings set kit.allowedSources <json-array>'"
        )
    return SbxError(
        errors.FAILURE,
        f"{reason}, so sbx kit.allowedSources still permits '{prefix}'; "
        f"kit source '{repo}' was not removed",
        f"{fix}; then re-run: acq kit-source rm {repo}",
    )


def kit_source_revoked(repo: str) -> str | None:
    """Revoke a removed kit source from sbx's ``kit.allowedSources``.

    sbx has no ``kit-source-revoke`` subcommand: the allowlist lives under
    ``sbx settings`` as a JSON array at ``kit.allowedSources``, and it is
    owner-granular (``host/owner/``). acq only ever *unions* onto it, so a removed
    source stays fetchable until its owner prefix is dropped here.

    Mirrors Bash ``acq_backend_kit_source_revoked``: the prefix is dropped only
    when nothing that remains trusted after removing ``repo`` needs it (the
    control plane, another registered source, or an ``ACQ_EXTRA_KIT_SOURCES``
    grant), and the setting is re-read afterwards to confirm. Prefixes compare
    casefolded, and every case variant of the prefix is dropped with it.

    Returns ``None`` when a remaining source still needs the prefix (nothing is
    revoked and sbx is not called). Otherwise returns the prefix, which sbx no
    longer grants. Raises :class:`SbxError` on any failure to read, write or
    verify the setting; it never returns quietly in that case.
    """
    prefix = kits.owner_prefix(repo)
    remaining = {p.casefold() for p in kits.kit_source_prefixes(exclude=repo)}
    if prefix.casefold() in remaining:
        return None
    sources = _read_allowed_sources()
    if sources is None:
        raise _revoke_failed(repo, prefix, "could not read kit.allowedSources as a JSON array")
    if not _grants(sources, prefix):
        return prefix
    desired = json.dumps([s for s in sources if not _grants([s], prefix)])
    proc = _run(["settings", "set", "kit.allowedSources", desired])
    if proc.returncode != 0:
        raise _revoke_failed(repo, prefix, "could not write kit.allowedSources", desired)
    verify = _read_allowed_sources()
    if verify is None or _grants(verify, prefix):
        raise _revoke_failed(repo, prefix, "kit.allowedSources still lists it after the update", desired)
    return prefix
