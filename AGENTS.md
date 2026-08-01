---
title: "Agentic Coding Quickstart - Agent Rules"
description: "Behavioral rules for AI coding agents operating with a sandboxing backend (SBX or MSB) + USAi"
status: canonical
tier: 1
last_updated: "2026-08-01"
audience: "developers"
keywords: ["AGENTS.md", "acq", "sbx", "msb", "usai", "sandbox", "agent-rules", "workspace"]
related_files: ["docs/QUICKSTART.md", "docs/BACKEND_GUIDE.md", "docs/KNOWN_FAILURE_MODES.md", "docs/adr/0001-sbx-usai-agent-execution-architecture.md", "docs/adr/0010-acq-pluggable-backends.md", "docs/adr/0011-msb-backend-and-neutral-kits.md"]
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
federally-configured agent sandbox by composing existing tools: a **sandboxing
backend** — the `sbx` CLI (SBX) or `msb` (MSB / microsandbox) — plus four
**mixin kits** hosted in the community
[agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo (`integrations/isolation/acq-kits/`). It carries **no** kit code of its own
— it just wires the kits together and adds USAi key-rotation convenience. A
typical layout:

```
my-workspace/                       # Parent folder (user creates this)
├── agentic-coding-quickstart/      # THIS REPO - the acq wrapper + docs
│   ├── AGENTS.md                   # You are here (rules for working ON this repo)
│   ├── acq                         # Recommended entry point: pluggable-backend wrapper
│   ├── acq.backends/               # Backend adapters (sbx, msb)
│   ├── qsbx                        # DEPRECATED: use acq instead (removed in 2.0.0)
│   ├── scripts/                    # helper scripts (USAi key rotation, tests)
│   └── docs/                       # Setup guides and references
└── my-app/                         # User's project(s)
```

When `acq` creates a sandbox it applies four kits by pinned remote reference
(`--kit git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=<sha>&dir=…`).
The same neutral kits apply to both backends; per-backend translation is the
adapter's job (see [ADR-0010](docs/adr/0010-acq-pluggable-backends.md) /
[ADR-0011](docs/adr/0011-msb-backend-and-neutral-kits.md)).

### Agent Resource Access

When working on user projects, the agent has access to:

| Resource | Location | Use For |
|----------|----------|---------|
| Global config | `~/.config/opencode/opencode.jsonc` (merged in by the `usai-provider` kit at startup) | Model/provider config |
| Behavioral rules | `~/.config/opencode/AGENTS.md` (linked to playbook clone) | Federal agent rules |
| Skills | `~/.agents/skills` (linked to playbook clone) | Step-by-step procedures |
| Setup guides | `./docs/` | Backend (SBX/MSB) configuration, troubleshooting |

**To use a skill:** Read the SKILL.md file in the skill directory and follow its procedures.

---

## Purpose

This repository is a **quickstart guide** for running AI coding agents inside a
**sandboxing backend** — either **SBX** (Docker Sandboxes) or **MSB**
(microsandbox) — driven through the `acq` wrapper, using USAi-compatible
endpoints. `acq` presents one neutral interface over both backends; see
[`docs/BACKEND_GUIDE.md`](docs/BACKEND_GUIDE.md) and
[ADR-0010](docs/adr/0010-acq-pluggable-backends.md) /
[ADR-0011](docs/adr/0011-msb-backend-and-neutral-kits.md) for how they differ.

> **Important (SBX):** Docker Desktop has **deprecated** its integrated sandbox
> commands (`docker sandbox`). Use the standalone **`sbx` CLI** instead. The
> `sbx` CLI does **not** require Docker Desktop. (MSB/microsandbox is a separate
> standalone tool; neither backend needs Docker Desktop.)

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

- **Description:** Quickstart guide for AI agent development with a sandboxing backend (SBX or MSB) and USAi endpoints
- **Language(s):** Shell scripts, JSON/JSONC configuration, Markdown documentation
- **Framework(s):** `acq` wrapper over the SBX CLI and MSB (microsandbox), OpenCode, USAi API
- **Data Classification:** Internal / Non-sensitive (no PII, no CUI)
- **ATO Status:** Pre-ATO development
- **Authorized Agent(s):** OpenCode, Claude Code, GitHub Copilot

> **Note:** Docker Desktop is **not required**. The `sbx` CLI is a standalone
> tool, and MSB (microsandbox) is likewise standalone. Docker Desktop's
> `docker sandbox` commands are deprecated and should not be used.

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
| **Commit Message** | OPTIONAL | `Co-authored-by: AI Agent <ai-agent@gsa.gov>` in footer |
| **Documentation** | REQUIRED | This AGENTS.md documents AI agent authorization |

