"""Descriptor-anchored path validation for the provider-input tree on Windows.

The POSIX implementation in ``acq.backends/common.sh`` walks a path one
component at a time with ``os.open(..., O_NOFOLLOW | O_DIRECTORY, dir_fd=...)``.
That is a *descriptor-anchored* walk: every component is opened relative to the
handle of the parent that was just vetted, so a symlink anywhere in the path is
either rejected outright (``O_NOFOLLOW``) or never reached (``dir_fd``).

Windows CPython has none of those primitives: ``os.O_DIRECTORY`` and
``os.O_NOFOLLOW`` do not exist, ``dir_fd`` is unsupported, and a directory
cannot be opened as a file descriptor with ``os.open`` at all. This module
provides the equivalent guarantee with the Win32 API (see ADR-0038):

* Every component is opened with ``FILE_FLAG_OPEN_REPARSE_POINT``, which opens
  the reparse point itself instead of following it, and
  ``FILE_FLAG_BACKUP_SEMANTICS``, which is required to get a handle to a
  directory. This is the ``O_NOFOLLOW`` equivalent.
* The opened object's attributes are read with
  ``GetFileInformationByHandleEx(FileAttributeTagInfo)``. A component carrying
  ``FILE_ATTRIBUTE_REPARSE_POINT`` (symbolic link, junction, mount point) is
  rejected, and so is anything that is not ``FILE_ATTRIBUTE_DIRECTORY``. This is
  the ``O_DIRECTORY`` check plus the no-symlink invariant.
* The handle's own resolved name (``GetFinalPathNameByHandleW``) must be a
  direct child of the parent handle's resolved name: the resolved path's parent
  directory must equal the vetted parent's resolved path, and its last component
  must be a real name. The last component is deliberately *not* compared with the
  literal spelling, because the kernel reports the long name for an 8.3 alias
  (``PROGRA~1`` -> ``Program Files``). A child whose resolved parent is anywhere
  else means an ancestor was swapped for a reparse point between the parent being
  vetted and this open, which is the descriptor-relative walk's TOCTOU protection
  expressed as an identity check.

Nothing here follows a link, and every failure path raises rather than
returning a "best effort" result. There is deliberately no fallback to
``os.makedirs``: that would silently reintroduce the traversal this code exists
to prevent.

Failures raise ``SystemExit`` with the same payload the POSIX path uses at each
call site, so callers cannot tell the two implementations apart:

* ``safe_mkdir`` -> ``SystemExit('provider-input path must be absolute')`` for a
  relative path, ``SystemExit('unsafe provider-input path')`` otherwise.
* ``safe_dir`` -> ``SystemExit(1)`` (silent) for every failure.
"""

import ctypes
import ntpath
from ctypes import wintypes

FILE_ATTRIBUTE_DIRECTORY = 0x0010
FILE_ATTRIBUTE_REPARSE_POINT = 0x0400
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
FILE_LIST_DIRECTORY = 0x0001
FILE_READ_ATTRIBUTES = 0x0080
FILE_SHARE_ALL = 0x0001 | 0x0002 | 0x0004
OPEN_EXISTING = 3
ERROR_FILE_NOT_FOUND = 2
ERROR_PATH_NOT_FOUND = 3
ERROR_ALREADY_EXISTS = 183
FILE_ATTRIBUTE_TAG_INFO_CLASS = 9
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


class FILE_ATTRIBUTE_TAG_INFO(ctypes.Structure):
    _fields_ = [
        ("FileAttributes", wintypes.DWORD),
        ("ReparseTag", wintypes.DWORD),
    ]


class UnsafePath(Exception):
    """A component is missing, is not a directory, or is a reparse point."""


_KERNEL32 = None


def _kernel32():
    """Return kernel32 with explicit signatures (resolved once, lazily)."""
    global _KERNEL32
    if _KERNEL32 is None:
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateFileW.restype = wintypes.HANDLE
        k32.CreateFileW.argtypes = [
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            ctypes.c_void_p,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        ]
        k32.GetFileInformationByHandleEx.restype = wintypes.BOOL
        k32.GetFileInformationByHandleEx.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        k32.GetFinalPathNameByHandleW.restype = wintypes.DWORD
        k32.GetFinalPathNameByHandleW.argtypes = [
            wintypes.HANDLE,
            wintypes.LPWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
        ]
        k32.CreateDirectoryW.restype = wintypes.BOOL
        k32.CreateDirectoryW.argtypes = [wintypes.LPCWSTR, ctypes.c_void_p]
        k32.CloseHandle.restype = wintypes.BOOL
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        _KERNEL32 = k32
    return _KERNEL32


def _open_directory(path):
    """Open PATH as a directory handle without following a final reparse point."""
    k32 = _kernel32()
    handle = k32.CreateFileW(
        path,
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
        FILE_SHARE_ALL,
        None,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        None,
    )
    if not handle or handle == INVALID_HANDLE_VALUE:
        raise ctypes.WinError(ctypes.get_last_error())
    return handle


