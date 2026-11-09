"""Tier-2 tests for ``acq usai-rotate-api-key`` on msb and sbx (ADR-0012).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` in-process against
the deterministic ``__stub__`` backends. Rotation is a store write plus a
re-feed: the new key goes to the acq secret store, then to every running msb
sandbox (``msb modify --secret``, value in the child's environment only) and to
every sbx custom secret that carries it (``secret set-custom --placeholder P
--value-stdin``, value on the child's stdin only). A partial re-feed exits 1
naming the sandboxes that missed the key, and re-running the rotation fixes
them. The new key must never appear in output, in any argv element (checked as
a substring), or in any file acq or a stub writes outside the secret store.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, msb, sbx, secretstore

OLD = "S3NTINEL-old-usai-key-41d0"
NEW = "S3NTINEL-new-usai-key-9b7e"
USAI_FLAG = "USAI_API_KEY@api.gsa.usai.gov"
_CLEARED = (
    "ACQ_BACKEND", "ACQ_IMAGE", "ACQ_MSB_IMAGE", "ACQ_SECRET_NO_LIVE_REFEED",
    "ACQ_PROVIDER_CREDENTIAL_BINDINGS", "ACQ_PROVIDER_CREDENTIAL_SEED",
    "ACQ_MSB_STUB_CATALOG", "ACQ_MSB_STUB_FAIL", "ACQ_MSB_STUB_FAIL_ADD",
    "ACQ_SBX_STUB_CATALOG", "ACQ_SBX_STUB_SECRETS", "ACQ_SBX_STUB_CUSTOM_SECRETS",
    "ACQ_SBX_STUB_FAIL", "ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES",
    "USAI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "GITLAB_TOKEN",
)


def _base(monkeypatch, tmp_path, *, msb_on: bool, sbx_on: bool):
    for name in _CLEARED:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1" if msb_on else "0")
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1" if sbx_on else "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))


def _msb_running(monkeypatch, tmp_path, *names, sbx_on=False):
    """msb with ``names`` running and one stopped sandbox, and ``OLD`` stored."""
    _base(monkeypatch, tmp_path, msb_on=True, sbx_on=sbx_on)
    catalog = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    catalog.parent.mkdir(parents=True, exist_ok=True)
    catalog.write_text(json.dumps({n: "running" for n in names} | {"idle": "stopped"}), encoding="utf-8")
    msb.HeldRecord("idle", complete=True).save()
    secretstore.store(secretstore.key_for("usai"), OLD)


def _row(scope, placeholder):
    return {"scope": scope, "env": "USAI_API_KEY", "placeholder": placeholder, "targets": ["api.gsa.usai.gov"]}


def _sbx_rows(monkeypatch, tmp_path, *rows, msb_on=False):
    """sbx 0.51.0 whose custom-secrets table holds ``rows``, and ``OLD`` stored."""
    _base(monkeypatch, tmp_path, msb_on=msb_on, sbx_on=True)
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps(list(rows)))
    secretstore.store(secretstore.key_for("usai"), OLD)


def _sbx_table(tmp_path) -> list[dict]:
    path = tmp_path / "sbx-home" / ".docker-sbx" / "custom-secrets.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else []


@pytest.fixture
def msb_children(monkeypatch):
    """Record (argv, env) of every stub msb child process."""
    seen: list[tuple[list[str], dict]] = []
    real = subprocess.run

    def spy(argv, *args, **kwargs):
        if any("_stub_msb" in str(a) for a in argv):
            seen.append((list(argv), dict(kwargs.get("env") or {})))
        return real(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", spy)
    return seen


@pytest.fixture
def sbx_calls(monkeypatch):
    """Record (argv, stdin) of every sbx child the adapter starts."""
    seen: list[tuple[list[str], str | None]] = []
    real = sbx._run

    def spy(argv, *, timeout=None, input_text=None):
        seen.append((list(argv), input_text))
        return real(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", spy)
    return seen


def _rotate(capsys, monkeypatch, backend, *, value=NEW, json_out=True):
    monkeypatch.setattr(sys, "stdin", io.StringIO(value + "\n"))
    rc = cli.main(["--backend", backend, "usai-rotate-api-key"] + (["--json"] if json_out else []))
    out, err = capsys.readouterr()
    doc = json.loads(out) if json_out and out.strip() else None
    return rc, doc, out, err


def _assert_never_leaked(tmp_path, argvs, *streams):
    """``NEW`` is in no argv element (as a substring), stream, or written file
    outside the acq secret store (state records, stub tables, logs)."""
    for argv in argvs:
        for element in argv:
            assert NEW not in str(element), f"new key leaked into argv element {element!r}"
    for text in streams:
        assert NEW not in text
    # The conftest redirects HOME, XDG_* and the store under one throwaway root.
    store = Path(os.environ["ACQ_SECRET_STORE_DIR"]).resolve()
    for root in (Path(tmp_path), store.parent):
        for path in root.rglob("*"):
            if path.is_file() and store not in path.resolve().parents:
                assert NEW.encode() not in path.read_bytes(), f"new key written to {path}"


def _modified(children) -> dict[str, dict]:
    """``{sandbox: env}`` for every ``msb modify NAME --secret USAI...``."""
    return {argv[argv.index("modify") + 1]: env for argv, env in children
            if "modify" in argv and USAI_FLAG in argv}


# ---------------------------------------------------------------------------
# msb
# ---------------------------------------------------------------------------

def test_msb_rotation_stores_and_refeeds_every_running_sandbox(monkeypatch, tmp_path, capsys, msb_children):
    _msb_running(monkeypatch, tmp_path, "a", "b")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 0, (out, err)
    assert doc["data"]["rotated"] is True
    assert doc["data"]["backends"] == [{"backend": "msb", "refed": ["a", "b"], "kept_own": []}]
    assert secretstore.resolve("usai") == NEW
    fed = _modified(msb_children)
    assert sorted(fed) == ["a", "b"]  # the stopped sandbox is not touched
    assert all(env["USAI_API_KEY"] == NEW for env in fed.values())
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children], out, err)


def test_msb_rotation_keeps_a_sandbox_own_key(monkeypatch, tmp_path, capsys, msb_children):
    _msb_running(monkeypatch, tmp_path, "a", "b")
    secretstore.store(secretstore.key_for("usai", "a"), OLD)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 0, (out, err)
    assert doc["data"]["backends"] == [{"backend": "msb", "refed": ["b"], "kept_own": ["a"]}]
    assert sorted(_modified(msb_children)) == ["b"]
    assert secretstore.resolve("usai", "a") == OLD


def test_msb_partial_refeed_exits_1_naming_the_sandbox_then_retry_fixes_it(
    monkeypatch, tmp_path, capsys, msb_children
):
    _msb_running(monkeypatch, tmp_path, "a", "b")
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "b")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1
    message = doc["error"]["message"]
    assert "(msb: not re-fed: b (msb modify failed); re-fed: a)" in message
    assert "re-run 'acq usai-rotate-api-key'" in doc["error"]["remediation"]
    assert secretstore.resolve("usai") == NEW  # stored, so a retry re-feeds it
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children], out, err)

    monkeypatch.delenv("ACQ_MSB_STUB_FAIL_ADD")
    msb_children.clear()
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 0, (out, err)
    fed = _modified(msb_children)
    assert fed["b"]["USAI_API_KEY"] == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children], out, err)


def test_msb_rotation_human_output_never_shows_the_key(monkeypatch, tmp_path, capsys, msb_children):
    _msb_running(monkeypatch, tmp_path, "a")
    rc, _doc, out, err = _rotate(capsys, monkeypatch, "msb", json_out=False)
    assert rc == 0, err
    assert "rotated the USAi API key" in out and "msb: re-fed a" in out
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children], out, err)


# ---------------------------------------------------------------------------
# sbx
# ---------------------------------------------------------------------------

def _set_customs(calls) -> dict[str, tuple[list[str], str | None]]:
    """``{scope: (argv, stdin)}`` for every ``sbx secret set-custom``."""
    out = {}
    for argv, stdin in calls:
        if argv[:2] == ["secret", "set-custom"]:
            scope = argv[argv.index("--sandbox") + 1] if "--sandbox" in argv else "global"
            out[scope] = (argv, stdin)
    return out


def test_sbx_rotation_resets_each_entry_keeping_its_placeholder(monkeypatch, tmp_path, capsys, sbx_calls):
    rows = [_row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1")]
    _sbx_rows(monkeypatch, tmp_path, *rows)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert doc["data"]["backends"] == [{"backend": "sbx", "refed": ["a"], "kept_own": []}]
    assert secretstore.resolve("usai") == NEW
    sets = _set_customs(sbx_calls)
    assert sorted(sets) == ["a", "global"]
    for scope, placeholder in (("global", "sbx-cs-g1"), ("a", "sbx-cs-a1")):
        argv, stdin = sets[scope]
        assert argv[argv.index("--placeholder") + 1] == placeholder
        assert "--value-stdin" in argv and stdin == NEW
    assert sorted(_sbx_table(tmp_path), key=lambda r: r["scope"]) == sorted(rows, key=lambda r: r["scope"])
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_rotation_keeps_a_sandbox_own_key(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"))
    secretstore.store(secretstore.key_for("usai", "a"), OLD)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert doc["data"]["backends"] == [{"backend": "sbx", "refed": [], "kept_own": ["a"]}]
    assert sorted(_set_customs(sbx_calls)) == ["global"]


def test_sbx_rotation_creates_the_global_entry_when_there_is_none(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path)
    rc, _doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert [(r["scope"], r["env"]) for r in _sbx_table(tmp_path)] == [("global", "USAI_API_KEY")]
    assert _set_customs(sbx_calls)["global"][1] == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_partial_refeed_exits_1_naming_the_sandbox_then_retry_fixes_it(
    monkeypatch, tmp_path, capsys, sbx_calls
):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"), _row("b", "sbx-cs-b1"))
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES", "b")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    message = doc["error"]["message"]
    assert "(sbx: not re-fed: sandbox b; re-fed: a)" in message
    assert "re-run 'acq usai-rotate-api-key'" in doc["error"]["remediation"]
    assert secretstore.resolve("usai") == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)

    monkeypatch.delenv("ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES")
    sbx_calls.clear()
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert doc["data"]["backends"][0]["refed"] == ["a", "b"]
    assert _set_customs(sbx_calls)["b"][1] == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_global_entry_failure_exits_1(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"))
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES", "global")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert "the global USAi secret" in doc["error"]["message"]
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_rotation_below_0_51_is_refused_with_nothing_changed(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"))
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.39.0")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert doc["error"]["code"] == "backend_version_unsupported"
    assert secretstore.resolve("usai") == OLD
    assert _set_customs(sbx_calls) == {}
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_duplicate_global_entries_are_refused_with_nothing_changed(monkeypatch, tmp_path, capsys, sbx_calls):
    rows = [_row("global", "sbx-cs-g1"), _row("global", "sbx-cs-g2")]
    _sbx_rows(monkeypatch, tmp_path, *rows)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert "sbx-cs-g1" in doc["error"]["remediation"] and "sbx-cs-g2" in doc["error"]["remediation"]
    assert secretstore.resolve("usai") == OLD
    assert _set_customs(sbx_calls) == {}


# ---------------------------------------------------------------------------
# Both backends installed: the shared store means both are re-fed.
# ---------------------------------------------------------------------------

def test_rotation_on_msb_also_refeeds_installed_sbx(monkeypatch, tmp_path, capsys, msb_children, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps([_row("global", "sbx-cs-g1")]))
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 0, (out, err)
    assert [b["backend"] for b in doc["data"]["backends"]] == ["msb", "sbx"]
    assert _modified(msb_children)["a"]["USAI_API_KEY"] == NEW
    assert _set_customs(sbx_calls)["global"][1] == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children + sbx_calls], out, err)


def test_rotation_on_msb_leaves_sbx_without_a_usai_entry_alone(monkeypatch, tmp_path, capsys, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    rc, _doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 0, (out, err)
    assert _set_customs(sbx_calls) == {} and _sbx_table(tmp_path) == []


def test_rotation_names_the_other_backend_when_it_fails(monkeypatch, tmp_path, capsys, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps([_row("global", "sbx-cs-g1")]))
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES", "global")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1
    assert "(sbx: not re-fed: the global USAi secret" in doc["error"]["message"]
    assert secretstore.resolve("usai") == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)
