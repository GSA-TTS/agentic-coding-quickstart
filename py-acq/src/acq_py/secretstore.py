"""The acq-owned, backend-neutral secret store, shared with the Bash ``acq``.

This is a byte-compatible port of ``acq.backends/secret-store.sh``. Both
implementations read and write the same entries, so a value stored by one is
read back unchanged by the other and no credential migration is needed while
they coexist (plan default: shared layout).

Layout (identical to Bash):

* Keys are ``acq.<service>`` (global) or ``acq.<sandbox>.<service>`` (sandbox
  scope); a sandbox-scoped value takes precedence over the global one.
  Service and sandbox names are restricted to ``[A-Za-z0-9_-]+`` so ``.`` stays
  an unambiguous separator and no name can break a keychain command stream.
* Backends: macOS keychain through ``security -i`` (the value is in the stdin
  command stream, never argv); Linux ``secret-tool`` (value on stdin); Windows
  DPAPI through in-box PowerShell, written as the versioned ``acq-dpapi-v1``
  envelope; and a 0600 file fallback under ``$XDG_DATA_HOME/acq/secrets``.
* The file fallback is never used on Windows: NTFS cannot enforce 0600, so when
  DPAPI is unavailable this module refuses instead of writing plaintext (plan
  default 2). A legacy plaintext file left by the Bash file backend is still
  read on Windows and re-encrypted in place, as Bash does.
* A non-secret endpoint sidecar (``HOST<TAB>ENV``) per key under
  ``secret-meta/``, and a non-secret key index (``secret-index``) that lets
  keychain-backed stores be enumerated.

Trust hygiene: a value is never placed on argv, never printed, never logged,
and never included in an exception message. Subprocess failures are reported
with fixed text naming the key only.

Environment (same names and precedence as Bash): ``ACQ_SECRET_STORE_DIR``
forces the file backend rooted there (the offline-test escape hatch; on Windows
it only relocates the DPAPI files); ``ACQ_SECRET_FILE_DIR``,
``ACQ_SECRET_META_DIR``, ``ACQ_SECRET_INDEX_FILE`` and ``ACQ_SECRET_FORCE_FILE``
override the layout; ``ACQ_SECRET_SECURITY_BIN`` and
``ACQ_SECRET_POWERSHELL_BIN`` replace the keychain tools only when
``ACQ_SECRET_STORE_DIR`` is also set, so production never honors them; Windows
PowerShell is otherwise run by its full path under ``%SystemRoot%``, never found
on PATH, and the override must be absolute too. Unlike
Bash, a relative path in any of these is refused rather than resolved against
the current directory, which is normally the untrusted workspace.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import NamedTuple

from . import errors, hostexec, userdirs

# The constant keychain "service" label; the full acq key is the account.
KEYCHAIN_LABEL = "acq-secret-store"

# First line of every value the Windows DPAPI backend writes. It shares the
# plaintext file backend's paths, so this header is what tells ciphertext apart
# from a legacy plaintext value. Bump the suffix if the envelope ever changes.
DPAPI_HEADER = "acq-dpapi-v1"

# Service and sandbox names: the store-key alphabet Bash's ``_acq_secret_key``
# enforces. Applied with fullmatch (``$`` would accept a trailing newline).
NAME_RE = re.compile(r"[A-Za-z0-9_-]+")
_META_ENV_RE = re.compile(r"[A-Za-z0-9_]+")
# One endpoint host: two or more DNS labels, optionally led by one ``*.``
# wildcard label. The two-label floor refuses a bare TLD (``com``) and, after a
# wildcard, a TLD-wide one (``*.com``); a label needs a letter or digit, so ``_``,
# ``*``, ``**``, ``.`` and ``a..b`` are refused too. Same shape as msb's egress
# target grammar. The suffix check is label-count only: it does not consult the
# public-suffix list, so ``*.co.uk`` still passes.
_HOST_LABEL = r"(?=[A-Za-z0-9_-]*[A-Za-z0-9])[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?"
_HOST_RE = re.compile(rf"(?:\*\.)?{_HOST_LABEL}(?:\.{_HOST_LABEL})+")
_FILE_UNSAFE_RE = re.compile(r"[^A-Za-z0-9._-]")

# Seams: the platform checks, so the macOS and Windows paths run on any host.
IS_WINDOWS = sys.platform in ("win32", "cygwin", "msys")
IS_MACOS = sys.platform == "darwin"

# Upper bound on one keychain-tool call. Generous, because a locked keyring can
# legitimately wait for the user to unlock it.
TOOL_TIMEOUT = 300.0

_SECURITY_DEFAULT = "/usr/bin/security"
# Windows PowerShell is launched by its full path under %SystemRoot%, never by a
# PATH search: acq usually runs inside the workspace it sandboxes, and a planted
# powershell.exe there must not be the one that decrypts the user's secrets
# (acq.cmd follows the same rule).
_POWERSHELL_RELATIVE = ("System32", "WindowsPowerShell", "v1.0", "powershell.exe")

# The PowerShell one-liners, byte-identical to Bash's so both sides call DPAPI
# the same way: plaintext and ciphertext move over stdin/stdout, never argv.
_PS_ENCRYPT = (
    '$ErrorActionPreference="Stop"; Add-Type -AssemblyName System.Security; '
    "$i=[Console]::In.ReadToEnd(); $b=[Text.Encoding]::UTF8.GetBytes($i); "
    "[Console]::Out.Write([Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect("
    "$b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)))"
)
_PS_DECRYPT = (
    '$ErrorActionPreference="Stop"; Add-Type -AssemblyName System.Security; '
    "$i=[Console]::In.ReadToEnd(); $e=[Convert]::FromBase64String($i.Trim()); "
    "[Console]::Out.Write([Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect("
    "$e,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)))"
)


class SecretStoreError(Exception):
    """A store operation failed. Carries the adapters' (code, message,
    remediation) contract. The message names keys and paths, never a value."""

    def __init__(self, code: str, message: str, remediation: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation


@dataclass(frozen=True)
class Scope:
    """A secret scope: global (``sandbox is None``) or one sandbox.

    The kind is structural, so a sandbox literally named ``global`` is a
    sandbox scope and can never be mistaken for the global one.
    """

    sandbox: str | None = None

    @property
    def is_global(self) -> bool:
        return self.sandbox is None

    @property
    def label(self) -> str:
        """The scope as reported in output: ``global`` or the sandbox name."""
        return "global" if self.sandbox is None else self.sandbox

    def describe(self) -> str:
        """Human description that stays unambiguous (``sandbox 'global'``)."""
        return "global" if self.sandbox is None else f"sandbox '{self.sandbox}'"


GLOBAL = Scope()


def sandbox_scope(name: str) -> Scope:
    return Scope(sandbox=name)


def as_scope(value: Scope | str) -> Scope:
    """Accept a :class:`Scope`, or a legacy scope string from an older caller.

    A string can only mean "global" through the old sentinel, which is exactly
    the ambiguity :class:`Scope` removes, so new code passes a Scope.
    """
    if isinstance(value, Scope):
        return value
    return GLOBAL if value == "global" else Scope(sandbox=value)


class Binding(NamedTuple):
    """A non-secret endpoint mapping from the meta sidecar."""

    host: str
    env: str


# ---------------------------------------------------------------------------
# Names, keys and values.
# ---------------------------------------------------------------------------

def name_ok(name: str | None) -> bool:
    """True for a name Bash's store would accept as a key segment."""
    return name is not None and NAME_RE.fullmatch(name) is not None


