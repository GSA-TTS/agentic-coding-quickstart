# Agentic Coding Quickstart

> **Audience:** Government developers in the USAi pilot program  
> **Purpose:** Get AI coding agents running safely on your local machine in under 5 minutes

This guide helps you use AI coding agents (like OpenCode) inside isolated Docker sandboxes, connecting to government-approved API endpoints (USAi).

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. Running them in sandboxes provides:

- **Isolation:** Agent can't access your full system
- **Secret protection:** API keys never touch disk or logs
- **Reproducibility:** Same environment every time
- **Audit trail:** Clear boundaries for what the agent can do

## What is Docker Sandboxes?

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) runs AI coding agents in isolated microVM environments. Each sandbox gets its own Docker daemon, filesystem, and network—the agent can build containers, install packages, and modify files without touching your host system.

There are **two ways** to use Docker Sandboxes:

| Method | Install | Command Prefix | Best For |
|--------|---------|----------------|----------|
| **Docker Desktop built-in** | None (Docker Desktop 4.58+) | `docker sandbox` | Quick start, GFE Macs with managed Docker |
| **Standalone sbx CLI** | Homebrew/Winget/apt | `sbx` | Full features, more flexibility |

**Recommended:** Start with `docker sandbox` if you already have Docker Desktop. Upgrade to `sbx` CLI later if you need advanced features.

## Prerequisites

- **Docker Desktop 4.58+** (check: `docker --version`) — OR — **sbx CLI** installed (`sbx --version`)
- **USAi API key** from your agency's pilot program
- **Docker** running locally

## Installing Docker Sandboxes

### Option A: Docker Desktop Built-in (Recommended for GFE Macs)

If you have **Docker Desktop 4.58 or later**, sandboxes are already built-in. No extra installation needed.

```bash
# Verify you have the sandbox command
docker sandbox --help
```

> **Note:** On some managed Docker installations, the command is `docker sandbox` (two words), not `docker sbx`.

### Option B: Standalone sbx CLI (More Features)

The standalone CLI offers more features and doesn't require Docker Desktop:

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

