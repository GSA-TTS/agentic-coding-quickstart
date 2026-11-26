"""Fail-closed contracts for platform-specific pytest selection.

The CI lanes must be derived from pytest's collected node IDs, rather than from
file globs or a convention that a future test author might not know.  The
selector intentionally treats a test without a platform marker as neutral; the
representative node IDs below prevent removal of the explicit native markers
that protect real Windows behavior.
"""

from __future__ import annotations

import subprocess
import os
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
TESTS = "tests"
SELECTOR = ROOT / "scripts" / "pytest_platform_selection.py"

# Regression sentinels. These exercise actual Windows launchers, native path
# lookup, and Job objects; they must never migrate into the Linux-neutral lane.
WINDOWS_NATIVE = {
    "tests/test_windows_launchers.py::test_default_runs_the_managed_runtime_with_safe_path[acq.cmd-unset]",
}


def _collect(marker: str | None = None) -> set[str]:
    command = [sys.executable, "-m", "pytest", "--collect-only", "-q"]
    if marker is not None:
        command.extend(["-m", marker])
    command.append(str(TESTS))
    environment = os.environ.copy()
    # conftest deliberately scrubs inherited PYTHONPATH. Retain only the active
    # pytest installation for this subprocess collection, never a checkout path.
    environment["PYTHONPATH"] = str(Path(pytest.__file__).resolve().parents[1])
    result = subprocess.run(command, cwd=ROOT / "py-acq", capture_output=True, text=True, env=environment)
    assert result.returncode in (0, 5), result.stderr
    return {line for line in result.stdout.splitlines() if line.startswith("tests/")}


def _expression(lane: str) -> str:
    result = subprocess.run([sys.executable, str(SELECTOR), lane], capture_output=True, text=True, check=True)
    return result.stdout.strip()


def test_platform_markers_are_declared():
    pyproject = (ROOT / "py-acq" / "pyproject.toml").read_text(encoding="utf-8")
    assert "platform_windows:" in pyproject
    assert "platform_macos:" in pyproject
    assert "platform_shared:" in pyproject


def test_every_collected_item_is_selected_exactly_once():
    all_items = _collect()
    windows = _collect(_expression("windows-native"))
    macos = _collect(_expression("macos-native"))
    neutral = _collect(_expression("linux-neutral"))

    assert all_items
    assert not windows & macos, "a native test needs an explicit shared classification"
    assert neutral | windows | macos == all_items
    assert not (neutral & windows) and not (neutral & macos) and not (windows & macos)


def test_windows_native_regression_sentinels_are_selected():
    selected = _collect(_expression("windows-native"))
    assert WINDOWS_NATIVE <= selected


def test_linux_neutral_selection_excludes_windows_native_sentinel():
    assert not WINDOWS_NATIVE & _collect(_expression("linux-neutral"))


def test_selector_rejects_unknown_lane():
    result = subprocess.run([sys.executable, str(SELECTOR), "unknown"], capture_output=True, text=True)
    assert result.returncode != 0
