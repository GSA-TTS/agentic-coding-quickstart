"""Tier-2 implementation tests for the kit-source registry + kit-inspection layer.

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb, then inspect
the host-side records. Contract evidence lives only in the vector corpus
(``test/vectors``); the stub and the ``ACQ_KIT_SOURCE_DISCOVERY`` seam are internal
test seams, never secrets.

Each guard below is written as a mutation-proof assertion: the exact refusal code
and exit class are pinned, so removing or weakening the guard fails the test.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from acq_py import cli, kits, state

FULL_REF = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 40-char SHA-1 (synthetic)
TEAM_REPO = "github.com/acme/team-kits"


def _env(monkeypatch, tmp_path, *, catalog=None, discovery=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in (
        "ACQ_BACKEND",
        "ACQ_MSB_STUB_CATALOG",
        "ACQ_MSB_STUB_FAIL",
        "ACQ_IMAGE",
        "ACQ_MSB_IMAGE",
        "ACQ_KIT_SOURCE_DISCOVERY",
        "ACQ_EXTRA_KITS",
        "ACQ_PROVIDER_KITS",
    ):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))
    if discovery is not None:
        monkeypatch.setenv("ACQ_KIT_SOURCE_DISCOVERY", json.dumps(discovery))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1]) if out else None
    return rc, doc


def _write_provenance(tmp_path, backend, sandbox, applied_ref):
    path = kits._provenance_path(backend, sandbox)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {"schema": kits.KIT_SCHEMA, "backend": backend, "sandbox": sandbox, "applied_ref": applied_ref}
        ),
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# kit-source: full-ref pinning and the trusted-source registry.
# ---------------------------------------------------------------------------

def test_kit_source_add_requires_full_ref(monkeypatch, tmp_path, capsys):
    """Mutation-proof guard: a non-full ref is refused with kit_ref_not_pinned."""
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "kit-source", "add", TEAM_REPO, "--ref", "main", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "kit_ref_not_pinned"
    # Nothing was persisted by a refused add.
    assert kits.source_record(TEAM_REPO) is None

    rc, doc = _invoke(capsys, "kit-source", "add", TEAM_REPO, "--ref", "7dd2ddc", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "kit_ref_not_pinned"


def test_kit_source_add_full_ref_persists_and_lists(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "kit-source", "add", TEAM_REPO, "--ref", FULL_REF, "--json")
    assert rc == 0
    assert doc["data"]["action"] == "added"
    assert doc["data"]["ref"] == FULL_REF

    record = kits.source_record(TEAM_REPO)
    assert record is not None
    assert record["schema"] == kits.KIT_SCHEMA
    assert list(record.keys())[0] == "schema"  # version marker leads the record
    assert record["ref"] == FULL_REF

    rc, doc = _invoke(capsys, "kit-source", "ls", "--json")
    assert rc == 0
    sources = {s["repository"]: s for s in doc["data"]["sources"]}
    # The control plane is always present; the team source is now reachable via the seam.
    assert kits.CONTROL_PLANE_REPO in sources
    assert TEAM_REPO in sources
    assert sources[TEAM_REPO]["ref"] == FULL_REF
    assert sources[TEAM_REPO]["discovery_status"] == "unreachable"


def test_kit_source_rm_roundtrip_and_errors(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)

    _invoke(capsys, "kit-source", "add", TEAM_REPO, "--ref", FULL_REF, "--json")
    rc, doc = _invoke(capsys, "kit-source", "rm", TEAM_REPO, "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True
    assert kits.source_record(TEAM_REPO) is None

    # rm of a non-registered source fails closed with kit_source_not_found.
    rc, doc = _invoke(capsys, "kit-source", "rm", TEAM_REPO, "--json")
    assert rc == 1
    assert doc["error"]["code"] == "kit_source_not_found"


def test_kit_source_rm_rejects_unknown_backend(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: `--backend bogus` is rejected (usage, exit 2) BEFORE
    # the registry entry is removed, matching every other mutating verb.
    _env(monkeypatch, tmp_path)
    _invoke(capsys, "kit-source", "add", TEAM_REPO, "--ref", FULL_REF, "--json")
    assert kits.source_record(TEAM_REPO) is not None

    rc, doc = _invoke(capsys, "--backend", "bogus", "kit-source", "rm", TEAM_REPO, "--json")
    assert rc == 2
    assert doc["error"]["code"] == "usage"
    # The registry entry was NOT silently removed by the refused invocation.
    assert kits.source_record(TEAM_REPO) is not None


def test_kit_source_rm_control_plane_refused(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    rc, doc = _invoke(capsys, "kit-source", "rm", kits.CONTROL_PLANE_REPO, "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_kit_source_add_control_plane_refused(monkeypatch, tmp_path, capsys):
    # Symmetry with rm: the pinned trust anchor cannot be re-added either.
    _env(monkeypatch, tmp_path)
    rc, doc = _invoke(capsys, "kit-source", "add", kits.CONTROL_PLANE_REPO, "--ref", FULL_REF, "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert kits.source_record(kits.CONTROL_PLANE_REPO) is None


def test_kit_source_discovery_seam_reachable(monkeypatch, tmp_path, capsys):
    """The discovery seam forces a non-control-plane source to reachable, offline."""
    _env(monkeypatch, tmp_path, discovery={TEAM_REPO: ["acme-provider"]})

    _invoke(capsys, "kit-source", "add", TEAM_REPO, "--ref", FULL_REF, "--json")
    rc, doc = _invoke(capsys, "kit-source", "ls", "--json")
    assert rc == 0
    sources = {s["repository"]: s for s in doc["data"]["sources"]}
    assert sources[TEAM_REPO]["discovery_status"] == "reachable"
    assert sources[TEAM_REPO]["provider_kits"] == ["acme-provider"]


# ---------------------------------------------------------------------------
# kit list: control-plane ref + effective built-in/provider/extra sets.
# ---------------------------------------------------------------------------

def test_kit_list_effective_sets(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", "./local-kit git+https://github.com/acme/kits.git#ref=x&dir=k")

    rc, doc = _invoke(capsys, "kit", "list", "--json")
    assert rc == 0
    data = doc["data"]
    assert data["control_plane_ref"] == kits.control_plane_ref()
    assert "usai-provider" not in data["built_in"]  # provider role is separate
    assert data["built_in"] == ["zscaler-ca-certificate", "agentic-coding-playbook", "git-ssh-sign"]
    assert data["provider"] == ["usai-provider"]
    assert data["extra"] == ["./local-kit", "git+https://github.com/acme/kits.git#ref=x&dir=k"]


# ---------------------------------------------------------------------------
# kit check / kit update: provenance currency + consent.
# ---------------------------------------------------------------------------

def test_kit_check_unknown_current_stale(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "mybox", "--json")
    assert rc == 0
    assert doc["data"]["status"] == "unknown"
    assert doc["data"]["applied"] is None
    assert doc["data"]["local"] == kits.CONTROL_PLANE_REF

    _write_provenance(tmp_path, "msb", "mybox", kits.CONTROL_PLANE_REF)
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "mybox", "--json")
    assert rc == 0
    assert doc["data"]["status"] == "current"

    _write_provenance(tmp_path, "msb", "mybox", "0" * 40)
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "mybox", "--json")
    assert rc == 0
    assert doc["data"]["status"] == "stale"


def test_kit_check_missing_sandbox_exit_1(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "nope", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "sandbox_not_found"


def test_kit_update_consent_gate(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})

    # Non-interactive (--json) without --yes refuses; nothing is recorded.
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "update", "mybox", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "consent_required"
    assert kits.provenance_read("msb", "mybox") is None
    assert kits.consent_read("msb", "mybox") is None

    # --yes consents and records CONSENT (not applied provenance).
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "update", "mybox", "--yes", "--json")
    assert rc == 0
    assert doc["data"]["action"] == "consent_recorded"
    assert doc["data"]["status"] == "deferred"
    assert doc["data"]["consented_ref"] == kits.CONTROL_PLANE_REF
    # applied_ref is NOT written: kit update never fabricates currency.
    assert kits.provenance_read("msb", "mybox") is None
    assert kits.consent_read("msb", "mybox")["consented_ref"] == kits.CONTROL_PLANE_REF


def test_kit_update_does_not_flip_check_to_current(monkeypatch, tmp_path, capsys):
    """Mutation-proof guard: kit update must NOT make kit check report current.

    A stale sandbox stays stale after a consented ``kit update`` (the reapply is
    deferred), so removing the consent/applied separation flips ``kit check`` to
    ``current`` and fails this test.
    """
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    _write_provenance(tmp_path, "msb", "mybox", "0" * 40)  # stale

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "mybox", "--json")
    assert rc == 0
    assert doc["data"]["status"] == "stale"

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "update", "mybox", "--yes", "--json")
    assert rc == 0
    assert doc["data"]["status"] == "deferred"

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "mybox", "--json")
    assert rc == 0
    assert doc["data"]["status"] == "stale"  # NOT current — reapply is deferred


def test_kit_update_interactive_decline_records_nothing(monkeypatch, tmp_path, capsys):
    """Interactive confirmation: a decline exits 0 and records nothing (records only success)."""
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    monkeypatch.setattr(sys, "stdin", _FakeStdin(isatty=True))
    monkeypatch.setattr("builtins.input", lambda prompt="": "n")

    rc = cli.main(["--backend", "msb", "kit", "update", "mybox"])
    out, err = capsys.readouterr()
    assert rc == 0
    assert kits.provenance_read("msb", "mybox") is None
    assert kits.consent_read("msb", "mybox") is None


class _FakeStdin:
    def __init__(self, *, isatty):
        self._isatty = isatty

    def isatty(self):
        return self._isatty


def test_kit_apply_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "mybox", "some-ref", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"


# ---------------------------------------------------------------------------
# kit validate: validity + coded findings.
# ---------------------------------------------------------------------------

def _write_kit(tmp_path, name, spec_lines):
    kit_dir = tmp_path / name
    kit_dir.mkdir(exist_ok=True)
    (kit_dir / "spec.yaml").write_text("\n".join(spec_lines) + "\n", encoding="utf-8")
    return kit_dir


def test_kit_validate_valid(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    kit_dir = _write_kit(tmp_path, "good", ['schemaVersion: "hybrid/v1"', "kind: mixin", "name: my-kit"])

    rc, doc = _invoke(capsys, "kit", "validate", str(kit_dir), "--json")
    assert rc == 0
    assert doc["data"]["valid"] is True
    assert doc["data"]["findings"] == []


def test_kit_validate_coded_findings(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    kit_dir = _write_kit(tmp_path, "bad", ['schemaVersion: "sbx/v2"', "name: bad kit!"])

    rc, doc = _invoke(capsys, "kit", "validate", str(kit_dir), "--json")
    assert rc == 0  # a readable kit is a successful query answer; validity is data
    assert doc["data"]["valid"] is False
    codes = {f["code"] for f in doc["data"]["findings"]}
    assert "kit_schema_version" in codes
    assert "kit_name_unsafe" in codes


def test_kit_validate_missing_path(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    rc, doc = _invoke(capsys, "kit", "validate", str(tmp_path / "nope"), "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_kit_validate_missing_spec_dir_exit_1(monkeypatch, tmp_path, capsys):
    # A directory without a spec.yaml is an operational failure (kit_spec_missing),
    # not a successful query answer with a finding.
    _env(monkeypatch, tmp_path)
    empty = tmp_path / "empty"
    empty.mkdir()

    rc, doc = _invoke(capsys, "kit", "validate", str(empty), "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_kit_validate_unreadable_spec_exit_1(monkeypatch, tmp_path, capsys):
    # An unreadable spec.yaml is an operational failure (kit_spec_unreadable).
    _env(monkeypatch, tmp_path)
    kit_dir = _write_kit(tmp_path, "k", ['schemaVersion: "hybrid/v1"', "name: my-kit"])

    def _boom(*args, **kwargs):
        raise OSError("permission denied")

    monkeypatch.setattr(Path, "read_text", _boom)
    rc, doc = _invoke(capsys, "kit", "validate", str(kit_dir), "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_validate_kit_raises_kit_spec_error_for_unreadable(monkeypatch, tmp_path):
    # Direct unit coverage of the KitSpecError branch in validate_kit.
    kit_dir = _write_kit(tmp_path, "k", ['schemaVersion: "hybrid/v1"', "name: my-kit"])

    with pytest.raises(kits.KitSpecError):
        kits.validate_kit(str(tmp_path / "missing"))

    def _boom(*args, **kwargs):
        raise OSError("permission denied")

    monkeypatch.setattr(Path, "read_text", _boom)
    with pytest.raises(kits.KitSpecError):
        kits.validate_kit(str(kit_dir))


# ---------------------------------------------------------------------------
# Pure helpers (ref/repo/dir normalization).
# ---------------------------------------------------------------------------

def test_is_full_ref():
    assert kits.is_full_ref("7dd2ddc034b6597e97f450fa716e7d47c9a38287")
    assert kits.is_full_ref("A" * 40)
    assert kits.is_full_ref("f" * 64)
    assert not kits.is_full_ref("7dd2ddc")  # abbreviated
    assert not kits.is_full_ref("main")
    assert not kits.is_full_ref("v1.18.0")
    assert not kits.is_full_ref("7dd2ddc034b6597e97f450fa716e7d47c9a38287x")  # 41 chars


def test_normalize_repo():
    assert kits.normalize_repo("github.com/GSA-TTS/agentic-coding-patterns") == "github.com/GSA-TTS/agentic-coding-patterns"
    assert kits.normalize_repo("https://github.com/acme/kits.git") == "github.com/acme/kits"
    assert kits.normalize_repo("git+https://github.com/acme/kits.git#ref=x&dir=k") == "github.com/acme/kits"
    assert kits.normalize_repo("https://user:pass@github.com/acme/kits.git") is None  # credentials refused
    assert kits.normalize_repo("github.com/acme") is None  # not three segments


def test_kit_list_provider_env_override(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "acme-provider other-provider")
    rc, doc = _invoke(capsys, "kit", "list", "--json")
    assert rc == 0
    assert doc["data"]["provider"] == ["acme-provider", "other-provider"]
