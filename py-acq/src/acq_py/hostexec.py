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
backend session (``exec``, ``attach``, ``shell`` and passthrough).
"""

from __future__ import annotations

import errno
import ntpath
import os
import shlex
import signal
import subprocess
import sys
import threading
from collections.abc import Callable, Iterator
from types import FrameType
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
