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
import os
import re
import sys
from pathlib import Path

import pytest

from acq_py import cli, kit_msb, kits, kitspec, msb, state
from acq_py.commands import common as commands_common

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key

FULL_REF = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 40-char SHA-1 (synthetic)
TEAM_REPO = "github.com/acme/team-kits"
REPO_ROOT = Path(__file__).resolve().parents[2]


def _spy_run(monkeypatch) -> list[list[str]]:
    """Record the argv of every msb command the adapter runs (the stub still runs)."""
    seen: list[list[str]] = []
    real = msb._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    return seen


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
        "ACQ_KIT_SOURCE_SEED",
        "ACQ_EXTRA_KIT_SOURCES",
        "ACQ_EXTRA_KITS",
        "ACQ_PROVIDER_KITS",
        "ACQ_SUBSTRATE_STATE",
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

    rc, doc = _invoke(capsys, "kit-source", "add", TEAM_REPO, "--ref", "941a286", "--json")
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


@pytest.mark.parametrize(
    "repo",
    ["github.com/gsa-tts/agentic-coding-patterns", "github.com/GSA-TTS/Agentic-Coding-Patterns"],
)
@pytest.mark.parametrize("verb", ["add", "rm"])
def test_kit_source_control_plane_refused_in_any_case(monkeypatch, tmp_path, capsys, verb, repo):
    # GitHub ignores owner/repo case, so a case variant names the control plane
    # itself: add and rm both refuse it, and add writes no registry record.
    _env(monkeypatch, tmp_path)
    argv = ["kit-source", verb, repo, "--json"]
    if verb == "add":
        argv[3:3] = ["--ref", FULL_REF]
    rc, doc = _invoke(capsys, *argv)
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert kits.source_record(repo) is None


def test_is_control_plane_casefolds_owner_and_repo():
    assert kits.is_control_plane(kits.CONTROL_PLANE_REPO)
    assert kits.is_control_plane("github.com/gsa-tts/AGENTIC-CODING-PATTERNS")
    assert not kits.is_control_plane("github.com/gsa-tts/agentic-coding-patterns-fork")
    assert not kits.is_control_plane("gitlab.com/GSA-TTS/agentic-coding-patterns")


def test_kit_source_prefixes_cover_control_plane_registry_and_extra(monkeypatch, tmp_path):
    # Mirrors Bash acq_kit_source_prefixes: one owner prefix per trusted source,
    # with EXCLUDE_REPO left out, plus the legacy ACQ_EXTRA_KIT_SOURCES grants.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv(
        "ACQ_KIT_SOURCE_SEED",
        json.dumps(
            [
                {"repository": "github.com/acme/kits-a", "ref": FULL_REF},
                {"repository": "github.com/acme/kits-b", "ref": FULL_REF},
                {"repository": "github.com/solo/kits", "ref": FULL_REF},
            ]
        ),
    )
    monkeypatch.setenv("ACQ_EXTRA_KIT_SOURCES", "  github.com/legacy/ \tgitlab.com/x/ ")
    assert kits.kit_source_prefixes() == [
        "github.com/GSA-TTS/",
        "github.com/acme/",
        "github.com/solo/",
        "github.com/legacy/",
        "gitlab.com/x/",
    ]
    remaining = kits.kit_source_prefixes(exclude="github.com/solo/kits")
    assert "github.com/solo/" not in remaining
    assert "github.com/acme/" in remaining
    # The exclusion names a registry entry by its registered spelling, so a case
    # variant that is not registered leaves the real entry (and its prefix) counted.
    assert "github.com/solo/" in kits.kit_source_prefixes(exclude="github.com/SOLO/Kits")
    # The control plane is never excluded.
    assert "github.com/GSA-TTS/" in kits.kit_source_prefixes(exclude=kits.CONTROL_PLANE_REPO)


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


