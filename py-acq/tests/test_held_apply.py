"""HeldRecord schema 2, apply evidence and the read-only snapshot (ADR-0053)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from acq_py import errors, lock, msb, secretstore, state

SENTINEL = "synthetic-apply-canary-695"


@pytest.fixture(autouse=True)
def _state(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    for name in ("ACQ_PROVIDER_CREDENTIAL_BINDINGS", "ACQ_PROVIDER_CREDENTIAL_SEED", "USAI_API_KEY"):
        monkeypatch.delenv(name, raising=False)


def _doc(name: str) -> dict:
    return json.loads(msb.held_path(name).read_text(encoding="utf-8"))


def _applied(sandbox: str, service: str = "usai", *, status: str = "applied") -> None:
    """Persist one entry the way the write protocol will: from the resolver's identity."""
    identity = msb.effective_identity(service, sandbox)
    assert identity is not None

    def mutate(rec):
        rec.apply[service] = msb.apply_entry(identity, status=status)

    msb.held_update(sandbox, mutate)


def _snapshot(name: str, service: str = "usai"):
    return msb.held_apply_snapshot(name).services[service]


def test_records_are_schema_2_with_an_instance_and_empty_apply():
    msb.HeldRecord("box", complete=True).save()
    doc = _doc("box")
    assert doc["schema"] == 2 and doc["apply"] == {}
    assert doc["instance"].startswith("i:") and len(doc["instance"]) == 34


def test_same_name_recreation_never_inherits_instance_or_apply_evidence():
    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    first = _doc("box")["instance"]
    _applied("box")
    # A sandbox removed outside acq leaves its record behind; the next create
    # of that name must still start from nothing.
    msb.HeldRecord("box", complete=True).save()
    second = _doc("box")
    assert second["instance"] != first and second["apply"] == {}


def test_schema_1_record_is_unknown_and_the_reader_never_rewrites_it():
    path = msb.held_path("old")
    path.parent.mkdir(parents=True)
    binding = {"service": "usai", "host": "api.gsa.usai.gov", "scope": "global"}
    raw = json.dumps({"schema": 1, "sandbox": "old", "complete": True, "services": ["usai"],
                      "bindings": {"USAI_API_KEY": binding}})
    path.write_text(raw, encoding="utf-8")
    snapshot = msb.held_apply_snapshot("old")
    assert snapshot.instance is None
    assert snapshot.services["usai"].status == "unknown"
    assert msb.held_read("old").bindings == {"USAI_API_KEY": binding}
    assert path.read_text(encoding="utf-8") == raw


@pytest.mark.parametrize("mutate", [
    lambda e: e.update(status="done"),
    lambda e: e.update(attempt="x"),
    lambda e: e.update(revision="not-a-token"),
    lambda e: e.update(status="applied", applied_revision=None),
    lambda e: e.update(source="environment"),
    lambda e: e.update(scope="elsewhere"),
    lambda e: e.update(authority={"value": 1, "endpoint": None}),
    lambda e: e.update(status_at="yesterday"),
    lambda e: e.update(extra=1),
    lambda e: e.pop("host"),
])
def test_present_but_malformed_apply_is_an_explicit_failure(mutate):
    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    _applied("box")
    doc = _doc("box")
    mutate(doc["apply"]["usai"])
    msb.held_path("box").write_text(json.dumps(doc), encoding="utf-8")
    before = msb.held_path("box").read_bytes()
    for read in (lambda: msb.held_apply_snapshot("box"), lambda: msb.held_read("box")):
        with pytest.raises(msb.MsbError) as info:
            read()
        assert info.value.code == errors.STATE_SCHEMA_UNSUPPORTED
    assert msb.held_path("box").read_bytes() == before


def test_apply_must_be_an_object_and_instance_a_token():
    msb.HeldRecord("box", complete=True).save()
    for field, value in (("apply", []), ("instance", "i:short"), ("instance", None)):
        doc = _doc("box")
        doc[field] = value
        msb.held_path("box").write_text(json.dumps(doc), encoding="utf-8")
        with pytest.raises(msb.MsbError):
            msb.held_read("box")


def test_snapshot_reports_applied_but_never_reuse_eligible():
    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    _applied("box")
    snapshot = msb.held_apply_snapshot("box")
    assert snapshot.services["usai"].status == "applied"
    assert snapshot.reuse_eligible is False
    with pytest.raises(AttributeError):
        snapshot.reuse_eligible = True  # type: ignore[misc]


def test_global_change_invalidates_inheritors_and_leaves_scoped_bindings_alone():
    secretstore.set_secret("usai", None, SENTINEL)
    secretstore.set_secret("github", "scoped", SENTINEL + "-gh")
    for name in ("inherits", "scoped"):
        msb.HeldRecord(name, complete=True).save()
    _applied("inherits")
    _applied("scoped", "github")
    secretstore.set_secret("usai", None, SENTINEL + "-rotated")
    assert _snapshot("inherits").status == "pending"
    assert _snapshot("scoped", "github").status == "applied"
    # The same global change does not disturb a binding that has its own value.
    secretstore.set_secret("usai", "scoped", SENTINEL + "-own")
    assert _snapshot("scoped", "github").status == "applied"


def test_sandbox_named_global_is_a_sandbox_source():
    secretstore.set_secret("github", "global", SENTINEL)
    msb.HeldRecord("global", complete=True).save()
    _applied("global", "github")
    entry = _doc("global")["apply"]["github"]
    assert (entry["source"], entry["scope"]) == ("sandbox", "global")
    secretstore.set_secret("github", None, SENTINEL + "-g")
    assert _snapshot("global", "github").status == "applied"


