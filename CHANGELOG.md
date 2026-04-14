# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Semantic versioning (SemVer 2.0.0) adoption
- Conventional commits enforcement via commitlint
- Automated release workflow using hello-please
- ADR-0002: Version management and release automation decision record
- `.hello-please.yml` configuration for automated releases
- This CHANGELOG.md following Keep a Changelog v1.1.0 format
- CONTRIBUTING.md with commit message guidelines

### Changed

- Updated AGENTS.md with commit message requirements
- Updated CODING_PRACTICES.md with version control and release standards
- Migrated release workflow to hello-please automation

## [0.2.0] - 2026-03-31

### Added

- Python CLI wrapper for SBX operations (`sbx` command)
- Full test coverage for sandbox lifecycle operations
- Type hints and validation for all Python modules

### Changed

- Replaced bash-based sandbox wrapper with Python implementation
- Improved error handling and user feedback in CLI

### Fixed

- Sandbox lifecycle management issues

## [0.1.0] - 2026-02-27

### Added

- Initial project structure and documentation
- AGENTS.md behavioral rules for AI coding agents
- CODING_PRACTICES.md secure coding standards
- SBX quickstart guide and documentation
- Docker SBX integration for isolated agent execution
- USAi API endpoint configuration examples
- OpenCode configuration (`opencode.jsonc`)
- ADR-0001: SBX isolation architecture decision
- GitHub Actions CI workflow
- Gitleaks configuration for secret scanning
- CC0 1.0 Universal license

### Changed

- Default model from claude_3_7_sonnet to claude_4_5_opus
- Gitleaks configuration from `.gitleaks.toml` to `.gitleaks.repo.toml`
- Improved sandbox lifecycle documentation

### Fixed

- CI workflow: removed gitleaks action, improved developer experience
- GitHub token setup for git operations inside sandbox

[unreleased]: https://github.com/williamzujkowski/agent-sandbox/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/williamzujkowski/agent-sandbox/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/williamzujkowski/agent-sandbox/releases/tag/v0.1.0
