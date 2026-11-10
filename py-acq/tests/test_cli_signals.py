"""Ctrl-C and SIGTERM during a command (cli.main).

Ctrl-C must end acq with status 130 and no traceback; SIGTERM (and SIGHUP) with
128 + N. Both must still run the command's cleanup: a create interrupted while
the backend runs discards the uncreated sandbox's provider inputs, exactly as a
failed create does.

Non-contract evidence (ADR-0039m): the create cases drive ``cli.main``
in-process against the ``__stub__`` msb, replacing the backend create with one
that is interrupted. The subprocess cases signal a real ``python -m acq_py``
process from outside, once it reports that the create is running.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from acq_py import cli, msb, provider_input, secretstore
from acq_py.commands import common

posix_only = pytest.mark.skipif(sys.platform == "win32", reason="POSIX signals")
# Windows has no SIGHUP; the tests using it are POSIX-only, but parametrize runs at
# collection, so fall back to its POSIX number there.
_SIGHUP = getattr(signal, "SIGHUP", 1)


def _env(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_FAIL", "ACQ_IMAGE", "ACQ_MSB_IMAGE", "ACQ_PROVIDER_KITS",
                 "ACQ_PROVIDER_CREDENTIAL_BINDINGS", "ACQ_PROVIDER_CREDENTIAL_SEED", "USAI_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    (tmp_path / "ws").mkdir(exist_ok=True)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: False)
    monkeypatch.setattr(sys.modules["acq_py.security"], "ro_mount_supported", lambda: True)
    secretstore.set_secret("usai", None, "test-usai-key-not-a-secret")


def _create_argv(tmp_path):
    return ["--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", "box", "--json"]


def _generations() -> list[Path]:
    root = provider_input.input_root("msb", "box") / "generations"
    return list(root.iterdir()) if root.exists() else []


def _assert_create_cleaned_up():
    assert _generations() == []
    assert provider_input.recorded("msb", "box") == []


def test_ctrl_c_during_create_exits_130_quietly_after_cleanup(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    during: list[int] = []

    def interrupted(*_args, **_kwargs):
        during.append(len(_generations()))  # the provider inputs exist while create runs
        raise KeyboardInterrupt

    monkeypatch.setattr(msb, "create", interrupted)
    assert cli.main(_create_argv(tmp_path)) == 130
    assert during == [1]
    out, err = capsys.readouterr()
    assert out == ""
    assert "Traceback" not in err and "KeyboardInterrupt" not in err
    _assert_create_cleaned_up()


@posix_only
def test_sigterm_during_create_runs_cleanup_and_exits_143(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)

    during: list[int] = []

    def terminated(*_args, **_kwargs):
        during.append(len(_generations()))
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(30)  # the handler raises out of this sleep
        raise AssertionError("SIGTERM did not interrupt the create")

    monkeypatch.setattr(msb, "create", terminated)
    started = time.monotonic()
    assert cli.main(_create_argv(tmp_path)) == 143
    assert time.monotonic() - started < 20
    assert during == [1]
    out, err = capsys.readouterr()
    assert out == "" and "Traceback" not in err
    _assert_create_cleaned_up()
    # The default disposition is back once the command is over.
    assert signal.getsignal(signal.SIGTERM) is signal.SIG_DFL


@posix_only
def test_a_second_sigterm_cannot_cut_the_cleanup_short(monkeypatch):
    cleaned: list[str] = []

    def dispatch(*_args, **_kwargs):
        try:
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(30)
        finally:
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(0.2)  # a raise here would skip the line below
            cleaned.append("done")

    monkeypatch.setattr(cli, "_dispatch", dispatch)
    assert cli.main(["ls"]) == 143
    assert cleaned == ["done"]


@posix_only
def test_an_ignored_sigterm_stays_ignored(monkeypatch):
    seen: list[object] = []
    monkeypatch.setattr(cli, "_dispatch", lambda *_a, **_k: seen.append(signal.getsignal(signal.SIGTERM)) or 0)
    previous = signal.signal(signal.SIGTERM, signal.SIG_IGN)
    try:
        assert cli.main(["ls"]) == 0
        assert signal.getsignal(signal.SIGTERM) is signal.SIG_IGN
    finally:
        signal.signal(signal.SIGTERM, previous)
    assert seen == [signal.SIG_IGN]


# A real acq process whose backend create blocks: it prints READY once the
# create runs, then waits to be signalled. SIGINT is put back to Python's
# default first, because a test runner started in the background hands its
# children SIGINT ignored.
_DRIVER = """
import signal, sys, time
signal.signal(signal.SIGINT, signal.default_int_handler)
from acq_py import cli, msb, provider_input, secretstore
from acq_py.commands import common
common._stdin_is_terminal = lambda: False
sys.modules["acq_py.security"].ro_mount_supported = lambda: True
secretstore.set_secret("usai", None, "test-usai-key-not-a-secret")
def blocked(*_a, **_k):
    root = provider_input.input_root("msb", "box") / "generations"
    print("READY", len(list(root.iterdir())), flush=True)
    time.sleep(60)
