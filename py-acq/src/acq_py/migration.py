"""Tree-level forward-only state migration (ADR-0041m).

The acq orchestrator owns migration of acq-hosted records; backend adapters never
migrate acq state, and backend-native state is refused/delegated, never migrated.
Guest-writable state is never trusted or migrated (ADR-0035). This module is the
synchronized pre-step that runs before any mutating verb:

* a single tree-level **generation marker** (a checkpoint of progress, not a data
  format) is written LAST so a generation is never declared complete until every
  record is migrated — a partially-applied tree migration is detectable and
  resumable;
* migration runs under the exclusive OS advisory lock (:mod:`acq_py.lock`) so a
  second concurrent invocation fails closed and a crash auto-releases;
* forward migration is idempotent per record: older (legacy v0) records migrate
  forward in place, newer or unparseable records (or a reader below a record's
  ``min_reader``) are refused with a stable code + remediation;
* each record migrates atomically and non-destructively until verified: write
  temp + fsync + rename, retain the prior record as ``<name>.bak.<schema>`` until
  the new record parses back, then delete; on failure the old record is left
  intact and the path + failed step + remediation are reported. A migration is
  never reported successful unless the read-back verifies.

All sandbox-state records live under the state root (``state.state_dir()``) as
``state_dir()/<backend>/*.json``. The generation marker is
``state_dir()/generation`` (no ``.json`` suffix) and the migration lock is
``state_dir()/migration.lock``, so neither is picked up by the record scan.

This migration is **type-aware** (ADR-0041m): it only ever touches *sandbox-state*
records (those under a backend directory). Kit-source / provenance / consent
records live in sibling ``kit-sources/``, ``provenance/``, and ``kit-consent/``
directories and carry their OWN ``KIT_SCHEMA`` number space; sandbox-state
migration never rewrites or rejects them, so a future ``KIT_SCHEMA`` bump cannot
hard-fail sandbox migration and a legacy kit record is never rewritten into
sandbox space.

``ACQ_STATE_SEED`` is an internal test seam (never a secret, never written to
output): a JSON object mapping ``"<backend>/<name>"`` to a record (a dict is
serialized as JSON; a string is written verbatim, to simulate an unparseable
record) that is materialized into the state tree before migration runs, so a
single-invocation contract vector can seed legacy/newer/unparseable records.
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

from . import backends, config, errors, lock, state

# The tree generation this reader migrates records TO, and the schema level this
# reader itself understands. All record types currently write ``schema=1``; if a
# record type diverges in its own schema number space, the migration must become
# type-aware rather than treating every record as one schema space.
TARGET_SCHEMA = state.STATE_SCHEMA
READER_SCHEMA = state.STATE_SCHEMA

# Generation-marker and lock filenames under the state root.
_GENERATION_FILENAME = "generation"
_LOCK_FILENAME = "migration.lock"

SEED_ENV = "ACQ_STATE_SEED"


class MigrationError(Exception):
    """A forward migration failed closed (ADR-0041m).

    ``code`` is a stable error token; ``path`` and ``step`` (when present) locate
    the failed record and the migration step that failed, so the remediation names
    them rather than leaving the user to guess.
    """

    def __init__(
        self,
        code: str,
        message: str,
        remediation: str | None = None,
        *,
        path: str | None = None,
        step: str | None = None,
    ):
        super().__init__(message)
        self.code = code
        self.message = message
        self.remediation = remediation
        self.path = path
        self.step = step


def state_root() -> Path:
    return state.state_dir()


def generation_path() -> Path:
    return state_root() / _GENERATION_FILENAME


def lock_path() -> Path:
    return state_root() / _LOCK_FILENAME


# ---------------------------------------------------------------------------
# Generation marker (a checkpoint of progress, written LAST).
# ---------------------------------------------------------------------------

def read_generation() -> int:
    """Return the highest generation the marker declares fully applied (0 if none)."""
    try:
        raw = generation_path().read_text(encoding="utf-8")
    except OSError:
        return 0
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return 0
    if not isinstance(doc, dict):
        return 0
    gen = doc.get("generation")
    return gen if isinstance(gen, int) and not isinstance(gen, bool) else 0


def write_generation(generation: int) -> None:
    """Write the marker atomically (temp + fsync + rename); called LAST."""
    path = generation_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    data = json.dumps({"schema": state.STATE_SCHEMA, "generation": generation}, indent=2)
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Record scan and classification.
# ---------------------------------------------------------------------------

def iter_records() -> list[Path]:
    """Every *sandbox-state* record path, in deterministic path order.

    Only records under a backend directory (``state_dir()/<backend>/``) are
    sandbox state and therefore migratable here. Kit-source / provenance /
    consent records live in sibling directories with their own ``KIT_SCHEMA``
    number space and are deliberately excluded (ADR-0041m type-awareness).
    """
    root = state_root()
    if not root.is_dir():
        return []
    out: list[Path] = []
    for backend in backends.BACKENDS:
        directory = state.backend_dir(backend)
        if directory.is_dir():
            out.extend(sorted(p for p in directory.glob("*.json") if p.is_file()))
    return out


def _seed_records() -> None:
    """Materialize ``ACQ_STATE_SEED`` records into the state tree (test seam)."""
    raw = os.environ.get(SEED_ENV)
    if raw is None:
        return
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return
    if not isinstance(doc, dict):
        return
    for key, value in doc.items():
        backend, _, name = key.partition("/")
        if not backend or not name:
            continue
        path = state.record_path(backend, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, str):
            path.write_text(value, encoding="utf-8")  # simulate unparseable content
        elif isinstance(value, dict):
            path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def _load_record(path: Path) -> dict:
    """Read + classify one record's schema; raises :class:`MigrationError` to refuse.

    A JSON object without a ``schema`` key is legacy v0 (the tolerated case, to be
    migrated). Anything unparseable, a non-object, or carrying a ``min_reader``
    above this reader is refused (fail closed, ADR-0041m).
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise MigrationError(
            errors.MIGRATION_FAILED,
            f"could not read state record {str(path)!r}",
            "repair the file permissions and retry",
            path=str(path),
            step="read",
        ) from exc
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise MigrationError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            f"state record {str(path)!r} is not valid JSON",
            "the record cannot be migrated; remove it, or recreate the sandbox it describes",
            path=str(path),
        ) from exc
    if not isinstance(doc, dict):
        raise MigrationError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            f"state record {str(path)!r} is not a JSON object",
            "the record cannot be migrated; remove it, or recreate the sandbox it describes",
            path=str(path),
        )
    min_reader = doc.get("min_reader")
    if isinstance(min_reader, int) and not isinstance(min_reader, bool) and min_reader > READER_SCHEMA:
        raise MigrationError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            f"state record {str(path)!r} requires min_reader {min_reader}; "
            f"this reader understands schema {READER_SCHEMA}",
            "upgrade acq to a reader that understands this record's schema",
            path=str(path),
        )
    return doc


