# Specification — Python `acq` v1 replacement

> Status: accepted (pending human review of the user stories below)
> AI-assisted; owner: Bret Mogilefsky.

This specification synthesizes the eight accepted wayfinding decisions
(ADR-0038m through ADR-0045m) into a single implementable contract. Where a
detail lives in an ADR, this document states the requirement and cites the ADR
for the rationale; it does not restate the ADR in full.

## Terminology

- **Home agent** — the on-host AI coding agent that performs the remaining
  planning and the implementation under the bounded standing authorization of
  ADR-0045m. A role, not a product.
- **Managed runtime** — the app-private CPython that executes `acq`'s source; the
  user never manages Python (ADR-0042m).
- **Backend** — a sandboxing backend (SBX or MSB) reached through an adapter that
  satisfies the capability contract (ADR-0040m).
- **Contract oracle** — an observable behaviour the compatibility contract
  requires, proven only through the CLI subprocess boundary (ADR-0039m).

## Problem Statement

The current `acq` is an ~88 KB Bash wrapper that composes sandbox backends (SBX,
MSB) and community kits into a working USAi agent environment. It carries
deliberate user-facing and security contracts alongside accumulated quirks:
inconsistent exit codes, no machine-readable output, version-less on-disk state,
and a Bash test suite that cannot serve as a language-neutral oracle. We are
replacing it with a Python program that preserves the deliberate contracts,
drops the accidental ones, and is verifiable across three platforms.

## Solution

A Python `acq` v1: the same documented command surface and security guarantees,
normalized exits, versioned structured output, orchestrator-owned state with
forward-only migration, a transport-neutral backend seam (implemented as
subprocess adapters for SBX and MSB), an app-private managed runtime, and a
language-neutral test-vector corpus with live cross-platform qualification. The
compatibility contract is the source of truth; legacy Bash code and tests are
evidence, not specification.

## Architecture and seams

These boundaries are settled; implementation must respect them.

| Seam | What crosses it | Source |
|---|---|---|
| CLI surface | argv, exit codes (0 success / 2 usage / 1 operational), stdout/stderr | ADR-0038m |
| Structured output | versioned JSON on stdout; diagnostics on stderr | ADR-0038m |
| Backend adapter | capability contract, error vocabulary, host/guest path types | ADR-0040m |
| State | orchestrator-owned records, per-record `schema=N`, tree generation marker | ADR-0041m |
| Test oracle | subprocess-only vectors; Bash and pytest runners | ADR-0043m |

The highest seam is the CLI subprocess boundary: every contract oracle is proven
there, and no test reaches into implementation internals for contract evidence.

## User Stories

### Ordinary user

1. As an existing acq user, I want my documented commands to keep working, so that my workflow does not break on upgrade (ADR-0038m).
2. As a scripter, I want a `--json` flag with a stable, versioned envelope, so that I can parse results rather than scrape tables (ADR-0038m).
3. As a scripter, I want a meaningful exit code for every outcome, so that my scripts can branch reliably (ADR-0038m).
4. As an existing user, I want my configuration, credentials, and sandboxes to survive the upgrade — host records and secrets carry forward, and only the security-exception recreation discards the guest filesystem — so that I do not recreate state (ADR-0041m).
5. As a user on Windows, macOS, or Linux, I want `acq` to run without me managing Python, so that installation stays a single step (ADR-0042m).
6. As a user on a restricted or air-gapped host, I want ordinary operation never to touch the network for acq's own assets, so that it keeps working offline (ADR-0042m).
7. As a user, I want no secret value ever to appear in argv, logs, fixtures, or output, so that credentials cannot leak (ADR-0038m).
8. As a user, I want host-authoritative configuration and trusted startup code never to be writable by the guest, so that the sandbox cannot escalate (ADR-0038m, ADR-0041m).
9. As a user, I want an announced, verbatim backend passthrough for backend-only commands, so that backend-specific features stay reachable without becoming portable contracts (ADR-0038m).
10. As a user, I want non-interactive runs never to block waiting for input or invent consent, so that automation is safe (ADR-0038m).

### Enterprise

1. As IT, I want a managed runtime with clear provenance and a named patch owner, so that patch cadence is auditable (ADR-0042m).
2. As IT, I want installation to be user-scoped and non-elevating, so that it fits a locked-down fleet (ADR-0038m).
3. As IT, I want a complete, enumerated offline asset set whose completeness is proven by a live blocked-network install, so that air-gapped hosts are supported (ADR-0042m).
4. As IT, I want the qualification matrix to state exactly which platform/backend cells are claimed and which are unqualified, so that deployment claims are honest (ADR-0044m).

