# acq Backend Parity — sbx vs. msb

> **Status:** analysis / planning input (not a decision record).
> **Scope:** the gaps between the `sbx` and `msb` backends of `acq` as they
> stand after quickstart 2.0.1 (patterns `PATTERNS_KIT_REF` v1.7.0), and how each
> gap is dispositioned — schedule, accept, or upstream-blocked.
> **Companion ADR:** [ADR-0014](../adr/0014-neutral-port-publish-and-background-vocab.md)
> (the neutral port-publish + background vocabulary, gap A below).
>
> **Rebase note (main moved under us):** several referenced PRs have since merged
> to `main` — #221/#223 (sbx port-publish carry + `--kit` interception, gap A
> sbx-half), #229 (per-sandbox GitHub token, new ADR-0013), and #230 (msb agent
> install/launch + GitHub-via-REST secret binding, which closed #203). Gap C and
> gap F below are updated accordingly; the companion ADR was renumbered
> 0013→**0014** because #229 landed a different ADR-0013.

This document is the shared map for bringing `msb` up to parity with `sbx`. It
does not itself change behavior; it records what differs, why, and what the
trigger is for each item that is being deferred or accepted. Tracking issues are
filed from the "Actionable" rows once the plan is approved.

---

## Background

`acq` runs one command surface over multiple isolation backends
([ADR-0010](../adr/0010-acq-pluggable-backends.md)). Kits are authored once in
the neutral `hybrid/v1` vocabulary and translated per backend by
`acq.backends/kit-translate.sh` ([ADR-0011](../adr/0011-msb-backend-and-neutral-kits.md)).
Two adapters ship today: `acq.backends/sbx.sh` (Docker Sandboxes) and
`acq.backends/msb.sh` (microsandbox). Both implement the same
`acq_backend_*` contract, but the underlying runtimes differ, and a handful of
capabilities are wired for one backend and not the other.

`agentContext` is applied by **neither** adapter today, so it is parity (equally
absent), not a gap. This document lists only the real divergences.

---

## Gap summary

