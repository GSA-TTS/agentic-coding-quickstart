# Contributing to agent-sandbox

Thank you for contributing to the Agentic Coding Quickstart project! This guide will help you understand our development workflow and standards.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Commit Message Guidelines](#commit-message-guidelines)
- [Pull Request Process](#pull-request-process)
- [Development Standards](#development-standards)
- [Testing Requirements](#testing-requirements)

---

## Code of Conduct

This project operates under federal government standards of professional conduct. All contributors must:

- Be respectful and constructive in all interactions
- Follow security and compliance requirements outlined in `AGENTS.md` and `docs/CODING_PRACTICES.md`
- Report security vulnerabilities privately (see `SECURITY.md`)

---

## Getting Started

### Prerequisites

- Docker (for SBX containers)
- Git
- Basic understanding of the SBX tooling and USAi API endpoints

### Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/williamzujkowski/agent-sandbox.git
   cd agent-sandbox
   ```

2. Read the core documentation:
   - `AGENTS.md` — Behavioral rules for AI agents
   - `docs/CODING_PRACTICES.md` — Secure coding standards
   - `docs/SBX_QUICKSTART.md` — SBX setup guide

3. Follow the quickstart to set up your environment

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

#### Feature Addition
```
feat(agents): add continuous monitoring requirements

Adds section 17 to CODING_PRACTICES.md covering post-deployment
monitoring requirements per M-25-21 federal guidance.

Refs: NIST SP 800-218A, M-25-21
```

#### Bug Fix
```
fix(sbx): correct secret injection path in container config

The previous configuration used /app/secrets instead of /run/secrets,
causing secrets to fail injection on container startup.

Fixes: #42
```

#### Documentation Update
```
docs(readme): clarify SBX installation requirements

Updates README to explicitly list Docker version requirements
and link to the full SBX quickstart guide.
```

#### Breaking Change
```
feat(api)!: migrate authentication to OAuth 2.0

BREAKING CHANGE: API authentication now requires OAuth 2.0 tokens
instead of API keys. Clients must update their authentication flow.

Migration guide: docs/migration/oauth-migration.md
Refs: #123
```

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

Releases are **fully automated** via GitHub Actions and hello-please:

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

- **Security vulnerabilities:** See `SECURITY.md` for responsible disclosure
- **General questions:** Open a GitHub Discussion
- **Bug reports:** Open a GitHub Issue with:
  - Steps to reproduce
  - Expected vs actual behavior
  - Environment details (OS, Docker version, etc.)

---

## License

This project is released under the CC0 1.0 Universal license. See `LICENSE` for details.

---

**Thank you for contributing to the Agentic Coding Quickstart!**
