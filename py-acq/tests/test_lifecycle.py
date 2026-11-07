"""Tier-2 implementation tests for the MSB lifecycle slice (ADR-0040m, lifecycle side).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb, then inspect
the host-authoritative state record. Contract evidence lives only in the vector
corpus (``test/vectors``); the stub is an internal test seam, never a secret.
"""

from __future__ import annotations

import json

import pytest

from acq_py import cli, state


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
    # ``shell`` selects no agent kit, so this stays on the sandbox-templates path
    # (ADR-0030): opencode on sbx would require the kit-apply capability, which is
    # msb-only in this slice (fail-closed; see test_sbx_create_opencode_fails_closed).
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


def test_sbx_create_opencode_fails_closed(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: opencode requires the built-in agent kit, which needs
    # the kit-apply capability the sbx adapter declares unsupported (ADR-0040m).
    # The refusal is fail-closed BEFORE create, so no half-provisioned sandbox is
    # stranded without its agent binary.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))

    ws = tmp_path / "workspace"
    ws.mkdir()
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "opencode", str(ws), "--name", "sbx-box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"
    # Nothing was created by the refused invocation.
    assert state.record_read("sbx", "sbx-box") is None


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
    assert cli._resolve_image(None, "opencode") == "acq-image"

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
