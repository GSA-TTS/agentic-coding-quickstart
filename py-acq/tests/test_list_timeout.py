"""Tier-2 tests for the bounded backend listing calls (``timeouts.list_timeout_s``).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` and the adapters
in-process against the deterministic ``__stub__`` backends, with
``subprocess.run`` patched to time out on the listing calls. A backend whose
listing hangs must make ``acq ls`` fail with a clear ``timeout`` error, never
wait forever; the contract side is ``cli/ls-list-timeout-msb``.
"""

from __future__ import annotations

import json
import subprocess

import pytest

from acq_py import cli, errors, msb, sbx, timeouts


def _env(monkeypatch, tmp_path):
    for name in ("ACQ_BACKEND", "ACQ_LIST_TIMEOUT", "ACQ_MSB_STUB_CATALOG", "ACQ_SBX_STUB_CATALOG",
                 "ACQ_MSB_STUB_FAIL", "ACQ_SBX_STUB_FAIL"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))


@pytest.fixture
def hang(monkeypatch):
    """Make every listing child time out; record the timeout each call was given."""
    budgets: list[float | None] = []
    real = subprocess.run

    def fake(argv, *args, **kwargs):
        tail = [str(a) for a in argv]
        if "list" in tail or "ls" in tail:
            budgets.append(kwargs.get("timeout"))
            raise subprocess.TimeoutExpired(list(argv), kwargs.get("timeout") or 0)
        return real(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", fake)
    return budgets


@pytest.mark.parametrize("backend, listing", [("msb", "msb list"), ("sbx", "sbx ls")])
def test_ls_fails_with_a_timeout_when_the_listing_hangs(monkeypatch, tmp_path, capsys, hang, backend, listing):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_LIST_TIMEOUT", "7")
    rc = cli.main(["--backend", backend, "ls", "--json"])
    doc = json.loads(capsys.readouterr().out)
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert doc["error"]["message"] == f"'{listing}' did not answer within 7s"
    assert "ACQ_LIST_TIMEOUT" in doc["error"]["remediation"]
    assert hang == [7.0]


def test_ls_human_output_names_the_timeout(monkeypatch, tmp_path, capsys, hang):
    _env(monkeypatch, tmp_path)
    assert cli.main(["--backend", "msb", "ls"]) == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert "'msb list' did not answer within 60s" in err
    assert hang == [timeouts.DEFAULT_LIST_TIMEOUT_S]


@pytest.mark.parametrize("call", [
    msb.list_names, msb.running_names, sbx.list_names, sbx.running_names,
])
def test_every_listing_call_is_bounded_by_default(monkeypatch, tmp_path, hang, call):
    _env(monkeypatch, tmp_path)
    with pytest.raises((msb.MsbError, sbx.SbxError)) as info:
        call()
    assert info.value.code == errors.TIMEOUT
    assert hang == [timeouts.DEFAULT_LIST_TIMEOUT_S]


@pytest.mark.parametrize("call", [msb.list_names, msb.running_names, sbx.list_names])
def test_an_explicit_timeout_still_raises_timeout_expired(monkeypatch, tmp_path, hang, call):
    # Rotation passes its own budget and reports the timeout itself.
    _env(monkeypatch, tmp_path)
    with pytest.raises(subprocess.TimeoutExpired):
        call(timeout=3)
    assert hang == [3]


@pytest.mark.parametrize("raw", ["0", "-1", "nan", "soon"])
def test_an_invalid_list_timeout_falls_back_to_the_default(monkeypatch, capsys, raw):
    monkeypatch.setenv("ACQ_LIST_TIMEOUT", raw)
    assert timeouts.list_timeout_s() == timeouts.DEFAULT_LIST_TIMEOUT_S
    assert "ignoring ACQ_LIST_TIMEOUT" in capsys.readouterr().err
