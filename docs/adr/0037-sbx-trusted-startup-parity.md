---
title: "SBX Trusted-Startup Parity (read-only host mount vs native replay vs exec-time injection)"
status: proposed
date: 2026-10-25
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-3", "AC-6", "CM-5", "CM-6", "SC-7", "SI-7", "SI-17"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0037: SBX Trusted-Startup Parity

## Context and Problem Statement

[ADR-0035](0035-host-authoritative-sandbox-config.md) Mechanism 2 makes a kit's
`readonly: true` startup code tamper-resistant on msb: acq stages the pinned file
on the host, mounts the per-sandbox config directory `:ro`, and runs the heal from
the mounted path, so a passwordless-sudo guest cannot rewrite the code acq
re-executes on restart. On msb that rests on msb's own host-side enforcement of the
`:ro` mount, confirmed per sandbox from `msb inspect` and a version floor (ADR-0035);
a guest-run probe is never accepted as proof.

SBX has no equivalent. `acq_backend_provision` for sbx creates the host config
directory but never mounts it (it holds host-only keys such as `extra-kits`,
`builtin-kits`, and `generic-opencode`), and the sbx kit translator does not
consume the `readonly` field. What an SBX restart runs is whatever sbx registered
from the kit's `setup.startup` at create, replayed natively on every sandbox
start. Two facts about that path are **not established**:

1. Where sbx keeps the registered startup command and whether a sudo guest can
   alter it (or the files it references) between create and the next start.
2. Whether the files a startup command invokes (delivered under `files/home/` or
   `setup.files`) are guest-writable after delivery. They are: the guest owns its
   filesystem, so these are the same guest-resident copies ADR-0035 rejects.

Scope today is small. An audit of the pinned Patterns release (v1.17.0) found no
`acq-kits/*/spec.yaml` that declares `readonly: true`, so Mechanism 2 had no
consumer on either backend. The v1.18.0 pin changes that: the opt-in `oci-engine`
kit now declares `readonly: true` on its root startup grant script and storage
helper. On msb those run from the read-only mount; on sbx the translator still
ignores the field, so the kit's startup command takes its legacy branch and runs
the root-owned copies published at create. The SBX gap is therefore no longer
latent for that one opt-in kit. Re-check this against the pin in force when the ADR
is accepted.
This ADR decides the direction so that the first kit to opt in does not silently
get weaker guarantees on SBX than on msb.

