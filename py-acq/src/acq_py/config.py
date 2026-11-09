"""Host-authoritative ``config.yaml`` schema marker (ADR-0038m §config, ADR-0041m).

The legacy Bash ``acq`` persists user configuration at
``${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml`` with no version marker.
ADR-0041m adds a flat ``schema:`` key as the first line so a reader can detect the
version before touching any other key, and migrates a schema-less (legacy v0)
config forward in place. This module owns that marker and the forward migration;
the full config-key surface (``configure``) is a separate slice.

There is deliberately **no** YAML dependency: the flat ``schema:`` marker is read
and written line-wise, so ordinary operation stays stdlib-only and offline
(ADR-0042m). Unknown keys are preserved verbatim; only the leading ``schema:``
line is added on forward migration.

``config.yaml`` lives in the config tree (``XDG_CONFIG_HOME``), distinct from the
state tree the record/generation machinery migrates (ADR-0041m: orchestrator-owned
state). Both carry their own ``schema`` marker; the two never share a number space
with the structured-output ``schema_version`` in ``envelope.py``.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from . import userdirs

CONFIG_SCHEMA = 1

# A flat ``schema:`` key: column 0, a single integer token, optional trailing
# comment. Nested/indented keys and ``schema_version:`` are deliberately NOT
# matched — this marker is the flat top-level key, not the result-schema version.
_SCHEMA_LINE_RE = re.compile(r"^schema:\s*([0-9]+)\s*(?:#.*)?$")


class ConfigSchemaError(Exception):
    """``config.yaml`` carries a schema this reader cannot read (ADR-0041m).

    Raised for a newer-than-this-reader or non-integer ``schema`` marker. A
    schema-less (legacy v0) config is the one tolerated case and is migrated
    forward rather than misread.
    """


def config_path() -> Path:
    """Resolve the acq config file (ADR-0038m §config path).

    An empty or relative ``XDG_CONFIG_HOME`` is ignored as the XDG Base Directory
    specification requires, falling back to ``$HOME/.config`` (see
    :mod:`userdirs`).
    """
    return userdirs.xdg_base("XDG_CONFIG_HOME", ".config") / "acq" / "config.yaml"


def _read_raw() -> str | None:
    try:
        return config_path().read_text(encoding="utf-8")
    except OSError:
        return None


def config_schema() -> int | None:
    """Read the flat ``schema`` marker: its value, or ``None`` when absent/legacy.

    Raises :class:`ConfigSchemaError` for a newer or non-integer marker
    (fail-closed, ADR-0041m).
    """
    raw = _read_raw()
    if raw is None:
        return None
    for line in raw.splitlines():
        match = _SCHEMA_LINE_RE.match(line)
        if match:
            value = int(match.group(1))
            if value != CONFIG_SCHEMA:
                raise ConfigSchemaError(
                    f"config.yaml carries schema {value}; this reader understands "
                    f"schema {CONFIG_SCHEMA}"
                )
            return value
    return None  # legacy v0 (no marker)


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".yaml.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def migrate_config() -> str:
    """Forward-migrate ``config.yaml`` to add the flat ``schema:`` marker.

    Returns ``"none"`` (absent or already current) or ``"migrated"``. Non-destructive
    until verified: the prior file is retained as ``config.yaml.bak.0`` until the
    rewritten file parses back with the correct marker, then deleted. On a
    read-back failure the original is restored and the path + failed step are
    reported.

    Raises :class:`ConfigSchemaError` for a newer/non-integer marker.
    """
    raw = _read_raw()
    if raw is None:
        return "none"
    try:
        current = config_schema()
    except ConfigSchemaError:
        raise
    if current == CONFIG_SCHEMA:
        return "none"

    # Legacy v0: prepend the marker as the first line (schema is the first field).
    body = raw.rstrip("\n")
    migrated = f"schema: {CONFIG_SCHEMA}\n" + (body + "\n" if body else "")

    path = config_path()
    backup = path.with_name(path.name + ".bak.0")
    tmp = path.with_suffix(".yaml.tmp")
    step = "write"
    try:
        if path.exists():
            os.replace(path, backup)
        step = "write"
        _atomic_write(path, migrated)
        step = "verify"
        verified = path.read_text(encoding="utf-8")
        if _SCHEMA_LINE_RE.match(verified.splitlines()[0] or "") is None or config_schema() != CONFIG_SCHEMA:
            raise ConfigSchemaError(f"config.yaml did not verify after migration (step {step})")
        backup.unlink(missing_ok=True)
    except ConfigSchemaError:
        _restore(path, backup, tmp)
        raise
    except OSError as exc:
        _restore(path, backup, tmp)
        raise ConfigSchemaError(
            f"config.yaml migration failed at step {step!r}: {path} ({exc})"
        ) from exc
    return "migrated"


def _restore(path: Path, backup: Path, tmp: Path) -> None:
    """Best-effort restore of the prior config after a failed migration."""
    try:
        if backup.exists():
            os.replace(backup, path)
    except OSError:
        pass
    try:
        tmp.unlink()
    except OSError:
        pass


def doctor_check() -> dict:
    """Report config-schema health for ``acq doctor`` (read-only)."""
    try:
        current = config_schema()
    except ConfigSchemaError as exc:
        return {
            "id": "config-schema",
            "status": "fail",
            "message": str(exc),
            "remediation": "remove or repair config.yaml so its schema marker is readable",
        }
    if current is None:
        return {
            "id": "config-schema",
            "status": "warn",
            "message": "config.yaml is a legacy schema-less (v0) config",
            "remediation": "run any acq command; config.yaml is migrated forward in place",
        }
    return {"id": "config-schema", "status": "pass", "message": f"config.yaml schema {current}"}
