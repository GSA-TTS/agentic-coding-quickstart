---
title: "Shard collected Python tests by whole file and retain the vectors gate"
description: "Bounded CI parallelism without duplicating the independent vector corpora"
status: proposed
tier: 2
date: 2026-11-25
decision_makers: ["Bret Mogilefsky"]
category: deployment
nist_controls: ["CM-3", "SA-11", "SI-17"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
related_files: [".github/workflows/python-vectors.yml", "scripts/pytest_shard.py", "py-acq/tests/test_pytest_shards.py"]
---

# ADR-0054m: Whole-file Python vectors CI shards

## Context and Problem Statement

The Python vectors job serializes the full pytest suite and two independent
corpus runs. Increasing its timeout preserves correctness but does not reduce
feedback latency. This decision is CI-only; no runtime behavior changes.

## Decision Drivers

- Preserve every collected test, parametrization and file-scoped fixture.
- Retain the required `vectors` check and fail closed on incomplete execution.
- Preserve pinned, read-only Patterns evidence and hash-locked tools.
- Avoid new dependencies, checked-in file lists and test-output secret capture.

## Considered Options

1. Keep serial execution: simplest, but no parallel feedback.
2. Add pytest-xdist: unnecessary dependency and different fixture isolation.
3. Partition pytest's collected files into four CI workers: chosen.

## Decision Outcome

Each worker collects the full suite with pytest, then the CI-only
`scripts.pytest_shard` plugin greedily partitions whole files by collected item
count, with deterministic path and worker tie-breaking. Helpers with no collected
items are not selected. New collected files join automatically, including the
plugin's own tests. Invalid specs and empty shards fail, never run a default suite.
Counts are only a balancing heuristic, not measured runtime weights.

The matrix has `fail-fast: false`. The source Bash vector runner and installed
wheel corpus run once in a dependent job after all workers succeed. The final
`vectors` job runs with `always()` and explicitly requires both the matrix and
the corpus job to report success. Failure, cancellation and skipping are not
success; a late wheel failure also fails the required gate.

Pytest retains capture but suppresses captured fixture output in failure reports.
Short tracebacks and all outcome summaries retain diagnostic context. Failures
appear during execution; the final summary retains every failure. No tokens or
new persisted credentials are introduced. Each pytest worker independently
verifies the pinned Patterns checkout, makes it read-only and rejects its missing
checkout skip reason.

## Consequences

Collection and setup repeat four times. Whole-file balancing cannot split a slow
parametrized file, and hosted scheduling can erase any wall-clock improvement.
Local focused timings are estimates only; hosted native runs are authoritative.
No speedup is claimed before observed timing. Triggers, concurrency, read-only
permissions and checkout credential custody remain unchanged.

## Verification and Rollback

Focused tests exercise actual collection, complete disjoint partitioning, added
files, helper exclusion, fixture isolation, invalid and empty shards, and execute
the final gate for every combination of success/failure/cancelled/skipped results.
Workflow mutation controls reject a missing matrix leg or ignored prerequisite.
Revert this change to restore the serial job; no runtime or stored-data rollback
is required. Human review is required before integration.
