# OpenHands Configuration for USAi

This document explains how to run [OpenHands](https://github.com/OpenHands/OpenHands)
end-to-end against the GSA USAi endpoint.

## Overview

OpenHands is an AI-driven development platform that provides a web-based IDE
experience with powerful coding agents. Because USAi exposes an
OpenAI-compatible API, OpenHands can talk to it using the `openai/` model prefix
(handled internally by LiteLLM).

> [!IMPORTANT]
> OpenHands **V1** (the current GUI / agent-server Docker image) reads its LLM
> configuration from `~/.openhands/settings.json` — **not** from environment
> variables or `config.toml`. The custom USAi Base URL therefore must be written
> into that settings file before launch. `make run-openhands` does this for you
> via [`scripts/seed-openhands-settings.sh`](scripts/seed-openhands-settings.sh).

## Quick Start (End-to-End)

```bash
# 1. Export your USAi API key as OPENAI_API_KEY.
#    If you stored it in SBX during `make setup`, pull it from there:
export OPENAI_API_KEY="$(sbx secret get USAI_API_KEY)"
#    Or set it directly:
export OPENAI_API_KEY="your-usai-api-key"

# 2. Launch OpenHands. This seeds ~/.openhands/settings.json with the USAi
#    provider config and then starts the container.
make run-openhands

# 3. Open the web interface:
#    http://localhost:3000
```

That's it. The agent starts pre-configured for USAi — no manual entry in the
Settings UI is required.

To use a different USAi-entitled model:

```bash
make run-openhands OPENHANDS_MODEL=openai/gpt-5.2-latest-guardrails-defaultv2
```

## What `make run-openhands` Does

1. **`_check-openhands-keys`** — verifies `OPENAI_API_KEY` is exported (Docker
   cannot read SBX secrets directly).
2. **`_seed-openhands-settings`** — runs
   [`scripts/seed-openhands-settings.sh`](scripts/seed-openhands-settings.sh),
   which writes `~/.openhands/settings.json` with the USAi model, base URL, and
   API key (file permissions `0600`).
3. **`docker run`** — launches the OpenHands V1 container with your project
   mounted into the sandbox at `/workspace` and the web UI on port 3000.

## Required Environment Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `OPENAI_API_KEY` | Yes | Your USAi API key. Seeded into `settings.json` as the LLM API key. |
| `OPENHANDS_MODEL` | No (default below) | LiteLLM model id, e.g. `openai/gpt-5.4-latest-guardrails-defaultv2`. |
| `USAI_BASE_URL` | No | USAi endpoint. Defaults to `https://api.gsa.usai.gov/api/v1`. |

```bash
# Export your USAi API key as OPENAI_API_KEY
export OPENAI_API_KEY="your-usai-api-key"

# Optional: persist it in your shell profile
echo 'export OPENAI_API_KEY="your-usai-api-key"' >> ~/.zshrc  # or ~/.bashrc
```

> [!NOTE]
> OpenHands expects the key in `OPENAI_API_KEY` when using OpenAI-compatible
> APIs, even though we are connecting to USAi.

## Manual Docker Command

If you prefer to run Docker directly, first seed the USAi provider config, then
launch the container:

```bash
# 1. Seed ~/.openhands/settings.json with the USAi provider config
OPENHANDS_MODEL="openai/gpt-5.4-latest-guardrails-defaultv2" \
  ./scripts/seed-openhands-settings.sh

# 2. Launch OpenHands (accessible at http://localhost:3000)
docker run -it --rm --pull always \
  -e AGENT_SERVER_IMAGE_REPOSITORY="ghcr.io/openhands/agent-server" \
  -e AGENT_SERVER_IMAGE_TAG="1.28.0-python" \
  -e SANDBOX_VOLUMES="$(pwd):/workspace:rw" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands:/.openhands \
  -p 3000:3000 \
  --add-host host.docker.internal:host-gateway \
  --name openhands-app \
  docker.openhands.dev/openhands/openhands:1.8
```

Access the web interface at: http://localhost:3000

## The Seeded `settings.json`

`scripts/seed-openhands-settings.sh` writes `~/.openhands/settings.json` in the
OpenHands V1 persisted-settings schema (API key redacted below):

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

| Field | Value | Description |
|-------|-------|-------------|
| `agent_settings.agent` | `CodeActAgent` | Default agent type for coding tasks |
| `agent_settings.llm.model` | `openai/gpt-5.4-latest-guardrails-defaultv2` | USAi model (with `openai/` prefix) |
| `agent_settings.llm.base_url` | `https://api.gsa.usai.gov/api/v1` | USAi API endpoint |
| `agent_settings.llm.api_key` | (from `OPENAI_API_KEY`) | USAi API key |
| `conversation_settings.max_iterations` | `100` | Max iterations per task |

The `SANDBOX_VOLUMES` environment variable (`$PWD:/workspace:rw`) mounts your
project into the agent sandbox.

> [!NOTE]
> The repo also ships [`.openhands/config.toml`](.openhands/config.toml), but that
> file is only consumed by the **legacy (V0)** OpenHands runtime. The V1 GUI image
> used by `make run-openhands` ignores it and reads `~/.openhands/settings.json`.

## Changing the Model

```bash
# Using Make
make run-openhands OPENHANDS_MODEL=openai/gpt-5.2-latest-guardrails-defaultv2

# Or re-seed manually, then relaunch
OPENHANDS_MODEL="openai/gpt-5.2-latest-guardrails-defaultv2" \
  ./scripts/seed-openhands-settings.sh
make run-openhands
```

Available USAi models (check your entitlements):

- `openai/gpt-5.4-latest-guardrails-defaultv2` (GPT-5.4 with guardrails)
- `openai/gpt-5.2-latest-guardrails-defaultv2` (GPT-5.2 with guardrails)

> [!IMPORTANT]
> The `openai/` prefix is required for OpenHands to treat these as
> OpenAI-compatible API models.

## Security Considerations

### API Key Management

- **Never commit your USAi API key to version control.**
- The key is read from `OPENAI_API_KEY` at runtime and written to
  `~/.openhands/settings.json` with `0600` permissions.
- For persistent storage, add it to your shell profile (e.g. `~/.zshrc`), or use
  SBX secrets:
  `sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"`

### Docker Socket Access

The Docker run command mounts `/var/run/docker.sock` so OpenHands can spawn
sandbox containers. This grants significant system access:

- **Risk:** OpenHands can create/manage Docker containers on your host.
- **Mitigation:** Only run OpenHands in trusted environments.

### Network Access

OpenHands containers can make network requests. When running in production:

- Use network policies to restrict outbound connections.
- For SBX integration, allow the USAi endpoint:
  `sbx policy allow network -g "api.gsa.usai.gov"`

## Troubleshooting

### OpenHands can't authenticate with USAi

**Symptom:** Authentication errors in the OpenHands interface.

**Solution:** Re-seed the settings with a valid key and restart.

```bash
export OPENAI_API_KEY="your-usai-api-key"
./scripts/seed-openhands-settings.sh
make run-openhands
```

### Wrong model / settings not applied

**Symptom:** The UI shows the wrong model or stale credentials.

**Cause:** OpenHands caches its config in `~/.openhands/settings.json`.

**Solution:** Re-seed (optionally with a new model) and relaunch.

```bash
OPENHANDS_MODEL="openai/gpt-5.4-latest-guardrails-defaultv2" \
  ./scripts/seed-openhands-settings.sh
make run-openhands
```

### Model not found

**Symptom:** OpenHands reports the model doesn't exist.

**Possible causes:**

1. Model name is incorrect (must include the `openai/` prefix).
2. Your USAi API key doesn't have entitlements for that model.
3. The model name in USAi has changed.

**Solution:** Verify entitlements at
<https://console.gsa.usai.gov/key-management> and re-run with the correct name:

```bash
make run-openhands OPENHANDS_MODEL=openai/gpt-5.4-latest-guardrails-defaultv2
```

### Port 3000 already in use

```bash
# Find what's using port 3000
lsof -i :3000

# Either stop that process, or map a different host port
docker run ... -p 3001:3000 ...
```

### Docker permission denied

**Symptom:** `permission denied while trying to connect to the Docker daemon socket`.

**Solution (Linux):**

```bash
sudo usermod -aG docker $USER
newgrp docker
```

**Solution (macOS):**

- Ensure Docker Desktop is running.
- Check Docker Desktop settings → Advanced → "Allow the default Docker socket".

## AGENTS.md Integration

OpenHands can access project files through the workspace mount, including
`AGENTS.md` behavioral rules.

To ensure OpenHands follows your project's guidelines:

1. **Place `AGENTS.md` in your project root** — OpenHands will have access to it
   through the workspace mount.
2. **Instruct the agent explicitly** — in your first prompt, tell OpenHands:
   ```
   Please read and follow the rules in AGENTS.md before proceeding with any tasks.
   ```
3. **Reference rules as needed** — remind the agent of specific rules during the
   session.

OpenHands does not automatically load `AGENTS.md` on startup, so you must
explicitly instruct it to read and follow the guidelines.

## Additional Resources

- [OpenHands Quickstart Guide](docs/QUICKSTART_OPENHANDS.md) — Full setup instructions
- [OpenHands ADR](docs/adr/0003-openhands-agent-support.md) — Architecture decision record
- [OpenHands Official Docs](https://docs.openhands.dev) — Upstream documentation
- [USAi Console](https://console.gsa.usai.gov/key-management) — Manage API keys and entitlements
- [SBX Patterns](templates/SBX_PATTERNS.md) — Credential injection patterns

## Support

For issues specific to this setup:

- Open an issue in the [agentic-coding-quickstart repository](https://github.com/GSA-TTS/agentic-coding-quickstart/issues)
- Ask in the [agentic-coding Slack channel](https://gsa.enterprise.slack.com/archives/C0B44531QLE)

For general OpenHands questions:

- [OpenHands GitHub](https://github.com/OpenHands/OpenHands)
- [OpenHands Slack](https://dub.sh/openhands)
