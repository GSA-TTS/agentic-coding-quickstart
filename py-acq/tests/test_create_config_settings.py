"""Tier-2 tests: create and run read what ``acq configure`` writes (ADR-0031).

``provider_kit`` gives way to ``--no-provider-kits`` and ``ACQ_PROVIDER_KITS``
in Bash's order, and ``scope_github_token`` is the default answer to the
per-sandbox GitHub-token prompt (ADR-0013) that create and run show before
provisioning. ``extra_kits`` is covered with the kit selection in
test_kitspec.py and test_kit_msb.py.

Non-contract evidence (ADR-0039m): ``cli.main`` runs in-process against the
deterministic ``__stub__`` backends. No real credential is used; the tokens
below are throwaway strings, and none may reach any output.
"""

from __future__ import annotations

import io
import json
import os
import sys

import pytest

from acq_py import cli, config, msb, provider_creds, secretstore, security, state
from acq_py.commands import common, configure, creds
from gitfixtures import git_repo

TOKEN = "ghp_THROWAWAY-SCOPED-TOKEN"
UNBUNDLED = "git+https://example.invalid/provider-kit.git#ref=main&dir=kit"


def _msb_env(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))


def _sbx_env(monkeypatch, tmp_path):
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))


def _plain_ws(tmp_path):
    ws = tmp_path / "plain-ws"
    ws.mkdir()
    return ws


def _github_ws(monkeypatch, tmp_path, *urls):
    ws = tmp_path / "ws"
    for i, url in enumerate(urls or ("https://github.com/alpha/app.git",)):
        git_repo(monkeypatch, ws / f"repo{i}", url)
    return ws


def _main(capsys, *argv):
    rc = cli.main(list(argv))
    out, err = capsys.readouterr()
    lines = out.strip().splitlines()
    return rc, (json.loads(lines[-1]) if lines and lines[-1].startswith("{") else None), out, err


def _write_config(text: str) -> None:
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _terminal(monkeypatch, *, answer: str, token: str | None = None) -> list[str]:
    """Pretend stdin is a terminal: ``answer`` is the line typed at the yes/no
    prompt and ``token`` the hidden token line. Returns the prompts shown."""
    shown: list[str] = []
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr(configure.Terminal, "read_line", lambda self: answer)

    def read_secret(prompt):
        shown.append(prompt)
        if token is None:
            raise AssertionError("the token must not be read")
        return token

    monkeypatch.setattr(common, "_read_secret_tty", read_secret)
    return shown


# ---------------------------------------------------------------------------
# --no-provider-kits > ACQ_PROVIDER_KITS > config.yaml provider_kit
# ---------------------------------------------------------------------------

def test_no_provider_kits_beats_an_exported_provider_kit(monkeypatch, tmp_path, capsys):
    # An unbundled provider kit would have to be fetched, so it is refused...
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", UNBUNDLED)
    ws = _plain_ws(tmp_path)
    rc, doc, _, _ = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "np1", "--json")
    assert rc == 1 and doc["error"]["code"] == "unsupported_capability"
    # ...and --no-provider-kits wins over it: no provider kit, no key required.
    rc, doc, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "np1",
                            "--no-provider-kits", "--json")
    assert rc == 0, err
    assert "usai-provider" not in doc["data"]["kits"]
    assert os.environ["ACQ_PROVIDER_KITS"] == UNBUNDLED  # the export is restored


def test_no_provider_kits_beats_config_provider_kit(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.delenv("ACQ_PROVIDER_KITS", raising=False)
    _write_config("provider_kit: no-such-source/some-kit\n")
    ws = _plain_ws(tmp_path)
    rc, doc, _, _ = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "np2", "--json")
    assert rc == 1 and doc["error"]["code"] == "validation_failed"
    assert "provider kit could not be resolved" in doc["error"]["message"]
    rc, doc, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "np2",
                            "--no-provider-kits", "--json")
    assert rc == 0, err
    assert "ACQ_PROVIDER_KITS" not in os.environ  # nothing leaks past the invocation


