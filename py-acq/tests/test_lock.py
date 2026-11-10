"""The OS advisory lock primitive (``acq_py.lock.exclusive_lock``).

Two behaviours of the wait itself: a long wait says what it waits for, once and
only on stderr; and on the secret-store lock an exclusive waiter is not starved
by shared holders that keep arriving, while a waiter that crashed holds nobody
up. The locks are real OS locks on files under a temporary state directory;
two opens of one file in the same process exclude each other, as two processes
would.
"""

from __future__ import annotations

import os
import subprocess
import sys
import threading
import time

import pytest

from acq_py import lock

posix_only = pytest.mark.skipif(sys.platform == "win32", reason="msvcrt locks have no shared mode")


@pytest.fixture
def state_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    return tmp_path / "state"


def _intent_path():
    path = lock.secret_store_lock_path()
    return path.with_name(path.name + ".writer")


def _marker_held() -> bool:
    """True while some acquirer holds the writer-waiting marker."""
    path = _intent_path()
    if not path.exists():
        return False
    with open(path, "a+b") as fh:
        if lock._try_os_lock(fh):
            lock._unlock(fh)
            return False
    return True


# ---------------------------------------------------------------------------
# The wait notice.
# ---------------------------------------------------------------------------


def test_a_long_wait_prints_one_notice_on_stderr(state_dir, monkeypatch, capsys):
    monkeypatch.setattr(lock, "_WAIT_NOTICE_S", 0.1)
    path = state_dir / "locks" / "demo.lock"
    with lock.exclusive_lock(path, 5.0):
        with pytest.raises(lock.MigrationLockTimeout):
            with lock.exclusive_lock(path, 0.6, what="the demo lock (another acq command uses it)", retry_s=0.02):
                pass
    out, err = capsys.readouterr()
    assert out == ""
    assert err.count("acq: waiting for the demo lock, held by another acq command...") == 1, err
    assert "another acq command uses it" not in err


def test_a_short_wait_is_silent(state_dir, monkeypatch, capsys):
    path = state_dir / "locks" / "demo.lock"
    with lock.exclusive_lock(path, 5.0):
        with pytest.raises(lock.MigrationLockTimeout):
            with lock.exclusive_lock(path, 0.3, retry_s=0.02):
                pass
    with lock.exclusive_lock(path, 0.3):  # free: no wait at all
        pass
    assert capsys.readouterr() == ("", "")


def test_the_notice_leaves_json_stdout_alone(state_dir, monkeypatch, capsys):
    # A command that waits under --json still prints exactly one envelope on stdout.
    import json

    from acq_py import cli

    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("MSB_HOME", str(state_dir.parent / "msb-home"))
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.6")
    monkeypatch.setattr(lock, "_WAIT_NOTICE_S", 0.1)
    with lock.sandbox_lock("msb", "box"):
        rc = cli.main(["--backend", "msb", "rm", "box", "--json"])
    out, err = capsys.readouterr()
    doc = json.loads(out)
    assert rc == 1 and doc["command"] == "rm" and doc["error"]["code"] == "timeout"
    assert "waiting for the lifecycle lock for sandbox 'box', held by another acq command" in err
    assert "waiting" not in out


# ---------------------------------------------------------------------------
# Writer preference on the secret-store lock.
# ---------------------------------------------------------------------------


@posix_only
def test_a_waiting_global_change_holds_back_new_shared_holders(state_dir, monkeypatch):
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "10")
    got: list[str] = []

    def writer():
        with lock.secret_store_lock():
            got.append("writer")

    first = lock.secret_store_lock(shared=True)
    first.__enter__()  # a create holding the store
    thread = threading.Thread(target=writer)
    try:
        thread.start()
        time.sleep(0.6)  # the writer is waiting (it polls every 0.2 s)
        # A second create arriving now waits behind the writer instead of
        # overlapping the first and keeping the writer out for good.
        monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.4")
        with pytest.raises(lock.SecretStoreLockTimeout):
            with lock.secret_store_lock(shared=True):
                pass
        assert got == []
    finally:
        first.__exit__(None, None, None)
        thread.join(15)
    assert got == ["writer"]
    assert not _marker_held()  # given up once the writer held the lock


@posix_only
def test_shared_holders_still_overlap_with_no_writer_waiting(state_dir, monkeypatch):
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.4")
    with lock.secret_store_lock(shared=True):
        with lock.secret_store_lock(shared=True):
            pass


def test_a_writer_that_crashed_while_waiting_holds_nobody_up(state_dir, monkeypatch):
    # The marker is an OS lock, released with the process: a killed writer
    # leaves at most an unlocked file behind.
    path = _intent_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    script = (
        "import sys, time\n"
        "from acq_py import lock\n"
        "fh = open(sys.argv[1], 'a+b')\n"
        "assert lock._try_os_lock(fh)\n"
        "print('held', flush=True)\n"
        "time.sleep(60)\n"
    )
    proc = subprocess.Popen([sys.executable, "-c", script, str(path)], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, text=True, env=os.environ.copy())
    try:
        assert proc.stdout is not None and proc.stdout.readline().strip() == "held"
        assert _marker_held()
        proc.kill()
        proc.wait(15)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(15)
    assert path.exists()
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "2")
    with lock.secret_store_lock(shared=True):
        pass
    with lock.secret_store_lock():
        pass


def test_a_writer_that_times_out_gives_its_marker_up(state_dir, monkeypatch):
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    with lock.secret_store_lock():
        with pytest.raises(lock.SecretStoreLockTimeout):
            with lock.secret_store_lock():
                pass
        assert not _marker_held()
