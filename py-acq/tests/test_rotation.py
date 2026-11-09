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

from acq_py import cli, errors, lock, msb, sbx, secretstore

OLD = "S3NTINEL-old-usai-key-41d0"
NEW = "S3NTINEL-new-usai-key-9b7e"
USAI_FLAG = "USAI_API_KEY@api.gsa.usai.gov"
_CLEARED = (
    "ACQ_BACKEND", "ACQ_IMAGE", "ACQ_MSB_IMAGE", "ACQ_SECRET_NO_LIVE_REFEED",
    "ACQ_PROVIDER_CREDENTIAL_BINDINGS", "ACQ_PROVIDER_CREDENTIAL_SEED",
    "ACQ_MSB_STUB_CATALOG", "ACQ_MSB_STUB_FAIL", "ACQ_MSB_STUB_FAIL_ADD",
    "ACQ_SBX_STUB_CATALOG", "ACQ_SBX_STUB_SECRETS", "ACQ_SBX_STUB_CUSTOM_SECRETS",
    "ACQ_SBX_STUB_FAIL", "ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES", "ACQ_SBX_STUB_PLACEHOLDER_MODE", "ACQ_SANDBOX_LOCK_TIMEOUT",
    "ACQ_ROTATE_TIMEOUT",
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


def _msb_catalog(tmp_path, sandboxes: dict[str, str]) -> None:
    """The stub msb's sandboxes, ``{name: state}``."""
    catalog = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    catalog.parent.mkdir(parents=True, exist_ok=True)
    catalog.write_text(json.dumps(sandboxes), encoding="utf-8")


def _usai_record(name: str) -> None:
    """acq's binding record saying sandbox ``name`` holds the global USAi key."""
    rec = msb.HeldRecord(name, complete=True)
    rec.bindings["USAI_API_KEY"] = {"service": "usai", "host": "api.gsa.usai.gov", "scope": "global"}
    rec.save()


def _msb_running(monkeypatch, tmp_path, *names, sbx_on=False):
    """msb with ``names`` running and one stopped sandbox, and ``OLD`` stored."""
    _base(monkeypatch, tmp_path, msb_on=True, sbx_on=sbx_on)
    _msb_catalog(tmp_path, {n: "running" for n in names} | {"idle": "stopped"})
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


def _res(backend, refed, *, kept=(), missed=(), glob=None):
    out = {"backend": backend, "refed": list(refed), "kept_own": list(kept), "not_refed": list(missed)}
    return out if glob is None else out | {"global": glob}


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
    assert doc["data"]["backends"] == [_res("msb", ["a", "b"])]
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
    assert doc["data"]["backends"] == [_res("msb", ["b"], kept=["a"])]
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
    assert doc["error"]["backends"] == [_res("msb", ["a"], missed=["b (msb modify failed)"])]
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
    assert "rotated the USAi API key" in out and "msb: re-fed: a" in out
    assert "stopped sandboxes are not re-fed" in out
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
    assert doc["data"]["backends"] == [_res("sbx", ["a"], glob="updated")]
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
    assert doc["data"]["backends"] == [_res("sbx", [], kept=["a"], glob="updated")]
    assert sorted(_set_customs(sbx_calls)) == ["global"]


def test_sbx_rotation_creates_the_global_entry_when_there_is_none(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert doc["data"]["backends"] == [_res("sbx", [], glob="created")]
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
    assert "(sbx: not re-fed: sandbox b (sbx secret set-custom failed); re-fed: the global USAi secret, a)" in message
    assert doc["error"]["backends"] == [
        _res("sbx", ["a"], missed=["sandbox b (sbx secret set-custom failed)"], glob="updated")
    ]
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


# ---------------------------------------------------------------------------
# Every backend is checked before anything is stored.
# ---------------------------------------------------------------------------

def test_a_refusal_from_the_other_backend_changes_nothing(monkeypatch, tmp_path, capsys, msb_children, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    dupes = [_row("global", "sbx-cs-g1"), _row("global", "sbx-cs-g2")]
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps(dupes))
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1
    assert "nothing was changed" in doc["error"]["remediation"] and "ADR-0008" in doc["error"]["remediation"]
    assert secretstore.resolve("usai") == OLD
    assert _modified(msb_children) == {} and _set_customs(sbx_calls) == {}
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children + sbx_calls], out, err)