**Rationale:** Federal guidance (NIST AI RMF, SP 800-218A) emphasizes system-level traceability over granular per-commit attribution. PR-level disclosure provides auditable records without commit noise.

When AI attribution IS included in commits, use:
```
Co-authored-by: AI Agent <ai-agent@gsa.gov>
```

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

## Sandbox Rules (Non-Negotiable)

> These rules apply to **whichever backend `acq` selects** — SBX (Docker
> Sandboxes) or MSB (microsandbox). They are principle-level and backend-neutral;
> the per-backend mechanics (secret injection, port publishing, etc.) live in
> [`docs/BACKEND_GUIDE.md`](docs/BACKEND_GUIDE.md) and
> [ADR-0011](docs/adr/0011-msb-backend-and-neutral-kits.md). Where SBX and MSB
> genuinely differ, the difference is called out inline below.
>
> **Tooling Note (SBX):** Use the standalone `sbx` CLI for SBX operations.
> Docker Desktop's integrated `docker sandbox` commands are **deprecated** and
> will be removed; the `sbx` CLI does not require Docker Desktop. MSB
> (microsandbox) is a separate standalone tool. Prefer the `acq` wrapper over
> calling either backend CLI directly.

### 1. No Secrets Exposure

The agent MUST NEVER:
- Print, log, or persist API keys, tokens, or credentials
- Hardcode secrets in source files, config files, or scripts
- Deliberately expose real secret *values* (e.g., `echo $SECRET`, or piping `printenv`/`env` output somewhere it is logged, committed, or shown)
- Include secrets in commit messages, comments, or documentation

> **Note on `env` / `printenv` in the sandbox:** Inside the sandbox, secrets are
> **injected placeholders or proxied** (the agent never holds the real USAi key
> material) — on SBX via the proxy/placeholder mechanism, on MSB via
> `--secret ENV@HOST` swap-on-the-wire — so inspecting the environment is not
> automatically a leak. The `usai-provider` kit's OpenCode policy is
> **default-allow** (the sandbox is the security boundary), so these commands are
> **allowed** rather than gated — the agent should still avoid deliberately
> dumping secret values. The prohibition above is about *exposing real secret
> values*, not about routine environment inspection in the sandbox. The gated
> (`ask`) class is instead commands that open a **new outbound destination**
> (e.g. `git push`, new git remotes, `scp`/`sftp`/`rsync`/`nc`); see ADR-0005 and
> the kit's decision record.

All secrets MUST be accessed via:
- The backend's secret management (SBX secret store / proxy, or MSB `--secret ENV@HOST` binding), driven through `acq`
- Environment variables injected at runtime (not persisted)

### 2. Assume You Are Untrusted

Agents must behave as if:
- The runtime environment is monitored
- Outputs may be logged and reviewed
- Any exposed secret is considered compromised

### 3. The Sandbox Is the Security Boundary

All agent execution MUST:
- Occur inside the sandbox (SBX or MSB) when working with USAi endpoints
- Go through `acq` (or the backend CLI it wraps) — never the deprecated `docker sandbox` commands
- Avoid direct host interaction unless explicitly required
- Avoid writing outside the working directory
- Respect container/VM filesystem boundaries

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
- [x] Execute commands inside the sandbox (SBX or MSB)

---

## Actions Requiring Approval

The agent MUST ask the user before:
- [ ] Installing or upgrading dependencies
- [ ] Making network requests to external services (except USAi endpoints)
- [ ] Modifying CI/CD pipeline configurations
- [ ] Deleting files or directories
- [ ] Committing or pushing code
- [ ] Modifying backend configuration (SBX or MSB), or creating sandboxes outside the sanctioned bootstrap (`acq run` / `acq create` / `qsbx run` / `sbx run` / `msb run`, which auto-create a sandbox as part of normal execution and are pre-approved)
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
- [ ] Bypass the sandbox (SBX or MSB) for convenience
- [ ] Create network listeners or reverse connections

---

## Data Handling

- **Sensitive data types in this project:** API keys, tokens, credentials (never stored)
- **Approved data storage:** Local filesystem within project directory only
- **PII handling:** No PII should exist in this repository
- **Data residency:** Local development only

The agent MUST:
- Never include API keys or tokens in logs, comments, or test fixtures
- Use environment variables injected via the sandbox backend (SBX or MSB) for all credentials
- Mask any sensitive values if debugging output is required

