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

## 5-Minute Quickstart (sbx CLI) — Recommended

Already have Docker Desktop 4.41+? Run these commands:

```bash
# 1. Set network policy (first-time only)
sbx policy set-default balanced

# 2. Allow USAi endpoint
sbx policy allow network -g "api.gsa.usai.gov"

# 3. Store your USAi API key securely
sbx secret set -g anthropic
# When prompted, enter your USAi API key

# 4. Store GitHub token (for code access)
sbx secret set -g github
# When prompted, paste output of: gh auth token

# 5. Start a sandbox in your project
cd /path/to/your/project
sbx run opencode .
```

That's it. You're now running an AI coding agent in an isolated container with USAi access.

**Need more details?** See the [Full sbx CLI Guide](docs/QUICKSTART_SBX.md).

**Prefer Docker Desktop UI?** See the [Docker Desktop Guide](docs/QUICKSTART_DOCKER_DESKTOP.md).

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
| Docker Desktop 4.41+ | `docker --version` | Includes sbx CLI |
| USAi API key | From your GSA account | Stored via `sbx secret` |
| GitHub token | `gh auth status` | Optional, for code access |

**Installing sbx CLI (if not bundled):**

```bash
# macOS
brew install docker/tap/sbx && sbx login

# Windows
winget install -h Docker.sbx && sbx login
```

---

## What's in This Repo

| File/Directory | Purpose |
|----------------|---------|
| `opencode.jsonc` | Pre-configured for USAi endpoints |
| `.zed/tasks.json` | Pre-configured tasks for **Zed Editor** |
| `.pre-commit-config.yaml` | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md` | Behavioral rules the agent follows |
| `docs/QUICKSTART_SBX.md` | Full sbx CLI setup guide |
| `docs/QUICKSTART_DOCKER_DESKTOP.md` | Docker Desktop setup guide |
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

For Git provider credentials and advanced patterns, see [docs/SBX_QUICKSTART.md](docs/SBX_QUICKSTART.md#git-provider-credentials).

---

## Troubleshooting

### Network policy blocks USAi

```bash
sbx policy allow network -g "api.gsa.usai.gov"
```

> Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent.

### "docker: unknown command: docker sbx"

Use `docker sandbox` (two words), not `docker sbx`. Or install the standalone `sbx` CLI.

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

Want to use sbx + USAi in your own repository?

```bash
# Copy essential files from templates/
cp templates/opencode.jsonc /path/to/your/project/

# Copy Zed tasks (optional, if using Zed Editor)
mkdir -p /path/to/your/project/.zed
cp templates/zed-tasks.json /path/to/your/project/.zed/tasks.json
```

See [templates/BOOTSTRAP.md](templates/BOOTSTRAP.md) for detailed instructions.

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
