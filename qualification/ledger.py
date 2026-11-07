"""The Tier-3 transcript ledger (ADR-0044m).

A committed JSON file of metadata and hashes about recorded live runs: never the
transcripts themselves (those are attached to a release, not committed) and never
a secret. The release gate (:mod:`qualification.gate`) reads it to decide whether
each claimed cell holds a current green transcript.

Besides ``entries`` it holds ``waivers`` (a claimed cell the maintainer has
explicitly accepted without a current transcript, each with a reason and a
mandatory expiry) and ``accepted_backend_versions`` (the backend versions under
acceptance; moving one past a transcript's ``major.minor`` expires it).

It lives outside the Tier-3 surface so recording a run never expires the runs it
records.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from datetime import date, datetime
from pathlib import Path

from .matrix import MSB, PLATFORMS, SBX, is_claimed

SCHEMA_VERSION = 1
DEFAULT_LEDGER = "docs/qualification-ledger.json"
VERDICTS = ("PASS", "FAIL", "BLOCKED", "FLAKY")
_FINAL_VERSION = re.compile(r"\d+\.\d+\.\d+")

_PLATFORM_TOKENS = {
    ("Darwin", "arm64"): "macos-arm64",
    ("Darwin", "x86_64"): "macos-x86_64",
    ("Linux", "x86_64"): "linux-x86_64",
    ("Linux", "aarch64"): "linux-aarch64",
    ("Linux", "arm64"): "linux-aarch64",
    ("Windows", "x86_64"): "windows-x64",
    ("Windows", "AMD64"): "windows-x64",
}


class LedgerError(ValueError):
    """The ledger (or a transcript offered to it) is malformed. The gate fails closed."""


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


def platform_token(os_name: str, arch: str) -> str:
    """The matrix platform token for a harness ``os``/``arch`` pair."""
    try:
        return _PLATFORM_TOKENS[(os_name, arch)]
    except KeyError:
        raise LedgerError(f"cannot derive a platform from os={os_name!r} arch={arch!r}; pass --platform") from None


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
    entry = Entry(**{field: _text(doc, field, where) for field in Entry.__dataclass_fields__})
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
    """Validate a decoded ledger document; raise :class:`LedgerError` if malformed."""
    if not isinstance(doc, dict) or doc.get("schema_version") != SCHEMA_VERSION:
        raise LedgerError(f"schema_version must be {SCHEMA_VERSION}")
    versions = doc.get("accepted_backend_versions", {})
    if not isinstance(versions, dict) or not all(
        k in (MSB, SBX) and isinstance(v, str) and _FINAL_VERSION.fullmatch(v) for k, v in versions.items()
    ):
        raise LedgerError("accepted_backend_versions must map msb/sbx to final X.Y.Z versions")
    return Ledger(
        tuple(_parse_entry(e, i) for i, e in enumerate(_list(doc, "entries"))),
        tuple(_parse_waiver(w, i) for i, w in enumerate(_list(doc, "waivers"))),
        dict(versions),
    )


def load_ledger(path: str | Path) -> Ledger:
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise LedgerError(f"cannot read ledger {path}: {exc}") from None
    return parse_ledger(doc)


def latest_entry(ledger: Ledger, backend: str, platform: str) -> Entry | None:
    """The most recently recorded entry for a cell (latest wins, even if it failed).

    Equal timestamps fail closed: a non-PASS entry beats a PASS at the same time.
    """
    matching = [e for e in ledger.entries if (e.backend, e.platform) == (backend, platform)]
    return max(
        matching,
        key=lambda e: (datetime.fromisoformat(e.recorded_at), e.verdict != "PASS"),
        default=None,
    )


def entry_from_transcript(
    doc: dict, raw: bytes, *, platform: str | None = None, recorded_at: str | None = None
) -> Entry:
    """Build a ledger entry from a harness ``transcript.json`` (``raw`` is its bytes)."""
    import hashlib

    attempts = doc.get("attempts") if isinstance(doc, dict) else None
    if not isinstance(attempts, list) or not attempts or not all(isinstance(a, dict) for a in attempts):
        raise LedgerError("transcript has no attempts")
    env, last = attempts[0].get("environment"), attempts[-1]
    if not isinstance(env, dict):
        raise LedgerError("transcript attempt has no environment")
    stamp = recorded_at or last.get("recorded_at")
    if not stamp:
        raise LedgerError("transcript has no recorded_at (older harness); pass --recorded-at")
    missing = [k for k in ("backend", "os", "arch", "backend_version", "os_build", "hypervisor", "rev", "artifact_sha256") if k not in env]
    if missing:
        raise LedgerError(f"transcript environment is missing {', '.join(missing)}")
    if not re.fullmatch(r"[0-9a-f]{7,64}", str(env["rev"])) or set(str(env["rev"])) == {"0"}:
        raise LedgerError(
            "transcript rev is not a real commit; run the cell with --rev $(git rev-parse HEAD)"
        )
    entry = {
        "backend": env["backend"],
        "platform": platform or platform_token(env["os"], env["arch"]),
        "verdict": str(doc.get("outcome", "")),
        "backend_version": env["backend_version"],
        "os_build": env["os_build"],
        "arch": env["arch"],
        "hypervisor": env["hypervisor"],
        "rev": env["rev"],
        "artifact_sha256": env["artifact_sha256"],
        "recorded_at": stamp,
        "transcript_sha256": hashlib.sha256(raw).hexdigest(),
    }
    _cell(entry, "transcript")
    return _parse_entry(entry, 0)


def append_entry(path: str | Path, entry: Entry) -> None:
    """Append ``entry`` to the ledger file, preserving everything else."""
    target = Path(path)
    ledger = load_ledger(target)
    if any(e.transcript_sha256 == entry.transcript_sha256 for e in ledger.entries):
        raise LedgerError("this transcript is already recorded")
    doc = json.loads(target.read_text(encoding="utf-8"))
    doc.setdefault("entries", []).append(asdict(entry))
    target.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
