"""Tier-2 tests for ``acq secret import`` (parity with Bash ``acq_secret_import``).

``secret import`` copies known service tokens from the host environment into
the acq secret store and touches no backend. These drive ``cli.main``
in-process; the store is the conftest's throwaway file store. Byte-level parity
with the Bash CLI is in ``test_secretstore_bash.py``.
"""

from __future__ import annotations

import io
import json
import os
import sys
from pathlib import Path

import pytest

from acq_py import cli, secretstore

_TOKENS = ("USAI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "GITLAB_TOKEN", "ACQ_PROVIDER_CREDENTIAL_BINDINGS")


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in _TOKENS:
        monkeypatch.delenv(name, raising=False)
    # No backend is installed: import must not need one.
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))


def _store() -> Path:
    return Path(os.environ["ACQ_SECRET_STORE_DIR"])


def _run(capsys, *argv):
    rc = cli.main(["secret", "import", *argv, "--json"])
    out, err = capsys.readouterr()
    return rc, json.loads(out), err


def test_import_all_stores_each_detected_token_never_echoing_it(monkeypatch, capsys):
    monkeypatch.setenv("USAI_API_KEY", "usai-secret-0001")
    monkeypatch.setenv("GH_TOKEN", "gh-secret-0002")
    rc, doc, err = _run(capsys, "--all")
    assert rc == 0 and err == ""
    assert doc["data"] == {
        "scope": "global", "scope_kind": "global", "dry_run": False, "mode": "all", "imported": 2, "skipped": 0,
        "results": [
            {"service": "github", "source_env": "GH_TOKEN", "existed": False, "outcome": "imported"},
            {"service": "usai", "source_env": "USAI_API_KEY", "existed": False, "outcome": "imported"},
        ],
    }
    assert "secret-000" not in json.dumps(doc)
    assert secretstore.resolve("usai") == "usai-secret-0001"
    assert secretstore.resolve("github") == "gh-secret-0002"


def test_github_token_preferred_over_gh_token(monkeypatch, capsys):
    monkeypatch.setenv("GITHUB_TOKEN", "primary")
    monkeypatch.setenv("GH_TOKEN", "fallback")
    rc, doc, _ = _run(capsys, "github", "--all")
    assert rc == 0 and doc["data"]["results"][0]["source_env"] == "GITHUB_TOKEN"
    assert secretstore.resolve("github") == "primary"


def test_all_skips_existing_force_overwrites(monkeypatch, capsys):
    secretstore.store("acq.usai", "old-value")
    monkeypatch.setenv("USAI_API_KEY", "new-value")
    rc, doc, _ = _run(capsys, "--all")
    assert doc["data"]["results"][0]["outcome"] == "skipped" and doc["data"]["results"][0]["reason"] == "exists"
    assert secretstore.resolve("usai") == "old-value"
    rc, doc, _ = _run(capsys, "-f")
    assert rc == 0 and doc["data"]["imported"] == 1
    assert secretstore.resolve("usai") == "new-value"


def test_dry_run_writes_nothing(monkeypatch, capsys):
    monkeypatch.setenv("USAI_API_KEY", "dry-value-9876")
    rc = cli.main(["secret", "import", "--dry-run", "--force"])
    out, err = capsys.readouterr()
    assert rc == 0
    assert out == "secret import done: 1 imported, 0 skipped\n"
    assert "would import 'usai' from $USAI_API_KEY (...9876) into global." in err
    assert "dry-value" not in out + err  # only the masked last-4 preview
    assert not _store().exists()


def test_interactive_without_a_tty_skips(monkeypatch, capsys):
    monkeypatch.setenv("USAI_API_KEY", "v1")
    rc, doc, _ = _run(capsys)
    assert rc == 0 and doc["data"]["results"][0]["reason"] == "not_a_tty"
    assert not _store().exists()
    monkeypatch.setenv("ACQ_SECRET_IMPORT_ASSUME_YES", "1")
    rc, doc, _ = _run(capsys)
    assert doc["data"]["imported"] == 1 and secretstore.resolve("usai") == "v1"


