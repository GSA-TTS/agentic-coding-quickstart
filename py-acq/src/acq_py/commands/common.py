"""Shared command-layer helpers: the adapter seam, the failure envelopes, backend
resolution, workspace/guest-path handling, and the secret-scope parsers.

Every ``commands/*`` module routes through here, so the usage/operational failure
vocabulary and the exit-code contract (0 success, 2 usage, 1 operational) live in
exactly one place (ADR-0038m §2). ``cli`` re-exports these names, so the dispatch
layer and the Tier-2 tests keep addressing them as ``cli.<name>``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from .. import (
    backends,
    config,
    envelope,
    errors,
    hostexec,
    kits,
    msb,
    sbx,
    secretstore,
    security,
    state,
)

# Both adapters and the acq secret store raise an error carrying the same
# (code, message, remediation) contract; catch this tuple uniformly at the seam.
_ADAPTER_ERRORS = (msb.MsbError, sbx.SbxError, secretstore.SecretStoreError)

# Agent tokens accepted by acq dispatch (mirrors acq.backends/agents.sh). Read by the
# ``run`` create-vs-reattach decision in ``commands.lifecycle``.
KNOWN_AGENTS = frozenset(
    "claude codex copilot cursor docker-agent droid gemini kiro opencode shell".split()
)

# Guest-side workspace a session starts in when no host record supplies one
# (mirrors the legacy ``_acq_msb_workspace_for`` default, ADR-0011).
DEFAULT_GUEST_WORKSPACE = "/home/agent"

# The default base image (ADR-0030): a generic, agent-less devenv-enabled base for
# EVERY agent. Agent harness installation is deferred to kits (starting with
# opencode), so the base image no longer differs per agent; an explicit
# ``--image``/``ACQ_IMAGE``/``ACQ_MSB_IMAGE`` override is the only way to change it
# (ADR-0022 precedence). The devenv base is agent-less: the agent binary is
# installed by the pinned opencode kit at create time (see ``commands.lifecycle._apply_agent_kit``).
#
# TODO(quarterly): the digest below is a real, reproducible pin — re-reviewed on
# the quarterly cadence (ADR-0030). It is sourced from the devenv image VERSION /
# Dockerfile pins in ``integrations/isolation/images/devenv/`` (devenv-shell:2.1.0)
# and the upstream ``acq.backends/agents.sh`` default.
OPENCODE_DEVENV_IMAGE = (
    "ghcr.io/gsa-tts/agentic-coding-patterns/devenv-shell@"
    "sha256:0b5f4cc95c8fa7dd7f3ffd02b56e63d0caf9b151421ff6ea3cb34b2139e3966c"
)


def _adapter(backend: str):
    """Resolve the adapter module for a backend name (``"sbx"`` else ``msb``)."""
    return sbx if backend == "sbx" else msb


def _supports(backend: str, capability: str) -> bool:
    """Consult the adapter's declared capability record (ADR-0040m).

    A capability the adapter declares ``unsupported`` fails closed; an adapter
    without a ``capability_record`` (the pre-record msb adapter) supports whatever
    it implements. The orchestrator reads the record once per decision, so the
    fail-closed ``unsupported_capability`` behavior is derived from the record
    rather than hardcoded per verb.
    """
    record_fn = getattr(_adapter(backend), "capability_record", None)
    if record_fn is None:
        return True
    return record_fn().get("capabilities", {}).get(capability) != "unsupported"


def _default_image_for_agent(agent: str) -> str:
    """The default base image: the pinned devenv shell image for every agent.

    The ``agent`` argument is retained for signature compatibility with the
    per-agent mapping it replaced, but it no longer selects a different image.
    """
    return OPENCODE_DEVENV_IMAGE


def _usage_failure(command: str | None, message: str, emit_json: bool) -> int:
    if emit_json:
        doc = envelope.error(
            command or "acq",
            errors.USAGE,
            message,
            remediation="run 'acq --help' for usage",
        )
        print(json.dumps(doc))
    else:
        print(f"acq: {message}", file=sys.stderr)
        print("run 'acq --help' for usage", file=sys.stderr)
    return errors.EXIT_USAGE


def _operational_failure(
    command: str,
    code: str,
    message: str,
    remediation: str | None,
    emit_json: bool,
    exit_code: int = errors.EXIT_FAILURE,
) -> int:
    """Emit an operational failure (exit 1) with a stable error code.

    Distinct from a usage error (exit 2): the command was well-formed but could
    not be carried out. The JSON form puts the failure envelope on stdout; the
    human form writes diagnostics to stderr. ``exit_code`` defaults to 1 and is
    overridden only where the contract requires preserving a backend's own status
    (e.g. ``cp`` forwarding ``msb copy``'s exit, ADR-0038m §1).
    """
    if emit_json:
        doc = envelope.error(command, code, message, remediation=remediation)
        print(json.dumps(doc))
    else:
        print(f"acq: {message}", file=sys.stderr)
        if remediation:
            print(remediation, file=sys.stderr)
    return exit_code


def _resolve_active_backend(explicit: str | None) -> str | None:
    """Resolve the active backend for read-only reporting.

    Precedence: the ``--backend`` flag, then the ``ACQ_BACKEND`` environment
    variable, then the ``backend:`` key ``backend set`` persists in
    ``config.yaml``, then the auto-detect default (Bash ``acq_resolve_backend``).
    An invalid flag value is a usage error (handled by the caller); an invalid
    environment value is dropped and the next source is consulted.

    An invalid persisted value is NOT skipped: it resolves to ``None`` so nothing
    auto-detects past a broken pin. Mutating callers refuse first through
    :func:`_invalid_persisted_backend_failure`, as Bash does when its adapter
    lookup fails; read-only reporting (``backend list``, ``doctor``) warns and
    goes on. This replaces the earlier lenient reading of ADR-0038m's "drop
    invalid persisted backends", which silently ignored the value: ADR-0038m drops
    Bash's *acceptance* of an invalid backend (``backend set`` now refuses one),
    and a value that still reaches config.yaml by hand is surfaced, not hidden.

    Auto-detect default arms:

        * exactly one backend installed -> that backend;
        * sbx and msb both installed -> msb;
        * none installed -> ``None``;
        * (future) two or more installed and none is msb -> prompt the user and
          persist the answer via ``backend set``.

    The last arm cannot arise in v1 (only sbx and msb exist), so it is
    documented but not implemented here.
    """
    if explicit is not None:
        return explicit
    env_backend = os.environ.get("ACQ_BACKEND")
    if env_backend in backends.BACKENDS:
        return env_backend
    persisted = config.read_field("backend")
    if persisted is not None:
        return persisted if persisted in backends.BACKENDS else None
    installed = [s.name for s in backends.detect_all() if s.installed]
    if len(installed) == 1:
        return installed[0]
    if len(installed) > 1:
        return "msb"
    return None


def _invalid_persisted_backend(explicit: str | None) -> str | None:
    """The persisted ``backend:`` value when it is not a known backend and would
    be consulted (no ``--backend`` flag and no valid ``ACQ_BACKEND``), else ``None``.
    """
    if explicit is not None or os.environ.get("ACQ_BACKEND") in backends.BACKENDS:
        return None
    persisted = config.read_field("backend")
    if persisted is None or persisted in backends.BACKENDS:
        return None
    return persisted


def _invalid_persisted_backend_message(value: str) -> str:
    return f"config.yaml ({config.config_path()}) sets an unknown backend: {value!r} (expected sbx or msb)"


_INVALID_PERSISTED_REMEDIATION = (
    "run 'acq backend set msb' or 'acq backend set sbx' (or 'acq backend unset' to auto-detect)"
)


def _invalid_persisted_backend_failure(explicit: str | None, command: str, emit_json: bool) -> int | None:
    """Refuse a verb that needs a backend when config.yaml persists an unknown one.

    Returns the emitted exit code, or ``None`` when the persisted value is fine
    or not consulted.
    """
    value = _invalid_persisted_backend(explicit)
    if value is None:
        return None
    return _operational_failure(
        command,
        errors.BACKEND_NOT_FOUND,
        _invalid_persisted_backend_message(value),
        _INVALID_PERSISTED_REMEDIATION,
        emit_json,
    )


def _resolve_backend_for_mutation(
    explicit: str | None,
    emit_json: bool,
    command: str,
    *,
    domain: str = "lifecycle",
    capability: str | None = None,
) -> tuple[str | None, int | None]:
    """Resolve the backend for a mutating verb and enforce the version floor.

    Returns ``(backend_name, exit_code)``; ``exit_code`` is non-``None`` when a
    failure was already emitted (unknown backend -> usage, no backend /
    unsupported version -> operational, all fail-closed before mutation).
    ``domain`` names the verb family for the no-backend remediation prose.
    ``capability`` (when set) additionally enforces that capability's per-capability
    version floor (``backends.CAPABILITY_FLOORS``) above the global floor.
    """
    if explicit is not None and explicit not in backends.BACKENDS:
        return None, _usage_failure(
            command,
            f"unknown backend: {explicit!r} (expected sbx or msb)",
            emit_json,
        )
    invalid = _invalid_persisted_backend_failure(explicit, command, emit_json)
    if invalid is not None:
        return None, invalid
    name = _resolve_active_backend(explicit)
    if name is None:
        return None, _operational_failure(
            command,
            errors.BACKEND_NOT_FOUND,
            "no sandbox backend detected",
            f"install msb {backends.MSB_MIN_VERSION[0]}.{backends.MSB_MIN_VERSION[1]}.{backends.MSB_MIN_VERSION[2]} or newer and retry",
            emit_json,
        )
    problem = backends.check_version(backends.BACKENDS[name])
    if problem is not None:
        return None, _operational_failure(command, problem.code, problem.message, problem.remediation, emit_json)
    if capability is not None:
        cap_problem = backends.check_capability_floor(backends.BACKENDS[name], capability)
        if cap_problem is not None:
            return None, _operational_failure(
                command, cap_problem.code, cap_problem.message, cap_problem.remediation, emit_json
            )
    return name, None


def _resolve_backend_for_lifecycle(
    explicit: str | None, emit_json: bool, command: str
) -> tuple[str | None, int | None]:
    """Backend resolution for the lifecycle verbs (kept as a named alias)."""
    return _resolve_backend_for_mutation(explicit, emit_json, command, domain="lifecycle")


class SecretInputError(secretstore.SecretStoreError):
    """A secret could not be read safely from the terminal. Carries no value;
    being a store error, it leaves through the command boundary as a stable
    ``validation_failed`` envelope from every verb that reads a secret."""

    def __init__(self, message: str):
        super().__init__(errors.VALIDATION_FAILED, message, "pipe the secret on stdin instead")


def _read_secret_tty(prompt: str) -> str:
    """Read one line from the terminal with echo off; the prompt goes to stderr.

    ``getpass`` falls back to an echoing read (with a warning) when it cannot
    turn echo off; that warning is raised as an error here, before anything is
    read, so a typed secret is never shown.
    """
    import getpass
    import warnings

    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        try:
            value = getpass.getpass(prompt, stream=sys.stderr)
        except getpass.GetPassWarning:
            raise SecretInputError("cannot turn off terminal echo to read the secret") from None
        except UnicodeError:
            raise SecretInputError(_NOT_UTF8) from None
        except EOFError:
            return ""
    if _has_surrogates(value):  # a terminal decoded with surrogateescape
        raise SecretInputError(_NOT_UTF8)
    return value


# Fixed text: a decode error's own message quotes the offending byte and its
# offset, which are part of the secret, so it is never passed on.
_NOT_UTF8 = "the secret value is not valid UTF-8"


def _has_surrogates(text: str) -> bool:
    return any("\ud800" <= ch <= "\udfff" for ch in text)


def _is_mintty_pipe_name(name: str) -> bool:
    """True for the named pipe an MSYS2/Cygwin pty (mintty, Git Bash) hands a
    native Windows program as its stdin, e.g. ``\\msys-1888ae32e00d56aa-pty0-from-master``."""
    return ("msys-" in name or "cygwin-" in name) and "-pty" in name and "-from-master" in name


def _stdin_is_mintty() -> bool:
    """True when stdin is a Git Bash/mintty terminal seen through its pty pipe.

    Native Windows Python sees that terminal as a pipe, not a console, so it
    cannot turn echo off; the pipe's name is the reliable marker. Any failure
    to inspect the handle answers False.
    """
    if sys.platform != "win32":
        return False
    try:
        import ctypes
        import msvcrt

        handle = msvcrt.get_osfhandle(sys.stdin.fileno())
        kernel32 = ctypes.windll.kernel32
        if kernel32.GetFileType(handle) != 3:  # FILE_TYPE_PIPE
            return False
        size = 4 + 2 * 1024
        buf = ctypes.create_string_buffer(size)
        if not kernel32.GetFileInformationByHandleEx(handle, 2, buf, size):  # FileNameInfo
            return False
        length = int.from_bytes(buf.raw[:4], "little")
        name = buf.raw[4 : 4 + length].decode("utf-16-le", "replace")
    except Exception:  # noqa: BLE001 - a detection miss must never break the read
        return False
    return _is_mintty_pipe_name(name)


_MINTTY_HINT = (
    "acq: warning: this terminal (Git Bash/mintty) cannot hide what you type, so the secret "
    "will be visible. Press Ctrl-C and pipe it instead (printf '%s' \"$TOKEN\" | acq ...), "
    "or run acq from a native console (Windows Terminal, PowerShell, cmd)."
)


def _read_piped_secret(one_line: bool = False) -> str:
    """Read stdin (all of it, or one typed line) as strict UTF-8, from the byte
    stream when there is one."""
    buffer = getattr(sys.stdin, "buffer", None)
    if buffer is None:  # an in-memory text stream (tests): already decoded
        data = sys.stdin.readline() if one_line else sys.stdin.read()
    else:
        try:
            raw = buffer.readline() if one_line else buffer.read()
            data = raw.decode("utf-8")
        except UnicodeError:
            raise SecretInputError(_NOT_UTF8) from None
    if _has_surrogates(data):
        raise SecretInputError(_NOT_UTF8)
    return data


def _read_secret_value(prompt: str = "Enter secret value: ") -> str:
    """Read the secret value: silently from a terminal, else from stdin.

    On a terminal the user is prompted (on stderr) and the line is read with
    echo off. Piped stdin keeps trailing-newline fidelity: exactly the single
    terminal newline that a terminal/``echo`` appends is stripped (plus an
    immediately preceding ``\\r`` for a CRLF terminator). Any further trailing
    newlines are value content and are preserved: a value that legitimately ends
    in newlines is not silently truncated. A lone trailing ``\\r`` with no
    preceding ``\\n`` is likewise preserved.

    Bytes that are not valid UTF-8 fail closed with a fixed
    ``validation_failed`` message that quotes nothing from the input. Under
    Git Bash/mintty, where typed input cannot be hidden, a warning and the
    prompt go to stderr first.

    The value is returned to the caller and must never be printed, logged, or
    placed on argv. An empty result signals "no value was piped".
    """
    if _stdin_is_terminal():
        return _read_secret_tty(prompt)
    mintty = _stdin_is_mintty()
    if mintty:
        print(_MINTTY_HINT, file=sys.stderr)
        print(prompt, end="", file=sys.stderr, flush=True)
    data = _read_piped_secret(one_line=mintty)
    if data.endswith("\n"):
        data = data[:-1]  # strip exactly one terminal newline
        if data.endswith("\r"):  # optional preceding CR (CRLF terminator)
            data = data[:-1]
    return data


def _stdin_is_terminal() -> bool:
    """True when stdin is an interactive terminal (a real console on Windows,
    where ``< NUL`` would otherwise pass for one)."""
    return hostexec.stream_is_terminal(sys.stdin)


def _validate_workspace(command: str, path: str | None, emit_json: bool) -> tuple[str | None, int | None]:
    """Resolve the workspace to an absolute directory, or emit a validation failure."""
    if not path:
        return None, _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            "missing workspace path",
            f"usage: acq {command} AGENT PATH",
            emit_json,
        )
    resolved = _logical_abspath(path)
    if not os.path.isdir(resolved):
        return None, _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            f"workspace path does not exist or is not a directory: {path}",
            "create the workspace first, then re-run",
            emit_json,
        )
    return resolved, None


def _logical_abspath(path: str) -> str:
    """Absolute form of a typed workspace path, keeping the shell's logical cwd.

    ``os.path.abspath`` joins onto ``os.getcwd()``, which has symlinks resolved.
    For ``.`` (the working directory itself) the shell's logical ``$PWD`` is used
    instead, when it names the same directory, so a symlinked project directory
    gets the sandbox name Bash's ``derive_name`` gives it (``basename "$PWD"``)
    and the same name as when its path is typed out. Any other path is made
    absolute as before: a ``..`` step resolved against the logical path could
    name a different directory than the one the OS opens.
    """
    if os.path.normpath(path) == os.curdir:
        pwd = os.environ.get("PWD") or ""
        if pwd and os.path.isabs(pwd):
            # Check the same normalised value that is returned: a raw ``$PWD``
            # with ``..`` through a symlink can resolve to the cwd while its
            # lexical form names a different directory.
            logical = os.path.normpath(pwd)
            try:
                if os.path.samefile(logical, os.curdir):
                    return logical
            except OSError:
                pass
    return os.path.abspath(path)


# Module-local seam for path canonicalization. ``_mount_workspace`` reads this
# instead of ``os.path.realpath`` directly so a test can substitute a Windows
# ``realpath`` simulation without mutating the process-wide ``os.path.realpath``
# (the same pattern as ``msb.WINDOWS``, ADR-0029).
REALPATH = os.path.realpath


def _mount_workspace(backend: str, workspace: str) -> str:
    """The host path to mount and record for ``workspace``.

    msb cannot mount a symlinked host path (notably the macOS ``$TMPDIR``,
    ``/var/folders`` -> ``/private/var/folders``), so it gets the real path; the
    guest ``-w`` start directory is derived from the same value. The same
    ``realpath`` is what keeps a Windows ``subst`` or mapped-drive workspace
    working after the session that created it: drive letters are per logon
    session, so without ``realpath`` the record would hold ``Z:\\proj`` and the
    sandbox could not restart from a session without ``Z:`` (msb fails the mount
    with os error 2), while the resolved plain-drive or UNC path mounts from any
    session. Live runs on msb 0.7.7 mounted drive letters within one session and
    accepted a UNC ``--volume`` source; ``_guest_path`` translates either form.
    On Windows ``realpath`` also expands 8.3 short names and normalises case (``C:\\PROGRA~1\\x`` ->
    ``C:\\Program Files\\x``), so the *recorded* workspace string can differ from
    what the user typed; that is benign — the sandbox name derives from the typed
    path (``_derive_name`` runs before this), and exec/attach/shell/reattach all
    read the same recorded realpath back, so host and guest stay self-consistent
    and only the user-visible string changes. sbx keeps the path as typed. Call
    this AFTER deriving the sandbox name, which must come from the path the user
    typed.
    """
    return REALPATH(workspace) if backend == "msb" else workspace


def _launch_token(backend: str, name: str, agent: str | None) -> str | None:
    """Resolve the launch command: a recorded kit entrypoint wins over the agent name.

    A future kit may declare an entrypoint that differs from the agent token it
    installs (ADR-0030 "declares its entrypoint"); the recorded entrypoint is the
    command to run, not the raw agent name.
    """
    applied = kits.kit_applied_read(backend, name)
    if applied and applied.get("entrypoint"):
        return applied["entrypoint"]
    return agent


def _trusted_gate(record: dict | None, backend: str, command: str, name: str, emit_json: bool) -> int | None:
    """Refuse a trusted operation on a sandbox missing its read-only mount.

    Returns an emitted exit code when the record requires the mount and the probe
    reports it missing (ADR-0035/0041m), else ``None`` to proceed.
    """
    try:
        security.assert_trusted(record, backend, name)
    except security.SecurityException as exc:
        return _operational_failure(command, exc.code, exc.message, exc.remediation, emit_json)
    return None


def _sandbox_ref(token: str) -> tuple[str, str] | None:
    """Return ``(name, guest_path)`` when ``token`` is a ``NAME:/guest/path`` ref.

    Host and guest path types are distinct (ADR-0038m §4): only a bare ``NAME:``
    prefix followed by a POSIX-absolute path is a guest ref. A Windows drive
    (``C:/…``) is a single-letter host path, never a guest ref, so a host mount
    source is never misread as a guest path implicitly.
    """
    if ":" not in token:
        return None
    name, _sep, rest = token.partition(":")
    if not rest.startswith("/"):
        return None
    if not name or any(ch in name for ch in "/\\:"):
        return None
    if os.name == "nt" and len(name) == 1 and name.isalpha():
        return None
    return (name, rest)


def _workspace_from_record(backend: str, name: str) -> str:
    """Resolve the guest workspace for a session (``-w``), host-authoritative.

    Returns the recorded workspace, or :data:`DEFAULT_GUEST_WORKSPACE` when the
    record is absent or legacy v0 (a missing record is a starting-directory
    default, not an authority decision). A newer/unknown-schema or unparseable
    record raises :class:`state.StateSchemaError` so the caller fails closed
    rather than running in a guessed cwd (ADR-0041m).
    """
    record = state.record_read(backend, name)  # raises StateSchemaError
    if record and record.get("workspace"):
        return record["workspace"]
    return DEFAULT_GUEST_WORKSPACE


def _slugify(token: str) -> str:
    """Normalize a token into a sandbox-name slug (mirrors acq.backends slugify).

    Only ASCII ``a-z0-9`` survive; runs of anything else collapse to one hyphen,
    matching the legacy ``tr + sed`` transform.
    """
    out: list[str] = []
    prev_dash = False
    for ch in token.lower():
        if ("a" <= ch <= "z") or ("0" <= ch <= "9"):
            out.append(ch)
            prev_dash = False
        elif not prev_dash:
            out.append("-")
            prev_dash = True
    return "".join(out).strip("-")


def _derive_name(agent: str, workspace: str) -> str:
    """``<agent>-<basename>`` slug for a workspace (mirrors Bash ``derive_name``).

    ``workspace`` is the path as the user typed it, made absolute by
    :func:`_validate_workspace` (logical for ``.``), never the canonicalized
    mount path.
    """
    base = os.path.basename(workspace.rstrip("/\\")) or "workspace"
    return f"{_slugify(agent)}-{_slugify(base)}"


def _secret_scope_args(parser: argparse.ArgumentParser, *, remainder_help: str) -> None:
    """Add the shared ``-g/--global`` flag + REMAINDER scope/service tokens."""
    parser.add_argument("-g", "--global", dest="global_scope", action="store_true", help="global scope")
    parser.add_argument("args", nargs=argparse.REMAINDER, help=remainder_help)


def _secret_name_ok(name: str) -> bool:
    """A service or sandbox name for the secret verbs: the store-key alphabet
    ``[A-Za-z0-9_-]+``, and no leading ``-`` so it can never be read as a flag
    when it reaches a backend CLI's argv."""
    return secretstore.name_ok(name) and not name.startswith("-")


def _secret_names_problem(scope: secretstore.Scope | None, service: str | None) -> str | None:
    """Why the scope/service names are refused, or None. Checked before any
    store or backend access."""
    for kind, name in (("sandbox", None if scope is None else scope.sandbox), ("service", service)):
        if name is not None and not _secret_name_ok(name):
            return f"invalid {kind} name {name!r}: names must match [A-Za-z0-9_-]+ and not start with '-'"
    return None


def _parse_secret_scope_service(
    global_scope: bool, tokens: list[str]
) -> tuple[secretstore.Scope | None, str | None]:
    """Parse ``[-g | --global | SANDBOX] SERVICE`` -> ``(scope, service)``.

    ``scope`` is a typed :class:`secretstore.Scope`: the flag form is the global
    scope, the positional form a sandbox scope, so a sandbox literally named
    ``global`` stays a sandbox. Returns ``(None, None)`` for any other shape so
    the caller emits a usage error. Name validity is checked separately
    (:func:`_secret_names_problem`).
    """
    if global_scope:
        if len(tokens) != 1:
            return None, None
        return secretstore.GLOBAL, tokens[0]
    if len(tokens) != 2:
        return None, None
    scope, service = tokens
    if scope.startswith("-"):
        return None, None
    return secretstore.sandbox_scope(scope), service


def _split_host_env(tokens: list[str]) -> tuple[list[str], list[str], str | None, str | None]:
    """Pull ``--host H`` / ``--host=H`` (repeatable) and ``--env E`` / ``--env=E``
    out of ``secret set``'s trailing tokens.

    Returns ``(positionals, hosts, env, error)``; ``error`` names a flag given
    without its value. Repeated hosts accumulate (the comma-joined multi-host
    form the sidecar stores) rather than silently dropping endpoints.
    """
    positionals: list[str] = []
    hosts: list[str] = []
    env: str | None = None
    it = iter(tokens)
    for token in it:
        flag, eq, inline = token.partition("=")
        if flag not in ("--host", "--env"):
            positionals.append(token)
            continue
        value: str | None = inline
        if not eq:
            value = next(it, None)
        if not value:
            return positionals, hosts, env, f"{flag} needs a value"
        if flag == "--host":
            hosts.append(value)
        else:
            env = value
    return positionals, hosts, env, None


def _parse_secret_ls_scope(global_scope: bool, tokens: list[str]) -> tuple[secretstore.Scope | None, bool]:
    """Parse the optional ``secret ls`` scope filter -> ``(scope, ok)``.

    ``ok`` is False for a malformed filter (extra tokens, or an unknown flag),
    in which case the caller emits a usage error.
    """
    if global_scope:
        return (secretstore.GLOBAL, True) if not tokens else (None, False)
    if not tokens:
        return None, True
    if len(tokens) > 1:
        return None, False
    token = tokens[0]
    if token.startswith("-"):
        return None, False
    return secretstore.sandbox_scope(token), True
