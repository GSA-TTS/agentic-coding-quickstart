"""Credential epoch evidence through the store API (ADR-0053)."""

import json
import os
import re
import subprocess
import sys
import threading
from pathlib import Path

import pytest

from acq_py import secretstore, state


def revision_record(key):
    return json.loads((state.state_dir() / "secret-rev" / f"{key}.json").read_text())


def test_identical_value_writes_and_remove_readd_have_distinct_epochs():
    key = secretstore.key_for("example")
    tokens = []
    for operation in (
        lambda: secretstore.store(key, "synthetic-credential"),
        lambda: secretstore.store(key, "synthetic-credential"),
        lambda: secretstore.delete(key),
        lambda: secretstore.store(key, "synthetic-credential"),
    ):
        operation()
        record = revision_record(key)
        assert set(record) == {"schema", "committed", "pending", "authority"}
        assert record["schema"] == 1
        assert record["pending"] is None
        assert re.fullmatch(r"r:[0-9a-f]{32}", record["committed"])
        tokens.append(record["committed"])
    assert len(set(tokens)) == 4
    assert secretstore.get(key) == "synthetic-credential"


def test_endpoint_failure_keeps_composite_write_pending(monkeypatch):
    key = secretstore.key_for("example")
    secretstore.set_secret("example", None, "first", "api.example.com", "EXAMPLE_KEY")
    old = revision_record(key)["committed"]
    original = secretstore._stage_atomic

    def fail_metadata(path, content):
        if path.parent.name == "meta":
            raise OSError("synthetic metadata failure")
        return original(path, content)

    with monkeypatch.context() as patch:
        patch.setattr(secretstore, "_stage_atomic", fail_metadata)
        with pytest.raises(secretstore.SecretStoreError):
            secretstore.set_secret("example", None, "second", "new.example.com", "EXAMPLE_KEY")
    assert secretstore.get(key) == "second"
    record = revision_record(key)
    assert record["pending"] is not None
    assert record["committed"] == old
    secretstore.meta_store("example", None, "new.example.com", "EXAMPLE_KEY")
    assert revision_record(key)["pending"] is not None
    secretstore.set_secret("example", None, "third", "new.example.com", "EXAMPLE_KEY")
    assert revision_record(key)["pending"] is None


def test_metadata_write_cannot_certify_value_from_another_store(monkeypatch, tmp_path):
    key = secretstore.key_for("example")
    secretstore.store(key, "from-store-a")
    store_b = tmp_path / "store-b"
    store_b.mkdir()
    (store_b / key).write_text("from-store-b")
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(store_b))
    secretstore.meta_store("example", None, "api.example.com", "EXAMPLE_KEY")
    assert secretstore.get(key) == "from-store-b"
    assert revision_record(key)["authority"]["value"] is None


@pytest.mark.parametrize("boundary", ["pending", "value", "metadata"])
def test_process_kill_leaves_real_transaction_pending(boundary):
    key = secretstore.key_for("example")
    secretstore.set_secret("example", None, "before-crash", "api.example.com", "EXAMPLE_KEY")
    old = revision_record(key)["committed"]
    script = '''
import sys
from acq_py import secretstore, secret_revision
secretstore.IS_WINDOWS = False
boundary = sys.argv[1]
def pause():
    print("boundary-reached", flush=True)
    sys.stdin.read(1)
original_write = secret_revision.write
original_value = secretstore._store_value
original_meta = secretstore._meta_store
def write(path, doc):
    original_write(path, doc)
    if boundary == "pending" and doc.get("pending"):
        pause()
def value(*args):
    original_value(*args)
    if boundary == "value":
        pause()
def meta(*args):
    original_meta(*args)
    if boundary == "metadata":
        pause()
secret_revision.write = write
secretstore._store_value = value
secretstore._meta_store = meta
secretstore.set_secret("example", None, "after-crash", "new.example.com", "EXAMPLE_KEY")
'''
    child = subprocess.Popen([sys.executable, "-c", script, boundary], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    observed = []
    reached = threading.Event()

    def read_boundary():
        observed.append(child.stdout.readline())
        reached.set()

    reader = threading.Thread(target=read_boundary, daemon=True)
    reader.start()
    try:
        assert reached.wait(15), "child did not reach write boundary"
        assert observed == ["boundary-reached\n"], "child exited before write boundary"
        child.kill()
        child.wait(timeout=15)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=15)
        child.stdin.close()
        child.stdout.close()
        child.stderr.close()
        reader.join(timeout=15)
    record = revision_record(key)
    assert record["pending"] is not None
    assert record["committed"] == old
    assert secretstore.get(key) == ("before-crash" if boundary == "pending" else "after-crash")
    # A real succeeding write also proves the OS released the dead child's lock.
    secretstore.set_secret("example", None, "recovered", "new.example.com", "EXAMPLE_KEY")
    assert revision_record(key)["pending"] is None


def test_state_and_authority_files_contain_no_credential_derivatives():
    import base64
    import hashlib

    sentinel = b"synthetic-sensitive-canary-695"
    secretstore.set_secret("example", None, sentinel.decode(), "api.example.com", "EXAMPLE_KEY")
    forbidden = [sentinel, base64.b64encode(sentinel), sentinel.hex().encode()]
    for algorithm in (hashlib.sha256, hashlib.sha512):
        forbidden += [algorithm(sentinel).digest(), algorithm(sentinel).hexdigest().encode()]
    files = [p for p in state.state_dir().rglob("*") if p.is_file()]
    files += list(Path(os.environ["ACQ_SECRET_STORE_DIR"]).rglob(".acq-authority-*.json"))
    assert any(p.parent.name == "secret-rev" for p in files)
    assert any(p.name.startswith(".acq-authority-") for p in files)
    for path in files:
        assert all(value not in path.read_bytes() for value in forbidden), "non-secret file leaked canary"


