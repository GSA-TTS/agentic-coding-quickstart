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
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path

from . import hostexec, state, timeouts

if sys.platform == "win32":  # pragma: no cover - exercised only on Windows hosts
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
    ``remediation`` is the acq-authored next step to show the user.
    """

    def __init__(self, message: str, remediation: str | None = None):
        super().__init__(message)
        self.remediation = remediation


class SandboxLockUnsafe(SandboxLockTimeout):
    """The Bash lock's directory is a link or not a directory, so it is not taken.

    A :class:`SandboxLockTimeout` so every lifecycle verb refuses it the same
    way, with its own remediation.
    """


@contextmanager
def exclusive_lock(
    path: Path,
    timeout_s: float | None = None,
    *,
    what: str = "the migration lock",
    timeout_cls: type[LockTimeout] = MigrationLockTimeout,
    also_acquire: Callable[[], bool] | None = None,
    retry_s: float = _RETRY_INTERVAL_S,
) -> Iterator[None]:
    """Hold an exclusive OS advisory lock on ``path`` for the duration of the block.

    Creates ``path`` (and its parent) if needed. Waits up to ``timeout_s`` for the
    lock (default: :func:`configured_timeout_s`, read now rather than at import);
    raises ``timeout_cls`` past the deadline, naming ``what``. The lock is
    released in a ``finally`` on normal exit *and* is auto-released by the OS if
    the process dies without cleanup (a crash). ``also_acquire`` takes a second
    lock once the OS lock is held; when it returns False (held elsewhere) the OS
    lock is released again and the wait continues. The caller releases that
    second lock itself, inside the block. Errors it raises propagate.
    """
    if timeout_s is None:
        timeout_s = configured_timeout_s()
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "a+b")
    deadline = time.monotonic() + timeout_s
    acquired = False
    try:
        while True:
            if _try_os_lock(fh):
                if also_acquire is None or also_acquire():
                    acquired = True
                    break
                _unlock(fh)
            if time.monotonic() >= deadline:
                raise timeout_cls(f"could not acquire {what} at {path} within {timeout_s:.1f}s")
            time.sleep(retry_s)
        yield
    finally:
        if acquired:
            _unlock(fh)
        fh.close()


def _try_os_lock(fh) -> bool:
    """Take the OS advisory lock without blocking; False when it is held elsewhere."""
    try:
        if sys.platform == "win32":  # pragma: no cover - Windows only
            # msvcrt.locking locks one byte; ensure the file has one.
            fh.seek(0, os.SEEK_END)
            if fh.tell() == 0:
                fh.write(b"\0")
                fh.flush()
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Held elsewhere (EWOULDBLOCK / EACCES / EDEADLK).
        return False
    return True


def _unlock(fh) -> None:
    try:
        if sys.platform == "win32":  # pragma: no cover - Windows only
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

# Poll interval while another command holds the sandbox: each poll may probe a
# Bash lock owner with ``ps``, so it is coarser than the migration lock's.
_SANDBOX_RETRY_S = 0.2

# On Windows a Bash lock directory counts as held for this long after it was
# created (there is no usable PID probe there). Long enough to cover a create
# with a cold kit install.
_BASH_WINDOWS_FRESH_S = 900.0

_BASH_SAFE_BYTES = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")


def sandbox_lock_path(backend: str, name: str) -> Path:
    """The lock file for one sandbox, keyed like its state record."""
    return state.state_dir() / "locks" / state.safe_token(backend) / f"{state.record_key(name)}.lock"


@contextmanager
def sandbox_lock(backend: str, name: str) -> Iterator[None]:
    """Serialize lifecycle mutations (create, recreate, rm, kit apply) of one sandbox.

    Two locks are held for the whole transaction:

    * an OS advisory lock on :func:`sandbox_lock_path`, which serializes Python
      acq commands and is released by the OS if the process dies; and
    * Bash acq's per-sandbox ``mkdir`` lock (see :class:`_BashLock`), taken with
      the same owner line and stale-owner rules Bash uses, so Bash and Python acq
      also exclude each other while they coexist.

    Raises :class:`SandboxLockTimeout` after ``$ACQ_SANDBOX_LOCK_TIMEOUT``
    seconds (default 300).
    """
    timeout_s = timeouts.env_seconds(SANDBOX_TIMEOUT_ENV, DEFAULT_SANDBOX_TIMEOUT_S)
    bash = _BashLock(backend, name)
    try:
        with exclusive_lock(
            sandbox_lock_path(backend, name),
            timeout_s,
            what=f"the lifecycle lock for sandbox '{name}' (another acq command is changing it)",
            timeout_cls=SandboxLockTimeout,
            also_acquire=bash.acquire,
            retry_s=_SANDBOX_RETRY_S,
        ):
            try:
                yield
            finally:
                bash.release()
    except SandboxLockUnsafe:
        raise
    except SandboxLockTimeout as exc:
        raise SandboxLockTimeout(str(exc), bash.remediation(name)) from None


class ProviderCredentialLockTimeout(LockTimeout):
    """Another acq command is changing the same provider-credential binding."""


def provider_credential_lock_path(provider: str) -> Path:
    """The lock file for one provider's credential binding, keyed like its record."""
    return state.state_dir() / "locks" / "provider-credentials" / f"{state.record_key(provider)}.lock"


