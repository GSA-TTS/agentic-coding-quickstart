#!/usr/bin/env python3
# Git Bash (MSYS2/Cygwin) emulation for the kit-fetch guardian, run against the
# real acq prefix with synthetic dispatch (no backend, no credentials).
#
# Git Bash's ps rejects -o ("ps: unknown option -- o"); its /proc instead has a
# per-process `ppid` file and an `exename` file holding the executable path. Here
# a fake ps that rejects -o goes first on PATH, and the guardian's /proc lookups
# are pointed at a directory that a populator thread keeps in that MSYS layout,
# mirrored from the real Linux /proc for the processes of each case's session. A
# guardian that still depends on `ps -o` exits on its first lookup and its EXIT
# trap removes the root, so later kit fetches fail; this test requires instead
# that it holds the root, lets a kit materialize, kills its tick promptly at exit,
# notices an orphaning (also when the procfs still names the dead owner as its
# parent, as Cygwin does after taskkill /F), and leaves an unrelated process alone.
#
# What this cannot model, and was instead checked on a real Git Bash host:
# - On MSYS a child's /proc/<pid>/ppid is readable as soon as `&` returns. Here
#   the populator needs a few milliseconds, so the guardian waits for its own
#   entry before starting, and a tick that is not mirrored yet just looks unknown.
# - The real exename contents (/usr/bin/sleep for the tick) and how Cygwin's
#   procfs behaves around exec are approximated from the Linux comm field.

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

repo, scratch = (Path(p).resolve() for p in sys.argv[1:3])
shell = sys.argv[3]
LATENCY_BOUND = 0.5  # a tick that is not killed costs up to ~1s
SETTLE_BOUND = 5.0   # orphan polling is once per second; keep margin for load

prefix = (repo / "acq").read_text().split("# Pre-parse global flags", 1)[0]
# On MSYS a process has its /proc entry from birth; the populator below needs a
# moment to mirror a new PID, so the guardian waits until its own entry exists.
START_LINE = '      owner=$1 root=$2 tick=""\n'
WAIT_LINE = '        wait "$tick" || :\n'
assert prefix.count(START_LINE) == 1, "guardian start changed; update the injection"
assert prefix.count(WAIT_LINE) == 1, "guardian loop changed; update the injection"
prefix = prefix.replace(START_LINE, START_LINE
                        + '      while [ ! -r "$FAKEPROC/$$/ppid" ]; do sleep 0.01; done\n')
# The bystander case points `tick` at an unrelated `sleep` right after the real
# tick was reaped and delivers USR1 there (what a reused PID looks like).
prefix = prefix.replace(WAIT_LINE, WAIT_LINE
                        + '        [ -z "$WINDOW_VICTIM" ] || { tick=$WINDOW_VICTIM;'
                        + ' kill -USR1 "$$"; }\n')
prefix = prefix.replace('"/proc/', '"$FAKEPROC/')

script = scratch / "acq"
(scratch / "acq.backends").symlink_to(repo / "acq.backends", target_is_directory=True)
script.write_text(prefix + r'''
printf 'READY %s %s %s\n' "$$" "$_ACQ_KIT_FETCH_ROOT" "$_ACQ_KIT_FETCH_GUARDIAN"
IFS= read -r value
stage=$(mktemp -d "$_ACQ_KIT_FETCH_ROOT/materialize.XXXXXX") && printf 'MATERIALIZED %s\n' "$stage"
IFS= read -r value
exit 0
''')

real_ps = shutil.which("ps")
assert real_ps, "ps not found"
fakebin = scratch / "fakebin"
fakebin.mkdir()
(fakebin / "ps").write_text('#!/bin/sh\nfor a in "$@"; do case "$a" in -o*|-*o*)\n'
                            '  echo "ps: unknown option -- o" >&2; exit 1 ;; esac; done\n'
                            'exec %s "$@"\n' % real_ps)
(fakebin / "ps").chmod(0o755)