def key_for(service: str, sandbox: str | None = None) -> str:
    """The store key, failing closed on a name that would alias another scope."""
    if not name_ok(service) or (sandbox is not None and not name_ok(sandbox)):
        raise SecretStoreError(
            errors.VALIDATION_FAILED,
            "service and sandbox names must match [A-Za-z0-9_-]+",
            "use a name made of letters, digits, '_' and '-'",
        )
    return f"acq.{sandbox}.{service}" if sandbox else f"acq.{service}"


def _try_key(service: str, sandbox: str | None = None) -> str | None:
    try:
        return key_for(service, sandbox)
    except SecretStoreError:
        return None


def value_problem(value: str) -> str | None:
    """Why ``value`` cannot be stored intact, or None. Never quotes the value.

    The store holds one line, so newline and tab are refused (plan default 3),
    and the reserved envelope header would read back as ciphertext.
    """
    if not value:
        return "the secret value is empty"
    if any("\ud800" <= ch <= "\udfff" for ch in value):
        # Undecodable input carried through surrogateescape: not a real value.
        return "the secret value is not valid UTF-8"
    if "\n" in value or "\t" in value:
        return "the secret value contains a newline or tab, which the acq secret store cannot store intact"
    if value.removesuffix("\r") == DPAPI_HEADER:
        return "the secret value equals the reserved DPAPI envelope header"
    return None


