#!/usr/bin/env python3
# Use the executable's real prefix with synthetic dispatch, never a backend or
# credential store. Python's subprocess/PTY tools deliver signals without the
# ignored SIGINT disposition imposed by a shell's asynchronous command list.

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import time

repo, scratch = (Path(p).resolve() for p in sys.argv[1:3])
shell = sys.argv[3]
source = (repo / "acq").read_text()
prefix = source.split("# Pre-parse global flags", 1)[0]
script = scratch / "acq"
(scratch / "acq.backends").symlink_to(repo / "acq.backends", target_is_directory=True)
script.write_text(prefix + r'''
printf 'READY %s %s %s\n' "$$" "$_ACQ_KIT_FETCH_ROOT" "$_ACQ_KIT_FETCH_GUARDIAN"
case "$1" in
  success) exit 0 ;;
  failure) exit 37 ;;
  replace) trap ':' EXIT; exit 19 ;;
  clear) trap - EXIT; exit 23 ;;
  stdin) IFS= read -r value; printf 'INPUT %s\n' "$value" ;;
  tty) [ -t 0 ] && [ -t 1 ]; IFS= read -r value; printf 'TTY %s\n' "$value" ;;
  nested) "$BASH" "$0" success; [ -d "$_ACQ_KIT_FETCH_ROOT" ]; printf 'OUTER-LIVE\n' ;;
  spinner) _acq_spin_install_traps; printf 'ARMED\n'; IFS= read -r value ;;
  prompt) trap 'trap - INT; kill -s INT $$' INT; printf 'ARMED\n'; IFS= read -r value ;;
  foreground) printf 'ARMED\n'; sleep 30; printf 'UNEXPECTED\n' ;;
  survive) sleep 2; [ -d "$_ACQ_KIT_FETCH_ROOT" ]; printf 'ROOT-LIVE\n' ;;
  exec)
    exec "$BASH" -c 'printf "EXEC %s\n" "$$"; IFS= read -r value'
    ;;
  signal) printf 'ARMED\n'; IFS= read -r value ;;
esac
''')


def environment(path=None):
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith(("ACQ_", "_ACQ_", "BASH_FUNC_")) or key == "BASH_ENV":
            del env[key]
    env.update(TMPDIR=str(scratch), HOME=str(scratch), XDG_CONFIG_HOME=str(scratch))
    # A stale inherited root must never be adopted by a new invocation.
    env["_ACQ_KIT_FETCH_ROOT"] = str(scratch / "unrelated")
    if path is not None:
        env["PATH"] = f"{path}{os.pathsep}{env.get('PATH', '')}"
    return env


def ps_wrapper(name, body):
    # A `ps` placed first on PATH reaches only the guardian's parent lookups: the
    # harness's own ps calls run with the harness's PATH.
    directory = scratch / name
    directory.mkdir()
    wrapper = directory / "ps"
    wrapper.write_text(f"#!{sys.executable} -I\n" + body)
    wrapper.chmod(0o755)
    return directory


# Like procps ps, the slow wrapper dies from SIGTERM even though the guardian
# ignores it, and it holds the guardian's lookup open long enough for a group
# SIGTERM to land inside it every time. The marker says the window is open.
REAL_PS = shutil.which("ps")
SLOW_PS = ps_wrapper("slow-ps", f"""import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_DFL)
open({str(scratch / "slow-ps.started")!r}, "a").close()
time.sleep(3)
os.execv({REAL_PS!r}, [{REAL_PS!r}] + sys.argv[1:])
""")
FAILING_PS = ps_wrapper("failing-ps", "import sys\nsys.exit(1)\n")


def assert_clean(output):
    roots = [Path(line.split()[2]) for line in output.splitlines() if line.startswith("READY ")]
    deadline = time.monotonic() + 8
    while any(root.exists() for root in roots) and time.monotonic() < deadline:
        time.sleep(0.02)
    assert roots and not any(root.exists() for root in roots), output
    assert (scratch / "unrelated").is_dir()


def run_case(mode, expected, data="", path=None):
    result = subprocess.run([shell, str(script), mode], input=data, capture_output=True,
                            text=True, env=environment(path), timeout=30)
    assert result.returncode == expected, (mode, result.returncode, result.stdout, result.stderr)
    assert not result.stderr, result.stderr
    assert_clean(result.stdout)
    print("PASS", mode)
    return result.stdout


def until(process, marker):
    output = b""
    deadline = time.monotonic() + 15
    while marker not in output and time.monotonic() < deadline:
        if select.select([process.stdout], [], [], 0.1)[0]:
            block = os.read(process.stdout.fileno(), 4096)
            if not block:
                break
            output += block
    assert marker in output, output
    return output.decode()


def process_state(pid):
    result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
    return result.stdout.strip()


def wait_until_blocked(process):
    # `ARMED` is printed before the script reaches its blocking `read`. A trapped
    # signal that lands in that gap is not delivered by EINTR: the shell only
    # runs the trap after `read` returns, so the case would hang until stdin
    # closes. Wait until the process sleeps, on three consecutive polls (a
    # runnable or preempted process reports R, never S), before signalling.
    deadline = time.monotonic() + 15
    asleep = 0
    while asleep < 3 and process.poll() is None and time.monotonic() < deadline:
        asleep = asleep + 1 if process_state(process.pid).startswith("S") else 0
        time.sleep(0.02)
    assert asleep >= 3, ("never blocked", process_state(process.pid))