@pytest.mark.parametrize("ref", [
    "git+https://github.com/acme/kits.git?private_token=s3cr3t-tok#ref=x&dir=k",
    "git+https://github.com/acme/kits.git#ref=x&dir=k&token=s3cr3t-tok",
])
def test_kit_list_refuses_an_extra_ref_refused_at_input(monkeypatch, tmp_path, capsys, ref):
    # Bash's kit list stops in _build_kit_list on such a ref; neither lists it.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", f"./local-kit {ref}")
    rc, doc = _invoke(capsys, "kit", "list", "--json")
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert doc["error"]["message"].startswith("ACQ_EXTRA_KITS: remote kit ref refused")
    assert "s3cr3t-tok" not in json.dumps(doc)


def test_kit_list_refuses_a_provider_ref_refused_at_input(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "git+https://github.com/acme/kits.git#ref=x&dir=k&token=s3cr3t-tok")
    rc, doc = _invoke(capsys, "kit", "list", "--json")
    assert rc == 1 and doc["error"]["message"].startswith("ACQ_PROVIDER_KITS: remote kit ref refused")
    assert "s3cr3t-tok" not in json.dumps(doc)


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


@pytest.mark.parametrize("raw", [
    b"{not json",
    b"[]",
    b"\xff\xfe",
    json.dumps({"schema": 99, "provider_selection": "explicit"}).encode(),
], ids=["bad-json", "not-an-object", "bad-utf8", "unknown-schema"])
def test_an_unreadable_provenance_record_never_reads_as_no_selection(monkeypatch, tmp_path, raw):
    # "Nothing recorded" applies the current selection, which could bind a
    # provider the create left out; a damaged record fails closed instead.
    _env(monkeypatch, tmp_path)
    path = kits._provenance_path("msb", "box")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)
    with pytest.raises(kits.ProviderSelectionError, match="unreadable recorded provider selection"):
        kits.provider_selection_read("msb", "box")
    with pytest.raises(kits.ProviderSelectionError):
        with kits.recorded_provider_selection("msb", "box"):
            pytest.fail("ran under the current selection")
    assert kits.provenance_status("msb", "box") == "unknown"  # the currency report stays lenient


def test_provider_selection_absent_record_and_legacy_record_read_as_nothing(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    assert kits.provider_selection_read("msb", "box") is None
    path = kits._provenance_path("msb", "box")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"applied_ref": "0" * 40}), encoding="utf-8")  # v0: no schema marker
    assert kits.provider_selection_read("msb", "box") is None


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

    # --yes consents and reapplies the bundle in place; provenance follows success.
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "update", "mybox", "--yes", "--json")
    assert rc == 0
    assert doc["data"]["action"] == "refreshed"
    assert doc["data"]["status"] == "current"
    assert doc["data"]["kits"] == ["zscaler-ca-certificate", "usai-provider", "agentic-coding-playbook", "git-ssh-sign"]
    assert kits.provenance_read("msb", "mybox")["applied_ref"] == kits.CONTROL_PLANE_REF


def test_kit_update_failed_reapply_does_not_flip_check_to_current(monkeypatch, tmp_path, capsys):
    """Mutation-proof guard: only a complete reapply makes kit check report current.

    A stale sandbox whose reapply fails stays stale (exit 1, provenance
    untouched); the same update succeeding then flips it to current.
    """
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    _write_provenance(tmp_path, "msb", "mybox", "0" * 40)  # stale
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "exec")

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "update", "mybox", "--yes", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "failure"
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "mybox", "--json")
    assert doc["data"]["status"] == "stale"  # NOT current: the reapply failed

    monkeypatch.delenv("ACQ_MSB_STUB_FAIL")
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "update", "mybox", "--yes", "--json")
    assert rc == 0
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "check", "mybox", "--json")
    assert doc["data"]["status"] == "current"


def test_kit_update_forces_install_commands(monkeypatch, tmp_path, capsys):
    """``kit update`` reruns install-phase commands their run-once marker would skip."""
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    seen = _spy_run(monkeypatch)
    for _ in range(2):
        _write_provenance(tmp_path, "msb", "mybox", "0" * 40)
        rc, _doc = _invoke(capsys, "--backend", "msb", "kit", "update", "mybox", "--yes", "--json")
        assert rc == 0
    installs = [a for a in seen if a[0] == "exec" and any("git config --system gpg.format ssh" in t for t in a)]
    assert len(installs) == 2  # git-ssh-sign's install ran on both refreshes


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


