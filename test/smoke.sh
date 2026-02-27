#!/usr/bin/env bash
# smoke.sh — Lightweight validation tests (no Docker required)
# Usage: ./test/smoke.sh
set -euo pipefail

# shellcheck source=test/helpers.sh
source "$(dirname "$0")/helpers.sh"

echo "=== Agent Sandbox Smoke Tests ==="
echo ""

# File structure (all committed files)
echo "File structure:"
check "sandbox.sh exists" test -f sandbox.sh
check "sandbox.sh is executable" test -x sandbox.sh
check "Makefile exists" test -f Makefile
check "network-policy.json exists" test -f network-policy.json
check ".sops.yaml exists" test -f .sops.yaml
check ".env.example exists" test -f .env.example
check ".gitignore exists" test -f .gitignore
check "README.md exists" test -f README.md
check "CHANGELOG.md exists" test -f CHANGELOG.md
check "CONTRIBUTING.md exists" test -f CONTRIBUTING.md
check "LICENSE exists" test -f LICENSE
check "SECURITY.md exists" test -f SECURITY.md
check "AGENTS.md exists" test -f AGENTS.md
check "docs/QUICKSTART.md exists" test -f docs/QUICKSTART.md
check "docs/SOPS-SETUP.md exists" test -f docs/SOPS-SETUP.md
check "docs/SECURITY.md exists" test -f docs/SECURITY.md
check "config.sh exists" test -f config.sh
check "test/helpers.sh exists" test -f test/helpers.sh
check "test/smoke.sh exists" test -f test/smoke.sh
check "test/sandbox-unit.sh exists" test -f test/sandbox-unit.sh
check ".github/workflows/ci.yml exists" test -f .github/workflows/ci.yml
check ".github/workflows/release.yml exists" test -f .github/workflows/release.yml
check ".gitleaks.toml exists" test -f .gitleaks.toml
check "VERSION exists" test -f VERSION
check "release.sh exists" test -f release.sh
check "release.sh is executable" test -x release.sh
check "test/fixtures/ exists" test -d test/fixtures
check "openai fixture exists" test -f test/fixtures/openai-models.json
check "usai fixture exists" test -f test/fixtures/usai-models.json
check "vllm fixture exists" test -f test/fixtures/vllm-models.json
check "ollama fixture exists" test -f test/fixtures/ollama-models.json
check "edge-case fixture exists" test -f test/fixtures/edge-case-models.json
check "large fixture exists" test -f test/fixtures/large-models.json
echo ""

# ShellCheck
echo "Static analysis:"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck config.sh passes" shellcheck config.sh
    check "shellcheck sandbox.sh passes" shellcheck -x sandbox.sh
    check "shellcheck release.sh passes" shellcheck release.sh
    check "shellcheck test/helpers.sh passes" shellcheck -x -e SC1091 test/helpers.sh
    check "shellcheck test/smoke.sh passes" shellcheck -x -e SC1091 test/smoke.sh
    check "shellcheck test/sandbox-unit.sh passes" shellcheck -x -e SC1091 test/sandbox-unit.sh
else
    printf "  SKIP: shellcheck not installed\n"
fi
echo ""

# JSON validation
echo "Config validation:"
if command -v jq >/dev/null 2>&1; then
    check "network-policy.json is valid JSON" jq empty network-policy.json
    check "network-policy.json has blockCidrs" jq -e '.blockCidrs | length > 0' network-policy.json
    check "network-policy.json blocks RFC 1918" jq -e '.blockCidrs | index("10.0.0.0/8")' network-policy.json
    check "network-policy.json blocks link-local" jq -e '.blockCidrs | index("169.254.0.0/16")' network-policy.json
    check "network-policy.json has IPv6 blocks" jq -e '.blockCidrsIpv6 | length > 0' network-policy.json
    # Validate all test fixtures are valid JSON
    check "fixture: openai-models.json valid" jq empty test/fixtures/openai-models.json
    check "fixture: usai-models.json valid" jq empty test/fixtures/usai-models.json
    check "fixture: vllm-models.json valid" jq empty test/fixtures/vllm-models.json
    check "fixture: ollama-models.json valid" jq empty test/fixtures/ollama-models.json
    check "fixture: edge-case-models.json valid" jq empty test/fixtures/edge-case-models.json
    check "fixture: large-models.json valid" jq empty test/fixtures/large-models.json
    check "fixture: all have data array" bash -c "for f in test/fixtures/*.json; do jq -e '.data | type == \"array\"' \"\$f\" >/dev/null || exit 1; done"
else
    printf "  SKIP: jq not installed\n"
fi
echo ""

# .gitignore security entries
echo "Gitignore security:"
check ".gitignore blocks .env" grep -q "^\.env$" .gitignore
check ".gitignore blocks .env.enc" grep -q "^\.env\.enc$" .gitignore
check ".gitignore blocks *.key" grep -q "^\*\.key$" .gitignore
check ".gitignore blocks *.pem" grep -q "^\*\.pem$" .gitignore
check ".gitignore blocks opencode.jsonc" grep -q "opencode.jsonc" .gitignore
echo ""

