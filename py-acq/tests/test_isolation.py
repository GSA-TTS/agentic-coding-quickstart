"""Guard: the suite never resolves the developer's real home or acq dirs.

These tests deliberately do NOT request ``isolate_user_dirs``: they must fail if
that fixture ever stops being autouse, because then every other test would run
against the real home.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from conftest import REAL_HOME

_REAL_ACQ_DIRS = (
    Path(REAL_HOME, ".config", "acq"),
    Path(REAL_HOME, ".local", "state", "acq"),
    Path(REAL_HOME, ".local", "share", "acq"),
)


def _snapshot():
    snap = {}
    for root in _REAL_ACQ_DIRS:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            try:
                st = path.lstat()
            except OSError:
                continue
            snap[str(path)] = (st.st_size, st.st_mtime_ns)
    return snap


def test_home_and_xdg_dirs_are_redirected(tmp_path_factory):
    base = Path(tmp_path_factory.getbasetemp()).resolve()
    assert os.environ["HOME"] != REAL_HOME
    for var in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
        assert Path(os.environ[var]).resolve().is_relative_to(base), var
    # The one ACQ_* the fixture sets: the secret store is pinned to a throwaway
    # file backend so no test can reach the host keychain.
    assert [v for v in os.environ if v.startswith("ACQ_")] == ["ACQ_SECRET_STORE_DIR"]
    assert Path(os.environ["ACQ_SECRET_STORE_DIR"]).resolve().is_relative_to(base)
    assert "MSB_HOME" not in os.environ and "SBX_HOME" not in os.environ


def test_state_touching_command_writes_only_under_the_test_tree(tmp_path, acq_cmd):
    before = _snapshot()
    ws = tmp_path / "workspace"
    ws.mkdir()
    env = dict(os.environ, ACQ_MSB_BIN="__stub__", ACQ_MSB_VERSION="0.7.7",
               ACQ_MSB_INSTALLED="1", ACQ_SBX_INSTALLED="0", MSB_HOME=str(tmp_path / "msb-home"))
    proc = subprocess.run(acq_cmd + ["--backend", "msb", "create", "shell", str(ws), "--name", "iso", "--json"],
                          env=env, capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    # No ACQ_STATE_DIR is set, so state resolves through the redirected XDG dir.
    assert (Path(os.environ["XDG_STATE_HOME"]) / "acq").is_dir()
    assert _snapshot() == before
