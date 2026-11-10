#!/usr/bin/env python3
# Ctrl-C during `acq create`: SIGINT (or SIGTERM) sent to acq's whole process
# group, as a terminal does, while the stubbed backend `create` is blocked and
# the spinner is animating on a TTY. acq must clean up the uncreated attempt
# exactly once (one confirm-absent listing, provider-input generation discarded,
# lock released, backend child reaped, cursor restored) and end with the
# conventional status: 130 for SIGINT, 143 for SIGTERM.
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
# registered as its backend child), and block until signalled. SIGINT is ignored
# in an asynchronous child of a non-interactive shell, so only acq's own
# TERM-to-children can end it, exactly as for the real backend CLI.
WRAPPER = """#!/bin/sh
case "${1:-}" in
  create)
    printf 'create-blocked\\n' >> "$CALLS"
    printf '%s\\n' "$$" > "@DIR@/create.pid"
    exec sleep 60 ;;
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


def run_case(backend, sig):
    case = f"{backend}-{signal.Signals(sig).name.lower()}"
    name = f"sig-{case}"
    work = stubdir / f"case-{case}"
    tmp = work / "tmp"
    for directory in (work / "bin", tmp, work / "proj"):
        directory.mkdir(parents=True)
    calls = work / "calls.log"
    calls.touch()
    wrapper = work / "bin" / backend
    wrapper.write_text(WRAPPER.replace("@DIR@", str(work)).replace("@STUBDIR@", str(stubdir))
                       .replace("@BACKEND@", backend))
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
        os.killpg(process.pid, sig)
        until(lambda: process.poll() is not None, master, output, "acq to exit", 90)
        drain(master, output)
        rc = process.returncode
        # SIGINT: the top-level shell waits for the provisioning subshell, whose
        # chained handlers exit 130, and exits with that status. SIGTERM: the
        # top-level shell has no TERM trap, so it dies of the signal at once
        # (-15 here, 143 to a calling shell) while the subshell finishes the
        # cleanup on its own; wait for that below.
        expected = (128 + sig,) if sig == signal.SIGINT else (128 + sig, -sig)
        assert rc in expected, (case, "exit status", rc, bytes(output[-600:]))
        until(lambda: not alive(child) and not list(
            provenance.glob(f"provider-input/{backend}/{name}.*.lock")),
            master, output, "cleanup after exit", 30)
        # The cursor is restored before the lock is released, but `until` stops
        # as soon as it sees the release, possibly before reading those bytes.
        # They are already in the PTY, so one more drain collects them.
        drain(master, output)
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
cases = [(backend, sig) for backend in ("sbx", "msb") for sig in (signal.SIGINT, signal.SIGTERM)]
with ThreadPoolExecutor(max_workers=4) as pool:
    futures = [pool.submit(run_case, *args) for args in cases]
failures = [(cases[i], f.exception()) for i, f in enumerate(futures) if f.exception()]
for args, error in failures:
    print("FAIL", args, error, file=sys.stderr)
sys.exit(1 if failures else 0)
