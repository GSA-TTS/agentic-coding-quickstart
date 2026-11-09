#!/usr/bin/env python3
# Git Bash (MSYS2/Cygwin) emulation for the provider-input transaction guardian
# and lock-owner identity, run against a copy of the real acq and adapters with
# stubbed backend bodies (no backend, no credentials).
#
# Git Bash's ps rejects -o ("ps: unknown option -- o"). Its /proc instead has a
# per-process `ppid` file, and the /proc/<pid> directory's mtime is the process
# start time in whole seconds. Here a fake ps that rejects -o goes first on PATH
# and the adapters' /proc lookups are pointed at a directory that a populator
# thread keeps in that layout, mirrored from the real Linux /proc for each
# scenario's session. Each fake /proc/<pid> is a symlink whose own mtime is the
# start time, so rewriting its ppid file never disturbs the identity. Code that
# still depends on `ps -o` cannot start the guardian or compute an identity, so
# provision and terminate exit 1 before their bodies run.
#
# What this cannot model, and was instead checked on a real Git Bash host:
# - Cygwin keeps the /proc/<pid> mtime across exec (the stat starttime field
#   changes there). Linux start times never change, so a mutant that used the
#   stat field would still pass here.
# - On MSYS a child's /proc/<pid>/ppid is readable as soon as `&` returns. Here
#   the populator needs a few milliseconds, so the copy waits for the guardian's
#   entry right after starting it, which hides any lag in the real procfs.

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

repo, scratch = (Path(p).resolve() for p in sys.argv[1:3])
shell = sys.argv[3]

copy = scratch / "repo"
copy.mkdir()
shutil.copy2(repo / "acq", copy / "acq")
shutil.copytree(repo / "acq.backends", copy / "acq.backends")
common = copy / "acq.backends" / "common.sh"
text = common.read_text()
# On MSYS a process has its /proc entry from birth; the populator needs a moment
# to mirror a new PID, so wait for the guardian's entry right after it starts.
SPAWN_LINE = "  _ACQ_PROVIDER_INPUT_GUARDIAN_PID=$!\n"
assert text.count(SPAWN_LINE) == 1, "guardian start changed; update the injection"
text = text.replace(SPAWN_LINE, SPAWN_LINE + '  while [ ! -r "$FAKEPROC/$_ACQ_PROVIDER_INPUT_GUARDIAN_PID/ppid" ];'
                    ' do sleep 0.01; done\n')
common.write_text(text.replace('"/proc/', '"$FAKEPROC/'))

real_ps = shutil.which("ps")
assert real_ps, "ps not found"
fakebin = scratch / "fakebin"
fakebin.mkdir()
(fakebin / "ps").write_text('#!/bin/sh\nfor a in "$@"; do case "$a" in -o*|-*o*)\n'
                            '  echo "ps: unknown option -- o" >&2; exit 1 ;; esac; done\n'
                            'exec %s "$@"\n' % real_ps)
(fakebin / "ps").chmod(0o755)

BOOT = next(int(line.split()[1]) for line in Path("/proc/stat").read_text().splitlines()
            if line.startswith("btime "))
HZ = os.sysconf("SC_CLK_TCK")


class Populator(threading.Thread):
    """Mirror real processes into MSYS-style fake procfs trees, one per session."""

    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.trees = {}  # session id -> fake proc dir
        self.made = {}   # (fake proc dir, pid) -> start ticks of the mirrored process
        self.stopping = threading.Event()

    def watch(self, sid, root):
        (root / ".data").mkdir(parents=True)
        with self.lock:
            self.trees[sid] = root

    def forget(self, sid):
        with self.lock:
            self.trees.pop(sid, None)

    @staticmethod
    def scan():
        table = {}
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                stat = Path("/proc", name, "stat").read_text()
                fields = stat[stat.rindex(")") + 2:].split()
                table[int(name)] = (int(fields[1]), int(fields[3]), int(fields[19]))
            except (OSError, ValueError, IndexError):
                continue  # the process exited while it was being read
        return table

    def mirror(self, root, pid, ppid, start):
        data = root / ".data" / str(pid)
        data.mkdir(exist_ok=True)
        ppid_file = data / "ppid"
        want = "%d\n" % ppid
        try:
            current = ppid_file.read_text()
        except OSError:
            current = None
        if current != want:
            tmp = data / "ppid.tmp"
            tmp.write_text(want)
            os.replace(tmp, ppid_file)
        if self.made.get((root, pid)) != start:
            link, tmp = root / str(pid), root / (".link.%d" % pid)
            if os.path.lexists(tmp):
                os.unlink(tmp)
            os.symlink(Path(".data", str(pid)), tmp)
            seconds = BOOT + start // HZ
            os.utime(tmp, (seconds, seconds), follow_symlinks=False)
            os.replace(tmp, link)
            self.made[(root, pid)] = start

    def mirror_tree(self, sid, root, table):
        live = {pid for pid, (_, sess, _) in table.items() if sess == sid}
        for pid in live:
            ppid, _, start = table[pid]
            self.mirror(root, pid, ppid, start)
        for entry in root.iterdir():
            if entry.name.isdigit() and int(entry.name) not in live:
                os.unlink(entry)
                shutil.rmtree(root / ".data" / entry.name, ignore_errors=True)
                self.made.pop((root, int(entry.name)), None)

    def run(self):
        while not self.stopping.is_set():
            table = self.scan()
            # Mirror while holding the lock, so forget() waits for any pass still
            # writing into that tree. One tree's error must never stop the thread
            # the other scenarios need.
            with self.lock:
                for sid, root in list(self.trees.items()):
                    try:
                        self.mirror_tree(sid, root, table)
                    except OSError:
                        pass
            time.sleep(0.005)


