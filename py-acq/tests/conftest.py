"""Shared fixtures for the pytest vector runner.

The CLI-under-test is driven as a subprocess (contract evidence is subprocess-only,
ADR-0039m). ``PYTHONPATH`` is extended here so both the in-process imports and the
subprocess ``python -m acq_py`` resolve the package without an installed copy.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
PY_ACQ_SRC = REPO_ROOT / "py-acq" / "src"
VECTORS_DIR = REPO_ROOT / "test" / "vectors"

_sep = os.pathsep
_existing = os.environ.get("PYTHONPATH")
os.environ["PYTHONPATH"] = str(PY_ACQ_SRC) + (_sep + _existing if _existing else "")
sys.path.insert(0, str(PY_ACQ_SRC))


@pytest.fixture(scope="session")
def vectors_dir() -> Path:
    return VECTORS_DIR


@pytest.fixture(scope="session")
def acq_cmd() -> list[str]:
    return [sys.executable, "-m", "acq_py"]


@pytest.fixture(scope="session")
def python_exe() -> str:
    return sys.executable