def test_kit_update_on_windows_nul_stdin_refuses_without_prompting(monkeypatch, tmp_path, capsys, windows_nul_stdin):
    """Human mode with ``< NUL`` on Windows: isatty() says True, but there is no
    console, so the consent prompt must refuse rather than wait for input."""
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    windows_nul_stdin("y\n")
    monkeypatch.setattr("builtins.input", lambda prompt="": pytest.fail("prompted without a console"))

    rc = cli.main(["--backend", "msb", "kit", "update", "mybox"])
    err = capsys.readouterr().err
    assert rc == 1
    assert "refusing to refresh 'mybox' non-interactively without --yes" in err
    assert kits.provenance_read("msb", "mybox") is None


class _FakeStdin:
    def __init__(self, *, isatty):
        self._isatty = isatty

    def isatty(self):
        return self._isatty


def test_kit_apply_unknown_kit_ref_fails_closed(monkeypatch, tmp_path, capsys):
    # A name that is neither a built-in agent kit nor an existing local kit
    # directory is refused before anything can be applied.
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "mybox", "some-ref", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_kit_apply_missing_sandbox_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "nope", "opencode", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "sandbox_not_found"


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

    monkeypatch.setattr(kits, "open", _boom, raising=False)
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

    monkeypatch.setattr(kits, "open", _boom, raising=False)
    with pytest.raises(kits.KitSpecError):
        kits.validate_kit(str(kit_dir))


def test_validate_kit_refuses_a_spec_linking_outside_the_kit(tmp_path):
    other = tmp_path / "elsewhere.yaml"
    other.write_text('schemaVersion: "hybrid/v1"\nname: other\n', encoding="utf-8")
    kit_dir = tmp_path / "linked-kit"
    kit_dir.mkdir()
    (kit_dir / "spec.yaml").symlink_to(other)
    with pytest.raises(kits.KitSpecError, match="outside the kit"):
        kits.validate_kit(str(kit_dir))


def test_validate_kit_accepts_a_spec_symlink_inside_the_kit(tmp_path):
    kit_dir = tmp_path / "aliased-kit"
    kit_dir.mkdir()
    (kit_dir / "spec.v1.yaml").write_text('schemaVersion: "hybrid/v1"\nname: aliased\n', encoding="utf-8")
    (kit_dir / "spec.yaml").symlink_to("spec.v1.yaml")
    assert kits.validate_kit(str(kit_dir))["valid"] is True


def _kit_with_sources(tmp_path, *sources):
    kit_dir = tmp_path / "src-kit"
    (kit_dir / "files").mkdir(parents=True)
    (kit_dir / "files" / "ok").write_text("inside", encoding="utf-8")
    (tmp_path / "outside.txt").write_text("outside", encoding="utf-8")
    lines = ['schemaVersion: "hybrid/v1"', "name: src-kit", "files:"]
    for i, src in enumerate(sources):
        lines += [f"  - path: /home/agent/f{i}", f"    source: {src}"]
    (kit_dir / "spec.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return kit_dir


def test_validate_kit_accepts_in_kit_sources_and_links(tmp_path):
    kit_dir = _kit_with_sources(tmp_path, "files/ok", "files/alias")
    (kit_dir / "files" / "alias").symlink_to("ok")
    assert kits.validate_kit(str(kit_dir)) == {"valid": True, "findings": []}


@pytest.mark.parametrize("source", ["/etc/hostname", "../outside.txt", "files/../../outside.txt", "files/out", "files/missing"])
def test_validate_kit_reports_sources_outside_the_kit(tmp_path, source):
    kit_dir = _kit_with_sources(tmp_path, source)
    (kit_dir / "files" / "out").symlink_to("../../outside.txt")
    result = kits.validate_kit(str(kit_dir))
    assert result["valid"] is False
    assert [f["code"] for f in result["findings"]] == ["kit_file_source_unsafe"]


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="needs mkfifo")
def test_validate_kit_refuses_a_non_regular_spec(tmp_path):
    fifo = tmp_path / "spec.yaml"
    os.mkfifo(fifo)
    with pytest.raises(kits.KitSpecError, match="not a regular file"):
        kits.validate_kit(str(fifo))


