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
import sys

from acq_py import cli, msb, provider_creds


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


# ---------------------------------------------------------------------------
# provider-credential set / ls / rm
# ---------------------------------------------------------------------------

def test_provider_credential_value_never_in_argv_or_output(monkeypatch, tmp_path, capsys):
    # The hard guarantee: a provider credential VALUE appears only as the backend
    # child's stdin, never in the adapter's argv or in any stdout/stderr.
    _env(monkeypatch, tmp_path)
    captured: dict = {}
    real_run = msb._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["argv"] = list(argv)
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(msb, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-PROVIDER-KEY\n"))

    rc = cli.main(
        ["--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"]
    )
    out, err = capsys.readouterr()

    assert rc == 0
    assert captured["input_text"] == "TOP-SECRET-PROVIDER-KEY"
    assert "TOP-SECRET-PROVIDER-KEY" not in captured["argv"]
    assert "TOP-SECRET-PROVIDER-KEY" not in out
    assert "TOP-SECRET-PROVIDER-KEY" not in err


def test_provider_credential_set_ls_reports_binding_only(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 0
    assert doc["data"]["provider"] == "usai"
    assert doc["data"]["key_env"] == "USAI_API_KEY"
    assert doc["data"]["hosts"] == ["api.gsa.usai.gov"]
    assert doc["data"]["source_layer"] == "provider-credentials"
    # The value itself is never a field.
    assert "value" not in doc["data"]
    assert "value-1" not in json.dumps(doc)

    rc, doc = _invoke(capsys, "provider-credential", "ls", "--json")
    assert rc == 0
    assert doc["data"]["bindings"] == [
        {"provider": "usai", "key_env": "USAI_API_KEY", "hosts": ["api.gsa.usai.gov"], "source_layer": "provider-credentials"}
    ]
    # ls reports exactly the four non-secret fields, never a value or value_state.
    assert set(doc["data"]["bindings"][0]) == {"provider", "key_env", "hosts", "source_layer"}


def test_provider_credential_rm_semantics(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))
    rc, _ = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 0

    rc, doc = _invoke(capsys, "provider-credential", "rm", "usai", "--json")
    assert rc == 0
    assert doc["data"] == {"provider": "usai", "removed": True}

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


def test_provider_credential_set_newer_schema_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _write_binding_record(
        tmp_path, "usai",
        {"schema": 99, "provider": "usai", "key_env": "USAI_API_KEY", "hosts": ["api.gsa.usai.gov"]},
    )
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "msb", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 1
    assert doc["error"]["code"] == "state_schema_unsupported"


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
    # provider-credential set is a common capability: it runs against the sbx
    # adapter too, reporting the binding only and never the value (ADR-0040m).
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(
        capsys, "--backend", "sbx", "provider-credential", "set", "usai", "USAI_API_KEY", "--host", "api.gsa.usai.gov", "--json"
    )
    assert rc == 0
    assert doc["data"]["provider"] == "usai"
    assert doc["data"]["key_env"] == "USAI_API_KEY"
    assert doc["data"]["hosts"] == ["api.gsa.usai.gov"]
    assert "value" not in doc["data"]
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
# github-scope
# ---------------------------------------------------------------------------

def test_github_scope_token_never_exposed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    captured: dict = {}
    real_run = msb._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["argv"] = list(argv)
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(msb, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ghp_FAKE-SCOPED-TOKEN\n"))

    rc = cli.main(["--backend", "msb", "github-scope", "mybox", str(tmp_path), "--json"])
    out, err = capsys.readouterr()

    assert rc == 0
    assert captured["input_text"] == "ghp_FAKE-SCOPED-TOKEN"
    assert "ghp_FAKE-SCOPED-TOKEN" not in captured["argv"]
    assert "ghp_FAKE-SCOPED-TOKEN" not in out
    assert "ghp_FAKE-SCOPED-TOKEN" not in err


def test_github_scope_records_per_sandbox(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("token\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "github-scope", "mybox", str(tmp_path), "--json")
    assert rc == 0
    assert doc["data"] == {"sandbox": "mybox", "backend": "msb", "scoped": True}

    # The scope is recorded host-side (ADR-0041m), never carrying a value.
    record = provider_creds.github_scope_read("msb", "mybox")
    assert record is not None
    assert record["sandbox"] == "mybox"
    assert record["scoped"] is True
    assert "token" not in record
    assert "value" not in record


def test_github_scope_no_value_validation_failed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    rc, doc = _invoke(capsys, "--backend", "msb", "github-scope", "mybox", str(tmp_path), "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_github_scope_sbx(monkeypatch, tmp_path, capsys):
    # github-scope is a common capability: the per-sandbox scope is recorded
    # host-side for the sbx backend too (ADR-0013).
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setattr(sys, "stdin", io.StringIO("token\n"))

    rc, doc = _invoke(capsys, "--backend", "sbx", "github-scope", "mybox", str(tmp_path), "--json")
    assert rc == 0
    assert doc["data"]["backend"] == "sbx"
    assert doc["data"]["scoped"] is True
    record = provider_creds.github_scope_read("sbx", "mybox")
    assert record is not None
    assert record["sandbox"] == "mybox"


# ---------------------------------------------------------------------------
# usai-rotate-api-key
# ---------------------------------------------------------------------------

def test_rotate_key_never_in_argv_or_output(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    captured: dict = {}
    real_run = msb._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["argv"] = list(argv)
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(msb, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("NEW-ROTATED-KEY\n"))

    rc = cli.main(["--backend", "msb", "usai-rotate-api-key", "--json"])
    out, err = capsys.readouterr()

    assert rc == 0
    assert captured["input_text"] == "NEW-ROTATED-KEY"
    assert "NEW-ROTATED-KEY" not in captured["argv"]
    assert "NEW-ROTATED-KEY" not in out
    assert "NEW-ROTATED-KEY" not in err
    assert captured["argv"] == ["rotate"]


def test_rotate_fails_closed_unreachable(monkeypatch, tmp_path, capsys):
    # Seed the OLD key on DISK (not the env seam, which the stub prefers over
    # disk) so the assertion genuinely proves a failed rotation did NOT touch the
    # on-disk store. The file is written non-canonically (indent=2) so any
    # rewrite by the stub's `_save_secrets` (compact, sorted keys) is detectable.
    _env(monkeypatch, tmp_path)
    secrets_path = tmp_path / "msb-home" / ".microsandbox" / "secrets.json"
    secrets_path.parent.mkdir(parents=True, exist_ok=True)
    original_bytes = json.dumps({"global": {"usai": "set"}}, indent=2)
    secrets_path.write_text(original_bytes, encoding="utf-8")

    monkeypatch.setenv("ACQ_MSB_STUB_ROTATE", "unreachable")
    monkeypatch.setattr(sys, "stdin", io.StringIO("new-key\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "usai-rotate-api-key", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "provider_unreachable"

    # The old key on DISK was NOT replaced: the file is byte-identical (a failed
    # rotation leaves the old key in place, ADR-0012).
    assert secrets_path.read_text(encoding="utf-8") == original_bytes


def test_rotate_fails_closed_auth_failed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})
    monkeypatch.setenv("ACQ_MSB_STUB_ROTATE", "auth_failed")
    monkeypatch.setattr(sys, "stdin", io.StringIO("new-key\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "usai-rotate-api-key", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "provider_auth_failed"


def test_rotate_success_replaces_key(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})
    monkeypatch.setattr(sys, "stdin", io.StringIO("new-key\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "usai-rotate-api-key", "--json")
    assert rc == 0
    assert doc["data"] == {"provider": "usai", "key_env": "USAI_API_KEY", "rotated": True}
    assert "new-key" not in json.dumps(doc)


def test_rotate_no_value_validation_failed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    rc, doc = _invoke(capsys, "--backend", "msb", "usai-rotate-api-key", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_rotate_sbx(monkeypatch, tmp_path, capsys):
    # usai-rotate-api-key (key-rotate) is a common capability: it runs against the
    # sbx adapter too, reporting provider/key_env/rotated and never the new key.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setattr(sys, "stdin", io.StringIO("new-key\n"))

    rc, doc = _invoke(capsys, "--backend", "sbx", "usai-rotate-api-key", "--json")
    assert rc == 0
    assert doc["data"] == {"provider": "usai", "key_env": "USAI_API_KEY", "rotated": True}
    assert "new-key" not in json.dumps(doc)
