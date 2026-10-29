#!/usr/bin/env python3
# Exit latency and process-leak checks for the kit-fetch guardian, run against the
# real acq prefix with synthetic dispatch (no backend, no credentials). The
# guardian's one-second tick must neither delay the foreground shell's exit nor
# outlive it, and the private root must still disappear when the owner is killed.

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

repo, scratch = (Path(p).resolve() for p in sys.argv[1:3])
shell = sys.argv[3]
LATENCY_BOUND = 0.5  # a stuck tick costs ~0.9s; a healthy exit costs ~0.01s
SETTLE_BOUND = 5.0  # orphan polling is once per second; keep margin for load

prefix = (repo / "acq").read_text().split("# Pre-parse global flags", 1)[0]
script = scratch / "acq"
(scratch / "acq.backends").symlink_to(repo / "acq.backends", target_is_directory=True)
script.write_text(prefix + r'''
printf 'READY %s %s %s\n' "$$" "$_ACQ_KIT_FETCH_ROOT" "$_ACQ_KIT_FETCH_GUARDIAN"
case "$1" in
  latency) printf 'ARMED\n'; IFS= read -r value; printf 'BYE\n'; exit 0 ;;
  signal) printf 'ARMED\n'; IFS= read -r value ;;
  replace) printf 'ARMED\n'; IFS= read -r value; trap ':' EXIT; exit 19 ;;
  exec) printf 'ARMED\n'; IFS= read -r value; exec sh -c 'exit 0' ;;
esac
''')


def environment():
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith(("ACQ_", "_ACQ_", "BASH_FUNC_")) or key == "BASH_ENV":
            del env[key]
    env.update(TMPDIR=str(scratch), HOME=str(scratch), XDG_CONFIG_HOME=str(scratch))
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
    def __init__(self, mode):
        self.process = subprocess.Popen([shell, str(script), mode], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=environment(), start_new_session=True)
        self.output = until(self.process, b"ARMED").decode()
        ready = self.output.splitlines()[0].split()
        assert int(ready[1]) == self.process.pid, self.output
        self.root = Path(ready[2])
        self.guardian = int(ready[3])
        self.tick = fresh_tick(self.guardian)

    def finish(self, label, since=None):
        """Collect the exit, then require root, guardian and tick to be gone.

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
        self.output += rest.decode()
        assert not errors, (label, errors)
        while time.monotonic() - since < SETTLE_BOUND:
            if not (self.root.exists() or alive(self.guardian) or alive(self.tick)):
                return time.monotonic() - since
            time.sleep(0.02)
        raise AssertionError((label, "leaked",
                              {"root": self.root.exists(), "guardian": alive(self.guardian),
                               "tick": alive(self.tick)}))

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        for pid in (self.guardian, self.tick):
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
        subprocess.run(["rm", "-rf", "--", str(self.root)], check=False)


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
        case.finish("exit", said)
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
        case.finish(signal.Signals(sig).name, sent)
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


jobs = [latency_exit, lambda: latency_signal(signal.SIGTERM), lambda: latency_signal(signal.SIGINT),
        lambda: latency_signal(signal.SIGHUP), lambda: settles("replace", "replaced-trap"),
        lambda: settles("exec", "exec"), orphaned]
with ThreadPoolExecutor(max_workers=4) as pool:
    for result in [pool.submit(job) for job in jobs]:
        print("PASS", result.result())
