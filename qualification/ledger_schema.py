"""Version-1 ledger value types and structural validation (ADR-0040)."""

from dataclasses import dataclass
from datetime import date, datetime
import re

from .matrix import MSB, SBX, PLATFORMS, is_claimed

SCHEMA_VERSION = 1
VERDICTS = ("PASS", "FAIL", "BLOCKED", "FLAKY")
_FINAL_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_REV = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
_BINDING = ("oracle", "oracle_sha256")


class LedgerError(ValueError):
    """Malformed ledger or transcript input; the gate fails closed."""


@dataclass(frozen=True)
class Entry:
    backend: str
    platform: str
    verdict: str
    backend_version: str
    os_build: str
    arch: str
    hypervisor: str
    rev: str
    artifact_sha256: str
    recorded_at: str
    transcript_sha256: str
    oracle: str = ""
    oracle_sha256: str = ""


@dataclass(frozen=True)
class Waiver:
    backend: str
    platform: str
    reason: str
    expires: date
    issue: str = ""


@dataclass(frozen=True)
class Ledger:
    entries: tuple[Entry, ...]
    waivers: tuple[Waiver, ...]
    accepted_backend_versions: dict


def _list(doc: dict, key: str) -> list:
    value = doc.get(key, [])
    if not isinstance(value, list):
        raise LedgerError(f"{key!r} must be a list")
    return value


def _text(doc: dict, key: str, where: str) -> str:
    value = doc.get(key)
    if not isinstance(value, str) or not value:
        raise LedgerError(f"{where}: {key!r} must be a non-empty string")
    return value


def _cell(doc: dict, where: str) -> tuple[str, str]:
    backend, platform = _text(doc, "backend", where), _text(doc, "platform", where)
    if backend not in (MSB, SBX) or platform not in PLATFORMS:
        raise LedgerError(f"{where}: unknown cell {backend}/{platform}")
    return backend, platform


def _parse_entry(doc: dict, index: int) -> Entry:
    where = f"entries[{index}]"
    if not isinstance(doc, dict):
        raise LedgerError(f"{where}: must be an object")
    _cell(doc, where)
    present = [field for field in _BINDING if field in doc]
    if present and len(present) != len(_BINDING):
        raise LedgerError(f"{where}: oracle and oracle_sha256 must be given together")
    fields = [f for f in Entry.__dataclass_fields__ if f not in _BINDING or present]
    entry = Entry(**{field: _text(doc, field, where) for field in fields})
    if not _REV.fullmatch(entry.rev):
        raise LedgerError(f"{where}: rev must be a full 40- or 64-hex commit id")
    # One spelling per hash keeps the duplicate check unambiguous.
    if not _SHA256.fullmatch(entry.transcript_sha256):
        raise LedgerError(f"{where}: transcript_sha256 must be 64 lowercase hex digits")
    if present and not _SHA256.fullmatch(entry.oracle_sha256):
        raise LedgerError(f"{where}: oracle_sha256 must be 64 lowercase hex digits")
    if entry.verdict not in VERDICTS:
        raise LedgerError(f"{where}: verdict must be one of {VERDICTS}")
    try:
        if datetime.fromisoformat(entry.recorded_at).tzinfo is None:
            raise ValueError
    except ValueError:
        raise LedgerError(f"{where}: recorded_at must be ISO 8601 with a timezone") from None
    return entry


def _parse_waiver(doc: dict, index: int) -> Waiver:
    where = f"waivers[{index}]"
    if not isinstance(doc, dict):
        raise LedgerError(f"{where}: must be an object")
    backend, platform = _cell(doc, where)
    if not is_claimed(backend, platform):
        raise LedgerError(f"{where}: {backend}/{platform} is not a claimed cell; nothing to waive")
    try:
        expires = date.fromisoformat(_text(doc, "expires", where))
    except ValueError:
        raise LedgerError(f"{where}: expires must be YYYY-MM-DD") from None
    return Waiver(backend, platform, _text(doc, "reason", where), expires, str(doc.get("issue") or ""))


def parse_ledger(doc: object) -> Ledger:
    """Validate a decoded ledger document without changing its public schema."""
    if not isinstance(doc, dict) or doc.get("schema_version") != SCHEMA_VERSION:
        raise LedgerError(f"schema_version must be {SCHEMA_VERSION}")
    versions = doc.get("accepted_backend_versions", {})
    if not isinstance(versions, dict) or not all(
        k in (MSB, SBX) and isinstance(v, str) and _FINAL_VERSION.fullmatch(v) for k, v in versions.items()
    ):
        raise LedgerError("accepted_backend_versions must map msb/sbx to final X.Y.Z versions")
    entries = tuple(_parse_entry(e, i) for i, e in enumerate(_list(doc, "entries")))
    seen: dict[str, int] = {}
    for i, entry in enumerate(entries):
        if entry.transcript_sha256 in seen:
            raise LedgerError(
                f"entries[{i}]: transcript_sha256 is already recorded by entries[{seen[entry.transcript_sha256]}]"
            )
        seen[entry.transcript_sha256] = i
    return Ledger(entries, tuple(_parse_waiver(w, i) for i, w in enumerate(_list(doc, "waivers"))), dict(versions))
