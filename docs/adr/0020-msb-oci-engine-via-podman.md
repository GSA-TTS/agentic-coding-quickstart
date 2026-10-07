---
title: "Ensure an OCI container engine in msb sandboxes via rootless podman, not docker-in-docker"
status: superseded
date: 2026-08-11
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-6", "CM-7", "SA-8", "SA-15", "SC-7", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
superseded_by: ["docs/adr/0030-agent-kits-on-devenv-base.md", "docs/adr/0031-interactive-acq-configure.md"]
---

# ADR-0020: Ensure an OCI container engine in msb sandboxes via rootless podman

> **Status: SUPERSEDED by [ADR-0030](0030-agent-kits-on-devenv-base.md) and
> [ADR-0031](0031-interactive-acq-configure.md).** The rootless-podman and
> podman-over-docker-in-docker decisions remain the design basis, but the
> implementation moved out of the msb adapter and into the neutral `oci-engine`
> patterns kit. OCI support is no longer installed by default on msb; users opt
> in through `acq configure`, `ACQ_EXTRA_KITS`, or `--kit`. This ADR is retained
> for adapter-era rationale and historical context.

## Context and Problem Statement

Agents working inside a sandbox sometimes need to run OCI images, for example
`docker run` or `docker compose`. The default msb image included Docker client
bits, but msb did not start `dockerd`, and Docker's `overlay2` storage driver did
not fit the already-overlay sandbox root without a dedicated disk-backed data
volume.

The adapter-era design tried to guarantee OCI support for every msb sandbox. That
made msb and sbx asymmetric: msb sandboxes received podman whether they asked for
it, while sbx sandboxes did not. ADR-0030 later moved capability provisioning to
neutral patterns kits, and ADR-0031 added a discoverable opt-in kit catalog.

## Superseding Decision

OCI support is now provided by the **`oci-engine` catalog kit**, sourced from the
same pinned `agentic-coding-patterns` bundle as the built-in kits. Users select it
with `acq configure` for a durable default, or pass its pinned kit ref through
`ACQ_EXTRA_KITS` / `--kit` for explicit per-run use.

This is a breaking change for msb users: new msb sandboxes no longer install an
OCI engine by default. Existing sandboxes keep whatever was already installed;
new sandboxes that need `docker run` or `docker compose` must opt into the kit.

## Decisions That Still Hold

1. **podman over docker-in-docker.** podman is daemonless, avoids managing a
   long-lived Docker daemon inside the sandbox, and does not require nested
   virtualization.
2. **Rootless execution.** The engine should run as the unprivileged `agent` user
   so in-sandbox containers do not require a rootful daemon or a sudo-wrapped
   client path.
3. **`docker` compatibility.** The user-facing command path should support common
   Docker workflows by routing `docker run` and `docker compose` to podman.
4. **Overlay-root handling.** The implementation must account for storage on an
   overlay root, preferring fuse-overlayfs when available and falling back to a
   safe working storage driver when necessary.
5. **Short-name safety.** Unqualified image-name behavior should fail closed or be
   explicitly configured by the kit, because silent short-name resolution can
   enable image substitution or typosquatting attacks.

## Consequences

- **Backend parity.** The same opt-in kit applies on sbx and msb instead of only
  the msb adapter provisioning podman.
- **Narrower default exposure.** The adapter no longer grants OCI-related device
  access unconditionally during provision or start. The kit owns those grants and
  can gate them on the engine being present, including revoking stale grants when
  absent.
- **Clearer default.** Sandboxes that do not need container-in-sandbox support no
  longer pay the create-time package-install cost or require package-mirror
  egress.
- **Explicit migration.** Users who relied on default msb podman must select
  `oci-engine` with `acq configure`, or pass the pinned kit ref through
  `ACQ_EXTRA_KITS` / `--kit`.

## Validation

- Offline tests cover catalog exposure, configured-name expansion to the pinned
  kit ref, configured kit persistence, fresh-shell `acq start` reload, and the
  absence of adapter-owned podman install/device grants when `oci-engine` is not
  selected.
- `scripts/verify-backends --only msb --oci-only` provisions a dedicated live msb
  sandbox with the `oci-engine` kit and verifies rootless podman, the `docker`
  alias, a local `docker build`, and a `docker run` when registry egress allows.

## References

- [ADR-0030: Agent kits on a devenv base](0030-agent-kits-on-devenv-base.md)
- [ADR-0031: Interactive `acq configure` for extra kits and token-scoping defaults](0031-interactive-acq-configure.md)
- [Known Failure Modes: `docker run` or `docker compose` missing inside a sandbox](../KNOWN_FAILURE_MODES.md#34-docker-run-or-docker-compose-missing-inside-a-sandbox)
