"""Portable OS advisory migration lock (ADR-0041m).

The tree-level migration is a synchronized pre-step guarded by an exclusive OS
advisory lock: ``fcntl.flock`` on POSIX, ``msvcrt.locking`` on Windows. Both are
*advisory* locks the operating system releases automatically when the holding
process exits — including on a crash — so a crashed migration can never strand
state behind a stale lock. A second invocation waits a bounded interval
(:data:`DEFAULT_TIMEOUT_S`, overridable via ``ACQ_MIGRATION_LOCK_TIMEOUT``, read
at each acquisition rather than at import) and then fails closed with
:class:`MigrationLockTimeout` rather than racing the in-flight migration.

The same primitive also backs the per-sandbox lifecycle lock
(:func:`sandbox_lock`), which serializes create, recreate and rm on one sandbox.

This is an internal primitive, not part of the public ``acq`` command surface.
"""

from __future__ import annotations

import os
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path

from . import state, timeouts

if os.name == "nt":  # pragma: no cover - exercised only on Windows hosts
    import msvcrt
else:
    import fcntl

# Bounded wait before a second invocation fails closed (seconds). Overridable via
# TIMEOUT_ENV so a contract/unit vector can observe the fail-closed path without
# a long wait. The override is read lazily by ``configured_timeout_s()``: a
# malformed value must not crash an unrelated command at import, and a
# non-finite one must not make the bounded wait unbounded.
DEFAULT_TIMEOUT_S = 5.0
TIMEOUT_ENV = "ACQ_MIGRATION_LOCK_TIMEOUT"

# Poll interval between non-blocking acquisition attempts.
_RETRY_INTERVAL_S = 0.05


def configured_timeout_s() -> float:
    """The bounded lock wait in seconds: ``$ACQ_MIGRATION_LOCK_TIMEOUT`` or the default."""
    return timeouts.env_seconds(TIMEOUT_ENV, DEFAULT_TIMEOUT_S)


class LockTimeout(Exception):
    """An exclusive lock could not be acquired within its bounded wait."""


class MigrationLockTimeout(LockTimeout):
    """The migration lock could not be acquired within the bounded wait.

    Fail-closed: the caller reports ``migration_locked`` and never mutates while
    another migration holds the lock.
    """


class SandboxLockTimeout(LockTimeout):
    """Another acq command holds the lifecycle lock for this sandbox.

    Fail-closed: the caller reports the stable ``timeout`` code and changes
    nothing, rather than racing the in-flight create, recreate or rm.
    """


@contextmanager
def exclusive_lock(
    path: Path,
    timeout_s: float | None = None,
    *,
    what: str = "the migration lock",
    timeout_cls: type[LockTimeout] = MigrationLockTimeout,
    also_held: Callable[[], bool] | None = None,
) -> Iterator[None]:
    """Hold an exclusive OS advisory lock on ``path`` for the duration of the block.

    Creates ``path`` (and its parent) if needed. Waits up to ``timeout_s`` for the
    lock (default: :func:`configured_timeout_s`, read now rather than at import);
    raises ``timeout_cls`` past the deadline, naming ``what``. The lock is
    released in a ``finally`` on normal exit *and* is auto-released by the OS if
    the process dies without cleanup (a crash). ``also_held`` names a second,
    foreign lock: when it reports held after the OS lock is taken, the OS lock is
    released again and the wait continues.
    """
    if timeout_s is None:
        timeout_s = configured_timeout_s()
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "a+b")
    deadline = time.monotonic() + timeout_s
    acquired = False
    try:
        while True:
            try:
                if os.name == "nt":  # pragma: no cover - Windows only
                    # msvcrt.locking locks one byte; ensure the file has one.
                    fh.seek(0, os.SEEK_END)
                    if fh.tell() == 0:
                        fh.write(b"\0")
                        fh.flush()
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                if also_held is not None and also_held():
                    _unlock(fh)
                    acquired = False
                    raise BlockingIOError("held by a foreign lock")
                break
            except OSError:
                # The lock is held elsewhere (EWOULDBLOCK / EACCES / EDEADLK).
                if time.monotonic() >= deadline:
                    raise timeout_cls(
                        f"could not acquire {what} at {path} within {timeout_s:.1f}s"
                    )
                time.sleep(_RETRY_INTERVAL_S)
        yield
    finally:
        if acquired:
            _unlock(fh)
        fh.close()


def _unlock(fh) -> None:
    try:
        if os.name == "nt":  # pragma: no cover - Windows only
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Per-sandbox lifecycle lock.
# ---------------------------------------------------------------------------

