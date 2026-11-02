---
title: "Live cross-platform qualification matrix and transcript"
status: proposed
date: 2026-11-02
decision_makers: ["Bret Mogilefsky"]
category: development-process
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0044: Live cross-platform qualification matrix and transcript

## Context and Problem Statement

The verification strategy settled that host-enforcement oracles require a
green live transcript against real MSB/SBX, real microVMs, and a native
Windows host, gating release and gating any PR that touches a security oracle.
It left the exact oracle list, the qualified platform/backend matrix, the
transcript contents and durability, and the BLOCKED/staleness/flakiness
handling open.

## Decision

Six oracles require Tier 3 (everything else stays Tier 1): the
host-enforced read-only trusted-config mount (ADR-0035/ADR-0037); secret
placeholder/proxy and swap-on-the-wire substitution and secret non-exposure;
real backend behaviour (kit apply, attach, boot contract, version
fail-closed); offline completeness (network-blocked install plus smoke);
the security-exception recreation flow (ADR-0041); and native-Windows
ordinary-user operation.

The qualified matrix is: msb on Linux x86_64, Linux aarch64, macOS arm64,
macOS x86_64, and Windows x64 (floor ≥ 0.6.9, refusing 0.7.0–0.7.2, with
oracles 1–3 at ≥ 0.7.7); sbx on Linux x86_64, macOS arm64, and Windows x64
(floor ≥ 0.39.0). sbx on macOS x86_64 and Linux aarch64 is unqualified
(not claimed). Each matrix cell is in exactly one of three states:
qualified (green current transcript), unqualified (not claimed), or
blocked (attempted, no verdict).

A transcript records environment identity (OS build, arch, hypervisor
state), backend and version, glibc floor where relevant, the commit SHA,
artifact SHA-256, the commands run, observed output or a verified digest,
and a PASS/FAIL/BLOCKED verdict with the canonical one-pasteable signature
line already emitted by `scripts/qualify-msb-ro-mount`:
`RESULT <PASS|FAIL|BLOCKED> msb=<ver> image=<image> host=<os arch>
rev=<sha> dir=<abs path>` (the backend token generalises `msb=` to `sbx=`
for sbx cells). Transcripts are attached to the release and, for a PR
touching a Tier-3 oracle, to that PR as artifacts with attestations where
available; they are not committed.

BLOCKED is a first-class recorded outcome, never a pass, distinct from an
unqualified (unclaimed) cell. The release gate is every qualified cell
holding a green current transcript; a PR touching a Tier-3 oracle attaches
a fresh transcript; re-verification runs quarterly; the developer owns and
runs the fleet. An unavailable qualified cell records blocked and holds
the gate.

Staleness is detected, not trusted: a transcript expires when its recorded
commit SHA, artifact SHA-256, backend version, or OS build no longer
matches the artifact under acceptance, and is regenerated. A FAIL is
confirmed real by re-running up to three attempts where the commit SHA,
artifact SHA-256, backend version, and OS build plus hypervisor state must
match (wall-clock time, transcript directory, nonce, and sandbox name may
differ); a result diverging across three attempts is flaky and is
escalated to a tracking issue plus KNOWN_FAILURE_MODES, never softened.

## Consequences

A release cannot be declared ready without green live transcripts on every
qualified cell, and a security-oracle change cannot merge without fresh
live evidence. Cells that cannot reach a verdict are visible as blocked,
not silently dropped. The repository does not accumulate transcript files;
the durable reference is the release/PR artifact plus its hashes and
attestations.

## Verification

The matrix and the reproduction rule are themselves asserted by the
transcripts they govern: a green transcript per qualified cell per release,
and a fresh transcript on any PR touching a Tier-3 oracle.
