"""Resolve host programs without searching the current directory.

acq usually runs from inside the workspace it is about to sandbox, and that
workspace is untrusted: an agent in the guest can write to it. On Windows,
``CreateProcess``, ``cmd.exe`` and ``shutil.which`` all look in the current
directory before ``PATH``, so launching a bare name such as ``git`` or ``msb``
would run a ``git.exe`` or ``msb.exe`` planted in the workspace on the host.
POSIX ``exec`` does the same for an empty or relative ``PATH`` entry.

Every host program acq launches is therefore resolved here to an absolute path,
from absolute ``PATH`` entries only, and launched by that path. On Windows only
``.exe`` files are accepted: a bare name passed to ``CreateProcess`` only ever
matched ``.exe``, and batch files are run through ``cmd.exe`` with its own
argument-quoting rules.

It also owns :func:`run_foreground`, the one way acq hands the terminal to a
backend session (``exec``, ``attach``, ``shell`` and passthrough), and
:func:`run_captured`, which bounds a captured backend call so that on Windows a
timeout ends every process the call started (:class:`StepJob`).
"""

from __future__ import annotations

import errno
import functools
import ntpath
import os
import shlex
import signal
import subprocess
import sys
import threading
from collections.abc import Callable, Iterator
from types import FrameType, SimpleNamespace
from typing import Any

# What signal.getsignal returns and signal.signal accepts (Handlers is an int).
_Handler = Callable[[int, FrameType | None], Any] | int


def _is_windows() -> bool:
    return sys.platform == "win32"


def _has_dir(name: str) -> bool:
    # Windows accepts both separators and drive prefixes (``C:msb.exe``).
    return bool(os.path.dirname(name) or (_is_windows() and ntpath.dirname(name)))


def _is_absolute(path: str) -> bool:
    """True only for a path that does not depend on the current directory.

    On Windows a path needs a drive (or UNC share) and a root: ``C:foo`` is
    relative to the drive's current directory, and ``\\foo`` to the current
    drive, which may itself be the workspace (``subst``). ``os.path.isabs``
    accepts the latter on Python 3.12, so it is not used there.
    """
    if not _is_windows():
        return os.path.isabs(path)
    drive, rest = ntpath.splitdrive(path)
    if drive.startswith(("\\\\", "//")):
        return True
    return bool(drive) and rest.startswith(("\\", "/"))


def _path_entries(path: str | None = None) -> list[str]:
    entries = []
    value = os.environ.get("PATH", os.defpath) if path is None else path
    for entry in value.split(os.pathsep):
        # cmd.exe tolerates a quoted entry such as "C:\Program Files\Git\cmd".
        if _is_windows() and len(entry) >= 2 and entry[0] == entry[-1] == '"':
            entry = entry[1:-1]
        if entry and _is_absolute(entry):
            entries.append(entry)
    return entries


def _file_names(name: str) -> list[str]:
    if _is_windows() and not name.lower().endswith(".exe"):
        return [name + ".exe"]
    return [name]


def which_all(name: str, path: str | None = None) -> Iterator[str]:
    """Yield every absolute path of ``name`` in the absolute entries of ``path``.

    ``path`` defaults to ``PATH``. The current directory is never searched,
    whatever it contains: empty, ``.`` and other relative entries are skipped.
    Callers that must pass over some matches (the qualification oracle skips the
    WSL ``bash.exe`` launcher) take the first one they accept.
    """
    if not name or _has_dir(name):
        return
    for entry in _path_entries(path):
        for file_name in _file_names(name):
            candidate = os.path.join(entry, file_name)
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                yield candidate


def which(name: str, path: str | None = None) -> str | None:
    """Return the absolute path of ``name`` from absolute PATH entries, or None.

    ``path`` defaults to ``PATH``; see :func:`which_all`.
    """
    return next(which_all(name, path), None)


def command(name: str) -> list[str]:
    """Return ``[absolute path]`` for ``name``; raise FileNotFoundError if absent.

    Raising (rather than falling back to the bare name) matters on Windows,
    where the bare name would be found in the current directory.
    """
    path = which(name)
    if path is None:
        raise FileNotFoundError(errno.ENOENT, f"{name} not found on PATH", name)
    return [path]