def decode_key(key: str) -> tuple[str, str] | None:
    """``(scope, service)`` for a stored key: scope is ``-g`` for global, the
    sandbox name, or ``?`` for a multi-dot key no current write can produce.
    Mirrors ``_acq_secret_decode_key``."""
    if not key.startswith("acq."):
        return None
    rest = key[len("acq."):]
    if rest.count(".") >= 2:
        return "?", rest
    if "." in rest:
        sandbox, _, service = rest.partition(".")
        return sandbox, service
    return "-g", rest


# ---------------------------------------------------------------------------
# Layout and backend selection.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class _Layout:
    file_dir: Path
    meta_dir: Path
    index_file: Path
    force_file: bool
    test_tools: bool  # ACQ_SECRET_STORE_DIR set: honor the tool overrides


def _abs_env(name: str) -> Path | None:
    value = os.environ.get(name, "")
    if not value:
        return None
    if not userdirs.is_absolute(value):
        raise SecretStoreError(
            errors.VALIDATION_FAILED,
            f"{name} must be an absolute path",
            f"set {name} to an absolute path, or unset it",
        )
    return Path(value)


def _default_file_dir() -> Path:
    try:
        return userdirs.xdg_base("XDG_DATA_HOME", ".local", "share") / "acq" / "secrets"
    except userdirs.UserDirError as exc:
        raise SecretStoreError(errors.VALIDATION_FAILED, exc.message, exc.remediation) from None


def _layout() -> _Layout:
    store_dir = _abs_env("ACQ_SECRET_STORE_DIR")
    if store_dir is not None:
        return _Layout(store_dir, store_dir / "meta", store_dir / "index", True, True)
    file_dir = _abs_env("ACQ_SECRET_FILE_DIR") or _default_file_dir()
    base = file_dir.parent if file_dir.name == "secrets" else file_dir
    return _Layout(
        file_dir,
        _abs_env("ACQ_SECRET_META_DIR") or base / "secret-meta",
        _abs_env("ACQ_SECRET_INDEX_FILE") or base / "secret-index",
        bool(os.environ.get("ACQ_SECRET_FORCE_FILE")),
        False,
    )


def _tool_override(layout: _Layout, var: str) -> str | None:
    if not layout.test_tools:
        return None
    return os.environ.get(var) or None


def _security_bin(layout: _Layout) -> str:
    return _tool_override(layout, "ACQ_SECRET_SECURITY_BIN") or _SECURITY_DEFAULT


def _executable(path: str) -> str | None:
    """``path`` when it is an absolute, existing executable file, else None."""
    if userdirs.is_absolute(path) and os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    return None


def _powershell(layout: _Layout) -> str | None:
    """The absolute path of Windows PowerShell, or None. The test-only override
    must itself be absolute; nothing is looked up on PATH."""
    override = _tool_override(layout, "ACQ_SECRET_POWERSHELL_BIN")
    if override:
        return _executable(override)
    system_root = os.environ.get("SystemRoot", "")
    if not userdirs.is_absolute(system_root):
        return None
    return _executable(os.path.join(system_root, *_POWERSHELL_RELATIVE))


