"""Tier-2 tests for ``acq configure`` (ADR-0031).

The interactive flow is driven three ways: in-process with scripted keys (for
coverage of every branch), on a real pseudo-terminal (the key handling a user
gets), and against the Bash ``acq configure`` with the same answers, whose
``config.yaml`` must come out identical. The Bash side is driven by its own
scripted-input hook, ``ACQ_PROMPT_TEST_INPUT``.
"""

from __future__ import annotations

import collections
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, config
from acq_py.commands import configure

REPO_ROOT = Path(__file__).resolve().parents[2]
BASH_ACQ = REPO_ROOT / "acq"
BASH = shutil.which("bash") if os.name == "posix" else None
needs_bash = pytest.mark.skipif(BASH is None, reason="needs a POSIX bash")
POSIX_ONLY = pytest.mark.skipif(os.name != "posix", reason="POSIX pty and file modes")

PROVIDER_DEFAULT = "agentic-coding-patterns/usai-provider"
CONTROL_PLANE_USAI = "github.com/GSA-TTS/agentic-coding-patterns/usai-provider"
SEED = b"schema: 1\nbackend: msb\n# hand-edited\ncustom_key: keep  # trailing\nextra_kits: paseo\n"
KEY_WORDS = {"UP", "DOWN", "LEFT", "RIGHT", "SPACE", "ENTER", "QUIT"}


def _write_config(data: bytes) -> Path:
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def _state_env(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))


class _Script:
    """Scripted terminal input: keys for the checkbox lists, lines for confirms."""

    def __init__(self, keys, lines=()):
        self.keys = collections.deque(keys)
        self.lines = collections.deque(lines)

    def install(self, monkeypatch):
        monkeypatch.setattr(configure, "interactive", lambda emit_json: not emit_json)
        monkeypatch.setattr(configure.Terminal, "read_key", lambda term: self.keys.popleft())
        monkeypatch.setattr(configure.Terminal, "read_line", lambda term: self.lines.popleft())
        return self


def _run(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    return rc, captured.out, captured.err


# ---------------------------------------------------------------------------
# Non-interactive: report only.
# ---------------------------------------------------------------------------

def test_json_reports_each_setting_with_its_source_layer(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(b"schema: 1\nscope_github_token: yes\nprovider_kit: example/kit\n")
    monkeypatch.setenv("ACQ_EXTRA_KITS", "git+https://example.invalid/kit")
    monkeypatch.setenv("ACQ_KIT_SOURCE_SEED", json.dumps(
        [{"repository": "github.com/team/kits", "ref": "a" * 40, "directory": "kits"}]))
    rc, out, err = _run(capsys, "--backend", "sbx", "configure", "--json")
    assert rc == 0 and err == ""
    doc = json.loads(out)
    assert doc["command"] == "configure"
    assert doc["data"]["config_path"] == str(path)
    assert doc["data"]["interactive"] is False and doc["data"]["changed"] is False
    assert doc["data"]["settings"] == [
        {"key": "backend", "value": "sbx", "source": "flag", "honoured_by_python": True},
        {"key": "extra_kits", "value": "git+https://example.invalid/kit", "source": "env", "honoured_by_python": True,
         "python_applies": "pinned-only"},
        {"key": "scope_github_token", "value": "yes", "source": "config", "honoured_by_python": True},
        {"key": "provider_credential_bindings", "value": None, "source": "default", "honoured_by_python": True},
        {"key": "provider_kit", "value": "example/kit", "source": "config", "honoured_by_python": True,
         "python_applies": "pinned-only"},
        {"key": "kit_sources", "value": f"github.com/team/kits@{'a' * 40}|kits", "source": "config",
         "honoured_by_python": True},
    ]
    assert path.read_bytes() == b"schema: 1\nscope_github_token: yes\nprovider_kit: example/kit\n"


def test_json_backend_and_provider_layers(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    _write_config(b"backend: sbx\n")
    monkeypatch.setenv("ACQ_BACKEND", "bogus")  # ignored, as backend resolution ignores it
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")  # explicitly empty: no provider kit
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "opencode-go=OPENCODE_GO_API_KEY@opencode.ai")
    rc, out, _ = _run(capsys, "configure", "--json")
    assert rc == 0
    settings = {s["key"]: s for s in json.loads(out)["data"]["settings"]}
    assert settings["backend"] == {"key": "backend", "value": "sbx", "source": "config", "honoured_by_python": True}
    assert settings["provider_kit"] == {"key": "provider_kit", "value": "", "source": "env", "honoured_by_python": True,
                                        "python_applies": "pinned-only"}
    assert settings["provider_credential_bindings"] == {
        "key": "provider_credential_bindings", "value": "opencode-go=OPENCODE_GO_API_KEY@opencode.ai",
        "source": "env", "honoured_by_python": True,
        "entries": [{"value": "opencode-go=OPENCODE_GO_API_KEY@opencode.ai", "source": "env"}]}
    monkeypatch.setenv("ACQ_BACKEND", "msb")
    rc, out, _ = _run(capsys, "configure", "--json")
    assert json.loads(out)["data"]["settings"][0] == {
        "key": "backend", "value": "msb", "source": "env", "honoured_by_python": True}


def test_json_config_layer_bindings(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_SEED", json.dumps(
        [{"provider": "acme", "key_env": "ACME_KEY", "hosts": ["a.example.gov", "b.example.gov"]},
         {"provider": "bare", "key_env": "BARE_KEY", "hosts": []}]))
    rc, out, _ = _run(capsys, "configure", "--json")
    assert rc == 0
    settings = {s["key"]: s for s in json.loads(out)["data"]["settings"]}
    assert settings["provider_credential_bindings"] == {
        "key": "provider_credential_bindings",
        "value": "acme=ACME_KEY@a.example.gov,b.example.gov bare=BARE_KEY",
        "source": "config",
        "honoured_by_python": True,
        "entries": [{"value": "acme=ACME_KEY@a.example.gov,b.example.gov", "source": "config"},
                    {"value": "bare=BARE_KEY", "source": "config"}],
    }


def test_bindings_from_both_layers_are_labelled_per_entry(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_SEED", json.dumps(
        [{"provider": "acme", "key_env": "ACME_KEY", "hosts": ["a.example.gov"]}]))
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "opencode-go=OPENCODE_GO_API_KEY@opencode.ai")
    rc, out, _ = _run(capsys, "configure", "--json")
    assert rc == 0
    setting = json.loads(out)["data"]["settings"][3]
    assert setting["source"] == "mixed"
    # The order is provider-credential ls's (by layer, then provider).
    assert setting["entries"] == [{"value": "opencode-go=OPENCODE_GO_API_KEY@opencode.ai", "source": "env"},
                                  {"value": "acme=ACME_KEY@a.example.gov", "source": "config"}]
    rc, _, err = _run(capsys, "configure")
    assert ("      provider creds:     opencode-go=OPENCODE_GO_API_KEY@opencode.ai [env] acme=ACME_KEY@a.example.gov"
            "   (acq provider-credential ls)\n") in err


