"""Tier-2 implementation tests for the state-migration slice (ADR-0041m).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly, drive
``migration.migrate_tree()`` and ``cli.main`` in-process, and inspect the
host-authoritative state records and the tree-level generation marker. Contract
evidence lives only in the vector corpus (``test/vectors``); the
``ACQ_STATE_SEED`` and ``ACQ_SECURITY_MOUNT_STATE`` seams are internal test
seams, never secrets.

Each guard below is a mutation-proof assertion: the exact refusal code and exit
class are pinned, so removing or weakening the guard fails the test.
"""

from __future__ import annotations

import json
import os

import pytest

from acq_py import cli, config, errors, lock, migration, security, state

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key


def _env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    for name in (
        "ACQ_BACKEND",
        "ACQ_MSB_STUB_CATALOG",
        "ACQ_MSB_STUB_FAIL",
        "ACQ_IMAGE",
        "ACQ_MSB_IMAGE",
        "ACQ_STATE_SEED",
        "ACQ_SECURITY_MOUNT_STATE",
        "ACQ_MIGRATION_LOCK_TIMEOUT",
    ):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1]) if out else None
    return rc, doc


def _write_record(backend, name, doc):
    path = state.record_path(backend, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


def _write_catalog(tmp_path, catalog):
    """Seed the stub msb catalog on disk (persists across remove+create)."""
    path = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(catalog), encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# Forward migration in place (legacy v0 -> schema=1).
# ---------------------------------------------------------------------------

def test_forward_migration_in_place(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    path = _write_record(
        "msb", "legacy",
        {"name": "legacy", "backend": "msb", "agent": "opencode", "workspace": "/w"},
    )

    migration.migrate_tree()

    record = state.record_read("msb", "legacy")
    assert record is not None
    assert record["schema"] == state.STATE_SCHEMA
    assert list(record.keys())[0] == "schema"  # schema is the FIRST field
    assert record["agent"] == "opencode"
    assert record["workspace"] == "/w"
    # The .bak.<old_schema> sidecar is deleted once the new record verified.
    assert not path.with_name(path.name + ".bak.0").exists()
    # The generation marker is written LAST, declaring the tree complete.
    assert migration.read_generation() == migration.TARGET_GENERATION


def test_forward_migration_is_idempotent(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    path = _write_record("msb", "legacy", {"name": "legacy", "backend": "msb"})

    migration.migrate_tree()
    first = state.record_read("msb", "legacy")
    migration.migrate_tree()  # re-run: current record is a no-op

    assert state.record_read("msb", "legacy") == first
    assert not path.with_name(path.name + ".bak.0").exists()


def test_crash_converges_idempotent(monkeypatch, tmp_path):
    """A partial tree (some records migrated, no marker) resumes and converges."""
    _env(monkeypatch, tmp_path)
    path_a = _write_record("msb", "a", {"name": "a", "backend": "msb"})
    _write_record("msb", "b", {"name": "b", "backend": "msb"})

    # Simulate a crash after migrating "a" but before writing the marker.
    migration._migrate_record(path_a, {"name": "a", "backend": "msb"})
    assert state.record_read("msb", "a") is not None
    assert state.record_read("msb", "b") is None  # still legacy v0
    assert migration.read_generation() == 0  # marker NOT written (crash)

    migration.migrate_tree()  # resume

    assert state.record_read("msb", "a") is not None  # idempotent no-op
    assert state.record_read("msb", "b") is not None  # now migrated
    assert migration.read_generation() == migration.TARGET_GENERATION


# ---------------------------------------------------------------------------
# Fail-closed refusal (newer / unparseable / min_reader).
# ---------------------------------------------------------------------------

def test_newer_schema_refused(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _write_record("msb", "future", {"schema": 99, "name": "future", "backend": "msb"})

    with pytest.raises(migration.MigrationError) as exc:
        migration.migrate_tree()
    assert exc.value.code == errors.STATE_SCHEMA_UNSUPPORTED
    assert "schema 99" in exc.value.message
    assert exc.value.remediation


def test_unparseable_record_refused(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    path = state.record_path("msb", "broken")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("not json {{{", encoding="utf-8")

    with pytest.raises(migration.MigrationError) as exc:
        migration.migrate_tree()
    assert exc.value.code == errors.STATE_SCHEMA_UNSUPPORTED


def test_min_reader_refused(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _write_record("msb", "needy", {"schema": 1, "min_reader": 2, "name": "needy", "backend": "msb"})

    with pytest.raises(migration.MigrationError) as exc:
        migration.migrate_tree()
    assert exc.value.code == errors.STATE_SCHEMA_UNSUPPORTED
    assert "min_reader" in exc.value.message

    # The strict per-record reader refuses the same record (not just the tree scan).
    with pytest.raises(state.StateSchemaError):
        state.record_read("msb", "needy")


# ---------------------------------------------------------------------------
# Atomic + non-destructive migration.
# ---------------------------------------------------------------------------

def test_atomic_failure_leaves_old_record_intact(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    legacy = {"name": "legacy", "backend": "msb", "agent": "opencode"}
    path = _write_record("msb", "legacy", legacy)

    # Force the read-back verify to fail, so the migration must restore the prior.
    def _failing_verify(_path):
        raise migration.MigrationError(errors.MIGRATION_FAILED, "verify failed", step="verify")

    monkeypatch.setattr(migration, "_verify", _failing_verify)

    with pytest.raises(migration.MigrationError) as exc:
        migration.migrate_tree()
    assert exc.value.code == errors.MIGRATION_FAILED
    assert exc.value.step == "verify"

    # The old record is intact (still legacy v0, unchanged content)...
    assert json.loads(path.read_text(encoding="utf-8")) == legacy
    # ...and no .bak or .tmp sidecar is left behind.
    assert not path.with_name(path.name + ".bak.0").exists()
    assert not path.with_suffix(".json.tmp").exists()
    assert migration.read_generation() == 0  # never declared complete


def test_bak_retained_until_verified(monkeypatch, tmp_path):
    """The .bak sidecar exists only while the new record is unverified."""
    _env(monkeypatch, tmp_path)
    path = _write_record("msb", "legacy", {"name": "legacy", "backend": "msb"})
    bak = path.with_name(path.name + ".bak.0")

    observed = []

    original_verify = migration._verify

    def _spy_verify(p):
        # The .bak sidecar must still exist while we verify (it is retained
        # until the new record parses, then deleted).
        observed.append(bak.exists())
        original_verify(p)

    monkeypatch.setattr(migration, "_verify", _spy_verify)

    migration.migrate_tree()

    assert observed == [True]
    assert not bak.exists()


# ---------------------------------------------------------------------------
# Exclusive OS advisory lock.
# ---------------------------------------------------------------------------

def test_lock_second_invocation_fails_closed(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MIGRATION_LOCK_TIMEOUT", "0.2")

    with lock.exclusive_lock(migration.lock_path(), timeout_s=5.0):
        with pytest.raises(migration.MigrationError) as exc:
            migration.migrate_tree()
        assert exc.value.code == errors.MIGRATION_LOCKED


def test_lock_auto_releases_after_use(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _write_record("msb", "legacy", {"name": "legacy", "backend": "msb"})

    migration.migrate_tree()  # acquires and releases the lock
    # A subsequent migration succeeds: the lock was released, not stranded.
    migration.migrate_tree()
    assert state.record_read("msb", "legacy") is not None


# ---------------------------------------------------------------------------
# config.yaml flat schema marker.
# ---------------------------------------------------------------------------

def test_config_forward_migration_adds_schema_first(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("backend: msb\n", encoding="utf-8")

    assert config.migrate_config() == "migrated"
    assert config.config_schema() == config.CONFIG_SCHEMA
    lines = path.read_text(encoding="utf-8").splitlines()
    assert lines[0] == f"schema: {config.CONFIG_SCHEMA}"
    assert "backend: msb" in lines
    # Non-destructive: no .bak sidecar left after a verified migration.
    assert not path.with_name(path.name + ".bak.0").exists()


def test_config_newer_schema_refused(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("schema: 99\n", encoding="utf-8")

    with pytest.raises(config.ConfigSchemaError):
        config.config_schema()


# ---------------------------------------------------------------------------
# Security-exception recreation (ADR-0035 / ADR-0041m).
# ---------------------------------------------------------------------------

_SEC_RECORD = {
    "schema": 1,
    "name": "sec",
    "backend": "msb",
    "agent": "opencode",
    "workspace": "/w",
    "ro_host_config": True,
}


def test_attach_fails_closed_on_missing_mount(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    _write_record("msb", "sec", _SEC_RECORD)
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))

    rc, doc = _invoke(capsys, "--backend", "msb", "attach", "sec", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.SECURITY_EXCEPTION
    assert "recreate" in doc["error"]["remediation"]


def test_attach_ok_when_mount_present(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    _write_record("msb", "sec", _SEC_RECORD)
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "ok"}))

    rc, _doc = _invoke(capsys, "--backend", "msb", "attach", "sec", "--json")
    assert rc == 0  # the gate passes; the stub launch succeeds


def test_attach_not_gated_without_record_requirement(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"plain": "running"})
    _write_record("msb", "plain", {"schema": 1, "name": "plain", "backend": "msb", "agent": "opencode", "workspace": "/w"})
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"plain": "missing"}))

    # No ro_host_config -> the security gate does not apply (legacy path).
    rc, _doc = _invoke(capsys, "--backend", "msb", "attach", "plain", "--json")
    assert rc == 0


def test_recreate_requires_consent(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    _write_record("msb", "sec", _SEC_RECORD)
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.CONSENT_REQUIRED


def test_recreate_on_windows_nul_stdin_refuses_without_prompting(monkeypatch, tmp_path, capsys, windows_nul_stdin):
    """Human mode with ``< NUL`` on Windows: isatty() says True, but there is no
    console, so ``create --recreate`` must refuse rather than prompt."""
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    _write_record("msb", "sec", _SEC_RECORD)
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))
    windows_nul_stdin("y\n")
    monkeypatch.setattr("builtins.input", lambda prompt="": pytest.fail("prompted without a console"))

    rc = cli.main(["--backend", "msb", "create", "--recreate", "sec"])
    err = capsys.readouterr().err
    assert rc == 1
    assert "refusing to recreate 'sec' non-interactively without --yes" in err


def test_recreate_refused_when_not_security_exception(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"plain": "running"})
    _write_record("msb", "plain", {"schema": 1, "name": "plain", "backend": "msb", "agent": "opencode", "workspace": "/w"})
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"plain": "ok"}))

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "plain", "--yes", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.VALIDATION_FAILED


