---
title: "USAi Placeholder Recovery: Offer Session-Preserving Recreate, Then Non-Destructive Rebind"
status: accepted
date: 2026-07-08
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["AC-6", "CM-6", "IA-5", "SC-12", "SI-11", "SI-17"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0008: USAi Placeholder Recovery — Offer Session-Preserving Recreate, Then Non-Destructive Rebind

## Context and Problem Statement

USAi is injected into sandboxes as a **custom secret** (`sbx secret set-custom`),
which is **not** proxied. sbx bakes a **placeholder token** into each sandbox's
`USAI_API_KEY` at creation time and resolves that placeholder to the real global
secret value at request time (see
[KNOWN_FAILURE_MODES.md §14](../KNOWN_FAILURE_MODES.md#14-sbx-proxy-doesnt-work-with-custom-baseurl-security-implication)).

`scripts/rotate-apikey` (`qsbx usai-rotate-api-key`) deliberately **preserves**
the placeholder across rotation, so existing sandboxes keep resolving. But a user
who instead **deletes and re-adds** the global USAi secret — or otherwise
regenerates it — causes sbx to mint a **new** placeholder. A freshly created
sandbox picks up the new placeholder; an **existing** sandbox still carries the
**old** one, which the proxy can no longer resolve. The proxy then injects an
**empty** `USAI_API_KEY`, and USAi returns **HTTP 401**. The sandbox's baked-in
value can even read back **empty**.

`qsbx` already distinguished this from an expired key: on a sandbox 401 it probes
a throwaway fresh sandbox, and a fresh-200 result routes to
`offer_update_stale_placeholder`. But that function had two defects:

1. It rebound the sandbox-scoped secret to the **sandbox's own** placeholder
   (`--placeholder "$sandbox_placeholder"`) — the very value that stopped
   resolving — so the "repair" re-bound to a dead token.
2. When the sandbox placeholder read back **empty** (the common real case, seen
   in the field), it hit a hard `Could not read the sandbox's USAI_API_KEY
   placeholder. Aborting attach.` with **no recovery path** — the exact dead-end
   a user reported.

The question: what should `qsbx` do when it detects this orphaned-placeholder
state, given that the sandbox's `opencode.jsonc` is otherwise correct and the
user may have live chat sessions in it?

## Decision

`qsbx` treats this as a **recoverable** state and offers two routes, in order.

### 1. Offer a session-preserving recreate first (when it can)

> **Note ([ADR-0009](0009-require-sbx-0.35.0-in-place-kit-healing.md)):** as of
> ADR-0009, pre-kit sandboxes heal in place via `sbx kit add`, so this
> stale-placeholder recovery is the **sole remaining consumer** of
> `migrate_or_halt` (and `halt_with_options`). They are retained specifically for
> route 1 below.

When `qsbx run` has the create args in hand (the AGENT form), the **first**
option is to recreate the sandbox via the existing session-preserving migration
(`migrate_or_halt`): export sessions (sanitized) → remove → recreate with the
kits (which mint a correct, current placeholder) → import sessions. This is the
most reliable fix because it guarantees the sandbox carries the current
placeholder, and it reuses a well-tested, fail-closed path (never removes a
sandbox without a verified export).

### 2. Non-destructive rebind to the CURRENT GLOBAL placeholder

If the user declines the recreate (or on the attach-by-name form, where `qsbx`
lacks the create args), `qsbx` offers to add a **sandbox-scoped** custom secret
bound to the **current global placeholder** — read from `sbx secret ls -g` via
`global_usai_placeholder`, **never** the stale/empty sandbox value — then
re-validates with `check_key`. The user is prompted for the current key; it is
never passed on the command line.

### 3. Fail closed only when there is nothing safe to bind to

If the sandbox placeholder already **equals** the current global placeholder,
this is not a stale-placeholder case and `qsbx` aborts (rebinding would change
nothing). If there is **no** global placeholder to bind to (the secret is truly
gone), `qsbx` aborts with explicit recreate guidance rather than binding to an
empty value. Binding to the stale/empty sandbox placeholder — the old bug — is
never done.

## Consequences

- **Better:** the reported dead-end (empty placeholder → hard abort) becomes a
  guided recovery. The default path preserves the user's sessions; the fallback
  keeps the sandbox in place without deleting anything.
- **Correctness:** the rebind now targets the **current global** placeholder, so
  it actually resolves — fixing the second defect where the repair re-bound to a
  dead token.
- **Least privilege / secret hygiene (AC-6, IA-5):** the key is still entered
  interactively (never on the command line or in shell history); rebinding is
  scoped to the single affected sandbox.
- **Reuse:** route 1 reuses `migrate_or_halt`'s fail-closed guarantees rather
  than adding a second destructive path.
- **Limitation:** on attach-by-name, only the rebind is offered (no create args
  to recreate with); the user can re-run in AGENT form to get the recreate
  option. Noted in the code.
- **Not prevented at the source:** this does not stop a delete+re-add from
  orphaning placeholders in the first place; prevention is documented guidance
  (use `qsbx usai-rotate-api-key`). Acceptable for a low-impact dev tool.

## Validation

- Offline unit checks in `scripts/test-migrate-or-halt` (stubbed `sbx`, no Docker
  or network) covering `offer_update_stale_placeholder`:
  - empty sandbox placeholder + present global, decline recreate + accept rebind,
    post-repair 200 → returns 0 and binds to the **current global** placeholder;
  - accept the recreate offer → runs the migration (`sbx rm`/recreate) and does
    **not** `secret set-custom`;
  - empty sandbox placeholder + **no** global → aborts with recreate guidance,
    no `set-custom`;
  - sandbox placeholder == global (not stale) → aborts, no `set-custom`;
  - attach-by-name (no create args) → recreate not offered; rebind used.
- `bash -n qsbx` clean; `./scripts/test-migrate-or-halt` 49/49; markdownlint /
  shellcheck / gitleaks via `npm run lint` clean.
- **Verified live** with `./scripts/verify-migrate-live` on a sandbox-capable
  host: the end-to-end path (recreate/rebind against a real sandbox, USAi 200
  afterward, session preserved) succeeds.

## Links

- Failure mode: [KNOWN_FAILURE_MODES.md §23](../KNOWN_FAILURE_MODES.md#23-usai-401-in-an-existing-sandbox-after-deletingrecreating-the-global-secret)
- Related: [ADR-0005](0005-kits-from-patterns-and-agent-trust-model.md) (kits by
  pinned reference), [KNOWN_FAILURE_MODES.md §14](../KNOWN_FAILURE_MODES.md#14-sbx-proxy-doesnt-work-with-custom-baseurl-security-implication)
  (custom-secret injection), [§20](../KNOWN_FAILURE_MODES.md#20-authentication-failed-after-copying-a-new-key)
- Rotation helper that preserves the placeholder: `scripts/rotate-apikey`
  (now a thin shim; the placeholder-preserving logic moved into
  `acq.backends/sbx.sh` as `acq_backend_rotate_key` per
  [ADR-0012](0012-backend-neutral-key-rotation.md))
- Upstream custom-service support: [docker/sbx-releases#35](https://github.com/docker/sbx-releases/issues/35)