def test_kit_ref_userinfo_is_redacted(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    token = "ghp_CONFIGURE-USERINFO-TOKEN"
    monkeypatch.setenv("ACQ_EXTRA_KITS", f"git+https://user:{token}@github.com/o/r.git#ref=x other")
    monkeypatch.setenv("ACQ_PROVIDER_KITS", f"https://{token}@example.gov/kit")
    rc, out, _ = _run(capsys, "configure", "--json")
    assert rc == 0 and token not in out
    settings = {s["key"]: s["value"] for s in json.loads(out)["data"]["settings"]}
    assert settings["extra_kits"] == "git+https://***@github.com/o/r.git#ref=x other"
    assert settings["provider_kit"] == "https://***@example.gov/kit"
    rc, _, err = _run(capsys, "configure")
    assert rc == 0 and token not in err and "git+https://***@github.com/o/r.git#ref=x other" in err
    rc, out, _ = _run(capsys, "kit", "list", "--json")
    assert rc == 0 and token not in out
    data = json.loads(out)["data"]
    assert data["extra"] == ["git+https://***@github.com/o/r.git#ref=x", "other"]
    assert data["provider"] == ["https://***@example.gov/kit"]
    assert configure.kits.redact_userinfo("git+ssh://git@github.com/o/r") == "git+ssh://***@github.com/o/r"
    assert configure.kits.redact_userinfo("no url here") == "no url here"
    assert configure.kits.redact_userinfo("https://u:p@ss@h.gov/x@y") == "https://***@h.gov/x@y"


def test_kit_ref_query_and_extra_fragment_values_are_never_shown(monkeypatch, tmp_path, capsys):
    # configure reports ACQ_EXTRA_KITS and ACQ_PROVIDER_KITS verbatim apart from
    # the display redaction; a query string or an extra fragment value is hidden.
    _state_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", "git+https://github.com/o/r.git?private_token=SEKRIT#ref=x&dir=k ./kit")
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "git+https://github.com/o/r.git#ref=x&dir=k&token=SEKRIT")
    rc, out, _ = _run(capsys, "configure", "--json")
    assert rc == 0 and "SEKRIT" not in out
    settings = {s["key"]: s["value"] for s in json.loads(out)["data"]["settings"]}
    assert settings["extra_kits"] == "git+https://github.com/o/r.git?***#ref=x&dir=k ./kit"
    assert settings["provider_kit"] == "git+https://github.com/o/r.git#ref=x&dir=k&***"
    rc, _, err = _run(capsys, "configure")
    assert rc == 0 and "SEKRIT" not in err


