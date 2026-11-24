"""Edit-only, local 0.8.2 explicit-context SDK spike. Inert on import.

The caller owns a fresh process and immutable private two-package payload.
See docs/explorations/python-sdk-transport.md for the trust boundary.
"""

from __future__ import annotations

import hashlib
import importlib
import importlib.metadata
import importlib.util
import json
import os
import re
import stat
import sys
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import NoReturn

VERSION = "0.8.2"
MANIFEST = "sdk-manifest.json"
PACKAGES = ("microsandbox", "microsandbox_core")
DIST_INFO = "microsandbox-0.8.2.dist-info"
CORE_DIST_INFO = "microsandbox_core-0.8.2.dist-info"
ALLOWED_TOP_LEVEL = PACKAGES + (DIST_INFO, CORE_DIST_INFO)
CORE_REQUIREMENT = "microsandbox-core==0.8.2"
REQUIRED_FILES = (
    "microsandbox/__init__.py",
    "microsandbox_core/__init__.py",
    f"{DIST_INFO}/METADATA",
    f"{CORE_DIST_INFO}/METADATA",
)
MAX_MANIFEST = 1024 * 1024
MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_FILES = 1024
MAX_PROBE = 16384


class SDKContextRuntimeError(ValueError):
    """Sanitized refusal; a failed initialization requires a new process."""


@dataclass(frozen=True)
class SDKContextRuntimeConfig:
    payload_root: str
    manifest_sha256: str
    msb_path: str
    libkrunfw_path: str
    home: str
    config_path: str


@dataclass(frozen=True)
class LoadedSDKContext:
    """Process-local handle. Never serialize this object, modules, or context."""

    config: SDKContextRuntimeConfig
    sdk: ModuleType
    core: ModuleType
    context: object


_LOCK = threading.RLock()
_ATTEMPTED = False
_LOADED: LoadedSDKContext | None = None


def _refuse() -> NoReturn:
    raise SDKContextRuntimeError(
        "private SDK context initialization refused; use a fresh process"
    )


def _json(raw: bytes) -> object:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                _refuse()
            result[key] = value
        return result

    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: _refuse())


def _absolute(value: str) -> Path:
    if (type(value) is not str or not value or len(value) > 4096
            or any(ord(c) < 32 for c in value)):
        _refuse()
    path = Path(value)
    if not path.is_absolute() or str(path) != value or ".." in path.parts:
        _refuse()
    # Reject symlinks in every component, including the payload root's ancestors.
    for item in (*reversed(path.parents), path):
        if stat.S_ISLNK(item.lstat().st_mode):
            _refuse()
    return path


def _private(path: Path, *, directory: bool = False) -> os.stat_result:
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or info.st_mode & 0o022
            or info.st_uid != os.getuid()):
        _refuse()
    if not directory and info.st_nlink != 1:
        _refuse()
    return info


def _read(path: Path, limit: int, *, digest_only: bool = False) -> tuple[int, bytes | str]:
    before = _private(path)
    if before.st_size > limit:
        _refuse()
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(path, flags), "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            _refuse()
        digest, chunks, size = hashlib.sha256(), [], 0
        while chunk := stream.read(min(1024 * 1024, limit + 1 - size)):
            size += len(chunk)
            if size > limit:
                _refuse()
            digest.update(chunk)
            if not digest_only:
                chunks.append(chunk)
        after = os.fstat(stream.fileno())
        def identity(s):
            return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if size != before.st_size or identity(after) != identity(opened):
            _refuse()
    return size, digest.hexdigest() if digest_only else b"".join(chunks)


def _relative(name: str) -> bool:
    if type(name) is not str or len(name) > 1024:
        return False
    path = PurePosixPath(name)
    return (not path.is_absolute() and str(path) == name and ".." not in path.parts
            and len(path.parts) >= 2 and "\\" not in name
            and all(ord(c) >= 32 for c in name)
            and path.parts[0] in ALLOWED_TOP_LEVEL
            and "__pycache__" not in path.parts
            and path.suffix.lower() not in (".pth", ".pyc", ".pyo"))


def _inventory(root: Path) -> set[str]:
    files, directories, pending = set(), 0, [root]
    while pending:
        directory = pending.pop()
        _private(directory, directory=True)
        with os.scandir(directory) as entries:
            for entry in entries:
                path = Path(entry.path)
                name = path.relative_to(root).as_posix()
                if entry.is_dir(follow_symlinks=False):
                    directories += 1
                    if (directories > MAX_FILES or len(path.parts) - len(root.parts) > 16
                            or path.parts[len(root.parts)] not in ALLOWED_TOP_LEVEL
                            or "__pycache__" in path.parts):
                        _refuse()
                    pending.append(path)
                else:
                    _private(path)
                    if name != MANIFEST and not _relative(name):
                        _refuse()
                    files.add(name)
                    if len(files) > MAX_FILES + 1:
                        _refuse()
    return files


