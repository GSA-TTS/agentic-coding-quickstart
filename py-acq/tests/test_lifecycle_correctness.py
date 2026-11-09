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

import contextlib
import json
import os
import shlex
import shutil
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


_REPO = Path(__file__).resolve().parents[2]
_POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="Bash locks carry POSIX pids")


def _bash_lock(name: str = "box") -> Path:
    return lock._bash_lock_dir("msb", name)


def _bash(script: str, *args: str, timeout: float = 30) -> subprocess.CompletedProcess:
    """Run ``script`` in Bash with acq.backends/common.sh sourced (its real lock code)."""
    return subprocess.run(
        ["bash", "-c", f'source "{_REPO}/acq.backends/common.sh" >/dev/null 2>&1; {script}', "bash", *args],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout,
    )


@_POSIX_ONLY
def test_a_live_bash_lock_for_the_same_sandbox_blocks_rm(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"box": "running"})
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    bash_lock = _bash_lock()
    bash_lock.mkdir(parents=True)
    identity = lock._process_identity(os.getpid())
    assert identity
    (bash_lock / "owner").write_text(f"{os.getpid()} {identity}\n", encoding="utf-8")

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert str(bash_lock) in doc["error"]["remediation"]
    assert "box" in json.loads(_catalog_path(tmp_path).read_text(encoding="utf-8"))
    assert bash_lock.is_dir()  # a live holder's lock is never touched


@_POSIX_ONLY
@pytest.mark.parametrize(
    "owner",
    [
        "999999999 12345",  # the owner process is gone
        "{pid} not-my-start-time",  # a reused PID: alive, but a different process
        "\u00b2 12345",  # a non-ASCII digit PID is not a PID
        "\u0663\u0664 12345",
    ],
)
def test_a_stale_bash_lock_is_recovered(monkeypatch, tmp_path, capsys, owner):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"box": "running"})
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    bash_lock = _bash_lock()
    bash_lock.mkdir(parents=True)
    (bash_lock / "owner").write_text(owner.format(pid=os.getpid()) + "\n", encoding="utf-8")

    rc, _doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0
    assert not bash_lock.exists()  # recovered, then taken and released by acq


@_POSIX_ONLY
def test_an_ownerless_bash_lock_is_not_touched(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"box": "running"})
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    bash_lock = _bash_lock()
    bash_lock.mkdir(parents=True)

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert bash_lock.is_dir()


@pytest.mark.parametrize("token", ["12", "007"])
def test_owner_pid_accepts_ascii_digits(token):
    assert lock._owner_pid(token) == int(token)


@pytest.mark.parametrize("token", ["", "-1", "1.5", " 12", "\u00b2", "\u0663\u0664", "12a"])
def test_owner_pid_rejects_anything_but_ascii_digits(token):
    assert lock._owner_pid(token) is None


