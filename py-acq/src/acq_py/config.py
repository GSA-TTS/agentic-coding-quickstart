"""Host-authoritative ``config.yaml``: flat keys and the schema marker (ADR-0038m §config, ADR-0041m).

The legacy Bash ``acq`` persists user configuration at
``${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml`` with no version marker.
ADR-0041m adds a flat ``schema:`` key as the first line so a reader can detect the
version before touching any other key, and migrates a schema-less (legacy v0)
config forward in place. This module owns that marker, the forward migration, and
the flat-key reader/writer the ``backend set``/``unset`` verbs and backend
resolution use.

There is deliberately **no** YAML dependency: keys are read and written line-wise,
so ordinary operation stays stdlib-only and offline (ADR-0042m). Bash and Python
share this one file, so :func:`read_field` and :func:`write_field` mirror the Bash
``_acq_config_read_field`` / ``_acq_config_write_field`` byte for byte: the same
top-level key match, the same comment and quote handling, the same "last
duplicate wins" read, and the same "drop every old line for the key, append the
new one" write. Every other line, including keys this reader does not know, is
kept verbatim. They work on bytes so line endings and non-UTF-8 content survive.

Writes differ from Bash in two deliberate ways: a symlinked ``config.yaml`` (a
dotfiles-managed link) is written through to its target instead of being replaced
by a regular file, and an existing file keeps its permission mode instead of being
reset. A brand-new file is created ``0600`` and starts with the ``schema:`` marker.
Every write is a temp file, fsync, and atomic rename, so a crash at any point
leaves either the old file or the new one, never neither.

``config.yaml`` lives in the config tree (``XDG_CONFIG_HOME``), distinct from the
state tree the record/generation machinery migrates (ADR-0041m: orchestrator-owned
state). Both carry their own ``schema`` marker; the two never share a number space
with the structured-output ``schema_version`` in ``envelope.py``.

``ACQ_CONFIG_SEED`` is an internal test seam (never a secret, never written to
output): when set and no ``config.yaml`` exists yet, the migration pre-step of a
mutating verb writes its text there, so a single-invocation contract vector can
start from a given config (mirrors ``ACQ_STATE_SEED``). Read-only paths never
materialize it, and it is honoured only while a backend runs the bundled
``__stub__`` (the same gate as the backend detection overrides), so a stray export
cannot write a real user's config. Keep a vector's seed on one line: the Bash
vector runner reads environment values line by line.
"""

from __future__ import annotations

import errno
import os
import re
import stat
import sys
import tempfile
import time
from pathlib import Path

from . import backends, userdirs

CONFIG_SCHEMA = 1

# What config_schema() returns for an existing file that has no marker.
LEGACY_SCHEMA = 0

SEED_ENV = "ACQ_CONFIG_SEED"

# A flat ``schema:`` key: column 0, a single integer token, optional trailing
# comment. Nested/indented keys and ``schema_version:`` are deliberately NOT
# matched — this marker is the flat top-level key, not the result-schema version.
_SCHEMA_LINE_RE = re.compile(r"^schema:\s*([0-9]+)\s*(?:#.*)?$")

# Key names the Bash reader/writer accept; anything else is refused so a key can
# never smuggle regex syntax into the line match.
_KEY_RE = re.compile(r"[A-Za-z0-9_]+")

# POSIX [[:space:]] as awk sees it in the C locale.
_SPACE = b" \t\n\r\v\f"
_TRAILING_COMMENT_RE = re.compile(rb"[ \t\n\r\v\f]+#.*\Z", re.DOTALL)
_DOUBLE_QUOTED_RE = re.compile(rb'"[^"]*"')

# A new file, and the backup migration keeps while it runs, are owner-only.
_NEW_FILE_MODE = 0o600

# Write failures that mean "this file cannot be changed" (a read-only target, as
# home-manager or nix provide) rather than a broken setup.
_READ_ONLY_ERRNOS = frozenset({errno.EACCES, errno.EROFS, errno.EPERM})