def test_validate_kit_refuses_an_oversized_spec(tmp_path):
    kit_dir = _write_kit(tmp_path, "big", ['schemaVersion: "hybrid/v1"', "name: big"])
    with open(kit_dir / "spec.yaml", "a", encoding="utf-8") as fh:
        fh.write("#" * (kits._MAX_SPEC_BYTES + 1))
    with pytest.raises(kits.KitSpecError, match="larger than"):
        kits.validate_kit(str(kit_dir))


def test_validate_kit_accepts_a_direct_spec_path(tmp_path):
    kit_dir = _write_kit(tmp_path, "direct", ['schemaVersion: "hybrid/v1"', "name: direct-kit"])
    assert kits.validate_kit(str(kit_dir / "spec.yaml"))["valid"] is True


# ---------------------------------------------------------------------------
# Pure helpers (ref/repo/dir normalization).
# ---------------------------------------------------------------------------

def test_is_full_ref():
    assert kits.is_full_ref("941a286f912b99475429c3c00db49a99af5b241e")
    assert kits.is_full_ref("A" * 40)
    assert kits.is_full_ref("f" * 64)
    assert not kits.is_full_ref("941a286")  # abbreviated
    assert not kits.is_full_ref("main")
    assert not kits.is_full_ref("v1.19.0")
    assert not kits.is_full_ref("941a286f912b99475429c3c00db49a99af5b241ex")  # 41 chars


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


# ---------------------------------------------------------------------------
# Built-in agent kits (ADR-0030): inference, pinned install, kit apply.
# ---------------------------------------------------------------------------

def test_agent_kit_for_builtin_bundle_only(monkeypatch):
    # Mutation-proof guard: implicit agent-kit inference matches the built-in
    # bundle only. A team/personal kit named after an agent (ACQ_EXTRA_KITS) is
    # never consulted, and shell selects no agent kit (ADR-0030 §Agent kit
    # inference).
    monkeypatch.setenv("ACQ_EXTRA_KITS", "opencode claude shell")
    assert kits.agent_kit_for("opencode") == "opencode"
    assert kits.agent_kit_for("shell") is None
    assert kits.agent_kit_for("claude") is None
    assert kits.agent_kit_for("codex") is None
    assert kits.is_agent_kit("opencode") is True
    assert kits.is_agent_kit("claude") is False


def test_agent_kit_is_the_pinned_bundled_kit():
    # Bash parity: the opencode agent kit is the bundled Patterns kit, whose
    # install fetches a pinned binary and verifies its SHA-256 (never an
    # unpinned npm install).
    spec = kitspec.load_bundled_kit("opencode")
    install = spec.commands_for("install")
    assert len(install) == 1 and install[0].user == "0"
    script = install[0].argv[-1]
    assert "OPENCODE_SHA256_LINUX_X64=" in script and "npm install" not in script
    assert kits.agent_kit_entrypoint("opencode") == spec.agent_field("entrypoint") == "opencode"

def test_kit_apply_capability_maps_through_seam():
    # Mutation-proof guard: the kit-apply capability maps through the adapter
    # seam (ADR-0040m) — both adapters declare it in their capability records
    # (not the record_fn-is-None fallback): msb applies kits itself, sbx through
    # `sbx create --kit` and `sbx kit add`.
    rec = msb.capability_record("0.7.7")
    assert rec["backend"] == "msb"
    assert rec["capabilities"]["kit-apply"] == "required"
    assert rec["capabilities"]["secret-list"] == "required"  # served from the acq store
    assert rec["capabilities"]["key-present"] == "unsupported"  # sbx-only
    assert cli._supports("msb", "kit-apply") is True
    assert cli._supports("sbx", "kit-apply") is True