@_POSIX_ONLY
@pytest.mark.skipif(not shutil.which("bash"), reason="needs bash")
def test_bash_waits_for_a_python_held_sandbox_lock(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    with lock.sandbox_lock("msb", "café box"):
        held = _bash_lock("café box")
        owner = (held / "owner").read_text(encoding="utf-8").split()
        assert owner[0] == str(os.getpid())
        expected = subprocess.run(
            ["sh", "-c", 'ps -o lstart= -p "$1" | tr -d "[:space:]"', "sh", str(os.getpid())],
            capture_output=True, text=True,
        ).stdout
        assert " ".join(owner[1:]) == expected
        # Bash's own acquire refuses: the Python owner is live.
        proc = _bash(
            'ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire msb "$1" $$', "café box"
        )
        assert proc.returncode == 1
        assert "owned by live pid" in proc.stderr
    assert not held.exists()


@_POSIX_ONLY
@pytest.mark.skipif(not shutil.which("bash"), reason="needs bash")
def test_python_waits_for_a_bash_held_sandbox_lock_and_recovers_it_when_stale(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    holder = subprocess.Popen(["sleep", "60"])
    try:
        proc = _bash('acq_provider_input_lock_acquire msb "$1" "$2"', "box", str(holder.pid))
        assert proc.returncode == 0, proc.stderr
        assert Path(proc.stdout.strip()) == _bash_lock()
        with pytest.raises(lock.SandboxLockTimeout) as info:
            with lock.sandbox_lock("msb", "box"):
                pass
        assert str(_bash_lock()) in (info.value.remediation or "")
    finally:
        holder.kill()
        holder.wait()
    with lock.sandbox_lock("msb", "box"):  # the Bash owner is gone: stale, recovered
        assert _bash_lock().is_dir()
    assert not _bash_lock().exists()


@pytest.mark.skipif(not (shutil.which("tr") and shutil.which("cksum")), reason="needs tr and cksum")
def test_bash_lock_key_matches_tr_and_cksum_for_a_non_ascii_name():
    name = "café box/ü"
    safe = subprocess.run(
        ["tr", "-c", "A-Za-z0-9._-", "_"], input=name.encode("utf-8"), capture_output=True
    ).stdout.decode("ascii")
    total = subprocess.run(["cksum"], input=name.encode("utf-8"), capture_output=True).stdout.split()[0]
    assert lock._bash_safe(name) == safe == "caf___box___"
    assert lock._posix_cksum(name.encode("utf-8")) == int(total)


@_POSIX_ONLY
@pytest.mark.skipif(not shutil.which("bash"), reason="needs bash")
def test_bash_lock_dir_matches_bash_provider_input_root(monkeypatch, tmp_path):
    for name in ("box", "café box/ü"):
        proc = _bash('acq_provider_input_root msb "$1"', name)
        assert proc.returncode == 0, proc.stderr
        assert str(lock._bash_lock_dir("msb", name)) == proc.stdout.strip() + ".lock"


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


def test_substrate_steps_run_as_their_own_user_detached_with_git_guards(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    calls = _capture_subprocess(monkeypatch)
    msb.provision_substrate("box", [("root", ["useradd", "-m", "agent"]), ("agent", ["install-nix", "--single-user"])])
    assert len(calls) == 2
    users = []
    for argv, kwargs in calls:
        head = argv[: argv.index("--")]
        users.append(head[head.index("-u") + 1])
        assert _contains(head, _GUARDS)
        assert kwargs.get("stdin") is subprocess.DEVNULL
        assert kwargs.get("timeout") is not None
    assert users == ["root", "agent"]


@pytest.mark.parametrize("gaps", [["nix", "agent-user"], ["agent-user", "direnv", "nix", "devenv"]])
def test_substrate_plan_creates_the_agent_user_first_as_root(gaps):
    from acq_py.commands import lifecycle

    steps = lifecycle._substrate_provision_steps(gaps)
    assert steps[0] == ("root", ["useradd", "-m", "agent"])
    assert all(user == "agent" for user, _argv in steps[1:])
    assert [argv[0] for _user, argv in steps[1:]][:1] == ["install-nix"]


# ---------------------------------------------------------------------------
# rm needs positive proof that a guest is gone before it clears host records.
# ---------------------------------------------------------------------------

def _created_box(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    rc, _ = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0
    assert _kit_record_path("msb", "box").exists()


def _records_intact():
    assert state.record_path("msb", "box").exists()
    assert _kit_record_path("msb", "box").exists()


def test_rm_keeps_records_when_remove_fails_and_listing_fails(monkeypatch, tmp_path, capsys):
    _created_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "remove")
    monkeypatch.setattr(msb, "list_names", lambda: None)

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.FAILURE
    assert "could not confirm" in doc["error"]["message"]
    _records_intact()
    assert "box" in json.loads(_catalog_path(tmp_path).read_text(encoding="utf-8"))


def test_rm_keeps_records_of_an_apparent_orphan_when_listing_fails(monkeypatch, tmp_path, capsys):
    # The guest still exists, but msb cannot list it (and remove fails too): that
    # is not evidence that the guest is gone, so nothing is cleared.
    _created_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "remove")
    monkeypatch.setattr(msb, "list_names", lambda: None)
    monkeypatch.setattr(msb, "exists", lambda name: False)

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 1
    _records_intact()


def test_rm_keeps_records_when_listing_raises(monkeypatch, tmp_path, capsys):
    _created_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "remove")

    def cannot_list():
        raise msb.cli_unavailable()

    monkeypatch.setattr(msb, "list_names", cannot_list)
    rc, _doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 1
    _records_intact()


def test_rm_keeps_records_when_remove_fails_and_the_guest_is_still_listed(monkeypatch, tmp_path, capsys):
    _created_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "remove")

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 1
    assert doc["error"]["message"] == "msb remove failed for sandbox 'box'"
    _records_intact()


