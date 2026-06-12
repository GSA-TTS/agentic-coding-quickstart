---
title: "Add OpenHands as a Supported Agent"
status: accepted
date: 2026-06-05
decision_makers: ["William Zujkowski"]
category: tooling
nist_controls: ["AC-6", "SC-7"]
impact_level: low
ato_relevance: no
risk_treatment: accept
---

# ADR-0003: Add OpenHands as a Supported Agent

## Context and Problem Statement

The repository currently documents OpenCode as the primary agent with detailed configuration
(`opencode.jsonc`), while other agents (Claude Code, GitHub Copilot, Cursor, Gemini) are
referenced as SBX-supported but lack integration guidance. OpenHands is a popular open-source
AI-driven development platform that teams are requesting to use with USAi.

Since USAi exposes an OpenAI-compatible API, OpenHands should work by configuring the LLM
provider to point at the USAi endpoint. We need to document this pattern and provide
first-class support.

## Decision Drivers

- Teams requesting OpenHands support for USAi integration
- USAi already exposes an OpenAI-compatible API (same format OpenHands expects)
- OpenHands provides a rich web-based IDE experience
- Multiple agent types available (CodeActAgent, BrowsingAgent, etc.)
- Active open-source community with frequent updates
- Docker-based deployment aligns with containerization best practices

## Considered Options

1. **Seed `~/.openhands/settings.json` with the USAi provider config** — OpenHands
   V1 reads its LLM configuration (model, base URL, API key) from a persisted
   settings file. Pre-seed it so USAi works on first launch with no manual UI steps.
2. **Require manual entry in the Settings UI** — Launch the container and have the
   user enter the USAi Base URL, model, and key in the Settings panel each time.
3. **Do not support OpenHands** — Only support OpenCode as the primary agent.

## Decision Outcome

**Chosen option: Option 1** — Seed `~/.openhands/settings.json` with the USAi
provider configuration before launching the OpenHands V1 Docker container.

### Rationale

- **V1 reality:** OpenHands V1 (the current GUI/agent-server image) does **not**
  honor a custom LLM Base URL via environment variables. The legacy
  `LLM_BASE_URL`/`LLM_MODEL` env-var approach only worked for the V0 runtime.
  USAi's custom endpoint therefore must live in the persisted settings file.
- **End-to-end without manual steps:** Seeding `settings.json` means
  `make run-openhands` produces a working USAi-backed agent on first launch — no
  Settings-UI clicks required.
- **Docker-native approach:** OpenHands is designed to run as a Docker container
  with a web interface, aligning with modern containerized development practices.
- **Secret hygiene:** The API key is read from `OPENAI_API_KEY` at runtime and
  written into `settings.json` with `0600` permissions; it is never committed.
- **Web-based interface:** OpenHands provides a rich IDE experience (file browser,
  terminal, chat) complementing the CLI-based OpenCode.
- **Agent flexibility:** OpenHands supports multiple agent types (CodeActAgent for
  coding, BrowsingAgent for research).

## Technical Details

### Provider Configuration (seeded settings.json)

The harness writes `~/.openhands/settings.json` via
`scripts/seed-openhands-settings.sh`. Key fields:

| Field | Value | Purpose |
|-------|-------|---------|
| `agent_settings.llm.api_key` | Your USAi API key | Authentication with USAi |
| `agent_settings.llm.base_url` | `https://api.gsa.usai.gov/api/v1` | Routes requests to USAi |
| `agent_settings.llm.model` | `openai/gpt-5.4-latest-guardrails-defaultv2` | Selects the model |
| `agent_settings.agent_kind` | `openhands` | V1 discriminated settings variant |

The `SANDBOX_VOLUMES` environment variable (`$PWD:/workspace:rw`) mounts the
project into the agent sandbox.

### Docker Deployment

OpenHands V1 runs as a Docker container exposing port 3000:

```bash
# 1. Seed the USAi provider config into ~/.openhands/settings.json
OPENAI_API_KEY="$OPENAI_API_KEY" \
OPENHANDS_MODEL="openai/gpt-5.4-latest-guardrails-defaultv2" \
  ./scripts/seed-openhands-settings.sh

# 2. Launch OpenHands
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

### Legacy Configuration File

`.openhands/config.toml` is retained for the **legacy (V0)** OpenHands runtime,
which reads provider settings from TOML. The V1 GUI image ignores it.

### Model Name Mapping

OpenHands uses the `openai/` prefix for OpenAI-compatible models:

| OpenHands Model | USAi Model |
|-----------------|------------|
| `openai/gpt-5.4-latest-guardrails-defaultv2` | `gpt-5.4-latest-guardrails-defaultv2` |
| `openai/gpt-5.2-latest-guardrails-defaultv2` | `gpt-5.2-latest-guardrails-defaultv2` |

### Network Requirements

No SBX network policy changes needed if running Docker directly on the host. If running
within an SBX context, ensure `api.gsa.usai.gov` is in the allowed network policy.

## Consequences

### Positive

- Teams can use OpenHands with USAi immediately
- Web-based interface provides richer development experience
- Docker deployment is familiar to most developers
- Multiple agent types available for different tasks
- Active community with frequent updates and improvements

### Negative

- Requires Docker (not just sbx CLI)
- Web interface runs on a port that must be accessible
- Different deployment model than sbx-based agents (OpenCode, etc.)
- Users must manage their own Docker security

### Risks

- **Low:** USAi model catalog may change, requiring documentation updates
- **Low:** OpenHands updates may change configuration format
- **Medium:** Docker socket mounting requires careful security consideration

## Related Decisions

- [ADR-0001](0001-sbx-usai-agent-execution-architecture.md) — SBX as isolation layer