def backend_name() -> str:
    """The active mechanism: keychain-macos | keychain-linux | keychain-windows | file.

    Windows is checked first and never falls back to the plaintext file.
    """
    layout = _layout()
    if IS_WINDOWS:
        if _powershell(layout) is None:
            raise SecretStoreError(
                errors.FAILURE,
                "Windows DPAPI is unavailable (Windows PowerShell was not found under "
                "%SystemRoot%), and acq never stores secrets in plaintext on Windows",
                "set SystemRoot to the absolute Windows directory (e.g. C:\\Windows) so "
                "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe is found, then retry",
            )
        return "keychain-windows"
    if layout.force_file:
        return "file"
    if IS_MACOS:
        sec = _security_bin(layout)
        return "keychain-macos" if os.path.isfile(sec) and os.access(sec, os.X_OK) else "file"
    return "keychain-linux" if hostexec.which("secret-tool") else "file"


# ---------------------------------------------------------------------------
# Subprocess and file helpers. Nothing here ever puts a value in argv or text.
# ---------------------------------------------------------------------------

def _enc(text: str) -> bytes:
    return text.encode("utf-8", "surrogateescape")


def _dec(data: bytes) -> str:
    return data.decode("utf-8", "surrogateescape")


def _run_tool(argv: list[str], stdin: str | None = None) -> tuple[int, str]:
    """Run a keychain tool; ``(returncode, stdout)``. A tool that cannot start or
    times out reports 127; its stdout (possibly a value) is then discarded."""
    try:
        proc = subprocess.run(
            argv,
            input=_enc(stdin) if stdin is not None else None,
            stdin=None if stdin is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=TOOL_TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return proc.returncode, _dec(proc.stdout)


def _file_for(directory: Path, key: str) -> Path:
    return directory / _FILE_UNSAFE_RE.sub("_", key)


def _mkdir_private(directory: Path) -> None:
    """``mkdir -p`` under umask 077: every directory created here is 0700."""
    missing = []
    current = directory
    while not current.exists():
        missing.append(current)
        if current.parent == current:
            break
        current = current.parent
    for path in reversed(missing):
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass


def _write_new_private(path: Path, data: bytes, *, append: bool = False) -> None:
    flags = os.O_WRONLY | os.O_CREAT | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= os.O_APPEND if append else os.O_EXCL
    fd = os.open(path, flags, 0o600)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
    finally:
        os.close(fd)


def _stage_atomic(path: Path, content: str) -> Path:
    """Write ``content`` to a hidden 0600 temp beside ``path``; return the temp.

    The caller renames it over ``path``. The ``.<name>.tmp.<pid>`` name matches
    Bash's, so either side's delete removes the other's leftovers.
    """
    _mkdir_private(path.parent)
    tmp = path.parent / f".{path.name}.tmp.{os.getpid()}"
    try:
        tmp.unlink()
    except FileNotFoundError:
        pass
    try:
        _write_new_private(tmp, _enc(content))
    except OSError:
        _unlink_quiet(tmp)
        raise
    return tmp


def _unlink_quiet(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def _read_text(path: Path) -> str | None:
    try:
        return _dec(path.read_bytes())
    except OSError:
        return None


def _first_line(text: str) -> str:
    return text.split("\n", 1)[0]


def _is_envelope_text(text: str) -> bool:
    # A trailing CR is trimmed so a CRLF-mangled envelope is still recognized
    # rather than read as legacy plaintext.
    return _first_line(text).removesuffix("\r") == DPAPI_HEADER


def _is_envelope(path: Path) -> bool:
    text = _read_text(path)
    return text is not None and _is_envelope_text(text)


def _store_failed(key: str, what: str) -> SecretStoreError:
    return SecretStoreError(
        errors.FAILURE,
        f"secret store: {what} failed for '{key}'",
        "check the secret store backend (keychain, DPAPI or the acq data directory) and retry",
    )


# ---------------------------------------------------------------------------
# Per-backend value storage.
# ---------------------------------------------------------------------------

def _security_i_quote(token: str) -> str:
    return '"' + token.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _store_macos(layout: _Layout, key: str, value: str) -> None:
    # `security add-generic-password -w VALUE` would put the value on argv; the
    # `security -i` command stream is stdin, terminated by EOF.
    cmd = (
        f"add-generic-password -U -s {_security_i_quote(KEYCHAIN_LABEL)} "
        f"-a {_security_i_quote(key)} -w {_security_i_quote(value)}\n"
    )
    rc, _ = _run_tool([_security_bin(layout), "-i"], stdin=cmd)
    if rc != 0:
        raise _store_failed(key, "macOS keychain write")


def _store_linux(key: str, value: str) -> None:
    tool = hostexec.which("secret-tool")
    rc = 127 if tool is None else _run_tool(
        [tool, "store", f"--label={KEYCHAIN_LABEL}", "acq_key", key], stdin=value
    )[0]
    if rc != 0:
        raise _store_failed(key, "keychain write")


def _store_file(layout: _Layout, key: str, value: str) -> None:
    path = _file_for(layout.file_dir, key)
    try:
        tmp = _stage_atomic(path, value)
    except OSError:
        raise _store_failed(key, "file write") from None
    try:
        os.replace(tmp, path)
    except OSError:
        _unlink_quiet(tmp)
        raise _store_failed(key, "file write") from None


def dpapi_encrypt(plaintext: str) -> str | None:
    """Base64 DPAPI (CurrentUser) ciphertext of ``plaintext``, or None.

    A seam: tests replace this and :func:`dpapi_decrypt` to exercise the
    envelope logic without Windows.
    """
    ps = _powershell(_layout())
    if ps is None:
        return None
    rc, out = _run_tool([ps, "-NoLogo", "-NoProfile", "-Command", _PS_ENCRYPT], stdin=plaintext)
    return out.rstrip("\n") if rc == 0 else None


def dpapi_decrypt(ciphertext: str) -> str | None:
    """Plaintext for base64 DPAPI ``ciphertext``, or None when undecryptable."""
    ps = _powershell(_layout())
    if ps is None:
        return None
    rc, out = _run_tool([ps, "-NoLogo", "-NoProfile", "-Command", _PS_DECRYPT], stdin=ciphertext)
    return out.rstrip("\n") if rc == 0 else None


def _warn_marker(path: Path) -> Path:
    return path.parent / f".{path.name}.warned"


def _envelope(ciphertext: str) -> str:
    return f"{DPAPI_HEADER}\n{ciphertext}"


def _store_windows(layout: _Layout, key: str, value: str) -> None:
    path = _file_for(layout.file_dir, key)
    enc = dpapi_encrypt(value)
    if not enc:
        raise _store_failed(key, "Windows DPAPI encryption")
    _store_file(layout, key, _envelope(enc))
    # The value is encrypted now, so a stale migration warning marker goes.
    _unlink_quiet(_warn_marker(path))


def _migrate_warn(key: str, path: Path, why: str) -> None:
    """Warn at most once per key that a legacy value stayed in plaintext."""
    marker = _warn_marker(path)
    if marker.exists():
        return
    try:
        _write_new_private(marker, b"")
    except OSError:
        pass
    print(
        f"acq: warning: could not encrypt the '{key}' secret at rest with Windows DPAPI ({why}); "
        "it remains in plaintext on disk. Re-run 'acq secret set' once DPAPI is available.",
        file=sys.stderr,
    )


def _migrate_windows(key: str, path: Path, value: str) -> None:
    """Best-effort re-encryption of a legacy plaintext value; never fails a read."""
    enc = dpapi_encrypt(value)
    if not enc:
        _migrate_warn(key, path, "DPAPI encryption failed" if enc is None else "DPAPI produced no ciphertext")
        return
    try:
        tmp = _stage_atomic(path, _envelope(enc))
    except OSError:
        _migrate_warn(key, path, "temporary file write failed")
        return
    # Replace only if the file is still the legacy value read above, so a
    # concurrent `secret set` during the encrypt call is not reverted.
    current = _read_text(path)
    if current is None or _is_envelope_text(current) or current.rstrip("\n") != value:
        _unlink_quiet(tmp)
        return
    try:
        os.replace(tmp, path)
    except OSError:
        _unlink_quiet(tmp)
        _migrate_warn(key, path, "rename failed")
        return
    _unlink_quiet(_warn_marker(path))


def _get_file(layout: _Layout, key: str) -> str | None:
    text = _read_text(_file_for(layout.file_dir, key))
    if text is None or _is_envelope_text(text):
        # Ciphertext this backend cannot decrypt fails closed: returning the
        # base64 blob would make callers bind it as the secret.
        return None
    return text.rstrip("\n")


def _get_windows(layout: _Layout, key: str) -> str | None:
    path = _file_for(layout.file_dir, key)
    text = _read_text(path)
    if text is None:
        return None
    if _is_envelope_text(text):
        parts = text.split("\n", 1)
        value = dpapi_decrypt(parts[1] if len(parts) > 1 else "")
    else:
        value = text.rstrip("\n")
        _migrate_windows(key, path, value)
    return value or None


def _get_macos(layout: _Layout, key: str) -> str | None:
    rc, out = _run_tool([_security_bin(layout), "find-generic-password", "-s", KEYCHAIN_LABEL, "-a", key, "-w"])
    value = out.rstrip("\n") if rc == 0 else ""
    # Fall back to the pre-`security -i` 0600 file until it is re-saved.
    return value if value else _get_file(layout, key)


def _get_linux(key: str) -> str | None:
    tool = hostexec.which("secret-tool")
    if tool is None:
        return None
    rc, out = _run_tool([tool, "lookup", "acq_key", key])
    value = out.rstrip("\n")
    return value if rc == 0 and value else None


# ---------------------------------------------------------------------------
# The key index (keychain backends only).
# ---------------------------------------------------------------------------

def _read_lines(path: Path) -> list[str]:
    text = _read_text(path)
    if not text:
        return []
    lines = text.split("\n")
    return lines[:-1] if lines[-1] == "" else lines


def _index_add(layout: _Layout, key: str) -> None:
    """Record ``key`` in the index (deduplicated, 0600). Best-effort."""
    try:
        _mkdir_private(layout.index_file.parent)
        if key in _read_lines(layout.index_file):
            return
        _write_new_private(layout.index_file, _enc(key + "\n"), append=True)
    except OSError:
        pass


def _index_remove(layout: _Layout, key: str) -> None:
    """Drop ``key`` from the index (idempotent). Best-effort."""
    index = layout.index_file
    if not index.is_file():
        return
    tmp = index.parent / f"{index.name}.tmp.{os.getpid()}"
    try:
        _unlink_quiet(tmp)
        kept = "".join(f"{line}\n" for line in _read_lines(index) if line != key)
        _write_new_private(tmp, _enc(kept))
        os.replace(tmp, index)
    except OSError:
        _unlink_quiet(tmp)


# ---------------------------------------------------------------------------
# Public value API (mirrors acq_secret_store/get/delete/resolve/has).
# ---------------------------------------------------------------------------

def store(key: str, value: str) -> None:
    """Store ``value`` under ``key`` in the active backend, overwriting."""
    problem = value_problem(value)
    if problem is not None:
        raise SecretStoreError(errors.VALIDATION_FAILED, f"{problem}; nothing stored for '{key}'")
    layout = _layout()
    backend = backend_name()
    if backend == "keychain-macos":
        _store_macos(layout, key, value)
        _delete_file(layout, key)
        _index_add(layout, key)
    elif backend == "keychain-linux":
        _store_linux(key, value)
        _index_add(layout, key)
    elif backend == "keychain-windows":
        _store_windows(layout, key, value)
    else:
        _store_file(layout, key, value)


def get(key: str) -> str | None:
    """The value stored under ``key`` (possibly empty), or None when absent or
    unreadable."""
    layout = _layout()
    backend = backend_name()
    if backend == "keychain-macos":
        return _get_macos(layout, key)
    if backend == "keychain-linux":
        return _get_linux(key)
    if backend == "keychain-windows":
        return _get_windows(layout, key)
    return _get_file(layout, key)


def _delete_file(layout: _Layout, key: str) -> None:
    path = _file_for(layout.file_dir, key)
    # Drop the migration marker and any temp left by a crash between write and
    # rename, so a delete cannot leave a decryptable copy behind.
    for leftover in path.parent.glob(f".{path.name}.tmp.*"):
        _unlink_quiet(leftover)
    _unlink_quiet(_warn_marker(path))
    if not os.path.lexists(path):
        return
    try:
        path.unlink()
    except OSError:
        raise _store_failed(key, "file remove") from None


def delete(key: str) -> None:
    """Remove ``key`` from the active backend. Idempotent."""
    layout = _layout()
    backend = backend_name()
    if backend == "keychain-macos":
        _run_tool([_security_bin(layout), "delete-generic-password", "-s", KEYCHAIN_LABEL, "-a", key])
        _index_remove(layout, key)
    elif backend == "keychain-linux":
        tool = hostexec.which("secret-tool")
        if tool is not None:
            _run_tool([tool, "clear", "acq_key", key])
        _index_remove(layout, key)
    _delete_file(layout, key)


def resolve(service: str, sandbox: str | None = None) -> str | None:
    """The value for ``service``: the sandbox scope first, then global."""
    candidates = ([_try_key(service, sandbox)] if sandbox else []) + [_try_key(service)]
    for key in candidates:
        if key is None:
            continue
        value = get(key)
        if value:
            return value
    return None


def has(service: str, sandbox: str | None = None) -> bool:
    return resolve(service, sandbox) is not None


def _present_unreadable(layout: _Layout, key: str) -> bool:
    return _is_envelope(_file_for(layout.file_dir, key))


def unreadable(service: str, sandbox: str | None = None) -> bool:
    """True when a value is stored but this host cannot present it (a DPAPI
    envelope the active backend cannot decrypt)."""
    if has(service, sandbox):
        return False
    layout = _layout()
    candidates = ([_try_key(service, sandbox)] if sandbox else []) + [_try_key(service)]
    return any(key is not None and _present_unreadable(layout, key) for key in candidates)


def exists(service: str, sandbox: str | None = None) -> bool:
    """True when this exact scope holds a value, readable or not (no fallback)."""
    key = key_for(service, sandbox)
    return bool(get(key)) or _present_unreadable(_layout(), key)


# ---------------------------------------------------------------------------
# Endpoint metadata sidecar (non-secret HOST<TAB>ENV).
# ---------------------------------------------------------------------------

def host_list_ok(host: str) -> bool:
    """True when ``host`` is one or more comma-separated endpoint hosts.

    Shared by every ``--host`` path (``secret set`` on both backends and the
    endpoint sidecar), so a malformed or over-broad host is refused before
    anything is stored.
    """
    return 0 < len(host) <= 1024 and all(
        len(part) <= 253 and _HOST_RE.fullmatch(part) is not None for part in host.split(",")
    )


def _check_binding(service: str, host: str, env: str) -> None:
    # Charset-restricted so neither can smuggle a flag into a later
    # `--secret ENV@HOST` argv.
    if _META_ENV_RE.fullmatch(env) is None or not host_list_ok(host):
        raise SecretStoreError(
            errors.VALIDATION_FAILED,
            f"refusing an unsafe host or env name for '{service}'",
            "hosts are DNS names of two or more labels (comma-separated, an optional "
            "leading '*.'); env names match [A-Za-z0-9_]+",
        )


def meta_store(service: str, sandbox: str | None, host: str, env: str) -> None:
    """Persist the endpoint mapping. Empty host or env stores nothing."""
    if not host or not env:
        return
    _check_binding(service, host, env)
    key = key_for(service, sandbox)
    layout = _layout()
    path = _file_for(layout.meta_dir, key)
    try:
        tmp = _stage_atomic(path, f"{host}\t{env}\n")
        os.replace(tmp, path)
    except OSError:
        raise _store_failed(key, "endpoint metadata write") from None


def _meta_read(layout: _Layout, key: str | None) -> Binding | None:
    if key is None:
        return None
    lines = _read_lines(_file_for(layout.meta_dir, key))
    if not lines or not lines[0]:
        return None
    host, _, env = lines[0].partition("\t")
    return Binding(host, env)


def meta_resolve(service: str, sandbox: str | None = None) -> Binding | None:
    """The endpoint mapping, sandbox scope first, then global."""
    layout = _layout()
    if sandbox:
        found = _meta_read(layout, _try_key(service, sandbox))
        if found:
            return found
    return _meta_read(layout, _try_key(service))


def meta_resolve_exact(service: str, sandbox: str | None = None) -> Binding | None:
    """The endpoint mapping for exactly this scope (no global fallback)."""
    return _meta_read(_layout(), _try_key(service, sandbox))


def meta_delete(service: str, sandbox: str | None = None) -> None:
    key = _try_key(service, sandbox)
    if key is not None:
        _unlink_quiet(_file_for(_layout().meta_dir, key))


def _dir_names(directory: Path) -> list[str]:
    try:
        return sorted(p.name for p in directory.iterdir() if p.is_file())
    except OSError:
        return []


def meta_list(sandbox: str | None = None) -> list[str]:
    """Services with a sidecar in ``sandbox``'s scope or the global scope.

    A dotted key that is neither this sandbox's nor a plain global one (another
    sandbox, or a legacy dotted global) is skipped, never mis-attributed.
    """
    seen: list[str] = []
    for base in _dir_names(_layout().meta_dir):
        if not base.startswith("acq."):
            continue
        rest = base[len("acq."):]
        prefix = f"acq.{sandbox}."
        if sandbox and base.startswith(prefix):
            svc = base[len(prefix):]
        else:
            svc = "" if "." in rest else rest
        if svc and svc not in seen:
            seen.append(svc)
    return seen


# ---------------------------------------------------------------------------
# Enumeration.
# ---------------------------------------------------------------------------

def list_keys() -> list[str]:
    """Every stored value key (keys only). Keychain stores enumerate the index,
    the sidecar names and any legacy files, keeping only keys that resolve."""
    layout = _layout()
    if backend_name() not in ("keychain-macos", "keychain-linux"):
        return [n for n in _dir_names(layout.file_dir) if n.startswith("acq.")]
    candidates = (
        _read_lines(layout.index_file) + _dir_names(layout.meta_dir) + _dir_names(layout.file_dir)
    )
    out: list[str] = []
    for key in candidates:
        if key.startswith("acq.") and key not in out and get(key) is not None:
            out.append(key)
    return out


def list_entries() -> list[dict]:
    """``{scope, service, value_state}`` per stored key, never a value.

    ``scope`` is ``global``, the sandbox name, or ``?`` for an ambiguous legacy
    key, and ``scope_kind`` (``global``, ``sandbox`` or ``unknown``) keeps a
    sandbox named ``global`` apart from the global scope; ``value_state`` is
    ``set`` or ``unreadable``.
    """
    out = []
    for key in list_keys():
        decoded = decode_key(key)
        if decoded is None or not decoded[1]:
            continue
        scope, service = decoded
        sandbox = None if scope in ("-g", "?") else scope
        state = "unreadable" if scope != "?" and unreadable(service, sandbox) else "set"
        kind = {"-g": "global", "?": "unknown"}.get(scope, "sandbox")
        out.append({
            "scope": "global" if scope == "-g" else scope, "scope_kind": kind, "service": service, "value_state": state,
        })
    return out


# ---------------------------------------------------------------------------
# The composite write used by `secret set` (acq_secret_set_interactive minus
# reading the value).
# ---------------------------------------------------------------------------

def set_secret(service: str, sandbox: str | None, value: str, host: str = "", env: str = "") -> str:
    """Store ``value`` for ``(service, sandbox)`` and, when both are given, the
    non-secret ``host``/``env`` endpoint mapping. Returns the key."""
    key = key_for(service, sandbox)
    if host and env:
        _check_binding(service, host, env)  # before the value, so nothing is half-written
    store(key, value)
    meta_store(service, sandbox, host, env)
    return key
