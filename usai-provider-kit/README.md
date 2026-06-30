# usai-provider (sbx mixin kit)

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that configures a
coding agent to use the GSA **USAi** OpenAI-compatible endpoint as its model
provider, with network egress allow-listed.

## Scope and roadmap

Today this kit targets **OpenCode**: it drops an `opencode.jsonc` and points
OpenCode at it. It is named `usai-provider` (rather than
`usai-opencode-provider`) deliberately — the intent is to grow it into a single
kit that configures the USAi provider for **multiple agents** (e.g. Codex,
Claude Code, Cursor) as their config formats are added. Until then, applying it
on a non-OpenCode agent has no effect beyond the network allow-list.

## What it does

- **Network egress** — allow-lists `api.gsa.usai.gov` (`caps.network`), since
  USAi is a custom endpoint, not a built-in sbx service.
- **Provider config** — ships `opencode.jsonc` (the USAi provider block + the
  generated USAi model catalog) and sets
  `OPENCODE_CONFIG=/home/agent/usai-config/opencode.jsonc` so OpenCode loads it
  instead of prompting for a provider on startup.
- **Co-tenancy guard** — a warn-only startup check (see
  [Co-tenancy](#co-tenancy)).

## Usage

```bash
sbx run --kit <path-to-this-kit> opencode /path/to/project
```

The kit is a `mixin`, so it composes with other kits via additional `--kit`
flags.

## Prerequisites

The USAi API key is **not** stored in the kit. The shipped `opencode.jsonc`
reads it from the injected `USAI_API_KEY` env var. Store it once in sbx's secret
store (the proxy injects it; the container never sees the raw value):

```bash
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY
```

USAi keys expire periodically — if the agent starts failing auth, rotate the key
and update the secret. See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## Design: compose, don't clobber

OpenCode merges config from **global** (`~/.config/opencode/opencode.json[c]`) <
**`OPENCODE_CONFIG`** (a single custom file) < **project**
(`<workspace>/.opencode/`). This kit deliberately writes a *namespaced* file
(`~/usai-config/opencode.jsonc`) and points `OPENCODE_CONFIG` at it, rather than
writing the global path. That way the kit **composes with** whatever the
opencode base template writes globally instead of overwriting it — so USAi
support doesn't preclude picking up upstream config changes.

## Co-tenancy

`OPENCODE_CONFIG` is a single scalar env var, so only one kit can own it (env
composition is last-wins). This kit owns it, and tags its config with an
ownership **marker comment** (`usai-provider-kit:owns-opencode-config`). A
warn-only `commands.startup` check fires if `OPENCODE_CONFIG` ends up pointing at
a file without that marker (i.e. another kit claimed the channel). It never
blocks startup.

> The marker is a JSONC **comment**, not a config key, because current OpenCode
> validates against a closed schema and rejects unknown top-level keys.

**If you are writing another kit that needs to add OpenCode config, do not set
`OPENCODE_CONFIG`.** Instead drop your fragment at
`<workspace>/.opencode/opencode.jsonc` (kit `files/workspace/...`) — OpenCode
deep-merges it *over* `OPENCODE_CONFIG`, so your keys and the USAi provider
config compose without either clobbering the other.

## Updating the model catalog

The shipped `opencode.jsonc` contains a generated block of USAi models. To
refresh it against the live USAi + models.dev data:

```bash
npm run sync:usai-models     # from this kit directory
```

The generator only rewrites the region between the `BEGIN/END GENERATED USAI
MODELS` markers and the default model selection; the ownership marker comment and
hand-maintained config are preserved. `npm test` covers the generator.

## Verifying

Run the bundled check on a host with `sbx` installed and logged in:

```bash
./scripts/verify
```

It validates the spec, creates a throwaway sandbox with the kit, and confirms
`OPENCODE_CONFIG` is set, the config file + ownership marker are present, and
the USAi API is reachable with the injected key. Set `KEEP=1` to keep the
sandbox for inspection.

## Design decisions

See [`docs/decisions/`](docs/decisions/):

- [`usai-provider-as-mixin-kit.md`](docs/decisions/usai-provider-as-mixin-kit.md)
  — why a self-contained kit, namespaced `OPENCODE_CONFIG`, secret handling.
- [`opencode-config-co-tenancy.md`](docs/decisions/opencode-config-co-tenancy.md)
  — single `OPENCODE_CONFIG` owner, the ownership marker, the fragment contract.

## Layout

```
usai-provider-kit/
├── spec.yaml                                   # the kit
├── files/home/usai-config/opencode.jsonc       # USAi provider + model catalog
├── scripts/
│   ├── sync-usai-models.mjs                    # regenerate the model catalog
│   └── verify                                  # host-side end-to-end check
├── tests/                                      # generator tests + fixture
├── docs/decisions/                             # design decision records
└── package.json                                # npm test / sync:usai-models
```
