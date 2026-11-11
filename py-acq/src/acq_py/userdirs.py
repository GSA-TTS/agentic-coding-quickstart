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

Explicit path overrides (``ACQ_STATE_DIR`` in :mod:`state`, and the
:data:`PATH_OVERRIDES` here) are different: a relative value is refused rather
than ignored, since silently replacing it would hide the misconfiguration. Bash
acq refuses the same variables with the same message
(``acq.backends/userdirs.sh``).
"""

from __future__ import annotations

import os
import re
from pathlib import Path, PurePath


class UserDirError(Exception):
    """A user directory cannot be resolved to a trustworthy absolute path."""

    def __init__(self, message: str, remediation: str):
        super().__init__(message)
        self.message = message
        self.remediation = remediation


# The path flavor used for the absoluteness test; a seam so tests can exercise
# the Windows rules on any host.
_PATH: type[PurePath] = Path


def is_absolute(value: str | None) -> bool:
    """True for a non-empty absolute path string.

    Uses ``PurePath.is_absolute`` rather than ``os.path.isabs``: on Windows it
    requires both a drive and a root on every supported Python, whereas
    ``os.path.isabs`` before Python 3.13 also accepts rooted-but-driveless forms
    such as ``\\foo`` or ``/c/Users/x``, which resolve against the current drive.
    """
    return value is not None and value != "" and _PATH(value).is_absolute()


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


# Host path overrides py-acq honours from the environment, in the order Bash
# checks them, each with the default it falls back to (named in the
# remediation). Bash acq honours more (msb ssh/ports state and so on) and
# refuses those too.
_STORE_FALLBACK = "the default secret store"
PATH_OVERRIDES: tuple[tuple[str, str], ...] = (
    ("ACQ_SECRET_STORE_DIR", _STORE_FALLBACK),
    ("ACQ_SECRET_FILE_DIR", _STORE_FALLBACK),
    ("ACQ_PROVENANCE_DIR", "the default"),
    ("ACQ_SECRET_META_DIR", "the default"),
    ("ACQ_SECRET_INDEX_FILE", "the default"),
    ("ACQ_SBX_KIT_CACHE", "the default"),
    ("ACQ_MSB_KIT_CACHE", "the default"),
    ("ACQ_MSB_STARTUP_STAGE_DIR", "the default"),
    ("ACQ_MSB_UPSTREAM_CA_FILE", "the default"),
    ("ACQ_MSB_BALANCED_HOSTS_FILE", "the default"),
    ("ACQ_MSB_SSH_DIR", "the default"),
    ("ACQ_MSB_SSH_KEY", "the default"),
    ("ACQ_MSB_SSH_KNOWN_HOSTS", "the default"),
    ("ACQ_MSB_PORTS_DIR", "the default"),
    ("ACQ_MSB_CLONES_DIR", "the default"),
)

# Read only when ACQ_SECRET_STORE_DIR is unset: the store dir relocates them.
_STORE_RELOCATED = ("ACQ_SECRET_META_DIR", "ACQ_SECRET_INDEX_FILE")


def path_override(var: str, default: str = "the default") -> Path | None:
    """The path an override variable names, or ``None`` when it is unset or empty.

    A relative value is refused with :class:`UserDirError`: it would resolve
    against the current directory, normally the agent-writable workspace.
    ``default`` names what unsetting the variable falls back to.
    """
    value = os.environ.get(var, "")
    if not value:
        return None
    if not is_absolute(value):
        raise UserDirError(
            f"{var} must be an absolute path, got {value!r}",
            f"set {var} to an absolute path, or unset it to use {default}",
        )
    return Path(value)


def check_path_overrides() -> None:
    """Raise :class:`UserDirError` for the first relative :data:`PATH_OVERRIDES` value."""
    store_set = bool(os.environ.get("ACQ_SECRET_STORE_DIR"))
    for var, default in PATH_OVERRIDES:
        if store_set and var in _STORE_RELOCATED:
            continue
        path_override(var, default)
    check_ca_paths()


def check_ca_paths() -> None:
    """Refuse relative CA entries before list splitting can reinterpret drive paths."""
    var = "ACQ_MSB_UPSTREAM_CA_CERT"
    rest = os.environ.get(var, "")
    while rest:
        parts = re.split(r"[:\s]", rest, maxsplit=1)
        value, rest = parts[0], parts[1] if len(parts) > 1 else ""
        if re.fullmatch(r"[A-Za-z]", value) and rest.startswith(("/", "\\")):
            value += ":" + re.split(r"[:\s]", rest, maxsplit=1)[0]
            posix = "/" + value[0].lower() + value[2:].replace("\\", "/")
            raise UserDirError(
                f"{var} entries must be absolute POSIX paths (the list is split on ':'), got {value!r}",
                f"use the POSIX form of a Windows path in {var}, e.g. {posix!r}",
            )
        if value and not value.startswith("/"):
            raise UserDirError(
                f"{var} entries must be absolute paths, got {value!r}",
                f"list absolute PEM paths in {var}, or unset it",
            )
