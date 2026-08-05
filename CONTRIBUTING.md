# Contributing to Agentic Coding Quickstart

Thank you for contributing! This repository helps GSA teams use AI coding agents effectively.

## Ecosystem Overview

This repo is one of three in the agentic coding ecosystem:

| Repo | Focus | Typical Contributions |
|------|-------|----------------------|
| **[Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart)** (you are here) | Environment setup | SBX fixes, troubleshooting docs, config improvements |
| **[Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)** | Standards & practices | Coding standards, skills, templates |
| **[Patterns](https://github.com/GSA-TTS/agentic-coding-patterns)** | Community sharing | Workflows, lessons learned, tool examples |

**Not sure where your contribution belongs?** Ask in the [agentic-coding Slack channel](https://gsa.enterprise.slack.com/archives/C0B44531QLE).

## Getting Help

- **Questions:** Ask in the [agentic-coding Slack channel](https://gsa.enterprise.slack.com/archives/C0B44531QLE) (others benefit too)
- **Bugs:** Open a GitHub issue with steps to reproduce
- **Security issues:** See [SECURITY.md](SECURITY.md) — direct fixes preferred

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Commit Message Guidelines](#commit-message-guidelines)
- [Pull Request Process](#pull-request-process)
- [Development Standards](#development-standards)
- [Testing Requirements](#testing-requirements)

---

## Code of Conduct

This project operates under professional standards of conduct. All contributors:

- Be respectful and constructive in all interactions
- Follow security requirements outlined in `AGENTS.md` and `docs/CODING_PRACTICES.md`
- For security issues, see [SECURITY.md](SECURITY.md)

---

## Getting Started

### Prerequisites

- Docker (for SBX containers)
- Git
- Basic understanding of the SBX tooling and USAi API endpoints

### Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
   cd agentic-coding-quickstart
   ```

2. Read the core documentation:
   - `AGENTS.md` — Behavioral rules for AI agents
   - `docs/CODING_PRACTICES.md` — Secure coding standards
   - `docs/QUICKSTART_SBX.md` — sbx CLI setup guide

3. Follow the quickstart to set up your environment

---

## Local Development Checks

Run CI checks locally before pushing to catch issues early.

### Install dependencies

#### Markdown linter (Node.js)
```bash
npm ci --prefix .github/linters
```
#### Pre-commit hooks (Python) — optional but recommended
- requires `pre-commit` installation and setup
- see `docs/PRE_COMMIT_SETUP.md` for instructions

### Available scripts

| Command | What it does |
|---------|-------------|
| `npm run lint:md` | Lint markdown files (same rules as CI) |
| `npm run lint` | Run all linters |
| `npm run lint:secrets` | Run gitleaks (requires gitleaks to be installed: `brew install gitleaks`) |
| `npm run check` | Run the full pre-commit suite (gitleaks, shellcheck, YAML/JSON validation, whitespace, markdown lint) |

> [!NOTE]
> `npm run check` auto-fixes some issues (markdown, whitespace, EOF) — review and stage the changes it makes.

This repo carries almost no application code, so it has no broad test suite. The
kits it applies — and their tests (permission-matrix, model-sync, per-kit
`scripts/verify`) — live in the
[agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo under `integrations/isolation/acq-kits/`. Changes to provider config,
rules, skills, or CA trust belong there.

There is one offline unit harness (stubbed `sbx`/`msb`/`opencode`, no Docker or network):

- **`scripts/test-acq`** — covers `acq` dispatch, backend resolution, secret
  command shapes, and kit list completeness. Run after changing `acq`,
  `acq.backends/common.sh`, `acq.backends/sbx.sh`, or `acq.backends/msb.sh`.

  ```bash
  ./scripts/test-acq
  ```

To verify the backends end-to-end against the **real** toolchain (requires a
host that can create sandboxes — Docker for sbx, or KVM for msb):

```bash
./scripts/verify-backends
```

It exercises the kit/agent/USAi flow on each installed backend. It cannot run
inside a sandbox (no nested sandboxes).

### Quick pre-push check

```bash
npm run lint
```

Or for the most comprehensive local check (requires pre-commit):

```bash
npm run check
```

---

## Commit Message Guidelines

This project follows **Conventional Commits 1.0.0** for automated version management and changelog generation.

### Commit Message Format

```
<type>(<optional-scope>): <subject>

<optional-body>

<optional-footer>
```

### Commit Types

| Type | Version Bump | When to Use |
|------|--------------|-------------|
| `feat` | Minor (0.X.0) | New feature added (backward-compatible) |
| `fix` | Patch (0.0.X) | Bug fix (backward-compatible) |
| `docs` | None | Documentation only changes |
| `style` | None | Code style/formatting (no logic change) |
| `refactor` | None | Code refactoring (no feature or bug change) |
| `perf` | Patch (0.0.X) | Performance improvement |
| `test` | None | Adding or updating tests |
| `chore` | None | Maintenance tasks (no production code change) |
| `ci` | None | CI/CD pipeline changes |
| `build` | None | Build system changes |
| `revert` | Depends | Reverting a previous commit |
| `security` | Patch (0.0.X) | Security fixes |

### Breaking Changes

Breaking changes trigger a **Major version bump** (X.0.0) and MUST be indicated in one of two ways:

1. **Footer notation** (preferred):
   ```
   feat(api): migrate authentication to OAuth 2.0

   BREAKING CHANGE: API authentication now requires OAuth 2.0 tokens
   instead of API keys. Clients must update their authentication flow.
   ```

2. **Type suffix**:
   ```
   feat(api)!: migrate authentication to OAuth 2.0
   ```

### Commit Message Rules

✅ **DO:**
- Use lowercase for type, scope, and subject
- Keep subject line ≤72 characters
- Use imperative mood ("add" not "added" or "adds")
- Separate subject from body with a blank line
- Wrap body text at 100 characters
- Reference issues/tickets in the footer (e.g., `Fixes: #42`, `Refs: #123`)

❌ **DON'T:**
- End subject line with a period
- Use past tense in subject line
- Write vague messages ("fix bug", "update code")
- Skip the commit type prefix
- Exceed 100 characters in the header

### Examples

#### Feature Addition (SBX setup)
```
feat(sbx): add network policy configuration step

Adds explicit network policy configuration to SBX setup guide.
Includes examples for allowing USAi API endpoints and blocking
external network access.

Refs: #39
```

#### Bug Fix (Command syntax)
```
fix(docs): correct sbx version command syntax

Changed 'sbx --version' to 'sbx version' per CLI documentation.
Also updated network policy flag from --policy to --global.

Fixes: #36
```

#### Documentation Update (Quickstart guide)
```
docs(readme): clarify Docker and SBX requirements

Updates README to explicitly list:
- Docker Desktop 4.0+ requirement
- SBX installation steps
- Link to full quickstart guide

```

#### Breaking Change (API migration)
```
feat(api)!: migrate authentication to OAuth 2.0

BREAKING CHANGE: API authentication now requires OAuth 2.0 tokens
instead of API keys. Clients must update their authentication flow.

Migration guide: docs/migration/oauth-migration.md
Refs: #123
```

### Validation and Merge Strategy

Conventional-commit format is enforced on the **pull request title** by a
pinned GitHub Action (`amannn/action-semantic-pull-request`, see
`.github/workflows/pr-lint.yml`) — **no local tooling or `npm install` is
required**.

**Squash-merge is the preferred merge strategy.** On squash, the validated PR
title becomes the squashed commit subject, which is exactly what the release
automation (release-please) consumes to determine version bumps. Keep the PR
title in `type(scope): description` form, e.g.:

```
feat(sbx): add reset target for stale sandbox paths
```

Per-commit messages on a feature branch are not individually linted (they are
squashed away), so focus on getting the PR title right.

---

## Pull Request Process

1. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```

2. **Make your changes** following the coding standards in `docs/CODING_PRACTICES.md`

3. **Write tests** if applicable — all new features should include tests

4. **Commit your changes** using conventional commit format:
   ```bash
   git commit -m "feat(scope): add new feature"
   ```

5. **Push to your fork**:
   ```bash
   git push origin feat/your-feature-name
   ```

6. **Open a pull request** with:
   - Clear description of changes
   - Reference to related issues
   - Screenshots (if UI changes)
   - Test results (if applicable)

7. **Address review feedback** — reviewers will check for:
   - Compliance with `AGENTS.md` and `docs/CODING_PRACTICES.md`
   - Conventional commit format
   - Test coverage
   - Security implications

8. **Squash and merge** — Use a conventional commit message for the squash commit title

---

## Development Standards

All code must comply with:

- **AGENTS.md** — Behavioral rules for AI agents
- **docs/CODING_PRACTICES.md** — Secure coding standards including:
  - Input validation and output encoding
  - Secrets management (no secrets in code!)
  - Dependency security (exact version pinning)
  - Architecture discipline (ADRs for major decisions)
  - Size limits (functions ≤50 lines, files ≤400 lines)
  - Test-driven development

### Architecture Decision Records (ADRs)

Major architectural changes require an ADR before implementation:

- Format: MADR (Markdown Architecture Decision Record)
- Location: `docs/adr/`
- Naming: `NNNN-title-of-decision.md`
- See: `docs/adr/0002-version-management-and-release-automation.md` for template

Create an ADR before:
- Adding external dependencies
- Changing authentication/authorization flows
- Introducing new data stores
- Altering module boundaries
- Selecting AI models or frameworks

---

## Testing Requirements

- All patterns must be reproducible from scratch
- Test inside SBX containers, not directly on host
- Verification must not expose secrets
- Document what worked, what failed, and why

For code contributions:
- Write tests alongside code (TDD: red → green → refactor)
- Cover happy path + edge cases + error cases
- Add regression tests for bug fixes
- Ensure tests pass before submitting PR

---

## Release Process

Releases are **fully automated** via GitHub Actions and release-please:

1. Commits to `main` are analyzed for conventional commit types
2. Version bump is determined automatically:
   - `feat:` → Minor version bump
   - `fix:`, `perf:`, `security:` → Patch version bump
   - `BREAKING CHANGE:` → Major version bump
3. CHANGELOG.md is auto-updated
4. Git tag is created (`vX.Y.Z`)
5. GitHub release is published with release notes

**No manual version bumping is required** — just use correct commit types!

---

## Questions or Issues?

- **Questions:** Ask in the agentic-coding Slack channel
- **Security issues:** See [SECURITY.md](SECURITY.md) — direct fixes preferred
- **Bug reports:** Open a GitHub Issue with:
  - Steps to reproduce
  - Expected vs actual behavior
  - Environment details (OS, Docker version, etc.)

## Teams

- **[@GSA-TTS/agentic-coding-team](https://github.com/orgs/GSA-TTS/teams/agentic-coding-team):** Team members — review, contribute, provide feedback
- **[@GSA-TTS/agentic-coding-admins](https://github.com/orgs/GSA-TTS/teams/agentic-coding-admins):** Repository administrators — merge, release, maintain

---

## Public domain

This project is in the public domain within the United States, and copyright and
related rights in the work worldwide are waived through the
[CC0 1.0 Universal public domain dedication](https://creativecommons.org/publicdomain/zero/1.0/).
See [`LICENSE`](LICENSE) for details.

All contributions to this project will be released under the CC0 dedication. By
submitting a pull request or issue, you are agreeing to comply with this waiver
of copyright interest.

---

**Thank you for helping improve the Agentic Coding Quickstart!**
