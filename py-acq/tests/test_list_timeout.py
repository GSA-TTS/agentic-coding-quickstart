"""Tier-2 tests for the bounded backend listing calls (``timeouts.list_timeout_s``).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` and the adapters
in-process against the deterministic ``__stub__`` backends, with
``subprocess.run`` patched to time out on the listing calls. A backend whose
listing hangs must make ``acq ls`` fail with a clear ``timeout`` error, never
wait forever; the contract side is ``cli/ls-list-timeout-msb``.
"""

from __future__ import annotations

import json
import subprocess

import pytest

from acq_py import cli, errors, msb, sbx, timeouts


def _env(monkeypatch, tmp_path):
    for name in ("ACQ_BACKEND", "ACQ_LIST_TIMEOUT", "ACQ_MSB_STUB_CATALOG", "ACQ_SBX_STUB_CATALOG",
                 "ACQ_MSB_STUB_FAIL", "ACQ_SBX_STUB_FAIL"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))


@pytest.fixture
def hang(monkeypatch):
    """Make every listing child time out; record the timeout each call was given."""
    budgets: list[float | None] = []
    real = subprocess.run

    def fake(argv, *args, **kwargs):
        tail = [str(a) for a in argv]
        if "list" in tail or "ls" in tail:
            budgets.append(kwargs.get("timeout"))
            raise subprocess.TimeoutExpired(list(argv), kwargs.get("timeout") or 0)
        return real(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", fake)
    return budgets


@pytest.mark.parametrize("backend, listing", [("msb", "msb list"), ("sbx", "sbx ls")])
def test_ls_fails_with_a_timeout_when_the_listing_hangs(monkeypatch, tmp_path, capsys, hang, backend, listing):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_LIST_TIMEOUT", "7")
    rc = cli.main(["--backend", backend, "ls", "--json"])
    doc = json.loads(capsys.readouterr().out)
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert doc["error"]["message"] == f"'{listing}' did not answer within 7s"
    assert "ACQ_LIST_TIMEOUT" in doc["error"]["remediation"]
    assert hang == [7.0]


def test_ls_human_output_names_the_timeout(monkeypatch, tmp_path, capsys, hang):
    _env(monkeypatch, tmp_path)
    assert cli.main(["--backend", "msb", "ls"]) == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert "'msb list' did not answer within 60s" in err
    assert hang == [timeouts.DEFAULT_LIST_TIMEOUT_S]


@pytest.mark.parametrize("call", [
    msb.list_names, msb.running_names, sbx.list_names, sbx.running_names,
])
def test_every_listing_call_is_bounded_by_default(monkeypatch, tmp_path, hang, call):
    _env(monkeypatch, tmp_path)
    with pytest.raises((msb.MsbError, sbx.SbxError)) as info:
        call()
    assert info.value.code == errors.TIMEOUT
    assert hang == [timeouts.DEFAULT_LIST_TIMEOUT_S]


@pytest.mark.parametrize("call", [msb.list_names, msb.running_names, sbx.list_names])
def test_an_explicit_timeout_still_raises_timeout_expired(monkeypatch, tmp_path, hang, call):
    # Rotation passes its own budget and reports the timeout itself.
    _env(monkeypatch, tmp_path)
    with pytest.raises(subprocess.TimeoutExpired):
        call(timeout=3)
    assert hang == [3]


# ---------------------------------------------------------------------------
# On Windows a bounded call runs in a Job object, which a timeout terminates, so
# a process the backend started (an auto-started msb server) dies with it. The
# OS is faked here; the live Job object checks are in test_qualify_backend_cell.
# ---------------------------------------------------------------------------


class _Proc:
    def __init__(self, events, *, hangs):
        self.events, self.hangs, self.pid, self.returncode = events, hangs, 4242, None
        self.stdin = self.stdout = self.stderr = None

    def communicate(self, input=None, timeout=None):
        self.events.append(("communicate", input, timeout))
        if self.hangs:
            raise subprocess.TimeoutExpired("msb", timeout)
        self.returncode = 0
        return "out", "err"

    def kill(self):
        self.events.append("kill")


@pytest.fixture
def windows_job(monkeypatch, no_job_objects):
    from acq_py import hostexec

    state = {"events": [], "hangs": False, "adopt_error": None}
    events = state["events"]

    class Job:
        def terminate(self):
            events.append("terminate")

        def release(self):
            events.append("release")

    def popen(argv, **kwargs):
        events.append(("spawn", kwargs.get("creationflags"), kwargs.get("stdin")))
        return _Proc(events, hangs=state["hangs"])

    def adopt(pid):
        events.append(("adopt", pid))
        if state["adopt_error"] is not None:
            raise state["adopt_error"]
        return Job()

    def run(argv, **kwargs):
        events.append(("run", kwargs.get("timeout")))
        return subprocess.CompletedProcess(argv, 0, "plain", "")

    monkeypatch.setattr(hostexec, "JOB_OBJECTS", True)
    monkeypatch.setattr(hostexec.subprocess, "Popen", popen)
    monkeypatch.setattr(hostexec.subprocess, "run", run)
    monkeypatch.setattr(hostexec.StepJob, "adopt", staticmethod(adopt))
    monkeypatch.setattr(hostexec, "_REAP_TIMEOUT_S", 0.0)
    return state


def test_on_windows_a_bounded_call_runs_suspended_in_a_job_released_after(windows_job):
    from acq_py import hostexec

    proc = hostexec.run_captured(["msb", "list"], timeout=5.0, input_text="v")
    assert (proc.returncode, proc.stdout, proc.stderr) == (0, "out", "err")
    assert windows_job["events"] == [("spawn", hostexec.CREATE_SUSPENDED, subprocess.PIPE), ("adopt", 4242),
                                     ("communicate", "v", 5.0), "release"]


def test_on_windows_a_timeout_terminates_the_whole_job(windows_job):
    from acq_py import hostexec

    windows_job["hangs"] = True
    with pytest.raises(subprocess.TimeoutExpired):
        hostexec.run_captured(["msb", "list"], timeout=0.5)
    events = windows_job["events"]
    assert events[:3] == [("spawn", hostexec.CREATE_SUSPENDED, subprocess.DEVNULL), ("adopt", 4242),
                          ("communicate", None, 0.5)]
    assert "terminate" in events and "kill" not in events  # the job, not only the direct child


def test_on_windows_a_process_that_cannot_join_a_job_is_killed_before_it_runs_then_run_plainly(windows_job):
    from acq_py import hostexec

    windows_job["adopt_error"] = OSError("no job")
    proc = hostexec.run_captured(["msb", "list"], timeout=5.0)
    assert proc.stdout == "plain"
    assert windows_job["events"][1:] == [("adopt", 4242), "kill", ("communicate", None, 0.0), ("run", 5.0)]


def test_an_unbounded_call_or_a_posix_host_uses_plain_subprocess_run(windows_job, monkeypatch):
    from acq_py import hostexec

    hostexec.run_captured(["msb", "create"])  # no timeout: nothing to bound
    monkeypatch.setattr(hostexec, "JOB_OBJECTS", False)
    hostexec.run_captured(["msb", "list"], timeout=5.0)
    assert windows_job["events"] == [("run", None), ("run", 5.0)]


def test_the_backend_adapters_bound_their_calls_through_run_captured(monkeypatch, tmp_path):
    from acq_py import hostexec

    _env(monkeypatch, tmp_path)
    seen = []
    monkeypatch.setattr(hostexec, "run_captured",
                        lambda argv, **kw: seen.append(kw["timeout"]) or subprocess.CompletedProcess(argv, 0, "", ""))
    msb.list_names()
    sbx.list_names()
    assert seen == [timeouts.DEFAULT_LIST_TIMEOUT_S] * 2


@pytest.mark.parametrize("raw", ["0", "-1", "nan", "soon"])
def test_an_invalid_list_timeout_falls_back_to_the_default(monkeypatch, capsys, raw):
    monkeypatch.setenv("ACQ_LIST_TIMEOUT", raw)
    assert timeouts.list_timeout_s() == timeouts.DEFAULT_LIST_TIMEOUT_S
    assert "ignoring ACQ_LIST_TIMEOUT" in capsys.readouterr().err
