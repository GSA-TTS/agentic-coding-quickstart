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

# Collection imports acq_py before any function fixture runs. The timeout
# tunables are now read lazily, but clear inherited ACQ_* here as well so a
# developer's shell cannot change anything read during import.
for _var in [v for v in os.environ if v.startswith("ACQ_")]:
    del os.environ[_var]


REAL_HOME = os.path.expanduser("~")
_USER_DIR_VARS = ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")
# Backend-stub homes are consulted before HOME; a developer's export must not leak in.
_BACKEND_HOME_VARS = ("MSB_HOME", "SBX_HOME")


@pytest.fixture(autouse=True)
def isolate_user_dirs(tmp_path_factory, monkeypatch):
    """Keep every test away from the developer's real home and acq state.

    Mutating verbs run the state/config migration, which resolves
    ``$XDG_CONFIG_HOME`` / ``$HOME/.config`` and ``$XDG_STATE_HOME``; a test that
    only redirected ``ACQ_STATE_DIR`` would otherwise rewrite a real
    ``~/.config/acq/config.yaml``. ``ACQ_*`` variables inherited from the
    developer's shell (``ACQ_BACKEND``, ``ACQ_IMPL``, adapter overrides) are
    cleared so they cannot change a test's outcome. Subprocess-driven tests
    inherit the redirected environment.
    """
    root = tmp_path_factory.mktemp("user-dirs")
    home = root / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    for var in _USER_DIR_VARS:
        path = root / var.lower()
        path.mkdir()
        monkeypatch.setenv(var, str(path))
    for var in [v for v in os.environ if v.startswith("ACQ_")] + list(_BACKEND_HOME_VARS):
        monkeypatch.delenv(var, raising=False)
    return root


@pytest.fixture(scope="session")
def vectors_dir() -> Path:
    return VECTORS_DIR


@pytest.fixture(scope="session")
def acq_cmd() -> list[str]:
    return [sys.executable, "-m", "acq_py"]


@pytest.fixture(scope="session")
def python_exe() -> str:
    return sys.executable
