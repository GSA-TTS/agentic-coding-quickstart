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
import shlex
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager, suppress
from pathlib import Path
from typing import IO

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

# How long a command waits for a lock in silence. After that it prints one line
# on stderr saying what it waits for, so a command blocked for minutes behind
# another acq command does not look hung. Never on stdout: ``--json`` output
# stays one envelope.
_WAIT_NOTICE_S = 2.0


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
    shared: bool = False,
    writer_preference: bool = False,
) -> Iterator[None]:
    """Hold an exclusive OS advisory lock on ``path`` for the duration of the block.

    Creates ``path`` (and its parent) if needed. Waits up to ``timeout_s`` for the
    lock (default: :func:`configured_timeout_s`, read now rather than at import);
    raises ``timeout_cls`` past the deadline, naming ``what``. The lock is
    released in a ``finally`` on normal exit *and* is auto-released by the OS if
    the process dies without cleanup (a crash). ``also_acquire`` takes a second
    lock once the OS lock is held; when it returns False (held elsewhere) the OS
    lock is released again and the wait continues. The caller releases that
    second lock itself, inside the block. Errors it raises propagate. A wait
    longer than :data:`_WAIT_NOTICE_S` prints one notice on stderr.

    ``shared`` takes a shared lock instead, which other shared holders do not
    exclude, on POSIX. ``msvcrt.locking`` has no shared mode, so on Windows it
    is exclusive: holders that could have overlapped take turns instead.

    ``writer_preference`` keeps a steady stream of shared holders from starving
    an exclusive waiter (see :class:`_WriterIntent`).
    """
    if timeout_s is None:
        timeout_s = configured_timeout_s()
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "a+b")
    intent: _WriterIntent | None = None
    start = time.monotonic()
    noticed = acquired = False
    try:
        if writer_preference:
            intent = _WriterIntent.open(path, shared=shared, what=what, timeout_cls=timeout_cls)
        while True:
            if (intent is None or intent.may_try()) and _try_os_lock(fh, shared=shared):
                if also_acquire is None or also_acquire():
                    acquired = True
                    break
                _unlock(fh)
            waited = time.monotonic() - start
            if waited >= timeout_s:
                raise timeout_cls(f"could not acquire {what} at {path} within {timeout_s:.1f}s")
            if not noticed and waited >= _WAIT_NOTICE_S:
                noticed = True
                _wait_notice(what)
            time.sleep(retry_s)
        if intent is not None:
            intent.close()  # held: shared acquirers now wait on the lock itself
        yield
    finally:
        if intent is not None:
            intent.close()
        if acquired:
            _unlock(fh)
        fh.close()


def _wait_notice(what: str) -> None:
    """Say once, on stderr, that this command waits for a lock another acq command holds.

    ``what`` names the lock; its parenthetical (who usually holds it) is
    replaced by the plainer "held by another acq command".
    """
    label = what.split(" (", 1)[0]
    try:
        print(f"acq: waiting for {label}, held by another acq command...", file=sys.stderr, flush=True)
    except (OSError, ValueError):  # a closed or broken stderr must not fail the wait
        pass


class _WriterIntent:
    """A "writer waiting" marker that new shared acquirers of a lock respect.

    Shared holders of a lock overlap, so while at least one always holds it an
    exclusive waiter never gets a turn. An exclusive waiter therefore also
    holds an exclusive OS lock on a second file next to the lock
    (``<lock>.writer``) for as long as it waits. A shared acquirer first checks
    that file and, while a writer holds it, does not try the lock at all; the
    holders already in drain and the writer gets the lock next. The writer
    gives the marker up as soon as it holds the lock (or gives up waiting).

    The marker is an OS lock, not the file's existence, so a writer that
    crashes while waiting releases it with the process: readers are held up
    only while the writer is alive and waiting, never by a leftover file. On
    Windows, where ``msvcrt.locking`` is exclusive only, a shared acquirer's
    check briefly takes the marker exclusively, so two checks at once may each
    see the other as a writer and retry once.
    """

    def __init__(self, fh: IO[bytes], *, shared: bool):
        self._shared = shared
        self._held = False
        self._fh: IO[bytes] | None = fh

    @classmethod
    def open(cls, path: Path, *, shared: bool, what: str, timeout_cls: type[LockTimeout]) -> _WriterIntent:
        """Open the marker next to ``path``; a marker that cannot be opened is the lock's own error.

        Every caller already reports ``timeout_cls`` (fail closed, naming the
        lock), so an unusable marker is reported the same way rather than as a
        raw ``OSError``.
        """
        marker = path.with_name(path.name + ".writer")
        try:
            return cls(open(marker, "a+b"), shared=shared)
        except OSError as exc:
            raise timeout_cls(f"could not acquire {what}: cannot open its writer marker {marker} "
                              f"({exc.strerror or exc})") from exc

    def may_try(self) -> bool:
        """Whether this acquirer may try the lock now; an exclusive one takes the marker first."""
        if self._fh is None:
            return True
        if self._shared:
            if not _try_os_lock(self._fh, shared=True):
                return False  # a writer is waiting
            _unlock(self._fh)
            return True
        if not self._held:
            self._held = _try_os_lock(self._fh)
        return True  # a second writer competes for the lock itself

    def close(self) -> None:
        if self._fh is None:
            return
        if self._held:
            _unlock(self._fh)
            self._held = False
        self._fh.close()
        self._fh = None


