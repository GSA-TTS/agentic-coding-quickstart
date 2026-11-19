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


# Exact transcript allow-list. The terminal line discipline has echo off, so the
# only bytes that may reach the screen are those the masked reader itself emits.
PROMPT = b"READY"  # the prompt argument, printed once before any input is read
MASK = b"*"  # exactly one per accepted input byte, nothing else
ERASE = b"\b \b"  # backspace, space, backspace: erases one mask on delete
# Failure diagnostic; "\r\n" because the pty output processing maps "\n" to CRLF.
REFUSAL = b"acq: cannot disable terminal echo; refusing secret input.\r\n"

# Synthetic inputs per mode. Their bytes must never overlap the allow-list above
# so that any echoed input byte is distinguishable from permitted output.
# They span lowercase, digits, uppercase and the punctuation of real tokens, so a
# leak that only fires for one character class (e.g. digits) is still caught.
# Exactly one "-" (the "paused" mode stalls on it) and no byte of READY, "*",
# backspace or space.
PRE = b"synthetic-"
CLASSES = b"Q9_.@/+=~!#%$\\;:"
SECRET = PRE + CLASSES + b"secret"
PAYLOADS = {
    "typing": SECRET + b"\n",
    "paste": SECRET + b"\n",
    "paused": SECRET + b"\n",
    "delayed": SECRET + b"\n",
    "backspace": PRE + b"X\x7f" + CLASSES + b"secret\n",
    "eof": b"partial" + CLASSES + b"\x04",
    "empty": b"\n",
    # Signal modes type a partial value first so a handler that leaks it is caught.
    "interrupt": SECRET,
    "terminate": SECRET,
    "hangup": SECRET,
    "terminate-group": SECRET,
    "hangup-group": SECRET,
}
# terminate/hangup signal only the reader subshell (deterministic: its trap must
# run); the -group modes signal the whole process group, as `kill -TERM -pgid`
# would, where the wrapper may die first, so only the clean-state checks apply.
SIGNAL_MODES = ("interrupt", "terminate", "hangup", "terminate-group", "hangup-group")


def expected_transcript(mode):
    if mode == "stty-failure":
        return REFUSAL
    if mode == "backspace":
        return PROMPT + MASK * (len(PRE) + 1) + ERASE + MASK * (len(CLASSES) + 6)
    if mode == "eof":
        return PROMPT + MASK * (len(PAYLOADS[mode]) - 1)
    if mode in SIGNAL_MODES:
        return PROMPT + MASK * len(SECRET)
    if mode == "empty":
        return PROMPT
    return PROMPT + MASK * len(SECRET)


def check_transcript(mode, observed):
    expected = expected_transcript(mode)
    overlap = set(PAYLOADS.get(mode, b"")) & set(expected)
    assert not overlap, (mode, "payload overlaps allow-list", sorted(overlap))
    if mode.endswith("-group"):
        # Killing the whole group can make bash itself print a diagnostic (e.g.
        # "run_pending_traps") nondeterministically: require the exact permitted
        # transcript as a prefix and leave the rest to the echo-token checks.
        observed = bytes(observed)[: len(expected)]
    assert bytes(observed) == expected, (
        mode, "TRANSCRIPT MISMATCH: differs from the exact permitted output",
        "expected", expected, "observed", bytes(observed))


