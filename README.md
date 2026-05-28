# Agentic Coding Quickstart

> **Audience:** GSA teams using AI coding agents
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi

This quickstart gets you from zero to running an AI coding agent with USAi in under 5 minutes using Docker Sandboxes.

## Agentic Coding Ecosystem

This repository is part of a three-repo ecosystem:

| Repo | Purpose | When to Use |
|------|---------|-------------|
| **[Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart)** (you are here) | Get running | First day setup, sbx + USAi config |
| **[Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)** | Do it right | Repo setup, standards, best practices |
| **[Patterns](https://github.com/GSA-TTS/agentic-coding-patterns)** | Share & learn | Community patterns, lessons learned |

**Your journey:** Start here (Quickstart) to get your environment working, then use the Playbook to set up your projects properly, and visit Patterns to share what you learn.

---

## 5-Minute Quickstart

### Step 1: Install sbx CLI

The `sbx` CLI is a standalone tool — Docker Desktop is **not required**.

```bash
# macOS
brew install docker/tap/sbx && sbx login

# Windows
winget install -h Docker.sbx && sbx login

# Linux (Ubuntu)
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm $USER && newgrp kvm
sbx login
```

> [!NOTE]
> `sbx login` requires a Docker account. Docker Desktop is not required, but if you have it,
> your Docker subscription covers sbx licensing.

### Step 2: Configure and Run

```bash
# 1. Set network policy (first-time only)
sbx policy set-default balanced

# 2. Allow USAi endpoint
sbx policy allow network -g "api.gsa.usai.gov"

# 3. Store your USAi API key securely (USAi is a custom endpoint, not built-in)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"

# 4. Store GitHub token (for code access)
gh auth token | sbx secret set -g github

# 5. Start a sandbox in your project
cd /path/to/your/project
sbx run opencode .
```

> [!NOTE]
> USAi is not a built-in sbx service, so we use `sbx secret set-custom` instead of `sbx secret set -g`.
> If you change the secret, you must **delete and recreate** the sandbox for it to take effect.

That's it. You're now running an AI coding agent in an isolated container with USAi access.

**Need more details?** See the [Full sbx CLI Guide](docs/QUICKSTART_SBX.md).

> [!WARNING]
> **Docker Desktop `docker sandbox` commands are deprecated.** Use the `sbx` CLI instead.
> See [Docker's deprecation notice](https://docs.docker.com/reference/cli/docker/sandbox/).

---

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. Running them in sandboxes provides:

- **Isolation** — Agent can't access your full system
- **Secret protection** — API keys injected via proxy, never touch disk
- **Reproducibility** — Same environment every time
- **Audit trail** — Clear boundaries for what the agent can do

---

## Prerequisites

| Requirement | How to Check | Notes |
|-------------|--------------|-------|
| sbx CLI | `sbx version` | Standalone tool, Docker Desktop not required |
| USAi API key | From your GSA account | Stored via `sbx secret` |
| GitHub token | `gh auth status` | Optional, for code access |

---

## What's in This Repo

| File/Directory | Purpose |
|----------------|---------|
| `opencode.jsonc` | Pre-configured for USAi endpoints |
| `.zed/tasks.json` | Pre-configured tasks for **Zed Editor** |
| `.pre-commit-config.yaml` | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md` | Behavioral rules the agent follows |
| `docs/QUICKSTART_SBX.md` | Full sbx CLI setup guide |
| `docs/QUICKSTART_DOCKER_DESKTOP.md` | ~~Docker Desktop setup guide~~ (deprecated) |
| `docs/ZED_SETUP.md` | **Zed Editor** integration guide |
| `docs/KNOWN_FAILURE_MODES.md` | Troubleshooting guide |
| `templates/` | Files to copy into your own projects |

---

## Zed Editor Integration (Optional)

If you use the **Zed Editor**, pre-configured tasks are available in `.zed/tasks.json`:

- **OpenCode: Run Agent** — Launch the agent in your sandbox
- **OpenCode: Create Sandbox** — Create a new sandbox
- **OpenCode: Environment Diagnostics** — Run `make doctor`

See the **[Zed Editor Setup Guide](docs/ZED_SETUP.md)** for detailed instructions.

---

## Security Model

1. **All execution inside sbx containers** — Isolated from your host system
2. **Authorized endpoints only** — USAi, GitHub (via proxy)
3. **Secret proxy** — Agent never sees raw API keys when using `sbx secret`
4. **Agent follows AGENTS.md rules** — Explicit permissions and prohibitions

For Git provider credentials and advanced patterns, see [docs/QUICKSTART_SBX.md](docs/QUICKSTART_SBX.md).

---

## Troubleshooting

### Network policy blocks USAi

```bash
sbx policy allow network -g "api.gsa.usai.gov"
```

> Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent.

### "docker: unknown command: docker sbx" or "docker sandbox deprecated"

The `docker sandbox` command is deprecated. Install and use the standalone `sbx` CLI instead:

```bash
# macOS
brew install docker/tap/sbx

# Windows
winget install Docker.sbx
```

Then use `sbx` commands directly (e.g., `sbx run opencode .` instead of `docker sandbox run opencode .`).

### OpenCode shows wrong providers

Ensure you're in a directory with `opencode.jsonc`. For sbx, the workspace is auto-mounted.

### Authentication failed

```bash
# Check your secret is stored
sbx secret list

# Re-set if needed
sbx secret set -g anthropic
```

For more troubleshooting, see [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md).

---

## Bootstrap Your Own Project

Want to use sbx + USAi in your own repository? Use the `init-project.sh` script to automatically provision any directory (new or existing) with all necessary configuration files.

### Quick Start

```bash
# Provision a new or existing project directory
./init-project.sh /path/to/your/project
```

### What Gets Provisioned

The script copies these files to your target directory:

| File | Purpose |
|------|---------|
| `AGENTS.md` | Behavioral rules for AI agents |
| `opencode.jsonc` | Pre-configured USAi endpoints |
| `Makefile` | Helper commands (`make setup`, `make doctor`, etc.) |
| `.zed/tasks.json` | Zed Editor task integration |
| `README.md` | Generated project README (only if it doesn't exist) |

The script also:
- Initializes a git repository (if not already initialized)
- Preserves existing files (won't overwrite your README.md)
- Works with both empty and populated directories

### Example

```bash
# From the quickstart directory
cd /path/to/agentic-coding-quickstart

# Provision your project
./init-project.sh /path/to/my-existing-app

# Result:
# [OK] AGENTS.md
# [OK] opencode.jsonc
# [OK] Makefile
# [OK] .zed/tasks.json
# [OK] Git repository initialized (if needed)
```

### Next Steps After Provisioning

```bash
cd /path/to/your/project
make setup    # Clone playbook and check dependencies
make doctor   # Verify your environment
```

**Alternative (Manual):** If you prefer manual setup, see [templates/BOOTSTRAP.md](templates/BOOTSTRAP.md) for detailed instructions.

---

## What's Next?

1. **Set up your project properly** — Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
2. **Share what you learn** — Contribute to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** — Found something unclear? Open an issue or submit a PR

---

## Getting Help

1. **Troubleshooting:** [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)
2. **Agent behavior:** [AGENTS.md](AGENTS.md)
3. **Questions:** [agentic-coding Slack channel](https://gsa.enterprise.slack.com/archives/C0B44531QLE)
4. **Platform issues:** support@usai.gov

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

**Data Classification:** Internal/Non-sensitive
# CI trigger
