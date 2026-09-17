---
title: "Use Agent Kits on a Devenv-Enabled Agent-Less Base Image"
status: proposed
date: 2026-09-15
decision_makers: ["Bret Mogilefsky", "William Zujkowski", "Basilio Bogado"]
category: architecture
nist_controls: ["AC-6", "CM-2", "CM-3", "CM-6", "CM-7", "SA-8", "SA-15", "SC-7"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0030: Use Agent Kits on a Devenv-Enabled Agent-Less Base Image

## Context and Problem Statement

`acq` currently carries too much knowledge about specific coding agents and the
base images that happen to include them. Recent agent-kit work for additional
harnesses such as Pi, Prime Agent, and Goose exposes the tension: each new agent
should not require another special base image or another bespoke branch in core
`acq` behavior.

In parallel, the patterns repository has introduced a reusable devenv-capable
base-image pattern
([GSA-TTS/agentic-coding-patterns#395](https://github.com/GSA-TTS/agentic-coding-patterns/pull/395)):
**Nix (single-user) + devenv + direnv on a parametrized `BASE_IMAGE`**. That is
not necessarily a NixOS image. This is a useful property: Ubuntu and similar
general-purpose images are more familiar to many teams, and bring-your-own-image
users are likely to start from them, while still getting Nix/devenv/direnv on
top.

The proposed direction is to make the sandbox image provide a generic devenv
substrate, move agent installation and configuration into kits, and have `acq`
compose those declarations consistently across backends.

## Devenv Baseline and Upstream Impact

The substrate this ADR depends on is currently behind the releases that ship the
behaviors it leans on. `integrations/isolation/images/devenv/` in the patterns
repository pins its toolchain to `nixos-25.05` and installs `devenv` from that
channel, which resolves to **devenv 1.11.2**. devenv 2.x is present in neither
`nixos-25.05` nor `nixos-25.11`; it first appears in `nixos-26.05` (2.1.2) and in
`nixpkgs-unstable` (2.2/2.3). The devenv major is therefore part of the substrate
contract, not an incidental of the pin.

Changes since devenv 2.0 that bear directly on this ADR:

- **Process supervision.** devenv 2.0 makes its native Rust process manager the
  default (dependency ordering, readiness probes, watchdog, socket activation,
  restart policies). 2.2 adds a shared manager that other terminals attach to,
  cold-starts a named process, and stops with `devenv down`; 2.3 adds shutdown
  signal and grace. Detached manager state lives in `.devenv`, so the workspace
  needs a persistent path for it.
- **Activation.** 2.0 makes `devenv shell` self-reloading and direnv optional;
  2.2 keys auto-activation on `devenv.nix` rather than `devenv.yaml`, and
  `devenv init` no longer writes `.envrc` by default. A workspace must therefore
  carry a `devenv.nix` to auto-activate.
- **Out-of-tree environments.** 2.0 adds `--from`; 2.2 makes a `--from` source
  persistent per directory via `devenv allow`, carrying profiles and (for local
  sources) the source's full `devenv.yaml`. A substrate can now be referenced at
  run time instead of only baked into an image.
- **Ports.** 2.0 adds automatic port allocation and a strict-port mode; 2.3 adds
  a localhost reverse proxy with per-process hostnames, optional HTTPS via
  `mkcert`, and Linux capabilities for privileged binds.
- **Secrets.** 2.x bundles SecretSpec, a provider-based secret manager that
  prompts before releasing values.
- **Introspection.** `devenv eval`, `devenv build`, and `devenv tasks list`
  expose configuration and task state as JSON, and traces identify the invoking
  caller. These are documented, semver-versioned surfaces.
- **Footprint.** The devenv closure shrank from 528 MB to 376 MB and bundles
  Nix 2.35.2; the nixpkgs-wide ELF-note loader cache and a statically linked
  devenv build lower startup cost further.
- **Platforms.** 2.2 drops `x86_64-darwin`. The sandbox is Linux-only, so this
  affects contributor hosts but not the image matrix.

Consequences for the substrate and the kit contract:

- The base image must move to a channel that carries the intended devenv major,
  and the devenv major must be recorded as part of the substrate contract.
- Kit-declared processes and any status `acq` inspects must account for
  `.devenv` state persistence and for devenv's automatic quiet mode when it
  detects a coding agent (`DEVENV_NO_AI_AGENT=1` opts out).
- No existing kit uses devenv, so there is no 1.x-to-2.x migration cost for kit
  authors; kits can target 2.x directly.

## Decision Drivers

- **Reduce agent-specific behavior in core `acq`.** `acq` should orchestrate
  sessions, sandboxes, credentials, mounts, networks, and kits; it should not
  need built-in install/config knowledge for every agent harness.
- **Keep the base image generic and familiar.** A parametrized base image with
  Nix, devenv, and direnv layered on top lets teams use Ubuntu-like bases while
  preserving reproducible environment management.
- **Make agent support a kit-authoring problem.** Adding OpenCode, Pi, Goose,
  Prime Agent, or a future harness should primarily mean adding or selecting an
  agent kit.
- **Single-source the guest environment contract.** Kit declarations should
  describe files, environment, volumes, egress, startup steps, and entrypoints in
  one neutral vocabulary instead of threading backend-specific logic through the
  msb and sbx adapters.
- **Preserve backend neutrality.** The same high-level kit model should apply to
  both msb and sbx, even if each backend translates declarations differently.
- **Minimize base-image proliferation.** Agent-populated images may remain useful
  as cache optimizations, but should not define behavior.

## Considered Options

1. **Keep agent-populated base images and core `acq` agent knowledge.** This is
   the current shape. It works for a small set of agents, but does not scale as
   additional harnesses arrive.
2. **Use a NixOS-only base image.** This maximizes Nix consistency, but raises
   the adoption cost for teams more familiar with Ubuntu-like images and does not
   match likely bring-your-own-image usage.
3. **Use a parametrized base image with Nix, devenv, and direnv layered on top,
   plus agent kits.** This keeps the base image generic, preserves familiar OS
   choices, and moves agent-specific knowledge to kits.

## Proposed Decision Outcome

Proposed option: **Option 3**.

`acq` should target an agent-less, devenv-enabled base-image contract: Nix
(single-user), devenv, and direnv layered onto a parametrized `BASE_IMAGE`.
Agent installation, agent-specific configuration, and the agent entrypoint should
move into agent kits. `acq run <agent> <workspace>` may infer the matching agent
kit when the user does not explicitly provide it; `shell` remains the likely
special case because it is not an agent harness.

The high-level layering becomes:

```text
User / control plane
  CLI, Agor-like UI, future Factory UI

Normalized session API
  acq today, possibly split later

Harness adapter layer
  OpenCode, Pi, Goose, Prime Agent, future agents

Environment / capability layer
  kits + devenv

Sandbox control layer
  acq lifecycle, credentials, network, mounts

Backends
  msb, sbx

Generic devenv-enabled base
  parametrized BASE_IMAGE + Nix (single-user) + devenv + direnv
```

The corresponding kit model is expected to look like:

```text
acq
├─ backends: msb, sbx
├─ image: ACQ_IMAGE / BASE_IMAGE-derived devenv image
└─ kits
   ├─ built-in bundle
   │  ├─ neutral: CA trust, playbook, git signing, shared security policy
   │  ├─ OCI engine: podman or equivalent (optional, not in the default set)
   │  ├─ agent: opencode | pi | goose | prime-agent | ...
   │  └─ provider facts: USAi endpoint, key env var, model catalog
   └─ extra kits
      ├─ team kit
      └─ personal kit
```

This ADR is intentionally proposed, not accepted. It records the direction, the
review outcomes, and the questions that remain open before implementation.

## Lifecycle Sketch

At create time:

1. Resolve the backend, base image, agent, and kit set.
2. Merge kit declarations for create-time concerns such as egress and volumes.
3. Create the microVM from the generic devenv-enabled image.
4. Prepare the agent user and baseline guest contract.
5. Apply kits in order: built-in bundle first, then extra kits, with explicit
   conflict rules.
6. Let the selected agent kit install or expose the agent binary and declare its
   entrypoint.

At run or attach time:

1. Start the sandbox if needed.
2. Re-apply idempotent file, environment, and startup declarations as required.
3. Attach using the selected agent kit's declared command.
4. Surface any pending workspace activation (devenv or direnv) for the human to
   approve, per the activation contract.

## Review Outcomes

Review of the proposed direction converged on the following answers to the
questions above. They are recorded as the intended shape for implementation.

### Agent install contract

Agent binaries are installed at create time by their agent kit and **pinned by
content**: `nix profile install github:NixOS/nixpkgs/<rev>#<agent>` at the
substrate's declared rev (content-hashed, cached, and identical across arches),
or a sha256-pinned release binary for agents nixpkgs does not carry (the
goose-server pattern). Create-time cost is once per sandbox and is acceptable
next to the image pull, the Nix seed, and the first devenv build. Any published
agent-populated image is an artifact produced by applying the kit, so the image
and the kit cannot drift. The current create-time fallback
(`npm install -g opencode-ai` resolving to latest) is not the contract.

### Activation

Activation is a human trust decision. The base image ships Nix, devenv, direnv,
and the shell hook; the workspace owns its `.envrc`; `acq`'s job at run or attach
time ends at giving `exec` and `run` a login shell in the primary repository.
`acq` may detect an unactivated workspace, surface the command, and — only on
explicit confirmation — invoke it. It never auto-approves and never runs
activation non-interactively, **unless the user has explicitly opted in through
an `ACQ_` environment variable** (for example `ACQ_AUTO_ACTIVATION=1`), which
delegates the trust decision to the user's own environment. Because direnv and
devenv trust is path-scoped, per-worktree approval is a property of the
workspace, not something `acq` should globalize; preferring `devenv shell` or a
shared `--from` source keeps the trust unit at the project level.

### Create-time versus run-time

Create-time is anything the backend must know before boot: egress, volumes, and
ports. Run-time is files, environment, and startup steps, which are re-applied on
msb on every run.

Guest sizing (CPU and memory) is a separate kit-vocabulary gap tracked in its
own issue (see Links).

### Process supervision

The general in-guest supervisor is devenv's native process manager.
Agent-internal supervision (for example goose's `background:`) is a kit
implementation detail and is not modeled by `acq`. Out-of-guest services are the
host's concern and use podman-compose, chosen for cross-platform support
including Windows (devenv does not run on Windows), rather than a second devenv
supervision story.

### Kit roles

This ADR uses "provider kit", "agent kit", and "capability kit" as role labels
within the same neutral kit model. They are not separate schema families unless a
future ADR introduces role-specific validation.

A provider-role kit publishes provider facts as static data that `acq` can
consume before sandbox creation. A provider-role kit does not render
agent-specific configuration.

An agent-role kit installs or exposes an agent harness, declares its entrypoint,
and renders that harness's configuration from provider facts. An agent-role kit
does not define provider authority.

A capability-role kit adds shared sandbox capabilities such as CA trust, playbook
configuration, git signing, or OCI tooling.

A single kit may eventually carry multiple roles, but the default expectation is
one primary role per built-in kit so ownership and conflict behavior remain
clear.

### Provider configuration

`usai-provider` exports the provider **facts** (endpoint, key environment
variable, model catalog); each agent kit **renders** those facts in its own
configuration format. `acq` never merges agent configuration files — the agent
owns its config-merge semantics, for example OpenCode's project-layer deep merge
for its permission gate.

#### Provider facts artifact contract

The `usai-provider` kit is the authoritative source for USAi provider facts. It
publishes those facts as a static, non-executable metadata artifact in the kit
tree so `acq` can consume them before sandbox creation.

The initial artifact path is:

```text
provider-facts/usai.env
```

The file is parsed as data, never sourced or evaluated. `acq` accepts only known
keys and validates each value before use. The initial schema is:

```sh
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.gsa.usai.gov
ACQ_PROVIDER_BASE_URL=https://api.gsa.usai.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.gsa.usai.gov/api/v1/models
ACQ_PROVIDER_KEY_ENV=USAI_API_KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://gsa.usai.gov/console/key-management
ACQ_PROVIDER_BIND_HOSTS=api.gsa.usai.gov
```

`acq` may use provider facts only for sandbox lifecycle and credential plumbing:
backend secret binding, key validation, key-management guidance, and network/DNS
diagnostics. Agent-specific configuration rendering remains the responsibility
of agent kits.

Precedence is:

```text
explicit user --host/--env metadata > provider-facts artifact > acq fallback defaults
```

Until the pinned `usai-provider` kit includes this artifact, `acq` may carry
transitional fallback defaults for current backend behavior. Those fallback
defaults are not authoritative and must be removed or demoted once the artifact
is available at the pinned kit ref.

### Bring-your-own image contract

The contract must pin **where the Nix store lives** (`/nix`), not merely require
that nix, devenv, and direnv exist. A kit volume that seeds and shadows a baked
store (as the login.gov team kit does) breaks silently otherwise. The workspace
must also carry a `devenv.nix` so auto-activation applies.

### Egress and kit conflicts

Egress is **union-only and visible**: a personal kit must not widen network reach
without a trace. "Later wins" applies to environment and files, not to egress.

### Personal dotfiles

Personal preferences are a personal kit (via `ACQ_EXTRA_KITS`) that delivers
files, pinned `nix profile install` tools, and shell snippets. The neutral
`~/.rc.d` sourcing hook belongs in the base-image contract or a built-in neutral
kit, not in a team kit. Adopt the hook broadly, with documented guardrails: it is
kit-owned rather than user-editable, sourced for bash and zsh in deterministic
lexical order, handled through their native conf.d mechanisms for fish and
nushell, never used for secrets, and not used to duplicate what devenv already
provides inside a devenv shell. Documented use-cases: the hook itself (neutral
kit); agent shell integration that must exist outside a devenv shell; team tool
environment and completions; personal aliases and functions; and the
direnv/devenv hook.

### Agent kit inference

`acq run <agent> <workspace>` resolves the agent kit by name match against the
**built-in bundle only**, never against extra kits, so a team or personal kit
named after an agent cannot silently become that agent. The create output (or an
equivalent such as `acq kit ls`) prints the selected kit; an explicit `--kit`
wins; `shell` selects no agent kit.

### OCI engine kit

Rootless podman setup moves out of the msb adapter into an explicit OCI engine
kit usable by both backends, but it is **optional and not part of the default
bundle**: it is a create-time install plus egress for every sandbox, and many
kits never need it.

### Capabilities available through passwordless sudo

`acq` grants the agent passwordless sudo, so devenv features that need privilege
— binding privileged ports, the localhost proxy, `mkcert` CA trust, and
`linux.capabilities` — are technically available in-guest. They must be
explicitly declared by a kit and off by default, and treated like other in-guest
CA trust rather than enabled implicitly by a workspace.

### SecretSpec scope

SecretSpec is confined to in-sandbox usage. Host- and boundary-level secrets
remain in `acq`'s secret store; this ADR does not move the trust boundary into
SecretSpec.

### Stability contract during migration

The refactor must preserve: `--clone` semantics with the `ACQ_CLONE` and
`ACQ_WORKSPACE` guest markers
([ADR-0027](0027-neutral-clone-option.md)); startup steps re-applied on every msb
run; `ACQ_EXTRA_KITS` local paths applied after the built-in bundle; `acq exec`
and `acq shell` landing in the primary repository with a login shell; `ACQ_IMAGE`
as the image override; and `volumes:` mounted at boot before any exec. The
login.gov team's `scripts/verify` asserts each of these against a real `--clone`
sandbox on the active backend and can gate the refactor.

## Open Questions

- **Merge semantics beyond egress:** "later wins" is accepted for environment
  and files and "union" for egress, but volume and startup-step conflicts across
  built-in, team, and personal kits still need a rule.
- **Minimum bring-your-own-image contract:** the exact required contents and how
  `acq` verifies them (including `/nix`, `devenv.nix`, and the shell hook).
- **Migration sequencing:** the order in which `acq run opencode .` behavior
  changes, and which regression checks gate each step.

## Consequences

### Positive Consequences

- Core `acq` becomes less coupled to any one agent harness.
- New agent support can be developed and reviewed as kit behavior.
- Agent binaries are installed pinned by content and provider configuration is
  rendered per agent kit, so images need not bake any agent.
- The base-image story becomes simpler: generic devenv substrate first,
  agent-populated images only as optional cache optimizations.
- The same environment/capability model can span msb and sbx.
- Kit-authoring agents and humans can rely on the broader devenv ecosystem.

### Negative Consequences

- devenv becomes load-bearing architecture and must be documented, versioned, and
  verified as part of the sandbox contract.
- `.devenv` (evaluation cache and detached process-manager state) must be
  persisted for supervision and caching to work across runs.
- Privileged devenv capabilities (privileged binds, the localhost proxy, CA
  trust) are reachable through passwordless sudo and must be declared per kit and
  off by default.
- Kit merge semantics become more important and need security review.
- Debugging startup failures may require better introspection into generated
  devenv config and kit application order.
- Agent install steps must be idempotent and safe to re-run.

### Compliance Consequences

- **AC-6 / CM-7:** Moving capabilities into explicit kits supports least
  privilege and least functionality, provided optional kits cannot silently widen
  permissions; capability-widening features (privileged binds, CA trust) are
  declared and off by default.
- **CM-2 / CM-3 / CM-6:** A declarative kit and base-image contract improves
  configuration baselines and change traceability.
- **SA-8 / SA-15:** Separating harness, environment, and sandbox concerns makes
  architecture review and secure development responsibilities clearer.
- **SC-7:** Egress declarations are union-only and visible across built-in,
  team, and personal kits, and a personal kit cannot widen reach without a trace.

## Links

- [ADR-0010: acq Pluggable Backends](0010-acq-pluggable-backends.md)
- [ADR-0011: MSB Backend and Neutral Kits](0011-msb-backend-and-neutral-kits.md)
- [ADR-0018: MSB Balanced Egress Baseline](0018-msb-balanced-egress-baseline.md)
- [ADR-0020: Ensure an OCI container engine in msb sandboxes via rootless podman](0020-msb-oci-engine-via-podman.md)
- [ADR-0022: Neutral Image Override](0022-neutral-image-override.md)
- [ADR-0023: Neutral Volumes Kit Vocabulary](0023-neutral-volumes-kit-vocabulary.md)
- [ADR-0027: Neutral Clone Option](0027-neutral-clone-option.md)
- [GSA-TTS/agentic-coding-quickstart#475: neutral `resources:` kit field for guest CPU and memory](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/475)
- [GSA-TTS/agentic-coding-quickstart#473: discussion issue](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/473)
- [GSA-TTS/agentic-coding-patterns#395: devenv base image pattern](https://github.com/GSA-TTS/agentic-coding-patterns/pull/395)
