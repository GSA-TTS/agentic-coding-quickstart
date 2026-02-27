# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Updated dependency versions** — GitHub Actions, Docker Desktop, and CLI tools updated to latest LTS versions as of Feb 2026
  - GitHub Actions: actions/checkout v6.0.2, softprops/action-gh-release v2.5.0
  - CLI tools: SOPS v3.12.1, AGE v1.3.1, jq v1.8.1
- **Added Docker version check** — Warns if Docker Desktop version is older than recommended minimum
- **Updated documentation** — Version numbers included in README and config.sh
- **Improved OpenCode configuration** — Added Authorization header support for better API compatibility
- **Enhanced validation** — Added checks for OpenCode configuration format and content

## [3.2.0] - 2026-02-26

### Added

- **`make quickstart`** — Single command: validates `.env`, discovers models, generates `opencode.jsonc`, encrypts secrets
- **`load_env()` helper** — Auto-sources `.env` file when `OPENAI_COMPAT_*` vars are not in the shell environment; `make models` and `make config` now read from `.env` automatically
- **6 new tests** — `load_env` helper tests (sourcing, env override, comments, missing file) + quickstart guard tests

## [3.1.4] - 2026-02-26

### Fixed

- **`enabled_providers` whitelist** — Generated `opencode.jsonc` now includes `enabled_providers` to show only custom provider models, hiding all 75+ built-in OpenCode providers
- **3 new `enabled_providers` test assertions** — Verified in config generation (section 35), E2E validation (section 48), and full pipeline helper

## [3.1.3] - 2026-02-26

### Added

- **Makefile targets** — `make lint`, `make smoke`, `make unit` for running individual test suites locally
- **Makefile validation in CI** — `make help` and `make version` verified in CI pipeline
- **Makefile smoke tests** — 8 new checks for target existence and wiring
- **sandbox.sh help completeness** — `help` listed as a command in help output
- **README: Model Discovery section** — Documents env-vars → models → config → launch workflow
- **CONTRIBUTING: Model test fixture docs** — How to add/modify test fixtures for model detection
- **AGENTS.md updates** — New Makefile targets, fixture test references in test style section

## [3.1.2] - 2026-02-26

### Added

- **Test fixtures** — Real-world `/v1/models` response fixtures for OpenAI, GSA USAi, vLLM, Ollama, edge cases, and 120-model stress test
- **Multi-format provider tests** — E2E pipeline tests for all 4 provider formats (sections 41-44)
- **Edge case hardening** — Model IDs with slashes, dots, colons, Unicode; empty `owned_by`; long names (section 45)
- **Large model performance test** — 120 models parsed + config generated in <5 seconds (section 46)
- **HTTPS URL validation tests** — 12 edge cases including IPv4, localhost, remote rejection (section 47)
- **E2E JSONC validation** — Full pipeline output validated against OpenCode schema expectations (section 48)
- **Provider name sanitization tests** — Special char stripping, truncation at 50 chars (section 49)

## [3.1.1] - 2026-02-26

### Added

- **`VERSION` file** — Single source of truth for project version (semver)
- **`release.sh`** — Automated release script: version bump, changelog update, git tag
- **GitHub Actions release workflow** — Tag-triggered GitHub Release creation with changelog extraction
- `--version` / `version` command in sandbox.sh
- `make version`, `make release-patch`, `make release-minor`, `make release-major` targets
- Model context/output limits in generated `opencode.jsonc` (from `/v1/models` response)
- `small_model` auto-selection in generated config (picks smallest-context model)
- Release workflow documentation in AGENTS.md and CONTRIBUTING.md
- Backfilled git tags for v2.1.0 through v3.0.0

## [3.0.0] - 2026-02-26

### Added