def _try_os_lock(fh, *, shared: bool = False) -> bool:
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
            fcntl.flock(fh.fileno(), (fcntl.LOCK_SH if shared else fcntl.LOCK_EX) | fcntl.LOCK_NB)
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


# Lock order. A command that holds more than one of these locks takes them in
# this order, and never takes an earlier one while it holds a later one, so two
# commands cannot each hold a lock the other waits for:
#
#   1. a sandbox's lifecycle lock (:func:`sandbox_lock`); ``secret import`` takes
#      one per backend, in the order of ``backends.BACKENDS``;
#   2. one provider-credential lock (:func:`provider_credential_lock`);
#   3. the secret-store lock (:func:`secret_store_lock`).
#
# Who takes what: create, run and recreate take 1, then 3 shared around the
# backend create (where the store is read to bind the new guest's secrets);
# start and restart take 1, then 3 shared around ``msb start`` and again around
# binding what the store gained while the sandbox was stopped. A provider key
# stored at the create's prompt takes 2 and 3, before 3 is taken shared. A
# sandbox-scoped ``secret set``/``rm`` takes 1, and for usai also 2 (usai), so it
# cannot interleave with a key rotation. A global ``secret set``/``rm`` takes 3,
# and for usai 2 (usai) first; ``usai-rotate-api-key`` and ``provider-credential
# set``/``rm`` take 2, then 3. ``secret import`` takes, for each write, what
# ``secret set`` takes for the same scope and service.


class SecretStoreLockTimeout(LockTimeout):
    """A global secret change and a sandbox create are waiting on each other's store access."""


def secret_store_lock_path() -> Path:
    return state.state_dir() / "locks" / "secret-store.lock"