def test_recreate_preserves_host_record(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _write_catalog(tmp_path, {"sec": "running"})  # on-disk catalog: remove+create persist
    # Recreate canonicalizes the recorded msb workspace with realpath, which on
    # Windows turns a POSIX "/w" into "<current drive>:\w". Record a workspace
    # that is already canonical on this host, so preserved means unchanged.
    (tmp_path / "w").mkdir()
    workspace = os.path.realpath(tmp_path / "w")
    _write_record("msb", "sec", {**_SEC_RECORD, "workspace": workspace})
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 0
    assert doc["data"]["recreated"] is True

    # Host record + secrets preserved: the record keeps its authority fields.
    record = state.record_read("msb", "sec")
    assert record["agent"] == "opencode"
    assert record["workspace"] == workspace
    # Re-established where this host can have it; never claimed on Windows.
    assert record.get("ro_host_config") is (True if security.ro_mount_supported() else None)


# ---------------------------------------------------------------------------
# The migration pre-step runs before a mutating verb (CLI-level).
# ---------------------------------------------------------------------------

def test_mutating_verb_refuses_on_newer_record(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"x": "running"})
    _write_record("msb", "future", {"schema": 99, "name": "future", "backend": "msb"})

    rc, doc = _invoke(capsys, "--backend", "msb", "stop", "x", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.STATE_SCHEMA_UNSUPPORTED


def test_read_only_verb_does_not_migrate(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={})
    path = _write_record("msb", "legacy", {"name": "legacy", "backend": "msb"})

    rc, doc = _invoke(capsys, "--backend", "msb", "ls", "--json")
    assert rc == 0
    # Read-only diagnostics do NOT migrate: the legacy record stays schema-less.
    assert json.loads(path.read_text(encoding="utf-8")) == {"name": "legacy", "backend": "msb"}
    assert migration.read_generation() == 0


def test_doctor_state_check_reports_legacy_as_warn(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={})
    _write_record("msb", "legacy", {"name": "legacy", "backend": "msb"})

    rc, doc = _invoke(capsys, "--backend", "msb", "doctor", "--json")
    assert rc == 0
    checks = {c["id"]: c for c in doc["data"]["checks"]}
    assert checks["state"]["status"] == "warn"


def test_doctor_state_check_reports_newer_as_fail(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={})
    _write_record("msb", "future", {"schema": 99, "name": "future", "backend": "msb"})

    rc, doc = _invoke(capsys, "--backend", "msb", "doctor", "--json")
    assert rc == 0
    checks = {c["id"]: c for c in doc["data"]["checks"]}
    assert checks["state"]["status"] == "fail"


# ---------------------------------------------------------------------------
# Review fixes.
# ---------------------------------------------------------------------------

def test_attach_fails_closed_when_probe_unset(monkeypatch, tmp_path, capsys):
    """The security gate fails closed when the mount probe is unset (not "ok")."""
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    _write_record("msb", "sec", _SEC_RECORD)
    # No ACQ_SECURITY_MOUNT_STATE -> the offline default is "unknown", fail closed.
    assert "ACQ_SECURITY_MOUNT_STATE" not in os.environ

    rc, doc = _invoke(capsys, "--backend", "msb", "attach", "sec", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.SECURITY_EXCEPTION


def test_mount_state_unset_is_unknown(monkeypatch, tmp_path):
    # Without the seam the real probe runs; against the stub, a sandbox msb does
    # not know cannot be inspected, so the guarantee is unconfirmed.
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    assert security.mount_state("msb", "anything") == "unknown"


def test_crash_window_preserves_record(monkeypatch, tmp_path):
    """A crash at the rename step must not orphan a record onto a .bak sidecar.

    The fix copies (not moves) the prior record to ``.bak``, so ``path`` always
    holds a valid record; a crash at the rename leaves the old record in place.
    """
    _env(monkeypatch, tmp_path)
    legacy = {"name": "legacy", "backend": "msb", "agent": "opencode"}
    path = _write_record("msb", "legacy", legacy)

    class _Crash(BaseException):
        pass

    real_replace = os.replace

    def crash_at_rename(src, dst, *a, **k):
        # Crash only when the new record is about to go live (dst == path);
        # a ".bak" sidecar move (dst == backup) is allowed to succeed so the
        # test can observe the orphan the buggy move would create.
        if dst == path:
            raise _Crash("simulated crash at rename")
        return real_replace(src, dst, *a, **k)

    monkeypatch.setattr(migration.os, "replace", crash_at_rename)

    with pytest.raises(_Crash):
        migration.migrate_tree()

    # `path` still holds the OLD record — it was copied, never moved.
    assert json.loads(path.read_text(encoding="utf-8")) == legacy

    # Resume converges without losing the record.
    monkeypatch.setattr(migration.os, "replace", real_replace)
    migration.migrate_tree()
    record = state.record_read("msb", "legacy")
    assert record is not None
    assert record["agent"] == "opencode"
    assert record["schema"] == state.STATE_SCHEMA


def test_sandbox_migration_does_not_touch_kit_records(monkeypatch, tmp_path):
    """Migration is type-aware: kit records keep their own KIT_SCHEMA space."""
    _env(monkeypatch, tmp_path)
    root = state.state_dir()

    kit_source = root / "kit-sources" / "github.com_acme_team-kits.abc12345.json"
    kit_source.parent.mkdir(parents=True, exist_ok=True)
    kit_source.write_text(
        json.dumps({"repository": "github.com/acme/team-kits", "ref": "a" * 40, "directory": "kits"}),
        encoding="utf-8",
    )
    kit_prov = root / "provenance" / "msb" / "box.abc12345.json"
    kit_prov.parent.mkdir(parents=True, exist_ok=True)
    kit_prov.write_text(
        json.dumps({"schema": 99, "backend": "msb", "sandbox": "box", "applied_ref": "x"}),
        encoding="utf-8",
    )
    _write_record("msb", "legacy", {"name": "legacy", "backend": "msb", "agent": "opencode"})

    migration.migrate_tree()

    # The sandbox record migrated...
    assert state.record_read("msb", "legacy") is not None
    # ...but the kit records are untouched: the schema-less kit-source record is
    # NOT rewritten into sandbox space, and the bumped KIT_SCHEMA record is
    # ignored rather than hard-failing sandbox migration.
    assert json.loads(kit_source.read_text(encoding="utf-8")) == {
        "repository": "github.com/acme/team-kits",
        "ref": "a" * 40,
        "directory": "kits",
    }
    assert json.loads(kit_prov.read_text(encoding="utf-8")) == {
        "schema": 99,
        "backend": "msb",
        "sandbox": "box",
        "applied_ref": "x",
    }


def test_config_migrated_independently_of_generation_marker(monkeypatch, tmp_path):
    """A legacy config.yaml is migrated even after the state tree is current."""
    _env(monkeypatch, tmp_path)
    _write_record("msb", "legacy", {"name": "legacy", "backend": "msb"})
    migration.migrate_tree()
    assert migration.read_generation() == migration.TARGET_GENERATION

    # A legacy config.yaml appears after the state tree is already current.
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("backend: msb\n", encoding="utf-8")

    migration.migrate_tree()
    assert config.config_schema() == config.CONFIG_SCHEMA
    lines = path.read_text(encoding="utf-8").splitlines()
    assert lines[0] == f"schema: {config.CONFIG_SCHEMA}"


def test_seed_is_materialized_inside_lock(monkeypatch, tmp_path):
    """The test-seam materialization happens inside the migration lock."""
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MIGRATION_LOCK_TIMEOUT", "0.2")
    monkeypatch.setenv("ACQ_STATE_SEED", json.dumps({"msb/legacy": {"name": "legacy", "backend": "msb"}}))
    path = state.record_path("msb", "legacy")

    with lock.exclusive_lock(migration.lock_path(), timeout_s=5.0):
        with pytest.raises(migration.MigrationError) as exc:
            migration.migrate_tree()
        assert exc.value.code == errors.MIGRATION_LOCKED

    # The seed was NOT materialized: it happens inside the (held) lock.
    assert not path.exists()
