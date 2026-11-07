"""Version/identity assembly for ``acq version`` (ADR-0042m).

``version`` reports: ``impl`` (the implementation marker, always "python" here),
``acq_version`` (SemVer), ``source_revision`` (the baked release commit SHA),
nullable ``backend``/``backend_version``, and ``kit_control_plane_ref``.

The two baked values may be overridden via the ``ACQ_VERSION`` and
``ACQ_SOURCE_REVISION`` environment variables for reproducible builds/tests.
They are build-time overrides, never secrets. ``source_revision`` falls back to
``git rev-parse HEAD`` when run from a checkout; that lookup is local and never
reaches the network (ADR-0042m: ordinary operation never downloads acq's own
assets).
"""

from __future__ import annotations

import os
import subprocess

from . import __version__


def _git_revision() -> str | None:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    rev = out.stdout.strip()
    return rev or None


def acq_version() -> str:
    return os.environ.get("ACQ_VERSION") or __version__


def source_revision() -> str | None:
    override = os.environ.get("ACQ_SOURCE_REVISION")
    if override:
        return override
    return _git_revision()


def version_data() -> dict:
    """Assemble the ``version`` command's required result data (ADR-0038m).

    ``impl`` is the implementation marker ("python") so a bug report is
    unambiguous about which implementation produced the output (ADR-0046m).
    ``backend``, ``backend_version``, and ``kit_control_plane_ref`` are nullable
    until the backend adapters and kit control plane land.
    """
    return {
        "impl": "python",
        "acq_version": acq_version(),
        "source_revision": source_revision(),
        "backend": None,
        "backend_version": None,
        "kit_control_plane_ref": None,
    }
