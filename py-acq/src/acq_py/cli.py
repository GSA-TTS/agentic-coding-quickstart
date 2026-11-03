"""CLI entrypoint for the acq v1 Python skeleton.

The highest seam is the subprocess boundary (ADR-0038m section 1): exit codes
0/1/2 and the structured-output envelope (``--json``) are the contract. The
foundation slice implements ``version`` and ``doctor`` plus the ``--json`` flag
end to end; the backend-detection slice adds ``backend list`` and
``backend check`` (the read side of the adapter seam, ADR-0040m). The MSB
lifecycle slice adds ``create``, ``run``, ``stop``, ``rm``, and ``ls`` through the
subprocess-calling MSB adapter. The rest of the command surface arrives with
later slices.

Output contract:
    * human output -> stdout, diagnostics -> stderr (no ``--json``)
    * JSON envelope -> stdout, diagnostics -> stderr (``--json``)
    * exit 0 success, 2 usage error, 1 operational failure
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

from . import backends, doctor, envelope, errors, msb, state, version_info

# Agent tokens accepted by acq dispatch (mirrors acq.backends/agents.sh). Kept in
# the CLI because it owns the create-vs-reattach decision for ``run``.
KNOWN_AGENTS = frozenset(
    "claude codex copilot cursor docker-agent droid gemini kiro opencode shell".split()
)

DEFAULT_MSB_IMAGE = "docker.io/docker/sandbox-templates:shell-docker"


class UsageError(Exception):
    """Raised for usage errors; carries the human-facing message."""


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # argparse's default prints usage + exits; we raise so main() can emit a
        # consistent failure envelope/exit code instead.
        raise UsageError(message)


def _flag_value(argv: list[str], flag: str) -> str | None:
    try:
        i = argv.index(flag)
    except ValueError:
        return None
    if i + 1 < len(argv):
        return argv[i + 1]
    return None


def _strip_flag(argv: list[str], flag: str) -> list[str]:
    out: list[str] = []
    skip_next = False
    for token in argv:
        if skip_next:
            skip_next = False
            continue
        if token == flag:
            skip_next = True
            continue
        out.append(token)
    return out


def build_parser() -> _Parser:
    parser = _Parser(
        prog="acq",
        description="acq v1 - run AI coding agents inside a federally-configured sandbox",
        add_help=True,
    )
    parser.add_argument("--version", action="store_true", help="show version and exit")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")
    sub.add_parser("version", help="show acq version + backend info")
    doctor_p = sub.add_parser("doctor", help="diagnose the acq environment")
    doctor_p.add_argument("name", nargs="?", default=None, help="sandbox to inspect (requires a backend)")
    sub.add_parser("help", help="show help")

    backend_parser = sub.add_parser(
        "backend", help="detect and inspect the sandbox backends (sbx, msb)"
    )
    backend_sub = backend_parser.add_subparsers(dest="backend_command", metavar="SUBCOMMAND")
    backend_sub.add_parser("list", help="list detected backends")
    check_parser = backend_sub.add_parser("check", help="fail closed on an unsupported backend version")
    check_parser.add_argument("name", help="backend name (sbx | msb)")

    create_parser = sub.add_parser("create", help="create a sandbox (detached)")
    create_parser.add_argument("agent", help="agent to provision (e.g. opencode, shell)")
    create_parser.add_argument("path", help="workspace directory to mount")
    create_parser.add_argument("--name", help="explicit sandbox name (default: derived from agent+path)")
    create_parser.add_argument("--image", help="base image override (default: shell-docker)")

    run_parser = sub.add_parser("run", help="create+attach a sandbox, or re-attach an existing one")
    run_parser.add_argument("target", help="AGENT (create+attach) or an existing sandbox name (re-attach)")
    run_parser.add_argument("path", nargs="?", help="workspace directory to mount (AGENT form)")
    run_parser.add_argument("--name", help="explicit sandbox name (AGENT form)")
    run_parser.add_argument("--image", help="base image override (AGENT form)")

    sub.add_parser("ls", help="list sandboxes")

    stop_parser = sub.add_parser("stop", help="stop a sandbox without removing it")
    stop_parser.add_argument("name", help="sandbox name")

    rm_parser = sub.add_parser("rm", help="remove a sandbox")
    rm_parser.add_argument("name", help="sandbox name")

    return parser


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
) -> int:
    """Emit an operational failure (exit 1) with a stable error code.

    Distinct from a usage error (exit 2): the command was well-formed but could
    not be carried out. The JSON form puts the failure envelope on stdout; the
    human form writes diagnostics to stderr.
    """
    if emit_json:
        doc = envelope.error(command, code, message, remediation=remediation)
        print(json.dumps(doc))
    else:
        print(f"acq: {message}", file=sys.stderr)
        if remediation:
            print(remediation, file=sys.stderr)
    return errors.EXIT_FAILURE


def run_version(emit_json: bool) -> int:
    data = version_info.version_data()
    if emit_json:
        print(json.dumps(envelope.success("version", data)))
        return errors.EXIT_SUCCESS
    print("acq v1 (Python skeleton)")
    print(f"  acq version:       {data['acq_version']}")
    print(f"  source revision:   {data['source_revision'] or '(not a git clone)'}")
    print(f"  backend:           {data['backend'] or 'none'}")
    print(f"  backend version:   {data['backend_version'] or 'none'}")
    print(f"  kit control plane: {data['kit_control_plane_ref'] or 'none'}")
    return errors.EXIT_SUCCESS


def _resolve_active_backend(explicit: str | None) -> str | None:
    """Resolve the active backend for read-only reporting.

    Precedence: the ``--backend`` flag, then the ``ACQ_BACKEND`` environment
    variable, then (in a later slice) config persistence via ``backend set``,
    then the auto-detect default. An invalid flag value is a usage error
    (handled by the caller); an invalid environment value is dropped (ADR-0038m
    "drop invalid persisted backends").

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
    installed = [s.name for s in backends.detect_all() if s.installed]
    if len(installed) == 1:
        return installed[0]
    if len(installed) > 1:
        return "msb"
    return None


