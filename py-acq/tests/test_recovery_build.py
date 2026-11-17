"""Packaging never resolves a WSL/Bash shim to generate recovery."""

import runpy
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
generate = runpy.run_path(str(ROOT / "py-acq/recovery_build.py"))["generate_recovery"]


@pytest.mark.skipif(sys.platform == "win32", reason="Bash byte comparison is POSIX-only")
def test_generator_matches_shell_builder(tmp_path):
    expected = tmp_path / "shell.command"
    subprocess.run(["bash", str(ROOT / "scripts/build-uninstaller"), str(expected)], check=True)
    actual = tmp_path / "nested" / "python.command"
    generate(ROOT / "py-acq", actual)
    assert actual.read_bytes() == expected.read_bytes()
    assert b"\r\n" not in actual.read_bytes()


def test_generator_does_not_launch_any_subprocess(monkeypatch, tmp_path):
    def refused(*args, **kwargs):
        raise AssertionError("generator attempted to launch a host executable")

    monkeypatch.setattr(subprocess, "run", refused)
    target = tmp_path / "recovery.command"
    generate(ROOT / "py-acq", target)
    assert target.read_bytes().startswith(b"#!/bin/bash\n")


def test_sdist_payload_is_copied_without_checkout(tmp_path):
    project = tmp_path / "sdist"
    source = project / "src/acq_py/uninstall.command"
    source.parent.mkdir(parents=True)
    source.write_bytes(b"#!/bin/bash\nfixture\n")
    target = tmp_path / "build/acq_py/uninstall.command"
    generate(project, target)
    assert target.read_bytes() == source.read_bytes()
