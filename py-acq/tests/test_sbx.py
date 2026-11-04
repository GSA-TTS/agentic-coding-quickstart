"""Tier-2 implementation tests for the SBX adapter (ADR-0040m sbx obligations).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` sbx. Contract
evidence lives only in the vector corpus (``test/vectors``); the stub is an
internal test seam, never a secret. The paramount assertions here are the sbx-only
obligations the common surface does not cover: ``key_present`` reports presence
without a value, ``kit_source_revoked`` reports the revoked ref, raw-placeholder
removal leaves the acq store unchanged, and ``secret ls`` fails closed with
``unsupported_capability`` (``secret-list`` is msb-only).
"""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors, sbx, state


def _env(monkeypatch, tmp_path, *, catalog=None, secrets=None):
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    for name in (
        "ACQ_BACKEND",
        "ACQ_MSB_BIN",
        "ACQ_SBX_STUB_CATALOG",
        "ACQ_SBX_STUB_SECRETS",
        "ACQ_SBX_STUB_SECRET_LS_RAW",
        "ACQ_SBX_STUB_RAW_PLACEHOLDERS",
        "ACQ_SBX_STUB_ALLOWED_SOURCES",
        "ACQ_SBX_STUB_PORTS",
        "ACQ_SBX_STUB_PORTS_RAW",
        "ACQ_SBX_STUB_FAIL",
        "ACQ_SBX_STUB_ROTATE",
        "ACQ_SBX_STUB_EXEC_EXIT",
        "ACQ_SBX_STUB_COPY_EXIT",
        "ACQ_SBX_STUB_EXIT_CODE",
        "ACQ_IMAGE",
        "ACQ_MSB_IMAGE",
    ):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", json.dumps(catalog))
    if secrets is not None:
        monkeypatch.setenv("ACQ_SBX_STUB_SECRETS", json.dumps(secrets))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out
    doc = json.loads(out) if out.strip() else None
    return rc, doc


# ---------------------------------------------------------------------------
# Capability record (ADR-0040m declaration).
# ---------------------------------------------------------------------------

def test_capability_record_declares_sbx_obligations():
    rec = sbx.capability_record("0.39.0")
    assert rec["backend"] == "sbx"
    assert rec["version"] == "0.39.0"
    caps = rec["capabilities"]
    # sbx-only obligations are required.
    assert caps["key-present"] == "required"
    assert caps["kit-source-revoke"] == "required"
    # msb-only obligations are unsupported on sbx.
    assert caps["secret-list"] == "unsupported"
    assert caps["start"] == "unsupported"
    assert caps["restart"] == "unsupported"
    # Common obligations are required.
    assert caps["secret-write"] == "required"
    assert caps["secret-rm"] == "required"
    assert caps["key-rotate"] == "required"
    assert caps["provision"] == "required"


# ---------------------------------------------------------------------------
# key_present (sbx-only).
# ---------------------------------------------------------------------------

def test_key_present_reports_presence_without_value(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})
    # Presence is a bool; the value is never read or surfaced.
    assert sbx.key_present("global", "usai") is True
    assert sbx.key_present("global", "github") is False


def test_key_present_backend_cannot_answer_fails_closed(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", str(tmp_path / "definitely-missing-sbx"))
    with pytest.raises(sbx.SbxError) as exc:
        sbx.key_present("global", "usai")
    # A down backend is never conflated with "absent": it raises backend_not_found.
    assert exc.value.code == errors.BACKEND_NOT_FOUND


def test_secret_has_on_sbx_is_key_present(monkeypatch, tmp_path, capsys):
    # The `secret has` predicate maps to key_present on sbx: exit 0 present / 1
    # absent, stdout silent (never a value).
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})

    rc = cli.main(["--backend", "sbx", "secret", "has", "-g", "usai"])
    out, err = capsys.readouterr()
    assert rc == 0
    assert out == ""
    assert err == ""

    rc = cli.main(["--backend", "sbx", "secret", "has", "-g", "github"])
    out, err = capsys.readouterr()
    assert rc == 1
    assert out == ""
    assert err == ""


