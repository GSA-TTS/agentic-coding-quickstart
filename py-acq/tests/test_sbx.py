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
import shlex
import sys
from pathlib import Path

import subprocess

import pytest

from acq_py import cli, errors, kits, sbx, state


def _env(monkeypatch, tmp_path, *, catalog=None, secrets=None, custom=None):
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
        "ACQ_SBX_STUB_CUSTOM_SECRETS",
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
    if custom is not None:
        monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps(custom))


def _custom(scope, env, placeholder, *targets):
    """One row of the stub's custom-secrets table (state only, never a value)."""
    return {"scope": scope, "env": env, "placeholder": placeholder, "targets": list(targets)}


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
    # sbx has NO `rotate` subcommand: key-rotate re-sets the key with
    # `secret set-custom --placeholder P --value-stdin`.
    assert caps["key-rotate"] == "required"
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
    _env(monkeypatch, tmp_path, secrets={"global": {"github": "set"}},
         custom=[_custom("global", "USAI_API_KEY", "sbx-cs-u1", "api.gsa.usai.gov")])
    # Presence is a bool; the value is never read or surfaced. A built-in is
    # matched by name, usai by its custom secret's env var.
    assert sbx.key_present("global", "github") is True
    assert sbx.key_present("global", "usai") is True
    assert sbx.key_present("global", "openai") is False


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
    _env(monkeypatch, tmp_path, custom=[_custom("global", "USAI_API_KEY", "sbx-cs-u1", "api.gsa.usai.gov")])

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


def test_kit_source_revoked_fails_closed_when_re_read_keeps_only_a_case_variant(monkeypatch, tmp_path):
    # sbx accepted the write, but the re-read lists github.com/Acme/ in place of
    # the removed github.com/acme/. GitHub owners ignore case, so that entry still
    # grants the removed source's owner: the revocation is not verified.
    _env(monkeypatch, tmp_path)
    calls = _fake_settings(monkeypatch, after_set=json.dumps(["docker.io/", "github.com/Acme/"]))
    with pytest.raises(sbx.SbxError) as excinfo:
        sbx.kit_source_revoked("github.com/acme/team-kits")
    assert excinfo.value.code == errors.FAILURE
    assert "kit.allowedSources still lists it after the update" in excinfo.value.message
    assert """sbx settings set kit.allowedSources '["docker.io/"]'""" in excinfo.value.remediation
    assert [c[:2] for c in calls] == [["settings", "get"], ["settings", "set"], ["settings", "get"]]


def test_kit_source_revoked_fails_closed_when_re_read_is_unparseable(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _fake_settings(monkeypatch, after_set="not json")
    with pytest.raises(sbx.SbxError) as excinfo:
        sbx.kit_source_revoked("github.com/acme/team-kits")
    assert excinfo.value.code == errors.FAILURE
    # The setting could not be read back: the error says so, rather than
    # claiming sbx still lists the prefix.
    assert "could not read kit.allowedSources back after the update" in excinfo.value.message
    assert "still lists" not in excinfo.value.message


def test_kit_source_revoke_recovery_command_round_trips_a_single_quote(monkeypatch, tmp_path):
    # An allowlist entry holding a single quote must survive the printed
    # command: shell-splitting it gives back exactly the JSON acq wanted.
    _env(monkeypatch, tmp_path)
    sources = ["docker.io/", "github.com/acme/", "example.com/it's/"]
    calls = []

    def fake_run(argv, **_kw):
        calls.append(list(argv))
        if argv[:2] == ["settings", "get"]:
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(sources), stderr="")
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="refused")

    monkeypatch.setattr(sbx, "_run", fake_run)
    with pytest.raises(sbx.SbxError) as excinfo:
        sbx.kit_source_revoked("github.com/acme/team-kits")
    command = excinfo.value.remediation.removeprefix("run: ").split("; then re-run:")[0]
    words = shlex.split(command)
    assert words[:4] == ["sbx", "settings", "set", "kit.allowedSources"]
    assert json.loads(words[4]) == ["docker.io/", "example.com/it's/"]
    assert words[4] == calls[-1][3]


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
    _env(monkeypatch, tmp_path, secrets={"global": {"github": "set"}})
    monkeypatch.setenv("ACQ_SBX_STUB_RAW_PLACEHOLDERS", json.dumps(["sbx-cs-abc123"]))

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "sbx-cs-abc123", "--json")
    assert rc == 0
    assert doc["data"]["placeholder"] == "sbx-cs-abc123"
    assert doc["data"]["value_state"] == "unset"

    # The managed secret store is unchanged: the acq-managed `github` secret is
    # still present (raw removal never rewrites host-held/managed records).
    assert sbx.key_present("global", "github") is True
    # No host sandbox-state record was written by the raw removal.
    assert state.list_records("sbx") == []

    # The raw placeholder was dropped from the sbx proxy table.
    raw_path = Path(tmp_path) / "sbx-home" / ".docker-sbx" / "raw-placeholders.json"
    assert json.loads(raw_path.read_text(encoding="utf-8")) == []


