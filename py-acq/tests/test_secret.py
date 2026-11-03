"""Tier-2 implementation tests for the secret verbs (ADR-0040m secret capabilities).

Non-contract evidence (ADR-0039m): these reach into ``acq_py`` directly and drive
``cli.main`` in-process against the deterministic ``__stub__`` msb. Contract
evidence lives only in the vector corpus (``test/vectors``); the stub is an
internal test seam, never a secret. The paramount assertion here is that no secret
VALUE ever appears in argv or output — it flows only as the backend child's stdin.
"""

from __future__ import annotations

import io
import json
import sys

from acq_py import cli, msb


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
    ):
        monkeypatch.delenv(name, raising=False)
    if secrets is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_SECRETS", json.dumps(secrets))


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out
    doc = json.loads(out) if out.strip() else None
    return rc, doc


def test_secret_value_never_in_argv_or_output(monkeypatch, tmp_path, capsys):
    # The hard guarantee: a secret value appears ONLY as the backend child's stdin,
    # never in the adapter's argv or in any stdout/stderr (mutation-proof guard).
    _env(monkeypatch, tmp_path)
    captured: dict = {}
    real_run = msb._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["argv"] = list(argv)
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(msb, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-VALUE\n"))

    rc = cli.main(["--backend", "msb", "secret", "set", "-g", "usai", "--json"])
    out, err = capsys.readouterr()

    assert rc == 0
    assert captured["input_text"] == "TOP-SECRET-VALUE"
    assert "TOP-SECRET-VALUE" not in captured["argv"]
    assert "TOP-SECRET-VALUE" not in out
    assert "TOP-SECRET-VALUE" not in err


def test_secret_roundtrip_set_ls_has_rm(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("value-1\n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json")
    assert rc == 0
    assert doc["data"] == {"scope": "global", "service": "usai", "value_state": "set"}

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "ls", "--json")
    assert rc == 0
    assert doc["data"]["secrets"] == [{"scope": "global", "service": "usai", "value_state": "set"}]

    rc, _ = _invoke(capsys, "--backend", "msb", "secret", "has", "-g", "usai")
    assert rc == 0

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0
    assert doc["data"]["value_state"] == "unset"

    rc, _ = _invoke(capsys, "--backend", "msb", "secret", "has", "-g", "usai")
    assert rc == 1


def test_secret_has_silent(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})

    rc = cli.main(["--backend", "msb", "secret", "has", "-g", "usai"])
    out, err = capsys.readouterr()
    assert rc == 0
    assert out == ""
    assert err == ""

    rc = cli.main(["--backend", "msb", "secret", "has", "-g", "github"])
    out, err = capsys.readouterr()
    assert rc == 1
    assert out == ""
    assert err == ""


def test_secret_rm_missing_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "nope", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_missing"


def test_secret_ls_unreadable_fails_closed(monkeypatch, tmp_path, capsys):
    # ADR-0038m §48 drops inspection-failure-as-empty: a failed listing is a
    # secret_unreadable failure, not an empty result.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL", "secret ls")

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_unreadable"


def test_secret_ls_bad_shape_fails_closed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_SECRET_LS_RAW", '{"not":"a list"}')

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_unreadable"


def test_secret_set_no_value_validation_failed(monkeypatch, tmp_path, capsys):
    # Empty stdin is a validation failure (exit 1), not a usage error (exit 2):
    # the invocation is well-formed but supplies no storable value (ADR-0038m §1).
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_secret_set_whitespace_only_validation_failed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("   \n"))

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "set", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"


def test_secret_value_trailing_newline_preserved(monkeypatch, tmp_path, capsys):
    # Trailing-newline fidelity: exactly one terminal newline is stripped; any
    # further trailing newlines are value content, not silently truncated.
    _env(monkeypatch, tmp_path)
    captured: dict = {}
    real_run = msb._run

    def spy(argv, *, timeout=None, input_text=None):
        captured["input_text"] = input_text
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(msb, "_run", spy)
    monkeypatch.setattr(sys, "stdin", io.StringIO("abc\n\n"))

    rc = cli.main(["--backend", "msb", "secret", "set", "-g", "usai", "--json"])
    assert rc == 0
    assert captured["input_text"] == "abc\n"

    # A lone trailing \r (no preceding \n) is preserved, and a CRLF terminator is
    # stripped to the bare value.
    monkeypatch.setattr(sys, "stdin", io.StringIO("abc\r"))
    assert cli._read_secret_value() == "abc\r"
    monkeypatch.setattr(sys, "stdin", io.StringIO("abc\r\n"))
    assert cli._read_secret_value() == "abc"


def test_secret_rm_backend_error_not_secret_missing(monkeypatch, tmp_path, capsys):
    # A down backend is NOT "absent": `secret rm` must report the backend's
    # accurate code (backend_not_found here) and never delete, never secret_missing.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_BIN", str(tmp_path / "definitely-missing-msb"))

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "rm", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "backend_not_found"
    assert doc["error"]["code"] != "secret_missing"


def test_secret_has_backend_error_silent_stdout_stderr_diag(monkeypatch, tmp_path, capsys):
    # `secret has` on a backend that cannot answer: stdout stays silent and exit
    # is 1, but a stderr diagnostic distinguishes it from a true "absent".
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_BIN", str(tmp_path / "definitely-missing-msb"))

    rc = cli.main(["--backend", "msb", "secret", "has", "-g", "usai"])
    out, err = capsys.readouterr()
    assert rc == 1
    assert out == ""
    assert "msb backend CLI" in err


def test_secret_ls_entry_bad_shape_fails_closed(monkeypatch, tmp_path, capsys):
    # A wrong-shape *entry* (a list element that is not {scope, service, ...})
    # fails closed with secret_unreadable rather than being silently dropped.
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_SECRET_LS_RAW", '[{"scope":"global","service":"usai","value_state":"set"}, 123]')

    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "secret_unreadable"


def test_sbx_secret_unsupported(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")

    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "ls", "--json")
    assert rc == 1
    assert doc["error"]["code"] == "unsupported_capability"


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