# ---------------------------------------------------------------------------
# kit_source_revoked (sbx-only).
# ---------------------------------------------------------------------------

def test_kit_source_revoked_reports_revoked_ref(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_ALLOWED_SOURCES", json.dumps(["docker.io/", "github.com/acme/"]))
    revoked = sbx.kit_source_revoked("github.com/acme/team-kits")
    # The revoked owner prefix (host/owner/) is the "ref" sbx reports.
    assert "github.com/acme/" in revoked


def test_kit_source_rm_on_sbx_revokes_and_removes(monkeypatch, tmp_path, capsys):
    # kit-source rm on sbx drops the host registry entry AND revokes the source
    # from sbx's kit.allowedSources (ADR-0040m kit_source_revoked).
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_KIT_SOURCE_SEED", json.dumps([{"repository": "github.com/acme/team-kits", "ref": "a" * 40, "directory": "kits"}]))

    rc, doc = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", "github.com/acme/team-kits", "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True


# ---------------------------------------------------------------------------
# Raw-placeholder removal (sbx-only, ADR-0038m §48).
# ---------------------------------------------------------------------------

def test_raw_placeholder_removal_leaves_acq_store_unchanged(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})
    monkeypatch.setenv("ACQ_SBX_STUB_RAW_PLACEHOLDERS", json.dumps(["sbx-cs-abc123"]))

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "sbx-cs-abc123", "--json")
    assert rc == 0
    assert doc["data"]["placeholder"] == "sbx-cs-abc123"
    assert doc["data"]["value_state"] == "unset"

    # The managed secret store is unchanged: the acq-managed `usai` secret is still
    # present (raw removal never rewrites host-held/managed records).
    assert sbx.key_present("global", "usai") is True
    # No host sandbox-state record was written by the raw removal.
    assert state.list_records("sbx") == []

    # The raw placeholder was dropped from the sbx proxy table.
    raw_path = Path(tmp_path) / "sbx-home" / ".docker-sbx" / "raw-placeholders.json"
    assert json.loads(raw_path.read_text(encoding="utf-8")) == []


# ---------------------------------------------------------------------------
# No secret value ever appears in argv or output on the sbx path.
# ---------------------------------------------------------------------------

def test_secret_value_never_in_argv_or_output_sbx(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    captured: dict = {}
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["argv"] = list(argv)
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-VALUE\n"))

    rc = cli.main(["--backend", "sbx", "secret", "set", "-g", "usai", "--json"])
    out, err = capsys.readouterr()

    assert rc == 0
    assert captured["input_text"] == "TOP-SECRET-VALUE"
    assert "TOP-SECRET-VALUE" not in captured["argv"]
    assert "TOP-SECRET-VALUE" not in out
    assert "TOP-SECRET-VALUE" not in err


# ---------------------------------------------------------------------------
# secret ls is msb-only: unsupported_capability on sbx.
# ---------------------------------------------------------------------------

def test_secret_ls_unsupported_on_sbx(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"


# ---------------------------------------------------------------------------
# exec / cp / ports route through the sbx stub too (common capabilities).
# ---------------------------------------------------------------------------

def test_exec_cp_ports_against_sbx_stub(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_SBX_STUB_PORTS", json.dumps({"box": [{"host_port": 8080, "guest_port": 80}]}))

    # exec preserves the child's exit status (ADR-0038m §1).
    monkeypatch.setenv("ACQ_SBX_STUB_EXEC_EXIT", "7")
    rc, doc = _invoke(capsys, "--backend", "sbx", "--json", "exec", "box", "--", "true")
    assert rc == 7
    assert doc["data"]["exit_code"] == 7

    # cp reports the host/guest direction (ADR-0038m §4).
    rc, doc = _invoke(capsys, "--backend", "sbx", "--json", "cp", "./a.txt", "box:/tmp/d.txt")
    assert rc == 0
    assert doc["data"]["direction"] == "in"

    # ports reports declared host/guest mappings, never listener health.
    rc, doc = _invoke(capsys, "--backend", "sbx", "--json", "ports", "box")
    assert rc == 0
    assert doc["data"]["ports"] == [{"host_port": 8080, "guest_port": 80, "origin": "create"}]