@pytest.mark.parametrize("argv", [["configure"], ["configure", "--json"]], ids=["human", "json"])
def test_non_interactive_leaves_a_legacy_config_unchanged(monkeypatch, tmp_path, capsys, argv):
    _state_env(monkeypatch, tmp_path)
    legacy = b"backend: msb\nextra_kits: paseo\n"
    path = _write_config(legacy)
    rc, _, _ = _run(capsys, *argv)
    assert rc == 0
    assert path.read_bytes() == legacy


def test_no_secret_value_reaches_the_output(tmp_path):
    secret = "CONFIGURE-SECRET-VALUE-0123456789"
    env = dict(os.environ, ACQ_STATE_DIR=str(tmp_path / "state"), USAI_API_KEY=secret, GITHUB_TOKEN=secret,
               OPENCODE_GO_API_KEY=secret, ACQ_PROVIDER_CREDENTIAL_BINDINGS="opencode-go=OPENCODE_GO_API_KEY@opencode.ai")
    for argv in (["configure", "--json"], ["configure"]):
        proc = subprocess.run([sys.executable, "-m", "acq_py", *argv], env=env, capture_output=True,
                              stdin=subprocess.DEVNULL, timeout=120, check=False)
        assert proc.returncode == 0, proc.stderr
        assert secret.encode() not in proc.stdout + proc.stderr
    assert not config.config_path().exists()


def test_malformed_binding_env_fails_closed(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "not-a-binding")
    rc, out, _ = _run(capsys, "configure", "--json")
    assert rc == 1 and json.loads(out)["error"]["code"] == "validation_failed"