See [Docker Sandboxes documentation](https://docs.docker.com/ai/sandboxes/) for full installation details.

## Quick Start

### Step 1: Configure Network Policy (Required)

When you first run a sandbox command, you'll be prompted to choose a network policy. **Do not choose "Open"** — it allows access to internal GSA resources, which is a security risk on GFE.

Choose **"Balanced"** or **"Locked Down"**, then add the USAi endpoint:

```bash
# Allow USAi API endpoint (required for both methods)
sbx policy allow network "api.gsa.usai.gov"
```

> **Why not "Open"?** On GFE machines, "Open" allows the agent to access internal GSA network resources. Always use "Balanced" with explicit allowlist entries.

### Step 2: Set Your API Key

**For sbx CLI:** Export in your current terminal session:
```bash
export USAI_API_KEY="your-api-key-here"
```

**For Docker Desktop:** Add to your shell config AND restart Docker Desktop:
```bash
# Add to ~/.bashrc or ~/.zshrc
echo 'export USAI_API_KEY="your-api-key-here"' >> ~/.zshrc
source ~/.zshrc

# IMPORTANT: Restart Docker Desktop (Quit and reopen)
# Docker reads env vars at startup, not from your current shell
```

> **Common mistake:** Setting the env var in your terminal isn't enough for Docker Desktop. You must add it to your shell config file AND restart Docker Desktop.

### Step 3: Create and Run Sandbox

**Using Standalone CLI (`sbx`) — Recommended:**

```bash
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
sbx create --name quickstart opencode .
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) quickstart opencode
```

**Using Docker Desktop (`docker sandbox`):**

```bash
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
docker sandbox create --name quickstart opencode .
docker sandbox run quickstart
```

That's it. You're now running an AI coding agent in an isolated container with USAi access.

### Command Comparison

| Action | Docker Desktop | Standalone sbx CLI |
|--------|----------------|--------------------|
| Create sandbox | `docker sandbox create --name NAME opencode .` | `sbx create --name NAME opencode .` |
| Run/connect | `docker sandbox run NAME` | `sbx run NAME` |
| Run with env vars | (set in shell config, restart Docker) | `sbx exec -it -e VAR="$VAR" NAME cmd` |
| List sandboxes | `docker sandbox ls` | `sbx ls` |
| Remove sandbox | `docker sandbox rm NAME` | `sbx rm NAME` |
| Set secrets | N/A (use shell config) | `sbx secret set -g SERVICE` |

## What's in This Repo

| File | Purpose |
|------|---------|
| `opencode.jsonc` | Pre-configured for USAi endpoints |
| `AGENTS.md` | Behavioral rules the agent follows |
| `docs/SBX_QUICKSTART.md` | Detailed setup walkthrough |
| `docs/KNOWN_FAILURE_MODES.md` | Troubleshooting guide |
| `docs/CODING_PRACTICES.md` | Secure coding standards |
| `templates/` | Files to copy into your own projects |

## Bootstrap Your Own Project

Want to use SBX + USAi in your own repository? Copy the template files:

```bash
# Set your target repo path
TARGET_REPO="/path/to/your/project"

# Copy the OpenCode config
cp templates/opencode.jsonc "$TARGET_REPO/"

# Copy the SBX patterns reference
mkdir -p "$TARGET_REPO/docs"
cp templates/SBX_PATTERNS.md "$TARGET_REPO/docs/"

# If you have an existing AGENTS.md, append the SBX addendum (skip the header)
tail -n +6 templates/AGENTS_SBX_ADDENDUM.md >> "$TARGET_REPO/AGENTS.md"
```

See [templates/BOOTSTRAP.md](templates/BOOTSTRAP.md) for detailed instructions.

### For Playbook Users

If you've bootstrapped your project using the [Agentic Coding Playbook](https://github.com/GSA-TTS/agentic-coding-playbook), the quickstart templates complement it:

- **Playbook** → Project structure, AGENTS.md, coding practices, risk assessment
- **Quickstart** → USAi configuration, SBX patterns, credential injection

## Key Commands

### Docker Desktop (`docker sandbox`)

```bash
# Create a sandbox
docker sandbox create --name my-sandbox opencode .

# Run/connect to sandbox
docker sandbox run my-sandbox

# List your sandboxes
docker sandbox ls

# Remove a sandbox
docker sandbox rm my-sandbox

# Reset all sandboxes
docker sandbox reset
```

### Standalone CLI (`sbx`)

```bash
# Create a sandbox
sbx create --name my-sandbox opencode .

# Run OpenCode (always use this pattern for USAi)
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) my-sandbox opencode

# List your sandboxes
sbx ls

# Stop a sandbox
sbx stop my-sandbox

# Remove a sandbox
sbx rm my-sandbox
```

## Security Model

1. **All execution happens inside SBX containers** - isolated from your host
2. **Authorized endpoints only** - USAi, GitHub (via proxy), GitLab (via direct injection)
3. **Agent follows AGENTS.md rules** - explicit permissions and prohibitions

### Git Provider Credentials

For agents that need GitHub or GitLab access:

```bash
# GitHub (recommended: use SBX proxy)
gh auth token | sbx secret set -g github

# GitLab (direct injection required)
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) my-sandbox opencode
```

See [docs/SBX_QUICKSTART.md](docs/SBX_QUICKSTART.md) for full credential injection patterns.

### Known Limitation: API Key Visibility

**Risk:** With the current SBX tooling, the USAi API key is injected directly into the container environment via `-e USAI_API_KEY="$USAI_API_KEY"`. This means the agent process *can* read the key from the environment.

**Why this happens:** SBX's secret proxy only supports a fixed set of services (OpenAI, Anthropic, etc.) with hardcoded endpoints. Custom endpoints like USAi (`api.gsa.usai.gov`) bypass the proxy entirely.

**Mitigations in place:**
- Key is never written to disk or config files
- `AGENTS.md` rules prohibit the agent from printing/logging secrets
- Container isolation limits exposure scope
- Key only exists in memory during execution

**Upstream tracking:** This limitation is tracked in [docker/sbx-releases#35](https://github.com/docker/sbx-releases/issues/35) - "Feature Request: Configurable Secret Injection for Custom Services"

**Future state:** When SBX supports custom service mappings, we can use true proxy-based injection where the agent never sees the raw key.

## Troubleshooting

**Network policy errors / "Balanced" policy blocks USAi**
- Add the USAi endpoint to your allowlist: `sbx policy allow network "api.gsa.usai.gov"`
- Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent

**"docker: unknown command: docker sbx"**
- Use `docker sandbox` (two words), not `docker sbx`
- If that doesn't work, verify Docker Desktop version: `docker --version` (need 4.58+)
- Alternatively, install the standalone `sbx` CLI via Homebrew

**OpenCode shows wrong providers (OpenAI, Anthropic, etc.)**
- Make sure you're in this repo's directory
- For `sbx`: Use `-w $(pwd)` to set the working directory
- For `docker sandbox`: The workspace is auto-mounted
- Verify `opencode.jsonc` exists

**Authentication failed / Unauthorized errors**
- Check your API key: `echo "Length: ${#USAI_API_KEY}"`
- For `sbx`: Ensure you're using `-e USAI_API_KEY="$USAI_API_KEY"` flag
- For `docker sandbox`: 
  1. Add the key to `~/.bashrc` or `~/.zshrc` (not just `export` in terminal)
  2. Run `source ~/.zshrc`
  3. **Restart Docker Desktop completely** (Quit → Reopen)
  4. Then run `docker sandbox run quickstart`

**"Unknown agent" error**
- Use: `docker sandbox create --name NAME opencode .` or `sbx create --name NAME opencode .`
- Note the `opencode .` at the end (agent type and workspace path)

See `docs/KNOWN_FAILURE_MODES.md` for more troubleshooting help.

## Pilot Scope

This quickstart is part of a **limited government pilot** for evaluating AI coding agents. Current constraints:

- **Authorized endpoints only** - USAi, GitHub, and approved GitLab instances
- **Local development only** - not for production use
- **Pattern validation** - documenting what works and what doesn't

## Getting Help

- Check `docs/KNOWN_FAILURE_MODES.md` first
- Review `AGENTS.md` for agent behavior rules
- Contact your pilot program coordinator

## Contributing

Found a failure mode we haven't documented? Please add it to `docs/KNOWN_FAILURE_MODES.md` with:
1. Symptoms
2. Root cause
3. Fix

---

**Impact Level:** FIPS Low | **Data Classification:** Internal/Non-sensitive | **ATO Status:** Pre-ATO (pilot)