def test_interactive_prompt_on_a_tty(monkeypatch, capsys):
    class _Tty(io.StringIO):
        def isatty(self):
            return True

    monkeypatch.setenv("USAI_API_KEY", "tty-value-ABCD")
    monkeypatch.setattr(sys, "stdin", _Tty("n\n"))
    rc = cli.main(["secret", "import"])
    err = capsys.readouterr().err
    assert rc == 0 and "import usai from $USAI_API_KEY (...ABCD) into global? [y/N]" in err
    assert not _store().exists()
    monkeypatch.setattr(sys, "stdin", _Tty("y\n"))
    assert cli.main(["secret", "import"]) == 0
    assert secretstore.resolve("usai") == "tty-value-ABCD"


def test_multiline_or_tab_value_is_refused_without_printing_it(monkeypatch, capsys):
    monkeypatch.setenv("USAI_API_KEY", "LINE-ONE\nLINE-TWO")
    monkeypatch.setenv("GITHUB_TOKEN", "TAB-A\tTAB-B")
    rc = cli.main(["secret", "import", "--all"])
    out, err = capsys.readouterr()
    assert rc == 0 and "0 imported, 2 skipped" in out
    assert "refusing 'usai'" in err and "refusing 'github'" in err
    for fragment in ("LINE-ONE", "LINE-TWO", "TAB-A", "TAB-B"):
        assert fragment not in out + err
    assert not _store().exists()


def test_sandbox_scope_including_one_named_global(monkeypatch, capsys):
    monkeypatch.setenv("GITHUB_TOKEN", "gh-scoped")
    rc = cli.main(["secret", "import", "global", "--all"])
    err = capsys.readouterr().err
    assert rc == 0 and "imported 'github' (sandbox 'global') from $GITHUB_TOKEN." in err
    assert (_store() / "acq.global.github").exists() and not (_store() / "acq.github").exists()
    rc, doc, _ = _run(capsys, "usai", "mybox", "--all")
    assert rc == 0 and doc["data"]["scope"] == "mybox" and doc["data"]["scope_kind"] == "sandbox"
    assert doc["data"]["results"] == []


def test_registered_provider_is_importable(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "opencode-go=OPENCODE_API_KEY@api.example.com")
    monkeypatch.setenv("OPENCODE_API_KEY", "oc-secret")
    rc, doc, _ = _run(capsys, "opencode-go", "--all")
    assert rc == 0 and doc["data"]["results"][0]["source_env"] == "OPENCODE_API_KEY"
    assert secretstore.resolve("opencode-go") == "oc-secret"


def test_nothing_found(capsys):
    rc = cli.main(["secret", "import"])
    out, err = capsys.readouterr()
    assert rc == 0 and out == "secret import done: 0 imported, 0 skipped\n"
    assert "no known service tokens found" in err


@pytest.mark.parametrize(
    ("argv", "message"),
    [
        (["usai", "--bogus"], "secret import: unknown flag '--bogus'"),
        (["--service=nope"], "secret import: unknown service 'nope' for --service"),
        (["usai", "github"], "secret import: unexpected extra argument 'github'"),
        (["box1", "box2"], "secret import: unexpected extra argument 'box2'"),
        (["-g", "mybox"], "secret import: give either -g or a SANDBOX, not both"),
    ],
)
def test_usage_errors(monkeypatch, capsys, argv, message):
    monkeypatch.setenv("USAI_API_KEY", "v")
    rc, doc, _ = _run(capsys, *argv)
    assert rc == 2 and doc["error"] == {**doc["error"], "code": "usage", "message": message}
    assert not _store().exists()


def test_invalid_sandbox_name_refused_before_store_access(monkeypatch, capsys):
    monkeypatch.setenv("USAI_API_KEY", "v")
    rc, doc, _ = _run(capsys, "my.box", "--all")
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert not _store().exists()


def test_store_failure_is_an_operational_error(monkeypatch, capsys):
    monkeypatch.setenv("USAI_API_KEY", "v")
    _store().parent.mkdir(parents=True, exist_ok=True)
    _store().write_text("not a directory")
    rc, doc, _ = _run(capsys, "--all")
    assert rc == 1 and doc["error"]["code"] == "failure"
    assert "failed to store 'usai' (global)" in doc["error"]["message"]
