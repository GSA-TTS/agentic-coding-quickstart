"""Tier-2 tests for the ``config.yaml`` layer (ADR-0038m §config, ADR-0041m).

Non-contract evidence (ADR-0039m): these reach into ``acq_py.config`` directly
and drive the CLI as a subprocess. The Bash and Python implementations share
``config.yaml``, so the parity tests at the end source the Bash reader/writer from
``acq.backends/common.sh`` and compare bytes.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

from acq_py import config, doctor, migration
from acq_py.commands import common

REPO_ROOT = Path(__file__).resolve().parents[2]
COMMON_SH = REPO_ROOT / "acq.backends" / "common.sh"

POSIX_ONLY = pytest.mark.skipif(os.name != "posix", reason="POSIX file modes and symlinks")


def _write_config(data: bytes) -> Path:
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def _mode(path: Path) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


def _run_cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "acq_py", *args],
        capture_output=True,
        text=True,
        timeout=60,
    )


# ---------------------------------------------------------------------------
# Flat-key reader: mirrors _acq_config_read_field.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("content", "expected"),
    [
        (b"backend: sbx\n", "sbx"),
        (b"backend:sbx\n", "sbx"),
        (b"backend   :   sbx   \n", "sbx"),
        (b"backend: sbx # pinned\n", "sbx"),
        (b'backend: "sbx"\n', "sbx"),
        (b"backend: 'msb'\n", "msb"),
        (b'backend: "sbx" # comment\n', "sbx"),
        (b"backend: # only a comment\n", None),
        (b"backend:\n", None),
        (b"backend: sbx\r\n", "sbx"),
        (b"backend: sbx", "sbx"),
        (b"backend: sbx\nbackend: msb\n", "msb"),
        (b"backend: sbx\nbackend:\n", None),
        (b"  backend: sbx\n", None),
        (b"backends: sbx\n", None),
        (b"schema: 1\nextra_kits: paseo\n", None),
        (b'backend: "a"#b\n', '"a"#b'),
    ],
)
def test_read_field_matches_bash_semantics(content, expected):
    _write_config(content)
    assert config.read_field("backend") == expected


def test_read_field_absent_file_and_unsafe_key():
    assert config.read_field("backend") is None
    _write_config(b"backend: sbx\n")
    assert config.read_field("back.end") is None
    assert config.read_field("") is None


# ---------------------------------------------------------------------------
# Flat-key writer: mirrors _acq_config_write_field.
# ---------------------------------------------------------------------------

def test_write_field_preserves_unknown_keys_and_order():
    path = _write_config(b"schema: 1\n# hand comment\nbackend: msb\nextra_kits: paseo\nbackend: x\nfuture_key: {a: 1}\n")
    config.write_field("backend", "sbx")
    assert path.read_bytes() == (
        b"schema: 1\n# hand comment\nextra_kits: paseo\nfuture_key: {a: 1}\nbackend: sbx\n"
    )


def test_write_field_empty_value_removes_the_key():
    path = _write_config(b"schema: 1\nbackend: msb\nextra_kits: paseo\n")
    config.write_field("backend", "")
    assert path.read_bytes() == b"schema: 1\nextra_kits: paseo\n"


def test_write_field_keeps_crlf_lines_and_terminates_last_line():
    path = _write_config(b"extra_kits: paseo\r\nscope_github_token: yes")
    config.write_field("backend", "sbx")
    assert path.read_bytes() == b"extra_kits: paseo\r\nscope_github_token: yes\nbackend: sbx\n"


def test_write_field_new_file_carries_the_schema_marker():
    path = config.config_path()
    config.write_field("backend", "sbx")
    assert path.read_bytes() == f"schema: {config.CONFIG_SCHEMA}\nbackend: sbx\n".encode()
    assert config.config_schema() == config.CONFIG_SCHEMA
    if os.name == "posix":
        assert _mode(path) == 0o600
        assert _mode(path.parent) == 0o700


def test_config_writes_wait_for_the_config_lock(monkeypatch):
    # backend set/unset and configure read, edit and rewrite the whole file, so
    # a second writer waits for the lock rather than losing the first change.
    from acq_py import lock

    path = _write_config(b"schema: 1\nbackend: msb\n")
    monkeypatch.setenv("ACQ_MIGRATION_LOCK_TIMEOUT", "0.2")
    with lock.exclusive_lock(config.config_lock_path()):  # another acq command holds it
        with pytest.raises(config.ConfigLockTimeout) as exc:
            config.write_field("backend", "sbx")
        assert isinstance(exc.value, OSError) and "config.yaml lock" in str(exc.value)
        with pytest.raises(config.ConfigLockTimeout):
            config.remove_if_only_marker()
        with pytest.raises(config.ConfigLockTimeout):
            config.migrate_config()
        assert path.read_bytes() == b"schema: 1\nbackend: msb\n"
        # The CLI's migration pre-step rewrites config.yaml under the same lock,
        # so it is the step that reports it.
        proc = _run_cli("backend", "set", "sbx", "--json")
        assert proc.returncode == 1, proc.stderr
        error = json.loads(proc.stdout)["error"]
        assert error["code"] == "migration_failed" and "config.yaml lock" in error["message"]
    config.write_field("backend", "sbx")
    assert path.read_bytes() == b"schema: 1\nbackend: sbx\n"


@pytest.mark.parametrize("value", ["a\nb", "a\rb", "a\x00b"])
def test_write_field_refuses_values_that_would_inject_lines(value):
    path = _write_config(b"backend: msb\n")
    with pytest.raises(ValueError):
        config.write_field("backend", value)
    assert path.read_bytes() == b"backend: msb\n"


def test_write_field_refuses_unsafe_key():
    with pytest.raises(ValueError):
        config.write_field("back:end", "sbx")
    assert not config.config_path().exists()


@POSIX_ONLY
def test_write_field_does_not_clobber_an_unreadable_config():
    path = _write_config(b"backend: msb\nprovider_credential_bindings: x\n")
    path.chmod(0o000)
    try:
        if os.access(path, os.R_OK):
            pytest.skip("running with privileges that bypass file modes")
        with pytest.raises(OSError):
            config.write_field("backend", "sbx")
    finally:
        path.chmod(0o600)
    assert path.read_bytes() == b"backend: msb\nprovider_credential_bindings: x\n"


@POSIX_ONLY
def test_write_field_writes_through_a_symlink_and_keeps_its_mode(tmp_path):
    dotfiles = tmp_path / "dotfiles"
    dotfiles.mkdir()
    target = dotfiles / "acq.yaml"
    target.write_bytes(b"extra_kits: paseo\n")
    target.chmod(0o640)
    link = config.config_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target)

    config.write_field("backend", "sbx")

    assert link.is_symlink(), "the dotfiles symlink was replaced by a regular file"
    assert os.readlink(link) == str(target)
    assert target.read_bytes() == b"extra_kits: paseo\nbackend: sbx\n"
    assert _mode(target) == 0o640
    assert sorted(p.name for p in dotfiles.iterdir()) == ["acq.yaml"], "temp file left behind"


@POSIX_ONLY
def test_write_field_keeps_a_0600_mode():
    path = _write_config(b"backend: msb\n")
    path.chmod(0o600)
    old = os.umask(0o022)
    try:
        config.write_field("backend", "sbx")
    finally:
        os.umask(old)
    assert _mode(path) == 0o600


# ---------------------------------------------------------------------------
# Schema marker: absent vs legacy vs current.
# ---------------------------------------------------------------------------

def test_config_schema_distinguishes_absent_from_legacy():
    assert config.config_schema() is None
    _write_config(b"backend: msb\n")
    assert config.config_schema() == config.LEGACY_SCHEMA
    _write_config(b"schema: 1\nbackend: msb\n")
    assert config.config_schema() == config.CONFIG_SCHEMA


def test_doctor_config_check_passes_when_config_is_absent():
    check = config.doctor_check()
    assert check["id"] == "config-schema"
    assert check["status"] == "pass", check
    assert "legacy" not in check["message"]


def test_doctor_config_check_warns_on_legacy_and_fails_on_newer():
    _write_config(b"backend: msb\n")
    assert config.doctor_check()["status"] == "warn"
    _write_config(b"schema: 99\n")
    assert config.doctor_check()["status"] == "fail"
    _write_config(b"schema: 1\n")
    assert config.doctor_check()["status"] == "pass"


def test_doctor_reports_the_config_check():
    ids = [check["id"] for check in doctor.doctor_checks()]
    assert "config-schema" in ids


# ---------------------------------------------------------------------------
# Forward migration: crash-safe, symlink- and mode-preserving.
# ---------------------------------------------------------------------------

_LEGACY = b"backend: msb\nprovider_credential_bindings: usai=USAI_API_KEY@api.gsa.usai.gov\n"
_MIGRATED = f"schema: {config.CONFIG_SCHEMA}\n".encode() + _LEGACY

# Runs migrate_config in a child that hard-exits (os._exit, so no except/finally
# block can tidy up) at the K-th filesystem commit point: a replace, an fsync, or
# an unlink. MODE "before" exits instead of performing the call; "after" performs
# it first. A child that never reaches K prints "done" and exits 0.
_CRASH_CHILD = textwrap.dedent(
    """
    import os, sys
    from acq_py import config

    k, mode = int(sys.argv[1]), sys.argv[2]
    count = [0]
    real = os

    class Proxy:
        def __getattr__(self, name):
            return getattr(real, name)

    def wrap(fn):
        def inner(*args, **kwargs):
            count[0] += 1
            if count[0] == k and mode == "before":
                real._exit(70)
            result = fn(*args, **kwargs)
            if count[0] == k and mode == "after":
                real._exit(70)
            return result
        return inner

    proxy = Proxy()
    for name in ("replace", "rename", "fsync", "unlink", "remove"):
        setattr(proxy, name, wrap(getattr(real, name)))
    config.os = proxy
    config.migrate_config()
    print("done")
    """
)


def _crash_at(k: int, mode: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-c", _CRASH_CHILD, str(k), mode],
        capture_output=True,
        text=True,
        timeout=60,
    )


@POSIX_ONLY
@pytest.mark.parametrize("mode", ["before", "after"])
def test_migration_crash_at_any_step_leaves_config_intact(mode):
    path = config.config_path()
    backup = path.with_name("config.yaml.bak.0")
    reached_end = False
    crashed_before_backup_unlink = False
    for k in range(1, 30):
        if path.parent.exists():
            shutil.rmtree(path.parent)
        _write_config(_LEGACY).chmod(0o600)

        proc = _crash_at(k, mode)
        assert path.exists(), f"config.yaml missing after a crash at commit point {k} ({mode})"
        assert path.read_bytes() in (_LEGACY, _MIGRATED), f"torn config.yaml at commit point {k} ({mode})"
        if proc.returncode == 70 and path.read_bytes() == _MIGRATED and backup.exists():
            crashed_before_backup_unlink = True

        # The next run converges: the config is migrated, nothing is lost, and a
        # backup the crash left behind is cleaned up.
        assert config.migrate_config() in ("none", "migrated")
        assert path.read_bytes() == _MIGRATED
        assert config.config_schema() == config.CONFIG_SCHEMA
        assert _mode(path) == 0o600
        assert not backup.exists(), f"leftover backup after a crash at commit point {k} ({mode})"
        if proc.returncode == 0 and "done" in proc.stdout:
            reached_end = True
            break
        assert proc.returncode == 70, proc.stderr
    assert reached_end, "migrate_config never completed without a crash"
    if mode == "before":
        assert crashed_before_backup_unlink, "the backup-unlink step was never interrupted"


def test_migration_interrupted_in_process_leaves_config_intact(monkeypatch):
    # A KeyboardInterrupt (a BaseException, not an OSError) at the moment the
    # migrated bytes are committed must not strand the config in a .bak file.
    path = _write_config(_LEGACY)
    real_replace = os.replace

    def interrupt(src, dst, *args, **kwargs):
        if Path(dst).name == "config.yaml":
            raise KeyboardInterrupt
        return real_replace(src, dst, *args, **kwargs)

    monkeypatch.setattr(config.os, "replace", interrupt)
    with pytest.raises(KeyboardInterrupt):
        config.migrate_config()
    monkeypatch.setattr(config.os, "replace", real_replace)

    assert path.read_bytes() == _LEGACY
    assert config.migrate_config() == "migrated"
    assert path.read_bytes() == _MIGRATED


@POSIX_ONLY
def test_migration_keeps_symlink_and_mode(tmp_path):
    dotfiles = tmp_path / "dotfiles"
    dotfiles.mkdir()
    target = dotfiles / "acq.yaml"
    target.write_bytes(_LEGACY)
    target.chmod(0o600)
    link = config.config_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target)

    assert config.migrate_config() == "migrated"

    assert link.is_symlink(), "migration replaced the dotfiles symlink"
    assert target.read_bytes() == _MIGRATED
    assert _mode(target) == 0o600
    assert not link.with_name("config.yaml.bak.0").exists()


def test_migration_verify_failure_restores_the_original(monkeypatch):
    path = _write_config(_LEGACY)
    monkeypatch.setattr(config, "config_schema", lambda: config.LEGACY_SCHEMA)
    with pytest.raises(config.ConfigSchemaError):
        config.migrate_config()
    assert path.read_bytes() == _LEGACY


# ---------------------------------------------------------------------------
# Persisted backend precedence: flag -> env -> config -> auto-detect.
# ---------------------------------------------------------------------------

@pytest.fixture
def both_installed(monkeypatch):
    # The installed/version overrides are honoured only for the bundled stub.
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")


def test_auto_detect_keeps_sbx_while_it_has_sandboxes(both_installed, monkeypatch):
    monkeypatch.delenv("ACQ_BACKEND", raising=False)
    monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", '{"old-box": "running"}')
    assert common._resolve_active_backend(None) == "sbx"
    monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", "{}")
    assert common._resolve_active_backend(None) == "msb"
    # A listing that fails (or times out) counts as no sandboxes, as in Bash.
    monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", '{"old-box": "running"}')
    monkeypatch.setattr(common.sbx, "list_names", lambda **_kw: None)
    assert common._resolve_active_backend(None) == "msb"

    def timed_out(**_kw):
        raise subprocess.TimeoutExpired(["sbx", "ls", "-q"], 10)

    monkeypatch.setattr(common.sbx, "list_names", timed_out)
    assert common._resolve_active_backend(None) == "msb"


def test_persisted_backend_beats_auto_detect(both_installed):
    _write_config(b"backend: sbx\n")
    assert common._resolve_active_backend(None) == "sbx"


def test_env_and_flag_beat_persisted_backend(both_installed, monkeypatch):
    _write_config(b"backend: sbx\n")
    monkeypatch.setenv("ACQ_BACKEND", "msb")
    assert common._resolve_active_backend(None) == "msb"
    monkeypatch.delenv("ACQ_BACKEND")
    assert common._resolve_active_backend("msb") == "msb"


def test_invalid_env_falls_through_to_persisted_backend(both_installed, monkeypatch):
    _write_config(b"backend: sbx\n")
    monkeypatch.setenv("ACQ_BACKEND", "podman")
    assert common._resolve_active_backend(None) == "sbx"


def test_invalid_persisted_backend_is_not_skipped_for_auto_detect(both_installed):
    _write_config(b"backend: podman\n")
    assert common._resolve_active_backend(None) is None
    assert common._invalid_persisted_backend(None) == "podman"
    # A flag or a valid ACQ_BACKEND means the persisted value is not consulted.
    assert common._invalid_persisted_backend("msb") is None


def test_invalid_persisted_backend_fails_mutating_verbs_closed(both_installed):
    _write_config(b"backend: podman\n")
    proc = _run_cli("rm", "nope", "--json")
    assert proc.returncode == 1, proc.stderr
    error = json.loads(proc.stdout)["error"]
    assert error["code"] == "backend_not_found"
    assert "config.yaml" in error["message"] and "'podman'" in error["message"]
    assert "acq backend set" in error["remediation"]


def test_invalid_persisted_backend_fails_passthrough_closed(both_installed):
    _write_config(b"backend: podman\n")
    # --json goes before the verb: after a passthrough verb it is the backend's.
    proc = _run_cli("--json", "frobnicate")
    assert proc.returncode == 1
    assert json.loads(proc.stdout)["error"]["code"] == "backend_not_found"


def test_invalid_persisted_backend_is_a_warning_for_backend_list(both_installed):
    _write_config(b"backend: podman\n")
    proc = _run_cli("backend", "list", "--json")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)["data"]
    assert data["active_backend"] is None
    assert "'podman'" in data["warnings"][0]
    assert "acq: warning:" in proc.stderr


def test_invalid_persisted_backend_fails_the_doctor_check():
    _write_config(b"backend: podman\n")
    check = doctor.persisted_backend_check()
    assert check["id"] == "config-backend" and check["status"] == "fail"
    assert "acq backend set" in check["remediation"]
    _write_config(b"backend: sbx\n")
    assert doctor.persisted_backend_check()["status"] == "pass"
    proc = _run_cli("doctor", "--json")
    assert proc.returncode == 0


# ---------------------------------------------------------------------------
# `acq backend set` / `acq backend unset` (subprocess).
# ---------------------------------------------------------------------------

def test_backend_set_persists_and_preserves_other_keys():
    path = _write_config(b"extra_kits: paseo\nbackend: msb\n")
    proc = _run_cli("backend", "set", "sbx", "--json")
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["command"] == "backend set"
    assert doc["data"]["backend"] == "sbx"
    assert doc["data"]["previous"] == "msb"
    assert doc["data"]["config_path"] == str(path)
    assert path.read_bytes() == b"schema: 1\nextra_kits: paseo\nbackend: sbx\n"


def test_backend_set_human_output():
    proc = _run_cli("backend", "set", "msb")
    assert proc.returncode == 0, proc.stderr
    assert "default backend set to 'msb'" in proc.stdout
    assert config.read_field("backend") == "msb"


def test_backend_set_refuses_an_unknown_backend():
    path = _write_config(b"backend: msb\n")
    proc = _run_cli("backend", "set", "podman", "--json")
    assert proc.returncode == 2
    assert json.loads(proc.stdout)["error"]["code"] == "usage"
    assert path.read_bytes() == b"backend: msb\n"


def test_backend_set_refuses_a_newer_config_schema():
    path = _write_config(b"schema: 99\nbackend: msb\n")
    proc = _run_cli("backend", "set", "sbx", "--json")
    assert proc.returncode == 1
    assert json.loads(proc.stdout)["error"]["code"] == "state_schema_unsupported"
    assert path.read_bytes() == b"schema: 99\nbackend: msb\n"


def test_backend_unset_clears_only_the_backend():
    path = _write_config(b"backend: sbx\nextra_kits: paseo\n")
    proc = _run_cli("backend", "unset", "--json")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)["data"]
    assert data["cleared"] is True and data["previous"] == "sbx" and data["backend"] is None
    assert path.read_bytes() == b"schema: 1\nextra_kits: paseo\n"


def test_backend_unset_removes_a_config_left_holding_only_the_marker():
    path = _write_config(b"backend: sbx\n")
    proc = _run_cli("backend", "unset")
    assert proc.returncode == 0, proc.stderr
    assert "cleared the persisted default backend" in proc.stdout
    assert not path.exists()


def test_backend_unset_when_nothing_is_persisted():
    proc = _run_cli("backend", "unset", "--json")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)["data"]
    assert data["cleared"] is False and data["previous"] is None
    assert not config.config_path().exists()


def test_backend_list_reports_the_persisted_backend(both_installed):
    _write_config(b"backend: sbx\n")
    proc = _run_cli("backend", "list", "--json")
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["data"]["active_backend"] == "sbx"


# ---------------------------------------------------------------------------
# Bash <-> Python parity on the shared config.yaml.
# ---------------------------------------------------------------------------

BASH = shutil.which("bash")
needs_bash = pytest.mark.skipif(BASH is None or os.name != "posix", reason="needs bash on a POSIX host")

_PARITY_INPUTS = [
    b"",
    b"backend: sbx\n",
    b"schema: 1\nbackend: 'msb'   # pinned\nextra_kits: paseo openchamber\n",
    b'backend: "sbx" # c\r\nscope_github_token: yes\r\n',
    b"backend: sbx\nbackend: msb\n  backend: indented\nbackendx: no",
    b"# comment only\nfuture: {nested: 1}\nbackend:\n",
    b"backend: a#b\nextra_kits: x # y # z\n",
    b'backend: "a"#b\nextra_kits: \'x\'#y # z\n',
]


def _bash(script: str, *args: str) -> subprocess.CompletedProcess:
    assert BASH is not None
    return subprocess.run(
        [BASH, "-c", f'source "$1"; shift; {script}', "bash", str(COMMON_SH), *args],
        capture_output=True,
        timeout=60,
        env={**os.environ, "LC_ALL": "C"},
    )


@needs_bash
@pytest.mark.parametrize("content", _PARITY_INPUTS)
@pytest.mark.parametrize("key", ["backend", "extra_kits", "scope_github_token", "future"])
def test_bash_and_python_read_the_same_value(content, key):
    _write_config(content)
    proc = _bash('_acq_config_read_field "$1"', key)
    assert proc.returncode == 0, proc.stderr
    bash_value = proc.stdout.decode().rstrip("\n") or None
    assert config.read_field(key) == bash_value


@needs_bash
@pytest.mark.parametrize("content", [c for c in _PARITY_INPUTS if c])
@pytest.mark.parametrize(("key", "value"), [("backend", "sbx"), ("backend", ""), ("extra_kits", "paseo")])
def test_bash_and_python_write_the_same_bytes(content, key, value):
    path = _write_config(content)
    proc = _bash('_acq_config_write_field "$1" "$2"', key, value)
    assert proc.returncode == 0, proc.stderr
    bash_bytes = path.read_bytes()

    _write_config(content)
    config.write_field(key, value)
    assert path.read_bytes() == bash_bytes


@needs_bash
def test_python_backend_set_round_trips_through_bash(both_installed):
    _write_config(b"extra_kits: paseo\n")
    assert _run_cli("backend", "set", "sbx").returncode == 0
    proc = _bash("_acq_config_read_field backend; _acq_config_read_field extra_kits")
    assert proc.stdout.decode().splitlines() == ["sbx", "paseo"]

    # Bash writes the backend back; Python resolves what Bash persisted.
    assert _bash("_acq_config_write_field backend msb").returncode == 0
    assert common._resolve_active_backend(None) == "msb"
    assert config.config_schema() == config.CONFIG_SCHEMA
    assert config.read_field("extra_kits") == "paseo"


# ---------------------------------------------------------------------------
# Read-only configs, the seed seam, leftovers, and doctor's unreadable cases.
# ---------------------------------------------------------------------------

_STUB_MSB = {"ACQ_MSB_BIN": "__stub__", "ACQ_MSB_VERSION": "0.7.7", "ACQ_SBX_INSTALLED": "0"}


def _read_only_dotfile(tmp_path: Path) -> Path:
    """A legacy config.yaml symlinked to a read-only file in a read-only directory."""
    store = tmp_path / "store"
    store.mkdir()
    target = store / "acq.yaml"
    target.write_bytes(_LEGACY)
    target.chmod(0o444)
    store.chmod(0o555)
    link = config.config_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target)
    if os.access(store, os.W_OK):
        store.chmod(0o755)
        pytest.skip("running with privileges that bypass file modes")
    return target


@POSIX_ONLY
def test_migration_skips_a_read_only_symlink_target(tmp_path, capsys):
    target = _read_only_dotfile(tmp_path)
    try:
        assert config.migrate_config() == "skipped"
        assert target.read_bytes() == _LEGACY
        assert config.config_path().is_symlink()
        assert not config.config_path().with_name("config.yaml.bak.0").exists()
        note = capsys.readouterr().err
        assert str(target) in note and "schema: 1" in note
        # Still readable, and doctor keeps warning.
        assert config.read_field("backend") == "msb"
        assert config.doctor_check()["status"] == "warn"
    finally:
        target.parent.chmod(0o755)


@POSIX_ONLY
def test_mutating_verb_runs_past_a_read_only_legacy_config(tmp_path, monkeypatch):
    target = _read_only_dotfile(tmp_path)
    try:
        for name, value in _STUB_MSB.items():
            monkeypatch.setenv(name, value)
        proc = _run_cli("--backend", "msb", "rm", "nope", "--json")
        assert proc.returncode == 1
        assert json.loads(proc.stdout)["error"]["code"] == "sandbox_not_found", proc.stdout
        assert "read-only" in proc.stderr and str(target) in proc.stderr
    finally:
        target.parent.chmod(0o755)


def test_config_seed_is_never_materialized_on_a_read_only_path(monkeypatch):
    monkeypatch.setenv("ACQ_CONFIG_SEED", "backend: sbx")
    for name, value in _STUB_MSB.items():
        monkeypatch.setenv(name, value)
    assert _run_cli("backend", "list", "--json").returncode == 0
    assert _run_cli("doctor", "--json").returncode == 0
    assert config.read_field("backend") is None
    assert not config.config_path().exists()


def test_config_seed_is_materialized_by_the_migration_pre_step_in_stub_mode(monkeypatch):
    monkeypatch.setenv("ACQ_CONFIG_SEED", "backend: sbx")
    migration.migrate_tree()
    assert not config.config_path().exists(), "seed honoured without a stub backend"

    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    migration.migrate_tree()
    path = config.config_path()
    assert config.read_field("backend") == "sbx"
    assert config.config_schema() == config.CONFIG_SCHEMA  # migrated in the same pre-step
    if os.name == "posix":
        assert _mode(path.parent) == 0o700
        assert _mode(path) == 0o600


def test_leftover_backup_is_removed_once_the_config_is_marked():
    path = _write_config(_MIGRATED)
    backup = path.with_name("config.yaml.bak.0")
    backup.write_bytes(_LEGACY)
    assert config.migrate_config() == "none"
    assert not backup.exists()
    assert path.read_bytes() == _MIGRATED


@pytest.mark.parametrize("content", [_MIGRATED, _LEGACY])
def test_a_directory_in_place_of_the_backup_is_refused_by_name(content):
    path = _write_config(content)
    backup = path.with_name("config.yaml.bak.0")
    backup.mkdir()
    with pytest.raises(migration.MigrationError) as info:
        migration.migrate_tree()
    assert info.value.code == "migration_failed"
    assert "config.yaml.bak.0" in info.value.message
    assert "config.yaml.bak.0" in (info.value.remediation or "")
    assert path.read_bytes() == content


def _symlinks_supported(tmp_path: Path) -> bool:
    """True when this host lets the test user create symlinks (Windows needs a
    privilege or developer mode)."""
    probe = tmp_path / "symlink-probe"
    try:
        probe.symlink_to(tmp_path / "symlink-probe-target")
    except (OSError, NotImplementedError):
        return False
    probe.unlink()
    return True


def _age(path: Path) -> None:
    """Backdate ``path`` past the stale-temp cutoff without following a symlink.

    A symlink's own mtime can only be set where ``os.utime`` supports
    ``follow_symlinks=False`` (not on Windows); there it is left as is, which
    only makes the "symlinks survive" check easier to pass, never harder.
    """
    old = time.time() - 3600
    if not path.is_symlink():
        os.utime(path, (old, old))
    elif os.utime in os.supports_follow_symlinks:
        os.utime(path, (old, old), follow_symlinks=False)


def test_stale_temp_files_are_removed_and_fresh_ones_kept():
    path = _write_config(_MIGRATED)
    stale = [path.with_name("config.yaml.tmp.abc_1234"), path.with_name("config.yaml.bak.0.tmp.def45678"),
             path.with_name("config.yaml.tmp.4242")]
    fresh = path.with_name("config.yaml.tmp.xyz78901")
    for leftover in [*stale, fresh]:
        leftover.write_bytes(b"partial")
    for leftover in stale:
        _age(leftover)
    config.migrate_config()
    assert not any(p.exists() for p in stale)
    assert fresh.exists()


def test_replace_bytes_temp_names_match_the_cleanup_pattern(monkeypatch):
    # Pins the mkstemp name shape the cleanup relies on (prefix + 8 characters).
    seen: list[str] = []
    real_replace = os.replace

    def record(src, dst, *args, **kwargs):
        seen.append(Path(src).name)
        return real_replace(src, dst, *args, **kwargs)

    monkeypatch.setattr(config.os, "replace", record)
    config.write_field("backend", "sbx")
    assert seen and all(config._temp_name_pattern("config.yaml", bash=False).fullmatch(n) for n in seen), seen


def _plant_near_misses(directory: Path, base: str, tmp_path: Path, symlinks: bool) -> list[Path]:
    """Create user files that look like temp files but must survive the cleanup."""
    planted = [directory / f"{base}.tmp.old", directory / f"{base}.tmp.abcd12345", directory / f"{base}.tmp.QRST9876"]
    for user_file in planted:
        user_file.write_bytes(b"mine")
    a_dir = directory / f"{base}.tmp.efgh5678"
    a_dir.mkdir()
    planted.append(a_dir)
    if symlinks:
        symlink = directory / f"{base}.tmp.abcd1234"
        symlink.symlink_to(tmp_path / "elsewhere")
        planted.append(symlink)
    return planted


def test_cleanup_leaves_user_files_symlinks_and_directories_alone(tmp_path):
    path = _write_config(_MIGRATED)
    survivors = _plant_near_misses(path.parent, "config.yaml", tmp_path, _symlinks_supported(tmp_path))
    ours = path.with_name("config.yaml.tmp.zz_99999")
    ours.write_bytes(b"partial")
    for leftover in [*survivors, ours]:
        _age(leftover)

    assert config.migrate_config() == "none"
    missing = [p.name for p in survivors if not os.path.lexists(p)]
    assert not missing, f"cleanup removed {missing}"
    assert not ours.exists()


def test_cleanup_next_to_a_symlink_target_touches_only_acq_temp_files(tmp_path):
    if not _symlinks_supported(tmp_path):
        pytest.skip("this host does not allow creating symlinks")
    dotfiles = tmp_path / "dotfiles"
    dotfiles.mkdir()
    target = dotfiles / "acq.yaml"
    target.write_bytes(_MIGRATED)
    link = config.config_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target)

    survivors = _plant_near_misses(dotfiles, "acq.yaml", tmp_path, symlinks=True)
    # Next to the target only acq's own temp files are removed: no Bash pid
    # files and no backup temp files, which are only ever written in the config
    # directory.
    bash_like = dotfiles / "acq.yaml.tmp.4242"
    backup_like = dotfiles / "acq.yaml.bak.0.tmp.abcd1234"
    ours = dotfiles / "acq.yaml.tmp.zz_99999"
    for leftover in (bash_like, backup_like, ours):
        leftover.write_bytes(b"partial")
    survivors += [bash_like, backup_like]
    for leftover in [*survivors, ours]:
        _age(leftover)

    assert config.migrate_config() == "none"
    missing = [p.name for p in survivors if not os.path.lexists(p)]
    assert not missing, f"cleanup removed {missing}"
    assert not ours.exists()


@POSIX_ONLY
def test_doctor_fails_on_an_unreadable_config():
    path = _write_config(b"schema: 1\n")
    path.chmod(0o000)
    try:
        if os.access(path, os.R_OK):
            pytest.skip("running with privileges that bypass file modes")
        check = config.doctor_check()
        assert check["status"] == "fail" and "cannot read" in check["message"]
    finally:
        path.chmod(0o600)


@POSIX_ONLY
def test_doctor_fails_on_a_dangling_symlink(tmp_path):
    link = config.config_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(tmp_path / "gone.yaml")
    check = config.doctor_check()
    assert check["status"] == "fail" and "dangling symlink" in check["message"]


# ---------------------------------------------------------------------------
# The config.yaml lock Bash and Python share (lock.ConfigDirLock, Bash
# _acq_config_lock_acquire).
# ---------------------------------------------------------------------------

def _dir_lock() -> Path:
    path = config.config_lock_path()
    return path.with_name(path.name + ".d")


def _hold_dir_lock(owner: str | None) -> Path:
    """Leave the shared lock directory as another command would, with ``owner`` as its owner line."""
    lock_dir = _dir_lock()
    lock_dir.mkdir(parents=True)
    if owner is not None:
        (lock_dir / "owner").write_text(owner + "\n", encoding="utf-8")
    return lock_dir


def _live_owner() -> str:
    from acq_py import lock

    identity = lock._process_identity(os.getpid())
    if identity is None:
        pytest.skip("no process identity (ps) on this host")
    return f"{os.getpid()} {identity}"


@POSIX_ONLY
def test_python_config_write_takes_and_releases_the_shared_lock_directory(monkeypatch):
    from acq_py import lock

    seen = []
    real = config._write_field_locked
    monkeypatch.setattr(config, "_write_field_locked",
                        lambda k, v: seen.append(lock._owner_line(_dir_lock())) or real(k, v))
    config.write_field("backend", "sbx")
    assert seen == [_live_owner()]  # held, with this process as its owner, during the write
    assert not os.path.lexists(_dir_lock())


@POSIX_ONLY
def test_python_config_write_waits_for_a_live_holder_of_the_shared_lock(monkeypatch):
    path = _write_config(b"schema: 1\nbackend: msb\n")
    lock_dir = _hold_dir_lock(_live_owner())  # as a running Bash acq leaves it
    monkeypatch.setenv("ACQ_MIGRATION_LOCK_TIMEOUT", "0.3")
    with pytest.raises(config.ConfigLockTimeout) as exc:
        config.write_field("backend", "sbx")
    message = str(exc.value)
    assert f"{lock_dir} is held" in message
    assert f"rm -f -- {lock_dir}/owner && rmdir -- {lock_dir}" in message
    assert path.read_bytes() == b"schema: 1\nbackend: msb\n"
    assert lock_dir.is_dir()


@POSIX_ONLY
def test_python_never_removes_a_shared_lock_directory_with_no_owner(monkeypatch):
    lock_dir = _hold_dir_lock(None)
    monkeypatch.setenv("ACQ_MIGRATION_LOCK_TIMEOUT", "0.3")
    with pytest.raises(config.ConfigLockTimeout, match="remove the leftover lock directory"):
        config.write_field("backend", "sbx")
    assert lock_dir.is_dir()
    # The documented recovery command clears it.
    subprocess.run(["sh", "-c", f"rm -f -- '{lock_dir}/owner' && rmdir -- '{lock_dir}'"], check=True)
    config.write_field("backend", "sbx")
    assert config.read_field("backend") == "sbx"


@POSIX_ONLY
def test_python_recovers_a_shared_lock_left_by_a_dead_holder():
    proc = subprocess.run([sys.executable, "-c", "import os; print(os.getpid())"], capture_output=True,
                          text=True, check=True)
    lock_dir = _hold_dir_lock(f"{proc.stdout.strip()} Thu1Jan00:00:001970")
    config.write_field("backend", "sbx")
    assert config.read_field("backend") == "sbx"
    assert not os.path.lexists(lock_dir)


@needs_bash
def test_bash_config_write_waits_while_python_holds_the_config_lock():
    path = _write_config(b"schema: 1\nbackend: msb\n")
    env = {"ACQ_MIGRATION_LOCK_TIMEOUT": "0.4"}
    with config.config_lock():
        proc = subprocess.run(
            [BASH, "-c", 'source "$1"; _acq_config_write_field backend sbx', "bash", str(COMMON_SH)],
            capture_output=True, text=True, timeout=60, env={**os.environ, **env},
        )
        assert proc.returncode == 1, proc.stderr
        assert "could not take the config.yaml lock" in proc.stderr
        assert path.read_bytes() == b"schema: 1\nbackend: msb\n"
    proc = _bash("_acq_config_write_field backend sbx")
    assert proc.returncode == 0, proc.stderr
    assert config.read_field("backend") == "sbx"
    assert not os.path.lexists(_dir_lock())


@needs_bash
def test_python_config_write_waits_while_bash_holds_the_shared_lock(monkeypatch):
    # Bash holds the lock while it rewrites config.yaml; a Python write in that
    # window waits instead of overwriting the Bash change with stale content.
    path = _write_config(b"schema: 1\nbackend: msb\n")
    gate = _dir_lock().parent / "gate"
    script = (
        '_acq_config_write_field_locked() { : > "$1"; while [ -e "$1" ]; do sleep 0.05; done; }; '
        '_acq_config_write_field "$1"'
    )
    holder = subprocess.Popen([BASH, "-c", f'source "$1"; shift; {script}', "bash", str(COMMON_SH), str(gate)],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={**os.environ, "LC_ALL": "C"})
    try:
        deadline = time.monotonic() + 30
        while not gate.exists():
            assert holder.poll() is None, holder.communicate()
            assert time.monotonic() < deadline, "the Bash writer never took the lock"
            time.sleep(0.05)
        monkeypatch.setenv("ACQ_MIGRATION_LOCK_TIMEOUT", "0.3")
        with pytest.raises(config.ConfigLockTimeout):
            config.write_field("backend", "sbx")
        assert path.read_bytes() == b"schema: 1\nbackend: msb\n"
    finally:
        gate.unlink(missing_ok=True)
        holder.communicate(timeout=30)
    assert holder.returncode == 0
    monkeypatch.delenv("ACQ_MIGRATION_LOCK_TIMEOUT")
    config.write_field("backend", "sbx")
    assert config.read_field("backend") == "sbx"


def test_windows_rule_counts_a_fresh_directory_as_held_and_recovers_an_old_one():
    # ConfigDirLock._acquire_windows is plain os code, so its rule is checked here
    # on any host: neither side can check the other's PID on Windows, so the age
    # of the directory decides.
    from acq_py import lock, state

    shared = lock.ConfigDirLock(config.config_lock_path(), state.state_dir())
    lock_dir = _hold_dir_lock("4242 unverified")
    assert shared._acquire_windows() is False and shared.blocked
    old = time.time() - lock.CONFIG_WINDOWS_STALE_S - 5
    os.utime(lock_dir, (old, old))
    assert shared._acquire_windows() is True
    assert lock._owner_line(lock_dir) == f"{os.getpid()} windows"
    shared.release()
    assert not os.path.lexists(lock_dir)
