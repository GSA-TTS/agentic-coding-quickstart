---
title: "Automate USAI Model Sync and Default Selection for OpenCode Templates"
status: accepted
date: 2026-06-05
decision_makers: ["William Zujkowski"]
category: configuration-management
nist_controls: ["CM-2", "CM-3", "AC-6", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
---

# ADR-0003: Automate USAI Model Sync and Default Selection for OpenCode Templates

> **Update (2026-06):** The reference config moved from `templates/opencode.jsonc`
> to the repository-root `opencode.jsonc`, and the local sync command is now
> `npm run sync:usai-models` (the `make` targets were removed). References below
> reflect the original decision; paths and commands have since changed.

## Context and Problem Statement

The quickstart repository ships `templates/opencode.jsonc` as the reference
OpenCode configuration for SBX + USAI setups. That template currently contains a
hand-maintained `provider.usai.models` block and asks users to customize it
manually based on their USAI API key entitlements.

This approach creates two problems:

1. The template drifts as USAI adds, removes, or renames models.
2. Default model selection becomes stale unless maintainers notice newer model
   generations and update the file by hand.

At the same time, the repository must remain minimal, reviewable, and safe for a
documentation-first quickstart project. Model synchronization cannot bypass code
review, cannot expose secrets, and cannot assume that a model listed by the
`/models` endpoint is guaranteed to succeed at runtime for every request.

## Decision Drivers

- **CM-2 (Baseline Configuration):** The template must remain current and auditable
- **CM-3 (Configuration Change Control):** Automated changes must remain reviewable
- **AC-6 (Least Privilege):** Automation credentials and workflow permissions must be minimal
- **SI-7 (Software and Information Integrity):** Generated template changes must be deterministic
- **Developer Experience:** Users should get a working default without manual catalog curation
- **Simplicity:** Keep one template file instead of introducing a complex runtime dependency chain

## Considered Options

1. **Keep the model list fully manual**
2. **Generate the `provider.usai.models` block from the USAI `/models` API**
3. **Remove the catalog and keep only a few manual defaults**
4. **Depend on a secondary external catalog such as `models.dev` during CI**

## Decision Outcome

Chosen option: **Generate the `provider.usai.models` block from the USAI `/models`
API using a repo-local script, while keeping default-selection policy in the
repository and requiring PR-based review for generated updates**.

This keeps the quickstart template self-contained for downstream users while
avoiding blind drift in the model catalog.

### Architecture Overview

```
[Local make sync-models command]
          |
          v
[Repo-local sync script]
          |
          +--> GET https://api.gsa.usai.gov/api/v1/models
          |
          +--> Filter to OpenCode-appropriate models
          |
          +--> Rank defaults with repo policy
          |
          v
[Update generated section in templates/opencode.jsonc]
          |
          v
[Commit and push via normal PR process]
```

> **Note:** GitHub Actions cannot reach `api.gsa.usai.gov` due to network
> restrictions. The sync is performed locally using `make sync-models` until
> network access is resolved.

### Key Implementation Elements

1. **USAI as the source of truth for available models**
   - The sync script reads the USAI `/models` endpoint using a dedicated
     automation credential.
   - The script treats the API response as availability metadata, not as a full
     guarantee of runtime success.

2. **Deterministic generated section in `templates/opencode.jsonc`**
   - Only a bounded generated section is replaced by automation.
   - Manual configuration, comments, permissions, and non-generated defaults stay
     readable in the template.

3. **Repo-local default selection policy**
   - `model` tracks the highest available **Opus** generation.
   - `agent.compaction.model` tracks the highest available **GPT** generation.
   - `small_model` remains a curated fast/cheap fallback, preferring Haiku-class
     models when available.
   - The policy uses normalized parsing of model IDs and names so that versioned
     variants such as `claude_4_5_opus` and `gpt-5.4-latest-guardrails-defaultv2`
     can be ranked consistently.

4. **Local execution instead of GitHub Actions**
   - The sync is run locally via `make sync-models` with an exported `USAI_API_KEY`.
   - GitHub Actions cannot reach `api.gsa.usai.gov` due to network restrictions.
   - Changes are committed and pushed through the normal PR process.
   - This approach can be revisited if network access is resolved.

5. **Optional external references are advisory, not required**
   - External catalogs such as `models.dev` may help maintain ranking heuristics
     during development, but they are not a required runtime dependency of the
     sync workflow.
   - The workflow must remain functional if a secondary catalog is unavailable.

### Positive Consequences

- The quickstart template stays closer to the live USAI catalog
- Default model choices keep pace with newer Opus and GPT generations
- Generated changes remain reviewable through normal pull requests
- The solution remains self-contained and reproducible for downstream users
- Fixture-based tests can validate behavior without live secrets

### Negative Consequences

- The repository gains a small amount of generator logic to maintain
- Model ranking requires explicit policy decisions for edge cases
- `/models` availability can still diverge from runtime entitlement for a given key
- Sync requires local execution with `USAI_API_KEY` until network access is resolved

### Compliance Consequences

- **CM-2:** Satisfied — the template baseline is kept current in version control
- **CM-3:** Satisfied — automated updates remain subject to review through pull requests
- **AC-6:** Satisfied — workflow and API credentials can be scoped to the minimum needed access
- **SI-7:** Satisfied — deterministic rendering and fixture tests reduce accidental drift

## Alternatives Considered

### Keep the model list fully manual

Rejected because:
- It does not scale as USAI model inventory changes
- It leaves default selection stale for long periods
- It pushes catalog maintenance onto end users and maintainers unnecessarily

### Remove the catalog and keep only a few manual defaults

Rejected because:
- It reduces discoverability for downstream users
- It weakens the template's value as a working OpenCode provider example

### Depend on `models.dev` during CI

Rejected because:
- It adds an unnecessary second network dependency to the workflow
- USAI availability is the authoritative source for this repo's template
- A secondary catalog can be useful during development without being required in CI

## Implementation Plan

1. Add generated section markers to `templates/opencode.jsonc`
2. Add a repo-local script to fetch, filter, rank, and render USAI models
3. Add fixture-based tests for filtering, ranking, and rendering
4. Update README and bootstrap docs to describe generated vs manual sections
5. Add `make sync-models` target for local execution
6. Document operational caveats in troubleshooting docs where needed

## Links

- Related: `templates/opencode.jsonc`
- Related: `README.md`
- Related: `templates/BOOTSTRAP.md`
- Related: `docs/KNOWN_FAILURE_MODES.md`
- Related: `AGENTS.md`
