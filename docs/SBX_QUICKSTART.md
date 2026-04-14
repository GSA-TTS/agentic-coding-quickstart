# SBX + USAi Quick Start

This guide gets you from zero to running an AI agent inside SBX with USAi in under 5 minutes.

## Prerequisites

- SBX CLI installed (`sbx --version`)
- USAi API key (set as `USAI_API_KEY` environment variable on host)
- This repository cloned locally

## Quick Start (3 Commands)

```bash
# 1. Verify your API key is set on the HOST (should show key length, not the key itself)
echo "USAI_API_KEY length: ${#USAI_API_KEY}"

# 2. Create a sandbox for OpenCode in current directory
sbx create --name usai-test opencode .

# 3. Run OpenCode with API key injection
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) usai-test opencode
```

That's it. You're now running an AI agent in an isolated container with USAi access.

> **Important:** USAi requires manual API key injection because it uses a custom endpoint. SBX's built-in secret proxy only works with standard provider endpoints (OpenAI, Anthropic, etc.).

---

## Step-by-Step Walkthrough

### Step 1: Set Your API Key (on Host)

**On your host machine** (not inside the container):

```bash
# Option A: Export for current session
export USAI_API_KEY="your-api-key-here"

# Option B: Add to shell profile (bash)
echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.bashrc
source ~/.bashrc

# Option C: Add to shell profile (zsh)
echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.zshrc
source ~/.zshrc
```

**Verify it's set** (safe command - only shows length):
```bash
echo "Key is set: ${USAI_API_KEY:+yes}" 
echo "Key length: ${#USAI_API_KEY}"
```

### Step 2: Create a Sandbox

SBX requires specifying an agent type and workspace path:

```bash
# Create a sandbox for OpenCode in current directory
cd /path/to/sbx-testing
sbx create --name usai-test opencode .

# Verify it exists
sbx ls
```

**Available agents:** `claude`, `codex`, `copilot`, `docker-agent`, `gemini`, `kiro`, `opencode`, `shell`

### Step 3: Run OpenCode with USAi

**Important:** USAi uses a custom endpoint, so you must inject the API key manually:

```bash
# Run with API key injection and working directory set
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) usai-test opencode
```

The `-e` flag injects the environment variable, and `-w` sets the working directory so OpenCode finds the `opencode.jsonc` config.

### Why Not Use SBX Secret Management?

SBX's `sbx secret set` command works great for standard providers (OpenAI, Anthropic, etc.) because SBX proxies requests to known endpoints and injects authentication automatically.

However, USAi uses a **custom baseURL** (`https://api.gsa.usai.gov/api/v1`), which the SBX proxy doesn't recognize. So we inject the API key directly via `-e USAI_API_KEY="$USAI_API_KEY"`.

This is still secure because:
- The key only exists in the container's environment during execution
- It's never written to disk or config files
- The container is isolated from the host

**Verify it's set** (safe command - only shows length):
```bash
echo "Key is set: ${USAI_API_KEY:+yes}" 
echo "Key length: ${#USAI_API_KEY}"
```

### Step 2: Configure SBX Secrets (One-Time Setup)

SBX manages secrets for predefined services and injects authentication automatically via a proxy. For USAi (which uses OpenAI-compatible API), use the `openai` service:

```bash
# Set the secret globally for OpenAI-compatible APIs (includes USAi)
sbx secret set -g openai
# Enter your USAI_API_KEY when prompted

# Verify it's stored
sbx secret ls
```

**Available services:** `anthropic`, `aws`, `cursor`, `github`, `google`, `groq`, `mistral`, `nebius`, `openai`, `xai`

> **Note:** SBX proxies API requests and injects authentication automatically. The secret is never exposed directly to the agent - this is a security feature.

### Step 3: Create a Sandbox

SBX requires specifying an agent type and workspace path:

```bash
# Create a sandbox for OpenCode in current directory
sbx create opencode .

# Or with a custom name
sbx create --name usai-test opencode .

# Verify it exists
sbx list
```

**Available agents:** `claude`, `codex`, `copilot`, `docker-agent`, `gemini`, `kiro`, `opencode`, `shell`

### Step 4: Run the Sandbox

```bash
# Attach to the sandbox
sbx run opencode

# Or if you used a custom name
sbx run usai-test
```