def override_command(value: str) -> list[str]:
    """Parse an ``ACQ_*_BIN`` override into argv.

    An absolute path naming an existing file is taken whole, so a Windows path
    with backslashes or spaces survives. Otherwise the value is split
    shell-style; on Windows backslashes are kept (POSIX splitting would turn
    ``C:\\tools\\msb.exe`` into the drive-relative ``C:toolsmsb.exe``). The
    program must then be an absolute path or a bare name, which is resolved with
    :func:`command`; a relative path would resolve against the current
    directory, i.e. the workspace, and is refused.

    A value that does not split (an unbalanced quote) raises
    ``FileNotFoundError`` like every other unusable override, so each caller's
    ``OSError`` handling reports it as a backend CLI that cannot be run instead
    of letting ``shlex``'s ``ValueError`` escape as a traceback.
    """
    if _is_absolute(value) and os.path.isfile(value):
        return [value]
    try:
        if _is_windows():
            parts = [
                p[1:-1] if len(p) >= 2 and p[0] == p[-1] == '"' else p
                for p in shlex.split(value, posix=False)
            ]
        else:
            parts = shlex.split(value)
    except ValueError as exc:
        raise FileNotFoundError(errno.ENOENT, "program override is not a valid command line", value) from exc
    if not parts:
        raise FileNotFoundError(errno.ENOENT, "empty program override", value)
    if not _has_dir(parts[0]):
        parts[0] = command(parts[0])[0]
    elif not _is_absolute(parts[0]):
        raise FileNotFoundError(
            errno.ENOENT,
            "program override must be an absolute path or a bare name",
            parts[0],
        )
    return parts


def stdin_is_tty() -> bool:
    """True when acq's stdin is a terminal, so a session can be given a PTY."""
    try:
        if not os.isatty(0):
            return False
    except OSError:
        return False
    return not _is_windows() or _windows_console(0)


def stream_is_terminal(stream) -> bool:
    """True when ``stream`` (``sys.stdin``, say) is an interactive terminal.

    ``isatty()`` alone is not enough on Windows: the NUL device is a character
    device, so ``acq ... < NUL`` reports a TTY and anything that then waits for
    keys hangs. There a file stream counts only when its handle is a real
    console. A stream with no OS file behind it (a test double) is taken at its
    ``isatty()`` word.
    """
    isatty = getattr(stream, "isatty", None)
    try:
        if isatty is None or not isatty():
            return False
    except (OSError, ValueError):  # a closed stream
        return False
    if not _is_windows():
        return True
    try:
        fd = stream.fileno()
    except (AttributeError, OSError, ValueError):
        return True
    return _windows_console(fd)


def _windows_console(fd: int) -> bool:  # pragma: no cover - Windows only
    """True when ``fd``'s handle is a console (``GetConsoleMode`` succeeds).

    Any failure, including a handle that is not a console, reads as False.
    ``ctypes.windll`` loads kernel32 once and keeps it, so a call costs no DLL
    load. The handle goes in as ``c_void_p``: a 64-bit handle value does not
    fit the C ``int`` ctypes would otherwise convert a Python int to.
    """
    if sys.platform != "win32":
        return False
    import ctypes
    import msvcrt

    try:
        handle = msvcrt.get_osfhandle(fd)
    except OSError:
        return False
    mode = ctypes.c_ulong()
    try:
        return bool(ctypes.windll.kernel32.GetConsoleMode(ctypes.c_void_p(handle), ctypes.byref(mode)))
    except OSError:  # kernel32 could not be loaded
        return False


def terminal_env() -> list[str]:
    """The host terminal's identity (TERM, COLORTERM) as ``NAME=value`` entries.

    For a session that has a PTY: msb does not pass the caller's terminal type
    into the guest, so a TUI agent would see ``TERM=linux`` and drop to sixteen
    colours. Only variables the host has set are returned; nothing is invented.
    """
    entries = []
    for var in ("TERM", "COLORTERM"):
        value = os.environ.get(var)
        if value and not any(ch in value for ch in "\n\r\t"):
            entries.append(f"{var}={value}")
    return entries


def utf8_input_ok(text: str | None) -> bool:
    """True when ``text`` (input for a backend CLI) encodes as UTF-8, or is None.

    The backends' streams are opened as UTF-8 with ``errors="replace"``, so
    output that is not UTF-8 cannot fail a call. The same setting would quietly
    turn an unencodable input character (a lone surrogate, which is how Python
    carries undecodable bytes from the environment) into ``?``, sending the
    backend a different value. The caller refuses such input instead.
    """
    if text is None:
        return True
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def exit_status(returncode: int) -> int:
    """Map a child's return code to a shell-style exit status.

    ``subprocess`` reports a child killed by signal N as ``-N``; a shell reports
    ``128 + N`` (143 for SIGTERM, 130 for SIGINT). Passing ``-N`` on to
    ``SystemExit`` would truncate it to ``256 - N`` instead.
    """
    return 128 - returncode if returncode < 0 else returncode