def test_kit_apply_applies_and_records(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "mybox", "opencode", "--json")
    assert rc == 0
    assert doc["data"]["action"] == "applied"
    assert doc["data"]["applied"] is True
    assert doc["data"]["kit"] == "opencode"
    assert doc["data"]["entrypoint"] == "opencode"
    rec = kits.kit_applied_read("msb", "mybox")
    assert rec is not None
    assert rec["kit"] == "opencode"
    assert rec["entrypoint"] == "opencode"


def test_kit_apply_reapply_is_noop(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: re-applying the same kit is a no-op — the in-guest
    # install is NOT re-invoked (no duplicate install). The host record gates it.
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    calls: list[tuple] = []
    monkeypatch.setattr(kit_msb, "apply_single", lambda *a, **k: calls.append(a) or True)

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "mybox", "opencode", "--json")
    assert rc == 0
    assert doc["data"]["action"] == "applied"
    assert len(calls) == 1

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "mybox", "opencode", "--json")
    assert rc == 0
    assert doc["data"]["action"] == "noop"
    assert doc["data"]["applied"] is False
    assert len(calls) == 1  # the install ran exactly once across both applies


def test_kit_apply_backend_failure_fails_closed(monkeypatch, tmp_path, capsys):
    # Raw backend text never reaches the envelope (ADR-0040m): a failing
    # in-guest install (now driven via `msb exec`) maps to a stable code, not the
    # stub's raw stderr.
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "exec")

    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "apply", "mybox", "opencode", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "failure"
    # The applied-kit record is written only on success (ADR-0038m §3 drops false
    # partial success).
    assert kits.kit_applied_read("msb", "mybox") is None


def test_run_opencode_selects_devenv_and_applies_kit(monkeypatch, tmp_path, capsys):
    # acq run opencode . provisions the pinned devenv base and applies the pinned
    # opencode kit (ADR-0030), while reporting image/kit/entrypoint.
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "oc-box", "--json")
    assert rc == 0
    data = doc["data"]
    assert data["image"] == cli.OPENCODE_DEVENV_IMAGE
    assert data["kit"] == "opencode"
    assert data["entrypoint"] == "opencode"
    assert kits.kit_applied_read("msb", "oc-box")["kit"] == "opencode"


def test_run_shell_keeps_no_kit(monkeypatch, tmp_path, capsys):
    # shell selects no agent kit but still lands on the devenv base (ADR-0030:
    # the base image no longer differs per agent).
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "sh-box", "--json")
    assert rc == 0
    data = doc["data"]
    assert data["image"] == cli.OPENCODE_DEVENV_IMAGE
    assert data["kit"] is None
    assert data["entrypoint"] is None
    assert kits.kit_applied_read("msb", "sh-box") is None


def test_run_claude_ignores_team_kits(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: a team/personal kit named after a non-built-in agent
    # (claude) is never inferred as the agent kit (ADR-0030 inference scope).
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    # An extra kit that does provide an agent (the bundled opencode kit) is
    # applied as an extra, never inferred as claude's agent kit.
    monkeypatch.setenv("ACQ_EXTRA_KITS", kitspec.builtin_kit_ref("opencode"))

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "claude", str(ws), "--name", "cl-box", "--json")
    assert rc == 0
    data = doc["data"]
    assert data["kit"] is None  # claude is not a built-in agent kit
    assert data["kits"][-1] == "opencode"  # ...but the extra kit was applied
    assert data["image"] == cli.OPENCODE_DEVENV_IMAGE
    assert kits.kit_applied_read("msb", "cl-box") is None


def test_run_unfetchable_extra_kits_are_refused_not_ignored(monkeypatch, tmp_path, capsys):
    # Extra kits that are neither bundled nor existing local kit directories are
    # refused before create, never silently dropped.
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", "opencode claude shell")
    seen = _spy_run(monkeypatch)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "claude", str(ws), "--name", "cl-box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert "was not found" in doc["error"]["message"]
    assert "'opencode'" in doc["error"]["message"]
    assert not [a for a in seen if a[0] == "create"]
    assert state.record_read("msb", "cl-box") is None