def _backend_list_data(active_backend: str | None) -> dict:
    statuses = backends.detect_all()
    return {
        "active_backend": active_backend,
        "backends": [
            {
                "name": s.name,
                "installed": s.installed,
                "version": s.version,
            }
            for s in statuses
        ],
    }


def run_backend_list(emit_json: bool, active_backend: str | None) -> int:
    data = _backend_list_data(active_backend)
    if emit_json:
        print(json.dumps(envelope.success("backend list", data)))
        return errors.EXIT_SUCCESS
    print("Installed backends:")
    for record in data["backends"]:
        if record["installed"]:
            ver = record["version"]
            line = f"  {record['name']}  v{ver}" if ver != "unknown" else f"  {record['name']}  {ver}"
        else:
            line = f"  {record['name']}  (not found)"
        if record["name"] == active_backend:
            line += " (active)"
        print(line)
    return errors.EXIT_SUCCESS


def run_backend_check(emit_json: bool, name: str) -> int:
    spec = backends.BACKENDS.get(name)
    if spec is None:
        return _usage_failure(
            "backend check",
            f"unknown backend: {name!r} (expected sbx or msb)",
            emit_json,
        )
    problem = backends.check_version(spec)
    if problem is None:
        status = backends.detect(spec)
        data = {
            "name": spec.name,
            "installed": status.installed,
            "version": status.version,
        }
        if emit_json:
            print(json.dumps(envelope.success("backend check", data)))
        else:
            print(f"backend '{spec.name}': version {status.version} (supported)")
        return errors.EXIT_SUCCESS
    if emit_json:
        print(
            json.dumps(
                envelope.error(
                    "backend check",
                    problem.code,
                    problem.message,
                    remediation=problem.remediation,
                )
            )
        )
    else:
        print(f"acq: {problem.message}", file=sys.stderr)
        if problem.remediation:
            print(f"      {problem.remediation}", file=sys.stderr)
    return errors.EXIT_FAILURE