# ---------------------------------------------------------------------------
# No secret value ever appears in argv or output on the sbx path.
# ---------------------------------------------------------------------------

def _spy(monkeypatch):
    """Record every sbx call as ``(argv, input_text)``."""
    calls: list = []
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        calls.append((list(argv), input_text))
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    return calls


def _assert_value_only_on_stdin(calls, value, *texts):
    # Every argv ELEMENT is searched for the substring, so `--flag=VALUE` is caught.
    assert all(value not in arg for argv, _ in calls for arg in argv)
    assert all(value not in text for text in texts)
    assert [stdin for _, stdin in calls if stdin is not None] == [value]


def test_secret_value_never_in_argv_or_output_sbx(monkeypatch, tmp_path, capsys):
    # usai is a custom endpoint on sbx: `secret set-custom --host --env
    # --value-stdin`, bound to its pinned host, with the value on stdin only.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    calls = _spy(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-VALUE\n"))

    rc = cli.main(["--backend", "sbx", "secret", "set", "-g", "usai", "--json"])
    out, err = capsys.readouterr()

    assert rc == 0
    fed = [argv for argv, stdin in calls if stdin is not None]
    assert fed == [["secret", "set-custom", "--host", "api.gsa.usai.gov", "--env", "USAI_API_KEY", "--value-stdin"]]
    _assert_value_only_on_stdin(calls, "TOP-SECRET-VALUE", out, err)


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
    # The value never reaches argv (any element, so `--flag=VALUE` too), stdout, or stderr.
    assert all("TOP-SECRET-PROVIDER-KEY" not in arg for arg in captured["argv"])
    assert "TOP-SECRET-PROVIDER-KEY" not in out
    assert "TOP-SECRET-PROVIDER-KEY" not in err


# ---------------------------------------------------------------------------
# secret ls is msb-only: unsupported_capability on sbx.
# ---------------------------------------------------------------------------

def test_secret_ls_supported_on_sbx(monkeypatch, tmp_path, capsys):
    # sbx HAS a `secret ls` (the secret-list capability); it lists scope/service/
    # value_state, never a value.
    _env(monkeypatch, tmp_path, secrets={"global": {"github": "set"}})
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 0
    assert doc["data"]["secrets"] == [
        {"scope": "global", "scope_kind": "global", "service": "github", "value_state": "set"}
    ]


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


# ---------------------------------------------------------------------------
# The sbx credential path: built-ins through `secret set`, every other endpoint
# through `secret set-custom`, and has/rm over both of sbx's tables.
# ---------------------------------------------------------------------------

def _store():
    import os

    return Path(os.environ["ACQ_SECRET_STORE_DIR"])


def _custom_table(tmp_path) -> list:
    path = Path(tmp_path) / "sbx-home" / ".docker-sbx" / "custom-secrets.json"
    return json.loads(path.read_text(encoding="utf-8"))


