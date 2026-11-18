---
title: "Introduce the qualification evaluator without activating release gating"
description: "Trust boundaries, transcript consistency, offline checks, and the bounded imported resolver exception"
status: proposed
tier: 2
date: 2026-11-16
last_updated: "2026-11-16"
category: development-process
---

# ADR-0040: Qualification evaluator introduction

## Context and Problem Statement

The Python CLI integration needs an evaluator already reviewed on the base
branch, so a candidate cannot relax its own qualification rules. The imported
code referred to a broader ADR-0044m that is not present in this checkout. This
scoped decision governs the evaluator foundation here; it does not adopt or
activate that broader integration. Import provenance is in
[BOOTSTRAP.md](../../qualification/BOOTSTRAP.md).

## Decision

Introduce `qualification.gate` and its dependency closure as an **inactive
release-gate foundation**. Do not add a production ledger, waivers, live-run
entry point, or release enforcement. The offline tests run in the existing
pre-commit standard path (and therefore its hosted workflow); testing evaluator
code is not running a release qualification gate. Missing ledgers fail closed.

Keep the existing CLI, RESULT line, and version-1 document shape. Strictly
reject malformed or contradictory evidence: exact document/attempt/environment
fields, typed identities, commit and digest syntax, oracle commands, and
timezone-aware timestamps. An empty output digest is permitted only for a
BLOCKED attempt, as the runner records one when no output was obtained.
The older runner's empty timestamp remains an explicit unknown, requiring the
existing recorder override; it cannot reconstruct as published evidence unaided.
Replay validated attempts through `repro.reproduce`, using the recorded attempt
count as its budget: the schema does not record the requested budget. This
preserves the existing configurable reproduction semantics, including a lone
FAIL becoming FLAKY and two matching failures confirming FAIL. Reject attempts
after the reproduction rule would have stopped. Binding-field divergence must
be FLAKY, never PASS or confirmed FAIL; backend/OS/architecture must remain one
cell. Hashes establish internal consistency, not that a real run happened.

Under `verify-evidence --base`, existing entries are immutable and append-only:
compare every field, reject removal or same-hash mutation, and require one
visible verifying transcript per new entry. New timestamps or revisions require
new evidence, not relabeling old hashes. Waiver/accepted-version changes still
need human review; this evidence check does not authenticate their approval.

## Trust and base policy

A future activation must run a clean, exact base-branch evaluator and its
resolver against candidate data/history only, with trusted Python and Git,
`-B -s -P`, a sole absolute evaluator PYTHONPATH, clean startup/Git configuration,
replacement refs disabled, complete history and verified candidate HEAD.
Candidate code must not execute in that evaluator job; report paths must be
fresh trusted temporary paths. See the
[evaluation contract](../../qualification/BOOTSTRAP.md#evaluation-contract).
This is a required future integration contract, not a claim that a Tier-3
workflow currently enforces it. Evaluator changes require separate administrator
review before later candidates can use those rules. CODEOWNERS review remains
the authenticity control for self-reported evidence and waivers.

## Scope and size exception

Split ledger responsibilities into focused schema, evidence-audit, and
transcript-validation modules inside `qualification/`, retaining the existing
ledger API. Do not mechanically split the imported resolver:
`py-acq/src/acq_py/hostexec.py` remains the unchanged 856-line dependency loaded
by exact path by `qualification/hostexec.py`. Grant a narrow introduction-only
exception to the 400-line file limit and the 50-line function limit for its
existing `run_foreground` (61 lines including its safety rationale). Its other
functions remain within 50 lines. The evaluator uses its absolute-path
`which`/`command` resolution; standalone loading avoids the application package
and its tracing imports. The same file also carries intertwined terminal/signal
and Windows Job-object lifecycle code, whose safe refactoring needs the full
cross-platform application's tests, not an evaluator-bootstrap patch.

This exception permits no growth, new dependency, weakened check, or blanket
size exemption. Reconsider it when integrating or changing that resolver; carry
this exact limitation in the introduction PR description. No exception is
granted to ledger validation. Offline evaluator tests do not certify the unused
Windows process lifecycle code.

## Validation and consequences

Use synthetic canonical transcripts, never live qualification evidence. Tests
exercise recording, evidence reconstruction, reproduction outcomes and binding
divergence, strict-schema rejection, visible/hidden/duplicate/missing blocks,
and real temporary Git history for immutable entries, qualification staleness
and ancestry. No oracle or backend executes. Run tests only in an independently
isolated sandbox; a separate checkout is not isolation.

Negative controls for independent validation: temporarily bypass the outcome
comparison in `validated_attempts` and return `doc["outcome"]` instead of the
derived outcome (contradiction tests must fail), restore hash-only base
comparison (same-hash mutation tests must fail), and remove the pre-commit hook
(standard-path wiring tests must fail). Make mutations only in disposable
sandbox copies, never the reviewed worktree. Report test counts and actual
outcomes; this decision records a plan, not a claim of successful execution.

Rollback is to revert the foundation before activation. Later live integration
must separately review orchestration, policy adoption, and real platform
evidence; no green offline check authorizes a release.

## Links / tracking

- Introduction: GSA-TTS/agentic-coding-quickstart#699.
- Dependent integration: GSA-TTS/agentic-coding-quickstart#697.
