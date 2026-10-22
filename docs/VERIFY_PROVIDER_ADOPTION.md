---
title: "Provider-Neutral Adoption Validation"
description: "Offline and live procedures for validating provider-input adoption on SBX and MSB"
status: draft
tier: 2
last_updated: "2026-10-22"
audience: "developers"
keywords: ["provider", "validation", "sbx", "msb", "opencode", "offline"]
related_files: ["scripts/verify-backends", "test/bats/146-provider-verification.bats", "test/bats/147-provider-input-projection.bats", "docs/howto/acq.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# Provider-Neutral Adoption Validation

This procedure separates the preparatory offline checks from the live backend
validation required before provider-input adoption can be considered complete.
The Bats cases named below are **offline tests**. They use local fixtures and
stubs; they are not E2E tests and do not prove that SBX, MSB, USAi, or a fresh
OpenCode process works on a real host.

## Offline Checks

Run the focused provider checks after initializing the Bats submodules:

```bash
./scripts/test-acq-bats test/bats/146-provider-verification.bats
./scripts/test-acq-bats test/bats/147-provider-input-projection.bats
```

Expected result: both commands complete successfully, with every Bats case
reported as `ok`. These checks prove that provider facts and projected inputs are consumed generically, URL and environment inputs are validated, and
malformed facts fail closed without invoking a backend or a network service.

## Live Validation Record

Run on a sandbox-capable host, outside any sandbox. Use a fresh temporary
workspace and the backend-specific command for each row. Never paste or print a
real provider key; the verifier's synthetic value only tests binding and
transport plumbing.

Record the observed command output, timestamp, backend version, and one of
`PASS`, `FAIL`, or `BLOCKED` for every row. `BLOCKED` is required when the
backend, virtualization, credentials, or released provider kit is unavailable.

| Check | SBX | MSB | Observed output / notes |
|---|---|---|---|
| Fresh `acq run opencode .` startup | BLOCKED | BLOCKED | No live run claimed in this preparatory slice |
| Fresh OpenCode process starts | BLOCKED | BLOCKED | Record actual startup output |
| `acq exec NAME -- opencode models` consumes projected provider input | BLOCKED | BLOCKED | Record actual model listing; do not claim from mocks |
| Remove projected provider input and restart OpenCode | BLOCKED | BLOCKED | Record expected actionable failure or documented fallback |
| Malformed provider input is rejected before startup | BLOCKED | BLOCKED | Record exact validation error and exit status |
| `scripts/verify-backends --only <backend>` | BLOCKED | BLOCKED | Run only outside a sandbox; capture transcript |

Example live commands, with placeholders only:

```bash
./acq run opencode /path/to/fresh-project
./acq exec <sandbox-name> -- opencode models
./acq exec <sandbox-name> -- sh -c '...remove the projected provider input...'
./acq stop <sandbox-name>
./scripts/verify-backends --only sbx
./scripts/verify-backends --only msb
```

Do not mark this record `PASS` from the offline Bats suite. Update the table
only after the real SBX/MSB flows have run and their output has been retained in
the draft PR verification transcript.
