---
title: "Agentic Coding Quickstart - Agent Rules"
description: "Behavioral rules for AI coding agents operating with SBX + USAi"
status: canonical
tier: 1
last_updated: "2026-08-01"
audience: "developers"
keywords: ["AGENTS.md", "sbx", "usai", "sandbox", "agent-rules", "workspace"]
related_files: ["docs/KNOWN_FAILURE_MODES.md", "docs/adr/0001-sbx-usai-agent-execution-architecture.md"]
load_priority: "always"
review_cycle: "quarterly"
---

# AGENTS.md — Agentic Coding Quickstart

> **System:** Agentic Coding Quickstart | **Impact Level:** FIPS Low | **Agency:** GSA
>
> **Last Updated:** 2026-06-26 | **Reviewed By:** William Zujkowski
>
> This document defines the behavioral rules for AI coding agents operating within this project. The AI agent MUST follow these rules without exception.

---

## Workspace Structure

This repository is a thin **wrapper** (`acq`) that stands up a working,
federally-configured agent sandbox by composing existing tools: the `sbx` CLI
plus four sbx **mixin kits** hosted in the community
[agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo (`integrations/isolation/sbx-kits/`). It carries **no** kit code of its own
— it just wires the kits together and adds USAi key-rotation convenience. A
typical layout:

```
my-workspace/                       # Parent folder (user creates this)
├── agentic-coding-quickstart/      # THIS REPO - the acq wrapper + docs
│   ├── AGENTS.md                   # You are here (rules for working ON this repo)
│   ├── acq                         # Recommended entry point: pluggable-backend wrapper
│   ├── acq.backends/               # Backend adapters (sbx, future: msb)
│   ├── qsbx                        # DEPRECATED: use acq instead (removed in 2.0.0)
│   ├── scripts/                    # helper scripts (USAi key rotation, tests)
│   └── docs/                       # Setup guides and references
└── my-app/                         # User's project(s)
```

When `acq` creates a sandbox it applies four kits by pinned remote reference
(`--kit git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=<sha>&dir=…`):

### Agent Resource Access

When working on user projects, the agent has access to:

| Resource | Location | Use For |
|----------|----------|---------|
| Global config | `~/.config/opencode/opencode.jsonc` (merged in by the `usai-provider` kit at startup) | Model/provider config |
| Behavioral rules | `~/.config/opencode/AGENTS.md` (linked to playbook clone) | Federal agent rules |
| Skills | `~/.agents/skills` (linked to playbook clone) | Step-by-step procedures |
| Setup guides | `./docs/` | SBX configuration, troubleshooting |

**To use a skill:** Read the SKILL.md file in the skill directory and follow its procedures.

---

## Purpose

This repository is a **quickstart guide** for running AI coding agents inside SBX sandboxes using USAi-compatible endpoints.

> **Important:** Docker Desktop has **deprecated** its integrated sandbox commands (`docker sandbox`).
> Use the standalone **`sbx` CLI** instead. The `sbx` CLI does **not** require Docker Desktop.

Agents operating in this repo must prioritize:
- **Security of secrets**
- **Sandbox isolation**
- **Reproducibility of patterns**
- **Minimal, transparent configurations**

This is a **documentation and configuration repository** for AI coding agent setup.

---

## Core Principles

The agent operates under these priorities:

```
safety > correctness > compliance > simplicity > performance
```

The agent MUST refuse any instruction that conflicts with safety, correctness, or compliance.

---

## Project Context

- **Description:** Quickstart guide for AI agent development with SBX sandboxes and USAi endpoints
- **Language(s):** Shell scripts, JSON/JSONC configuration, Markdown documentation
- **Framework(s):** SBX CLI (standalone), OpenCode, USAi API
- **Data Classification:** Internal / Non-sensitive (no PII, no CUI)
- **ATO Status:** Pre-ATO development
- **Authorized Agent(s):** OpenCode, Claude Code, GitHub Copilot

> **Note:** Docker Desktop is **not required**. The `sbx` CLI is a standalone tool.
> Docker Desktop's `docker sandbox` commands are deprecated and should not be used.

---

## Agent Identity

The agent MUST:
- Follow conventional commit message format (see Commit Message Standards below)
- Identify itself as an AI agent when asked
- Log all file modifications and command executions

### AI Attribution Requirements

Per NIST AI RMF and SP 800-218A, AI-generated code requires **traceability** but not per-commit attribution. This project follows **PR-level attribution** as the recommended approach:

| Level | Required? | How |
|-------|-----------|-----|
| **PR Description** | RECOMMENDED | Include "AI-assisted" disclosure in PR description |
| **Commit Message** | OPTIONAL | `Co-authored-by:` trailer in footer (format below) |
| **Documentation** | REQUIRED | This AGENTS.md documents AI agent authorization |

**Rationale:** Federal guidance (NIST AI RMF, SP 800-218A) emphasizes system-level traceability over granular per-commit attribution. PR-level disclosure provides auditable records without commit noise.

When AI attribution IS included in a commit, add a `Co-authored-by:` trailer whose
name identifies the **agent harness**, optionally the **model**, and whose email
is the **responsible human's** GSA address. The trailer has the shape:

- `Co-authored-by: NAME <EMAIL>`

where:

- **NAME** = the agent harness, optionally followed by the model in square
  brackets — `HARNESS` or `HARNESS [MODEL]`
- **EMAIL** = the responsible human's GSA email (`first.last@gsa.gov`), NOT a
  generic agent address — this keeps every AI-assisted commit tied to an
  accountable person.

The name-and-email together sit between a literal space, a `<`, and a `>`, exactly
as Git requires for a co-author trailer. Concretely:

```text
Co-authored-by: OpenCode [claude-opus-4] <first.last@gsa.gov>
```

More examples (all valid):

```text
Co-authored-by: OpenCode <jane.doe@gsa.gov>
Co-authored-by: Claude Code [claude-sonnet-4.5] <john.smith@gsa.gov>
Co-authored-by: GitHub Copilot [gpt-5] <first.last@gsa.gov>
```

Notes for getting the punctuation right:

- The email MUST be wrapped in angle brackets `<…>`; the model (when present) MUST
  be wrapped in square brackets `[…]` and placed BEFORE the angle-bracketed email.
- Do not put the model inside the angle brackets — only the email goes there.
- Omit the `[MODEL]` segment if the model is unknown; never invent one.

---

## Commit Message Standards

This project follows **Conventional Commits 1.0.0** and **Semantic Versioning 2.0.0**.

### Commit Message Format

```
<type>(<optional-scope>): <subject>

<optional-body>

<optional-footer>
```

### Commit Types

| Type | Version Bump | Description |
|------|--------------|-------------|
| `feat` | Minor | New feature (backward-compatible) |
| `fix` | Patch | Bug fix (backward-compatible) |
| `docs` | None | Documentation only changes |
| `style` | None | Code style/formatting (no logic change) |
| `refactor` | None | Code refactoring (no feature/bug change) |
| `perf` | Patch | Performance improvement |
| `test` | None | Test changes |
| `chore` | None | Maintenance tasks (no production code change) |
| `ci` | None | CI/CD pipeline changes |
| `build` | None | Build system changes |
| `revert` | Depends | Revert previous commit |
| `security` | Patch | Security fixes |

### Breaking Changes

- Include `BREAKING CHANGE:` in commit footer → Major version bump
- Alternative: Use `!` after type (e.g., `feat!: new API`)

### Examples

```
feat(agents): add continuous monitoring requirements

Adds section 17 to CODING_PRACTICES.md covering post-deployment
monitoring requirements per M-25-21.

Refs: NIST SP 800-218A, M-25-21
```

```
fix(sbx): correct secret injection path

The previous configuration used an incorrect path that caused
secrets to fail injection on container startup.

Fixes: #42
```

```
feat(api)!: migrate authentication to OAuth 2.0

BREAKING CHANGE: API authentication now requires OAuth 2.0 tokens
instead of API keys. Clients must update authentication flow.
```

### Commit Message Rules

The agent MUST:
- Use lowercase for type, scope, and subject
- Keep subject line ≤72 characters
- Not end subject with period
- Use imperative mood ("add" not "added" or "adds")
- Include ticket/issue reference when applicable
- Wrap body at 100 characters
- Separate subject from body with blank line

The agent MUST NOT:
- Create commits with vague messages ("fix bug", "update code")
- Skip the commit type prefix
- Use past tense in subject line
- Exceed 100 character header length

---

## SBX-Specific Rules (Non-Negotiable)

> **Tooling Note:** Use the standalone `sbx` CLI for all sandbox operations.
> Docker Desktop's integrated `docker sandbox` commands are **deprecated** and will be removed.
> The `sbx` CLI does not require Docker Desktop — it is a standalone tool.

### 1. No Secrets Exposure

The agent MUST NEVER:
- Print, log, or persist API keys, tokens, or credentials
- Hardcode secrets in source files, config files, or scripts
- Deliberately expose real secret *values* (e.g., `echo $SECRET`, or piping `printenv`/`env` output somewhere it is logged, committed, or shown)
- Include secrets in commit messages, comments, or documentation

> **Note on `env` / `printenv` in the sandbox:** Inside an SBX sandbox, secrets
> are **injected placeholders or proxied** (the agent never holds the real USAi
> key material), so inspecting the environment is not automatically a leak. The
> `usai-provider` kit's OpenCode policy is **default-allow** (the sandbox is the
> security boundary), so these commands are **allowed** rather than gated — the
> agent should still avoid deliberately dumping secret values. The prohibition
> above is about *exposing real secret values*, not about routine environment
> inspection in the sandbox. The gated (`ask`) class is instead commands that
> open a **new outbound destination** (e.g. `git push`, new git remotes,
> `scp`/`sftp`/`rsync`/`nc`); see ADR-0005 and the kit's decision record.

