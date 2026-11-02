---
title: "Configuration and state migration behavior"
status: accepted
date: 2026-11-01
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-4", "CM-6", "SC-28", "SI-2"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0041: Configuration and state migration behavior

## Context and Problem Statement

The Bash acq wrapper persists user configuration (`config.yaml`), host-side
provenance and per-sandbox records, secret-store envelopes, and clone/port/SSH
state across many small files, most of which carry no version marker. A Python
replacement must read and migrate that state without a blanket recreation
requirement (compatibility contract §3), while never weakening host authority
(ADR-0035) or silently touching backend-owned state (ADR-0032). Migration
ownership, schema versioning, mixed-version behavior, rollback, and the
security-exception recreation flow were left to this decision.

## Decision

The acq **orchestrator** owns migration of acq-hosted records; backend adapters
never migrate acq state, and backend-native state (msb catalog, sbx
registration) is refused or delegated, never migrated. Guest-writable state is
never trusted or migrated.

Each durable record carries its own integer **state-schema version** as the
first field (`schema=N`, reusing the existing provenance `schema=1`); absence
means legacy v0. `config.yaml` gains a `schema:` flat key. This is distinct from
the structured-output `schema_version`. Upgrades are forward-only and
idempotent per record. A single tree-level **generation marker** is a checkpoint
of migration progress, not a data format; it makes a partially-applied tree
migration detectable and resumable.

Compatibility is **forward-only**: V1 replaces Bash and maintains no coexistence
guarantee. The only obligation toward the legacy acq is that it must not
silently misread new state — achieved by new filenames/keys plus a `schema`
marker the old flat-key reader ignores. Version mismatch fails closed by
default: older records migrate forward; newer or unparseable records, or a
reader below a record's `min_reader`, are refused with a stable code, message,
and remediation; read-only diagnostics may report `unknown`.

Migration is atomic and non-destructive until verified: per record, write temp
+ fsync + rename, retain the prior record as `<name>.bak.<schema>` until the
new record parses, then delete; on failure leave the old record intact and
print the path, failed step, and remediation. Across the tree, migration is a
synchronized pre-step under an exclusive OS advisory migration lock
(`flock`/`fcntl` on POSIX, `msvcrt.locking` on Windows) that auto-releases on
crash. A second invocation waits a bounded interval then fails closed; a crash
mid-migration converges via idempotent forward migration, and the marker is
written last so a generation is never declared complete until all its records
are done. A migration is never reported successful unless the read-back
verifies.

A sandbox missing a required host-enforced guarantee (the ADR-0035 read-only
trusted-config mount) fails closed for the affected trusted operations and
requires explicit, consent-gated recreation; host-held records and secrets are
preserved, the guest filesystem is lost, and no weaker guest-writable fallback
is permitted.

Migratable records are the §3 semantic state plus `clones/`, `ports/`, `ssh/`;
disposable caches are those acq can regenerate from host-held authority and
pinned refs with no observable difference. Classification is proven by a
"regenerable without loss" vector, not asserted.

## Consequences

Existing users upgrade in place without losing deliberate configuration, state,
credentials, or sandbox identity, and without inheriting the Bash
implementation's version-less files. A reader that does not understand a
record's schema refuses rather than corrupting it. The one tolerated recreation
is limited to the security exception and never weakens host authority. Internal
file formats remain non-public; only the version marker and the semantic state
are stable. V1's file layout is not constrained by the legacy implementation,
and a crashed migration cannot strand state behind a stale lock.

## Verification

Tier-1 vectors assert per-record forward migration, fail-closed refusal on
newer/unparseable/`min_reader` records, the generation-marker/checkpoint
behavior under a simulated crash, and the regenerable-without-loss
classification. Tier-3 live transcripts assert the security-exception
recreation flow on a real backend and that the migration lock auto-releases on
process death across POSIX and Windows: a sandbox stripped of the read-only
mount record fails closed on trusted operations and is recreated from
host-held authority with secrets and identity preserved.