# ---------------------------------------------------------------------------
# sbx must keep the placeholder running sandboxes were injected with.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("mode", ["mint", "duplicate"])
def test_sbx_entry_that_lost_its_placeholder_is_not_re_fed(monkeypatch, tmp_path, capsys, sbx_calls, mode):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"))
    monkeypatch.setenv("ACQ_SBX_STUB_PLACEHOLDER_MODE", mode)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    lost = "sbx did not keep a single entry with its placeholder"
    missed = doc["error"]["backends"][0]["not_refed"]
    assert missed == [f"the global USAi secret (used by every sbx sandbox without its own entry) ({lost})",
                      f"sandbox a ({lost})"]
    assert doc["error"]["backends"][0]["refed"] == []
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


# ---------------------------------------------------------------------------
# An installed backend below acq's version floor.
# ---------------------------------------------------------------------------

def test_a_below_floor_backend_holding_the_key_is_not_re_fed(monkeypatch, tmp_path, capsys, msb_children, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.38.0")
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps([_row("global", "sbx-cs-g1")]))
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1
    assert [b["backend"] for b in doc["error"]["backends"]] == ["msb", "sbx"]
    msb_result, sbx_result = doc["error"]["backends"]
    assert msb_result == _res("msb", ["a"])
    assert sbx_result["refed"] == [] and "0.38.0" in sbx_result["not_refed"][0]
    assert "upgrade sbx" in doc["error"]["remediation"]
    assert _modified(msb_children)["a"]["USAI_API_KEY"] == NEW
    assert _set_customs(sbx_calls) == {}
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children + sbx_calls], out, err)


def test_a_below_floor_backend_without_the_key_is_skipped(monkeypatch, tmp_path, capsys, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.38.0")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 0, (out, err)
    sbx_result = doc["data"]["backends"][1]
    assert sbx_result["backend"] == "sbx" and sbx_result["not_refed"] == [] and "0.38.0" in sbx_result["skipped"]


def test_a_below_floor_msb_holding_the_key_is_not_re_fed(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), msb_on=True)
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.6.0")
    _msb_catalog(tmp_path, {"old-box": "stopped"})
    _usai_record("old-box")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert doc["error"]["backends"][0] == _res("sbx", [], glob="updated")
    assert doc["error"]["backends"][1]["backend"] == "msb" and doc["error"]["backends"][1]["not_refed"]
    assert _set_customs(sbx_calls)["global"][1] == NEW


# ---------------------------------------------------------------------------
# One sandbox's failure does not stop the others.
# ---------------------------------------------------------------------------

def test_msb_unreadable_record_fails_only_that_sandbox(monkeypatch, tmp_path, capsys, msb_children):
    _msb_running(monkeypatch, tmp_path, "a", "b")
    msb.held_path("a").parent.mkdir(parents=True, exist_ok=True)
    msb.held_path("a").write_text("{not json", encoding="utf-8")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1
    result = doc["error"]["backends"][0]
    assert result["refed"] == ["b"] and result["not_refed"][0].startswith("a (cannot read the record")
    assert _modified(msb_children)["b"]["USAI_API_KEY"] == NEW