@contextmanager
def secret_store_lock(*, shared: bool = False) -> Iterator[None]:
    """Serialize global secret changes against the creates that read the store to bind a guest.

    A global ``secret set``/``rm`` stores or deletes the value and then re-feeds
    (or unbinds) every running sandbox. A create reads the store and binds what
    it read into the new guest, which those re-feeds may not see yet; between
    the two, a removed secret could stay bound in the new sandbox, or a replaced
    one keep its old value. Global changes take this lock exclusively; creates
    take it ``shared``, so creates do not wait for each other (except on
    Windows, see :func:`exclusive_lock`). The wait is the lifecycle lock's
    (``$ACQ_SANDBOX_LOCK_TIMEOUT``). See the lock order above. A global change
    waiting for the lock holds back creates that arrive after it, so a steady
    stream of creates and starts cannot keep it waiting until it times out
    (writer preference, :class:`_WriterIntent`). Raises
    :class:`SecretStoreLockTimeout`.
    """
    timeout_s = timeouts.env_seconds(SANDBOX_TIMEOUT_ENV, DEFAULT_SANDBOX_TIMEOUT_S)
    with exclusive_lock(
        secret_store_lock_path(),
        timeout_s,
        what="the secret-store lock (another acq command is changing a global secret or creating a sandbox)",
        timeout_cls=SecretStoreLockTimeout,
        retry_s=_SANDBOX_RETRY_S,
        shared=shared,
        writer_preference=True,
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


def _open_lock_parent(parent: Path, root: Path, label: str = "sandbox lock") -> int:
    """Open (creating as needed) a ``mkdir`` lock's parent directory; returns its descriptor.

    ``root`` (the provenance root, or the state root) is acq's own tree and is
    created normally (it may sit under a home directory that is itself reached
    through a link). Every directory below it is created and opened relative to
    the one above with ``O_NOFOLLOW``, as Bash's
    ``_acq_provider_input_safe_mkdir`` walks its path, so a link planted there
    can never send the lock, or the owner file written into it, out of the tree.
    Raises :class:`SandboxLockUnsafe` for a link or non-directory on the way;
    ``label`` names the lock in its message.
    """
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
                    f"unsafe {label} path: {here} is a symbolic link or not a directory",
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


class _MkdirLock:
    """A ``mkdir`` lock Bash and Python acq share, taken and released the Bash way.

    The lock is a directory; whoever creates it writes ``PID IDENTITY`` into its
    ``owner`` file, and a holder whose PID is gone or whose identity changed is
    recovered as stale (:func:`_bash_owner_state`). Python takes it with its own
    PID and identity, so a Bash command waits for it and can recover it after a
    crash, and it applies the same rules to a Bash holder. A directory with no
    readable owner line is never removed: it may be another command's lock in
    the instant between its ``mkdir`` and its owner write, so a waiter times out
    and :meth:`recovery_command` says how to remove a leftover one.

    Where Python cannot compute its own identity (no ``ps``) it does not take the
    directory, since Bash could not verify it, and only waits for a live Bash
    holder. Windows has no PID probe that works across Git Bash and native
    Python; each lock decides there what an existing directory means
    (:meth:`_acquire_windows`).
    """

    label = "lock"
    # Whether an existing directory with no owner file is taken (see _take).
    claims_ownerless = False

    def __init__(self, path: Path, root: Path):
        self.path = path
        self.root = root
        self.token: str | None = None
        self.blocked = False
        self._identity: tuple[str | None] | None = None

    def _own_identity(self) -> str | None:
        """This process's identity, worked out once (it cannot change while the process lives)."""
        if self._identity is None:
            self._identity = (_process_identity(os.getpid()),)
        return self._identity[0]

    def acquire(self) -> bool:
        """Take the lock, or return False while a Bash or Python holder has it."""
        self.blocked = False
        if sys.platform == "win32":  # pragma: no cover - Windows only
            return self._acquire_windows()
        identity = self._own_identity()
        for _attempt in range(3):
            if identity is None:
                self.blocked = self.path.exists() and _bash_owner_state(self.path) != "stale"
                return not self.blocked
            parent = _open_lock_parent(self.path.parent, self.root, self.label)
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

    def _acquire_windows(self) -> bool:  # pragma: no cover - Windows only
        raise NotImplementedError

    def _take(self, parent: int, token: str) -> bool:
        """``mkdir`` the lock under the open ``parent`` and create the owner file; False when held.

        Both steps resolve names relative to ``parent``, so a link swapped in
        for a directory on the way is never followed. The exclusive create of
        the owner file is what decides who holds the lock: Bash's ``mkdir`` is
        not atomic with every coreutils (uutils ``mkdir`` reports success to
        concurrent callers; KNOWN_FAILURE_MODES section 90), so a Bash taker may
        share the directory this one just made. Losing that race never removes
        the winner's owner file. Where :attr:`claims_ownerless` is set, an
        existing directory with no owner file is taken as well. If writing the
        token fails after the owner file was created, that file is this
        process's own and is removed again.
        """
        try:
            os.mkdir(self.path.name, dir_fd=parent)
        except FileExistsError:
            if not self.claims_ownerless:
                return False
        try:
            fd = os.open(self.path.name, os.O_RDONLY | _O_DIRECTORY | _O_NOFOLLOW, dir_fd=parent)
        except FileNotFoundError:
            return False  # released or recovered in the meantime: look again
        except OSError:
            self._rmdir_quietly()
            raise
        try:
            try:
                owner = os.open("owner", os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW, 0o644, dir_fd=fd)
            except FileExistsError:
                return False  # another taker created the owner file first
            except FileNotFoundError:
                return False  # the directory was removed (a releasing or losing taker): look again
            except OSError:
                self._rmdir_quietly()
                raise
            try:
                with os.fdopen(owner, "w", encoding="utf-8") as fh:
                    fh.write(token + "\n")
            except OSError:
                with suppress(OSError):
                    os.unlink("owner", dir_fd=fd)
                self._rmdir_quietly()
                raise
        finally:
            os.close(fd)
        self.token = token
        return True

    def _rmdir_quietly(self) -> None:
        """Remove the lock directory if it is empty (a failed take of this process's own)."""
        try:
            _retry_permission(self.path.rmdir)
        except OSError:
            pass

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

    def recovery_command(self) -> str:
        """The command that removes a leftover lock directory, for a user to paste.

        Only for when no acq command is running: the directory may otherwise be
        a live command's lock. POSIX shell (and Git Bash) form, or PowerShell on
        Windows.
        """
        if sys.platform == "win32":  # pragma: no cover - Windows only
            return f"Remove-Item -LiteralPath {_ps_quote(str(self.path))} -Recurse -Force"
        return f"rm -f -- {shlex.quote(str(self.path / 'owner'))} && rmdir -- {shlex.quote(str(self.path))}"

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
            _retry_permission((self.path / "owner").unlink)
        except FileNotFoundError:
            pass
        except OSError:
            return
        try:
            _retry_permission(self.path.rmdir)
        except OSError:
            pass


# On Windows an antivirus scanner or the search indexer can hold a just-written
# file open for a moment, so deleting it (or its directory) fails with a
# PermissionError that clears on its own. A normal release retries briefly
# rather than leave the lock directory behind. Elsewhere the error is final.
_RETRY_PERMISSION = sys.platform == "win32"
_PERMISSION_RETRIES = 10
_PERMISSION_RETRY_S = 0.05


def _retry_permission(op: Callable[[], None]) -> None:
    """Run ``op``, retrying a PermissionError briefly on Windows."""
    for attempt in range(_PERMISSION_RETRIES):
        try:
            op()
            return
        except PermissionError:
            if not _RETRY_PERMISSION or attempt == _PERMISSION_RETRIES - 1:
                raise
            time.sleep(_PERMISSION_RETRY_S)


# Characters PowerShell reads as a single quote inside a single-quoted string:
# the ASCII one and U+2018-U+201B. Each is doubled to stand for itself.
_PS_QUOTES = frozenset("'\u2018\u2019\u201a\u201b")


def _ps_quote(text: str) -> str:
    """``text`` as a PowerShell single-quoted literal."""
    return "'" + "".join(c + c if c in _PS_QUOTES else c for c in text) + "'"


def _windows_pid_alive(pid: int) -> bool:  # pragma: no cover - Windows only
    """True unless Windows says process ``pid`` does not exist or has exited.

    ``OpenProcess`` fails with ERROR_INVALID_PARAMETER for a PID no process
    has; any other failure (access denied, say) counts as alive. An exit code
    other than STILL_ACTIVE means it has exited.
    """
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined,unused-ignore]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return ctypes.get_last_error() != 87  # type: ignore[attr-defined,unused-ignore]  # ERROR_INVALID_PARAMETER
    try:
        code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return True
        return code.value == 259  # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


