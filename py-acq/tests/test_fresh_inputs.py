"""Packaged-profile staging, with explicit seams for validator execution.

The opt-in actual-validator test must run in the primary's isolated environment.
Other tests mock validation, not bundle verification or filesystem operations.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from acq_py import fresh_inputs as fresh
from acq_py import kitspec, preparation_assets, provider_input, provider_validator

pytestmark = pytest.mark.skipif(os.name != "posix", reason="POSIX fresh preparation only")


@pytest.fixture
def inputs(tmp_path, monkeypatch):
    bundle = tmp_path / "kitbundle"
    shutil.copytree(kitspec.BUNDLE_DIR, bundle)
    monkeypatch.setattr(kitspec, "BUNDLE_DIR", bundle)
    monkeypatch.setattr(kitspec, "BUNDLE_MANIFEST", bundle / "MANIFEST.json")
    root = tmp_path / "inputs"
    monkeypatch.setattr(provider_input, "input_root", lambda backend, name: root / name)
    calls = []

    def validate(manifests):
        assert len(manifests) == 1
        manifest = manifests[0]
        assert manifest.is_absolute()
        assert stat.S_IMODE(manifest.parent.stat().st_mode) == 0o700
        assert stat.S_IMODE(manifest.stat().st_mode) == 0o400
        value = json.loads(manifest.read_bytes())
        assert value["schemaVersion"] == "acq-provider-input-bundle/v3"
        assert value["discovery"] == {"adapter": "usai-openai-list/v1"}
        assert "normalizerPath" not in value
        assert {p.name for p in manifest.parent.iterdir()} == {
            "provider-input.json", "facts.json", "snapshot.json", "spec.yaml",
        }
        calls.append({p.name: p.read_bytes() for p in manifest.parent.iterdir()})

    monkeypatch.setattr(provider_validator, "validate_bundles", validate)
    return bundle, root, calls


def assert_empty(root):
    assert not list(root.rglob("generation.*"))
    assert not list(root.rglob(".snapshot.*"))
    assert not list(root.rglob(".staging.*"))
    assert not list(root.rglob("current"))


def test_complete_unpublished_generation_and_exact_bytes(inputs):
    bundle, root, calls = inputs
    result = fresh.prepare("demo")
    assert len(calls) == 1
    assert result.generation.parent == root / "demo/generations"
    assert not (root / "demo/current").exists()
    files = {p.relative_to(result.generation).as_posix(): p for p in result.generation.rglob("*") if p.is_file()}
    assert set(files) == set(fresh._LIMITS) | {fresh._RECEIPT}
    for role in ("facts", "snapshot"):
        assert files[f"models/providers/usai/{role}.json"].read_bytes() == calls[0][f"{role}.json"]
    assert all(stat.S_IMODE(path.stat().st_mode) == 0o444 for path in files.values())
    assert result.artifact_sha256 == hashlib.sha256(files[fresh._RUNTIME].read_bytes()).hexdigest()
    assert files[fresh._BASE].read_bytes() == (bundle / "opencode/files/home/opencode-config/base-config.jsonc").read_bytes()
    assert result.guest_artifact == f"{result.guest_root}/{fresh._RUNTIME}"
    assert result.guest_base_config == f"{result.guest_root}/{fresh._BASE}"
    assert provider_input.msb_flags(result.generation)[1] == f"{result.generation}:{result.guest_root}:ro"
    assert fresh.read_existing("demo", result.generation) == result


def test_explicit_none_has_present_empty_inventory_and_distinct_receipt(inputs):
    _, _, calls = inputs
    result = fresh.prepare("demo", usai=False)
    providers = result.generation / "models/providers"
    assert providers.is_dir() and list(providers.iterdir()) == []
    assert not calls  # no provider manifest exists to validate; assets still verified
    receipt = json.loads((result.generation / fresh._RECEIPT).read_bytes())
    assert receipt["profile"] == "packaged-none-opencode/v1"
    assert set(receipt["files"]) == {fresh._RUNTIME, fresh._BASE}
    assert fresh.read_existing("demo", result.generation) == result
    assert not result.usai
    # Missing is not authoritative empty, and added provider input is not NONE.
    providers.rmdir()
    with pytest.raises(fresh.FreshInputsError):
        fresh.read_existing("demo", result.generation)
    providers.mkdir()
    (providers / "unselected").mkdir()
    with pytest.raises(fresh.FreshInputsError):
        fresh.read_existing("demo", result.generation)


def test_real_packaged_runtime_empty_selection_removes_owned_stale_provider(inputs, tmp_path):
    """Run only in the reviewed test sandbox; no backend/network or live key."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("isolated test environment must provide Node for producer qualification")
    result = fresh.prepare("demo", usai=False)
    config_dir = tmp_path / "global"
    config_dir.mkdir()
    provider = {"name": "Stale managed provider", "npm": "@ai-sdk/openai-compatible",
                "options": {"baseURL": "https://api.gsa.usai.gov/api/v1",
                            "apiKey": "{env:USAI_API_KEY}"}, "models": {}}
    digest = hashlib.sha256(json.dumps(provider, separators=(",", ":")).encode()).hexdigest()
    ownership = {"schemaVersion": "acq-opencode-provider-state/v3", "providers": {"usai": digest}, "roles": {}}
    config = config_dir / "opencode.jsonc"
    encoded = base64.urlsafe_b64encode(json.dumps(ownership).encode()).decode().rstrip("=")
    config.write_text("// acq-provider-config-state: " + encoded + "\n" +
                      json.dumps({"provider": {"usai": provider}, "theme": "user-choice"}))
    completed = subprocess.run([node, str(result.generation / fresh._RUNTIME),
        "--provider-root", str(result.generation), "--global-dir", str(config_dir),
        "--base-config", str(result.generation / fresh._BASE), "--mode", "live-required"],
        env={"PATH": os.defpath, "HOME": str(tmp_path)}, stdin=subprocess.DEVNULL,
        capture_output=True, timeout=30, check=False)
    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout) == {"sourceOutcome": "live", "metadataOutcome": "not-requested"}
    rendered = json.loads("\n".join(line for line in config.read_text().splitlines() if not line.lstrip().startswith("//")))
    assert "usai" not in rendered.get("provider", {})
    assert rendered["theme"] == "user-choice"