# Set by _ignore_interrupt when acq itself received SIGINT during the current
# foreground run (from the terminal's Ctrl-C, or a kill aimed at acq).
_interrupted = False


def _ignore_interrupt(_signum: int, _frame: FrameType | None) -> None:
    """SIGINT handler used while a foreground child runs: note it, do nothing."""
    global _interrupted
    _interrupted = True


def run_foreground(argv: list[str], *, stdout: int | None = None) -> int:
    """Run ``argv`` in the foreground and return its shell-style exit status.

    The child inherits acq's terminal and process group, so the terminal's
    Ctrl-C reaches it directly and it decides what an interrupt means (an agent
    TUI cancels its current step; a shell redraws its prompt). acq only waits.
    ``subprocess.run`` would instead turn the interrupt into
    ``KeyboardInterrupt``, SIGKILL the child and print a traceback.

    While the child runs, SIGINT in acq goes to a handler that does nothing. It
    is a real handler rather than ``SIG_IGN`` on purpose: an ignored signal stays
    ignored across ``exec`` and would make the child deaf to Ctrl-C, while a
    caught one is reset to the default in the child. ``OSError`` from starting
    the program propagates to the caller.

    When the child dies of SIGINT *and* acq received SIGINT as well (a Ctrl-C
    for the whole foreground job), acq dies of SIGINT too, as a shell does (see
    :func:`_die_of_interrupt`). In that case it prints nothing more: under
    ``--json`` there is no envelope. A SIGINT aimed only at the child gives an
    ordinary status 130, and the caller reports it as usual.
    """
    global _interrupted
    _interrupted = False
    previous = _hold_interrupt()
    try:
        child = subprocess.Popen(argv, stdout=stdout)
        returncode = child.wait()
    finally:
        if previous is not None:
            signal.signal(signal.SIGINT, previous)
    if returncode == -signal.SIGINT and _interrupted and previous is not None and not _is_windows():
        _die_of_interrupt()
    return exit_status(returncode)


