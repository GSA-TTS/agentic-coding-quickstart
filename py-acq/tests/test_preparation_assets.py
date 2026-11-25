"""Offline asset integrity tests; copied/synthetic fixtures never run upstream code."""

from __future__ import annotations

import compileall
import glob
import hashlib
import json
import os
import shutil
import sys
import tomllib
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

from acq_py import preparation_assets as assets


@pytest.fixture
def bundle(tmp_path, monkeypatch):
    root = tmp_path / "bundle"
    shutil.copytree(assets._BUNDLE_ROOT, root)
    monkeypatch.setattr(assets, "_BUNDLE_ROOT", root)
    return root


def refused():
    return pytest.raises(
        assets.AssetError, match="^packaged preparation assets failed verification$"
    )


def test_real_package_pin_and_frozen_interface():
    verified = assets.verify_assets()
    assert verified.source_revision == "83c254a743f4b6fa539cafb1a453361a85e0691b"
    assert verified.validator_script == assets._BUNDLE_ROOT / assets._VALIDATOR
    assert verified.schema_dir == assets._BUNDLE_ROOT / assets._SCHEMAS
    assert verified.credential_bindings == assets._BUNDLE_ROOT / assets._BINDINGS
    assert verified.runtime_artifact == assets._BUNDLE_ROOT / assets._RUNTIME
    with pytest.raises(FrozenInstanceError):
        verified.source_revision = "untrusted"


def test_installer_style_compilation_preserves_closed_bundle(bundle, tmp_path, monkeypatch):
    # Exercise the stdlib compiler used by installers without needing pip/build
    # dependencies or running upstream code. Actual wheel/sdist proof is separate.
    verified = assets.verify_assets()
    assert verified.validator_script.name == "validate_provider_input_contract.py.txt"
    assert not list(bundle.rglob("*.py"))
    monkeypatch.setattr(sys, "pycache_prefix", None)
    monkeypatch.setattr(sys, "dont_write_bytecode", False)
    control = tmp_path / "control.py"
    control.write_text(
        "raise RuntimeError('compilation must not execute code')\n", encoding="utf-8"
    )

    assert compileall.compile_dir(tmp_path, force=True, quiet=2)

    # Positive control: an ordinary .py really was compiled in this environment.
    assert list((tmp_path / "__pycache__").glob("control.*.pyc"))
    assert not list(bundle.rglob("__pycache__"))
    assert not list(bundle.rglob("*.pyc"))
    assert assets.verify_assets() == verified


@pytest.mark.parametrize("name", sorted(assets._FILES | {"MANIFEST.json"}))
def test_every_file_is_required(bundle, name):
    (bundle / name).unlink()
    with refused():
        assets.verify_assets()


@pytest.mark.parametrize("name", sorted(assets._FILES | {"MANIFEST.json"}))
def test_every_file_digest_is_checked(bundle, name):
    path = bundle / name
    original = path.read_bytes()
    path.write_bytes(bytes([original[0] ^ 1]) + original[1:])
    with refused():
        assets.verify_assets()


@pytest.mark.parametrize("delta", [-1, 1])
def test_asset_size_is_checked(bundle, delta):
    path = bundle / assets._VALIDATOR
    original = path.read_bytes()
    path.write_bytes(original[:-1] if delta < 0 else original + b"x")
    with refused():
        assets.verify_assets()


@pytest.mark.parametrize("name", ["unexpected", ".hidden", "scripts/__pycache__"])
@pytest.mark.parametrize("directory", [False, True])
def test_closed_tree_rejects_extra_files_and_directories(bundle, name, directory):
    path = bundle / name
    path.mkdir() if directory else path.write_bytes(b"extra")
    with refused():
        assets.verify_assets()


@pytest.mark.parametrize("name", ["LICENSE", "MANIFEST.json", "scripts", "."])
def test_symlinks_rejected_even_when_target_bytes_are_valid(bundle, tmp_path, name):
    path = bundle if name == "." else bundle / name
    target = tmp_path / "original"
    path.rename(target)
    try:
        path.symlink_to(target, target_is_directory=target.is_dir())
    except OSError:
        pytest.skip("host does not permit fixture symlinks")
    with refused():
        assets.verify_assets()


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="POSIX fixture")
def test_fifo_is_rejected_without_opening(bundle):
    path = bundle / "LICENSE"
    path.unlink()
    os.mkfifo(path)
    with refused():
        assets.verify_assets()


