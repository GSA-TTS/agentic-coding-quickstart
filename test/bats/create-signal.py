#!/usr/bin/env python3
# Ctrl-C during `acq create`: SIGINT (or SIGTERM) sent to acq's whole process
# group, as a terminal does, while the stubbed backend `create` is blocked and
# the spinner is animating on a TTY. acq must clean up the uncreated attempt
# exactly once (one confirm-absent listing, provider-input generation discarded,
# lock released, backend child reaped, cursor restored), exit only after that
# cleanup, and end with the conventional status: 130 for SIGINT, 143 for
# SIGTERM. The "pid" cases send SIGTERM to acq's PID alone: acq is documented
# not to forward it, so it must wait for the provisioning step to finish and
# then stop with 143.
#
# The spinner composes its own INT/TERM/EXIT traps over the provisioning
# subshell's, so this is the path where the chained handlers must run in the
# right order. Runs under the bats stub environment (make_stubs): the stub
# backends, isolated state and offline kits come from the inherited env.
#
# Usage: create-signal.py REPO STUBDIR BASH

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import time

repo, stubdir = (Path(p).resolve() for p in sys.argv[1:3])
shell = sys.argv[3]

# A terminal's Ctrl-C reaches a shell whose SIGINT is at its default. A runner
# started in the background by a non-interactive shell (`cmd &`, as a hook
# runner or a parallel loop may do) instead hands every child SIGINT ignored,
# and a shell cannot trap a signal that was ignored on entry. acq then rightly
# ignores the SIGINT, the stub `create` runs to its end, and acq goes on past
# create. Undo an inherited SIG_IGN here: a handler, unlike SIG_IGN, is reset
# to the default across exec, so acq starts as it would from a terminal.
signal.signal(signal.SIGINT, signal.default_int_handler)
signal.signal(signal.SIGTERM, signal.SIG_DFL)

# Intercept only `create`: record it, publish this process's PID (the one acq
# registered as its backend child), and block. SIGINT is ignored in an
# asynchronous child of a non-interactive shell, so only acq's own
# TERM-to-children (or a group SIGTERM) can end it, exactly as for the real
# backend CLI. On TERM it takes a second to exit, as a backend tidying up would,
# so acq's cleanup measurably outlasts the signal: an acq that exits before its
# cleanup has finished is caught with the child still alive.
#
# The "pid" cases instead block until the test creates a release file and then
# run the stub's real create, because a signal sent to acq's PID alone never
# reaches this child.
WRAPPER = """#!/bin/sh
case "${1:-}" in
  create)
    printf 'create-blocked\\n' >> "$CALLS"
    printf '%s\\n' "$$" > "@DIR@/create.pid"
    if [ "@TARGET@" = pid ]; then
      while [ ! -f "@DIR@/release" ]; do sleep 0.1; done
      exec "@STUBDIR@/@BACKEND@" "$@"
    fi
    trap 'kill "$s" 2>/dev/null; sleep 1; exit 143' TERM
    sleep 60 & s=$!
    wait "$s"
    exit 0 ;;
esac
exec "@STUBDIR@/@BACKEND@" "$@"
"""

LISTING = {"sbx": "sbx ls -q", "msb": "msb list -q"}


def drain(master, sink, wait=0.05):
    while select.select([master], [], [], wait)[0]:
        try:
            block = os.read(master, 4096)
        except OSError:
            return
        if not block:
            return
        sink.extend(block)
        wait = 0


def until(predicate, master, sink, what, limit=60):
    deadline = time.monotonic() + limit
    while not predicate():
        assert time.monotonic() < deadline, ("timed out waiting for " + what, bytes(sink[-400:]))
        drain(master, sink)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def registered(tmp, pid):
    for registry in tmp.glob("acq-provider-children.*"):
        try:
            if str(pid) in registry.read_text().split():
                return True
        except OSError:
            pass
    return False


