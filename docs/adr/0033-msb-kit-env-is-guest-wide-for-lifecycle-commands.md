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

On the msb backend, a kit's lifecycle commands (`install`, `initFiles`,
`startup`) ran with only **that kit's own** `environment[]`, threaded as
`msb exec -e NAME=value`. Interactive sessions were already whole-guest: acq
replays the merged marker on `run`/`attach`/`shell` (ADR-0011's 2026-08-26
update). Commands started by a kit's lifecycle phase were not.

That split is invisible until a kit's command **outlives the command** and
launches other processes. A daemon kit starts its supervisor from a
`background: true` startup command, so every agent that daemon later spawns
inherits only the daemon kit's env. A separate kit that sets `OPENCODE_CONFIG`
(agent instructions plus a default-deny permission layer) is silently missing
from those agents, while the injected credentials are still present — a quiet
loss of a policy/permission control, not a visible failure. Terminal sessions
look correct, so a smoke test passes.

The hard part is **order independence**. The persisted marker
(`/var/lib/acq/kit-env`) is appended per kit *inside the same loop that runs that
kit's commands*, so "read the merged marker when running commands" is correct
only when the env-declaring kit happens to be applied before the daemon kit, and
silently wrong in the reverse order.

## Decision Drivers

- **A kit must not be able to silently drop another kit's policy config** from
  the environment of agents it launches (AC-3, AC-6, CM-6).
- **Order independence** — the effective env must not depend on the order kits
  are applied in, which is an implementation detail of the kit list.
- **One kit must not weaken another kit's hardening** — the adapter's
  non-interactive git guards are per-kit safety, not shared config (CM-7).
- **Same resolution rule as sessions** — last-value-wins, so a command and a
  session agree on which kit's value survives.
- **No new guest dependency** — kits must not each have to source a marker file
  themselves; the adapter owns the threading.
- **Fail soft, never empty** — an unreadable marker degrades to the previous
  per-kit behavior rather than stripping a kit's own env.

## Considered Options

1. **Pre-pass over the full kit set in the full-set paths; marker fallback for
   the mid-life single-kit path.** Chosen.
2. **Read the persisted marker inside `_acq_msb_run_commands` for every path.**
   Rejected: order-dependent by construction — the marker is written in the same
   per-kit loop, so a daemon kit applied before the env-declaring kit still sees
   nothing. It would fix the reported case only for one kit ordering.
3. **Have each kit source `/var/lib/acq/kit-env` in its own commands.** Rejected:
   pushes an adapter concern into every kit, is opt-in (so a kit that forgets is
   silently broken), and couples kit content to a guest path acq owns.
4. **Do nothing; document that kit env is session-only.** Rejected: the
   vocabulary exists for agent-runtime config (ADR-0011), and the failure mode is
   a silent loss of permission/policy configuration.

## Decision Outcome

**Chosen: Option 1.** Kit `environment[]` is treated as **guest-wide
configuration**, so every kit lifecycle command runs with the merged env of the
full effective kit set, using the same last-value-wins order sessions replay.

Where the merged set comes from, per path:

| Path | Source of the merged env |
|------|--------------------------|
| `acq_backend_provision` (create) | pre-pass over every fetched kit spec, computed **before** the first kit is applied |
| `acq_backend_ensure_kits_applied` (heal / `acq start`, `restart`, re-attach) | same pre-pass; kit refs are resolved in one loop, merged, then applied in a second loop |
| `acq_backend_apply_kit` (`acq kit apply NAME KITREF`) | no full set exists — falls back to the sandbox's already-persisted merged marker value |
| neither available (marker absent or unwritable) | this kit's own `environment[]` — the pre-existing behavior |

The mid-life fallback is correct for an additive add: the new kit's own entries
are appended to the marker *before* its commands run, and the read applies
last-value-wins, so the new kit still overrides an older value.

**Guard ownership stays per kit, tracked by value (load-bearing).** The adapter
injects `GIT_TERMINAL_PROMPT=0` + `GIT_ASKPASS`/`SSH_ASKPASS=/bin/false` onto kit
commands unless *that* kit declared `GIT_TERMINAL_PROMPT` itself. Deciding this
from the *merged* set would let one kit's opt-out disable the guards for every
other kit's commands — and a prompting kit command with no credential blocks
provision forever (observed with the playbook kit). So the merged set is widened
for **threading** only: a command receives **only its own kit's value** for a
guard name.