def test_human_report_names_flag_and_env_layers(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", "custom-ref")
    rc, out, err = _run(capsys, "--backend", "msb", "configure")
    assert rc == 0 and out == ""
    assert "      default backend:    msb   [from --backend]\n" in err
    assert "      extra kits:         custom-ref   [from ACQ_EXTRA_KITS]\n" in err
    assert err.endswith(configure.PINNED_ONLY_NOTE + "\n\n"
                        "acq: non-interactive; configuration unchanged.\n"
                        "      Run 'acq configure' from a terminal to change kits/token scoping.\n")
    # An unknown --backend is refused, never reported as a flag-layer value.
    rc, out, _ = _run(capsys, "--backend", "bogus", "configure", "--json")
    assert rc == 2 and json.loads(out)["error"]["code"] == "usage"


def test_no_prompt_env_keeps_a_terminal_non_interactive(monkeypatch):
    class _Tty:
        def isatty(self):
            return True

    monkeypatch.setattr(sys, "stdin", _Tty())
    assert configure.interactive(False) is True
    assert configure.interactive(True) is False
    monkeypatch.setenv("ACQ_NO_PROMPT", "1")
    assert configure.interactive(False) is False
    monkeypatch.delenv("ACQ_NO_PROMPT")
    monkeypatch.setenv("ACQ_NO_PROGRESS", "1")
    assert configure.interactive(False) is False


def test_windows_nul_stdin_is_not_interactive(monkeypatch, tmp_path, capsys):
    """On Windows ``< NUL`` reports isatty() True; only a real console counts,
    so configure reports instead of waiting for keys."""
    from acq_py import hostexec

    class _Nul:
        def isatty(self):
            return True

        def fileno(self):
            return 0

    _state_env(monkeypatch, tmp_path)
    monkeypatch.setattr(sys, "stdin", _Nul())
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    monkeypatch.setattr(hostexec, "_windows_console", lambda fd: False)
    assert configure.interactive(False) is False
    monkeypatch.setattr(configure.Terminal, "read_key", lambda term: pytest.fail("prompted on NUL"))
    rc, out, err = _run(capsys, "configure")
    assert rc == 0 and out == ""
    assert "acq: non-interactive; configuration unchanged." in err
    monkeypatch.setattr(hostexec, "_windows_console", lambda fd: True)
    assert configure.interactive(False) is True


@needs_bash
def test_human_report_matches_bash(tmp_path):
    _write_config(SEED + b"scope_github_token: yes\nprovider_kit: example/kit\n")
    env = _bash_env(tmp_path)
    bash = subprocess.run([BASH, str(BASH_ACQ), "configure"], env=env, capture_output=True,
                          stdin=subprocess.DEVNULL, timeout=120, check=False)
    py_env = dict(os.environ, ACQ_STATE_DIR=env["ACQ_STATE_DIR"])
    python = subprocess.run([sys.executable, "-m", "acq_py", "configure"], env=py_env, capture_output=True,
                            stdin=subprocess.DEVNULL, timeout=120, check=False)
    assert bash.returncode == 0 and python.returncode == 0, (bash.stderr, python.stderr)
    # The one added line: the note that Python applies only bundled or pinned kits.
    note = configure.PINNED_ONLY_NOTE.encode() + b"\n"
    assert note in python.stderr
    assert python.stderr.replace(note, b"", 1) == bash.stderr
    assert python.stdout == bash.stdout == b""


# ---------------------------------------------------------------------------
# Interactive flow (scripted keys, in-process).
# ---------------------------------------------------------------------------

def test_interactive_writes_the_three_bash_keys_and_keeps_the_rest(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    monkeypatch.setenv("COLUMNS", "200")
    path = _write_config(SEED)
    # Kits: openchamber on, paseo off, oci-engine on (UP wraps from the first row
    # to the last). Scope: yes. Provider: move to the control-plane kit, check it,
    # uncheck the shipped default.
    _Script(["SPACE", "DOWN", "SPACE", "UP", "UP", "SPACE", "x", "ENTER",
             "DOWN", "SPACE", "UP", "SPACE", "ENTER"], ["y\n"]).install(monkeypatch)
    rc, out, err = _run(capsys, "configure")
    assert rc == 0 and out == ""
    assert path.read_bytes() == (
        b"schema: 1\nbackend: msb\n# hand-edited\ncustom_key: keep  # trailing\n"
        b"extra_kits: openchamber oci-engine\nscope_github_token: yes\n"
        b"provider_kit: " + CONTROL_PLANE_USAI.encode() + b"\n"
    )
    assert "  [x] zscaler-ca-certificate  Zscaler/corporate CA trust" in err
    assert "(always applied)" in err
    assert "? Scope a per-sandbox GitHub token by default (on create)? [y/N] " in err
    assert err.endswith(f"\nacq: configuration saved to {path}.\n"
                        "      extra kits:         openchamber oci-engine\n"
                        f"      provider kit:       {CONTROL_PLANE_USAI}\n")


def test_interactive_defaults_come_from_the_config(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(b"schema: 1\nextra_kits: oci-engine paseo\nscope_github_token: y\n"
                         + f"provider_kit: {CONTROL_PLANE_USAI}\n".encode())
    # ENTER keeps the kits, a bare line keeps the scope default (yes), ENTER keeps
    # the provider.
    _Script(["ENTER", "ENTER"], ["\n"]).install(monkeypatch)
    rc, _, err = _run(capsys, "configure")
    assert rc == 0
    assert "[Y/n]" in err
    assert path.read_bytes() == (b"schema: 1\nextra_kits: paseo oci-engine\nscope_github_token: yes\n"
                                 + f"provider_kit: {CONTROL_PLANE_USAI}\n".encode())


def test_interactive_clearing_everything(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(SEED + b"scope_github_token: yes\n")
    # Uncheck paseo (the only extra), answer no, uncheck the provider: the extra
    # kits key goes away and the provider key is not written.
    _Script(["DOWN", "SPACE", "ENTER", "SPACE", "ENTER"], ["n\n"]).install(monkeypatch)
    rc, _, err = _run(capsys, "configure")
    assert rc == 0
    assert path.read_bytes() == (b"schema: 1\nbackend: msb\n# hand-edited\ncustom_key: keep  # trailing\n"
                                 b"scope_github_token: no\n")
    assert "      extra kits:         <none>\n" in err
    assert f"      provider kit:       {PROVIDER_DEFAULT}\n" in err


def test_unrecognized_answer_takes_the_default(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(b"schema: 1\n")
    _Script(["ENTER", "ENTER"], ["maybe\n"]).install(monkeypatch)
    assert _run(capsys, "configure")[0] == 0
    assert b"scope_github_token: no\n" in path.read_bytes()


def test_cancel_writes_nothing(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(SEED)
    _Script(["SPACE", "QUIT"]).install(monkeypatch)
    rc, _, err = _run(capsys, "configure")
    assert rc == 0
    assert "acq: selection cancelled; keeping current configuration." in err
    assert path.read_bytes() == SEED


def test_cancel_leaves_a_legacy_config_untouched(monkeypatch, tmp_path, capsys):
    # The migration pre-step runs only before the first write, so a cancelled
    # run does not even add the schema marker.
    _state_env(monkeypatch, tmp_path)
    legacy = b"backend: msb\nextra_kits: paseo\n"
    path = _write_config(legacy)
    _Script(["SPACE", "QUIT"]).install(monkeypatch)
    assert _run(capsys, "configure")[0] == 0
    assert path.read_bytes() == legacy


def test_a_refusing_pre_step_stops_before_the_first_write(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(SEED)
    _Script(["SPACE", "ENTER"]).install(monkeypatch)
    calls = []

    def refuse(emit_json, command):
        calls.append(command)
        return 1

    monkeypatch.setattr(cli, "_migration_pre_step", refuse)
    assert _run(capsys, "configure")[0] == 1
    assert calls == ["configure"]
    assert path.read_bytes() == SEED


def test_cancel_at_the_provider_keeps_the_other_answers(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(b"schema: 1\nprovider_kit: example/kit\n")
    _Script(["ENTER", "QUIT"], ["yes\n"]).install(monkeypatch)
    rc, _, err = _run(capsys, "configure")
    assert rc == 0
    assert path.read_bytes() == b"schema: 1\nprovider_kit: example/kit\nscope_github_token: yes\n"
    assert "      provider kit:       example/kit\n" in err


def test_provider_kit_userinfo_never_reaches_the_terminal(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    ref = "git+https://oauth2:glpat-LEAKME@host/k.git#ref=abc"
    path = _write_config(f"schema: 1\nprovider_kit: {ref}\n".encode())
    # Keep the kits and the scope default; cancel the provider list, so the
    # summary reports the configured (unchanged) provider kit.
    script = _Script(["ENTER", "QUIT"], ["\n"]).install(monkeypatch)
    rc, out, err = _run(capsys, "configure")
    assert rc == 0
    assert "glpat-LEAKME" not in out + err
    assert err.endswith("      provider kit:       git+https://***@host/k.git#ref=abc\n")
    assert f"provider_kit: {ref}\n".encode() in path.read_bytes()  # the stored value is untouched
    labels = []
    monkeypatch.setattr(configure, "_row", lambda term, i, item, *rest: labels.append(item) or "")
    script.keys.append("ENTER")
    configure.multiselect(configure.Terminal(), 0, [], [(ref, f"{ref} (@x)")])
    assert labels and all("LEAKME" not in label + desc for label, desc in labels)


def test_fresh_config_is_created_with_the_schema_marker(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    _Script(["SPACE", "ENTER", "ENTER"], [""]).install(monkeypatch)
    assert _run(capsys, "configure")[0] == 0
    assert config.config_path().read_bytes() == (
        b"schema: 1\nextra_kits: openchamber\nscope_github_token: no\n"
        + f"provider_kit: {PROVIDER_DEFAULT}\n".encode())


def test_ctrl_c_exits_130_and_writes_nothing(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(SEED)
    _Script([]).install(monkeypatch)

    def interrupt(term):
        raise KeyboardInterrupt

    monkeypatch.setattr(configure.Terminal, "read_key", interrupt)
    rc, _, err = _run(capsys, "configure")
    assert rc == 130
    assert err.endswith("\033[?25h\033[?25h\n")
    assert path.read_bytes() == SEED


def test_sigterm_in_key_mode_exits_143_and_writes_nothing(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(SEED)
    _Script([]).install(monkeypatch)

    def terminated(term):
        raise configure.Signalled(15)

    monkeypatch.setattr(configure.Terminal, "read_key", terminated)
    rc, _, err = _run(capsys, "configure")
    assert rc == 143
    assert err.endswith("\033[?25h\033[?25h\n")
    assert path.read_bytes() == SEED


def test_newer_config_schema_is_refused_before_any_prompt(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(b"schema: 99\nbackend: msb\n")
    _Script([]).install(monkeypatch)  # no keys: a prompt would fail the test
    rc, _, err = _run(capsys, "configure")
    assert rc == 1
    assert "schema 99" in err and "Select kits" not in err
    assert path.read_bytes() == b"schema: 99\nbackend: msb\n"


def test_legacy_config_is_migrated_before_the_write(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    path = _write_config(b"backend: msb\n")
    _Script(["ENTER", "ENTER"], ["n\n"]).install(monkeypatch)
    assert _run(capsys, "configure")[0] == 0
    assert path.read_bytes() == (b"schema: 1\nbackend: msb\nscope_github_token: no\n"
                                 + f"provider_kit: {PROVIDER_DEFAULT}\n".encode())


@POSIX_ONLY
def test_symlinked_config_is_written_through(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    target = tmp_path / "dotfiles" / "acq.yaml"
    target.parent.mkdir()
    target.write_bytes(b"schema: 1\nbackend: msb\n")
    link = config.config_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target)
    _Script(["SPACE", "ENTER", "ENTER"], ["n\n"]).install(monkeypatch)
    assert _run(capsys, "configure")[0] == 0
    assert link.is_symlink()
    assert target.read_bytes().startswith(b"schema: 1\nbackend: msb\nextra_kits: openchamber\n")


def test_write_failure_is_reported(monkeypatch, tmp_path, capsys):
    _state_env(monkeypatch, tmp_path)
    _write_config(SEED)
    _Script(["ENTER"]).install(monkeypatch)

    def refuse(key, value):
        raise PermissionError(13, "Permission denied", str(config.config_path()))

    monkeypatch.setattr(config, "write_field", refuse)
    rc, _, err = _run(capsys, "configure")
    assert rc == 1
    assert "could not write" in err and "Permission denied" in err


def test_widget_rendering_details(monkeypatch):
    term = configure.Terminal()
    term.color = True
    monkeypatch.setenv("COLUMNS", "30")
    assert term.columns() == 30
    monkeypatch.setenv("COLUMNS", "5")
    assert term.columns() == 80
    monkeypatch.setenv("COLUMNS", "x")
    assert term.columns() >= 20
    assert configure._fit("abcdef", 4) == "abc…"
    assert configure._fit("abc", 4) == "abc"
    assert configure._sanitize("a\x1b[31mb\x9bc") == "a[31mbc"
    cursor = configure._row(term, 2, ("k", "d"), 1, False, True, 80)
    assert cursor == "\033[K\033[36m\033[1m❯ [ ] k  d\033[0m\n"
    checked = configure._row(term, 2, ("k", "d"), 1, True, False, 80)
    assert checked == "\033[K\033[32m  [x] k  d\033[0m\n"
    frozen = configure._row(term, 1, ("k", "d"), 1, True, False, 80)
    assert frozen == "\033[K\033[2m  [x] k  d (always applied)\033[0m\n"


def test_keys_mode_is_a_no_op_without_a_terminal(monkeypatch):
    import io

    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    with configure.Terminal().keys():
        pass


@POSIX_ONLY
def test_key_and_line_decoding(monkeypatch):
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, b" jk\rQx\x1b[A\x1b[B\x1b[C\x1b[D\x1bzz" + b"yes\n" + b"tail")
        os.close(write_fd)
        write_fd = -1
        monkeypatch.setattr(configure, "_stdin_fd", lambda: read_fd)
        term = configure.Terminal()
        keys = [term.read_key() for _ in range(12)]
        assert keys == ["SPACE", "DOWN", "UP", "ENTER", "QUIT", "x", "UP", "DOWN", "RIGHT", "LEFT", "QUIT", "y"]
        assert term.read_line() == "es\n"
        assert term.read_line() == "tail"
        assert term.read_key() == "QUIT"  # end of input
    finally:
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)


def test_provider_candidates_include_discovered_kits(monkeypatch, tmp_path):
    _state_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_KIT_SOURCE_SEED", json.dumps(
        [{"repository": "github.com/team/kits", "ref": "b" * 40},
         {"repository": "github.com/team/unpinned", "ref": ""}]))
    monkeypatch.setenv("ACQ_KIT_SOURCE_DISCOVERY", json.dumps(
        {"github.com/team/kits": ["team-provider", "team-provider"], "*": ["never"]}))
    assert configure.provider_kit_candidates() == [
        (PROVIDER_DEFAULT, f"{PROVIDER_DEFAULT} (shipped)"),
        (CONTROL_PLANE_USAI, f"{CONTROL_PLANE_USAI} (@{configure.kits.CONTROL_PLANE_REF})"),
        ("github.com/team/kits/team-provider", f"github.com/team/kits/team-provider (@{'b' * 40})"),
    ]


# ---------------------------------------------------------------------------
# A real terminal.
# ---------------------------------------------------------------------------

class _Pty:
    """``acq configure`` running on a pseudo-terminal; killed if a test fails."""

    def __init__(self, tmp_path, columns: str = "200"):
        import pty

        env = dict(os.environ, ACQ_STATE_DIR=str(tmp_path / "state"), COLUMNS=columns)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child: the pty is its controlling terminal and stdin
            try:
                os.execvpe(sys.executable, [sys.executable, "-m", "acq_py", "configure"], env)
            finally:
                os._exit(127)
        self.output = b""

    def _drain(self, wait: float) -> bool:
        """Read what is ready within ``wait`` seconds; False at end of output."""
        import select

        if not select.select([self.fd], [], [], wait)[0]:
            return True
        try:
            chunk = os.read(self.fd, 4096)
        except OSError:
            return False
        self.output += chunk
        return bool(chunk)

    def wait_for(self, marker: bytes, count: int = 1, timeout: float = 60) -> None:
        import time

        deadline = time.monotonic() + timeout
        while self.output.count(marker) < count and time.monotonic() < deadline:
            if not self._drain(0.2):
                break
        assert self.output.count(marker) >= count, self.output

    def send(self, data: bytes) -> None:
        os.write(self.fd, data)

    def signal(self, signum: int) -> None:
        os.kill(self.pid, signum)

    def exit_code(self, timeout: float = 30) -> int:
        """The child's exit code; the child is killed if it outlives ``timeout``."""
        import signal
        import time

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.pid = 0
                return os.waitstatus_to_exitcode(status)
            self._drain(0.1)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        self.pid = 0
        raise AssertionError(f"acq configure did not exit within {timeout}s: {self.output!r}")

    def assert_terminal_restored(self) -> None:
        """Echo and line mode are back on, and the hidden cursor was shown again."""
        import termios

        try:
            lflag = termios.tcgetattr(self.fd)[3]
        except termios.error:  # a platform whose pty master does not report the mode
            lflag = None
        if lflag is not None:
            assert lflag & termios.ECHO and lflag & termios.ICANON, "terminal left in key mode"
        assert self.output.rfind(b"\x1b[?25h") > self.output.rfind(b"\x1b[?25l") >= 0, self.output

    def close(self) -> None:
        import signal

        if self.pid:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


@POSIX_ONLY
def test_interactive_flow_on_a_pseudo_terminal(tmp_path):
    """Drive the real CLI on a pty with real keystrokes: raw keys for the lists,
    a typed line for the confirm."""
    path = _write_config(SEED)
    term = _Pty(tmp_path)
    try:
        term.wait_for(b"oci-engine")
        # The cursor starts on openchamber: check it, move to paseo and uncheck
        # it, then use the arrow-key escape to reach oci-engine and check it.
        term.send(b" j \x1b[B \r")
        term.wait_for(b"[y/N]")
        term.send(b"y\n")
        term.wait_for(b"q cancel)", count=2)
        term.send(b"j k \r")  # check the control-plane kit, uncheck the shipped default
        term.wait_for(b"configuration saved")
        assert term.exit_code() == 0, term.output
        term.assert_terminal_restored()
    finally:
        term.close()
    assert b"\x1b[?25l" in term.output and b"\x1b[?25h" in term.output
    assert b"y\r\n" in term.output  # the confirm answer is echoed; the keys are not
    assert path.read_bytes() == (b"schema: 1\nbackend: msb\n# hand-edited\ncustom_key: keep  # trailing\n"
                                 b"extra_kits: openchamber oci-engine\nscope_github_token: yes\n"
                                 b"provider_kit: " + CONTROL_PLANE_USAI.encode() + b"\n")


@POSIX_ONLY
def test_pseudo_terminal_q_cancels_and_rows_fit_the_width(tmp_path):
    path = _write_config(SEED)
    term = _Pty(tmp_path, columns="40")
    try:
        term.wait_for(b"oci-engine")
        term.send(b" q")
        term.wait_for(b"selection cancelled")
        assert term.exit_code() == 0, term.output
        term.assert_terminal_restored()
    finally:
        term.close()
    rows = [line for line in term.output.decode("utf-8", "replace").split("\r\n") if "[x]" in line or "[ ]" in line]
    assert rows and all(len(re.sub("\x1b\\[[0-9;?]*[A-Za-z]", "", row)) <= 40 for row in rows), rows
    assert path.read_bytes() == SEED


@POSIX_ONLY
@pytest.mark.parametrize("key,code", [(b"\x1b", 0), (b"\x03", 130)], ids=["lone-escape", "ctrl-c"])
def test_pseudo_terminal_escape_and_ctrl_c_restore_the_terminal(tmp_path, key, code):
    import time

    path = _write_config(SEED)
    term = _Pty(tmp_path)
    try:
        term.wait_for(b"oci-engine")
        sent = time.monotonic()
        term.send(b" " + key)  # toggle a row first: nothing may be written
        assert term.exit_code(timeout=15) == code, term.output
        assert time.monotonic() - sent < 15
        term.assert_terminal_restored()
    finally:
        term.close()
    if code == 0:
        assert b"selection cancelled" in term.output
    assert path.read_bytes() == SEED


@POSIX_ONLY
@pytest.mark.parametrize("signame", ["SIGTERM", "SIGHUP"])
def test_pseudo_terminal_sigterm_and_sighup_restore_the_terminal(tmp_path, signame):
    import signal

    signum = getattr(signal, signame)
    path = _write_config(SEED)
    term = _Pty(tmp_path)
    try:
        term.wait_for(b"oci-engine")
        term.send(b" ")
        term.wait_for(b"[x] openchamber")
        term.signal(signum)
        assert term.exit_code() == 128 + signum, term.output
        term.assert_terminal_restored()
    finally:
        term.close()
    assert path.read_bytes() == SEED


# ---------------------------------------------------------------------------
# Bash parity.
# ---------------------------------------------------------------------------

def _bash_env(tmp_path) -> dict:
    """A clean environment for the Bash acq: the redirected user dirs, no backend
    on PATH, and no trusted kit source to fetch (so provider discovery stays
    offline)."""
    keep = ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
            "ACQ_SECRET_STORE_DIR", "DBUS_SESSION_BUS_ADDRESS", "TMPDIR")
    env = {k: os.environ[k] for k in keep if k in os.environ}
    env.update(PATH="/usr/bin:/bin", ACQ_STATE_DIR=str(tmp_path / "state"), ACQ_KIT_SOURCES="none",
               HTTPS_PROXY="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9", GIT_TERMINAL_PROMPT="0")
    return env


def _python_script(tokens: list[str]) -> _Script:
    """The same answers for the Python widgets. Bash's confirm takes the next
    scripted token; its provider list (one row offline) replays the script from
    the start, where only SPACE and ENTER/QUIT matter."""
    end = next((i for i, t in enumerate(tokens) if t in ("ENTER", "QUIT")), len(tokens))
    kit_keys = tokens[: end + 1] if end < len(tokens) else [*tokens, "ENTER"]
    if len(tokens) == 1:  # a one-token script is a standalone confirm answer too
        answer = tokens[0]
    else:
        answer = tokens[end + 1] if end + 1 < len(tokens) else ""
    line = "" if answer in KEY_WORDS else answer + "\n"
    provider_keys = [t for t in kit_keys if t in ("SPACE", "ENTER", "QUIT")]
    return _Script([*kit_keys, *provider_keys], [line])


PARITY_CASES = [
    pytest.param(SEED, "DOWN SPACE DOWN SPACE ENTER y", id="swap-extras-scope-yes"),
    pytest.param(SEED + b"scope_github_token: yes\n", "SPACE ENTER n", id="add-extra-scope-no-provider-cleared"),
    pytest.param(None, "ENTER", id="fresh-config-defaults"),
    pytest.param(SEED, "SPACE QUIT", id="cancel"),
]


@needs_bash
@pytest.mark.parametrize("seed,script", PARITY_CASES)
def test_written_config_matches_bash(monkeypatch, tmp_path, capsys, seed, script):
    path = config.config_path()
    if seed is not None:
        _write_config(seed)
    env = _bash_env(tmp_path / "bash")
    env["ACQ_PROMPT_TEST_INPUT"] = script
    proc = subprocess.run([BASH, str(BASH_ACQ), "configure"], env=env, capture_output=True,
                          stdin=subprocess.DEVNULL, timeout=120, check=False)
    assert proc.returncode == 0, proc.stderr
    bash_bytes = path.read_bytes() if path.exists() else None

    if seed is not None:
        _write_config(seed)
    elif path.exists():
        path.unlink()
    _state_env(monkeypatch, tmp_path / "python")
    _python_script(script.split()).install(monkeypatch)
    assert _run(capsys, "configure")[0] == 0
    python_bytes = path.read_bytes() if path.exists() else None

    if seed is None:
        # The one deliberate difference: a config Python creates starts with the
        # schema marker (ADR-0041m); Bash's writer never adds it.
        assert python_bytes is not None and python_bytes.startswith(b"schema: 1\n")
        python_bytes = python_bytes[len(b"schema: 1\n"):]
    assert python_bytes == bash_bytes


@needs_bash
def test_kit_catalog_matches_bash():
    """The picker rows and the shipped provider default are copies of Bash data."""
    code = (
        'ACQ_SOURCE_ONLY=1 . "$1"; '
        'for i in "${!ACQ_KIT_NAMES[@]}"; do printf "B\\t%s\\t%s\\n" "${ACQ_KIT_NAMES[$i]}" "${ACQ_KIT_DESCS[$i]}"; done; '
        'for i in "${!ACQ_OPTIN_KIT_NAMES[@]}"; do printf "O\\t%s\\t%s\\n" "${ACQ_OPTIN_KIT_NAMES[$i]}" "${ACQ_OPTIN_KIT_DESCS[$i]}"; done; '
        'printf "P\\t%s\\n" "$ACQ_PROVIDER_KIT_DEFAULT"'
    )
    proc = subprocess.run([BASH, "-c", code, "bash", str(BASH_ACQ)], env=_bash_env(Path(os.environ["HOME"])),
                          capture_output=True, text=True, timeout=120, check=False)
    assert proc.returncode == 0, proc.stderr
    expected = [f"B\t{name}\t{configure.BUILTIN_KIT_DESCS[name]}" for name in configure.kits.BUILTIN_KIT_NAMES]
    expected += [f"O\t{name}\t{desc}" for name, desc in configure.OPTIN_KITS]
    expected += [f"P\t{configure.PROVIDER_KIT_DEFAULT}"]
    assert proc.stdout.splitlines() == expected
