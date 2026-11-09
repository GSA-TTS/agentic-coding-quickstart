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

import subprocess

import pytest

from acq_py import cli, errors, kits, sbx, state


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
        "ACQ_KIT_SOURCE_SEED",
        "ACQ_EXTRA_KIT_SOURCES",
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
    # sbx HAS a `secret` subcommand (set/ls/rm), so secret-list is required.
    assert caps["secret-list"] == "required"
    # sbx has NO `rotate` subcommand (key-rotate is unsupported).
    assert caps["key-rotate"] == "unsupported"
    # msb-only obligations are unsupported on sbx.
    assert caps["start"] == "unsupported"
    assert caps["restart"] == "unsupported"
    # Common obligations are required.
    assert caps["secret-write"] == "required"
    assert caps["secret-rm"] == "required"
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


def test_kit_source_rm_auto_detected_sbx_revokes_and_removes(monkeypatch, tmp_path, capsys):
    # kit-source rm resolves the ACTIVE backend (auto-detect included) and revokes
    # the source from sbx's kit.allowedSources when sbx is the auto-detected
    # backend, closing the prior asymmetry where revocation fired only on an
    # explicit --backend sbx / ACQ_BACKEND=sbx selection. Mutation proof: the
    # owner prefix is dropped from the persisted allowed-sources file, which only
    # happens when sbx.kit_source_revoked fires.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_KIT_SOURCE_SEED", json.dumps([{"repository": "github.com/acme/team-kits", "ref": "a" * 40, "directory": "kits"}]))
    monkeypatch.setenv("ACQ_SBX_STUB_ALLOWED_SOURCES", json.dumps(["docker.io/", "github.com/acme/"]))

    # No --backend flag, no ACQ_BACKEND: auto-detect resolves sbx (sole backend).
    rc, doc = _invoke(capsys, "kit-source", "rm", "github.com/acme/team-kits", "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True

    # Mutation proof: the revoked owner prefix is gone from sbx's allowlist.
    allowed_path = Path(tmp_path) / "sbx-home" / ".docker-sbx" / "allowed-sources.json"
    assert json.loads(allowed_path.read_text(encoding="utf-8")) == ["docker.io/"]


FULL_REF = "a" * 40


def _allowed_path(tmp_path) -> Path:
    return Path(tmp_path) / "sbx-home" / ".docker-sbx" / "allowed-sources.json"


def _seed_allowed(tmp_path, sources) -> None:
    path = _allowed_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(sources), encoding="utf-8")


def _allowed(tmp_path) -> list:
    return json.loads(_allowed_path(tmp_path).read_text(encoding="utf-8"))


def _add_source(capsys, repo):
    rc, _ = _invoke(capsys, "--backend", "sbx", "kit-source", "add", repo, "--ref", FULL_REF, "--json")
    assert rc == 0


def test_kit_source_rm_keeps_owner_prefix_a_sibling_source_needs(monkeypatch, tmp_path, capsys):
    # sbx's allowlist is owner-granular: removing acme/kits-a must not revoke
    # github.com/acme/ while acme/kits-b is still trusted. Once the last acme
    # source goes, the prefix is revoked.
    _env(monkeypatch, tmp_path)
    _seed_allowed(tmp_path, ["docker.io/", "github.com/acme/"])
    _add_source(capsys, "github.com/acme/kits-a")
    _add_source(capsys, "github.com/acme/kits-b")

    rc, doc = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", "github.com/acme/kits-a", "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True
    assert _allowed(tmp_path) == ["docker.io/", "github.com/acme/"]
    assert kits.source_record("github.com/acme/kits-a") is None

    rc, doc = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", "github.com/acme/kits-b", "--json")
    assert rc == 0
    assert _allowed(tmp_path) == ["docker.io/"]


@pytest.mark.parametrize("repo", ["github.com/GSA-TTS/team-kits", "github.com/gsa-tts/team-kits"])
def test_kit_source_rm_keeps_control_plane_owner_prefix(monkeypatch, tmp_path, capsys, repo):
    # The pinned control-plane kits are fetched from github.com/GSA-TTS/, so a
    # team source under that owner (in any letter case) never revokes it.
    _env(monkeypatch, tmp_path)
    _seed_allowed(tmp_path, ["docker.io/", "github.com/GSA-TTS/"])
    _add_source(capsys, repo)

    rc, doc = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", repo, "--json")
    assert rc == 0
    assert doc["data"]["removed"] is True
    assert _allowed(tmp_path) == ["docker.io/", "github.com/GSA-TTS/"]


