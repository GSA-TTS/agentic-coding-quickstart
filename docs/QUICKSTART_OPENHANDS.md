# OpenHands Quickstart Guide

> **For teams using OpenHands** — Run OpenHands AI-driven development agent with USAi.

This guide walks you through setting up [OpenHands](https://github.com/OpenHands/OpenHands) to work with USAi inside Docker containers.

## Why OpenHands + USAi?

OpenHands is an AI-driven development platform that provides a web-based IDE experience with powerful coding agents. It supports multiple LLM providers through OpenAI-compatible APIs, making it compatible with USAi.

> [!IMPORTANT]
> OpenHands runs as a Docker container and provides a web interface accessible via browser.
> The agent can execute code, browse the web, and interact with your development environment.

OpenHands V1 (the current GUI image) does **not** accept a custom LLM Base URL
through environment variables — it reads its runtime configuration from
`~/.openhands/settings.json`. To make USAi work end-to-end without manually
entering settings in the web UI, `make run-openhands` seeds that file for you via
[`scripts/seed-openhands-settings.sh`](../scripts/seed-openhands-settings.sh).

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

OpenHands needs your USAi API key exported as `OPENAI_API_KEY` so the harness can
seed it into the OpenHands settings:

```bash
# Set USAi API key as OPENAI_API_KEY
export OPENAI_API_KEY="your-usai-api-key"

# If you stored it in SBX during `make setup`, export it from there:
export OPENAI_API_KEY="$(sbx secret get USAI_API_KEY)"

# Optional: Add to your shell profile for persistence
echo 'export OPENAI_API_KEY="your-usai-api-key"' >> ~/.zshrc
```

> [!IMPORTANT]
> OpenHands Docker cannot read SBX secrets directly — the key must be present as
> the `OPENAI_API_KEY` environment variable before starting.

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
- USAi as the LLM provider (seeded into `~/.openhands/settings.json`)
- Default model: `openai/gpt-5.4-latest-guardrails-defaultv2`
- Web interface at http://localhost:3000

`make run-openhands` performs three steps:
1. `_check-openhands-keys` — verifies `OPENAI_API_KEY` is exported
2. `_seed-openhands-settings` — writes the USAi provider config into
   `~/.openhands/settings.json` (model, base URL, and API key) with `0600`
   permissions
3. Launches the OpenHands Docker container with your project mounted at
   `/workspace`

### Manual Docker Run

First seed the settings (or run the script directly):

```bash
OPENAI_API_KEY="your-usai-api-key" \
OPENHANDS_MODEL="openai/gpt-5.4-latest-guardrails-defaultv2" \
  ./scripts/seed-openhands-settings.sh
```

Then start the container:

```bash
docker run -it --rm --pull always \
  -e AGENT_SERVER_IMAGE_REPOSITORY="ghcr.io/openhands/agent-server" \
  -e AGENT_SERVER_IMAGE_TAG="1.28.0-python" \
  -e LOG_ALL_EVENTS=true \
  -e SANDBOX_VOLUMES="$(pwd):/workspace:rw" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands:/.openhands \
  -p 3000:3000 \
  --add-host host.docker.internal:host-gateway \
  --name openhands-app \
  docker.openhands.dev/openhands/openhands:1.8
```

Then open http://localhost:3000 in your browser. The USAi provider, model, and
key will already be configured.

---

## How It Works

| What | Value | Purpose |
|------|-------|---------|
| `agent_settings.llm.api_key` | Your USAi API key | Authentication |
| `agent_settings.llm.base_url` | `https://api.gsa.usai.gov/api/v1` | Routes requests to USAi |
| `agent_settings.llm.model` | `openai/gpt-5.4-latest-guardrails-defaultv2` | USAi model selection |
| `SANDBOX_VOLUMES` | `$(pwd):/workspace:rw` | Mounts your project into the sandbox |

OpenHands V1 reads its LLM configuration from `~/.openhands/settings.json`, which
`make run-openhands` seeds before launching the container. The `openai/` model
prefix tells LiteLLM (used internally by OpenHands) to speak the
OpenAI-compatible chat-completions API that USAi exposes.

---

## Model Selection

USAi exposes OpenAI models with specific names. Specify a USAi model name via the `OPENHANDS_MODEL` Make override:

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

OpenHands V1 stores its active configuration in `~/.openhands/settings.json`.
`make run-openhands` generates this file via
[`scripts/seed-openhands-settings.sh`](../scripts/seed-openhands-settings.sh).
The seeded file looks like (API key redacted):

```json
{
  "schema_version": 2,
  "v1_enabled": true,
  "agent_settings": {
    "schema_version": 4,
    "agent_kind": "openhands",
    "agent": "CodeActAgent",
    "llm": {
      "model": "openai/gpt-5.4-latest-guardrails-defaultv2",
      "base_url": "https://api.gsa.usai.gov/api/v1",
      "api_key": "<your-usai-key>"
    },
    "tools": [{ "name": "TerminalTool", "params": {} }]
  },
  "conversation_settings": { "schema_version": 1, "max_iterations": 100 },
  "llm_profiles": {
    "profiles": { "Default": { "model": "...", "base_url": "...", "api_key": "..." } },
    "active": "Default"
  }
}
```

> [!NOTE]
> The repo also ships `.openhands/config.toml`, but that file is only used by the
> **legacy (V0)** OpenHands runtime. The V1 GUI image used by `make run-openhands`
> ignores it and reads `~/.openhands/settings.json` instead.

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

### Settings not applied / wrong model in the UI

OpenHands caches settings in `~/.openhands/settings.json`. If you change models
or your key is stale, re-seed and restart:

```bash
export OPENAI_API_KEY="your-usai-api-key"
./scripts/seed-openhands-settings.sh
make run-openhands
```

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
| Configuration | `opencode.jsonc` | `~/.openhands/settings.json` (seeded) |
| Runtime | SBX sandbox | Docker container |
| Agent type | CLI agent | Multiple agents (CodeAct, Browsing, etc.) |
| Model selection | In config file | `OPENHANDS_MODEL` Make override |

---

## Next Steps

- [Full sbx CLI Guide](QUICKSTART_SBX.md) — Advanced sandbox management
- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Troubleshooting guide
- [SBX Patterns](../templates/SBX_PATTERNS.md) — Credential injection patterns
- [OpenHands Documentation](https://docs.openhands.dev) — Official OpenHands docs
