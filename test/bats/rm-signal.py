#!/usr/bin/env python3
# A signal to acq's whole process group during `acq rm`, as a terminal, `timeout`
# or a service manager sends it, while the stubbed backend remove is blocked.
# The terminate step runs in a subshell that holds the sandbox lock and the
# backend child and has its own HUP/INT/TERM cleanup. acq must wait for that
# cleanup (backend child reaped, lock released) before it exits, and then end
# with 128 + N: 143 for SIGTERM, 129 for SIGHUP, 130 for SIGINT.
#
# Same pattern as create-signal.py, without a PTY (`rm` shows no spinner).
# Runs under the bats stub environment (make_stubs): the stub backends and
# isolated state come from the inherited env.
#
# Usage: rm-signal.py REPO STUBDIR BASH

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

PRINT_LOCK = threading.Lock()

repo, stubdir = (Path(p).resolve() for p in sys.argv[1:3])
shell = sys.argv[3]

# Undo an inherited SIG_IGN, as create-signal.py does: a shell cannot trap a
# signal that was ignored on entry.
signal.signal(signal.SIGINT, signal.default_int_handler)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
signal.signal(signal.SIGHUP, signal.SIG_DFL)

# Intercept only the backend remove: publish this process's PID (the one acq
# registers as its backend child) and block. On TERM (acq's TERM-to-children,
# or the group signal) it takes a second to exit, as a backend tidying up
# would, so acq's cleanup measurably outlasts the signal.
WRAPPER = """#!/bin/sh
case "${1:-}" in
  @VERB@)
    printf '%s\\n' "$$" > "@DIR@/remove.pid"
    trap 'kill "$s" 2>/dev/null; sleep 1; exit 143' TERM
    sleep 60 & s=$!
    wait "$s"
    exit 0 ;;
esac
exec "@STUBDIR@/@BACKEND@" "$@"
"""

VERB = {"sbx": "rm", "msb": "remove"}


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


def until(predicate, what, limit=60):
    deadline = time.monotonic() + limit
    while not predicate():
        assert time.monotonic() < deadline, "timed out waiting for " + what
        time.sleep(0.05)


def run_case(backend, sig):
    case = f"rm-{backend}-{signal.Signals(sig).name.lower()}"
    name = f"sig-{case}"
    work = stubdir / f"case-{case}"
    tmp = work / "tmp"
    for directory in (work / "bin", tmp):
        directory.mkdir(parents=True)
    wrapper = work / "bin" / backend
    wrapper.write_text(WRAPPER.replace("@DIR@", str(work)).replace("@STUBDIR@", str(stubdir))
                       .replace("@BACKEND@", backend).replace("@VERB@", VERB[backend]))
    wrapper.chmod(0o755)
    env = os.environ.copy()
    for key in ("ACQ_DEBUG", "SSH_AUTH_SOCK"):
        env.pop(key, None)
    provenance = work / "provenance"
    env.update(PATH=f"{work / 'bin'}{os.pathsep}{env['PATH']}", CALLS=str(work / "calls.log"),
               TMPDIR=str(tmp), ACQ_BACKEND=backend, ACQ_NO_PROMPT="1",
               ACQ_PROVENANCE_DIR=str(provenance))
    log = work / "acq.log"
    with open(log, "wb") as sink:
        process = subprocess.Popen([shell, str(repo / "acq"), "rm", name], stdin=subprocess.DEVNULL,
                                   stdout=sink, stderr=sink, env=env, start_new_session=True)
    pid_file = work / "remove.pid"
    try:
        until(lambda: (pid_file.is_file() and pid_file.read_text().strip()) or process.poll() is not None,
              "the blocked remove")
        assert process.poll() is None, ("acq exited before the remove", log.read_text())
        child = int(pid_file.read_text())
        until(lambda: registered(tmp, child), "child registration")
        os.killpg(process.pid, sig)
        process.wait(timeout=90)
        rc = process.returncode
        # acq exits only once the terminate subshell has: the backend child is
        # gone and the lock released at that moment.
        assert not alive(child), (case, "acq exited before its backend child", log.read_text())
        locks = list(provenance.glob(f"provider-input/{backend}/{name}.*.lock"))
        assert not locks, (case, "acq exited before releasing the lock", locks)
        assert rc == 128 + sig, (case, "exit status", rc, log.read_text())
        with PRINT_LOCK:  # the cases run in threads; keep each line whole
            print(f"PASS {case} status {rc}", flush=True)
    except AssertionError as error:
        raise AssertionError(f"{case}: {error!r}") from None
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            process.wait(timeout=15)


cases = [(backend, sig) for backend in ("sbx", "msb") for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)]
with ThreadPoolExecutor(max_workers=len(cases)) as pool:
    futures = [pool.submit(run_case, *args) for args in cases]
failures = [(cases[i], f.exception()) for i, f in enumerate(futures) if f.exception()]
for args, error in failures:
    print("FAIL", args, error, file=sys.stderr)
sys.exit(1 if failures else 0)