def test_kit_source_rm_keeps_owner_prefix_granted_by_extra_sources(monkeypatch, tmp_path, capsys):
    # A legacy ACQ_EXTRA_KIT_SOURCES grant still needs the prefix.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KIT_SOURCES", "github.com/other/ github.com/acme/")
    _seed_allowed(tmp_path, ["docker.io/", "github.com/acme/"])
    _add_source(capsys, "github.com/acme/team-kits")

    rc, _ = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", "github.com/acme/team-kits", "--json")
    assert rc == 0
    assert _allowed(tmp_path) == ["docker.io/", "github.com/acme/"]


def test_kit_source_rm_revokes_every_case_variant_of_the_owner(monkeypatch, tmp_path, capsys):
    # GitHub owners are case-insensitive, so a case variant of the prefix grants
    # the same owner and is revoked with it.
    _env(monkeypatch, tmp_path)
    _seed_allowed(tmp_path, ["docker.io/", "github.com/Acme/", "github.com/acme/"])
    _add_source(capsys, "github.com/acme/team-kits")

    rc, _ = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", "github.com/acme/team-kits", "--json")
    assert rc == 0
    assert _allowed(tmp_path) == ["docker.io/"]


def test_kit_source_rm_keeps_prefix_a_case_variant_record_still_needs(monkeypatch, tmp_path, capsys):
    # The registry is keyed by exact spelling, so github.com/Acme/kits and
    # github.com/acme/kits are separate records. Removing one leaves the other
    # registered, and its owner prefix (the same owner on GitHub) stays allowed.
    _env(monkeypatch, tmp_path)
    _seed_allowed(tmp_path, ["docker.io/", "github.com/acme/"])
    _add_source(capsys, "github.com/Acme/kits")
    _add_source(capsys, "github.com/acme/kits")

    rc, _ = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", "github.com/acme/kits", "--json")
    assert rc == 0
    assert _allowed(tmp_path) == ["docker.io/", "github.com/acme/"]
    assert kits.source_record("github.com/Acme/kits") is not None


def _fake_settings(monkeypatch, *, after_set):
    """Replace sbx._run: ``settings get`` reports the prefix until a set, then ``after_set``."""
    calls = []
    state_box = {"current": json.dumps(["docker.io/", "github.com/acme/"])}

    def fake_run(argv, **_kw):
        calls.append(list(argv))
        if argv[:2] == ["settings", "get"]:
            return subprocess.CompletedProcess(argv, 0, stdout=state_box["current"], stderr="")
        if argv[:2] == ["settings", "set"]:
            state_box["current"] = after_set
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
        raise AssertionError(f"unexpected sbx call: {argv}")

    monkeypatch.setattr(sbx, "_run", fake_run)
    return calls


def test_kit_source_revoked_re_reads_and_fails_closed_when_prefix_remains(monkeypatch, tmp_path):
    # sbx accepted the write but still lists the prefix: revocation is not
    # verified, so it fails closed with a recovery command.
    _env(monkeypatch, tmp_path)
    calls = _fake_settings(monkeypatch, after_set=json.dumps(["docker.io/", "github.com/acme/"]))
    with pytest.raises(sbx.SbxError) as excinfo:
        sbx.kit_source_revoked("github.com/acme/team-kits")
    assert excinfo.value.code == errors.FAILURE
    assert "github.com/acme/" in excinfo.value.message
    assert """sbx settings set kit.allowedSources '["docker.io/"]'""" in excinfo.value.remediation
    assert [c[:2] for c in calls] == [["settings", "get"], ["settings", "set"], ["settings", "get"]]


