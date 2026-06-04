# Agentic Coding Quickstart - Makefile
# Simple commands for setting up and managing your AI-assisted development workspace

CODEX_MODEL ?= gpt-5.4-latest-guardrails-defaultv2
CODEX_BASE_URL ?= https://api.gsa.usai.gov/api/v1

.PHONY: setup doctor new-project clean install-hooks help init-project run-agent run-codex

# Default target
help:
	@echo "Agentic Coding Quickstart"
	@echo "========================="
	@echo ""
	@echo "Commands:"
	@echo "  make setup                 - Set up your workspace (clone playbook, check dependencies, save USAI_API_KEY to SBX)"
	@echo "  make doctor                - Run health checks on your environment"
	@echo "  make new-project           - Create a new project directory (interactive)"
	@echo "  make init-project TARGET_DIR=/path - Bootstrap a project directory (non-interactive)"
	@echo "  make run-agent             - Run OpenCode agent in SBX"
	@echo "  make run-codex             - Run Codex (OpenAI) agent in SBX"
	@echo "  make install-hooks         - [OPTIONAL] Install pre-commit hooks"
	@echo "  make clean                 - Remove generated files"
	@echo ""
	@echo "First time? Run: make setup"

# Set up the workspace
setup: _check-git _check-sbx _check-usai-key _clone-playbook
	@echo ""
	@echo "Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure your credentials (see docs/QUICKSTART_SBX.md)"
	@echo "  2. Start your AI agent"
	@echo "  3. Ask it to help you build something"
	@echo ""

_check-git:
	@echo "Checking Git..."
	@command -v git >/dev/null 2>&1 || { echo "ERROR: Git not found. Install Git first."; exit 1; }
	@echo "  Git: OK"

_check-sbx:
	@echo "Checking SBX..."
	@command -v sbx >/dev/null 2>&1 || { echo "ERROR: SBX not found. Install SBX first."; exit 1; }
	@# Verify sbx is accessible (catches auth/daemon issues)
	@sbx secret ls >/dev/null 2>&1 || { \
		echo "ERROR: Cannot access SBX. Common fixes:"; \
		echo "  - Run: sbx login"; \
		echo "  - Run: sbx diagnose"; \
		exit 1; \
	}
	@echo "  SBX: OK"

_check-usai-key:
	@echo "Checking USAI_API_KEY secret in SBX..."
	@if sbx secret ls 2>/dev/null | grep -q "USAI_API_KEY"; then \
		echo "  USAI_API_KEY: OK"; \
	else \
		echo "  USAI_API_KEY not found in SBX secrets."; \
		read -s -p "Paste USAI_API_KEY value here: " key; \
		echo ""; \
		if [ -n "$$key" ]; then \
			USAI_KEY="$$key" sh -c 'sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$$USAI_KEY"' || { \
				echo "ERROR: Failed to store USAI_API_KEY in SBX secrets."; \
				echo "  Check that SBX is running and you have permissions."; \
				exit 1; \
			}; \
			echo "  USAI_API_KEY: Stored in SBX secrets"; \
		else \
			echo ""; \
			echo "ERROR: USAI_API_KEY is required. Get your key at:"; \
			echo "  https://console.gsa.usai.gov/key-management"; \
			exit 1; \
		fi; \
	fi

_clone-playbook:
	@echo "Checking for playbook..."
	@if [ -d "../agentic-coding-playbook" ]; then \
		echo "  Playbook: already exists"; \
	else \
		echo "  Cloning playbook..."; \
		git clone https://github.com/GSA-TTS/agentic-coding-playbook.git ../agentic-coding-playbook || { \
			echo "ERROR: Failed to clone playbook. Check your network connection."; \
			exit 1; \
		}; \
		echo "  Playbook: cloned"; \
	fi

# Run health checks
doctor:
	@echo "Running health checks..."
	@echo ""
	@echo "Environment"
	@echo "-----------"
	@command -v git >/dev/null 2>&1 && echo "[OK] Git installed" || echo "[FAIL] Git not found"
	@command -v sbx >/dev/null 2>&1 && echo "[OK] SBX installed" || echo "[FAIL] SBX not found"
	@if sbx secret ls 2>/dev/null | grep -q "USAI_API_KEY"; then \
		echo "[OK] USAI_API_KEY secret set in SBX"; \
	else \
		echo "[FAIL] USAI_API_KEY secret not found in SBX"; \
	fi
	@echo ""
	@echo "Workspace"
	@echo "---------"
	@test -d "../agentic-coding-playbook" && echo "[OK] Playbook found" || echo "[FAIL] Playbook not found (run: make setup)"
	@test -f "../agentic-coding-playbook/AGENTS.md" && echo "[OK] Playbook AGENTS.md exists" || echo "[WARN] Playbook AGENTS.md missing"
	@test -d "../agentic-coding-playbook/skills" && echo "[OK] Skills directory found" || echo "[WARN] Skills directory missing"
	@echo ""
	@echo "Run 'make setup' to fix any issues."

