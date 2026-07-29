---
title: "Neutral Port-Publish and Background-Command Kit Vocabulary"
status: accepted
date: 2026-07-24
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SA-17", "SC-7", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0014: Neutral Port-Publish and Background-Command Kit Vocabulary

## Context and Problem Statement

[ADR-0011](0011-msb-backend-and-neutral-kits.md) established the neutral
`hybrid/v1` kit vocabulary (`caps.network.allow`, `files[]`, `commands[]`,
`environment`, `agentContext`, `backend_shortcuts`, `backend_extras`) so one kit
set drives every backend. Two capabilities that a real kit needs are **not**
modeled in the neutral vocabulary and live only under `backend_extras.sbx`:

1. **Published ports.** The `openchamber` kit exposes two guest ports (the
   OpenChamber UI and a shared OpenCode server). The neutral spec has no
   port-publish field, so the port list sits in
   `backend_extras.sbx.publishedPorts` and only the sbx translator
   (`kit_spec_published_ports` in `acq.backends/kit-translate.sh`) reads it.
2. **Background startup command.** The kit's startup hook runs a never-exiting
   supervisor loop that must not block sandbox start. There is no neutral
   `background` flag, so this also lives in `backend_extras.sbx`
   (`background: true`).

Because both live under the sbx-only extras block, `openchamber` can only
declare `backends: [sbx]`. The `msb` adapter has **zero** consumption of either
field (verified: no `publishedPorts`/`background` reference in
`acq.backends/msb.sh`). This is gap **A** in the
[sbx↔msb backend parity epic (#234)](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/234)
and the largest blocker to a kit declaring `backends: [sbx, msb]`
(patterns [#233](https://github.com/GSA-TTS/agentic-coding-patterns/issues/233)).

> **Update (main after rebase):** the sbx half of the port path already landed —
> quickstart [#221](https://github.com/GSA-TTS/agentic-coding-quickstart/pull/221)
> made `kit_translate_to_sbx` carry `backend_extras.sbx.publishedPorts` into the
> synthesized sbx-v2 spec (closing [#219](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/219))
> and quote wildcard allow hosts (closing [#220](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/220)),
> and [#223](https://github.com/GSA-TTS/agentic-coding-quickstart/pull/223) taught
> `acq run/create` to intercept and translate a user `--kit <ref>`. This ADR's
> remaining work is the **neutral** promotion of the field (out of the sbx-only
> extras block) plus the **msb consumer** — the sbx side is now a rename +
> deprecated-fallback, not a from-scratch carry.

### Revisited against `msb --tree` (msb 0.6.7)

An earlier draft of this ADR was written against the microsandbox docs. The
published command surface was later confirmed against a **live `msb --tree` on
msb 0.6.7** (released 2026-07-27), which corrects three assumptions:

1. **`msb -p` is richer than `HOST:GUEST`.** It accepts `BIND_ADDR:HOST:GUEST`
   (default bind `127.0.0.1`) and `/udp` variants. The neutral schema below
   deliberately stays **TCP + default (loopback) bind** — matching what sbx
   publishes and what `openchamber` needs — so bind-address and UDP are
   **recorded as msb-supported but out of parity scope** here (not added to the
   neutral vocabulary in this ADR).
2. **Post-hoc port publishing *is* possible on msb**, via `msb ssh serve` +
   OpenSSH `-L`/`-D` forwarding — but through an SSH tunnel, not a NAT publish,
   and only against a running sandbox after an authorized key. That is a
   **separate capability** from create-time `-p` and is handled incrementally in
   its own decision record (see Links: post-hoc publish ADR + gap K). This ADR
   remains scoped to create/run-time `-p`.
3. **`msb snapshot` exists as a full CLI verb** (create/list/inspect/verify/
   remove/save/load, plus `run --from-snapshot`). This is unrelated to ports but
   corrects a stale "no snapshot verb" claim elsewhere; snapshot wiring stays
   out of scope as beyond-sbx-parity (see epic #234 / #225).

The neutral schema is owned by the **patterns** repo
(`schemas/kit-hybrid-v1.schema.json`, `validate-kits.py`); the translator and
adapters are owned by **quickstart**. So this is a cross-repo change with the
same fail-closed gating ADR-0011 used: quickstart pins a released
`PATTERNS_KIT_REF` only after the schema property exists.

## Decision Drivers

- **Enable `backends: [sbx, msb]` for port/background kits** — the concrete
  driver from patterns #233.
- **Backend-neutral by construction** — a kit should express "publish this port"
  and "run this in the background" once, not per backend.
- **No behavior change for existing sbx kits** — a kit still using
  `backend_extras.sbx.publishedPorts` must keep working during migration.
- **No new runtime dependency** — parse with `awk`, consistent with ADR-0011.
- **Fail closed on untrusted input (SI-10)** — port/background fields reach a
  shell/`-p` argv, so they must be validated before use, like every other
  neutral field.
- **Cross-repo fail-closed gating** — do not pin a patterns ref that lacks the
  schema property.

## Considered Options

1. **Promote `publishedPorts` + `background` to neutral top-level fields; both
   adapters consume them; keep reading `backend_extras.sbx` as a deprecated
   fallback for one release.** Chosen.
2. **Add a `backend_extras.msb` block mirroring the sbx one.** Rejected:
   perpetuates per-backend duplication (the exact drift ADR-0011 set out to
   avoid) and does not make kits backend-neutral.
3. **Leave openchamber sbx-only.** Rejected: abandons msb parity for a
   first-class opt-in kit and blocks patterns #233 indefinitely.

## Decision Outcome

**Chosen: Option 1.** Add two neutral fields to `hybrid/v1`:

- **`publishedPorts`** — a top-level list of port mappings. Each entry:
  `{ host: <int>, guest: <int>, protocol?: tcp|udp, name?: <string> }`. When
  `host` is omitted it defaults to `guest`.
- **`background`** — a boolean on a `commands[]` entry (default `false`),
  marking a startup command that must be detached rather than awaited.

### Translation

- **sbx.** `kit_spec_published_ports` reads the neutral `publishedPorts` first,
  falling back to `backend_extras.sbx.publishedPorts` for one release
  (deprecation warning). The synthesized sbx-v2 kit is unchanged in shape, so
  the observable sbx result is identical. `background` maps to the sbx-v2
  startup-command semantics already in use.
- **msb.** The msb adapter gains a consumer that maps each neutral
  `publishedPorts` entry to `msb create/run -p HOST:GUEST` (msb's create/run-time
  publish). `msb -p` also accepts `BIND_ADDR:HOST:GUEST` and `/udp`, but the
  neutral schema stays TCP + default loopback bind for parity scope, so the
  translation emits a plain `-p HOST:GUEST`. Create/run-time is the only NAT
  publish path; post-hoc publishing via `msb ssh serve` is a distinct capability
  handled in the incremental post-hoc-publish ADR (see Links), not here. A
  `background: true` startup command is run detached (`msb exec -d` /
  `nohup … &` equivalent) so it does not block provision, the same reason the
  sbx path backgrounds it. The msb adapter already backgrounds its own agent
  launch and marker-gates install commands (quickstart
  [#230](https://github.com/GSA-TTS/agentic-coding-quickstart/pull/230),
  **merged to main**), so the detached-command plumbing this ADR needs is now in
  place to build on.

### Validation (SI-10)

Both fields are untrusted kit input that reach argv:

- `publishedPorts[].host`/`.guest` MUST be integers in `1..65535`; `protocol`
  MUST be `tcp` or `udp` when present; `name` is charset-restricted. Offending
  entries are dropped with a warning and reported by `acq kit validate`.
- `background` MUST be a boolean; any other value is treated as `false` with a
  warning.

The patterns `kit-hybrid-v1.schema.json` gains the matching properties and
`validate-kits.py` enforces them (the shared choke point). This dovetails with
patterns [#225](https://github.com/GSA-TTS/agentic-coding-patterns/issues/225)
(field validation at the gate).

### Capability flags

Unchanged by this ADR. msb keeps `ACQ_BACKEND_SUPPORTS_PORT_FORWARD=0`: that flag
gates a **post-hoc** `acq ports` publish verb, which this ADR does not add —
create/run-time `-p` is a separate mechanism. Note the flag's rationale is being
corrected separately: msb *can* forward ports post-hoc via `msb ssh serve` +
`ssh -L` (an SSH tunnel, not a NAT publish), so the flag flips to `1` only when
that path is wired in the incremental post-hoc-publish ADR (see Links), not here.

## Consequences

- **Better:** `openchamber` (and future services) can declare
  `backends: [sbx, msb]`; port/background intent is expressed once, neutrally.
  Adding `ppp` (Phase 3) inherits both fields for free via the translator.
- **Tradeoff:** one release carries a `backend_extras.sbx.publishedPorts`
  fallback + deprecation warning; removed in the following minor.
- **Compliance:** no new external services or data classification change
  (CM-2/CM-3/CM-6); egress is still allow-listed per kit (SC-7); the new fields
  are validated before reaching a shell/argv (SI-10). Structural adapter +
  translator change (SA-8/SA-15/SA-17).
- **Cross-repo gate (must hold before merge):** `PATTERNS_KIT_REF` is bumped to
  a **released** patterns commit that includes the `publishedPorts`/`background`
  schema properties and validator — mirroring ADR-0011's v1.7.0 pin discipline.
  Until that release exists, the quickstart pin is held and the neutral fields
  are read defensively (absence is a no-op, not an error).

## Validation

- `bash -n acq acq.backends/*.sh` clean.
- `scripts/test-acq` gains cases: neutral `publishedPorts` → sbx-v2 + msb `-p`;
  `backend_extras.sbx.publishedPorts` fallback still translates (with the
  deprecation warning); `background` command is emitted detached on both
  backends; invalid port/protocol/background values are dropped and reported by
  `acq kit validate`.
- Live end-to-end (openchamber on sbx and msb) is deferred to a sandbox-capable
  host via `scripts/verify-backends`, per ADR-0011 (no nested sandboxes; msb
  needs `/dev/kvm`).

## Links

- Parity tracking: [sbx↔msb backend parity epic (#234)](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/234)
  (gap A)
- Implementation: quickstart [#224](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/224)
- Builds on: [ADR-0011](0011-msb-backend-and-neutral-kits.md) (neutral vocabulary),
  [ADR-0010](0010-acq-pluggable-backends.md) (adapter contract)
- Incremental follow-on: [ADR-0015](0015-msb-post-hoc-port-publish-via-ssh.md)
  (post-hoc port publish on msb via `ssh serve` + `ssh -L`), tracked in
  [#238](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/238) (gap K)
- Driver: patterns [#233](https://github.com/GSA-TTS/agentic-coding-patterns/issues/233)
  (openchamber msb/ppp parity)
- Related security gate: patterns [#225](https://github.com/GSA-TTS/agentic-coding-patterns/issues/225)
  (validate-kits.py field validation)
- Prior port fix: quickstart [#221](https://github.com/GSA-TTS/agentic-coding-quickstart/pull/221)
  (sbx translator carried `backend_extras.sbx.publishedPorts`; **merged to main**)
  and [#223](https://github.com/GSA-TTS/agentic-coding-quickstart/pull/223)
  (`--kit <ref>` interception on run/create; **merged to main**)
