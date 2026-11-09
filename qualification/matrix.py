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
        "windows-x64",
    }),
    SBX: frozenset({
        "linux-x86_64",
        "macos-arm64",
        "windows-x64",
    }),
}

# Version floors (ADR-0044m). msb also refuses 0.7.0..0.7.2 (oracles 1-3 require
# >= 0.7.7); sbx requires >= 0.39.0. The cell oracle exercises oracles 1-3, so a
# Tier-3 run is evidence only at or above ``ORACLE_FLOORS`` as well. The gate blocks
# a cell whose entry or accepted version fails :func:`version_problem`, the ledger
# refuses to accept such a version, and ``qualification.host`` refuses to run on one.
VERSION_FLOORS = {
    MSB: "0.6.9",
    SBX: "0.39.0",
}
MSB_REFUSED_RANGE = ("0.7.0", "0.7.2")
ORACLE_FLOORS = {
    MSB: "0.7.7",
}


def _version_tuple(version: str) -> tuple[int, int, int] | None:
    # ASCII digits only: ``\d`` also matches other scripts' digits, which int() accepts.
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)", version)
    return (int(match[1]), int(match[2]), int(match[3])) if match else None


def version_problem(backend: str, version: str) -> str | None:
    """Why ``version`` of ``backend`` cannot carry Tier-3 evidence (ADR-0044m floors), or ``None``."""
    found = _version_tuple(version)
    if found is None:
        return f"{backend} {version!r} is not a final X.Y.Z version"
    floor = VERSION_FLOORS.get(backend)
    if floor and found < _version_tuple(floor):
        return f"{backend} {version} is below the supported floor {floor}"
    if backend == MSB and _version_tuple(MSB_REFUSED_RANGE[0]) <= found <= _version_tuple(MSB_REFUSED_RANGE[1]):
        return f"msb {version} is in the refused range {MSB_REFUSED_RANGE[0]}-{MSB_REFUSED_RANGE[1]}"
    oracle = ORACLE_FLOORS.get(backend)
    if oracle and found < _version_tuple(oracle):
        return f"{backend} {version} is below {oracle}, which oracles 1-3 need"
    return None


def is_claimed(backend: str, platform: str) -> bool:
    """Whether ``backend`` on ``platform`` is a claimed (qualified) cell."""
    return platform in QUALIFIED.get(backend, frozenset())


# What a host in each cell reports as its harness ``arch`` and ``hypervisor``
# (``qualification.host.detect_host`` sets the hypervisor from the OS: hvf on macOS,
# wsl2 on Windows, kvm on Linux). A ledger entry whose recorded arch or hypervisor is
# not one of its cell's is evidence from a different host, so it qualifies nothing:
# one run cannot stand for two cells.
PLATFORM_HOSTS = {
    "linux-x86_64": (frozenset({"x86_64"}), frozenset({"kvm"})),
    "linux-aarch64": (frozenset({"aarch64", "arm64"}), frozenset({"kvm"})),
    "linux-musl": (frozenset({"x86_64", "aarch64", "arm64"}), frozenset({"kvm"})),
    "macos-arm64": (frozenset({"arm64"}), frozenset({"hvf"})),
    "macos-x86_64": (frozenset({"x86_64"}), frozenset({"hvf"})),
    "windows-x64": (frozenset({"x86_64", "AMD64"}), frozenset({"wsl2"})),
    "windows-arm64": (frozenset({"arm64", "ARM64", "aarch64"}), frozenset({"wsl2"})),
}


def host_mismatch(platform: str, arch: str, hypervisor: str) -> str | None:
    """Why a run on ``arch``/``hypervisor`` cannot be evidence for ``platform``, or ``None``."""
    arches, hypervisors = PLATFORM_HOSTS.get(platform, (frozenset(), frozenset()))
    if arch not in arches:
        return f"arch {arch!r} is not a {platform} host"
    if hypervisor not in hypervisors:
        return f"hypervisor {hypervisor!r} is not a {platform} host"
    return None


# The committed cell oracle, repo-relative. A ledger entry counts only if the run it
# records executed exactly ``<python> CELL_ORACLE --backend <backend>`` and the entry
# carries the SHA-256 of that file as committed at the recorded revision (see
# ``qualification.ledger``). It is on the Tier-3 surface, so a change to it after a
# run also expires the run.
CELL_ORACLE = "scripts/qualify-backend-cell"


# A transcript stays current for this long: the quarterly re-verification cadence
# (AGENTS.md "Periodic Re-Verification").
MAX_AGE_DAYS = 90

