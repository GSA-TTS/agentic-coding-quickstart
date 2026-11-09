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

import pytest

from acq_py import cli


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
    from acq_py.secretstore import GLOBAL, Scope

    # Flag form -> global scope + one service token.
    assert cli._parse_secret_scope_service(True, ["usai"]) == (GLOBAL, "usai")
    # Positional form -> sandbox scope + service.
    assert cli._parse_secret_scope_service(False, ["mybox", "github"]) == (Scope("mybox"), "github")
    # A sandbox literally named `global` is a sandbox scope, never the global one.
    scope, _ = cli._parse_secret_scope_service(False, ["global", "github"])
    assert scope == Scope("global") and not scope.is_global and scope != GLOBAL
    # Scope-less set is dropped (ADR-0038m §48): a lone token is not a valid shape.
    assert cli._parse_secret_scope_service(False, ["usai"]) == (None, None)
    assert cli._parse_secret_scope_service(True, []) == (None, None)
    # `secret ls` scope filter is optional.
    assert cli._parse_secret_ls_scope(False, []) == (None, True)
    assert cli._parse_secret_ls_scope(True, []) == (GLOBAL, True)
    assert cli._parse_secret_ls_scope(False, ["mybox"]) == (Scope("mybox"), True)
    assert cli._parse_secret_ls_scope(False, ["global"]) == (Scope("global"), True)
    assert cli._parse_secret_ls_scope(False, ["a", "b"]) == (None, False)


# ---------------------------------------------------------------------------
# The backend-neutral seam over the acq secret store (shared with Bash).
# ---------------------------------------------------------------------------

def _store_dir():
    import os
    from pathlib import Path

    return Path(os.environ["ACQ_SECRET_STORE_DIR"])


def _spy_sbx(monkeypatch):
    from acq_py import sbx

    calls: list[list[str]] = []
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        calls.append(list(argv))
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    return calls


