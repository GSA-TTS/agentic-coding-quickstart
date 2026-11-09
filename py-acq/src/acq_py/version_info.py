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

import json
import os
import subprocess
from pathlib import Path

from . import __version__, envelope, errors, hostexec


# The checkout acq runs from: src/acq_py -> src -> py-acq -> repository root.
_CHECKOUT_ROOT = Path(__file__).resolve().parents[3]


def _git_revision() -> str | None:
    # Report acq's own revision, as the Bash acq does with `git -C`. Running git
    # in the current directory would report the workspace's revision instead, and
    # would read the workspace's .git/config, which the sandboxed agent can write.
    if not (_CHECKOUT_ROOT / ".git").exists():
        return None
    try:
        out = subprocess.run(
            [*hostexec.command("git"), "-C", str(_CHECKOUT_ROOT), "rev-parse", "HEAD"],
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
    unambiguous about which implementation produced the output (ADR-0047m).
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


def run_version(emit_json: bool) -> int:
    """The ``version`` command handler (human/JSON rendering over :func:`version_data`).

    Lives here, beside :func:`version_data`, so a change to the ``version`` output
    fields touches only this module and never ``cli.py``. That keeps the
    ``version`` command off the Tier-3 surface (ADR-0044m): no live oracle asserts
    its exact output, so a version-output-only change must not expire a recorded
    transcript. ``cli.py`` delegates to this handler for ``version``/``--version``.
    """
    data = version_data()
    if emit_json:
        print(json.dumps(envelope.success("version", data)))
        return errors.EXIT_SUCCESS
    print("acq v1 (Python skeleton)")
    print(f"  acq version:       {data['acq_version']}")
    print(f"  impl:              {data['impl']}")
    print(f"  source revision:   {data['source_revision'] or '(not a git clone)'}")
    print(f"  backend:           {data['backend'] or 'none'}")
    print(f"  backend version:   {data['backend_version'] or 'none'}")
    print(f"  kit control plane: {data['kit_control_plane_ref'] or 'none'}")
    return errors.EXIT_SUCCESS
