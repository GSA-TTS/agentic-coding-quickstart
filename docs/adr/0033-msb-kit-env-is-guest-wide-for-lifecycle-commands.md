---
title: "msb kit environment[] is guest-wide for kit lifecycle commands"
status: accepted
date: 2026-09-29
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-3", "AC-6", "CM-2", "CM-6", "CM-7", "SA-8", "SA-15", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0033: msb kit `environment[]` is guest-wide for kit lifecycle commands

## Context and Problem Statement

On msb, a kit's lifecycle commands (`install`, `initFiles`, `startup`) ran with only
**that kit's own** `environment[]`. Sessions were already whole-guest — acq replays
the merged `/var/lib/acq/kit-env` marker on `run`/`attach`/`shell` (ADR-0011's
2026-08-26 update) — but commands were not.

That split is invisible until a kit's command outlives itself. A daemon kit starts its
supervisor from a `background: true` startup command, so every agent that daemon spawns
inherits only the daemon kit's env: another kit's `OPENCODE_CONFIG` (agent instructions
plus a default-deny permission layer) was silently absent from those agents while the
injected credentials were still present — a quiet loss of a policy control, and
sessions still looked correct, so smoke tests passed.

**The order-independence trap.** The marker is appended per kit *inside the same loop
that runs that kit's commands*, so "read the merged marker when running commands" is
correct only when the env-declaring kit happens to be applied first, and silently
wrong in the reverse order. Any fix must establish the merged set before the first
kit is applied.

## Decision Drivers

- A kit must not silently drop another kit's policy config from the env of agents it
  launches, and the result must not depend on kit application order (AC-3, AC-6, CM-6).
- One kit must not weaken another kit's hardening: the non-interactive git guards are
  per-kit safety, not shared config (CM-7).
- Kits must not each have to source a marker file; the adapter owns the threading.

## Considered Options

**Pre-pass over the full kit set — chosen.** A **per-kit marker read** is
order-dependent by construction (see the trap above), fixing the reported case in one
kit order only. Having each kit source the marker itself is opt-in — a kit that
forgets is silently broken — and pushes an adapter concern into every kit.

## Decision Outcome

Kit `environment[]` is **guest-wide configuration**: every kit lifecycle command runs
with the merged env of the full effective kit set, last-value-wins — the same
resolution sessions replay.

| Path | Source of the merged env |
|------|--------------------------|
| `acq_backend_provision` (create) | pre-pass over every fetched kit spec, before the first apply |
| `acq_backend_ensure_kits_applied` (heal / `start`, `restart`, re-attach) | same pre-pass; refs resolved in one loop, merged, applied in a second |
| `acq_backend_apply_kit` (`acq kit apply`) | no full set exists — the sandbox's already-persisted merged marker value |
| neither available (marker absent/unwritable) | this kit's own `environment[]` — the pre-existing behavior |

The mid-life fallback suits an additive add: the new kit's entries reach the marker
*before* its commands run, and the read is last-value-wins, so it still overrides.

**Guard ownership is per kit, tracked by value.** acq injects `GIT_TERMINAL_PROMPT=0` +
`GIT_ASKPASS`/`SSH_ASKPASS=/bin/false` onto kit commands unless *that* kit declared
`GIT_TERMINAL_PROMPT` itself; a prompting kit command with no credential blocks
provision forever (observed with the playbook kit). So a command may only ever receive
**its own kit's value** for a guard name — and the ownership record must be that kit's
guard **tokens** (`NAME=value`), not the names it declared, because the merge has
already collapsed a duplicate name to the *last* kit's value:

> Kit A declares `GIT_TERMINAL_PROMPT=0` and owns a command; a later kit B declares
> `=1`. Under name-only ownership A's own command ran with B's opt-out *and* no
> `GIT_ASKPASS`/`SSH_ASKPASS` at all — worse than before the change, where A correctly
> got its own `0`.

So: strip every guard-name token from the merged set whoever contributed it, re-add this
kit's own, then append acq's values unless this kit set `GIT_TERMINAL_PROMPT`. Both
collision shapes (name and value) are closed; a kit's own override still stands for its
own commands. The staged `--script-path` body shares the same helper so the paths cannot
drift — **that path is inert today** (ADR-0017), so it fixes no live symptom; it exists
so ADR-0017's re-verification trap cannot resurface this bug unnoticed.

## Consequences

- **Broader blast radius per var.** A var one kit declares now reaches every kit's
  commands — intended (it matches sbx, where `environment.variables` is sandbox-level),
  but a kit author can no longer assume a command's env is theirs alone.
- **Staging-order coupling at create.** `--script-path` staging moved into a second
  loop over the same kit dirs, since the merged env is only knowable once every kit is
  fetched; same list, same order, so the first-kit-stakes-the-name rule holds.
- **Knowingly left undone: a merged var can name a not-yet-staged path.** Kit *N*'s
  commands can now receive e.g. `OPENCODE_CONFIG` pointing at a file kit *N+k* has not
  copied in yet, turning "no team config" into "possibly broken team config" until the
  declaring kit's files land. That is the startup-races-its-own-prerequisites class, not
  an env-scoping one: fixing it needs an ordering/barrier decision (stage all `files[]`
  before any commands, or a readiness barrier before background startup).

## Links

- ADR-0011 (the `environment` vocabulary and session-replay marker this widens),
  ADR-0014 (`background: true`, whose daemons made the gap visible), ADR-0017 (the
  staged-script path and its inertness caveat).
- `acq.backends/msb.sh`: `_acq_msb_merge_kit_env_into` (pre-pass),
  `_acq_msb_own_guard_tokens_into` + `_acq_msb_env_tokens_with_guards_into` (guard
  ownership), `_acq_msb_persisted_kit_env_into` (mid-life fallback, session replay).
- Tests: `test/bats/79-msb-merged-kit-env.bats` (lifecycle commands),
  `78-msb-kit-env.bats` (marker/session replay), `73-msb-kits-startup.bats` (staged body).
- Reported as GSA-TTS/agentic-coding-quickstart#515; the deferred
  startup-races-its-prerequisites class is GSA-TTS/agentic-coding-quickstart#506.