def test_source_swap_after_snapshot_never_changes_materialized_bytes(inputs, monkeypatch):
    bundle, _, calls = inputs
    original = provider_validator.validate_bundles

    def swap(manifests):
        original(manifests)
        (bundle / "usai-provider/provider-input/facts.json").write_text('{"untrusted":"replacement"}')
        (bundle / "usai-provider/files/home/usai-config/model-catalog-snapshot.json").unlink()

    monkeypatch.setattr(provider_validator, "validate_bundles", swap)
    result = fresh.prepare("demo")
    assert (result.generation / "models/providers/usai/facts.json").read_bytes() == calls[0]["facts.json"]
    assert (result.generation / "models/providers/usai/snapshot.json").read_bytes() == calls[0]["snapshot.json"]


@pytest.mark.parametrize("asset", [fresh._RUNTIME, fresh._BASE])
def test_self_consistent_generation_must_match_current_verified_sources(inputs, asset):
    result = fresh.prepare("demo")
    target = result.generation / asset
    target.chmod(0o600)
    target.write_bytes(target.read_bytes() + b"\n")
    files = {name: (result.generation / name).read_bytes() for name in fresh._LIMITS}
    receipt = result.generation / fresh._RECEIPT
    receipt.chmod(0o600)
    receipt.write_bytes(fresh._encode(fresh._receipt(files)))
    with pytest.raises(fresh.FreshInputsError):
        fresh.read_existing("demo", result.generation)


def test_source_swap_after_bundle_verification_is_rechecked(inputs, monkeypatch):
    bundle, root, calls = inputs
    original = kitspec.verify_bundle

    def swap():
        problems = original()
        path = bundle / "usai-provider/provider-input/facts.json"
        # Equal length avoids relying only on the size check.
        path.write_bytes(path.read_bytes().replace(b"api.gsa.usai.gov", b"api.bad.usai.gov"))
        return problems

    monkeypatch.setattr(kitspec, "verify_bundle", swap)
    with pytest.raises(fresh.FreshInputsError):
        fresh.prepare("demo")
    assert not calls
    assert_empty(root)