def _payload(config: SDKContextRuntimeConfig) -> tuple[Path, set[str]]:
    root = _absolute(config.payload_root)
    _private(root, directory=True)
    if re.fullmatch(r"[0-9a-f]{64}", config.manifest_sha256) is None:
        _refuse()
    _, raw = _read(root / MANIFEST, MAX_MANIFEST)
    if not isinstance(raw, bytes):
        _refuse()
    if hashlib.sha256(raw).hexdigest() != config.manifest_sha256:
        _refuse()
    manifest = _json(raw)
    if (type(manifest) is not dict or set(manifest) != {"schema", "version", "files"}
            or type(manifest["schema"]) is not int or manifest["schema"] != 1
            or manifest["version"] != VERSION):
        _refuse()
    files = manifest["files"]
    if type(files) is not dict or not 1 <= len(files) <= MAX_FILES:
        _refuse()
    total = 0
    for name, record in files.items():
        if (not _relative(name) or type(record) is not dict
                or set(record) != {"size", "sha256"}
                or type(record["size"]) is not int or not 0 <= record["size"] <= MAX_FILE
                or type(record["sha256"]) is not str
                or re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is None):
            _refuse()
        total += record["size"]
        if total > MAX_TOTAL:
            _refuse()
    if _inventory(root) != set(files) | {MANIFEST}:
        _refuse()
    for name, record in files.items():
        size, digest = _read(root / name, MAX_FILE, digest_only=True)
        if size != record["size"] or digest != record["sha256"]:
            _refuse()
    if not set(REQUIRED_FILES) <= files.keys():
        _refuse()
    if (files[f"{DIST_INFO}/METADATA"]["size"] > MAX_MANIFEST
            or files[f"{CORE_DIST_INFO}/METADATA"]["size"] > MAX_MANIFEST):
        _refuse()
    return root, set(files)


def _environment(config: SDKContextRuntimeConfig, root: Path, files: set[str]) -> None:
    expected = {"MSB_PATH": config.msb_path, "MSB_LIBKRUNFW_PATH": config.libkrunfw_path,
                "MSB_HOME": config.home, "MSB_CONFIG_PATH": config.config_path}
    for key, value in expected.items():
        if os.environ.get(key) != value:
            _refuse()
    if any(key.startswith("MSB_") and key not in expected for key in os.environ):
        _refuse()
    if any(key.startswith(("LD_", "DYLD_")) or key in (
            "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT") for key in os.environ):
        _refuse()
    if not sys.dont_write_bytecode:
        _refuse()
    for value in (config.msb_path, config.libkrunfw_path):
        path = _absolute(value)
        _private(path)
        if path.relative_to(root).as_posix() not in files:
            _refuse()
    if not os.access(config.msb_path, os.X_OK):
        _refuse()
    _private(_absolute(config.home), directory=True)
    path = _absolute(config.config_path)
    _, raw = _read(path, 4096)
    if not isinstance(raw, bytes):
        _refuse()
    if _json(raw) != {}:
        _refuse()


def _metadata(root: Path) -> None:
    distributions = list(importlib.metadata.distributions(path=[str(root)]))
    if len(distributions) != 2:
        _refuse()
    by_name: dict[str, importlib.metadata.Distribution] = {}
    for dist in distributions:
        names = dist.metadata.get_all("Name")
        if (names is None or len(names) != 1
                or dist.metadata.get_all("Version") != [VERSION]
                or Path(str(dist.locate_file(""))) != root
                or names[0] in by_name):
            _refuse()
        by_name[names[0]] = dist
    if set(by_name) != {"microsandbox", "microsandbox-core"}:
        _refuse()
    if by_name["microsandbox"].metadata.get_all("Requires-Dist") != [CORE_REQUIREMENT]:
        _refuse()
    if by_name["microsandbox-core"].metadata.get_all("Requires-Dist") is not None:
        _refuse()


def _is_sdk_module_name(name: str) -> bool:
    return any(name == pkg or name.startswith(f"{pkg}.") for pkg in PACKAGES)


def _origins(root: Path, files: set[str]) -> None:
    if not all(isinstance(sys.modules.get(pkg), ModuleType) for pkg in PACKAGES):
        _refuse()
    for name, module in tuple(sys.modules.items()):
        if not _is_sdk_module_name(name):
            continue
        if not isinstance(module, ModuleType):
            _refuse()
        pkg = "microsandbox_core" if name.startswith("microsandbox_core") else "microsandbox"
        pkg_root = root / pkg
        origin = getattr(module, "__file__", None)
        if origin is not None:
            origin_path = _absolute(origin)
            if (not origin_path.is_relative_to(pkg_root)
                    or origin_path.relative_to(root).as_posix() not in files):
                _refuse()
        locations = getattr(module, "__path__", ())
        if origin is None and not locations:
            _refuse()
        for location in locations:
            if not _absolute(str(location)).is_relative_to(pkg_root):
                _refuse()
    for dist_name, expected_req in (
        ("microsandbox", [CORE_REQUIREMENT]),
        ("microsandbox-core", None),
    ):
        dist = importlib.metadata.distribution(dist_name)
        if (Path(str(dist.locate_file(""))) != root
                or dist.version != VERSION
                or dist.metadata.get_all("Name") != [dist_name]
                or dist.metadata.get_all("Version") != [VERSION]
                or dist.metadata.get_all("Requires-Dist") != expected_req):
            _refuse()


