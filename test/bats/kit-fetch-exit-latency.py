#!/usr/bin/env python3
# Exit latency and process-leak checks for the kit-fetch guardian, run against the
# real acq prefix with synthetic dispatch (no backend, no credentials). The
# guardian's one-second tick must neither delay the foreground shell's exit nor
# outlive it, and the private root must still disappear when the owner is killed.

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

repo, scratch = (Path(p).resolve() for p in sys.argv[1:3])
shell = sys.argv[3]
LATENCY_BOUND = 0.5  # a stuck tick costs ~0.9s; a healthy exit costs ~0.01s
SETTLE_BOUND = 5.0  # orphan polling is once per second; keep margin for load

prefix = (repo / "acq").read_text().split("# Pre-parse global flags", 1)[0]
# The window variant adds one line to the guardian loop, directly after `wait "$tick"`
# has reaped the tick, and delivers USR1 to the guardian itself there. That is the
# exact state a real USR1 would find if it arrived in that window: `tick` still set
# but the child already reaped. With WINDOW_VICTIM set it also points `tick` at that
# unrelated process, which is what a reused PID looks like; without it the real
# stale value is left in place. With WINDOW_DOUBLE set, a stream of USR1s follows the
# first for ~0.3s and `ps` is slowed to 0.1s, so several land while the exit trap runs. With WINDOW_CHILD set, `tick` is instead a live
# child of the guardian that is not a `sleep`.
WAIT_LINE = '        wait "$tick" || :\n'
assert prefix.count(WAIT_LINE) == 1, "guardian loop changed; update the window injection"
window_prefix = prefix.replace(WAIT_LINE, WAIT_LINE
                               + '        [ -z "$WINDOW_VICTIM" ] || tick=$WINDOW_VICTIM\n'
                               + '        [ -z "$WINDOW_CHILD" ] || { sh -c "sleep 2; :" & tick=$!; }\n'
                               + '        [ -z "$WINDOW_DOUBLE" ] || ps() { sleep 0.1; command ps "$@"; }\n'
                               + '        [ -z "$WINDOW_DOUBLE" ] || { (n=0; while [ "$n" -lt 300 ]; do sleep 0.001;'
                               + ' kill -USR1 "$$" 2>/dev/null || break; n=$((n+1)); done) & }\n'
                               + '        kill -USR1 "$$"\n')
script = scratch / "acq"
window_script = scratch / "acq-window"
(scratch / "acq.backends").symlink_to(repo / "acq.backends", target_is_directory=True)
BODY = r'''
printf 'READY %s %s %s\n' "$$" "$_ACQ_KIT_FETCH_ROOT" "$_ACQ_KIT_FETCH_GUARDIAN"
case "$1" in
  latency) printf 'ARMED\n'; IFS= read -r value; printf 'BYE\n'; exit 0 ;;
  signal) printf 'ARMED\n'; IFS= read -r value ;;
  replace) printf 'ARMED\n'; IFS= read -r value; trap ':' EXIT; exit 19 ;;
  exec) printf 'ARMED\n'; IFS= read -r value; exec sh -c 'exit 0' ;;
esac
'''
script.write_text(prefix + BODY)
window_script.write_text(window_prefix + BODY)


def environment(tmp):
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith(("ACQ_", "_ACQ_", "BASH_FUNC_")) or key == "BASH_ENV":
            del env[key]
    env.update(TMPDIR=str(tmp), HOME=str(scratch), XDG_CONFIG_HOME=str(scratch))
    return env


def processes():
    table = {}
    for line in subprocess.check_output(["ps", "-eo", "pid=,ppid=,comm="], text=True).splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3:
            table[int(fields[0])] = (int(fields[1]), os.path.basename(fields[2]))
    return table


def ticks(guardian):
    return {pid for pid, (ppid, comm) in processes().items() if ppid == guardian and comm == "sleep"}


