"""Host-side user directory resolution (XDG Base Directory specification).

acq keeps host-authoritative state and configuration under the user's XDG base
directories. The specification requires those variables to hold absolute paths:
"If an implementation encounters a relative path in any of these variables it
should consider the path invalid and ignore it." A relative value would resolve
against the current directory, which is normally the workspace a sandboxed agent
can write to, so honoring it would let guest-writable files stand in for acq's
host records and config. An empty or relative value is therefore treated as unset
and the documented default under the home directory is used instead.

The home directory gets the same treatment: ``HOME`` is used only when it is
absolute; otherwise the account's home from the password database (POSIX) or
the platform profile directory (Windows) is used. When no absolute home can be
found, resolution fails with :class:`UserDirError` rather than guessing.
"""

from __future__ import annotations

import os
from pathlib import Path


class UserDirError(Exception):
    """A user directory cannot be resolved to a trustworthy absolute path."""

    def __init__(self, message: str, remediation: str):
        super().__init__(message)
        self.message = message
        self.remediation = remediation


def is_absolute(value: str | None) -> bool:
    """True for a non-empty absolute path string."""
    return value is not None and value != "" and os.path.isabs(value)


def _account_home() -> Path | None:
    """The account's home directory, ignoring the ``HOME`` variable."""
    try:
        import pwd
    except ImportError:  # Windows: Path.home() reads USERPROFILE, never HOME.
        try:
            candidate = str(Path.home())
        except RuntimeError:
            candidate = ""
    else:
        try:
            candidate = pwd.getpwuid(os.getuid()).pw_dir
        except KeyError:
            candidate = ""
    return Path(candidate) if is_absolute(candidate) else None


def home_dir() -> Path:
    """Resolve an absolute home directory, or raise :class:`UserDirError`."""
    env_home = os.environ.get("HOME", "")
    if is_absolute(env_home):
        return Path(env_home)
    fallback = _account_home()
    if fallback is not None:
        return fallback
    raise UserDirError(
        "cannot determine an absolute home directory "
        f"(HOME is {'unset' if 'HOME' not in os.environ else repr(env_home)})",
        "set HOME to an absolute path, or set the XDG base directory variables "
        "(XDG_STATE_HOME, XDG_CONFIG_HOME) to absolute paths",
    )


def xdg_base(var: str, *default: str) -> Path:
    """Resolve one XDG base directory.

    ``var``'s value is used only when it is an absolute path; an unset, empty, or
    relative value falls back to ``home_dir()`` joined with ``default``.
    """
    value = os.environ.get(var, "")
    if is_absolute(value):
        return Path(value)
    return home_dir().joinpath(*default)
