"""``acq doctor`` check assembly (ADR-0038m §doctor).

``doctor`` reports an overall ``status`` and a list of checks, each carrying a
stable ``id``, a per-check ``status``, a human ``message``, and an optional
``remediation``. The compatibility contract fixes the *shape* — overall status
plus per-check id/status/message/remediation, stable IDs, actionable
remediation — but not the concrete list of checks; that inventory grows as the
backend adapters land (ADR-0040m ``doctor``).

Status vocabulary (stable tokens, one scale for both overall and per-check):
    * ``pass`` — healthy
    * ``warn`` — degraded
    * ``fail`` — failed

The overall ``status`` is derived from the checks: ``fail`` (any fail) outranks
``warn`` (any warn) outranks ``pass``.

The checks are the managed runtime (ADR-0042m), backend-adapter availability
(ADR-0040m), state-tree migration health, the ``config.yaml`` schema marker
and persisted backend (ADR-0041m, ADR-0038m), and a pending import of the Bash
acq's state (ADR-0041m). All are deterministic, read-only
and never touch the network, so ``doctor`` is a safe diagnostic in any context.
"""

from __future__ import annotations

from . import backends, config, migration, runtime, userdirs

PASS = "pass"  # nosec B105 # a check status
WARN = "warn"
FAIL = "fail"


def runtime_check() -> dict:
    """Report whether acq can resolve the runtime it executes subprocesses with.

    ``resolve_runtime`` never downloads and always returns a usable interpreter
    — the app-private managed bundle or the documented IT-approved base
    interpreter fallback — so this check is ``pass`` in both cases and records
    the supplier in the message (ADR-0042m).
    """
    rt = runtime.resolve_runtime()
    if rt.managed:
        message = f"app-private runtime present ({rt.supplier})"
    else:
        message = "using the IT-approved base interpreter (no app-private runtime bundle present)"
    return {"id": "runtime", "status": PASS, "message": message}


def backend_check() -> dict:
    """Report backend-adapter availability.

    No adapter is present in this slice, so sandbox and backend commands are
    unavailable. That is a ``warn`` (degraded) condition, not a failure: ``acq``
    itself still runs. The ID is stable; a later adapter slice reuses it and
    reports the active backend instead.
    """
    return {
        "id": "backend",
        "status": WARN,
        "message": "no sandbox backend adapter is available",
        "remediation": "backend adapters ship in a later slice; sandbox commands are unavailable in this build",
    }


def doctor_checks() -> list[dict]:
    """Return the ordered check list for the current build."""
    return [runtime_check(), backend_check(), state_check(), config.doctor_check(), persisted_backend_check(),
            bash_import_check()]


def bash_import_check() -> dict:
    """Report an import of the Bash acq's state that ran and is not finished (ADR-0041m).

    A pending part is retried on every mutating command, but its warnings are
    printed only when they change, so after the first time nothing says the
    import is stuck. This check says so, with the warnings it last printed.
    An import that has not run yet (no mutating command since this acq was
    installed) runs with the next one, and passes. Read-only, like every check.
    """
    try:
        generation = migration.read_generation()
        started = migration.import_started()
        done = migration.read_import_done()
        warnings = migration.read_import_warnings()
    except userdirs.UserDirError as exc:
        return {"id": "bash-import", "status": FAIL, "message": exc.message, "remediation": exc.remediation}
    if generation >= migration.TARGET_GENERATION:
        return {"id": "bash-import", "status": PASS, "message": "the Bash acq's state is imported (or there was none)"}
    if generation < migration.RECORDS_GENERATION or not started:
        return {"id": "bash-import", "status": PASS,
                "message": "the Bash acq's state is imported by the next mutating acq command"}
    pending = [part for part in migration.import_parts() if part not in done]
    message = f"the import of the Bash acq's state is not finished ({', '.join(pending) or 'unknown'} pending)"
    if warnings:
        message += ": " + "; ".join(warnings)
    return {
        "id": "bash-import",
        "status": WARN,
        "message": message,
        "remediation": "fix what the message names, then run any mutating acq command (create, rm, secret set) "
        "to import the rest",
    }


def persisted_backend_check() -> dict:
    """Report the ``backend:`` value ``backend set`` persists in config.yaml.

    An unknown value fails the check: every verb that needs a backend refuses
    while it is there (it is never skipped in favour of auto-detect).
    """
    value = config.read_field("backend")  # an unresolvable config path reads as None
    if value is None:
        return {"id": "config-backend", "status": PASS, "message": "no persisted backend; acq auto-detects"}
    if value not in backends.BACKENDS:
        return {
            "id": "config-backend",
            "status": FAIL,
            "message": f"config.yaml sets an unknown backend: {value!r} (expected sbx or msb)",
            "remediation": "run 'acq backend set msb' or 'acq backend set sbx' (or 'acq backend unset' to auto-detect)",
        }
    return {"id": "config-backend", "status": PASS, "message": f"persisted backend: {value}"}


def state_check() -> dict:
    """Report state-tree migration health (read-only; ADR-0041m).

    ``doctor`` is a diagnostic and does NOT migrate: it reports the current tree
    state so a newer/unparseable record is surfaced (``fail``) and a legacy v0
    record is flagged (``warn``) as "will migrate forward on the next mutating
    verb", rather than being silently skipped. An unresolvable state root (a
    relative ``ACQ_STATE_DIR``, or no absolute home to fall back to) or a relative
    path override is reported as a failed check rather than raised, so the
    diagnostic still completes.
    """
    try:
        generation = migration.read_generation()
        records = list(migration.iter_records())
        userdirs.check_path_overrides()
    except userdirs.UserDirError as exc:
        return {"id": "state", "status": FAIL, "message": exc.message, "remediation": exc.remediation}
    newer: list[str] = []
    legacy: list[str] = []
    for path in records:
        try:
            doc = migration._load_record(path)
        except migration.MigrationError:
            newer.append(path.name)
            continue
        schema = doc.get("schema")
        if schema is None:
            legacy.append(path.name)
        elif isinstance(schema, int) and not isinstance(schema, bool) and schema > migration.TARGET_SCHEMA:
            newer.append(path.name)
    if newer:
        return {
            "id": "state",
            "status": FAIL,
            "message": f"state tree has {len(newer)} record(s) this reader cannot read "
            f"(generation {generation})",
            "remediation": "upgrade acq, or remove the offending record(s) and recreate "
            "the sandboxes they describe",
        }
    if legacy:
        return {
            "id": "state",
            "status": WARN,
            "message": f"state tree has {len(legacy)} legacy v0 record(s) to migrate forward "
            f"(generation {generation})",
            "remediation": "run any mutating acq command; records migrate forward in place",
        }
    return {"id": "state", "status": PASS, "message": f"state tree migrated (generation {generation})"}


def overall_status(checks: list[dict]) -> str:
    """Derive the overall status from per-check statuses.

    ``fail`` (any fail) outranks ``warn`` (any warn) outranks ``pass``.
    """
    statuses = {check["status"] for check in checks}
    if FAIL in statuses:
        return FAIL
    if WARN in statuses:
        return WARN
    return PASS


def doctor_data() -> dict:
    """Assemble the ``doctor`` command's required result data (ADR-0038m)."""
    checks = doctor_checks()
    return {"status": overall_status(checks), "checks": checks}