@contextmanager
def provider_credential_lock(provider: str) -> Iterator[None]:
    """Serialize ``provider-credential set``/``rm`` for one provider.

    ``set`` snapshots the binding record, writes it, stores the value and may
    put the snapshot back; ``rm`` removes the credential and then the record. A
    second command for the same provider waiting here can therefore never see,
    or roll back to, a half-finished change. Storing and re-feeding a value can
    take as long as a sandbox lifecycle step, so the wait is the lifecycle
    lock's (``$ACQ_SANDBOX_LOCK_TIMEOUT``). Raises
    :class:`ProviderCredentialLockTimeout`.
    """
    timeout_s = timeouts.env_seconds(SANDBOX_TIMEOUT_ENV, DEFAULT_SANDBOX_TIMEOUT_S)
    with exclusive_lock(
        provider_credential_lock_path(provider),
        timeout_s,
        what=f"the provider-credential lock for '{provider}' (another acq command is changing it)",
        timeout_cls=ProviderCredentialLockTimeout,
        retry_s=_SANDBOX_RETRY_S,
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


def posix_cksum(data: bytes) -> int:
    """POSIX ``cksum`` CRC of ``data`` (public name for the other Bash-layout readers)."""
    return _posix_cksum(data)


def _bash_safe(token: str) -> str:
    """Bash's ``tr -c 'A-Za-z0-9._-' '_'``: every other UTF-8 byte becomes ``_``."""
    return "".join(chr(b) if b in _BASH_SAFE_BYTES else "_" for b in token.encode("utf-8"))


def bash_provenance_dir() -> Path:
    """Bash's provenance root (``_acq_provenance_dir`` in ``acq.backends/common.sh``).

    Delegates to :func:`state.provenance_dir`, which refuses a relative
    ``ACQ_PROVENANCE_DIR`` and ignores relative user directories.
    """
    return state.provenance_dir()


def bash_sandbox_key(name: str) -> str:
    """Bash's per-sandbox path key: the sanitized name, a dot, and the name's ``cksum``."""
    return f"{_bash_safe(name)}.{_posix_cksum(name.encode('utf-8'))}"


def _bash_lock_dir(backend: str, name: str) -> Path:
    """Bash's per-sandbox provision/terminate lock directory (``*.lock``).

    Mirrors ``acq_provider_input_root`` in ``acq.backends/common.sh``.
    """
    return bash_provenance_dir() / "provider-input" / _bash_safe(backend) / f"{bash_sandbox_key(name)}.lock"


_O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def _open_lock_parent(parent: Path) -> int:
    """Open (creating as needed) the Bash lock's parent directory; returns its descriptor.

    The provenance root is acq's own tree and is created normally (it may sit
    under a home directory that is itself reached through a link). Every
    directory below it is created and opened relative to the one above with
    ``O_NOFOLLOW``, as Bash's ``_acq_provider_input_safe_mkdir`` walks its path,
    so a link planted there can never send the lock, or the owner file written
    into it, out of the tree. Raises :class:`SandboxLockUnsafe` for a link or
    non-directory on the way.
    """
    root = bash_provenance_dir()
    root.mkdir(parents=True, exist_ok=True)
    fd = os.open(root, os.O_RDONLY | _O_DIRECTORY)
    here = root
    try:
        for part in parent.relative_to(root).parts:
            here = here / part
            try:
                os.mkdir(part, dir_fd=fd)
            except FileExistsError:
                pass
            try:
                child = os.open(part, os.O_RDONLY | _O_DIRECTORY | _O_NOFOLLOW, dir_fd=fd)
            except OSError as exc:
                raise SandboxLockUnsafe(
                    f"unsafe sandbox lock path: {here} is a symbolic link or not a directory",
                    f"remove {here} (acq creates it again as a directory), then retry",
                ) from exc
            os.close(fd)
            fd = child
    except BaseException:
        os.close(fd)
        raise
    return fd


def _owner_pid(token: str) -> int | None:
    """An owner PID field as an int, or ``None`` unless it is plain ASCII digits."""
    if not (token.isascii() and token.isdigit()):
        return None
    try:
        return int(token)
    except ValueError:
        return None


def _process_identity(pid: int) -> str | None:
    """The start-time identity Bash records next to a lock owner's PID.

    Mirrors ``_acq_provider_input_process_identity``: the ``/proc/PID`` mtime in
    seconds where ``/proc/PID/ppid`` exists (Cygwin/MSYS), else ``ps -o lstart=``
    with all whitespace removed. ``None`` when it cannot be determined.
    """
    proc = Path(f"/proc/{pid}")
    try:
        if os.access(proc / "ppid", os.R_OK):
            return str(int(proc.stat().st_mtime))
    except OSError:
        return None
    ps = hostexec.which("ps")  # resolved from absolute PATH entries only
    if ps is None:
        return None
    try:
        out = subprocess.run(
            [ps, "-o", "lstart=", "-p", str(pid)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    ident = "".join(out.stdout.split()) if out.returncode == 0 else ""
    return ident or None


def _pid_alive(pid: int | None) -> bool:
    """``kill -0 PID``: True when the process exists (even if owned by another user)."""
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, OverflowError, ValueError):
        return False
    return True


def _owner_line(lock_dir: Path) -> str:
    """The first line of a lock's ``owner`` file ("" when it cannot be read)."""
    try:
        return (lock_dir / "owner").read_text(encoding="utf-8").split("\n", 1)[0]
    except (OSError, UnicodeDecodeError):
        return ""


def _bash_owner_state(lock_dir: Path, line: str | None = None) -> str:
    """Classify an existing Bash lock as ``live``, ``stale`` or ``invalid``.

    The same rules as ``acq_provider_input_lock_acquire``: the owner line is
    ``PID IDENTITY``; it is live when the PID's current identity equals the
    recorded one, stale when the PID is gone or now has a different identity (a
    reused PID), and otherwise invalid (Bash refuses to touch it, and so does
    this: a directory with no owner line may be another command's lock in the
    instant between its ``mkdir`` and its owner write). A symlinked or
    non-directory lock path is invalid. ``line`` is the owner line already read.
    """
    if lock_dir.is_symlink() or not lock_dir.is_dir():
        return "invalid"
    if line is None:
        line = _owner_line(lock_dir)
    fields = line.strip(" ").split(" ", 1)
    pid_token = fields[0]
    identity = fields[1].strip(" ") if len(fields) > 1 else ""
    pid = _owner_pid(pid_token)
    actual = _process_identity(pid) if pid is not None else None
    if pid_token and identity and actual is not None and actual == identity:
        return "live"
    if pid_token and (not _pid_alive(pid) or (actual is not None and actual != identity)):
        return "stale"
    return "invalid"


class _BashLock:
    """Bash acq's per-sandbox ``mkdir`` lock, taken and released the Bash way.

    Bash's provision and terminate paths ``mkdir`` ``<provider-input root>.lock``
    and write ``PID IDENTITY`` into its ``owner`` file; a holder whose PID is gone
    or whose identity changed is recovered as stale. Python acq takes the same
    directory with its own PID and identity, so a Bash command waits for it and
    can recover it after a crash, and it applies the same rules to a Bash holder.

    Where Python cannot compute its own identity (no ``ps``) it does not take the
    directory, since Bash could not verify it, and only waits for a live Bash
    holder. On Windows there is no usable PID probe (Git Bash PIDs are not
    Windows PIDs, and ``os.kill`` terminates rather than probes), so Python never
    takes the directory and treats an existing one as held for
    ``_BASH_WINDOWS_FRESH_S`` seconds after it was created.
    """

    def __init__(self, backend: str, name: str):
        self.path = _bash_lock_dir(backend, name)
        self.token: str | None = None
        self.blocked = False

    def acquire(self) -> bool:
        """Take the lock, or return False while a Bash or Python holder has it."""
        self.blocked = False
        if sys.platform == "win32":  # pragma: no cover - Windows only
            self.blocked = self._recent_on_windows()
            return not self.blocked
        identity = _process_identity(os.getpid())
        for _attempt in range(3):
            if identity is None:
                self.blocked = self.path.exists() and _bash_owner_state(self.path) != "stale"
                return not self.blocked
            parent = _open_lock_parent(self.path.parent)
            try:
                if self._take(parent, f"{os.getpid()} {identity}"):
                    return True
            finally:
                os.close(parent)
            line = _owner_line(self.path)
            if _bash_owner_state(self.path, line) == "stale":
                self._remove(line)
                continue
            self.blocked = True
            return False
        self.blocked = True
        return False

    def _take(self, parent: int, token: str) -> bool:
        """``mkdir`` the lock under the open ``parent`` and write the owner line; False when it exists.

        Both steps resolve names relative to ``parent``, so a link swapped in
        for a directory on the way is never followed.
        """
        try:
            os.mkdir(self.path.name, dir_fd=parent)
        except FileExistsError:
            return False
        try:
            fd = os.open(self.path.name, os.O_RDONLY | _O_DIRECTORY | _O_NOFOLLOW, dir_fd=parent)
            try:
                owner = os.open("owner", os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW, 0o644, dir_fd=fd)
            finally:
                os.close(fd)
            with os.fdopen(owner, "w", encoding="utf-8") as fh:
                fh.write(token + "\n")
        except OSError:
            self._remove(None)
            raise
        self.token = token
        return True

    def release(self) -> None:
        """Remove the lock if this process still owns it."""
        if self.token is None:
            return
        try:
            current = (self.path / "owner").read_text(encoding="utf-8").strip()
        except OSError:
            current = ""
        if current == self.token:
            self._remove(self.token)
        self.token = None

    def remediation(self, name: str) -> str:
        """The next step for a user whose command timed out on this sandbox's lock."""
        base = f"wait for the other acq command on sandbox '{name}' to finish, then retry"
        if not self.blocked:
            return base
        if sys.platform == "win32":  # pragma: no cover - Windows only
            return (
                f"{base}; a lock left by Bash acq ({self.path}) counts as held for "
                f"{int(_BASH_WINDOWS_FRESH_S // 60)} minutes after it was taken, so if no "
                "acq command is running, wait or remove that directory"
            )
        return f"{base}; if no acq command is running, remove the leftover lock directory {self.path}"

    def _remove(self, expected: str | None) -> None:
        """Remove the lock, unless its owner line is no longer ``expected``.

        A stale lock is judged on the owner line read first. Another command
        may recover it and take it anew before this one gets here, and that
        new lock must survive, so the line is read again right before the
        removal. ``None`` is for a lock this process has just created and not
        yet given an owner. (The read and the removal are still two steps, the
        same narrow window Bash's own recovery has.)
        """
        if expected is not None and _owner_line(self.path).strip() != expected.strip():
            return
        try:
            (self.path / "owner").unlink()
        except FileNotFoundError:
            pass
        except OSError:
            return
        try:
            self.path.rmdir()
        except OSError:
            pass

    def _recent_on_windows(self) -> bool:  # pragma: no cover - Windows only
        try:
            if self.path.is_symlink() or not self.path.is_dir():
                return False
            return time.time() - self.path.stat().st_mtime < _BASH_WINDOWS_FRESH_S
        except OSError:
            return False
