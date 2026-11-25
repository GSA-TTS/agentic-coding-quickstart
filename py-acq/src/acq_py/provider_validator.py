"""Offline, host-owned validation of an explicit set of private v3 snapshots.

The caller owns snapshot creation and must keep those bytes unchanged through
materialization. This adapter neither discovers bundles nor runs provider code.
"""

from __future__ import annotations

import json
import math
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path

from . import userdirs

_OUTPUT_LIMIT = 64 * 1024
_MANIFEST_LIMIT = 1024 * 1024
_BINDINGS_LIMIT = 1024 * 1024
# Match the pinned runtime's facts read cap and RUNTIME_LIMITS.resultBytes.
_FACTS_LIMIT = 64 * 1024
_CATALOG_LIMIT = 4 * 1024 * 1024
_SPEC_LIMIT = 64 * 1024
# Count every consumed reference, including repeated files, plus bindings.
_INPUT_LIMIT = 16 * 1024 * 1024
# Matches the pinned Patterns runtime artifact's RUNTIME_LIMITS.providers.
_PROVIDER_LIMIT = 8
_REAP_SECONDS = 1.0
_V3 = "acq-provider-input-bundle/v3"
_PROBE = '''import importlib.metadata as m
required = {"PyYAML": "6.0.3", "jsonschema": "4.26.0"}
try:
    actual = {name: m.version(name) for name in required}
except m.PackageNotFoundError:
    raise SystemExit(2)
raise SystemExit(0 if actual == required else 2)
'''


class ValidatorError(Exception):
    """A closed diagnostic, never containing subprocess output or input paths."""


def _require_posix() -> None:
    if os.name != "posix" or sys.platform == "win32":
        raise ValidatorError("bounded provider validation is supported only on POSIX")


def _runtime_root() -> Path:
    override = os.environ.get("ACQ_PROVIDER_INPUT_DATA_DIR", "")
    if override:
        if not userdirs.is_absolute(override):
            raise ValidatorError("provider validator data directory must be absolute")
        return Path(override)
    try:
        return userdirs.xdg_base("XDG_DATA_HOME", ".local", "share") / "acq/provider-input-validator"
    except userdirs.UserDirError:
        raise ValidatorError("cannot resolve provider validator data directory") from None


def resolve_python(override: str | None = None) -> Path:
    """Resolve only a preinstalled runtime, preserving the venv's lexical path.

    No PATH lookup, shell parsing, installation, or fallback from a bad override.
    Native Windows execution is deliberately refused before any subprocess.
    """
    _require_posix()
    value = os.environ.get("ACQ_PROVIDER_INPUT_PYTHON", "") if override is None else override
    if not isinstance(value, str) or "\x00" in value:
        raise ValidatorError("provider validator Python must be an absolute executable path")
    if override == "":
        raise ValidatorError("provider validator Python override must not be empty")
    if value:
        if not userdirs.is_absolute(value):
            raise ValidatorError("provider validator Python must be an absolute executable path")
        candidates = [Path(value)]
    else:
        root = _runtime_root() / "provider-input-validator.current"
        candidates = [root / part for part in ("bin/python3", "Scripts/python.exe", "python.exe")]
    try:
        for candidate in candidates:
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate  # Do not resolve: a venv commonly symlinks its interpreter.
    except OSError:
        raise ValidatorError("preinstalled provider validator Python is unavailable") from None
    raise ValidatorError("preinstalled provider validator Python is unavailable")


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValidatorError("provider validation deadline exceeded")
    return remaining


