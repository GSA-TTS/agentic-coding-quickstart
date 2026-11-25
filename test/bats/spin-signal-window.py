#!/usr/bin/env python3
# A signal at any point of acq_spin_start must leave no animator running and the
# cursor visible, and must still run the caller's INT and EXIT handlers once.
#
# The spinner composes its INT/TERM/EXIT traps over the caller's. Each case
# below delivers SIGINT to the shell at one fixed point of that sequence, so the
# timing is deterministic: a `trap` function shadows the builtin and signals the
# shell just before chosen calls reach it. Bash runs a pending trap at the next
# command boundary, which is before the shadowed `builtin trap` executes. The
# frames case signals from inside the frame-list command substitution instead.
# The animator ignores SIGINT (it is an asynchronous child of a non-interactive
# shell), so whatever is left running after the shell exits stays in its
# process group. The owner case kills the shell with SIGKILL, which runs no
# trap, while the spinner is animating.
#
# Usage: spin-signal-window.py REPO BASH SCRATCH

import os
from pathlib import Path
import signal
import subprocess
import sys
import time

repo, shell, scratch = Path(sys.argv[1]).resolve(), sys.argv[2], Path(sys.argv[3])

# A runner started in the background by a non-interactive shell hands every
# child SIGINT ignored, and a shell cannot trap a signal ignored on entry. Undo
# that here: a handler (unlike SIG_IGN) is reset to the default across exec.
signal.signal(signal.SIGINT, signal.default_int_handler)

SCRIPT = r'''
export ACQ_SCRIPT_DIR="$1"
. "$1/acq.backends/progress.sh"
point=$2
_acq_progress_enabled() { return 0; }
self=$(exec sh -c 'echo "$PPID"')
trap 'echo "PRIOR-EXIT rc=$?"' EXIT
trap 'echo PRIOR-INT; exit 130' INT
trap() {
  case "$point:$*" in
    "capture:-p EXIT"|"install-exit:_acq_spin_cleanup_exit EXIT"|\
    "install-int:_acq_spin_cleanup_signal INT INT"|\
    "install-term:_acq_spin_cleanup_signal TERM TERM")
      point=fired; kill -s INT "$self" ;;
  esac
  builtin trap "$@"
}
_acq_frames_orig=$(declare -f _acq_spin_frames | sed 1d)
eval "_acq_spin_frames() {
  [ \"\$point\" = frames ] && kill -s INT \"\$self\"
  $_acq_frames_orig
}"
acq_spin_start "Working"
echo STARTED
sleep 31
echo NOT-REACHED
'''


def leftovers(pgid):
    # Every process still in the shell's group except the script's own
    # `sleep 31`, which outlives a shell killed by SIGKILL and is not under test.
    table = subprocess.run(["ps", "-axo", "pid=,pgid=,command="], capture_output=True,
                           text=True).stdout.splitlines()
    rows = [line.split(None, 2) for line in table]
    return [row for row in rows if len(row) == 3 and row[1] == str(pgid)
            and row[2].split() != ["sleep", "31"]]


def wait_for(predicate, limit=30):
    deadline = time.monotonic() + limit
    while not predicate():
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


def run_case(point):
    out, err = scratch / f"{point}.out", scratch / f"{point}.err"
    with open(out, "wb") as stdout, open(err, "wb") as stderr:
        process = subprocess.Popen([shell, "-c", SCRIPT, "spin", str(repo), point],
                                   stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                   start_new_session=True)
    try:
        if point in ("running", "owner"):
            # Wait for the first frame, so the animator is drawing.
            assert wait_for(lambda: b"Working" in err.read_bytes()), (point, "no frame")
            if point == "owner":
                os.kill(process.pid, signal.SIGKILL)
            else:
                # The whole group, as a terminal does: the foreground `sleep 31`
                # must die too, or the shell would run its trap only after it.
                os.killpg(process.pid, signal.SIGINT)
        rc = process.wait(timeout=60)
        # Whatever else is still in the group after the shell exited is a
        # leaked animator. It stops within a frame of its owner's exit, so 30 s
        # is only a failure ceiling.
        leaked = not wait_for(lambda: not leftovers(process.pid))
        text, frames = out.read_text(), err.read_bytes()
        assert not leaked, (point, "still running after the shell exited",
                            leftovers(process.pid), text)
        if point == "owner":
            assert rc == -signal.SIGKILL, (point, rc, text)
            return
        assert rc == 130, (point, "status", rc, text, frames[-200:])
        assert "NOT-REACHED" not in text, (point, text)
        assert text.count("PRIOR-INT") == 1, (point, text)
        assert text.count("PRIOR-EXIT rc=130") == 1 and text.count("PRIOR-EXIT") == 1, (point, text)
        hidden = frames.rfind(b"\x1b[?25l")
        assert hidden < 0 or b"\x1b[?25h" in frames[hidden:], (point, "cursor left hidden", frames[-200:])
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            process.wait(timeout=15)


failed = False
for point in ("frames", "capture", "install-exit", "install-int", "install-term", "running", "owner"):
    try:
        run_case(point)
        print("PASS", point)
    except AssertionError as error:
        failed = True
        print("FAIL", point, repr(error))
sys.exit(1 if failed else 0)