@pytest.mark.parametrize("kind", ["changed", "extra", "directory", "link", "parent-link", "fifo"])
def test_invalid_bundle_never_validates_or_stages(inputs, kind):
    bundle, root, calls = inputs
    target = bundle / "usai-provider/provider-input/facts.json"
    if kind == "changed":
        target.write_bytes(b"{}")
    elif kind == "extra":
        (bundle / "extra.json").write_bytes(b"{}")
    elif kind == "directory":
        (bundle / "usai-provider/unlisted").mkdir()
    elif kind == "parent-link":
        target.parent.rename(bundle / "moved")
        target.parent.symlink_to(bundle / "moved", target_is_directory=True)
    else:
        target.unlink()
        if kind == "link":
            target.symlink_to(bundle / "MANIFEST.json")
        else:
            os.mkfifo(target)
    with pytest.raises(fresh.FreshInputsError):
        fresh.prepare("demo")
    assert calls == []
    assert_empty(root)


def test_failed_verifier_and_asset_errors_are_closed(inputs, monkeypatch):
    _, root, calls = inputs
    monkeypatch.setattr(kitspec, "verify_bundle", lambda: ["private diagnostic"])
    with pytest.raises(fresh.FreshInputsError) as error:
        fresh.prepare("demo")
    assert str(error.value) == fresh._FAILURE
    assert error.value.__suppress_context__
    assert not calls
    assert_empty(root)


def test_asset_verification_failure_precedes_copy(inputs, monkeypatch):
    _, root, calls = inputs

    def fail():
        raise preparation_assets.AssetError("private asset path")

    monkeypatch.setattr(preparation_assets, "verify_assets", fail)
    with pytest.raises(fresh.FreshInputsError, match=fresh._FAILURE):
        fresh.prepare("demo")
    assert not calls
    assert_empty(root)


@pytest.mark.parametrize("kind", ["refusal", "mutation", "extra"])
def test_validator_failure_or_snapshot_mutation_leaves_no_generation(inputs, monkeypatch, kind):
    _, root, _ = inputs

    def fail(manifests):
        if kind == "refusal":
            raise provider_validator.ValidatorError("private diagnostic")
        if kind == "extra":
            (manifests[0].parent / "extra").mkdir()
        else:
            target = manifests[0].parent / "snapshot.json"
            target.chmod(0o600)
            target.write_bytes(b"{}")

    monkeypatch.setattr(provider_validator, "validate_bundles", fail)
    with pytest.raises(fresh.FreshInputsError):
        fresh.prepare("demo")
    assert_empty(root)


def test_materialization_failure_leaves_no_half_generation(inputs, monkeypatch):
    _, root, _ = inputs
    original = provider_input._copy_out

    def fail(raw, destination, mode):
        if destination.name == fresh._BASE:
            raise OSError("private write failure")
        original(raw, destination, mode)

    monkeypatch.setattr(provider_input, "_copy_out", fail)
    with pytest.raises(fresh.FreshInputsError):
        fresh.prepare("demo")
    assert_empty(root)


@pytest.mark.parametrize("limit", [fresh._FACTS_LIMIT, fresh._CATALOG_LIMIT,
                                     fresh._ASSET_LIMIT, fresh._MANIFEST_LIMIT,
                                     fresh._SPEC_LIMIT, fresh._RECEIPT_LIMIT])
def test_bounded_reader_exact_and_over_limit(tmp_path, limit):
    path = tmp_path / "data"
    path.write_bytes(b" " * limit)
    assert len(fresh._read(tmp_path, "data", limit)) == limit
    with path.open("ab") as stream:
        stream.write(b" ")
    with pytest.raises(fresh.FreshInputsError):
        fresh._read(tmp_path, "data", limit)
    with path.open("wb") as stream:
        stream.truncate(16 * 1024 * 1024 * 1024)
    with pytest.raises(fresh.FreshInputsError):
        fresh._read(tmp_path, "data", limit)


