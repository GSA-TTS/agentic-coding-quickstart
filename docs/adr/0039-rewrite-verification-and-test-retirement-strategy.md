---
title: "Rewrite verification and test-retirement strategy"
status: proposed
date: 2026-11-01
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: []
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0039: Rewrite verification and test-retirement strategy

## Context and Problem Statement

The Bash acq suite (~830 bats tests plus a stub library and host-side
verifiers) must become safe evidence for a Python rewrite rather than an
obligation to port. It mixes subprocess CLI assertions, in-process
sourcing of Bash internals, and source-regex checks over installer text.
The compatibility contract requires language-neutral behavioral coverage
that survives further rewrites, and forbids mocks or coverage percentages
from standing in for live qualification of host enforcement.

## Decision

Contract oracles are proven only by driving the shipped CLI as a
subprocess; in-process Bash assertions are implementation detail, never
contract evidence. Valuable behavioral assertions are re-expressed as
language-neutral test vectors (argv/env/fixture -> expected
stdout/stderr/exit), consumed by a Bash runner and a pytest runner.

Evidence is three tiers: Tier 1 fast subprocess vectors in CI; Tier 2
implementation unit/integration tests (non-contract); Tier 3 live
cross-platform acceptance against real MSB/SBX, real microVMs, and a
native Windows host. Tier 3 gates release with a recorded transcript, and
the security/host-enforcement oracles additionally gate any PR that
touches them.

A command's rewrite is done only when every oracle touching it has a
named green evidence cell in its tier. Coverage percentages and stub
counts are not evidence; host-enforcement oracles require a green live
transcript. Tests asserting a DROP-classified behavior are retired
on-touch, naming the row; Preserve behaviors become named oracles.
No bulk port or delete.

Oracle isolation is re-established, not re-learned: throwaway
HOME/XDG/git identity, redirected secret/state/provenance roots, no live
secret refeed, stubs refusing out-of-tree writes, no keychain prompt
blocking, stable cache workspace, CRLF normalization, and neutralized
developer knobs.

## Consequences

The rewrite is proven against an observable contract independent of
implementation language, and security claims require real-backend
evidence at both PR and release boundaries. In-process and source-regex
tests are deliberately retired as implementation detail rather than
ported. Exact per-test classification, vector encoding, and the
qualification matrix remain separate follow-up decisions.

## Verification

A per-file classification inventory names every existing test against
these buckets; every contract oracle maps to a Tier 1 vector or a Tier 3
transcript; a live transcript exists per supported platform per release
and on every PR touching a security oracle.
