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

The generation marker counts tree-level steps, independently of the record
schema: generation 1 is the record schema pass above; generation 2 imports the
Bash acq's state (:mod:`acq_py.legacy_bash`) so sandboxes, trusted kit sources
and provider-credential bindings it created keep working. The import only ever
creates Python records that do not exist yet and never deletes or rewrites a
Bash file, so it is safe to repeat; a tree already marked generation 1 is
scanned again. Each part of it (sandboxes, kit sources, bindings) runs once per
tree and is recorded in the marker when complete: a record removed afterwards
with this acq (``rm``, ``kit-source rm``, ``provider-credential rm``) is not
brought back from the Bash files left behind. A ``config.yaml`` list Bash itself
would refuse leaves its part pending, retried on each mutating verb (its warning
is printed again only when it changes), and the tree stays at generation 1 until
the list is fixed and imported.

``ACQ_STATE_SEED`` is an internal test seam (never a secret, never written to
output): a JSON object mapping ``"<backend>/<name>"`` to a record (a dict is
serialized as JSON; a string is written verbatim, to simulate an unparseable
record) that is materialized into the state tree before migration runs, so a
single-invocation contract vector can seed legacy/newer/unparseable records.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
from collections.abc import Callable
from pathlib import Path

from . import (
    backends,
    config,
    errors,
    kits,
    legacy_bash,
    lock,
    provider_creds,
    state,
    userdirs,
)

# The tree generation this reader migrates records TO, and the schema level this
# reader itself understands. All record types currently write ``schema=1``; if a
# record type diverges in its own schema number space, the migration must become
# type-aware rather than treating every record as one schema space.
TARGET_SCHEMA = state.STATE_SCHEMA
READER_SCHEMA = state.STATE_SCHEMA

# The tree generation a completed migration declares (see the module docstring):
# 1 = records at TARGET_SCHEMA, 2 = the Bash acq's state imported.
RECORDS_GENERATION = 1
TARGET_GENERATION = 2

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


