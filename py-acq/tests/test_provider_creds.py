"""Tier-2 implementation tests for the provider-credential / github-scope /
usai-rotate-api-key slice (ADR-0038m §provider-credential, ADR-0012, ADR-0013).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb. Contract
evidence lives only in the vector corpus (``test/vectors``). The paramount
assertion is that no credential VALUE ever appears in argv or output — it flows
only as the backend child's stdin, and the binding/scope is host-authoritative
state with no value field.
"""

from __future__ import annotations

import io
import json
import os
import sys

from acq_py import cli, gitrepos, msb, provider_creds
from gitfixtures import git_repo


def _env(monkeypatch, tmp_path, *, secrets=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in (
        "ACQ_BACKEND",
        "ACQ_MSB_STUB_CATALOG",
        "ACQ_IMAGE",
        "ACQ_MSB_IMAGE",
        "ACQ_MSB_STUB_FAIL",
        "ACQ_MSB_STUB_SECRETS",
        "ACQ_MSB_STUB_SECRET_LS_RAW",
        "ACQ_MSB_STUB_ROTATE",
        "ACQ_PROVIDER_CREDENTIAL_BINDINGS",
        "ACQ_PROVIDER_CREDENTIAL_SEED",
    ):
        monkeypatch.delenv(name, raising=False)
    if secrets is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_SECRETS", json.dumps(secrets))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out
    doc = json.loads(out) if out.strip() else None
    return rc, doc


def _invoke_full(capsys, *argv):
    rc = cli.main(list(argv))
    out, err = capsys.readouterr()
    return rc, (json.loads(out) if out.strip() else None), out, err


# ---------------------------------------------------------------------------
# provider-credential set / ls / rm
# ---------------------------------------------------------------------------

def test_provider_credential_value_never_in_argv_or_output(monkeypatch, tmp_path, capsys):
    # The hard guarantee on the backend that stores provider credentials (sbx
    # `secret set-custom --value-stdin`, v0.51.0): the value appears ONLY as the
    # backend child's stdin, never argv/output. Mirrors the working `secret set`
    # mutation proof in test_secret.py.
    from acq_py import sbx

    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    captured: dict = {}
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["argv"] = list(argv)
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-PROVIDER-KEY\n"))

    rc = cli.main(
        ["--backend", "sbx", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"]
    )
    out, err = capsys.readouterr()

    assert rc == 0
    assert captured["input_text"] == "TOP-SECRET-PROVIDER-KEY"
    assert captured["argv"][:2] == ["secret", "set-custom"]
    assert "--value-stdin" in captured["argv"]
    assert captured["argv"].count("--host") == 1
    assert "TOP-SECRET-PROVIDER-KEY" not in captured["argv"]
    assert "TOP-SECRET-PROVIDER-KEY" not in out
    assert "TOP-SECRET-PROVIDER-KEY" not in err


def test_provider_credential_msb_stores_in_the_acq_store(monkeypatch, tmp_path, capsys):
    # msb has no provider-credential subcommand: the value goes to the acq
    # secret store (bound as --secret KEY_ENV@HOST at create), never to output.
    from acq_py import secretstore

    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-PROVIDER-KEY\n"))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    out, err = capsys.readouterr()
    assert rc == 0
    assert doc["data"]["key_env"] == "USAI_API_KEY"
    assert secretstore.resolve("usai") == "TOP-SECRET-PROVIDER-KEY"
    assert "TOP-SECRET-PROVIDER-KEY" not in out
    assert "TOP-SECRET-PROVIDER-KEY" not in err


def test_provider_credential_set_ls_reports_binding_only(monkeypatch, tmp_path, capsys):
    # `provider-credential ls` is host-side (no backend value store): seed the
    # binding directly and assert it reports provider/key_env/hosts/source_layer,
    # never a value.
    _env(monkeypatch, tmp_path)
    provider_creds.set_binding("usai", "USAI_API_KEY", ["api.gsa.usai.gov"])

    rc, doc = _invoke(capsys, "provider-credential", "ls", "--json")
    assert rc == 0
    assert doc["data"]["bindings"] == [
        {"provider": "usai", "key_env": "USAI_API_KEY", "hosts": ["api.gsa.usai.gov"], "source_layer": "provider-credentials"}
    ]
    # ls reports exactly the four non-secret fields, never a value or value_state.
    assert set(doc["data"]["bindings"][0]) == {"provider", "key_env", "hosts", "source_layer"}


def test_provider_credential_rm_semantics(monkeypatch, tmp_path, capsys):
    # provider-credential rm is host-side (no backend value store): seed the binding
    # directly and assert rm / rm-again semantics.
    _env(monkeypatch, tmp_path)
    provider_creds.set_binding("usai", "USAI_API_KEY", ["api.gsa.usai.gov"])

    rc, doc = _invoke(capsys, "provider-credential", "rm", "usai", "--json")
    assert rc == 0
    assert doc["data"] == {"provider": "usai", "removed": True, "credential_removed": False}

    # Removing an absent binding fails closed with secret_missing (exit 1).
    rc, doc = _invoke(capsys, "provider-credential", "rm", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_missing"


def _write_binding_record(tmp_path, provider, doc):
    path = provider_creds._binding_path(provider)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


def test_provider_credential_rm_newer_schema_fails_closed(monkeypatch, tmp_path, capsys):
    # A newer/unknown-schema binding record fails closed with the stable
    # state_schema_unsupported code, never a raw traceback (ADR-0041m).
    _env(monkeypatch, tmp_path)
    _write_binding_record(
        tmp_path, "usai",
        {"schema": 99, "provider": "usai", "key_env": "USAI_API_KEY", "hosts": ["api.gsa.usai.gov"]},
    )

    rc, doc = _invoke(capsys, "provider-credential", "rm", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


def _sbx_calls(monkeypatch):
    from acq_py import sbx

    calls: list = []
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        calls.append(list(argv))
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    return calls


def _sbx_secrets(tmp_path) -> dict:
    path = tmp_path / "sbx-home" / ".docker-sbx" / "secrets.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def test_provider_credential_set_schema_error_leaves_no_orphan(monkeypatch, tmp_path, capsys):
    # An unreadable (newer-schema) binding record is refused BEFORE the value
    # reaches the backend: nothing is stored, and a retry is not blocked by an
    # orphaned sbx secret.
    _sbx_env(monkeypatch, tmp_path, version="0.51.0")
    path = _write_binding_record(
        tmp_path, "usai",
        {"schema": 99, "provider": "usai", "key_env": "USAI_API_KEY", "hosts": ["api.gsa.usai.gov"]},
    )
    before = path.read_bytes()
    calls = _sbx_calls(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ORPHAN-CANDIDATE\n"))

    rc, doc = _invoke(
        capsys, "--backend", "sbx", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"
    assert not any(argv[:2] == ["secret", "set-custom"] for argv in calls)
    assert "USAI_API_KEY" not in json.dumps(_sbx_secrets(tmp_path))
    assert path.read_bytes() == before


def test_provider_credential_set_unwritable_binding_leaves_no_orphan(monkeypatch, tmp_path, capsys):
    from pathlib import Path

    _sbx_env(monkeypatch, tmp_path, version="0.51.0")
    calls = _sbx_calls(monkeypatch)
    real_replace = os.replace

    def deny(src, dst, *a, **k):
        if Path(dst).parent == provider_creds._binding_dir():
            raise PermissionError(13, "Permission denied")
        return real_replace(src, dst, *a, **k)

    monkeypatch.setattr(os, "replace", deny)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ORPHAN-CANDIDATE\n"))
    rc, doc = _invoke(
        capsys, "--backend", "sbx", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 1 and doc["error"]["code"] == "failure"
    assert "nothing was stored" in doc["error"]["remediation"]
    assert not any(argv[:2] == ["secret", "set-custom"] for argv in calls)


def test_provider_credential_set_refusal_restores_the_previous_binding(monkeypatch, tmp_path, capsys):
    # sbx refuses a second set-custom for the same env var; the binding must not
    # be left pointing at the new host while the stored secret targets the old.
    _sbx_env(monkeypatch, tmp_path, version="0.51.0")
    argv = ["--backend", "sbx", "provider-credential", "set", "acme", "ACME_KEY", "--json"]
    monkeypatch.setattr(sys, "stdin", io.StringIO("first\n"))
    assert _invoke(capsys, *argv, "--host", "old.acme.gov")[0] == 0
    before = provider_creds._binding_path("acme").read_bytes()
    monkeypatch.setattr(sys, "stdin", io.StringIO("second\n"))
    rc, doc = _invoke(capsys, *argv, "--host", "new.acme.gov")
    assert rc == 1 and "already exists" in doc["error"]["message"]
    assert provider_creds._binding_path("acme").read_bytes() == before
    # A brand-new provider refused by the backend leaves no binding at all.
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret ls")
    monkeypatch.setattr(sys, "stdin", io.StringIO("third\n"))
    rc, _doc = _invoke(capsys, "--backend", "sbx", "provider-credential", "set", "other", "OTHER_KEY",
                       "--host", "models.other.gov", "--json")
    assert rc == 1
    assert provider_creds.get_binding("other") is None


def test_provider_credential_rm_unlink_failure_is_not_success(monkeypatch, tmp_path, capsys):
    from pathlib import Path

    _env(monkeypatch, tmp_path)
    provider_creds.set_binding("usai", "USAI_API_KEY", ["api.gsa.usai.gov"])
    target = provider_creds._binding_path("usai")
    real_unlink = Path.unlink

    def deny(self, *a, **k):
        if self == target:
            raise PermissionError(13, "Permission denied")
        return real_unlink(self, *a, **k)

    monkeypatch.setattr(Path, "unlink", deny)
    rc, doc = _invoke(capsys, "provider-credential", "rm", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "failure"
    assert "Permission denied" in doc["error"]["message"]
    rc, doc = _invoke(capsys, "provider-credential", "ls", "--json")
    assert [b["provider"] for b in doc["data"]["bindings"]] == ["usai"]


def test_provider_credential_rm_needs_a_backend_for_a_stored_value(monkeypatch, tmp_path, capsys):
    from acq_py import secretstore

    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    provider_creds.set_binding("acme", "ACME_KEY", ["models.acme.gov"])
    secretstore.store(secretstore.key_for("acme"), "STORED-VALUE")
    rc, doc = _invoke(capsys, "provider-credential", "rm", "acme", "--json")
    assert rc == 1 and doc["error"]["code"] == "backend_not_found"
    assert provider_creds.get_binding("acme") is not None
    assert secretstore.get(secretstore.key_for("acme")) == "STORED-VALUE"


def _sbx_custom_table(tmp_path) -> list:
    path = tmp_path / "sbx-home" / ".docker-sbx" / "custom-secrets.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else []


def test_provider_credential_rm_on_sbx_removes_the_custom_secret(monkeypatch, tmp_path, capsys):
    # `provider-credential set` on sbx creates a global set-custom entry; rm
    # finds it by KEY_ENV and the pinned host and removes it by placeholder,
    # so nothing is left injected and there is no warning.
    from acq_py import sbx

    _sbx_env(monkeypatch, tmp_path, version="0.51.0")
    monkeypatch.setattr(sys, "stdin", io.StringIO("v-1\n"))
    assert _invoke(capsys, "--backend", "sbx", "provider-credential", "set", "acme", "ACME_KEY",
                   "--host", "models.acme.gov", "--json")[0] == 0
    [row] = _sbx_custom_table(tmp_path)
    assert (row["env"], row["targets"]) == ("ACME_KEY", ["models.acme.gov"])
    # --accept-unconfirmed is msb-only: refused before anything changes.
    rc, doc, _out, _err = _invoke_full(capsys, "--backend", "sbx", "provider-credential", "rm", "acme",
                                       "--accept-unconfirmed", "x", "--json")
    assert rc == 1 and doc["error"]["code"] == "unsupported_capability"
    assert provider_creds.get_binding("acme") is not None and len(_sbx_custom_table(tmp_path)) == 1
    calls: list = []
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        calls.append(list(argv))
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    rc, doc, _out, err = _invoke_full(capsys, "--backend", "sbx", "provider-credential", "rm", "acme", "--json")
    assert rc == 0 and doc["data"] == {"provider": "acme", "removed": True, "credential_removed": True}
    assert ["secret", "rm", "--placeholder", row["placeholder"], "-f"] in calls
    assert _sbx_custom_table(tmp_path) == []
    assert provider_creds.get_binding("acme") is None
    assert "warning" not in err


def test_provider_credential_rm_on_sbx_warns_only_when_a_custom_secret_remains(monkeypatch, tmp_path, capsys):
    _sbx_env(monkeypatch, tmp_path, version="0.51.0")
    # A failed removal keeps the binding and warns.
    monkeypatch.setattr(sys, "stdin", io.StringIO("v-1\n"))
    assert _invoke(capsys, "--backend", "sbx", "provider-credential", "set", "acme", "ACME_KEY",
                   "--host", "models.acme.gov", "--json")[0] == 0
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret rm")
    rc, doc, _out, err = _invoke_full(capsys, "--backend", "sbx", "provider-credential", "rm", "acme", "--json")
    assert rc == 1 and provider_creds.get_binding("acme") is not None
    assert "may still be injected" in err and "$ACME_KEY" in err and "acq secret rm PLACEHOLDER" in err
    assert len(_sbx_custom_table(tmp_path)) == 1
    # A same-KEY_ENV entry for another host is not this binding's, so it is not
    # removed; rm fails (never a silent success) and keeps the binding.
    monkeypatch.delenv("ACQ_SBX_STUB_FAIL")
    (tmp_path / "sbx-home" / ".docker-sbx" / "custom-secrets.json").unlink()
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps(
        [{"scope": "global", "env": "ACME_KEY", "placeholder": "sbx-cs-elsewhere", "targets": ["models.other.gov"]}]
    ))
    rc, doc, _out, err = _invoke_full(capsys, "--backend", "sbx", "provider-credential", "rm", "acme", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert "may still be injected" in doc["error"]["message"] and "acq secret rm sbx-cs-elsewhere" in doc["error"]["remediation"]
    assert provider_creds.get_binding("acme") is not None
    from acq_py import sbx, secretstore

    assert sbx.custom_secret_placeholders(secretstore.GLOBAL, "ACME_KEY") == ["sbx-cs-elsewhere"]  # untouched
    assert not (tmp_path / "sbx-home" / ".docker-sbx" / "custom-secrets.json").exists()
    # Nothing listed for the KEY_ENV at all: nothing to warn about.
    provider_creds.set_binding("other", "OTHER_KEY", ["models.other.gov"])
    rc, doc, _out, err = _invoke_full(capsys, "--backend", "sbx", "provider-credential", "rm", "other", "--json")
    assert rc == 0 and doc["data"]["credential_removed"] is False and "warning" not in err


def test_provider_credential_rm_on_sbx_never_reports_removed_while_a_row_remains(monkeypatch, tmp_path, capsys):
    # A stored value exists, and the only ACME_KEY row targets a host the
    # binding no longer pins (re-pinned out of band). The row is skipped and the
    # stored value deleted, but $ACME_KEY is still injected: rm must not report
    # credential_removed: true or exit 0.
    from acq_py import secretstore

    _sbx_env(monkeypatch, tmp_path, version="0.51.0")
    provider_creds.set_binding("acme", "ACME_KEY", ["models.acme.gov"])
    secretstore.store(secretstore.key_for("acme"), "STORED-VALUE")
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps(
        [{"scope": "global", "env": "ACME_KEY", "placeholder": "sbx-cs-old", "targets": ["models.old.gov"]}]
    ))
    rc, doc, out, err = _invoke_full(capsys, "--backend", "sbx", "provider-credential", "rm", "acme", "--json")
    assert rc == 1 and doc["error"]["code"] == "unbind_failed"
    assert doc["error"]["message"].startswith("removed the stored 'acme' credential, but sbx still lists")
    assert "credential_removed: false" in doc["error"]["message"]
    assert "'acq secret rm sbx-cs-old'" in doc["error"]["remediation"]
    assert "STORED-VALUE" not in out + err
    assert provider_creds.get_binding("acme") is not None  # kept, so the removal can be retried


def test_provider_credential_set_and_rm_wait_for_the_provider_lock(monkeypatch, tmp_path, capsys):
    from acq_py import lock, secretstore

    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    provider_creds.set_binding("other", "OTHER_KEY", ["models.other.gov"])
    with lock.provider_credential_lock("acme"):
        monkeypatch.setattr(sys, "stdin", io.StringIO("LOCKED-OUT-VALUE\n"))
        rc, doc = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                          "--host", "models.acme.gov", "--json")
        assert rc == 1 and doc["error"]["code"] == "timeout"
        assert provider_creds.get_binding("acme") is None and secretstore.resolve("acme") is None
        provider_creds.set_binding("acme", "ACME_KEY", ["models.acme.gov"])
        rc, doc = _invoke(capsys, "provider-credential", "rm", "acme", "--json")
        assert rc == 1 and doc["error"]["code"] == "timeout"
        assert provider_creds.get_binding("acme") is not None
        # Another provider is not held up.
        rc, doc = _invoke(capsys, "provider-credential", "rm", "other", "--json")
        assert rc == 0
    rc, doc = _invoke(capsys, "provider-credential", "rm", "acme", "--json")
    assert rc == 0


def test_provider_credential_set_and_rm_wait_for_a_create_reading_the_store(monkeypatch, tmp_path, capsys):
    # The credential is a global value a create may be binding into a new guest.
    from acq_py import lock, secretstore

    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.3")
    with lock.secret_store_lock(shared=True):
        monkeypatch.setattr(sys, "stdin", io.StringIO("LOCKED-OUT-VALUE\n"))
        rc, doc = _invoke(capsys, "--backend", "msb", "provider-credential", "set", "acme", "ACME_KEY",
                          "--host", "models.acme.gov", "--json")
        assert rc == 1 and doc["error"]["code"] == "timeout"
        assert "secret-store lock" in doc["error"]["message"]
        assert provider_creds.get_binding("acme") is None and secretstore.resolve("acme") is None
        provider_creds.set_binding("acme", "ACME_KEY", ["models.acme.gov"])
        rc, doc = _invoke(capsys, "provider-credential", "rm", "acme", "--json")
        assert rc == 1 and doc["error"]["code"] == "timeout"
        assert provider_creds.get_binding("acme") is not None


def test_provider_credential_min_reader_fails_closed(monkeypatch, tmp_path, capsys):
    # A record whose min_reader exceeds this reader is refused, not misread.
    _env(monkeypatch, tmp_path)
    _write_binding_record(
        tmp_path, "usai",
        {"schema": 1, "min_reader": 2, "provider": "usai", "key_env": "USAI_API_KEY", "hosts": ["api.gsa.usai.gov"]},
    )

    rc, doc = _invoke(capsys, "provider-credential", "rm", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


def test_provider_credential_bool_schema_fails_closed(monkeypatch, tmp_path, capsys):
    # A bool schema (True == 1 in Python) must NOT be misread as schema 1.
    _env(monkeypatch, tmp_path)
    _write_binding_record(
        tmp_path, "usai",
        {"schema": True, "provider": "usai", "key_env": "USAI_API_KEY", "hosts": ["api.gsa.usai.gov"]},
    )

    rc, doc = _invoke(capsys, "provider-credential", "rm", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


def test_provider_credential_set_no_value_validation_failed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_provider_credential_set_invalid_provider(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "BAD_ID!", "KEY_ENV", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_provider_credential_set_invalid_host(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "https://evil.example.com", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_provider_credential_set_reserved_key_env(monkeypatch, tmp_path, capsys):
    # A provider cannot claim a reserved env var owned by a different service.
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "opencode-go", "GITHUB_TOKEN", "--host", "api.example.gov", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_provider_credential_set_missing_host(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_provider_credential_sbx(monkeypatch, tmp_path, capsys):
    # sbx `secret set-custom --value-stdin` (v0.51.0) reads the value on stdin,
    # so `provider-credential set` succeeds and records the binding host-side,
    # reporting provider/key_env/hosts/source_layer — never a value.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "sbx", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 0
    assert doc["data"] == {
        "provider": "usai",
        "key_env": "USAI_API_KEY",
        "hosts": ["api.gsa.usai.gov"],
        "source_layer": "provider-credentials",
    }
    # The value never appears in the success envelope.
    assert "value-1" not in json.dumps(doc)


def test_provider_credential_sbx_version_floor(monkeypatch, tmp_path, capsys):
    # `provider-credential set` on sbx requires sbx >= 0.51.0 (the version that
    # added `secret set-custom --value-stdin`). An older sbx fails closed with
    # backend_version_unsupported BEFORE the backend is invoked, so the value is
    # never read, never placed on argv, never in output.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.50.1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "sbx", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "backend_version_unsupported"
    assert "value-1" not in json.dumps(doc)


def test_provider_credential_env_layer_reported(monkeypatch, tmp_path, capsys):
    # The per-invocation ACQ_PROVIDER_CREDENTIAL_BINDINGS layer is reported with
    # source_layer "env"; a malformed entry fails closed.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "opencode-go=OPENCODE_GO_API_KEY@models.example.gov")

    rc, doc = _invoke(capsys, "provider-credential", "ls", "--json")
    assert rc == 0
    assert doc["data"]["bindings"] == [
        {
            "provider": "opencode-go",
            "key_env": "OPENCODE_GO_API_KEY",
            "hosts": ["models.example.gov"],
            "source_layer": "env",
        }
    ]

    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "malformed-token-without-equals")
    rc, doc = _invoke(capsys, "provider-credential", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


# ---------------------------------------------------------------------------
# github-scope (ADR-0013): detect the workspace's repos, refuse several owners,
# store the token for one sandbox only. Workspaces are temporary git repos.
# ---------------------------------------------------------------------------

def _sbx_env(monkeypatch, tmp_path, version="0.39.0"):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", version)
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))


def _one_owner_ws(monkeypatch, tmp_path):
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "app", "https://github.com/alpha/app.git")
    git_repo(monkeypatch, ws / "lib", "git@github.com:alpha/lib.git")
    return ws


def test_github_scope_token_never_exposed(monkeypatch, tmp_path, capsys):
    # On sbx the token travels only as the backend child's stdin, never argv or
    # output, and the acq store holds it under the sandbox scope.
    from acq_py import sbx, secretstore

    _sbx_env(monkeypatch, tmp_path)
    ws = _one_owner_ws(monkeypatch, tmp_path)
    captured: list = []
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        captured.append((list(argv), input_text))
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ghp_FAKE-SCOPED-TOKEN\n"))

    rc = cli.main(["--backend", "sbx", "github-scope", "mybox", str(ws), "--json"])
    out, err = capsys.readouterr()

    assert rc == 0, out
    feeds = [(argv, text) for argv, text in captured if argv[:2] == ["secret", "set"]]
    assert feeds == [(["secret", "set", "--sandbox", "mybox", "github"], "ghp_FAKE-SCOPED-TOKEN")]
    assert all("ghp_FAKE-SCOPED-TOKEN" not in " ".join(argv) for argv, _ in captured)
    assert "ghp_FAKE-SCOPED-TOKEN" not in out
    assert "ghp_FAKE-SCOPED-TOKEN" not in err
    assert secretstore.get(secretstore.key_for("github", "mybox")) == "ghp_FAKE-SCOPED-TOKEN"
    assert secretstore.get(secretstore.key_for("github")) is None


def test_github_scope_records_per_sandbox(monkeypatch, tmp_path, capsys):
    _sbx_env(monkeypatch, tmp_path)
    ws = _one_owner_ws(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("token\n"))

    rc, doc = _invoke(capsys, "--backend", "sbx", "github-scope", "mybox", str(ws), "--json")
    assert rc == 0
    # It reports what the token was requested for, never that it was narrowed.
    assert doc["data"] == {
        "sandbox": "mybox", "backend": "sbx", "scope": "sandbox", "owner": "alpha",
        "repos": ["alpha/app", "alpha/lib"], "stored": True,
    }

    # The scope is recorded host-side (ADR-0041m), never carrying a value.
    record = provider_creds.github_scope_read("sbx", "mybox")
    assert record is not None
    assert record["sandbox"] == "mybox"
    assert record["owner"] == "alpha" and record["repos"] == ["alpha/app", "alpha/lib"]
    assert "scoped" not in record
    assert "token" not in record
    assert "value" not in record


def test_github_scope_no_value_validation_failed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    ws = _one_owner_ws(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    rc, doc = _invoke(capsys, "--backend", "msb", "github-scope", "mybox", str(ws), "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    # The remediation carries the pre-filled token URL for the one owner.
    assert gitrepos.pat_url("alpha", "mybox") in doc["error"]["remediation"]


def test_github_scope_multiline_token_refused(monkeypatch, tmp_path, capsys):
    from acq_py import secretstore

    _env(monkeypatch, tmp_path)
    ws = _one_owner_ws(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("tok\tSECRET-TAIL\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "github-scope", "mybox", str(ws), "--json")
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert "SECRET-TAIL" not in json.dumps(doc)
    assert not secretstore.exists("github", "mybox")


def test_github_scope_sbx(monkeypatch, tmp_path, capsys):
    # github-scope is a common capability: the per-sandbox scope is recorded
    # host-side for the sbx backend too (ADR-0013).
    _sbx_env(monkeypatch, tmp_path)
    ws = _one_owner_ws(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("token\n"))

    rc, doc = _invoke(capsys, "--backend", "sbx", "github-scope", "mybox", str(ws), "--json")
    assert rc == 0
    assert doc["data"]["backend"] == "sbx"
    assert doc["data"]["scope"] == "sandbox"
    record = provider_creds.github_scope_read("sbx", "mybox")
    assert record is not None
    assert record["sandbox"] == "mybox"


def test_github_scope_msb_stores_for_the_sandbox_only(monkeypatch, tmp_path, capsys):
    # msb used to refuse github-scope; it now takes the same path as
    # `acq secret set SANDBOX github` (acq store, sandbox scope).
    from acq_py import secretstore

    _env(monkeypatch, tmp_path)
    ws = _one_owner_ws(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ghp_MSB-SCOPED\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "github-scope", "mybox", str(ws), "--json")
    assert rc == 0, doc
    assert doc["data"]["stored"] is True and doc["data"]["owner"] == "alpha"
    assert secretstore.get(secretstore.key_for("github", "mybox")) == "ghp_MSB-SCOPED"
    assert secretstore.get(secretstore.key_for("github")) is None


def test_github_scope_multi_owner_refused_before_reading(monkeypatch, tmp_path, capsys):
    from acq_py import secretstore

    _env(monkeypatch, tmp_path)
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "a", "https://github.com/alpha/a.git")
    git_repo(monkeypatch, ws / "b", "https://github.com/beta/b.git")
    stdin = io.StringIO("ghp_SHOULD-NOT-BE-READ\n")
    monkeypatch.setattr(sys, "stdin", stdin)

    rc, doc = _invoke(capsys, "--backend", "msb", "github-scope", "mybox", str(ws), "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert "alpha/a" in doc["error"]["message"] and "beta/b" in doc["error"]["message"]
    assert stdin.tell() == 0  # the token was never read
    assert not secretstore.exists("github", "mybox")
    assert provider_creds.github_scope_read("msb", "mybox") is None


def test_github_scope_no_repos_is_a_noop(monkeypatch, tmp_path, capsys):
    from acq_py import secretstore

    _env(monkeypatch, tmp_path)
    ws = tmp_path / "ws"
    git_repo(monkeypatch, ws / "local", None)  # a repo with no GitHub remote
    (ws / "plain").mkdir()
    stdin = io.StringIO("ghp_SHOULD-NOT-BE-READ\n")
    monkeypatch.setattr(sys, "stdin", stdin)

    rc, doc = _invoke(capsys, "--backend", "msb", "github-scope", "mybox", str(ws), "--json")
    assert rc == 0
    assert doc["data"] == {"sandbox": "mybox", "backend": "msb", "scope": "none", "repos": [], "stored": False}
    assert stdin.tell() == 0
    assert not secretstore.exists("github", "mybox")
    assert provider_creds.github_scope_read("msb", "mybox") is None


def test_github_scope_human_guidance_has_the_pat_url(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    ws = _one_owner_ws(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ghp_HUMAN-TOKEN\n"))

    rc = cli.main(["--backend", "msb", "github-scope", "mybox", str(ws)])
    out, err = capsys.readouterr()
    assert rc == 0, err
    assert gitrepos.pat_url("alpha", "mybox") in err
    assert "alpha/app" in err and "alpha/lib" in out
    assert "ghp_HUMAN-TOKEN" not in out + err


# ---------------------------------------------------------------------------
# usai-rotate-api-key (rotation itself is covered in test_rotation.py)
# ---------------------------------------------------------------------------

def test_rotate_no_value_validation_failed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    rc, doc = _invoke(capsys, "--backend", "msb", "usai-rotate-api-key", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