---

## Common Commands Reference

### Sandbox Management

```bash
# Create a sandbox (AGENT = claude|codex|copilot|gemini|kiro|opencode|shell)
sbx create AGENT PATH
sbx create --name my-sandbox opencode .

# List sandboxes
sbx ls

# Run/attach to a sandbox
sbx run SANDBOX_NAME

# Stop a sandbox (keeps state)
sbx stop SANDBOX_NAME

# Delete a sandbox
sbx rm SANDBOX_NAME
```

### Secret Management

```bash
# Set a secret globally (prompts for value)
# SERVICE = anthropic|aws|cursor|github|google|groq|mistral|nebius|openai|xai
sbx secret set -g SERVICE

# Set a secret for a specific sandbox
sbx secret set SANDBOX_NAME SERVICE

# Set via pipe (use carefully - may appear in history)
echo "$API_KEY" | sbx secret set -g openai

# List configured secrets
sbx secret ls

# Remove a secret
sbx secret rm SERVICE
```

> **How it works:** SBX proxies API requests from the agent and injects authentication headers automatically. The agent never sees the raw secret.

### Executing Commands

```bash
# Run OpenCode with USAi (the working pattern)
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode

# Run a command in the sandbox
sbx exec SANDBOX_NAME COMMAND

# Interactive shell
sbx exec -it SANDBOX_NAME sh

# Run with environment variable injection
sbx exec -e VAR="value" SANDBOX_NAME COMMAND
```

### Debugging

```bash
# Check if secrets are available inside sandbox
sbx exec SANDBOX_NAME sh -c 'echo "Key length: ${#USAI_API_KEY}"'

# Test network connectivity
sbx exec SANDBOX_NAME curl -I https://api.gsa.usai.gov

# Check what's in the workspace
sbx exec SANDBOX_NAME ls -la
```

---

## Troubleshooting

### "unknown agent" error

**Problem:** `sbx create usai-test` fails with "unknown agent".

**Fix:** SBX requires an agent type. Use:
```bash
sbx create opencode .
# Or with custom name:
sbx create --name usai-test opencode .
```

### OpenCode shows generic providers, not USAi

**Problem:** OpenCode starts but shows OpenAI, Anthropic, etc. instead of USAi models.

**Root Cause:** Either:
1. API key not injected properly
2. Config file not found
3. Working directory not set

**Fix:** Use the full command with all flags:
```bash
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) usai-test opencode
```

Verify the config exists:
```bash
sbx exec usai-test cat $(pwd)/opencode.jsonc
```

### "API key not found" or authentication errors

**Problem:** Agent can't authenticate to USAi.

**Fix:** USAi requires manual key injection (SBX proxy doesn't work with custom endpoints):
```bash
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) usai-test opencode
```

Verify your key is set on the host:
```bash
echo "Key length: ${#USAI_API_KEY}"
```

### "Connection refused" or timeouts

**Problem:** Can't reach USAi API.

**Fix:** Check network connectivity from inside the sandbox:
```bash
sbx exec <name> curl -v https://api.gsa.usai.gov/api/v1/models
```

### "Model not found" despite being listed

**Problem:** Model appears in `/models` but fails at inference.

**Fix:** 
1. Confirm your API key has access to that specific model
2. Try a different model (e.g., `gpt-4o-mini`)
3. Check `docs/KNOWN_FAILURE_MODES.md` for more details

### Config file not found

**Problem:** OpenCode doesn't see `opencode.jsonc`.

**Fix:** The workspace is automatically mounted when you create with a path. Ensure you created the sandbox from this repo's directory:
```bash
cd /path/to/sbx-testing
sbx create opencode .
```

---

## Security Reminders

1. **Never print your API key**: Use `${#VAR}` to check length, not `echo $VAR`
2. **Never commit secrets**: The `opencode.jsonc` uses `${USAI_API_KEY}` variable substitution
3. **Always use SBX**: Don't run agents directly on host with USAi credentials
4. **Review agent output**: Before sharing logs, ensure no secrets leaked

---

## Next Steps

- Read `AGENTS.md` for full behavioral rules
- Check `docs/KNOWN_FAILURE_MODES.md` if something breaks
- Review `docs/adr/0001-sbx-usai-agent-execution-architecture.md` for architecture rationale
