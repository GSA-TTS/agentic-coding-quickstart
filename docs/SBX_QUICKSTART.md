# Docker Sandboxes + USAi Quick Start

This guide gets you from zero to running an AI agent inside Docker Sandboxes with USAi in under 5 minutes.

## What is Docker Sandboxes?

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) runs AI coding agents in isolated microVM environments. Each sandbox gets its own Docker daemon, filesystem, and network—the agent can build containers, install packages, and modify files without touching your host system.

There are **two ways** to use Docker Sandboxes:

| Method | Install | Command Prefix | Best For |
|--------|---------|----------------|----------|
| **Docker Desktop built-in** | None (Docker Desktop 4.58+) | `docker sandbox` | Quick start, GFE Macs with managed Docker |
| **Standalone sbx CLI** | Homebrew/Winget/apt | `sbx` | Full features, secret proxy, more flexibility |

> **Which should I use?** Start with `docker sandbox` if you already have Docker Desktop 4.58+. The standalone `sbx` CLI offers additional features like the secret proxy (for GitHub tokens) and more granular control. Both work for basic USAi usage.

## Prerequisites

**Choose one:**
- **Docker Desktop 4.58+** (`docker --version` to check) — sandboxes built-in, no extra install
- **Standalone sbx CLI** (`sbx --version` to check) — install via Homebrew/Winget/apt

**Plus:**
- USAi API key (set as `USAI_API_KEY` environment variable on host)
- This repository cloned locally
- (Optional) GitHub CLI logged in (`gh auth status`)
- (Optional) GitLab CLI logged in (`glab auth status`)

## Installing Docker Sandboxes

### Option A: Docker Desktop Built-in (No Extra Install)

If you have **Docker Desktop 4.58 or later**, sandboxes are already included. Verify:

```bash
docker sandbox --help
```

> **Note:** On some managed Docker installations (like GSA GFE Macs), the command is `docker sandbox` (two words), not `docker sbx`. If `docker sbx` returns "unknown command", try `docker sandbox`.

### Option B: Standalone sbx CLI (More Features)

The standalone CLI offers additional features (secret proxy, network policies) and doesn't require Docker Desktop.

**macOS (Homebrew):**
```bash
brew install docker/tap/sbx
sbx login
```

**Windows (Winget):**
```powershell
winget install -h Docker.sbx
sbx login
```

**Linux (Ubuntu):**
```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm $USER
newgrp kvm
sbx login
```

