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

## Update (2026-08-02)

**Corrected mechanism (source-verified).** The original decision below assumed
that registering the startup body with `--script-path acq-startup:<file>` would
be enough for microsandbox to replay it on a native restart. That is **not**
correct: microsandbox's `msb start`/`msb restart` call `Sandbox::start_detached`,
which replays a persisted startup command derived **only** from
`runtime.entrypoint` / `runtime.cmd` — **never** from `runtime.scripts`. A bare
`--script-path acq-startup:<file>` only STAGES the script on the guest PATH at
`/.msb/scripts/acq-startup`; it is **not** executed at start. `msb create` has no
trailing command and no `--start`/`--on-start`/`--exec` flag, and the
persisted-startup replay additionally depends on internal `launch_intent`/init
semantics that are **uncertain** on the pinned msb 0.6.7 (`launch_intent` is
serde-skipped).

**Chosen resolution (this increment ships it):**

 - **The acq `start`/`restart` verb — the sole, deterministic mechanism (msb).** Add an
   acq `start`/`restart` verb backed by `acq_backend_start` (`msb start` on the
   msb backend). After the backend resume, re-drive
   `acq_backend_ensure_kits_applied`, which re-applies the pinned kits
   idempotently and **re-runs the startup phase via the exec path** — the actual
   mechanism that brings kit `startup`/`background` services back up. On the
   **msb** backend, a **stopped** sandbox is also started automatically at the top
   of `acq_backend_ensure_kits_applied`, so `acq run <stopped-sandbox>` works
   end-to-end on msb (start → heal/startup → attach) — this closes the stated gap
   without any native-persistence uncertainty.

 - **sbx has no `start`/`restart` verb — resume is automatic on attach.** The sbx
   CLI exposes no `start` (or `restart`) subcommand (`sbx --help`: create, exec,
   run, stop, rm, …), and sbx has no analogue of msb's "start but stay detached":
   with no attached session sbx auto-idles a sandbox to the stopped state, and the
   next `sbx run` / `sbx exec` transparently resumes it (verified by hand). So on
   sbx there is nothing for a standalone resume primitive to do:
   `acq_backend_start` is **deliberately not defined** on the sbx adapter, and the
   acq `start`/`restart` verbs are **capability-gated** — they exit with an
   actionable message pointing at `acq run <name>` rather than shelling out to a
   non-existent `sbx start`. `acq run <stopped-sbx-sandbox>` already works because
   the heal (`sbx kit add`/`sbx exec`) and attach (`sbx run`) auto-start the
   sandbox. (An earlier revision of this ADR wrongly listed `sbx start` as the sbx
   resume primitive; no such subcommand exists — corrected here.)

**Native restart OUTSIDE acq is out of scope (found in live testing).** An
earlier revision of this increment also, behind an opt-in flag
(`ACQ_MSB_PERSIST_STARTUP_ENTRYPOINT`), designated the staged script as
`--entrypoint /.msb/scripts/acq-startup` so microsandbox's `start_detached` would
replay it on a raw `msb start`/reboot. **That approach was removed.** Live
testing showed a raw `msb start` of a secret-bound sandbox fails *before* any
startup question arises:

```
error: invalid config: secret USAI_API_KEY: host environment variable USAI_API_KEY is not set
```

`msb start` re-reads the sandbox's persisted `--secret ENV@HOST` bindings and
requires each value present in the host environment — and only acq injects those
(see `acq_backend_start` and the secret note below). So a native `msb start`
outside acq cannot boot a secret-bound sandbox at all, which makes the
`--entrypoint` persistence path moot: there is no supported way to resume such a
sandbox except through acq. Rather than ship a gated, unverified,
image-init-overriding flag that could never deliver on its promise, the flag and
its wiring were removed. **Restart durability is therefore provided solely by the
acq `start`/`restart` verb.** Always resume via `acq start` / `acq restart` (or
`acq run <name>`), never a bare `msb start`.

The original decision text below is preserved for the audit record; treat the
"only option that makes startup re-run on a microsandbox-native restart" claim in
the original Decision Outcome as **corrected** by this note.

**Secret re-injection on resume (found in live testing).** `msb start` re-reads
the sandbox's persisted `--secret ENV@HOST` bindings and requires each named
value to be present in the *host* environment at start time — microsandbox does
not retain the value across a stop. So `acq_backend_start` must resolve and
export the same secrets `acq_backend_provision` bound at create, or `msb start`
fails with `invalid config: secret USAI_API_KEY: host environment variable
USAI_API_KEY is not set`. The resolve/export/`--secret`-collect logic is
therefore shared between create and resume via a single helper
(`_acq_msb_bind_secrets_into`), and the exported values are unset immediately
after the msb child reads them (on both success and failure). This is also the
reason native-restart-outside-acq is infeasible (above).

## Update (2026-08-18): CLI/extra kit refs must be persisted for the resume heal

The resume-heal mechanism above (`acq_backend_ensure_kits_applied` re-runs the
`startup` phase) is only as complete as the **kit set** it iterates. Two follow-on
gaps meant a sandbox created with `acq run … --kit <ref>` — the intended path for
a supervised-daemon kit such as `paseo` or `openchamber` — still came back from a
`msb stop` + `acq start` with its ports mapped but its daemon dead:

1. `acq_backend_ensure_kits_applied` originally iterated only the built-in kits +
   `ACQ_EXTRA_KITS`, skipping CLI `--kit` refs (`ACQ_CLI_KITS`). Fixed by folding
   `ACQ_CLI_KITS` into the heal's kit list, matching `acq_backend_provision`.

