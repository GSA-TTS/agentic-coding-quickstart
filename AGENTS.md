---
title: "Agentic Coding Quickstart - Agent Rules"
description: "Behavioral rules for AI coding agents operating with SBX + USAi"
status: canonical
tier: 1
last_updated: "2026-04-21"
audience: "developers"
keywords: ["AGENTS.md", "sbx", "usai", "sandbox", "agent-rules", "workspace"]
related_files: ["docs/KNOWN_FAILURE_MODES.md", "docs/adr/0001-sbx-usai-agent-execution-architecture.md"]
load_priority: "always"
review_cycle: "quarterly"
---

# AGENTS.md — Agentic Coding Quickstart

> **System:** Agentic Coding Quickstart | **Impact Level:** FIPS Low | **Agency:** GSA
>
> **Last Updated:** 2026-04-21 | **Reviewed By:** William Zujkowski
>
> This document defines the behavioral rules for AI coding agents operating within this project. The AI agent MUST follow these rules without exception.

---

## Workspace Structure

This repository holds the **shared global config** (OpenCode settings, agent
rules, docs) plus the playbook as a pinned submodule. The repository root is
also an **sbx mixin kit** (`spec.yaml` + `files/`) named `usai-opencode-provider`
that configures OpenCode for USAi at sandbox creation. `qsbx` mounts this clone
into SBX sandboxes and symlinks the config into the home locations OpenCode
searches. A typical layout:

```
my-workspace/                       # Parent folder (user creates this)
├── agentic-coding-quickstart/      # THIS REPO - global config + sbx kit, mounted into sandboxes
│   ├── AGENTS.md                   # You are here (rules for working ON this repo)
│   ├── spec.yaml                   # sbx mixin kit: USAi provider + network egress
│   ├── files/home/usai-config/opencode.jsonc  # USAi provider + model config (shared)
│   ├── opencode.jsonc -> files/home/usai-config/opencode.jsonc   # root convenience symlink
│   ├── agentic-coding-playbook/    # Pinned submodule: skills + federal AGENTS.md
│   ├── qsbx                        # sbx wrapper: mounts clone, links config into sandbox
│   └── docs/                       # Setup guides and references
└── my-app/                         # User's project(s)
```

Inside the sandbox, `qsbx` delivers the shared config two ways:

- **OpenCode provider config** — applied as an sbx **kit** (`qsbx` passes
  `--kit <clone>` to `sbx create`). The kit drops
  `<clone>/files/home/usai-config/opencode.jsonc` at `~/usai-config/opencode.jsonc`
  and sets `OPENCODE_CONFIG` to point there (see `docs/adr/0005`). The kit owns
  the single-valued `OPENCODE_CONFIG` channel; other config-contributing kits
  must use `<workspace>/.opencode/opencode.jsonc` instead (see `docs/adr/0006`).
- **Playbook rules + skills** — symlinked into the locations OpenCode searches
  (not yet packaged as a kit):
  - `~/.config/opencode/AGENTS.md` → `<clone>/agentic-coding-playbook/AGENTS.md`
  - `~/.agents/skills` → `<clone>/agentic-coding-playbook/.agents/skills`

So edits to the shared config or playbook (after a submodule bump) are picked up
by every sandbox. (An empirical spike found OpenCode does **not** read the
rules/skills relative to `OPENCODE_CONFIG_DIR`, which is why they are symlinked
into the home search paths rather than carried by the kit; see `docs/adr/0004`.)

Applying the kit directly (without `qsbx`) is equivalent for the provider config:
`sbx run --kit . opencode <project>`.

### Agent Resource Access

When working on user projects, the agent has access to:

| Resource | Location | Use For |
|----------|----------|---------|
| Global config | `~/usai-config/opencode.jsonc` (via kit `OPENCODE_CONFIG`) | Model/provider config |
| Behavioral rules | `~/.config/opencode/AGENTS.md` (linked to playbook) | Federal agent rules |
| Skills | `~/.agents/skills` (linked to playbook) | Step-by-step procedures |
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

## SBX-Specific Rules (Non-Negotiable)

> **Tooling Note:** Use the standalone `sbx` CLI for all sandbox operations.
> Docker Desktop's integrated `docker sandbox` commands are **deprecated** and will be removed.
> The `sbx` CLI does not require Docker Desktop — it is a standalone tool.

### 1. No Secrets Exposure

The agent MUST NEVER:
- Print, log, or persist API keys, tokens, or credentials
- Hardcode secrets in source files, config files, or scripts
- Use `printenv`, `env`, or `echo $SECRET` in ways that expose values
- Include secrets in commit messages, comments, or documentation

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
- [ ] Creating new SBX containers or modifying SBX configuration
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
| GitHub | SBX proxy (`sbx secret set -g github`) | Recommended; agent never sees token |
| GitLab | Custom secret (`sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN`) | Not a built-in SBX service |

See `docs/QUICKSTART_SBX.md` for detailed credential injection patterns.

---

## Coding Standards

- Follow [`agentic-coding-playbook/docs/CODING_PRACTICES.md`](https://github.com/GSA-TTS/agentic-coding-playbook/blob/main/docs/CODING_PRACTICES.md) (the pinned playbook submodule) for secure coding guidelines
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
- [ ] Test inside SBX containers, not directly on host

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

**One-command bootstrap:** `./qsbx run opencode .` (creates sandbox with config mounted, then attaches)
**One-command verify:** `sbx exec <sandbox-name> <verify-command>`

> **Note:** `qsbx run` is the preferred method — it creates the sandbox if needed
> (mounting this clone as global config), then attaches. qsbx uses the clone it
> lives in; export `QUICKSTART_CLONE` only to override that.

**ADR location:** `docs/adr/`

---

## Approved Patterns

### Model Configuration

- Use OpenAI-compatible providers
- Use environment variable injection for API keys
- Use explicit `baseURL` for USAi endpoints

### Execution

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
