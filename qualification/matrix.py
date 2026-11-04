"""The qualified/unqualified/blocked matrix (ADR-0044m).

The ADR claims a specific set of platform/backend cells; every other cell is
unqualified (not claimed). Windows ARM64 and musl are explicitly unqualified.
Each cell is in exactly one of three states: ``qualified`` (green current
transcript), ``unqualified`` (not claimed), or ``blocked`` (attempted, no green
verdict — this holds the release gate).

The report is a pure function of the transcripts it is handed, so it is testable
offline with fake transcripts and never fabricates a live result.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Mapping

from .model import Transcript, Verdict

MSB = "msb"
SBX = "sbx"


class MatrixState(str, Enum):
    QUALIFIED = "qualified"
    UNQUALIFIED = "unqualified"
    BLOCKED = "blocked"


# Platform cells. ``linux-musl`` (musl libc) and ``windows-arm64`` are
# explicitly unqualified for every backend (ADR-0044m; spec §Out of scope).
PLATFORMS = (
    "linux-x86_64",
    "linux-aarch64",
    "linux-musl",
    "macos-arm64",
    "macos-x86_64",
    "windows-x64",
    "windows-arm64",
)

# The claimed (qualified) cells: backend -> {platform, ...}. Any cell NOT listed
# here is unqualified (not claimed) and is reported honestly, never silently.
QUALIFIED = {
    MSB: frozenset({
        "linux-x86_64",
        "linux-aarch64",
        "macos-arm64",
        "macos-x86_64",
        "windows-x64",
    }),
    SBX: frozenset({
        "linux-x86_64",
        "macos-arm64",
        "windows-x64",
    }),
}

# Version floors (ADR-0044m). msb also refuses 0.7.0..0.7.2 (oracles 1-3 require
# >= 0.7.7); sbx requires >= 0.39.0.
VERSION_FLOORS = {
    MSB: "0.6.9",
    SBX: "0.39.0",
}
MSB_REFUSED_RANGE = ("0.7.0", "0.7.2")


def is_claimed(backend: str, platform: str) -> bool:
    """Whether ``backend`` on ``platform`` is a claimed (qualified) cell."""
    return platform in QUALIFIED.get(backend, frozenset())


def is_current(transcript: Transcript, *, rev: str, artifact_sha256: str) -> bool:
    """A transcript is current iff its recorded identity matches the artifact
    under acceptance (ADR-0044m staleness: rev and artifact SHA must match)."""
    env = transcript.environment
    return env.rev == rev and env.artifact_sha256 == artifact_sha256


def cell_state(
    backend: str,
    platform: str,
    *,
    transcript: Transcript | None,
    rev: str,
    artifact_sha256: str,
) -> MatrixState:
    """The matrix state of one cell.

    Unclaimed cells are unqualified (honest reporting — never claimed, never a
    pass). A claimed cell is qualified only when it holds a green *current*
    transcript; otherwise blocked (no green verdict — holds the gate).
    """
    if not is_claimed(backend, platform):
        return MatrixState.UNQUALIFIED
    if (
        transcript is not None
        and transcript.verdict is Verdict.PASS
        and is_current(transcript, rev=rev, artifact_sha256=artifact_sha256)
    ):
        return MatrixState.QUALIFIED
    return MatrixState.BLOCKED


@dataclass(frozen=True)
class CellReport:
    backend: str
    platform: str
    claimed: bool
    state: MatrixState


def report_matrix(
    transcripts: Mapping[tuple[str, str], Transcript] | None = None,
    *,
    rev: str,
    artifact_sha256: str,
) -> list[CellReport]:
    """The full matrix report, one ``CellReport`` per backend x platform cell.

    ``transcripts`` maps ``(backend, platform)`` to the cell's current transcript;
    missing cells report blocked (claimed) or unqualified (unclaimed).
    """
    transcripts = transcripts or {}
    reports: list[CellReport] = []
    for backend in (MSB, SBX):
        for platform in PLATFORMS:
            transcript = transcripts.get((backend, platform))
            reports.append(
                CellReport(
                    backend=backend,
                    platform=platform,
                    claimed=is_claimed(backend, platform),
                    state=cell_state(
                        backend,
                        platform,
                        transcript=transcript,
                        rev=rev,
                        artifact_sha256=artifact_sha256,
                    ),
                )
            )
    return reports
