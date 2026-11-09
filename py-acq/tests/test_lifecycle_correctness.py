"""Tier-2 tests for sandbox lifecycle correctness (ADR-0040m, ADR-0041m).

Covers the host-record and in-guest execution rules the create/rm/recreate
verbs must keep:

* ``rm`` clears every per-sandbox host record (state and applied-kit), including
  for a sandbox removed outside acq, so re-creating the name re-installs the
  agent kit;
* create, recreate and rm on one sandbox are serialized by a per-sandbox lock,
  which also honours a live Bash lock for the same sandbox;
* a failed recreate keeps the host record so it can be retried;
* ``.`` names the sandbox from the logical working directory, like Bash;
* in-guest kit and substrate steps never read the user's terminal, carry the
  non-interactive git guards and a timeout, and substrate steps run as root.

These drive ``cli.main`` in-process (and, for the lock, as subprocesses) against
the deterministic ``__stub__`` msb. The stub is an internal test seam.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

import pytest

from acq_py import cli, errors, kits, lock, msb, state
from acq_py.commands import common

_INSTALL = kits.agent_kit_install("opencode")


def _env(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1]) if out else None
    return rc, doc


def _catalog_path(tmp_path) -> Path:
    return tmp_path / "msb-home" / ".microsandbox" / "catalog.json"


def _write_catalog(tmp_path, catalog: dict) -> None:
    path = _catalog_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(catalog), encoding="utf-8")


def _spy_installs(monkeypatch) -> list[list[str]]:
    """Record every in-guest install argv the msb adapter runs."""
    installs: list[list[str]] = []
    real = msb._run

    def spy(argv, **kwargs):
        if argv[-len(_INSTALL):] == _INSTALL:
            installs.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    return installs


def _kit_record_path(backend: str, name: str) -> Path:
    return kits._kit_applied_path(backend, name)


# ---------------------------------------------------------------------------
# rm clears every per-sandbox host record.
# ---------------------------------------------------------------------------

def test_rm_then_create_reinstalls_the_agent_kit(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    installs = _spy_installs(monkeypatch)

    rc, _ = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0
    assert len(installs) == 1
    assert _kit_record_path("msb", "box").exists()

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True
    assert not _kit_record_path("msb", "box").exists()
    assert state.record_read("msb", "box") is None

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0
    assert doc["data"]["kit"] == "opencode"
    assert len(installs) == 2  # the fresh guest got its agent installed again


def test_create_ignores_a_stale_kit_record_left_by_an_out_of_band_removal(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    installs = _spy_installs(monkeypatch)
    # A record left behind by a sandbox removed outside acq (no guest, no state).
    kits.kit_applied_write("msb", "box", "opencode", "opencode")

    rc, _ = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0
    assert len(installs) == 1


def test_rm_clears_orphaned_host_records(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    rc, _ = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0
    _write_catalog(tmp_path, {})  # the guest is removed outside acq

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0
    assert doc["data"] == {"name": "box", "backend": "msb", "removed": True, "backend_absent": True}
    assert not state.record_path("msb", "box").exists()
    assert not _kit_record_path("msb", "box").exists()

    rc, doc = _invoke(capsys, "--backend", "msb", "ls", "--json")
    assert rc == 0
    assert doc["data"]["sandboxes"] == []


def test_rm_clears_an_unreadable_orphaned_record(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    path = state.record_path("msb", "box")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{not json", encoding="utf-8")
    _write_catalog(tmp_path, {})

    # Migration refuses an unparseable record tree-wide, so drive rm directly.
    from acq_py.commands import lifecycle

    class _Parsed:
        name = "box"

    rc = lifecycle.run_rm(_Parsed(), True, "msb")
    doc = json.loads(capsys.readouterr().out.strip())
    assert rc == 0
    assert doc["data"]["backend_absent"] is True
    assert not path.exists()


def test_rm_cleans_up_when_remove_fails_because_the_guest_is_already_gone(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    rc, _ = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0

    def remove_races_an_external_removal(name):
        _write_catalog(tmp_path, {})
        raise msb.MsbError(errors.FAILURE, f"msb remove failed for sandbox '{name}'")

    monkeypatch.setattr(msb, "remove", remove_races_an_external_removal)
    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True
    assert not state.record_path("msb", "box").exists()
    assert not _kit_record_path("msb", "box").exists()


# ---------------------------------------------------------------------------
# A failed recreate keeps the host record so it can be retried.
# ---------------------------------------------------------------------------

_SEC_RECORD = {
    "schema": 1,
    "name": "sec",
    "backend": "msb",
    "agent": "opencode",
    "workspace": "/w",
    "ro_host_config": True,
}


def test_recreate_kit_failure_keeps_the_host_record_for_a_retry(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"sec": "running"})
    path = state.record_path("msb", "sec")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(_SEC_RECORD), encoding="utf-8")
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))

    real_kit_apply = msb.kit_apply

    def failing_kit_apply(name, kit, install_cmd):
        raise msb.MsbError(errors.FAILURE, f"could not apply kit '{kit}' to sandbox '{name}'", "retry")

    monkeypatch.setattr(msb, "kit_apply", failing_kit_apply)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.FAILURE
    record = state.record_read("msb", "sec")
    assert record is not None
    assert record["agent"] == "opencode"
    assert record.get("ro_host_config") is True
    assert not _kit_record_path("msb", "sec").exists()

    monkeypatch.setattr(msb, "kit_apply", real_kit_apply)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 0
    assert doc["data"]["recreated"] is True


# ---------------------------------------------------------------------------
# `.` derives the sandbox name from the logical working directory.
# ---------------------------------------------------------------------------

@pytest.mark.skipif(os.name == "nt", reason="POSIX symlinked cwd")
def test_dot_derives_the_name_from_the_logical_working_directory(monkeypatch, tmp_path, capsys):
    real = tmp_path / "real-target"
    real.mkdir()
    link = tmp_path / "my-proj"
    link.symlink_to(real, target_is_directory=True)
    _env(monkeypatch, tmp_path)
    monkeypatch.chdir(link)  # os.getcwd() now reports the physical real-target
    monkeypatch.setenv("PWD", str(link))  # the shell's logical $PWD

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", ".", "--json")
    assert rc == 0
    assert doc["data"]["name"] == "opencode-my-proj"


@pytest.mark.skipif(os.name == "nt", reason="POSIX symlinked cwd")
def test_dot_ignores_a_pwd_that_does_not_name_the_working_directory(monkeypatch, tmp_path, capsys):
    real = tmp_path / "real-target"
    real.mkdir()
    other = tmp_path / "elsewhere"
    other.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.chdir(real)
    monkeypatch.setenv("PWD", str(other))  # stale: names a different directory

    assert cli._derive_name("opencode", common._logical_abspath(".")) == "opencode-real-target"


# ---------------------------------------------------------------------------
# Per-sandbox lock.
# ---------------------------------------------------------------------------

_SLOW_STUB = """
import os, sys, time
from pathlib import Path
args = sys.argv[1:]
gate = Path(os.environ["SLOW_GATE"])
if "install" in args:
    (gate / "installing").touch()
    deadline = time.monotonic() + 30
    while not (gate / "release").exists() and time.monotonic() < deadline:
        time.sleep(0.05)
