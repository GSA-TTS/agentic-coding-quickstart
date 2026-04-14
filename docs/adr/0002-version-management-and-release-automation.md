---
title: "Adopt Semantic Versioning, Conventional Commits, and release-please for Release Automation"
status: accepted
date: 2026-04-14
decision_makers: ["William Zujkowski"]
category: development-process
nist_controls: ["CM-2", "CM-3", "SA-10", "SA-11"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
---

# ADR-0002: Adopt Semantic Versioning, Conventional Commits, and release-please for Release Automation

## Context and Problem Statement

As this repository evolves from a quickstart guide to a reference implementation for
federal AI coding patterns, we need a consistent, auditable, and low-friction approach
to version management, release automation, and change documentation.

Federal software development requires clear traceability from commits through releases
to deployed artifacts. Manual versioning and changelog maintenance are error-prone and
do not scale as the project grows.

## Decision Drivers

- **CM-2 (Baseline Configuration):** Version control and configuration management must be auditable
- **CM-3 (Configuration Change Control):** Changes must be documented with clear rationale
- **SA-10 (Developer Configuration Management):** Version control practices must support compliance
- **SA-11 (Developer Testing):** Release process must integrate with automated testing
- **Developer Experience:** Release process should be low-friction and automatable
- **Traceability:** Ability to trace changes from commits through releases to deployed systems
- **AGENTS.md Compliance:** AI agents must follow structured commit patterns

## Considered Options

1. **Semantic Versioning + Conventional Commits + release-please (Automated)**
2. **Manual Versioning with Keep a Changelog**
3. **Calendar Versioning (CalVer) with Manual Releases**
4. **Automated Semantic Release (semantic-release npm package)**

## Decision Outcome

Chosen option: **Semantic Versioning + Conventional Commits + release-please (Automated)**,
because it provides the best balance of automation, traceability, and federal compliance
requirements while maintaining simplicity and being backed by Google's well-maintained tooling.

### Architecture Overview

```
[Developer Commit]
       |
       +--> Conventional Commit Format
       |    (feat:, fix:, chore:, docs:, BREAKING CHANGE:)
       |
       v
[GitHub Actions: Commit Lint Check]
       |
       v
[Merge to main]
       |
       v
[release-please: Creates Release PR with version bump + CHANGELOG]
       |
       v
[Merge Release PR]
       |
       v
[Create Git Tag + GitHub Release]
```

### Key Implementation Elements

1. **Semantic Versioning (SemVer 2.0.0)**
   - Version format: `MAJOR.MINOR.PATCH`
   - MAJOR: Breaking changes (incompatible API changes)
   - MINOR: New features (backward-compatible)
   - PATCH: Bug fixes (backward-compatible)
   - Pre-release: `1.0.0-alpha.1`, `1.0.0-beta.2`, `1.0.0-rc.1`

2. **Conventional Commits Specification**
   - Commit format: `<type>(<scope>): <subject>`
   - Types:
     - `feat:` → Minor version bump (new feature)
     - `fix:` → Patch version bump (bug fix)
     - `docs:` → No version bump (documentation only)
     - `chore:` → No version bump (maintenance)
     - `test:` → No version bump (test changes)
     - `refactor:` → No version bump (code refactoring)
     - `perf:` → Patch version bump (performance improvement)
     - `ci:` → No version bump (CI/CD changes)
     - `build:` → No version bump (build system changes)
     - `revert:` → Version bump determined by reverted commit
   - Breaking changes: Include `BREAKING CHANGE:` in commit footer → Major version bump
   - Scope: Optional, e.g., `feat(agents): add new agent rule`

3. **release-please for Release Automation**
   - Google-maintained tool for automated releases based on conventional commits
   - Creates a Release PR that accumulates changes and updates CHANGELOG.md
   - When Release PR is merged, creates git tag and GitHub release
   - Configuration in `release-please-config.json` and `.release-please-manifest.json`
   - GitHub Action: `googleapis/release-please-action`

4. **CHANGELOG.md Format**
   - Follow Keep a Changelog v1.1.0 format
   - Auto-generated from conventional commits via release-please
   - Sections: Added, Changed, Deprecated, Removed, Fixed, Security
   - Each version links to GitHub compare view

5. **Commitlint Enforcement**
   - Pre-commit hook validates commit message format
   - CI check blocks non-compliant commits
   - Configuration in `.commitlintrc.yml`

### Positive Consequences

- Automatic version bumping based on commit semantics
- Auto-generated changelog reduces manual documentation burden
- Clear traceability from commit to release
- AI agents can follow structured commit patterns easily
- SemVer provides clear expectations for downstream consumers
- GitHub Actions integration enables full automation
- Compliance-friendly audit trail (CM-2, CM-3, SA-10)
- release-please is backed by Google with strong maintenance and community

### Negative Consequences

- Team must learn and follow conventional commit format
- Squash merges require careful commit message composition
- Release PR model requires an additional merge step
- Requires discipline — incorrect commit types lead to incorrect version bumps

### Compliance Consequences

- **CM-2 (Baseline Configuration):** Satisfied — all versions tracked in git with clear diffs
- **CM-3 (Configuration Change Control):** Satisfied — CHANGELOG documents all changes with rationale
- **SA-10 (Developer Configuration Management):** Satisfied — version control enforced via commitlint
- **SA-11 (Developer Testing):** Satisfied — release workflow integrates with CI testing
- **SSP Impact:** Add release process description to System Design section

## Alternatives Considered

### Manual Versioning with Keep a Changelog

Rejected because:
- Error-prone (version mismatches between files)
- High manual effort for CHANGELOG maintenance
- Does not scale as team grows
- AI agents cannot reliably update changelogs correctly

### Calendar Versioning (CalVer)

Rejected because:
- Does not convey semantic meaning of changes
- Harder for downstream consumers to assess breaking changes
- Less common in federal software development
- SemVer is industry standard and well-understood

### Automated Semantic Release (semantic-release npm package)

Rejected because:
- Heavy dependency on Node.js ecosystem
- More complex configuration
- Requires Node.js runtime in CI

### hello-please

Initially considered but rejected because:
- Repository no longer exists/accessible
- Less community support than release-please
- release-please has stronger Google backing and maintenance

## Implementation Plan

1. Create `release-please-config.json` and `.release-please-manifest.json`
2. Create initial `CHANGELOG.md` with Keep a Changelog format
3. Add commitlint configuration (`.commitlintrc.yml`)
4. Update AGENTS.md with commit message requirements
5. Update CODING_PRACTICES.md with version control standards
6. Update `.github/workflows/release.yml` to use release-please
7. Add CONTRIBUTING.md with commit message guidelines
8. Backfill CHANGELOG for existing releases (v0.1.0, v0.2.0)

## Commit Message Format Reference

```
<type>(<optional-scope>): <subject>

<optional-body>

<optional-footer>
```

### Examples

```
feat(agents): add continuous monitoring requirements to AGENTS.md

Adds section 17 to CODING_PRACTICES.md covering post-deployment
monitoring requirements per M-25-21.

Refs: NIST SP 800-218A, M-25-21
```

```
fix(sbx): correct secret injection path in SBX configuration

The previous configuration used an incorrect path that caused
secrets to fail injection on container startup.

Fixes: #42
```

```
feat(api)!: migrate authentication to OAuth 2.0

BREAKING CHANGE: API authentication now requires OAuth 2.0 tokens
instead of API keys. Clients must update authentication flow.

Migration guide: docs/migration/oauth-migration.md
```

## Links

- [Semantic Versioning 2.0.0](https://semver.org/)
- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/)
- [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
- [release-please](https://github.com/googleapis/release-please)
- [release-please-action](https://github.com/googleapis/release-please-action)
- [NIST SP 800-53 Rev 5 — CM-2 Baseline Configuration](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [NIST SP 800-53 Rev 5 — CM-3 Configuration Change Control](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- Related: `AGENTS.md`, `docs/CODING_PRACTICES.md`
