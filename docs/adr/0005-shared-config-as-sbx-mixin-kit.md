---
title: "Distribute Shared OpenCode Config as an sbx Mixin Kit at the Repo Root"
status: accepted
date: 2026-06-29
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["CM-2", "CM-3", "SA-10", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
---

# ADR-0005: Distribute Shared OpenCode Config as an sbx Mixin Kit at the Repo Root

## Context and Problem Statement

ADR-0004 established that `qsbx` mounts this clone into each sandbox and
post-create symlinks the shared OpenCode config, the playbook's `AGENTS.md`, and
its skills into the sandbox home. That works, but the provider-config half of
the job is exactly what `sbx` now supports **declaratively** via *kits* — a
`spec.yaml` (plus an optional `files/` tree) that `sbx` applies at sandbox
creation with `--kit`.

Moving the USAi provider wiring into a kit reduces the imperative surface area
of `qsbx`, makes the configuration reproducible without the wrapper, and aligns
with the upstream `sbx` extension model. This ADR covers **only** the OpenCode
provider config + network egress. Federal `AGENTS.md` and skills remain a
`qsbx` responsibility for now; a separate mixin kit for that content is planned
(likely sourced from the playbook repo).

## Decision Drivers

- **CM-2 / CM-3:** one auditable, version-controlled source; changes land via PR.
- **SA-10 / SI-7:** declarative, inspectable wiring instead of shell steps.
- **Reduce user toil:** fewer wrapper-specific steps to get USAi working.
- **Upstream compatibility:** USAi support must not preclude picking up changes
  from the official opencode template/kit.
- **Minimalism (AGENTS.md):** prefer one config file + one command.

## Decision Outcome

**The repository root *is* the kit.** We add a `spec.yaml` at the root
(`schemaVersion: "2"`, `kind: mixin`, `name: usai-opencode-provider`) and move
the shared config under the kit's `files/` tree.

### Layout change

```
agentic-coding-quickstart/                       # = the kit root
├── spec.yaml                                     # NEW
├── opencode.jsonc -> files/home/usai-config/opencode.jsonc   # retargeted symlink
├── files/home/usai-config/opencode.jsonc         # MOVED from opencode/opencode.jsonc
└── agentic-coding-playbook/                      # submodule (untouched)
```

The previous `opencode/` directory is removed. The root `opencode.jsonc`
convenience symlink is retargeted to the new location, so anything resolving
`./opencode.jsonc` keeps working.

### What the kit declares

- `caps.network.allow: [api.gsa.usai.gov]` — explicit egress on a default-deny
  network (replaces the manual `sbx policy allow network` for kit users).
- `environment.variables.OPENCODE_CONFIG: /home/agent/usai-config/opencode.jsonc`
  — tells OpenCode to load the namespaced config.
- `files/home/usai-config/opencode.jsonc` — the config payload, injected to
  `/home/agent/usai-config/opencode.jsonc`.

### Why a namespaced path + `OPENCODE_CONFIG`, not the global path

OpenCode merges config from **global** (`~/.config/opencode/opencode.json|jsonc`)
< **custom** (`OPENCODE_CONFIG`) < **project root**, later overriding earlier
per key. The official `opencode-model-runner` kit writes the *global* path.

In a fresh sandbox home there is nothing to clobber, so the original
anti-clobber rationale is weak. The stronger reason is **composition**: by
writing a namespaced file and pointing `OPENCODE_CONFIG` at it, this kit layers
*on top of* whatever the opencode template/kit writes globally, instead of
fighting it for the same path. That keeps us forward-compatible with upstream
changes — the explicit decision driver above. We deliberately do **not** write
`~/.config/opencode/opencode.json`.

### Secret handling (unchanged for now)

The kit declares the *requirement* for the key but never its value. The config
still reads `{env:USAI_API_KEY}`, and the user supplies it once with
`sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY`. Replacing
this with a kit `credentials[]` proxy-injection (so the real key never enters
the sandbox env, and the manual step disappears) is a deferred follow-up — it
needs live verification that USAi accepts proxy header injection.

### schemaVersion "2"

We target v2 (`caps.network`, top-level `environment`) per the current spec
library. If a deployed engine rejects v2, the fallback is v1
(`network.allowedDomains`); the spec fields are otherwise equivalent.

### Coexistence with `qsbx`

> **Update (2026-06-29):** `qsbx` now *uses* the kit rather than running a
> parallel path. `qsbx`'s `sbx create` passes `--kit <clone>`, and its home-dir
> symlinking no longer creates `~/.config/opencode/opencode.jsonc` — the OpenCode
> provider config arrives solely via the kit's `OPENCODE_CONFIG`. `qsbx` still
> mounts the clone read-only and symlinks the playbook's `AGENTS.md` and
> `~/.agents/skills`, which are not yet packaged as a kit. So there is now a
> single source of provider config (the kit), whether the sandbox is created by
> `qsbx` or by plain `sbx run --kit .`.

## Considered Options

1. **Kit in a `usai-opencode-provider/` subdirectory** — rejected: an extra
   nested path, and the repo already exists to *be* this config; the root is the
   natural kit boundary.
2. **`commands.initFiles` with inline config content** — rejected: the config is
   large (full provider block + generated model catalog) and is maintained/tested
   as a real `.jsonc` file; embedding a stringified copy in YAML would duplicate
   it and break the sync script's single source of truth.
3. **Write the global path directly** (matches opencode-model-runner) — rejected:
   loses the compose-don't-clobber property that protects upstream compatibility.
4. **Repo root is the kit; config under `files/home`; `OPENCODE_CONFIG`** —
   chosen.

## Consequences

### Positive

- Provider config is reproducible via `sbx run --kit .` without `qsbx`.
- Declarative, inspectable, PR-reviewed (CM-3, SA-10, SI-7).
- Composes with upstream opencode config instead of clobbering it.
- `qsbx` shrinks in scope over time (full migration is a follow-up).

### Negative / Residual

- The manual `sbx secret set-custom` step remains until the credentials-proxy
  follow-up lands.
- The playbook rules/skills are still delivered by `qsbx`'s read-only mount +
  symlinks, not the kit; full convergence waits on the planned second
  (playbook-content) mixin kit.
- v2 schema assumes a v0.34-era engine; older engines need the v1 fallback.

## Validation

- `npm test` (path move) and `node scripts/sync-usai-models.mjs --check
  --fixture` pass against the new config path.
- `sbx kit validate .` reports VALID (confirms v2 acceptance).
- `sbx run --kit . opencode <project>` starts OpenCode with no provider prompt;
  `sbx exec` confirms `OPENCODE_CONFIG` is set and the file is present at the
  namespaced path and not forced to the global path by this kit.

## Links

- Supersedes (in part): ADR-0004 (config source path)
- Related: ADR-0003 (model sync — sync script repointed), `spec.yaml`, `qsbx`
- [sbx kits overview](https://docs.docker.com/ai/sandboxes/customize/kits/)
- [OpenCode config precedence](https://opencode.ai/docs/config/#precedence-order)