def test_sbx_backend_error_fails_only_that_sandbox(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"), _row("b", "sbx-cs-b1"))
    real = sbx._run

    def flaky(argv, *, timeout=None, input_text=None):
        if argv[:2] == ["secret", "set-custom"] and "--sandbox" in argv and argv[argv.index("--sandbox") + 1] == "a":
            raise sbx.SbxError(errors.TIMEOUT, "sbx timed out", None)
        return real(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", flaky)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert doc["error"]["backends"] == [_res("sbx", ["b"], missed=["sandbox a (sbx timed out)"], glob="updated")]
    assert NEW not in out + err


# ---------------------------------------------------------------------------
# Rotation, and global usai set/rm, serialize on the usai provider lock.
# ---------------------------------------------------------------------------

def test_rotation_waits_for_the_usai_provider_lock(monkeypatch, tmp_path, capsys, msb_children):
    _msb_running(monkeypatch, tmp_path, "a")
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.2")
    with lock.provider_credential_lock("usai"):
        rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1 and doc["error"]["code"] == errors.TIMEOUT
    assert secretstore.resolve("usai") == OLD and _modified(msb_children) == {}
    assert NEW not in out + err


@pytest.mark.parametrize("argv, takes_lock", [
    (["secret", "set", "-g", "usai"], True),
    (["secret", "rm", "-g", "usai"], True),
    (["secret", "set", "-g", "github"], False),
    (["secret", "set", "box", "usai"], False),
])
def test_global_usai_set_and_rm_take_the_usai_provider_lock(monkeypatch, tmp_path, capsys, argv, takes_lock):
    _msb_running(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.2")
    monkeypatch.setattr(sys, "stdin", io.StringIO(NEW + "\n"))
    with lock.provider_credential_lock("usai"):
        rc = cli.main(["--backend", "msb", *argv, "--json"])
    doc = json.loads(capsys.readouterr().out)
    if takes_lock:
        assert rc == 1 and doc["error"]["code"] == errors.TIMEOUT
        assert secretstore.resolve("usai") == OLD
    else:
        assert rc == 0, doc


# ---------------------------------------------------------------------------
# An sbx whose secret list cannot be read: msb still rotates, sbx is named.
# ---------------------------------------------------------------------------

_UNLISTED = "any sandbox holding the key (acq could not read sbx's secret list: "


def test_unreadable_sbx_list_does_not_block_rotation_on_msb(monkeypatch, tmp_path, capsys, msb_children, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", "b", sbx_on=True)
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps([_row("global", "sbx-cs-g1")]))
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret ls")
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "b")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1
    assert secretstore.resolve("usai") == NEW
    msb_result, sbx_result = doc["error"]["backends"]
    assert msb_result == _res("msb", ["a"], missed=["b (msb modify failed)"])
    assert sbx_result == _res("sbx", [], missed=[_UNLISTED + "could not read the secret store)"])
    assert "sbx: not re-fed: " + _UNLISTED in doc["error"]["message"]
    # Every backend's remediation is shown, not only the first one.
    remediation = doc["error"]["remediation"]
    assert "re-run 'acq usai-rotate-api-key' with the same key to retry" in remediation
    assert "once 'sbx secret ls --json' works again" in remediation
    assert _modified(msb_children)["a"]["USAI_API_KEY"] == NEW
    assert _set_customs(sbx_calls) == {}
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children + sbx_calls], out, err)


def test_unreadable_sbx_list_human_output_shows_every_remediation(monkeypatch, tmp_path, capsys, msb_children):
    _msb_running(monkeypatch, tmp_path, "a", "b", sbx_on=True)
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret ls")
    monkeypatch.setenv("ACQ_MSB_STUB_FAIL_ADD", "b")
    rc, _doc, out, err = _rotate(capsys, monkeypatch, "msb", json_out=False)
    assert rc == 1
    assert "  sbx: NOT re-fed: " + _UNLISTED in err
    lines = err.splitlines()
    assert any(line.startswith("re-run 'acq usai-rotate-api-key'") for line in lines)
    assert any(line.startswith("once 'sbx secret ls --json' works again") for line in lines)
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children], out, err)


def test_unreadable_sbx_list_refuses_rotation_on_sbx_naming_sbx(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"))
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "secret ls")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert doc["error"]["code"] == errors.SECRET_UNREADABLE
    assert doc["error"]["message"] == "sbx: could not read the secret store"
    assert secretstore.resolve("usai") == OLD
    assert _set_customs(sbx_calls) == {}
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_other_backend_preflight_refusal_names_it(monkeypatch, tmp_path, capsys):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    dupes = [_row("global", "sbx-cs-g1"), _row("global", "sbx-cs-g2")]
    monkeypatch.setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps(dupes))
    rc, doc, _out, _err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1 and doc["error"]["message"].startswith("sbx: sbx lists 2 global custom secrets")


