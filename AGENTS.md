# AGENTS.md — AI Agent Instructions for agent-sandbox

> This file defines how AI coding agents should interact with this repository.
> It is read by Claude Code, Codex CLI, Gemini CLI, and other agent platforms.

## Mandatory Reading

Before making ANY code changes, agents MUST read and follow:

1. **This file (AGENTS.md)** — Project-specific rules and conventions
2. **[docs/CODING_PRACTICES.md](docs/CODING_PRACTICES.md)** — Secure coding standards (input validation, secrets, testing, architecture)

Violations of CODING_PRACTICES.md will be rejected in code review.

## Project Overview

**agent-sandbox** is a macOS-only tool that runs AI coding agents in isolated Docker Desktop sandboxes with encrypted secrets (SOPS/AGE) and network controls (RFC 1918 + cloud IMDS blocking).

**Stack:** Bash, Docker Desktop sandbox mode, SOPS/AGE, macOS Keychain, jq

## Commands

```bash
# Run all tests (smoke + unit/integration)
make test

# Individual test suites
make smoke                   # File structure, shellcheck, config validation
make unit                    # Unit + integration tests requiring macOS + sops/age
make lint                    # ShellCheck on all shell scripts

# Validate environment
make validate

# Quickstart (validates .env, discovers models, generates config, encrypts)
make quickstart              # All-in-one: .env → models → config → encrypt

# Model discovery (requires OPENAI_COMPAT_BASE_URL + OPENAI_COMPAT_API_KEY in .env)
make models                  # List models from OpenAI-compatible API
make config                  # Generate opencode.json from discovered models

# Version + release
make version                 # Print current version
make release-patch           # Bump patch (x.y.Z+1), update CHANGELOG, tag
make release-minor           # Bump minor (x.Y+1.0), update CHANGELOG, tag
make release-major           # Bump major (X+1.0.0), update CHANGELOG, tag

# Show available commands
make help
```

## Architecture

```
VERSION                  # Semver version (single source of truth). Read by sandbox.sh + release.sh.
config.sh               # Centralized constants (readonly). Single source of truth.
sandbox.sh              # Main script — sources config.sh, implements all subcommands.
release.sh              # Release automation — version bump, changelog update, git tag.
test/helpers.sh          # Shared test functions (check, check_err, summary). Sources config.sh.
test/smoke.sh            # Fast validation: file structure, shellcheck, config checks.
test/sandbox-unit.sh     # Thorough tests: encrypt/decrypt roundtrips, guards, edge cases.
test/fixtures/           # /v1/models API response fixtures (OpenAI, USAi, vLLM, Ollama, edge cases).
network-policy.json      # CIDR block rules applied via docker sandbox network proxy.
.sops.yaml               # AGE public key for SOPS encryption (placeholder until setup).
.env.example             # Template for API keys.
Makefile                 # User-facing commands (delegates to sandbox.sh + release.sh).
```

### Documentation

```
docs/QUICKSTART.md       # Step-by-step first-use guide
docs/SECURITY.md         # Full threat model, network policy, audit logging, secret lifecycle
docs/SOPS-SETUP.md       # SOPS/AGE key management, manual operations, team sharing, rotation
docs/CODING_PRACTICES.md # Secure coding standards — MUST READ before any code changes
```

## Conventions

### Config Constants

All shared constants live in `config.sh`. This file is sourced by `sandbox.sh` and all test suites (via `test/helpers.sh`).

- **Defaults** are `readonly` variables prefixed with `DEFAULT_` (e.g., `DEFAULT_SANDBOX_NAME`)
- **Runtime values** in `sandbox.sh` use `${VAR:-$DEFAULT_VAR}` for environment overridability
- **Non-overridable constants** have no `DEFAULT_` prefix (e.g., `PLACEHOLDER_KEY`, `SOPS_FORMAT_FLAGS`)
- Never hardcode values that exist in `config.sh` — always reference the constant

### Shell Style

- `set -euo pipefail` at the top of every script
- ShellCheck clean (`shellcheck -x -e SC1091` for cross-file sourcing)
- `SC2086` disabled only for intentional word splitting on `$SOPS_FORMAT_FLAGS`
- `SC2034` disabled in `config.sh` (variables used by sourcing scripts)
- Functions: `cmd_*` for subcommands, lowercase with underscores
- Logging: `log "message"` for info, `err "message"` for fatal errors (exits 1)
- Audit: `audit "action" "detail"` — all user-facing operations must log

