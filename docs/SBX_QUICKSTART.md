# SBX + USAi Quick Start

This guide gets you from zero to running an AI agent inside SBX with USAi in under 5 minutes.

## Prerequisites

- SBX CLI installed (`sbx --version`)
- USAi API key (set as `USAI_API_KEY` environment variable on host)
- This repository cloned locally
- (Optional) GitHub CLI logged in (`gh auth status`)
- (Optional) GitLab CLI logged in (`glab auth status`)

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

## Credential Injection Overview

SBX supports two methods for injecting credentials:

| Method | Security | Use Case | Supported Services |
|--------|----------|----------|-------------------|
| **SBX Proxy** (recommended) | High - agent never sees token | Standard API endpoints | `anthropic`, `aws`, `cursor`, `github`, `google`, `groq`, `mistral`, `nebius`, `openai`, `xai` |
| **Direct Injection** (`-e`) | Medium - token in container env | Custom endpoints (USAi, GitLab) | Any service |

**Rule of thumb:** Use SBX proxy when available; use direct injection for custom endpoints.

---

## Git Provider Credentials (GitHub / GitLab)

Agents often need git credentials for cloning private repos, creating PRs, or pushing changes. Here's how to inject them securely.

### GitHub (github.com)

GitHub is a **built-in SBX service**, so the proxy method works:

**Method 1: SBX Proxy (Recommended)**

```bash
# One-time setup - pipe token from gh cli (most secure)
gh auth token | sbx secret set -g github

# Or enter manually when prompted
sbx secret set -g github

# Verify it's stored
sbx secret ls
```

The SBX proxy intercepts requests to `api.github.com` and injects authentication automatically. The agent never sees the actual token.

**Method 2: Direct Injection**

```bash
# Inject on-demand from gh cli
sbx exec -it \
  -e GH_TOKEN="$(gh auth token)" \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -w $(pwd) SANDBOX_NAME opencode
```

**Verify GitHub access inside sandbox:**
```bash
# Uses proxy - should return your username
sbx exec SANDBOX_NAME sh -c 'curl -s -H "Authorization: Bearer test" https://api.github.com/user | jq .login'
```

### GitLab (Custom Instances)

GitLab is **NOT a built-in SBX service**, so you must use direct injection:

```bash
# For gitlab.com
sbx exec -it \
  -e GITLAB_TOKEN="your-gitlab-token" \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -w $(pwd) SANDBOX_NAME opencode

# For self-hosted GitLab (e.g., workshop.cloud.gov)
# Extract token from glab cli config
sbx exec -it \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -w $(pwd) SANDBOX_NAME opencode
```

**Verify GitLab access inside sandbox:**
```bash
sbx exec SANDBOX_NAME sh -c 'curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://$GITLAB_HOST/api/v4/user | jq .username'
```

### Combined: USAi + GitHub + GitLab

For agents that need all three:

```bash
# Full injection command
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GH_TOKEN="$(gh auth token)" \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) SANDBOX_NAME opencode
```

> **Tip:** If you've already set GitHub via `sbx secret set -g github`, you can omit `-e GH_TOKEN` - the proxy handles it.

### Git Credential Summary

| Provider | SBX Proxy | Direct Injection | CLI to Extract Token |
|----------|-----------|------------------|---------------------|
| GitHub (github.com) | `sbx secret set -g github` | `-e GH_TOKEN="$(gh auth token)"` | `gh auth token` |
| GitLab.com | Not supported | `-e GITLAB_TOKEN="..."` | `glab config get token` |
| GitLab (self-hosted) | Not supported | `-e GITLAB_TOKEN="..." -e GITLAB_HOST="..."` | `glab config get --host HOST token` |

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
cd /path/to/your-project
sbx create --name my-sandbox opencode .

# Verify it exists
sbx ls
```

**Available agents:** `claude`, `codex`, `copilot`, `docker-agent`, `gemini`, `kiro`, `opencode`, `shell`

### Step 3: Configure Git Provider Secrets (Optional)

If your agent needs to interact with GitHub:

```bash
# Recommended: Use SBX proxy for GitHub
gh auth token | sbx secret set -g github
```

### Step 4: Run OpenCode with USAi

**Important:** USAi uses a custom endpoint, so you must inject the API key manually:

```bash
# Basic: USAi only
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) my-sandbox opencode

# With GitLab (for projects using GitLab)
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) my-sandbox opencode
```

The `-e` flag injects environment variables, and `-w` sets the working directory so OpenCode finds the `opencode.jsonc` config.

### Why Not Use SBX Secret Management for USAi?

SBX's `sbx secret set` command works great for standard providers (OpenAI, Anthropic, GitHub, etc.) because SBX proxies requests to known endpoints and injects authentication automatically.

However, USAi uses a **custom baseURL** (`https://api.gsa.usai.gov/api/v1`), which the SBX proxy doesn't recognize. So we inject the API key directly via `-e USAI_API_KEY="$USAI_API_KEY"`.