def _print_doctor_human(data: dict) -> None:
    print("acq: doctor")
    for check in data["checks"]:
        print(f"  [{check['status']:4}] {check['id']}: {check['message']}")
        remediation = check.get("remediation")
        if remediation:
            print(f"           {remediation}")
    print(f"overall: {data['status']}")


def run_doctor(emit_json: bool, name: str | None) -> int:
    # `acq doctor NAME` inspects a named sandbox's image contract, a
    # backend-provided capability (ADR-0040m `doctor`). No adapter is present in
    # this slice, so the request fails closed with exit 1 rather than inventing
    # a result.
    if name is not None:
        return _operational_failure(
            "doctor",
            errors.UNSUPPORTED,
            f"cannot inspect sandbox {name!r}: no backend adapter is available",
            "backend adapters ship in a later slice; sandbox inspection is unavailable in this build",
            emit_json,
        )

    data = doctor.doctor_data()
    if emit_json:
        print(json.dumps(envelope.success("doctor", data)))
        return errors.EXIT_SUCCESS
    _print_doctor_human(data)
    return errors.EXIT_SUCCESS


# ---------------------------------------------------------------------------
# MSB lifecycle verbs (create / run / stop / rm / ls).
# ---------------------------------------------------------------------------

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
    base = os.path.basename(workspace.rstrip("/\\")) or "workspace"
    return f"{_slugify(agent)}-{_slugify(base)}"


def _resolve_image(flag_image: str | None) -> str:
    if flag_image:
        return flag_image
    env = os.environ.get("ACQ_IMAGE") or os.environ.get("ACQ_MSB_IMAGE")
    if env:
        return env
    return DEFAULT_MSB_IMAGE


def _resolve_backend_for_lifecycle(
    explicit: str | None, emit_json: bool, command: str
) -> tuple[str | None, int | None]:
    """Resolve the backend for a mutating verb and enforce the version floor.

    Returns ``(backend_name, exit_code)``; ``exit_code`` is non-``None`` when a
    failure was already emitted (unknown backend -> usage, no backend / non-msb /
    unsupported version -> operational, all fail-closed before mutation).
    """
    if explicit is not None and explicit not in backends.BACKENDS:
        return None, _usage_failure(
            command,
            f"unknown backend: {explicit!r} (expected sbx or msb)",
            emit_json,
        )
    name = _resolve_active_backend(explicit)
    if name is None:
        return None, _operational_failure(
            command,
            errors.BACKEND_NOT_FOUND,
            "no sandbox backend detected",
            f"install msb {backends.MSB_MIN_VERSION[0]}.{backends.MSB_MIN_VERSION[1]}.{backends.MSB_MIN_VERSION[2]} or newer and retry",
            emit_json,
        )
    if name != "msb":
        return None, _operational_failure(
            command,
            errors.UNSUPPORTED,
            f"backend '{name}' lifecycle is not implemented in this build",
            "only the msb adapter ships in this slice; the sbx adapter arrives later",
            emit_json,
        )
    problem = backends.check_version(backends.BACKENDS["msb"])
    if problem is not None:
        return None, _operational_failure(command, problem.code, problem.message, problem.remediation, emit_json)
    return name, None


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
    resolved = os.path.abspath(path)
    if not os.path.isdir(resolved):
        return None, _operational_failure(
            command,
            errors.VALIDATION_FAILED,
            f"workspace path does not exist or is not a directory: {path}",
            "create the workspace first, then re-run",
            emit_json,
        )
    return resolved, None


def _wait_exec_ready(name: str) -> bool:
    deadline = time.monotonic() + msb.READY_TIMEOUT_S
    while True:
        if msb.exec_ready(name):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


def _create_sandbox(agent: str, workspace: str, name: str, image: str) -> dict:
    """Create + exec-ready gate + record write; returns the result record data."""
    msb.create(name, image, workspace, memory=msb.DEFAULT_MEMORY, cpus=msb.DEFAULT_CPUS)
    if not _wait_exec_ready(name):
        # A half-created sandbox must not strand (legacy _acq_msb_cleanup_uncreated_attempt).
        try:
            msb.remove(name)
        except msb.MsbError:
            pass
        raise msb.MsbError(
            errors.TIMEOUT,
            f"sandbox '{name}' did not become exec-ready",
            "check msb logs, then remove the half-created sandbox and retry",
        )
    state.record_write("msb", name, agent=agent, workspace=workspace, image=image)
    return {"name": name, "backend": "msb", "agent": agent, "workspace": workspace, "state": "running"}