def test_secret_set_writes_the_acq_store_only_when_the_backend_accepts(monkeypatch, tmp_path, capsys):
    # sbx accepts: the value lands in the acq store, then sbx is fed.
    _env_sbx(monkeypatch, tmp_path)
    calls = _spy_sbx(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TOP-SECRET-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 0 and doc["data"] == {"scope": "global", "service": "usai", "value_state": "set"}
    assert (_store_dir() / "acq.usai").read_bytes() == b"TOP-SECRET-VALUE"
    assert ["secret", "set", "usai"] in calls
    # sbx already holds the scoped secret: refused before the store is touched.
    _env_sbx(monkeypatch, tmp_path, secrets={"box": {"github": "set"}})
    monkeypatch.setattr(sys, "stdin", io.StringIO("NEW-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "box", "github", "--json")
    assert rc == 1 and "already exists" in doc["error"]["message"]
    assert not (_store_dir() / "acq.box.github").exists()
    # msb declares secret-write unsupported (until its binding path lands):
    # refused without storing anything.
    _env_msb(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("MSB-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "msb", "secret", "set", "mybox", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "unsupported_capability"
    assert sorted(p.name for p in _store_dir().iterdir()) == ["acq.usai"]


def test_sandbox_named_global_is_a_sandbox_scope(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path)
    calls = _spy_sbx(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("GH-TOKEN-VALUE\n"))
    rc = cli.main(["--backend", "sbx", "secret", "set", "global", "github"])
    out, _ = capsys.readouterr()
    assert rc == 0
    assert out == "stored secret 'github' (sandbox 'global')\n"
    assert (_store_dir() / "acq.global.github").exists()
    assert not (_store_dir() / "acq.github").exists()
    assert ["secret", "set", "--sandbox", "global", "github"] in calls


def test_secret_set_dash_or_unsafe_service_refused_before_any_access(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path)
    calls = _spy_sbx(monkeypatch)
    for argv in (["mybox", "-dash"], ["-g", "a.b"], ["-g", "a b"], ["my.box", "github"], ["-x", "github"]):
        monkeypatch.setattr(sys, "stdin", io.StringIO("SHOULD-NOT-STORE\n"))
        rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", *argv, "--json")
        assert rc in (1, 2), argv
        assert doc["error"]["code"] in ("validation_failed", "usage"), argv
    assert calls == []
    assert not _store_dir().exists()
    rc = cli.main(["--backend", "sbx", "secret", "has", "mybox", "-dash"])
    assert rc == 1 and calls == []


@pytest.mark.parametrize("value", ["SECRETA\nSECRETB\n", "SECRETA\tSECRETB\n", "acq-dpapi-v1\n"])
def test_secret_set_unstorable_value_refused_and_never_echoed(monkeypatch, tmp_path, capsys, value):
    _env_sbx(monkeypatch, tmp_path)
    calls = _spy_sbx(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO(value))
    rc = cli.main(["--backend", "sbx", "secret", "set", "-g", "usai", "--json"])
    out, err = capsys.readouterr()
    assert rc == 1 and json.loads(out)["error"]["code"] == "validation_failed"
    assert "SECRETA" not in out + err and "SECRETB" not in out + err
    assert calls == [] and not _store_dir().exists()


def test_secret_set_host_env_validation(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path)
    cases = [
        (["-g", "svc", "--host", "api.example.gov"], "needs --env"),
        (["-g", "svc", "--env", "SVC_KEY"], "needs --host"),
        (["-g", "svc", "--host", "api.example.gov", "--env", "1BAD"], "invalid env var name"),
        (["-g", "svc", "--host", "bad host", "--env", "SVC_KEY"], "invalid --host"),
        (["-g", "svc", "--host=a.gov,", "--env=SVC_KEY"], "invalid --host"),
    ]
    for argv, needle in cases:
        monkeypatch.setattr(sys, "stdin", io.StringIO("VALUE-1\n"))
        rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", *argv, "--json")
        assert rc == 1 and doc["error"]["code"] == "validation_failed", argv
        assert needle in doc["error"]["message"], argv
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "svc", "--host", "--json")
    assert rc == 2
    assert not _store_dir().exists()


def test_secret_set_custom_endpoint_on_sbx_refused_before_storing(monkeypatch, tmp_path, capsys):
    # sbx needs set-custom for a custom endpoint, which the adapter does not
    # drive yet: refused up front instead of binding to the wrong endpoint.
    _env_sbx(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", io.StringIO("GL-TOKEN\n"))
    rc, doc = _invoke(
        capsys, "--backend", "sbx", "secret", "set", "-g", "gitlab", "--host", "workshop.cloud.gov", "--env", "GITLAB_TOKEN", "--json"
    )
    assert rc == 1 and doc["error"]["code"] == "unsupported_capability"
    assert not _store_dir().exists()


def test_secret_set_records_the_endpoint_sidecar(monkeypatch, tmp_path, capsys):
    # The neutral layer persists host/env for any backend that accepts them.
    from acq_py import sbx

    _env_sbx(monkeypatch, tmp_path)
    fed: list = []
    monkeypatch.setattr(sbx, "secret_preflight", lambda *a: None)
    monkeypatch.setattr(sbx, "secret_feed", lambda *a: fed.append(a))
    monkeypatch.setattr(sys, "stdin", io.StringIO("GL-TOKEN\n"))
    rc = cli.main(
        ["--backend", "sbx", "secret", "set", "mybox", "gitlab", "--host", "workshop.cloud.gov", "--host", "alt.cloud.gov",
         "--env", "GITLAB_TOKEN", "--json"]
    )
    capsys.readouterr()
    assert rc == 0
    assert (_store_dir() / "meta" / "acq.mybox.gitlab").read_bytes() == b"workshop.cloud.gov,alt.cloud.gov\tGITLAB_TOKEN\n"
    assert (_store_dir() / "acq.mybox.gitlab").read_bytes() == b"GL-TOKEN"
    assert fed[0][1:] == ("gitlab", "GL-TOKEN", "workshop.cloud.gov,alt.cloud.gov", "GITLAB_TOKEN")
    # --host alone works for a service with a known env var.
    monkeypatch.setattr(sys, "stdin", io.StringIO("GH-TOKEN\n"))
    assert cli.main(["--backend", "sbx", "secret", "set", "-g", "github", "--host", "ghe.example.gov"]) == 0
    assert (_store_dir() / "meta" / "acq.github").read_bytes() == b"ghe.example.gov\tGITHUB_TOKEN\n"


def test_secret_set_feed_failure_reports_the_partial_state(monkeypatch, tmp_path, capsys):
    from acq_py import sbx

    _env_sbx(monkeypatch, tmp_path)

    def boom(*_a, **_k):
        raise sbx.SbxError("failure", "could not feed secret 'usai' to sbx", "check backend logs and retry")

    monkeypatch.setattr(sbx, "secret_feed", boom)
    monkeypatch.setattr(sys, "stdin", io.StringIO("FEED-VALUE\n"))
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "set", "-g", "usai", "--json")
    assert rc == 1
    assert doc["error"]["message"].startswith("stored 'usai' in the acq secret store, but ")
    assert "FEED-VALUE" not in json.dumps(doc)
    assert (_store_dir() / "acq.usai").exists()


def test_secret_rm_store_only_entry(monkeypatch, tmp_path, capsys):
    from acq_py import secretstore

    _env_sbx(monkeypatch, tmp_path)
    calls = _spy_sbx(monkeypatch)
    secretstore.set_secret("gitlab", "box", "GL", "workshop.cloud.gov", "GITLAB_TOKEN")
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "box", "gitlab", "--json")
    assert rc == 0 and doc["data"] == {"scope": "box", "service": "gitlab", "value_state": "unset"}
    assert not secretstore.exists("gitlab", "box")
    assert secretstore.meta_resolve_exact("gitlab", "box") is None
    assert not any(c[:2] == ["secret", "rm"] for c in calls)  # not in sbx: nothing to unbind


def test_secret_rm_both_and_exact_scope(monkeypatch, tmp_path, capsys):
    from acq_py import secretstore

    _env_sbx(monkeypatch, tmp_path, secrets={"global": {"usai": "set"}})
    calls = _spy_sbx(monkeypatch)
    secretstore.set_secret("usai", None, "U")
    # A sandbox scope does not fall back to the global entry for removal.
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "otherbox", "usai", "--json")
    assert rc == 1 and doc["error"]["code"] == "secret_missing"
    rc, _ = _invoke(capsys, "--backend", "sbx", "secret", "rm", "-g", "usai", "--json")
    assert rc == 0
    assert ["secret", "rm", "usai", "-f"] in calls
    assert not secretstore.has("usai")


def test_secret_has_rejects_unsafe_names_silently(monkeypatch, tmp_path, capsys):
    _env_sbx(monkeypatch, tmp_path)
    rc = cli.main(["--backend", "sbx", "secret", "has", "-g", "a.b", "--json"])
    out, err = capsys.readouterr()
    assert rc == 1 and out == "" and "invalid service name" in err


def test_tty_read_uses_no_echo_and_refuses_an_echoing_fallback(monkeypatch):
    import getpass

    from acq_py.commands import common

    class _Tty(io.StringIO):
        def isatty(self):
            return True

    seen = {}

    def fake_getpass(prompt, stream=None):
        seen["prompt"] = prompt
        return "TYPED-SECRET"

    monkeypatch.setattr(sys, "stdin", _Tty("PIPED-NOT-USED\n"))
    monkeypatch.setattr(getpass, "getpass", fake_getpass)
    assert common._read_secret_value("Enter USAi API key: ") == "TYPED-SECRET"
    assert seen["prompt"] == "Enter USAi API key: "

    def echoing_fallback(prompt, stream=None):
        import warnings

        warnings.warn("Can not control echo on the terminal.", getpass.GetPassWarning, stacklevel=2)
        raise AssertionError("must not read after the echo warning")

    monkeypatch.setattr(getpass, "getpass", echoing_fallback)
    with pytest.raises(common.SecretInputError) as info:
        common._read_secret_value()
    assert info.value.code == "validation_failed"


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX pty")
def test_secret_typed_at_a_terminal_is_not_echoed(tmp_path):
    """Drive the real CLI on a pseudo-terminal: the prompt shows, the typed
    value never comes back on the terminal, and the store holds it."""
    import os
    import pty
    import select
    import time

    store = _store_dir()
    env = dict(os.environ, ACQ_SBX_BIN="__stub__", ACQ_SBX_VERSION="0.39.0", ACQ_SBX_INSTALLED="1",
               ACQ_MSB_INSTALLED="0", ACQ_STATE_DIR=str(tmp_path / "state"), SBX_HOME=str(tmp_path / "sbx"))
    pid, fd = pty.fork()
    if pid == 0:  # child: the pty is its controlling terminal and stdin
        os.execvpe(sys.executable, [sys.executable, "-m", "acq_py", "--backend", "sbx", "secret", "set", "-g", "usai"], env)
    output = b""

    def pump(until: bytes, deadline: float) -> None:
        nonlocal output
        while until not in output and time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    return
                if not chunk:
                    return
                output += chunk

    pump(b"Enter USAi API key: ", time.monotonic() + 60)
    assert b"Enter USAi API key: " in output, output
    os.write(fd, b"PTY-TYPED-SECRET\n")
    pump(b"stored secret", time.monotonic() + 60)
    _, status = os.waitpid(pid, 0)
    pump(b"\0", time.monotonic() + 1)
    os.close(fd)
    assert os.waitstatus_to_exitcode(status) == 0, output
    assert b"PTY-TYPED-SECRET" not in output
    assert (store / "acq.usai").read_bytes() == b"PTY-TYPED-SECRET"


# ---------------------------------------------------------------------------
# Review follow-ups: undecodable input, rm ordering, Git Bash/mintty.
# ---------------------------------------------------------------------------

@pytest.mark.skipif(sys.platform == "win32", reason="POSIX locales")
@pytest.mark.parametrize("locale", ["C.UTF-8", "C"])
def test_non_utf8_secret_is_refused_without_a_traceback_or_its_bytes(tmp_path, locale):
    import os
    import subprocess

    env = dict(os.environ, ACQ_SBX_BIN="__stub__", ACQ_SBX_VERSION="0.39.0", ACQ_SBX_INSTALLED="1",
               ACQ_MSB_INSTALLED="0", ACQ_STATE_DIR=str(tmp_path / "state"), SBX_HOME=str(tmp_path / "sbx"),
               LC_ALL=locale, LANG=locale)
    env.pop("PYTHONUTF8", None)
    env.pop("PYTHONIOENCODING", None)
    proc = subprocess.run(
        [sys.executable, "-m", "acq_py", "--backend", "sbx", "secret", "set", "-g", "usai", "--json"],
        input=b"SECRET\xffTAIL\n", capture_output=True, env=env, timeout=120, check=False,
    )
    assert proc.returncode == 1, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["error"] == {**doc["error"], "code": "validation_failed", "message": "the secret value is not valid UTF-8"}
    both = proc.stdout + proc.stderr
    assert b"Traceback" not in both
    for leak in (b"\xff", b"\\xff", b"0xff", "ÿ".encode(), b"position", b"SECRET", b"TAIL"):
        assert leak not in both, leak
    assert not _store_dir().exists()


def test_undecodable_values_never_reach_the_store(monkeypatch):
    import getpass

    from acq_py import secretstore
    from acq_py.commands import common

    assert secretstore.value_problem("ab\udcffcd") == "the secret value is not valid UTF-8"

    class _Tty(io.StringIO):
        def isatty(self):
            return True

    monkeypatch.setattr(sys, "stdin", _Tty(""))
    monkeypatch.setattr(getpass, "getpass", lambda prompt, stream=None: "ab\udcffcd")
    with pytest.raises(common.SecretInputError) as info:
        common._read_secret_value()
    assert info.value.message == "the secret value is not valid UTF-8"

    def undecodable(prompt, stream=None):
        raise UnicodeDecodeError("utf-8", b"SECRET\xff", 6, 7, "invalid start byte")

    monkeypatch.setattr(getpass, "getpass", undecodable)
    with pytest.raises(common.SecretInputError) as info:
        common._read_secret_value()
    assert "SECRET" not in info.value.message and "\\xff" not in info.value.message


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX environment bytes")
def test_import_refuses_a_non_utf8_environment_value(tmp_path):
    import os
    import subprocess

    env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_TOKEN", "GH_TOKEN", "GITLAB_TOKEN")}
    env["USAI_API_KEY"] = "SECRET\udcffTAIL"  # encodes back to the raw 0xff byte
    proc = subprocess.run(
        [sys.executable, "-m", "acq_py", "secret", "import", "--all", "--json"],
        stdin=subprocess.DEVNULL, capture_output=True, env=env, timeout=120, check=False,
    )
    assert proc.returncode == 0, proc.stderr
    doc = json.loads(proc.stdout)
    assert doc["data"]["results"] == [
        {"service": "usai", "source_env": "USAI_API_KEY", "outcome": "refused", "reason": "unstorable"}
    ]
    assert b"SECRET" not in proc.stdout + proc.stderr and b"Traceback" not in proc.stderr
    assert not _store_dir().exists()


def test_secret_rm_keeps_the_store_when_the_backend_unbind_fails(monkeypatch, tmp_path, capsys):
    # The backend is unbound first; if that fails, the store value and its
    # endpoint sidecar must survive so the user can retry the removal.
    from acq_py import sbx, secretstore

    _env_sbx(monkeypatch, tmp_path, secrets={"box": {"gitlab": "set"}})
    secretstore.set_secret("gitlab", "box", "GL-VALUE", "workshop.cloud.gov", "GITLAB_TOKEN")

    def refuse(*_a):
        raise sbx.SbxError("failure", "could not remove secret 'gitlab' for sandbox 'box'", "check backend logs and retry")

    monkeypatch.setattr(sbx, "secret_unbind", refuse)
    rc, doc = _invoke(capsys, "--backend", "sbx", "secret", "rm", "box", "gitlab", "--json")
    assert rc == 1 and doc["error"]["code"] == "failure"
    assert secretstore.resolve("gitlab", "box") == "GL-VALUE"
    assert secretstore.meta_resolve_exact("gitlab", "box") == ("workshop.cloud.gov", "GITLAB_TOKEN")


def test_mintty_pipe_names():
    from acq_py.commands import common

    assert common._is_mintty_pipe_name("\\msys-1888ae32e00d56aa-pty0-from-master")
    assert common._is_mintty_pipe_name("\\cygwin-e022582115c10879-pty3-from-master")
    assert not common._is_mintty_pipe_name("\\msys-1888ae32e00d56aa-pty0-to-master")
    assert not common._is_mintty_pipe_name("\\Win32Pipes.0000123c.00000002")
    assert not common._is_mintty_pipe_name("\\msys-1888ae32e00d56aa-pipe-0x1")
    if sys.platform != "win32":
        assert common._stdin_is_mintty() is False


def test_mintty_stdin_warns_that_input_is_visible_and_reads_one_line(monkeypatch, capsys):
    from acq_py.commands import common

    monkeypatch.setattr(common, "_stdin_is_mintty", lambda: True)
    monkeypatch.setattr(sys, "stdin", io.StringIO("TYPED-VALUE\nlater input\n"))
    assert common._read_secret_value("Enter USAi API key: ") == "TYPED-VALUE"
    err = capsys.readouterr().err
    assert "Git Bash/mintty" in err and "will be visible" in err
    assert err.endswith("Enter USAi API key: ")
    assert "TYPED-VALUE" not in err