# Temp files from an interrupted write older than this are removed by the
# migration pre-step. Only the exact names acq and Bash create are touched, since
# the directory may be a user's dotfiles: ``<name>.tmp.`` plus mkstemp's random
# part (eight characters from ``[a-z0-9_]`` in CPython's tempfile; a test pins it)
# for ``_replace_bytes``, and ``config.yaml.tmp.<pid>`` for Bash's writer, which
# only ever writes in the config directory.
_STALE_TEMP_SECONDS = 300
_TEMP_INFIX = ".tmp."
_MKSTEMP_PART = "[a-z0-9_]{8}"


class ConfigSchemaError(Exception):
    """``config.yaml`` carries a schema this reader cannot read (ADR-0041m).

    Raised for a newer-than-this-reader marker. A schema-less (legacy v0) config
    is the one tolerated case and is migrated forward rather than misread.
    """


class ConfigMigrationError(ConfigSchemaError):
    """A migration step could not be carried out (the schema itself is fine).

    Carries actionable ``remediation`` prose naming the file that is in the way.
    """

    def __init__(self, message: str, remediation: str):
        super().__init__(message)
        self.remediation = remediation


def config_path() -> Path:
    """Resolve the acq config file (ADR-0038m §config path).

    An empty or relative ``XDG_CONFIG_HOME`` is ignored as the XDG Base Directory
    specification requires, falling back to ``$HOME/.config`` (see
    :mod:`userdirs`).
    """
    return userdirs.xdg_base("XDG_CONFIG_HOME", ".config") / "acq" / "config.yaml"


# ---------------------------------------------------------------------------
# Reading.
# ---------------------------------------------------------------------------

def seed_config() -> None:
    """Materialize ``ACQ_CONFIG_SEED`` when no config exists yet (test seam).

    Called only from the migration pre-step, and only while a backend adapter
    runs the bundled stub.
    """
    seed = os.environ.get(SEED_ENV)
    stubbed = any(os.environ.get(f"ACQ_{name.upper()}_BIN") == backends.STUB_SENTINEL for name in backends.BACKENDS)
    if seed is None or not stubbed:
        return
    path = config_path()
    if os.path.lexists(path):
        return
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _replace_bytes(path, seed.encode("utf-8", "surrogateescape"), _NEW_FILE_MODE)


def _read_bytes() -> bytes | None:
    """The config's bytes, or ``None`` when it is absent or unreadable."""
    path = config_path()
    try:
        return path.read_bytes()
    except OSError:
        return None


def _lines(raw: bytes) -> list[bytes]:
    """Split into lines the way awk does: on LF, a final LF ends the last line."""
    if not raw:
        return []
    lines = raw.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    return lines


def _key_pattern(key: str) -> re.Pattern[bytes]:
    # Bash: awk's ``^KEY[[:space:]]*:`` — a top-level key only, never an
    # indented one.
    return re.compile(b"^" + key.encode("ascii") + rb"[ \t\n\r\v\f]*:")


def _strip_comment(value: bytes) -> bytes:
    """Drop an inline ``#`` comment that is outside quotes (Bash parity)."""
    if value[:1] in (b'"', b"'"):
        in_single = in_double = False
        for i, char in enumerate(value):
            if char == 0x27 and not in_double:
                in_single = not in_single
            elif char == 0x22 and not in_single:
                in_double = not in_double
            elif char == 0x23 and not in_single and not in_double and (i == 0 or value[i - 1] in _SPACE):
                return value[:i]
        return value
    if value[:1] == b"#":
        return b""
    return _TRAILING_COMMENT_RE.sub(b"", value, count=1)


def _parse_value(rest: bytes) -> bytes:
    value = _strip_comment(rest.lstrip(_SPACE)).rstrip(_SPACE)
    if _DOUBLE_QUOTED_RE.fullmatch(value):
        return value[1:-1]
    if value[:1] == b"'" and value[-1:] == b"'":
        return value[1:-1]
    return value


def read_field(key: str) -> str | None:
    """The value of the flat top-level ``KEY: value`` line, or ``None``.

    Mirrors Bash ``_acq_config_read_field``: an absent file, an absent key, an
    empty value, or a key name outside ``[A-Za-z0-9_]`` all read as ``None``; when
    a key repeats, the last line wins. The schema marker is not checked here, so a
    read-only caller can still report a persisted value.
    """
    if not _KEY_RE.fullmatch(key):
        return None
    try:
        raw = _read_bytes()
    except userdirs.UserDirError:
        return None
    if raw is None:
        return None
    pattern = _key_pattern(key)
    value = b""
    for line in _lines(raw):
        match = pattern.match(line)
        if match:
            value = _parse_value(line[match.end():])
    return value.decode("utf-8", "surrogateescape") if value else None