def test_manifest_cannot_reauthorize_tampered_file(bundle):
    path = bundle / "LICENSE"
    path.write_bytes(b"replacement")
    manifest_path = bundle / "MANIFEST.json"
    manifest = json.loads(manifest_path.read_bytes())
    manifest["files"]["LICENSE"] = {
        "size": 11, "sha256": hashlib.sha256(b"replacement").hexdigest()
    }
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    with refused():
        assets.verify_assets()


def test_oversize_manifest_is_rejected_before_open(bundle, monkeypatch):
    (bundle / "MANIFEST.json").write_bytes(b"x" * (assets._MANIFEST_LIMIT + 1))

    def unexpected_open(*args, **kwargs):
        pytest.fail("oversize file must not be opened")

    monkeypatch.setattr(assets.os, "open", unexpected_open)
    with refused():
        assets.verify_assets()


@pytest.mark.parametrize("invalid", [None, [], {}, {"version": True}])
def test_synthetic_pinned_malformed_manifest_fails_closed(bundle, monkeypatch, invalid):
    # Synthetic application pin exercises shape checks beyond authentication.
    raw = json.dumps(invalid).encode()
    (bundle / "MANIFEST.json").write_bytes(raw)
    monkeypatch.setattr(assets, "_MANIFEST_SHA256", hashlib.sha256(raw).hexdigest())
    with refused():
        assets.verify_assets()


@pytest.mark.parametrize("change", ["escape", "missing", "negative", "boolean", "large", "digest", "record"])
def test_synthetic_pinned_bad_entries_fail_closed(bundle, monkeypatch, change):
    manifest_path = bundle / "MANIFEST.json"
    manifest = json.loads(manifest_path.read_bytes())
    files = manifest["files"]
    if change == "escape":
        files["../outside"] = files.pop("LICENSE")
    elif change == "missing":
        del files["LICENSE"]
    elif change in {"negative", "boolean", "large"}:
        files["LICENSE"]["size"] = {
            "negative": -1, "boolean": True, "large": assets._ASSET_LIMIT + 1
        }[change]
    elif change == "digest":
        files["LICENSE"]["sha256"] = "not a digest"
    else:
        files["LICENSE"] = None
    raw = json.dumps(manifest).encode()
    manifest_path.write_bytes(raw)
    monkeypatch.setattr(assets, "_MANIFEST_SHA256", hashlib.sha256(raw).hexdigest())
    with refused():
        assets.verify_assets()


def test_filesystem_errors_have_fixed_diagnostics(bundle, monkeypatch):
    def fail(*args, **kwargs):
        raise PermissionError("sensitive host path")

    monkeypatch.setattr(assets.os, "open", fail)
    with refused() as error:
        assets.verify_assets()
    assert error.value.__suppress_context__


def test_schema_reference_closure_is_local_and_resolves():
    schemas = assets.verify_assets().schema_dir
    documents = sorted(schemas.glob("*.schema.json"))
    assert len(documents) == 5
    references = []
    for path in documents:
        document = json.loads(path.read_bytes())
        pending = [document]
        while pending:
            node = pending.pop()
            if isinstance(node, list):
                pending.extend(node)
            elif isinstance(node, dict):
                pending.extend(node.values())
                assert "$dynamicRef" not in node and "$recursiveRef" not in node
                if "$ref" in node:
                    ref = node["$ref"]
                    assert ref.startswith("#/")
                    target = document
                    for token in ref[2:].split("/"):
                        target = target[token.replace("~1", "/").replace("~0", "~")]
                    assert isinstance(target, dict)
                    references.append((path.name, ref))
    assert references == [
        ("acq-neutral-model-catalog.schema.json", "#/$defs/releaseDateSource"),
        ("acq-neutral-model-catalog.schema.json", "#/$defs/cost"),
        ("acq-neutral-model-catalog.schema.json", "#/$defs/cost"),
        ("acq-neutral-model-catalog.schema.json", "#/$defs/model"),
    ]


def test_package_data_patterns_cover_exact_bundle():
    project = Path(__file__).resolve().parents[1]
    config = tomllib.loads((project / "pyproject.toml").read_text(encoding="utf-8"))
    patterns = config["tool"]["setuptools"]["package-data"]["acq_py"]
    package = project / "src" / "acq_py"
    included = {
        Path(match).relative_to(package / "preparation_bundle").as_posix()
        for pattern in patterns if pattern.startswith("preparation_bundle/")
        for match in glob.glob(str(package / pattern), recursive=True)
        if Path(match).is_file()
    }
    assert included == assets._FILES | {"MANIFEST.json"}
    assert "src/acq_py/preparation_bundle/LICENSE" in config["project"]["license-files"]
