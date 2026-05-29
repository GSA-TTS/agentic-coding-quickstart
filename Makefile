# Agentic Coding Quickstart - Makefile
# Simple commands for setting up and managing your AI-assisted development workspace

.PHONY: setup doctor new-project clean install-hooks help init-project create-sandbox run-agent

# Default target
help:
	@echo "Agentic Coding Quickstart"
	@echo "========================="
	@echo ""
	@echo "Commands:"
	@echo "  make setup                 - Set up your workspace (clone playbook, check dependencies)"
	@echo "  make doctor                - Run health checks on your environment"
	@echo "  make new-project           - Create a new project directory (interactive)"
	@echo "  make init-project TARGET_DIR=/path - Bootstrap a project directory (non-interactive)"
	@echo "  make create-sandbox        - Create SBX sandbox 'quickstart'"
	@echo "  make run-agent             - Run OpenCode agent in SBX"
	@echo "  make install-hooks         - [OPTIONAL] Install pre-commit hooks"
	@echo "  make clean                 - Remove generated files"
	@echo ""
	@echo "First time? Run: make setup"

# Set up the workspace
setup: _check-git _check-sbx _clone-playbook
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
	@echo "  SBX: OK"

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
	@if [ -n "$$USAI_API_KEY" ]; then \
		echo "[OK] USAI_API_KEY is set"; \
	else \
		echo "[FAIL] USAI_API_KEY is not set"; \
		echo ""; \
		echo "To set your API key, run:"; \
		echo "  export USAI_API_KEY=\"your-api-key-here\""; \
		echo ""; \
		echo "Get your API key at: https://console.gsa.usai.gov/key-management"; \
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
init-project: _check-target-dir
	@echo "Initializing project in $(TARGET_DIR)..."
	@mkdir -p "$(TARGET_DIR)"
	@echo "Copying configuration files..."
	@cp AGENTS.md "$(TARGET_DIR)/" && echo "  [OK] AGENTS.md"
	@cp opencode.jsonc "$(TARGET_DIR)/" && echo "  [OK] opencode.jsonc"
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
	@cp .zed/tasks.json "$(TARGET_DIR)/.zed/tasks.json" && echo "  [OK] .zed/tasks.json"

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

# Create SBX sandbox 'quickstart'
create-sandbox:
	@echo "Creating SBX sandbox 'quickstart'..."
	@if sbx ls | grep -q "quickstart"; then \
		echo "Sandbox 'quickstart' already exists. Skipping creation."; \
	else \
		sbx create --name quickstart opencode .; \
	fi

# Run OpenCode agent in sandbox 'quickstart'
run-agent: _check-usai-key
	@echo "Running OpenCode agent in SBX sandbox 'quickstart'..."
	@sbx exec -it \
		-e USAI_API_KEY="$(USAI_API_KEY)" \
		$(if $(NODE_TLS_REJECT_UNAUTHORIZED),-e NODE_TLS_REJECT_UNAUTHORIZED="$(NODE_TLS_REJECT_UNAUTHORIZED)",) \
		-w "$(shell pwd)" quickstart opencode

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