def config_schema() -> int | None:
    """The flat ``schema`` marker: its value, :data:`LEGACY_SCHEMA` for an existing
    file with no marker, or ``None`` when there is no config file.

    Raises :class:`ConfigSchemaError` for a newer marker (fail-closed, ADR-0041m).
    """
    raw = _read_bytes()
    if raw is None:
        return None
    for line in _lines(raw):
        match = _SCHEMA_LINE_RE.match(line.decode("utf-8", "surrogateescape"))
        if match:
            value = int(match.group(1))
            if value != CONFIG_SCHEMA:
                raise ConfigSchemaError(
                    f"config.yaml carries schema {value}; this reader understands "
                    f"schema {CONFIG_SCHEMA}"
                )
            return value
    return LEGACY_SCHEMA


# ---------------------------------------------------------------------------
# Writing.
# ---------------------------------------------------------------------------

def _fsync_dir(directory: Path) -> None:
    """Persist a rename in ``directory`` (best effort; not possible on Windows)."""
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _replace_bytes(dest: Path, data: bytes, mode: int) -> None:
    """Atomically replace ``dest`` with ``data``: temp file, fsync, rename.

    The temp file sits beside ``dest`` (same filesystem, so the rename is atomic)
    and is created owner-only before it is given ``mode``. It is removed if
    anything fails before the rename.
    """
    fd, tmp_name = tempfile.mkstemp(prefix=dest.name + _TEMP_INFIX, dir=dest.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, dest)
    except BaseException:
        _unlink_quietly(tmp)
        raise
    if os.name == "posix":
        _fsync_dir(dest.parent)


def _write_target(path: Path) -> Path:
    """Where a write to ``path`` lands: a symlink's final target, else ``path``."""
    return Path(os.path.realpath(path)) if path.is_symlink() else path


def _write_config_bytes(path: Path, data: bytes) -> None:
    """Replace the config's content, writing through a symlink and keeping the mode."""
    target = _write_target(path)
    try:
        mode = stat.S_IMODE(os.stat(target).st_mode)
    except FileNotFoundError:
        mode = _NEW_FILE_MODE
    _replace_bytes(target, data, mode)


def _ensure_config_dir(path: Path) -> None:
    # Bash creates the directory with umask 077 and then forces 0700.
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)


def write_field(key: str, value: str) -> Path:
    """Set the flat ``KEY: VALUE`` line, keeping every other line; return the path.

    Mirrors Bash ``_acq_config_write_field``: every existing top-level line for
    ``key`` is dropped, the other lines are re-emitted unchanged (each ending in
    LF), and ``KEY: VALUE`` is appended. An empty ``value`` removes the key. A new
    file starts with the ``schema:`` marker. Raises ``ValueError`` for a key outside
    ``[A-Za-z0-9_]`` or a value that would break the line format, and ``OSError``
    when the existing file cannot be read (it is never overwritten blind).
    """
    if not _KEY_RE.fullmatch(key):
        raise ValueError(f"unsafe config key: {key!r}")
    if any(char in value for char in "\n\r\x00"):
        raise ValueError(f"config value for {key!r} contains a line break or NUL")
    path = config_path()
    _ensure_config_dir(path)
    try:
        raw: bytes | None = path.read_bytes()
    except FileNotFoundError:
        raw = None
    if raw is None:
        out = [f"schema: {CONFIG_SCHEMA}\n".encode()]
    else:
        pattern = _key_pattern(key)
        out = [line + b"\n" for line in _lines(raw) if not pattern.match(line)]
    if value:
        out.append(f"{key}: {value}\n".encode("utf-8", "surrogateescape"))
    _write_config_bytes(path, b"".join(out))
    return path


def remove_if_only_marker() -> bool:
    """Delete ``config.yaml`` when nothing but the schema marker remains; return
    whether it was removed.

    Bash ``backend unset`` deletes a config it left empty so a fresh install looks
    pristine (an empty file would suppress Bash's first-run ``acq configure``
    offer). A Python-written file also carries the marker, so "empty" here means
    no other line. A symlinked config is left in place: deleting the link would
    break the user's dotfiles setup.
    """
    path = config_path()
    if path.is_symlink():
        return False
    raw = _read_bytes()
    if raw is None:
        return False
    for line in _lines(raw):
        text = line.decode("utf-8", "surrogateescape")
        if not _SCHEMA_LINE_RE.match(text):
            return False
    path.unlink()
    return True


