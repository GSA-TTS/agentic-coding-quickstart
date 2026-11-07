"""``exec``, ``attach``, ``shell``, ``cp``, ``ports``, and announced verbatim
backend passthrough: the verbs that act on an existing sandbox (ADR-0038m §4).
"""

from __future__ import annotations

import json
import subprocess
import sys

from .. import backends, envelope, errors, msb, state
from . import common


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
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
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
    rc = adapter.exec_command(name, command, workspace=workspace, json_mode=emit_json)
    if emit_json:
        print(json.dumps(envelope.success("exec", {"name": name, "exit_code": rc})))
    return rc


def run_attach(parsed, emit_json: bool, backend: str) -> int:
    """``acq attach NAME`` — attach to an existing sandbox, launching its agent.

    This is the interactive path; its non-interactive contract is deterministic
    (ADR-0038m §1, spec user story #10): fail closed on a missing sandbox or a
    missing/unreadable host record, then launch the recorded agent and propagate
    its status. The agent comes from host-authoritative state only — there is no
    agent-to-shell fallback (ADR-0038m §48). True PTY allocation and ssh-agent
    forwarding are Tier-3/live concerns and are not synthesized here.
    """
    adapter = common._adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return common._operational_failure(
            "attach",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
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
    rc = adapter.launch(name, workspace, common._launch_token(backend, name, agent), json_mode=emit_json)
    if emit_json:
        print(json.dumps(envelope.success("attach", {"name": name, "backend": backend, "agent": agent, "exit_code": rc})))
    return rc


def run_shell(parsed, emit_json: bool, backend: str) -> int:
    """``acq shell NAME`` — open an interactive login shell in a sandbox.

    Runs ``/bin/sh -l`` as the unprivileged ``agent`` user (never root), with the
    child's status preserved. Like ``attach``, the non-interactive path is
    deterministic and PTY allocation is deferred to the live tier.
    """
    adapter = common._adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return common._operational_failure(
            "shell",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
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
    rc = adapter.launch(name, workspace, "shell", json_mode=emit_json)
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
    name, guest_path = src_ref if src_ref else dst_ref
    host_path = dst if src_ref else src
    direction = "out" if src_ref else "in"
    if not adapter.exists(name):
        return common._operational_failure(
            "cp",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls'",
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

    ADR-0038m §2 fixes the required data: host/guest mappings plus origin. A
    missing sandbox fails closed with ``sandbox_not_found``; a ports read that
    fails or returns unparseable output fails closed with a stable code rather
    than being swallowed as an empty list (ADR-0038m §48 drops
    "inspection-failure-as-empty"). Post-hoc ``--publish`` (ADR-0015) is deferred.
    """
    adapter = common._adapter(backend)
    name = parsed.name
    if not adapter.exists(name):
        return common._operational_failure(
            "ports",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
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


def _passthrough(argv: list[str], explicit: str | None, emit_json: bool) -> int:
    """Forward an unknown subcommand verbatim to the active backend (ADR-0038m §1).

    The handoff is announced on stderr so the user knows any output/errors below
    the notice belong to the backend, not acq. The backend binary's exit status is
    preserved. Passthrough is a verbatim escape hatch: a successful handoff never
    emits an acq JSON envelope (the backend owns stdout, so ``--json`` is inert);
    only the no-backend failure follows acq's normal error contract.
    """
    verb = argv[0]
    name = common._resolve_active_backend(explicit)
    if name is None:
        return common._operational_failure(
            verb,
            errors.BACKEND_NOT_FOUND,
            "no sandbox backend detected",
            f"install msb {backends.MSB_MIN_VERSION[0]}.{backends.MSB_MIN_VERSION[1]}.{backends.MSB_MIN_VERSION[2]} or newer and retry",
            emit_json,
        )
    # The msb adapter honors ACQ_MSB_BIN (its test seam); sbx forwards to the raw
    # CLI. Either way the unknown verb + args are forwarded unchanged.
    if name == "msb":
        binary = msb.msb_command()
    else:
        binary = [backends.BACKENDS[name].cli]
    print(f"acq: '{verb}' is not an acq subcommand - forwarding to '{name}'.", file=sys.stderr)
    print(f"     (output and any errors below are from '{name}', not acq)", file=sys.stderr)
    return subprocess.run([*binary, *argv]).returncode
