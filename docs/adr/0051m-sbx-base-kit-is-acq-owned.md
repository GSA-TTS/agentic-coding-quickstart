---
title: "acq supplies the sbx sandbox base kit instead of a built-in agent"
status: accepted
date: 2026-11-12
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-5", "CM-7", "SI-7"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0051m: acq supplies the sbx sandbox base kit instead of a built-in agent

## Context and Problem Statement

`sbx create`'s first positional is either a built-in agent name or a sandbox kit
reference. acq passed a built-in agent — `shell` for the generic path, the
agent's own name otherwise — and layered its own translated kits on top with
`--kit`. This worked while both sides were v1/v2 kits.

sbx now publishes every built-in agent as a **v3** kit (`docker.io/sbx/shell:latest`
and `docker.io/sbx/opencode:latest` are both `schemaVersion: 3`; all published
`sbx/shell` tags, back to 2026-10-26, are v3). acq translates its neutral kits to
**v2**. sbx refuses to mix formats in one sandbox:

```text
error: resolve kits: cannot mix v3 kits with v1/v2 kits in one sandbox;
compositions are single-format (v3: shell; v1/v2: …)
```

So every `acq create` on sbx began failing at create. This surfaced during the
Tier-3 Windows re-qualification, but it is cross-platform (the failure is in the
create command, not the OS). Downgrading the sbx CLI does not help: the agent is
a floating OCI kit (`:latest`), so 0.51.0 resolves the same v3 shell kit as 0.53.0.

acq already owns its **image** (`common.OPENCODE_DEVENV_IMAGE`, ADR-0030). The
missing piece was the **base kit**: acq had nothing of its own to pass, so it
borrowed Docker's, and inherited Docker's kit-format churn.

## Decision

acq generates its own `kind: sandbox` base kit and passes it as the first
positional, so a create no longer names a built-in sbx agent:

- `kit_sbx.base_sandbox_spec(image)` emits a v2 `kind: sandbox` kit whose
  `sandbox.image` is the resolved base image (acq's pinned default, or an
  `--image` override) and whose workload is a plain login bash
  (`-c 'exec "$@"' bash bash -l`).
- `kit_sbx.prepare(kits, image)` publishes it under the state directory
  (`generated/acq-base.<digest>`, content-keyed so an image change is a new
  directory) alongside the translated mixins, the git identity kit and the
  startup barrier kit, and returns it as `CreateKits.base_dir`.
- `lifecycle._new_sbx_sandbox` passes `prepared.base_dir` as the first positional
  for the agents acq fully owns: `shell` (the base workload itself) and
  `opencode` (its pinned kit installs OpenCode — on the default image, and on top
  of a custom one). Any other agent still uses its sbx built-in for now.
- The Tier-3 cell oracle no longer passes
  `--image docker.io/docker/sandbox-templates:shell-docker`, so it creates from
  acq's default image (`ACQ_IMAGE` is dropped by the oracle's isolated
  environment too). `qualification.host` records that same pin as the
  transcript's `image=` label, and a test keeps the two equal.

The base kit is emitted as v2 to match the translated mixins. acq owning the
base means acq also owns the format: a future sbx format bump changes acq's
generator, not every create.

## Consequences

- Positive: `acq create` works again on current sbx **for the Python
  implementation** (`ACQ_IMPL=python`, the Windows default); the sbx cell oracle
  passes end to end; an interrupted format change on Docker's side cannot
  silently break acq's base a second time, because acq no longer consumes a
  built-in agent kit.
- Negative / tracked: the Bash implementation (`acq.backends/sbx.sh`, still the
  default on macOS/Linux) keeps the built-in-agent positional and is still broken
  by the v3/v2 mix. It is recorded in `docs/KNOWN_FAILURE_MODES.md` §99 and
  tracked in `mogul/agentic-coding-quickstart#250`; porting the base kit to Bash or
  flipping the POSIX default to Python is
  the follow-up.
- Positive: the sandbox's base image is exactly acq's resolved image, even when
  the base kit is what supplies it, so `--image` and the default behave the same.
- Negative / bounded: agents that acq has no install kit for (`claude`, `codex`,
  …) still pass their sbx built-in agent and remain exposed to the same mix
  until they gain acq agent kits. `shell` and `opencode` — the qualification and
  primary paths — are fixed.
- Positive: the Tier-3 cell now qualifies acq's own default base image, not
  Docker's template image, so a green sbx cell is evidence for what acq ships.
  The transcript's `image=` label is held equal to that pin by a test, so the
  harness and the CLI cannot silently drift apart.

## Alternatives considered

- **Translate every acq kit to v3.** Keeps acq consuming Docker's built-in agent
  and inherits the next format bump; acq would still have to track Docker's
  agent-kit schema change for change.
- **Downgrade sbx below the v3 change.** Rejected: the agent kit is floating, so
  the CLI version does not select the kit format; 0.51.0 and 0.53.0 fail
  identically.
- **Pin the shell kit to a pre-v3 digest.** Rejected: there is no pre-v3
  `sbx/shell` artifact, and pinning a built-in agent would still leave acq
  dependent on Docker's kit.

## Amendment to ADR-0022 (Option 3)

ADR-0022 Option 3 rejected synthesizing a `kind: sandbox` kit to implement the
neutral `--image`: `--template` is the purpose-built primitive for the image, and
a sandbox kit "would collide with acq's four built-in mixin kits". That rejection
stands for image selection: `--image` still maps to `-t` here.

This ADR synthesizes a sandbox kit for a different purpose — replacing the
built-in **agent** positional, so a create is composed from acq's own kits. It is
passed as `sbx create`'s first positional, not as `--kit`, so it does not collide
with the mixins it sits beside, and the collision Option 3 named does not arise.

## Links

- Issue: `mogul/agentic-coding-quickstart#247`
- Related: ADR-0030 (agent kits on an agent-less devenv base), ADR-0044m
  (Tier-3 qualification), ADR-0048m (Windows defaults to the Python
  implementation).
- Evidence: v2 base kit validated with `sbx kit inspect --offline`; `acq create`
  and the sbx cell oracle both pass on sbx 0.51.0 with the default and the
  Docker template image.