# ---------------------------------------------------------------------------
# Forward migration.
# ---------------------------------------------------------------------------

def migrate_config() -> str:
    """Forward-migrate ``config.yaml`` to add the flat ``schema:`` marker.

    Returns ``"none"`` (absent or already current), ``"migrated"``, or
    ``"skipped"`` when a legacy config cannot be written (a read-only symlink
    target, as home-manager or nix provide). The original is never moved out of
    the way: its bytes are first copied to ``config.yaml.bak.0``, then the
    migrated content atomically replaces the file (through a symlink, keeping its
    mode), and the backup is deleted only once the new file reads back with the
    right marker. A crash at any step therefore leaves either the legacy file,
    which the next run migrates again, or the migrated one; a backup or temp file
    left by such a crash is removed by a later run. If the read-back fails, the
    original bytes are written back.

    A legacy config that cannot be written is still readable, so the verb goes
    on: a note on stderr names the read-only file, and ``doctor`` keeps warning
    until the marker is added there by hand.

    Raises :class:`ConfigSchemaError` for a newer marker, and
    :class:`ConfigMigrationError` for a step that failed.
    """
    path = config_path()
    backup = path.with_name(path.name + ".bak.0")
    _remove_stale_temps(path)
    raw = _read_bytes()
    if raw is None:
        return "none"
    if config_schema() == CONFIG_SCHEMA:
        _remove_leftover_backup(backup)
        return "none"

    # Legacy v0: prepend the marker as the first line (schema is the first field).
    migrated = f"schema: {CONFIG_SCHEMA}\n".encode() + raw
    if raw and not raw.endswith(b"\n"):
        migrated += b"\n"

    try:
        _replace_bytes(backup, raw, _NEW_FILE_MODE)
    except OSError as exc:
        if exc.errno in _READ_ONLY_ERRNOS and not os.access(path.parent, os.W_OK):
            # The whole config directory is read-only: nothing can be written.
            _note_read_only(path.parent)
            return "skipped"
        raise ConfigMigrationError(
            f"could not write the config backup {backup}: {exc.strerror or exc}; config.yaml was not changed",
            f"remove or repair {backup} (it must be a writable regular file or absent), then retry",
        ) from exc
    try:
        _write_config_bytes(path, migrated)
    except OSError as exc:
        _unlink_quietly(backup)
        if exc.errno in _READ_ONLY_ERRNOS:
            _note_read_only(_write_target(path))
            return "skipped"
        raise ConfigMigrationError(
            f"config.yaml migration failed while writing {path}: {exc.strerror or exc}; config.yaml was not changed",
            "check that config.yaml and its directory are writable, then retry",
        ) from exc
    if not _verified():
        try:
            _write_config_bytes(path, raw)
        except OSError as exc:
            # The backup is now the only copy of the original, so it is kept.
            raise ConfigMigrationError(
                f"config.yaml did not verify after migration and could not be restored: {path} "
                f"({exc.strerror or exc}); the original is kept at {backup}",
                f"copy {backup} back to {path}, then retry",
            ) from exc
        _unlink_quietly(backup)
        raise ConfigSchemaError(f"config.yaml did not verify after migration; the original was restored: {path}")
    _unlink_quietly(backup)
    return "migrated"


def _note_read_only(target: Path) -> None:
    print(
        f"acq: note: {target} is read-only, so config.yaml was left without its schema marker; "
        f"add 'schema: {CONFIG_SCHEMA}' as the first line of that file to record it",
        file=sys.stderr,
    )


def _remove_leftover_backup(backup: Path) -> None:
    """Remove a ``config.yaml.bak.0`` an interrupted migration left behind.

    Only called once ``config.yaml`` carries the current marker, so the backup is
    no longer needed. A directory (or anything else that cannot be removed) in its
    place is refused, because the next legacy migration could not write its backup
    there either.
    """
    if not os.path.lexists(backup):
        return
    if backup.is_dir() and not backup.is_symlink():
        raise ConfigMigrationError(
            f"{backup} is a directory, where acq keeps a temporary config backup",
            f"remove the directory {backup}, then retry",
        )
    try:
        os.unlink(backup)
    except OSError as exc:
        raise ConfigMigrationError(
            f"could not remove the leftover config backup {backup}: {exc.strerror or exc}",
            f"remove {backup}, then retry",
        ) from exc