def _import_private(root: Path, files: set[str]) -> tuple[ModuleType, ModuleType]:
    sys.path.insert(0, str(root))
    importlib.invalidate_caches()
    for pkg in ("microsandbox_core", "microsandbox"):
        spec = importlib.util.find_spec(pkg)
        if (spec is None or spec.origin is None
                or _absolute(spec.origin) != root / pkg / "__init__.py"):
            _refuse()
    core = importlib.import_module("microsandbox_core")
    sdk = importlib.import_module("microsandbox")
    _origins(root, files)
    return sdk, core


def _select_context(sdk: ModuleType, config: SDKContextRuntimeConfig) -> object:
    version_fn = getattr(sdk, "version", None)
    if not callable(version_fn) or version_fn() != VERSION:
        _refuse()
    local_cls = getattr(sdk, "LocalContext", None)
    base_cls = getattr(sdk, "Context", None)
    kind_enum = getattr(sdk, "ContextKind", None)
    if not isinstance(local_cls, type) or not isinstance(base_cls, type) or kind_enum is None:
        _refuse()
    context = local_cls(home=config.home, config_path=config.config_path)
    if not isinstance(context, local_cls) or not isinstance(context, base_cls):
        _refuse()
    local_kind = getattr(kind_enum, "LOCAL", None)
    kind = getattr(context, "kind", None)
    if local_kind is None or kind != local_kind or kind != "local":
        _refuse()
    sandboxes = getattr(context, "sandboxes", None)
    if (sandboxes is None
            or getattr(getattr(sandboxes, "context", None), "kind", None) != local_kind):
        _refuse()
    # LocalContext does not accept msb_path or libkrunfw_path; verify runtime resolution separately.
    resolved = sdk.resolve_runtime()
    if (resolved.msb_path != config.msb_path
            or resolved.libkrunfw_path != config.libkrunfw_path):
        _refuse()
    return context


def load_private_sdk_context(config: SDKContextRuntimeConfig) -> LoadedSDKContext:
    """Initialize once in an exclusively owned fresh process; never reset globals.

    No environment mutation, default-backend mutation, downloading, installation,
    PATH lookup, catalog migration or lifecycle calls. Failure poisons this loader
    even if native initialization only partially completed. Identical successful
    calls return the same handle.
    """
    global _ATTEMPTED, _LOADED
    with _LOCK:
        if _LOADED is not None:
            if type(config) is SDKContextRuntimeConfig and config == _LOADED.config:
                return _LOADED
            _refuse()
        if _ATTEMPTED:
            _refuse()
        _ATTEMPTED = True
        try:
            if type(config) is not SDKContextRuntimeConfig or os.name != "posix":
                _refuse()
            if any(_is_sdk_module_name(n) for n in sys.modules):
                _refuse()
            root, files = _payload(config)
            _environment(config, root, files)
            _metadata(root)
            # Plain path insertion deliberately does not execute site .pth files.
            sdk, core = _import_private(root, files)
            context = _select_context(sdk, config)
            _origins(root, files)
            _LOADED = LoadedSDKContext(config, sdk, core, context)
            return _LOADED
        except BaseException:
            # No rollback/unimport: the native process state cannot be restored.
            raise SDKContextRuntimeError(
                "private SDK context initialization refused; use a fresh process"
            ) from None


@contextmanager
def _quiet_native():
    # Only the disposable probe redirects file descriptors, never the library API.
    # Native diagnostics are neither protocol output nor safe error details.
    sys.stdout.flush()
    sys.stderr.flush()
    saved = (os.dup(1), os.dup(2))
    try:
        with open(os.devnull, "wb") as sink:
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
            try:
                yield
            finally:
                sys.stdout.flush()
                sys.stderr.flush()
    finally:
        for target, descriptor in zip((1, 2), saved, strict=True):
            os.dup2(descriptor, target)
            os.close(descriptor)


def _probe() -> int:
    """One fixed load-only operation for an externally isolated, bounded child."""
    try:
        raw = sys.stdin.buffer.read(MAX_PROBE + 1)
        if len(raw) > MAX_PROBE:
            _refuse()
        request = _json(raw)
        if type(request) is not dict or set(request) != {"operation", "config"}:
            _refuse()
        if request["operation"] != "load" or type(request["config"]) is not dict:
            _refuse()
        config = SDKContextRuntimeConfig(**request["config"])
        with _quiet_native():
            loaded = load_private_sdk_context(config)
            if load_private_sdk_context(config) is not loaded:
                _refuse()
            if getattr(loaded.context, "kind", None) != "local":
                _refuse()
            home_path = _absolute(config.home)
            if (home_path / "db").exists() or any(home_path.glob("*.db*")):
                _refuse()
        result, status = {"ok": True, "version": VERSION, "context": "local"}, 0
    except BaseException:
        result, status = {"ok": False, "error": "sdk-context-runtime-refused"}, 1
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(_probe())
