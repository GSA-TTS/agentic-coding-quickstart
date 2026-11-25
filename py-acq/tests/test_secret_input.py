"""Deterministic Windows handle classification, not live Windows qualification."""

from __future__ import annotations

import ctypes
import io
import sys
from types import SimpleNamespace

import pytest

from acq_py.commands import common


@pytest.mark.parametrize("name, terminal", [
    ("\\msys-1888ae32e00d56aa-pty0-from-master", True),
    ("\\cygwin-e022582115c10879-pty3-from-master", True),
    ("\\msys-1888ae32e00d56aa-pipe-0x1", False),
    ("\\Win32Pipes.0000123c.00000002", False),
])
def test_windows_stdin_handle_distinguishes_terminal_from_explicit_pipe(monkeypatch, capsys, name, terminal):
    """Inspect the input handle, not the launching shell or output terminal."""
    stream = io.StringIO("PIPE-INPUT\r\n")
    monkeypatch.setattr(stream, "fileno", lambda: 0)
    monkeypatch.setattr(sys, "stdin", stream)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: False)
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setitem(sys.modules, "msvcrt", SimpleNamespace(get_osfhandle=lambda fd: 123))

    def pipe_name(handle, info_class, buf, size):
        assert (handle, info_class) == (123, 2)
        encoded = name.encode("utf-16-le")
        buf.raw = len(encoded).to_bytes(4, "little") + encoded + bytes(size - 4 - len(encoded))
        return 1

    kernel32 = SimpleNamespace(GetFileType=lambda handle: 3, GetFileInformationByHandleEx=pipe_name)
    monkeypatch.setattr(ctypes, "windll", SimpleNamespace(kernel32=kernel32), raising=False)
    assert common._stdin_is_mintty() is terminal
    if terminal:
        with pytest.raises(common.SecretInputError):
            common._read_secret_value()
        assert stream.tell() == 0
    else:
        assert common._read_secret_value() == "PIPE-INPUT"
    assert capsys.readouterr() == ("", "")


def test_explicit_redirected_file_keeps_input_semantics(monkeypatch, tmp_path, capsys):
    path = tmp_path / "input"
    path.write_bytes(b"FILE-INPUT\r\n")
    with path.open(encoding="utf-8", newline="") as stream:
        monkeypatch.setattr(sys, "stdin", stream)
        assert common._read_secret_value() == "FILE-INPUT"
    assert capsys.readouterr() == ("", "")


_PTY_DRIVER = """
import sys
from acq_py import cli
from acq_py.commands import common
def read(*_a, **_k):
    value = common._read_secret_value("SAFE-PROMPT: ")
    assert value == ("" if sys.argv[1] == "eof" else "PTY-INPUT")
    return 0
cli._dispatch = read
raise SystemExit(cli.main(["ls"]))
"""


@pytest.mark.skipif(sys.platform == "win32", reason="real POSIX PTY, not Windows evidence")
@pytest.mark.parametrize("action, status", [("paste", 0), ("eof", 0), ("int", 130), ("term", 143), ("hup", 129)])
def test_real_pty_secret_input_restores_echo_after_paste_eof_or_signal(action, status):
    import os
    import pty
    import select
    import signal
    import subprocess
    import termios
    import time

    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    proc = subprocess.Popen([sys.executable, "-c", _PTY_DRIVER, action], stdin=slave, stdout=slave,
                            stderr=slave, start_new_session=True)
    output = b""
    try:
        deadline = time.monotonic() + 10
        while b"SAFE-PROMPT: " not in output and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 4096)
        assert b"SAFE-PROMPT: " in output
        assert not termios.tcgetattr(slave)[3] & termios.ECHO
        if action == "paste":
            os.write(master, b"PTY-INPUT\n")
        elif action == "eof":
            os.write(master, b"\x04")
        else:
            proc.send_signal({"int": signal.SIGINT, "term": signal.SIGTERM, "hup": signal.SIGHUP}[action])
        assert proc.wait(timeout=10) == status
        while select.select([master], [], [], 0.1)[0]:
            output += os.read(master, 4096)
        assert termios.tcgetattr(slave) == original
        assert b"PTY-INPUT" not in output
        assert b"Traceback" not in output
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        os.close(master)
        os.close(slave)
