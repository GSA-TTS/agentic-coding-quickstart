# Agentic Coding Quickstart - Makefile
# Simple commands for setting up and managing your AI-assisted development workspace

.PHONY: setup doctor new-project clean help

# Default target
help:
	@echo "Agentic Coding Quickstart"
	@echo "========================="
	@echo ""
	@echo "Commands:"
	@echo "  make setup        - Set up your workspace (clone playbook, check dependencies)"
	@echo "  make doctor       - Run health checks on your environment"
	@echo "  make new-project  - Create a new project directory"
	@echo "  make clean        - Remove generated files"
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
