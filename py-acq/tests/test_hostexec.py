"""Host programs are never resolved from the current directory.

acq runs from inside the (untrusted) workspace, so a program planted there must
not be launched on the host, whatever PATH contains (see acq_py.hostexec).
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import backends, hostexec, msb, sbx, version_info


def _exe(path: Path) -> Path:
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    ws = tmp_path / "ws"
    ws.mkdir()
    for name in ("git", "msb", "sbx", "git.exe", "msb.exe", "sbx.exe"):
        _exe(ws / name)
    monkeypatch.chdir(ws)
    monkeypatch.delenv("ACQ_MSB_BIN", raising=False)
    monkeypatch.delenv("ACQ_SBX_BIN", raising=False)
    return ws


@pytest.mark.parametrize(
    "path_value", ["", ".", os.pathsep, "." + os.pathsep + "bin", "ws"]
)
def test_relative_and_empty_path_entries_are_never_searched(
    workspace, monkeypatch, path_value
):
    monkeypatch.setenv("PATH", path_value)
    for name in ("git", "msb", "sbx"):
        assert hostexec.which(name) is None
        with pytest.raises(FileNotFoundError):
            hostexec.command(name)


def test_absolute_path_entry_resolves_to_an_absolute_path(
    workspace, tmp_path, monkeypatch
):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    real = _exe(bindir / "msb")
    monkeypatch.setenv("PATH", os.pathsep.join(["", ".", str(bindir)]))
    assert hostexec.which("msb") == str(real)
    assert msb.msb_command() == [str(real)]


def test_backend_adapters_fail_closed_rather_than_fall_back_to_a_bare_name(
    workspace, monkeypatch
):
    monkeypatch.setenv("PATH", ".")
    with pytest.raises(FileNotFoundError):
        msb.msb_command()
    with pytest.raises(FileNotFoundError):
        sbx.sbx_command()
    monkeypatch.delenv("ACQ_MSB_INSTALLED", raising=False)
    monkeypatch.delenv("ACQ_MSB_VERSION", raising=False)
    assert backends._is_installed(backends.BACKENDS["msb"]) is False
    assert backends._run_version_command(backends.BACKENDS["msb"]) is None


def test_names_with_a_directory_part_are_not_searched(workspace, monkeypatch):
    monkeypatch.setenv("PATH", str(workspace))
    assert hostexec.which("./msb") is None
    assert hostexec.which(str(workspace / "msb")) is None


def test_windows_only_accepts_exe_from_absolute_entries(
    workspace, tmp_path, monkeypatch
):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    _exe(bindir / "msb.cmd")
    real = _exe(bindir / "msb.exe")
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    monkeypatch.setenv("PATH", os.pathsep.join([".", str(bindir)]))
    assert hostexec.which("msb") == str(real)
    assert hostexec.which("msb.exe") == str(real)
    real.unlink()
    assert hostexec.which("msb") is None  # msb.cmd is not a match, nor is .\msb.exe


def test_override_naming_an_existing_file_is_taken_whole(tmp_path, monkeypatch):
    (tmp_path / "dir with space").mkdir()
    target = _exe(tmp_path / "dir with space" / "msb")
    monkeypatch.setenv("ACQ_MSB_BIN", str(target))
    assert msb.msb_command() == [str(target)]


def test_windows_override_keeps_backslashes(monkeypatch):
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    assert hostexec.override_command(r"C:\tools\msb.exe --debug") == [
        r"C:\tools\msb.exe",
        "--debug",
    ]
    assert hostexec.override_command(r'"C:\Program Files\msb\msb.exe" -v') == [
        r"C:\Program Files\msb\msb.exe",
        "-v",
    ]


def test_bare_override_is_resolved_not_taken_from_the_workspace(workspace, monkeypatch):
    monkeypatch.setenv("PATH", ".")
    monkeypatch.setenv("ACQ_SBX_BIN", "sbx --debug")
    with pytest.raises(FileNotFoundError):
        sbx.sbx_command()


def test_git_revision_reads_acq_checkout_not_the_workspace(workspace, monkeypatch):
    seen = {}

    def fake_run(argv, **kwargs):
        seen["argv"], seen["kwargs"] = argv, kwargs
        return subprocess.CompletedProcess(argv, 0, stdout="abc123\n", stderr="")

    bindir = workspace.parent / "bin"
    bindir.mkdir()
    real = _exe(bindir / "git")
    monkeypatch.setenv("PATH", str(bindir))
    monkeypatch.setattr(version_info, "_CHECKOUT_ROOT", workspace.parent)
    (workspace.parent / ".git").mkdir()
    monkeypatch.setattr(version_info.subprocess, "run", fake_run)
    assert version_info._git_revision() == "abc123"
    assert seen["argv"][:3] == [str(real), "-C", str(workspace.parent)]


def test_git_revision_skips_git_outside_a_checkout(tmp_path, monkeypatch):
    monkeypatch.setattr(version_info, "_CHECKOUT_ROOT", tmp_path)
    monkeypatch.setattr(
        version_info.subprocess, "run", lambda *a, **k: pytest.fail("git was run")
    )
    assert version_info._git_revision() is None


@pytest.mark.skipif(sys.platform != "win32", reason="Windows current-directory search")
def test_windows_planted_exe_is_not_resolved(workspace):
    assert hostexec.which("git") != str(workspace / "git.exe")
    assert hostexec.which("msb") != str(workspace / "msb.exe")
