# OpenHands Quickstart Guide

> **For teams using OpenHands** — Run OpenHands AI-driven development agent with USAi.

This guide walks you through setting up [OpenHands](https://github.com/OpenHands/OpenHands) to work with USAi inside Docker containers.

## Why OpenHands + USAi?

OpenHands is an AI-driven development platform that provides a web-based IDE experience with powerful coding agents. It supports multiple LLM providers through OpenAI-compatible APIs, making it compatible with USAi.

> [!IMPORTANT]
> OpenHands runs as a Docker container and provides a web interface accessible via browser.
> The agent can execute code, browse the web, and interact with your development environment.

This repo ships a `.openhands/config.toml` that configures the USAi provider automatically.

**Key benefits:**

- **Web-based IDE** — Rich visual interface with terminal, file browser, and chat
- **Full agent capabilities** — Code execution, web browsing, file manipulation
- **Multiple agent types** — CodeActAgent for coding tasks, BrowsingAgent for research
- **Docker isolation** — Runs in a containerized environment

---

## Prerequisites

| Requirement | How to Check | Notes |
|-------------|--------------|-------|
| Docker | `docker --version` | Required for running OpenHands |
| USAi API key | From your GSA account | Set as `OPENAI_API_KEY` env var |
| GitHub token | `gh auth status` | Optional, for code access |

---

## Step 1: Set Environment Variables

OpenHands reads configuration from environment variables:

```bash
# Set USAi API key as OPENAI_API_KEY
export OPENAI_API_KEY="your-usai-api-key"

# Optional: Add to your shell profile for persistence
echo 'export OPENAI_API_KEY="your-usai-api-key"' >> ~/.zshrc
```

> [!IMPORTANT]
> OpenHands requires the `OPENAI_API_KEY` environment variable to be set before starting.

---

## Step 2: Configure Network (if using SBX)

If you're running OpenHands within an SBX context:

```bash
# Set default policy (first-time only)
sbx policy set-default balanced

# Allow USAi endpoint
sbx policy allow network -g "api.gsa.usai.gov"
```

---

## Step 3: Run OpenHands

### Using Make (Recommended)

```bash
# From the quickstart directory
make run-openhands
```

This starts OpenHands with:
- USAi as the LLM provider
- Default model: `openai/gpt-5.4-latest-guardrails-defaultv2`
- Web interface at http://localhost:3000

### Manual Docker Run

```bash
docker run -it --pull always \
  -e LLM_MODEL="openai/gpt-5.4-latest-guardrails-defaultv2" \
  -e LLM_BASE_URL="https://api.gsa.usai.gov/api/v1" \
  -e LLM_API_KEY="$OPENAI_API_KEY" \
  -e WORKSPACE_MOUNT_PATH="$(pwd)" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands:/.openhands \
  -v "$(pwd)":/opt/workspace_base \
  -p 3000:3000 \
  --add-host host.docker.internal:host-gateway \
  ghcr.io/openhands/openhands:latest
```

Then open http://localhost:3000 in your browser.

---

## How It Works

| What | Value | Purpose |
|------|-------|---------|
| `LLM_API_KEY` | Your USAi API key | Authentication |
| `LLM_BASE_URL` | `https://api.gsa.usai.gov/api/v1` | Routes requests to USAi |
| `LLM_MODEL` | `openai/gpt-5.4-latest-guardrails-defaultv2` | USAi model selection |
| `WORKSPACE_MOUNT_PATH` | Your project directory | Working directory for the agent |

OpenHands loads configuration from environment variables and `.openhands/config.toml` in the project root.

---

## Model Selection

USAi exposes OpenAI models with specific names. Specify a USAi model name via the `LLM_MODEL` environment variable or Make override:

```bash
# Override model via Make
make run-openhands OPENHANDS_MODEL=openai/gpt-5.2-latest-guardrails-defaultv2
```

Available models via USAi (check your entitlements):

| USAi Model Name | Description |
|----------------|-------------|
| `openai/gpt-5.4-latest-guardrails-defaultv2` | GPT-5.4 with guardrails |
| `openai/gpt-5.2-latest-guardrails-defaultv2` | GPT-5.2 with guardrails |

> [!NOTE]
> Model availability depends on your USAi API key entitlements.
> The `openai/` prefix is required for OpenHands to use the OpenAI-compatible API format.

---

## AGENTS.md Integration

OpenHands can be configured to read and follow `AGENTS.md` rules. When OpenHands starts in your project directory, it can access the workspace where `AGENTS.md` is located.

To ensure the agent follows your guidelines:
1. Place `AGENTS.md` in your project root
2. Instruct the agent to read and follow `AGENTS.md` in your prompts
3. The agent will have access to the file through the workspace mount

---

## Configuration File

This repo ships `.openhands/config.toml` which provides default settings:

```toml
[core]
workspace_base = "/workspace"
default_agent = "CodeActAgent"
max_iterations = 100

[llm]
model = "openai/gpt-5.4-latest-guardrails-defaultv2"
base_url = "https://api.gsa.usai.gov/api/v1"
api_key_env = "OPENAI_API_KEY"

[sandbox]
base_container_image = "nikolaik/python-nodejs:python3.12-nodejs22-slim"
timeout = 120
```

Environment variables take precedence over config file settings.

---

## Running with Make

```bash
# From the quickstart directory
make run-openhands
```

This runs OpenHands with USAi configuration. The web interface will be available at http://localhost:3000.

To override the default model:

```bash
make run-openhands OPENHANDS_MODEL=openai/gpt-5.2-latest-guardrails-defaultv2
```

---

## Troubleshooting

### OpenHands can't reach USAi

```bash
# Verify network connectivity
curl -I https://api.gsa.usai.gov/api/v1/models

# Check environment variable is set
echo $OPENAI_API_KEY
```

### Authentication failed

```bash
# Verify API key is set
echo $OPENAI_API_KEY

# Re-set the API key
export OPENAI_API_KEY="your-usai-api-key"
```

### Docker permission denied

```bash
# Ensure Docker socket is accessible
ls -la /var/run/docker.sock

# On Linux, you may need to add your user to the docker group
sudo usermod -aG docker $USER
newgrp docker
```

### Model not found

USAi model names may differ from standard OpenAI names. Check:

1. Your USAi API key entitlements at <https://console.gsa.usai.gov/key-management>
2. Use the full model name with `openai/` prefix (e.g., `openai/gpt-5.4-latest-guardrails-defaultv2`)

### Port already in use

```bash
# Check what's using port 3000
lsof -i :3000

# Use a different port
docker run ... -p 3001:3000 ...
```

---

## Differences from OpenCode

| Feature | OpenCode | OpenHands |
|---------|----------|-----------|
| Interface | CLI (terminal) | Web-based IDE (browser) |
| Configuration | `opencode.jsonc` | `.openhands/config.toml` + env vars |
| Runtime | SBX sandbox | Docker container |
| Agent type | CLI agent | Multiple agents (CodeAct, Browsing, etc.) |
| Model selection | In config file | Environment variable or config file |

---

## Next Steps

- [Full sbx CLI Guide](QUICKSTART_SBX.md) — Advanced sandbox management
- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Troubleshooting guide
- [SBX Patterns](../templates/SBX_PATTERNS.md) — Credential injection patterns
- [OpenHands Documentation](https://docs.openhands.dev) — Official OpenHands docs