def identity(pid):
    """What a PID is right now, or None. Start time makes a reused PID differ."""
    try:
        out = subprocess.check_output(["ps", "-o", "ppid=,comm=,lstart=", "-p", str(pid)],
                                      text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return None
    fields = out.split(None, 2)
    if len(fields) < 3:
        return None
    return (os.path.basename(fields[1]), " ".join(fields[2].split()))


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return processes().get(pid, (0, ""))[1] != ""


def until(process, marker):
    output = b""
    deadline = time.monotonic() + 5
    while marker not in output and time.monotonic() < deadline:
        if select.select([process.stdout], [], [], 0.1)[0]:
            block = os.read(process.stdout.fileno(), 4096)
            if not block:
                break
            output += block
    assert marker in output, output
    return output


def fresh_tick(guardian):
    # A tick that just started has almost a full second left, so a guardian that
    # waits for it to finish is unmistakable rather than lucky-fast.
    deadline = time.monotonic() + 5
    seen = set()
    while time.monotonic() < deadline:
        current = ticks(guardian)
        if seen and current - seen:
            return next(iter(current - seen))
        seen |= current
        time.sleep(0.005)
    raise AssertionError("guardian never started a fresh tick")


class Case:
    def __init__(self, mode, window=None, wait_for_tick=True, child=False, double=False):
        """Start an acq owner; leave nothing behind if startup fails part-way.

        Every process this case may later kill is recorded together with its
        identity (command and start time) the moment it is discovered, so close()
        never signals a PID whose identity is unknown or has changed.
        """
        self.process = None
        self.known = {}
        self.guardian = self.tick = self.root = None
        self.tmp = Path(tempfile.mkdtemp(prefix="case.", dir=scratch))
        try:
            env = environment(self.tmp)
            if window is not None:
                env["WINDOW_VICTIM"] = str(window)
                env["WINDOW_CHILD"] = "1" if child else ""
                env["WINDOW_DOUBLE"] = "1" if double else ""
            self.process = subprocess.Popen(
                [shell, str(window_script if window is not None else script), mode],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=env, start_new_session=True)
            self.output = until(self.process, b"ARMED").decode()
            ready = self.output.splitlines()[0].split()
            assert int(ready[1]) == self.process.pid, self.output
            self.root = Path(ready[2])
            self.guardian = int(ready[3])
            self.remember(self.guardian)
            if wait_for_tick:
                self.tick = fresh_tick(self.guardian)
                self.remember(self.tick)
        except BaseException:
            self.close()
            raise

    def remember(self, pid):
        self.known[pid] = identity(pid)

    def kill_known(self, pid):
        """SIGKILL pid only if it is still the very process recorded earlier."""
        seen = self.known.get(pid)
        if seen is not None and identity(pid) == seen:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def finish(self, label, since=None, bound=SETTLE_BOUND):
        """Collect the exit, then require root, guardian and tick to be gone.

        `bound` is how long everything may take to disappear; the guardian is
        signalled directly in the exit and signal cases, so those use the tight
        LATENCY_BOUND and an orphaned tick that merely times out is a failure.
        The guardian shares the owner's stderr pipe, so communicate() also waits
        for the guardian to exit; time is therefore measured from `since`.
        """
        since = time.monotonic() if since is None else since
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        self.process.stdin = None
        rest, errors = self.process.communicate(timeout=SETTLE_BOUND)
        # communicate() also waited for the guardian's end of the stderr pipe.
        self.output += rest.decode()
        assert not errors, (label, errors)
        while time.monotonic() - since < bound:
            if not (self.root.exists() or alive(self.guardian) or alive(self.tick)):
                return time.monotonic() - since
            time.sleep(0.02)
        raise AssertionError((label, "leaked",
                              {"root": self.root.exists(), "guardian": alive(self.guardian),
                               "tick": alive(self.tick)}))

    def close(self):
        process = self.process
        if process is not None:
            if process.poll() is None:
                # Children of a live, unreaped owner cannot have a reused PID; this
                # catches a guardian started before READY was parsed.
                table = processes()
                family = {process.pid}
                grew = True
                while grew:
                    grew = False
                    for pid, (ppid, _) in table.items():
                        if ppid in family and pid not in family:
                            family.add(pid)
                            grew = True
                for pid in family - {process.pid}:
                    if pid not in self.known:
                        self.remember(pid)
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        for pid in (self.guardian, self.tick, *self.known):
            if pid is not None:
                self.kill_known(pid)
        shutil.rmtree(self.tmp, ignore_errors=True)


def latency_exit():
    case = Case("latency")
    try:
        case.process.stdin.write(b"go\n")
        case.process.stdin.flush()
        until(case.process, b"BYE")
        said = time.monotonic()
        code = case.process.wait(timeout=SETTLE_BOUND)
        delay = time.monotonic() - said
        assert code == 0 and delay < LATENCY_BOUND, ("exit", code, delay)
        case.finish("exit", said, LATENCY_BOUND)
        return "exit-latency %.3fs" % delay
    finally:
        case.close()


def latency_signal(sig):
    case = Case("signal")
    try:
        sent = time.monotonic()
        case.process.send_signal(sig)
        code = case.process.wait(timeout=SETTLE_BOUND)
        delay = time.monotonic() - sent
        assert code in (-sig, 128 + sig) and delay < LATENCY_BOUND, (sig, code, delay)
        case.finish(signal.Signals(sig).name, sent, LATENCY_BOUND)
        return "%s-latency %.3fs" % (signal.Signals(sig).name, delay)
    finally:
        case.close()


def settles(mode, label, stdin=b"go\n"):
    case = Case(mode)
    try:
        started = time.monotonic()
        case.process.stdin.write(stdin)
        case.process.stdin.flush()
        case.process.wait(timeout=SETTLE_BOUND)
        return "%s-removed-after %.3fs" % (label, case.finish(label, started))
    finally:
        case.close()


def orphaned():
    case = Case("signal")
    try:
        started = time.monotonic()
        case.process.kill()
        case.process.wait(timeout=SETTLE_BOUND)
        return "sigkill-removed-after %.3fs" % case.finish("sigkill", started)
    finally:
        case.close()


def window_child():
    """USR1 in the window while `tick` is a live guardian child that is not `sleep`.

    The ppid check alone would accept it; only the command-name check spares it.
    The guardian must wait the child out (about two seconds) rather than kill it.
    """
    case = Case("signal", window="", wait_for_tick=False, child=True)
    try:
        started = time.monotonic()
        deadline = started + 3 * SETTLE_BOUND
        while time.monotonic() < deadline and alive(case.guardian):
            time.sleep(0.02)
        took = time.monotonic() - started
        assert not alive(case.guardian), "guardian did not exit"
        assert took > 2.0, ("guardian killed a non-sleep child", took)
        case.process.kill()
        case.process.wait(timeout=SETTLE_BOUND)
        errors = case.process.stderr.read().decode()
        assert not errors, errors
        return "window-non-sleep-child-spared %.3fs" % took
    finally:
        case.close()


def window(victim, double=False):
    """USR1 arrives after `wait` reaped the tick but before `tick` is cleared.

    With a victim, `tick` holds the PID of an unrelated `sleep` that is not the
    guardian's child (what a reused PID looks like); the guardian must exit
    without signalling it. Without one, `tick` is the real reaped PID and the
    guardian must still exit cleanly and quietly.
    """
    bystander = subprocess.Popen(["sleep", "30"]) if victim else None
    case = None
    try:
        if bystander is not None:
            bystander_id = identity(bystander.pid)
            assert bystander_id is not None and bystander_id[0] == "sleep", bystander_id
        case = Case("signal", window=bystander.pid if victim else "", wait_for_tick=False,
                    double=double)
        started = time.monotonic()
        # The guardian reaches the window when its first one-second tick ends.
        deadline = started + SETTLE_BOUND
        while time.monotonic() < deadline and alive(case.guardian):
            time.sleep(0.02)
        assert not alive(case.guardian), "guardian did not exit from the window USR1"
        assert not case.root.exists(), "root left behind"
        if bystander is not None:
            assert bystander.poll() is None, ("guardian killed an unrelated process",
                                             bystander.poll())
            assert identity(bystander.pid) == bystander_id
        case.process.kill()
        case.process.wait(timeout=SETTLE_BOUND)
        errors = case.process.stderr.read().decode()
        assert not errors, errors
        return "window-%s %.3fs" % ("bystander-spared" if victim else
                                    "double-usr1-clean" if double else "stale-pid-clean",
                                    time.monotonic() - started)
    finally:
        if case is not None:
            case.close()
        if bystander is not None:
            bystander.kill()
            bystander.wait()


jobs = [lambda: window(True), lambda: window(False), lambda: window(False, True), window_child, latency_exit, lambda: latency_signal(signal.SIGTERM), lambda: latency_signal(signal.SIGINT),
        lambda: latency_signal(signal.SIGHUP), lambda: settles("replace", "replaced-trap"),
        lambda: settles("exec", "exec"), orphaned]
with ThreadPoolExecutor(max_workers=4) as pool:
    for result in [pool.submit(job) for job in jobs]:
        print("PASS", result.result())
