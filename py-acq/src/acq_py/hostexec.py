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
"""

from __future__ import annotations

import errno
import ntpath
import os
import shlex
import sys


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


def _path_entries() -> list[str]:
    entries = []
    for entry in os.environ.get("PATH", os.defpath).split(os.pathsep):
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


def which(name: str) -> str | None:
    """Return the absolute path of ``name`` from absolute PATH entries, or None.

    The current directory is never searched, whatever ``PATH`` contains:
    empty, ``.`` and other relative entries are skipped.
    """
    if not name or _has_dir(name):
        return None
    for entry in _path_entries():
        for file_name in _file_names(name):
            candidate = os.path.join(entry, file_name)
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
    return None


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
    """
    if _is_absolute(value) and os.path.isfile(value):
        return [value]
    if _is_windows():
        parts = [
            p[1:-1] if len(p) >= 2 and p[0] == p[-1] == '"' else p
            for p in shlex.split(value, posix=False)
        ]
    else:
        parts = shlex.split(value)
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
