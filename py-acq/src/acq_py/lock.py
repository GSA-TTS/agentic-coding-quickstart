"""Portable OS advisory migration lock (ADR-0041m).

The tree-level migration is a synchronized pre-step guarded by an exclusive OS
advisory lock: ``fcntl.flock`` on POSIX, ``msvcrt.locking`` on Windows. Both are
*advisory* locks the operating system releases automatically when the holding
process exits — including on a crash — so a crashed migration can never strand
state behind a stale lock. A second invocation waits a bounded interval
(:data:`DEFAULT_TIMEOUT_S`, overridable via ``ACQ_MIGRATION_LOCK_TIMEOUT``) and
then fails closed with :class:`MigrationLockTimeout` rather than racing the
in-flight migration.

This is an internal primitive, not part of the public ``acq`` command surface.
"""

from __future__ import annotations

import os
import time
from contextlib import contextmanager
from pathlib import Path

if os.name == "nt":  # pragma: no cover - exercised only on Windows hosts
    import msvcrt
else:
    import fcntl

# Bounded wait before a second invocation fails closed (seconds). Overridable so
# a contract/unit vector can observe the fail-closed path without a long wait.
DEFAULT_TIMEOUT_S = float(os.environ.get("ACQ_MIGRATION_LOCK_TIMEOUT", "5.0"))

# Poll interval between non-blocking acquisition attempts.
_RETRY_INTERVAL_S = 0.05


class MigrationLockTimeout(Exception):
    """The migration lock could not be acquired within the bounded wait.

    Fail-closed: the caller reports ``migration_locked`` and never mutates while
    another migration holds the lock.
    """


@contextmanager
def exclusive_lock(path: Path, timeout_s: float = DEFAULT_TIMEOUT_S):
    """Hold an exclusive OS advisory lock on ``path`` for the duration of the block.

    Creates ``path`` (and its parent) if needed. Waits up to ``timeout_s`` for the
    lock; raises :class:`MigrationLockTimeout` past the deadline. The lock is
    released in a ``finally`` on normal exit *and* is auto-released by the OS if
    the process dies without cleanup (a crash).
    """
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
                break
            except OSError:
                # The lock is held elsewhere (EWOULDBLOCK / EACCES / EDEADLK).
                if time.monotonic() >= deadline:
                    raise MigrationLockTimeout(
                        f"could not acquire the migration lock at {path} "
                        f"within {timeout_s:.1f}s"
                    )
                time.sleep(_RETRY_INTERVAL_S)
        yield
    finally:
        if acquired:
            try:
                if os.name == "nt":  # pragma: no cover - Windows only
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        fh.close()
