---
title: "Home-agent handoff and bounded autonomy contract"
status: proposed
date: 2026-11-02
decision_makers: ["Bret Mogilefsky"]
category: governance
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

Home agents hold standing authorization, on the fork
`mogul/agentic-coding-quickstart` only, to: write issue and comment content
(open, update and close wayfinder tickets and their dependency edges), edit the
wayfinder map issue's Decisions-so-far index, create branches, commit to and
push non-protected branches, and open pull requests from fork branches. `main`
is the only protected branch, reached solely through pull requests with the
human as sole merge approver.

Everything else stays gated: force-push or history rewrite, any write to
upstream `GSA-TTS/agentic-coding-quickstart`, dependency installation or a new
dependency, license/EULA acceptance, CI/CD configuration changes, merging one's
own pull request, anything crossing the fork boundary, and privileged setup or
elevation (never).

Retained gates: required checks (the repository's pre-commit hook,
`scripts/run-shellcheck` at `--severity=warning`, markdownlint, all Tier-1
vectors green; a fresh green live transcript on changes touching a
security/host-enforcement oracle); adversarial review by a distinct
non-authoring home-agent session that reports divergences and holds no approval
authority; and human oversight, in which the human is the sole merge approver
and the sole decider of every exception, license acceptance, and dependency
installation.

Three exception classes, each recorded as a fully-qualified issue or a
`docs/KNOWN_FAILURE_MODES.md` entry naming the trigger, with the human always
deciding: security finding (stop, report privately, never file a public issue);
privilege escalation or privileged setup (never performed); fork-boundary
crossing (never performed under standing authorization).

Attribution: public artifacts attribute as "AI-assisted" only, never naming a
tool, model, or provider.

Cost and stop conditions: a home-agent session halts and returns to the human on
a ~30-minute wall-clock cap, three consecutive failures on the same pre-approved
write (each reported and reasoned, never silent), any red required check or
adversarial-review divergence, or any exception class.

Planning transfer (wayfinding, specification, decomposition, and orchestration
of the open decision tickets) is authorized now; implementation readiness of the
replacement waits until the final specification is approved and ADR-0038 through
ADR-0045 are recorded.

MicroVM validation: home agents may run on the host and create microVMs to
validate host/guest developer experience; this authorizes neither privileged
setup nor any override of existing permission rules.

## Consequences

The policy is recorded as an amendment to AGENTS.md (the operational
instructions) plus this ADR (the rationale). The amendment rewrites the
attribution section to the generic AI-assisted form, edits the three permission
tables, and adds a "Bounded standing authorization (home agents)" section. Peer
PR approval is not required; adversarial review plus human merge approval
replace it for this experiment.

## Verification

The AGENTS.md amendment is reviewed adversarially by a distinct agent against
the seven settled resolutions before merge, and the human merges. No model or
provider name appears in any public artifact.