# The Tier-3 surface: what a live run actually exercises. A change to any of these
# after a transcript was recorded makes it stale; a release-only commit (version
# bump, changelog, docs, tests, CI) does not. The harness entries are the run
# path only (the ``run`` command, its model, runner and reproduction rule): the
# matrix, ledger and gate read transcripts and do not affect a run, so editing
# them must not expire the evidence they evaluate. Being off the surface does not
# let a change loosen them for itself: on a pull request CI runs the gate from the
# base branch (see ``qualification.gate``), so this list and its exclusions are
# always the ones already on ``main``. Narrow or widen this list when
# the oracle's reach changes. The default image is a mutable tag, so an upstream
# image change is bounded only by the age limit.
#
# The CLI is on the surface as a whole *directory* prefix, not a whitelist: a
# trailing-slash entry matches every path under it, so a new module, subpackage,
# or data file under ``py-acq/src/acq_py/`` defaults to ON-surface (the gate's
# "fails closed" posture — anything it cannot establish as excluded stays
# surface). The exclusions below carve out the modules no committed oracle
# asserts AND that are genuinely unreachable from the oracle's commands, so a
# break there affects only the non-contract commands they serve. The ``version``
# command is off-surface: its data assembly and human/JSON output live together
# in ``version_info.py`` (``run_version`` was split out of ``cli.py``), and
# ``cli.py`` imports it lazily, so a version-output-only change touches only
# ``version_info.py`` and never the surface.
TIER3_SURFACE = (
    "py-acq/src/acq_py/",
    "scripts/qualify-backend-cell",
    "scripts/qualify-msb-ro-mount",
    "qualification/__init__.py",
    "qualification/__main__.py",
    "qualification/cli.py",
    "qualification/model.py",
    "qualification/runner.py",
    "qualification/repro.py",
)

# Modules under ``py-acq/src/acq_py/`` that are OFF the surface. To be here a
# module must satisfy BOTH:
#   (a) no committed oracle asserts its behaviour — of ADR-0044m's six oracles,
#       the two committed ones are the cell oracle (boot contract + secret/
#       provider-credential non-exposure) and the ro-mount oracle; #4 (offline
#       completeness) is deferred and #5 (security-exception recreation) is a
#       manual sequence, neither of which drives ``acq version``/``acq doctor``;
#   (b) it is genuinely unreachable from the oracle's commands — ``cli.py`` must
#       NOT import it at startup, or a break there would kill create/ls/exec/rm/
#       secret/provider-credential while ``touches_surface`` says False.
# ``test_off_surface_modules_are_not_loaded_by_cli`` enforces (b) by asserting
# importing ``acq_py.cli`` loads none of these.
TIER3_SURFACE_EXCLUSIONS = (
    "py-acq/src/acq_py/version_info.py",  # `acq version` data + output (lazy import)
    "py-acq/src/acq_py/doctor.py",        # `acq doctor` (lazy import)
    "py-acq/src/acq_py/runtime.py",       # managed-runtime resolution (only via doctor)
    "py-acq/src/acq_py/_stub_msb.py",     # deterministic test backend (subprocess-only)
    "py-acq/src/acq_py/_stub_sbx.py",     # deterministic test backend (subprocess-only)
)


def touches_surface(changed_paths) -> bool:
    """Whether any changed path (repo-relative, ``/``-separated) is on the Tier-3 surface.

    A path is on the surface when it matches an entry (a trailing-slash entry
    matches everything under that directory) and is not carved out by an
    exclusion. Directory entries make the surface fail CLOSED: a new file under
    an entry defaults to on-surface.
    """
    for path in changed_paths:
        if not any(
            path == entry or (entry.endswith("/") and path.startswith(entry))
            for entry in TIER3_SURFACE
        ):
            continue
        if any(
            path == excl or (excl.endswith("/") and path.startswith(excl))
            for excl in TIER3_SURFACE_EXCLUSIONS
        ):
            continue
        return True
    return False


_FINAL_VERSION = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)")


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
    transcript recorded at, and accepted at, a backend version that meets the
    floors (:func:`version_problem`); otherwise blocked (holds the gate).
    """
    if not is_claimed(backend, platform):
        return MatrixState.UNQUALIFIED
    if (
        transcript is not None
        and transcript.verdict is Verdict.PASS
        and version_problem(backend, transcript.environment.backend_version) is None
        and (backend_version is None or version_problem(backend, backend_version) is None)
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