### Home agent (implementer)

1. As a home agent, I want each command's contract expressed as a language-neutral vector, so that I can implement against an oracle rather than the Bash source (ADR-0043m).
2. As a home agent, I want fork-only write authorization with retained gates, so that I can work without per-action approval but never cross the fork boundary (ADR-0045m).
3. As a home agent, I want this specification decomposed into vertical slices I can land and verify independently, so that I do not block on one enormous change (this document and its tickets).

## Implementation Decisions

1. **Command and exit contract** — preserve documented commands; `0` success, `2` usage, `1` operational; child/backend status preserved on exec, attach, shell, copy, ports, and passthrough (ADR-0038m).
2. **Structured output** — common envelope (`schema_version`, `command`, `data` or `error{code,message,remediation?}`); a required-field table per command; unknown fields additive, required-field changes bump the schema version (ADR-0038m).
3. **Behaviour triage** — the preserve / drop / preserve-with-warning classification, each entry carrying its named test, is binding (ADR-0038m).
4. **Backend seam** — transport-neutral capability contract; 27 adapter obligations (23 common + 4 backend-specific) declared with support levels and proven by conformance vectors; a ~14-code error vocabulary with backend-native text never a portable field; host-authoritative trust (ADR-0040m). `active_backend` resolves `--backend` flag → `ACQ_BACKEND` env → config (`backend set`) → auto-detect: exactly one installed → that one; sbx and msb both installed → msb; none → null; two or more and none is msb → prompt the user and persist the answer.
   - **Default base image is agent-dependent (ADR-0030):** `opencode` resolves to the pinned generic devenv base (`ghcr.io/gsa-tts/agentic-coding-patterns/devenv-shell@<digest>`); `shell` and the other known agents keep the sandbox-templates derivation (`<stem>-docker`, with `claude`→`claude-code` and `cursor`→`cursor-agent`). Override precedence is `--image` → `ACQ_IMAGE` → `ACQ_MSB_IMAGE` → the agent-dependent default (ADR-0022). Full kit-driven agent install (devenv base + pinned agent kit) is deferred to the kits slice.
5. **State migration** — orchestrator-owned; per-record `schema=N` plus a tree generation marker under an auto-releasing OS advisory lock; forward-only and fail-closed; the security-exception recreation flow for a sandbox missing the verified read-only mount (ADR-0041m).
6. **Runtime and install** — app-private CPython on all five platform cells; update by re-running the installer; no `acq update` command; OS signing deferred with the fleet application-control risk recorded as a tracked task (ADR-0042m).
7. **Verification** — subprocess-only oracles, three evidence tiers, sentinel conformance covering every assertion mode and normalisation transform, and a CI-validated coverage manifest (ADR-0039m, ADR-0043m).
8. **Qualification** — six Tier-3 oracles, the qualified/unqualified/blocked matrix states, the verbatim `RESULT` transcript signature, and the 3-attempt reproduction rule (ADR-0044m).
9. **Autonomy** — the bounded standing authorization of ADR-0045m governs who builds this and how it is reviewed and merged.

## Testing Decisions

- Contract evidence comes only from the CLI subprocess boundary; Tier-2 implementation tests may exist but never count as contract evidence.
- Fast coverage is Tier-1 vectors (offline, CI); unit and integration are Tier-2 (non-contract); live qualification is Tier-3 with recorded transcripts, gating releases and security-touching PRs.
- Backend-specific behaviour is proven only through the CLI (Tier-1 conformance with stubbed backends, Tier-3 live with real backends); adapter-level unit tests in isolation are permitted as Tier-2 implementation detail and never count as contract evidence.
- Coverage percentages and mock/stub counts are never evidence of done; a command is done when its contract vectors pass and its Tier-3 oracles hold a green transcript where required.
- Tests encoding a DROP-classified behaviour retire on touch, citing the contract row.

## Out of Scope

- New backends, direct MSB Python bindings, and OpenShell (map Out of scope).
- OS-level code signing for v1 (deferred and tracked; ADR-0042m).
- Windows ARM64 and musl (explicitly unqualified; ADR-0044m).
- Upstream rollout or any write to the upstream repository (map Out of scope).
- Implementing anything beyond the first slice's boundary in a single ticket.

## Further Notes

- The implementation tickets this specification decomposes into are authored and
  published separately; each is a vertical slice with native blocking edges.
- NIST control mappings on the ADRs are best-effort and subject to human review.
