"""Tier-2 implementation tests for the MSB lifecycle slice (ADR-0040m, lifecycle side).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb, then inspect
the host-authoritative state record. Contract evidence lives only in the vector
corpus (``test/vectors``); the stub is an internal test seam, never a secret.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

from acq_py import cli, migration, state
from fresh_fixture import fresh_fixture as _fresh_fixture

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key


def _env(monkeypatch, tmp_path, *, catalog=None, fresh=False):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_IMAGE", "ACQ_MSB_IMAGE", "ACQ_MSB_STUB_FAIL"):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))
    if fresh:
        _fresh_fixture(monkeypatch, tmp_path)


def _jobs(tmp_path, name):
    path = tmp_path / "msb-home/.microsandbox/fresh-jobs.json"
    return list(json.loads(path.read_text(encoding="utf-8")).get(name, {}).values()) if path.exists() else []


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    # Refuse an earlier success envelope followed by a failure, too.
    doc = json.loads(out) if out else None
    return rc, doc


def test_create_writes_schema_first_record(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path, fresh=True)

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "e2e", "--json")
    assert rc == 0
    assert doc["command"] == "create"
    assert doc["data"]["name"] == "e2e"
    assert doc["data"]["backend"] == "msb"
    assert doc["data"]["state"] == "running"

    record = state.record_read("msb", "e2e")
    assert record is not None
    assert record["schema"] == state.STATE_SCHEMA
    # `schema` is the FIRST field (ADR-0041m: the version marker leads the record).
    assert list(record.keys())[0] == "schema"
    assert record["agent"] == "opencode"


def test_lifecycle_end_to_end(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path, fresh=True)

    assert _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "e2e", "--json")[0] == 0

    rc, doc = _invoke(capsys, "--backend", "msb", "ls", "--json")
    assert rc == 0
    names = {entry["name"]: entry for entry in doc["data"]["sandboxes"]}
    assert names["e2e"]["state"] == "running"
    assert names["e2e"]["backend"] == "msb"

    rc, doc = _invoke(capsys, "--backend", "msb", "stop", "e2e", "--json")
    assert rc == 0
    assert doc["data"]["state"] == "stopped"

    rc, doc = _invoke(capsys, "--backend", "msb", "rm", "e2e", "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True
    assert state.record_read("msb", "e2e") is None


def test_create_existing_fails_closed(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path, catalog={"life-test": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "life-test", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "sandbox_exists"


def test_stop_missing_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"alpha": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "stop", "nope", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "sandbox_not_found"


def test_sbx_lifecycle_end_to_end(monkeypatch, tmp_path, capsys):
    # The sbx adapter routes the common lifecycle verbs through the sbx stub with
    # host-authoritative state records keyed by the sbx backend (ADR-0040m).
    # ``shell`` selects no agent kit; the built-in support kits are still passed
    # to sbx at create (see test_sbx_create_opencode_applies_its_kit).
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))

    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "sbx-box", "--json")
    assert rc == 0
    assert doc["data"]["backend"] == "sbx"
    assert doc["data"]["name"] == "sbx-box"

    record = state.record_read("sbx", "sbx-box")
    assert record is not None
    assert record["schema"] == state.STATE_SCHEMA
    assert record["agent"] == "shell"

    rc, doc = _invoke(capsys, "--backend", "sbx", "ls", "--json")
    assert rc == 0
    names = {entry["name"]: entry for entry in doc["data"]["sandboxes"]}
    assert names["sbx-box"]["state"] == "running"
    assert names["sbx-box"]["backend"] == "sbx"

    rc, doc = _invoke(capsys, "--backend", "sbx", "stop", "sbx-box", "--json")
    assert rc == 0
    assert doc["data"]["state"] == "stopped"

    rc, doc = _invoke(capsys, "--backend", "sbx", "rm", "sbx-box", "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True
    assert state.record_read("sbx", "sbx-box") is None


def test_sbx_create_opencode_applies_its_kit(monkeypatch, tmp_path, capsys):
    # The documented bootstrap works on sbx: opencode's bundled agent kit is
    # translated and passed to `sbx create --kit` with the built-in kits, and the
    # recorded entrypoint is what a later re-attach launches.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))

    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "opencode", str(ws), "--name", "sbx-box", "--json")
    assert rc == 0
    assert doc["data"]["kit"] == "opencode"
    assert doc["data"]["kits"][-1] == "opencode"
    assert state.record_read("sbx", "sbx-box")["agent"] == "opencode"


def test_slugify_and_derive_name():
    assert cli._slugify("OpenCode!") == "opencode"
    assert cli._slugify("  a/b  ") == "a-b"
    assert cli._derive_name("opencode", "/workspace/my-app") == "opencode-my-app"


def _write_record(backend, name, doc):
    path = state.record_path(backend, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


def test_record_read_refuses_newer_schema(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _write_record("msb", "future", {"schema": 99, "name": "future", "backend": "msb"})

    with pytest.raises(state.StateSchemaError):
        state.record_read("msb", "future")
    # Read-only diagnostics skip a newer-schema record rather than misread it.
    assert state.list_records("msb") == []


def test_record_read_legacy_v0_is_absent(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _write_record("msb", "legacy", {"name": "legacy", "backend": "msb"})  # no schema marker

    assert state.record_read("msb", "legacy") is None
    assert state.list_records("msb") == []


def test_run_reattach_missing_record_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"orphan": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "orphan", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_run_reattach_newer_schema_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"future": "running"})
    _write_record(
        "msb",
        "future",
        {"schema": 99, "name": "future", "backend": "msb", "agent": "opencode", "workspace": "/w"},
    )

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "future", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


def test_create_unknown_agent_fails_closed(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "notanagent", str(ws), "--json")
    assert rc == 2
    assert doc["error"]["code"] == "usage"
    assert "unknown agent" in doc["error"]["message"]


def test_default_image_resolution():
    # ADR-0030: the default base image is the pinned devenv shell image for EVERY
    # agent (harness installation is deferred to kits). The per-agent
    # sandbox-templates mapping is collapsed to a single default.
    for agent in ("shell", "opencode", "claude", "cursor", "codex", "droid", "gemini"):
        assert cli._default_image_for_agent(agent) == cli.OPENCODE_DEVENV_IMAGE


def test_image_override_precedence(monkeypatch):
    for name in ("ACQ_IMAGE", "ACQ_MSB_IMAGE"):
        monkeypatch.delenv(name, raising=False)

    assert cli._resolve_image(None, "opencode") == cli.OPENCODE_DEVENV_IMAGE

    monkeypatch.setenv("ACQ_MSB_IMAGE", "msb-image")
    assert cli._resolve_image(None, "opencode") == "msb-image"

    monkeypatch.setenv("ACQ_IMAGE", "acq-image")
    assert cli._resolve_image(None, "opencode") == "msb-image"
    assert cli._resolve_image(None, "opencode", "sbx") == "acq-image"

    assert cli._resolve_image("flag-image", "opencode") == "msb-image"
    monkeypatch.delenv("ACQ_MSB_IMAGE")
    assert cli._resolve_image("flag-image", "opencode") == "flag-image"


def _symlinked_workspace(tmp_path):
    real = tmp_path / "real-target"
    real.mkdir()
    link = tmp_path / "proj"
    try:
        link.symlink_to(real, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unavailable on this host")
    return link, real


def test_msb_create_mounts_and_records_the_real_workspace_path(monkeypatch, tmp_path, capsys):
    link, real = _symlinked_workspace(tmp_path)
    _env(monkeypatch, tmp_path, fresh=True)

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(link), "--name", "linked", "--json")
    assert rc == 0
    assert doc["data"]["workspace"] == str(real.resolve())
    assert state.record_read("msb", "linked")["workspace"] == str(real.resolve())


def test_msb_sandbox_name_derives_from_the_path_as_typed(monkeypatch, tmp_path, capsys):
    link, real = _symlinked_workspace(tmp_path)
    _env(monkeypatch, tmp_path, fresh=True)

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(link), "--json")
    assert rc == 0
    assert doc["data"]["name"] == cli._derive_name("opencode", str(link))
    assert "real-target" not in doc["data"]["name"]


def test_sbx_workspace_is_not_canonicalized(monkeypatch, tmp_path):
    link, _real = _symlinked_workspace(tmp_path)

    assert cli._mount_workspace("sbx", str(link)) == str(link)
    assert cli._mount_workspace("msb", str(link)) == str(link.resolve())


def test_msb_windows_path_families_resolve_to_guest_forms(monkeypatch):
    """mapped / subst / 8.3-case Windows workspaces each resolve and mount correctly.

    On Windows ``os.path.realpath`` rewrites each of the three families to a
    distinct native form, and ``_guest_path`` must translate every one of them:
    a mapped drive resolves to its UNC share (``/unc``), a ``subst`` drive to its
    plain-drive target (existing drive branch -> ``/c``), and an 8.3/case path to
    its expanded, normalised form (also the drive branch). ``realpath`` is mocked
    to simulate Windows on a POSIX host, and the ``msb.WINDOWS`` seam makes the
    translation run regardless of host OS.
    """
    from acq_py import msb
    from acq_py.commands import common

    realpath_map = {
        "Z:\\proj": "\\\\server\\share\\proj",  # mapped drive -> UNC share
        "X:\\proj": "C:\\actual\\proj",  # subst drive -> plain drive target
        "C:\\PROGRA~1\\acq": "C:\\Program Files\\acq",  # 8.3 + case -> expanded
    }
    monkeypatch.setattr(common, "REALPATH", lambda p: realpath_map.get(p, p))
    monkeypatch.setattr(msb, "WINDOWS", True)

    # Mapped drive: realpath yields the UNC form, which mounts under /unc.
    assert cli._mount_workspace("msb", "Z:\\proj") == "\\\\server\\share\\proj"
    assert msb._guest_path("\\\\server\\share\\proj") == "/unc/server/share/proj"

    # subst drive: realpath yields a plain drive, taking the existing drive branch.
    assert cli._mount_workspace("msb", "X:\\proj") == "C:\\actual\\proj"
    assert msb._guest_path("C:\\actual\\proj") == "/c/actual/proj"

    # 8.3/case: realpath expands and normalises; the guest form is the drive branch.
    assert cli._mount_workspace("msb", "C:\\PROGRA~1\\acq") == "C:\\Program Files\\acq"
    assert msb._guest_path("C:\\Program Files\\acq") == "/c/Program Files/acq"


def test_msb_83_case_name_derives_from_typed_path():
    """The 8.3/case rewrite is benign because the sandbox name uses the typed path.

    ``_derive_name`` runs before ``_mount_workspace`` (see ``commands.lifecycle``),
    so a realpath expansion/normalisation changes only the recorded workspace
    string — never the sandbox name. Forward-slash forms keep ``os.path.basename``
    deterministic on a POSIX host while still distinguishing the two spellings.
    """
    typed = "C:/PROGRA~1"
    expanded = "C:/Program Files"
    assert cli._derive_name("opencode", typed) == "opencode-progra-1"
    assert cli._derive_name("opencode", expanded) == "opencode-program-files"


def test_msb_adapter_receives_the_real_workspace_path(monkeypatch, tmp_path, capsys):
    link, real = _symlinked_workspace(tmp_path)
    _env(monkeypatch, tmp_path, fresh=True)
    seen = {}
    original = cli.msb.create

    def spy(name, image, workspace, **kwargs):
        seen["workspace"] = workspace
        return original(name, image, workspace, **kwargs)

    monkeypatch.setattr(cli.msb, "create", spy)
    rc, _doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(link), "--name", "spy", "--json")
    assert rc == 0
    assert seen["workspace"] == str(real.resolve())


def test_run_reattach_launches_in_the_recorded_workspace(monkeypatch, tmp_path, capsys):
    link, real = _symlinked_workspace(tmp_path)
    _env(monkeypatch, tmp_path, fresh=True)
    assert _invoke(capsys, "--backend", "msb", "create", "opencode", str(real), "--name", "legacy", "--json")[0] == 0
    # An older build recorded the symlink form of the workspace.
    legacy = str(link)
    record = state.record_read("msb", "legacy")
    _write_record("msb", "legacy", {**record, "workspace": legacy})

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(link), "--name", "legacy", "--json")
    assert rc == 0
    assert doc["data"]["exit_code"] == 0
    launched = [job for job in _jobs(tmp_path, "legacy") if job["status"]["command"][3].startswith("acq-launch-")]
    assert len(launched) == 1
    assert launched[0]["workspace"] == legacy
    assert state.record_read("msb", "legacy")["workspace"] == legacy


def test_run_opencode_reattach_without_a_record_fails_closed(monkeypatch, tmp_path, capsys):
    _link, real = _symlinked_workspace(tmp_path)
    _env(monkeypatch, tmp_path, catalog={"orphan": "running"})
    launched = {}
    monkeypatch.setattr(cli.msb, "launch", lambda name, workspace, agent, **kw: launched.update(workspace=workspace) or 0)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(real), "--name", "orphan", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"
    assert "data" not in doc
    assert launched == {}
    assert _jobs(tmp_path, "orphan") == []
    assert state.record_read("msb", "orphan") is None


_SEC_RECORD = {
    "schema": 1,
    "name": "sec",
    "backend": "msb",
    "agent": "opencode",
    "workspace": "/w",
    "ro_host_config": True,
}


def _seed_record(doc):
    path = state.record_path("msb", doc["name"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc))


def _forbid_launch(monkeypatch):
    def launch(*_a, **_k):
        raise AssertionError("launch must not be reached")

    monkeypatch.setattr(cli.msb, "launch", launch)


@pytest.mark.parametrize("mount", ["missing", "unknown"])
def test_run_typed_path_reattach_refuses_missing_trusted_mount(monkeypatch, tmp_path, capsys, mount):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.16")
    _seed_record(_SEC_RECORD)
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": mount}))
    _forbid_launch(monkeypatch)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "sec", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "security_exception"


def test_run_typed_path_reattach_allowed_when_trusted_mount_ok(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.16")
    # Mount trust alone admits legacy shell, NOT the fresh OpenCode profile.
    _seed_record({**_SEC_RECORD, "agent": "shell"})
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "ok"}))
    launched = {}
    monkeypatch.setattr(cli.msb, "launch", lambda name, workspace, agent, **kw: launched.update(workspace=workspace) or 0)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "sec", "--json")
    assert rc == 0
    assert launched["workspace"] == "/w"


def test_run_typed_path_reattach_fails_closed_on_newer_schema(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path, catalog={"future": "running"})
    # Mark the tree migrated so the migration pre-step does not trip on the record
    # first; this test must reach the typed-path reattach's own schema check.
    migration.write_generation(migration.TARGET_GENERATION)
    _seed_record({**_SEC_RECORD, "name": "future", "schema": 99, "ro_host_config": False})
    _forbid_launch(monkeypatch)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "future", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


# ---------------------------------------------------------------------------
# A workspace must not hold acq's own directories: the guest could rewrite
# acq's records and its read-only trusted config through the writable mount.
# ---------------------------------------------------------------------------

def _assert_overlap_refused(rc, doc, relation, what):
    assert rc == 1, doc
    assert doc["error"]["code"] == "validation_failed"
    assert f"{relation} acq's {what}" in doc["error"]["message"]
    assert "not your home directory itself" in doc["error"]["remediation"]


@pytest.mark.parametrize("verb", ["create", "run"])
def test_a_workspace_containing_the_state_dir_is_refused(monkeypatch, tmp_path, capsys, verb):
    _env(monkeypatch, tmp_path)  # ACQ_STATE_DIR is tmp_path/state
    _forbid_launch(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", verb, "opencode", str(tmp_path), "--name", "box", "--json")
    _assert_overlap_refused(rc, doc, "contains", "state directory")
    assert not cli.msb.exists("box")
    assert state.record_read("msb", "box") is None


def test_a_workspace_inside_the_state_dir_is_refused(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    ws = tmp_path / "state" / "msb" / "ws"
    ws.mkdir(parents=True)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    _assert_overlap_refused(rc, doc, "is inside", "state directory")
    assert not cli.msb.exists("box")


@pytest.mark.parametrize("var,what", [("XDG_CONFIG_HOME", "config directory"),
                                      ("ACQ_SECRET_STORE_DIR", "secret store"),
                                      ("XDG_STATE_HOME", "state directory")])
def test_a_workspace_holding_the_config_secret_store_or_provenance_dir_is_refused(
        monkeypatch, tmp_path, capsys, var, what):
    _env(monkeypatch, tmp_path)
    ws = tmp_path / "project"
    (ws / "inner").mkdir(parents=True)
    monkeypatch.setenv(var, str(ws / "inner"))  # XDG_STATE_HOME moves the provenance tree (host-config dirs)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    _assert_overlap_refused(rc, doc, "contains", what)
    assert not cli.msb.exists("box")


@pytest.mark.parametrize("var,what", [
    ("XDG_DATA_HOME", "data directory"),  # where the host-run provider-input validator lives
    ("XDG_CACHE_HOME", "cache directory"),
    ("ACQ_PROVIDER_INPUT_DATA_DIR", "provider-input directory"),
    ("ACQ_SBX_KIT_CACHE", "kit cache"),
    ("ACQ_MSB_KIT_CACHE", "kit cache"),
    ("ACQ_MSB_STARTUP_STAGE_DIR", "kit startup staging directory"),
])
def test_a_workspace_holding_another_acq_directory_is_refused(monkeypatch, tmp_path, capsys, var, what):
    _env(monkeypatch, tmp_path)
    ws = tmp_path / "project"
    (ws / "inner").mkdir(parents=True)
    monkeypatch.setenv(var, str(ws / "inner"))
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    _assert_overlap_refused(rc, doc, "contains", what)
    assert not cli.msb.exists("box")


def test_a_workspace_holding_the_balanced_hosts_file_is_refused(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    ws = tmp_path / "project"
    ws.mkdir()
    hosts = ws / "balanced-hosts.txt"
    hosts.write_text("example.gov\n", encoding="utf-8")
    monkeypatch.setenv("ACQ_MSB_BALANCED_HOSTS_FILE", str(hosts))
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    _assert_overlap_refused(rc, doc, "contains", "balanced-tier hosts file")


def test_an_acq_location_at_the_filesystem_root_does_not_refuse_every_workspace(monkeypatch, tmp_path, capsys):
    # As in Bash: every workspace lies inside '/', so that is not a refusal.
    _env(monkeypatch, tmp_path, fresh=True)
    ws = tmp_path / "ws"
    ws.mkdir()
    monkeypatch.setenv("ACQ_MSB_KIT_CACHE", os.path.abspath(os.sep))
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0, doc


def test_the_overlap_check_compares_by_file_identity_too(monkeypatch, tmp_path):
    # A case-insensitive filesystem (macOS) can spell one directory two ways,
    # which no path comparison sees. Here a link plays that part, with link
    # resolution switched off so only the identity check can catch it.
    from acq_py.commands import common

    _env(monkeypatch, tmp_path)
    alias = tmp_path.parent / f"{tmp_path.name}-alias"  # outside tmp_path, so no path comparison matches
    alias.symlink_to(tmp_path, target_is_directory=True)
    try:
        monkeypatch.setattr(common, "REALPATH", lambda p: p)
        monkeypatch.setenv("ACQ_STATE_DIR", str(alias / "state"))
        (tmp_path / "state").mkdir(exist_ok=True)
        assert common._within(str(alias / "state"), str(tmp_path))
        assert not common._within(str(tmp_path.parent / "elsewhere"), str(tmp_path))
        assert common._workspace_overlap_failure("create", str(tmp_path), True) == 1
    finally:
        alias.unlink()


def test_the_identity_check_ignores_a_zero_inode(monkeypatch, tmp_path):
    # Some Windows network shares report inode 0 for every directory, so two
    # unrelated directories on one share would "match" by identity.
    from acq_py.commands import common

    real_stat = os.stat

    def zero_inode(path, *a, **k):
        st = real_stat(path, *a, **k)
        return os.stat_result((st.st_mode, 0, 7, *tuple(st)[3:]))

    a = tmp_path / "share" / "a"
    b = tmp_path / "share" / "b"
    a.mkdir(parents=True)
    b.mkdir()
    monkeypatch.setattr(common.os, "stat", zero_inode)
    assert not common._within(str(a), str(b))
    assert common._within(str(a / "inner"), str(a))  # the path comparison still works


@pytest.mark.skipif(os.name != "nt", reason="needs a case-insensitive Windows filesystem")
@pytest.mark.parametrize("verb", ["create", "run"])
def test_a_case_variant_workspace_spelling_is_refused_on_windows(monkeypatch, tmp_path, capsys, verb):
    # NTFS is case-insensitive: an upper-case spelling of the directory holding
    # acq's state is that same directory, and must be refused like it.
    _env(monkeypatch, tmp_path)
    _forbid_launch(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", verb, "opencode", str(tmp_path).upper(), "--name", "box", "--json")
    _assert_overlap_refused(rc, doc, "contains", "state directory")


def test_the_overlap_path_comparison_folds_case_where_normcase_does(monkeypatch, tmp_path):
    # The path comparison goes through os.path.normcase, which folds case on
    # Windows. Model that fold here; the upper-case spelling does not exist on
    # a case-sensitive host, so only the path comparison can match it.
    from acq_py.commands import common

    monkeypatch.setattr(common.os.path, "normcase", str.lower)
    upper = str(tmp_path).upper()
    assert common._within(str(tmp_path / "state"), upper)
    assert common._within(upper + os.sep + "STATE", str(tmp_path))
    assert not common._within(str(tmp_path.parent / "elsewhere"), upper)


def test_a_workspace_reached_through_a_link_is_compared_canonically(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    link = tmp_path.parent / f"{tmp_path.name}-link"
    link.symlink_to(tmp_path, target_is_directory=True)
    try:
        rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(link), "--name", "box", "--json")
    finally:
        link.unlink()
    _assert_overlap_refused(rc, doc, "contains", "state directory")


def test_run_by_name_refuses_a_recorded_workspace_holding_acq_state(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"old": "running"})
    _seed_record({"schema": 1, "name": "old", "backend": "msb", "agent": "shell", "workspace": str(tmp_path)})
    _forbid_launch(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "old", "--json")
    _assert_overlap_refused(rc, doc, "contains", "state directory")


def test_run_typed_path_reattach_refuses_a_recorded_workspace_holding_acq_state(monkeypatch, tmp_path, capsys):
    # The typed path is safe; the recorded one (which is what gets mounted) is not.
    ws = tmp_path / "ws"
    ws.mkdir()
    _env(monkeypatch, tmp_path, catalog={"old": "running"})
    _seed_record({"schema": 1, "name": "old", "backend": "msb", "agent": "shell", "workspace": str(tmp_path)})
    _forbid_launch(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "old", "--json")
    _assert_overlap_refused(rc, doc, "contains", "state directory")


def test_recreate_refuses_a_recorded_workspace_holding_acq_state(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    _seed_record({**_SEC_RECORD, "workspace": str(tmp_path)})
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))
    removed = []
    monkeypatch.setattr(cli.msb, "remove", lambda name: removed.append(name))
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    _assert_overlap_refused(rc, doc, "contains", "state directory")
    assert removed == []
    assert state.record_read("msb", "sec")["ro_host_config"] is True


def test_fresh_stub_is_explicit_and_has_no_implicit_live_success(monkeypatch, tmp_path, capsys):
    from acq_py import _stub_msb

    _env(monkeypatch, tmp_path)
    assert _stub_msb.main(["msb", "--version"]) == 0
    assert capsys.readouterr().out == "msb 0.7.7\n"
    assert _stub_msb.main(["msb", "jobs", "--help"]) == 1
    capsys.readouterr()
    monkeypatch.setenv("ACQ_MSB_STUB_FRESH", "1")
    assert _stub_msb.main(["msb", "--version"]) == 0
    assert capsys.readouterr().out == "msb 0.7.16\n"
    assert _stub_msb.main(["msb", "create", "--name", "box", "synthetic-image"]) == 0
    assert _stub_msb.main(["msb", "exec", "--detach", "--no-stdin", "--timeout", "1s",
                           "--user", "agent", "box", "--", "/bin/sh", "-c", "synthetic", "acq-preparation"]) == 1
    assert _jobs(tmp_path, "box") == []


@pytest.mark.parametrize("limit", [1, 100, 0, 101, 256])
def test_fresh_stub_enforces_native_job_page_limit(monkeypatch, tmp_path, capsys, limit):
    from acq_py import _stub_msb

    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_FRESH", "1")
    rc = _stub_msb.main(["msb", "jobs", "--all", "--limit", str(limit), "--format", "json", "box"])
    captured = capsys.readouterr()
    if 1 <= limit <= 100:
        assert rc == 0
        assert json.loads(captured.out) == {"items": [], "next_cursor": None}
        assert captured.err == ""
    else:
        assert rc == 1
        assert captured.out == ""
        assert captured.err.strip() == "job page size must be between 1 and 100"


def test_fresh_stub_does_not_claim_truncated_inventory_is_complete(monkeypatch, tmp_path, capsys):
    from acq_py import _stub_msb

    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_FRESH", "1")
    _stub_msb._fixture_write("fresh-jobs", {"box": {
        str(index): {"status": {"id": "job_" + f"{index:032x}"}} for index in range(101)}})
    assert _stub_msb.main(["msb", "jobs", "--all", "--limit", "100", "--format", "json", "box"]) == 0
    page = json.loads(capsys.readouterr().out)
    assert len(page["items"]) == 100
    assert page["next_cursor"] is not None


@pytest.mark.parametrize("verb", ["create", "run"])
def test_public_fresh_lifecycle_uses_managed_preparation(monkeypatch, tmp_path, capsys, verb):
    from acq_py import fresh_inputs, security

    _env(monkeypatch, tmp_path, fresh=True)
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", verb, "opencode", str(ws), "--name", "fresh", "--json")
    assert rc == 0, doc
    assert "error" not in doc and doc["command"] == verb
    jobs = _jobs(tmp_path, "fresh")
    preparation = [job for job in jobs if job["status"]["command"][3] == "acq-preparation"]
    foreground = [job for job in jobs if job["status"]["command"][3].startswith("acq-launch-")]
    assert len(preparation) == (2 if verb == "run" else 1)
    assert len(foreground) == (1 if verb == "run" else 0)
    assert len({job["status"]["id"] for job in jobs}) == len(jobs)
    for job in preparation:
        assert job["status"]["stdin_closed"] is True
        assert job["status"]["tty"] is False
        assert job["status"]["command"][-2:] == ["--mode", "live-required"]
    mounts = json.loads((tmp_path / "msb-home/.microsandbox/mounts.json").read_text())["fresh"]
    mounted = next(m for m in mounts if Path(m["host"]).name.startswith("generation."))
    assert mounted["options"]["readonly"] is True
    inputs = fresh_inputs.read_existing("fresh", Path(mounted["host"]))
    assert inputs.guest_root == mounted["guest"]
    assert not list(security.host_config_dir("fresh").glob("preparation-ca-*"))
    # Both guest terminal status and reported result were consumed, not cached
    # as authority for the next public run.
    previous = {job["status"]["id"] for job in jobs}
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "fresh", "--json")
    assert rc == 0, doc
    new = [job for job in _jobs(tmp_path, "fresh") if job["status"]["id"] not in previous]
    assert len(new) == 2
    assert new[0]["status"]["command"][3] == "acq-preparation"
    assert new[1]["status"]["command"][3].startswith("acq-launch-")


@pytest.mark.parametrize("verb", ["create", "run"])
@pytest.mark.parametrize("output,code", [
    ('{"sourceOutcome":"snapshot","metadataOutcome":"not-requested"}', "0"),
    ('{"sourceOutcome":"live","metadataOutcome":"not-requested"}', "1"),
    ('{"schemaVersion":"acq-runtime-model-outcome/v1","outcome":"failure",'
     '"stage":"membership","reason":"connection","failureClass":"transient"}', "1"),
    ("not-json", "0"),
])
def test_public_fresh_lifecycle_refuses_guest_failure(monkeypatch, tmp_path, capsys, verb, output, code):
    from acq_py import msb_preparation

    _env(monkeypatch, tmp_path, fresh=True)
    monkeypatch.setenv("ACQ_MSB_STUB_PREPARATION_STDOUT", output)
    monkeypatch.setenv("ACQ_MSB_STUB_PREPARATION_EXIT", code)
    ws = tmp_path / "workspace"
    ws.mkdir()
    attempted = []
    original = msb_preparation.run_preparation

    def observe(*args, **kwargs):
        attempted.append(args[0])
        return original(*args, **kwargs)

    monkeypatch.setattr(msb_preparation, "run_preparation", observe)
    rc, doc = _invoke(capsys, "--backend", "msb", verb, "opencode", str(ws), "--name", "failed", "--json")
    assert rc == 1, doc
    assert doc["error"]["code"] == "validation_failed"
    assert "data" not in doc
    assert attempted == ["failed"]
    assert not any(job["status"]["command"][3].startswith("acq-launch-") for job in _jobs(tmp_path, "failed"))


@pytest.mark.parametrize("change", ["result", "generation", "binding", "readonly", "ca-content", "ca-mode"])
def test_public_fresh_reattach_rechecks_inputs_and_result(monkeypatch, tmp_path, capsys, change):
    _env(monkeypatch, tmp_path, fresh=True)
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "fresh", "--json")
    assert rc == 0, doc
    native = tmp_path / "msb-home/.microsandbox"
    jobs_before = _jobs(tmp_path, "fresh")
    if change == "result":
        monkeypatch.setenv("ACQ_MSB_STUB_PREPARATION_STDOUT", '{"sourceOutcome":"snapshot","metadataOutcome":"not-requested"}')
    elif change == "generation":
        mounts = json.loads((native / "mounts.json").read_text())["fresh"]
        generation = Path(next(m["host"] for m in mounts if Path(m["host"]).name.startswith("generation.")))
        artifact = generation / "runtime-model-preparation.mjs"
        artifact.chmod(0o600)
        artifact.write_text("synthetic corruption")
    elif change == "binding":
        bindings = json.loads((native / "secrets.json").read_text())
        bindings["fresh"]["USAI_API_KEY"]["host"] = "wrong.invalid"
        (native / "secrets.json").write_text(json.dumps(bindings))
    elif change == "readonly":
        monkeypatch.setenv("ACQ_MSB_STUB_MOUNT_RW", "fresh")
    else:
        ca = tmp_path / "msb-home/tls/ca.crt"
        ca.chmod(0o666 if change == "ca-mode" else 0o600)
        if change == "ca-content":
            ca.write_text("not a public certificate")
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "fresh", "--json")
    assert rc == 1, doc
    assert "error" in doc and "data" not in doc
    jobs = _jobs(tmp_path, "fresh")
    assert len(jobs) == len(jobs_before) + (1 if change == "result" else 0)
    assert not any(job["status"]["command"][3].startswith("acq-launch-") for job in jobs)


def test_trusted_mount_alone_does_not_admit_legacy_opencode(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.16")
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "ok"}))
    _seed_record(_SEC_RECORD)
    _forbid_launch(monkeypatch)
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "sec", "--json")
    assert rc == 1
    assert "error" in doc and "data" not in doc
    assert _jobs(tmp_path, "sec") == []


@pytest.mark.parametrize("change", ["generation-writable", "binding-missing"])
def test_fresh_reattach_refuses_input_defects_with_trusted_host_config(monkeypatch, tmp_path, capsys, change):
    from acq_py import msb_preparation, security

    _env(monkeypatch, tmp_path, fresh=True)
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "fresh", "--json")
    assert rc == 0, doc
    native = tmp_path / "msb-home/.microsandbox"
    jobs_before = _jobs(tmp_path, "fresh")
    assert jobs_before
    mounts = json.loads((native / "mounts.json").read_text())
    host_config = next(m for m in mounts["fresh"] if m["guest"] == security.HOST_CONFIG_GUEST_DIR)
    assert host_config["options"]["readonly"] is True
    if change == "generation-writable":
        generation = next(m for m in mounts["fresh"] if Path(m["host"]).name.startswith("generation."))
        assert generation["options"]["readonly"] is True
        generation["options"]["readonly"] = False
        (native / "mounts.json").write_text(json.dumps(mounts))
    else:
        bindings = json.loads((native / "secrets.json").read_text())
        del bindings["fresh"]["USAI_API_KEY"]
        (native / "secrets.json").write_text(json.dumps(bindings))
    # The established host-config gate must still pass: otherwise it hides the
    # fresh generation/binding check this negative is intended to exercise.
    assert security.mount_check("msb", "fresh")[0] == "ok"

    def forbidden(*args, **kwargs):
        pytest.fail("invalid fresh inputs reached another preparation attempt")

    monkeypatch.setattr(msb_preparation, "run_preparation", forbidden)
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "fresh", "--json")
    assert rc == 1, doc
    assert "error" in doc and "data" not in doc
    assert _jobs(tmp_path, "fresh") == jobs_before
    assert not any(job["status"]["command"][3].startswith("acq-launch-") for job in jobs_before)


def test_public_fresh_create_refuses_preinstalled_validator_failure(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, fresh=True)
    validator = Path(os.environ["ACQ_PROVIDER_INPUT_PYTHON"])
    validator.write_text(f"#!{sys.executable}\nraise SystemExit(2)\n", encoding="utf-8")
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "failed", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert "data" not in doc
    assert not cli.msb.exists("failed")
    assert state.record_read("msb", "failed") is None
    assert _jobs(tmp_path, "failed") == []


def test_public_fresh_create_refuses_bundle_validation_after_successful_probe(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, fresh=True)
    validator = Path(os.environ["ACQ_PROVIDER_INPUT_PYTHON"])
    calls = tmp_path / "validator-calls.jsonl"
    validator.write_text(f"#!{sys.executable}\n" + f'''import json
import sys
from pathlib import Path
args = sys.argv[1:]
with Path({str(calls)!r}).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(args) + "\\n")
assert args[0] == "-I"
if args[1] == "-c":
    raise SystemExit(0)
assert "--bundle" in args
raise SystemExit(2)
''', encoding="utf-8")
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "failed", "--json")
    assert rc == 1, doc
    assert doc["error"]["code"] == "validation_failed"
    assert "data" not in doc
    recorded = [json.loads(line) for line in calls.read_text(encoding="utf-8").splitlines()]
    assert len(recorded) == 2
    assert recorded[0][:2] == ["-I", "-c"]
    assert recorded[1][0] == "-I" and recorded[1][1] != "-c"
    assert recorded[1].count("--bundle") == 1
    assert "--schema-dir" in recorded[1] and "--credential-bindings" in recorded[1]
    assert not cli.msb.exists("failed")
    assert state.record_read("msb", "failed") is None
    assert _jobs(tmp_path, "failed") == []


@pytest.mark.parametrize("verb", ["start", "restart"])
@pytest.mark.parametrize("success", [True, False])
def test_fresh_start_and_restart_require_new_preparation(monkeypatch, tmp_path, capsys, verb, success):
    _env(monkeypatch, tmp_path, fresh=True)
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "fresh", "--json")
    assert rc == 0, doc
    assert _invoke(capsys, "--backend", "msb", "stop", "fresh", "--json")[0] == 0
    before = _jobs(tmp_path, "fresh")
    if not success:
        monkeypatch.setenv("ACQ_MSB_STUB_PREPARATION_STDOUT", '{"sourceOutcome":"snapshot","metadataOutcome":"not-requested"}')
    rc, doc = _invoke(capsys, "--backend", "msb", verb, "fresh", "--json")
    assert rc == (0 if success else 1), doc
    assert ("data" in doc) is success
    assert ("error" in doc) is not success
    after = _jobs(tmp_path, "fresh")
    assert len(after) == len(before) + 1
    assert after[-1]["status"]["command"][3] == "acq-preparation"
    assert after[-1]["status"]["id"] not in {job["status"]["id"] for job in before}
    assert not any(job["status"]["command"][3].startswith("acq-launch-") for job in after)


def test_fresh_old_managed_job_version_is_not_silently_upgraded(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, fresh=True)
    # Enough for legacy read-only mounts, but not the qualified managed API.
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.11")
    monkeypatch.setenv("ACQ_MSB_STUB_VERSION", "0.7.11")
    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "old", "--json")
    assert rc == 1, doc
    assert "error" in doc and "data" not in doc
    assert _jobs(tmp_path, "old") == []