def _attributes(handle):
    k32 = _kernel32()
    info = FILE_ATTRIBUTE_TAG_INFO()
    if not k32.GetFileInformationByHandleEx(
        handle,
        FILE_ATTRIBUTE_TAG_INFO_CLASS,
        ctypes.byref(info),
        ctypes.sizeof(info),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return info.FileAttributes


def _final_path(handle):
    """Echo the name of the object HANDLE actually refers to, \\?\\ prefix stripped."""
    k32 = _kernel32()
    size = 32768
    buffer = ctypes.create_unicode_buffer(size)
    written = k32.GetFinalPathNameByHandleW(handle, buffer, size, 0)
    if written == 0 or written >= size:
        raise ctypes.WinError(ctypes.get_last_error())
    path = buffer.value
    if path[:8].upper() == "\\\\?\\UNC\\":
        return "\\\\" + path[8:]
    if path.startswith("\\\\?\\"):
        return path[4:]
    return path


def _close(handle):
    if handle:
        _kernel32().CloseHandle(handle)


def _anchor(path):
    """Split an absolute Windows path into (anchor, components).

    The anchor is the OS-level root: a drive root (``C:\\``) or a UNC share. It
    is opened without the reparse-point rejection, mirroring the POSIX walk that
    opens ``/`` without ``O_NOFOLLOW`` and canonicalizes only OS-level aliases
    such as macOS ``/var`` -> ``/private/var``.
    """
    drive, rest = ntpath.splitdrive(path)
    if not drive:
        raise UnsafePath("no volume in %r" % (path,))
    if len(drive) == 2 and drive[1] == ":":
        anchor = drive + "\\"
    else:
        anchor = drive
    parts = [part for part in rest.replace("/", "\\").split("\\") if part]
    # A colon in a component would make ntpath.join treat it as a drive or an
    # alternate data stream, so the vetted object would not be the one named.
    if any(":" in part for part in parts):
        raise UnsafePath("colon in a path component of %r" % (path,))
    return anchor, parts


def _open_component(literal, create):
    """Open one component, creating it first when permitted and missing."""
    try:
        return _open_directory(literal)
    except OSError as exc:
        if exc.winerror not in (ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND):
            raise UnsafePath("cannot open %r: %s" % (literal, exc))
        if not create:
            raise UnsafePath("missing %r" % (literal,))
        # CreateDirectoryW inherits the parent's ACL, which is the Windows
        # analogue of the POSIX 0o755 mkdir honouring umask.
        if not _kernel32().CreateDirectoryW(literal, None):
            error = ctypes.get_last_error()
            if error != ERROR_ALREADY_EXISTS:
                raise UnsafePath("cannot create %r: %s" % (literal, ctypes.WinError(error)))
        return _open_directory(literal)


def _normalized(path):
    """Fold PATH to the form two names of the same Windows object compare in.

    ``ntpath`` is used explicitly: this is Windows path logic, and ``os.path`` is
    ``posixpath`` on any other host, where it would give the wrong answer.
    """
    return ntpath.normcase(ntpath.normpath(path)).rstrip("\\")


def _resolved_leaf(parent_final, actual):
    """Return ACTUAL's last component if ACTUAL is a direct child of PARENT_FINAL.

    The parent is compared by resolved name, never by the caller's spelling, so a
    short (8.3) alias that resolves to a long name under the same parent is
    accepted while anything resolving under a different parent is not. Returns
    ``None`` for a drive/share root, a ``.``/``..`` component, or a different
    parent.
    """
    if any(c in (".", "..") for c in actual.replace("/", "\\").split("\\")):
        return None
    head, leaf = ntpath.split(ntpath.normpath(actual))
    if not leaf or leaf in (".", ".."):
        return None
    if _normalized(head) != _normalized(parent_final):
        return None
    return leaf


def _vet(child, literal, parent_final):
    """Reject a link, a non-directory, or a child not directly under the parent."""
    attributes = _attributes(child)
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT:
        raise UnsafePath("reparse point at %r" % (literal,))
    if not attributes & FILE_ATTRIBUTE_DIRECTORY:
        raise UnsafePath("not a directory at %r" % (literal,))
    actual = _final_path(child)
    leaf = _resolved_leaf(parent_final, actual)
    # A colon cannot occur in a directory name; it marks an alternate-data-stream
    # handle (``dir:stream``) that must not stand in for the directory itself.
    if leaf is None or ":" in leaf:
        raise UnsafePath(
            "redirected %r -> %r (not directly under %r)" % (literal, actual, parent_final)
        )
    return actual


def _walk(path, create):
    """Validate (and optionally create) PATH without traversing any link."""
    if not ntpath.isabs(path):
        raise UnsafePath("not absolute: %r" % (path,))
    anchor, parts = _anchor(ntpath.normpath(path))
    handle = _open_directory(anchor)
    parent_literal = anchor
    parent_final = _final_path(handle)
    try:
        if not _attributes(handle) & FILE_ATTRIBUTE_DIRECTORY:
            raise UnsafePath("anchor is not a directory: %r" % (anchor,))
        for part in parts:
            literal = ntpath.join(parent_literal, part)
            child = _open_component(literal, create)
            try:
                actual = _vet(child, literal, parent_final)
            except UnsafePath:
                _close(child)
                raise
            _close(handle)
            handle = child
            parent_literal = literal
            parent_final = actual
    finally:
        _close(handle)


def safe_mkdir(path):
    """Create PATH one component at a time, never traversing a link."""
    try:
        _walk(path, create=True)
    except UnsafePath as exc:
        if not ntpath.isabs(path):
            raise SystemExit("provider-input path must be absolute")
        raise SystemExit("unsafe provider-input path") from exc


def safe_dir(path):
    """Validate that PATH is an existing, link-free directory."""
    try:
        _walk(path, create=False)
    except UnsafePath as exc:
        raise SystemExit(1) from exc
