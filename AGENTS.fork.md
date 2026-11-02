# Fork rules — mogul/agentic-coding-quickstart

These rules apply to this fork. They supplement `AGENTS.md` and override it
where the two conflict. The human is the sole merge approver and the sole
decider of exceptions, license acceptance, and dependency installation.

## AI attribution (overrides the AGENTS.md attribution examples)

Public artifacts attribute as "AI-assisted" only — never a tool, model, or
provider name. PR-level disclosure is required; the optional commit trailer is
`Co-authored-by: AI-assisted <responsible-human-email>`; resolution comments end
"AI-assisted planning session." The AGENTS.md attribution examples that name a
harness or a model do not apply here.

## Bounded standing authorization (home agents)

Home agents hold standing authorization for fork-only writes on
`mogul/agentic-coding-quickstart`: issue/comment writes, map Decisions-so-far
edits, branches, commits and pushes to non-protected branches, and opening pull
requests. Everything else stays gated. `main` is the only protected branch,
reached solely through a pull request with the human as sole merge approver.

The retained gates — required checks, adversarial review by a distinct
non-authoring agent, and human oversight — and the exception classes, generic
attribution, and cost/stop conditions are defined in ADR-0045.

## Permission deltas (override the AGENTS.md permission tables)

Additionally permitted, on this fork only: issue/comment writes, map
Decisions-so-far edits, branch creation, commits to and pushes of non-protected
branches, and opening pull requests from fork branches.

Additionally gated — explicit approval every time: force-push (history rewrite);
any write to `upstream` (`GSA-TTS/agentic-coding-quickstart`); dependency
installation or a new dependency; license/EULA acceptance; CI/CD configuration
changes; secrets/credential values (sandbox-backend injection only, never in
code, commits, or logs); merging one's own pull request; anything crossing the
fork boundary; privileged setup or elevation (never).

Additionally prohibited: writing to `upstream`; pushing directly to `main`
(reached only via pull request); escalating privileges or performing privileged
setup.

## ADR status lifecycle

ADRs may be recorded as `proposed` on any non-`main` branch, but a change may
not merge to `main` while its ADR is still `proposed`: promote it to `accepted`
before merge, or keep it out of the merged change.