@pytest.mark.parametrize("relative,limit", [
    ("usai-provider/provider-input.json", fresh._MANIFEST_LIMIT),
    ("usai-provider/provider-input/facts.json", fresh._FACTS_LIMIT),
    ("usai-provider/files/home/usai-config/model-catalog-snapshot.json", fresh._CATALOG_LIMIT),
    ("usai-provider/spec.yaml", fresh._SPEC_LIMIT),
    ("opencode/files/home/opencode-config/base-config.jsonc", fresh._ASSET_LIMIT),
])
def test_selected_file_limit_even_when_inventory_claims_valid(inputs, relative, limit):
    bundle, _, _ = inputs
    # Exercise the per-role guard independently of the whole-bundle byte cap.
    raw = b" " * (limit + 1)
    (bundle / relative).write_bytes(raw)
    blob = hashlib.sha1(b"blob %d\0" % len(raw) + raw, usedforsecurity=False).hexdigest()
    inventory = {relative: {"size": len(raw), "git_blob": blob}}
    with pytest.raises(fresh.FreshInputsError):
        fresh._kit_bytes(inventory, relative, limit)


@pytest.mark.parametrize("relative,limit", list(fresh._LIMITS.items()))
def test_existing_per_file_bounds(inputs, relative, limit):
    result = fresh.prepare("demo")
    target = result.generation / relative
    target.chmod(0o600)
    with target.open("wb") as stream:
        stream.truncate(limit + 1)
    with pytest.raises(fresh.FreshInputsError):
        fresh.read_existing("demo", result.generation)


@pytest.mark.parametrize("kind", ["facts", "snapshot", "runtime", "base", "receipt", "extra",
                                   "directory", "symlink", "hardlink", "missing", "parent-link"])
def test_existing_tampering_rejected(inputs, tmp_path, kind):
    result = fresh.prepare("demo")
    root = result.generation
    mapping = {"facts": "models/providers/usai/facts.json", "snapshot": "models/providers/usai/snapshot.json",
               "runtime": fresh._RUNTIME, "base": fresh._BASE, "receipt": fresh._RECEIPT}
    if kind in mapping:
        path = root / mapping[kind]
        path.chmod(0o600)
        path.write_bytes(b"{}")
    elif kind == "extra":
        (root / "extra").touch()
    elif kind == "directory":
        (root / "empty").mkdir()
    elif kind == "parent-link":
        (root / "models").rename(tmp_path / "models")
        (root / "models").symlink_to(tmp_path / "models", target_is_directory=True)
    else:
        path = root / fresh._BASE
        raw = path.read_bytes()
        path.unlink()
        outside = tmp_path / "outside"
        outside.write_bytes(raw)
        if kind == "symlink":
            path.symlink_to(outside)
        elif kind == "hardlink":
            os.link(outside, path)
    with pytest.raises(fresh.FreshInputsError):
        fresh.read_existing("demo", root)


def test_existing_ignores_current_and_rejects_other_sandbox(inputs):
    _, root, _ = inputs
    first = fresh.prepare("demo")
    second = fresh.prepare("demo")
    (root / "demo/current").symlink_to(second.generation)
    assert fresh.read_existing("demo", first.generation) == first
    for path in (root / "demo/current", Path("generation.relative")):
        with pytest.raises(fresh.FreshInputsError):
            fresh.read_existing("demo", path)
    with pytest.raises(fresh.FreshInputsError):
        fresh.read_existing("other", first.generation)


def test_routing_digest_covers_full_facts_and_descriptor(inputs):
    result = fresh.prepare("demo")
    expected = hashlib.sha256(fresh._encode({"facts": fresh._FACTS, "discovery": fresh._DISCOVERY})).hexdigest()
    assert result.routing_digest == expected


@pytest.mark.skipif(not os.environ.get("PREPARATION_TEST_VALIDATOR_PYTHON"),
                    reason="primary must supply an isolated pinned validator runtime")
def test_actual_packaged_validator(tmp_path, monkeypatch):
    monkeypatch.setenv("ACQ_PROVIDER_INPUT_PYTHON", os.environ["PREPARATION_TEST_VALIDATOR_PYTHON"])
    monkeypatch.setattr(provider_input, "input_root", lambda backend, name: tmp_path / name)
    # No validation mock: checks real schemas, facts/catalog, binding and spec.
    result = fresh.prepare("actual")
    assert fresh.read_existing("actual", result.generation) == result