def diagnostics(process):
    table = subprocess.run(["ps", "-axo", "pid,ppid,pgid,stat,command"], capture_output=True,
                           text=True).stdout.splitlines()
    tree = [line for line in table
            if line.split()[:1] == ["PID"] or str(process.pid) in line.split()[:3]]
    errors = b""
    while process.stderr is not None and not process.stderr.closed \
            and select.select([process.stderr], [], [], 0)[0]:
        block = os.read(process.stderr.fileno(), 4096)
        if not block:
            break
        errors += block
    return "process tree:\n" + "\n".join(tree) + "\nstderr tail: " + repr(errors[-500:])


def wait_for_file(path):
    deadline = time.monotonic() + 15
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert path.exists(), ("never created", path)


def signal_case(mode, sig, group=False, path=None, marker=None):
    process = subprocess.Popen([shell, str(script), mode], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=environment(path), start_new_session=True)
    output = ""
    try:
        output = until(process, b"EXEC " if mode == "exec" else b"ARMED")
        assert int(output.splitlines()[0].split()[1]) == process.pid, output
        if mode == "exec":
            assert int(output.splitlines()[1].split()[1]) == process.pid, output
        if not group:
            wait_until_blocked(process)
        if group:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                children = subprocess.check_output(["ps", "-eo", "ppid=,comm="], text=True)
                if any(line.split() == [str(process.pid), "sleep"] for line in children.splitlines()):
                    break
                time.sleep(0.02)
            else:
                raise AssertionError("foreground child did not start")
            if marker is not None:
                wait_for_file(marker)
            os.killpg(process.pid, sig)
        else:
            process.send_signal(sig)
        process.wait(timeout=15)
        process.stdin.close()
        process.stdin = None
        rest, errors = process.communicate(timeout=15)
        output += rest.decode()
        assert process.returncode in (-sig, 128 + sig), (mode, sig, process.returncode, errors)
        assert "UNEXPECTED" not in output, output
        assert not errors, errors
        assert_clean(output)
        print("PASS", mode, signal.Signals(sig).name, "group" if group else "pid",
              "" if path is None else path.name)
    except (AssertionError, subprocess.TimeoutExpired) as error:
        raise AssertionError(f"{error!r}\n{diagnostics(process)}") from None
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=15)


def tty_case():
    master, slave = pty.openpty()
    process = subprocess.Popen([shell, str(script), "tty"], stdin=slave, stdout=slave,
                               stderr=subprocess.PIPE, env=environment(), start_new_session=True)
    os.close(slave)
    try:
        os.write(master, b"terminal-input\n")
        process.wait(timeout=15)
        output = b""
        while select.select([master], [], [], 0.1)[0]:
            try:
                output += os.read(master, 4096)
            except OSError:
                break
        assert process.returncode == 0 and b"TTY terminal-input" in output, output
        assert_clean(output.decode())
        print("PASS tty")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=15)
        os.close(master)


(scratch / "unrelated").mkdir()


def stdin_case():
    assert "INPUT piped-input" in run_case("stdin", 0, "piped-input\n")


def nested_case():
    nested = run_case("nested", 0)
    roots = [line.split()[2] for line in nested.splitlines() if line.startswith("READY ")]
    assert len(set(roots)) == 2 and "OUTER-LIVE" in nested, nested


def failed_lookup_case():
    # A failed parent lookup must not end the guardian and delete the root
    # while acq is still running.
    assert "ROOT-LIVE" in run_case("survive", 0, path=FAILING_PS)


# Every case owns a private process tree and kit-fetch root, and the acq exit path
# waits ~1s on the cleanup guardian, so cases are wall-clock bound rather than CPU
# bound. Run them concurrently (4 at a time, with generous per-step failure
# ceilings so a loaded 2-CPU runner cannot flake; passing runs never wait on them); each is still executed and asserted individually,
# and every failure is reported below.
cases = [(run_case, (mode, status)) for mode, status in
         (("success", 0), ("failure", 37), ("replace", 19), ("clear", 23))]
cases += [(stdin_case, ()), (nested_case, ()), (tty_case, ())]
cases += [(signal_case, (mode, sig)) for mode in ("signal", "exec", "spinner")
          for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)]
cases += [(signal_case, ("foreground", sig, True))
          for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)]
cases += [(signal_case, ("prompt", signal.SIGINT)), (signal_case, ("signal", signal.SIGKILL))]
# A group SIGTERM that kills the guardian's parent lookup must leave acq's stderr
# empty. With every lookup failing, the owner check alone must still end the
# guardian and remove the root after a SIGKILL, which runs no EXIT trap.
cases += [(failed_lookup_case, ()),
          (signal_case, ("foreground", signal.SIGTERM, True, SLOW_PS,
                         scratch / "slow-ps.started")),
          (signal_case, ("signal", signal.SIGKILL, False, FAILING_PS))]

with ThreadPoolExecutor(max_workers=4) as pool:
    futures = [pool.submit(fn, *args) for fn, args in cases]
failures = [(cases[i], f.exception()) for i, f in enumerate(futures) if f.exception()]
for (fn, args), error in failures:
    print("FAIL", fn.__name__, args, repr(error), file=sys.stderr)
sys.exit(1 if failures else 0)
