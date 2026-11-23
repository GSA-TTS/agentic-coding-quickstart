"""Offline, host-owned validation of an explicit set of private v3 snapshots.

The caller owns snapshot creation and must keep those bytes unchanged through
materialization. This adapter neither discovers bundles nor runs provider code.
"""

from __future__ import annotations

import json
import math
import os
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
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate  # Do not resolve: a venv commonly symlinks its interpreter.
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


def _manifest_identity(path: Path) -> tuple[int, int]:
    # O_NONBLOCK prevents an attacker-controlled FIFO from blocking before fstat.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > _MANIFEST_LIMIT:
            raise ValidatorError("provider manifest must be a bounded regular file")
        raw = stream.read(_MANIFEST_LIMIT + 1)
    if len(raw) > _MANIFEST_LIMIT:
        raise ValidatorError("provider manifest must be a bounded regular file")
    value = json.loads(raw, object_pairs_hook=_unique_object)
    if not isinstance(value, dict) or value.get("schemaVersion") != _V3:
        raise ValidatorError("fresh provider validation requires v3 manifests")
    return info.st_dev, info.st_ino


def _explicit_paths(manifests: Sequence[str | Path], deadline: float) -> list[Path]:
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
            identity = _manifest_identity(path)
            _remaining(deadline)
            if identity in identities:
                raise ValidatorError("duplicate provider manifest path")
            identities.add(identity)
            paths.append(path)
    except (OSError, ValueError, RecursionError):
        raise ValidatorError("provider manifest is missing, unreadable or malformed") from None
    return paths


def _credential_bindings(value: str | Path, deadline: float) -> Path:
    """Check a host-owned data snapshot; the pinned CLI validates its content."""
    _remaining(deadline)
    if not isinstance(value, (str, Path)) or not Path(value).is_absolute():
        raise ValidatorError("credential bindings must name an absolute regular snapshot")
    path = Path(value)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= _BINDINGS_LIMIT:
                raise ValidatorError("credential bindings must be a bounded nonempty regular snapshot")
            raw = stream.read(_BINDINGS_LIMIT + 1)
        if not raw or len(raw) > _BINDINGS_LIMIT:
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
    paths = _explicit_paths(manifests, deadline)
    # Lazy import keeps the adapter importable independently of packaged assets;
    # there is deliberately no production fallback when verification is absent.
    from .preparation_assets import verify_assets

    assets = verify_assets()
    _remaining(deadline)
    bindings = _credential_bindings(
        assets.credential_bindings if credential_bindings is None else credential_bindings, deadline,
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