def _record_schema(doc: dict, path: Path) -> int:
    """The record's current schema: 0 for a schema-less legacy record, else its int.

    Refuses a non-integer (or bool) marker (fail closed).
    """
    schema = doc.get("schema")
    if schema is None:
        return 0  # legacy v0
    if not isinstance(schema, int) or isinstance(schema, bool):
        raise MigrationError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            f"state record {str(path)!r} carries schema {schema!r}; "
            f"this reader understands schema {READER_SCHEMA}",
            "the record cannot be migrated; remove it, or recreate the sandbox it describes",
            path=str(path),
        )
    return schema


def _verify(path: Path) -> None:
    """Read back a just-migrated record and refuse unless it parses correctly.

    The migration is never reported successful unless this verifies (ADR-0041m):
    the record must be a JSON object whose FIRST field is ``schema`` with the
    target value.
    """
    try:
        verified = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MigrationError(
            errors.MIGRATION_FAILED,
            f"state record {str(path)!r} did not parse back after migration",
            "the prior record has been retained; retry the migration",
            path=str(path),
            step="verify",
        ) from exc
    if not isinstance(verified, dict) or not verified or next(iter(verified)) != "schema":
        raise MigrationError(
            errors.MIGRATION_FAILED,
            f"state record {str(path)!r} did not verify (schema is not the first field)",
            "the prior record has been retained; retry the migration",
            path=str(path),
            step="verify",
        )
    if verified["schema"] != TARGET_SCHEMA:
        raise MigrationError(
            errors.MIGRATION_FAILED,
            f"state record {str(path)!r} did not verify (schema {verified['schema']!r})",
            "the prior record has been retained; retry the migration",
            path=str(path),
            step="verify",
        )