def test_secret_set_custom_routes(monkeypatch, tmp_path, capsys):
    # An explicit --host takes the custom route even for a built-in name (a
    # self-hosted GitLab must not be bound to gitlab.com), scoped with --sandbox.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    calls = _spy(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("GL-TOKEN-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "mybox", "gitlab",
                      "--host", "workshop.cloud.gov", "--env", "GITLAB_TOKEN", "--json")
    assert rc == 0 and doc["data"]["scope_kind"] == "sandbox"
    assert [argv for argv, stdin in calls if stdin is not None] == [
        ["secret", "set-custom", "--sandbox", "mybox", "--host", "workshop.cloud.gov",
         "--env", "GITLAB_TOKEN", "--value-stdin"]
    ]
    _assert_value_only_on_stdin(calls, "GL-TOKEN-VALUE", json.dumps(doc))
    # A registered provider binds every pinned host; a sandbox named `global`
    # gets `--sandbox global`.
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "acme=ACME_API_KEY@api.acme.example,m.acme.example")
    calls.clear()
    monkeypatch.setattr(sys, "stdin", io.StringIO("ACME-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "global", "acme", "--json")
    assert rc == 0 and doc["data"] == {"scope": "global", "scope_kind": "sandbox", "service": "acme", "value_state": "set"}
    assert [argv for argv, stdin in calls if stdin is not None] == [
        ["secret", "set-custom", "--sandbox", "global", "--host", "api.acme.example", "--host", "m.acme.example",
         "--env", "ACME_API_KEY", "--value-stdin"]
    ]


def test_secret_set_refusals_happen_before_anything_is_stored(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    # Below sbx 0.51.0 there is no `set-custom --value-stdin`: refused, never fed
    # to the native route (which would bind usai to nothing).
    calls = _spy(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("U-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "backend_version_unsupported"
    assert "0.51.0" in doc["error"]["message"]
    # A name sbx would store but never inject is refused too.
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setattr(sys, "stdin", io.StringIO("X-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "nosuchsvc", "--json")
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert "no host/env mapping" in doc["error"]["message"]
    assert not any(argv[:2] in (["secret", "set"], ["secret", "set-custom"]) for argv, _ in calls)
    assert not _store().exists()


def test_secret_set_refuses_an_existing_entry_on_either_table(monkeypatch, tmp_path, capsys):
    # A stale native `gitlab` entry would keep injecting to gitlab.com after a
    # custom --host set; an existing custom entry would prompt to overwrite.
    _env(monkeypatch, tmp_path, secrets={"global": {"gitlab": "set"}},
         custom=[_custom("global", "USAI_API_KEY", "sbx-cs-u1", "api.gsa.usai.gov")])
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setattr(sys, "stdin", io.StringIO("V\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "gitlab",
                      "--host", "workshop.cloud.gov", "--env", "GITLAB_TOKEN", "--json")
    assert rc == 1 and "already exists" in doc["error"]["message"]
    monkeypatch.setattr(sys, "stdin", io.StringIO("V\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 1 and "acq secret rm sbx-cs-u1" in doc["error"]["remediation"]
    assert not _store().exists()


def test_secret_has_maps_services_and_falls_back_to_global(monkeypatch, tmp_path, capsys):
    # A native entry named `usai` is never injected (no proxy rule maps it); the
    # custom USAI_API_KEY secret is. A sandbox scope falls back to global.
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set", "github": "set"}})
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "usai"]) == 1
    assert cli.main(["--backend", "sbx", "secret", "has", "mybox", "github"]) == 0
    assert cli.main(["--backend", "sbx", "secret", "has", "mybox", "usai"]) == 1
    _env(monkeypatch, tmp_path, custom=[_custom("mybox", "USAI_API_KEY", "sbx-cs-u1", "api.gsa.usai.gov")])
    assert cli.main(["--backend", "sbx", "secret", "has", "mybox", "usai"]) == 0
    assert cli.main(["--backend", "sbx", "secret", "has", "otherbox", "usai"]) == 1
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "usai"]) == 1
    out, err = capsys.readouterr()
    assert out == "" and err == ""


def test_secret_rm_custom_by_placeholder_with_force_and_no_stdin(monkeypatch, tmp_path, capsys):
    from acq_py import secretstore

    _env(monkeypatch, tmp_path, custom=[
        _custom("global", "USAI_API_KEY", "sbx-cs-global", "api.gsa.usai.gov"),
        _custom("mybox", "GITLAB_TOKEN", "sbx-cs-mybox", "workshop.cloud.gov"),
    ])
    secretstore.set_secret("usai", None, "U")
    secretstore.set_secret("gitlab", "mybox", "G", "workshop.cloud.gov", "GITLAB_TOKEN")
    seen: list = []
    real = subprocess.run

    def watch(argv, **kw):
        seen.append((list(argv), kw.get("stdin"), kw.get("input")))
        return real(argv, **kw)

    monkeypatch.setattr(sbx.subprocess, "run", watch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0 and doc["data"] == {"scope": "global", "scope_kind": "global", "service": "usai", "value_state": "unset"}
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "mybox", "gitlab", "--json")
    assert rc == 0
    removals = [(argv[argv.index("secret"):], stdin) for argv, stdin, _ in seen if "rm" in argv]
    assert removals == [
        (["secret", "rm", "--placeholder", "sbx-cs-global", "-f"], subprocess.DEVNULL),
        (["secret", "rm", "--placeholder", "sbx-cs-mybox", "--sandbox", "mybox", "-f"], subprocess.DEVNULL),
    ]
    assert _custom_table(tmp_path) == []
    assert not secretstore.exists("usai") and not secretstore.exists("gitlab", "mybox")


def test_raw_placeholder_rm_forces_and_closes_stdin(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, custom=[_custom("global", "ACME_API_KEY", "sbx-cs-raw", "api.acme.example")])
    seen: list = []
    real = subprocess.run

    def watch(argv, **kw):
        seen.append((list(argv), kw.get("stdin")))
        return real(argv, **kw)

    monkeypatch.setattr(sbx.subprocess, "run", watch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "sbx-cs-raw", "--json")
    assert rc == 0 and doc["data"]["placeholder"] == "sbx-cs-raw"
    argv, stdin = seen[-1]
    assert argv[argv.index("secret"):] == ["secret", "rm", "--placeholder", "sbx-cs-raw", "-f"]
    assert stdin is subprocess.DEVNULL
    assert _custom_table(tmp_path) == []


def test_global_label_ambiguity_fails_closed(monkeypatch, tmp_path, capsys):
    # sbx labels the global scope and a sandbox named `global` both "global".
    from acq_py import secretstore

    # With a sandbox named `global` in sbx, `has -g` cannot tell: exit 1 and say so.
    _env(monkeypatch, tmp_path, catalog={"global": "running"}, secrets={"global": {"github": "set"}})
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "github"]) == 1
    out, err = capsys.readouterr()
    assert out == "" and "cannot tell" in err
    # Asking for the sandbox named `global` sees it either way (it is that
    # sandbox's entry or the global one, injectable into it both ways)...
    assert cli.main(["--backend", "sbx", "secret", "has", "global", "github"]) == 0
    # ...but will not pipe a value into a possible overwrite prompt.
    monkeypatch.setattr(sys, "stdin", io.StringIO("GH\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "global", "github", "--json")
    assert rc == 1 and "cannot tell" in doc["error"]["message"]
    # A custom entry's placeholder might be the other scope's: rm refuses and
    # keeps the store entry.
    _env(monkeypatch, tmp_path, custom=[_custom("global", "USAI_API_KEY", "sbx-cs-g", "api.gsa.usai.gov")])
    secretstore.set_secret("usai", "global", "U")
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "global", "usai", "--json")
    assert rc == 1 and "cannot tell" in doc["error"]["message"]
    assert secretstore.exists("usai", "global")
    assert _custom_table_seeded_unchanged(tmp_path)
    # A native entry is removed by a scope-naming argv, so sbx itself resolves it.
    _env(monkeypatch, tmp_path, secrets={"global": {"github": "set"}})
    calls = _spy(monkeypatch)
    rc, _doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "global", "github", "--json")
    assert rc == 0
    assert ["secret", "rm", "--sandbox", "global", "github", "-f"] in [argv for argv, _ in calls]


def _custom_table_seeded_unchanged(tmp_path) -> bool:
    # The stub writes its custom table only on a change.
    return not (Path(tmp_path) / "sbx-home" / ".docker-sbx" / "custom-secrets.json").exists()


def test_secret_ls_reports_scope_kind(monkeypatch, tmp_path, capsys):
    secrets = {"global": {"github": "set"}, "mybox": {"github": "set"}}
    _env(monkeypatch, tmp_path, secrets=secrets,
         custom=[_custom("global", "USAI_API_KEY", "sbx-cs-u1", "api.gsa.usai.gov")])
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 0
    assert [(e["scope"], e["scope_kind"], e["service"]) for e in doc["data"]["secrets"]] == [
        ("global", "global", "github"), ("mybox", "sandbox", "github"), ("global", "global", "USAI_API_KEY"),
    ]
    # Once sbx has a sandbox named `global`, its label is no longer readable as global.
    _env(monkeypatch, tmp_path, catalog={"global": "running"}, secrets=secrets)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "-g", "--json")
    assert rc == 0
    assert doc["data"]["secrets"] == [{"scope": "global", "scope_kind": "unknown", "service": "github", "value_state": "set"}]


def test_provider_credential_set_existing_custom_secret_hint(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, custom=[_custom("global", "ACME_API_KEY", "sbx-cs-acme", "api.acme.example")])
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setattr(sys, "stdin", io.StringIO("ACME\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "provider-credential", "set", "acme", "ACME_API_KEY",
                      "--host", "api.acme.example", "--json")
    assert rc == 1 and "already exists" in doc["error"]["message"]
    assert "acq secret rm sbx-cs-acme" in doc["error"]["remediation"]


def test_provider_credential_set_names_every_existing_placeholder(monkeypatch, tmp_path, capsys):
    # Two entries for the env var on different hosts are not duplicates, but
    # both block the set: each is named by its own placeholder, none generically.
    _env(monkeypatch, tmp_path, custom=[_custom("global", "ACME_API_KEY", "sbx-cs-acme", "api.acme.example"),
                                        _custom("global", "ACME_API_KEY", "sbx-cs-other", "other.example")])
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setattr(sys, "stdin", io.StringIO("ACME\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "provider-credential", "set", "acme", "ACME_API_KEY",
                      "--host", "api.acme.example", "--json")
    assert rc == 1 and "already exists" in doc["error"]["message"]
    remediation = doc["error"]["remediation"]
    assert "acq secret rm sbx-cs-acme" in remediation and "acq secret rm sbx-cs-other" in remediation
    assert "<placeholder>" not in remediation


_DUPES = [_custom("global", "USAI_API_KEY", "sbx-cs-dupa", "api.gsa.usai.gov"),
          _custom("global", "USAI_API_KEY", "sbx-cs-dupb", "api.gsa.usai.gov")]


def _assert_duplicate_refusal(error, *placeholders, host="api.gsa.usai.gov"):
    assert f"sbx lists {len(placeholders)} global custom secrets for $" in error["message"]
    assert f" on {host}" in error["message"]
    for placeholder in placeholders:
        assert placeholder in error["message"]
        assert f"'sbx secret rm --placeholder {placeholder} -f'" in error["remediation"]
    assert "a running sandbox may hold one of these placeholders" in error["remediation"]


def _spy_rm(monkeypatch):
    calls: list[list[str]] = []
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        calls.append(list(argv))
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    return calls


def test_secret_set_refuses_duplicate_global_usai_entries(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, custom=_DUPES)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    calls = _spy_rm(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("V\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 1
    _assert_duplicate_refusal(doc["error"], "sbx-cs-dupa", "sbx-cs-dupb")
    assert doc["error"]["remediation"].startswith("nothing was stored;")
    assert "acq usai-rotate-api-key" in doc["error"]["remediation"]
    assert not any(argv[:2] in (["secret", "rm"], ["secret", "set-custom"]) for argv in calls)
    assert not _store().exists()


def test_secret_rm_refuses_duplicate_usai_entries_and_removes_nothing(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, custom=[*_DUPES, _custom("global", "USAI_API_KEY", "sbx-cs-other", "other.example")])
    calls = _spy_rm(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1
    _assert_duplicate_refusal(doc["error"], "sbx-cs-dupa", "sbx-cs-dupb")
    assert doc["error"]["remediation"].startswith("nothing was removed;")
    assert "sbx-cs-other" not in json.dumps(doc)
    assert not any(argv[:2] == ["secret", "rm"] for argv in calls)


def test_secret_rm_removes_only_the_entry_on_the_usai_host(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, custom=[_custom("global", "USAI_API_KEY", "sbx-cs-main", "api.gsa.usai.gov"),
                                        _custom("global", "USAI_API_KEY", "sbx-cs-other", "other.example")])
    calls = _spy_rm(monkeypatch)
    sbx.secret_rm("global", "usai")
    removals = [argv for argv in calls if argv[:2] == ["secret", "rm"]]
    assert removals == [["secret", "rm", "--placeholder", "sbx-cs-main", "-f"]]


def test_a_placeholder_with_odd_characters_is_never_printed_as_a_command(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, custom=[_custom("global", "USAI_API_KEY", "sbx-cs-ok1", "api.gsa.usai.gov"),
                                        _custom("global", "USAI_API_KEY", "$(touch x)", "api.gsa.usai.gov")])
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setattr(sys, "stdin", io.StringIO("V\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 1
    text = json.dumps(doc)
    assert "'sbx secret rm --placeholder sbx-cs-ok1 -f'" in text
    assert "$(touch" not in text and "unexpected characters" in text


def test_provider_credential_set_refuses_duplicate_entries(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, custom=[_custom("global", "ACME_API_KEY", "sbx-cs-a1", "api.acme.example"),
                                        _custom("global", "ACME_API_KEY", "sbx-cs-a2", "api.acme.example")])
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    calls = _spy_rm(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ACME\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "provider-credential", "set", "acme", "ACME_API_KEY",
                      "--host", "api.acme.example", "--json")
    assert rc == 1
    _assert_duplicate_refusal(doc["error"], "sbx-cs-a1", "sbx-cs-a2", host="api.acme.example")
    assert not any(argv[:2] in (["secret", "rm"], ["secret", "set-custom"]) for argv in calls)


def test_rotation_refuses_duplicate_global_usai_entries_with_removal_commands(monkeypatch, tmp_path, capsys):
    # Two global entries on the USAi host: refused with every placeholder named;
    # an entry for the same env var on another host does not count.
    _env(monkeypatch, tmp_path, custom=[*_DUPES, _custom("global", "USAI_API_KEY", "sbx-cs-alt", "alt.example")])
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    calls = _spy_rm(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("NEW-KEY\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "usai-rotate-api-key", "--json")
    assert rc == 1
    _assert_duplicate_refusal(doc["error"], "sbx-cs-dupa", "sbx-cs-dupb")
    assert "sbx-cs-alt" not in doc["error"]["message"] + doc["error"]["remediation"]
    assert not any(argv[:2] in (["secret", "rm"], ["secret", "set-custom"]) for argv in calls)


def test_malformed_provider_binding_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "not-a-binding")
    monkeypatch.setattr(sys, "stdin", io.StringIO("V\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert not _store().exists()


def test_custom_endpoint_host_that_reads_as_a_flag_is_refused(monkeypatch, tmp_path):
    # Defence in depth below the neutral layer's own checks: a host part that
    # starts with "-" would be parsed by sbx as a flag.
    _env(monkeypatch, tmp_path)
    for host, env in (("-x.example.gov", "KEY"), ("a.gov,", "KEY"), ("a.gov", "1BAD"), ("", "KEY")):
        with pytest.raises(sbx.SbxError) as info:
            sbx.secret_feed(sbx.secretstore.GLOBAL, "svc", "V", host, env)
        assert info.value.code == errors.VALIDATION_FAILED


def test_custom_rows_must_match_the_recorded_hosts(monkeypatch, tmp_path, capsys):
    # Two custom secrets share an env var but target different hosts. Matching
    # on the env var alone would remove the other host's placeholder, and has
    # would answer yes for the wrong host.
    from acq_py import secretstore

    rows = [
        _custom("global", "GITLAB_TOKEN", "sbx-cs-other", "gitlab.other.example"),
        _custom("global", "GITLAB_TOKEN", "sbx-cs-ours", "workshop.cloud.gov"),
    ]
    _env(monkeypatch, tmp_path, custom=rows)
    secretstore.set_secret("gitlab", None, "G", "workshop.cloud.gov", "GITLAB_TOKEN")
    calls = _spy(monkeypatch)
    rc, _doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "gitlab", "--json")
    assert rc == 0
    removals = [argv for argv, _ in calls if argv[:2] == ["secret", "rm"]]
    assert removals == [["secret", "rm", "--placeholder", "sbx-cs-ours", "-f"]]
    assert [row["placeholder"] for row in _custom_table(tmp_path)] == ["sbx-cs-other"]
    # usai's pin (api.gsa.usai.gov) is not met by a USAI_API_KEY row that
    # targets somewhere else either. (Drop the stub's table so the seed applies.)
    (Path(tmp_path) / "sbx-home" / ".docker-sbx" / "custom-secrets.json").unlink()
    _env(monkeypatch, tmp_path, custom=[_custom("global", "USAI_API_KEY", "sbx-cs-elsewhere", "llm.elsewhere.example")])
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "usai"]) == 1
    _env(monkeypatch, tmp_path, custom=[_custom("global", "USAI_API_KEY", "sbx-cs-u", "API.GSA.USAI.GOV")])
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "usai"]) == 0


def test_native_rm_failing_on_an_ambiguous_row_says_so_and_runs_once(monkeypatch, tmp_path, capsys):
    # Both a global and a sandbox-`global` github row are labelled "global": the
    # removal is the same argv, so it runs once, and when sbx refuses it the
    # error is the ambiguity, not a generic retry.
    from acq_py import secretstore

    # A definite row that fails keeps the generic retry advice.
    _env(monkeypatch, tmp_path, secrets={"mybox": {"github": "set"}})
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret rm")
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "mybox", "github", "--json")
    assert rc == 1 and doc["error"]["remediation"] == "check backend logs and retry"

    _env(monkeypatch, tmp_path, secrets={"global": {"github": "set"}})
    secretstore.set_secret("github", "global", "GH")
    monkeypatch.setattr(sbx, "_read_listing", lambda: [
        sbx._Entry("service", "global", "github", ""), sbx._Entry("service", "global", "github", ""),
    ])
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret rm")
    calls = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "global", "github", "--json")
    assert rc == 1 and "cannot tell" in doc["error"]["message"]
    assert doc["error"]["remediation"].startswith("the acq secret store entry was kept")
    assert [argv for argv, _ in calls if argv[:2] == ["secret", "rm"]] == [
        ["secret", "rm", "--sandbox", "global", "github", "-f"]
    ]
    assert secretstore.exists("github", "global")


def test_unreadable_sandbox_list_makes_the_global_label_ambiguous(monkeypatch, tmp_path, capsys):
    # If `sbx ls -q` fails, acq cannot rule out a sandbox named `global`.
    _env(monkeypatch, tmp_path, secrets={"global": {"github": "set"}})
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "ls")
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "github"]) == 1
    assert "cannot tell" in capsys.readouterr().err
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 0
    assert doc["data"]["secrets"] == [{"scope": "global", "scope_kind": "unknown", "service": "github", "value_state": "set"}]


def test_secret_ls_for_sandbox_global_without_such_a_sandbox_is_empty(monkeypatch, tmp_path, capsys):
    # With no sandbox named `global` in sbx, a "global" row is the global scope,
    # so listing the sandbox named `global` shows nothing (and -g shows it).
    _env(monkeypatch, tmp_path, secrets={"global": {"github": "set"}})
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "global", "--json")
    assert rc == 0 and doc["data"]["secrets"] == []
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "-g", "--json")
    assert rc == 0 and [e["scope_kind"] for e in doc["data"]["secrets"]] == ["global"]


def test_custom_row_without_targets_fails_closed_for_a_pinned_env(monkeypatch, tmp_path, capsys):
    # A row with no targets for an env var pinned to hosts could be another
    # host's secret: has and rm fail closed (secret_unreadable) instead of
    # matching on the env var alone.
    from acq_py import secretstore

    _env(monkeypatch, tmp_path, custom=[_custom("global", "USAI_API_KEY", "sbx-cs-bare")])
    secretstore.set_secret("usai", None, "U")
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "usai"]) == 1
    assert "no target hosts" in capsys.readouterr().err
    calls = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "secret_unreadable"
    assert not any(argv[:2] == ["secret", "rm"] for argv, _ in calls)
    assert secretstore.exists("usai")
    # A service with no recorded hosts still matches by env var alone.
    _env(monkeypatch, tmp_path, custom=[_custom("global", "RAW_ENV", "sbx-cs-raw")])
    assert cli.main(["--backend", "sbx", "secret", "has", "-g", "RAW_ENV"]) == 0