def _collect(proc: subprocess.Popen, deadline: float) -> tuple[int, bytes]:
    output = bytearray()
    total = 0
    with selectors.DefaultSelector() as selector:
        for pipe in (proc.stdout, proc.stderr):
            if pipe is not None:
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ)
        while selector.get_map():
            for key, _ in selector.select(_remaining(deadline)):
                try:
                    chunk = os.read(key.fd, min(8192, _OUTPUT_LIMIT - total + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                total += len(chunk)
                if total > _OUTPUT_LIMIT:
                    raise ValidatorError("provider validation output limit exceeded")
                if key.fileobj is proc.stdout:
                    output.extend(chunk)
    try:
        return proc.wait(timeout=_remaining(deadline)), bytes(output)
    except subprocess.TimeoutExpired:
        raise ValidatorError("provider validation deadline exceeded") from None


def _stop(proc: subprocess.Popen) -> None:
    # Host-validator process group only; not a guest-process cleanup guarantee.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    finally:
        for pipe in (proc.stdout, proc.stderr):
            if pipe is not None:
                pipe.close()
    try:
        proc.wait(timeout=_REAP_SECONDS)
    except subprocess.TimeoutExpired:
        raise ValidatorError("provider validator cleanup could not be confirmed") from None


def _run_bounded(argv: list[str], deadline: float) -> tuple[int, bytes]:
    """Narrow POSIX capture for the trusted interpreter and packaged validator.

    Count BOTH streams before retaining bytes; never communicate() after timeout.
    A private process group, null stdin and a fixed cwd avoid terminal/workspace
    inheritance. This is not a sandbox for an untrusted executable override.
    """
    _require_posix()
    _remaining(deadline)
    try:
        proc = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd="/", start_new_session=True, close_fds=True,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        )
        try:
            return _collect(proc, deadline)
        finally:
            _stop(proc)
    except (OSError, ValueError):
        raise ValidatorError("provider validator process could not be run") from None


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON member")
        result[key] = value
    return result


class _InputBudget:
    """Byte budget only, not a parser allocation or process RSS bound."""

    def __init__(self) -> None:
        self.remaining = _INPUT_LIMIT


def _read_input(
    path: Path, limit: int, budget: _InputBudget, deadline: float, label: str,
) -> tuple[bytes, os.stat_result]:
    _remaining(deadline)
    # Trusted immutable ancestors are a caller obligation. The final component
    # cannot be a symlink, and a FIFO cannot block before the regular-file check.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValidatorError(f"{label} must be a bounded regular file")
        if info.st_size > budget.remaining:
            raise ValidatorError("provider validation aggregate input byte limit exceeded")
        raw = stream.read(min(limit, budget.remaining) + 1)
    if len(raw) > limit or len(raw) != info.st_size:
        raise ValidatorError(f"{label} must be a bounded immutable regular file")
    if len(raw) > budget.remaining:
        raise ValidatorError("provider validation aggregate input byte limit exceeded")
    budget.remaining -= len(raw)
    _remaining(deadline)
    return raw, info


def _relative_input(root: Path, value: object) -> Path:
    # Validate before Path normalizes dot/empty components. Use the v3 schema's
    # ASCII alphabet, with no empty components, traversal or control characters.
    if (not isinstance(value, str) or not 0 < len(value) <= 256
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", value) is None
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValidatorError("provider artifact path must be a strict relative path")
    path = root
    parts = value.split("/")
    for part in parts[:-1]:
        path /= part
        if not stat.S_ISDIR(path.lstat().st_mode):
            raise ValidatorError("provider artifact path components must be non-symlink directories")
    return path / parts[-1]


def _manifest_identity(path: Path, budget: _InputBudget, deadline: float) -> tuple[int, int]:
    raw, info = _read_input(path, _MANIFEST_LIMIT, budget, deadline, "provider manifest")
    value = json.loads(raw, object_pairs_hook=_unique_object)
    if not isinstance(value, dict) or value.get("schemaVersion") != _V3:
        raise ValidatorError("fresh provider validation requires v3 manifests")
    for field, limit in (("factsPath", _FACTS_LIMIT), ("snapshotPath", _CATALOG_LIMIT)):
        artifact = _relative_input(path.parent, value.get(field))
        _read_input(artifact, limit, budget, deadline, "provider artifact")
    # The pinned CLI also reads this undeclared adjacent YAML file if present.
    # Only absence is optional: dangling symlinks and nonregular files fail closed.
    spec = path.parent / "spec.yaml"
    try:
        spec.lstat()
    except FileNotFoundError:
        pass
    else:
        _read_input(spec, _SPEC_LIMIT, budget, deadline, "provider spec")
    return info.st_dev, info.st_ino


def _explicit_paths(
    manifests: Sequence[str | Path], deadline: float, budget: _InputBudget,
) -> list[Path]:
    if not isinstance(manifests, (list, tuple)) or not manifests:
        raise ValidatorError("provide a nonempty explicit manifest list or confirm empty selection")
    if len(manifests) > _PROVIDER_LIMIT:
        raise ValidatorError("provider manifest count exceeds the limit of eight")
    paths: list[Path] = []
    identities: set[tuple[int, int]] = set()
    try:
        for item in manifests:
            _remaining(deadline)
            if not isinstance(item, (str, Path)) or not str(item):
                raise ValidatorError("provider manifest paths must be explicit and absolute")
            path = Path(item)
            if not path.is_absolute():
                raise ValidatorError("provider manifest paths must be explicit and absolute")
            identity = _manifest_identity(path, budget, deadline)
            _remaining(deadline)
            if identity in identities:
                raise ValidatorError("duplicate provider manifest path")
            identities.add(identity)
            paths.append(path)
    except (OSError, ValueError, RecursionError):
        raise ValidatorError("provider input is missing, unreadable, unsafe or malformed") from None
    return paths


def _credential_bindings(value: str | Path, deadline: float, budget: _InputBudget) -> Path:
    """Check a host-owned data snapshot; the pinned CLI validates its content."""
    _remaining(deadline)
    if not isinstance(value, (str, Path)) or not Path(value).is_absolute():
        raise ValidatorError("credential bindings must name an absolute regular snapshot")
    path = Path(value)
    try:
        raw, _ = _read_input(path, _BINDINGS_LIMIT, budget, deadline, "credential bindings")
        if not raw:
            raise ValidatorError("credential bindings must be a bounded nonempty regular snapshot")
    except (OSError, ValueError):
        raise ValidatorError("credential bindings snapshot is missing, unreadable or unsafe") from None
    _remaining(deadline)
    return path


def validate_empty_selection() -> None:
    """Confirm a caller-established empty selection without discovery or execution.

    This explicit operation says nothing about missing or unreadable manifests;
    the caller must already have successfully selected zero providers.
    """


def validate_bundles(
    manifests: Sequence[str | Path], *, python_override: str | None = None,
    credential_bindings: str | Path | None = None, timeout: float = 30.0,
) -> None:
    """Validate all private v3 manifest snapshots in one pinned CLI invocation.

    Raises ValidatorError (or the asset verifier's fixed AssetError) on refusal.
    Optional credential_bindings names a caller-owned immutable merged binding
    snapshot, not executable code. Otherwise use the verified packaged default.
    Input inspection, probe and validation share a deadline of at most 300
    seconds; process reaping may take another second. No output is published.
    """
    _require_posix()
    if (isinstance(timeout, bool) or not isinstance(timeout, (int, float))
            or not math.isfinite(timeout) or not 0 < timeout <= 300):
        raise ValidatorError("provider validation timeout must be finite and within 300 seconds")
    deadline = time.monotonic() + timeout
    budget = _InputBudget()
    paths = _explicit_paths(manifests, deadline, budget)
    # Lazy import keeps the adapter importable independently of packaged assets;
    # there is deliberately no production fallback when verification is absent.
    from .preparation_assets import verify_assets

    assets = verify_assets()
    _remaining(deadline)
    bindings = _credential_bindings(
        assets.credential_bindings if credential_bindings is None else credential_bindings,
        deadline, budget,
    )
    python = resolve_python(python_override)
    status, _ = _run_bounded([str(python), "-I", "-c", _PROBE], deadline)
    if status:
        raise ValidatorError("provider validator requires PyYAML 6.0.3 and jsonschema 4.26.0")
    argv = [str(python), "-I", str(assets.validator_script),
            "--schema-dir", str(assets.schema_dir),
            "--credential-bindings", str(bindings)]
    for path in paths:
        argv.extend(("--bundle", str(path)))
    status, _ = _run_bounded(argv, deadline)
    if status:
        raise ValidatorError("provider manifest set failed pinned contract validation")
