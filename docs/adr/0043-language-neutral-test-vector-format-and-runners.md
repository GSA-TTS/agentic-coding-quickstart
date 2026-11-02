---
title: "Language-neutral test-vector format and runners"
status: accepted
date: 2026-11-02
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["SA-11", "SA-15", "CA-2"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0043: Language-neutral test-vector format and runners

## Context and Problem Statement

The compatibility contract requires language-neutral behavioral coverage that
survives further rewrites: the Bash `acq` and the Python rewrite must be proven
against one oracle set. The verification strategy settled that contract oracles
are subprocess-only, encoded as language-neutral test vectors over a three-tier
evidence model, with oracle isolation re-established rather than re-learned. It
left the concrete vector encoding, the dual-runner conformance rule, and the
normalisation and isolation declarations open.

## Decision

A test vector is one immutable UTF-8 JSON file at
`test/vectors/<section>/<id>.json` recording a single CLI invocation, its
expected observable result, and the isolation it requires. Fields: `schema`,
`id`, `oracle` (the contract row or capability it proves), `tier`,
`backend`/`platform` scope, `invoke` (argv/env/unset/stdin/fixtures/timeout),
`expect` (exit, plus stdout/stderr with an assertion mode and a normalisation
list, plus recorded side-effects), and `isolation` (redirected HOME/XDG/secret/
state/provenance, no-live-refeed, offline, ssh stubs). Negative oracles are
ordinary vectors: fail-closed refusal is an expected nonzero exit plus the
stable error code, asserted with no mutation.

Two runners consume the corpus: a Bash runner (using `jq`, pinned and declared
in CI) and a pytest runner. A future language adopts the corpus by writing a
runner, never rewriting expectations. Vectors carry the what; runners carry the
how. The conformance rule is a sentinel golden set with at least one sentinel
per assertion mode and per normalisation transform, run identically by each
runner's own CI, so a diverging runner fails on the feature rather than passing
on representatives.

Normalisation is exact-by-default: a field is byte-exact unless it declares
`normalize` transforms (`abspath`, `tmpdir`, `crlf`, `timing`, `order`, `json`),
and only declared transforms apply. Regex is not a mode. Isolation is
structural: the `isolation` block is part of the vector, and a runner that
cannot honour it fails closed.

The migration-assigned `min_reader` and `regenerable-without-loss` checks are
ordinary vectors in this schema, not a separate mechanism. Coverage is proven
by a CI-validated manifest mapping every contract row, capability, and adapter
obligation to at least one vector id, validated against the corpus so a missing
or renamed vector fails the check rather than being assumed absent.

## Consequences

The Bash and Python implementations are proven against one observable corpus
independent of implementation language, and a third language can adopt it with
a runner only. The suite gains a pinned `jq` dependency and a per-vector file
layout; both are deliberate and CI-enforced. Oracles cannot silently weaken
because normalisation is declared per-field and every mode/transform has a
sentinel, and isolation cannot regress because it is declared per-vector and
enforced or failed-closed.

## Verification

Every contract row, capability, and adapter obligation maps to a vector id via
the CI-validated manifest; each runner passes the sentinel set in its own CI;
Tier-3 live transcripts reference the same vector ids on real backends/hosts.
