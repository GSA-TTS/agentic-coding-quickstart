"""Tier-2 implementation tests for the secret verbs (ADR-0040m secret capabilities).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` backends. Contract
evidence lives only in the vector corpus (``test/vectors``); the stubs are an
internal test seam, never a secret. The paramount assertion is that no secret
VALUE ever appears in argv or output — it flows only as the backend child's stdin.

Reconciliation with the real CLIs (msb 0.7.11 / sbx 0.50.1):

* msb has NO standalone ``secret`` subcommand, so every secret verb fails closed
  with ``unsupported_capability`` (secrets on msb are per-sandbox ``--secret
  ENV@HOST`` bindings, a provider-credential concern).
* sbx HAS ``secret set/ls/rm``, so the secret verbs (and ``secret ls``) work on
  sbx, with the value on the child's stdin only.
"""

from __future__ import annotations

import io
import json
import sys

from acq_py import backends, cli


def _env_msb(monkeypatch, tmp_path):
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
    ):
        monkeypatch.delenv(name, raising=False)


def _env_sbx(monkeypatch, tmp_path, *, secrets=None):
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    for name in (
        "ACQ_BACKEND",
        "ACQ_SBX_STUB_CATALOG",
        "ACQ_SBX_STUB_SECRETS",
        "ACQ_SBX_STUB_SECRET_LS_RAW",
        "ACQ_SBX_STUB_FAIL",
    ):
        monkeypatch.delenv(name, raising=False)
    if secrets is not None:
        monkeypatch.setenv("ACQ_SBX_STUB_SECRETS", json.dumps(secrets))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out
    doc = json.loads(out) if out.strip() else None
    return rc, doc


# ---------------------------------------------------------------------------
# msb: every secret verb fails closed with unsupported_capability (no `secret`
# subcommand on the real msb).
# ---------------------------------------------------------------------------

def test_msb_secret_set_unsupported_value_never_in_argv_or_output(monkeypatch, tmp_path, capsys):
    _env_msb(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-VALUE\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json")
    out, err = capsys.readouterr()

    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"
    assert "TOP-SECRET-VALUE" not in out
    assert "TOP-SECRET-VALUE" not in err


def test_msb_secret_has_unsupported_silent_stdout(monkeypatch, tmp_path, capsys):
    _env_msb(monkeypatch, tmp_path)

    rc = cli.main(["--backend", "msb", "secret", "has", "-g", "usai"])
    out, err = capsys.readouterr()
    assert rc == 1
    assert out == ""
    assert "not supported" in err


def test_msb_secret_rm_unsupported(monkeypatch, tmp_path, capsys):
    _env_msb(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"


def test_msb_secret_ls_unsupported(monkeypatch, tmp_path, capsys):
    _env_msb(monkeypatch, tmp_path)

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"


# ---------------------------------------------------------------------------
# sbx: the secret verbs work (value on stdin only, never argv/output).
# ---------------------------------------------------------------------------

def test_sbx_secret_value_never_in_argv_or_output(monkeypatch, tmp_path, capsys):
    # The hard guarantee on the backend that stores secrets: a value appears ONLY
    # as the backend child's stdin, never argv/output.
    from acq_py import sbx

    _env_sbx(monkeypatch, tmp_path)
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


def test_sbx_secret_roundtrip_set_ls_has_rm(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 0
    assert doc["data"] == {"scope": "global", "service": "usai", "value_state": "set"}

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 0
    assert doc["data"]["secrets"] == [{"scope": "global", "service": "usai", "value_state": "set"}]

    rc, _ = _invoke(capsys, "--backend", "sbx", "secret", "has", "-g", "usai")
    assert rc == 0

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0
    assert doc["data"]["value_state"] == "unset"

    rc, _ = _invoke(capsys, "--backend", "sbx", "secret", "has", "-g", "usai")
    assert rc == 1


def test_sbx_secret_has_silent(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})

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


def test_sbx_secret_rm_missing_fails_closed(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "nope", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_missing"


def test_sbx_secret_ls_unreadable_fails_closed(monkeypatch, tmp_path, capsys):
    # ADR-0038m §48 drops inspection-failure-as-empty: a failed listing is a
    # secret_unreadable failure, not an empty result.
    _env_sbx(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret ls")

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_unreadable"


def test_sbx_secret_ls_bad_shape_fails_closed(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_SECRET_LS_RAW", '{"not":"a list"}')

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_unreadable"


def test_sbx_secret_ls_entry_bad_shape_fails_closed(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_SECRET_LS_RAW", '[{"scope":"global","service":"usai","value_state":"set"}, 123]')

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_unreadable"


def test_sbx_secret_rm_backend_error_not_secret_missing(monkeypatch, tmp_path, capsys):
    # A down backend is NOT "absent": `secret rm` must report the backend's
    # accurate code (backend_not_found here) and never delete, never secret_missing.
    _env_sbx(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", str(tmp_path / "definitely-missing-sbx"))
    # The version floor probes the same program and would refuse first; skip it
    # so the secret verb's own handling of an unanswering backend is exercised.
    monkeypatch.setattr(backends, "check_version", lambda spec: None)

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "backend_not_found"
    assert doc["error"]["code"] != "secret_missing"


# ---------------------------------------------------------------------------
# Common validation + value-fidelity (backend-independent).
# ---------------------------------------------------------------------------

def test_secret_set_no_value_validation_failed(monkeypatch, tmp_path, capsys):
    # Empty stdin is a validation failure (exit 1), not a usage error (exit 2).
    _env_msb(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_secret_set_whitespace_only_validation_failed(monkeypatch, tmp_path, capsys):
    _env_msb(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("   \n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_secret_value_trailing_newline_preserved(monkeypatch):
    # Trailing-newline fidelity: exactly one terminal newline is stripped; any
    # further trailing newlines are value content, not silently truncated.
    monkeypatch.setattr(sys, "stdin", io.StringIO("abc\n\n"))
    assert cli._read_secret_value() == "abc\n"

    monkeypatch.setattr(sys, "stdin", io.StringIO("abc\r"))
    assert cli._read_secret_value() == "abc\r"
    monkeypatch.setattr(sys, "stdin", io.StringIO("abc\r\n"))
    assert cli._read_secret_value() == "abc"


def test_secret_scope_parsing():
    # Flag form -> global scope + one service token.
    assert cli._parse_secret_scope_service(True, ["usai"]) == ("global", "usai")
    # Positional form -> sandbox scope + service.
    assert cli._parse_secret_scope_service(False, ["mybox", "github"]) == ("mybox", "github")
    # Scope-less set is dropped (ADR-0038m §48): a lone token is not a valid shape.
    assert cli._parse_secret_scope_service(False, ["usai"]) == (None, None)
    assert cli._parse_secret_scope_service(True, []) == (None, None)
    # `secret ls` scope filter is optional.
    assert cli._parse_secret_ls_scope(False, []) == (None, True)
    assert cli._parse_secret_ls_scope(True, []) == ("global", True)
    assert cli._parse_secret_ls_scope(False, ["mybox"]) == ("mybox", True)
    assert cli._parse_secret_ls_scope(False, ["a", "b"]) == (None, False)
