"""Exercise real terminal echo with synthetic input; never read real credentials."""

import os
import fcntl
import pty
import select
import signal
import subprocess
import sys
import termios
import time
from pathlib import Path

if not __debug__:
    raise RuntimeError("terminal regressions require Python assertions enabled")


def collect(fd, process, timeout=5):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                data.extend(os.read(fd, 65536))
            except OSError:
                break
        if process.poll() is not None:
            while select.select([fd], [], [], 0)[0]:
                data.extend(os.read(fd, 65536))
            return bytes(data)
    raise AssertionError("terminal test timed out")


def exercise(root, scratch, mode):
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    result = scratch / (mode + ".result")
    prelude = ""
    if mode == "stty-failure":
        prelude = 'stty() { if [ "$1" = -echo ]; then return 1; fi; command stty "$@"; };'
    command = prelude + '''
      . "$1/acq.backends/secret-store.sh"
      value=$(_acq_read_secret_masked READY)
      rc=$?
      if [ "$rc" = 0 ]; then printf '%s' "$value" > "$2"; fi
      exit "$rc"
    '''
    env = os.environ.copy()
    # Do not inherit real credentials into the synthetic terminal test.
    for key in ("USAI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN"):
        env.pop(key, None)
    def terminal_session():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [os.environ.get("ACQ_TEST_BASH", "bash"), "-c", command, "_", str(root), str(result)],
        stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=terminal_session,
    )
    observed = bytearray()
    try:
        deadline = time.monotonic() + 5
        while b"READY" not in observed and process.poll() is None:
            assert time.monotonic() < deadline, "prompt timed out"
            if select.select([master], [], [], 0.05)[0]:
                observed.extend(os.read(master, 65536))
        if mode != "stty-failure":
            assert b"READY" in observed
            assert not termios.tcgetattr(slave)[3] & termios.ECHO
            if mode == "interrupt":
                os.write(master, b"\x03")
            elif mode == "terminate":
                os.killpg(process.pid, signal.SIGTERM)
            elif mode == "hangup":
                os.killpg(process.pid, signal.SIGHUP)
            else:
                payload = b"synthetic-secret\n"
                if mode == "backspace":
                    payload = b"synthetic-X\x7fsecret\n"
                elif mode == "eof":
                    payload = b"partial\x04"
                elif mode == "empty":
                    payload = b"\n"
                if mode == "delayed":
                    time.sleep(2.2)
                if mode in ("typing", "paused"):
                    for char in payload:
                        os.write(master, bytes([char]))
                        time.sleep(2.2 if mode == "paused" and char == ord("-") else 0.01)
                        if char != 10:
                            assert not termios.tcgetattr(slave)[3] & termios.ECHO
                else:
                    os.write(master, payload)
        try:
            observed.extend(collect(master, process))
        except AssertionError as error:
            raise AssertionError((mode, str(error))) from error
        rc = process.wait(timeout=5)
        deadline = time.monotonic() + 2
        while termios.tcgetattr(slave) != before and time.monotonic() < deadline:
            time.sleep(0.01)
        assert termios.tcgetattr(slave) == before, (mode, "settings not restored")
        assert b"synthetic" not in observed and b"partial" not in observed, mode
        if mode in ("paste", "typing", "paused", "delayed", "backspace", "empty"):
            assert rc == 0, mode
            assert result.read_bytes() == (b"" if mode == "empty" else b"synthetic-secret")
            assert observed.count(b"*") >= (0 if mode == "empty" else 16), mode
        else:
            assert rc != 0 and not result.exists(), mode
        if mode == "stty-failure":
            assert b"READY" not in observed, "prompt displayed before echo disabled"
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        os.close(master)
        os.close(slave)


if __name__ == "__main__":
    root, scratch = map(Path, sys.argv[1:])
    for mode in ("paste", "typing", "paused", "delayed", "backspace", "empty", "eof", "interrupt", "terminate", "hangup", "stty-failure"):
        exercise(root, scratch, mode)
    print("terminal checks passed")