class _BashLock(_MkdirLock):
    """Bash acq's per-sandbox ``mkdir`` lock (see :class:`_MkdirLock`).

    Bash's provision and terminate paths ``mkdir`` ``<provider-input root>.lock``
    and write ``PID IDENTITY`` into its ``owner`` file. On Windows there is no
    usable PID probe (Git Bash PIDs are not Windows PIDs, and ``os.kill``
    terminates rather than probes), so Python never takes the directory and
    treats an existing one as held for ``_BASH_WINDOWS_FRESH_S`` seconds after it
    was created.
    """

    label = "sandbox lock"

    def __init__(self, backend: str, name: str):
        super().__init__(_bash_lock_dir(backend, name), bash_provenance_dir())

    def _acquire_windows(self) -> bool:  # pragma: no cover - Windows only
        self.blocked = self._recent_on_windows()
        return not self.blocked

    def remediation(self, name: str) -> str:
        """The next step for a user whose command timed out on this sandbox's lock."""
        base = f"wait for the other acq command on sandbox '{name}' to finish, then retry"
        if not self.blocked:
            return base
        if sys.platform == "win32":  # pragma: no cover - Windows only
            return (
                f"{base}; a lock left by Bash acq ({self.path}) counts as held for "
                f"{int(_BASH_WINDOWS_FRESH_S // 60)} minutes after it was taken, so if no "
                f"acq command is running, wait or remove that directory: {self.recovery_command()} "
                "(see docs/KNOWN_FAILURE_MODES.md, section 79)"
            )
        return (f"{base}; if no acq command is running, remove the leftover lock directory: "
                f"{self.recovery_command()} (see docs/KNOWN_FAILURE_MODES.md, section 79)")

    def _recent_on_windows(self) -> bool:  # pragma: no cover - Windows only
        try:
            if self.path.is_symlink() or not self.path.is_dir():
                return False
            return time.time() - self.path.stat().st_mtime < _BASH_WINDOWS_FRESH_S
        except OSError:
            return False


