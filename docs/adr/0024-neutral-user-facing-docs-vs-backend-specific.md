---
title: "Keep neutral user-facing docs in the quickstart repo; backend deep-dives stay symmetric"
status: accepted
date: 2026-08-21
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-6", "SA-5", "SA-8", "SA-15", "SA-17"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0024: Neutral user-facing docs vs. backend-specific docs

## Context and Problem Statement

`acq` is a thin wrapper over two sandbox backends — sbx (Docker Sandboxes) and
msb (microsandbox) — and exists precisely so user-facing guidance can stay
evergreen across backends (see [ADR-0010](0010-acq-pluggable-backends.md) and
[ADR-0011](0011-msb-backend-and-neutral-kits.md)). User testing surfaced that
docs still leaned on raw `sbx` commands for operations the wrapper fully covers
(the canonical "mount multiple directories" content was trapped in a
backend-specific guide and phrased in `sbx run` syntax), contradicting the
README's neutral claim. We need a durable convention for **where doc content
lives and which command vocabulary it uses**, so this drift does not recur.

## Decision Drivers

- **Evergreen docs.** The `acq` abstraction only pays off if user-facing docs
  are written against it rather than a specific backend.
- **Symmetry between backends.** A dedicated deep-dive for one backend and none
  for the other subtly signals primacy the default backend does not have.
- **Single source of truth.** Cross-cutting concepts (e.g. multi-workspace
  mounts) should have one canonical home, not be duplicated per backend.
- **Honest exceptions.** Some mechanics are genuinely backend-specific (login,
  network policy, `secret set-custom`, `--clone` remote lifecycle, backend
  diagnostics) and must remain shown as raw backend commands.
- **Docs-as-code (AGENTS.md §15.4).** Documentation boundaries are an
  architectural concern worth recording for traceability.

## Considered Options

1. **Neutral user-facing docs in `acq` terms; backend-specific docs are the
   symmetric exception.** Chosen. Cross-cutting concepts live in neutral docs
   in this repo; raw backend commands appear only for un-abstracted mechanics,
   shown "acq-first, raw backend command as a labeled equivalent."
2. **Keep per-backend guides as the primary user-facing docs.** Rejected:
   re-entrenches the drift this epic is fixing and forces readers to pick a
   backend before learning neutral operations.
3. **Collapse everything into one neutral doc with no backend-specific pages.**
   Rejected: genuinely backend-specific mechanics need a home, and erasing them
   loses diagnostic detail.

## Decision Outcome

Chosen option: **Option 1**, because it makes the `acq` abstraction the default
reader experience while preserving honest, symmetric homes for the mechanics the
wrapper deliberately does not abstract.

Concretely:

- Neutral, user-facing docs live in this quickstart repo and are written against
  the `acq` abstraction (e.g. `docs/CONCEPTS.md`, `docs/howto/acq.md`).
- Backend-specific deep-dives are the exception. They are kept **symmetric**
  across backends and should live alongside the backend implementation. The
  backends and their kits live in `GSA-TTS/agentic-coding-patterns`, so the
  cross-repo home question is tracked separately (see
  GSA-TTS/agentic-coding-quickstart#355).
- Convention: where a raw backend command is unavoidable in user-facing docs,
  show the `acq` command **first** and the raw backend command as a labeled
  **"equivalent."** Raw `sbx` / `msb` appears only for un-abstracted mechanics
  (login, policy, `secret set-custom`, `--clone` remote lifecycle, backend
  diagnostics).

### Positive Consequences

- User-facing docs stay evergreen across backends; adding or swapping a backend
  does not invalidate the neutral narrative.
- One canonical home per cross-cutting concept eliminates duplicate, drifting
  copies.
- The default reader path no longer implies a backend preference.

### Negative Consequences

- Contributors must learn the "acq-first, raw-as-equivalent" convention and the
  list of genuinely backend-specific exceptions.
- Some content moves between docs (link churn) as the boundary is applied.

### Compliance Consequences

- Supports SA-5 (system documentation) and SA-8/SA-15/SA-17 (documented,
  reviewable engineering boundaries) by recording the doc-structure decision.
- No ATO boundary change; this is an internal documentation-structure decision.

## Links

- Epic: GSA-TTS/agentic-coding-quickstart#348
- Related backend-primacy reconciliation: GSA-TTS/agentic-coding-quickstart#338
  (this ADR defers to it where the two overlap)
- Cross-repo backend-doc-ownership follow-up (blocked):
  GSA-TTS/agentic-coding-quickstart#355
- [ADR-0010: acq pluggable-backend wrapper](0010-acq-pluggable-backends.md)
- [ADR-0011: msb backend and neutral kits](0011-msb-backend-and-neutral-kits.md)
