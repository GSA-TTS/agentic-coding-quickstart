---
title: "Home-agent handoff and bounded autonomy contract"
status: accepted
date: 2026-11-02
decision_makers: ["Bret Mogilefsky"]
category: governance
nist_controls: ["AC-2", "AC-3", "AC-6", "AC-17", "AU-2", "AU-3", "AU-6", "CM-5", "IA-2", "PL-4", "SI-7"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0045m: Home-agent handoff and bounded autonomy contract

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
until the final specification is approved and ADR-0038m through ADR-0045m are
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

## Enforcement status (2026-11-09)

The retained gates above are a policy. Most of them are **not enforced by
repository settings** on `mogul/agentic-coding-quickstart`; they hold by
convention. This note records what is enforced and what is not, so that nobody
reads the gates as technical controls. The decision above is unchanged.

**Enforced by the `main` ruleset:**

- changes reach `main` only through a pull request;
- commits must be signed;
- no force-push, and `main` cannot be deleted.

**Not enforced by the ruleset:**

- **Required checks.** The ruleset's required-status-check list is empty. The
  checks below run in CI on every pull request to `main`, but a red or missing
  check does not block the merge.
- **Reviews.** The ruleset requires zero approving reviews and no code-owner
  review.
- **CODEOWNERS.** `.github/CODEOWNERS` names `GSA-TTS` teams, and GitHub cannot
  resolve an organisation team as an owner of a personal repository. So the
  admin review that ADR-0044m and `docs/howto/qualification.md` describe for the
  qualification ledger, `qualification/` and the committed oracles applies
  upstream only. On this fork it is not enforced.
- **Distinct-agent adversarial review and the human as sole merge approver.**
  Home agents and the human push and merge as the same GitHub account. So
  repository records cannot show that a merge was the human's decision and not an
  agent's, and nothing technical stops an agent with push rights from merging its
  own pull request. AGENTS.fork.md gates that action, and only the agent's own
  compliance enforces it. An adversarial review is visible only if the PR body or
  a comment records it.
- **The fresh live transcript for a Tier-3 surface change.** The
  `Tier-3 release gate` workflow reports a stale cell on the pull request, but it
  is advisory. Its workflow header and `docs/howto/release-gate-setup.md` say not
  to require it until release PRs reliably report checks. Pull requests that
  changed `py-acq/src/acq_py/` have merged while that gate was red, and their
  cells were re-recorded only afterwards or are still pending re-qualification.

**CI checks that run on every pull request to `main`** (job names as they
appear on a PR):

| Retained gate | Check that implements it |
|---|---|
| pre-commit hook (gitleaks, shellcheck, markdownlint and the other hooks) | `pre-commit` |
| `scripts/run-shellcheck` at `--severity=warning` | inside `pre-commit` |
| markdownlint | `Markdown Lint` (Markdown changes only), and inside `pre-commit` |
| Tier-1 vectors | `vectors` |
| (related) Python quality | `ruff, mypy, bandit and coverage` |
| (related) bash 3.2 and Windows suites | `acq offline suite under bash 3.2`, `Windows` (aggregate jobs that always report) |
| (related) PR title | `Conventional Commit Title` |
| fresh Tier-3 transcript | `Tier-3 release gate` (advisory) |

Making these gates technical controls takes repository settings: required status
checks, and a review rule that works on a personal fork. Only the maintainer can
change those settings. Until then, a merge under a red required check or without
the adversarial review is a convention breach, not something the repository
blocks.
