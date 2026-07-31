---
title: "Record Kit-Bundle Provenance and Offer a Safe Stale-Sandbox Refresh"
status: accepted
date: 2026-07-30
decision_makers: ["William Zujkowski"]
category: maintainability
nist_controls: ["CM-2", "CM-3", "CM-8", "SA-10", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0016: Record Kit-Bundle Provenance and Offer a Safe Stale-Sandbox Refresh

## Context and Problem Statement

`acq` applies a built-in "bundle" of four neutral kits (USAi provider, playbook,
Zscaler CA, git-ssh-sign) to each sandbox, pinned to a full 40-char
`PATTERNS_KIT_REF` in `acq.backends/common.sh`. When a maintainer bumps that pin
(for example, after USAi adds new models to the canonical `opencode.jsonc` in the
patterns repo), **new** sandboxes get the new bundle. **Existing** sandboxes do
not:

- On **sbx**, `acq_backend_ensure_kits_applied` only injects kits that are
  *absent* (a feature-probe). A kit that is present but built from an older ref is
  never refreshed.
- On **msb**, every kit is re-applied idempotently each run, so the files can
  update — but nothing tells the user it happened, and there was no way to answer
  the basic question "is this sandbox on my current pin?"

Nothing inside or beside a sandbox recorded **which** bundle ref was applied, so
"is this sandbox current?" was unanswerable. Users silently drifted.

The prerequisite for this work — an additive `provenance` block on the
`hybrid/v1` kit schema — is provided by the pinned `PATTERNS_KIT_REF` in the
patterns repo.

## Decision

`acq` records **host-side** kit-bundle provenance for each sandbox and uses it to
detect staleness against the **local** pinned `PATTERNS_KIT_REF`, offering a safe
in-place refresh.

1. **Provenance record (host-side).** After a successful bundle apply — in
   `acq_backend_provision` and `acq_backend_ensure_kits_applied` for both
   backends — acq writes a small `key=value` record under
   `${XDG_STATE_HOME:-$HOME/.local/state}/acq/provenance/<backend>/<sandbox>.env`
   (overridable with `ACQ_PROVENANCE_DIR`). It records the bundle name, source
   repo, the exact applied `PATTERNS_KIT_REF`, the backend, and an ISO-8601 UTC
   timestamp. The write is atomic (temp file + `mv`) and **only after success**,
   so a failed apply never claims currency.

2. **Host-side, not guest-side.** The record lives on the machine running acq,
   keyed by backend + sandbox name. Reading it needs no guest `exec`, so the
   check is fast and works for a stopped sandbox. If host state is lost, the
   sandbox reads as `unknown`, which is treated as "offer a refresh" — never a
   destructive default.

3. **Staleness = exact-ref mismatch, fail-open.** `acq_provenance_status`
   returns `current` (recorded ref == local pin), `stale` (recorded ref != local
   pin), or `unknown` (no/unreadable record). No git-ancestry check and no
   network call: the comparison is deterministic and offline-safe, and the
   **local checkout's pin is the source of truth** (never the mutable patterns
   `main`). A newer-but-different pin correctly offers a refresh.

4. **Automatic advisory on `acq run`.** For an **existing** sandbox,
   `maybe_offer_bundle_refresh` runs after the heal step. When the sandbox is
   `stale`/`unknown` it offers an in-place refresh. It is **interactive only**,
   defaults to **No**, treats EOF/Ctrl-D as decline, and a decline never blocks
   launch. In a **non-interactive** run (no TTY) it prints one concise advisory
   and continues — it never blocks. A just-provisioned sandbox is current by
   construction, so the offer is only on the existing-sandbox paths.

5. **Explicit commands.** `acq kit check SANDBOX` reports status read-only (no
   mutation). `acq kit update SANDBOX [--yes]` reapplies the bundle in place;
   `--yes` skips the confirmation and is honored **only** on this explicit
   command (the automatic run-check never auto-updates). A non-interactive
   `acq kit update` without `--yes` refuses rather than guessing.

6. **Opt-out.** `ACQ_UPDATE_CHECK=0` (env) or `acq run --no-update-check` (single
   run) silences the automatic check. The explicit commands still work.

7. **Whole-bundle reconcile via the existing idempotent path.** The refresh
   reuses `acq_backend_ensure_kits_applied` — sbx injects any absent kits, msb
   re-applies all kits idempotently — then rewrites provenance. It is an in-place
   kit reapply: sessions, secrets, unrelated config, and project overrides are
   preserved. It never deletes or recreates the sandbox. If a backend cannot
   update cleanly, acq explains, preserves the sandbox, and prints a manual
   recovery path (`acq kit update` again, or `acq rm && acq run`).

## Consequences

### Positive

- A maintainer bumps `PATTERNS_KIT_REF` once; existing sandboxes are detected as
  stale and can be refreshed in place, on the user's terms.
- `acq kit check` answers "is this sandbox current?" deterministically and
  offline.
- No new network or trust surface: provenance is local, and the source of truth
  stays the pinned SHA. A separately-tracked "checkout behind origin" network
  check is intentionally out of scope here.
- Fail-open throughout: a lost record, an unreadable file, or a non-TTY run never
  blocks a launch.

### Negative / trade-offs

- Provenance is host-local: if the user deletes `~/.local/state/acq` or moves to a
  new machine, existing sandboxes read as `unknown` and re-offer a refresh. This
  is safe (a refresh is idempotent) but can prompt once unnecessarily. Chosen
  over a guest-side record to avoid a per-run `exec` round-trip and per-backend
  read/write code; a guest mirror can be added later if needed.
- Staleness is exact-ref, so a *downgrade* of the local pin also reads as `stale`.
  That is correct behavior (the sandbox does not match the pin) even if it is not
  strictly "older".

### Neutral

- The record format is a dependency-free flat `key=value` file, matching the
  awk-parsed acq config convention (no YAML/JSON parser added to the shell path).

## Alternatives Considered

- **Guest-side provenance** (write inside each sandbox). Survives host-state
  loss, but costs an `exec` per check and needs per-backend paths/ownership.
  Rejected as heavier; revisit if host-local proves insufficient.
- **Git-ancestry staleness** (flag only when the recorded ref is a true ancestor
  of the local pin). More precise, but needs a git call against patterns history,
  adds a network/trust surface, and cannot run offline. Rejected: exact-ref
  mismatch matches "the local pin is the source of truth".
- **Auto-refresh on run.** Rejected: mutating a user's sandbox without consent
  violates the fail-safe posture. The default is always No / advisory.

## Security Considerations

- The sandbox name is sanitized to a safe filename charset before it is used in a
  filesystem path (defense-in-depth against traversal via a crafted name).
- No secrets are read or written by the provenance path; the record holds only a
  commit SHA, a bundle name, a repo slug, a backend name, and a timestamp.
- SHA pinning is preserved: `PATTERNS_KIT_REF` remains a full 40-char SHA and the
  refresh fetches exactly that ref, never mutable `main`.
- The backend abstraction is preserved: the shared logic lives in `common.sh`;
  each adapter only calls `acq_provenance_write` after its own successful apply.

## Rollback

Revert the commits on the feature branch. The provenance records under
`~/.local/state/acq/provenance` are inert data; they can be left in place or
removed with no effect on sandboxes. No sandbox state is touched by a rollback.

## References

- ADR-0009 (in-place kit healing), ADR-0011 (msb backend and neutral kits)
