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
2. **Standalone `sbx` CLI** installed:
   ```bash
   # macOS
   brew install docker/tap/sbx

   # Windows
   winget install Docker.sbx
   ```
3. **USAi API Key** stored securely (USAi is a custom endpoint):
   ```bash
   sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY
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
| `OpenCode: Run Agent` | Launches OpenCode inside SBX via `qsbx` (secrets auto-injected, creates sandbox if needed, shared config mounted) | `./qsbx run opencode .` |
| `OpenCode: Environment Diagnostics` | Checks that `qsbx`, `sbx`, `opencode`, and the USAI_API_KEY custom secret are available | inline checks |

> **Note:** The deprecated Docker Desktop tasks have been removed. Use the `sbx` CLI tasks above.

### 3. Step-by-Step Workflow inside Zed

1. **Run Diagnostics:** Open the tasks palette and select `OpenCode: Environment Diagnostics`. It will open a panel in Zed and verify your SBX setup states.
2. **Launch OpenCode Agent:** Select `OpenCode: Run Agent`. This creates the sandbox if needed and launches the agent.
3. **Interact with the Agent:** The agent will boot inside a terminal panel in Zed. You can type prompts directly to the agent (e.g. *"Analyze the directory structure and check for AGENTS.md"*).
4. **Interactive Approvals:** Because our `opencode.jsonc` is configured with `"edit": "ask"` and `"bash": "ask"` for safety, the agent will prompt you in the terminal for approval before making file changes or running mutating shell commands. Type `y` or `n` directly into the Zed terminal tab to respond.

---

## Alternative: Integrated Terminal

If you prefer to run commands manually, open Zed's integrated terminal (`Ctrl + ~`) and run `sbx` directly:

```bash
# Check that sbx is installed and your USAi key secret is set
command -v sbx && sbx secret ls | grep USAI_API_KEY

# Run agent (creates sandbox automatically if needed and mounts shared config)
./qsbx run opencode .
```

---

## Mounting This Config into Your Sandbox

This repository's shared config (`opencode/opencode.jsonc`) and the playbook
submodule are meant to be mounted into sandboxes rather than copied into each
project. Use `qsbx` to mount this clone and symlink the config into the sandbox
home (`~/.config/opencode/opencode.jsonc`, `~/.config/opencode/AGENTS.md`,
`~/.agents/skills`) automatically:

```bash
./qsbx run opencode /path/to/your/project
```

`qsbx run` creates the sandbox (with this clone mounted) if it doesn't exist,
then attaches. It uses the clone it lives in; set `QUICKSTART_CLONE` only to
override that.

The `.zed/tasks.json` in this repo drives the Zed tasks above. If you want the
same tasks in another repo, copy that file into your project's `.zed/` directory
and adjust the sandbox name to match.

---

## Troubleshooting Zed Integration

### "Task Command Not Found"
- The Zed tasks call `./qsbx`, which then calls `sbx`. Ensure you opened Zed at the repository root so `./qsbx` exists.
- If Zed was launched from Finder or Spotlight, it may not inherit your shell `PATH`; the task prepends common Homebrew paths (`/opt/homebrew/bin` and `/usr/local/bin`) before calling `sbx` and `opencode`.
- You can edit `.zed/tasks.json` to adjust the commands for your environment.

### "ERROR: USAI_API_KEY not found"
- USAi is a custom endpoint, so you must use `sbx secret set-custom`:
  ```bash
  sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY
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
- Standard interactive shells are fully supported, but if you run into environment issues, run `./qsbx run opencode .` directly in Zed's integrated terminal (`Ctrl + ~`) instead of the task runner.