def _atomic_migrate(path: Path, new_doc: dict, old_schema: int) -> None:
    """Migrate one record atomically and non-destructively (ADR-0041m).

    The prior record is **copied** to ``<name>.bak.<old_schema>`` — ``path`` keeps
    holding the valid old record — then the new record is written to a temp file,
    fsynced, and atomically renamed over ``path``. ``path`` therefore always holds
    a valid record (old until the rename, new after), so a crash at any point can
    never orphan a record onto a ``.bak`` sidecar the scanner ignores. On a
    read-back failure the old record is restored; on any earlier failure ``path``
    still holds the old record. Either way a :class:`MigrationError` names the
    path + failed step.
    """
    backup = path.with_name(path.name + f".bak.{old_schema}")
    tmp = path.with_suffix(".json.tmp")
    try:
        shutil.copyfile(path, backup)
    except OSError as exc:
        raise MigrationError(
            errors.MIGRATION_FAILED,
            f"could not back up state record {str(path)!r} (step backup)",
            "the prior record is intact; retry the migration",
            path=str(path),
            step="backup",
        ) from exc
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(new_doc, indent=2, sort_keys=False) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        _remove_sidecars(backup, tmp)
        raise MigrationError(
            errors.MIGRATION_FAILED,
            f"could not migrate state record {str(path)!r} (step write)",
            "the prior record is intact; retry the migration",
            path=str(path),
            step="write",
        ) from exc
    try:
        _verify(path)
    except MigrationError:
        _restore(path, backup, tmp)
        raise
    backup.unlink(missing_ok=True)


def _restore(path: Path, backup: Path, tmp: Path) -> None:
    """Restore the prior record after a failed read-back (best-effort).

    ``path`` holds the new (unverified) record and ``backup`` the prior copy;
    swap the prior back into place and drop the temp file.
    """
    try:
        if backup.exists():
            os.replace(backup, path)
    except OSError:
        pass
    try:
        tmp.unlink()
    except OSError:
        pass


def _remove_sidecars(backup: Path, tmp: Path) -> None:
    """Remove the ``.bak``/``.tmp`` sidecars after a pre-rename failure.

    ``path`` still holds the valid prior record (the rename never happened), so
    the copy and temp file are just dropped.
    """
    try:
        backup.unlink()
    except OSError:
        pass
    try:
        tmp.unlink()
    except OSError:
        pass


def _migrate_record(path: Path, doc: dict) -> bool:
    """Forward-migrate one record in place; return True when it changed.

    A current (``schema == TARGET_SCHEMA``) record is left untouched; a newer
    schema is refused (fail closed).
    """
    old_schema = _record_schema(doc, path)
    if old_schema == TARGET_SCHEMA:
        return False
    if old_schema > TARGET_SCHEMA:
        raise MigrationError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            f"state record {str(path)!r} carries schema {old_schema}; "
            f"this reader understands schema {READER_SCHEMA}",
            "upgrade acq, or remove the record and recreate the sandbox it describes",
            path=str(path),
        )
    # Forward migration: schema becomes the FIRST field, other fields preserved.
    new_doc: dict = {"schema": TARGET_SCHEMA}
    for key, value in doc.items():
        if key != "schema":
            new_doc[key] = value
    _atomic_migrate(path, new_doc, old_schema)
    return True


# ---------------------------------------------------------------------------
# The synchronized pre-step.
# ---------------------------------------------------------------------------

def migrate_tree() -> None:
    """Run the forward migration under the exclusive advisory lock.

    Idempotent and crash-converging: a generation marker at or above the target
    short-circuits the *record* pass; otherwise every sandbox-state record is
    (re)classified and forward-migrated — an already-migrated record is a no-op —
    and the marker is written LAST so a crash mid-migration resumes on the next
    run. ``config.yaml`` is migrated in the same critical section but INDEPENDENT
    of the state generation marker, so a subsequently-legacy config is still
    migrated once the record tree is already current.
    """
    try:
        with lock.exclusive_lock(lock_path()):
            _seed_records()  # materialize the test seam inside the critical section
            config.migrate_config()  # independent of the generation marker
            if read_generation() >= TARGET_SCHEMA:
                return
            for path in iter_records():
                doc = _load_record(path)
                _migrate_record(path, doc)
            write_generation(TARGET_SCHEMA)  # LAST: a generation completes only now
    except lock.MigrationLockTimeout as exc:
        raise MigrationError(
            errors.MIGRATION_LOCKED,
            str(exc),
            "another migration is in progress; retry shortly",
        ) from exc
    except config.ConfigSchemaError as exc:
        raise MigrationError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            "repair or remove config.yaml so its schema marker is readable",
        ) from exc
    except OSError as exc:
        # An unwritable or full state root (creating the lock file, writing the
        # generation marker, the config.yaml step) must fail closed through the
        # error contract, not crash every mutating verb with a traceback.
        # Per-record failures are already MigrationErrors naming their step.
        where = exc.filename or str(state_root())
        raise MigrationError(
            errors.MIGRATION_FAILED,
            f"could not migrate the acq state tree at {str(where)!r}: {exc.strerror or exc}",
            "check that the acq state and config directories are writable and have free space, then retry",
            path=str(where),
        ) from exc