def _read_marker() -> dict:
    try:
        doc = json.loads(generation_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return doc if isinstance(doc, dict) else {}


def read_import_done() -> set[str]:
    """The parts of the generation-2 Bash import already complete (see :func:`import_bash_state`)."""
    done = _read_marker().get("bash_import_done")
    return {p for p in done if isinstance(p, str)} if isinstance(done, list) else set()


def read_import_warned() -> str | None:
    """The digest of the pending import's warnings last printed, if any (see :func:`import_bash_state`)."""
    warned = _read_marker().get("bash_import_warned")
    return warned if isinstance(warned, str) else None


def read_import_warnings() -> list[str]:
    """The warnings the pending import last printed (``acq doctor`` shows them again).

    Redacted again on the way out (:func:`legacy_bash.redact`), so a marker
    written by an acq that did not redact never shows a credential.
    """
    warnings = _read_marker().get("bash_import_warnings")
    return [legacy_bash.redact(w) for w in warnings if isinstance(w, str)] if isinstance(warnings, list) else []


def import_started() -> bool:
    """True once a generation-2 import has run and left something in the marker (see :func:`import_bash_state`)."""
    marker = _read_marker()
    return any(key in marker for key in ("bash_import_done", "bash_import_warned", "bash_import_warnings"))


def import_parts() -> tuple[str, ...]:
    """The parts of the generation-2 import, in the order they run."""
    return tuple(_IMPORT_PARTS)


def write_generation(generation: int, *, import_done: set[str] | None = None,
                     import_warned: str | None = None, import_warnings: list[str] | None = None) -> None:
    """Write the marker atomically (temp + fsync + rename); called LAST.

    ``import_done`` records which parts of a not yet finished generation-2 import
    are complete, so they are not run again; ``import_warned`` the digest of the
    warnings that import last printed, so the same ones are not printed again,
    and ``import_warnings`` their text, which ``acq doctor`` reports while the
    import stays pending (a mutating command prints them only once). The
    warnings name paths and Bash config values; URL credentials in those values
    are redacted when a warning is raised (:func:`legacy_bash.warn`) and again
    here, before the text is written.
    """
    path = generation_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    doc: dict = {"schema": state.STATE_SCHEMA, "generation": generation}
    if import_done:
        doc["bash_import_done"] = sorted(import_done)
    if import_warned:
        doc["bash_import_warned"] = import_warned
    if import_warnings:
        doc["bash_import_warnings"] = [legacy_bash.redact(w) for w in import_warnings]
    data = json.dumps(doc, indent=2)
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
# Generation 2: import the Bash acq's state.
# ---------------------------------------------------------------------------

def _import_kit_sources() -> tuple[int, bool]:
    """Import ``config.yaml`` ``kit_sources``; returns ``(records created, complete)``.

    The control plane is never registered (it is the shipped pin). An entry
    whose ref is not a full commit SHA, including an unpinned one, is skipped
    with a warning: this acq only trusts immutable refs, and a registered source
    without a ref would trust the whole repository. A list that cannot be parsed
    is not complete: it is retried, with a warning, until it is fixed.
    """
    try:
        entries = legacy_bash.kit_sources()
    except legacy_bash.LegacyParseError as exc:
        legacy_bash.warn(f"config.yaml kit_sources was not imported: {exc}; fix it to import it")
        return 0, False
    created = 0
    for repo, ref, directory in entries:
        if kits.is_control_plane(repo):
            continue
        if not kits.is_full_ref(ref):
            legacy_bash.warn(
                f"kit source '{repo}' was not imported: ref {legacy_bash.shown_ref(ref)} is not a full commit SHA; "
                f"run 'acq kit-source add {repo} --ref <full-sha>' to trust it"
            )
            continue
        created += kits.import_source(repo, ref, directory)
    return created, True


def _import_provider_bindings() -> tuple[int, bool]:
    """Import ``config.yaml`` ``provider_credential_bindings``; returns ``(created, complete)``."""
    try:
        bindings = legacy_bash.provider_credential_bindings()
    except legacy_bash.LegacyParseError as exc:
        legacy_bash.warn(f"config.yaml provider_credential_bindings was not imported: {exc}; fix it to import it")
        return 0, False
    return sum(provider_creds.import_binding(p, k, h) for p, k, h in bindings), True


def _import_sandbox(sandbox: legacy_bash.BashSandbox) -> bool:
    """Create the Python record for one Bash sandbox; True when it was created.

    A sandbox the Bash acq knows nothing useful about (no agent, no workspace:
    a create that never finished) is skipped. The recorded bundle ref and
    provider selection are carried over only to a record this import created (``imported_from: bash``), so it
    never describes a different sandbox that this acq already has under the same
    name; it is retried for such a record, in case a crash came between the two.
    """
    if sandbox.agent is None and sandbox.workspace is None:
        return False
    fields: dict = {"agent": sandbox.agent, "workspace": sandbox.workspace}
    if sandbox.ro_host_config:
        fields["ro_host_config"] = True
    if sandbox.ssh_auth_sock:
        fields["ssh_auth_sock"] = sandbox.ssh_auth_sock
    fields["imported_from"] = "bash"
    created = state.record_import(sandbox.backend, sandbox.name, fields)
    selection: dict = {}
    if sandbox.provider_selection:  # so start and kit update keep what Bash created it with
        selection["provider_selection"] = sandbox.provider_selection
        if sandbox.provider_kits:
            selection["provider_kits"] = sandbox.provider_kits
    if (sandbox.applied_ref or selection) and (created or _imported_record(sandbox.backend, sandbox.name)):
        kits.provenance_import(sandbox.backend, sandbox.name, sandbox.applied_ref, sandbox.applied_at, selection)
    return created


def _imported_record(backend: str, name: str) -> bool:
    """True when the sandbox's existing record is one this import created."""
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError:
        return False
    return record is not None and record.get("imported_from") == "bash"


def _import_sandboxes(done: set[str]) -> tuple[int, bool]:
    """Import every Bash sandbox; returns ``(created, complete)``.

    A Bash backend directory that cannot be read leaves the part pending (with
    a warning naming it), so the sandboxes in it are imported once it can be,
    rather than the part completing with them missing. Each backend that
    imports fully adds its own ``sandboxes:<backend>`` mark to ``done`` and is
    never imported again, so while another backend keeps the part pending, a
    record removed afterwards is not brought back.
    """
    created = 0
    complete = True
    for backend in backends.BACKENDS:
        mark = f"sandboxes:{backend}"
        if mark in done:
            continue
        try:
            names = legacy_bash.sandbox_names(backend)
        except OSError as exc:
            where = f" {str(exc.filename)!r}" if exc.filename else ""
            legacy_bash.warn(
                f"the Bash acq's {backend} sandbox records were not imported: cannot read their "
                f"directory{where} ({exc.strerror or exc}); fix its permissions to import them"
            )
            complete = False
            continue
        for name in names:
            created += _import_sandbox(legacy_bash.read_sandbox(backend, name))
        done.add(mark)
    return created, complete


# The parts of the import, each completed (and recorded in the marker) on its
# own. A part may add finer marks of its own to the ``done`` set it is given.
_IMPORT_PARTS: dict[str, Callable[[set[str]], tuple[int, bool]]] = {
    "sandboxes": _import_sandboxes,
    "kit_sources": lambda done: _import_kit_sources(),
    "provider_credentials": lambda done: _import_provider_bindings(),
}


def import_bash_state() -> bool:
    """Import the Bash acq's state into this acq's records; True when every part is complete.

    Idempotent: only records that do not exist yet are created, and no Bash file
    is changed. A Bash value its own readers would refuse is skipped with a
    warning. Each part is recorded in the marker once complete and never runs
    again, so a record removed afterwards is not brought back; a config list
    that cannot be parsed leaves its part pending, to be imported once fixed.

    A pending part is retried on every mutating command, but its warnings are
    printed only when they differ from the ones printed last (a digest of them
    is kept in the marker): the same unfixed list does not warn on every
    command, and a change to it, or to what else is pending, warns again.
    """
    done = read_import_done()
    counts = {part: 0 for part in _IMPORT_PARTS}
    with legacy_bash.collecting_warnings() as warnings:
        for part, run in _IMPORT_PARTS.items():
            if part in done:
                continue
            before = set(done)
            counts[part], complete = run(done)
            if complete:  # the part's own mark covers its finer ones
                done.difference_update({mark for mark in done if mark.startswith(f"{part}:")})
                done.add(part)
            if done != before:
                write_generation(RECORDS_GENERATION, import_done=done, import_warned=read_import_warned(),
                                 import_warnings=read_import_warnings())
    finished = done >= set(_IMPORT_PARTS)
    _report_import_warnings(warnings, done, pending=not finished)
    if any(counts.values()):
        print(
            f"acq: imported {counts['sandboxes']} sandbox record(s), {counts['kit_sources']} kit "
            f"source(s) and {counts['provider_credentials']} provider-credential binding(s) "
            "from the Bash acq's state",
            file=sys.stderr,
        )
    return finished


def _report_import_warnings(warnings: list[str], done: set[str], *, pending: bool) -> None:
    """Print the import's warnings, unless a pending import printed exactly these last time.

    A finished import prints whatever it collected (each such warning comes from
    a part that runs once). A pending one compares a digest of its warnings
    with the one in the marker, and records the new digest, and the warnings
    themselves for ``acq doctor``, when they differ. A marker that has the
    digest but not the text (written before the text was kept) gets the text
    without printing anything again.
    """
    if not pending:
        for message in warnings:
            legacy_bash.warn(message)
        return
    digest = hashlib.sha256("\n".join(warnings).encode("utf-8")).hexdigest() if warnings else None
    if digest == read_import_warned():
        if warnings and read_import_warnings() != warnings:
            write_generation(RECORDS_GENERATION, import_done=done, import_warned=digest, import_warnings=warnings)
        return
    for message in warnings:
        legacy_bash.warn(message)
    write_generation(RECORDS_GENERATION, import_done=done, import_warned=digest, import_warnings=warnings)


# ---------------------------------------------------------------------------
# The synchronized pre-step.
# ---------------------------------------------------------------------------

def _migrate_generations(generation: int) -> None:
    """Apply every tree step above ``generation``, writing the marker after each."""
    if generation < RECORDS_GENERATION:
        for path in iter_records():
            doc = _load_record(path)
            _migrate_record(path, doc)
        write_generation(RECORDS_GENERATION)  # LAST: a generation completes only now
    if generation < TARGET_GENERATION and import_bash_state():
        write_generation(TARGET_GENERATION)


def migrate_tree() -> None:
    """Run the forward migration under the exclusive advisory lock.

    Idempotent and crash-converging: each tree step at or below the marker is
    skipped. Below generation 1 every sandbox-state record is (re)classified and
    forward-migrated (an already-migrated record is a no-op); below generation 2
    the Bash acq's state is imported. Each step writes the marker LAST, so a crash
    mid-step resumes on the next run. ``config.yaml`` is migrated in the same
    critical section but INDEPENDENT of the state generation marker, so a
    subsequently-legacy config is still migrated once the record tree is already
    current.
    """
    try:
        with lock.exclusive_lock(lock_path()):
            _seed_records()  # materialize the test seams inside the critical section
            config.seed_config()
            config.migrate_config()  # independent of the generation marker
            _migrate_generations(read_generation())
    except lock.MigrationLockTimeout as exc:
        raise MigrationError(
            errors.MIGRATION_LOCKED,
            str(exc),
            "another migration is in progress; retry shortly",
        ) from exc
    except config.ConfigLockTimeout as exc:
        # An OSError too, but a lock wait, not an unwritable directory: the
        # message names the lock (and, for a leftover one, how to remove it).
        raise MigrationError(
            errors.MIGRATION_FAILED,
            str(exc),
            "wait for the other acq command that is changing config.yaml to finish, then retry",
        ) from exc
    except config.ConfigMigrationError as exc:
        raise MigrationError(errors.MIGRATION_FAILED, str(exc), exc.remediation) from exc
    except config.ConfigSchemaError as exc:
        raise MigrationError(
            errors.STATE_SCHEMA_UNSUPPORTED,
            str(exc),
            "repair or remove config.yaml so its schema marker is readable",
        ) from exc
    except userdirs.UserDirError as exc:
        raise MigrationError(errors.MIGRATION_FAILED, exc.message, exc.remediation) from exc
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
