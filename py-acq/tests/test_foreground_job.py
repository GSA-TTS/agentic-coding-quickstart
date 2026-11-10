"""The foreground session child: its Windows Job object and the start-up signal window.

``hostexec.run_foreground`` starts the backend session (``msb exec``, ``sbx
exec``, passthrough). Two things are checked here:

- On Windows the child runs in a kill-on-close Job object, so a forced kill of
  acq (``taskkill /F``, which runs no handler) still ends the session. A child
  that exits normally releases the job, so what it left running keeps running.
  The POSIX cases drive that path with fakes; the Windows cases use the real
  thing.
- A SIGTERM, SIGHUP or Ctrl-Break that lands while the child is being started
  is not lost to the previous handler: it is recorded, the child is ended as
  soon as it exists, and acq then ends by that signal.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import textwrap
import threading
import time
from pathlib import Path

import pytest

from acq_py import hostexec

windows_only = pytest.mark.skipif(sys.platform != "win32", reason="real Windows Job objects")

SRC = Path(__file__).resolve().parents[1] / "src"


def _alive(pid: int) -> bool:
    """True while ``pid`` runs. Never ``os.kill(pid, 0)``: on Windows that kills it."""
    if sys.platform != "win32":
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True
    import ctypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.restype = ctypes.c_void_p
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        kernel32.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code))
        return code.value == 259  # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(ctypes.c_void_p(handle))


def _wait_for(predicate, timeout: float = 20.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def _sleeper(pid_file: Path, seconds: int = 60) -> list[str]:
    """A child that writes its pid, then sleeps (ignoring nothing)."""
    return [sys.executable, "-c",
            f"import os, time; open({str(pid_file)!r}, 'w').write(str(os.getpid())); time.sleep({seconds})"]


# ---------------------------------------------------------------------------
# The Job object path, with fakes (any host).
# ---------------------------------------------------------------------------

class _Child:
    # A deaf child ignores the signal passed on to it: it is still running when
    # the grace period ends, and only a kill (or its job's end) stops it.
    deaf = False

    def __init__(self, events, pid):
        self.events, self.pid, self.returncode = events, pid, None
        self.ended = False

    def wait(self, timeout=None):
        self.events.append(("wait", self.pid))
        if self.deaf and not self.ended and timeout == hostexec._SESSION_SIGNAL_GRACE_S:
            raise subprocess.TimeoutExpired("msb", timeout)
        self.returncode = 0
        return 0

    def kill(self):
        self.events.append(("kill", self.pid))
        self.ended = True

    def send_signal(self, signum):
        self.events.append(("signal", self.pid))

    def terminate(self):  # TerminateProcess on Windows: it cannot be ignored
        self.events.append(("terminate-child", self.pid))
        self.ended = True


@pytest.fixture
def fake_job(monkeypatch, no_job_objects):
    state = {"events": [], "adopt_error": None, "children": [], "deaf": False, "signal_on_start": None}
    events = state["events"]
    pids = iter(range(4242, 4300))

    class Job:
        def release(self):
            events.append("release")

        def terminate(self):
            events.append("terminate")
            for child in state["children"]:
                child.ended = True

    def popen(argv, **kwargs):
        child = _Child(events, next(pids))
        child.deaf = state["deaf"]
        state["children"].append(child)
        events.append(("spawn", child.pid, kwargs.get("creationflags"), kwargs.get("stdout")))
        if state["signal_on_start"] is not None:
            hostexec._session_signal(state["signal_on_start"], None)  # lands while it starts
        return child

    def adopt(pid):
        events.append(("adopt", pid))
        if state["adopt_error"] is not None:
            raise state["adopt_error"]
        return Job()

    monkeypatch.setattr(hostexec, "JOB_OBJECTS", True)
    monkeypatch.setattr(hostexec.subprocess, "Popen", popen)
    monkeypatch.setattr(hostexec.StepJob, "adopt", staticmethod(adopt))
    monkeypatch.setattr(hostexec, "_REAP_TIMEOUT_S", 0.0)
    return state


def test_on_windows_the_session_runs_suspended_in_a_job_released_once_it_exits(fake_job):
    assert hostexec.run_foreground(["msb", "exec", "box"], stdout=2) == 0
    assert fake_job["events"] == [("spawn", 4242, hostexec.CREATE_SUSPENDED, 2), ("adopt", 4242),
                                  ("wait", 4242), "release"]


def test_a_session_that_cannot_join_a_job_is_killed_before_it_runs_then_started_plainly(fake_job):
    fake_job["adopt_error"] = OSError("no job")
    assert hostexec.run_foreground(["msb", "exec", "box"]) == 0
    assert fake_job["events"] == [("spawn", 4242, hostexec.CREATE_SUSPENDED, None), ("adopt", 4242),
                                  ("kill", 4242), ("wait", 4242),
                                  ("spawn", 4243, None, None), ("wait", 4243)]


def test_an_interrupted_adopt_kills_the_suspended_child_and_starts_nothing_else(fake_job):
    fake_job["adopt_error"] = KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt):
        hostexec.run_foreground(["msb", "exec", "box"])
    spawns = [e for e in fake_job["events"] if e[0] == "spawn"]
    assert len(spawns) == 1 and ("kill", 4242) in fake_job["events"]


@pytest.mark.parametrize("deaf", [False, True], ids=["exits-in-grace", "killed-after-grace"])
def test_a_child_killed_after_the_grace_period_takes_its_whole_job_with_it(fake_job, deaf):
    # A child that ignored the signal may have started others that ignore it
    # too, so its job is terminated; one that exited in time has it released.
    if deaf and sys.platform == "win32":
        pytest.skip("acq passes SIGTERM on as TerminateProcess, which cannot be ignored; "
                    "the deaf Ctrl-Break case is the real Job object test below")
    fake_job["deaf"] = deaf
    fake_job["signal_on_start"] = signal.SIGTERM
    previous = signal.signal(signal.SIGTERM, _acq_handler)
    try:
        with pytest.raises(Ended):
            hostexec.run_foreground(["msb", "exec", "box"])
    finally:
        signal.signal(signal.SIGTERM, previous)
    events = fake_job["events"]
    assert ("kill", 4242) not in events  # never the child alone
    if deaf:
        assert "terminate" in events and events.index("terminate") < events.index("release")
    else:
        assert "terminate" not in events and events[-1] == "release"


def test_off_windows_the_session_gets_no_job(fake_job, monkeypatch):
    monkeypatch.setattr(hostexec, "JOB_OBJECTS", False)
    assert hostexec.run_foreground(["msb", "exec", "box"]) == 0
    assert fake_job["events"] == [("spawn", 4242, None, None), ("wait", 4242)]


# ---------------------------------------------------------------------------
# A signal that lands while the child is being started (POSIX and Windows).
# ---------------------------------------------------------------------------

class Ended(BaseException):
    pass


def _acq_handler(signum, _frame):  # stands in for cli's own handler
    raise Ended(signum)


def _signal_during_start(monkeypatch, signum: int, *, fail: bool = False) -> list[subprocess.Popen]:
    """Deliver ``signum`` to acq right after the session child is created
    (or, with ``fail``, instead of creating it), before any wait began.
    Returns the list the created children are added to."""
    real = subprocess.Popen
    children: list[subprocess.Popen] = []

    def popen(*args, **kwargs):
        if fail:
            signal.raise_signal(signum)
            raise FileNotFoundError(2, "no such program")
        children.append(real(*args, **kwargs))
        signal.raise_signal(signum)  # its Python handler runs before this returns
        return children[-1]

    monkeypatch.setattr(hostexec.subprocess, "Popen", popen)
    return children


@pytest.mark.parametrize("name", ["SIGTERM", "SIGHUP", "SIGBREAK"])
def test_a_signal_while_the_child_starts_ends_the_child_then_acq(monkeypatch, tmp_path, name):
    signum = getattr(signal, name, None)
    if signum is None:
        pytest.skip(f"{name} does not exist on this platform")
    # A long grace period: the child must be ended at once, not waited out.
    # (A Ctrl-Break that came before the child existed never reached it.)
    monkeypatch.setattr(hostexec, "_SESSION_SIGNAL_GRACE_S", 30.0)
    previous = signal.signal(signum, _acq_handler)
    started = time.monotonic()
    children: list[subprocess.Popen] = []
    try:
        children = _signal_during_start(monkeypatch, signum)
        with pytest.raises(Ended) as caught:
            hostexec.run_foreground(_sleeper(tmp_path / "pid"))
        monkeypatch.undo()
        assert signal.getsignal(signum) is _acq_handler  # restored before it ran
        assert caught.value.args == (signum,)
        assert time.monotonic() - started < 20
        [child] = children
        assert child.poll() is not None  # ended and reaped before acq's handler ran
    finally:
        signal.signal(signum, previous)
        for leftover in children:
            if leftover.poll() is None:
                leftover.kill()
                leftover.wait()


def test_a_signal_while_the_program_fails_to_start_still_ends_acq(monkeypatch):
    previous = signal.signal(signal.SIGTERM, _acq_handler)
    try:
        _signal_during_start(monkeypatch, signal.SIGTERM, fail=True)
        with pytest.raises(Ended):
            hostexec.run_foreground([sys.executable, "-c", "pass"])
        monkeypatch.undo()
        assert signal.getsignal(signal.SIGTERM) is _acq_handler
    finally:
        signal.signal(signal.SIGTERM, previous)


def test_with_no_signal_a_program_that_cannot_start_still_raises(tmp_path):
    before = signal.getsignal(signal.SIGTERM)
    with pytest.raises(OSError):
        hostexec.run_foreground([str(tmp_path / "no-such-program")])
    assert signal.getsignal(signal.SIGTERM) is before


# ---------------------------------------------------------------------------
# The real Job object on Windows.
# ---------------------------------------------------------------------------

_ACQ_STAND_IN = textwrap.dedent("""
    import sys
    sys.path.insert(0, {src!r})
    from acq_py import hostexec
    hostexec.JOB_OBJECTS = True
    sys.exit(hostexec.run_foreground(sys.argv[1:]))
