"""Tier-2 implementation tests for the MSB lifecycle slice (ADR-0040m, lifecycle side).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb, then inspect
the host-authoritative state record. Contract evidence lives only in the vector
corpus (``test/vectors``); the stub is an internal test seam, never a secret.
"""

from __future__ import annotations

import json
import os

import pytest

from acq_py import cli, migration, state

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key


def _env(monkeypatch, tmp_path, *, catalog=None):
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


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1]) if out else None
    return rc, doc


def test_create_writes_schema_first_record(monkeypatch, tmp_path, capsys):
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)

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
    _env(monkeypatch, tmp_path)

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
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(link), "--name", "linked", "--json")
    assert rc == 0
    assert doc["data"]["workspace"] == str(real.resolve())
    assert state.record_read("msb", "linked")["workspace"] == str(real.resolve())


def test_msb_sandbox_name_derives_from_the_path_as_typed(monkeypatch, tmp_path, capsys):
    link, real = _symlinked_workspace(tmp_path)
    _env(monkeypatch, tmp_path)

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
    _env(monkeypatch, tmp_path)
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
    _env(monkeypatch, tmp_path)
    assert _invoke(capsys, "--backend", "msb", "create", "opencode", str(real), "--name", "legacy", "--json")[0] == 0
    # An older build recorded the symlink form of the workspace.
    legacy = str(link)
    state.record_write("msb", "legacy", agent="opencode", workspace=legacy, image=None)
    launched = {}
    monkeypatch.setattr(cli.msb, "launch", lambda name, workspace, agent, **kw: launched.update(workspace=workspace) or 0)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(link), "--name", "legacy", "--json")
    assert rc == 0
    assert doc["data"]["action"] == "reattached"
    assert launched["workspace"] == legacy
    assert doc["data"]["workspace"] == legacy


def test_run_reattach_without_a_record_falls_back_to_the_typed_path(monkeypatch, tmp_path, capsys):
    _link, real = _symlinked_workspace(tmp_path)
    _env(monkeypatch, tmp_path, catalog={"orphan": "running"})
    launched = {}
    monkeypatch.setattr(cli.msb, "launch", lambda name, workspace, agent, **kw: launched.update(workspace=workspace) or 0)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(real), "--name", "orphan", "--json")
    assert rc == 0
    assert launched["workspace"] == str(real.resolve())


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
    _seed_record(_SEC_RECORD)
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "ok"}))
    launched = {}
    monkeypatch.setattr(cli.msb, "launch", lambda name, workspace, agent, **kw: launched.update(workspace=workspace) or 0)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "sec", "--json")
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
    _env(monkeypatch, tmp_path)
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
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "old", "--json")
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