# Create a new project (interactive)
new-project:
	@echo "Create a new project"
	@echo "--------------------"
	@read -p "Project name (lowercase, hyphens ok): " name; \
	if [ -z "$$name" ]; then \
		echo "ERROR: Project name required"; \
		exit 1; \
	fi; \
	$(MAKE) init-project TARGET_DIR="../$$name"

# Initialize a new project from the quickstart (non-interactive)
init-project: _check-target-dir _clone-playbook
	@echo "Initializing project in $(TARGET_DIR)..."
	@# Verify required source files exist before copying
	@test -f ../agentic-coding-playbook/AGENTS.md || { \
		echo "ERROR: Playbook AGENTS.md not found."; \
		echo "  Run 'make setup' or check ../agentic-coding-playbook exists."; \
		exit 1; \
	}
	@test -f templates/AGENTS_SBX_ADDENDUM.md || { \
		echo "ERROR: templates/AGENTS_SBX_ADDENDUM.md not found."; \
		exit 1; \
	}
	@test -f templates/opencode.jsonc || { \
		echo "ERROR: templates/opencode.jsonc not found."; \
		exit 1; \
	}
	@test -f templates/SBX_PATTERNS.md || { \
		echo "ERROR: templates/SBX_PATTERNS.md not found."; \
		exit 1; \
	}
	@echo "Copying configuration files..."
	@cp ../agentic-coding-playbook/AGENTS.md "$(TARGET_DIR)/" && echo "  [OK] AGENTS.md"
	@tail -n +7 templates/AGENTS_SBX_ADDENDUM.md >> "$(TARGET_DIR)/AGENTS.md" && echo "  [OK] AGENTS.md (SBX addendum appended)"
	@cp templates/opencode.jsonc "$(TARGET_DIR)/" && echo "  [OK] opencode.jsonc"
	@cp Makefile "$(TARGET_DIR)/" && echo "  [OK] Makefile"

	@# Only create README if it doesn't exist
	@if [ ! -f "$(TARGET_DIR)/README.md" ]; then \
		echo "# $$(basename "$(TARGET_DIR)")" > "$(TARGET_DIR)/README.md"; \
		echo "" >> "$(TARGET_DIR)/README.md"; \
		echo "Project initialized from agentic-coding-quickstart." >> "$(TARGET_DIR)/README.md"; \
		echo "" >> "$(TARGET_DIR)/README.md"; \
		echo "Next: run 'make setup' inside your new project directory." >> "$(TARGET_DIR)/README.md"; \
		echo "  [OK] README.md (created)"; \
	else \
		echo "  [SKIP] README.md (already exists)"; \
	fi

	@# Create .zed directory and copy tasks.json
	@mkdir -p "$(TARGET_DIR)/.zed"
	@cp templates/zed-tasks.json "$(TARGET_DIR)/.zed/tasks.json" && echo "  [OK] .zed/tasks.json"

	@# Create docs directory and copy SBX_PATTERNS.md
	@mkdir -p "$(TARGET_DIR)/docs"
	@cp templates/SBX_PATTERNS.md "$(TARGET_DIR)/docs/SBX_PATTERNS.md" && echo "  [OK] docs/SBX_PATTERNS.md"

	@# Only run git init if it's not already a git repository
	@if [ ! -d "$(TARGET_DIR)/.git" ]; then \
		git init "$(TARGET_DIR)" > /dev/null 2>&1; \
		echo "  [OK] Git repository initialized"; \
	else \
		echo "  [SKIP] Git repository (already exists)"; \
	fi
	@echo ""
	@echo "[OK] Project initialized in $(TARGET_DIR)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. cd $(TARGET_DIR)"
	@echo "  2. make setup"

