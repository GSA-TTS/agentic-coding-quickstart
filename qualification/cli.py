"""CLI for the qualification harness (``python -m qualification``).

Two subcommands:

``run`` — drive one cell and emit the verbatim ``RESULT`` signature line plus a
machine-readable ``OUTCOME`` disposition line. Offline-testable by pointing
``--`` + a command at a fake backend (e.g. ``python -c "exit 1"``).

``matrix`` — print the qualified/unqualified/blocked matrix honestly.

The harness is Tier-3 tooling, not CLI code; the live run is its downstream
consumer. Exit codes: 0 PASS, 1 FAIL, 2 BLOCKED, 3 FLAKY (escalation).
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from .matrix import is_claimed, report_matrix
from .model import Environment, format_result_line
from .runner import (
    CellResult,
    exit_code_for,
    result_verdict,
    run_cell,
    transcript_document,
)

# Deterministic defaults so an offline run (and its fixtures) never depend on the
# host. A live Tier-3 run overrides every identity field explicitly.
_DEFAULT_REV = "0000000000000000000000000000000000000000"
_DEFAULT_ARTIFACT = "0000000000000000000000000000000000000000000000000000000000000000"
_DEFAULT_DIR = "none"  # no evidence directory written unless --transcript-dir given


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="qualification",
        description="Qualification harness (ADR-0044m): RESULT transcript, matrix, reproduction.",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    run_p = sub.add_parser("run", help="run one cell and emit its RESULT line")
    run_p.add_argument("--backend", required=True, choices=["msb", "sbx"])
    run_p.add_argument("--platform", default="")
    run_p.add_argument("--backend-version", default="unknown")
    run_p.add_argument("--image", default="unknown")
    run_p.add_argument("--os", default="Linux")
    run_p.add_argument("--os-build", default="unknown")
    run_p.add_argument("--arch", default="x86_64")
    run_p.add_argument("--hypervisor", default="unknown")
    run_p.add_argument("--glibc-floor", default=None)
    run_p.add_argument("--rev", default=_DEFAULT_REV)
    run_p.add_argument("--artifact-sha256", default=_DEFAULT_ARTIFACT)
    run_p.add_argument("--transcript-dir", default=None)
    run_p.add_argument("--attempts", type=int, default=3)
    run_p.add_argument("--timeout", type=float, default=120.0)
    run_p.add_argument("command", nargs=argparse.REMAINDER)

    matrix_p = sub.add_parser("matrix", help="print the qualification matrix")
    matrix_p.add_argument("--json", action="store_true")
    return parser


def _environment(args: argparse.Namespace) -> Environment:
    transcript_dir = args.transcript_dir or _DEFAULT_DIR
    if args.transcript_dir:
        transcript_dir = str(Path(args.transcript_dir).resolve())
    return Environment(
        os=args.os,
        os_build=args.os_build,
        arch=args.arch,
        hypervisor=args.hypervisor,
        backend=args.backend,
        backend_version=args.backend_version,
        image=args.image,
        rev=args.rev,
        artifact_sha256=args.artifact_sha256,
        transcript_dir=transcript_dir,
        glibc_floor=args.glibc_floor,
    )


def _cmd_run(args: argparse.Namespace) -> int:
    environment = _environment(args)
    unqualified = bool(args.platform) and not is_claimed(args.backend, args.platform)
    command = list(args.command)
    # ``argparse.REMAINDER`` captures the literal ``--`` separator; drop it.
    if command and command[0] == "--":
        command = command[1:]
    result: CellResult = run_cell(
        command,
        environment,
        unqualified=unqualified,
        max_attempts=args.attempts,
        timeout=args.timeout,
    )

    sys.stdout.write(f"OUTCOME {result.outcome.value}\n")
    sys.stdout.write(
        format_result_line(result_verdict(result.outcome), result.environment) + "\n"
    )

    if args.transcript_dir:
        transcript_dir = Path(environment.transcript_dir)
        transcript_dir.mkdir(parents=True, exist_ok=True)
        path = transcript_dir / "transcript.json"
        path.write_text(
            json.dumps(transcript_document(result), sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )

    return exit_code_for(result.outcome)


def _cmd_matrix(args: argparse.Namespace) -> int:
    reports = report_matrix({}, now=datetime.now(timezone.utc))
    if args.json:
        cells = [
            {
                "backend": r.backend,
                "platform": r.platform,
                "claimed": r.claimed,
                "state": r.state.value,
            }
            for r in reports
        ]
        sys.stdout.write(
            json.dumps(
                {"schema_version": 1, "command": "matrix", "data": {"cells": cells}},
                separators=(",", ":"),
            )
            + "\n"
        )
    else:
        for r in reports:
            marker = "unqualified" if not r.claimed else r.state.value
            sys.stdout.write(f"{r.backend} {r.platform} {marker}\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.subcommand == "run":
        return _cmd_run(args)
    return _cmd_matrix(args)


if __name__ == "__main__":
    raise SystemExit(main())
