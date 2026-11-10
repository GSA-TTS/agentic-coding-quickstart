"""``exec``, ``attach``, ``shell``, ``cp``, ``ports``, and announced verbatim
backend passthrough: the verbs that act on an existing sandbox (ADR-0038m §4).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

from .. import (
    backends,
    envelope,
    errors,
    gitrepos,
    hostexec,
    kit_msb,
    kit_sbx,
    lock,
    msb,
    publish,
    sbx,
    state,
)
from . import common

# Host identity variables replayed into every session, so commits made in the
# guest carry the user's identity (Bash: ``acq_host_git_identity_env``).
_GIT_IDENTITY_VARS = ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL")
# A recorded guest ssh-agent socket must be an absolute path in a word-safe
# charset, the same guard Bash applies to ACQ_MSB_SSH_AGENT_GUEST_SOCK.
_SAFE_GUEST_SOCK = re.compile(r"/[A-Za-z0-9._/-]*")


def _identity_value_is_safe(value: str) -> bool:
    # One ``NAME=value`` per entry: a line break or tab would split or corrupt it.
    return not any(ch in value for ch in "\n\r\t")


def _host_git_config(key: str) -> str | None:
    """Read ``git config --global --get KEY`` on the host; ``None`` if unavailable.

    The inherited repository redirects are cleared first: an inherited
    ``GIT_CONFIG`` makes ``git config --global`` fail outright ("only one config
    file at a time"), which would hide the user's global value.

    git stores its config as UTF-8 and prints the value unchanged, so it is
    decoded as UTF-8, never with the locale's code page: on a Windows ANSI code
    page a name such as "Łukasz" would otherwise fail to decode (a traceback in
    every session) or turn into mojibake. Bytes that are not UTF-8 become
    U+FFFD rather than an error.
    """
    git = hostexec.which("git")
    if git is None:
        return None
    try:
        proc = subprocess.run(
            [git, "config", "--global", "--get", key],
            env=gitrepos.git_env(keep_command_scope=True),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.rstrip("\r\n") or None


def host_git_identity_env() -> list[str]:
    """The host's git identity as ``NAME=value`` entries for a guest session.

    Explicit ``GIT_AUTHOR_*``/``GIT_COMMITTER_*`` values are forwarded as set.
    ``EMAIL`` comes from the environment, else from the global ``user.email``.
    Values that are empty or contain a line break or tab are skipped.
    """
    entries = []
    for var in _GIT_IDENTITY_VARS:
        value = os.environ.get(var)
        if value and _identity_value_is_safe(value):
            entries.append(f"{var}={value}")
    email = os.environ.get("EMAIL")
    if not (email and _identity_value_is_safe(email)):
        email = _host_git_config("user.email")
    if email and _identity_value_is_safe(email):
        entries.append(f"EMAIL={email}")
    return entries


def _forwarded_ssh_auth_sock(record: dict | None) -> str | None:
    """The guest ssh-agent socket recorded for this sandbox, or ``None``.

    The record carries ``ssh_auth_sock`` only when the sandbox was created with
    host ssh-agent forwarding (see ADR-0021). The host's own ``SSH_AUTH_SOCK`` is
    never forwarded: it names a host path that means nothing in the guest.
    """
    sock = (record or {}).get("ssh_auth_sock")
    if isinstance(sock, str) and _SAFE_GUEST_SOCK.fullmatch(sock):
        return sock
    return None


def session_env(record: dict | None) -> list[str]:
    """Backend-neutral ``NAME=value`` entries for a session in this sandbox.

    The adapters add their own (HOME, SHELL, and TERM/COLORTERM when the session
    has a terminal).
    """
    entries = host_git_identity_env()
    sock = _forwarded_ssh_auth_sock(record)
    if sock is not None:
        entries.append(f"SSH_AUTH_SOCK={sock}")
    return entries


def prepare_session(backend: str, name: str, record: dict | None) -> list[str]:
    """Ready ``name`` for a session and return the session's ``NAME=value`` entries.

    The entries are :func:`session_env`. On msb, as in Bash, the host's global
    git identity is first written into the guest's global git config, and the
    kit environment recorded when the kits were applied is added last, so a
    kit's ``environment`` reaches every agent session. sbx applies both itself:
    its kits carry their environment, and the git identity kit sets the config.
    """
    entries = session_env(record)
    if backend == "msb":
        # The same host values the sbx git identity kit writes into its guest.
        msb.apply_git_global_config(name, kit_sbx.git_global_config_env())
        entries += kit_msb.session_env(name)
    return entries


def session_env_for(backend: str, name: str) -> list[str]:
    """:func:`prepare_session` for a sandbox whose record the caller has not read."""
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError:
        record = None
    return prepare_session(backend, name, record)


def run_exec(parsed, emit_json: bool, backend: str) -> int:
    """``acq exec NAME -- CMD...`` — run a command non-interactively.

    The child's exit status is acq's exit status (ADR-0038m §1). In ``--json``
    mode the child's stdout is routed to stderr and one success envelope carrying
    the exit code is emitted on stdout (ADR-0038m §2).
    """
    adapter = common._adapter(backend)
    name = parsed.name
    command = list(parsed.cmd)
    if not command:
        return common._usage_failure(
            "exec",
            f"exec requires a command after '--' (usage: acq exec {name} -- CMD...)",
            emit_json,
        )
    if not adapter.exists(name):
        return common._operational_failure(
            "exec",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return common._operational_failure(
            "exec",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = common._trusted_gate(record, backend, "exec", name, emit_json)
    if gate is not None:
        return gate
    workspace = (record or {}).get("workspace") or common.DEFAULT_GUEST_WORKSPACE
    env = prepare_session(backend, name, record)
    rc = adapter.exec_command(name, command, workspace=workspace, json_mode=emit_json, env=env)
    if emit_json:
        print(json.dumps(envelope.success("exec", {"name": name, "exit_code": rc})))
    return rc


def run_attach(parsed, emit_json: bool, backend: str) -> int:
    """``acq attach NAME`` — attach to an existing sandbox, launching its agent.

    This is the interactive path; its non-interactive contract is deterministic
    (ADR-0038m §1, spec ordinary-user story 10): fail closed on a missing sandbox or a
    missing/unreadable host record, then launch the recorded agent and propagate
    its status. The agent comes from host-authoritative state only — there is no
    agent-to-shell fallback (ADR-0038m §48). The adapter gives the session a PTY
    when stdin is a terminal, and replays the session environment.
    """
    adapter = common._adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return common._operational_failure(
            "attach",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return common._operational_failure(
            "attach",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    if record is None:
        return common._operational_failure(
            "attach",
            errors.VALIDATION_FAILED,
            f"sandbox '{name}' has no readable host state record; cannot determine the agent to launch",
            f"create it with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = common._trusted_gate(record, backend, "attach", name, emit_json)
    if gate is not None:
        return gate
    agent = record.get("agent")
    if not agent:
        return common._operational_failure(
            "attach",
            errors.VALIDATION_FAILED,
            f"sandbox '{name}' records no agent; cannot determine the agent to launch",
            f"create it with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    workspace = record.get("workspace") or common.DEFAULT_GUEST_WORKSPACE
    token = common._launch_token(backend, name, agent)
    rc = adapter.launch(name, workspace, token, json_mode=emit_json, env=prepare_session(backend, name, record))
    if emit_json:
        print(json.dumps(envelope.success("attach", {"name": name, "backend": backend, "agent": agent, "exit_code": rc})))
    return rc


def run_shell(parsed, emit_json: bool, backend: str) -> int:
    """``acq shell NAME`` — open an interactive login shell in a sandbox.

    Runs a login shell as the unprivileged ``agent`` user (never root), with the
    child's status preserved. Like ``attach``, it gets a PTY when stdin is a
    terminal and the session environment.
    """
    adapter = common._adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return common._operational_failure(
            "shell",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError as exc:
        return common._operational_failure(
            "shell",
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            f"recreate the sandbox with 'acq create', or remove it with 'acq rm {name}'",
            emit_json,
        )
    gate = common._trusted_gate(record, backend, "shell", name, emit_json)
    if gate is not None:
        return gate
    workspace = (record or {}).get("workspace") or common.DEFAULT_GUEST_WORKSPACE
    rc = adapter.launch(name, workspace, "shell", json_mode=emit_json, env=prepare_session(backend, name, record))
    if emit_json:
        print(json.dumps(envelope.success("shell", {"name": name, "backend": backend, "exit_code": rc})))
    return rc


def run_cp(parsed, emit_json: bool, backend: str) -> int:
    """``acq cp SRC DST`` — copy between a native host path and a POSIX guest path.

    Exactly one side is a ``NAME:/guest/path`` reference; the other is a host
    path. Host and guest types stay distinct (ADR-0038m §4): a host mount source
    is never treated as a guest path implicitly. The host side is forwarded
    verbatim to the backend, which resolves it natively on the host, so a
    UNC/network host path (``\\\\server\\share\\...`` / ``//server/share/...``)
    is accepted the same way a plain-drive path is — consistent with the UNC
    workspace mount the msb adapter now supports (ADR-0029). There is no
    host→guest translation on the ``cp`` host side, so nothing can round-trip
    lossily. The backend copy status is preserved.
    """
    adapter = common._adapter(backend)
    src = parsed.src
    dst = parsed.dst
    src_ref = common._sandbox_ref(src)
    dst_ref = common._sandbox_ref(dst)
    if src_ref and dst_ref:
        return common._usage_failure(
            "cp",
            "copying between two sandboxes is not supported; exactly one side must be a host path",
            emit_json,
        )
    if not src_ref and not dst_ref:
        return common._usage_failure(
            "cp",
            "exactly one of SRC/DST must be a sandbox reference (NAME:/guest/path)",
            emit_json,
        )
    ref = src_ref or dst_ref
    assert ref is not None  # nosec B101 # checked above; narrows the type for mypy
    name, guest_path = ref
    host_path = dst if src_ref else src
    direction = "out" if src_ref else "in"
    if not adapter.exists(name):
        return common._operational_failure(
            "cp",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls'",
            emit_json,
        )
    # The host side is forwarded verbatim to the backend, which resolves it
    # natively on the host (ADR-0029). There is no host->guest translation on
    # this side, so a UNC/network host path (\\server\share\... /
    # //server/share/...) is accepted the same way a plain-drive path is —
    # consistent with the UNC workspace mount the msb adapter now supports.
    rc = adapter.copy(src, dst)
    if rc != 0:
        return common._operational_failure(
            "cp",
            errors.FAILURE,
            f"copy failed between host and sandbox '{name}'",
            f"check {backend} logs and retry",
            emit_json,
            exit_code=rc,
        )
    if emit_json:
        print(json.dumps(envelope.success("cp", {"name": name, "host": host_path, "guest": guest_path, "direction": direction, "exit_code": 0})))
    else:
        if direction == "in":
            print(f"copied {host_path} -> {name}:{guest_path}")
        else:
            print(f"copied {name}:{guest_path} -> {host_path}")
    return errors.EXIT_SUCCESS


def run_ports(parsed, emit_json: bool, backend: str) -> int:
    """``acq ports NAME`` — report declared host/guest mappings, never health.

    ADR-0038m §2 fixes the required data: host/guest mappings plus origin
    (``create`` for a create-time mapping, ``post-hoc`` for a tunnel ``acq ports
    --publish`` opened). A missing sandbox fails closed with
    ``sandbox_not_found``; a ports read that fails or returns unparseable output
    fails closed with a stable code rather than being swallowed as an empty list
    (ADR-0038m §48 drops "inspection-failure-as-empty"). With ``--publish`` it
    publishes instead (:func:`_publish_ports`).
    """
    adapter = common._adapter(backend)
    name = parsed.name
    requested = getattr(parsed, "publish", None) or []
    if requested and None in requested:
        # A --publish with no value is refused, never read as "list" (ADR-0038m
        # drops ignored missing values).
        return common._operational_failure(
            "ports", errors.VALIDATION_FAILED, "--publish given with no value (expected HOST:GUEST)",
            f"run 'acq ports {name} --publish HOST:GUEST'", emit_json,
        )
    if not adapter.exists(name):
        return common._operational_failure(
            "ports",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            "list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    if requested:
        return _publish_ports(name, requested, emit_json, backend)
    try:
        mappings = adapter.ports(name)
    except common._ADAPTER_ERRORS as exc:
        return common._operational_failure("ports", exc.code, exc.message, exc.remediation, emit_json)
    data = {"name": name, "ports": mappings}
    if emit_json:
        print(json.dumps(envelope.success("ports", data)))
    else:
        if not mappings:
            print(f"no declared ports for sandbox '{name}'")
        else:
            for entry in mappings:
                print(f"guest {entry['guest_port']} -> host {entry['host_port']} ({entry['origin']})")
    return errors.EXIT_SUCCESS


def _publish_ports(name: str, requested: list[str], emit_json: bool, backend: str) -> int:
    """``acq ports NAME --publish H:G...`` (ADR-0015).

    On msb every value is checked first (two integers 1..65535, as Bash's
    ``_acq_msb_valid_publish``), then one tunnel per value is opened under the
    sandbox's lifecycle lock, so an ``rm`` cannot strand a tunnel half recorded.
    Each repeated ``--publish`` is honoured (Bash kept only the last), all or
    nothing. On sbx the values are sbx's own publish, forwarded verbatim; its
    status is kept.
    """
    if backend == "sbx":
        rc = sbx.publish_ports(name, requested, json_mode=emit_json)
        if rc != 0:
            return common._operational_failure(
                "ports", errors.FAILURE, f"sbx could not publish the requested port of sandbox '{name}'",
                "check the value against 'sbx ports --help' and retry", emit_json, exit_code=rc,
            )
        if emit_json:
            print(json.dumps(envelope.success("ports", {"name": name, "requested": requested})))
        return errors.EXIT_SUCCESS
    for mapping in requested:
        problem = publish.posthoc_problem(mapping)
        if problem is not None:
            return common._operational_failure(
                "ports", errors.VALIDATION_FAILED, problem,
                "give both ports, e.g. 'acq ports NAME --publish 8080:3000'", emit_json,
            )
    try:
        with lock.sandbox_lock(backend, name):
            opened = msb.publish_ports(name, requested)
    except lock.SandboxLockTimeout as exc:
        return common._operational_failure(
            "ports", errors.TIMEOUT, str(exc),
            exc.remediation or f"wait for the other acq command on sandbox '{name}' to finish, then retry",
            emit_json,
        )
    except msb.MsbError as exc:
        return common._operational_failure("ports", exc.code, exc.message, exc.remediation, emit_json)
    if emit_json:
        print(json.dumps(envelope.success("ports", {"name": name, "requested": requested, "ports": opened})))
        return errors.EXIT_SUCCESS
    for entry in opened:
        print(f"acq(msb): published host 127.0.0.1:{entry['host_port']} -> sandbox {name} "
              f"127.0.0.1:{entry['guest_port']}", file=sys.stderr)
        print(f"acq(msb):   via 'msb ssh serve' on 127.0.0.1:{entry['serve_port']} + ssh -L (ADR-0015).",
              file=sys.stderr)
    print(f"acq(msb):   tear down with 'acq rm {name}' (or 'acq stop {name}').", file=sys.stderr)
    return errors.EXIT_SUCCESS


def _passthrough(argv: list[str], explicit: str | None, emit_json: bool) -> int:
    """Forward an unknown subcommand verbatim to the active backend (ADR-0038m §1).

    The handoff is announced on stderr so the user knows any output/errors below
    the notice belong to the backend, not acq. The backend binary's exit status is
    preserved. Passthrough is a verbatim escape hatch: a successful handoff never
    emits an acq JSON envelope (the backend owns stdout, so ``--json`` is inert).
    Failures before the handoff follow acq's normal error contract: an unknown
    ``--backend`` is a usage error (exit 2), and no backend, or a backend CLI that
    cannot be started, is ``backend_not_found`` (exit 1).

    Like Bash's ``_acq_backend_passthrough``, it does not run the version floor:
    the verb is the backend's own, so the backend judges it.
    """
    verb = argv[0]
    if explicit is not None and explicit not in backends.BACKENDS:
        return common._usage_failure(
            verb,
            f"unknown backend: {explicit!r} (expected sbx or msb)",
            emit_json,
        )
    invalid = common._invalid_persisted_backend_failure(explicit, verb, emit_json)
    if invalid is not None:
        return invalid
    name = common._resolve_active_backend(explicit)
    if name is None:
        return common._operational_failure(
            verb,
            errors.BACKEND_NOT_FOUND,
            "no sandbox backend detected",
            f"install msb {backends.MSB_MIN_VERSION[0]}.{backends.MSB_MIN_VERSION[1]}.{backends.MSB_MIN_VERSION[2]} or newer and retry",
            emit_json,
        )
    # Each adapter's command resolver honours its ACQ_<BACKEND>_BIN test seam, so
    # the binary forwarded to is the one every other verb runs. The binary is
    # resolved before the notice so a missing CLI yields only acq's error.
    try:
        binary = msb.msb_command() if name == "msb" else sbx.sbx_command()
    except OSError:
        return _backend_unavailable(verb, name, emit_json)
    if not (os.path.isfile(binary[0]) and os.access(binary[0], os.X_OK)):
        return _backend_unavailable(verb, name, emit_json)
    print(f"acq: '{verb}' is not an acq subcommand - forwarding to '{name}'.", file=sys.stderr)
    print(f"     (output and any errors below are from '{name}', not acq)", file=sys.stderr)
    try:
        return hostexec.run_foreground([*binary, *argv])
    except OSError:
        return _backend_unavailable(verb, name, emit_json)


def _backend_unavailable(verb: str, backend: str, emit_json: bool) -> int:
    """Report a backend CLI that cannot be started, using the adapter's own error."""
    err = common._adapter(backend).cli_unavailable()
    return common._operational_failure(verb, err.code, err.message, err.remediation, emit_json)