`sbx kit add` of startup-bearing kits is refused on sbx 0.38
(`docs/KNOWN_FAILURE_MODES.md` section 36), so on that version mid-life repair is
already "recreate the sandbox". The Kits v2 documentation
([docs.docker.com Kits v2](https://docs.docker.com/ai/sandboxes/customize/kits/))
says current sbx supports `setup.startup` mixins via recreate (not verified
here; no network or sbx access on the authoring host), so the refusal is
version-scoped and is not assumed for later releases. The "mountless sandbox"
behavior attributed to sbx >= 0.42 below is likewise unverified. This ADR concerns
create-time delivery and restart replay only.

**Does sbx share the msb forgeable-gate class?** No, because sbx does not run
trusted code from the `:ro` mount today: `acq.backends/sbx.sh` has no consumer of the
kit `readonly` field, the translator ignores it, and the sbx host config directory is
never mounted. The only `:ro` mounts on sbx are the provider-input generation
(read as data by the guest-side renderer, not executed by acq) and no acq decision
reads a guest answer about them. The msb gate was forgeable because acq took a
guest-run probe's zero exit as proof of read-only enforcement; sbx has no such gate.
The open question for sbx is the one this ADR already states: native replay and mount
enforcement are unverified, and Option B must not be implemented without a
host-side check of the same kind as msb's: what the backend itself recorded for the
mount, plus a host-judged canary as corroboration.

## Decision Drivers

- **Same rule as ADR-0035**: acq-trusted code is host-materialized and `:ro`, or
  host-held and exec-injected; guest-resident copies are not trusted.
- **Do not claim what is unverified.** The sbx documentation describes startup
  commands as registered at create and replayed "on each subsequent sandbox
  start" ([Kits v2](https://docs.docker.com/ai/sandboxes/customize/kits/)) but
  says nothing about integrity of that registration against a sudo guest.
- **Use only sbx behavior acq already depends on.** Read-only extra workspace
  positionals (`PATH:ro`, after the read/write primary workspace) are already used
  for provider inputs (`acq_provider_input_sbx_mount`), and sbx mounts a workspace
  at the same absolute path as on the host
  ([Architecture](https://docs.docker.com/ai/sandboxes/architecture/)).
- **No host-side code execution** and no new network or credential surface.
- **Windows path forms** (ADR-0029): a host-path-identical guest mount must be
  expressible there.
- **Proportionality**: the sandbox is the boundary (ADR-0005); the residual risk
  is a guest steering its own restart behavior, not a host escape.

## Considered Options

### Option A: Rely on sbx native startup replay integrity

Treat sbx's registered `setup.startup` as trusted and do nothing.

- Pros: no code; matches how sbx is designed to be used.
- Cons: integrity is unverified (see above); does not cover files the startup
  command invokes, which remain guest-writable; no parity with msb Mechanism 2.
- Verdict: **not acceptable as a claim** without live validation of both points.
  Acceptable only as a documented, bounded residual risk.

### Option B: Dedicated read-only host mount for trusted kit files on SBX

Stage `readonly: true` files on the host, as msb does, into a **dedicated**
directory (not the whole config directory) and pass it as an extra `PATH:ro`
positional after the workspace, exactly like the provider-input generation. The
SBX translator rewrites startup argv tokens that equal a `readonly` file's guest
path to the mount path before emitting `setup.startup`.

- Pros: reuses a positional form acq already ships; restart replay executes
  host-materialized code even if sbx's registration is replayed verbatim; the
  mount persists with the sandbox, so restarts need no acq involvement.
- Cons: the guest sees the mount at the **host's absolute path**, not
  `/var/lib/acq/host`, so the rewritten argv embeds a host path (Windows forms per
  ADR-0029); the dedicated directory must contain only non-sensitive, public,
  pinned kit payload (traversable `0711`, files `0555`, per ADR-0035), never the
  flat `0600` keys, so the whole config directory must not be mounted; the
  translator gains a `readonly` consumer; behavior with mountless sandboxes
  (sbx >= 0.42) must be confirmed (extra workspaces under `--clone` are documented
  as always mounted directly rather than cloned, `docs/howto/sbx.md`); the registration itself (the argv
  naming the mount path) is still sbx-held state (Option A's unverified point 1),
  though tampering with it can only redirect execution, not substitute trusted
  content.
- Verdict: **feasible, unverified live.**

### Option C: Exec-time injection by acq

On each attach/heal, acq runs the trusted startup commands itself with
`sbx exec`, feeding the code from the host (stdin or per-run copy), and ships kits
to sbx without those startup commands.

- Pros: acq owns the code path completely, as on msb's heal.
- Cons: sbx's native replay is lost for those commands, so restarts that do not go
  through acq (sbx-native stop/start, `sbx run` outside acq) skip them; the
  per-run copy reintroduces the TOCTOU window ADR-0035 rejected (Option 2 there);
  startup-bearing kits can no longer be translated one-to-one, which departs from
  the neutral-kit contract (ADR-0011); larger code change.
- Verdict: **rejected** unless Option B is shown impossible.

### Option D: Accept and document

Record that SBX trusted-restart parity does not exist, rely on native replay,
and require that no kit mark startup code `readonly: true` on SBX until a
mechanism is validated (the translator would warn, not silently degrade).

- Pros: zero risk of an unverified mechanism; honest; no code.
- Cons: SBX users get weaker restart integrity than msb for any kit that opts in.
- Verdict: **correct interim state**, because no shipped kit opts in.

## Decision Outcome (proposed)

**Adopt Option D now and Option B as the implementation path, gated on live
validation and on the first shipped kit that sets `readonly: true`.** Do not
implement Option C. Do not implement runtime code for Option B until the live
validation below passes, because its integrity claim rests on sbx behavior
(mount enforcement under a sudo guest, restart persistence) that has not been
observed.

Until then the SBX translator MUST NOT silently treat `readonly: true` as
satisfied. When the first kit opts in, the SBX path must either implement
Option B or emit a visible warning that the file is a guest copy on SBX.

**Implementation status (interim, Option D):** the visible warning is
implemented. `_acq_sbx_translate_kit` in `acq.backends/sbx.sh` writes one
stderr warning per kit translation (so once per kit per create or kit-add) that
names the kit and the guest path of every `readonly: true` file and states that
on SBX they are guest-resident copies with no integrity guarantee against a
sudo guest. The kit still applies unchanged; kits with no `readonly: true`
files stay silent. The first kit to opt in is `oci-engine` (Patterns v1.18.0).
Regression coverage: `test/bats/91-sbx-readonly-warning.bats`. Option B (the
read-only mount) remains unimplemented and gated on the live validation below.

## Live Validation Required Before Implementing Option B

Run on a real sbx host (cannot run inside a sandbox). Record exact sbx version.

1. **Mount form**: `sbx create ... <workspace> <dir>:ro` with a dedicated
   directory. Confirm the guest path equals the host absolute path, the primary
   workspace stays read/write, and a second `:ro` positional composes with the
   provider-input generation.
2. **Enforcement under sudo**: as guest root, attempt a write, create, rename,
   `chmod`, and `mount -o remount,rw` on the directory and on a file in it.
   Confirm all fail and the host copy is unchanged. Judge it from the host side
   (inspect the real host directory afterwards), as the msb canary in
   `scripts/qualify-msb-ro-mount` does; a guest-reported denial is not evidence.
   Nothing is recorded for sbx. For msb, enforcement is host-side (ADR-0035) and one
   canary run on msb 0.7.7 corroborates it.
3. **Permissions**: the guest `agent` (uid 1000) can execute a `0555` file under a
   `0711` directory it cannot list, with host files owned by the host user.
4. **Restart persistence**: after `sbx stop`/start and after a host reboot, the
   mount is present and a startup command referencing it runs; after the host
   directory is removed, startup fails closed rather than running a guest copy.
5. **Native replay integrity (also settles Option A)**: locate where sbx stores
   the registered startup command (`sbx kit inspect`, then the guest and VM
   filesystem). As guest root, edit the registered command and each file it
   references, restart, and record what executes. This determines how much the
   registration itself can be trusted.
6. **Sandbox modes**: repeat 1 and 4 with `--clone` (extra workspaces are
   documented as always mounted directly; confirm that holds for the `:ro`
   positional) and, on sbx >= 0.42, with no workspace.
7. **Windows path forms** (ADR-0029): confirm the mount path embedded in argv is
   valid in the guest.
8. **Negative control**: confirm no host config keys (`workspace`, `extra-kits`,
   `builtin-kits`, provenance) are visible to the guest from this mount.

A passing run is added to `scripts/verify-backends` with a `readonly: true`
fixture kit and an SBX tamper step, mirroring the msb live fixture.

## Consequences

### Positive

- The latent SBX gap is named, bounded, and tied to a concrete trigger instead of
  being discovered when a kit opts in.
- Reuses an existing, shipped sbx mechanism if validation passes.
- Validation step 5 resolves whether native replay is trustworthy independent of
  this ADR's outcome.

### Negative / risks

- Until Option B lands, an SBX sandbox running a kit with trusted startup code
  restarts guest-resident code with no integrity guarantee beyond sbx's own.
- The mount path embeds a host path in the guest, which leaks the host username
  and directory layout to the guest (already true for the workspace mount).
- The `kit-files` directory must stay free of sensitive content; this constraint
  already applies on msb.

### Neutral

- Passwordless sudo is unchanged. No change to the neutral `hybrid/v1` vocabulary.

## Links

- [ADR-0035](0035-host-authoritative-sandbox-config.md) — the principle and
  Mechanism 2 this ADR extends to SBX.
- [ADR-0011](0011-msb-backend-and-neutral-kits.md) — neutral kits; per-backend
  translation is the adapter's job.
- [ADR-0029](0029-windows-host-guest-path-forms.md) — host/guest path forms.
- `docs/KNOWN_FAILURE_MODES.md` sections 36 (sbx kit-add refusal), 47 (msb session
  shell), and 48 (sbx startup barrier): related accepted residual risks.
- sbx documentation:
  [Kits v2](https://docs.docker.com/ai/sandboxes/customize/kits/),
  [Architecture](https://docs.docker.com/ai/sandboxes/architecture/),
  [Security model](https://docs.docker.com/ai/sandboxes/security/). The `sbx`
  binary was not available on the authoring host; no CLI help text was inspected
  and nothing here was verified live.
