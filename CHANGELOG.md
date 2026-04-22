# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.4.0...v0.5.0) (2026-04-22)


### Features

* add workspace structure and makefile for simplified setup ([#20](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/20)) ([abd22e8](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/abd22e8629b7912b5cc34835b37c4457fe7f7cee))

## [0.4.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.3.0...v0.4.0) (2026-04-14)


### Features

* **templates:** add bootstrap files for copying quickstart to other repos ([7ea07e7](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/7ea07e782a7623588415a97cef8884a667299b64))

## [0.3.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.2.0...v0.3.0) (2026-04-14)


### Features

* add semver, conventional commits, and automated releases ([#12](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/12)) ([5c3cdfb](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/5c3cdfb0c11f16d8253500bfcadf299abedd07c1))


### Bug Fixes

* **ci:** migrate from hello-please to release-please ([583dca5](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/583dca5c3390268536aad47ff8323726855660d2))

## [Unreleased]

### Added

- Semantic versioning (SemVer 2.0.0) adoption
- Conventional commits enforcement via commitlint
- Automated release workflow using release-please (Google)
- ADR-0002: Version management and release automation decision record
- `release-please-config.json` and `.release-please-manifest.json` for automated releases
- This CHANGELOG.md following Keep a Changelog v1.1.0 format
- CONTRIBUTING.md with commit message guidelines

### Changed

- Updated AGENTS.md with commit message requirements and AI attribution guidance
- Updated CODING_PRACTICES.md with version control and release standards
- Migrated release workflow to release-please automation

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