_check-target-dir:
	@if [ -z "$(TARGET_DIR)" ]; then \
		echo "ERROR: TARGET_DIR is not set. Usage: make init-project TARGET_DIR=/path/to/project"; \
		exit 1; \
	fi
	@if [ -d "$(TARGET_DIR)" ]; then \
		echo "--> Provisioning existing directory: $(TARGET_DIR)"; \
	else \
		echo "--> Creating new directory: $(TARGET_DIR)"; \
		mkdir -p "$(TARGET_DIR)"; \
	fi

# Clean up
clean:
	@echo "Nothing to clean (this repo doesn't generate files)"

# Run OpenCode agent in sandbox with default name
run-agent: _check-usai-key
	@echo "Running OpenCode agent in SBX sandbox..."
	@sbx run opencode .

# Run Codex (OpenAI) agent in sandbox
# openai_base_url redirects the built-in openai provider to USAi.
# Passed via -c CLI override (bypasses project config restrictions).
run-codex: _check-codex-keys
	@echo "Running Codex agent in SBX sandbox with model $(CODEX_MODEL)..."
	@sbx run codex . -- \
		-c 'openai_base_url="$(CODEX_BASE_URL)"' \
		-m "$(CODEX_MODEL)"

# Check Codex-specific secrets (only OPENAI_API_KEY needed; base URL is
# configured via -c flags at runtime, not via env vars or SBX secrets).
_check-codex-keys:
	@echo "Checking Codex secrets in SBX..."
	@# Check OPENAI_API_KEY (used by Codex as the auth credential via env_key)
	@if sbx secret ls 2>/dev/null | grep -q "OPENAI_API_KEY"; then \
		echo "  OPENAI_API_KEY: OK"; \
	else \
		echo "  OPENAI_API_KEY not found in SBX secrets."; \
		echo "  Codex requires OPENAI_API_KEY mapped to your USAi key."; \
		read -s -p "Paste USAI_API_KEY value (will be stored as OPENAI_API_KEY): " key; \
		echo ""; \
		if [ -n "$$key" ]; then \
			USAI_KEY="$$key" sh -c 'sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_API_KEY --value "$$USAI_KEY"' || { \
				echo "ERROR: Failed to store OPENAI_API_KEY in SBX secrets."; \
				exit 1; \
			}; \
			echo "  OPENAI_API_KEY: Stored in SBX secrets"; \
		else \
			echo ""; \
			echo "ERROR: OPENAI_API_KEY is required for Codex. Get your USAi key at:"; \
			echo "  https://console.gsa.usai.gov/key-management"; \
			exit 1; \
		fi; \
	fi
	@echo ""
	@echo "NOTE: If you just set a new OPENAI_API_KEY secret, recreate any existing Codex sandbox:"
	@echo "  sbx rm <sandbox-name> && make run-codex"
	@echo ""

# Install pre-commit hooks (optional)
install-hooks:  ## [OPTIONAL] Install pre-commit hooks
	@command -v pre-commit >/dev/null 2>&1 || { \
		echo "ERROR: pre-commit not installed."; \
		echo "Install with: pip install pre-commit"; \
		exit 1; \
	}
	@pre-commit install
	@echo "Pre-commit hooks installed. Run 'pre-commit run --all-files' to test."

# Sync USAI model catalog
# Requires USAI_API_KEY environment variable or SBX secret
sync-models:
	@echo "Syncing USAI model catalog..."
	@if [ -z "$$USAI_API_KEY" ]; then \
		if command -v sbx >/dev/null 2>&1 && sbx secret ls 2>/dev/null | grep -q "USAI_API_KEY"; then \
			echo "  Using USAI_API_KEY from SBX secrets"; \
			echo "  Note: Run this inside SBX or export the key manually"; \
			echo ""; \
			echo "  To run inside SBX:"; \
			echo "    sbx run --rm -it node:22 bash -c 'npm ci && npm run sync'"; \
			echo ""; \
			echo "  Or export the key and run locally:"; \
			echo "    export USAI_API_KEY='your-key-here'"; \
			echo "    make sync-models"; \
			exit 1; \
		else \
			echo "ERROR: USAI_API_KEY not set."; \
			echo "  Export it: export USAI_API_KEY='your-key-here'"; \
			echo "  Or run: make setup (to store in SBX)"; \
			exit 1; \
		fi; \
	fi
	@node scripts/sync-usai-models.mjs --write-snapshot
	@echo ""
	@echo "Model catalog updated. Review changes with:"
	@echo "  git diff templates/opencode.jsonc"
