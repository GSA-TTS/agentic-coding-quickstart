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


# A program found on PATH: hostexec accepts only ``.exe`` files on Windows, so
# the fakes found through PATH carry the suffix there (POSIX names stay bare).
_EXE_SUFFIX = ".exe" if sys.platform == "win32" else ""


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
    "path_value",
    ["", ".", os.pathsep, "." + os.pathsep + "bin", os.path.join("..", "ws")],
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
    real = _exe(bindir / f"msb{_EXE_SUFFIX}")
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
    monkeypatch.setattr(hostexec, "_is_absolute", os.path.isabs)
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
    real = _exe(bindir / f"git{_EXE_SUFFIX}")
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


@pytest.mark.parametrize(
    "path, absolute",
    [
        (r"C:\Program Files\Git\cmd", True),
        ("C:/tools", True),
        (r"\\server\share\bin", True),
        (r"\\?\C:\tools", True),
        (r"C:tools", False),
        (r"\tools", False),
        ("/tools", False),
        ("tools", False),
        (".", False),
        ("", False),
    ],
)
def test_windows_absolute_requires_drive_and_root(monkeypatch, path, absolute):
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    assert hostexec._is_absolute(path) is absolute


def test_windows_path_entries_skip_relative_and_unquote(monkeypatch):
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    monkeypatch.setattr(hostexec.os, "pathsep", ";")
    monkeypatch.setenv(
        "PATH", r'.;;C:tools;\tools;"C:\Program Files\Git\cmd";C:\Windows\System32'
    )
    assert hostexec._path_entries() == [
        r"C:\Program Files\Git\cmd",
        r"C:\Windows\System32",
    ]


@pytest.mark.parametrize("value", ["msb", "msb --debug", "./msb", "bin/msb"])
def test_relative_override_never_runs_a_workspace_file(workspace, monkeypatch, value):
    (workspace / "bin").mkdir()
    _exe(workspace / "bin" / "msb")
    _exe(workspace / "msb --debug")
    monkeypatch.setenv("PATH", ".")
    monkeypatch.setenv("ACQ_MSB_BIN", value)
    with pytest.raises(FileNotFoundError):
        msb.msb_command()


@pytest.mark.parametrize("windows", [False, True])
def test_override_that_does_not_split_is_file_not_found(monkeypatch, windows):
    # Every caller maps OSError to "backend CLI cannot be run"; a ValueError
    # from shlex would bypass that and surface as a traceback.
    monkeypatch.setattr(hostexec, "_is_windows", lambda: windows)
    with pytest.raises(FileNotFoundError):
        hostexec.override_command('"/opt/msb --debug')


def test_windows_drive_relative_override_is_refused(monkeypatch):
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    with pytest.raises(FileNotFoundError):
        hostexec.override_command(r"C:msb.exe --x")


def test_passthrough_launches_the_resolved_backend(workspace, tmp_path, monkeypatch):
    from acq_py.commands import session

    bindir = tmp_path / "bin"
    bindir.mkdir()
    real = _exe(bindir / f"sbx{_EXE_SUFFIX}")
    monkeypatch.setenv("PATH", os.pathsep.join([".", str(bindir)]))
    monkeypatch.setenv("ACQ_BACKEND", "sbx")
    seen = {}

    def fake_run(argv, **kwargs):
        seen["argv"] = argv
        return 0

    monkeypatch.setattr(session.hostexec, "run_foreground", fake_run)
    assert session._passthrough(["image", "list"], None, False) == 0
    assert seen["argv"] == [str(real), "image", "list"]


def test_which_all_yields_every_match_from_an_explicit_path_in_order(workspace, tmp_path, monkeypatch):
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    a = _exe(first / f"msb{_EXE_SUFFIX}")
    b = _exe(second / f"msb{_EXE_SUFFIX}")
    monkeypatch.setenv("PATH", str(tmp_path / "elsewhere"))
    path = os.pathsep.join(["", ".", str(first), "rel", str(second)])
    assert list(hostexec.which_all("msb", path)) == [str(a), str(b)]
    assert hostexec.which("msb", path) == str(a)
    assert hostexec.which("msb") is None  # PATH itself is the default
    assert list(hostexec.which_all(os.path.join("rel", "msb"), path)) == []


@pytest.mark.skipif(sys.platform != "win32", reason="Windows current-directory search")
def test_windows_planted_exe_is_not_resolved(workspace, monkeypatch):
    monkeypatch.setenv("PATH", ".")
    assert hostexec.which("git") is None
    assert hostexec.which("msb") is None


# ---------------------------------------------------------------------------
# Interactivity: on Windows, ``< NUL`` must not pass for a terminal.
# ---------------------------------------------------------------------------

class _Stream:
    def __init__(self, tty, fileno=0):
        self._tty = tty
        self._fileno = fileno

    def isatty(self):
        if isinstance(self._tty, Exception):
            raise self._tty
        return self._tty

    def fileno(self):
        if isinstance(self._fileno, Exception):
            raise self._fileno
        return self._fileno


def test_stream_is_terminal_needs_a_console_on_windows(monkeypatch):
    consoles = []
    monkeypatch.setattr(hostexec, "_windows_console", lambda fd: consoles.append(fd) or False)
    monkeypatch.setattr(hostexec, "_is_windows", lambda: False)
    assert hostexec.stream_is_terminal(_Stream(True)) is True
    assert hostexec.stream_is_terminal(_Stream(False)) is False
    assert hostexec.stream_is_terminal(_Stream(ValueError("closed"))) is False
    assert hostexec.stream_is_terminal(object()) is False
    assert consoles == []  # POSIX never asks for a console

    # Windows: NUL is a character device, so isatty() says True; the console
    # check decides. A stream with no OS file is taken at its word.
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    assert hostexec.stream_is_terminal(_Stream(True, fileno=7)) is False
    assert consoles == [7]
    assert hostexec.stream_is_terminal(_Stream(True, fileno=OSError("no fd"))) is True
    monkeypatch.setattr(hostexec, "_windows_console", lambda fd: True)
    assert hostexec.stream_is_terminal(_Stream(True)) is True


def test_stdin_is_tty_needs_a_console_on_windows(monkeypatch):
    monkeypatch.setattr(hostexec.os, "isatty", lambda fd: True)
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    monkeypatch.setattr(hostexec, "_windows_console", lambda fd: False)
    assert hostexec.stdin_is_tty() is False
    monkeypatch.setattr(hostexec, "_windows_console", lambda fd: True)
    assert hostexec.stdin_is_tty() is True
    monkeypatch.setattr(hostexec, "_is_windows", lambda: False)
    assert hostexec.stdin_is_tty() is True

    def broken(fd):
        raise OSError("bad fd")

    monkeypatch.setattr(hostexec.os, "isatty", broken)
    assert hostexec.stdin_is_tty() is False


@pytest.mark.skipif(sys.platform != "win32", reason="the Windows console check itself")
def test_nul_is_not_a_console_on_windows():
    with open(os.devnull, "rb") as nul:
        assert os.isatty(nul.fileno())  # the trap this guards against
        assert hostexec._windows_console(nul.fileno()) is False
        assert hostexec.stream_is_terminal(nul) is False
