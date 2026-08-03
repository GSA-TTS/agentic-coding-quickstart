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

- **Mechanism 1 — deterministic, DEFAULT.** Add an acq `start`/`restart` verb
  backed by `acq_backend_start` (`msb start` / `sbx start`). After the backend
  resume, re-drive `acq_backend_ensure_kits_applied`, which re-applies the pinned
  kits idempotently and **re-runs the startup phase via the exec path** — the
  actual, deterministic mechanism that brings kit `startup`/`background` services
  back up. A **stopped** sandbox is also started automatically at the top of
  `acq_backend_ensure_kits_applied`, so `acq run <stopped-sandbox>` now works
  end-to-end (start → heal/startup → attach). This closes the stated gap without
  any native-persistence uncertainty.
- **Mechanism 2 — best-effort native persistence, EXPERIMENTAL / OPT-IN.** When a
  kit contributes startup commands, ALSO append
  `--entrypoint /.msb/scripts/acq-startup` to the create flags so microsandbox
  persists the staged script as the startup command replayed by `start_detached`
  on a native `msb start`/reboot. Because this **overrides the image's own
  entrypoint/init** (default image
  `docker.io/docker/sandbox-templates:shell-docker`) and depends on the uncertain
  0.6.7 `launch_intent`/init semantics, it is **gated behind
  `ACQ_MSB_PERSIST_STARTUP_ENTRYPOINT=1`, default OFF**, and requires **live
  verification on a KVM host**. When off, restart durability is provided entirely
  by mechanism 1 (safe-by-default: no entrypoint override, no boot risk). The
  entrypoint-vs-oneshot consideration (the body must not exit-0 in a way that
  halts the VM if used as the entrypoint) is a live-verification item; the body is
  intentionally not hardened for that until the native replay is confirmed.

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
after the msb child reads them (on both success and failure).

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
> `runtime.entrypoint`/`runtime.cmd`, not a bare `--script-path` registration. The
> shipped resolution is **Option 3 (combination)**: the acq `start`/`restart` verb
> re-running the idempotent kit apply is the deterministic primary path
> (mechanism 1, default), and native persistence via `--entrypoint
> /.msb/scripts/acq-startup` is the experimental secondary path (mechanism 2),
> gated behind `ACQ_MSB_PERSIST_STARTUP_ENTRYPOINT=1`, default off, pending live
> verification on a KVM host. The original Option 2 rationale is retained below for
> the audit record.

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
wires restart durability: the acq `start`/`restart` verb + `acq_backend_start` +
start-if-stopped-on-`acq run` (mechanism 1, default), and the gated
`--entrypoint` native persistence (mechanism 2, experimental).

### Positive Consequences

- Kit `startup`/`background` services are restored on resume: deterministically
  via `acq start`/`acq restart` and `acq run <stopped-sandbox>` (mechanism 1),
  and — when the experimental `--entrypoint` gate is enabled and verified on a
  KVM host — on a raw `msb start`/reboot (mechanism 2).
- Command bodies are staged as files, not interpolated shell strings (SI-10).
- No change to the neutral kit vocabulary or to install/idempotency semantics.
- Safe-by-default: mechanism 2's image-entrypoint override is opt-in only, so the
  runtime default carries no boot-risk from an unverified entrypoint change.

### Negative Consequences

- Two staging mechanisms now coexist (create-time script for startup persistence
  + exec for install and mid-life). The design note documents the boundary so a
  future maintainer does not collapse them incorrectly.
- The create-time script must reproduce the per-command run-as-user and
  non-interactive git guards the exec path applies at invocation, so that logic
  is shared/duplicated into the staged body.
- Mechanism 2 (`--entrypoint`) is UNVERIFIED against msb 0.6.7 and overrides the
  image init; it stays gated off until live KVM verification confirms the native
  replay and resolves the entrypoint-vs-oneshot body consideration.

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
- `acq.backends/msb.sh` design note — rewritten to reflect this decision
  (deterministic acq `start`/`restart` heal + gated experimental `--entrypoint`).
- `docs/explorations/acq-design.md` — reconciled with the shipped restart-durable
  behavior: the lifecycle-phase table and the usai-provider msb row now describe
  that startup re-runs on `acq run`/`acq start`/`acq restart` (acq re-drives the
  idempotent apply), and that a raw `msb start` outside acq only replays startup
  if the experimental `--entrypoint` persistence is enabled.
