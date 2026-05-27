# Agentic Coding Quickstart - Makefile
# Simple commands for setting up and managing your AI-assisted development workspace

.PHONY: setup doctor new-project clean install-hooks help

# Default target
help:
	@echo "Agentic Coding Quickstart"
	@echo "========================="
	@echo ""
	@echo "Commands:"
	@echo "  make setup                 - Set up your workspace (clone playbook, check dependencies)"
	@echo "  make doctor                - Run health checks on your environment"
	@echo "  make new-project           - Create a new project directory"
	@echo "  make create-sandbox        - Create SBX sandbox 'quickstart' (sbx CLI)"
	@echo "  make run-agent             - Run OpenCode agent in SBX (sbx CLI)"
	@echo "  make install-hooks         - [OPTIONAL] Install pre-commit hooks"
	@echo "  make clean                 - Remove generated files"
	@echo ""
	@echo "Deprecated targets (will be removed in future release):"
	@echo "  make create-sandbox-desktop- DEPRECATED: use 'make create-sandbox'"
	@echo "  make run-agent-desktop     - DEPRECATED: use 'make run-agent'"
	@echo ""
	@echo "First time? Run: make setup"

# Set up the workspace
setup: _check-docker _check-git _clone-playbook
	@echo ""
	@echo "Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure your credentials (see docs/SBX_QUICKSTART.md)"
	@echo "  2. Start your AI agent"
	@echo "  3. Ask it to help you build something"
	@echo ""

_check-docker:
	@echo "Checking Docker..."
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker not found. Install Docker first."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "ERROR: Docker not running. Start Docker first."; exit 1; }
	@echo "  Docker: OK"

_check-git:
	@echo "Checking Git..."
	@command -v git >/dev/null 2>&1 || { echo "ERROR: Git not found. Install Git first."; exit 1; }
	@echo "  Git: OK"

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
	@command -v docker >/dev/null 2>&1 && echo "[OK] Docker installed" || echo "[FAIL] Docker not found"
	@docker info >/dev/null 2>&1 && echo "[OK] Docker running" || echo "[FAIL] Docker not running"
	@command -v git >/dev/null 2>&1 && echo "[OK] Git installed" || echo "[FAIL] Git not found"
	@command -v sbx >/dev/null 2>&1 && echo "[OK] SBX installed" || echo "[WARN] SBX not found (optional)"
	@echo ""
	@echo "Workspace"
	@echo "---------"
	@test -d "../agentic-coding-playbook" && echo "[OK] Playbook found" || echo "[FAIL] Playbook not found (run: make setup)"
	@test -f "../agentic-coding-playbook/AGENTS.md" && echo "[OK] Playbook AGENTS.md exists" || echo "[WARN] Playbook AGENTS.md missing"
	@test -d "../agentic-coding-playbook/skills" && echo "[OK] Skills directory found" || echo "[WARN] Skills directory missing"
	@echo ""
	@echo "Run 'make setup' to fix any issues."

# Create a new project
new-project:
	@echo "Create a new project"
	@echo "--------------------"
	@read -p "Project name (lowercase, hyphens ok): " name; \
	if [ -z "$$name" ]; then \
		echo "ERROR: Project name required"; \
		exit 1; \
	fi; \
	if [ -d "../$$name" ]; then \
		echo "ERROR: Directory ../$$name already exists"; \
		exit 1; \
	fi; \
	mkdir -p "../$$name"; \
	echo "# $$name" > "../$$name/README.md"; \
	echo "" >> "../$$name/README.md"; \
	echo "Project created with agentic-coding-quickstart." >> "../$$name/README.md"; \
	echo ""; \
	echo "Created: ../$$name"; \
	echo ""; \
	echo "Next: Start your AI agent and ask it to help you set up the project."; \
	echo "      The agent can use skills from the playbook to scaffold your app."

# Clean up
clean:
	@echo "Nothing to clean (this repo doesn't generate files)"

# Create SBX sandbox 'quickstart' using sbx CLI
create-sandbox:
	@echo "Creating SBX sandbox 'quickstart'..."
	@if sbx ls | grep -q "quickstart"; then \
		echo "Sandbox 'quickstart' already exists. Skipping creation."; \
	else \
		sbx create --name quickstart opencode .; \
	fi

# DEPRECATED: Create SBX sandbox using Docker Desktop
# Docker has deprecated 'docker sandbox' commands. Use 'make create-sandbox' instead.
create-sandbox-desktop:
	@echo ""
	@echo "WARNING: 'docker sandbox' commands are DEPRECATED by Docker."
	@echo "         Use 'make create-sandbox' (sbx CLI) instead."
	@echo "         See: https://docs.docker.com/reference/cli/docker/sandbox/"
	@echo ""
	@if docker sandbox ls 2>/dev/null | grep -q "quickstart"; then \
		echo "Sandbox 'quickstart' already exists. Skipping creation."; \
	else \
		docker sandbox create --name quickstart opencode .; \
	fi

# Run OpenCode agent in sandbox 'quickstart' using sbx CLI
run-agent: _check-usai-key
	@echo "Running OpenCode agent in SBX sandbox 'quickstart'..."
	@sbx exec -it \
		-e USAI_API_KEY="$(USAI_API_KEY)" \
		$(if $(NODE_TLS_REJECT_UNAUTHORIZED),-e NODE_TLS_REJECT_UNAUTHORIZED="$(NODE_TLS_REJECT_UNAUTHORIZED)",) \
		-w "$(shell pwd)" quickstart opencode

# DEPRECATED: Run agent using Docker Desktop
# Docker has deprecated 'docker sandbox' commands. Use 'make run-agent' instead.
run-agent-desktop:
	@echo ""
	@echo "WARNING: 'docker sandbox' commands are DEPRECATED by Docker."
	@echo "         Use 'make run-agent' (sbx CLI) instead."
	@echo "         See: https://docs.docker.com/reference/cli/docker/sandbox/"
	@echo ""
	@docker sandbox run quickstart

_check-usai-key:
	@if [ -z "$(USAI_API_KEY)" ]; then \
		echo "ERROR: USAI_API_KEY environment variable is not set on host."; \
		echo "Please set it before running the agent. Example:"; \
		echo "  export USAI_API_KEY=\"your-key-here\""; \
		exit 1; \
	fi

# Install pre-commit hooks (optional)
install-hooks:  ## [OPTIONAL] Install pre-commit hooks
	@command -v pre-commit >/dev/null 2>&1 || { \
		echo "ERROR: pre-commit not installed."; \
		echo "Install with: pip install pre-commit"; \
		exit 1; \
	}
	@pre-commit install
	@echo "Pre-commit hooks installed. Run 'pre-commit run --all-files' to test."