def reader_pid(parent):
    """The reader's own subshell: the deepest descendant of the wrapper.

    wrapper -> command-substitution shell -> the reader's ( ... ) body, which owns
    the signal traps.
    """
    table = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True, check=True)
    children = {}
    for line in table.stdout.splitlines():
        pid, ppid = map(int, line.split())
        children.setdefault(ppid, []).append(pid)
    node = parent
    while children.get(node):
        assert len(children[node]) == 1, ("ambiguous reader subshell", node, children[node])
        node = children[node][0]
    assert node != parent, "reader subshell not found"
    return node


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
      printf '%s' "$value" > "$2.captured"
      if [ "$rc" = 0 ]; then printf '%s' "$value" > "$2"; fi
      exit "$rc"
    '''
    env = os.environ.copy()
    # Do not inherit real credentials into the synthetic terminal test.
    for key in ("USAI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN"):
        env.pop(key, None)
    def terminal_session():
        os.setsid()
        # A backgrounded/nohup parent leaves SIGINT ignored, which bash would inherit.
        signal.signal(signal.SIGINT, signal.SIG_DFL)
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
            assert not termios.tcgetattr(slave)[3] & termios.ECHO, "ECHO ENABLED at prompt"
            if mode in SIGNAL_MODES:
                os.write(master, PAYLOADS[mode])
                deadline = time.monotonic() + 5
                while observed.count(MASK) < len(PAYLOADS[mode]):
                    assert time.monotonic() < deadline, "mask echo timed out"
                    if select.select([master], [], [], 0.05)[0]:
                        observed.extend(os.read(master, 65536))
            if mode == "interrupt":
                os.write(master, b"\x03")
            elif mode == "terminate-group":
                os.killpg(process.pid, signal.SIGTERM)
            elif mode == "hangup-group":
                os.killpg(process.pid, signal.SIGHUP)
            elif mode in ("terminate", "hangup"):
                os.kill(reader_pid(process.pid), getattr(signal, "SIG" + ("TERM" if mode == "terminate" else "HUP")))
            else:
                payload = PAYLOADS[mode]
                if mode == "delayed":
                    time.sleep(2.2)
                if mode in ("typing", "paused"):
                    for char in payload:
                        os.write(master, bytes([char]))
                        time.sleep(2.2 if mode == "paused" and char == ord("-") else 0.01)
                        if char != 10:
                            assert not termios.tcgetattr(slave)[3] & termios.ECHO, "ECHO ENABLED"
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
        # A signal can end the wrapper before the reader subshell's trap runs, so
        # output written during cleanup arrives late: drain once more, now that
        # the restore (the last cleanup step) has happened.
        while select.select([master], [], [], 0.05)[0]:
            try:
                observed.extend(os.read(master, 65536))
            except OSError:
                break
        assert not any(token in observed for token in (b"synthetic", b"partial", CLASSES[:3])), (mode, "INPUT ECHOED")
        check_transcript(mode, observed)
        if mode in ("paste", "typing", "paused", "delayed", "backspace", "empty"):
            assert rc == 0, mode
            assert result.read_bytes() == (b"" if mode == "empty" else SECRET)
        else:
            assert rc != 0 and not result.exists(), mode
            # Nothing may reach the captured stdout of a failed entry either (the
            # wrapper shell dies before recording it when the signal hits the group).
            captured = result.with_name(mode + ".result.captured")
            assert not captured.exists() or not captured.read_bytes(), (
                mode, "CAPTURED STDOUT not empty")
        if mode == "stty-failure":
            assert b"READY" not in observed, "prompt displayed before echo disabled"
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        os.close(master)
        os.close(slave)


# Deliberately leaky variants of the reader. Each (name, mode, old, new, marker)
# patches one statement in a scratch copy; the oracle must reject every one, and
# for the stated reason (marker), not through an unrelated failure such as a timeout.
LEAKS = (
    ("mask-with-extra-char", "paste", "printf '*' >&2", "printf '*s' >&2", "TRANSCRIPT"),
    ("echo-one-real-char", "paste", "printf '*' >&2",
     "if [ ${#value} -eq 1 ]; then printf '%s' \"$char\" >&2; else printf '*' >&2; fi", "TRANSCRIPT"),
    ("omit-one-mask", "paste", "printf '*' >&2",
     "if [ ${#value} -ne 5 ]; then printf '*' >&2; fi", "TRANSCRIPT"),
    ("no-erase-on-backspace", "backspace", "printf '\\b \\b' >&2", ":", "TRANSCRIPT"),
    ("backspace-echoes-deleted-char", "backspace", "printf '\\b \\b' >&2",
     "printf '\\b%s\\b' \"${value: -1}\" >&2", "TRANSCRIPT"),
    ("interrupt-handler-leaks-value", "interrupt", "exit 130' INT",
     "printf %s \"$value\" >&2; exit 130' INT", "INPUT ECHOED"),
    ("terminate-handler-leaks-value", "terminate", "exit 143' TERM",
     "printf %s \"$value\" >&2; exit 143' TERM", "INPUT ECHOED"),
    ("eof-leaks-value-on-stdout", "eof", "$'\\004') return 1 ;;",
     "$'\\004') printf '%s' \"$value\"; return 1 ;;", "CAPTURED STDOUT"),
    ("echo-char-classes-digits-upper-symbols", "paste", "printf '*' >&2",
     "case \"$char\" in [0-9A-Z_.@/+=~!#%]) printf '%s' \"$char\" >&2;; *) printf '*' >&2;; esac", "INPUT ECHOED"),
    ("terminal-echo-left-on", "paste", "stty -echo -echonl", "stty echo -echonl", "ECHO ENABLED"),
)


def negative_controls(root, scratch):
    source = (root / "acq.backends" / "secret-store.sh").read_text()
    for name, mode, old, new, marker in LEAKS:
        assert source.count(old) == 1, (name, "patch target not found exactly once")
        copy = scratch / ("leak-" + name)
        (copy / "acq.backends").mkdir(parents=True)
        (copy / "acq.backends" / "secret-store.sh").write_text(source.replace(old, new))
        try:
            exercise(copy, copy, mode)
        except AssertionError as error:
            assert marker in str(error), (name, "rejected for the wrong reason", str(error))
            continue
        raise AssertionError((name, "leaky variant was accepted by the oracle"))


if __name__ == "__main__":
    root, scratch = map(Path, sys.argv[1:])
    for mode in ("paste", "typing", "paused", "delayed", "backspace", "empty", "eof", "interrupt", "terminate", "hangup", "terminate-group", "hangup-group", "stty-failure"):
        exercise(root, scratch, mode)
    negative_controls(root, scratch)
    print("terminal checks passed")
