# Decision: OpenCode config co-tenancy — single `OPENCODE_CONFIG` owner

**Status:** accepted

## Context

This kit sets `OPENCODE_CONFIG` to a file it ships, so OpenCode loads the USAi
provider config. As the ecosystem grows, **other mixin kits may also want to
contribute OpenCode configuration**. We need a co-tenancy story so adding USAi
support neither blocks nor is blocked by another kit's config.

## What OpenCode actually does (verified against source)

OpenCode assembles configuration by **deep-merging** these sources in order,
each overriding the previous per key (arrays concatenated/de-duped):

1. Remote well-known configs
2. **Global**: `~/.config/opencode/{config.json, opencode.json, opencode.jsonc}`
3. **`OPENCODE_CONFIG`**: a single custom file (what this kit sets)
4. **Project**: `opencode.json[c]` discovered walking up from the workspace
5. **`.opencode/` directories** (and `OPENCODE_CONFIG_DIR`): `opencode.json[c]`
6. **`OPENCODE_CONFIG_CONTENT`**: inline JSON from an env var
7. macOS managed preferences (MDM)

Two facts drive this decision:

- **`OPENCODE_CONFIG` (and `OPENCODE_CONFIG_CONTENT`) are single scalar env
  vars** — not search paths. If two kits both set `OPENCODE_CONFIG`, sbx
  environment composition is **last-wins**: one kit silently shadows the other,
  with no error.
- **Project / `.opencode` config merges *over* `OPENCODE_CONFIG`**, deep, per
  key. Because `provider`, `model`, etc. are objects keyed by id, two sources
  contributing *different* keys (`provider.usai` vs `provider.foo`) merge
  cleanly. OpenCode is the merge engine; a kit need not build one.

## Decision

A **convention-based co-tenancy contract** (not a custom merge engine — OpenCode
already merges):

1. **This kit owns `OPENCODE_CONFIG` by convention.** It is the single kit
   permitted to set that env var. Its config file carries an ownership **marker
   comment** — the literal string `usai-provider-kit:owns-opencode-config` in a
   JSONC comment.

2. **Other config-contributing kits MUST NOT set `OPENCODE_CONFIG` or
   `OPENCODE_CONFIG_CONTENT`.** Instead they drop a fragment at
   `<workspace>/.opencode/opencode.jsonc` (kit `files/workspace/...`), which
   OpenCode deep-merges *over* `OPENCODE_CONFIG`. Each kit owns its own file;
   OpenCode merges them. Fragments should contribute **distinct keys** (e.g.
   their own `provider.<id>`); two kits setting the same leaf (e.g. top-level
   `model`) is a semantic conflict no mechanism resolves, and last-merged wins.

3. **Fail loud, not silent.** A **warn-only** `commands.startup` guard checks
   that the file `OPENCODE_CONFIG` resolves to carries the ownership marker. If
   `OPENCODE_CONFIG` is unset, missing, or points at a foreign file (no marker —
   another kit grabbed the channel), it prints a warning with remediation. It
   **never blocks startup**.

### Why the marker is a comment, not a config key

An earlier version used a `"$usaiKit": true` top-level **key**. Current OpenCode
validates `opencode.jsonc` against a **closed schema** and rejects unknown
top-level keys (`Unrecognized key: $usaiKit` → "Configuration is invalid"), which
broke config loading. The ownership marker is therefore a **JSONC comment**,
which OpenCode ignores. The guard `grep`s the file for the marker string rather
than parsing a key.

## Considered alternatives

- **Custom fragment-merge engine** (kits drop `opencode.d/*.jsonc`; a shared
  startup step merges them) — rejected: OpenCode already merges the
  project/`.opencode` layer; a bespoke engine + JSONC merge tooling + a cross-kit
  merge-script contract is needless complexity.
- **Each kit sets `OPENCODE_CONFIG_CONTENT`** — rejected: same single-scalar
  last-wins problem.
- **Route everyone through `OPENCODE_CONFIG_DIR`** — rejected: still a single
  directory env var loading two fixed filenames, not a multi-kit fragment dir.

## Consequences

- Co-tenancy for cooperating kits with **zero** custom merge code.
- Silent shadowing of `OPENCODE_CONFIG` becomes a **loud warning**.
- The guard is warn-only: a non-conforming kit that grabs `OPENCODE_CONFIG` still
  wins; we surface it but can't prevent it. The contract is social.
- Co-tenant fragments live at the **project** layer (`<workspace>/.opencode/`),
  overlaying the user's repo; kit authors must namespace their keys.

## Validation

- The model-catalog generator preserves the marker comment (it only rewrites the
  region between the `BEGIN/END GENERATED USAI MODELS` markers and the default
  model selection); `npm test` covers this.
- Guard logic checked offline against unset / missing / ours-with-marker /
  foreign-without-marker: warns on all but ours.
- Empirical probe: drop `<workspace>/.opencode/opencode.jsonc` with
  `{"model":"usai/PROBE"}` and confirm OpenCode's effective model becomes
  `usai/PROBE`, proving the project layer merges over `OPENCODE_CONFIG`. If a
  future OpenCode changes this order, revisit the contract.
