# Setting up Zed Editor with OpenCode and Docker Sandboxes (SBX)

This guide documents how to set up and run the containerized OpenCode agent inside a sandboxed Docker environment (SBX) while developing on your host machine using the **Zed editor**.

> [!IMPORTANT]
> The Docker Desktop-integrated `docker sandbox` commands are **deprecated**.
> Use the standalone `sbx` CLI instead.
> See [Docker's deprecation notice](https://docs.docker.com/reference/cli/docker/sandbox/).

## Why Use Zed with Docker Sandboxes?

Using [Zed](https://zed.dev) with Docker Sandboxes and USAi provides a robust, fast developer workflow:

- **Instant Sync:** Since the SBX container mounts your project workspace directory, any code the agent generates or modifies inside the isolated sandbox is instantly reflected in Zed on your host machine.
- **PTY/TTY-Compliant Tasks:** Zed's integrated task runner provides a fully interactive pseudo-TTY, enabling you to respond to OpenCode's confirmation prompts (e.g., confirming file edits) right within your editor pane.
- **Secure Secret Boundary:** Zed and your host files are protected. The agent executes commands and runs tests purely inside the container, keeping your host system safe.

---

## Prerequisites

1. **Zed Editor** installed on your host machine.
2. **Standalone `sbx` CLI** installed:
   ```bash
   # macOS
   brew install docker/tap/sbx

   # Windows
   winget install Docker.sbx
   ```
3. **USAi API Key** stored securely (USAi is a custom endpoint):
   ```bash
   sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"
   ```
   > After setting the secret, recreate any existing sandbox: `sbx rm quickstart; sbx create --name quickstart opencode .`

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
| `USAi OpenCode: Run Agent` | Launches OpenCode inside a project-named SBX sandbox (secrets auto-injected, creates sandbox if needed) | `make run-agent` |
| `USAi OpenCode: Diagnostics (make doctor)` | Performs health checks on your Docker & SBX setup | `make doctor` |
| `USAi OpenCode: Set USAi API Key (SBX Secret)` | Prompts for `USAI_API_KEY` and stores it as an SBX custom secret | `make setup-usai-secret` |

> **Note:** The deprecated Docker Desktop tasks have been removed. Use the `sbx` CLI tasks above.

### 3. Step-by-Step Workflow inside Zed

1. **Run Diagnostics:** Open the tasks palette and select `USAi OpenCode: Diagnostics (make doctor)`. It will open a panel in Zed and verify your Docker and setup states.
2. **Launch OpenCode Agent:** Select `USAi OpenCode: Run Agent`. This creates the sandbox if needed and launches the agent.
3. **Interact with the Agent:** The agent will boot inside a terminal panel in Zed. You can type prompts directly to the agent (e.g. *"Analyze the directory structure and check for AGENTS.md"*).
4. **Interactive Approvals:** Because our `opencode.jsonc` is configured with `"edit": "ask"` and `"bash": "ask"` for safety, the agent will prompt you in the terminal for approval before making file changes or running mutating shell commands. Type `y` or `n` directly into the Zed terminal tab to respond.

---

## Alternative: Integrated Terminal (Makefile Shortcuts)

If you prefer to run commands manually, you can open Zed's integrated terminal (`Ctrl + ~`) and use the following Makefile shortcuts:

```bash
# Check if your environment is healthy
make doctor

# Store or reset your USAi key in SBX secrets
make setup-usai-secret

# Run agent (creates sandbox automatically if needed)
make run-agent

# Remove and recreate the project sandbox if SBX cached a stale workspace path
make reset-agent-sandbox
make run-agent
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

### Step 2: Use the generated `Makefile`

The bootstrap copies this repository's `Makefile` into the target project. That file provides the Zed task targets:

- `make setup-usai-secret` prompts for `USAI_API_KEY`, confirms before replacing an existing SBX secret, and points reset users to `https://console.gsa.usai.gov/`.
- `make doctor` checks local tooling, SBX access, SBX secret presence, and workspace files.
- `make run-agent` uses the current directory name as the SBX sandbox name and checks USAi API access from an existing sandbox before launch.
- `make reset-agent-sandbox` removes the project sandbox so changed custom secrets or workspace paths can be picked up.

The default sandbox name is the current directory name. You can override it with `SANDBOX_NAME=my-project make run-agent`.

---

## Troubleshooting Zed Integration

### "Task Command Not Found: make"
- Ensure that `make` is installed on your host machine (included by default on macOS, installable on Linux via `build-essential`, or Windows via Chocolatey/Scoop).
- Alternatively, you can edit your `.zed/tasks.json` and replace the `make` commands with the direct `sbx` command strings.

### "ERROR: USAI_API_KEY not found"
- USAi is a custom endpoint, so you must use `sbx secret set-custom`:
  ```bash
  sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"
  ```
- After setting the secret, **delete and recreate** the sandbox:
  ```bash
  sbx rm quickstart; sbx create --name quickstart opencode .
  ```

### SSL/TLS Certificate Errors ("unable to get local issuer certificate")
- If OpenCode launches but fails to connect with an `unable to get local issuer certificate` error, this is due to SSL/TLS interception/decryption on federal GFE (Government Furnished Equipment) networks.
- **To fix this:** Use the two-step `create` + `exec` pattern (since `sbx run` does not support `-e`):
  ```bash
  # For debugging TLS issues only - never use with real credentials
  sbx create --name debug-sandbox opencode . 2>/dev/null || true && \
  sbx exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 debug-sandbox opencode
  ```
- **⚠️ Security Warning:** Disabling TLS validation bypasses certificate verification. Only use this for debugging in isolated local environments, never with real credentials.
- See [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md#16-ssltls-certificate-errors-unable-to-get-local-issuer-certificate) for details.

### Terminal Output is Frozen or Unresponsive
- If a task runs and does not respond to keystrokes, close the terminal pane (`Cmd + W`) and trigger the task again via the tasks palette.
- Standard interactive shells are fully supported, but if you run into environment issues, run `make run-agent` directly in Zed's integrated terminal (`Ctrl + ~`) instead of the task runner.

### `OCI runtime exec failed: chdir ... no such file or directory`
- SBX may be trying to reuse cached workspace metadata for a sandbox whose host path changed or was never mounted correctly.
- Remove the project sandbox and let `make run-agent` recreate it from the current directory:
  ```bash
  make reset-agent-sandbox
  make run-agent
  ```
- See [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md#18-sbx-fails-to-start-with-host-path-chdir-error) for details.