All secrets MUST be accessed via:
- SBX secret management
- Environment variables injected at runtime (not persisted)

### 2. Assume You Are Untrusted

Agents must behave as if:
- The runtime environment is monitored
- Outputs may be logged and reviewed
- Any exposed secret is considered compromised

### 3. SBX Is the Security Boundary

All agent execution MUST:
- Occur inside SBX sandboxes when working with USAi endpoints
- Use the `sbx` CLI (not deprecated `docker sandbox` commands)
- Avoid direct host interaction unless explicitly required
- Avoid writing outside the working directory
- Respect container filesystem boundaries

### 4. Config-First Approach

Agents should:
- Prefer modifying configuration files over writing custom scripts
- Use `opencode.jsonc` (or equivalent) for model/provider setup
- Avoid introducing unnecessary abstraction layers
- Document configuration changes clearly

### 5. Keep It Minimal

The agent MUST NOT:
- Add frameworks without justification
- Add dependencies without explicit approval
- Introduce persistence layers
- Over-engineer solutions

This repo is for:
- Testing patterns
- Documenting outcomes
- Producing reproducible examples

---

## Permitted Actions

The agent MAY perform these actions without additional approval:
- [x] Read files within the project directory
- [x] Generate and modify source code and configuration
- [x] Run linters and formatters
- [x] Read documentation and public API references
- [x] Create and update documentation
- [x] Execute commands inside SBX sandboxes

