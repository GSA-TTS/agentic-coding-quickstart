"""The qualified/unqualified/blocked matrix (ADR-0044m).

The ADR claims a specific set of platform/backend cells; every other cell is
unqualified (not claimed). Windows ARM64 and musl are explicitly unqualified.
Each cell is in exactly one of three states: ``qualified`` (green current
transcript), ``unqualified`` (not claimed), or ``blocked`` (attempted, no green
verdict — this holds the release gate). "Current" is age, backend minor version,
and Tier-3 surface changes — not the commit SHA (see :func:`is_current`).

The report is a pure function of the transcripts it is handed, so it is testable
offline with fake transcripts and never fabricates a live result.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta
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


# A transcript stays current for this long: the quarterly re-verification cadence
# (AGENTS.md "Periodic Re-Verification").
MAX_AGE_DAYS = 90

# The Tier-3 surface: what a live run actually exercises. A change to any of these
# after a transcript was recorded makes it stale; a release-only commit (version
# bump, changelog, docs, tests, CI) does not. The harness entries are the run
# path only (the ``run`` command, its model, runner and reproduction rule): the
# matrix, ledger and gate read transcripts and do not affect a run, so editing
# them must not expire the evidence they evaluate. Narrow or widen this list when
# the oracle's reach changes. The default image is a mutable tag, so an upstream
# image change is bounded only by the age limit.
#
# The ``acq_py`` entries are a whitelist of the *contract-bearing* modules the
# live oracle (``scripts/qualify-backend-cell``: create/ls/exec/rm, secret,
# provider-credential) actually exercises, rather than the whole package. These
# modules are deliberately OFF the surface (no oracle asserts their behaviour):
# ``__init__.py`` (the package version constant — a version bump is release-only),
# ``version_info.py`` (the ``version`` command's data + output, owned end to end
# after ADR-0044m's split of ``run_version`` out of ``cli.py``), ``doctor.py``
# and ``runtime.py`` (``acq doctor``, reached only through ``doctor.py``), and
# ``_stub_*.py`` (deterministic test-only backends, not the real CLI the oracle
# drives). ``test_every_acq_py_module_is_classified_as_surface_or_off_surface``
# asserts every ``acq_py/*.py`` file is classified one way or the other, so a new
# module cannot silently fall off the surface.
TIER3_SURFACE = (
    "py-acq/src/acq_py/__main__.py",
    "py-acq/src/acq_py/backends.py",
    "py-acq/src/acq_py/cli.py",
    "py-acq/src/acq_py/config.py",
    "py-acq/src/acq_py/envelope.py",
    "py-acq/src/acq_py/errors.py",
    "py-acq/src/acq_py/kits.py",
    "py-acq/src/acq_py/lock.py",
    "py-acq/src/acq_py/migration.py",
    "py-acq/src/acq_py/msb.py",
    "py-acq/src/acq_py/provider_creds.py",
    "py-acq/src/acq_py/sbx.py",
    "py-acq/src/acq_py/security.py",
    "py-acq/src/acq_py/state.py",
    "scripts/qualify-backend-cell",
    "scripts/qualify-msb-ro-mount",
    "qualification/__init__.py",
    "qualification/__main__.py",
    "qualification/cli.py",
    "qualification/model.py",
    "qualification/runner.py",
    "qualification/repro.py",
)


def touches_surface(changed_paths) -> bool:
    """Whether any changed path (repo-relative, ``/``-separated) is on the Tier-3 surface."""
    return any(
        path == entry or (entry.endswith("/") and path.startswith(entry))
        for path in changed_paths
        for entry in TIER3_SURFACE
    )


_FINAL_VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def _minor(version: str) -> tuple[str, str] | None:
    """``(major, minor)`` of a final ``X.Y.Z`` version, else ``None``.

    Anything else (``unknown``, a pre-release such as ``0.7.7-rc1``, build
    metadata, a prefixed string) is unparseable and therefore never matches.
    """
    match = _FINAL_VERSION.fullmatch(version)
    return (str(int(match[1])), str(int(match[2]))) if match else None


def same_minor(a: str, b: str) -> bool:
    """Whether two final ``X.Y.Z`` versions share ``major.minor`` (unparseable never does)."""
    left = _minor(a)
    return left is not None and left == _minor(b)


def staleness(
    transcript: Transcript,
    *,
    now: datetime,
    backend_version: str | None = None,
    surface_changed: bool = False,
    max_age_days: int = MAX_AGE_DAYS,
) -> str | None:
    """Why a transcript no longer counts as current, or ``None`` when it does.

    It is current while all hold: it was recorded within ``max_age_days`` (and not
    in the future); its backend ``major.minor`` matches ``backend_version``, the
    final ``X.Y.Z`` version under acceptance (patch releases do not expire it,
    ``None`` skips the check, and an unparseable version on either side fails
    closed); and no Tier-3 surface change landed after it. ``surface_changed`` is
    computed by the caller for this transcript: the changes since the transcript's
    recorded ``rev`` (see :func:`touches_surface`). The artifact SHA-256 is
    provenance only. An unknown or naive ``recorded_at`` is never current.
    ``now`` must be timezone-aware.
    """
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    try:
        recorded = datetime.fromisoformat(transcript.recorded_at)
    except ValueError:
        return "recorded_at is missing or unparseable"
    if recorded.tzinfo is None:
        return "recorded_at has no timezone"
    if recorded > now:
        return "recorded_at is in the future"
    if now - recorded > timedelta(days=max_age_days):
        return f"older than {max_age_days} days"
    if backend_version is not None:
        recorded_minor = _minor(transcript.environment.backend_version)
        if recorded_minor is None or recorded_minor != _minor(backend_version):
            return (
                f"recorded at backend {transcript.environment.backend_version}, "
                f"accepted version is {backend_version}"
            )
    if surface_changed:
        return "the Tier-3 surface changed after it was recorded"
    return None


def is_current(transcript: Transcript, **kwargs) -> bool:
    """Whether a transcript still counts as current evidence (see :func:`staleness`)."""
    return staleness(transcript, **kwargs) is None


def cell_state(
    backend: str,
    platform: str,
    *,
    transcript: Transcript | None,
    now: datetime,
    backend_version: str | None = None,
    surface_changed: bool = False,
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
        and is_current(
            transcript, now=now, backend_version=backend_version, surface_changed=surface_changed
        )
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
    now: datetime,
    backend_versions: Mapping[str, str] | None = None,
    surface_changed: bool = False,
) -> list[CellReport]:
    """The full matrix report, one ``CellReport`` per backend x platform cell.

    ``transcripts`` maps ``(backend, platform)`` to the cell's latest transcript;
    missing cells report blocked (claimed) or unqualified (unclaimed).
    ``backend_versions`` maps a backend to the version under acceptance.
    """
    transcripts = transcripts or {}
    backend_versions = backend_versions or {}
    reports: list[CellReport] = []
    for backend in (MSB, SBX):
        for platform in PLATFORMS:
            reports.append(
                CellReport(
                    backend=backend,
                    platform=platform,
                    claimed=is_claimed(backend, platform),
                    state=cell_state(
                        backend,
                        platform,
                        transcript=transcripts.get((backend, platform)),
                        now=now,
                        backend_version=backend_versions.get(backend),
                        surface_changed=surface_changed,
                    ),
                )
            )
    return reports