class Populator(threading.Thread):
    """Mirror real processes into MSYS-style fake procfs trees, one per session."""

    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.trees = {}  # session id -> (fake proc dir, extra pids to mirror)
        self.stopping = threading.Event()

    def watch(self, sid, root, extra=(), frozen=False):
        with self.lock:
            self.trees[sid] = (root, set(extra), frozen)

    def forget(self, sid):
        with self.lock:
            self.trees.pop(sid, None)

    @staticmethod
    def write(path, text):
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(text)
        os.replace(tmp, path)

    def scan(self):
        table = {}
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                stat = Path("/proc", name, "stat").read_text()
                comm = stat[stat.index("(") + 1:stat.rindex(")")]
                fields = stat[stat.rindex(")") + 2:].split()
                table[int(name)] = (int(fields[1]), int(fields[3]), comm)
            except (OSError, ValueError, IndexError):
                continue  # the process exited while it was being read
        return table

    def mirror_tree(self, sid, root, extra, frozen, table):
        live = {pid for pid, (_, sess, _) in table.items() if sess == sid or pid in extra}
        for pid in live:
            entry = root / str(pid)
            entry.mkdir(exist_ok=True)
            ppid, _, comm = table[pid]
            self.write(entry / "exename", "/usr/bin/%s\n" % comm)
            # A frozen tree keeps each first-seen parent, as Cygwin does for a
            # child whose parent was killed outside Cygwin (taskkill /F).
            if not (frozen and (entry / "ppid").exists()):
                self.write(entry / "ppid", "%d\n" % ppid)
        for entry in root.iterdir():
            if entry.name.isdigit() and int(entry.name) not in live:
                shutil.rmtree(entry, ignore_errors=True)

    def run(self):
        while not self.stopping.is_set():
            table = self.scan()
            # Mirror while holding the lock, so forget() (and the rmtree its
            # caller does next) waits for any pass still writing into that tree.
            # One tree's error must never stop the thread the other cases need.
            with self.lock:
                for sid, (root, extra, frozen) in list(self.trees.items()):
                    try:
                        self.mirror_tree(sid, root, extra, frozen, table)
                    except OSError:
                        pass
            time.sleep(0.005)


populator = Populator()
populator.start()


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        return Path("/proc", str(pid), "stat").read_text().split(")")[-1].split()[0] != "Z"
    except OSError:
        return False


def until(process, marker):
    output = b""
    deadline = time.monotonic() + 10
    while marker not in output and time.monotonic() < deadline:
        if select.select([process.stdout], [], [], 0.1)[0]:
            block = os.read(process.stdout.fileno(), 4096)
            if not block:
                break
            output += block
    assert marker in output, (marker, output, "owner exit status", process.poll())
    return output.decode()