def _print_create_human(data: dict) -> None:
    print(
        f"sandbox '{data['name']}' created (backend {data['backend']}, "
        f"agent {data['agent']}, workspace {data['workspace']})"
    )


def run_create(parsed, emit_json: bool) -> int:
    workspace, exit_code = _validate_workspace("create", parsed.path, emit_json)
    if exit_code is not None:
        return exit_code
    name = parsed.name or _derive_name(parsed.agent, workspace)
    if msb.exists(name):
        return _operational_failure(
            "create",
            errors.SANDBOX_EXISTS,
            f"sandbox '{name}' already exists",
            f"re-attach with 'acq run {name}', or remove it with 'acq rm {name}'",
            emit_json,
        )
    image = _resolve_image(parsed.image)
    try:
        data = _create_sandbox(parsed.agent, workspace, name, image)
    except msb.MsbError as exc:
        return _operational_failure("create", exc.code, exc.message, exc.remediation, emit_json)
    if emit_json:
        print(json.dumps(envelope.success("create", data)))
    else:
        _print_create_human(data)
    return errors.EXIT_SUCCESS


def run_run(parsed, emit_json: bool) -> int:
    target = parsed.target
    if target in KNOWN_AGENTS:
        workspace, exit_code = _validate_workspace("run", parsed.path, emit_json)
        if exit_code is not None:
            return exit_code
        name = parsed.name or _derive_name(target, workspace)
        action = "reattached" if msb.exists(name) else "created"
        if not msb.exists(name):
            image = _resolve_image(parsed.image)
            try:
                _create_sandbox(target, workspace, name, image)
            except msb.MsbError as exc:
                return _operational_failure("run", exc.code, exc.message, exc.remediation, emit_json)
        if emit_json:
            print(
                json.dumps(
                    envelope.success(
                        "run",
                        {"name": name, "backend": "msb", "agent": target, "workspace": workspace, "state": "running", "action": action},
                    )
                )
            )
        # Launch in the foreground; the child's status is `run`'s exit status.
        return msb.launch(name, workspace, target)

    # Not a known agent: re-attach to an existing sandbox by name, else fail
    # closed as ambiguous (a token that is neither agent nor sandbox is a usage
    # error, matching the legacy dispatch).
    if not msb.exists(target):
        return _usage_failure(
            "run",
            f"'{target}' is not a known agent or an existing sandbox",
            emit_json,
        )
    # Re-attach by sandbox name (host-authoritative record supplies agent/workspace).
    record = state.record_read("msb", target)
    agent = record.get("agent") if record else None
    workspace = record.get("workspace") if record else None
    if emit_json:
        print(
            json.dumps(
                envelope.success(
                    "run",
                    {"name": target, "backend": "msb", "agent": agent, "workspace": workspace, "state": "running", "action": "reattached"},
                )
            )
        )
    return msb.launch(target, workspace, agent)


def _ls_data() -> dict:
    names = msb.list_names() or []
    running = set(msb.running_names() or [])
    sandboxes: list[dict] = []
    for name in names:
        entry: dict = {"name": name, "backend": "msb", "state": "running" if name in running else "stopped"}
        record = state.record_read("msb", name)
        if record:
            if record.get("agent"):
                entry["agent"] = record["agent"]
            if record.get("workspace"):
                entry["workspace"] = record["workspace"]
        sandboxes.append(entry)
    # A host record whose sandbox is gone (removed out-of-band) reads as unknown.
    for record in state.list_records("msb"):
        if record.get("name") not in names:
            entry = {"name": record["name"], "backend": "msb", "state": "unknown"}
            if record.get("agent"):
                entry["agent"] = record["agent"]
            if record.get("workspace"):
                entry["workspace"] = record["workspace"]
            sandboxes.append(entry)
    sandboxes.sort(key=lambda entry: entry["name"])
    return {"sandboxes": sandboxes}