def _die_of_interrupt() -> None:
    """End acq by SIGINT, as a shell does when its foreground job was interrupted.

    A calling shell loop (``for f in ...; do acq exec ...; done``) stops on
    Ctrl-C only if its child died *of* SIGINT; an ordinary exit with status 130
    tells it the child handled the interrupt, and the loop carries on. If the
    signal does not end the process, the caller falls back to status 130.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except (OSError, ValueError):
            pass
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.kill(os.getpid(), signal.SIGINT)


def _hold_interrupt() -> _Handler | None:
    """Install :func:`_ignore_interrupt` for SIGINT; return the handler it replaced.

    Returns ``None`` (and changes nothing) off the main thread, where Python
    does not allow signal handlers to be set, and when SIGINT is already ignored
    (acq started in the background, or under ``nohup``): the child then inherits
    the same disposition, as it would from a shell.
    """
    if threading.current_thread() is not threading.main_thread():
        return None
    previous = signal.getsignal(signal.SIGINT)
    if previous == signal.SIG_IGN:
        return None
    signal.signal(signal.SIGINT, _ignore_interrupt)
    # getsignal returns None for a handler not installed from Python; put the
    # default back in that case rather than leaving ours behind.
    return signal.SIG_DFL if previous is None else previous


# ---------------------------------------------------------------------------
# Windows Job objects. Shared with the qualification oracle
# (scripts/qualify-backend-cell), which loads this module by file path.
# ---------------------------------------------------------------------------

# The process-creation flag and the Job object values StepJob uses (winbase.h, winnt.h).
CREATE_SUSPENDED = 0x00000004
_JOB_EXTENDED_LIMITS = 9  # JobObjectExtendedLimitInformation
_KILL_ON_JOB_CLOSE = 0x00002000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
_BREAKAWAY_OK = 0x00000800  # JOB_OBJECT_LIMIT_BREAKAWAY_OK
# PROCESS_TERMINATE and PROCESS_SET_QUOTA (both needed to assign a process to a
# job), and PROCESS_SUSPEND_RESUME.
_PROCESS_JOB_ACCESS = 0x0001 | 0x0100 | 0x0800


@functools.cache
def job_structures() -> tuple[Any, Any]:
    """``(JOBOBJECT_BASIC_LIMIT_INFORMATION, JOBOBJECT_EXTENDED_LIMIT_INFORMATION)`` as ctypes structures.

    Built on first use, so ``ctypes`` (and its ``_ctypes`` extension, which a
    stripped-down Python may lack) is imported only where a Job object is
    used, never at acq's startup. ``IoInfo`` is IO_COUNTERS (six 64-bit counters).
    """
    import ctypes

    class BasicLimits(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_int64),
            ("PerJobUserTimeLimit", ctypes.c_int64),
            ("LimitFlags", ctypes.c_uint32),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", ctypes.c_uint32),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", ctypes.c_uint32),
            ("SchedulingClass", ctypes.c_uint32),
        ]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", BasicLimits),
            ("IoInfo", ctypes.c_uint64 * 6),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    return BasicLimits, ExtendedLimits


@functools.cache
def _win32():
    """kernel32 and ntdll functions with the prototypes StepJob needs (Windows only).

    Private library instances, so these prototypes never change the shared
    ``ctypes.windll`` ones another module may rely on.
    """
    if sys.platform != "win32":
        raise OSError("Job objects exist only on Windows")
    import ctypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    ntdll = ctypes.WinDLL("ntdll")
    handle, flag, dword = ctypes.c_void_p, ctypes.c_int, ctypes.c_uint32
    prototypes = {
        "CreateJobObjectW": (kernel32, [handle, ctypes.c_wchar_p], handle),
        "SetInformationJobObject": (kernel32, [handle, ctypes.c_int, handle, dword], flag),
        "AssignProcessToJobObject": (kernel32, [handle, handle], flag),
        "TerminateJobObject": (kernel32, [handle, ctypes.c_uint], flag),
        "OpenProcess": (kernel32, [dword, flag, dword], handle),
        "CloseHandle": (kernel32, [handle], flag),
        "NtResumeProcess": (ntdll, [handle], ctypes.c_long),
    }
    api = {}
    for name, (library, argtypes, restype) in prototypes.items():
        function = getattr(library, name)
        function.argtypes, function.restype = argtypes, restype
        api[name] = function
    return SimpleNamespace(**api)


def _win_error() -> OSError:
    import ctypes

    return ctypes.WinError(ctypes.get_last_error())  # type: ignore[attr-defined,unused-ignore]


class StepJob:
    """A Windows Job object holding one process and every process it starts.

    Job membership is fixed when a process is created and inherited by its
    descendants, so terminating the job kills those processes and nothing
    else (except one that broke away, see below; the job is a cleanup tool, not a
    security boundary). No process is looked up by pid, so a recycled pid
    cannot lead the kill to an unrelated process, as it can with
    ``taskkill /T``, which walks parent pids.

    The job kills its processes when its last handle is closed, so they do not
    outlive a caller that dies. When the process ends on its own,
    :meth:`release` lifts that limit before closing the handle: a process it
    left running on purpose (a backend daemon it started) keeps running, as it
    would without a job.

    A process started with ``CREATE_BREAKAWAY_FROM_JOB`` is let out of the job
    (``JOB_OBJECT_LIMIT_BREAKAWAY_OK``) rather than refused, so a backend that
    detaches its daemon that way still works; like a POSIX process that leaves
    its group with ``setsid``, it is then outside the kill.
    """

    def __init__(self, handle: int) -> None:
        self._handle: int | None = handle

    @classmethod
    def adopt(cls, pid: int) -> StepJob:
        """Put the suspended process ``pid`` in a new job, then resume it.

        The process must have been created with ``CREATE_SUSPENDED``, so nothing it
        starts can escape the job before it is assigned. ``subprocess`` keeps no
        handle to the primary thread, so it is resumed with ``NtResumeProcess``
        (ntdll) on a process handle. Raises ``OSError`` on failure; the caller then
        kills the process.
        """
        api = _win32()
        handle = api.CreateJobObjectW(None, None)
        if not handle:
            raise _win_error()
        job = cls(handle)
        try:
            job._limit(_KILL_ON_JOB_CLOSE | _BREAKAWAY_OK)
            process = api.OpenProcess(_PROCESS_JOB_ACCESS, False, pid)
            if not process:
                raise _win_error()
            try:
                if not api.AssignProcessToJobObject(handle, process):
                    raise _win_error()
                status = api.NtResumeProcess(process)
                if status != 0:
                    raise OSError(f"NtResumeProcess failed (NTSTATUS {status & 0xFFFFFFFF:#010x})")
            finally:
                api.CloseHandle(process)
        except BaseException:
            job._close()
            raise
        return job

    def _limit(self, flags: int) -> None:
        import ctypes

        info = job_structures()[1]()
        info.BasicLimitInformation.LimitFlags = flags
        if not _win32().SetInformationJobObject(self._handle, _JOB_EXTENDED_LIMITS,
                                                ctypes.byref(info), ctypes.sizeof(info)):
            raise _win_error()

    def terminate(self) -> None:
        """Kill every process in the job, then close it."""
        if self._handle is not None:
            _win32().TerminateJobObject(self._handle, 1)
            self._close()

    def release(self) -> None:
        """Close the job, leaving any process still in it running."""
        if self._handle is not None:
            try:
                self._limit(_BREAKAWAY_OK)
            except OSError:
                pass  # the close below then kills what is left, as a forced stop would
            self._close()

    def _close(self) -> None:
        handle, self._handle = self._handle, None
        if handle is not None:
            _win32().CloseHandle(handle)


# After a timed-out call's job is terminated, how long to wait for its pipes to
# close. A process that broke away from the job can hold them open indefinitely.
_REAP_TIMEOUT_S = 5.0

# Whether bounded calls run in a Job object: the real platform, not the
# ``_is_windows`` seam other tests turn on to exercise Windows path rules on a
# POSIX host, where ``Popen`` refuses ``creationflags``. A seam of its own.
JOB_OBJECTS = sys.platform == "win32"


def run_captured(argv: list[str], *, timeout: float | None = None, input_text: str | None = None,
                 env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """Run a backend CLI with its output captured as UTF-8, optionally bounded by ``timeout``.

    Without ``input_text`` the child's stdin is the null device. A call that
    outlasts ``timeout`` raises ``subprocess.TimeoutExpired``. ``OSError`` from
    starting the program propagates.

    ``subprocess.run`` kills only the direct child on a timeout. On Windows the
    wait for the child's output then lasts as long as any process it started
    (an msb that auto-started its server, say) holds the pipes, which can be
    forever. So there a bounded call runs in a :class:`StepJob`, and a timeout
    terminates the job: the child and everything it started. A call that ends
    in time releases the job, leaving what it started on purpose running. Off
    Windows, or without a timeout, this is plain ``subprocess.run``.
    """
    kwargs: dict[str, Any] = {"capture_output": True, "encoding": "utf-8", "errors": "replace"}
    if input_text is None:
        kwargs["stdin"] = subprocess.DEVNULL
    else:
        kwargs["input"] = input_text
    if env is not None:
        kwargs["env"] = env
    if timeout is None or not JOB_OBJECTS:
        return subprocess.run(argv, timeout=timeout, **kwargs)
    return _run_in_job(argv, timeout, input_text, kwargs)


def _run_in_job(argv: list[str], timeout: float, input_text: str | None,
                run_kwargs: dict[str, Any]) -> subprocess.CompletedProcess:
    """The Windows half of :func:`run_captured`: the call runs, and on a timeout dies, in its own job.

    The process is created suspended and resumed only once it is in the job. A
    host that cannot give it a job (``adopt`` fails) gets the process killed
    before it ran a single instruction, and the call made plainly instead.
    """
    proc = subprocess.Popen(
        argv, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8", errors="replace",
        env=run_kwargs.get("env"), creationflags=CREATE_SUSPENDED,
    )
    try:
        job = StepJob.adopt(proc.pid)
    except BaseException as exc:
        proc.kill()
        _reap(proc)
        if not isinstance(exc, OSError):
            raise
        return subprocess.run(argv, timeout=timeout, **run_kwargs)
    try:
        out, err = proc.communicate(input_text, timeout=timeout)
    except BaseException:
        # A timeout, or acq itself interrupted: nothing the call started may keep running.
        job.terminate()
        _reap(proc)
        raise
    finally:
        job.release()  # a no-op once terminated
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


def _reap(proc: subprocess.Popen) -> None:
    """Wait a bounded time for a killed ``proc``, then close its pipes."""
    try:
        proc.communicate(timeout=_REAP_TIMEOUT_S)
    except (subprocess.TimeoutExpired, OSError, ValueError):
        pass
    for pipe in (proc.stdin, proc.stdout, proc.stderr):
        if pipe is not None:
            try:
                pipe.close()
            except OSError:
                pass
