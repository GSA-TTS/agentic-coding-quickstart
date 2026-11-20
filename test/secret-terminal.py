"""Exercise real terminal echo with synthetic input; never read real credentials."""

import os
import fcntl
import pty
import re
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


# Group-signal modes (`kill -TERM -pgid`) hit the wrapper, the command-substitution
# shell and the reader subshell at once. Bash can then print one of its OWN
# diagnostics while it tears down: it re-enters its trap machinery with a trap
# list that is already being freed. These are bash defects, not output of the
# reader, and they differ by interpreter, so they are allowed only in the exact
# forms below, only at the END of the transcript, only after the full permitted
# prefix, and only a handful of times. Nothing else may trail the transcript.
#
# 1. Both interpreters (bash 5.x observed, bash 3.2.57 as "warning: ..."):
#      "<script>: [line N: ]warning: run_pending_traps: bad value in trap_list[K]: 0x1\r\n"
#    Bash found a trap slot already freed by the other signalled process.
# 2. bash 3.2.57 (musl build observed): the freed trap string is executed as a
#    command, so a fragment of the reader's own trap text is reported:
#      "<script>: line N: <fragment of the trap text>: command not found\r\n"
#    The fragment may be empty or span a line break ("...exit 143\r\ntrap"),
#    because the corrupted string is cut at arbitrary bytes.
# A fragment is accepted only if it is a substring of the trap text found in the
# production source and is NOT a substring of the synthetic secret, so a leaked
# input fragment cannot pass as a diagnostic. If a legitimate fragment ever
# collides with the secret the test fails closed (a visible flake), never open.
MAX_DIAGNOSTICS = 4
TRAP_WARNING = re.compile(
    rb"(?:line [0-9]+: )?warning: run_pending_traps: bad value in trap_list\[[0-9]+\]: 0x1\r\n")
TRAP_COMMAND = re.compile(rb"line [0-9]+: (.*?): command not found\r\n", re.DOTALL)


def trap_text(root):
    """Every `trap ...` line of the production reader, also with its quotes
    removed (bash reports the trap string after quote removal)."""
    source = (Path(root) / "acq.backends" / "secret-store.sh").read_bytes()
    lines = re.findall(rb"^[ \t]*(trap .*)$", source, re.MULTILINE)
    assert lines, "no trap lines found in the production reader"
    text = b"\n".join(lines)
    return text + b"\n" + text.replace(b'"', b"").replace(b"'", b"")


def fragment_is_trap_text(fragment, traps, secret):
    pieces = fragment.split(b"\r\n")
    return all(not piece or (piece in traps and piece not in secret) for piece in pieces)


def strip_group_diagnostics(tail, root):
    """Return the part of `tail` left after removing allowed bash diagnostics."""
    script = str(Path(root) / "acq.backends" / "secret-store.sh").encode() + b": "
    traps = trap_text(root)
    count = 0
    while tail.startswith(script):
        rest = tail[len(script):]
        match = TRAP_WARNING.match(rest)
        if match is None:
            match = TRAP_COMMAND.match(rest)
            if match is None or not fragment_is_trap_text(match.group(1), traps, SECRET):
                break
        count += 1
        if count > MAX_DIAGNOSTICS:
            break
        tail = rest[match.end():]
    return tail


def check_transcript(mode, observed, root):
    expected = expected_transcript(mode)
    overlap = set(PAYLOADS.get(mode, b"")) & set(expected)
    assert not overlap, (mode, "payload overlaps allow-list", sorted(overlap))
    observed = bytes(observed)
    if mode.endswith("-group") and observed.startswith(expected):
        # The WHOLE transcript is judged: only allowed diagnostics may follow.
        remainder = strip_group_diagnostics(observed[len(expected):], root)
        if not remainder:
            observed = expected
    assert observed == expected, (
        mode, "TRANSCRIPT MISMATCH: differs from the exact permitted output",
        "expected", expected, "observed", observed)


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
        check_transcript(mode, observed, root)
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


# Group-mode handler leaks write WITNESS to the terminal. Any unallowlisted bash
# diagnostic also yields a TRANSCRIPT MISMATCH, so the marker alone cannot show
# the injected handler ran; the witness bytes in the collected transcript can.
# The handler emits it through printf formatting so it only exists contiguously
# as output: a bash diagnostic quoting the mutated trap text shows the source form.
WITNESS = "HANDLER-LEAK-WITNESS"
WITNESS_PRINTF = "printf HANDLER-%s LEAK-WITNESS >&2"
LEAKS += (
    ("terminate-group-handler-appends-fragment", "terminate-group", "exit 143' TERM",
     WITNESS_PRINTF + "; exit 143' TERM", "TRANSCRIPT"),
    ("hangup-group-handler-appends-fragment", "hangup-group", "exit 129' HUP",
     WITNESS_PRINTF + "; exit 129' HUP", "TRANSCRIPT"),
)


