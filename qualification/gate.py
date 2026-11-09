"""The Tier-3 release gate and ledger recorder (ADR-0044m).

``python -m qualification.gate check`` decides, from the committed ledger alone,
whether every claimed cell holds a current green transcript, so a release can be
evaluated on a hosted runner with no live run. ``record`` turns a run's
``transcript.json`` into a ledger entry. ``verify-evidence`` checks the transcripts
a ledger PR body inlines against the ledger (each block's SHA-256 must be a
recorded ``transcript_sha256`` whose entry the block reproduces; with ``--base``,
every entry added since that revision needs exactly one such block, and none may
be hidden in an HTML comment), so a reviewer can audit a ledger PR without the
runner's files.

A claimed cell is ``qualified`` (current green transcript), ``waived`` (an
unexpired maintainer waiver in the ledger), or ``blocked``. The gate passes iff
no claimed cell is blocked. Anything it cannot establish fails closed: a
missing accepted backend version, a revision git does not know, a malformed
ledger.

Exit codes: 0 gate passes, 1 a cell is blocked, 2 the ledger or input is
unusable.

Each entry must also be consistent with the repository
(:func:`qualification.ledger.binding_problem`): it names the committed cell oracle,
its ``oracle_sha256`` matches that file as committed at its ``rev``, and its arch and
hypervisor are a host of its cell. The gate never sees transcripts, so it cannot
tell whether a run really executed the oracle (``record`` checks that, locally).

The ledger is self-reported and committed: beyond those checks its integrity is a
review control (CODEOWNERS on the ledger file), not a technical one.
``transcript_sha256`` helps that review because the ledger PR inlines each
transcript byte for byte; ``verify-evidence`` recomputes it from the PR body. An
entry, or the accepted version, below the ADR-0044m version floors blocks its cell
(:func:`qualification.matrix.version_problem`). A recorded ``rev`` must be an ancestor of the commit the gate
evaluates (otherwise the cell is blocked), so record a run at a commit that is on
``main`` (a squash-merged branch commit is not).

The rules this module applies (the claimed cells, the Tier-3 surface and its
carve-outs, the entry checks) live in this package, so they must not come from the
change under test: on a pull request the ``Tier-3 release gate`` workflow runs this
package from the base branch against the PR's ledger and history (``python -P`` with
``PYTHONPATH`` at a base-branch worktree). A PR therefore cannot loosen the rules it
is judged by; loosening them takes a PR of its own, which CODEOWNERS sends to an
admin.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

from .ledger import (
    DEFAULT_LEDGER,
    Ledger,
    LedgerError,
    append_entry,
    OracleDigest,
    binding_problem,
    audit_evidence,
    entry_from_transcript,
    evidence_blocks,
    parse_ledger,
    git_oracle_digest,
    latest_entry,
    load_ledger,
)
from .matrix import MSB, PLATFORMS, SBX, is_claimed, staleness, touches_surface, version_problem
from .model import Environment, Transcript, Verdict

_REV = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")

ChangedPaths = Callable[[str], "Iterable[str] | None"]


@dataclass(frozen=True)
class CellStatus:
    backend: str
    platform: str
    status: str  # qualified | waived | blocked
    reason: str = ""


def git_changed_paths(rev: str, cwd=None) -> list[str] | None:
    """Paths changed from ``rev`` to ``HEAD``; ``None`` if git cannot say.

    ``rev`` must be a full commit id that is an ancestor of ``HEAD``: a commit off
    the evaluated history (a dropped branch, another fork's PR) is not evidence for it.
    """
    if not _REV.fullmatch(rev):
        return None
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", rev, "HEAD"], capture_output=True, cwd=cwd)
    if ancestor.returncode != 0:
        return None
    # --no-renames lists both sides of a move (a file moved out of the surface must
    # still count); -z and quotePath=false avoid git's quoting of non-ASCII paths.
    proc = subprocess.run(
        ["git", "-c", "core.quotePath=false", "diff", "--name-only", "--no-renames", "-z", rev, "HEAD", "--"],
        capture_output=True,
        cwd=cwd,
    )
    if proc.returncode != 0:
        return None
    return [p for p in proc.stdout.decode("utf-8", "surrogateescape").split("\0") if p]


def _transcript_of(entry) -> Transcript:
    env = Environment(
        os=entry.platform,
        os_build=entry.os_build,
        arch=entry.arch,
        hypervisor=entry.hypervisor,
        backend=entry.backend,
        backend_version=entry.backend_version,
        image="",
        rev=entry.rev,
        artifact_sha256=entry.artifact_sha256,
        transcript_dir="",
    )
    return Transcript(Verdict.PASS, env, (), "", "", entry.recorded_at)


def _why_not_current(
    ledger: Ledger, entry, now: datetime, changed_paths: ChangedPaths, oracle_digest: OracleDigest
) -> str | None:
    if entry is None:
        return "no transcript recorded"
    if entry.verdict != "PASS":
        return f"latest transcript is {entry.verdict}"
    problem = binding_problem(entry, oracle_digest, now)
    if problem:
        return problem
    version = ledger.accepted_backend_versions.get(entry.backend)
    if version is None:
        return f"accepted_backend_versions has no entry for {entry.backend}"
    # The ADR-0044m floors and the msb refused range: a run on such a version is not
    # evidence, and accepting such a version cannot make one current.
    for which, candidate in (("recorded", entry.backend_version), ("accepted", version)):
        floor = version_problem(entry.backend, candidate)
        if floor:
            return f"{which} backend version: {floor}"
    paths = changed_paths(entry.rev)
    if paths is None:
        return f"revision {entry.rev[:12]} is not an ancestor of HEAD (record at a commit on main; fetch full history)"
    return staleness(
        _transcript_of(entry), now=now, backend_version=version, surface_changed=touches_surface(paths)
    )


def evaluate(
    ledger: Ledger,
    *,
    now: datetime,
    changed_paths: ChangedPaths = git_changed_paths,
    oracle_digest: OracleDigest = git_oracle_digest,
) -> list[CellStatus]:
    """The status of every claimed cell."""
    results: list[CellStatus] = []
    for backend in (MSB, SBX):
        for platform in PLATFORMS:
            if not is_claimed(backend, platform):
                continue
            entry = latest_entry(ledger, backend, platform)
            reason = _why_not_current(ledger, entry, now, changed_paths, oracle_digest)
            if reason is None:
                results.append(CellStatus(backend, platform, "qualified"))
                continue
            waiver = max(
                (w for w in ledger.waivers if (w.backend, w.platform) == (backend, platform)),
                key=lambda w: w.expires,
                default=None,
            )
            if waiver is None:
                results.append(CellStatus(backend, platform, "blocked", reason))
            elif waiver.expires < now.date():
                results.append(
                    CellStatus(backend, platform, "blocked", f"{reason}; waiver expired {waiver.expires}")
                )
            else:
                note = f"{reason}; waived until {waiver.expires}: {waiver.reason}"
                results.append(CellStatus(backend, platform, "waived", note))
    return results


def render(statuses: list[CellStatus]) -> str:
    lines = ["| backend | platform | status | detail |", "|---|---|---|---|"]
    lines += [
        f"| {s.backend} | {s.platform} | {s.status} | {s.reason.replace('|', '/').replace(chr(10), ' ')} |"
        for s in statuses
    ]
    blocked = sum(s.status == "blocked" for s in statuses)
    waived = sum(s.status == "waived" for s in statuses)
    lines.append("")
    lines.append(
        f"{len(statuses)} claimed cells: {len(statuses) - blocked - waived} qualified, "
        f"{waived} waived, {blocked} blocked. Gate {'FAILS' if blocked else 'passes'}."
    )
    return "\n".join(lines)


def _cmd_check(args: argparse.Namespace) -> int:
    ledger = load_ledger(args.ledger)
    statuses = evaluate(ledger, now=datetime.now(timezone.utc))
    if args.json:
        sys.stdout.write(json.dumps([s.__dict__ for s in statuses]) + "\n")
    else:
        sys.stdout.write(render(statuses) + "\n")
    return 1 if any(s.status == "blocked" for s in statuses) else 0


def _cmd_record(args: argparse.Namespace) -> int:
    with open(args.transcript, "rb") as handle:
        raw = handle.read()
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise LedgerError(f"{args.transcript} is not JSON: {exc}") from None
    entry = entry_from_transcript(doc, raw, platform=args.platform, recorded_at=args.recorded_at)
    append_entry(args.ledger, entry)
    sys.stdout.write(
        f"recorded {entry.verdict} {entry.backend}/{entry.platform} backend={entry.backend_version} "
        f"rev={entry.rev[:12]} in {args.ledger}\n"
    )
    return 0


def base_entries(ledger_path: str, rev: str, cwd=None) -> set[str]:
    """The ``transcript_sha256`` of every entry in the ledger as committed at ``rev``."""
    if not rev or rev.startswith("-"):
        raise LedgerError(f"--base {rev!r} is not a revision")
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, cwd=cwd)
    if top.returncode != 0:
        raise LedgerError("--base needs a git checkout")
    try:
        rel = Path(ledger_path).resolve().relative_to(Path(top.stdout.strip()).resolve()).as_posix()
    except ValueError:
        raise LedgerError(f"{ledger_path} is not inside the checkout, so it has no committed version") from None
    shown = subprocess.run(["git", "show", f"{rev}:{rel}"], capture_output=True, cwd=cwd)
    if shown.returncode != 0:
        raise LedgerError(f"cannot read {rel} at {rev}")
    return {e.transcript_sha256 for e in parse_ledger(json.loads(shown.stdout.decode("utf-8"))).entries}


def _cmd_verify_evidence(args: argparse.Namespace) -> int:
    ledger = load_ledger(args.ledger)
    required = None
    if args.base is not None:
        old = base_entries(args.ledger, args.base)
        required = [e for e in ledger.entries if e.transcript_sha256 not in old]
    if args.body == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(args.body, "rb") as handle:
            data = handle.read()
    blocks = evidence_blocks(data.decode("utf-8"))
    if not blocks and not required:
        if required is not None:
            sys.stdout.write("no entries added since the base, and no transcript blocks\n")
            return 0
        sys.stderr.write("qualification.gate: no ```json transcript blocks found\n")
        return 2
    results, problems = audit_evidence(ledger, blocks, required)
    for digest, problem in results:
        sys.stdout.write(f"{'MISMATCH' if problem else 'OK'} {digest}" + (f": {problem}" if problem else "") + "\n")
    for problem in problems:
        sys.stdout.write(problem + "\n")
    return 1 if problems or any(problem for _digest, problem in results) else 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="qualification.gate", description=__doc__.split("\n")[0])
    parser.add_argument("--ledger", default=DEFAULT_LEDGER)
    sub = parser.add_subparsers(dest="subcommand", required=True)
    check = sub.add_parser("check", help="evaluate the release gate from the ledger")
    check.add_argument("--json", action="store_true")
    record = sub.add_parser("record", help="append a run's transcript.json to the ledger")
    record.add_argument("transcript")
    record.add_argument("--platform", default=None, help="matrix platform token (default: derived from os/arch)")
    record.add_argument("--recorded-at", default=None, help="ISO 8601 UTC time (default: from the transcript)")
    verify = sub.add_parser(
        "verify-evidence", help="check the transcripts a ledger PR body inlines against the ledger"
    )
    verify.add_argument("body", help="a file holding the PR body, or - for stdin")
    verify.add_argument(
        "--base", default=None,
        help="the PR's base revision: every entry added since it must have exactly one verifying block",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        commands = {"check": _cmd_check, "record": _cmd_record, "verify-evidence": _cmd_verify_evidence}
        return commands[args.subcommand](args)
    except (LedgerError, OSError, ValueError, TypeError, KeyError) as exc:
        sys.stderr.write(f"qualification.gate: {exc}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
