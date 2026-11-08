"""The Tier-3 transcript ledger (ADR-0044m).

A committed JSON file of metadata and hashes about recorded live runs: never the
transcripts themselves (those are attached to a release, not committed) and never
a secret. The release gate (:mod:`qualification.gate`) reads it to decide whether
each claimed cell holds a current green transcript.

Besides ``entries`` it holds ``waivers`` (a claimed cell the maintainer has
explicitly accepted without a current transcript, each with a reason and a
mandatory expiry) and ``accepted_backend_versions`` (the backend versions under
acceptance; moving one past a transcript's ``major.minor`` expires it).

Each entry is bound to the evidence it claims: ``oracle`` and ``oracle_sha256`` name
the committed cell oracle the run executed and the SHA-256 of that file as committed
at the entry's ``rev``, and the entry's ``arch``/``hypervisor`` must be a host of its
cell. :func:`entry_from_transcript` refuses a transcript that did not run the oracle,
and :func:`binding_problem` is what the gate checks, so a hand-edited entry is held to
the same rule. A no-op command therefore qualifies nothing, and one run cannot stand
for another cell.

It lives outside the Tier-3 surface so recording a run never expires the runs it
records.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import asdict, dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Callable

from .matrix import CELL_ORACLE, MSB, PLATFORMS, SBX, host_mismatch, is_claimed

SCHEMA_VERSION = 1
DEFAULT_LEDGER = "docs/qualification-ledger.json"
VERDICTS = ("PASS", "FAIL", "BLOCKED", "FLAKY")
_FINAL_VERSION = re.compile(r"\d+\.\d+\.\d+")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_REV = re.compile(r"[0-9a-f]{7,64}")
# argv[0] of an oracle run may be the interpreter (``qualification.host`` runs
# ``sys.executable scripts/qualify-backend-cell``) or omitted (the shebang).
_INTERPRETER = re.compile(r"python[0-9.]*(\.exe)?|py(\.exe)?", re.IGNORECASE)

# Entries recorded before entries carried an oracle binding, identified by their
# ``transcript_sha256``. Each was recorded by ``qualification.host`` running the
# committed cell oracle (the ledger PR that added it inlines the transcript, whose
# ``commands`` show that); they are accepted without ``oracle``/``oracle_sha256`` and
# are otherwise held to every other rule. No new entry can join this set except by
# editing this file, which a PR cannot do for itself (the gate runs the base
# branch's copy). The newest was recorded 2026-11-08, so after 2027-02-06 all of them
# are older than ``MAX_AGE_DAYS`` and this set can be deleted.
LEGACY_UNBOUND_TRANSCRIPTS = frozenset({
    "dd35cd66098d7a05b98a1f82d6154e62d074843c294aa913de6acb29393f8545",  # msb macos-arm64
    "a2c33720b5d9e8ceba97a2e7cc9ead5a44936fc6a5cb4891bdda9a8fb389ea10",  # sbx macos-arm64
    "58c53763f4a5d5d013ae469178d7d4d2338e00f70980177d2579b36b3d472798",  # msb macos-arm64
    "abb5e532790297746d3c3e99821ea285012ef82f7d096320417724ca6f61521a",  # sbx macos-arm64
    "96d901c52f466933304c0a29d299cef21775eb685192e3a396889f94208330e3",  # msb windows-x64
    "f9f4d7445ca168af06adf4160f21b36dbd3b31259b4888b07357cec2429e9e19",  # sbx windows-x64
    "5cb1ce0b65df8908f3f56c706dba4a778582a02472bba76fce69c71b35c82b65",  # msb macos-arm64
    "1128ea4105921fef743ee462776d1c776bb38ea2b8c524b2685ae5ea54953bce",  # sbx macos-arm64
    "97810339e97d977af1fbcd110b7dfa4122cb88e3b2e3852ae0d2899a7157444a",  # msb macos-arm64
    "1f87d7c6c70b400921d070ac314b7574ea205a155a4ad92f86a38e83807184df",  # sbx macos-arm64
    "58e7a64074c1cc0042172145fb9fb998e30aa8f6e4f65a87eb9958a2ea44a4f3",  # msb windows-x64
    "8982d73f45ff18f144bb1ea92d28f87b07b095250e8a3612743f9b0ae5b399a5",  # sbx windows-x64
    "92ff5d8887a427f882d00ab548c1a99a27865609f0f01c4ab8cc78d4eac5fc7e",  # msb windows-x64
    "c3fe63bf7a3c9c986403b39a5c0203832236941869382b6a032bec8c165c8075",  # sbx windows-x64
    "5e42960bf04033c47de34cad8b13c06feb7e63fca233146698babc7ff018b453",  # msb macos-arm64
    "a5305f2d9ac836fa8d5bcf5cd069cac609818c681a0d6754a572c1a297c8c7ab",  # sbx macos-arm64
})

# ``(rev, path) -> SHA-256 of the file as committed at rev``, or ``None`` if git
# cannot say. Injectable so the gate's tests need no repository.
OracleDigest = Callable[[str, str], "str | None"]

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
    oracle: str = ""
    oracle_sha256: str = ""


_BINDING = ("oracle", "oracle_sha256")


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
    present = [field for field in _BINDING if field in doc]
    if present and len(present) != len(_BINDING):
        raise LedgerError(f"{where}: oracle and oracle_sha256 must be given together")
    fields = [f for f in Entry.__dataclass_fields__ if f not in _BINDING or present]
    entry = Entry(**{field: _text(doc, field, where) for field in fields})
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


def git_oracle_digest(rev: str, path: str, cwd=None) -> str | None:
    """SHA-256 of ``path`` as committed at ``rev`` (``None`` if git cannot say).

    The committed blob, not a working-tree file, so the digest is the same on every
    OS whatever its line-ending conversion.
    """
    if not _REV.fullmatch(rev) or path.startswith("-"):
        return None
    proc = subprocess.run(["git", "cat-file", "blob", f"{rev}:{path}"], capture_output=True, cwd=cwd)
    return hashlib.sha256(proc.stdout).hexdigest() if proc.returncode == 0 else None


def binding_problem(entry: Entry, oracle_digest: OracleDigest) -> str | None:
    """Why ``entry`` is not evidence from the committed oracle for its own cell, or ``None``."""
    mismatch = host_mismatch(entry.platform, entry.arch, entry.hypervisor)
    if mismatch:
        return f"recorded on another host: {mismatch}"
    if not entry.oracle:
        if entry.transcript_sha256 in LEGACY_UNBOUND_TRANSCRIPTS:
            return None
        return "entry has no oracle binding (oracle, oracle_sha256); re-record it with this tool"
    if entry.oracle != CELL_ORACLE:
        return f"recorded oracle {entry.oracle!r} is not the committed cell oracle {CELL_ORACLE}"
    committed = oracle_digest(entry.rev, CELL_ORACLE)
    if committed is None:
        return f"{CELL_ORACLE} is not committed at revision {entry.rev[:12]}"
    if committed != entry.oracle_sha256:
        return f"oracle_sha256 does not match {CELL_ORACLE} as committed at revision {entry.rev[:12]}"
    return None


def _oracle_run(commands: object, backend: str) -> bool:
    """Whether an attempt's argv is exactly ``[<python>] CELL_ORACLE --backend <backend>``."""
    if not isinstance(commands, list) or not all(isinstance(c, str) for c in commands):
        return False
    argv = list(commands)
    if len(argv) == 4 and _INTERPRETER.fullmatch(argv[0].replace("\\", "/").rsplit("/", 1)[-1]):
        argv = argv[1:]
    if len(argv) != 3:
        return False
    path = argv[0].replace("\\", "/")
    path = path[2:] if path.startswith("./") else path
    return path == CELL_ORACLE and argv[1:] == ["--backend", backend]


