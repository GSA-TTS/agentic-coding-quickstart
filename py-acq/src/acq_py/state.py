"""Orchestrator-owned sandbox state records (ADR-0041m).

acq owns the migration of acq-hosted records; each durable record carries its own
integer state-schema version as the FIRST field (``schema=N``, reusing the legacy
provenance ``schema=1``). This slice writes schema=1 records; the full forward-only
migration machinery (generation marker, OS advisory lock, refusal of
newer/unparseable records) lands with the state-migration slice.

The record is host-authoritative (ADR-0040m §trust ownership, ADR-0035): acq
writes it on the host, keyed by backend + sandbox name, and never reads
guest-writable state back to configure a sandbox. Backend-native state (the msb
catalog) is never migrated or treated as authority here.

The on-disk format is internal (non-public); only the ``schema`` marker and the
semantic fields below are stable. ``schema`` is always the first key so a
consumer can read the version marker before touching any other field.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

# State-schema version of the records this slice writes (ADR-0041m). Distinct
# from the structured-output ``schema_version`` in ``envelope.py``.
STATE_SCHEMA = 1


class StateSchemaError(Exception):
    """A record carries a state-schema this reader cannot read (ADR-0041m).

    Raised for a newer-than-this-reader or non-integer schema, or an unparseable
    record. The reader refuses rather than misreads; a schema-less (legacy v0)
    record is the one tolerated case and is reported as absent (forward migration
    is the state-migration slice's job).
    """


# The sandbox name reaches a filesystem path, so it is sanitized to a safe
# filename charset (defense-in-depth). A short checksum of the RAW name is
# appended so two distinct names that sanitize to the same string (e.g. "a/b" and
# "a_b") never alias onto one record.
_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")


def state_dir() -> Path:
    """Resolve the acq state root (host-side).

    Precedence: ``ACQ_STATE_DIR``, else ``XDG_STATE_HOME``, else
    ``$HOME/.local/state``, under an ``acq`` subdirectory (ADR-0041m:
    orchestrator-owned records; the layout is not constrained by the legacy
    implementation).
    """
    override = os.environ.get("ACQ_STATE_DIR")
    if override:
        return Path(override)
    base = os.environ.get("XDG_STATE_HOME")
    if not base:
        home = os.environ.get("HOME") or str(Path.home())
        base = os.path.join(home, ".local", "state")
    return Path(base) / "acq"


def _safe(token: str) -> str:
    return _SAFE_RE.sub("_", token)


def _checksum(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def record_path(backend: str, name: str) -> Path:
    """Path to one sandbox's state record, keyed by backend + sandbox name."""
    return state_dir() / _safe(backend) / f"{_safe(name)}.{_checksum(name)}.json"


def record_write(
    backend: str,
    name: str,
    *,
    agent: str | None,
    workspace: str | None,
    image: str | None = None,
    created_at: str | None = None,
) -> dict:
    """Write (atomically) a sandbox's host-authoritative state record.

    Call ONLY after the backend reports the sandbox created and exec-ready. The
    write is temp-file + fsync + rename so a crash cannot leave a half-written
    record (ADR-0041m atomic, non-destructive). ``schema`` is the first field.
    """
    doc: dict = {
        "schema": STATE_SCHEMA,
        "name": name,
        "backend": backend,
        "agent": agent,
        "workspace": workspace,
    }
    if image:
        doc["image"] = image
    if created_at:
        doc["created_at"] = created_at

    path = record_path(backend, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    data = json.dumps(doc, indent=2, sort_keys=False)
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return doc


def _record_from_path(path: Path, *, strict: bool, label: str) -> dict | None:
    """Read one record from ``path``.

    Returns the record dict when its ``schema`` is exactly ``STATE_SCHEMA``.

    * ``strict=True`` raises :class:`StateSchemaError` for a newer/unknown schema
      or unparseable content (the re-attach path refuses rather than misread).
    * ``strict=False`` returns ``None`` for anything unreadable, so a read-only
      diagnostic (``ls``) skips it rather than surfacing it as understood.

    A schema-less record is legacy v0 in both modes: it returns ``None`` (forward
    migration is the state-migration slice's job).
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        if strict:
            raise StateSchemaError(f"state record for {label!r} is not valid JSON") from exc
        return None
    if not isinstance(doc, dict):
        if strict:
            raise StateSchemaError(f"state record for {label!r} is not a JSON object")
        return None
    schema = doc.get("schema")
    if schema is None:
        return None  # legacy v0 (no marker)
    if not isinstance(schema, int) or schema != STATE_SCHEMA:
        if strict:
            raise StateSchemaError(
                f"state record for {label!r} carries schema {schema!r}; "
                f"this reader understands schema {STATE_SCHEMA}"
            )
        return None
    return doc


def record_read(backend: str, name: str) -> dict | None:
    """Read a sandbox's state record (strict).

    Returns the record when its schema is ``STATE_SCHEMA``, or ``None`` when the
    record is absent or legacy v0. Raises :class:`StateSchemaError` for a
    newer/unknown schema or unparseable content (ADR-0041m fail-closed).
    """
    return _record_from_path(record_path(backend, name), strict=True, label=name)


def record_remove(backend: str, name: str) -> None:
    """Remove a sandbox's state record (best-effort; a missing record is a no-op)."""
    try:
        record_path(backend, name).unlink()
    except OSError:
        pass


def list_records(backend: str) -> list[dict]:
    """List every readable (schema ``STATE_SCHEMA``) record for a backend.

    Sorted by record path. Newer/unknown-schema and unparseable records are
    skipped (ADR-0041m: read-only diagnostics may report ``unknown`` rather than
    misread); a schema-less legacy record is likewise skipped.
    """
    root = state_dir() / _safe(backend)
    out: list[dict] = []
    if not root.is_dir():
        return out
    for path in sorted(root.glob("*.json")):
        label = f"{backend}/{path.stem}"
        record = _record_from_path(path, strict=False, label=label)
        if record is not None:
            out.append(record)
    return out