class Case:
    def __init__(self, victim=None, frozen=False):
        self.tmp = Path(tempfile.mkdtemp(prefix="case.", dir=scratch))
        self.fake = self.tmp / "proc"
        self.fake.mkdir()
        env = os.environ.copy()
        for key in tuple(env):
            if key.startswith(("ACQ_", "_ACQ_", "BASH_FUNC_")) or key == "BASH_ENV":
                del env[key]
        env.update(TMPDIR=str(self.tmp), HOME=str(scratch), XDG_CONFIG_HOME=str(scratch),
                   FAKEPROC=str(self.fake), WINDOW_VICTIM=str(victim or ""),
                   PATH="%s:%s" % (fakebin, env.get("PATH", "")))
        self.process = subprocess.Popen([shell, str(script)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, start_new_session=True)
        populator.watch(self.process.pid, self.fake, [victim] if victim else [], frozen)
        self.guardian = None
        try:
            ready = until(self.process, b"READY").splitlines()[0].split()
            assert int(ready[1]) == self.process.pid, ready
            self.root, self.guardian = Path(ready[2]), int(ready[3])
        except BaseException:
            self.close()
            raise

    def send(self, line):
        self.process.stdin.write(line)
        self.process.stdin.flush()

    def fresh_tick(self):
        """Wait for a newly started tick to show up in the fake procfs as `sleep`."""
        deadline = time.monotonic() + SETTLE_BOUND
        seen = None
        while time.monotonic() < deadline:
            current = set()
            for entry in self.fake.iterdir():
                try:
                    if (entry.name.isdigit()
                            and (entry / "ppid").read_text().strip() == str(self.guardian)
                            and (entry / "exename").read_text().strip().endswith("/sleep")):
                        current.add(int(entry.name))
                except OSError:
                    pass
            if seen is not None and current - seen:
                return
            seen = current if seen is None else seen | current
            time.sleep(0.005)
        raise AssertionError("guardian never started a fresh tick")

    def gone(self, since, bound):
        while time.monotonic() - since < bound:
            if not (self.root.exists() or alive(self.guardian)):
                return time.monotonic() - since
            time.sleep(0.02)
        raise AssertionError(("leaked", {"root": self.root.exists(),
                                         "guardian": alive(self.guardian)}))

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None:
                stream.close()
        # The guardian is still in the case's session, so only it can be matched.
        if self.guardian is not None and alive(self.guardian):
            try:
                if os.getsid(self.guardian) == self.process.pid:
                    os.kill(self.guardian, signal.SIGKILL)
            except ProcessLookupError:
                pass
        populator.forget(self.process.pid)
        shutil.rmtree(self.tmp, ignore_errors=True)


def holds_root_and_exits_promptly():
    case = Case()
    try:
        time.sleep(2.5)  # at least two guardian ppid lookups
        assert alive(case.guardian), "guardian died: parent lookup failed without ps -o"
        assert case.root.is_dir(), "kit-fetch root removed while the owner is alive"
        case.send(b"go\n")
        stage = Path(until(case.process, b"MATERIALIZED").split("MATERIALIZED ", 1)[1].split()[0])
        assert stage.is_dir() and stage.parent == case.root, stage
        case.fresh_tick()
        said = time.monotonic()
        case.send(b"bye\n")
        code = case.process.wait(timeout=SETTLE_BOUND)
        delay = time.monotonic() - said
        assert code == 0 and delay < LATENCY_BOUND, ("tick not killed at exit", code, delay)
        case.gone(said, LATENCY_BOUND)
        errors = case.process.stderr.read().decode()
        assert not errors, errors
        return "held-root-materialized exit-latency %.3fs" % delay
    finally:
        case.close()


def orphaned(frozen=False):
    """SIGKILL the owner; the guardian must notice and remove the root.

    With `frozen`, the guardian's ppid file keeps naming the dead owner, which is
    what Cygwin shows after the owner is killed with taskkill /F, so only the
    owner liveness check can notice.
    """
    case = Case(frozen=frozen)
    try:
        time.sleep(1.5)
        assert alive(case.guardian) and case.root.is_dir(), "guardian did not hold the root"
        started = time.monotonic()
        case.process.kill()
        case.process.wait(timeout=SETTLE_BOUND)
        took = case.gone(started, SETTLE_BOUND)
        return "%s-removed-after %.3fs" % ("stale-ppid-owner-kill" if frozen else "sigkill", took)
    finally:
        case.close()


def bystander_spared():
    bystander = subprocess.Popen(["sleep", "30"])
    try:
        case = Case(victim=bystander.pid)
        try:
            started = time.monotonic()
            case.gone(started, SETTLE_BOUND)  # first tick ends, then the window USR1
            assert bystander.poll() is None, ("guardian killed an unrelated process",
                                             bystander.poll())
            return "window-bystander-spared %.3fs" % (time.monotonic() - started)
        finally:
            case.close()
    finally:
        bystander.kill()
        bystander.wait()


def orphaned_stale_ppid():
    return orphaned(frozen=True)


jobs = [holds_root_and_exits_promptly, orphaned, orphaned_stale_ppid, bystander_spared]
with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
    futures = [pool.submit(job) for job in jobs]
failures = 0
for job, future in zip(jobs, futures):
    if future.exception() is not None:
        failures += 1
        print("FAIL", job.__name__, repr(future.exception()), file=sys.stderr)
    else:
        print("PASS", future.result())
populator.stopping.set()
sys.exit(1 if failures else 0)