def run_case(backend, sig, target):
    case = f"{backend}-{signal.Signals(sig).name.lower()}" + ("-pid" if target == "pid" else "")
    name = f"sig-{case}"
    work = stubdir / f"case-{case}"
    tmp = work / "tmp"
    for directory in (work / "bin", tmp, work / "proj"):
        directory.mkdir(parents=True)
    calls = work / "calls.log"
    calls.touch()
    wrapper = work / "bin" / backend
    wrapper.write_text(WRAPPER.replace("@DIR@", str(work)).replace("@STUBDIR@", str(stubdir))
                       .replace("@BACKEND@", backend).replace("@TARGET@", target))
    wrapper.chmod(0o755)
    env = os.environ.copy()
    for key in ("ACQ_NO_PROGRESS", "ACQ_DEBUG", "SSH_AUTH_SOCK"):
        env.pop(key, None)
    # Each case owns its state: the cases run concurrently, and the kit caches
    # would otherwise default to the developer's real XDG cache.
    provenance = work / "provenance"
    env.update(PATH=f"{work / 'bin'}{os.pathsep}{env['PATH']}", CALLS=str(calls),
               TMPDIR=str(tmp), ACQ_BACKEND=backend, ACQ_NO_PROMPT="1",
               ACQ_PROVENANCE_DIR=str(provenance), ACQ_SBX_KIT_CACHE=str(work / "kits"),
               ACQ_MSB_KIT_CACHE=str(work / "msb-kits"))
    master, slave = pty.openpty()
    process = subprocess.Popen([shell, str(repo / "acq"), "create", "shell", "--name", name,
                                str(work / "proj")],
                               stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                               env=env, start_new_session=True)
    os.close(slave)
    output = bytearray()
    pid_file = work / "create.pid"
    try:
        until(lambda: pid_file.is_file() and pid_file.read_text().strip() or process.poll() is not None,
              master, output, "the blocked create")
        assert process.poll() is None, ("acq exited before create", bytes(output))
        child = int(pid_file.read_text())
        # Signal only once acq has registered the child it must reap, and the
        # spinner (which hides the cursor first) is animating.
        until(lambda: registered(tmp, child), master, output, "child registration")
        until(lambda: b"\x1b[?25l" in output and b"Creating sandbox" in output,
              master, output, "the spinner")
        lock_glob = f"provider-input/{backend}/{name}.*.lock"
        if target == "pid":
            # Only acq's own PID: the signal is not forwarded (documented in
            # progress.sh), so acq keeps waiting for the provisioning step, and
            # the create runs to completion once released.
            os.kill(process.pid, sig)
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline:
                drain(master, output)
            assert process.poll() is None, (case, "acq exited before provisioning finished", bytes(output[-600:]))
            assert alive(child), (case, "the signal reached the create")
            (work / "release").touch()
        else:
            os.killpg(process.pid, sig)
        until(lambda: process.poll() is not None, master, output, "acq to exit", 90)
        rc = process.returncode
        # acq exits only once the provisioning subshell has: the backend child
        # is gone and the lock released at that moment, for SIGTERM as for
        # Ctrl-C (Bash waits for a foreground child before running a trap).
        assert not alive(child), (case, "acq exited before its backend child", bytes(output[-600:]))
        assert not list(provenance.glob(lock_glob)), (case, "acq exited before releasing the lock")
        drain(master, output)
        # Ctrl-C and a group SIGTERM: the subshell's handlers exit 130/143 and
        # acq exits with that status. A SIGTERM to acq alone: provisioning
        # completes, then acq stops with 143 instead of going on.
        assert rc == 128 + sig, (case, "exit status", rc, bytes(output[-600:]))
        if target == "pid":
            assert b"stopped by SIGTERM after the provisioning step finished" in output, (case, bytes(output[-600:]))
            print("PASS", case, "status", rc)
            return
        generations = list(provenance.glob(f"provider-input/{backend}/{name}.*/generations/*"))
        assert not generations, (case, "generation not discarded", generations)
        log = calls.read_text().splitlines()
        assert "create-blocked" in log, (case, log)
        after = log[log.index("create-blocked") + 1:]
        assert after.count(LISTING[backend]) == 1, (case, "cleanup listings", after)
        tail = bytes(output).rsplit(b"Creating sandbox", 1)[-1]
        assert b"\x1b[?25h" in tail, (case, "cursor not restored", tail)
        print("PASS", case, "status", rc)
    except AssertionError as error:
        raise AssertionError(f"{case}: {error!r}") from None
    finally:
        # The whole session group, always: after a failed assertion the
        # provisioning subshell, its guardian, the spinner animator or the
        # blocked create may outlive acq itself.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            process.wait(timeout=15)
        os.close(master)


print("shell", subprocess.run([shell, "-c", 'printf %s "$BASH_VERSION"'], capture_output=True,
                               text=True).stdout)
cases = [(backend, sig, "group") for backend in ("sbx", "msb") for sig in (signal.SIGINT, signal.SIGTERM)]
cases += [(backend, signal.SIGTERM, "pid") for backend in ("sbx", "msb")]
with ThreadPoolExecutor(max_workers=len(cases)) as pool:
    futures = [pool.submit(run_case, *args) for args in cases]
failures = [(cases[i], f.exception()) for i, f in enumerate(futures) if f.exception()]
for args, error in failures:
    print("FAIL", args, error, file=sys.stderr)
sys.exit(1 if failures else 0)
