"""Backend detection and version-floor checking (ADR-0040m read side).

This module is the read half of the transport-neutral adapter seam: it discovers
the SBX and MSB sandbox backends, reports their installed state and detected
version, and enforces the version floor *fail closed* before any mutating verb
runs (ADR-0038m: "unsupported/unparseable backend versions fail before
mutation"). It never mutates host or backend state itself.

Version floors follow the ADR-0044m qualified matrix:

    * sbx  >= 0.39.0
    * msb  >= 0.6.9, refusing 0.7.0-0.7.2 (one-way state migration; ADR-0032),
      and only final releases (no prerelease/build suffix).

Detection and the reported version are overridable via environment variables for
reproducible, offline contract vectors (the same convention ``version_info.py``
uses for ``ACQ_VERSION``/``ACQ_SOURCE_REVISION``):

    * ``ACQ_SBX_INSTALLED`` / ``ACQ_MSB_INSTALLED`` - ``"1"`` or ``"0"`` forces
      the installed state, skipping the PATH lookup.
    * ``ACQ_SBX_VERSION`` / ``ACQ_MSB_VERSION`` - forces the version string the
      backend CLI would report (implies ``installed`` unless the explicit
      ``INSTALLED`` override says otherwise).

These overrides are an internal test seam, not part of the public ``acq``
command/contract surface: they exist only so contract vectors can run
deterministically and offline. They are never secrets and are never written to
output.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass

from . import errors, hostexec

# Version floors (ADR-0044m). Represented as (major, minor, patch) triples.
SBX_MIN_VERSION = (0, 39, 0)
MSB_MIN_VERSION = (0, 6, 9)
MSB_BLOCKED_MIN = (0, 7, 0)
MSB_BLOCKED_MAX = (0, 7, 2)

# A version token: optional leading `v`, X.Y (patch optional), and an optional
# `-prerelease` / `+build` suffix. The suffix is captured so `final` can be
# decided (msb refuses non-final releases); the numeric core is what the floor
# and blocked-range comparisons use.
_VERSION_RE = re.compile(r"v?(\d+)\.(\d+)(?:\.(\d+))?([-+][^\s]*)?")


@dataclass(frozen=True)
class Version:
    """A parsed backend version.

    ``final`` is False when the reported token carried a ``-``/``+`` suffix
    (a prerelease or build); only msb treats non-final as unsupported. The
    numeric core is what ordering uses; ``final`` never affects ordering.
    """

    major: int
    minor: int
    patch: int
    final: bool

    @property
    def string(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


def parse_version(raw: str) -> Version | None:
    """Parse a version string into a :class:`Version`, or None if unparseable.

    Only final releases carry ``final=True``. The ``v`` prefix and any
    prerelease/build suffix are dropped from the reported numeric core.
    """
    if not raw:
        return None
    match = _VERSION_RE.search(raw)
    if match is None:
        return None
    major = int(match.group(1))
    minor = int(match.group(2))
    patch = int(match.group(3) or 0)
    final = match.group(4) is None
    return Version(major, minor, patch, final)


def _core(v: Version) -> tuple[int, int, int]:
    return (v.major, v.minor, v.patch)


def version_ge(a: Version, b: Version) -> bool:
    """True when ``a`` is numerically at least ``b`` (ignoring ``final``)."""
    return _core(a) >= _core(b)


@dataclass(frozen=True)
class BackendSpec:
    """Static declaration for one adapter's read-side obligations.

    ``version_argv`` is the CLI invocation that reports the version, e.g.
    ``sbx version`` or ``msb --version``. ``require_final`` marks backends (msb)
    that refuse prerelease/build-suffixed versions.
    """

    name: str
    cli: str
    version_argv: tuple[str, ...]
    min_version: Version
    blocked_min: Version | None
    blocked_max: Version | None
    require_final: bool


BACKENDS: dict[str, BackendSpec] = {
    "sbx": BackendSpec(
        name="sbx",
        cli="sbx",
        version_argv=("version",),
        min_version=Version(*SBX_MIN_VERSION, True),
        blocked_min=None,
        blocked_max=None,
        require_final=False,
    ),
    "msb": BackendSpec(
        name="msb",
        cli="msb",
        version_argv=("--version",),
        min_version=Version(*MSB_MIN_VERSION, True),
        blocked_min=Version(*MSB_BLOCKED_MIN, True),
        blocked_max=Version(*MSB_BLOCKED_MAX, True),
        require_final=True,
    ),
}

# Deterministic reporting order (matches the legacy `acq backend list` order).
BACKEND_ORDER = ("sbx", "msb")

# Per-capability version floors (ADR-0040m §version floor). A capability listed
# here requires a NEWER backend than the global ``min_version``; requesting it on
# an older backend fails closed with ``backend_version_unsupported`` BEFORE the
# backend is invoked (the global floor is the base; these are additive).
CAPABILITY_FLOORS: dict[str, dict[str, Version]] = {
    "sbx": {
        # `sbx secret set-custom --value-stdin` landed in sbx 0.51.0; a
        # provider-credential value can only reach sbx safely (stdin, never
        # argv) from that release.
        "provider-credential-set": Version(0, 51, 0, True),
    },
    "msb": {},
}


@dataclass(frozen=True)
class BackendStatus:
    """Detected state of one backend.

    ``version`` is the reported string: the numeric core (``"X.Y.Z"``) when
    parseable, ``"unknown"`` when installed but unparseable, and ``None`` when
    not installed. ``parsed`` carries the structured version for the floor check
    (``None`` when there is nothing parseable).
    """

    name: str
    installed: bool
    version: str | None
    parsed: Version | None


@dataclass(frozen=True)
class VersionProblem:
    """A fail-closed version-floor refusal (ADR-0040m error vocabulary)."""

    code: str
    message: str
    remediation: str | None = None


def _env(name: str, key: str) -> str | None:
    return os.environ.get(f"ACQ_{name.upper()}_{key}")


def _is_installed(spec: BackendSpec) -> bool:
    override = _env(spec.name, "INSTALLED")
    if override is not None:
        return override == "1"
    if _env(spec.name, "VERSION") is not None:
        return True
    return hostexec.which(spec.cli) is not None


def _run_version_command(spec: BackendSpec) -> str | None:
    try:
        proc = subprocess.run(
            [*hostexec.command(spec.cli), *spec.version_argv],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def _detected_version(spec: BackendSpec) -> Version | None:
    forced = _env(spec.name, "VERSION")
    if forced is not None:
        return parse_version(forced)
    return parse_version(_run_version_command(spec) or "")


def detect(spec: BackendSpec) -> BackendStatus:
    """Discover one backend's installed state and version (read-only)."""
    if not _is_installed(spec):
        return BackendStatus(spec.name, False, None, None)
    parsed = _detected_version(spec)
    if parsed is None:
        return BackendStatus(spec.name, True, "unknown", None)
    return BackendStatus(spec.name, True, parsed.string, parsed)


