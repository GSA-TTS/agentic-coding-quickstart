---
title: "Home-agent handoff and bounded autonomy contract"
status: proposed
date: 2026-11-02
decision_makers: ["Bret Mogilefsky"]
category: governance
nist_controls: []
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0045: Home-agent handoff and bounded autonomy contract

## Context and Problem Statement

The wayfinding map resolved seven decisions (compatibility contract, verification
strategy, backend boundary, configuration and state migration, installation and
update channels, test-vector format, and qualification matrix) as resolution
comments on the fork. Remaining planning, specification, decomposition, and
implementation orchestration is to transfer to host-capable home agents. That
transfer requires a durable statement of what those agents may do without
per-action approval, what stays gated, and how the work is held accountable,
while omitting model and provider names from public artifacts.

## Decision

**Standing authorization scope (fork-only).** Pre-approved on
`mogul/agentic-coding-quickstart` without per-action approval: issue/comment
writes; opening/closing wayfinder tickets (sub-issues and dependency edges); map
"Decisions so far" edits; branch creation; commits to non-protected branches;
pushes of non-protected branches; opening PRs from fork branches.

Gated — explicit human approval every time: force-push (history rewrite); any
upstream write (never); dependency installation or a new dependency;
license/EULA acceptance on the organisation's behalf; CI/CD pipeline
configuration changes; secrets/credential values (sandbox-backend injection
only, never in code, commits, or logs); merging one's own PR; anything crossing
the fork boundary; privileged setup or elevation (never).

`main` is the only protected branch, reached solely through pull requests with
the human as sole merge approver.

**Retained gates.** Required checks: the repository's pre-commit hook,
`scripts/run-shellcheck` at `--severity=warning`, markdownlint, and all Tier-1
vectors green in CI; a PR touching a Tier-3 security/host-enforcement oracle
additionally attaches a fresh green live transcript. Adversarial review: a
distinct home-agent session (not the author) checks the change against the seven
resolutions and the compatibility contract's non-negotiable security guarantees,
reporting divergences; it holds no approval authority. Human oversight: the
developer is the sole merge approver and the sole decider on every exception,
license acceptance, and dependency installation.

**Exception classes.** Security finding — stop immediately, report privately,
never file a public issue; the human decides remediation. Privilege escalation
or privileged setup — never performed by a home agent; escalated. Fork-boundary
crossing — never performed under standing authorization; escalated. Each is
recorded as a fully-qualified issue or a `docs/KNOWN_FAILURE_MODES.md` entry
naming the trigger; the human always decides.

**Attribution.** Public artifacts attribute as "AI-assisted" only — never a
model, provider, or harness name. The PR body carries an "AI-assisted; owner:
<responsible human>" line; the optional commit trailer is `Co-authored-by:
AI-assisted <responsible-human-email>`; resolution comments end "AI-assisted
planning session."

**Cost and stop conditions.** A home-agent session halts and returns to the
human on any of: a ~30-minute wall-clock cap; three consecutive failures on the
same pre-approved write (each reported and reasoned, never silent); any red
required check or adversarial-review divergence; any exception class. No silent
retry, no unbounded loop.

**Planning transfer vs implementation readiness.** Transfers now: spec
authoring, decomposition into implementation tickets, and orchestration of the
open decision tickets, because the compatibility, security, feasibility, and
verification constraints are now coherent. Waits: writing the replacement,
until the final specification is approved and ADR-0038 through ADR-0045 are
recorded.

**MicroVM validation.** Home agents may run on the host and create microVMs to
validate host/guest developer experience. This authorises neither privileged
setup nor any override of existing permission rules; it is a test-vehicle
allowance, not a privilege grant.

## Consequences

Recorded as two artifacts, both landing as fork-only writes the contract itself
authorises (branch → commit → push → PR, human as merge approver): an AGENTS.md
amendment (the operational instructions) and this ADR (the rationale). The
amendment rewrites the AI-attribution section to the generic form, edits the
permission tables, and adds a "Bounded standing authorization (home agents)"
section.

## Verification

The AGENTS.md amendment is reviewed adversarially by a distinct agent against
the seven settled resolutions before merge, and the human merges. No model or
provider name appears in any public artifact.