See [Docker Sandboxes documentation](https://docs.docker.com/ai/sandboxes/) for full details.

## Network Policy Configuration (Important!)

When you first run a sandbox command, you'll be prompted to choose a network policy:

```
Choose a default network policy:
     1. Open         — All network traffic allowed, no restrictions.
     2. Balanced     — Default deny, with common dev sites allowed.
     3. Locked Down  — All network traffic blocked unless you allow it.
```

### Recommended: Choose "Balanced" (Option 2)

> **⚠️ Do NOT choose "Open" on GFE machines.** The "Open" policy allows the agent to access internal GSA network resources, which is a security risk.

After selecting "Balanced", you must add the USAi endpoint to the allowlist:

```bash
# Allow USAi API endpoint (required for USAi to work)
sbx policy allow network "api.gsa.usai.gov"

# Verify your policy rules
sbx policy ls
```

### If You Already Chose "Open"

Reset your policy and reconfigure:

```bash
# Reset to default (will prompt for policy choice again)
sbx policy reset

# Choose "Balanced" when prompted, then add USAi
sbx policy allow network "api.gsa.usai.gov"
```

### Full Allowlist for USAi

For the complete USAi experience (USAi + GitHub + package managers):

```bash
sbx policy allow network "api.gsa.usai.gov"
sbx policy allow network "api.github.com"
sbx policy allow network "github.com"
```

The "Balanced" policy already includes common package managers (npm, pypi) and container registries.

## Quick Start

### Using Docker Desktop (`docker sandbox`)

```bash
# 1. Set your API key in your shell config file (~/.bashrc or ~/.zshrc)
echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.zshrc
source ~/.zshrc

# 2. IMPORTANT: Restart Docker Desktop completely (Quit → Reopen)
#    Docker reads env vars at startup, not from your current shell

# 3. Configure network policy (first run will prompt - choose "Balanced")
#    Then add USAi to the allowlist:
sbx policy allow network "api.gsa.usai.gov"

# 4. Create a sandbox for OpenCode in current directory
docker sandbox create --name usai-test opencode .

# 5. Run OpenCode (connects to the sandbox)
docker sandbox run usai-test
```

> **Common mistake:** Setting `export USAI_API_KEY=...` in your terminal isn't enough for Docker Desktop. You must:
> 1. Add it to `~/.bashrc` or `~/.zshrc`
> 2. Source the file
> 3. **Completely restart Docker Desktop** (not just the terminal)

### Using Standalone CLI (`sbx`) — Recommended

```bash
# 1. Set your API key (export works for sbx CLI)
export USAI_API_KEY="your-api-key-here"

# 2. Configure network policy (first run will prompt - choose "Balanced")
#    Then add USAi to the allowlist:
sbx policy allow network "api.gsa.usai.gov"

# 3. Create a sandbox for OpenCode in current directory
sbx create --name usai-test opencode .

# 4. Run OpenCode with API key injection
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) usai-test opencode
```

That's it. You're now running an AI agent in an isolated container with USAi access.

> **Important:** USAi requires manual API key injection because it uses a custom endpoint. SBX's built-in secret proxy only works with standard provider endpoints (OpenAI, Anthropic, etc.).

### Command Comparison Reference

| Action | Docker Desktop | Standalone sbx CLI |
|--------|----------------|--------------------|
| Create sandbox | `docker sandbox create --name NAME opencode .` | `sbx create --name NAME opencode .` |
| Run/connect | `docker sandbox run NAME` | `sbx run NAME` |
| Run with env vars | Set in shell config + restart Docker | `sbx exec -it -e VAR="$VAR" NAME cmd` |
| List sandboxes | `docker sandbox ls` | `sbx ls` |
| Stop sandbox | (sandboxes auto-stop) | `sbx stop NAME` |
| Remove sandbox | `docker sandbox rm NAME` | `sbx rm NAME` |
| Set secrets | N/A (use shell config) | `sbx secret set -g SERVICE` |
| Reset all | `docker sandbox reset` | (remove individually) |

## Credential Injection Overview

How credentials are handled differs between Docker Desktop and the standalone CLI:

### Docker Desktop (`docker sandbox`)

Docker Desktop reads environment variables from your shell configuration file (`~/.bashrc`, `~/.zshrc`) at startup. The sandbox proxy injects credentials into API requests, so keys stay on your host.

```bash
# Add to ~/.bashrc or ~/.zshrc
export USAI_API_KEY="your-api-key"
export ANTHROPIC_API_KEY="your-key"  # if using Claude directly
export GH_TOKEN="your-github-token"  # for GitHub access
```

After adding variables, **source your config and restart Docker Desktop**.

### Standalone CLI (`sbx`)

The `sbx` CLI supports two methods:

| Method | Security | Use Case | Supported Services |
|--------|----------|----------|-------------------|
| **SBX Proxy** (recommended) | High - agent never sees token | Standard API endpoints | `anthropic`, `aws`, `cursor`, `github`, `google`, `groq`, `mistral`, `nebius`, `openai`, `xai` |
| **Direct Injection** (`-e`) | Medium - token in container env | Custom endpoints (USAi, GitLab) | Any service |

**Rule of thumb:** Use SBX proxy when available; use direct injection for custom endpoints like USAi.

---

## Git Provider Credentials (GitHub / GitLab)

Agents often need git credentials for cloning private repos, creating PRs, or pushing changes. Here's how to inject them securely.

### GitHub (github.com)

#### Using Docker Desktop

Add to your shell config and restart Docker Desktop:

```bash
# Add to ~/.bashrc or ~/.zshrc
export GH_TOKEN="$(gh auth token)"
# Or use a personal access token directly
export GITHUB_TOKEN="your-github-pat"
```

#### Using Standalone sbx CLI

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

GitLab is **NOT a built-in service** for either method, so you must use direct injection/shell config:

#### Using Docker Desktop

```bash
# Add to ~/.bashrc or ~/.zshrc
export GITLAB_TOKEN="your-gitlab-token"
export GITLAB_HOST="workshop.cloud.gov"  # for self-hosted
```

#### Using Standalone sbx CLI

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

### Combined: USAi + GitHub + GitLab (sbx CLI)

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

| Provider | Docker Desktop | sbx CLI (Proxy) | sbx CLI (Direct) |
|----------|----------------|-----------------|------------------|
| GitHub | `GH_TOKEN` in shell config | `sbx secret set -g github` | `-e GH_TOKEN="$(gh auth token)"` |
| GitLab.com | `GITLAB_TOKEN` in shell config | Not supported | `-e GITLAB_TOKEN="..."` |
| GitLab (self-hosted) | `GITLAB_TOKEN` + `GITLAB_HOST` | Not supported | `-e GITLAB_TOKEN="..." -e GITLAB_HOST="..."` |

---

## Step-by-Step Walkthrough

### Step 1: Set Your API Key (on Host)

**On your host machine** (not inside the container):

```bash
# Option A: Export for current session (sbx CLI only)
export USAI_API_KEY="your-api-key-here"

# Option B: Add to shell profile (required for Docker Desktop, recommended for both)
# For bash:
echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.bashrc
source ~/.bashrc

# For zsh:
echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.zshrc
source ~/.zshrc
```

> **Docker Desktop users:** After adding to your shell config, **restart Docker Desktop** so it picks up the new variable.

**Verify it's set** (safe command - only shows length):
```bash
echo "Key is set: ${USAI_API_KEY:+yes}"
echo "Key length: ${#USAI_API_KEY}"
```

### Step 2: Create a Sandbox

Both methods require specifying an agent type and workspace path:

```bash
cd /path/to/your-project

# Docker Desktop
docker sandbox create --name my-sandbox opencode .

# OR Standalone sbx CLI
sbx create --name my-sandbox opencode .

# Verify it exists
docker sandbox ls   # Docker Desktop
sbx ls              # Standalone CLI
```

**Available agents:** `claude`, `codex`, `copilot`, `docker-agent`, `gemini`, `kiro`, `opencode`, `shell`

### Step 3: Configure Git Provider Secrets (Optional)

If your agent needs to interact with GitHub:

**Docker Desktop:** Add `GH_TOKEN` to your shell config and restart Docker Desktop.

**Standalone sbx CLI:**
```bash
# Recommended: Use SBX proxy for GitHub
gh auth token | sbx secret set -g github
```

### Step 4: Run OpenCode with USAi

**Docker Desktop:**
```bash
# Simply run (environment variables come from shell config)
docker sandbox run my-sandbox
```

**Standalone sbx CLI:**

USAi uses a custom endpoint, so you must inject the API key manually:

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

#### Docker Desktop (`docker sandbox`)

```bash
# Create a sandbox
docker sandbox create --name my-sandbox opencode .

# Run/connect to sandbox
docker sandbox run my-sandbox

# List sandboxes
docker sandbox ls

# Execute a command in sandbox
docker sandbox exec -it my-sandbox bash

# Remove a sandbox
docker sandbox rm my-sandbox

# Reset all sandboxes
docker sandbox reset
```

#### Standalone CLI (`sbx`)

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

### Secret Management (sbx CLI only)

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

### Environment Variable Injection (sbx CLI)

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

#### Docker Desktop

```bash
# Run sandbox (uses env vars from shell config)
docker sandbox run SANDBOX_NAME

# Execute a command
docker sandbox exec -it SANDBOX_NAME bash

# Pass agent-specific options (use -- separator)
docker sandbox run SANDBOX_NAME -- --continue
```

#### Standalone sbx CLI

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

#### Docker Desktop

```bash
# Shell into sandbox
docker sandbox exec -it SANDBOX_NAME bash

# Check environment variables
docker sandbox exec -it SANDBOX_NAME bash -c 'echo "USAI key length: ${#USAI_API_KEY}"'

# Check workspace contents
docker sandbox exec -it SANDBOX_NAME ls -la

# View network activity
docker sandbox network log
```

#### Standalone sbx CLI

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

### Network policy blocks USAi API / Connection errors

**Problem:** Getting connection refused, timeout, or unauthorized errors when trying to reach USAi.

**Root Cause:** The "Balanced" network policy blocks unknown endpoints by default. USAi (`api.gsa.usai.gov`) must be explicitly allowed.

**Fix:**
```bash
# Add USAi to the allowlist
sbx policy allow network "api.gsa.usai.gov"

# Verify it was added
sbx policy ls
```

### Chose "Open" policy by mistake

**Problem:** You selected "Open" network policy, which is a security risk on GFE machines (allows access to internal GSA resources).

**Fix:** Reset and reconfigure:
```bash
# Reset policy (will prompt for new choice)
sbx policy reset

# Choose "Balanced" when prompted, then add USAi
sbx policy allow network "api.gsa.usai.gov"
```

### "docker: unknown command: docker sbx"

**Problem:** Running `docker sbx` returns "unknown command".

**Fix:** The correct command is `docker sandbox` (two words), not `docker sbx`. If that also doesn't work:
1. Check Docker Desktop version: `docker --version` (need 4.58+)
2. Verify the plugin exists: `ls ~/.docker/cli-plugins/docker-sandbox`
3. Alternatively, install the standalone `sbx` CLI via Homebrew:
   ```bash
   brew install docker/tap/sbx
   ```

### "unknown agent" error

**Problem:** `docker sandbox create usai-test` or `sbx create usai-test` fails with "unknown agent".

**Fix:** You must specify an agent type. Use:
```bash
# Docker Desktop
docker sandbox create --name usai-test opencode .

# Standalone CLI
sbx create --name usai-test opencode .
```

### OpenCode shows generic providers, not USAi

**Problem:** OpenCode starts but shows OpenAI, Anthropic, etc. instead of USAi models.

**Root Cause:** Either:
1. API key not injected properly
2. Config file not found
3. Working directory not set (sbx CLI)
4. Docker Desktop not restarted after setting env var

**Fix for Docker Desktop:**
1. Ensure `USAI_API_KEY` is in `~/.bashrc` or `~/.zshrc`
2. Source the file: `source ~/.zshrc`
3. **Restart Docker Desktop completely** (Quit → Reopen, not just close terminal)
4. Run: `docker sandbox run usai-test`

**Fix for sbx CLI:**
```bash
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) usai-test opencode
```

Verify the config exists:
```bash
# Docker Desktop
docker sandbox exec -it usai-test cat /path/to/opencode.jsonc

# sbx CLI
sbx exec usai-test cat $(pwd)/opencode.jsonc
```

### "API key not found" or authentication errors

**Problem:** Agent can't authenticate to USAi.

**Fix for Docker Desktop:**
1. Add to shell config: `export USAI_API_KEY="your-key"`
2. Source config and **restart Docker Desktop**

**Fix for sbx CLI:**
```bash
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) usai-test opencode
```

Verify your key is set on the host:
```bash
echo "Key length: ${#USAI_API_KEY}"
```

### GitHub API returns 401 Unauthorized

**Problem:** GitHub API calls fail despite having `gh` logged in.

**Fix for Docker Desktop:**
Add `GH_TOKEN` or `GITHUB_TOKEN` to your shell config and restart Docker Desktop.

**Fix for sbx CLI:**
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

## Pre-commit Hooks (Optional)

This repository includes an optional pre-commit configuration that provides:
- Secret detection (via gitleaks)
- Basic file hygiene checks (trailing whitespace, end-of-file-fixer, YAML/JSON validation)

**Important:** Pre-commit hooks are **opt-in** and do NOT auto-install during `make setup`.

### Why Optional?

Pre-commit hooks can interfere with user workflows, especially when:
- Users have their own pre-commit configurations
- Agents commit code on behalf of users
- Hooks require dependencies not available in all environments

By making hooks opt-in, users can:
- Learn from the example configuration
- Test pre-commit without commitment
- Decide if it fits their workflow

### Installing Pre-commit in SBX

If you're working inside a Docker Sandbox and want to use pre-commit:

```bash
# Install pre-commit (inside sandbox)
pip install pre-commit

# Install the hooks (from repo root)
pre-commit install

# Or use the make target (from repo root)
make install-hooks
```

### Running Checks Without Installing Hooks

You can run pre-commit checks on-demand without installing the hooks:

```bash
# Run all hooks on all files
pre-commit run --all-files

# Run all hooks on staged files only
pre-commit run

# Run a specific hook
pre-commit run gitleaks --all-files
```

This is useful for:
- Testing the configuration before installing hooks
- One-time checks before pushing
- CI/CD validation without hook installation

### Using Pre-commit with OpenCode

If you're using OpenCode inside SBX, the agent can run pre-commit checks on your behalf:

```bash
# After creating a sandbox and installing pre-commit
sbx exec SANDBOX_NAME pre-commit run --all-files
```

The agent should be configured to run pre-commit checks before committing if hooks are installed. If hooks are not installed, the agent will commit normally.

### Configuration Details

The `.pre-commit-config.yaml` file uses SHA-pinned revisions for security:

- **pre-commit-hooks v6.0.0**: Basic file hygiene
- **gitleaks v8.24.3**: Secret detection

To update hook versions, edit `.pre-commit-config.yaml` and update both the rev (SHA) and the version comment.

### Troubleshooting

**"pre-commit: command not found"**

Install pre-commit first:
```bash
pip install pre-commit
```

**Hooks failing on existing files**

Pre-commit may flag issues in existing files. Fix them or use:
```bash
# Run once to auto-fix what can be fixed
pre-commit run --all-files

# Then stage the fixes
git add -u
```

**Gitleaks false positives**

If gitleaks detects a false positive, add it to `.gitleaksignore`:
```bash
echo "path/to/file:line-number" >> .gitleaksignore
```

---

## Next Steps

- Read `AGENTS.md` for full behavioral rules
- Check `docs/KNOWN_FAILURE_MODES.md` if something breaks
- Review `docs/adr/0001-sbx-usai-agent-execution-architecture.md` for architecture rationale
