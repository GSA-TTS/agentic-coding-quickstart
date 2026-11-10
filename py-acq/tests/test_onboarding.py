"""Tier-2 tests for the create-time prompts (ADR-0031): the first-run offer and the kit picker.

Ports of Bash ``maybe_first_run_configure`` and ``create_time_kit_picker``. They
prompt only where Bash's ``_acq_prompt_interactive`` would (stdin a terminal,
``ACQ_NO_PROMPT``/``ACQ_NO_PROGRESS`` unset), and never under ``--json``. Keys and
lines are scripted by replacing the terminal reads; the opt-in kits are not
fetched (the kit selection is recorded, then resolved without them).
"""

from __future__ import annotations

import collections
import json

import pytest

from acq_py import cli, config, hostexec, kit_msb, kitspec, security, state
from acq_py.commands import common, configure

pytestmark = pytest.mark.provider_key

REF = {name: kitspec.builtin_kit_ref(name) for name, _ in configure.OPTIN_KITS}


def _env(monkeypatch, tmp_path, backend="msb"):
    monkeypatch.setattr(security, "WINDOWS", False)
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1" if backend == "msb" else "0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1" if backend == "sbx" else "0")
    for name in ("ACQ_BACKEND", "ACQ_EXTRA_KITS", "ACQ_NO_PROMPT", "ACQ_NO_PROGRESS", "ACQ_MSB_STUB_CATALOG"):
        monkeypatch.delenv(name, raising=False)
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


class _Terminal:
    """Scripted stdin: keys for the checkbox list, lines for the confirm."""

    def __init__(self, monkeypatch, keys=(), lines=()):
        self.keys = collections.deque(keys)
        self.lines = collections.deque(lines)
        self.keys_asked = 0
        self.lines_asked = 0
        monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
        monkeypatch.setattr(configure.Terminal, "read_key", lambda term: self._key())
        monkeypatch.setattr(configure.Terminal, "read_line", lambda term: self._line())

    @property
    def asked(self):
        return self.keys_asked + self.lines_asked

    def _key(self):
        self.keys_asked += 1
        return self.keys.popleft() if self.keys else "QUIT"

    def _line(self):
        self.lines_asked += 1
        return self.lines.popleft()


def _selections(monkeypatch, module=kit_msb):
    """Record the ``extras`` each kit selection gets, then select without fetching opt-in kits."""
    seen = []
    real = module.select

    def select(agent, cli_kits, *, image_is_default, extras=None):
        seen.append(extras)
        return real(agent, cli_kits, image_is_default=image_is_default, extras=None if extras is None else [])

    monkeypatch.setattr(module, "select", select)
    return seen


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    last = out.splitlines()[-1] if out else ""
    return rc, (json.loads(last) if last.startswith("{") else None), captured.err


def _write_config(text: str):
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# The first-run offer.
# ---------------------------------------------------------------------------


def test_declining_the_first_run_offer_records_the_backend_and_creates(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    term = _Terminal(monkeypatch, keys=["QUIT"], lines=["n\n"])
    rc, _, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fr")
    assert rc == 0, err
    assert "acq: looks like this is your first run — let's set up your kits." in err
    assert "Configure extra kits and token scoping now? [Y/n]" in err
    assert "acq: skipped. Run 'acq configure' anytime to change kits/token scoping." in err
    assert config.read_field("backend") == "msb"
    assert state.record_read("msb", "fr") is not None
    assert term.lines_asked == 1


def test_accepting_runs_configure_then_creates(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    _Terminal(monkeypatch, keys=["QUIT"], lines=["\n"])  # Enter takes the default: yes
    ran = []
    monkeypatch.setattr(configure, "run_configure", lambda *a: ran.append(a) or 0)
    rc, _, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fr")
    assert rc == 0 and len(ran) == 1, err
    assert ran[0][0] is False  # the human flow, never --json
    assert state.record_read("msb", "fr") is not None


def test_an_interrupted_configure_stops_the_create(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    _Terminal(monkeypatch, lines=["y\n"])
    monkeypatch.setattr(configure, "run_configure", lambda *a: 130)
    rc, _, _ = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fr")
    assert rc == 130 and state.record_read("msb", "fr") is None


def test_no_offer_once_a_config_exists(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    _write_config("schema: 1\n")
    term = _Terminal(monkeypatch, keys=["QUIT"])
    rc, _, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fr")
    assert rc == 0 and "first run" not in err and term.lines_asked == 0


@pytest.mark.parametrize("how", ["no-tty", "json", "no-prompt", "no-progress"])
def test_no_prompt_without_a_terminal_under_json_or_when_opted_out(monkeypatch, tmp_path, capsys, how):
    ws = _env(monkeypatch, tmp_path)
    term = _Terminal(monkeypatch)
    if how == "no-tty":
        monkeypatch.setattr(common, "_stdin_is_terminal", lambda: False)
    if how == "no-prompt":
        monkeypatch.setenv("ACQ_NO_PROMPT", "1")
    if how == "no-progress":
        monkeypatch.setenv("ACQ_NO_PROGRESS", "1")
    extra = ["--json"] if how == "json" else []
    rc, _, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fr", *extra)
    assert rc == 0, err
    assert term.asked == 0 and "first run" not in err
    assert not config.config_path().exists()


def test_a_windows_nul_stdin_is_not_a_terminal(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    term = _Terminal(monkeypatch)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: hostexec.stream_is_terminal(_Nul()))
    monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
    monkeypatch.setattr(hostexec, "_windows_console", lambda fd: False)
    rc, _, _ = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fr")
    assert rc == 0 and term.asked == 0


class _Nul:
    def isatty(self):
        return True

    def fileno(self):
        return 0


def test_run_offers_on_a_fresh_create_but_not_on_a_reattach(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setattr("acq_py.commands.lifecycle._launch_after_envelope", lambda *a, **k: 0)
    term = _Terminal(monkeypatch, keys=["QUIT"], lines=["n\n"])
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "fr")
    assert rc == 0 and "first run" in err and term.lines_asked == 1
    config.config_path().unlink()
    before = term.asked
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "fr")
    assert rc == 0 and "first run" not in err and term.asked == before