def test_default_provider_kit_still_needs_its_key(monkeypatch, tmp_path, capsys):
    # Without the flag the shipped provider kit is selected and its key gates
    # the create, so the flag above is what lifted the requirement.
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.delenv("ACQ_PROVIDER_KITS", raising=False)
    ws = _plain_ws(tmp_path)
    rc, doc, _, _ = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "np3", "--json")
    assert rc == 1 and doc["error"]["code"] == "secret_missing"


def test_run_accepts_no_provider_kits(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", UNBUNDLED)
    ws = _plain_ws(tmp_path)
    rc, doc, _, err = _main(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "np4",
                            "--no-provider-kits", "--json")
    assert rc == 0, err
    assert doc["data"]["action"] == "created"
    assert os.environ["ACQ_PROVIDER_KITS"] == UNBUNDLED


# ---------------------------------------------------------------------------
# scope_github_token: the per-sandbox GitHub-token prompt at create and run
# ---------------------------------------------------------------------------

@pytest.mark.provider_key
def test_create_without_a_terminal_only_advises(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    _write_config("scope_github_token: yes\n")
    stdin = io.StringIO(TOKEN + "\n")
    monkeypatch.setattr(sys, "stdin", stdin)
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "acq: note — this sandbox has no repo-scoped GitHub token.\n" in err
    assert "No GitHub token is set for this sandbox." in err
    assert f"To scope it later: acq github-scope adv {ws}\n" in err
    assert stdin.tell() == 0  # no token is read while prompts are off
    assert not secretstore.exists("github", "adv")


@pytest.mark.provider_key
def test_no_prompt_env_only_advises_even_at_a_terminal(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    _write_config("scope_github_token: yes\n")
    monkeypatch.setenv("ACQ_NO_PROMPT", "1")
    shown = _terminal(monkeypatch, answer="y\n")
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "To scope it later: acq github-scope adv" in err
    assert shown == [] and not secretstore.exists("github", "adv")


@pytest.mark.provider_key
def test_json_create_skips_the_nudge(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    shown = _terminal(monkeypatch, answer="y\n")
    rc, doc, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv", "--json")
    assert rc == 0 and doc["data"]["name"] == "adv"
    assert "GitHub" not in err and shown == []


@pytest.mark.provider_key
def test_configured_yes_scopes_before_the_msb_create_binds(monkeypatch, tmp_path, capsys):
    # A bare ENTER takes the configured default (yes), so the token is stored for
    # this sandbox before msb creates it, and the create binds it.
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    _write_config("scope_github_token: yes\n")
    shown = _terminal(monkeypatch, answer="\n", token=TOKEN)
    rc, _, out, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert f"? {creds.SCOPE_NOW_PROMPT} [Y/n] " in err
    assert shown == ["Enter GitHub token: "]
    assert secretstore.get(secretstore.key_for("github", "adv")) == TOKEN
    assert secretstore.get(secretstore.key_for("github")) is None
    assert "GITHUB_TOKEN" in msb.held_read("adv").bindings
    record = provider_creds.github_scope_read("msb", "adv")
    assert record is not None and record["owner"] == "alpha" and record["repos"] == ["alpha/app"]
    assert "stored a GitHub token for sandbox 'adv' only, requested for alpha/app." in err
    assert TOKEN not in out + err


@pytest.mark.provider_key
def test_unset_default_declines_on_enter(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    shown = _terminal(monkeypatch, answer="\n")
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert f"? {creds.SCOPE_NOW_PROMPT} [y/N] " in err
    assert f"continuing without scoping (run 'acq github-scope adv {ws}' anytime)" in err
    assert shown == [] and "GITHUB_TOKEN" not in msb.held_read("adv").bindings


@pytest.mark.provider_key
def test_configured_no_still_lets_the_user_say_yes(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    _write_config("scope_github_token: no\n")
    _terminal(monkeypatch, answer="y\n", token=TOKEN)
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "[y/N]" in err and secretstore.get(secretstore.key_for("github", "adv")) == TOKEN


@pytest.mark.provider_key
def test_an_empty_token_skips_without_failing_the_create(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    _write_config("scope_github_token: yes\n")
    _terminal(monkeypatch, answer="\n", token="")
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "GitHub scoping skipped (no token entered); continuing." in err
    assert not secretstore.exists("github", "adv")
    assert provider_creds.github_scope_read("msb", "adv") is None


@pytest.mark.provider_key
def test_multi_owner_workspace_is_refused_without_failing_the_create(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path, "https://github.com/alpha/a.git", "https://github.com/beta/b.git")
    _write_config("scope_github_token: yes\n")
    shown = _terminal(monkeypatch, answer="\n")
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "owned by 2 accounts" in err and shown == []


@pytest.mark.provider_key
def test_a_sandbox_with_its_own_token_is_not_nudged(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    secretstore.set_secret("github", "adv", TOKEN)
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "GitHub" not in err


@pytest.mark.provider_key
def test_a_global_token_is_named_as_broader(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    secretstore.set_secret("github", None, TOKEN)
    rc, _, out, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "A GLOBAL GitHub token is set; it grants this sandbox access to ALL" in err
    assert TOKEN not in out + err


@pytest.mark.provider_key
def test_a_workspace_without_github_repos_is_not_nudged(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _plain_ws(tmp_path)
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "GitHub" not in err


@pytest.mark.provider_key
def test_run_reattach_is_nudged_too(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    rc, _, _, _ = _main(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "adv", "--json")
    assert rc == 0
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    monkeypatch.setattr(msb, "launch", lambda *a, **k: 0)
    rc, _, _, err = _main(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    assert "To scope it later: acq github-scope adv" in err


@pytest.mark.provider_key
def test_security_recreate_is_nudged_too(monkeypatch, tmp_path, capsys):
    # A recreate builds a new guest, which binds its secrets at create like any other.
    _msb_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    catalog = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    catalog.parent.mkdir(parents=True)
    catalog.write_text(json.dumps({"sec": "running"}), encoding="utf-8")
    record = state.record_path("msb", "sec")
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({"schema": 1, "name": "sec", "backend": "msb", "agent": "opencode",
                                  "workspace": str(ws), "ro_host_config": True}), encoding="utf-8")
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))
    monkeypatch.setattr(security, "WINDOWS", False)
    rc, _, _, err = _main(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes")
    assert rc == 0, err
    assert "To scope it later: acq github-scope sec" in err


@pytest.mark.provider_key
def test_sbx_create_scopes_before_the_create(monkeypatch, tmp_path, capsys):
    from acq_py import sbx

    _sbx_env(monkeypatch, tmp_path)
    ws = _github_ws(monkeypatch, tmp_path)
    _write_config("scope_github_token: yes\n")
    _terminal(monkeypatch, answer="\n", token=TOKEN)
    calls: list = []
    real_run = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        calls.append((list(argv), input_text))
        return real_run(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    rc, _, _, err = _main(capsys, "--backend", "sbx", "create", "opencode", str(ws), "--name", "adv")
    assert rc == 0, err
    feed = calls.index((["secret", "set", "--sandbox", "adv", "github"], TOKEN))
    create = next(i for i, (argv, _) in enumerate(calls) if argv[0] == "create")
    assert feed < create  # stored and fed before sbx snapshots the sandbox
    assert all(TOKEN not in " ".join(argv) for argv, _ in calls)


def test_scope_default_reads_only_yes_spellings(monkeypatch, tmp_path):
    for value, expected in (("yes", True), ("y", True), ("Y", True), ("YES", False), ("no", False), ("", False)):
        _write_config(f"scope_github_token: {value}\n")
        assert creds.scope_github_token_default() is expected, value
    config.config_path().unlink()
    assert creds.scope_github_token_default() is False