# YAML validation
echo "SOPS config:"
check ".sops.yaml mentions age" grep -q "age:" .sops.yaml
echo ""

# sandbox.sh function checks
echo "Code quality:"
check "sandbox.sh has check_keychain_access" grep -q "check_keychain_access" sandbox.sh
check "sandbox.sh uses atomic decrypt" grep -q "ENV_FILE}.tmp" sandbox.sh
check "sandbox.sh quotes git identity" grep -q 'printf.*GIT_AUTHOR_NAME' sandbox.sh
check "sandbox.sh fails closed on CIDR" grep -q "fail_count" sandbox.sh
check "sandbox.sh has platform guard" grep -q 'REQUIRED_PLATFORM' sandbox.sh
check "sandbox.sh sources config.sh" grep -q 'source.*config.sh' sandbox.sh
check "sandbox.sh config is overridable" grep -q 'DEFAULT_SANDBOX_NAME' sandbox.sh
check "sandbox.sh sanitizes git identity" grep -q "tr -dc" sandbox.sh
check "sandbox.sh uses direct SOPS_AGE_KEY (not _CMD)" bash -c "grep -q 'export SOPS_AGE_KEY' sandbox.sh && ! grep -q 'SOPS_AGE_KEY_CMD' sandbox.sh"
check "sandbox.sh uses sops wrappers" grep -q "sops_encrypt\|sops_decrypt" sandbox.sh
check "config.sh exists" test -f config.sh
check "config.sh has PLACEHOLDER_KEY" grep -q "PLACEHOLDER_KEY" config.sh
check "config.sh has REQUIRED_TOOLS" grep -q "REQUIRED_TOOLS" config.sh
check "config.sh has MODELS_ENDPOINT_PATH" grep -q "MODELS_ENDPOINT_PATH" config.sh
check "config.sh has DEFAULT_OPENCODE_CONFIG" grep -q "DEFAULT_OPENCODE_CONFIG" config.sh
check "sandbox.sh has cmd_models" grep -q "cmd_models" sandbox.sh
check "sandbox.sh has cmd_config" grep -q "cmd_config" sandbox.sh
check "sandbox.sh has cmd_quickstart" grep -q "cmd_quickstart" sandbox.sh
check "sandbox.sh has load_env helper" grep -q "load_env" sandbox.sh
check "sandbox.sh validates HTTPS" grep -q "must use HTTPS" sandbox.sh
check "AGENTS.md references config.sh" grep -q "config.sh" AGENTS.md
check "AGENTS.md references sandbox.sh" grep -q "sandbox.sh" AGENTS.md
check "AGENTS.md references release.sh" grep -q "release.sh" AGENTS.md
check "AGENTS.md has prohibited actions" grep -q "Prohibited" AGENTS.md
check "AGENTS.md has releasing section" grep -q "Releasing" AGENTS.md
check "sandbox.sh has version command" grep -q "version" sandbox.sh
check "sandbox.sh reads VERSION file" grep -q "VERSION" sandbox.sh
check "release.sh validates semver" grep -q "semver" release.sh
check "release.sh creates annotated tags" grep -q "tag -a" release.sh
check "release.sh updates CHANGELOG" grep -q "CHANGELOG" release.sh
check "release workflow is SHA-pinned" grep -q "@" .github/workflows/release.yml
echo ""

# Version checks
echo "Version:"
check "VERSION is valid semver" bash -c "grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' VERSION"
check "release.sh current shows version" bash -c "./release.sh current | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'"
echo ""

# sandbox.sh --help
echo "CLI:"
check "sandbox.sh help runs" bash sandbox.sh help
check "help mentions models command" bash -c "bash sandbox.sh help 2>&1 | grep -q 'models'"
check "help mentions config command" bash -c "bash sandbox.sh help 2>&1 | grep -q 'config'"
check "help mentions version command" bash -c "bash sandbox.sh help 2>&1 | grep -q 'version'"
check "help mentions help command" bash -c "bash sandbox.sh help 2>&1 | grep -q 'help'"
check "help mentions quickstart command" bash -c "bash sandbox.sh help 2>&1 | grep -q 'quickstart'"
echo ""

# Makefile targets
echo "Makefile:"
check "make help works" make help
check "make help shows getting started" bash -c "make help 2>&1 | grep -q 'Getting Started:'"
check "make help shows examples" bash -c "make help 2>&1 | grep -q 'Examples:'"
check "make help shows env vars" bash -c "make help 2>&1 | grep -q 'OPENAI_COMPAT_BASE_URL'"
check "default make shows help" bash -c "make 2>&1 | grep -q 'agent-sandbox'"
check "make version works" make version
check "Makefile has lint target" grep -q "^lint:" Makefile
check "Makefile has smoke target" grep -q "^smoke:" Makefile
check "Makefile has unit target" grep -q "^unit:" Makefile
check "Makefile has models target" grep -q "^models:" Makefile
check "Makefile has config target" grep -q "^config:" Makefile
check "Makefile has quickstart target" grep -q "^quickstart:" Makefile
check "Makefile has release targets" grep -q "^release-patch:" Makefile
echo ""

# Summary
summary
