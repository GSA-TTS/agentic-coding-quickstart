# acq Backend Parity — sbx vs. msb

> **Status:** analysis / planning input (not a decision record).
> **Scope:** the gaps between the `sbx` and `msb` backends of `acq` as they
> stand after quickstart 2.0.1 (patterns `PATTERNS_KIT_REF` v1.7.0), and how each
> gap is dispositioned — schedule, accept, or upstream-blocked.
> **Companion ADR:** [ADR-0013](../adr/0013-neutral-port-publish-and-background-vocab.md)
> (the neutral port-publish + background vocabulary, gap A below).

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
| A | No neutral port-publish / background vocabulary | [#224](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/224), patterns [#233](https://github.com/GSA-TTS/agentic-coding-patterns/issues/233) | **Schedule** (ADR-0013) |
| B | msb `SUPPORTS_SNAPSHOTS=1` is unreachable (no `acq snapshot` verb / contract fn) | [#225](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/225) | **Schedule** (drop flag to 0) |
| C | msb secret binding is USAi-only (sbx feeds 7 built-ins + custom endpoints) | [#226](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/226) | **Schedule** (generic custom-endpoint); github stays blocked by F |
| D | `opencode-web.sh` is sbx-only | untracked | **Accept** (retire when #233 closes; openchamber supersedes) |
| E | No state-preserving in-place kit heal on msb | ADR-0011 accepted | **Accept** + minor runtime UX note |
| F | Private GitHub clone (playbook kit) skipped on msb | [#203](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/203) | **Accept** (upstream-blocked) |
| G | `validate-kits.py` doesn't reject malformed `mode`/`user` | patterns [#225](https://github.com/GSA-TTS/agentic-coding-patterns/issues/225) | **Schedule** (patterns repo) |
| H | test-acq msb auto-detect flaky when real `sbx` on PATH | [#217](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/217) | **Schedule** (test hygiene) |
| I | `verify-backends` msb row never runs in CI (needs KVM) | ADR-noted | **Accept** (document cadence) |
| J | Doc drift in BACKEND_GUIDE (version banner + differences table) | [#227](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/227) | **Schedule** (docs) |

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

**Disposition.** Design in [ADR-0013](../adr/0013-neutral-port-publish-and-background-vocab.md);
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

### C. msb secret binding is USAi-only — **Schedule**

**Evidence.** `sbx.sh` feeds 7 built-in services
(`anthropic github gitlab google-cloud openai aws azure`) plus custom
`--host/--env` endpoints. `msb.sh` `acq_backend_secret_set` stores every service
in the acq store but only *binds* `usai` at provision
(`--secret USAI_API_KEY@api.gsa.usai.gov`); `github` and any other service are
stored-but-not-wired (the `*)` arm says so explicitly).

**Why it matters.** A user who `acq secret set`s a custom endpoint on msb gets no
`--secret ENV@HOST` binding — a silent no-op relative to sbx.

**Disposition.** Extend the msb provision path to bind generic custom-endpoint
services (any service with a resolved `--host`/`--env`) via `--secret ENV@HOST`,
mirroring sbx's `set-custom` breadth. **GitHub specifically stays unbound** — see
gap F; that is upstream-blocked, not a scope choice.

### D. `opencode-web.sh` is sbx-only — **Accept** (retire on #233)

**Evidence.** `opencode-web.sh` hardcodes `sbx exec -d …` and prints
`sbx ports … --publish`. There is no msb branch.

**Why it matters.** The documented "run OpenCode in the browser" flow only works
on sbx. It also depends on gap A (a port must be publishable on msb).

**Disposition.** **Keep the script; do not add an msb path.** The `openchamber`
acq kit (patterns v1.8.0, PR #234) is a functional superset — it runs
`opencode serve` on host-published port 4096 (plus the OpenChamber UI on 3000)
via `publishedPorts`, with a robust supervised lifecycle. But it is **not** a
drop-in replacement today: it is opt-in and applied only at sandbox-create time,
pulls in the OpenChamber UI + a native module, and is itself sbx-only until the
gap-A port vocabulary lands (patterns #233). `opencode-web.sh` remains the
zero-dependency, backend-agnostic escape hatch for a bare/existing sandbox — a
conclusion the design doc (`acq-design.md:282`) already reached ("stays too —
still useful"). **Trigger to retire:** patterns #233 closes (openchamber reaches
`backends: [sbx, msb]` parity). At that point, delete `opencode-web.sh` and
update the two references (README "OpenCode Web" bullet, `acq-design.md:282`).

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

### F. Private GitHub clone (playbook kit) skipped on msb — **Accept**

**Evidence.** microsandbox 0.6.6 does not substitute the credential placeholder
for git's HTTPS smart-transport to `github.com` (verified extensively; the
`Authorization: Bearer` header path for USAi works, git does not). acq therefore
does not bind a GitHub `--secret` on msb; the playbook clone warns and continues
(non-fatal). Fully documented in ADR-0011 and BACKEND_GUIDE, tracked in #203.

**Disposition.** **Accept** — upstream-blocked. **Trigger to revisit:**
microsandbox [#756](https://github.com/superradcompany/microsandbox/issues/756) /
[#1170](https://github.com/superradcompany/microsandbox/issues/1170) fixed (git
HTTPS substitution works). Then bind `GITHUB_TOKEN` for the github hosts and
have the guest git clone carry the placeholder. Interim workarounds
(documented): use sbx for the playbook kit, or ship a base image with the
playbook pre-cloned, or make the repo public. #203 stays open as the watch.

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

### J. Doc drift in BACKEND_GUIDE — **Schedule**

**Evidence.** BACKEND_GUIDE.md says "As of 1.2.0" and lists msb/sbx table
versions as 1.1.0/1.2.0, while the repo is at 2.0.1. The "Differences from sbx"
table does not mention gaps B (snapshots unwired), C (secret breadth), or D
(opencode-web).

**Disposition.** **Schedule** — refresh the version banner and the differences
table so the guide matches shipped behavior. Fold in the outcomes of A–C as they
land, and record the openchamber-supersedes-opencode-web relationship (gap D).

---

## Sequencing

```
ADR-0013 (gap A design, accepted)   ── design gate
        │
        └─> A impl (quickstart translator + msb consumer)  ── unblocks patterns #233 Increment B

        B (drop msb snapshot flag to 0 + follow-up wiring)  ── independent, low-risk
        C (msb generic secret binding)      ── independent (github still blocked by F)
        H (test-acq PATH robustness)        ── independent, low-risk (#217)
        J (BACKEND_GUIDE refresh)           ── trails A–C

patterns, in parallel:
        G (validate-kits.py mode/user)      ── shared security choke point (#225)
        #233 Increment A (adopt quickstart#221, drop manual publish workaround)
```

**Accepted / not scheduled** (documented above with triggers): **D**
(opencode-web — retire when #233 closes), **E** (heal), **F** (#203, upstream),
**I** (verify-backends CI).

---

## Tracking issues

**Quickstart repo (new):**

1. [#224](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/224) —
   implement ADR-0013 neutral port-publish + background vocab and the msb
   consumer (gap A).
2. [#225](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/225) —
   drop msb `ACQ_BACKEND_SUPPORTS_SNAPSHOTS` to 0; follow-up to wire a real
   `acq snapshot` + `acq_backend_snapshot` (gap B).
3. [#226](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/226) —
   broaden msb secret binding to generic custom-endpoint services (gap C).
4. [#227](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/227) —
   refresh BACKEND_GUIDE version banner + differences table (gap J).

**Quickstart repo (reuse):**

- [#217](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/217) —
  test-acq PATH robustness (gap H); commented to link this parity effort.

**Patterns repo:**

1. [#225](https://github.com/GSA-TTS/agentic-coding-patterns/issues/225) —
   harden `validate-kits.py` (reject malformed `mode`/`user`/`path` + fixtures)
   (gap G); commented to confirm scope + the ADR-0013 intersection.
2. [#233](https://github.com/GSA-TTS/agentic-coding-patterns/issues/233) —
   openchamber msb/ppp parity (gap A Increment B); commented that ADR-0013 +
   quickstart#224 unblock it, and Increment A is unblocked now.

**Accepted (no new issue; keep existing watches):**
[#203](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/203) (gap F);
the ADR-0011 record for gap E; gap D retires when patterns #233 closes; the
verify-backends cadence (gap I) is documented in the BACKEND_GUIDE refresh
(quickstart #227).
