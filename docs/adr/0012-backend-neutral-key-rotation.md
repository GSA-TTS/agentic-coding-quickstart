---
title: "Make USAi Key Rotation Backend-Neutral via acq_backend_rotate_key"
status: accepted
date: 2026-07-22
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-3", "CM-6", "CM-7", "SA-8", "SA-15", "SA-17", "IA-5"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0012: Make USAi Key Rotation Backend-Neutral via acq_backend_rotate_key

## Context and Problem Statement

ADR-0010 established the `acq` pluggable-backend seam: the core dispatch calls
`acq_backend_*` functions and holds no backend-specific CLI knowledge, so a
backend (sbx, msb) is substituted purely by loading a different adapter. ADR-0011
added the `msb` adapter.

One code path was left coupled to `sbx`: **USAi key rotation.**
`scripts/rotate-apikey` is hardcoded to the `sbx` CLI end-to-end (`sbx secret
ls/rm/set-custom`, `sbx create/exec/rm` for validation). Two dispatch points
invoke it unconditionally, *after* the backend has already been resolved:

- `acq usai-rotate-api-key` (`acq`) — `exec "$ROTATE_SCRIPT"`
- `ensure_valid_key` (`acq.backends/common.sh`) — runs on `acq run` for **every**
  backend when the pre-attach key check fails

> **Note (non-rotation path):** `acq create` calls a sibling, `advise_valid_key`
> (`common.sh`), which only *warns* on a definitively invalid key and never
> rotates. Because `create` is detached and never attaches, there is nothing to
> gate; it does not invoke `acq_backend_rotate_key` and so does not touch the
> rotation mechanism this ADR governs. Interactive rotation remains exclusive to
> the `acq run` / attach path via `ensure_valid_key`.

A user on the `msb` backend who runs `acq run` with an expired key (USAi keys
expire every 7 days) is therefore funneled into `sbx` commands. If `sbx` is not
installed — or has no available seats — rotation fails and blocks the user from
launching their agent, even though nothing about their setup should touch `sbx`.
This is a violation of the ADR-0010 invariant ("no backend dependency outside the
adapters").

The rotation *mechanism* also differs by backend and cannot simply be
name-swapped:

- **sbx** owns a proxy placeholder that must be preserved across rotation so
  running sandboxes keep resolving the injected value. Rotation = re-feed the sbx
  proxy for `USAI_API_KEY@api.gsa.usai.gov` while keeping the placeholder.
- **msb** has no proxy-placeholder concept. The acq-owned secret store
  (`secret-store.sh`) is the source of truth; msb binds it at provision via
  `--secret ENV@HOST` and re-feeds running sandboxes with `msb modify --secret`.
  This is already exactly what `acq secret set -g usai` does on msb
  (`acq.backends/msb.sh`).

## Decision Drivers

- **Restore the ADR-0010 invariant** — no `sbx` (or any backend) knowledge
  outside `acq.backends/<name>.sh` (SA-8/SA-17).
- **Additive to the adapter contract** — extend the contract with one function,
  matching the existing `acq_backend_*` pattern rather than special-casing.
- **Preserve each backend's real rotation semantics** — sbx placeholder
  preservation; msb store re-feed. Not a lowest-common-denominator rewrite.
- **Fail closed, no silent fallback** — a missing rotation capability must report
  clearly, never quietly shell out to the wrong backend.

## Considered Options

1. **Add `acq_backend_rotate_key` to the adapter contract; dispatch through it.**
   Chosen. `scripts/rotate-apikey` becomes a thin `acq usai-rotate-api-key`
   shim (back-compat) that routes to the resolved backend. sbx keeps its
   placeholder-preserving logic inside `sbx.sh`; msb reuses its store re-feed.
2. **Branch on `ACQ_RESOLVED_BACKEND` at each call site.** Rejected: reintroduces
   backend knowledge into the neutral core (`acq`, `common.sh`) — the exact smell
   ADR-0010 removed — and duplicates the branch at two sites.
3. **Leave rotation sbx-only, document it.** Rejected: leaves msb users blocked
   on a routine (7-day) operation and contradicts the pluggable-backend promise.

## Decision Outcome

**Chosen: Option 1.**

- Extend the ADR-0010 adapter contract with one function:

  | Function | Purpose |
  |----------|---------|
  | `acq_backend_rotate_key` | Rotate the USAi API key using the backend's native secret mechanism; validate the new key; return non-zero on failure. |

- `acq usai-rotate-api-key` resolves the backend (already does) and calls
  `acq_backend_rotate_key` instead of `exec`ing the sbx-only script.
- `ensure_valid_key` (`common.sh`) calls `acq_backend_rotate_key` instead of the
  script, gated on the function being defined (fail closed with a clear message
  if a backend does not implement it).
- `acq.backends/sbx.sh` implements `acq_backend_rotate_key` by carrying the
  existing placeholder-preserving logic verbatim (dedup of pre-fix duplicate
  entries, in-place `set-custom`, throwaway-sandbox validation).
- `acq.backends/msb.sh` implements `acq_backend_rotate_key` by prompting for the
  new key into the acq store and re-feeding running sandboxes with
  `msb modify --secret` (the `acq secret set -g usai` path), then validating in a
  fresh sandbox via the shared `check_fresh_sandbox_key` helper.
- `scripts/rotate-apikey` is reduced to a thin back-compat wrapper that execs
  `acq usai-rotate-api-key` so existing muscle-memory / docs keep working, but it
  no longer contains any `sbx` calls.

### Adapter contract addition

`acq_backend_rotate_key` takes no required arguments (rotation is a global-key
operation). It MUST:
- collect the new key without placing it on argv (TTY prompt / stdin), never log
  the value;
- update the backend's injection mechanism for `USAI_API_KEY@api.gsa.usai.gov`;
- validate the new key against the USAi models API from inside a sandbox and
  return non-zero if validation fails or cannot run.

## Consequences

### Positive Consequences

- msb (and any future backend) users can rotate the USAi key without `sbx`
  installed — the reported block is removed.
- The neutral core (`acq`, `common.sh`) again holds zero backend CLI knowledge;
  the ADR-0010 seam is complete.
- Each backend keeps its correct rotation semantics (sbx placeholder, msb store
  re-feed).

### Negative Consequences

- The adapter contract grows by one function; existing/future adapters must
  implement it (enforced by fail-closed dispatch + a `scripts/test-acq` check).

### Compliance Consequences

- CM-7 (least functionality) / SA-8 (security engineering): removes an
  unintended cross-backend dependency.
- IA-5 (authenticator management): key rotation remains a first-class,
  audited operation regardless of backend; the secret value never reaches argv
  or logs.
- No change to attack surface, external services, or data classification
  (CM-3/CM-6). No ATO package impact.

## Validation

- `bash -n acq acq.backends/*.sh scripts/rotate-apikey scripts/test-acq` clean.
- `./scripts/test-acq` passes, including new checks that
  `acq usai-rotate-api-key` dispatches to `acq_backend_rotate_key` on both
  backends and that the rotate path issues no `sbx` command on the msb backend.
- **Deferred, requires a sandbox-capable host:** the live rotate→validate loop
  (creates a throwaway validation sandbox) cannot run inside a sandbox — mirrors
  the ADR-0010/0011 deferral. Tracked for `scripts/verify-*` coverage.

## Links

- Contract base: [ADR-0010](0010-acq-pluggable-backends.md) (Adapter contract)
- msb adapter + neutral kits: [ADR-0011](0011-msb-backend-and-neutral-kits.md)
- USAi placeholder recovery (sbx rotation semantics): [ADR-0008](0008-usai-placeholder-recovery.md)
