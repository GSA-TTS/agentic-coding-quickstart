# Setting up Zed Editor with OpenCode and Docker Sandboxes (SBX)

This guide documents how to set up and run the containerized OpenCode agent inside a sandboxed Docker environment (SBX) while developing on your host machine using the **Zed editor**.

## Why Use Zed with Docker Sandboxes?

Using [Zed](https://zed.dev) with Docker Sandboxes and USAi provides a robust, fast developer workflow:

- **Instant Sync:** Since the SBX container mounts your project workspace directory, any code the agent generates or modifies inside the isolated sandbox is instantly reflected in Zed on your host machine.
- **PTY/TTY-Compliant Tasks:** Zed's integrated task runner provides a fully interactive pseudo-TTY, enabling you to respond to OpenCode's confirmation prompts (e.g., confirming file edits) right within your editor pane.
- **Secure Secret Boundary:** Zed and your host files are protected. The agent executes commands and runs tests purely inside the container, keeping your host system safe.

---

## Prerequisites

1. **Zed Editor** installed on your host machine.
2. **Docker Desktop 4.58+** OR standalone **`sbx` CLI** running.
3. **USAi API Key** set in your host shell profile (required so Zed's terminal can read it):

   **For macOS/Linux (zsh):**
   ```bash
   echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.zshrc
   source ~/.zshrc
   ```

   **For macOS/Linux (bash):**
   ```bash
   echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.bashrc
   source ~/.bashrc
   ```

   *(Docker Desktop users: Remember to completely **restart Docker Desktop** after setting this variable so that the background service picks it up).*

---

## One-Command Setup & Run with Zed Tasks

This repository is pre-configured with a `.zed/tasks.json` file. This integrates with Zed's task runner, giving you one-click access to sandbox creation, health checks, and running the agent.

### 1. Open the Tasks Palette

In Zed, you can trigger tasks via the command palette:
1. Press `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows/Linux) to open the Command Palette.
2. Type `task: spawn` and press `Enter`.
3. *(Alternative shortcut: Press `Cmd+Alt+T` on macOS or `Ctrl+Alt+T` on Windows/Linux).*

### 2. Available Tasks

You will see several tasks preconfigured for this workspace:

| Task Label | Description | Underlying Command |
|------------|-------------|--------------------|
| `OpenCode: Create Sandbox (Standalone CLI)` | Creates the `quickstart` sandbox using `sbx` CLI | `make create-sandbox` |
| `OpenCode: Create Sandbox (Docker Desktop)` | Creates the `quickstart` sandbox using Docker Desktop | `make create-sandbox-desktop` |
| `OpenCode: Run Agent (Standalone CLI)` | Launches OpenCode inside SBX and injects your USAi key | `make run-agent` |
| `OpenCode: Run Agent (Docker Desktop)` | Launches OpenCode in SBX using Docker Desktop | `make run-agent-desktop` |
| `OpenCode: Environment Diagnostics` | Performs health checks on your Docker & SBX setup | `make doctor` |

### 3. Step-by-Step Workflow inside Zed

1. **Run Diagnostics:** Open the tasks palette and select `OpenCode: Environment Diagnostics (make doctor)`. It will open a panel in Zed and verify your Docker and setup states.
2. **Create Sandbox:** Select `OpenCode: Create Sandbox (Standalone CLI)` (or the Docker Desktop equivalent). This prepares your microVM.
3. **Launch OpenCode Agent:** Select `OpenCode: Run Agent (Standalone CLI)` (or Docker Desktop equivalent).
4. **Interact with the Agent:** The agent will boot inside a terminal panel in Zed. You can type prompts directly to the agent (e.g. *"Analyze the directory structure and check for AGENTS.md"*).
5. **Interactive Approvals:** Because our `opencode.jsonc` is configured with `"edit": "ask"` and `"bash": "ask"` for safety, the agent will prompt you in the terminal for approval before making file changes or running mutating shell commands. Type `y` or `n` directly into the Zed terminal tab to respond.

---

## Alternative: Integrated Terminal (Makefile Shortcuts)

If you prefer to run commands manually, you can open Zed's integrated terminal (`Ctrl + ~`) and use the following Makefile shortcuts:

```bash
# Check if your host has USAI_API_KEY set and everything is healthy
make doctor

# Option A: Standalone sbx CLI
make create-sandbox
make run-agent

# Option B: Docker Desktop built-in
make create-sandbox-desktop
make run-agent-desktop
```

---

## Bootstrapping a New Project with Zed Integration

If you want to configure a new or existing repository to use the OpenCode agent in SBX with Zed support:

### Step 1: Copy Templates

Use the quickstart bootstrap files to copy configurations over to your repository:

```bash
TARGET_REPO="/path/to/your/project"

# Copy OpenCode config
cp templates/opencode.jsonc "$TARGET_REPO/"

# Copy Zed Tasks configuration
mkdir -p "$TARGET_REPO/.zed"
cp templates/zed-tasks.json "$TARGET_REPO/.zed/tasks.json"

# Copy SBX patterns reference
mkdir -p "$TARGET_REPO/docs"
cp templates/SBX_PATTERNS.md "$TARGET_REPO/docs/"

# Append Sandbox Rules to AGENTS.md
tail -n +6 templates/AGENTS_SBX_ADDENDUM.md >> "$TARGET_REPO/AGENTS.md"
```

### Step 2: Configure your `Makefile`

Add these targets to your target repository's `Makefile` so that the Zed tasks function properly:

```makefile
# Create SBX sandbox using standalone CLI (sbx)
create-sandbox:
	@echo "Creating SBX sandbox using standalone CLI..."
	@if sbx ls | grep -q "my-sandbox"; then \
		echo "Sandbox already exists. Skipping creation."; \
	else \
		sbx create --name my-sandbox opencode .; \
	fi

# Create SBX sandbox using Docker Desktop
create-sandbox-desktop:
	@echo "Creating SBX sandbox using Docker Desktop..."
	@if docker sandbox ls 2>/dev/null | grep -q "my-sandbox"; then \
		echo "Sandbox already exists. Skipping creation."; \
	else \
		docker sandbox create --name my-sandbox opencode .; \
	fi

# Run OpenCode agent in sandbox using standalone CLI (sbx)
run-agent: _check-usai-key
	@echo "Running OpenCode agent in SBX sandbox (standalone CLI)..."
	@sbx exec -it -e USAI_API_KEY="$(USAI_API_KEY)" -w "$(shell pwd)" my-sandbox opencode

# Run OpenCode agent in sandbox using Docker Desktop
run-agent-desktop:
	@echo "Running OpenCode agent in SBX sandbox (Docker Desktop)..."
	@docker sandbox run my-sandbox

_check-usai-key:
	@if [ -z "$(USAI_API_KEY)" ]; then \
		echo "ERROR: USAI_API_KEY environment variable is not set on host."; \
		echo "Please set it before running the agent. Example:"; \
		echo "  export USAI_API_KEY=\"your-key-here\""; \
		exit 1; \
	fi
```

*(Note: If your sandbox name is different than `my-sandbox`, make sure to update the name in the `Makefile` and `.zed/tasks.json` to match!)*

---

## Troubleshooting Zed Integration

### "Task Command Not Found: make"
- Ensure that `make` is installed on your host machine (included by default on macOS, installable on Linux via `build-essential`, or Windows via Chocolatey/Scoop).
- Alternatively, you can edit your `.zed/tasks.json` and replace the `make` commands with the direct `sbx` or `docker sandbox` command strings.

### "ERROR: USAI_API_KEY environment variable is not set on host"
- Zed inherits environment variables from the parent shell that launched it.
- If you set `USAI_API_KEY` in `.zshrc` or `.bashrc` after launching Zed, you **must completely restart Zed** (or relaunch it from your terminal using `zed .`) so it picks up the newly exported variable.

### SSL/TLS Certificate Errors ("unable to get local issuer certificate")
- If OpenCode launches but fails to connect with an `unable to get local issuer certificate` error, this is due to SSL/TLS interception/decryption on federal GFE (Government Furnished Equipment) networks.
- **To fix this:** Add `export NODE_TLS_REJECT_UNAUTHORIZED="0"` to your host's shell profile (`~/.zshrc` or `~/.bashrc`) and restart Zed (and completely restart Docker Desktop if you are using it). This allows Node.js inside the isolated sandbox container to securely bypass GFE network decrypt validation.
- Alternatively, you can run from your host terminal using: `NODE_TLS_REJECT_UNAUTHORIZED=0 make run-agent`

### Terminal Output is Frozen or Unresponsive
- If a task runs and does not respond to keystrokes, close the terminal pane (`Cmd + W`) and trigger the task again via the tasks palette.
- Standard interactive shells are fully supported, but if you run into environment issues, run `make run-agent` directly in Zed's integrated terminal (`Ctrl + ~`) instead of the task runner.