def test_run_kit_explicit_override_wins(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: an explicit --kit overrides inference — shell (which
    # selects no agent kit) with --kit opencode applies the opencode kit.
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "sh-box", "--kit", "opencode", "--json")
    assert rc == 0
    data = doc["data"]
    assert data["image"] == cli.OPENCODE_DEVENV_IMAGE
    assert data["kit"] == "opencode"
    assert data["entrypoint"] == "opencode"
    assert kits.kit_applied_read("msb", "sh-box")["kit"] == "opencode"


def test_run_kit_unverifiable_substrate_fails_closed(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: a kit on an overridden image whose substrate state is
    # UNKNOWN (no seam) fails closed with validation_failed BEFORE create — acq
    # never applies a kit to an unverified image (ADR-0030 bring-your-own image
    # contract).
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(
        capsys,
        "--backend", "msb", "run", "opencode", str(ws), "--name", "oc-box",
        "--image", "docker.io/docker/sandbox-templates:shell-docker", "--json",
    )
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    # Nothing was created by the refused invocation.
    assert state.record_read("msb", "oc-box") is None


def test_run_kit_unaddressable_substrate_fails_closed(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: an unaddressable substrate gap (non-linux) is refused
    # with validation_failed BEFORE create — acq cannot provision it in-guest.
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv(
        "ACQ_SUBSTRATE_STATE",
        json.dumps({"docker.io/docker/sandbox-templates:shell-docker": ["non-linux"]}),
    )

    rc, doc = _invoke(
        capsys,
        "--backend", "msb", "run", "opencode", str(ws), "--name", "oc-box",
        "--image", "docker.io/docker/sandbox-templates:shell-docker", "--json",
    )
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert state.record_read("msb", "oc-box") is None


def test_run_kit_addressable_substrate_is_provisioned(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: addressable substrate gaps (nix + agent-user) are
    # PROVISIONED in-guest rather than rejected, then the agent kit is applied.
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv(
        "ACQ_SUBSTRATE_STATE",
        json.dumps({"docker.io/docker/sandbox-templates:shell-docker": ["nix", "agent-user"]}),
    )
    calls: list[tuple] = []
    monkeypatch.setattr(msb, "provision_substrate", lambda name, steps: calls.append((name, steps)) or None)

    rc, doc = _invoke(
        capsys,
        "--backend", "msb", "run", "opencode", str(ws), "--name", "oc-box",
        "--image", "docker.io/docker/sandbox-templates:shell-docker", "--json",
    )
    assert rc == 0
    assert doc["data"]["kit"] == "opencode"
    # The substrate gaps were provisioned in-guest (bootstrap nix + agent user)
    # before the agent install.
    assert len(calls) == 1
    assert calls[0][0] == "oc-box"
    assert ("agent", ["install-nix", "--single-user"]) in calls[0][1]
    assert ("root", ["useradd", "-m", "agent"]) in calls[0][1]
    assert kits.kit_applied_read("msb", "oc-box")["kit"] == "opencode"


def test_run_kit_substrate_ok_no_provision(monkeypatch, tmp_path, capsys):
    # An overridden image whose substrate is declared "ok" is applied without any
    # provision step (no bootstrap, just the agent install).
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv(
        "ACQ_SUBSTRATE_STATE",
        json.dumps({"docker.io/docker/sandbox-templates:shell-docker": "ok"}),
    )
    calls: list[tuple] = []
    monkeypatch.setattr(msb, "provision_substrate", lambda name, steps: calls.append((name, steps)) or None)

    rc, doc = _invoke(
        capsys,
        "--backend", "msb", "run", "opencode", str(ws), "--name", "oc-box",
        "--image", "docker.io/docker/sandbox-templates:shell-docker", "--json",
    )
    assert rc == 0
    assert doc["data"]["kit"] == "opencode"
    assert calls == []  # no substrate gaps -> no provision step


def test_run_unbundled_kit_ref_is_refused(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: --kit takes kit refs (Bash semantics); one outside the
    # built-in bundle that names no kit directory is refused before create,
    # never silently dropped or replaced by inference.
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "oc-box", "--kit", "team-kit", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert state.record_read("msb", "oc-box") is None


def test_kit_flag_is_repeatable_and_accepts_bundled_refs(monkeypatch, tmp_path, capsys):
    # --kit repeats; a bundled ref is applied after the built-ins (here twice the
    # same kit: applied once), and --kit opencode still selects the agent kit.
    ws = tmp_path / "workspace"
    ws.mkdir()
    _env(monkeypatch, tmp_path)
    ref = kitspec.builtin_kit_ref("git-ssh-sign")

    rc, doc = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "sh-box",
                      "--kit", "opencode", "--kit", ref, "--json")
    assert rc == 0
    assert doc["data"]["kit"] == "opencode"
    assert doc["data"]["kits"] == [
        "zscaler-ca-certificate", "usai-provider", "agentic-coding-playbook", "git-ssh-sign", "opencode",
    ]


def test_launch_uses_recorded_entrypoint(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: attach launches the recorded kit entrypoint, not the
    # raw agent token, so a future kit whose entrypoint differs from its agent name
    # works (ADR-0030 "declares its entrypoint").
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    state.record_write("msb", "box", agent="opencode", workspace="/w")
    kits.kit_applied_write("msb", "box", "opencode", "custom-opencode-bin")

    captured: dict = {}
    real_launch = msb.launch

    def spy(name, workspace, agent, *, json_mode=False, **_session):
        captured["agent"] = agent
        return 0

    monkeypatch.setattr(msb, "launch", spy)
    rc = cli.main(["--backend", "msb", "--json", "attach", "box"])
    capsys.readouterr()
    assert rc == 0
    assert captured["agent"] == "custom-opencode-bin"  # entrypoint, not "opencode"


# ---------------------------------------------------------------------------
# Cross-implementation pin parity (Bash <-> Python).
# ---------------------------------------------------------------------------
# The trust anchors are duplicated across two implementations: the Bash adapter
# stack pins the patterns repo/ref/dir in ``acq.backends/common.sh`` and the
# default devenv base in ``acq.backends/agents.sh``; the Python package carries
# the same values independently (``kits.CONTROL_PLANE_REPO``/``_REF``/``_DIR``
# and ``commands.common.OPENCODE_DEVENV_IMAGE``). Neither side derives one from
# the other, so a bump applied to one side only is silent drift: an agent could
# be launched on one base image while the bundle is fetched at another ref, or a
# wrong dir could resolve to a kit path that does not exist.
#
# Enforced for every assignment form Bash accepts — bare, ``export``,
# ``readonly``, ``declare -x``, ``local`` — wherever the assignment appears:
#   * exactly one assignment per anchored variable, so a function-local or
#     conditional reassignment fails loudly instead of the first match winning;
#   * that single assignment sits at column 0 — an indented-only definition is
#     not a top-level constant and fails;
#   * its value is non-empty and equals the Python constant, with the repo and
#     dir compared in their normalized form (Bash carries ``git+https://…git``,
#     Python carries ``host/owner/repo``).
# These checks raise via ``pytest.fail`` rather than ``assert`` so the guard
# still fails under ``python -O``, which strips bare assertions.
#
# Scope: this proves *value* parity, not *role* parity. Bash uses the devenv
# image only as the opencode fallback; Python uses it as the default base for
# every agent. Those roles agree today and are deliberately not compared here.

def _pin_assignments(text, variable):
    """Every quoted assignment of ``variable`` as ``(line, indent, value, standalone)``.

    Scans each line for ``VAR="..."`` in any position, so a reassignment hidden in
    a function body or a one-line ``if`` is seen, then classifies it: only a line
    whose entire statement is the assignment counts as ``standalone``.
    """
    name = re.escape(variable)
    prefix = r"(?:export|readonly|local|declare(?:[ \t]+-[A-Za-z]+)*)[ \t]+"
    assignment = re.compile(rf"""\b{name}[ \t]*=(?P<q>['"])(?P<value>[^'"]*)(?P=q)""")
    statement_start = re.compile(rf"""[ \t]*(?:{prefix})?""")
    statement_end = re.compile(r"""[ \t]*(?:#[^\r\n]*)?$""")

    found = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        for match in assignment.finditer(line):
            before = line[: match.start()]
            after = line[match.end() :]
            standalone = bool(statement_start.fullmatch(before)) and bool(
                statement_end.fullmatch(after)
            )
            indent = re.match(r"[ \t]*", before).group(0)
            found.append((lineno, indent, match.group("value"), standalone))
    return found


def _bash_pin(relative_path, variable):
    """Read the single top-level ``variable="..."`` out of a Bash source file."""
    path = REPO_ROOT / relative_path
    if not path.is_file():
        pytest.fail(f"{relative_path} is missing; the pin-parity guard cannot run")
    found = _pin_assignments(path.read_text(encoding="utf-8"), variable)
    if len(found) != 1:
        where = ", ".join(str(lineno) for lineno, *_ in found) or "none"
        pytest.fail(
            f"expected exactly one `{variable}=...` assignment in {relative_path}, "
            f"found {len(found)} (lines: {where}); none means the guard cannot read "
            "the pin at all, and any second definition (function-local, conditional, "
            "or an indented reassignment) would make the effective runtime value "
            "differ from the one checked here"
        )
    lineno, indent, value, standalone = found[0]
    if not value:
        pytest.fail(
            f"`{variable}` in {relative_path} (line {lineno}) is assigned an empty "
            "string; an empty anchor cannot be compared, and a consumer that "
            "defaults an empty value would silently use a different one"
        )
    if not standalone or indent:
        pytest.fail(
            f"the only `{variable}=...` assignment in {relative_path} (line {lineno}) "
            f"is not a top-level statement (indent {indent!r}); the guard accepts only "
            "a single column-0 definition that is the whole statement, so a "
            "function-local, conditional, or indented definition fails closed"
        )
    return value


def test_patterns_kit_repo_matches_python_control_plane_repo():
    bash_repo = _bash_pin("acq.backends/common.sh", "PATTERNS_KIT_REPO")
    normalized = kits.normalize_repo(bash_repo)
    if normalized != kits.CONTROL_PLANE_REPO:
        pytest.fail(
            f"acq.backends/common.sh PATTERNS_KIT_REPO={bash_repo!r} normalizes to "
            f"{normalized!r}, but kits.CONTROL_PLANE_REPO is {kits.CONTROL_PLANE_REPO!r}"
        )


def test_patterns_kit_ref_matches_python_control_plane_ref():
    bash_ref = _bash_pin("acq.backends/common.sh", "PATTERNS_KIT_REF")
    if bash_ref != kits.CONTROL_PLANE_REF:
        pytest.fail(
            f"acq.backends/common.sh PATTERNS_KIT_REF={bash_ref!r}, but "
            f"kits.CONTROL_PLANE_REF is {kits.CONTROL_PLANE_REF!r}"
        )


def test_patterns_kit_dir_matches_python_control_plane_dir():
    bash_dir = _bash_pin("acq.backends/common.sh", "PATTERNS_KIT_DIR")
    normalized = kits.normalize_dir(bash_dir)
    if normalized != kits.CONTROL_PLANE_DIR:
        pytest.fail(
            f"acq.backends/common.sh PATTERNS_KIT_DIR={bash_dir!r} normalizes to "
            f"{normalized!r}, but kits.CONTROL_PLANE_DIR is {kits.CONTROL_PLANE_DIR!r}"
        )


def test_default_devenv_image_matches_python_default_image():
    bash_image = _bash_pin("acq.backends/agents.sh", "ACQ_DEFAULT_OPENCODE_DEVENV_IMAGE")
    if bash_image != commands_common.OPENCODE_DEVENV_IMAGE:
        pytest.fail(
            f"acq.backends/agents.sh ACQ_DEFAULT_OPENCODE_DEVENV_IMAGE={bash_image!r}, "
            f"but commands.common.OPENCODE_DEVENV_IMAGE is "
            f"{commands_common.OPENCODE_DEVENV_IMAGE!r}"
        )