### Test Style

- Use `check "description" command args...` from `test/helpers.sh`
- Use `check_err "description" "expected_pattern" command args...` for stderr assertions
- Group tests into numbered sections with descriptive headers
- Use environment variable overrides instead of sed patching (e.g., `KEYCHAIN_SERVICE=test-val bash sandbox.sh decrypt`)
- Copy `config.sh` alongside `sandbox.sh` when testing in temp directories
- Use `>=` thresholds for count assertions (resilient to additions)
- Clean up temp files in trap handlers
- Model detection tests use fixtures in `test/fixtures/` with `run_model_pipeline()`, `run_small_model_selection()`, and `run_full_config_pipeline()` helpers (sections 41-49)

## File Roles

| File | Role | Agent May Modify? |
|------|------|-------------------|
| `config.sh` | Centralized constants | Yes — add new constants here, never elsewhere |
| `sandbox.sh` | Main script | Yes — all subcommands live here |
| `test/helpers.sh` | Shared test utilities | Yes — add new helpers here |
| `test/smoke.sh` | Fast structural tests | Yes — add checks for new files/patterns |
| `test/sandbox-unit.sh` | Thorough unit/integration tests | Yes — add tests for new functionality |
| `network-policy.json` | Network isolation rules | Yes — add CIDRs, update docs/SECURITY.md to match |
| `VERSION` | Semver version file | Yes — via `release.sh` only (never edit manually) |
| `release.sh` | Release automation | Yes — version bump, changelog, tag |
| `opencode.json` | OpenCode config (generated) | No — generated by `make config` from API models |
| `.sops.yaml` | SOPS config (placeholder) | No — generated by `make setup` |
| `.env` / `.env.enc` | Secrets | Never — gitignored, contains real API keys |
| `.github/workflows/ci.yml` | CI pipeline | Yes — keep SHA-pinned actions |
| `.github/workflows/release.yml` | Release workflow | Yes — keep SHA-pinned actions |

## Prohibited Actions

1. **Never commit secrets** — `.env`, `.env.enc`, `*.key`, `*.pem` are gitignored
2. **Never remove the platform guard** — macOS Keychain dependency is by design
3. **Never use `eval` or `SOPS_AGE_KEY_CMD`** — direct `SOPS_AGE_KEY` export only (security hardening)
4. **Never hardcode constants** that exist in `config.sh`
5. **Never use sed patching in tests** — use environment variable overrides
6. **Never skip shellcheck** — all `.sh` files must pass
7. **Never unpin GitHub Actions** — use SHA hashes, not version tags

## Releasing

```bash
# 1. Ensure working tree is clean (all changes committed)
# 2. Run release script (bumps VERSION, updates CHANGELOG, commits, tags)
make release-patch   # or release-minor / release-major

# 3. Push commit + tag (triggers GitHub Actions release workflow)
git push origin main --tags
```

The release workflow (`.github/workflows/release.yml`) automatically creates a GitHub Release with changelog notes extracted from `CHANGELOG.md`.

**Version source of truth:** `VERSION` file (plain text, e.g., `3.1.0`). Read by `sandbox.sh --version` and `release.sh`.

**Changelog format:** [Keep a Changelog](https://keepachangelog.com/). Add entries under `## [Unreleased]`. Release script moves them to a versioned section.

## Adding New Features

1. Add constants to `config.sh` if the value is shared across files
2. Implement in `sandbox.sh` (add `cmd_*` function, wire into `case` statement)
3. Add smoke test in `test/smoke.sh` (file existence, grep pattern)
4. Add unit tests in `test/sandbox-unit.sh` (numbered section, happy path + error cases)
5. Update `Makefile` if adding a new user-facing command
6. Update `README.md` commands table
7. Update `docs/` if the feature affects security model or setup

## Security Boundaries

- **Secrets** are encrypted at rest (SOPS/AGE), decrypted to temp files (mode 600), auto-cleaned on exit
- **Network** blocks RFC 1918, link-local, and cloud IMDS endpoints (see `network-policy.json`)
- **Keychain** access requires an active macOS session — fails closed if locked
- **Audit log** at `~/.config/agent-sandbox/audit.log` records all operations
- Security changes require review from @cloud-gov
