REPO ?= .

.DEFAULT_GOAL := help

.PHONY: quickstart setup run validate clean encrypt decrypt models config test smoke unit lint version release-patch release-minor release-major reset-keys help

quickstart:     ## Validate .env, discover models, generate config, encrypt (all-in-one)
	@./sandbox.sh quickstart

setup:          ## Install prerequisites, generate AGE key, create .sops.yaml
	@./sandbox.sh setup

run:            ## Launch OpenCode in Docker sandbox with secrets (REPO=path)
	@./sandbox.sh run "$(REPO)"

validate:       ## Check all prerequisites are configured
	@./sandbox.sh validate

clean:          ## Stop and remove the sandbox
	@./sandbox.sh clean

encrypt:        ## Encrypt .env → .env.enc
	@./sandbox.sh encrypt

decrypt:        ## Decrypt .env.enc → .env for editing
	@./sandbox.sh decrypt

reset-keys:     ## Reset AGE keys and re-encrypt .env (fixes key sync issues)
	@./reset-keys.sh

models:         ## List available models from OpenAI-compatible API
	@./sandbox.sh models

config:         ## Generate opencode.jsonc from discovered API models
	@./sandbox.sh config

test:           ## Run all test suites (requires sops, age, Keychain on macOS)
	@bash test/smoke.sh
	@bash test/sandbox-unit.sh

smoke:          ## Run smoke tests only (file structure, shellcheck, config validation)
	@bash test/smoke.sh

unit:           ## Run unit + integration tests only (requires macOS + sops/age)
	@bash test/sandbox-unit.sh

lint:           ## Run ShellCheck on all shell scripts
	@shellcheck config.sh sandbox.sh release.sh
	@shellcheck -x -e SC1091 test/helpers.sh test/smoke.sh test/sandbox-unit.sh
	@echo "All files pass ShellCheck"

version:        ## Print current version
	@./sandbox.sh version

release-patch:  ## Release patch version (x.y.Z+1)
	@./release.sh patch

release-minor:  ## Release minor version (x.Y+1.0)
	@./release.sh minor

release-major:  ## Release major version (X+1.0.0)
	@./release.sh major

help:           ## Show this help
	@echo "agent-sandbox — Run AI coding agents in isolated Docker sandboxes"
	@echo ""
	@echo "Getting Started:"
	@echo "  make setup                Install prerequisites, generate AGE key"
	@echo "  vim .env                  Add your API keys and provider settings"
	@echo "  make quickstart           Discover models, generate config, encrypt (all-in-one)"
	@echo "  make run REPO=~/project   Launch sandbox with your project"
	@echo ""
	@echo "Commands:"
	@grep -E '^[a-z][-a-z]*:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make setup                          # First-time setup"
	@echo "  make quickstart                     # Validate, discover models, config, encrypt"
	@echo "  make run REPO=~/my-project          # Launch sandbox"
	@echo "  make models                         # List available models from API"
	@echo "  make config                         # Regenerate opencode.jsonc"
	@echo "  make decrypt                        # Edit encrypted secrets"
	@echo "  make encrypt                        # Re-encrypt after editing"
	@echo "  make reset-keys                    # Reset AGE keys and fix sync issues"
	@echo "  make test                           # Run full test suite"
	@echo "  make lint                           # ShellCheck all scripts"
	@echo "  make release-patch                  # Cut a patch release"
	@echo ""
	@echo "Environment (.env):"
	@echo "  OPENAI_COMPAT_BASE_URL    API endpoint (e.g., https://api.gsa.usai.gov/api/v1)"
	@echo "  OPENAI_COMPAT_API_KEY     API key for the provider"
	@echo "  OPENAI_COMPAT_PROVIDER_NAME  Provider display name (default: custom-api)"
	@echo ""
	@echo "Docs: https://github.com/cloud-gov/agent-sandbox"
