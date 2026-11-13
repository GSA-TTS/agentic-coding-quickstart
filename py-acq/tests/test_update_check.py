"""Tier-2 tests for the stale-sandbox check on ``run`` and ``--no-update-check`` (ADR-0016).

A port of Bash ``maybe_offer_bundle_refresh``: on a re-attach, a sandbox whose
recorded kit bundle is not the pinned one (``stale``) or is unrecorded
(``unknown``) gets an advisory; at a terminal it is asked ``[y/N]``. The check is
purely local (an exact-ref comparison), so these tests make no network call.
"""

from __future__ import annotations

import io
import json

import pytest

from acq_py import cli, kits, security
from acq_py.commands import common, kit, lifecycle

pytestmark = pytest.mark.provider_key

STALE_NOTE = "was built from an older kit bundle than your pinned"
UNKNOWN_NOTE = "acq cannot confirm 'box' is on your pinned kit bundle"
LATER = "      To refresh later: acq kit update box"
SILENCE = "      To silence this check: ACQ_UPDATE_CHECK=0 (or acq run --no-update-check)."


def _env(monkeypatch, tmp_path):
    monkeypatch.setattr(security, "WINDOWS", False)
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_UPDATE_CHECK", kits.PROVENANCE_SEED_ENV):
        monkeypatch.delenv(name, raising=False)
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    monkeypatch.setattr(lifecycle, "_launch_after_envelope", lambda *a, **k: 0)
    return ws


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    return rc, captured.out, captured.err


def _created(monkeypatch, tmp_path, capsys, seed: str | None = "0" * 40):
    ws = _env(monkeypatch, tmp_path)
    rc, _, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0, err
    if seed is not None:
        # The seed replaces the recorded provenance, so the heal cannot make it current.
        monkeypatch.setenv(kits.PROVENANCE_SEED_ENV, json.dumps({"box": seed}))
    return ws


def _tty(monkeypatch, answer: str):
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr("sys.stdin", io.StringIO(answer))


@pytest.mark.parametrize("form", ["agent", "name"])
def test_a_stale_sandbox_gets_the_advisory_without_a_terminal(monkeypatch, tmp_path, capsys, form):
    ws = _created(monkeypatch, tmp_path, capsys)
    argv = ["run", "shell", str(ws), "--name", "box"] if form == "agent" else ["run", "box"]
    rc, out, err = _invoke(capsys, "--backend", "msb", *argv)
    assert rc == 0
    assert f"acq: note: 'box' {STALE_NOTE}" in err
    assert f"(local patterns ref {kits.CONTROL_PLANE_REF})." in err
    assert LATER in err and SILENCE in err
    assert "[y/N]" not in err and "[y/N]" not in out


def test_an_unrecorded_bundle_is_reported_as_unknown(monkeypatch, tmp_path, capsys):
    _created(monkeypatch, tmp_path, capsys, seed=None)
    monkeypatch.setenv(kits.PROVENANCE_SEED_ENV, json.dumps({}))
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0 and UNKNOWN_NOTE in err and LATER in err


def test_a_current_sandbox_gets_nothing(monkeypatch, tmp_path, capsys):
    _created(monkeypatch, tmp_path, capsys, seed=kits.CONTROL_PLANE_REF)
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0 and "kit bundle" not in err


@pytest.mark.parametrize("how", ["flag", "env"])
def test_the_check_can_be_switched_off(monkeypatch, tmp_path, capsys, how):
    ws = _created(monkeypatch, tmp_path, capsys)
    _tty(monkeypatch, "y\n")
    monkeypatch.setattr(lifecycle, "_refresh_bundle", lambda *a: pytest.fail("refreshed"))
    extra = ["--no-update-check"] if how == "flag" else []
    if how == "env":
        monkeypatch.setenv("ACQ_UPDATE_CHECK", "0")
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "box", *extra)
    assert rc == 0 and STALE_NOTE not in err


def test_only_zero_switches_it_off(monkeypatch, tmp_path, capsys):
    _created(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_UPDATE_CHECK", "no")
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0 and STALE_NOTE in err


def test_create_accepts_the_flag(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    rc, _, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box",
                         "--no-update-check", "--json")
    assert rc == 0, err


def test_json_never_prompts_even_at_a_terminal(monkeypatch, tmp_path, capsys):
    _created(monkeypatch, tmp_path, capsys)
    monkeypatch.setattr(common, "_stdin_is_terminal", lambda: True)
    monkeypatch.setattr("sys.stdin", io.StringIO(""))
    monkeypatch.setattr(lifecycle, "_refresh_bundle", lambda *a: pytest.fail("refreshed"))
    rc, out, err = _invoke(capsys, "--backend", "msb", "run", "box", "--json")
    assert rc == 0
    assert json.loads(out.strip().splitlines()[-1])["command"] == "run"
    assert "[y/N]" not in err and LATER in err


@pytest.mark.parametrize("answer", ["y\n", "Y\n", "yes\n", "YES\n"])
def test_a_yes_at_a_terminal_refreshes(monkeypatch, tmp_path, capsys, answer):
    _created(monkeypatch, tmp_path, capsys)
    _tty(monkeypatch, answer)
    calls = []
    monkeypatch.setattr(lifecycle, "_refresh_bundle", lambda backend, name: calls.append((backend, name)))
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0 and calls == [("msb", "box")]
    assert "acq: refresh the kit bundle in box now? [y/N] " in err


@pytest.mark.parametrize("answer", ["", "\n", "n\n", "yep\n"])
def test_anything_else_declines_and_the_run_goes_on(monkeypatch, tmp_path, capsys, answer):
    _created(monkeypatch, tmp_path, capsys)
    _tty(monkeypatch, answer)
    monkeypatch.setattr(lifecycle, "_refresh_bundle", lambda *a: pytest.fail("refreshed"))
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0
    assert "acq: continuing without refreshing (run 'acq kit update box' anytime)." in err


def test_the_refresh_reapplies_through_kit_update_and_never_fails_the_run(monkeypatch, tmp_path, capsys):
    _created(monkeypatch, tmp_path, capsys)
    _tty(monkeypatch, "y\n")
    seen = []

    def failing(name, emit_json, backend):
        seen.append((name, emit_json, backend))
        return 1

    monkeypatch.setattr(kit, "_kit_update_locked", failing)
    rc, out, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0 and seen == [("box", False, "msb")]
    assert "acq: refreshing the built-in kit bundle in 'box' (in place; state preserved)..." in err
    assert "acq: warning: kit refresh for 'box' did not complete cleanly; leaving it as-is." in err


def test_a_successful_refresh_reports_on_stderr(monkeypatch, tmp_path, capsys):
    _created(monkeypatch, tmp_path, capsys)
    _tty(monkeypatch, "y\n")

    def ok(name, emit_json, backend):
        print("refreshed")
        return 0

    monkeypatch.setattr(kit, "_kit_update_locked", ok)
    rc, out, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0 and "refreshed" in err and "refreshed" not in out and "did not complete" not in err


def test_the_status_is_read_before_the_heal_records_the_bundle_current(monkeypatch, tmp_path, capsys):
    _created(monkeypatch, tmp_path, capsys, seed=None)
    path = kits._provenance_path("msb", "box")
    doc = json.loads(path.read_text(encoding="utf-8"))
    path.write_text(json.dumps({**doc, "applied_ref": "0" * 40}), encoding="utf-8")
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "box")
    assert rc == 0 and STALE_NOTE in err
    assert kits.provenance_status("msb", "box") == "current"  # the heal still ran