def transcript_controls(root):
    """Drive check_transcript directly with group-mode transcripts: appended
    bytes must be rejected, the documented bash diagnostics accepted."""
    script = str(Path(root) / "acq.backends" / "secret-store.sh").encode()
    warning = script + b": line 1: warning: run_pending_traps: bad value in trap_list[1]: 0x1\r\n"
    command = script + b": line 1022: TERM: command not found\r\n"
    for mode in ("terminate-group", "hangup-group"):
        expected = expected_transcript(mode)
        for suffix in (b"", warning, command, warning + command):
            check_transcript(mode, expected + suffix, root)
        rejected = (
            ("single-char", b"s"),
            ("secret-suffix", b"secret"),
            ("secret-prefix-part", SECRET[:3]),
            ("mask-extra", b"*"),
            ("diagnostic-then-char", warning + b"s"),
            ("diagnostic-then-secret", command + b"secret"),
            ("char-then-diagnostic", b"s" + warning),
            ("diagnostic-extra-bytes", warning[:-2] + b"s\r\n"),
            ("secret-as-trap-fragment", script + b": line 1022: secret: command not found\r\n"),
            ("secret-char-as-trap-fragment", script + b": line 1022: s: command not found\r\n"),
            ("unknown-fragment", script + b": line 1022: hello: command not found\r\n"),
            ("diagnostic-too-many", warning * (MAX_DIAGNOSTICS + 1)),
            ("wrong-script", b"/tmp/other.sh: line 1: warning: run_pending_traps: bad value in trap_list[1]: 0x1\r\n"),
            ("missing-prefix", warning[len(script) + 2:]),
        )
        for name, suffix in rejected:
            try:
                check_transcript(mode, expected + suffix, root)
            except AssertionError as error:
                assert "TRANSCRIPT MISMATCH" in str(error), (mode, name, "wrong reason", str(error))
                continue
            raise AssertionError((mode, name, "appended bytes were accepted by the oracle"))
        try:
            check_transcript(mode, expected[:-1], root)
        except AssertionError:
            continue
        raise AssertionError((mode, "truncated transcript was accepted"))


def rejected_for_stated_reason(error, mode, marker):
    """True only if `error` carries the marker and, for group modes, the witness
    bytes the injected handler wrote to the transcript."""
    text = str(error)
    if marker not in text:
        return False
    return not mode.endswith("-group") or WITNESS in text


def negative_controls(root, scratch, run=exercise, leaks=None):
    source = (root / "acq.backends" / "secret-store.sh").read_text()
    for name, mode, old, new, marker in (LEAKS if leaks is None else leaks):
        assert source.count(old) == 1, (name, "patch target not found exactly once")
        copy = scratch / ("leak-" + name)
        (copy / "acq.backends").mkdir(parents=True)
        (copy / "acq.backends" / "secret-store.sh").write_text(source.replace(old, new))
        # A signal delivered to the whole foreground group (Ctrl-C, killpg) races
        # the wrapper against the reader's trap, so a leaky handler does not run
        # on every attempt: retry until it is observed. An
        # unrelated failure (e.g. a timing flake, or a bash diagnostic that merely
        # mismatches the transcript) is not a rejection for the stated reason and
        # is never counted as one.
        errors = []
        for _ in range(40 if mode in SIGNAL_MODES else 1):
            try:
                run(copy, copy, mode)
            except AssertionError as error:
                if rejected_for_stated_reason(error, mode, marker):
                    break
                errors.append(str(error))
        else:
            raise AssertionError((name, "leaky variant not rejected for the stated reason", errors[-1:]))


def mutation_witness_controls(root, scratch):
    """Drive negative_controls with a substitute for exercise: an unrelated
    transcript failure must not credit a group mutation whose handler never ran,
    while a failure carrying the handler's witness must."""
    group = tuple(entry for entry in LEAKS if entry[1].endswith("-group"))
    assert group and all(WITNESS_PRINTF in entry[3] for entry in group)

    def unrelated(copy, where, mode):
        raise AssertionError((mode, "TRANSCRIPT MISMATCH: unrelated bash diagnostic"))

    def quoted_trap(copy, where, mode):
        text = f": line 1: {WITNESS_PRINTF}; exit 143': command not found\r\n"
        raise AssertionError((mode, "TRANSCRIPT MISMATCH", "observed", text.encode()))

    def witnessed(copy, where, mode):
        raise AssertionError((mode, "TRANSCRIPT MISMATCH", "observed", WITNESS.encode()))

    for label, run in (("unrelated", unrelated), ("quoted-trap", quoted_trap)):
        try:
            negative_controls(root, scratch / label, run, group)
        except AssertionError as error:
            assert "not rejected for the stated reason" in str(error), (label, str(error))
        else:
            raise AssertionError((label, "failure credited a mutation that never ran"))
    negative_controls(root, scratch / "witnessed", witnessed, group)


if __name__ == "__main__":
    root, scratch = map(Path, sys.argv[1:])
    for mode in ("paste", "typing", "paused", "delayed", "backspace", "empty", "eof", "interrupt", "terminate", "hangup", "terminate-group", "hangup-group", "stty-failure"):
        exercise(root, scratch, mode)
    transcript_controls(root)
    mutation_witness_controls(root, scratch)
    negative_controls(root, scratch)
    print("terminal checks passed")
