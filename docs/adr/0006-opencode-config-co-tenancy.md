---
title: "OpenCode Config Co-Tenancy: Single OPENCODE_CONFIG Owner + Project-Layer Fragments"
status: accepted
date: 2026-06-29
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["CM-2", "CM-3", "SA-10", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
---

# ADR-0006: OpenCode Config Co-Tenancy

## Context and Problem Statement

ADR-0005 made the `usai-opencode-provider` kit set `OPENCODE_CONFIG` to a
namespaced file it drops in the sandbox. That kit now "owns" the
`OPENCODE_CONFIG` channel. As the ecosystem grows (e.g. the planned
playbook-content kit, and community kits from the agentic-coding-patterns
repo), **other mixins may also want to contribute OpenCode configuration**. We
need a co-tenancy story so adding USAi support does not block, or get blocked
by, another kit's config.

## What OpenCode actually does (verified against source)

Reading OpenCode's config loader (`packages/opencode/src/config/config.ts`,
`loadInstanceState`), configuration is assembled by **deep-merging** these
sources in order, each overriding the previous per key (arrays are
concatenated/de-duped via `mergeConfigConcatArrays`):

1. Remote well-known configs
2. **Global**: `~/.config/opencode/{config.json, opencode.json, opencode.jsonc}`
3. **`OPENCODE_CONFIG`**: a single custom file (what our kit sets)
4. **Project**: `opencode.json[c]` discovered walking up from the workspace
5. **`.opencode/` directories** (and `OPENCODE_CONFIG_DIR`): `opencode.json[c]`
6. **`OPENCODE_CONFIG_CONTENT`**: inline JSON from an env var
7. macOS managed preferences (MDM)

Two facts drive this decision:

- **`OPENCODE_CONFIG` (and `OPENCODE_CONFIG_CONTENT`) are single scalar env
  vars.** They are not search paths. If two kits both set `OPENCODE_CONFIG`,
  sbx environment composition is **last-wins** — one kit silently shadows the
  other, with no error. There is no per-kit layering on this channel.
- **Project / `.opencode` config is merged *over* `OPENCODE_CONFIG`** and
  OpenCode performs a deep, per-key merge. Because `provider`, `model.*`, etc.
  are objects keyed by id, two sources contributing *different* keys
  (`provider.usai` vs `provider.foo`) merge cleanly. OpenCode is the merge
  engine; we do not need to build one.

> Verification note: the merge order above was read from OpenCode source at one
> commit. The empirical probe in "Validation" confirms the running sandbox's
> OpenCode merges a `.opencode/opencode.jsonc` fragment over `OPENCODE_CONFIG`.

## Decision

Adopt a **convention-based co-tenancy contract**, not a custom merge engine
(YAGNI — OpenCode already merges):

1. **`usai-opencode-provider` owns `OPENCODE_CONFIG` by convention.** It is the
   single kit permitted to set that env var. Its config file carries a
   `"$usaiKit": true` ownership **sentinel** (a top-level key OpenCode ignores;
   commented in the file).

2. **Other config-contributing kits MUST NOT set `OPENCODE_CONFIG` or
   `OPENCODE_CONFIG_CONTENT`.** Instead they drop a fragment at
   `<workspace>/.opencode/opencode.jsonc` (kit `files/workspace/...`), which
   OpenCode deep-merges *over* `OPENCODE_CONFIG`. Each such kit owns its own
   file; OpenCode merges them. Fragments should contribute **distinct keys**
   (e.g. their own `provider.<id>`); a genuine same-leaf conflict (two kits both
   setting top-level `model`) is a semantic conflict no mechanism can resolve,
   and last-merged wins.

3. **Fail loud, not silent.** The kit ships a **warn-only** `commands.startup`
   guard that checks the file `OPENCODE_CONFIG` resolves to actually carries the
   `$usaiKit` sentinel. If `OPENCODE_CONFIG` is unset, missing, or points at a
   foreign file (no sentinel — i.e. another kit grabbed the channel), it prints
   a warning with remediation pointing here. It **never blocks startup**.

## Considered Options

1. **Custom fragment-merge engine** (each kit drops `opencode.d/*.jsonc`; a
   shared startup step merges them) — rejected: OpenCode already deep-merges the
   project/`.opencode` layer, so a bespoke engine (plus JSONC merge tooling and
   a cross-kit merge-script contract) is unnecessary complexity for no gain.
2. **Each kit sets `OPENCODE_CONFIG_CONTENT` instead** — rejected: same
   single-scalar last-wins problem as `OPENCODE_CONFIG`.
3. **Route everyone through `OPENCODE_CONFIG_DIR`** — rejected: still a single
   directory env var loading two fixed filenames, not a multi-kit fragment dir.
4. **Convention (single owner) + project-layer fragments + warn-only guard** —
   chosen. Cheapest robust option; leans on OpenCode's own merge.

## Consequences

### Positive

- True co-tenancy for cooperating kits with **zero** custom merge code —
  OpenCode merges `.opencode`/project fragments over our config.
- Silent shadowing of `OPENCODE_CONFIG` becomes a **loud warning** with a fix.
- The contract is documented for community (patterns-repo) kit authors.

### Negative / Residual

- The guard is **warn-only**: a non-conforming kit that grabs `OPENCODE_CONFIG`
  still wins the channel; we surface it but cannot prevent it from a kit.
- The contract relies on other kit authors following it (social, not enforced).
- Co-tenant fragments live at the **project** layer (`<workspace>/.opencode/`),
  so they overlay the user's repo; kit authors must namespace their keys.

## Validation

- `node scripts/sync-usai-models.mjs --check --fixture` and `npm test` confirm
  the `$usaiKit` sentinel survives model-catalog regeneration (the sync script
  only rewrites the generated block and the `model`/`small_model`/compaction
  strings, leaving the sentinel intact).
- Guard logic unit-checked offline against four cases (unset / missing /
  ours-with-sentinel / foreign-without-sentinel): warns on the first, second,
  and fourth; silent on ours.
- **Empirical probe (run in a sandbox):** drop
  `<workspace>/.opencode/opencode.jsonc` with `{"model":"usai/PROBE"}` and
  confirm OpenCode's effective model becomes `usai/PROBE`, proving the project
  layer merges over the kit's `OPENCODE_CONFIG`. If a future OpenCode changes
  this order, revisit the contract.

## Links

- Builds on: ADR-0005 (kit owns `OPENCODE_CONFIG`)
- Related: `usai-opencode-provider/spec.yaml` (`commands.startup` guard), `usai-opencode-provider/files/home/usai-config/opencode.jsonc` (`$usaiKit` sentinel)
- OpenCode config loader: `packages/opencode/src/config/config.ts` (`loadInstanceState`)