---

## Actions Requiring Approval

The agent MUST ask the user before:
- [ ] Installing or upgrading dependencies
- [ ] Making network requests to external services (except USAi endpoints)
- [ ] Modifying CI/CD pipeline configurations
- [ ] Deleting files or directories
- [ ] Committing or pushing code
- [ ] Modifying SBX configuration, or creating sandboxes outside the sanctioned bootstrap (`acq run` / `qsbx run` / `sbx run`, which auto-create a sandbox as part of normal execution and are pre-approved)
- [ ] Accessing endpoints outside the approved list

---

## Prohibited Actions

The agent MUST NEVER:
- [ ] Access files outside the project directory
- [ ] Access or modify production systems or data
- [ ] Hardcode secrets, API keys, tokens, or passwords
- [ ] Disable security controls, pre-commit hooks, or CI checks
- [ ] Bypass code review or change management processes
- [ ] Execute code downloaded from external sources without review
- [ ] Print environment variables containing secrets
- [ ] Store secrets in `.env` files committed to the repo
- [ ] Bypass SBX for convenience
- [ ] Create network listeners or reverse connections

---

## Data Handling

- **Sensitive data types in this project:** API keys, tokens, credentials (never stored)
- **Approved data storage:** Local filesystem within project directory only
- **PII handling:** No PII should exist in this repository
- **Data residency:** Local development only