- **`cmd_models`** — Query OpenAI-compatible `/v1/models` endpoint and list available models
- **`cmd_config`** — Auto-generate `opencode.jsonc` from discovered models with `{env:VAR}` API key references
- OpenAI-compatible API support: GSA USAi, Ollama, vLLM, LiteLLM, any `/v1/models` endpoint
- New `.env` variables: `OPENAI_COMPAT_BASE_URL`, `OPENAI_COMPAT_API_KEY`, `OPENAI_COMPAT_PROVIDER_NAME`
- Config constants: `DEFAULT_OPENCODE_CONFIG`, `MODELS_ENDPOINT_PATH`, `MAX_MODELS_RESPONSE_SIZE`, `MODELS_FETCH_TIMEOUT`
- HTTPS enforcement for non-local API endpoints (security hardening)
- Response size limits for model discovery (1 MB max)
- Model discovery parsing tests (mocked, no network required)
- Config generation validation tests (JSON structure, env var references, model counts)
- Command guard tests (missing URL, missing key, HTTP rejection)
- `opencode.jsonc` / `opencode.json` added to `.gitignore`
- `make models` and `make config` targets in Makefile

## [2.5.0] - 2026-02-26

### Added

- **`AGENTS.md`** — AI agent interaction guidelines (commands, conventions, file roles, prohibited actions)
- CI status badge in README.md
- AGENTS.md content validation in smoke tests
- `NETWORK_POLICY` and `CONFIG_DIR` overridability tests
- AGENTS.md link in README documentation section

### Changed

- CONTRIBUTING.md expanded — test suites, config conventions, test writing guidelines, security rules
- docs/SOPS-SETUP.md references `config.sh` as source of truth for Keychain service name
- `.env.example` model ID updated to non-date-stamped version

## [2.4.0] - 2026-02-26

### Added

- **`config.sh` — centralized constants file** sourced by sandbox.sh and all test suites
  - `DEFAULT_KEYCHAIN_SERVICE`, `DEFAULT_SANDBOX_NAME`, `DEFAULT_ENV_ENC`, etc.
  - `SOPS_FORMAT_FLAGS` — eliminates 7 duplicated `--input-type dotenv --output-type dotenv` strings
  - `PLACEHOLDER_KEY` — single source for the `.sops.yaml` placeholder string
  - `AGE_PRIVATE_KEY_REGEX`, `AGE_PUBLIC_KEY_REGEX` — centralized key format validation
  - `REQUIRED_TOOLS` array with install hints — used by `cmd_setup()` loop
  - `DOCKER_MIN_VERSION`, `REQUIRED_PLATFORM` constants
- `sops_encrypt()` / `sops_decrypt()` helper functions in sandbox.sh — wrap SOPS format flags
- Linux CI job (`ubuntu-latest`) — tests Darwin platform guard rejection on non-macOS
- jq fail-closed integration tests — verifies malformed JSON, empty JSON, missing keys
- config.sh constants integrity test section (validates all config values)
- Sed patch verification in `create_test_sandbox()` — fails fast if patch didn't apply

### Changed

- sandbox.sh sources `config.sh` for all defaults — no more hardcoded literal strings
- `cmd_setup()` uses `REQUIRED_TOOLS` array loop instead of 4 hardcoded `require_cmd` calls
- CIDR count assertions use `>=` thresholds instead of exact `eq` — resilient to policy additions
- All test sed patches use `$DEFAULT_KEYCHAIN_SERVICE` instead of hardcoded `"sops-age-key"`
- AGE key format tests use `$AGE_PRIVATE_KEY_REGEX` / `$AGE_PUBLIC_KEY_REGEX` from config
- Placeholder tests use `$PLACEHOLDER_KEY` from config
- Raw SOPS roundtrip tests use `$SOPS_FORMAT_FLAGS` from config
- ShellCheck CI now checks `config.sh` and uses `-x -e SC1091` for cross-file sourcing

## [2.3.0] - 2026-02-26

### Security

- Replaced `SOPS_AGE_KEY_CMD` eval with direct `SOPS_AGE_KEY` export — eliminates shell injection vector
- Fixed mktemp umask race condition — save/restore umask in parent shell instead of subshell
- Hardened git identity sanitization — allowlist regex via `tr -dc '[:alnum:] ._@-'`
- Pinned GitHub Actions to SHA hashes (actions/checkout, gitleaks) — supply chain hardening
- `jq` CIDR parsing now fails closed — aborts sandbox on parse error instead of silently applying no blocks