---

## Network Access

- **Authorized external endpoints:**
  - `https://api.gsa.usai.gov/api/v1` (USAi API)
  - `https://api.github.com` (GitHub API — via the SBX proxy, or the MSB `--secret` binding)
  - `https://workshop.cloud.gov` (GitLab API - GSA workshop instance)
- **Authorized internal endpoints:** None
- **TLS requirement:** TLS 1.2+ for all connections
- **Proxy configuration:** Use system proxy if configured

### Credential Injection Methods

Prefer driving these through `acq`, which applies the right mechanism for the
selected backend. The backends differ: **SBX** injects via its secret store /
proxy (placeholders swapped in-sandbox); **MSB** binds `ENV@HOST` and swaps the
real value in on the wire. Both keep the real secret out of the agent's hands.

| Service | SBX | MSB | Notes |
|---------|-----|-----|-------|
| USAi | Custom secret (`sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY`) | `acq secret set usai …` → bound as `USAI_API_KEY@api.gsa.usai.gov` | Custom endpoint not a built-in proxy service on SBX |
| GitHub | SBX proxy, **per-sandbox scoped** (`acq` fine-grained flow, or `sbx secret set <sandbox> github`) | `acq secret set github …` → bound as `GITHUB_TOKEN@api.github.com` (REST API host only) | Least-privilege per-sandbox default. Agent never sees the token. See [ADR-0013](docs/adr/0013-per-sandbox-github-token-downscoping.md) |
| GitLab | Custom secret (`sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN`) | `acq secret set gitlab --host workshop.cloud.gov --env GITLAB_TOKEN` → bound **generically** as `GITLAB_TOKEN@workshop.cloud.gov` (custom endpoint; requires `--host`/`--env`, not a built-in bind) | Not a built-in service on either backend |

See [`docs/BACKEND_GUIDE.md`](docs/BACKEND_GUIDE.md) for the full per-backend
credential-injection and secret-binding model (and
[`docs/QUICKSTART_SBX.md`](docs/QUICKSTART_SBX.md) for SBX-specific proxy
patterns).

---

## Coding Standards

- Follow [`CODING_PRACTICES.md`](https://github.com/GSA-TTS/agentic-coding-playbook/blob/main/docs/CODING_PRACTICES.md) in the GSA agentic-coding-playbook for secure coding guidelines
- Prefer explicit configuration over implicit behavior
- Maximum function length: 50 lines
- All external input MUST be validated before use
- Use parameterized queries for any database operations

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
- [ ] Test inside the sandbox (SBX or MSB), not directly on host

### Periodic Re-Verification

Documented backend patterns silently rot as `sbx`/`msb`, USAi, or OpenCode
versions move. A pattern marked "works" is only trustworthy if it still runs.

The agent SHOULD:
- Re-verify documented backend patterns by **running the real flow (live, not mocked)** on the quarterly review cadence (or on demand when a pattern is in doubt)
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
| Infrastructure | Backend config (SBX or MSB), deployment, access control | Explicit per-change approval |

---

## Engineering Discipline

The agent MUST:
- [x] Create an ADR before: adding dependencies, changing architecture, introducing new patterns
- [x] Not implement speculative features (YAGNI)
- [x] Prefer 1 config file + 1 command over complex setups
- [x] Document outcomes clearly enough for another engineer to follow

**One-command bootstrap:** `./acq run opencode .` (creates sandbox with config mounted, then attaches)
**One-command verify:** `acq exec <sandbox-name> <verify-command>` (routes to `sbx exec` / `msb exec` for the active backend)
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
- Prefer `acq` for running agents and managing sandboxes; it auto-creates the sandbox on the selected backend (SBX or MSB)
- Backend CLIs (`sbx run`, `sbx create`/`sbx exec`; `msb run`, `msb exec`) are available for manual management, but `acq` is preferred
- Avoid long-lived sandboxes unless required for testing
- **Do NOT use** deprecated `docker sandbox` commands

---

## Disallowed Patterns

- Storing API keys in `.env` files committed to repo
- Printing environment variables to stdout
- Bypassing the sandbox (SBX or MSB) for convenience
- Embedding credentials in config files
- Over-engineering simple tests
- Using deprecated `docker sandbox` commands (use the `sbx` CLI, or `acq`, instead)
- Assuming Docker Desktop is required (it is not — both SBX and MSB are standalone)
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
- It works inside the sandbox (SBX or MSB) without host dependencies
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