The agent MUST:
- Never include API keys or tokens in logs, comments, or test fixtures
- Use environment variables injected via SBX for all credentials
- Mask any sensitive values if debugging output is required

---

## Network Access

- **Authorized external endpoints:**
  - `https://api.gsa.usai.gov/api/v1` (USAi API)
  - `https://api.github.com` (GitHub API - via SBX proxy)
  - `https://workshop.cloud.gov` (GitLab API - GSA workshop instance)
- **Authorized internal endpoints:** None
- **TLS requirement:** TLS 1.2+ for all connections
- **Proxy configuration:** Use system proxy if configured

### Credential Injection Methods

| Service | Method | Notes |
|---------|--------|-------|
| USAi | Custom secret (`sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY`) | Custom endpoint not supported by SBX proxy |
| GitHub | SBX proxy, **per-sandbox scoped** (`acq` fine-grained flow, or `sbx secret set <sandbox> github`) | Recommended default: least-privilege, per-sandbox. Global `sbx secret set -g github` kept for back-compat. Agent never sees the token. See [ADR-0013](docs/adr/0013-per-sandbox-github-token-downscoping.md) |
| GitLab | Custom secret (`sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN`) | Not a built-in SBX service |

See `docs/QUICKSTART_SBX.md` for detailed credential injection patterns.

---

## Coding Standards