from acq_py import _stub_msb
raise SystemExit(_stub_msb.main(["msb", *args]))
"""


@pytest.mark.skipif(os.name == "nt", reason="the slow-stub wrapper is a POSIX command line")
def test_concurrent_create_and_rm_are_serialized(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir()
    gate = tmp_path / "gate"
    gate.mkdir()
    script = tmp_path / "slow_msb.py"
    script.write_text(_SLOW_STUB, encoding="utf-8")
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_BIN", f"{shlex.quote(sys.executable)} {shlex.quote(str(script))}")
    monkeypatch.setenv("SLOW_GATE", str(gate))
    base = [sys.executable, "-m", "acq_py", "--backend", "msb"]

    create = subprocess.Popen(
        [*base, "create", "opencode", str(ws), "--name", "box", "--json"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True,
    )
    rm = None
    try:
        deadline = time.monotonic() + 30
        while not (gate / "installing").exists():
            assert create.poll() is None, create.communicate()
            assert time.monotonic() < deadline, "create never reached the kit install"
            time.sleep(0.05)
        rm = subprocess.Popen(
            [*base, "rm", "box", "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True,
        )
        time.sleep(1.5)
        # rm must wait for the in-flight create rather than tear the sandbox down
        # underneath it.
        assert rm.poll() is None, rm.communicate()
    finally:
        (gate / "release").touch()
    c_out, c_err = create.communicate(timeout=60)
    r_out, r_err = rm.communicate(timeout=60)
    assert create.returncode == 0, (c_out, c_err)
    assert rm.returncode == 0, (r_out, r_err)
    assert json.loads(r_out.splitlines()[-1])["data"].get("backend_absent") is None
    # rm ran after create finished: nothing of the sandbox is left behind.
    assert json.loads(_catalog_path(tmp_path).read_text(encoding="utf-8")) == {}
    assert not state.record_path("msb", "box").exists()
    assert not _kit_record_path("msb", "box").exists()


def test_sandbox_lock_times_out_while_another_holder_has_it(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.2")
    with lock.sandbox_lock("msb", "box"):
        rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert "box" in doc["error"]["message"]
    catalog = _catalog_path(tmp_path)
    assert not catalog.exists() or "box" not in json.loads(catalog.read_text(encoding="utf-8"))
    assert state.record_read("msb", "box") is None


@pytest.mark.skipif(os.name == "nt", reason="Bash locks carry POSIX pids")
def test_a_live_bash_lock_for_the_same_sandbox_blocks_rm(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"box": "running"})
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.2")
    bash_lock = Path(os.environ["XDG_STATE_HOME"]) / "acq" / "provenance" / "provider-input" / "msb" / "box.3360700413.lock"
    bash_lock.mkdir(parents=True)
    (bash_lock / "owner").write_text(f"{os.getpid()} 12345\n", encoding="utf-8")

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert "box" in json.loads(_catalog_path(tmp_path).read_text(encoding="utf-8"))

    # A lock whose owner is gone is stale and does not block.
    (bash_lock / "owner").write_text("999999999 12345\n", encoding="utf-8")
    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0


def test_posix_cksum_matches_the_bash_lock_key():
    # `printf '%s' box | cksum` and `printf '' | cksum`.
    assert lock._posix_cksum(b"box") == 3360700413
    assert lock._posix_cksum(b"") == 4294967295


# ---------------------------------------------------------------------------
# Unique temp names for atomic record writes.
# ---------------------------------------------------------------------------

def test_record_writes_use_unique_temp_names(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    sources: list[str] = []
    real_replace = os.replace

    def spy(src, dst):
        sources.append(str(src))
        return real_replace(src, dst)

    monkeypatch.setattr(os, "replace", spy)
    state.record_write("msb", "box", agent="shell", workspace="/w")
    state.record_write("msb", "box", agent="shell", workspace="/w")
    kits.kit_applied_write("msb", "box", "opencode", "opencode")
    kits.kit_applied_write("msb", "box", "opencode", "opencode")
    assert len(sources) == 4
    assert len(set(sources)) == 4
    assert all(not Path(s).exists() for s in sources)


# ---------------------------------------------------------------------------
# In-guest kit and substrate steps.
# ---------------------------------------------------------------------------

def _capture_subprocess(monkeypatch, *, raise_timeout=False):
    calls: list[tuple[list[str], dict]] = []

    def fake_run(argv, **kwargs):
        calls.append((list(argv), kwargs))
        if raise_timeout:
            raise subprocess.TimeoutExpired(argv, kwargs.get("timeout") or 0)
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(msb.subprocess, "run", fake_run)
    return calls


_GUARDS = ["-e", "GIT_TERMINAL_PROMPT=0", "-e", "GIT_ASKPASS=/bin/false", "-e", "SSH_ASKPASS=/bin/false"]


def _contains(seq: list[str], sub: list[str]) -> bool:
    return any(seq[i:i + len(sub)] == sub for i in range(len(seq) - len(sub) + 1))


def test_kit_apply_runs_detached_from_the_terminal_with_git_guards(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    calls = _capture_subprocess(monkeypatch)
    msb.kit_apply("box", "opencode", _INSTALL)
    (argv, kwargs), = calls
    assert kwargs.get("stdin") is subprocess.DEVNULL
    assert kwargs.get("timeout") is not None and kwargs["timeout"] > 0
    head = argv[: argv.index("--")]
    assert _contains(head, ["-u", "agent"])
    assert _contains(head, _GUARDS)
    assert argv[argv.index("--") + 1:] == _INSTALL


def test_kit_apply_timeout_is_a_stable_error(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_KIT_TIMEOUT", "7")
    calls = _capture_subprocess(monkeypatch, raise_timeout=True)
    with pytest.raises(msb.MsbError) as info:
        msb.kit_apply("box", "opencode", _INSTALL)
    assert info.value.code == errors.TIMEOUT
    assert calls[0][1]["timeout"] == 7.0


def test_substrate_steps_run_as_root_detached_with_git_guards(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    calls = _capture_subprocess(monkeypatch)
    msb.provision_substrate("box", [["useradd", "-m", "agent"], ["install-nix", "--single-user"]])
    assert len(calls) == 2
    for argv, kwargs in calls:
        head = argv[: argv.index("--")]
        assert _contains(head, ["-u", "root"])
        assert not _contains(head, ["-u", "agent"])
        assert _contains(head, _GUARDS)
        assert kwargs.get("stdin") is subprocess.DEVNULL
        assert kwargs.get("timeout") is not None
