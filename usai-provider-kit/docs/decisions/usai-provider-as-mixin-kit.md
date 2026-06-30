# Decision: Ship the USAi provider config as a self-contained sbx mixin kit

**Status:** accepted

## Context

Coding agents running in an sbx sandbox start with no provider configured. For
OpenCode specifically, that means a provider-selection prompt and no access to
the GSA USAi gateway. We want a sandbox to come up already pointed at USAi,
declaratively, without copying config into every project and without an
imperative post-create step.

sbx **mixin kits** are the right tool: a `spec.yaml` plus a `files/` tree that
sbx applies at sandbox creation. This kit packages the USAi provider config that
way.

## Decision

Distribute the USAi provider configuration as a **self-contained mixin kit**:

- `caps.network.allow: [api.gsa.usai.gov]` — USAi is a custom endpoint, not a
  built-in sbx service, so egress must be allow-listed explicitly.
- `environment.variables.OPENCODE_CONFIG=/home/agent/usai-config/opencode.jsonc`
  — point OpenCode at a config file the kit ships, so it doesn't prompt.
- `files/home/usai-config/opencode.jsonc` — the provider block + generated USAi
  model catalog.

### Namespaced `OPENCODE_CONFIG`, not the global config path

OpenCode merges config across layers: **global**
(`~/.config/opencode/opencode.json[c]`) < **`OPENCODE_CONFIG`** (a single custom
file) < **project** (`<workspace>/.opencode/`). We deliberately write a
*namespaced* file (`~/usai-config/opencode.jsonc`) and point `OPENCODE_CONFIG`
at it, rather than writing the global path.

Rationale — **compose, don't clobber**: in a fresh sandbox the global path may be
seeded by the base agent template. Writing our own namespaced file and layering
it via `OPENCODE_CONFIG` lets the kit *compose with* whatever the template writes
globally instead of overwriting it. So USAi support doesn't preclude picking up
upstream config changes. (Empirically, the stock OpenCode base image writes no
global config of its own, so in practice our file is the only config loaded —
but the namespaced approach is robust either way.)

### Secret handling

The USAi API key is **not** in the kit. The shipped `opencode.jsonc` reads it
from the injected `USAI_API_KEY` env var; the user stores it once via the sbx
secret store (`sbx secret set-custom -g --host api.gsa.usai.gov --env
USAI_API_KEY`). The container never sees the raw value.

### Self-containment

Everything the kit needs travels with it: the spec, the config payload, the
model-catalog generator (`scripts/sync-usai-models.mjs` + tests), a host-side
`scripts/verify`, and its own `package.json`. The kit can be validated, tested,
and applied without any surrounding repository.

## Considered alternatives

- **Inline the config via `commands.initFiles`** — rejected: the config is large
  (provider block + generated catalog) and is maintained/tested as a real file;
  stringifying it into YAML would duplicate it and break the generator's single
  source of truth.
- **Write the global config path directly** (what the upstream model-runner kit
  does) — rejected: loses the compose-don't-clobber property.

## Consequences

- A sandbox with this kit applied has a working USAi provider with no prompt.
- The kit is portable and independently versionable.
- It owns the single-valued `OPENCODE_CONFIG` channel — see
  [`opencode-config-co-tenancy.md`](opencode-config-co-tenancy.md).
