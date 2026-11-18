"""Visible transcript blocks and field-for-field ledger evidence audits."""

import hashlib
import json
import re
from dataclasses import dataclass

from .ledger_schema import Entry, Ledger, LedgerError


@dataclass(frozen=True)
class EvidenceBlock:
    """Exact bytes from one fenced JSON block, and whether it is hidden."""

    raw: bytes
    hidden: bool


_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.S)


def evidence_blocks(text: str) -> list[EvidenceBlock]:
    """Read exact fenced JSON bytes, normalizing copied CRLF to canonical LF."""
    text = text.replace("\r\n", "\n")
    comments = [m.span() for m in _HTML_COMMENT.finditer(text)]
    blocks: list[EvidenceBlock] = []
    current: list[str] | None = None
    opened = offset = 0
    for line in text.split("\n"):
        if current is None:
            if line == "```json":
                current, opened = [], offset
        elif line == "```":
            hidden = any(start <= opened < end for start, end in comments)
            blocks.append(EvidenceBlock("".join(f"{x}\n" for x in current).encode("utf-8"), hidden))
            current = None
        else:
            current.append(line)
        offset += len(line) + 1
    return blocks


def verify_evidence(ledger: Ledger, blocks: list[bytes]) -> list[tuple[str, str | None]]:
    """Rebuild each hashed transcript's entry; the gate separately checks its oracle against Git."""
    # Deferred import keeps ledger's established public API without a module cycle.
    from .ledger import entry_from_transcript

    by_hash = {e.transcript_sha256: e for e in ledger.entries}
    results = []
    for raw in blocks:
        digest = hashlib.sha256(raw).hexdigest()
        entry = by_hash.get(digest)
        if entry is None:
            results.append((digest, "no ledger entry records this transcript_sha256"))
            continue
        try:
            doc = json.loads(raw)
            rebuilt = entry_from_transcript(
                doc, raw, platform=entry.platform, oracle_digest=lambda rev, path: entry.oracle_sha256 or None
            )
        except (LedgerError, ValueError) as exc:
            results.append((digest, f"{entry.backend}/{entry.platform}: {exc}"))
            continue
        differ = [f for f in Entry.__dataclass_fields__ if getattr(rebuilt, f) != getattr(entry, f)]
        results.append((digest, f"{entry.backend}/{entry.platform}: entry differs in {', '.join(differ)}" if differ else None))
    return results


def audit_evidence(
    ledger: Ledger, blocks: list[EvidenceBlock], required: list[Entry] | None = None
) -> tuple[list[tuple[str, str | None]], list[str]]:
    """Verify visible blocks and require exactly one per new entry, with no extras."""
    results = verify_evidence(ledger, [b.raw for b in blocks if not b.hidden])
    problems: list[str] = []
    seen: dict[str, int] = {}
    for b in blocks:
        digest = hashlib.sha256(b.raw).hexdigest()
        seen[digest] = seen.get(digest, 0) + 1
        if b.hidden:
            problems.append(f"HIDDEN {digest}: a transcript block inside an HTML comment is not shown to reviewers")
    problems += [f"DUPLICATE {d}: the same transcript appears {n} times" for d, n in seen.items() if n > 1]
    if required is not None:
        verified = {d for d, problem in results if problem is None}
        wanted = {e.transcript_sha256 for e in required}
        problems += [
            f"MISSING {e.transcript_sha256}: the {e.backend}/{e.platform} entry added since the base has no "
            "verifying transcript block"
            for e in required if e.transcript_sha256 not in verified
        ]
        problems += [f"EXTRA {d}: not an entry added since the base" for d in sorted(verified - wanted)]
    return results, problems
