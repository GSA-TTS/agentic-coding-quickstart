# Changelog

All notable changes to this project will be documented in this file.

This project follows:
- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)

## [Unreleased]

### Changed

- Improved developer workflow (`Makefile`, docs, onboarding)
- Documentation aligned with the Python CLI architecture
- Internal cleanup and release preparation

## [0.2.0] - 2026-03-31

### Added

- Python CLI implementation for `agent-sandbox`
- Provider probing for OpenAI-compatible `/v1/models` endpoints
- Deterministic `opencode.json` generation from validated provider state
- Project-local runtime state in `.agent-sandbox/`
- Structured JSONL audit logging
- Named network policy profiles: `open`, `balanced`, and `restricted`
- Optional `sops-age` support for stronger local secret handling
- Comprehensive automated test suite with high coverage
- Integrated developer tooling with Ruff, Bandit, and pytest

### Changed

- Replaced the Bash-first implementation with a Python package under `src/agent_sandbox/`
- Simplified the default workflow to `make init`, `make doctor`, `make probe`, and `make run`
- Centralized runtime configuration in `.agent-sandbox/config.toml`
- Simplified secrets handling so `.env` is the default path and `sops-age` is optional
- Moved logging to structured audit events instead of ad hoc shell output
- Updated documentation and onboarding around the Python CLI workflow

### Removed

- Legacy shell orchestration layer
- Shell-based config generation
- Shell-based test suites
- Legacy Make targets tied directly to shell implementation

### Breaking Changes

- The supported interface is now the Python CLI
- Legacy shell scripts and shell-only workflows are no longer supported
- Configuration paths and formats have changed
- The local workflow now assumes a Python environment

## [3.2.0] - 2026-02-26

### Added

- `make quickstart`
- `load_env()` helper
- additional tests

## [3.1.4] - 2026-02-26

### Fixed

- `enabled_providers` whitelist support in generated config
- additional test coverage for generated provider visibility

## [3.1.3] - 2026-02-26

### Added

- Makefile improvements
- Makefile validation in CI
- shell-era fixture and documentation updates

## [3.1.2] - 2026-02-26

### Added

- Expanded `/v1/models` fixtures
- multi-format provider tests
- edge-case hardening and performance tests

## [3.1.1] - 2026-02-26

### Added

- `VERSION` file
- `release.sh`
- initial GitHub Releases workflow
- shell-era version and release targets

## [3.0.0] - 2026-02-26

### Added

- OpenAI-compatible `/v1/models` support
- automatic shell-era config generation
- provider support for multiple compatible backends
- HTTPS enforcement and validation

## [2.5.0] - 2026-02-26

### Added

- `AGENTS.md`
- CI status badge in README
- shell-era agent and smoke test integration

## [2.4.0] - 2026-02-26

### Added

- centralized shell constants in `config.sh`
- shell helper and CI improvements

## [2.3.0] - 2026-02-26

### Security

- shell hardening around secret handling and CIDR validation

### Added

- macOS platform guard
- environment override support
- smoke test coverage for shell security features

## [2.2.0] - 2026-02-24

### Fixed

- safer decrypt flow
- keychain and sandbox guard improvements

### Added

- keychain pre-flight checks
- atomic decrypt safety tests
- shell-era cleanup and security tests

## [2.1.0] - 2026-02-24

### Changed

- consolidated shell test suites
- simplified CI and CIDR blocking
- cleaned up root `SECURITY.md`

### Added

- shell test helpers
- command validation tests
- raw SOPS roundtrip tests

## [2.0.0] - 2026-02-24

### Changed

- MVP rewrite into a smaller shell-based structure
- simplified Makefile and scripts
- preserved core security boundaries

## [1.x] - Pre-MVP

See `feature/enterprise-hardening` for earlier history.