### Added

- macOS platform guard — clear error on unsupported platforms
- All config values overridable via environment variables (`SANDBOX_NAME`, `CONFIG_DIR`, `KEYCHAIN_SERVICE`, `ENV_ENC`, `ENV_FILE`, `NETWORK_POLICY`, `SANDBOX_MEMORY`, `SANDBOX_CPUS`)
- Config overridability tests (env var override assertions)
- Smoke tests for platform guard, config override, git sanitization, direct SOPS_AGE_KEY, jq fail-closed
- `jq` added to CI brew install step

### Changed

- `docs/SOPS-SETUP.md` — manual operations now use `SOPS_AGE_KEY` instead of `SOPS_AGE_KEY_CMD`

## [2.2.0] - 2026-02-24

### Fixed

- `cmd_decrypt` now uses atomic write (temp file + mv) — prevents empty `.env` on SOPS failure
- Git identity sanitization strips NUL bytes and quotes values (prevents `=` injection in env files)
- Keychain `-T` flag changed from `-T ""` to `-T /usr/bin/security` (enables headless access)
- `SOPS_AGE_KEY_CMD` variables quoted for usernames with spaces
- CIDR network blocks are now truly fail-closed — abort and remove sandbox if any block fails

### Added

- `check_keychain_access()` pre-flight check with clear error message when Keychain is locked
- EXIT trap cleanup tests (verify temp file deletion on normal and error exits)
- `cmd_clean` graceful degradation test (no Docker required)
- Keychain pre-flight error message test
- Atomic decrypt safety tests (`.env.tmp` not left behind)
- Git identity quoting test (values with `=` are safely quoted)
- NUL byte sanitization test
- Smoke checks for new sandbox.sh security features

### Research

- PIV/CAC x509 evaluated and rejected — AGE+Keychain is sufficient for single-developer local sandbox

## [2.1.0] - 2026-02-24

### Changed

- Consolidated 3 test suites into 2 (merged sops-integration.sh into sandbox-unit.sh)
- Extracted shared test helpers to `test/helpers.sh` (DRY)
- Simplified CI pipeline (removed redundant steps covered by test suites)
- Simplified CIDR network blocking (removed lossy fallback, fail-closed)
- Cleaned up root SECURITY.md (pure pointer, no duplicated content)

### Added

- `check_err()` helper for stderr assertion testing
- cmd_validate tests (placeholder detection, partial failure)
- cmd_run guard tests (missing .env.enc, missing network-policy.json)
- Help text and Makefile target completeness tests
- Error message content assertions
- Git identity sanitization tests
- Raw SOPS encrypt/decrypt roundtrip tests
- Prerequisite checks in unit test suite

### Fixed

- CONTRIBUTING.md: "smoke tests" → "all test suites"

## [2.0.0] - 2026-02-24

### Changed

- **MVP rewrite**: Reduced from 75 files to 18-file structure
- Single `sandbox.sh` replaces `setup.sh` + 12 scripts
- SOPS/AGE replaces 5 credential backends (macOS Keychain storage)
- Network policy blocks 10 CIDRs (6 IPv4 + 4 IPv6) including all major cloud IMDS endpoints
- Simplified Makefile to 8 targets
- 2 test suites running on macOS CI

### Removed

- Federal compliance suite (NIST 800-53, OSCAL, FISMA)
- Enterprise templates (GitLab CI, Docker Compose, CODEOWNERS)
- Multi-profile credential system
- Container image signing (SBOM/cosign)
- Pentest suite

### Preserved

- All v1.x work available on `feature/enterprise-hardening` branch
- Core security: network isolation, resource limits, audit logging
- Docker Desktop sandbox mode integration

## [1.x] - Pre-MVP

See `feature/enterprise-hardening` branch for full history (80 commits).
