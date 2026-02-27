# Contributing

## Quick Start

```bash
git clone https://github.com/cloud-gov/agent-sandbox.git
cd agent-sandbox
make setup
```

## Development

1. Fork and create a feature branch
2. Make changes to `sandbox.sh` or supporting files
3. Run `make test` (all test suites) and `make validate` (prerequisites check)
4. Manual test with `make run` if Docker Desktop is available
5. Submit a PR against `main`

## Running Tests

```bash
# Full suite (smoke + unit/integration)
make test

# Individual suites
make smoke    # Fast: file structure, shellcheck, config validation
make unit     # Thorough: encrypt/decrypt roundtrips, guards, edge cases
make lint     # ShellCheck on all shell scripts
```

**Requirements:** macOS, sops, age, jq, shellcheck (all test suites require macOS Keychain).

## Config Conventions

All shared constants live in `config.sh`:

- **Defaults**: `readonly DEFAULT_*="value"` — overridable via environment
- **Constants**: `readonly NAME="value"` — not overridable
- **Usage in sandbox.sh**: `VAR="${VAR:-$DEFAULT_VAR}"`
- **Usage in tests**: `VAR=override bash sandbox.sh command` (never sed patching)

When adding a new constant, add it to `config.sh` and reference it everywhere. Never hardcode values that belong in config.

## Writing Tests

Tests use `check` and `check_err` from `test/helpers.sh`:

```bash
# Basic pass/fail assertion
check "description" command args...

# Assert stderr contains a pattern
check_err "description" "expected_pattern" command args...
```

Guidelines:
- Group tests into numbered sections with `echo "Section name:"`
- Test happy path, error cases, and edge cases
- Use environment overrides: `ENV_FILE=custom.env bash sandbox.sh encrypt`
- Copy `config.sh` alongside `sandbox.sh` when testing in temp directories
- Use `>=` thresholds for count assertions (resilient to additions)
- Clean up temp files in trap handlers

## Model Detection Test Fixtures

Test fixtures for the model discovery pipeline live in `test/fixtures/`. Each fixture is a JSON file matching the OpenAI `/v1/models` response format:

```json
{
  "object": "list",
  "data": [
    {
      "id": "model-name",
      "object": "model",
      "created": 1718841600,
      "owned_by": "provider-name",
      "context_length": 128000,
      "max_output_tokens": 16384
    }
  ]
}
```

**Current fixtures:**

| File | Provider Format | Models | Tests |
|------|----------------|--------|-------|
| `openai-models.json` | Standard OpenAI (no limits) | 3 | Section 41 |
| `usai-models.json` | GSA USAi (`context_length` + `max_output_tokens`) | 4 | Section 42 |
| `vllm-models.json` | vLLM (`max_model_len`) | 2 | Section 43 |
| `ollama-models.json` | Ollama (minimal fields, colons in IDs) | 2 | Section 44 |
| `edge-case-models.json` | Edge cases (slashes, dots, Unicode, long names) | 4 | Section 45 |
| `large-models.json` | Performance test (120 models) | 120 | Section 46 |

**Adding a new fixture:**

1. Create `test/fixtures/<name>-models.json` with the response format above
2. Add a validation check in `test/smoke.sh` (fixture existence + valid JSON)
3. Add a numbered test section in `test/sandbox-unit.sh` using `run_model_pipeline()` and `run_full_config_pipeline()` helpers
4. Test the three pipeline stages: model parsing, small_model selection, config generation

**Key fields by provider:**

- `context_length` — OpenAI/USAi: context window size
- `max_output_tokens` — USAi: max output tokens
- `max_model_len` — vLLM: maps to `limit.context` in config
- If no limit fields exist, models are included without `limit` in the generated config

## Versioning and Releases

This project uses [Semantic Versioning](https://semver.org/). The version is stored in a `VERSION` file at the repo root.

```bash
# Check current version
make version

# Cut a release (bumps VERSION, updates CHANGELOG.md, creates git tag)
make release-patch   # 3.1.0 → 3.1.1
make release-minor   # 3.1.0 → 3.2.0
make release-major   # 3.1.0 → 4.0.0

# Push to trigger GitHub Release
git push origin main --tags
```

**Changelog workflow:**
1. Add entries under `## [Unreleased]` in `CHANGELOG.md` as you work
2. When ready to release, run `make release-{patch|minor|major}`
3. The release script moves `[Unreleased]` content to a versioned section
4. Push the tag to trigger the GitHub Actions release workflow

**When to bump:**
- **patch**: Bug fixes, test improvements, doc updates
- **minor**: New features, new commands, new config constants
- **major**: Breaking changes (command renames, config format changes, removed features)

## Security

- Security changes require review from @wz-gsa
- Never commit secrets (`.env`, `*.key`, `*.pem`)
- Never use `eval` or `SOPS_AGE_KEY_CMD` — direct export only
- All GitHub Actions must be SHA-pinned

## Guidelines

- Follow [conventional commits](https://www.conventionalcommits.org/)
- Test on macOS (primary target)
- Run shellcheck on all `.sh` files before submitting
- See [AGENTS.md](AGENTS.md) for full conventions and file roles
