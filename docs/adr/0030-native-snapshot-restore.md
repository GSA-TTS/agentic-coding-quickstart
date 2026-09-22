---
title: "Expose native stateful snapshot/restore through acq"
status: accepted
date: 2026-09-22
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SA-17"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0030: Expose native stateful snapshot/restore through acq

## Context

Agent sandboxes sometimes need to survive a planned host reboot or recreation
without losing the running agent's context. A selective backup of one tool's data
directory is not enough: OpenCode, for example, keeps conversation state in its
own XDG data directory while Paseo keeps only metadata that points to it.

The msb backend has a native full-state snapshot primitive: `msb snapshot create
--full` captures disk, memory, execution, and device state. Its restore path can
also bind host resources at restore time, including `--vsock`, which is the same
mechanism acq uses for host SSH-agent forwarding. This matters because the msb
SSH-agent route is otherwise create-time only; after a host reboot the old host
socket endpoint may be stale.

The sbx local `template save` / `template load` model is different: it creates a
reusable template. Local capture is disk-only; memory plus microVM checkpoint is
cloud-only, and the documented local flow does not expose restore-time host
resource rebinding. That does not meet the stateful restore contract.

## Decision

Add acq-owned `snapshot` and `restore` verbs that are backed by native backend
primitives only when the backend supports full stateful restore with acq-managed
host-resource re-plumbing.

- msb is supported: `acq snapshot NAME [OUT]` maps to `msb snapshot create
  --full -o OUT` and writes a date-stamped archive when OUT is omitted. `acq
  restore NAME [SNAPSHOT]` maps to `msb restore`; when SNAPSHOT is omitted, acq
  restores the newest date-stamped archive for NAME. acq supplies current
  host-resource bindings internally.
- sbx is unsupported for these verbs. It fails closed with a clear unsupported
  message rather than offering a disk-only degraded mode.
- Restore does not expose user-facing `--vsock`, `--volume`, or `--port` flags.
  acq owns the re-plumbing: it re-derives the current SSH-agent vsock route and
  asks the backend to inherit validated source-local resource records for the
  rest.

## Consequences

- A supported backend can preserve live agent context across planned recreation
  without a per-application backup manifest.
- msb restore can re-derive the current host SSH-agent socket route, avoiding the
  stale create-time vsock endpoint that occurs after host reboot.
- Unsupported backends remain honest: the command fails clearly rather than
  pretending disk-only templates are equivalent to full stateful restore.

## Validation

- Offline unit tests cover dispatch, capability flags, unsupported sbx behavior,
  and the msb command shapes.
- Live validation requires an msb-capable host and should exercise: create an
  agent sandbox, snapshot it, remove/recreate through restore, verify agent
  history is present, and verify SSH signing works with the restored vsock route.
