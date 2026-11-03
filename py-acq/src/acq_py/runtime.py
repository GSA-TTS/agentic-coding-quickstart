"""Managed-runtime resolution (ADR-0042m).

The managed Python runtime is an app-private, prebuilt CPython that sits beside
the acq source; the user never manages Python. The supplier is settled:
Python.org embedded on Windows, python-build-standalone install-only archives on
macOS/Linux. An IT-approved base interpreter is an optional per-fleet fallback.

This module only *resolves* the runtime to use; it never downloads one.
Acquisition (download + checksum + provenance) belongs to the installer, a
later slice. Ordinary operation never reaches the network for acq's own assets.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path

# Settled suppliers (ADR-0042m), recorded so provenance is inspectable.
SUPPLIER_WINDOWS = "python.org-embedded"
SUPPLIER_POSIX = "python-build-standalone"
SUPPLIER_FALLBACK = "it-approved-base"


@dataclass(frozen=True)
class Runtime:
    executable: str
    supplier: str
    managed: bool  # True when the app-private bundle is in use


def _managed_runtime_executable() -> str | None:
    # 1. Explicit override for tests/fleet selection.
    override = os.environ.get("ACQ_RUNTIME")
    if override and Path(override).exists():
        return str(Path(override))
    # 2. A runtime bundle laid down beside the source by the installer.
    here = Path(__file__).resolve().parent
    if os.name == "nt":
        names = ("python.exe",)
    else:
        names = ("bin/python3", "bin/python")
    for name in names:
        candidate = here.parent.parent / "runtime" / name
        if candidate.exists():
            return str(candidate)
    return None


def resolve_runtime() -> Runtime:
    """Return the interpreter that should execute acq's subprocesses.

    Resolution is purely local (an env override or a filesystem check); it never
    downloads. When no app-private bundle is present the IT-approved base
    interpreter (the one currently running acq) is the documented fallback.
    """
    managed = _managed_runtime_executable()
    if managed is not None:
        supplier = SUPPLIER_WINDOWS if os.name == "nt" else SUPPLIER_POSIX
        return Runtime(executable=managed, supplier=supplier, managed=True)
    return Runtime(executable=sys.executable, supplier=SUPPLIER_FALLBACK, managed=False)
