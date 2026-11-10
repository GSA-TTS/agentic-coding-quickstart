"""Tier-2 tests for provider inputs: destination pins, the pre-create credential
gate, provider selection, materialisation safety and the attach-time key check.

Non-contract evidence (ADR-0039m): these drive ``cli.main`` and the adapter
in-process against the deterministic ``__stub__`` msb, recording every msb
child so they prove what was (and was not) created or bound. A secret value is
checked as a substring of every argv element and of all output. No provider is
ever contacted: the stub answers the in-guest key probe (``ACQ_MSB_STUB_PROBE``).
"""

from __future__ import annotations

import io
import json
import os
import shutil
import stat
import subprocess
import sys
import threading
from pathlib import Path

import pytest

from acq_py import cli, errors, kitspec, msb, provider_input, secretstore
from acq_py.commands import common

VALUE = "S3NTINEL-usai-gate-5d0e"


def _env(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_MSB_STUB_FAIL", "ACQ_MSB_STUB_PROBE", "ACQ_IMAGE",
                 "ACQ_MSB_IMAGE", "ACQ_PROVIDER_KITS", "ACQ_PROVIDER_CREDENTIAL_BINDINGS",
                 "ACQ_PROVIDER_CREDENTIAL_SEED", "USAI_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    (tmp_path / "ws").mkdir(exist_ok=True)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: False)


@pytest.fixture
def children(monkeypatch):
    """Record (argv, env) of every msb child process."""
    seen: list[tuple[list[str], dict | None]] = []
    real = subprocess.run

    def spy(argv, *args, **kwargs):
        if any("_stub_msb" in str(a) for a in argv):
            env = kwargs.get("env")
            seen.append((list(argv), dict(env) if env is not None else None))
        return real(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", spy)
    return seen


def _verb_calls(children, verb):
    out = []
    for argv, env in children:
        i = next(n for n, a in enumerate(argv) if a.endswith("_stub_msb") or a == "acq_py._stub_msb") + 1
        if argv[i:i + 1] == [verb]:
            out.append((argv[i:], env))
    return out


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out, err = capsys.readouterr()
    doc = json.loads(out) if out.strip().startswith("{") else None
    return rc, doc, out, err


def _create(capsys, tmp_path, *extra):
    return _invoke(capsys, "--backend", "msb", "create", "shell", str(tmp_path / "ws"), "--name", "box", *extra, "--json")


def _no_leak(value, children, *texts):
    for argv, _env in children:
        assert all(value not in token for token in argv), argv
    assert all(value not in text for text in texts)


# ---------------------------------------------------------------------------
# Destination pins.
# ---------------------------------------------------------------------------


@pytest.mark.provider_key
def test_a_kit_naming_another_host_than_the_pin_is_refused_before_create(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "usai=USAI_API_KEY@models.example.gov")
    rc, doc, _out, _err = _create(capsys, tmp_path)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "api.gsa.usai.gov" in doc["error"]["message"] and "models.example.gov" in doc["error"]["message"]
    assert _verb_calls(children, "create") == []
    assert not msb.exists("box")


@pytest.mark.provider_key
def test_a_kit_naming_another_key_variable_than_the_pin_is_refused(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "usai=USAI_OTHER_KEY@api.gsa.usai.gov")
    rc, doc, _out, _err = _create(capsys, tmp_path)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "USAI_OTHER_KEY" in doc["error"]["message"]
    assert _verb_calls(children, "create") == []


def test_an_unpinned_provider_is_refused():
    facts = provider_input.Facts("acme", "ACME_KEY", "models.acme.example", "https://models.acme.example/v1", "openai")
    with pytest.raises(provider_input.ProviderInputError) as exc:
        provider_input.check_pin(facts)
    assert exc.value.code == errors.VALIDATION_FAILED and "not pinned" in exc.value.message


# ---------------------------------------------------------------------------
# The pre-create credential gate.
# ---------------------------------------------------------------------------


def test_no_terminal_and_no_key_fails_closed_without_prompting(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("y\n"))
    rc, doc, _out, err = _create(capsys, tmp_path)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.SECRET_MISSING
    assert doc["error"]["remediation"] == "store it with 'acq secret set -g usai', then retry"
    assert "Store it now" not in err
    assert _verb_calls(children, "create") == []
    assert not secretstore.has("usai")


def test_a_host_exported_key_is_not_taken_for_a_stored_one(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("USAI_API_KEY", VALUE)
    rc, doc, out, err = _create(capsys, tmp_path)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.SECRET_MISSING
    assert "exported on the host" in doc["error"]["message"]
    assert _verb_calls(children, "create") == []
    _no_leak(VALUE, children, out, err)


def test_on_a_terminal_the_gate_asks_stores_and_binds(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr(sys, "stdin", io.StringIO("y\n"))
    monkeypatch.setattr(common, "_read_secret_tty", lambda prompt: VALUE)
    rc, doc, out, err = _create(capsys, tmp_path)
    assert rc == 0, (doc, err)
    assert "Store a credential for provider 'usai'" in err and "api.gsa.usai.gov" in err
    assert secretstore.resolve("usai") == VALUE
    assert doc["data"]["secret_bindings"] == ["USAI_API_KEY@api.gsa.usai.gov"]
    (argv, env), = _verb_calls(children, "create")
    assert env is not None and env["USAI_API_KEY"] == VALUE
    _no_leak(VALUE, children, out, err)


def test_on_a_terminal_declining_abandons_the_create(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr(sys, "stdin", io.StringIO("n\n"))
    monkeypatch.setattr(common, "_read_secret_tty", lambda prompt: pytest.fail("read a key after a decline"))
    rc, doc, _out, err = _create(capsys, tmp_path)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.SECRET_MISSING
    assert "Skipping" in err
    assert _verb_calls(children, "create") == []


@pytest.mark.parametrize("entered", ["", "   ", "bad\tvalue"])
def test_on_a_terminal_an_empty_or_unusable_key_stores_nothing_and_abandons(monkeypatch, tmp_path, capsys, children,
                                                                           entered):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr(sys, "stdin", io.StringIO("y\n"))
    monkeypatch.setattr(common, "_read_secret_tty", lambda prompt: entered)
    rc, doc, out, err = _create(capsys, tmp_path)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.SECRET_MISSING
    assert "abandoned" in doc["error"]["message"]
    assert not secretstore.has("usai")
    assert _verb_calls(children, "create") == []
    if entered.strip():
        _no_leak(entered, children, out, err)


# ---------------------------------------------------------------------------
# Provider selection.
# ---------------------------------------------------------------------------


@pytest.mark.provider_key
def test_the_default_provider_is_bound_while_its_kit_is_selected(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    rc, doc, _out, err = _create(capsys, tmp_path)
    assert rc == 0, (doc, err)
    assert doc["data"]["secret_bindings"] == ["USAI_API_KEY@api.gsa.usai.gov"]
    assert [f.provider for f in provider_input.recorded("msb", "box")] == ["usai"]


@pytest.mark.provider_key
def test_no_provider_kit_selected_binds_no_default_provider(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")
    rc, doc, _out, err = _create(capsys, tmp_path)
    assert rc == 0, (doc, err)
    assert doc["data"]["secret_bindings"] == []
    (argv, _env_map), = _verb_calls(children, "create")
    assert "--secret" not in argv
    assert provider_input.recorded("msb", "box") == []


def test_registry_ids_follow_the_selection(monkeypatch):
    monkeypatch.delenv("ACQ_PROVIDER_KITS", raising=False)
    assert provider_input.registry_ids() == ["usai"]
    assert provider_input.registry_ids({"ACQ_PROVIDER_KITS": ""}) == []
    external = {"ACQ_PROVIDER_KITS": "git+https://example.invalid/kits.git#ref=abc&dir=acme"}
    assert provider_input.default_selected(external) is False
    assert "usai" not in provider_input.registry_ids(external)


# ---------------------------------------------------------------------------
# The provider-input generation and its materialisation.
# ---------------------------------------------------------------------------


@pytest.mark.provider_key
def test_create_mounts_the_published_generation_read_only(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys.modules["acq_py.security"], "ro_mount_supported", lambda: True)
    monkeypatch.setattr(sys.modules["acq_py.security"], "probe_mount", lambda name: ("ok", ""))
    rc, doc, _out, err = _create(capsys, tmp_path)
    assert rc == 0, (doc, err)
    (argv, _env_map), = _verb_calls(children, "create")
    root = provider_input.input_root("msb", "box")
    current = root / "current"
    generation = (root / os.readlink(current)).resolve()
    guest = f"{provider_input.GUEST_DIR}/{generation.name}"
    assert f"{os.path.realpath(generation)}:{guest}:ro" in argv
    assert f"{provider_input.ROOT_ENV}={guest}" in argv
    usai = generation / "models" / "providers" / "usai"
    assert sorted(p.name for p in usai.iterdir()) == ["facts.json", "snapshot.json"]
    assert json.loads((usai / "facts.json").read_text(encoding="utf-8"))["host"] == "api.gsa.usai.gov"
    if os.name != "nt":
        assert stat.S_IMODE((usai / "facts.json").stat().st_mode) == 0o444


def _kit(tmp_path: Path, *, facts_path="provider-input/facts.json", host="api.example.gov") -> Path:
    kit = tmp_path / "kit"
    (kit / "provider-input").mkdir(parents=True)
    (kit / "snap").mkdir()
    manifest = {"schemaVersion": provider_input.BUNDLE_SCHEMA, "providerId": "acme", "factsPath": facts_path,
                "normalizerPath": "scripts/n.mjs", "snapshotPath": "snap/s.json", "providerPath": "models/providers/acme"}
    (kit / provider_input.MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")
    facts = {"schemaVersion": provider_input.FACTS_SCHEMA, "providerId": "acme", "apiProtocol": "openai-compatible",
             "host": host, "baseUrl": f"https://{host}/v1", "modelsUrl": f"https://{host}/v1/models", "keyEnv": "ACME_KEY"}
    (kit / "provider-input" / "facts.json").write_text(json.dumps(facts), encoding="utf-8")
    (kit / "snap" / "s.json").write_text(json.dumps({"providerId": "acme", "models": []}), encoding="utf-8")
    return kit


def _symlink(target: Path, link: Path) -> None:
    try:
        os.symlink(target, link)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks are unavailable on this host")


def test_materialize_copies_only_the_declared_files(tmp_path):
    kit = _kit(tmp_path)
    manifest, facts = provider_input.kit_facts(kit)
    assert facts.host == "api.example.gov"
    target = tmp_path / "providers"
    target.mkdir()
    provider_input.materialize(manifest, kit, target)
    assert sorted(p.name for p in (target / "acme").iterdir()) == ["facts.json", "snapshot.json"]
    with pytest.raises(provider_input.ProviderInputError, match="duplicate"):
        provider_input.materialize(manifest, kit, target)


def test_a_symlinked_facts_file_is_refused(tmp_path):
    kit = _kit(tmp_path)
    outside = tmp_path / "outside.json"
    outside.write_text((kit / "provider-input" / "facts.json").read_text(encoding="utf-8"), encoding="utf-8")
    (kit / "provider-input" / "facts.json").unlink()
    _symlink(outside, kit / "provider-input" / "facts.json")
    with pytest.raises(provider_input.ProviderInputError):
        provider_input.kit_facts(kit)


def test_a_symlinked_directory_in_the_path_is_refused(tmp_path):
    kit = _kit(tmp_path)
    real = tmp_path / "elsewhere"
    (kit / "snap").rename(real)
    _symlink(real, kit / "snap")
    manifest, _facts = provider_input.kit_facts(kit)
    target = tmp_path / "providers"
    target.mkdir()
    with pytest.raises(provider_input.ProviderInputError):
        provider_input.materialize(manifest, kit, target)


@pytest.mark.parametrize("bad", ["../facts.json", "/etc/passwd", "a//b", "a/./b", "a\\b", "C:/x"])
def test_an_escaping_artifact_path_is_refused(tmp_path, bad):
    kit = _kit(tmp_path, facts_path=bad)
    with pytest.raises(provider_input.ProviderInputError, match="unsafe"):
        provider_input.kit_facts(kit)


@pytest.mark.parametrize("host", ["api.example.gov:8443", "API.example.gov"])
def test_facts_with_an_unsafe_host_are_refused(tmp_path, host):
    with pytest.raises(provider_input.ProviderInputError):
        provider_input.kit_facts(_kit(tmp_path, host=host))


def test_a_models_url_on_another_host_is_refused(tmp_path):
    kit = _kit(tmp_path)
    path = kit / "provider-input" / "facts.json"
    doc = json.loads(path.read_text(encoding="utf-8"))
    doc["modelsUrl"] = "https://api.example.gov.evil.example/v1/models"
    path.write_text(json.dumps(doc), encoding="utf-8")
    with pytest.raises(provider_input.ProviderInputError, match="models URL"):
        provider_input.kit_facts(kit)


def test_the_bundled_usai_kit_has_valid_facts():
    found = provider_input.selected_facts(["usai-provider", "opencode"], kitspec.BUNDLE_DIR)
    assert [(k, f.provider, f.host) for k, _m, f in found] == [
        (kitspec.BUNDLE_DIR / "usai-provider", "usai", "api.gsa.usai.gov")]


def test_a_kit_outside_the_bundle_is_read_from_its_own_directory(tmp_path):
    # A fetched provider kit carries its own directory; the bundle copy of a kit
    # with the same name must not be read in its place.
    kit = tmp_path / "fetched" / "usai-provider"
    shutil.copytree(kitspec.BUNDLE_DIR / "usai-provider", kit)
    facts_path = kit / "provider-input" / "facts.json"
    doc = json.loads(facts_path.read_text(encoding="utf-8"))
    doc["modelsUrl"] = "https://api.gsa.usai.gov/api/v2/models"
    facts_path.write_text(json.dumps(doc), encoding="utf-8")
    found = provider_input.selected_facts([("usai-provider", kit), ("opencode", None)])
    assert [(k, f.models_url) for k, _m, f in found] == [(kit, "https://api.gsa.usai.gov/api/v2/models")]


def test_a_failed_create_discards_the_generation_and_the_record(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    secretstore.set_secret("usai", None, VALUE)
    monkeypatch.setattr(sys.modules["acq_py.security"], "ro_mount_supported", lambda: True)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "create")
    rc, doc, _out, _err = _create(capsys, tmp_path)
    assert rc == errors.EXIT_FAILURE
    generations = provider_input.input_root("msb", "box") / "generations"
    assert list(generations.iterdir()) == []
    assert provider_input.recorded("msb", "box") == []


# ---------------------------------------------------------------------------
# The attach-time key check.
# ---------------------------------------------------------------------------


def _run_box(capsys):
    return _invoke(capsys, "--backend", "msb", "run", "box", "--json")


@pytest.mark.provider_key
@pytest.mark.parametrize("answer,code", [
    ("401|0", errors.PROVIDER_AUTH_FAILED),
    ("403|0", errors.PROVIDER_AUTH_FAILED),
    ("000|7", errors.PROVIDER_UNREACHABLE),
    ("|6", errors.PROVIDER_UNREACHABLE),
    ("no status", errors.PROVIDER_UNREACHABLE),  # not "": Windows drops an empty env var, so the stub default applied
])
def test_attach_refuses_a_key_the_provider_does_not_accept(monkeypatch, tmp_path, capsys, children, answer, code):
    _env(monkeypatch, tmp_path)
    assert _create(capsys, tmp_path)[0] == 0
    monkeypatch.setenv("ACQ_MSB_STUB_PROBE", answer)
    children.clear()
    rc, doc, out, err = _run_box(capsys)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == code
    probe, = [argv for argv, _e in _verb_calls(children, "exec") if any("%{http_code}" in a for a in argv)]
    assert probe[-1] == "https://api.gsa.usai.gov/api/v1/models"
    assert any("$USAI_API_KEY" in a for a in probe)  # referenced by name, never a value
    _no_leak("test-usai-key-not-a-secret", children, out, err)


@pytest.mark.provider_key
def test_attach_with_an_accepted_key_probes_then_launches(monkeypatch, tmp_path, capsys, children):
    _env(monkeypatch, tmp_path)
    assert _create(capsys, tmp_path)[0] == 0
    children.clear()
    rc, doc, _out, err = _run_box(capsys)
    assert rc == 0, (doc, err)
    assert doc["data"]["action"] == "reattached"
    assert [a for a, _e in _verb_calls(children, "exec") if any("%{http_code}" in t for t in a)]


@pytest.mark.provider_key
def test_a_transient_provider_error_warns_and_attaches(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    assert _create(capsys, tmp_path)[0] == 0
    monkeypatch.setenv("ACQ_MSB_STUB_PROBE", "503|0")
    rc, _doc, _out, err = _run_box(capsys)
    assert rc == 0 and "transient" in err


@pytest.mark.provider_key
def test_a_tampered_facts_record_fails_the_attach_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    assert _create(capsys, tmp_path)[0] == 0
    record = provider_input._hc_dir("msb", "box") / provider_input.RECORD_KEY
    record.write_text("usai\tUSAI_API_KEY\tevil.example\thttps://evil.example/v1/models\topenai", encoding="utf-8")
    rc, doc, _out, _err = _run_box(capsys)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "pinned" in doc["error"]["message"]
    record.write_text("usai\tUSAI_API_KEY\tapi.gsa.usai.gov\thttps://api.gsa.usai.gov/$(x)\topenai", encoding="utf-8")
    rc, doc, _out, _err = _run_box(capsys)
    assert rc == errors.EXIT_FAILURE and "record" in doc["error"]["message"]


def test_classify_matches_bash():
    assert provider_input.classify("200|0") == "200"
    assert provider_input.classify("000|7") == "unreachable"
    assert provider_input.classify("|6") == "unresolved"
    assert provider_input.classify("") == ""
    assert provider_input.classify("xx|") == ""


def test_classify_splits_where_bash_does():
    # Bash takes the HTTP code from before the FIRST '|' and curl's exit code
    # from after the LAST one; with no '|' both are the whole output.
    assert provider_input.classify("200|7|0") == "200"
    assert provider_input.classify("401|x|0") == "401"
    assert provider_input.classify("200") == "unreachable"
    # Only ASCII digits count (Bash's tr -cd '0-9').
    assert provider_input.classify("٢٠٠|0") == ""


@pytest.mark.skipif(not hasattr(os, "fchmod") or not getattr(os, "O_NOFOLLOW", 0), reason="needs O_NOFOLLOW and fchmod")
def test_chmod_nofollow_never_follows_a_link_swapped_in_after_the_check(tmp_path, monkeypatch):
    target = tmp_path / "target"
    target.write_text("x", encoding="utf-8")
    target.chmod(0o644)
    link = tmp_path / "entry"
    link.symlink_to(target)
    # The link appears only after any by-name check would have run.
    monkeypatch.setattr(provider_input.os.path, "islink", lambda _p: False)
    provider_input._chmod_nofollow(link, 0o400)
    assert stat.S_IMODE(target.stat().st_mode) == 0o644
    plain = tmp_path / "plain"
    plain.write_text("y", encoding="utf-8")
    provider_input._chmod_nofollow(plain, 0o444)
    assert stat.S_IMODE(plain.stat().st_mode) == 0o444


# ---------------------------------------------------------------------------
# Recreate gates before it removes the old guest.
# ---------------------------------------------------------------------------


def _recreatable(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    catalog = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    catalog.parent.mkdir(parents=True, exist_ok=True)
    catalog.write_text(json.dumps({"sec": "running"}), encoding="utf-8")
    record = {"schema": 1, "name": "sec", "backend": "msb", "agent": "opencode", "workspace": str(tmp_path / "ws"),
              "ro_host_config": True}
    path = sys.modules["acq_py.state"].record_path("msb", "sec")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record), encoding="utf-8")
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))


@pytest.mark.provider_key
def test_recreate_with_a_pin_mismatch_keeps_the_old_guest(monkeypatch, tmp_path, capsys, children):
    _recreatable(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "usai=USAI_API_KEY@models.example.gov")
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.VALIDATION_FAILED, doc
    assert _verb_calls(children, "remove") == [] and _verb_calls(children, "create") == []
    assert msb.exists("sec")


def test_recreate_without_a_key_keeps_the_old_guest(monkeypatch, tmp_path, capsys, children):
    _recreatable(monkeypatch, tmp_path)
    rc, doc, _out, _err = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.SECRET_MISSING, doc
    assert _verb_calls(children, "remove") == [] and _verb_calls(children, "create") == []
    assert msb.exists("sec")


# ---------------------------------------------------------------------------
# Review follow-ups: curl's exit status and selection-off registry providers.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("raw", ["200|28", "200|7", "401|6"])
def test_a_status_with_a_failed_curl_is_never_accepted(raw):
    assert provider_input.classify(raw) in ("unreachable", "unresolved")


def test_a_registered_provider_is_not_delivered_with_selection_off(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "acme=ACME_KEY@models.acme.example")
    monkeypatch.delenv("ACQ_PROVIDER_KITS", raising=False)
    assert provider_input.delivery_ids("msb", "box") == ["acme", "usai"]
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")
    assert provider_input.delivery_ids("msb", "box") == []


def test_publish_and_discard_never_chmod_through_a_link(tmp_path, monkeypatch):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    outside = tmp_path / "outside.txt"
    outside.write_text("x", encoding="utf-8")
    os.chmod(outside, 0o600)
    generation = provider_input.prepare("msb", "box", [])
    _symlink(outside, generation / "models" / "link")
    provider_input.publish("msb", "box", generation)
    provider_input.discard(generation)
    assert not generation.exists() and outside.read_text(encoding="utf-8") == "x"
    if os.name != "nt":
        assert stat.S_IMODE(outside.stat().st_mode) == 0o600


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="needs FIFOs")
def test_a_fifo_in_place_of_an_artifact_is_refused_without_blocking(tmp_path):
    kit = _kit(tmp_path)
    fifo = kit / "provider-input" / "facts.json"
    fifo.unlink()
    os.mkfifo(fifo)
    outcome: list = []
    worker = threading.Thread(target=lambda: outcome.append(_raised(provider_input.kit_facts, kit)), daemon=True)
    worker.start()
    worker.join(timeout=10)
    if worker.is_alive():  # a blocking open: release it by opening the write end, then fail
        os.close(os.open(fifo, os.O_WRONLY | os.O_NONBLOCK))
        worker.join(timeout=5)
        pytest.fail("reading a FIFO artifact blocked")
    assert isinstance(outcome[0], provider_input.ProviderInputError) and "regular file" in str(outcome[0])


def _raised(func, *args):
    try:
        func(*args)
    except Exception as exc:  # noqa: BLE001 - the caller inspects what was raised
        return exc
    return None


def test_sbx_message_names_sbx_and_asks_to_re_store_a_stored_key():
    facts = provider_input.Facts("usai", "USAI_API_KEY", "api.gsa.usai.gov", "https://api.gsa.usai.gov/api/v1/models",
                                 "openai-compatible")
    with pytest.raises(provider_input.ProviderInputError) as exc:
        provider_input.gate([facts], has_key=lambda p: False, ask_store=None, backend="sbx", stored=lambda p: True)
    assert "sbx snapshots its proxy table" in exc.value.message and "msb" not in exc.value.message
    assert "is stored" in exc.value.message and exc.value.remediation.startswith("re-store it")


# ---------------------------------------------------------------------------
# The sbx side: the same gate at create, the same probe at attach.
# ---------------------------------------------------------------------------


def _sbx_env(monkeypatch, tmp_path):
    from test_kit_sbx import _env as kit_sbx_env

    for name in ("ACQ_SBX_STUB_PROBE", "ACQ_PROVIDER_KITS", "ACQ_PROVIDER_CREDENTIAL_BINDINGS", "USAI_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: False)
    return kit_sbx_env(monkeypatch, tmp_path)


def _sbx_create(capsys, ws):
    return _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "sb", "--json")


def test_sbx_create_without_an_injectable_key_fails_closed(monkeypatch, tmp_path, capsys):
    ws = _sbx_env(monkeypatch, tmp_path)
    rc, doc, _out, _err = _sbx_create(capsys, ws)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.SECRET_MISSING, doc
    assert not sys.modules["acq_py.sbx"].exists("sb")


@pytest.mark.provider_key
def test_sbx_create_refuses_a_pin_mismatch(monkeypatch, tmp_path, capsys):
    ws = _sbx_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "usai=USAI_API_KEY@models.example.gov")
    rc, doc, _out, _err = _sbx_create(capsys, ws)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.VALIDATION_FAILED, doc
    assert not sys.modules["acq_py.sbx"].exists("sb")


@pytest.mark.provider_key
@pytest.mark.parametrize("answer,code", [("401|0", errors.PROVIDER_AUTH_FAILED), ("000|7", errors.PROVIDER_UNREACHABLE)])
def test_sbx_attach_probes_the_recorded_provider(monkeypatch, tmp_path, capsys, answer, code):
    ws = _sbx_env(monkeypatch, tmp_path)
    rc, doc, _out, err = _sbx_create(capsys, ws)
    assert rc == 0, (doc, err)
    assert [f.provider for f in provider_input.recorded("sbx", "sb")] == ["usai"]
    monkeypatch.setenv("ACQ_SBX_STUB_PROBE", answer)
    rc, doc, _out, _err = _invoke(capsys, "--backend", "sbx", "run", "sb", "--json")
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == code, doc


def test_sbx_on_a_terminal_the_gate_asks_stores_feeds_and_creates(monkeypatch, tmp_path, capsys):
    # The terminal prompt-and-store path on sbx, end to end: the gate asks, the
    # key is read with echo off (stubbed), stored in the acq store and fed to
    # sbx's proxy table, so the re-check passes and the create goes ahead. The
    # value reaches sbx only on stdin, never argv or output.
    ws = _sbx_env(monkeypatch, tmp_path)
    sbx_mod = sys.modules["acq_py.sbx"]
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr(sys, "stdin", io.StringIO("y\n"))
    prompts = []
    monkeypatch.setattr(common, "_read_secret_tty", lambda prompt: prompts.append(prompt) or VALUE)
    argvs: list[list[str]] = []
    real = subprocess.run

    def spy(argv, *args, **kwargs):
        argvs.append([str(a) for a in argv])
        return real(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", spy)
    rc, doc, out, err = _sbx_create(capsys, ws)
    assert rc == 0, (doc, err)
    assert prompts == ["Enter the usai key: "]
    assert "Store a credential for provider 'usai'" in err and "api.gsa.usai.gov" in err
    assert secretstore.resolve("usai") == VALUE
    assert sbx_mod.secret_has(secretstore.GLOBAL, "usai")
    assert any("set-custom" in argv for argv in argvs)
    assert sbx_mod.exists("sb")
    for argv in argvs:
        assert all(VALUE not in token for token in argv), argv
    assert VALUE not in out + err


def test_sbx_provider_id_colliding_with_a_builtin_service_is_refused(monkeypatch, tmp_path):
    # A provider named like an sbx built-in service (here "openai") would be
    # fed through `sbx secret set openai` and bound to sbx's own vendor
    # endpoint, not the pinned host. No bundled kit declares such a provider,
    # so the selection is faked; the gate refuses before any key check.
    from acq_py.commands import lifecycle

    _sbx_env(monkeypatch, tmp_path)
    facts = provider_input.Facts("openai", "OPENAI_API_KEY", "models.example.gov",
                                 "https://models.example.gov/v1/models", "openai-compatible")
    monkeypatch.setattr(provider_input, "selected_facts", lambda kit_names: [("fake-kit", {}, facts)])
    monkeypatch.setattr(provider_input, "gate", lambda *a, **k: pytest.fail("the gate ran past the collision"))
    with pytest.raises(provider_input.ProviderInputError) as exc:
        lifecycle._provider_gate("sbx", "sb", ["fake-kit"])
    assert exc.value.code == errors.VALIDATION_FAILED
    assert "collides with an sbx built-in service" in exc.value.message and "models.example.gov" in exc.value.message
    # msb has no built-in services: the same selection reaches the gate there.
    reached = []
    monkeypatch.setattr(provider_input, "gate", lambda *a, **k: reached.append(True))
    lifecycle._provider_gate("msb", "sb", ["fake-kit"])
    assert reached == [True]


@pytest.mark.skipif(os.name == "nt", reason="POSIX directory permissions")
def test_discard_removes_a_generation_bash_made_read_only(tmp_path):
    generation = tmp_path / "generations" / "generation.x"
    usai = generation / "models" / "providers" / "usai"
    usai.mkdir(parents=True)
    (usai / "facts.json").write_text("{}", encoding="utf-8")
    for dirpath, dirnames, filenames in os.walk(generation, topdown=False):  # chmod -R a-w, as Bash publishes
        for entry in [*filenames, *dirnames]:
            path = Path(dirpath) / entry
            os.chmod(path, stat.S_IMODE(path.stat().st_mode) & ~0o222)
    os.chmod(generation, stat.S_IMODE(generation.stat().st_mode) & ~0o222)
    try:
        provider_input.discard(generation)
        assert not generation.exists()
    finally:
        if generation.exists():
            for dirpath, dirnames, _f in os.walk(generation):
                os.chmod(dirpath, 0o700)


def test_sbx_create_with_the_key_only_in_the_acq_store_asks_to_re_store(monkeypatch, tmp_path, capsys):
    ws = _sbx_env(monkeypatch, tmp_path)
    secretstore.set_secret("usai", None, VALUE)
    rc, doc, out, err = _sbx_create(capsys, ws)
    assert rc == errors.EXIT_FAILURE and doc["error"]["code"] == errors.SECRET_MISSING, doc
    assert "sbx backend cannot inject" in doc["error"]["message"] and "msb" not in doc["error"]["message"]
    assert VALUE not in out + err


@pytest.mark.provider_key
def test_no_provider_input_warning_where_the_platform_never_mounts_it(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    security = sys.modules["acq_py.security"]
    monkeypatch.setattr(security, "ro_mount_supported", lambda: False)
    monkeypatch.setattr(security, "ro_mount_platform_problem", lambda: security.PLATFORM_PROBLEM)
    rc, doc, _out, err = _create(capsys, tmp_path)
    assert rc == 0, (doc, err)
    assert "provider input is not mounted" not in err
    assert [f.provider for f in provider_input.recorded("msb", "box")] == ["usai"]


@pytest.mark.provider_key
def test_an_old_msb_warns_that_provider_input_is_not_mounted(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    security = sys.modules["acq_py.security"]
    monkeypatch.setattr(security, "ro_mount_supported", lambda: False)
    monkeypatch.setattr(security, "ro_mount_platform_problem", lambda: None)
    rc, doc, _out, err = _create(capsys, tmp_path)
    assert rc == 0, (doc, err)
    assert "provider input is not mounted" in err


@pytest.mark.provider_key
def test_windows_recreate_passes_the_gate_quietly(monkeypatch, tmp_path, capsys):
    _recreatable(monkeypatch, tmp_path)
    monkeypatch.setattr(sys.modules["acq_py.security"], "WINDOWS", True)
    rc, doc, _out, err = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 0, (doc, err)
    assert doc["data"]["recreated"] is True and doc["data"]["ro_host_config"] is False
    assert "provider input is not mounted" not in err