# ---------------------------------------------------------------------------
# Every sbx call a rotation makes is bounded; a timeout is a failure.
# ---------------------------------------------------------------------------

def _timing_out(monkeypatch, match):
    """Make ``sbx._run`` time out on the calls ``match(argv)`` selects."""
    real = sbx._run

    def run(argv, *, timeout=None, input_text=None):
        if match(argv):
            raise subprocess.TimeoutExpired([*argv], timeout or 0)
        return real(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", run)


def test_every_sbx_call_in_a_rotation_is_bounded(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"))
    monkeypatch.setenv("ACQ_ROTATE_TIMEOUT", "7")
    timeouts: list[float | None] = []
    real = sbx._run

    def run(argv, *, timeout=None, input_text=None):
        timeouts.append(timeout)
        return real(argv, timeout=timeout, input_text=input_text)

    monkeypatch.setattr(sbx, "_run", run)
    rc, _doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert timeouts and set(timeouts) == {7.0}


def test_rotation_timeout_defaults_to_bash_rotate_validate_timeout(monkeypatch):
    monkeypatch.delenv("ACQ_ROTATE_TIMEOUT", raising=False)
    from acq_py import timeouts

    assert timeouts.rotate_timeout_s() == 120.0


def test_sbx_set_custom_timeout_fails_only_that_sandbox(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"), _row("b", "sbx-cs-b1"))
    monkeypatch.setenv("ACQ_ROTATE_TIMEOUT", "7")
    _timing_out(monkeypatch, lambda argv: argv[:2] == ["secret", "set-custom"] and "a" in argv)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert doc["error"]["backends"] == [
        _res("sbx", ["b"], missed=["sandbox a ('sbx secret set-custom' timed out after 7s)"], glob="updated")
    ]
    assert secretstore.resolve("usai") == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_list_timeout_refuses_rotation_on_sbx(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"))
    _timing_out(monkeypatch, lambda argv: argv[:2] == ["secret", "ls"])
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert doc["error"]["message"] == "sbx: 'sbx secret ls' timed out after 120s"
    assert "ACQ_ROTATE_TIMEOUT" in doc["error"]["remediation"]
    assert secretstore.resolve("usai") == OLD
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_list_timeout_reports_sbx_not_re_fed_on_msb(monkeypatch, tmp_path, capsys, msb_children, sbx_calls):
    _msb_running(monkeypatch, tmp_path, "a", sbx_on=True)
    _timing_out(monkeypatch, lambda argv: argv[:2] == ["secret", "ls"])
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb")
    assert rc == 1
    assert doc["error"]["backends"][1] == _res("sbx", [], missed=[_UNLISTED + "'sbx secret ls' timed out after 120s)"])
    assert _modified(msb_children)["a"]["USAI_API_KEY"] == NEW
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children + sbx_calls], out, err)


def test_sbx_label_lookup_timeout_refuses_rotation(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"))
    _timing_out(monkeypatch, lambda argv: argv[:2] == ["ls", "-q"])
    rc, doc, _out, _err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1 and doc["error"]["message"] == "sbx: 'sbx ls' timed out after 120s"
    assert secretstore.resolve("usai") == OLD


# ---------------------------------------------------------------------------
# Reporting the global sbx entry.
# ---------------------------------------------------------------------------

def test_sbx_global_only_rotation_reports_the_global_entry(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"))
    rc, _doc, out, err = _rotate(capsys, monkeypatch, "sbx", json_out=False)
    assert rc == 0, err
    assert "  sbx: re-fed: the global USAi secret\n" in out
    assert "re-fed: none" not in out
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


def test_sbx_rotation_that_creates_the_global_entry_says_so(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path)
    rc, _doc, out, err = _rotate(capsys, monkeypatch, "sbx", json_out=False)
    assert rc == 0, err
    assert "  sbx: re-fed: the global USAi secret (created)\n" in out


def test_msb_rotation_with_nothing_running_says_re_fed_none(monkeypatch, tmp_path, capsys):
    _msb_running(monkeypatch, tmp_path)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "msb", json_out=False)
    assert rc == 0, err
    assert "  msb: re-fed: none\n" in out


def test_sbx_global_entry_failure_is_not_reported_as_global(monkeypatch, tmp_path, capsys):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"))
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL_CUSTOM_SCOPES", "global")
    rc, doc, _out, _err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1 and "global" not in doc["error"]["backends"][0]
    assert "; re-fed:" not in doc["error"]["message"]


# ---------------------------------------------------------------------------
# A same-env custom secret bound to other hosts is a different secret.
# ---------------------------------------------------------------------------

def test_sbx_secret_for_the_same_env_on_other_hosts_does_not_fail_the_check(monkeypatch, tmp_path, capsys, sbx_calls):
    other = {"scope": "a", "env": "USAI_API_KEY", "placeholder": "sbx-cs-a-other", "targets": ["other.example"]}
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"), other)
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert doc["data"]["backends"] == [_res("sbx", ["a"], glob="updated")]
    assert other in _sbx_table(tmp_path)  # left alone
    _assert_never_leaked(tmp_path, [argv for argv, _ in sbx_calls], out, err)


# ---------------------------------------------------------------------------
# An msb that fails acq's version check: records left by sandboxes removed
# outside acq still count (acq must not run msb to check, ADR-0032), and the
# remediation says how to clear them.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("version", ["0.6.0", "0.7.1"])
def test_unchecked_msb_counts_a_stale_record_without_running_msb(
    monkeypatch, tmp_path, capsys, msb_children, sbx_calls, version
):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), msb_on=True)
    monkeypatch.setenv("ACQ_MSB_VERSION", version)
    _msb_catalog(tmp_path, {})  # the sandbox was removed outside acq
    _usai_record("gone-box")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 1
    msb_result = doc["error"]["backends"][1]
    assert msb_result["backend"] == "msb" and msb_result["not_refed"]
    remediation = doc["error"]["remediation"]
    assert "acq's records say gone-box hold the USAi key" in remediation
    assert "'acq --backend msb rm NAME' clears it" in remediation
    # Only the version probe ran: no msb command that opens its catalog.
    assert [argv for argv, _ in msb_children if "--version" not in argv] == []
    _assert_never_leaked(tmp_path, [argv for argv, _ in msb_children + sbx_calls], out, err)


def test_unchecked_msb_without_a_usai_record_is_skipped_without_a_hint(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), msb_on=True)
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.6.0")
    msb.HeldRecord("plain", complete=True).save()
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert "0.6.0" in doc["data"]["backends"][1]["skipped"]
    assert msb.rotate_stale_hint() is None


# ---------------------------------------------------------------------------
# ACQ_ROTATE_TIMEOUT must be a positive number of seconds.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("raw", ["0", "0.0", "-1", "nan", "soon"])
def test_rotation_timeout_rejects_zero_and_invalid_values(monkeypatch, capsys, raw):
    from acq_py import timeouts

    monkeypatch.setenv("ACQ_ROTATE_TIMEOUT", raw)
    assert timeouts.rotate_timeout_s() == 120.0
    assert "ACQ_ROTATE_TIMEOUT" in capsys.readouterr().err


def test_zero_rotation_timeout_does_not_fail_every_sbx_call(monkeypatch, tmp_path, capsys, sbx_calls):
    _sbx_rows(monkeypatch, tmp_path, _row("global", "sbx-cs-g1"), _row("a", "sbx-cs-a1"))
    monkeypatch.setenv("ACQ_ROTATE_TIMEOUT", "0")
    rc, doc, out, err = _rotate(capsys, monkeypatch, "sbx")
    assert rc == 0, (out, err)
    assert doc["data"]["backends"] == [_res("sbx", ["a"], glob="updated")]
    assert "ignoring ACQ_ROTATE_TIMEOUT='0'" in err