- Follow [`CODING_PRACTICES.md`](https://github.com/GSA-TTS/agentic-coding-playbook/blob/main/docs/CODING_PRACTICES.md) in the GSA agentic-coding-playbook for secure coding guidelines
- Prefer explicit configuration over implicit behavior
- Maximum function length: 50 lines
- All external input MUST be validated before use
- Use parameterized queries for any database operations

### Durable References: Cross-Link Code, Docs, and ADRs — Not Trackers

This repository must remain **self-contained and outlive the issue tracker.**
GitHub issue/PR numbers, and internal epic labels ("gap A", "gap K", etc.), are
ephemeral SaaS-dependent tracking artifacts — useful during development, but an
obstacle to review and long-term maintenance once merged. The durable homes for
rationale are **ADRs and docs**; the durable homes for behavior are the **code
and its tests**.

The agent MUST:

- Keep **code comments self-contained.** Explain *why* in prose. A comment MAY
  point to an **ADR** (e.g. "see ADR-0015") — that is the correct durable anchor
  for a design decision. A comment MUST NOT rely on a bare `#NNN` /
  `quickstart#NNN` / `patterns#NNN` issue-or-PR reference, or an epic "gap X"
  label, to carry meaning: rewrite it as prose (and cite an ADR if one applies).
- Point **docs → code and ADRs** (what/where it is, why it was decided), and
  point **code → docs and ADRs** (the durable rationale). Prefer docs pointing at
  code over the reverse, except to cite an ADR.
- Before opening a PR, **strip ephemeral tracker references from any code comment
  or doc it added or touched.** Durable, cross-repo-relevant facts (a pinned
  release SHA, an upstream bug's observable behavior) belong in prose/ADRs, not as
  a bare tracker number.

The agent MAY leave issue/PR references in **ephemeral, non-durable contexts**:
commit messages, PR descriptions, `CHANGELOG.md` (release automation), and an
ADR's own *Links / tracking* section (where issue references are acceptable,
though prose or ADR cross-links are preferred). Test **names** that already encode
a regression's id MAY keep it as a stable identifier.

### Fully Qualify Issue/PR References in Anything Durable

Shorthand like `#233` is **fine when talking to a human in this session** — but
it MUST NOT land, unqualified, in anything durable or auto-linked (commit
messages, PR titles/descriptions, review comments, tracking issues, ADRs). Once
auto-linked, a bare `#233` resolves **relative to whatever repository renders
it** — so a `#233` written for `GSA-TTS/agentic-coding-quickstart` can silently
point at `GSA-TTS/agentic-coding-patterns#233` (a different thing) when quoted or
cross-posted.

Therefore, in any durable or cross-posted artifact, the agent MUST write
issue/PR references **fully qualified**:

- Cross-repo, always safe: `GSA-TTS/agentic-coding-quickstart#233` (or a full
  URL). Use this form in every commit message, PR body, review comment, and
  tracking issue — including when referring to the current repo — because these
  are read and auto-linked outside their origin.
- A bare `#233` is acceptable **only** within the same repository's PR/issue
  body where the target is unambiguous by construction, and even then the
  qualified form is preferred. When in doubt, fully qualify.

This does not change the durable-reference rule above (code comments and docs
prose still avoid tracker numbers entirely, qualified or not); it governs the
*ephemeral* contexts where a reference is allowed at all.

> Rationale: this is enforcement of the existing "docs-as-code" / self-contained
> repository discipline. Doing this continuously means no later "de-reference" or
> "re-qualify" cleanup pass is ever needed.

---

## Dependencies

- **Approved registries:** npmjs.com, pypi.org (for tooling only)
- **License restrictions:** No AGPL; GPL requires justification
- **Version pinning:** Exact versions only, no floating ranges
- **Vulnerability policy:** No critical/high CVEs

Before adding any dependency, the agent MUST:
1. Verify the package name is correct (check for typosquatting)
2. Check for known vulnerabilities
3. Verify the license is compatible
4. Get user approval

---

## Testing Requirements

- [ ] All patterns must be reproducible from scratch
- [ ] Document what worked, what failed, and why
- [ ] Verification must not expose secrets
- [ ] Test inside SBX containers, not directly on host

### Periodic Re-Verification

Documented SBX patterns silently rot as `sbx`, USAi, or OpenCode versions move. A pattern marked "works" is only trustworthy if it still runs.

The agent SHOULD:
- Re-verify documented SBX patterns by **running the real flow (live, not mocked)** on the quarterly review cadence (or on demand when a pattern is in doubt)
- Capture the actual output and compare it against the documented claim
- When a pattern marked "works" no longer reproduces, record it in `docs/KNOWN_FAILURE_MODES.md` **and** open a tracking issue (per Failure Handling below)

---

## Incident Response

If the agent discovers a potential security vulnerability:
1. Stop the current task immediately
2. Report the finding to the user
3. Do NOT create a public issue for security vulnerabilities
4. Document the finding in `docs/KNOWN_FAILURE_MODES.md` if appropriate

---

## Agent Meta-Constraints

The agent MUST:
- [x] Output an execution plan and wait for approval before modifying artifacts
- [x] Fail closed on ambiguity — halt and escalate, never guess
- [x] Not retry failed operations silently — report, diagnose, propose
- [x] Capture errors and document failures clearly
- [x] Propose minimal fixes for failures

**Risk modes for this project:**

| Mode | Scope | Requires Approval |
|------|-------|-------------------|
| Read-only | Analyze, review, answer questions | No |
| Scoped edit | Modify files identified in plan | Plan approval |
| Broad refactor | Cross-module changes | Plan + per-module approval |
| Infrastructure | SBX config, deployment, access control | Explicit per-change approval |

---

## Engineering Discipline

The agent MUST:
- [x] Create an ADR before: adding dependencies, changing architecture, introducing new patterns
- [x] Not implement speculative features (YAGNI)
- [x] Prefer 1 config file + 1 command over complex setups
- [x] Document outcomes clearly enough for another engineer to follow

**One-command bootstrap:** `./acq run opencode .` (creates sandbox with config mounted, then attaches)
**One-command verify:** `sbx exec <sandbox-name> <verify-command>`

> **Note:** `acq run` is the preferred method — it creates the sandbox if needed
> (mounting this clone as global config), then attaches. acq uses the clone it
> lives in; export `QUICKSTART_CLONE` only to override that.
>
> **Migrating from qsbx?** `qsbx` is deprecated; replace `./qsbx` with `./acq`
> — commands are identical on the sbx backend. Set `QSBX_SILENCE_DEPRECATION=1`
> to suppress the deprecation notice in scripts/CI.

**ADR location:** `docs/adr/`

---

## Approved Patterns

### Model Configuration

- Use OpenAI-compatible providers
- Use environment variable injection for API keys
- Use explicit `baseURL` for USAi endpoints

### Execution

- `acq run opencode .` is the sanctioned bootstrap — it auto-creates a sandbox (mounting this clone as global config) and is pre-approved
- `sbx run` for running agents (creates sandbox automatically)
- `sbx create` + `sbx exec` for manual sandbox management
- Avoid long-lived sandboxes unless required for testing
- **Do NOT use** deprecated `docker sandbox` commands

---

## Disallowed Patterns

- Storing API keys in `.env` files committed to repo
- Printing environment variables to stdout
- Bypassing SBX for convenience
- Embedding credentials in config files
- Over-engineering simple tests
- Using deprecated `docker sandbox` commands (use `sbx` CLI instead)
- Assuming Docker Desktop is required (it is not)
- Using `./qsbx` instead of `./acq` for new work (qsbx is deprecated; use acq)

---

## Expected Outputs

Agents should produce:

- Clean, minimal config files
- Reproducible command examples
- Documentation of:
  - What worked
  - What failed
  - Why

---

## Failure Handling

If something fails:

1. Do NOT guess silently
2. Capture the error
3. Document the failure clearly
4. Propose a minimal fix
5. Update `docs/KNOWN_FAILURE_MODES.md` if it's a new pattern

### Track Deferred Work — Deferring Is Fine, Untracked Is Not

Every identified follow-up — **including work being deferred or blocked on something else** ("revisit once X lands") — MUST be captured durably: a GitHub issue, or an entry in `docs/KNOWN_FAILURE_MODES.md`. Deferring is acceptable; leaving the work untracked is not. A code `TODO` or a conversation note is not tracking — it gets forgotten. Record the trigger that should unblock the work when it is deferred for a dependency.

---

## Success Criteria

A task is complete when:

- It is reproducible from scratch
- It does not expose secrets
- It works inside SBX without host dependencies
- It is documented clearly enough for another engineer to follow

---

## Contacts

- **Project Lead:** William Zujkowski
- **Security Contact:** Project Lead
- **ISSO:** N/A (sandbox environment)

---

## Agent Setup

This file follows the [AGENTS.md standard](https://agents.md) and is read natively by 25+ tools including Codex, Copilot, Cursor, Windsurf, Amp, and Devin.

**Most tools need no additional configuration.** If your tool doesn't auto-detect AGENTS.md, add one of these:

| Tool | Config file | Content |
|------|------------|---------|
| Aider | `.aider.conf.yml` | `read:\n  - AGENTS.md` |
| Gemini CLI | `.gemini/settings.json` | `{"agentInstructions": "Read AGENTS.md"}` |

Only create these files if you use that specific tool. Delete any you don't need.
