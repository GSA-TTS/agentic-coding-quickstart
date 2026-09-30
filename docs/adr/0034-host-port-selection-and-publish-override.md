---
title: "Per-Sandbox Host Port Selection and the --publish Override"
status: accepted
date: 2026-09-30
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-6", "CM-6", "SA-8", "SA-15", "SC-7", "SI-10", "SI-17"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0034: Per-Sandbox Host Port Selection and the `--publish` Override

## Context and Problem Statement

[ADR-0014](0014-neutral-port-publish-and-background-vocab.md) gave kits a neutral
`publishedPorts` vocabulary: an entry declares a **guest** port and may pin a
**host** port. The host side is optional precisely because the launcher, not the
kit, owns the host's port space — a kit that pinned `host:` would make every
sandbox built from it fight over one port.

Two problems, one cause.

**The host column's absence carried no meaning.** The neutral parser defaulted an
omitted `host:` to the guest port, so "the kit left the host port to the backend"
and "the kit asked for host port N" reached the consumer as the same record. On
msb that became `-p 6767:6767` for every sandbox from the kit. msb accepts the
duplicate mapping without complaint, so the second parallel sandbox **started
clean and was simply unreachable**: the first one owned the host port and answered
all traffic for it. Reproduced on acq main with msb 0.7.3 — two Paseo sandboxes,
both reporting `6767 -> host 127.0.0.1:6767`, only the first actually served.
(sbx was unaffected: its translator never re-emitted the host column, and sbx
assigns the host port itself.)

**There was no run-time way to pick a host port.** Even with per-sandbox
selection, a developer running several sandboxes in parallel cannot say "this
UI on 6868, that one on 6869" without editing the kit's `spec.yaml` — which
reintroduces the collision. Nor can a verification script request a
*known-free* port; the kit-verify step that tests real host→guest reachability
can only detect a collision and skip.

`--env` does not substitute for either: it targets the guest bind, and
`publishedPorts[].guest` is a literal with no interpolation, so moving the guest
port that way leaves acq publishing the original one.

## Decision Drivers

- **Absence must stay absence.** Only the consumer knows what "no host port
  requested" should become; a parser that invents a value destroys the
  distinction irrecoverably.
- **Silence is the failure mode to eliminate.** The bug's cost was not the
  collision, it was that nothing said so. Every outcome here must be visible: a
  chosen port, a refused port, or an "I could not tell".
- **An explicit request is never silently moved.** If the user or kit names a
  host port, acq either uses it or fails. Substituting another port would look
  like success while breaking whatever hardcoded that address.
- **Contention must be measured against reality.** The backend's declared
  mapping is not evidence a port is available.
- **Per-launch, not sticky.** The override belongs to one sandbox's creation.

## Considered Options

### For the collision (Part A)

1. **Consumer picks a free host port when the column is empty.** Chosen.
2. **Leave the default, fail when the port is taken.** Turns a silent collision
   into a loud one, but still makes parallel sandboxes from one kit mutually
   exclusive — the capability users actually want stays broken.
3. **Pass the duplicate through and let msb refuse it.** msb does not refuse it,
   which is the whole bug.

### For the override (Part B)

1. **`acq run/create --publish HOST:GUEST`, repeatable.** Chosen. Mirrors the
   existing post-hoc `acq ports --publish` spelling and the backend's own `-p`.
2. **An `ACQ_PUBLISH` env var.** Rejected: an exported value would silently
   re-pin the host port of *every* later sandbox in that shell, recreating the
   collision through a different door.
3. **Reuse the post-hoc path (`msb ssh serve` + `ssh -L`).** Rejected: that
   tunnel reaches the guest's **loopback**, while create-time publish reaches the
   guest interface IP. A kit that binds `0.0.0.0` for the create-time path would
   be reachable by accident of the tunnel rather than by the transport under
   test, and it needs a second command after create.

## Decision Outcome

**Chosen: A1 + B1.**

### Part A — the host column means what it says

`kit_spec_published_ports` emits the host column **verbatim**, empty when the kit
did not declare `host:`. Both source shapes do so: the neutral parser, and the
deprecated `backend_extras.sbx.publishedPorts` block, whose schema has no `host:`
key at all — "unspecified" is the only intent it can express, so encoding it as
host==guest was strictly wrong there too. The validator already tolerated an
empty host column, so it is unchanged.

The msb adapter then resolves the two intents differently:

| Host column | Behavior |
|---|---|
| empty | choose a **free** loopback host port, per sandbox |
| set | use it, or **fail the create** if it is already in use |

Published-port records now **accumulate across kits** and are mapped to `-p`
flags once after the kit loop, deduped by guest port with **last wins** —
mirroring the volumes union ([ADR-0023](0023-neutral-volumes-kit-vocabulary.md)).
Two kits publishing one guest port previously produced two conflicting `-p`
flags; and the single post-loop emission is the one place a CLI override can
compose.

### Part B — `--publish HOST:GUEST`