def test_kit_source_revoked_fails_closed_when_re_read_is_unparseable(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _fake_settings(monkeypatch, after_set="not json")
    with pytest.raises(sbx.SbxError) as excinfo:
        sbx.kit_source_revoked("github.com/acme/team-kits")
    assert excinfo.value.code == errors.FAILURE


def test_kit_source_rm_keeps_registry_entry_when_revocation_unverified(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _add_source(capsys, "github.com/acme/team-kits")
    _fake_settings(monkeypatch, after_set=json.dumps(["github.com/acme/"]))

    rc, doc = _invoke(capsys, "--backend", "sbx", "kit-source", "rm", "github.com/acme/team-kits", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "failure"
    assert kits.source_record("github.com/acme/team-kits") is not None


def test_kit_source_revoked_skips_backend_when_prefix_still_needed(monkeypatch, tmp_path):
    # Nothing to revoke means no sbx call at all (mirrors the Bash early return).
    _env(monkeypatch, tmp_path)
    calls = _fake_settings(monkeypatch, after_set="[]")
    assert sbx.kit_source_revoked("github.com/GSA-TTS/team-kits") is None
    assert calls == []


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


def test_provider_credential_set_uses_value_stdin(monkeypatch, tmp_path, capsys):
    # `provider-credential set` on sbx drives `secret set-custom --value-stdin`
    # (v0.51.0): the hosts map to repeated `--host`, key_env maps to `--env`, and
    # the value travels on the child's stdin only — never argv, never output.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    captured: dict = {}
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["argv"] = list(argv)
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-PROVIDER-KEY\n"))

    rc = cli.main(
        [
            "--backend", "sbx", "provider-credential", "set", "acme", "ACME_API_KEY",
            "--host", "api.acme.example", "--host", "models.acme.example", "--json",
        ]
    )
    out, err = capsys.readouterr()

    assert rc == 0
    assert captured["input_text"] == "TOP-SECRET-PROVIDER-KEY"
    assert captured["argv"][:2] == ["secret", "set-custom"]
    # Every host maps to a repeated --host flag; key_env maps to --env; the value
    # is requested on stdin via --value-stdin.
    assert captured["argv"].count("--host") == 2
    assert "api.acme.example" in captured["argv"]
    assert "models.acme.example" in captured["argv"]
    assert "ACME_API_KEY" in captured["argv"]
    assert "--value-stdin" in captured["argv"]
    # The value never reaches argv, stdout, or stderr.
    assert "TOP-SECRET-PROVIDER-KEY" not in captured["argv"]
    assert "TOP-SECRET-PROVIDER-KEY" not in out
    assert "TOP-SECRET-PROVIDER-KEY" not in err


# ---------------------------------------------------------------------------
# secret ls is msb-only: unsupported_capability on sbx.
# ---------------------------------------------------------------------------

def test_secret_ls_supported_on_sbx(monkeypatch, tmp_path, capsys):
    # sbx HAS a `secret ls` (the secret-list capability); it lists scope/service/
    # value_state, never a value.
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 0
    assert doc["data"]["secrets"] == [{"scope": "global", "service": "usai", "value_state": "set"}]


# ---------------------------------------------------------------------------
# kit apply is msb-only: unsupported_capability on sbx (ADR-0040m kit-apply).
# ---------------------------------------------------------------------------

def test_kit_apply_unsupported_on_sbx(monkeypatch, tmp_path, capsys):
    # Mutation-proof guard: sbx declares kit-apply unsupported, so `kit apply`
    # fails closed (exit 1, unsupported_capability) rather than installing.
    _env(monkeypatch, tmp_path, catalog={"mybox": "running"})
    rc, doc = _invoke(capsys, "--backend", "sbx", "kit", "apply", "mybox", "opencode", "--json")
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


def test_cp_unc_host_path_on_sbx(monkeypatch, tmp_path, capsys):
    # ADR-0029: cp's host side is forwarded verbatim on BOTH backends (resolved
    # natively), so a UNC/network host path is accepted on sbx the same way it is
    # on msb — there is no host->guest translation on the cp host side.
    _env(monkeypatch, tmp_path, catalog={"box": "running"})

    rc, doc = _invoke(capsys, "--backend", "sbx", "--json", "cp", "\\\\server\\share\\file.txt", "box:/tmp/dest.txt")
    assert rc == 0
    assert doc["data"]["direction"] == "in"
    assert doc["data"]["host"] == "\\\\server\\share\\file.txt"
    assert doc["data"]["guest"] == "/tmp/dest.txt"

    rc, doc = _invoke(capsys, "--backend", "sbx", "--json", "cp", "box:/tmp/src.txt", "\\\\server\\share\\file.txt")
    assert rc == 0
    assert doc["data"]["direction"] == "out"
    assert doc["data"]["host"] == "\\\\server\\share\\file.txt"
