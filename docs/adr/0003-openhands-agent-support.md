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

1. **Document OpenHands integration with Docker and environment variables** — Configure LLM
   provider via environment variables pointing to USAi
2. **Require a custom configuration file only** — Create `.openhands/config.toml` without
   Docker run documentation
3. **Do not support OpenHands** — Only support OpenCode as the primary agent

## Decision Outcome

**Chosen option: Option 1** — Document OpenHands integration with Docker deployment and
environment variable configuration, supplemented by a `.openhands/config.toml` for defaults.

### Rationale

- **Docker-native approach:** OpenHands is designed to run as a Docker container with a web
  interface. This aligns with modern containerized development practices.
- **Environment variables for runtime config:** OpenHands reads `LLM_BASE_URL`, `LLM_API_KEY`,
  and `LLM_MODEL` from environment variables, making it easy to configure at runtime.
- **Config file for defaults:** The `.openhands/config.toml` provides sensible defaults that
  can be overridden by environment variables.
- **Web-based interface:** OpenHands provides a rich IDE experience with file browser, terminal,
  and chat interface — complementing the CLI-based OpenCode.
- **Agent flexibility:** OpenHands supports multiple agent types (CodeActAgent for coding,
  BrowsingAgent for research) providing more flexibility than CLI-only agents.

## Technical Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `LLM_API_KEY` | Your USAi API key | Authentication with USAi |
| `LLM_BASE_URL` | `https://api.gsa.usai.gov/api/v1` | Routes requests to USAi |
| `LLM_MODEL` | `openai/gpt-5.4-latest-guardrails-defaultv2` | Selects the model |
| `WORKSPACE_MOUNT_PATH` | Project directory path | Working directory for agent |

### Docker Deployment

OpenHands runs as a Docker container exposing port 3000:

```bash
docker run -it --pull always \
  -e LLM_MODEL="openai/gpt-5.4-latest-guardrails-defaultv2" \
  -e LLM_BASE_URL="https://api.gsa.usai.gov/api/v1" \
  -e LLM_API_KEY="$OPENAI_API_KEY" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands:/.openhands \
  -v "$(pwd)":/opt/workspace_base \
  -p 3000:3000 \
  ghcr.io/openhands/openhands:latest
```

### Configuration File

`.openhands/config.toml` provides defaults:

```toml
[core]
workspace_base = "/workspace"
default_agent = "CodeActAgent"

[llm]
model = "openai/gpt-5.4-latest-guardrails-defaultv2"
base_url = "https://api.gsa.usai.gov/api/v1"
api_key_env = "OPENAI_API_KEY"
```

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
