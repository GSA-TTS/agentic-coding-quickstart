---
title: "Stage msb kit startup commands as a create-time script for restart durability"
status: accepted
date: 2026-08-02
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "CM-7", "SA-8", "SA-15", "SI-10", "SI-17"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0017: Stage msb kit startup commands as a create-time script for restart durability

## Context and Problem Statement

On the msb backend, kit `startup` commands (including long-lived `background`
supervisors) are applied imperatively via `msb exec` at provision time and on
the acq re-attach heal loop. They do **not** re-run on a microsandbox-native
restart (`msb stop` + `msb start`, or a host reboot that restarts the guest),
because acq never populates microsandbox's persisted `LaunchConfig.startup`. A
sandbox that is stopped and started back up *outside* acq therefore comes back
without its kit-defined background services running.

ADR-0011's msb adapter deliberately kept kit-command injection exec-based and
parked a `--script`/`--script-path` staging approach (recorded in the
`acq.backends/msb.sh` design note). This ADR revisits that parked decision for
the **narrow, specific case the note itself named as the one clean win**: a
create-time, re-runnable command body staged as a script file — because that is
exactly the mechanism microsandbox needs to re-run startup on restart.

## Decision Drivers

- Restart durability: a stopped-then-started msb sandbox must bring its kit
  background services back up without an `acq run` re-attach (the concrete
  failure motivating this: a supervised UI stack goes dark after `msb stop`/
  `msb start`).
- Preserve the ADR-0011 exec path for install (run-once, root-owned marker
  gating) and for mid-life kit apply/heal — a create-time flag cannot inject
  into an already-running sandbox, so the mid-life path stays exec-based.
- SI-10 untrusted-kit-input hardening: staging a command body as a file
  (`--script-path`) avoids assembling a shell string from kit-provided content.
- Keep the neutral `hybrid/v1` kit vocabulary and idempotency/marker semantics
  unchanged; no new kit-author-visible surface.
- Minimize divergence: reuse the existing translation/argv pipeline rather than
  introducing a parallel command model.

## Considered Options

1. **Give acq a `start`/`restart` verb** that re-drives the exec-based apply on
   every resume. Keeps a single dispatch path, but only heals when the user
   goes *through acq* — a raw `msb start` or a reboot-driven restart still comes
   back bare, so it does not close the stated gap.
2. **Stage kit `startup` commands as a create-time script registered with
   microsandbox** (`--script-path`), so microsandbox re-runs it on every
   `start_detached` (both `msb start` and `msb restart`). Keep the exec path for
   install and mid-life apply.
3. **Combination** — native create-time persistence for the restart path *plus*
   an acq resume verb for the in-place heal path.

## Decision Outcome

Chosen option: **Option 2**, because it is the only option that makes startup
re-run on a microsandbox-native restart (the actual gap), and it does so through
the exact create-time-only, re-runnable-script case that the ADR-0011 design
note identified as the clean, contained win for `--script-path`. The exec path
is retained unchanged for install (run-once marker gating) and mid-life
apply/heal, so the two mechanisms are complementary, not a fork: create-time
staging owns the reboot/`msb start` path; exec owns the in-place kit-add path.

This ADR is delivered in two increments. The first (this ADR's enabling change)
introduces the create-time `--script-path` staging of startup commands and
rewrites the design note; it is runtime-neutral. The second wires that staged
script into microsandbox's persisted startup so the observable restart-durable
behavior lands.

### Positive Consequences

- Kit `startup`/`background` services survive `msb stop`/`msb start` and reboots
  without an `acq run` re-attach.
- Command bodies are staged as files, not interpolated shell strings (SI-10).
- No change to the neutral kit vocabulary or to install/idempotency semantics.

### Negative Consequences

- Two staging mechanisms now coexist (create-time script for startup persistence
  + exec for install and mid-life). The design note documents the boundary so a
  future maintainer does not collapse them incorrectly.
- The create-time script must reproduce the per-command run-as-user and
  non-interactive git guards the exec path applies at invocation, so that logic
  is shared/duplicated into the staged body.

### Compliance Consequences

- SI-10 (input validation): kit-provided command bytes are staged as a file
  body and executed as registered scripts rather than interpolated into an
  `sh -c` string.
- SI-17 (fail-safe): background supervisors are restored deterministically after
  an unplanned restart, reducing silent post-reboot degradation.
- CM-2/CM-3/CM-6: sandbox startup configuration becomes part of the persisted,
  reproducible baseline rather than an imperative one-shot.

## Links

- ADR-0011 (msb backend and neutral hybrid/v1 kit translation) — establishes the
  exec-based kit-command staging this ADR augments for the startup case.
- ADR-0014 (neutral port-publish and background-command vocabulary) — defines the
  `background` command flag whose supervisors this ADR keeps alive across
  restarts.
- `acq.backends/msb.sh` design note — rewritten to reflect this decision.
- `docs/explorations/acq-design.md` — will be reconciled with the
  restart-durable behavior by the follow-up increment that wires the persisted
  startup. Increment 1 (this ADR) ships only create-time script *staging* and
  does not touch that document or introduce restart-durable behavior.
