"""Tier-2 implementation tests for the ACQ_IMPL coexistence switch (ADR-0046m).

These drive the repo-root Bash ``acq`` dispatcher as a subprocess to prove the
runtime switch end to end: unset/``bash`` runs the Bash body, ``python`` execs
the Python implementation, and an unknown value fails closed. They are
non-contract evidence (ADR-0039m); the Tier-1 oracles live under
``test/vectors/coexistence`` and run through both the pytest and Bash runners.

Skipped where a usable ``bash`` is unavailable (notably native Windows, where the
``bash`` on PATH is the WSL shim and cannot reach this checkout's paths).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
ACQ = REPO_ROOT / "acq"


def _have_bash() -> bool:
    return os.name != "nt" and shutil.which("bash") is not None


pytestmark = pytest.mark.skipif(not _have_bash(), reason="bash (POSIX) unavailable")


def _run_acq(env_extra: dict[str, str], *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    for name in ("ACQ_IMPL", "ACQ_RUNTIME"):
        env.pop(name, None)
    env.update(env_extra)
    return subprocess.run(
        ["bash", str(ACQ), *args],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_impl_unset_runs_bash_body():
    proc = _run_acq({}, "version")
    assert proc.returncode == 0, proc.stderr
    assert "script:" in proc.stdout
    assert "acq v1 (Python skeleton)" not in proc.stdout


def test_impl_bash_runs_bash_body():
    proc = _run_acq({"ACQ_IMPL": "bash"}, "version")
    assert proc.returncode == 0, proc.stderr
    assert "script:" in proc.stdout


def test_impl_python_dispatches():
    proc = _run_acq({"ACQ_IMPL": "python"}, "version")
    assert proc.returncode == 0, proc.stderr
    assert "acq v1 (Python skeleton)" in proc.stdout
    assert "impl:" in proc.stdout


def test_impl_python_forwards_json_and_exit_status():
    proc = _run_acq({"ACQ_IMPL": "python"}, "version", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["command"] == "version"
    assert doc["data"]["impl"] == "python"


def test_acq_python_launcher_runs_python():
    # ADR-0046m: the distinct `acq-python` identity runs the Python implementation
    # (never the Bash body), so the two entry points are observably distinct.
    acq_python = REPO_ROOT / "acq-python"
    proc = subprocess.run(
        ["bash", str(acq_python), "version"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    assert "acq v1 (Python skeleton)" in proc.stdout
    assert "impl:" in proc.stdout
    assert "script:" not in proc.stdout


def test_impl_unknown_fails_closed_exit_2():
    proc = _run_acq({"ACQ_IMPL": "bogus"}, "version")
    assert proc.returncode == 2
    assert "unsupported ACQ_IMPL" in proc.stderr