| # | Gap | State | Disposition |
|---|-----|-------|-------------|
| A | No neutral port-publish / background vocabulary (sbx-half landed via #221/#223) | [#224](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/224), patterns [#233](https://github.com/GSA-TTS/agentic-coding-patterns/issues/233) | **Schedule** (ADR-0014) |
| B | msb `SUPPORTS_SNAPSHOTS=1` is unreachable (no `acq snapshot` verb / contract fn) | [#225](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/225) | **Schedule** (drop flag to 0) |
| C | msb secret binding is a fixed table (usai + github via REST); arbitrary custom endpoints stored-not-bound | [#226](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/226) | **Schedule** (generic custom-endpoint) |
| D | `opencode-web.sh` — removed; openchamber kit supersedes it | folded into #233 | **Removed** (see gap D) |
| E | No state-preserving in-place kit heal on msb | ADR-0011 accepted | **Accept** + minor runtime UX note |
| F | Private GitHub clone (playbook kit) on msb — RESOLVED via REST tarball on msb 0.6.7 (#230) | [#203](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/203) (closed) | **Resolved** (git-over-HTTPS still upstream-blocked) |
| G | `validate-kits.py` doesn't reject malformed `mode`/`user` | patterns [#225](https://github.com/GSA-TTS/agentic-coding-patterns/issues/225) | **Schedule** (patterns repo) |
| H | test-acq msb auto-detect flaky when real `sbx` on PATH | [#217](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/217) | **Schedule** (test hygiene) |
| I | `verify-backends` msb row never runs in CI (needs KVM) | ADR-noted | **Accept** (document cadence) |
| J | Doc drift in BACKEND_GUIDE (version banner + differences table) | [#227](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/227) | **In progress** (banner + tables refreshed this branch) |

---

## Gap details

### A. No neutral port-publish / background vocabulary — **Schedule**

**Evidence.** `publishedPorts` and `background` live only under
`backend_extras.sbx` in the neutral spec. `kit-translate.sh`'s
`kit_spec_published_ports` explicitly reads *only* the sbx block, and
`acq.backends/msb.sh` has zero `publishedPorts`/`background` consumption. So a
kit that needs to expose a port or run a non-exiting supervisor (e.g.
`openchamber`) can only declare `backends: [sbx]`.

**Why it matters.** This is the single biggest blocker to a kit declaring
`backends: [sbx, msb]`. It is cross-repo: acq owns the translator/adapters, and
the neutral schema lives in patterns (`schemas/kit-hybrid-v1.schema.json`,
`validate-kits.py`).

**Landed on main (rebase).** The sbx half is already in: PR #221 made
`kit_translate_to_sbx` emit `backend_extras.sbx.publishedPorts` into the sbx-v2
spec (closing #219) and single-quote wildcard allow hosts (closing #220), while
PR #223 taught `acq run/create` to intercept a user `--kit <ref>` and translate
it.
So the remaining gap-A work is narrower than when this map was written: promote
the field to the **neutral** level (out of `backend_extras.sbx`) and add the
**msb consumer**; the sbx path becomes a rename + one-release deprecated
fallback rather than a new carry.

**Disposition.** Design in [ADR-0014](../adr/0014-neutral-port-publish-and-background-vocab.md);
implement the neutral fields + msb consumer in quickstart; land the schema
property in patterns; then flip openchamber to `backends: [sbx, msb]`
(patterns #233 Increment B).

### B. msb snapshots are unreachable — **Schedule**

**Evidence.** `acq.backends/msb.sh` sets `ACQ_BACKEND_SUPPORTS_SNAPSHOTS=1`, but
`acq` has no `snapshot` subcommand and the ADR-0010 adapter contract has no
`acq_backend_snapshot` function. `sbx` sets the flag to `0`. The capability is
advertised but cannot be invoked.

**Why it matters.** A declared capability with no dispatch point is silently
inert (the AGENTS.md "wiring complete" self-check). Either wire it or drop the
flag to 0 until it is wired.

**Disposition.** **Drop the flag to `0`** now — advertising a capability `acq`
cannot invoke is misleading. Set `ACQ_BACKEND_SUPPORTS_SNAPSHOTS=0` in
`acq.backends/msb.sh` and file a follow-up to wire a real `acq snapshot` verb +
`acq_backend_snapshot` contract function (with sbx returning "unsupported") when
snapshots are actually surfaced. This keeps the capability matrix honest without
committing to the larger snapshot UX now.

### C. msb secret binding is a fixed table (usai + github-via-REST) — **Schedule**

**Evidence.** `sbx.sh` feeds 7 built-in services
(`anthropic github gitlab google-cloud openai aws azure`) plus custom
`--host/--env` endpoints. On msb, #230 generalized the re-feed/rotate machinery
and added a `github` binding via the REST host: `_acq_msb_service_binding` is now
a fixed two-entry table — `usai` → `USAI_API_KEY@api.gsa.usai.gov` and `github`
→ `GITHUB_TOKEN@api.github.com` (REST only; see gap F). Any *other* service
(`acq secret set SANDBOX --host api.example.com --env API_KEY`) is still stored
in the acq store but **not bound** at provision (the `*)` arm returns empty).

**Why it matters.** A user who `acq secret set`s an arbitrary custom endpoint on
msb gets no `--secret ENV@HOST` binding — a silent no-op relative to sbx's
`set-custom` breadth. Closing this needs the acq secret store to persist the
per-service `--host`/`--env` pair (msb's `acq_backend_secret_set` does not yet
accept/store it) and `_acq_msb_service_binding` to read it back.

**Disposition.** **Schedule** — extend the msb provision path to bind generic
custom-endpoint services (any service with a resolved `--host`/`--env`) via
`--secret ENV@HOST`, mirroring sbx's `set-custom` breadth. GitHub is already
bound (REST host only); the git-over-HTTPS transport remains upstream-limited
(gap F). Tracked in #226.

### D. `opencode-web.sh` — **Removed** (superseded by the openchamber kit)

**Evidence.** `opencode-web.sh` hardcoded `sbx exec -d …` and printed
`sbx ports … --publish`; it had no msb branch and depended on gap A (a port must
be publishable) for any non-sbx future.

**Decision (updated).** The script has been **deleted**. The `openchamber` acq
kit is a functional superset — it runs `opencode serve` on host-published port
4096 (plus the OpenChamber UI on 3000) via `publishedPorts`, with a supervised
lifecycle — so the standalone helper no longer earns its keep as a separate
maintained entry point. This supersedes the earlier "keep it as a
zero-dependency escape hatch until #233 closes" disposition: rather than carry a
second, sbx-only code path, we consolidate on the kit.

**Consequence / dependency.** openchamber itself is still sbx-only until the
neutral port/background vocabulary lands (gap A / ADR-0014 / patterns
[#233](https://github.com/GSA-TTS/agentic-coding-patterns/issues/233)). So on
**msb** there is a browser-OpenCode coverage gap in the interim — this is folded
into the gap-A / #233 work (the openchamber kit reaching `backends: [sbx, msb]`)
rather than tracked as a separate item. Users needing the browser UI today use
the openchamber kit on sbx.

### E. No state-preserving in-place kit heal on msb — **Accept**

**Evidence.** sbx heals a sandbox missing kits with `sbx kit add` (state
preserved, requires sbx ≥ 0.35.0). msb's `acq_backend_ensure_kits_applied`
re-applies kits idempotently (files overwritten, install commands
marker-gated) because msb 0.6.6 has no equivalent state-preserving add. This is
recorded in ADR-0011.

**Disposition.** **Accept** — msb never silently destroys state, and the
idempotent re-apply is safe. Minor UX follow-up: the msb heal path is silent;
consider a one-line note that heal re-applies rather than adds in place.
**Trigger to revisit:** a microsandbox release that ships a state-preserving
in-place kit-add primitive.

### F. Private GitHub clone (playbook kit) on msb — **Resolved** (#230)

**Evidence.** microsandbox ≤ 0.6.6 did not substitute the credential placeholder
for git's HTTPS smart-transport to `github.com` (the `Authorization: Bearer`
header path for USAi worked, `git clone` did not). **Resolved on main:** msb
0.6.7 shipped the upstream fix for #1170, and #230 reworked the playbook kit to
fetch the repo **source tarball via the REST API**
(`api.github.com/repos/<repo>/tarball/<ref>`), which msb *does* substitute
(verified 0.6.7). acq now binds `GITHUB_TOKEN@api.github.com` on msb, so the
playbook kit works on msb. #203 is **closed** (on main, not yet in a tagged
release).

**Disposition.** **Resolved.** The generic `git clone` over HTTPS to
`github.com`/`codeload.github.com` is still not substituted upstream, so the
adapter deliberately binds the **REST host only** (`api.github.com`) and kits
that need github auth must use the REST API rather than `git clone`. **Residual
watch:** microsandbox git-transport substitution for `github.com`
([#756](https://github.com/superradcompany/microsandbox/issues/756) /
[#1170](https://github.com/superradcompany/microsandbox/issues/1170) fixed the
header path but not the git smart-transport) — if that lands, the adapter could
bind the git hosts too. No open quickstart issue remains for this gap.

### G. `validate-kits.py` doesn't reject malformed `mode`/`user` — **Schedule**

**Evidence.** patterns #225: the shared kit validator does not enforce
`files[].mode` (`^0?[0-7]{3,4}$`) or `commands[].user` (`^[0-9]+$`), and does not
reject shell metacharacters in `files[].path`. The msb adapter *does* defend at
the point of use (re-checks octal mode, passes `chmod`/`chown` as argv, rejects
unsafe paths), so this is defense-in-depth at the shared choke point, not an
open RCE in the current adapter — but the gate should still reject a hostile
spec before any adapter sees it.

**Disposition.** **Schedule in patterns** (the validator is the shared choke
point protecting every backend). Add the mode/user/path validation + regression
fixtures. Confirm the quickstart msb adapter's point-of-use defense stays.

### H. test-acq msb auto-detect flaky on a dev machine — **Schedule**

**Evidence.** #217: the "msb: auto-detect falls back to msb" test removes the
*stubbed* sbx but leaves a real `sbx` on the developer's PATH, so
`_auto_detect_backend` finds it and returns `sbx`. CI is clean (no real sbx);
local runs with sbx installed spuriously fail.

**Disposition.** **Schedule** — pin `PATH="$STUBDIR"` in the detection subshells
(both the "prefers sbx" and "falls back to msb" cases) so detection is
deterministic regardless of host tooling. Low-risk test hygiene. Already tracked
as #217.

### I. `verify-backends` msb row never runs in CI — **Accept**

**Evidence.** Only `scripts/test-acq` (offline, stubbed) is wired into
pre-commit/CI. `scripts/verify-backends` needs host virtualization (`/dev/kvm`)
and cannot run inside a sandbox (no nested sandboxes); the live msb
create→exec→attach loop is deferred, per ADR-0011.

**Disposition.** **Accept** — this is an environment constraint, not a code gap.
Document the manual cadence (run `scripts/verify-backends` on a KVM-capable host
after each release / after ≥3 behavior-affecting fixes, per AGENTS.md §8.3) and
capture the transcript. **Trigger to revisit:** availability of a KVM-capable CI
runner.

### J. Doc drift in BACKEND_GUIDE — **In progress** (partially refreshed)

**Evidence.** BACKEND_GUIDE.md said "As of 1.2.0" and listed msb/sbx table
versions as 1.1.0/1.2.0, while the repo is on the 2.x line. The "Differences
from sbx" table did not mention gaps B (snapshots unwired), C (secret breadth),
or D (opencode-web).

**Disposition.** **Refreshed in this branch:** the version banner is delinked
from a stale point release (2.x line), the per-backend version columns are
dropped, and the "Differences from sbx" + "Known limitations (msb)" sections now
fold in gaps B (snapshots inert, #225), C (fixed usai+github secret table, in
issue #226), D (opencode-web removed, openchamber supersedes), and the gap I
verify-backends cadence. The msb secret section and capability flags reflect
the github-via-REST binding from #230. #227 stays open to track any residual
drift as gaps A–C actually *land* (the guide currently describes them as
scheduled, not done).

---

## Sequencing

```
ADR-0014 (gap A design, accepted)   ── design gate
        │
        └─> A impl (quickstart translator + msb consumer)  ── unblocks patterns #233 Increment B
                (sbx half already merged: #221 carry + #223 --kit intercept)

        B (drop msb snapshot flag to 0 + follow-up wiring)  ── independent, low-risk
        C (msb generic secret binding)      ── independent (github REST bound via #230; arbitrary endpoints remain)
        H (test-acq PATH robustness)        ── independent, low-risk (#217)
        J (BACKEND_GUIDE refresh)           ── trails A–C

patterns, in parallel:
        G (validate-kits.py mode/user)      ── shared security choke point (#225)
        #233 Increment A (adopt quickstart#221, drop manual publish workaround)  ── unblocked now (#221 merged)
```

**Accepted / not scheduled** (documented above with triggers): **E** (heal),
**I** (verify-backends CI). **D** (opencode-web) is now **Removed** — the
standalone helper is deleted; the openchamber kit reaching `backends: [sbx, msb]`
is folded into gap A / #233. **F** (playbook clone on msb) is now **Resolved**
(#230, msb 0.6.7); its residual is an upstream git-transport watch, not a
tracked gap.

---

## Tracking issues

**Quickstart repo (new):**

1. [#224](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/224) —
   implement ADR-0014 neutral port-publish + background vocab and the msb
   consumer (gap A). Sbx half already merged (#221, #223).
2. [#225](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/225) —
   drop msb `ACQ_BACKEND_SUPPORTS_SNAPSHOTS` to 0; follow-up to wire a real
   `acq snapshot` + `acq_backend_snapshot` (gap B).
3. [#226](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/226) —
   broaden msb secret binding to generic custom-endpoint services (gap C).
   (github REST binding already landed via #230.)
4. [#227](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/227) —
   refresh BACKEND_GUIDE version banner + differences table (gap J).

**Quickstart repo (reuse):**

- [#217](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/217) —
  test-acq PATH robustness (gap H); commented to link this parity effort.

**Patterns repo:**

1. [#225](https://github.com/GSA-TTS/agentic-coding-patterns/issues/225) —
   harden `validate-kits.py` (reject malformed `mode`/`user`/`path` + fixtures)
   (gap G); commented to confirm scope + the ADR-0014 intersection.
2. [#233](https://github.com/GSA-TTS/agentic-coding-patterns/issues/233) —
   openchamber msb/ppp parity (gap A Increment B); commented that ADR-0014 +
   quickstart#224 unblock it, and Increment A is unblocked now (#221 merged).
   Now also the tracked home for gap D: with `opencode-web.sh` removed,
   openchamber is the sole browser-OpenCode path and its msb parity is what
   closes the interim msb coverage gap.

**Accepted (no new issue; keep existing watches):**
the ADR-0011 record for gap E; the verify-backends cadence (gap I) is documented
in the BACKEND_GUIDE refresh (quickstart #227). Gap D (opencode-web) is
**Removed** — no watch needed; its msb successor is patterns #233.

**Resolved (closed):**
[#203](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/203) (gap F) —
closed by #230 on main (msb 0.6.7 + REST-tarball playbook fetch); residual is an
upstream microsandbox git-transport watch only.
