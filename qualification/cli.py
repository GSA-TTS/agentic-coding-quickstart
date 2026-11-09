"""CLI for the qualification harness (``python -m qualification``).

Two subcommands:

``run`` — drive one cell and emit the verbatim ``RESULT`` signature line plus a
machine-readable ``OUTCOME`` disposition line. Offline-testable by pointing
``--`` + a command at a fake backend (e.g. ``python -c "exit 1"``).

``matrix`` — print every cell's state from the committed ledger: ``qualified``,
``waived`` or ``blocked`` for a claimed cell (the release gate's verdict), or
``unqualified`` for a cell that is not claimed.

The harness is Tier-3 tooling, not CLI code; the live run is its downstream
consumer. Exit codes: 0 PASS, 1 FAIL, 2 BLOCKED, 3 FLAKY (escalation).
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from .matrix import MSB, PLATFORMS, SBX, is_claimed
from .model import Environment, canonical_transcript_bytes, format_result_line
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
    run_p.add_argument("--attempts", type=_positive_int, default=3)
    run_p.add_argument("--timeout", type=_ascii_float, default=120.0)
    run_p.add_argument("command", nargs=argparse.REMAINDER)

    matrix_p = sub.add_parser("matrix", help="print the qualification matrix from the ledger")
    matrix_p.add_argument("--json", action="store_true")
    matrix_p.add_argument("--ledger", default="docs/qualification-ledger.json")
    return parser


def _ascii_float(text: str) -> float:
    # float() also accepts other scripts' digits ("\u0661\u0662"); refuse them.
    if not text.isascii():
        raise argparse.ArgumentTypeError(f"must be a number written in ASCII digits, got {text!r}")
    try:
        return float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"must be a number, got {text!r}") from None


def _positive_int(text: str) -> int:
    try:
        # int() also accepts other scripts' digits; only ASCII ones count.
        value = int(text) if text.isascii() else 0
    except ValueError:
        value = 0
    if value < 1:
        raise argparse.ArgumentTypeError(f"must be a whole number >= 1, got {text!r}")
    return value


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
        # Bytes, in the one canonical form: these exact bytes are hashed into the
        # ledger and shown in the ledger PR, so a reviewer can reproduce the hash.
        (transcript_dir / "transcript.json").write_bytes(
            canonical_transcript_bytes(transcript_document(result))
        )

    return exit_code_for(result.outcome)


def _cmd_matrix(args: argparse.Namespace) -> int:
    # The gate reads the ledger and git; imported here so ``run`` never needs either.
    from .gate import evaluate
    from .ledger import LedgerError, load_ledger

    try:
        ledger = load_ledger(args.ledger)
    except LedgerError as exc:
        sys.stderr.write(f"qualification matrix: {exc}\n")
        return 2
    claimed = {(s.backend, s.platform): s for s in evaluate(ledger, now=datetime.now(timezone.utc))}
    cells = []
    for backend in (MSB, SBX):
        for platform in PLATFORMS:
            status = claimed.get((backend, platform))
            cells.append({
                "backend": backend,
                "platform": platform,
                "claimed": status is not None,
                "state": status.status if status else "unqualified",
                "reason": status.reason if status else "",
            })
    if args.json:
        sys.stdout.write(
            json.dumps(
                {"schema_version": 1, "command": "matrix", "data": {"cells": cells}},
                separators=(",", ":"),
            )
            + "\n"
        )
    else:
        for c in cells:
            detail = f" ({c['reason']})" if c["reason"] else ""
            sys.stdout.write(f"{c['backend']} {c['platform']} {c['state']}{detail}\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.subcommand == "run":
        return _cmd_run(args)
    return _cmd_matrix(args)


if __name__ == "__main__":
    raise SystemExit(main())