def detect_all() -> list[BackendStatus]:
    """Discover every known backend in deterministic order."""
    return [detect(BACKENDS[name]) for name in BACKEND_ORDER]


def check_version(spec: BackendSpec) -> VersionProblem | None:
    """Enforce the version floor for one backend, fail closed (ADR-0040m).

    Returns ``None`` when the backend is installed and supported, else a
    :class:`VersionProblem` carrying a stable error code. No mutation occurs.
    """
    status = detect(spec)
    if not status.installed:
        return VersionProblem(
            errors.BACKEND_NOT_FOUND,
            f"backend '{spec.name}' CLI not found on PATH",
            f"install {spec.name} {spec.min_version.string} or newer and retry",
        )
    if status.parsed is None:
        return VersionProblem(
            errors.BACKEND_VERSION_UNKNOWN,
            f"could not determine a supported {spec.name} version",
            f"ensure '{spec.cli} {' '.join(spec.version_argv)}' reports a "
            f"{spec.name} release and retry",
        )
    parsed = status.parsed
    if not version_ge(parsed, spec.min_version):
        return VersionProblem(
            errors.BACKEND_VERSION_UNSUPPORTED,
            f"acq requires {spec.name} >= {spec.min_version.string}, but found "
            f"{parsed.string}",
            f"upgrade {spec.name} to {spec.min_version.string} or newer and retry",
        )
    if spec.blocked_min is not None and spec.blocked_max is not None:
        if version_ge(parsed, spec.blocked_min) and version_ge(spec.blocked_max, parsed):
            return VersionProblem(
                errors.BACKEND_VERSION_UNSUPPORTED,
                f"acq refuses {spec.name} {parsed.string} (blocked range "
                f"{spec.blocked_min.string}-{spec.blocked_max.string})",
                "move forward to the fixed release or roll back per the "
                "backend guide",
            )
    if spec.require_final and not parsed.final:
        return VersionProblem(
            errors.BACKEND_VERSION_UNSUPPORTED,
            f"acq requires a final {spec.name} release, but found a prerelease "
            f"or build ({parsed.string})",
            f"install a final {spec.name} release and retry",
        )
    return None


def check_capability_floor(spec: BackendSpec, capability: str) -> VersionProblem | None:
    """Enforce a per-capability version floor, fail closed (ADR-0040m).

    Returns ``None`` when the capability has no floor, the backend is absent or
    its version is unknown (the global ``check_version`` floor already refuses
    those before this is called), or the detected version meets the floor; else a
    :class:`VersionProblem` carrying ``backend_version_unsupported`` and a clear
    remediation. No mutation occurs.
    """
    floor = CAPABILITY_FLOORS.get(spec.name, {}).get(capability)
    if floor is None:
        return None
    status = detect(spec)
    if status.parsed is None:
        return None  # absent/unknown is the global floor's refusal, not this one
    if version_ge(status.parsed, floor):
        return None
    return VersionProblem(
        errors.BACKEND_VERSION_UNSUPPORTED,
        f"acq requires {spec.name} >= {floor.string} for '{capability}', "
        f"but found {status.parsed.string}",
        f"upgrade {spec.name} to {floor.string} or newer and retry",
    )