def _temp_name_pattern(name: str, bash: bool) -> re.Pattern[str]:
    """The exact temp-file names written for ``name`` (plus Bash's when ``bash``)."""
    part = f"(?:{_MKSTEMP_PART}|[0-9]+)" if bash else _MKSTEMP_PART
    return re.compile(re.escape(name + _TEMP_INFIX) + part)


def _remove_stale_temps(path: Path) -> None:
    """Remove stale temp files an interrupted write left behind.

    Looks only where acq writes: the config directory (the config's own temp
    files, Bash's ``config.yaml.tmp.<pid>``, and the backup's temp files) and,
    for a symlinked config, the target's directory (the target's temp files
    only). A name must match exactly, and only an old regular file is removed:
    never a symlink, a directory, or any other user file.
    """
    patterns = [
        (path.parent, _temp_name_pattern(path.name, bash=True)),
        (path.parent, _temp_name_pattern(path.name + ".bak.0", bash=False)),
    ]
    target = _write_target(path)
    if target != path:
        patterns.append((target.parent, _temp_name_pattern(target.name, bash=False)))
    cutoff = time.time() - _STALE_TEMP_SECONDS
    for directory, pattern in patterns:
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        for entry in names:
            if not pattern.fullmatch(entry):
                continue
            candidate = directory / entry
            try:
                info = os.lstat(candidate)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode) and info.st_mtime < cutoff:
                _unlink_quietly(candidate)


def _unlink_quietly(path: Path) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _verified() -> bool:
    """True when the config reads back with the current marker on its first line."""
    raw = _read_bytes()
    lines = _lines(raw) if raw is not None else []
    if not lines or _SCHEMA_LINE_RE.match(lines[0].decode("utf-8", "surrogateescape")) is None:
        return False
    try:
        return config_schema() == CONFIG_SCHEMA
    except ConfigSchemaError:
        return False


def _unreadable_problem(path: Path) -> dict | None:
    """A failed doctor check when ``config.yaml`` exists but cannot be read.

    ``_read_bytes`` treats an unreadable file as absent so the verbs keep their
    defaults; doctor must not report that as "no config.yaml".
    """
    if path.is_symlink() and not path.exists():
        return {
            "id": "config-schema",
            "status": "fail",
            "message": f"config.yaml is a dangling symlink ({path} -> {os.readlink(path)})",
            "remediation": "point the symlink at an existing file, or remove it to use the defaults",
        }
    if not os.path.lexists(path):
        return None
    try:
        with open(path, "rb"):
            pass
    except OSError as exc:
        return {
            "id": "config-schema",
            "status": "fail",
            "message": f"cannot read {path}: {exc.strerror or exc}",
            "remediation": "make config.yaml a regular file readable by your user, or remove it to use the defaults",
        }
    return None


def doctor_check() -> dict:
    """Report config-schema health for ``acq doctor`` (read-only)."""
    try:
        problem = _unreadable_problem(config_path())
        current = config_schema()
    except userdirs.UserDirError as exc:
        return {"id": "config-schema", "status": "fail", "message": exc.message, "remediation": exc.remediation}
    except ConfigSchemaError as exc:
        return {
            "id": "config-schema",
            "status": "fail",
            "message": str(exc),
            "remediation": "remove or repair config.yaml so its schema marker is readable",
        }
    if problem is not None:
        return problem
    if current is None:
        return {"id": "config-schema", "status": "pass", "message": "no config.yaml; defaults apply"}
    if current == LEGACY_SCHEMA:
        return {
            "id": "config-schema",
            "status": "warn",
            "message": "config.yaml is a legacy schema-less (v0) config",
            "remediation": "run any mutating acq command to migrate it in place; if the file is read-only, "
            f"add 'schema: {CONFIG_SCHEMA}' as its first line",
        }
    return {"id": "config-schema", "status": "pass", "message": f"config.yaml schema {current}"}
