---
title: "msb's shell agent and the ro-mount canary use acq's base image"
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

# ADR-0052m: msb's `shell` agent and the ro-mount canary use acq's base image

## Context and Problem Statement

ADR-0030 makes one agent-less devenv image acq's base for every agent, and the
Python backend creates from that image directly. The Bash msb backend kept an
older rule: `opencode` used the pinned devenv image, but every other agent,
including the `shell` positional, resolved to Docker's
`docker.io/docker/sandbox-templates:<agent>-docker` template. So `acq create
shell` meant a different image on `ACQ_IMPL=bash` than on the Python acq, and
the msb ro-mount canary defaulted to Docker's `shell-docker` while its own
comments described "acq's default msb image".

The Tier-3 oracle now creates from acq's default image (ADR-0051m), so the
qualification and the Bash backend disagreed about what acq's base is.

## Decision

- `acq.backends/msb.sh`'s `_acq_msb_resolve_image` maps the `shell` positional to
  `ACQ_DEFAULT_OPENCODE_DEVENV_IMAGE`, the same pin the Python backend uses, with
  `_ACQ_MSB_RESOLVED_IMAGE_SOURCE="acq-base-default"`. Precedence above it
  (`ACQ_MSB_IMAGE`, neutral `--image`/`ACQ_IMAGE`) is unchanged.
- `scripts/qualify-msb-ro-mount` defaults its image to the same pin, so the
  canary tests the image a real sandbox uses.
- A Python test holds the canary's default equal to
  `common.OPENCODE_DEVENV_IMAGE`, so the two cannot drift.

The fallback for a missing *agent-specific* image still uses Docker's
`shell-docker` (`_ACQ_MSB_DEFAULT_IMAGE`): that path is about a different
agent's template being unavailable, not about the `shell` base.

## Consequences

- `acq create shell` now creates from acq's pinned devenv image on both
  implementations, so they agree and the Bash backend no longer depends on
  Docker's `shell-docker` template for the `shell` agent.
- The ro-mount canary pulls and tests acq's base image, matching the cell.
- Other agents (`claude`, `codex`, …) still resolve to Docker's
  `<agent>-docker` template on the Bash backend, and their missing-image
  fallback is unchanged; moving those to acq agent kits is a separate change.

## Alternatives considered

- **Change `_ACQ_MSB_DEFAULT_IMAGE` to the devenv pin.** Rejected: that variable
  is also the fallback for a missing agent-specific template, and changing it
  would silently turn a failed `claude` image into a plain shell.
- **Leave the Bash on Docker's template.** Rejected: it contradicts ADR-0030 and
  makes `acq create shell` backend-dependent.

## Links

- Issue: `mogul/agentic-coding-quickstart#247`
- Related: ADR-0030 (agent kits on an agent-less devenv base), ADR-0051m (sbx
  base kit and the oracle's image), ADR-0022 (image precedence).