def test_rm_trusts_a_successful_remove_even_when_listing_fails(monkeypatch, tmp_path, capsys):
    _created_box(monkeypatch, tmp_path, capsys)
    monkeypatch.setattr(msb, "list_names", lambda: None)
    monkeypatch.setattr(msb, "exists", lambda name: False)

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "box", "--json")
    assert rc == 0
    assert doc["data"] == {"name": "box", "backend": "msb", "removed": True}
    assert not state.record_path("msb", "box").exists()
    assert not _kit_record_path("msb", "box").exists()


# ---------------------------------------------------------------------------
# run, recreate and kit apply take the sandbox lock; recreate re-checks under it.
# ---------------------------------------------------------------------------

def test_run_waits_for_the_sandbox_lock(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    with lock.sandbox_lock("msb", "box"):
        rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert state.record_read("msb", "box") is None
    assert not _catalog_path(tmp_path).exists() or "box" not in json.loads(_catalog_path(tmp_path).read_text(encoding="utf-8"))


def _sec_sandbox(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"sec": "running"})
    path = state.record_path("msb", "sec")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(_SEC_RECORD), encoding="utf-8")
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))


def _spy_removes(monkeypatch) -> list[str]:
    removed: list[str] = []
    real = msb.remove

    def spy(name):
        removed.append(name)
        return real(name)

    monkeypatch.setattr(msb, "remove", spy)
    return removed


def test_recreate_waits_for_the_sandbox_lock(monkeypatch, tmp_path, capsys):
    _sec_sandbox(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    removed = _spy_removes(monkeypatch)
    with lock.sandbox_lock("msb", "sec"):
        rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert removed == []


def _on_lock_entry(monkeypatch, action):
    """Run ``action`` the moment a command gets the sandbox lock (a racing command's effect)."""
    real = lock.sandbox_lock

    @contextlib.contextmanager
    def racing(backend, name):
        with real(backend, name):
            action()
            yield

    monkeypatch.setattr(lock, "sandbox_lock", racing)


def test_recreate_rereads_the_record_under_the_lock(monkeypatch, tmp_path, capsys):
    _sec_sandbox(monkeypatch, tmp_path)
    removed = _spy_removes(monkeypatch)
    _on_lock_entry(monkeypatch, lambda: state.record_remove("msb", "sec"))  # a racing rm

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.SANDBOX_NOT_FOUND
    assert removed == []


def test_recreate_rechecks_eligibility_under_the_lock(monkeypatch, tmp_path, capsys):
    # A concurrent recreate finished first: the sandbox now has its read-only
    # mount, and this recreate must not destroy the guest that one just rebuilt.
    _sec_sandbox(monkeypatch, tmp_path)
    removed = _spy_removes(monkeypatch)
    _on_lock_entry(monkeypatch, lambda: os.environ.__setitem__("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "ok"})))

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.VALIDATION_FAILED
    assert removed == []
    assert "sec" in json.loads(_catalog_path(tmp_path).read_text(encoding="utf-8"))


def test_kit_apply_waits_for_the_sandbox_lock(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"box": "running"})
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    installs = _spy_installs(monkeypatch)
    with lock.sandbox_lock("msb", "box"):
        rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "box", "opencode", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert installs == []
    assert not _kit_record_path("msb", "box").exists()


# ---------------------------------------------------------------------------
# `.` with a $PWD that normalises to a different directory.
# ---------------------------------------------------------------------------

@pytest.mark.skipif(os.name == "nt", reason="POSIX symlinked cwd")
def test_dot_ignores_a_pwd_whose_normal_form_is_a_different_directory(monkeypatch, tmp_path):
    target = tmp_path / "a" / "b"
    target.mkdir(parents=True)
    (tmp_path / "x").mkdir()
    (tmp_path / "x" / "link").symlink_to(target, target_is_directory=True)
    monkeypatch.chdir(tmp_path / "a")
    # Physically x/link/.. is a (the cwd); lexically it is x, a different directory.
    monkeypatch.setenv("PWD", str(tmp_path / "x" / "link" / ".."))

    assert common._logical_abspath(".") == str((tmp_path / "a").resolve())
    assert cli._derive_name("opencode", common._logical_abspath(".")) == "opencode-a"
