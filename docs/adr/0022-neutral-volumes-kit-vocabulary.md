---
title: "Neutral Volumes Kit Vocabulary"
status: accepted
date: 2026-08-19
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SA-17", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0022: Neutral Volumes Kit Vocabulary

## Context and Problem Statement

sbx kit-spec v2 §5.7 supports `volumes:` — sized, block-backed (or tmpfs)
volumes mounted at any absolute path, applied at sandbox creation. This is
verified fully wired on sbx 0.38.0: a mixin declaring a 2G volume gets a
dedicated ext4 block device of the declared size mounted at the path.

Hybrid/v1 kits cannot reach this: `kit-translate.sh` has no `volumes`
vocabulary, so a neutral kit has no way to declare storage. Teams that need it
script around the fixed disk layout in `commands.startup` instead — which runs
*after* the sandbox already accepts execs, so any storage rearrangement races
the user and the agent. The concrete driver
([#329](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/329),
login.gov Team Data): a kit that relocates a multi-GB `/nix` store onto larger
storage hit exactly that race in production (a first `direnv allow` died with
ENOENT mid-swap), and an unfixable ~1 s empty-`/nix` window per restart
remained — the startup step itself is what races. A create-time volume mounts
before any exec is possible, eliminating the race class entirely.

msb parity was researched in the #329 thread against the v0.6.8 tag (flags
exist at acq's `MIN_MSB_VERSION` floor): msb's storage primitives are a
superset of what the vocabulary needs — disk-backed named volumes
(`--mount-named NAME:PATH:kind=disk,size=SIZE`, raw ext4 via virtio-blk) and
`--tmpfs PATH:SIZE`.

## Decision Drivers

- **Kill the startup-storage race class** — volumes mount at boot, before any
  exec, on BOTH backends (the same ordering guarantee that motivated #329).
- **Backend-neutral by construction** — a kit expresses "give this path sized
  storage" once, not per backend (ADR-0011 doctrine).
- **No new runtime dependency** — parse with `awk`, consistent with ADR-0011.
- **Fail closed on untrusted input (SI-10)** — volume fields reach a generated
  sbx-v2 spec and an msb create argv.
- **No orphaned host state** — msb named volumes persist independently under
  `~/.microsandbox/volumes/`; sbx kit volumes die with the sandbox. Parity
  includes the lifecycle, not just the mount.

## Considered Options

1. **Neutral top-level `volumes:` consumed by both backends; msb derives a
   per-sandbox named volume and removes it on `rm`.** Chosen.
2. **sbx-only (`backend_extras.sbx`), warn-and-skip on msb.** Rejected:
   perpetuates the per-backend drift ADR-0011 exists to avoid, and msb has
   full-parity primitives at the current version floor.
3. **Keep scripting storage in `commands.startup`.** Rejected: the race class
   is unfixable from inside a startup step (#329).

## Decision Outcome

**Chosen: Option 1.** Add one neutral field to `hybrid/v1`, mirroring kit-spec
v2 §5.7 minus `mode`:

```yaml
volumes:
  - path: /var/lib/docker   # required, absolute
    size: 20G               # required
  - path: /scratch
    type: tmpfs             # optional; "" (block, default) | tmpfs
    size: 2G
```

- `size` is **required** — the neutral schema does not inherit sbx's
  unsized-volume default, which is still settling upstream (0.39-rc moved it
  50G → 512M between rcs).
- `mode` is **excluded** from the neutral vocabulary: msb's mount-option
  grammar has no equivalent (verified at 0.6.8: `ro/rw/noexec/nosuid/nodev`,
  `kind=`, `size=`, `quota=`), and a kit can `chmod` in a startup step. Keeping
  the vocabulary backend-uniform beats exposing every sbx knob.

### Translation

- **sbx.** `kit_translate_to_sbx` passes entries through 1:1 into the
  synthesized sbx-v2 `volumes:` block. Creation-time only (`sbx kit add` skips
  volumes); multiple kits union by path, last wins — sbx resolves that itself.
- **msb.** `_acq_msb_volume_flags_into` maps a block entry to
  `--mount-named acq-<sandbox>-<pathslug>:<path>:kind=disk,size=<size>` and a
  tmpfs entry to `--tmpfs <path>:<size>` at create. The named volume is derived
  **deterministically** from sandbox name + path slug so
  `acq_backend_terminate` can find and remove it (`msb volume ls -q` +
  `msb volume rm`, prefix `acq-<sandbox>-`) after a successful `msb remove` —
  without the cleanup, named volumes would silently accumulate under
  `~/.microsandbox/volumes/`. `--mount-named` is create-or-reuse: a leftover
  same-name volume with incompatible settings fails the create loudly rather
  than silently changing it.

### Unseeded mounts (both backends, by design)

Volumes mount **unseeded**: an empty filesystem shadows any image content at
the path (verified empirically on sbx 0.38; msb named volumes behave the
same). This is documented, backend-uniform behavior — the translator does not
try to fix it. A kit that needs the image's content at the path ships its own
first-boot copy step; content shadowed by the mount stays reachable through a
non-recursive bind mount of `/` (e.g. `mount --bind / /mnt/rootfs`, then copy
from `/mnt/rootfs/<path>`).

### Validation (SI-10)

Volume fields are untrusted kit input that reach a generated YAML spec and an
msb argv:

- `path` MUST be absolute and charset-restricted (`[A-Za-z0-9._/-]`); `type`
  MUST be empty or `tmpfs`; `size` MUST match the kit-spec v2 §5.7 byte-size
  grammar (`units.RAMInBytes`, e.g. `20G`, `512m`, `2gib`). Offending entries
  are dropped with a warning and reported by `acq kit validate`.
- The msb adapter re-checks the charset before values reach the create argv
  (defense-in-depth, mirroring `_acq_msb_port_flags_into`).

### Cross-repo gate (open)

The authoritative `hybrid/v1` schema lives in the patterns repo
(`schemas/kit-hybrid-v1.schema.json`, `validate-kits.py`), which does not yet
carry a `volumes` property. Per the ADR-0011/0014 discipline the neutral field
is read **defensively** here (absence is a silent no-op, never an error), so
this lands safely ahead of the schema; the field lights up end-to-end once the
patterns schema gains the property and `PATTERNS_KIT_REF` advances to a
released commit that includes it.

## Consequences

- **Better:** kits declare sized storage once, neutrally; the
  startup-storage-rearrangement race class disappears on both backends; the
  `/nix` relocation workaround (and its per-restart window) becomes a plain
  volume + seed step.
- **Tradeoff (accepted, flagged):** msb derived-volume cleanup is
  prefix-matched (`acq-<sandbox>-`), so a sandbox name that is itself a prefix
  of another sandbox's name + `-` (e.g. `web` vs `web-2`) could match the
  longer name's volumes at `rm` time. Accepted for now: acq's `derive_name`
  produces distinct agent-workspace slugs, and an exact-match cleanup would
  require re-fetching kit specs at terminate.
- **Tradeoff:** on msb a volume's contents do NOT survive `acq rm` (they die
  with the sandbox, like sbx). A user who wants sandbox-independent persistent
  storage manages a named volume outside acq.
- **Compliance:** no new external services or data classification change
  (CM-2/CM-3/CM-6); the new fields are validated before reaching a spec/argv
  (SI-10). Structural translator + adapter change (SA-8/SA-15/SA-17).

## Validation

- `bash -n acq acq.backends/*.sh` clean; `scripts/test-acq` gains cases
  (§10a5): neutral parse → sbx-v2 `volumes:` block + msb `--mount-named`/
  `--tmpfs`; invalid path/type/size dropped + warned and reported by
  `acq kit validate`; absence a no-op; `acq_backend_terminate` removes the
  sandbox's derived volumes and leaves other volumes alone.
- `scripts/verify-backends` gains a live check: a fixture kit declaring a 256m
  block volume is appended to every create; the guest must show
  `/acq-verify-vol` as a mountpoint on a dedicated `/dev` block device of
  roughly the declared size, and on msb the derived volume must be gone after
  `acq rm`. Live end-to-end runs need a sandbox-capable host per ADR-0011.
- Live-confirmed on msb 0.6.12 (macOS, no sandbox needed): the `--mount-named`/
  `--tmpfs` flag grammar, and a `msb volume create --kind disk --size 256M` →
  `ls -q` → `rm` round-trip (the exact verbs the terminate cleanup drives).
  Finding: msb refuses ext4 disk images below 128M ("image size is too small
  for ext4 formatting"), so the fixture — and kit authors — should stay well
  above it (~256m practical floor).
- **Live end-to-end PASSED on both backends** (`scripts/verify-backends` with
  the fixture kit):
  - msb 0.6.12 (macOS HVF), `--only msb` 17/17 — the derived disk volume
    mounted at boot on a dedicated virtio-blk device (`/dev/vdc`, 190432 kB
    usable for the declared 256m), and was removed again on `acq rm`.
  - sbx 0.39.0, `--only sbx` 9/9 — the synthesized v2 `volumes` block was
    accepted and mounted at boot on a dedicated block device (`/dev/vde`,
    235431 kB usable for the declared 256m). Notably one release past the
    0.38.0 the driver issue verified against, so 0.39's volume rework kept the
    sized-volume path intact.

## Links

- Driver: [#329](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/329)
  (neutral `volumes:` vocabulary; msb parity research in-thread)
- Builds on: [ADR-0011](0011-msb-backend-and-neutral-kits.md) (neutral
  vocabulary), [ADR-0014](0014-neutral-port-publish-and-background-vocab.md)
  (neutral-field promotion pattern + defensive read),
  [ADR-0010](0010-acq-pluggable-backends.md) (adapter contract)
- Upstream surfaces: sbx kit-spec v2 §5.7 (docker/sbx-kits-contrib
  `spec/SPEC-v2.md`); msb named/disk volumes + `msb volume` verbs
  (superradcompany/microsandbox docs, v0.6.8/0.6.9)
- Related upstream feature request (not acq's to fix): runtime-side seeding of
  volume content from the image (docker named-volume style)
