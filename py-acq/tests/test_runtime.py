"""Runtime overrides fail closed even when discovery has a usable fallback."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

from acq_py import runtime


@pytest.fixture
def managed_runtime(tmp_path: Path, monkeypatch) -> Path:
    package = tmp_path / "src" / "acq_py"
    package.mkdir(parents=True)
    monkeypatch.setattr(runtime, "__file__", str(package / "runtime.py"))
    executable = tmp_path / "runtime" / ("python.exe" if os.name == "nt" else "bin/python3")
    executable.parent.mkdir(parents=True)
    executable.touch()
    return executable


@pytest.mark.parametrize("kind", ["missing", "directory", "relative"])
def test_invalid_override_never_falls_back(tmp_path, monkeypatch, managed_runtime, kind):
    assert runtime.resolve_runtime().executable == str(managed_runtime)
    override = tmp_path / "invalid-python"
    if kind == "directory":
        override.mkdir()
    elif kind == "relative":
        override = Path("relative-python")
        monkeypatch.chdir(tmp_path)
        override.touch()
    monkeypatch.setenv("ACQ_RUNTIME", str(override))
    with pytest.raises(runtime.RuntimeResolutionError) as caught:
        runtime.resolve_runtime()
    assert "ACQ_RUNTIME" in caught.value.message
    assert str(override) in caught.value.message
    assert "set ACQ_RUNTIME" in caught.value.remediation
    assert "unset ACQ_RUNTIME" in caught.value.remediation


def test_absolute_override_takes_precedence(tmp_path, monkeypatch, managed_runtime):
    override = tmp_path / "approved-python"
    override.touch()
    monkeypatch.setenv("ACQ_RUNTIME", str(override))
    assert runtime.resolve_runtime().executable == str(override)


@pytest.mark.parametrize("override", [None, ""])
def test_no_override_uses_base_interpreter(tmp_path, monkeypatch, override):
    monkeypatch.setattr(runtime, "__file__", str(tmp_path / "src" / "acq_py" / "runtime.py"))
    if override is not None:
        monkeypatch.setenv("ACQ_RUNTIME", override)
    resolved = runtime.resolve_runtime()
    assert resolved.executable == sys.executable
    assert resolved.managed is False
