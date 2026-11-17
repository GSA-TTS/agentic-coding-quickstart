"""Run install.sh the way `curl -fsSL .../install.sh | sh` runs it from a terminal.

The script reaches `sh` on a pipe, so the shell's stdin is never a terminal.
Two modes:

  tty ANSWER   a pseudo-terminal is the controlling terminal and the shell's
               stdout and stderr. When a "[y/N]" prompt appears on it, ANSWER and
               a newline are typed back.
  notty        a new session with no controlling terminal, so /dev/tty cannot
               be opened, while stdout and stderr are still a pseudo-terminal.
               Nothing is ever typed.
  captured     a pseudo-terminal is the controlling terminal, but the shell's
               stdout and stderr go to a file, as when a harness captures the
               output. A prompt that does reach the terminal is answered "n"
               (so a regression is counted, not left hanging); the captured
               output follows the terminal's.

Usage: install-tty.py MODE [ANSWER] INSTALL_SH [INSTALLER ARGS...]

Everything the installer printed is written to stdout, followed by a line
"PROMPTS=<count>", and the exit status is the installer's. A run that does not
finish within 60 seconds is killed and exits 124.
"""

from __future__ import annotations

import os
import pty
import select
import signal
import sys
import tempfile
import time

DEADLINE = 60.0


def _argv(script: str, args: list[str]) -> list[str]:
    # `cat SCRIPT | sh -s -- ARGS`: the installer's stdin is the script pipe.
    return ["sh", "-c", 'cat "$0" | sh -s -- "$@"', script, *args]


def _drain(master: int, pid: int, answer: str | None) -> int:
    """Copy the terminal's output to stdout, typing ANSWER at each prompt."""
    output, typed = b"", 0
    stop = time.monotonic() + DEADLINE
    while True:
        if time.monotonic() > stop:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            sys.stdout.write(output.decode(errors="replace") + "\ninstall-tty: timed out\n")
            return 124
        if not select.select([master], [], [], 0.1)[0]:
            continue
        try:
            block = os.read(master, 4096)
        except OSError:  # EIO once every slave descriptor is closed
            block = b""
        if not block:
            break
        output += block
        if answer is not None and output.count(b"[y/N]") > typed:
            os.write(master, answer.encode() + b"\n")
            typed += 1
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(output.decode(errors="replace"))
    sys.stdout.write(f"\nPROMPTS={output.count(b'[y/N]')}\n")
    return os.waitstatus_to_exitcode(status)


def run_tty(answer: str, script: str, args: list[str]) -> int:
    pid, master = pty.fork()
    if pid == 0:
        os.execvp("sh", _argv(script, args))
    return _drain(master, pid, answer)


def run_notty(script: str, args: list[str]) -> int:
    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.close(master)
        # A new session has no controlling terminal. The slave descriptor is
        # inherited, not opened, so it does not become one.
        os.setsid()
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(slave)
        os.execvp("sh", _argv(script, args))
    os.close(slave)
    return _drain(master, pid, None)


def run_captured(script: str, args: list[str]) -> int:
    fd, log = tempfile.mkstemp(prefix="install-tty.")
    os.close(fd)
    try:
        pid, master = pty.fork()
        if pid == 0:
            out = os.open(log, os.O_WRONLY | os.O_TRUNC)
            os.dup2(out, 1)
            os.dup2(out, 2)
            os.close(out)
            os.execvp("sh", _argv(script, args))
        code = _drain(master, pid, "n")
        with open(log, encoding="utf-8", errors="replace") as captured:
            sys.stdout.write(captured.read())
        return code
    finally:
        os.unlink(log)


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "tty":
        return run_tty(argv[1], argv[2], argv[3:])
    if len(argv) >= 2 and argv[0] == "notty":
        return run_notty(argv[1], argv[2:])
    if len(argv) >= 2 and argv[0] == "captured":
        return run_captured(argv[1], argv[2:])
    sys.stderr.write(__doc__ or "")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
