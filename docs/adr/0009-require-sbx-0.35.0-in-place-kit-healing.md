---
title: "Require sbx >= 0.35.0 and Heal Pre-Kit Sandboxes In Place with sbx kit add"
status: accepted
date: 2026-07-14
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-11", "SI-7", "SI-17"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0009: Require sbx >= 0.35.0 and Heal Pre-Kit Sandboxes In Place with `sbx kit add`

## Context and Problem Statement

[ADR-0005](0005-kits-from-patterns-and-agent-trust-model.md) had `qsbx` deliver
its configuration as sbx mixin kits applied at sandbox-create time. Sandboxes
created before that migration (by an older `qsbx`, or a plain `sbx run` without
the `--kit` refs) have no USAi provider config and no playbook clone. The natural
fix — inject the missing kit into the existing sandbox with `sbx kit add` — was
**blocked by an upstream sbx bug** ([docker/sbx-releases#133][133]): on sbx
≤ 0.34.x, `sbx kit add` failed with `failed to read tar header: unexpected EOF`
on any kit shipping a static `files/` payload, which the `usai-provider` kit
does. A sandbox without the USAi provider config is unusable, so `qsbx`:

- gated in-place healing OFF behind `QSBX_AUTOHEAL_KITS` (default off), and
- offered a hand-rolled, **destructive** session migration instead
  (`migrate_or_halt`: export sanitized sessions → `sbx rm` the old sandbox →
  recreate with kits → import), or halted with manual options.

sbx **0.35.0** (2026-07-10) fixes #133: `sbx kit add` now **recreates the
sandbox container with the augmented kit set and preserves state**. It also
fixes `sbx cp` on a kit-added sandbox and lets `sbx run --name` re-attach to a
`--kit` sandbox without re-passing `--kit`. This removes the reason for both the
`QSBX_AUTOHEAL_KITS` gate and the bespoke migration path.

The question: adopt 0.35.0 as the floor and delete the workaround, given that
0.35.x ships **no Linux/ARM64 build** (deferred to 0.36.x)?

## Decision Drivers

- **Simplicity / least code:** the workaround (disable flag + a destructive,
  fail-closed export/recreate/import path + a pre-kit detector) exists solely to
  route around #133. With #133 fixed, it is dead weight and extra risk surface.
- **Non-destructive healing:** `sbx kit add` on 0.35.0 preserves state, so a
  pre-kit sandbox is repaired in place — no `sbx rm`, no session export/import.
- **Correctness / integrity (SI-7):** kits stay SHA-pinned; healing composes the
  same integrity-checked kits an initial create would.
- **Platform coverage:** 0.35.x has no Linux/ARM64 build, so a hard floor blocks
  that arch until 0.36.x.

## Considered Options

1. **Require >= 0.35.0; heal in place; remove the workaround.** Set the floor,
   run `ensure_kit_applied` unconditionally, delete the `QSBX_AUTOHEAL_KITS` flag
   and the pre-kit migration wiring.
2. **Keep floor at 0.34.0; keep the workaround for older sbx.** Support both:
   heal in place when `kit add` works, migrate otherwise. Maximum compatibility,
   maximum code.
3. **Require >= 0.35.0 but keep `migrate_or_halt` wired as a pre-kit fallback.**
   Redundant once healing is reliable.

## Decision Outcome

**Chosen: Option 1**, with a targeted Linux/ARM64 accommodation.

- `qsbx` requires **sbx >= 0.35.0** (`MIN_SBX_VERSION`). `require_sbx_version`
  fails closed below the floor, and on a **Linux/ARM64** host prints specific
  guidance (no 0.35.x ARM64 build; run on x86_64 or wait for 0.36.x) rather than
  a generic "upgrade" message the user cannot act on.
- In-place healing runs **unconditionally**: the `QSBX_AUTOHEAL_KITS` flag is
  removed and `ensure_kit_applied` heals any missing kit with `sbx kit add`
  (which recreates the sandbox preserving state).
- The pre-kit **detection + destructive migration wiring** is removed from the
  `run` dispatch (`sandbox_missing_usai` is deleted; `migrate_or_halt` /
  `halt_with_options` are no longer called for pre-kit sandboxes).
- **`migrate_or_halt`, `halt_with_options`, and their session export/import
  helpers are retained** — they remain route 1 of the unrelated ADR-0008
  stale-placeholder recovery (`offer_update_stale_placeholder`), a problem
  (delete + re-add of the global USAi secret) that still exists on 0.35.0 and is
  independent of #133.

## Consequences

- **Better:** pre-kit sandboxes heal in place with state preserved; no
  destructive `sbx rm`/export/import for the common upgrade path. Less code, one
  fewer feature flag, simpler `run` dispatch.
- **Tradeoff (platform):** Linux/ARM64 hosts cannot meet the floor until sbx
  0.36.x restores ARM64 builds. Accepted at FIPS-Low for a dev tool; `qsbx` and
  the README give explicit guidance (use x86_64 or wait for 0.36.x). Revisit when
  0.36.x ships.
- **Compliance:** healing composes the same SHA-pinned kits (SI-7); the change is
  a configuration-management decision (CM-2/CM-3/CM-6) with no new attack surface.
- **Docs:** README (Step 2, "Staying Current") and
  `docs/KNOWN_FAILURE_MODES.md` §19 are updated to describe in-place healing; the
  #133 history is kept as a note.
- **Superseding scope:** this narrows ADR-0005's healing description (which said
  `ensure_kit_applied` heals a sandbox missing a kit) to "unconditional, via
  0.35.0 `sbx kit add`"; ADR-0005 otherwise stands.

## Validation

- `bash -n qsbx` clean; `./scripts/test-migrate-or-halt` passes (the pre-kit
  `sandbox_missing_usai` cases are removed; the retained `migrate_or_halt` /
  `offer_update_stale_placeholder` / `halt_with_options` cases still pass).
- `npm run lint` (markdownlint, shellcheck, gitleaks, YAML/JSON) clean.
- **Deferred, requires a sandbox-capable host on sbx 0.35.0:**
  `./scripts/verify-migrate-live` repurposed to prove in-place healing —
  create a pre-kit sandbox (no kits), `qsbx run` it, assert `sbx kit add`
  applied the USAi kit and prior state survived. Must pass before merge.

## Links

- Upstream fix: [docker/sbx-releases#133][133]; sbx
  [v0.35.0 release notes](https://github.com/docker/sbx-releases/releases/tag/v0.35.0)
- Narrows: [ADR-0005](0005-kits-from-patterns-and-agent-trust-model.md)
- Related: [ADR-0008](0008-usai-placeholder-recovery.md) (sole remaining consumer
  of `migrate_or_halt`)
- Failure mode: [KNOWN_FAILURE_MODES.md §19](../KNOWN_FAILURE_MODES.md#19-opencode-shows-wrong-providers)

[133]: https://github.com/docker/sbx-releases/issues/133