def test_endpoint_only_change_invalidates_equality():
    secretstore.set_secret("svc", None, SENTINEL, "api.example.com", "SVC_KEY")
    msb.HeldRecord("box", complete=True).save()
    _applied("box", "svc")
    secretstore.set_secret("svc", None, SENTINEL, "other.example.com", "SVC_KEY")
    assert _snapshot("box", "svc").status == "pending"


def test_scoped_endpoint_with_a_global_value_is_covered_by_both_revisions():
    secretstore.set_secret("svc", None, SENTINEL, "api.example.com", "SVC_KEY")
    secretstore.meta_store("svc", "box", "scoped.example.com", "SVC_KEY")
    msb.HeldRecord("box", complete=True).save()
    identity = msb.effective_identity("svc", "box")
    assert identity is not None and identity.host == "scoped.example.com" and identity.source == "global"
    assert identity.revision is not None and "+" in identity.revision  # the endpoint scope has its own revision
    secretstore.set_secret("svc", None, SENTINEL + "-2", "api.example.com", "SVC_KEY")
    assert msb.effective_identity("svc", "box") != identity


def test_environment_source_is_never_versioned_or_applied(monkeypatch):
    monkeypatch.setenv("USAI_API_KEY", SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    identity = msb.effective_identity("usai", "box")
    assert identity is not None and identity.source == "environment" and identity.revision is None
    _applied("box")
    assert _doc("box")["apply"]["usai"]["status"] == "unknown"
    assert _snapshot("box").status == "unknown"


def test_pending_store_transaction_reads_unknown():
    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    _applied("box")
    path = state.state_dir() / "secret-rev" / "acq.usai.json"
    doc = json.loads(path.read_text())
    doc["pending"] = "r:" + "3" * 32
    path.write_text(json.dumps(doc))
    assert _snapshot("box").status == "unknown"


def test_store_a_then_store_b_never_equals_the_applied_revision(monkeypatch, tmp_path):
    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    _applied("box")
    store_b = tmp_path / "store-b"
    store_b.mkdir()
    (store_b / "acq.usai").write_text(SENTINEL)
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(store_b))
    assert _snapshot("box").status == "unknown"


def test_a_failed_entry_does_not_become_applied_by_equality():
    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    _applied("box", status="failed")
    assert _snapshot("box").status == "failed"


def test_snapshot_is_read_only(tmp_path):
    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    _applied("box")
    root = Path(os.environ["ACQ_SECRET_STORE_DIR"]).parent
    watched = [p for p in (state.state_dir().rglob("*"), root.rglob("*")) for p in p if p.is_file()
               and "locks" not in p.parts]
    before = {p: p.read_bytes() for p in watched}
    msb.held_apply_snapshot("box")
    assert {p: p.read_bytes() for p in watched} == before
    assert {p for p in state.state_dir().rglob("*") if p.is_file() and "locks" not in p.parts} <= set(before)


def test_records_hold_no_credential_value_or_derivative():
    import base64
    import hashlib

    secretstore.set_secret("usai", None, SENTINEL)
    msb.HeldRecord("box", complete=True).save()
    _applied("box")
    data = SENTINEL.encode()
    forbidden = [data, base64.b64encode(data), data.hex().encode(), hashlib.sha256(data).hexdigest().encode(),
                 hashlib.sha256(data).digest()]
    for path in (p for p in state.state_dir().rglob("*") if p.is_file()):
        assert all(item not in path.read_bytes() for item in forbidden), path


def test_the_per_record_lock_is_a_bounded_leaf(monkeypatch):
    monkeypatch.setenv("ACQ_SANDBOX_LOCK_TIMEOUT", "0.2")
    msb.HeldRecord("box", complete=True).save()
    with lock.held_record_lock("box"):
        with pytest.raises(msb.MsbError) as info:
            msb.held_update("box", lambda rec: rec.note("usai"))
    assert info.value.code == errors.TIMEOUT
    assert "usai" not in msb.held_read("box").services


def test_concurrent_read_modify_writes_lose_no_update(tmp_path):
    msb.HeldRecord("box", complete=True).save()
    script = textwrap.dedent("""
        import sys
        from acq_py import msb
        service = sys.argv[1]
        for _ in range(15):
            msb.held_update("box", lambda rec: rec.note(service))
            msb.held_update("box", lambda rec: rec.services.remove(service))
            msb.held_update("box", lambda rec: rec.note(service))
    """)
    children = [subprocess.Popen([sys.executable, "-c", script, f"svc{i}"], env=os.environ.copy())
                for i in range(4)]
    assert [child.wait(timeout=120) for child in children] == [0, 0, 0, 0]
    assert sorted(msb.held_read("box").services) == [f"svc{i}" for i in range(4)]


def test_a_newer_or_unknown_schema_is_refused_and_older_builds_would_refuse_schema_2():
    msb.HeldRecord("box", complete=True).save()
    doc = _doc("box")
    # Writers produce exactly schema 2, which a reader that only knows schema 1
    # (an exact-equality check) refuses.
    assert doc["schema"] == 2 != 1
    for schema in (3, 0, "2", True, None):
        msb.held_path("box").write_text(json.dumps({**doc, "schema": schema}), encoding="utf-8")
        with pytest.raises(msb.MsbError) as info:
            msb.held_read("box")
        assert info.value.code == errors.STATE_SCHEMA_UNSUPPORTED
