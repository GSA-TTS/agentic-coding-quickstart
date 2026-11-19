---
title: "Require explicit restart recovery for MSB secret updates"
description: "Separate credential storage from active sandbox injection and prevent implicit fleet restarts"
status: proposed
tier: 2
date: 2026-11-17
decision_makers: ["Bret Mogilefsky"]
category: security
nist_controls: ["IA-5", "CM-3", "SI-17"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
related_files: ["acq.backends/msb.sh", "docs/KNOWN_FAILURE_MODES.md"]
---

# ADR-0043: Explicit MSB secret-update recovery

## Context and Problem Statement

Saving a new credential in acq's host store does not establish that an existing
MSB sandbox uses it. MSB can reject a modification requiring restart, while acq
previously hid the error and returned success. A global update also resolved
one global value for all sandboxes instead of preserving scoped precedence.

## Decision Drivers

- Credential values must never enter argv or diagnostic output.
- Failed injection must produce a failure status, including partial fleet failure.
- Updating a global credential must not implicitly interrupt running processes.

## Considered Options

1. Always request restart during a global update: rejected as disruptive.
2. Report failed application and offer an explicit named-sandbox restart: chosen.
3. Leave storage-only success: rejected because authentication remains broken.

## Decision Outcome

Resolve each target's value and endpoint separately. Preserve successful storage
but fail the command if any target rejects application. Report safe sandbox and
service context rather than forwarding untrusted backend output.

For MSB, `acq secret set SANDBOX SERVICE --restart` explicitly permits restarting
that sandbox. Supply its other credentials from the existing host-side binding
resolver in a subshell. Do not support global restart. See ADR-0012 for the
backend-neutral rotation seam.

## Consequences

- Live rotation remains non-disruptive when MSB accepts it.
- Operators get actionable failures and can recover without recreating a sandbox.
- Explicit restart interrupts running processes. Credentials bound outside acq
  must still be supplied by the operator's environment; MSB remains authoritative
  about whether the modification can be applied.
- Stub regressions prove error propagation and command shape, not a live
  authentication round trip; live verification requires a sandbox-capable host.
