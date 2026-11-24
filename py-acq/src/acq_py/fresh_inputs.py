"""Stage only the verified packaged USAi/OpenCode fresh-launch profile.

The installed application and provenance ancestors are trusted host storage.
Private snapshots prevent source re-reads after validation; a generation receipt
detects corruption, not a same-account attacker who can rewrite the receipt too.
No credentials, downloads, provider executables or mutable-current reads occur.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path

from . import errors, kitspec, preparation_assets, provider_input, provider_validator

_PROVIDER = "models/providers/usai"
_RUNTIME = "runtime-model-preparation.mjs"
_BASE = "base-config.jsonc"
_RECEIPT = "prepared-inputs.json"
_MANIFEST_LIMIT = 1024 * 1024
_FACTS_LIMIT = 64 * 1024
_CATALOG_LIMIT = 4 * 1024 * 1024
_ASSET_LIMIT = 1024 * 1024
_SPEC_LIMIT = 64 * 1024
_RECEIPT_LIMIT = 4096
_TOTAL_LIMIT = 16 * 1024 * 1024
_LIMITS = {
    f"{_PROVIDER}/facts.json": _FACTS_LIMIT,
    f"{_PROVIDER}/snapshot.json": _CATALOG_LIMIT,
    f"{_PROVIDER}/discovery.json": 4096,
    _RUNTIME: _ASSET_LIMIT,
    _BASE: _ASSET_LIMIT,
}
_V2 = {
    "schemaVersion": "acq-provider-input-bundle/v2",
    "providerId": "usai",
    "factsPath": "provider-input/facts.json",
    "normalizerPath": "scripts/normalize-catalog.mjs",
    "snapshotPath": "files/home/usai-config/model-catalog-snapshot.json",
    "providerPath": _PROVIDER,
    "credentialEnvNames": ["USAI_API_KEY"],
}
_DISCOVERY = {
    "schemaVersion": "acq-runtime-discovery/v1",
    "providerId": "usai",
    "adapter": "usai-openai-list/v1",
}
_FACTS = {
    "schemaVersion": "acq-provider-facts/v1",
    "providerId": "usai",
    "apiProtocol": "openai-compatible",
    "host": "api.gsa.usai.gov",
    "baseUrl": "https://api.gsa.usai.gov/api/v1",
    "modelsUrl": "https://api.gsa.usai.gov/api/v1/models",
    "keyEnv": "USAI_API_KEY",
}
_FAILURE = "packaged fresh inputs are unavailable, unsafe or inconsistent"


class FreshInputsError(provider_input.ProviderInputError):
    """A fixed diagnostic suitable for the existing CLI error boundary."""

    def __init__(self) -> None:
        super().__init__(errors.VALIDATION_FAILED, _FAILURE,
                         "verify the installed application and validator; recreate the sandbox")


@dataclass(frozen=True)
class PreparedInputs:
    """An unpublished exact generation, never an authority to launch by itself."""

    generation: Path
    guest_root: str
    routing_digest: str
    artifact_sha256: str
    base_config_sha256: str
    guest_artifact: str
    guest_base_config: str
    usai: bool = True


def _encode(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=True, allow_nan=False) + "\n").encode("ascii")


def _unique(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            raise FreshInputsError()
        result[key] = value
    return result


def _object(raw: bytes) -> dict:
    value = json.loads(raw, object_pairs_hook=_unique)
    if not isinstance(value, dict):
        raise FreshInputsError()
    return value


def _sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _read(root: Path, relative: str, limit: int) -> bytes:
    """Bounded descriptor-relative no-follow read, including every child dir."""
    parts = relative.split("/")
    if any(p in (".", "..") or re.fullmatch(r"[A-Za-z0-9._-]+", p) is None for p in parts):
        raise FreshInputsError()
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for index, part in enumerate(parts):
            flags = os.O_RDONLY | os.O_NOFOLLOW
            flags |= os.O_NONBLOCK if index == len(parts) - 1 else os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > limit:
            raise FreshInputsError()
        with os.fdopen(fd, "rb") as stream:
            fd = -1
            raw = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
        if (len(raw) > limit or len(raw) != before.st_size
                or (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                != (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise FreshInputsError()
        return raw
    finally:
        if fd >= 0:
            os.close(fd)


def _closed_tree(root: Path, files: set[str], *, empty_providers: bool = False) -> None:
    """Reject every extra entry, even empty directories, links and special files."""
    directories = {""}
    if empty_providers:
        directories.update(("models", "models/providers"))
        for relative in ("models", "models/providers"):
            if not stat.S_ISDIR((root / relative).lstat().st_mode):
                raise FreshInputsError()
    for name in files:
        directories.update(str(p) for p in Path(name).parents if str(p) != ".")
    seen: set[str] = set()
    pending = [root]
    while pending:
        directory = pending.pop()
        if not stat.S_ISDIR(directory.lstat().st_mode):
            raise FreshInputsError()
        with os.scandir(directory) as entries:
            for entry in entries:
                relative = (directory / entry.name).relative_to(root).as_posix()
                mode = entry.stat(follow_symlinks=False).st_mode
                if relative in directories and stat.S_ISDIR(mode):
                    pending.append(directory / entry.name)
                elif relative in files and stat.S_ISREG(mode):
                    seen.add(relative)
                else:
                    raise FreshInputsError()
    if seen != files:
        raise FreshInputsError()


def _bundle_inventory() -> dict:
    # Preflight the legacy verifier's unbounded reads. The installed tree must
    # remain trusted and unchanged while that verifier runs.
    manifest = kitspec.bundle_manifest()
    inventory: dict = {}
    total = 0
    for kit, entry in manifest["kits"].items():
        for relative, meta in entry["files"].items():
            name = f"{kit}/{relative}"
            size = meta["size"]
            if (type(size) is not int or not 0 <= size <= _CATALOG_LIMIT
                    or len(inventory) >= 128):
                raise FreshInputsError()
            total += size
            if total > _TOTAL_LIMIT:
                raise FreshInputsError()
            inventory[name] = meta
    _closed_tree(kitspec.BUNDLE_DIR, set(inventory) | {"MANIFEST.json"})
    for name, meta in inventory.items():
        if len(_read(kitspec.BUNDLE_DIR, name, meta["size"])) != meta["size"]:
            raise FreshInputsError()
    if kitspec.verify_bundle():
        raise FreshInputsError()
    return inventory


def _kit_bytes(inventory: dict, name: str, limit: int) -> bytes:
    raw = _read(kitspec.BUNDLE_DIR, name, limit)
    meta = inventory[name]
    blob = hashlib.sha1(b"blob %d\0" % len(raw) + raw, usedforsecurity=False).hexdigest()
    if len(raw) != meta["size"] or blob != meta["git_blob"]:
        raise FreshInputsError()
    return raw


def _sources() -> tuple[dict[str, bytes], bytes, bytes]:
    inventory = _bundle_inventory()
    assets = preparation_assets.verify_assets()
    manifest = _object(_kit_bytes(inventory, "usai-provider/provider-input.json", _MANIFEST_LIMIT))
    if manifest != _V2:
        raise FreshInputsError()
    facts = _kit_bytes(inventory, f"usai-provider/{manifest['factsPath']}", _FACTS_LIMIT)
    if _object(facts) != _FACTS:
        raise FreshInputsError()
    catalog = _kit_bytes(inventory, f"usai-provider/{manifest['snapshotPath']}", _CATALOG_LIMIT)
    spec = _kit_bytes(inventory, "usai-provider/spec.yaml", _SPEC_LIMIT)
    # Explicit conversion: no normalizer is copied or executed, even if present.
    v3 = {key: value for key, value in manifest.items() if key != "normalizerPath"}
    v3.update(schemaVersion="acq-provider-input-bundle/v3", factsPath="facts.json",
              snapshotPath="snapshot.json", discovery={"adapter": _DISCOVERY["adapter"]})
    snapshot = {"provider-input.json": _encode(v3), "facts.json": facts,
                "snapshot.json": catalog, "spec.yaml": spec}
    base = _kit_bytes(inventory, "opencode/files/home/opencode-config/base-config.jsonc", _ASSET_LIMIT)
    runtime = _read(assets.runtime_artifact.parent, assets.runtime_artifact.name, _ASSET_LIMIT)
    return snapshot, runtime, base


def _write(root: Path, files: dict[str, bytes], mode: int) -> None:
    for name, raw in files.items():
        destination = root / name
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        provider_input._copy_out(raw, destination, mode)


def _validate_snapshot(root: Path, snapshot: dict[str, bytes]) -> None:
    private = Path(tempfile.mkdtemp(prefix=".snapshot.", dir=root))
    try:
        _write(private, snapshot, 0o400)
        provider_validator.validate_bundles([private / "provider-input.json"])
        _closed_tree(private, set(snapshot))
        # Do not accept validator-side mutation, and never re-read source kits.
        for name, expected in snapshot.items():
            if _read(private, name, len(expected)) != expected:
                raise FreshInputsError()
    finally:
        provider_input.discard(private)


def _receipt(files: dict[str, bytes], *, usai: bool = True) -> dict:
    routing: dict
    if usai:
        facts = _object(files[f"{_PROVIDER}/facts.json"])
        discovery = _object(files[f"{_PROVIDER}/discovery.json"])
        if facts != _FACTS or discovery != _DISCOVERY:
            raise FreshInputsError()
        routing = {"facts": facts, "discovery": discovery}
    else:
        routing = {"providers": []}
    return {
        "schemaVersion": "acq-prepared-inputs/v1",
        "profile": "packaged-usai-opencode/v1" if usai else "packaged-none-opencode/v1",
        "routing_digest": _sha(_encode(routing)),
        "files": {name: {"size": len(raw), "sha256": _sha(raw)} for name, raw in files.items()},
    }


def _prepared(generation: Path, receipt: dict) -> PreparedInputs:
    guest = provider_input.guest_root(generation)
    return PreparedInputs(generation, guest, receipt["routing_digest"],
                          receipt["files"][_RUNTIME]["sha256"],
                          receipt["files"][_BASE]["sha256"],
                          f"{guest}/{_RUNTIME}", f"{guest}/{_BASE}", receipt["profile"] == "packaged-usai-opencode/v1")


def _materialize(root: Path, snapshot: dict[str, bytes], runtime: bytes, base: bytes, *, usai: bool = True) -> PreparedInputs:
    files = {f"{_PROVIDER}/facts.json": snapshot["facts.json"],
             f"{_PROVIDER}/snapshot.json": snapshot["snapshot.json"],
             f"{_PROVIDER}/discovery.json": _encode(_DISCOVERY)} if usai else {}
    files.update({_RUNTIME: runtime, _BASE: base})
    receipt = _receipt(files, usai=usai)
    files[_RECEIPT] = _encode(receipt)
    staging = Path(tempfile.mkdtemp(prefix=".staging.", dir=root))
    generation = root / f"generation.{uuid.uuid4().hex}"
    try:
        _write(staging, files, 0o444)
        (staging / "models/providers").mkdir(parents=True, exist_ok=True)
        _closed_tree(staging, set(files), empty_providers=not usai)
        for name, expected in files.items():
            if _read(staging, name, len(expected)) != expected:
                raise FreshInputsError()
        directories = [staging / "models/providers", staging / "models", staging]
        if usai:
            directories.append(staging / _PROVIDER)
        for directory in directories:
            directory.chmod(0o755)  # guest traversal; the backend mount must be read-only
        result = _prepared(generation, receipt)
        staging.rename(generation)
        return result
    finally:
        if staging.exists():
            provider_input.discard(staging)


def _require_posix() -> None:
    if os.name != "posix":
        raise FreshInputsError()


def prepare(name: str, *, usai: bool = True) -> PreparedInputs:
    """Validate the packaged profile once; return a complete unpublished generation.

    Caller must first admit the exact packaged profile. Mount with
    provider_input.msb_flags(), then publish only after backend acceptance.
    The validator uses its preinstalled runtime; this helper never installs it.
    """
    try:
        _require_posix()
        if type(usai) is not bool:
            raise FreshInputsError()
        snapshot, runtime, base = _sources()
        root = provider_input.input_root("msb", name) / "generations"
        provider_input._safe_dir(root)
        root = root.resolve(strict=True)
        if usai:
            _validate_snapshot(root, snapshot)
        return _materialize(root, snapshot, runtime, base, usai=usai)
    except (OSError, ValueError, TypeError, KeyError, RecursionError, kitspec.KitSpecError,
            preparation_assets.AssetError, provider_validator.ValidatorError,
            provider_input.ProviderInputError):
        raise FreshInputsError() from None


def read_existing(name: str, generation: Path) -> PreparedInputs:
    """Verify the backend's exact mount source, never follow a current pointer.

    Closed inventory and byte digests detect tampering against the host receipt.
    The host receipt is not authenticated against a writer of that same account.
    This does not re-run discovery or the validator, or authorize live activation.
    """
    try:
        _require_posix()
        root = (provider_input.input_root("msb", name) / "generations").resolve(strict=True)
        generation = Path(generation)
        if (not generation.is_absolute() or generation.parent != root
                or re.fullmatch(r"generation\.[A-Za-z0-9_-]+", generation.name) is None):
            raise FreshInputsError()
        stored = _object(_read(generation, _RECEIPT, _RECEIPT_LIMIT))
        profile = stored.get("profile")
        if profile not in ("packaged-usai-opencode/v1", "packaged-none-opencode/v1"):
            raise FreshInputsError()
        usai = profile == "packaged-usai-opencode/v1"
        limits = _LIMITS if usai else {_RUNTIME: _ASSET_LIMIT, _BASE: _ASSET_LIMIT}
        _closed_tree(generation, set(limits) | {_RECEIPT}, empty_providers=not usai)
        files = {relative: _read(generation, relative, limit) for relative, limit in limits.items()}
        receipt = _receipt(files, usai=usai)
        # Byte-exact canonical encoding also rejects duplicate/extra receipt keys.
        if _read(generation, _RECEIPT, _RECEIPT_LIMIT) != _encode(receipt):
            raise FreshInputsError()
        # A self-consistent old receipt is not the currently installed runtime
        # or policy. Verify current sources, not just hashes supplied by receipt.
        _snapshot, runtime, base = _sources()
        if files[_RUNTIME] != runtime or files[_BASE] != base:
            raise FreshInputsError()
        return _prepared(generation, receipt)
    except (OSError, ValueError, TypeError, KeyError, RecursionError, kitspec.KitSpecError,
            preparation_assets.AssetError,
            provider_input.ProviderInputError):
        raise FreshInputsError() from None