def _print_ls_human(data: dict) -> None:
    sandboxes = data["sandboxes"]
    if not sandboxes:
        print("no sandboxes")
        return
    for entry in sandboxes:
        extra = f"  ({entry['agent']})" if entry.get("agent") else ""
        print(f"  {entry['name']}  {entry['backend']}  {entry['state']}{extra}")


def run_ls(emit_json: bool) -> int:
    data = _ls_data()
    if emit_json:
        print(json.dumps(envelope.success("ls", data)))
    else:
        _print_ls_human(data)
    return errors.EXIT_SUCCESS


def run_stop(parsed, emit_json: bool) -> int:
    name = parsed.name
    if not msb.exists(name):
        return _operational_failure(
            "stop",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls', or create one with 'acq create'",
            emit_json,
        )
    try:
        msb.stop(name)
    except msb.MsbError as exc:
        return _operational_failure("stop", exc.code, exc.message, exc.remediation, emit_json)
    data = {"name": name, "backend": "msb", "state": "stopped"}
    if emit_json:
        print(json.dumps(envelope.success("stop", data)))
    else:
        print(f"stopped sandbox '{name}'")
    return errors.EXIT_SUCCESS


def run_rm(parsed, emit_json: bool) -> int:
    name = parsed.name
    if not msb.exists(name):
        return _operational_failure(
            "rm",
            errors.SANDBOX_NOT_FOUND,
            f"sandbox '{name}' not found",
            f"list sandboxes with 'acq ls'",
            emit_json,
        )
    try:
        msb.remove(name)
    except msb.MsbError as exc:
        return _operational_failure("rm", exc.code, exc.message, exc.remediation, emit_json)
    state.record_remove("msb", name)
    data = {"name": name, "backend": "msb", "removed": True}
    if emit_json:
        print(json.dumps(envelope.success("rm", data)))
    else:
        print(f"removed sandbox '{name}'")
    return errors.EXIT_SUCCESS


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)

    emit_json = "--json" in args
    # `--backend NAME` selects the active backend for read-only reporting.
    backend_override = _flag_value(args, "--backend")
    args = [a for a in args if a != "--json"]
    args = _strip_flag(args, "--backend")

    parser = build_parser()
    try:
        parsed = parser.parse_args(args)
    except UsageError as exc:
        return _usage_failure(None, str(exc), emit_json)

    if parsed.version or parsed.command == "version":
        return run_version(emit_json)

    if parsed.command == "backend":
        if backend_override is not None and backend_override not in backends.BACKENDS:
            return _usage_failure(
                "backend",
                f"unknown backend: {backend_override!r} (expected sbx or msb)",
                emit_json,
            )
        if parsed.backend_command == "list":
            return run_backend_list(emit_json, _resolve_active_backend(backend_override))
        if parsed.backend_command == "check":
            return run_backend_check(emit_json, parsed.name)
        return _usage_failure(
            "backend",
            "backend requires a subcommand: list | check",
            emit_json,
        )

    if parsed.command == "doctor":
        return run_doctor(emit_json, parsed.name)

    if parsed.command in ("create", "run", "ls", "stop", "rm"):
        _backend, exit_code = _resolve_backend_for_lifecycle(backend_override, emit_json, parsed.command)
        if exit_code is not None:
            return exit_code
        if parsed.command == "create":
            return run_create(parsed, emit_json)
        if parsed.command == "run":
            return run_run(parsed, emit_json)
        if parsed.command == "ls":
            return run_ls(emit_json)
        if parsed.command == "stop":
            return run_stop(parsed, emit_json)
        if parsed.command == "rm":
            return run_rm(parsed, emit_json)

    if parsed.command == "help" or parsed.command is None:
        parser.print_help()
        return errors.EXIT_SUCCESS

    return _usage_failure(parsed.command, f"unknown command: {parsed.command}", emit_json)