def test_keychain_remove_failure_does_not_commit_deletion(monkeypatch):
    key = secretstore.key_for("example")
    secretstore.store(key, "retained")
    old = revision_record(key)["committed"]
    calls = []

    def failed_tool(argv, stdin=None):
        calls.append(argv)
        return 127, ""

    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-macos")
    monkeypatch.setattr(secretstore, "_run_tool", failed_tool)
    with pytest.raises(secretstore.SecretStoreError):
        secretstore.delete(key)
    assert calls
    assert revision_record(key)["pending"] is not None
    assert revision_record(key)["committed"] == old


def _key():
    return secretstore.key_for("example")


def test_a_then_b_store_switch_never_inherits_revision(monkeypatch, tmp_path):
    key = _key()
    secretstore.set_secret("example", None, "from-a", "api.example.com", "EXAMPLE_KEY")
    revision = secretstore.current_revision(key)
    assert revision is not None
    store_b = tmp_path / "store-b"
    store_b.mkdir()
    (store_b / key).write_text("from-b")
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(store_b))
    assert secretstore.get(key) == "from-b"
    assert secretstore.current_revision(key) is None


def test_marker_for_a_different_location_is_not_authority(monkeypatch, tmp_path):
    key = _key()
    secretstore.set_secret("example", None, "from-a", "api.example.com", "EXAMPLE_KEY")
    original = Path(os.environ["ACQ_SECRET_STORE_DIR"])
    store_b = tmp_path / "copied-marker"
    store_b.mkdir()
    for marker in original.glob(".acq-authority-*.json"):
        (store_b / marker.name).write_bytes(marker.read_bytes())
    (store_b / "meta").mkdir()
    for marker in (original / "meta").glob(".acq-authority-*.json"):
        (store_b / "meta" / marker.name).write_bytes(marker.read_bytes())
    (store_b / key).write_text("from-b")
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(store_b))
    assert secretstore.current_revision(key) is None


def test_legacy_sidecar_and_missing_marker_read_unknown():
    key = _key()
    secretstore.set_secret("example", None, "value", "api.example.com", "EXAMPLE_KEY")
    marker = next(Path(os.environ["ACQ_SECRET_STORE_DIR"]).glob(".acq-authority-*.json"))
    marker.unlink()
    assert secretstore.current_revision(key) is None
    secretstore.set_secret("example", None, "value", "api.example.com", "EXAMPLE_KEY")
    assert secretstore.current_revision(key) is not None
    path = state.state_dir() / "secret-rev" / f"{key}.json"
    path.write_text(json.dumps({"committed": "r:" + "1" * 32, "pending": None}))
    assert secretstore.current_revision(key) is None


def test_keychain_backend_has_no_value_authority(monkeypatch):
    key = _key()
    secretstore.set_secret("example", None, "value", "api.example.com", "EXAMPLE_KEY")
    assert secretstore.current_revision(key) is not None
    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-linux")
    assert secretstore.current_revision(key) is None


def test_macos_legacy_file_fallback_is_unknown(monkeypatch):
    key = _key()
    secretstore.set_secret("example", None, "value", "api.example.com", "EXAMPLE_KEY")
    assert secretstore.current_revision(key) is not None
    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-macos")
    assert secretstore.current_revision(key) is None


def test_metadata_directory_switch_is_unknown(monkeypatch, tmp_path):
    key = _key()
    secretstore.set_secret("example", None, "value", "api.example.com", "EXAMPLE_KEY")
    monkeypatch.delenv("ACQ_SECRET_STORE_DIR")
    monkeypatch.setenv("ACQ_SECRET_FILE_DIR", str(tmp_path / "secrets"))
    monkeypatch.setenv("ACQ_SECRET_META_DIR", str(tmp_path / "other-meta"))
    assert secretstore.current_revision(key) is None


def test_pending_transaction_reads_unknown_even_with_a_committed_revision(monkeypatch):
    key = _key()
    secretstore.set_secret("example", None, "value", "api.example.com", "EXAMPLE_KEY")
    assert secretstore.current_revision(key) is not None
    record = revision_record(key)
    path = state.state_dir() / "secret-rev" / f"{key}.json"
    path.write_text(json.dumps({**record, "pending": "r:" + "2" * 32}))
    assert secretstore.current_revision(key) is None


def test_keychain_write_read_back_under_the_same_backend_is_still_unknown(monkeypatch):
    key = _key()
    stored = {}
    monkeypatch.setattr(secretstore, "backend_name", lambda: "keychain-linux")
    monkeypatch.setattr(secretstore, "_store_linux", lambda k, v: stored.__setitem__(k, v))
    monkeypatch.setattr(secretstore, "_index_add", lambda *a: None)
    secretstore.store(key, "value")
    assert stored == {key: "value"}
    record = revision_record(key)
    assert record["committed"] is not None and record["authority"]["value"] is None
    assert secretstore.current_revision(key) is None