populator = Populator()
populator.start()

HEADER = r'''
set -u
while [ ! -r "$FAKEPROC/$$/ppid" ]; do sleep 0.01; done
ACQ_SCRIPT_DIR="$COPY" ACQ_SOURCE_ONLY=1 . "$COPY/acq"
. "$COPY/acq.backends/sbx.sh"
set +e
fail() { printf 'FAILED: %s\n' "$*"; exit 1; }
'''

SCENARIOS = {
    # Provision and terminate run their bodies under a guardian-owned lock.
    "provision-terminate": r'''
_acq_backend_provision_unlocked() {
  lock="$(acq_provider_input_root sbx box).lock"
  read -r owner identity < "$lock/owner" || exit 90
  [ "$owner" = "$_ACQ_PROVIDER_INPUT_GUARDIAN_PID" ] || exit 91
  case "$identity" in ""|*[!0-9]*) exit 92 ;; esac
  case "$_ACQ_PROVIDER_INPUT_TRANSACTION_PID" in ""|*[!0-9]*) exit 93 ;; esac
  [ "$_ACQ_PROVIDER_INPUT_TRANSACTION_PID" != "$$" ] || exit 94
  kill -0 "$_ACQ_PROVIDER_INPUT_TRANSACTION_PID" || exit 95
  echo PROVISION-RAN
}
_acq_backend_terminate_unlocked() { echo TERMINATE-RAN; }
acq_backend_provision box shell /tmp || fail "provision rc=$?"
acq_backend_terminate box || fail "terminate rc=$?"
[ ! -e "$(acq_provider_input_root sbx box).lock" ] || fail "lock left behind"
echo SCENARIO-OK
''',
    # A live owner whose start time does not match (a reused PID) is stale; a live
    # owner whose start time matches is never broken.
    "identity": r'''
lock="$(acq_provider_input_root sbx stalebox).lock"
_acq_provider_input_safe_mkdir "$lock" || fail mkdir
printf '%s 1\n' "$$" > "$lock/owner"
out=$(acq_provider_input_lock_acquire sbx stalebox 2>&1) || fail "reused pid not recovered: $out"
case "$out" in *"recovering stale"*) ;; *) fail "no recovery message: $out" ;; esac
acq_provider_input_lock_release "$lock" || fail release
identity=$(_acq_provider_input_process_identity "$$") || fail "no identity for a live pid"
case "$identity" in *[!0-9]*) fail "identity not from the MSYS procfs: $identity" ;; esac
# It is this PID's start time, checked against the real Linux /proc rather than
# the fake tree; it differs for a process started over a second later; and it
# does not drift while the owner lives.
real_start() { awk -v b="$BTIME" -v hz="$HZ" '{ sub(/.*\) /, ""); printf "%d\n", b + int($20 / hz) }' "/proc/$1/stat"; }
want=$(real_start "$$")
[ "$identity" -ge $((want - 1)) ] && [ "$identity" -le $((want + 1)) ] || fail "identity $identity is not start time $want"
sleep 30 & first=$!
sleep 1.2
sleep 30 & second=$!
for p in "$first" "$second"; do
  n=0; while [ ! -r "$FAKEPROC/$p/ppid" ] && [ "$n" -lt 300 ]; do sleep 0.01; n=$((n + 1)); done
done
a=$(_acq_provider_input_process_identity "$first"); b=$(_acq_provider_input_process_identity "$second")
kill "$first" "$second"; wait "$first" "$second" 2>/dev/null
[ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || fail "processes 1.2s apart share an identity: '$a' '$b'"
sleep 1.2
again=$(_acq_provider_input_process_identity "$$")
[ "$again" = "$identity" ] || fail "live owner identity drifted: $identity -> $again"
_acq_provider_input_safe_mkdir "$lock" || fail mkdir
printf '%s %s\n' "$$" "$identity" > "$lock/owner"
if out=$(ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire sbx stalebox 2>&1); then
  fail "live owner was broken"
fi
case "$out" in *"owned by live pid $$"*) ;; *) fail "unexpected: $out" ;; esac
echo SCENARIO-OK
''',
    # SIGKILL of the transaction subshell cannot free the lock while its guardian
    # lives; once the guardian notices and exits, the lock is recoverable. The
    # guardian polls once a second and leaves soon after its parent dies, so a
    # registered backend child keeps it alive for a fixed window; otherwise a
    # loaded host could reach the retry only after the guardian had (correctly)
    # gone.
    "parent-exit": r'''
(
  _acq_provider_input_guardian_start || exit 1
  acq_provider_input_lock_acquire sbx parentexit "$_ACQ_PROVIDER_INPUT_GUARDIAN_PID" >/dev/null || exit 1
  sleep 6 & _acq_provider_input_guardian_register_child "$!" || exit 1
  printf '%s\n' "$_ACQ_PROVIDER_INPUT_GUARDIAN_PID" > "$WORK/guardian.pid"
  sleep 10
) &
parent=$!
n=0
while [ ! -s "$WORK/guardian.pid" ] && kill -0 "$parent" 2>/dev/null && [ "$n" -lt 100 ]; do
  sleep 0.1; n=$((n + 1))
done
[ -s "$WORK/guardian.pid" ] || fail "transaction never took the lock"
guardian=$(cat "$WORK/guardian.pid")
kill -KILL "$parent"
if out=$(ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire sbx parentexit 2>&1); then
  fail "lock recovered while the guardian was alive"
fi
case "$out" in *"owned by live pid $guardian"*) ;; *) fail "unexpected: $out" ;; esac
wait "$parent" 2>/dev/null
n=0
while kill -0 "$guardian" 2>/dev/null && [ "$n" -lt 150 ]; do sleep 0.1; n=$((n + 1)); done
lock=$(acq_provider_input_lock_acquire sbx parentexit 2>/dev/null) || fail "lock not recoverable"
acq_provider_input_lock_release "$lock" || fail release
echo SCENARIO-OK
''',
}