acq-owned, repeatable, extracted before dispatch alongside `--image`
([ADR-0022](0022-neutral-image-override.md)) and `--clone`
([ADR-0027](0027-neutral-clone-option.md)), and honored only **before the `--`
separator** so an identical flag meant for the inner agent passes through
verbatim. The raw flag must never reach a backend CLI: `msb create` has its own
`-p` that the adapter synthesizes, and `sbx create` has no equivalent.

Overrides join the record list **after** every kit's, so the guest-keyed
last-wins union makes them beat both a kit's pinned host port and the port acq
would have chosen.

`HOST:GUEST` is required in full. A bare `--publish 6868` is ambiguous, and the
guest port is the kit's property rather than the launcher's, so acq refuses it
instead of guessing. Both sides are range-validated (SI-10) before reaching an
argv — digits-only guard and a length cap **first**, because `[ "$p" -ge 1 ]`
aborts the shell on a pathologically long digit string, and `$((...))` is worse:
`$((0080))` is a fatal invalid-octal error. A leading zero is refused outright
rather than silently accepted as decimal.

### The contention probe

Availability is measured by connecting to the **real host listener** — a bash
`/dev/tcp/127.0.0.1/PORT` redirect in a subshell — not by reading msb's declared
mapping. `msb inspect` reports what msb was *asked* for, and that record survives
unchanged when another process owns the port; that reporting gap is
[GSA-TTS/agentic-coding-quickstart#520](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/520)
and is deliberately not addressed here.

The literal IPv4 loopback is used, never `localhost`: a `::1`-first resolution
against an IPv4-only listener does not fail fast, it hangs.

The probe has three verdicts, and `unknown` is a real one: a bash built without
network redirection answers "No such file or directory". An unprobeable shell
gets **one** notice and the publish proceeds — the behavior before this check
existed. Fabricating `free` would reintroduce a silent collision; refusing to
create would break hosts that worked yesterday over a check acq cannot run.

### Two explicit refusals instead of silence

- **sbx.** sbx chooses the host port itself and exposes no knob (its kit-spec
  ports block keys on the guest port only), so honoring `--publish` there would
  be a lie. acq errors out and names the post-hoc `acq ports NAME --publish`
  alternative, which does work on both backends.
- **Re-attach.** The mapping lives in the create argv, so a re-attach cannot move
  it. Like `--image` and `--clone`, the flag prints an "ignored when re-attaching"
  note pointing at `acq ports` and at recreating the sandbox.

A `--publish` for a guest port no applied kit declares is **honored with a
note**: an explicit request is respected, but a mistyped guest port would
otherwise map a port with nothing behind it and look like a working publish.

## Consequences

- **Positive:** parallel sandboxes from one kit each get a reachable host
  address; predictable addresses are available per launch; a contended port fails
  visibly instead of producing a dead mapping; two kits publishing one guest port
  no longer emit conflicting flags.
- **Positive (test coverage):** a verify step that needs real host→guest
  reachability can now request a known-free host port instead of skipping when
  acq's choice collides.
- **Negative / trade-off:** the create-time host port is now **non-deterministic
  by default** for a kit that omits `host:` — scripts must read it back from
  `acq ports` (they already should have; the old value only looked stable) or pin
  it with `--publish`.
- **Negative:** the probe is a point-in-time check. A port free at probe time can
  be taken microseconds later, in which case msb's own create fails — loudly.
  Closing that window would require holding the port open across create, which
  is exactly what would prevent msb from binding it.
- **Scope:** `--publish` applies at **create only**, and on **msb only**. No env
  var. The post-hoc `acq ports --publish` tunnel
  ([ADR-0015](0015-msb-post-hoc-port-publish-via-ssh.md)) is untouched and is
  never used as a fallback.
- **Out of scope:** liveness annotation on `acq ports` output (see the tracking
  issue in Links); any change to the kits themselves, which live in the patterns
  repo.

## Links

- Driver: [#334](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/334)
  (run-time HOST port override; its second comment corrects the premise and
  reports the msb collision)
- Probing the host rather than the backend's declared mapping:
  [#520](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/520)
  (`acq ports` reports declared configuration, not liveness) — motivation only,
  not fixed here
- Corroborating evidence (no dependency; acq-side change only):
  [agentic-coding-patterns#453](https://github.com/GSA-TTS/agentic-coding-patterns/pull/453)
- Builds on: [ADR-0014](0014-neutral-port-publish-and-background-vocab.md)
  (neutral `publishedPorts`), [ADR-0023](0023-neutral-volumes-kit-vocabulary.md)
  (the cross-kit last-wins union this mirrors),
  [ADR-0022](0022-neutral-image-override.md) /
  [ADR-0027](0027-neutral-clone-option.md) (the acq-owned create-time flag
  pattern), [ADR-0015](0015-msb-post-hoc-port-publish-via-ssh.md) (the post-hoc
  tunnel this deliberately does not fall back to)
- Guest-bind prerequisite for create-time publish to be reachable at all:
  [#333](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/333)