# A create (kit install included) can legitimately run for minutes, so a second
# command on the same sandbox waits as long as Bash's provision lock does (300
# one-second retries) before failing closed. Overridable for tests and scripts.
DEFAULT_SANDBOX_TIMEOUT_S = 300.0
SANDBOX_TIMEOUT_ENV = "ACQ_SANDBOX_LOCK_TIMEOUT"

# How long a Bash lock directory with no owner file yet counts as live: Bash
# writes the owner right after ``mkdir``, so only a just-created one is in flight.
_BASH_OWNERLESS_GRACE_S = 60.0
# Without a usable PID probe (Windows), a Bash lock counts as live for this long:
# long enough to cover a create with a cold kit install.
_BASH_WINDOWS_FRESH_S = 900.0


def sandbox_lock_path(backend: str, name: str) -> Path:
    """The lock file for one sandbox, keyed like its state record."""
    return state.state_dir() / "locks" / state.safe_token(backend) / f"{state.record_key(name)}.lock"


@contextmanager
def sandbox_lock(backend: str, name: str) -> Iterator[None]:
    """Serialize lifecycle mutations (create, recreate, rm) of one sandbox.

    An OS advisory lock per sandbox, held across the whole transaction: the
    existence check, the backend call, the kit apply and the host-record writes.
    While Bash and Python acq coexist, a live Bash lock for the same sandbox (the
    ``mkdir`` lock its provision and terminate paths hold) also counts as held,
    so the two implementations never race each other on one sandbox. Raises
    :class:`SandboxLockTimeout` after ``$ACQ_SANDBOX_LOCK_TIMEOUT`` seconds.
    """
    timeout_s = timeouts.env_seconds(SANDBOX_TIMEOUT_ENV, DEFAULT_SANDBOX_TIMEOUT_S)
    with exclusive_lock(
        sandbox_lock_path(backend, name),
        timeout_s,
        what=f"the lifecycle lock for sandbox '{name}' (another acq command is changing it)",
        timeout_cls=SandboxLockTimeout,
        also_held=lambda: _bash_lock_held(backend, name),
    ):
        yield


def _posix_cksum(data: bytes) -> int:
    """POSIX ``cksum`` CRC of ``data``; Bash keys its per-sandbox paths with it."""
    crc = 0
    length = len(data)
    tail = bytearray()
    while length:
        tail.append(length & 0xFF)
        length >>= 8
    for byte in bytes(data) + bytes(tail):
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 else (crc << 1)
            crc &= 0xFFFFFFFF
    return ~crc & 0xFFFFFFFF


def _bash_lock_dir(backend: str, name: str) -> Path:
    """Bash's per-sandbox provision/terminate lock directory (``*.lock``).

    Mirrors ``acq_provider_input_root`` in ``acq.backends/common.sh``: Bash
    resolves its provenance root from ``ACQ_PROVENANCE_DIR`` or
    ``${XDG_STATE_HOME:-$HOME/.local/state}/acq/provenance``.
    """
    root = os.environ.get("ACQ_PROVENANCE_DIR") or ""
    if root:
        base = Path(root)
    else:
        xdg = os.environ.get("XDG_STATE_HOME") or ""
        home = os.environ.get("HOME") or str(Path.home())
        base = (Path(xdg) if xdg else Path(home) / ".local" / "state") / "acq" / "provenance"
    key = f"{state.safe_token(name)}.{_posix_cksum(name.encode('utf-8'))}"
    return base / "provider-input" / state.safe_token(backend) / f"{key}.lock"


def _bash_lock_held(backend: str, name: str) -> bool:
    """True while a Bash acq process holds its lock for this sandbox.

    The lock is live when its owner PID is running, or when it has no owner file
    yet and was created moments ago. A lock whose owner has exited is stale and is
    ignored (Bash itself recovers it). Windows hosts skip the PID probe (Git Bash
    PIDs are not Windows PIDs, and ``os.kill`` there terminates rather than
    probes), so there a lock counts as live while it is recent.
    """
    path = _bash_lock_dir(backend, name)
    try:
        if path.is_symlink() or not path.is_dir():
            return False
        owner = (path / "owner").read_text(encoding="utf-8").split()
    except FileNotFoundError:
        try:
            return time.time() - path.stat().st_mtime < _BASH_OWNERLESS_GRACE_S
        except OSError:
            return False
    except (OSError, UnicodeDecodeError):
        return False
    if os.name == "nt":  # pragma: no cover - Windows only
        try:
            return time.time() - path.stat().st_mtime < _BASH_WINDOWS_FRESH_S
        except OSError:
            return False
    if not owner or not owner[0].isdigit():
        return False
    try:
        os.kill(int(owner[0]), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # alive, owned by another user
    except (OSError, OverflowError):
        return False
    return True