def entry_from_transcript(
    doc: dict,
    raw: bytes,
    *,
    platform: str | None = None,
    recorded_at: str | None = None,
    oracle_digest: OracleDigest | None = None,
) -> Entry:
    """Build a ledger entry from a harness ``transcript.json`` (``raw`` is its bytes).

    Refuses a transcript whose attempts did not run the committed cell oracle for the
    transcript's own backend, and a ``platform`` that is not the transcript's host.
    ``oracle_digest`` reads the oracle as committed at the transcript's ``rev``
    (default: git in the current directory).
    """
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
    derived = "linux-musl" if platform == "linux-musl" and env["os"] == "Linux" else platform_token(env["os"], env["arch"])
    if platform and platform != derived:
        raise LedgerError(f"--platform {platform} is not the transcript's host ({env['os']} {env['arch']} is {derived})")
    if not all(_oracle_run(a.get("commands"), str(env["backend"])) for a in attempts):
        raise LedgerError(
            f"transcript did not run the committed cell oracle: every attempt's command must be "
            f"'{CELL_ORACLE} --backend {env['backend']}' (optionally after the Python interpreter)"
        )
    digest = (oracle_digest or git_oracle_digest)(str(env["rev"]), CELL_ORACLE)
    if digest is None:
        raise LedgerError(f"{CELL_ORACLE} is not committed at revision {str(env['rev'])[:12]} in this repository")
    entry = {
        "backend": env["backend"],
        "platform": derived,
        "verdict": str(doc.get("outcome", "")),
        "backend_version": env["backend_version"],
        "os_build": env["os_build"],
        "arch": env["arch"],
        "hypervisor": env["hypervisor"],
        "rev": env["rev"],
        "artifact_sha256": env["artifact_sha256"],
        "recorded_at": stamp,
        "transcript_sha256": hashlib.sha256(raw).hexdigest(),
        "oracle": CELL_ORACLE,
        "oracle_sha256": digest,
    }
    _cell(entry, "transcript")
    parsed = _parse_entry(entry, 0)
    problem = binding_problem(parsed, lambda rev, path: digest)
    if problem:
        raise LedgerError(f"transcript: {problem}")
    return parsed


def _rewrite(target: Path, mutate) -> None:
    """Re-read the ledger document, apply ``mutate(doc)``, and write it back."""
    doc = json.loads(target.read_text(encoding="utf-8"))
    mutate(doc)
    target.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def append_entry(path: str | Path, entry: Entry, *, retire_waiver: bool = False) -> None:
    """Append ``entry`` to the ledger file, preserving everything else.

    ``retire_waiver`` also drops any waiver for the entry's cell (a no-op when
    there is none), used when the entry is a green run.
    """
    target = Path(path)
    if any(e.transcript_sha256 == entry.transcript_sha256 for e in load_ledger(target).entries):
        raise LedgerError("this transcript is already recorded")

    def mutate(doc: dict) -> None:
        doc.setdefault("entries", []).append(asdict(entry))
        if retire_waiver:
            doc["waivers"] = [
                w for w in doc.get("waivers", [])
                if (w.get("backend"), w.get("platform")) != (entry.backend, entry.platform)
            ]

    _rewrite(target, mutate)


def set_accepted_version(path: str | Path, backend: str, version: str) -> None:
    """Move the backend version under acceptance (expires cells recorded at the old minor)."""
    if backend not in (MSB, SBX) or not _FINAL_VERSION.fullmatch(version):
        raise LedgerError(f"cannot accept {backend} {version!r}: need msb/sbx and a final X.Y.Z version")
    _rewrite(Path(path), lambda doc: doc.setdefault("accepted_backend_versions", {}).__setitem__(backend, version))
