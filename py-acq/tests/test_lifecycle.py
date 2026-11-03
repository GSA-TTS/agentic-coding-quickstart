"""Tier-2 implementation tests for the MSB lifecycle slice (ADR-0040m, lifecycle side).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb, then inspect
the host-authoritative state record. Contract evidence lives only in the vector
corpus (``test/vectors``); the stub is an internal test seam, never a secret.
"""

from __future__ import annotations

import json

from acq_py import cli, state


def _env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_IMAGE", "ACQ_MSB_IMAGE"):
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


def test_sbx_lifecycle_unsupported(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")

    rc, doc = _invoke(capsys, "--backend", "sbx", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"


def test_slugify_and_derive_name():
    assert cli._slugify("OpenCode!") == "opencode"
    assert cli._slugify("  a/b  ") == "a-b"
    assert cli._derive_name("opencode", "/workspace/my-app") == "opencode-my-app"