msb.create = blocked
raise SystemExit(cli.main(sys.argv[1:]))
"""


@posix_only
@pytest.mark.parametrize("sig, status", [(signal.SIGINT, 130), (signal.SIGTERM, 143), (_SIGHUP, 129)],
                         ids=["sigint", "sigterm", "sighup"])
def test_a_signalled_acq_process_exits_quietly_after_cleanup(monkeypatch, tmp_path, sig, status):
    _env(monkeypatch, tmp_path)
    proc = subprocess.Popen(
        [sys.executable, "-c", _DRIVER, *_create_argv(tmp_path)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=os.environ.copy(),
    )
    try:
        assert proc.stdout is not None
        assert proc.stdout.readline().strip() == "READY 1"  # the provider inputs exist
        proc.send_signal(sig)
        out, err = proc.communicate(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    assert proc.returncode == status, err
    assert "Traceback" not in err, err
    assert out == ""
    _assert_create_cleaned_up()


# A command whose cleanup hangs: it prints READY once running, then CLEANING
# once the first signal has started its cleanup, which never finishes. The
# grace period is shortened so the test need not wait ten seconds.
_HUNG_CLEANUP_DRIVER = """
import sys, time
from acq_py import cli
cli._SECOND_SIGNAL_GRACE_S = float(sys.argv[1])
def dispatch(*_a, **_k):
    try:
        print("READY", flush=True)
        time.sleep(60)
    finally:
        print("CLEANING", flush=True)
        time.sleep(60)
        print("CLEANED", flush=True)
cli._dispatch = dispatch
raise SystemExit(cli.main(["ls"]))
"""


def _hung_cleanup(grace: float) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [sys.executable, "-c", _HUNG_CLEANUP_DRIVER, str(grace)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


@posix_only
@pytest.mark.parametrize("sig", [signal.SIGTERM, _SIGHUP], ids=["sigterm", "sighup"])
def test_a_later_second_signal_stops_a_hung_cleanup(sig):
    proc = _hung_cleanup(0.5)
    try:
        assert proc.stdout is not None
        assert proc.stdout.readline().strip() == "READY"
        proc.send_signal(sig)
        assert proc.stdout.readline().strip() == "CLEANING"
        time.sleep(1.0)  # past the grace period
        proc.send_signal(sig)
        out, err = proc.communicate(timeout=20)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    # Ended by the signal itself (a shell reports 128 + N), not by finishing.
    assert proc.returncode == -sig, err
    assert "CLEANED" not in out
    assert "Traceback" not in err, err


@posix_only
def test_a_second_signal_within_the_grace_period_is_ignored():
    proc = _hung_cleanup(30.0)
    try:
        assert proc.stdout is not None
        assert proc.stdout.readline().strip() == "READY"
        proc.send_signal(signal.SIGTERM)
        assert proc.stdout.readline().strip() == "CLEANING"
        proc.send_signal(signal.SIGTERM)
        with pytest.raises(subprocess.TimeoutExpired):
            proc.wait(timeout=1.5)
    finally:
        proc.kill()
        proc.wait()


@pytest.mark.skipif(not hasattr(signal, "SIGBREAK"), reason="Windows Ctrl-Break")
def test_ctrl_break_unwinds_the_command_quietly_with_149(monkeypatch, capsys):
    cleaned: list[str] = []

    def dispatch(*_args, **_kwargs):
        try:
            signal.raise_signal(signal.SIGBREAK)  # type: ignore[attr-defined,unused-ignore]
            time.sleep(5)
        finally:
            cleaned.append("done")

    monkeypatch.setattr(cli, "_dispatch", dispatch)
    assert cli.main(["ls", "--json"]) == 128 + signal.SIGBREAK  # type: ignore[attr-defined,unused-ignore]
    assert cleaned == ["done"]
    assert capsys.readouterr().out == ""  # no envelope


def test_main_returns_the_command_status_when_nothing_is_signalled(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    assert cli.main(["version", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["command"] == "version"