The ownership record is the owning kit's guard **tokens** (`NAME=value`), not just
the names it declared. A name-only record is insufficient, because the merge has
already collapsed a duplicate name to the *last* kit's value before the filter
runs — so it cannot tell a kit's own guard value from another kit's. That gap was
a real regression against the pre-change behavior: with kit A declaring
`GIT_TERMINAL_PROMPT=0` and a later kit B declaring `=1`, kit A's own command ran
with kit B's opt-out *and* with no `GIT_ASKPASS`/`SSH_ASKPASS` at all, where
before it had correctly got its own `0`. The implementation therefore strips
**every** guard-name token from the merged set regardless of contributor, re-adds
this kit's own guard tokens, then appends acq's guard values unless this kit set
`GIT_TERMINAL_PROMPT` itself. Both collision shapes — another kit declaring a
guard name this kit does not (name collision) and another kit declaring the same
name with a different value (value collision) — are closed, while a kit that
declares a guard var still overrides it for its own commands.

The staged create-time `--script-path` body (ADR-0017) gets the same treatment,
for consistency. **That path is inert today** — a bare `--script-path`
registration is staged on the guest PATH and is not auto-run at boot — so this
part fixes no live symptom; it keeps the two paths from drifting so the ADR-0017
version-bump re-verification trap (a future msb that *does* auto-run the script)
cannot resurface this bug.

### Positive Consequences

- A daemon kit's launched agents see every kit's declared config, so a policy/
  permission layer contributed by another kit is no longer silently absent.
- The effective env is identical in both kit application orders.
- Commands and sessions now agree on the env and on duplicate resolution.
- Kits need no knowledge of `/var/lib/acq/kit-env`.

### Negative Consequences

- **Broader blast radius per var.** A var declared by one kit now reaches every
  kit's commands. This is the intended semantics (it matches sbx, where
  `environment.variables` is sandbox-level), but a kit author can no longer
  assume their command's env is theirs alone.
- **Staging-order coupling at create.** The `--script-path` staging moved out of
  the kit fetch loop into a second loop so the merged env is known first. The
  first-kit-stakes-the-script-name rule is preserved by iterating the same list
  in the same order.
- **Not addressed: a merged var can name a not-yet-staged path.** Kit *N*'s
  commands can now receive e.g. `OPENCODE_CONFIG` pointing at a file kit *N+k*
  has not copied in yet. Before this change the daemon saw **no** var; now it can
  see a var pointing at a **missing** file, which converts "no team config" into
  "possibly broken team config" for the window between the daemon starting and
  the declaring kit's files landing. This is the same class as the sbx
  startup/attach race (a startup command racing the state it depends on, tracked
  separately — see Links) and is deliberately out of scope here: fixing it needs
  an ordering/barrier decision (stage every kit's `files[]` before any kit's
  commands, or a readiness barrier before background startup), not an env-scoping
  one. Kits whose commands read a path from a var should already tolerate its
  absence.
- The guard-scoping rule is a real subtlety in the adapter: merged for threading,
  per-kit for the guard decision. It is asserted by a regression test so a future
  simplification cannot quietly collapse the two.

## Links

- ADR-0011 (msb backend and neutral hybrid/v1 kits) — defines the `environment`
  vocabulary and the session-replay marker this widens to lifecycle commands.
- ADR-0014 (neutral port-publish and background-command vocabulary) — defines the
  `background: true` startup commands whose daemons made the scoping gap visible.
- ADR-0017 (msb create-time startup-script staging) — the staged body updated for
  consistency here, including its inertness caveat and re-verification trap.
- `acq.backends/msb.sh` — `_acq_msb_merge_kit_env_into` (the pre-pass),
  `_acq_msb_own_guard_tokens_into` + `_acq_msb_env_tokens_with_guards_into`
  (merged threading, per-kit guard ownership by value),
  `_acq_msb_persisted_kit_env_into` (the mid-life fallback and session replay).
- `test/bats/79-msb-merged-kit-env.bats` — the lifecycle-command regression
  coverage (both kit orders, all three phases, the mid-life and heal paths,
  duplicate resolution, and both guard-collision shapes).
  `test/bats/78-msb-kit-env.bats` keeps the marker/session-replay coverage;
  `test/bats/73-msb-kits-startup.bats` covers the staged-body side.
- Reported as GSA-TTS/agentic-coding-quickstart#515. The related
  startup-races-its-own-prerequisites class noted under Negative Consequences is
  tracked as GSA-TTS/agentic-coding-quickstart#506.