""")


def _stand_in(tmp_path: Path, child: list[str]) -> subprocess.Popen:
    """A process that runs ``child`` through run_foreground, as acq does."""
    script = tmp_path / "acq_stand_in.py"
    script.write_text(_ACQ_STAND_IN.format(src=str(SRC)), encoding="utf-8")
    return subprocess.Popen([sys.executable, str(script), *child], stdin=subprocess.DEVNULL)


@windows_only
def test_a_forced_kill_of_acq_ends_the_session_child_and_what_it_started(tmp_path, real_job_objects):
    child_pid, grandchild_pid = tmp_path / "child", tmp_path / "grandchild"
    child = [sys.executable, "-c", textwrap.dedent(f"""
        import os, subprocess, sys, time
        subprocess.Popen({_sleeper(grandchild_pid)!r})
        open({str(child_pid)!r}, 'w').write(str(os.getpid()))
        time.sleep(60)
    """)]
    acq = _stand_in(tmp_path, child)
    try:
        assert _wait_for(lambda: child_pid.exists() and grandchild_pid.exists())
        pids = [int(child_pid.read_text()), int(grandchild_pid.read_text())]
        assert all(_alive(pid) for pid in pids)
        subprocess.run(["taskkill", "/F", "/PID", str(acq.pid)], check=True, capture_output=True)
        acq.wait(timeout=10)
        assert _wait_for(lambda: not any(_alive(pid) for pid in pids), 10)
    finally:
        if acq.poll() is None:
            acq.kill()


@windows_only
def test_a_session_killed_after_the_grace_period_ends_what_it_started(monkeypatch, tmp_path, real_job_objects):
    # The child ignores Ctrl-Break, so it is still running after the grace
    # period; its job is terminated, which ends the process it started too.
    monkeypatch.setattr(hostexec, "_SESSION_SIGNAL_GRACE_S", 0.5)
    signum = signal.SIGBREAK  # type: ignore[attr-defined,unused-ignore]
    ready, grandchild_pid = tmp_path / "ready", tmp_path / "grandchild"
    child = [sys.executable, "-c", textwrap.dedent(f"""
        import signal, subprocess, time
        signal.signal(signal.SIGBREAK, signal.SIG_IGN)
        subprocess.Popen({_sleeper(grandchild_pid)!r})
        open({str(ready)!r}, 'w').close()
        time.sleep(60)
    """)]
    seen: list[int] = []

    def raise_later():
        _wait_for(lambda: ready.exists() and grandchild_pid.exists())
        time.sleep(0.1)
        signal.raise_signal(signum)  # handled by the main thread at its next poll

    previous = signal.signal(signum, lambda n, _f: seen.append(n))
    try:
        threading.Thread(target=raise_later, daemon=True).start()
        assert hostexec.run_foreground(child) == 128 + signum
    finally:
        signal.signal(signum, previous)
    assert seen == [signum]
    assert _wait_for(lambda: not _alive(int(grandchild_pid.read_text())), 10)


@windows_only
def test_a_process_the_session_leaves_running_on_purpose_outlives_it(tmp_path, real_job_objects):
    grandchild_pid = tmp_path / "grandchild"
    child = [sys.executable, "-c",
             f"import subprocess, time; subprocess.Popen({_sleeper(grandchild_pid, 30)!r}); time.sleep(1)"]
    acq = _stand_in(tmp_path, child)
    try:
        assert acq.wait(timeout=30) == 0
        assert _wait_for(grandchild_pid.exists)
        pid = int(grandchild_pid.read_text())
        assert _alive(pid)  # the job was released, not closed with the kill limit
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    finally:
        if acq.poll() is None:
            acq.kill()
