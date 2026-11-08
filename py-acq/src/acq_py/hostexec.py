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
    for entry in os.environ.get("PATH", os.defpath).split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
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

    A value naming an existing file is taken whole, so a Windows path with
    backslashes or spaces survives. Otherwise it is split shell-style; on Windows
    backslashes are kept (POSIX splitting would turn ``C:\\tools\\msb.exe`` into
    the drive-relative ``C:toolsmsb.exe``, which resolves against the current
    directory). A bare program name is resolved with :func:`command`.
    """
    if os.path.isfile(value):
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
    return parts