# On Windows a config.yaml lock directory counts as held for this long after it
# was created, then as abandoned (Bash ``_ACQ_CONFIG_LOCK_WINDOWS_STALE_S``). A
# config write takes well under a second.
CONFIG_WINDOWS_STALE_S = 60.0


class ConfigDirLock(_MkdirLock):
    """The ``mkdir`` half of the config.yaml lock, shared with Bash acq.

    Python serializes config.yaml read-modify-writes with an OS advisory lock
    on ``locks/config.lock`` (``config.config_lock``). Bash cannot take that
    lock portably (no ``flock(1)`` on macOS; Git Bash's locks are not the ones
    ``msvcrt.locking`` takes), so both also take the directory
    ``locks/config.lock.d`` beside it (Bash ``_acq_config_lock_acquire``), and
    Python takes it only while it holds the OS lock. Whoever creates the
    ``owner`` file exclusively holds it, so a directory without one is taken
    (it is a leftover, or a taker that has not created its owner yet and will
    lose). On POSIX the owner rules of :class:`_MkdirLock` apply. On Windows neither side can check the other's
    PID, so both take the directory and count an existing one as held for
    :data:`CONFIG_WINDOWS_STALE_S` seconds after it was created, then recover
    it.
    """

    label = "config.yaml lock"
    # Every taker here decides by the owner file alone, so a directory left
    # without one (a taker that died before creating it) heals itself.
    claims_ownerless = True

    def __init__(self, os_lock_path: Path, root: Path):
        super().__init__(os_lock_path.with_name(os_lock_path.name + ".d"), root)

    def _acquire_windows(self) -> bool:
        """Take the directory, recovering an abandoned one.

        An existing directory is abandoned once it is
        :data:`CONFIG_WINDOWS_STALE_S` old, or at once when its owner is a
        Python acq (owner line ``PID windows``) whose process has exited. A Git
        Bash owner's PID cannot be checked from here, so only the age rule
        applies to it. A directory with no owner file is taken at once
        (:attr:`claims_ownerless`). Platform-neutral code (no ``dir_fd``), so it is also
        tested off Windows.
        """
        self.path.parent.mkdir(parents=True, exist_ok=True)
        token = f"{os.getpid()} windows"
        for _attempt in range(3):
            try:
                os.mkdir(self.path)
            except FileExistsError:
                if not os.path.lexists(self.path):
                    continue  # released in the meantime: look again
                if self.path.is_symlink() or not self.path.is_dir():
                    raise SandboxLockUnsafe(
                        f"unsafe {self.label} path: {self.path} is a symbolic link or not a directory",
                        f"remove {self.path}, then retry",
                    ) from None
            taken = self._create_owner(token)
            if taken:
                return True
            if taken is None:
                continue  # the directory went away: look again
            line = _owner_line(self.path)
            if self._abandoned_on_windows(line):
                self._remove(line)
                continue
            self.blocked = True
            return False
        self.blocked = True
        return False

    def _create_owner(self, token: str) -> bool | None:
        """Create the owner file exclusively; True when taken, False when held, None when the directory went."""
        try:
            fh = open(self.path / "owner", "x", encoding="utf-8")
        except FileExistsError:
            return False
        except FileNotFoundError:
            return None
        except OSError:
            self._rmdir_quietly()
            raise
        try:
            with fh:
                fh.write(token + "\n")
        except OSError:
            with suppress(OSError):
                (self.path / "owner").unlink()
            self._rmdir_quietly()
            raise
        self.token = token
        return True

    def _abandoned_on_windows(self, line: str) -> bool:
        if self._age_s() >= CONFIG_WINDOWS_STALE_S:
            return True
        fields = line.split()
        if len(fields) == 2 and fields[1] == "windows":
            pid = _owner_pid(fields[0])
            return pid is not None and not _windows_pid_alive(pid)
        return False

    def _age_s(self) -> float:
        try:
            return time.time() - self.path.stat().st_mtime
        except OSError:
            return 0.0

    def hint(self) -> str:
        """What to do when a leftover directory blocked the wait."""
        return (f"if no acq command is running, remove the leftover lock directory and retry: "
                f"{self.recovery_command()} (see docs/KNOWN_FAILURE_MODES.md, section 79)")