This is still secure because:
- The key only exists in the container's environment during execution
- It's never written to disk or config files
- The container is isolated from the host

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

# Pipe from CLI tools (recommended - avoids shell history)
gh auth token | sbx secret set -g github
echo "$API_KEY" | sbx secret set -g openai

# List configured secrets
sbx secret ls

# Remove a secret
sbx secret rm SERVICE
```

> **How it works:** SBX proxies API requests from the agent and injects authentication headers automatically. The agent never sees the raw secret.

### Environment Variable Injection

For services not supported by SBX proxy (USAi, GitLab, custom APIs):

```bash
# Single variable
sbx exec -e VAR="value" SANDBOX_NAME COMMAND

# Multiple variables
sbx exec \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host HOST token)" \
  -e GITLAB_HOST="HOST" \
  SANDBOX_NAME COMMAND
```

### Executing Commands

```bash
# Run OpenCode with USAi (the working pattern)
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode

# Run OpenCode with USAi + GitHub + GitLab
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GH_TOKEN="$(gh auth token)" \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) SANDBOX_NAME opencode

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
sbx exec SANDBOX_NAME sh -c 'echo "USAI key length: ${#USAI_API_KEY}"'
sbx exec SANDBOX_NAME sh -c 'echo "GH_TOKEN set: ${GH_TOKEN:+yes}"'
sbx exec SANDBOX_NAME sh -c 'echo "GITLAB_TOKEN set: ${GITLAB_TOKEN:+yes}"'

# Test GitHub API access (via proxy)
sbx exec SANDBOX_NAME sh -c 'curl -s -H "Authorization: Bearer test" https://api.github.com/user | jq .login'

# Test GitLab API access (direct injection required)
sbx exec -e GITLAB_TOKEN="$(glab config get --host HOST token)" SANDBOX_NAME \
  sh -c 'curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://HOST/api/v4/user | jq .username'

# Test USAi connectivity
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

### GitHub API returns 401 Unauthorized

**Problem:** GitHub API calls fail despite having `gh` logged in.

**Fix:** Ensure GitHub secret is set in SBX:
```bash
# Check if github secret exists
sbx secret ls

# If not, set it
gh auth token | sbx secret set -g github
```

The SBX proxy only works if the secret is stored via `sbx secret set`.

### GitLab API returns 401 Unauthorized

**Problem:** GitLab API calls fail inside sandbox.

**Fix:** GitLab requires direct token injection (not a built-in SBX service):
```bash
# For self-hosted GitLab
sbx exec -e GITLAB_TOKEN="$(glab config get --host YOUR_HOST token)" SANDBOX_NAME COMMAND

# Verify token is being passed
sbx exec -e GITLAB_TOKEN="test" SANDBOX_NAME sh -c 'echo "Token set: ${GITLAB_TOKEN:+yes}"'
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
cd /path/to/your-project
sbx create opencode .
```

---

## Security Reminders

1. **Never print your API key**: Use `${#VAR}` to check length, not `echo $VAR`
2. **Never commit secrets**: The `opencode.jsonc` uses `${USAI_API_KEY}` variable substitution
3. **Always use SBX**: Don't run agents directly on host with credentials
4. **Review agent output**: Before sharing logs, ensure no secrets leaked
5. **Prefer SBX proxy when available**: More secure than direct injection
6. **Pipe tokens from CLI tools**: Avoids shell history exposure (e.g., `gh auth token | sbx secret set -g github`)

---

## Quick Reference Card

### One-Time Setup

```bash
# GitHub (recommended: use proxy)
gh auth token | sbx secret set -g github

# Verify secrets
sbx secret ls
```

### Per-Session Commands

```bash
# USAi only
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX opencode

# USAi + GitLab (self-hosted)
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host GITLAB_HOST token)" \
  -e GITLAB_HOST="GITLAB_HOST" \
  -w $(pwd) SANDBOX opencode

# Full stack (USAi + GitHub direct + GitLab)
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GH_TOKEN="$(gh auth token)" \
  -e GITLAB_TOKEN="$(glab config get --host GITLAB_HOST token)" \
  -e GITLAB_HOST="GITLAB_HOST" \
  -w $(pwd) SANDBOX opencode
```

---

## Next Steps

- Read `AGENTS.md` for full behavioral rules
- Check `docs/KNOWN_FAILURE_MODES.md` if something breaks
- Review `docs/adr/0001-sbx-usai-agent-execution-architecture.md` for architecture rationale
