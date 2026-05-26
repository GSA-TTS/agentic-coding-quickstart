# Agentic Coding Quickstart

> **Audience:** GSA teams using AI coding agents
> **Purpose:** Get AI coding agents running safely on your local machine in under 5 minutes

This guide helps you use AI coding agents (like OpenCode) inside isolated Docker sandboxes, connecting to USAi API endpoints.

## Agentic Coding Ecosystem

This repository is part of a three-repo ecosystem:

| Repo | Purpose | When to Use |
|------|---------|-------------|
| **[Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart)** (you are here) | Get running | First day setup, SBX + USAi config |
| **[Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)** | Do it right | Repo setup, standards, best practices |
| **[Patterns](https://github.com/GSA-TTS/agentic-coding-patterns)** | Share & learn | Community patterns, lessons learned |

**Your journey:** Start here (Quickstart) to get your environment working, then use the Playbook to set up your projects properly, and visit Patterns to share what you learn with the community.

---

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
- **USAi API key** from the agentic coding program
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
| `.pre-commit-config.yaml` | Optional pre-commit hooks (secret detection, file hygiene) |
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

See the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook) for detailed project setup guidance.

## Key Commands

### Optional: Install Pre-commit Hooks

Pre-commit hooks are **opt-in** and provide secret detection and file hygiene checks:

```bash
# Install pre-commit (if not already installed)
pip install pre-commit

# Install the hooks
make install-hooks

# Or run checks without installing hooks
pre-commit run --all-files
```

See the "Pre-commit Hooks" section in [docs/SBX_QUICKSTART.md](docs/SBX_QUICKSTART.md) for details.

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

## About This Initiative

This quickstart supports GSA teams using AI coding agents for development. Current scope:

- **Authorized endpoints:** USAi, GitHub, and approved GitLab instances
- **Local development only:** Not for production use
- **Learning together:** Documenting what works and what doesn't

## Getting Help

1. **Troubleshooting:** Check `docs/KNOWN_FAILURE_MODES.md` first
2. **Agent behavior:** Review `AGENTS.md` for behavioral standards
3. **Questions:** Ask in the [agentic-coding Slack channel](https://gsa.enterprise.slack.com/archives/C0B44531QLE) (others benefit too)
4. **Improvement ideas:** Open an issue or submit a PR
5. **Platform concerns:** Contact support@usai.gov

## What's Next?

Once you have your environment working:

1. **Set up your project properly** → Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook) to configure AGENTS.md, standards, and best practices
2. **Share what you learn** → Contribute patterns to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** → Found something unclear? Fix it directly or open an issue

## Contributing

Found a failure mode we haven't documented? Have an improvement idea?

- **Fix it directly** — Submit a PR (preferred for internal repos)
- **Not sure how?** — Open an issue to discuss
- **Patterns you've discovered** — Share them in the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

---

**Data Classification:** Internal/Non-sensitive
