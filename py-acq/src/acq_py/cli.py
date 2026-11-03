"""CLI entrypoint for the acq v1 Python skeleton.

The highest seam is the subprocess boundary (ADR-0038m section 1): exit codes
0/1/2 and the structured-output envelope (``--json``) are the contract. The
foundation slice implements ``version`` and the ``--json`` flag end to end; the
backend-detection slice adds ``backend list`` and ``backend check`` (the read
side of the adapter seam, ADR-0040m). The rest of the command surface arrives
with later slices.

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

from . import backends, envelope, errors, version_info


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
    sub.add_parser("help", help="show help")

    backend_parser = sub.add_parser(
        "backend", help="detect and inspect the sandbox backends (sbx, msb)"
    )
    backend_sub = backend_parser.add_subparsers(dest="backend_command", metavar="SUBCOMMAND")
    backend_sub.add_parser("list", help="list detected backends")
    check_parser = backend_sub.add_parser("check", help="fail closed on an unsupported backend version")
    check_parser.add_argument("name", help="backend name (sbx | msb)")
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

    if parsed.command == "help" or parsed.command is None:
        parser.print_help()
        return errors.EXIT_SUCCESS

    return _usage_failure(parsed.command, f"unknown command: {parsed.command}", emit_json)
