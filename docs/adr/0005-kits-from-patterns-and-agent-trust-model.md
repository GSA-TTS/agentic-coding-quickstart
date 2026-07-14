---
title: "Deliver Kits from agentic-coding-patterns by Pinned Reference; New Agent Trust Model"
status: accepted
date: 2026-07-01
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["CM-2", "CM-3", "SA-10", "SA-12", "SC-7", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: ["0003", "0004"]
---

# ADR-0005: Deliver Kits from agentic-coding-patterns by Pinned Reference; New Agent Trust Model

> Supersedes [ADR-0003](0003-usai-model-sync-and-default-selection.md) and
> [ADR-0004](0004-playbook-submodule-shared-config.md).

## Context and Problem Statement

ADR-0004 vendored the playbook as a git submodule and had `qsbx` mount the clone
and symlink `AGENTS.md`/skills into the sandbox home. ADR-0003 kept the USAi
provider config and its model-sync tooling in this repo. Both put implementation
in the quickstart repo.

We have since extracted all of that into three reusable **sbx mixin kits** in the
community [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo (`integrations/isolation/sbx-kits/`): `usai-provider`,
`agentic-coding-playbook`, and `zscaler-ca-certificate`. The goal is for the
quickstart repo to be as narrowly scoped as possible — a comprehensible path to a
working agent sandbox that leans on existing tools (`sbx` + these kits) rather
than carrying the kit implementations itself.

This changes two things that need a recorded decision: **how kits are sourced**,
and **the trust model for the playbook rules** (ADR-0004's read-only mount is
gone).

## Decision

### Kits are applied by pinned remote reference

`qsbx` applies the three kits via `--kit` using
`git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=<sha>&dir=<kit>`,
where `<sha>` is a single, prominent `PATTERNS_KIT_REF` variable near the top of
`qsbx`. sbx requires remote kit refs to be a full 40-character commit SHA and
verifies fetched objects against it, so pinning by SHA **defeats content
substitution even through the trusted ZScaler TLS-inspecting proxy** (SA-12,
SI-7). Bumping the kits is a one-line, reviewable change to `PATTERNS_KIT_REF`.

`qsbx` also adds `github.com/GSA-TTS/` to sbx's `kit.allowedSources` allowlist
automatically (v0.34 gates remote kit sources), reading and re-writing that list
**fail-safe**: it only writes when it can read the current value as a valid JSON
array and appends via `jq`, never guessing on a transient read failure — so a
flaky read cannot silently narrow the operator's global allowlist.

### New agent trust model (supersedes ADR-0004's read-only mount)

ADR-0004 mounted the shared rules **read-only** so a prompt-injected agent could
not rewrite the rules it loads. The kit model instead has the
`agentic-coding-playbook` kit **clone the playbook into a writable
`~/.agentic-coding-playbook`** at container start and symlink `AGENTS.md` +
skills into each agent's search paths. The tradeoff:

- **Better:** cross-sandbox integrity. Each sandbox gets its own fresh clone
  pinned to a specific playbook commit (`PLAYBOOK_REF` + `PLAYBOOK_SHA`,
  SHA-verified by the kit). There is no shared mounted copy for one sandbox to
  corrupt for others, and the source is integrity-checked.
- **Worse:** in-session self-modification. Because the clone is writable and in
  the agent's home, an agent can modify its own `AGENTS.md`/skills *within a
  session*. This is a deliberate, accepted tradeoff:
  - The blast radius is one ephemeral sandbox; a fresh sandbox re-clones clean.
  - Rules/skills are advisory context, not a security boundary — the actual
    controls are sbx isolation, `caps.network` egress limits, and the USAi
    provider config, none of which live in the writable clone.
  - Keeping the clone writable is what makes the self-contained, no-mount kit
    model work across all supported agents.

  Residual risk is accepted at FIPS-Low for a development sandbox. If a future
  need requires immutable in-session rules, options are a read-only bind of the
  clone path or delivering rules via a mechanism the agent user can't write.

## Consequences

- The quickstart repo carries no kit code — just `qsbx`, docs, and the USAi
  key-rotation helper. Kit design rationale lives with each kit in the patterns
  repo (`docs/decisions/`).
- New create/start-time dependencies (SC-7 / SA-12): sandbox creation now
  requires network access to GitHub to resolve the kits, and — while the playbook
  repo is private — a GitHub token (`sbx secret set -g github`) for the clone.
  Offline creation degrades (playbook/kits unavailable) rather than using a
  vendored copy. Recorded in `docs/risk-assessment.md`.
- Existing clones created before this change have an orphaned submodule; the
  migration steps are in the README ("Staying Current") and
  `docs/KNOWN_FAILURE_MODES.md`.
- Executable tests (permission-matrix, model-sync) moved with the config into the
  `usai-provider` kit; the quickstart repo intentionally has none. Noted in
  CONTRIBUTING.

## Validation

> **Update ([ADR-0009](0009-require-sbx-0.35.0-in-place-kit-healing.md)):** the
> in-place healing described below was originally gated off (upstream sbx #133
> broke `sbx kit add` on file-shipping kits). sbx 0.35.0 fixes #133, so ADR-0009
> raises the floor to sbx >= 0.35.0 and `ensure_kit_applied` now heals
> unconditionally by recreating the sandbox with the added kit (state preserved).

- `qsbx` verified on sbx v0.34.0: a fresh `qsbx run` stands up a sandbox with all
  three kits; the allowlist update preserves existing entries and no-ops when
  already present; `ensure_kit_applied` heals a sandbox missing a kit and skips
  when a presence probe can't run.
- Kit-level behavior (SHA-verified playbook clone, USAi config, CA install) is
  validated by each kit's own `scripts/verify` and tests in the patterns repo.

## Links

- Supersedes: ADR-0003, ADR-0004
- Related: ADR-0001 (SBX isolation), the three kits in
  `agentic-coding-patterns/integrations/isolation/sbx-kits/`