2. More fundamentally, the CLI/extra refs were **in-memory only**: `ACQ_CLI_KITS`
   is populated by `extract_kit_flags` in the `run`/`create` dispatch arm, and
   `ACQ_EXTRA_KITS` is a bare env var. The `start`/`restart` verbs do not re-parse
   `--kit` and may run in a shell that never exported `ACQ_EXTRA_KITS`, so the heal
   iterated an **empty** CLI/extra set and re-ran only the built-ins' startup.

**Resolution.** acq persists the CLI (`--kit`) and `ACQ_EXTRA_KITS` refs
host-side at provision — a small `*.kits` record beside the bundle-provenance
record, keyed by backend + sandbox name, using the same sanitized-filename +
raw-name-checksum scheme (`acq_cli_kits_write` / `acq_cli_kits_load` in
`acq.backends/common.sh`; written from both `acq_backend_provision` on msb and
`acq_backend_create` on sbx). The `start` / `restart` verbs and the name-only
`acq run <sandbox>` re-attach **reload** that record into `ACQ_CLI_KITS` /
`ACQ_EXTRA_KITS` *before* the heal, so a resume re-runs a `--kit` kit's startup
**without the user re-passing `--kit`**. The record's presence is authoritative
(an empty record clears stale in-memory refs; a legacy sandbox with no record is a
no-op reload, preserving pre-fix behavior), and the reload is guarded so a `--kit`
re-passed on the same invocation stays authoritative. This is consistent with the
"restart durability is delivered by the acq verb, not native msb replay" posture
above: the verb now restores the *full* kit set, not just the built-ins. See
`docs/KNOWN_FAILURE_MODES.md` §33.

---

# ADR-0017: Stage msb kit startup commands as a create-time script for restart durability (original)

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

> **Corrected by the Update (2026-08-02) note above.** Option 2 alone does **not**
> make startup re-run on a native restart — `start_detached` replays only
> `runtime.entrypoint`/`runtime.cmd`, not a bare `--script-path` registration.
> Moreover, a native `msb start` outside acq cannot even boot a secret-bound
> sandbox (it needs the `--secret` host env vars only acq injects), so native
> restart is out of scope entirely. The shipped resolution is the acq
> `start`/`restart` verb re-running the idempotent kit apply — the deterministic
> path that re-runs startup via exec on resume. The `--entrypoint` native-
> persistence experiment described in the original Option 2 below was removed
> (see the Update note). The original Option 2 rationale is retained for the
> audit record only.

Chosen option (original): **Option 2**, because it is the only option that makes
startup re-run on a microsandbox-native restart (the actual gap), and it does so
through the exact create-time-only, re-runnable-script case that the ADR-0011
design note identified as the clean, contained win for `--script-path`. The exec
path is retained unchanged for install (run-once marker gating) and mid-life
apply/heal, so the two mechanisms are complementary, not a fork: create-time
staging owns the reboot/`msb start` path; exec owns the in-place kit-add path.

This ADR is delivered in two increments. The first (the enabling change)
introduced the create-time `--script-path` staging of startup commands and
rewrote the design note; it was runtime-neutral. The second (this increment)
wires restart durability via the acq `start`/`restart` verb + `acq_backend_start`
+ start-if-stopped-on-`acq run`. (An experimental `--entrypoint` native-
persistence path was prototyped in this increment and then removed once live
testing proved native restart outside acq is infeasible — see the Update note.)

### Positive Consequences

- Kit `startup`/`background` services are restored on resume deterministically
  via `acq start` / `acq restart` on **msb**, and, on **both** backends, via
  `acq run <stopped-sandbox>` — on msb through the start-if-stopped heal, on sbx
  through `sbx run`/`sbx exec` auto-resuming the sandbox. On sbx, `acq start`/
  `acq restart` are capability-gated (no such verb exists) and direct the user to
  `acq run`.
- Command bodies are staged as files, not interpolated shell strings (SI-10).
- No change to the neutral kit vocabulary or to install/idempotency semantics.
- Safe-by-default: no image-entrypoint override; resume never changes the guest
  boot path.

### Negative Consequences

- The startup script is staged at create for use by the exec heal, while install
  and mid-life apply also use the exec path. The design note documents the
  boundary so a future maintainer does not collapse them incorrectly.
- The create-time script must reproduce the per-command run-as-user and
  non-interactive git guards the exec path applies at invocation, so that logic
  is shared into the staged body.
- Resume works only through acq (`acq start`/`acq restart`/`acq run`); a raw
  `msb start` cannot boot a secret-bound sandbox, so it is not a supported resume
  path. This is inherent to acq-injected `--secret` bindings, not a regression.

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
- `acq.backends/msb.sh` design note — rewritten to reflect this decision (the
  deterministic acq `start`/`restart` heal; native restart outside acq is out of
  scope because `msb start` needs acq-injected secrets).
- `docs/explorations/acq-design.md` — reconciled with the shipped restart-durable
  behavior: the lifecycle-phase table and the usai-provider msb row now describe
  that startup re-runs on `acq run`/`acq start`/`acq restart` (acq re-drives the
  idempotent apply), and that a raw `msb start` outside acq is not a supported
  resume path.
- Resolved: the sbx lifecycle model was reconciled with the real `sbx` CLI —
  there is no `sbx start`/`restart` subcommand, and a stopped sbx sandbox is
  auto-resumed by the next `sbx run`/`sbx exec`. `acq_backend_start` is therefore
  intentionally undefined on sbx, `acq start`/`restart` are capability-gated to
  point at `acq run`, and `acq run <stopped-sbx-sandbox>` works via that
  auto-resume (GSA-TTS/agentic-coding-quickstart#265).
