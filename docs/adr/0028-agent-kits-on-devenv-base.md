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

# ADR-0028: Use Agent Kits on a Devenv-Enabled Agent-Less Base Image

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
   │  ├─ OCI engine: podman or equivalent container-run capability
   │  ├─ agent: opencode | pi | goose | prime-agent | ...
   │  └─ agent-aware: USAi/provider config in the selected agent's format
   └─ extra kits
      ├─ team kit
      └─ personal kit
```

This ADR is intentionally proposed, not accepted. It records the direction and
questions for discussion before implementation.

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
4. Activate the workspace's devenv/direnv environment according to the final
   contract.

## Open Questions

- **Activation contract:** Does `acq` run `devenv up`, `devenv shell`,
  `direnv allow`, or a combination? Which step belongs to the base image, the
  kit layer, and the project workspace?
- **Process supervision:** Can devenv's process supervision replace ad hoc
  supervisor loops used by related projects, and if so, what does `acq` need to
  guarantee?
- **Create-time versus run-time declarations:** Which kit declarations must be
  resolved before VM creation, and which can be re-applied safely on every run?
- **Kit ordering and conflicts:** What does "later wins" mean for security-
  sensitive fields such as egress, environment variables, volumes, and startup
  commands?
- **Agent kit inference:** How should `acq run opencode .` infer an OpenCode
  agent kit? How does the user inspect, override, or disable that inference?
- **Agent-aware provider config:** Should `usai-provider` remain one kit that
  emits configuration in the selected agent's format, or should each agent kit
  own its provider-config translation?
- **OCI engine kit:** Should rootless podman setup move out of the msb adapter
  into a default OCI engine kit that can be applied consistently by both
  backends?
- **Bring-your-own images:** What is the minimum base-image contract `acq` can
  require when users provide their own `BASE_IMAGE` or `ACQ_IMAGE`?
- **Dotfiles and personal configuration:** Are host dotfiles best represented as
  devenv configuration, a personal kit, a mounted volume, or explicit copy-in
  behavior?
- **Compatibility:** How much current `acq run opencode .` behavior must remain
  unchanged during migration?

## Consequences

### Positive Consequences

- Core `acq` becomes less coupled to any one agent harness.
- New agent support can be developed and reviewed as kit behavior.
- The base-image story becomes simpler: generic devenv substrate first,
  agent-populated images only as optional cache optimizations.
- The same environment/capability model can span msb and sbx.
- Kit-authoring agents and humans can rely on the broader devenv ecosystem.

### Negative Consequences

- devenv becomes load-bearing architecture and must be documented, versioned, and
  verified as part of the sandbox contract.
- Kit merge semantics become more important and need security review.
- Debugging startup failures may require better introspection into generated
  devenv config and kit application order.
- Agent install steps must be idempotent and safe to re-run.

### Compliance Consequences

- **AC-6 / CM-7:** Moving capabilities into explicit kits supports least
  privilege and least functionality, provided optional kits cannot silently widen
  permissions.
- **CM-2 / CM-3 / CM-6:** A declarative kit and base-image contract improves
  configuration baselines and change traceability.
- **SA-8 / SA-15:** Separating harness, environment, and sandbox concerns makes
  architecture review and secure development responsibilities clearer.
- **SC-7:** Egress declarations must fail closed and remain auditable when merged
  across built-in, team, and personal kits.

## Links

- [ADR-0010: acq Pluggable Backends](0010-acq-pluggable-backends.md)
- [ADR-0011: MSB Backend and Neutral Kits](0011-msb-backend-and-neutral-kits.md)
- [ADR-0018: MSB Balanced Egress Baseline](0018-msb-balanced-egress-baseline.md)
- [ADR-0020: Ensure an OCI container engine in msb sandboxes via rootless podman](0020-msb-oci-engine-via-podman.md)
- [ADR-0022: Neutral Image Override](0022-neutral-image-override.md)
- [ADR-0023: Neutral Volumes Kit Vocabulary](0023-neutral-volumes-kit-vocabulary.md)
- [GSA-TTS/agentic-coding-quickstart#473: discussion issue](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/473)
- [GSA-TTS/agentic-coding-patterns#395: devenv base image pattern](https://github.com/GSA-TTS/agentic-coding-patterns/pull/395)