def run(name):
    work = scratch / name
    fake = work / "proc"
    work.mkdir()
    script = work / "scenario.sh"
    script.write_text(HEADER + SCENARIOS[name])
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith(("ACQ_", "_ACQ_", "BASH_FUNC_")) or key == "BASH_ENV":
            del env[key]
    env.update(TMPDIR=str(work), HOME=str(work), XDG_CONFIG_HOME=str(work / "cfg"),
               XDG_STATE_HOME=str(work / "state"), ACQ_PROVENANCE_DIR=str(work / "prov"),
               ACQ_STATE_DIR=str(work / "state" / "acq"),
               ACQ_SECRET_STORE_DIR=str(work / "state" / "sec"),
               FAKEPROC=str(fake), COPY=str(copy), WORK=str(work), BTIME=str(BOOT), HZ=str(HZ),
               PATH="%s:%s" % (fakebin, env.get("PATH", "")))
    process = subprocess.Popen([shell, str(script)], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=env, start_new_session=True)
    populator.watch(process.pid, fake)
    try:
        output, _ = process.communicate(timeout=60)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, 9)
            process.wait()
        populator.forget(process.pid)
    output = output.decode()
    assert process.returncode == 0 and "SCENARIO-OK" in output, (name, process.returncode, output)
    if name == "provision-terminate":
        assert "PROVISION-RAN" in output and "TERMINATE-RAN" in output, output
    return name


names = list(SCENARIOS)
with ThreadPoolExecutor(max_workers=len(names)) as pool:
    futures = [pool.submit(run, name) for name in names]
failures = 0
for name, future in zip(names, futures):
    if future.exception() is not None:
        failures += 1
        print("FAIL", name, repr(future.exception()), file=sys.stderr)
    else:
        print("PASS", future.result())
populator.stopping.set()
sys.exit(1 if failures else 0)
