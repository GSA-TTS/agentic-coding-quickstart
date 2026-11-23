"""Verify the app-owned, offline preparation assets without executing them.

The code-pinned manifest authenticates package data, not provider input. Paths
remain valid only while the installed package is unchanged; callers must not
allow an untrusted writer to modify the application installation.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path

_BUNDLE_ROOT = Path(__file__).parent / "preparation_bundle"
_SOURCE_REVISION = "83c254a743f4b6fa539cafb1a453361a85e0691b"
_SOURCE_REPOSITORY = "https://github.com/GSA-TTS/agentic-coding-patterns"
_MANIFEST_SHA256 = "ffc5947c2c78c35d600104efd2b40d08d837d8345ba61ef3ced9e9fa1f5c4f39"
_MANIFEST_LIMIT = 16 * 1024
_ASSET_LIMIT = 1024 * 1024
_SCHEMAS = "integrations/isolation/schemas"
# Ship as data so ordinary installers cannot add bytecode to the closed tree.
# Python can still execute this byte-exact script via its explicit file path.
_VALIDATOR = "scripts/validate_provider_input_contract.py.txt"
_BINDINGS = f"{_SCHEMAS}/provider-credential-bindings.json"
_RUNTIME = (
    "integrations/isolation/acq-kits/opencode/files/home/opencode-config/"
    "runtime-model-preparation.mjs"
)
_FILES = frozenset({
    "LICENSE", "PROVENANCE.md", _VALIDATOR, _BINDINGS, _RUNTIME,
    *(
        f"{_SCHEMAS}/{name}.schema.json"
        for name in (
            "acq-provider-input-bundle", "acq-provider-input-bundle-v2",
            "acq-provider-input-bundle-v3", "acq-provider-facts",
            "acq-neutral-model-catalog",
        )
    ),
})
_FAILURE = "packaged preparation assets failed verification"


class AssetError(Exception):
    """The installed preparation assets are missing, unsafe, or inconsistent."""


@dataclass(frozen=True)
class VerifiedAssets:
    """Paths verified together against the application pin; not a file snapshot."""

    validator_script: Path
    schema_dir: Path
    credential_bindings: Path
    runtime_artifact: Path
    source_revision: str


def _read_regular(path: Path, limit: int) -> bytes:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
        raise AssetError(_FAILURE)
    # Nonblocking prevents a raced-in FIFO from hanging the caller. NOFOLLOW is
    # available on POSIX; the lstat/fstat identity check also covers other hosts.
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_BINARY", 0)
    with os.fdopen(os.open(path, flags), "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_size > limit
            or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            raise AssetError(_FAILURE)
        data = stream.read(limit + 1)
    if len(data) > limit or not stat.S_ISREG(path.lstat().st_mode):
        raise AssetError(_FAILURE)
    return data


def _check_tree(root: Path) -> None:
    files = _FILES | {"MANIFEST.json"}
    directories = {""}
    for name in files:
        directories.update(str(p) for p in Path(name).parents if str(p) != ".")
    seen: set[str] = set()
    pending = [root]
    while pending:
        directory = pending.pop()
        if not stat.S_ISDIR(directory.lstat().st_mode):
            raise AssetError(_FAILURE)
        with os.scandir(directory) as entries:
            for entry in entries:
                relative = (directory / entry.name).relative_to(root).as_posix()
                mode = entry.stat(follow_symlinks=False).st_mode
                if relative in directories and stat.S_ISDIR(mode):
                    pending.append(directory / entry.name)
                elif relative in files and stat.S_ISREG(mode):
                    seen.add(relative)
                else:
                    raise AssetError(_FAILURE)
    if seen != files:
        raise AssetError(_FAILURE)


def _verify_manifest(root: Path) -> None:
    raw = _read_regular(root / "MANIFEST.json", _MANIFEST_LIMIT)
    if hashlib.sha256(raw).hexdigest() != _MANIFEST_SHA256:
        raise AssetError(_FAILURE)
    manifest = json.loads(raw)
    if (
        not isinstance(manifest, dict)
        or set(manifest) != {"version", "source_repository", "source_revision", "files"}
        or type(manifest["version"]) is not int
        or manifest["version"] != 1
        or manifest["source_repository"] != _SOURCE_REPOSITORY
        or manifest["source_revision"] != _SOURCE_REVISION
        or not isinstance(manifest["files"], dict)
        or set(manifest["files"]) != _FILES
    ):
        raise AssetError(_FAILURE)
    for name, record in manifest["files"].items():
        if (
            not isinstance(record, dict)
            or set(record) != {"size", "sha256"}
            or type(record["size"]) is not int
            or not 0 <= record["size"] <= _ASSET_LIMIT
            or not isinstance(record["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is None
        ):
            raise AssetError(_FAILURE)
        data = _read_regular(root / name, record["size"])
        if len(data) != record["size"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise AssetError(_FAILURE)


def verify_assets() -> VerifiedAssets:
    """Verify only installed package assets, with bounded reads and fixed errors."""
    root = _BUNDLE_ROOT
    try:
        _check_tree(root)
        _verify_manifest(root)
    except (OSError, ValueError, TypeError, KeyError, AssetError):
        raise AssetError(_FAILURE) from None
    return VerifiedAssets(
        validator_script=root / _VALIDATOR,
        schema_dir=root / _SCHEMAS,
        credential_bindings=root / _BINDINGS,
        runtime_artifact=root / _RUNTIME,
        source_revision=_SOURCE_REVISION,
    )
