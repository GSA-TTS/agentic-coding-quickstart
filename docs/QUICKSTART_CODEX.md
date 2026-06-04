# Codex (OpenAI) Quickstart Guide

> **For teams using OpenAI Codex CLI** — Run Codex inside Docker Sandboxes with USAi.

This guide walks you through setting up [OpenAI Codex CLI](https://github.com/openai/codex) to work with USAi inside Docker Sandboxes.

## Why Codex + USAi?

Codex is OpenAI's agentic coding CLI. Since USAi exposes an **OpenAI-compatible API**, Codex works natively by setting the standard OpenAI environment variables (`OPENAI_API_KEY` and `OPENAI_BASE_URL`) to point at USAi.

**Key benefits:**

- **No configuration files needed** — Codex uses environment variables for endpoint configuration
- **Native AGENTS.md support** — Codex reads `AGENTS.md` automatically (part of the [agents.md standard](https://agents.md))
- **Full sandbox isolation** — Same security model as other agents in this repo

---

## Prerequisites

| Requirement | How to Check | Notes |
|-------------|--------------|-------|
| sbx CLI | `sbx version` | Standalone tool, Docker Desktop not required |
| USAi API key | From your GSA account | Stored via `sbx secret` |
| GitHub token | `gh auth status` | Optional, for code access |

---

## Step 1: Store Credentials

Codex expects `OPENAI_API_KEY` and `OPENAI_BASE_URL`. Since USAi is OpenAI-compatible, we map these to the USAi endpoint:

```bash
# Store USAi API key as OPENAI_API_KEY (Codex reads this natively)
sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_API_KEY --value "$USAI_API_KEY"

# Store USAi base URL (tells Codex to use USAi instead of api.openai.com)
sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_BASE_URL --value "https://api.gsa.usai.gov/api/v1"

# Store GitHub token (optional, for code access)
gh auth token | sbx secret set -g github
```

> [!IMPORTANT]
> After setting or changing secrets, you must **delete and recreate** the sandbox for changes to take effect.

---

## Step 2: Configure Network Policy

```bash
# Set default policy (first-time only)
sbx policy set-default balanced

# Allow USAi endpoint
sbx policy allow network -g "api.gsa.usai.gov"
```

---

## Step 3: Run Codex

```bash
# Navigate to your project
cd /path/to/your/project

# Run Codex in a sandbox
sbx run codex .
```

That's it. Codex will start inside the sandbox with USAi access.

---

## How It Works

| Environment Variable | Value | Purpose |
|---------------------|-------|---------|
| `OPENAI_API_KEY` | Your USAi API key | Authentication with USAi |
| `OPENAI_BASE_URL` | `https://api.gsa.usai.gov/api/v1` | Routes requests to USAi instead of OpenAI |

Codex uses the standard OpenAI SDK environment variables. By setting `OPENAI_BASE_URL` to USAi, all API calls are routed through the GSA gateway.

---

## Model Selection

USAi exposes OpenAI models with specific names. Codex will use the default model unless you specify one:

```bash
# Use a specific model (check USAi catalog for available names)
sbx exec -it SANDBOX_NAME codex --model gpt-5.4-latest-guardrails-defaultv2
```

Available models via USAi (check your entitlements):

| USAi Model Name | Description |
|----------------|-------------|
| `gpt-5.4-latest-guardrails-defaultv2` | GPT-5.4 with guardrails |
| `gpt-5.2-latest-guardrails-defaultv2` | GPT-5.2 with guardrails |

> [!NOTE]
> Model availability depends on your USAi API key entitlements.
> Run `codex --model MODEL_NAME` to specify a model explicitly.

---

## AGENTS.md Integration

Codex **natively reads `AGENTS.md`** — no additional configuration is needed. When Codex starts in your project directory, it automatically loads `AGENTS.md` and follows the rules defined there.

This means:

- Security rules are enforced automatically
- Commit message standards are followed
- Prohibited actions are respected
- No separate instruction file needed (unlike some other agents)

---

## Configuration File (Optional)

Codex supports a `codex.yaml` configuration file in your project root for additional settings. However, for USAi integration, **environment variables are sufficient** — no config file is required.

If you want to create a config file for other Codex settings:

```yaml
# codex.yaml (optional — only needed for non-default Codex settings)
# USAi connection is handled via OPENAI_API_KEY and OPENAI_BASE_URL env vars
model: gpt-5.4-latest-guardrails-defaultv2
```

---

## Running with Make

```bash
# From the quickstart directory
make run-codex
```

This runs `sbx run codex .` with the same credential checks as `make run-agent`.

---

## Troubleshooting

### Codex can't reach USAi

```bash
# Verify network policy
sbx policy ls

# Ensure USAi is allowed
sbx policy allow network -g "api.gsa.usai.gov"
```

### Authentication failed

```bash
# Check secrets are stored
sbx secret ls

# Re-set credentials
sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_API_KEY --value "$USAI_API_KEY"
sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_BASE_URL --value "https://api.gsa.usai.gov/api/v1"

# Recreate sandbox
sbx rm SANDBOX_NAME && sbx run codex .
```

### Model not found

USAi model names may differ from standard OpenAI names. Check:

1. Your USAi API key entitlements at <https://console.gsa.usai.gov/key-management>
2. Use the full model name including guardrails suffix (e.g., `gpt-5.4-latest-guardrails-defaultv2`)

### Codex ignores AGENTS.md

Codex should detect `AGENTS.md` automatically. If it doesn't:

1. Ensure `AGENTS.md` is in the project root (where you run `sbx run codex .`)
2. Check that the file is not empty or malformed
3. Verify you're using a recent version of the Codex CLI

---

## Differences from OpenCode

| Feature | OpenCode | Codex |
|---------|----------|-------|
| Configuration | `opencode.jsonc` | Environment variables + optional `codex.yaml` |
| Provider setup | Explicit provider config | Standard OpenAI env vars |
| Instruction files | `AGENTS.md`, `CLAUDE.md`, custom | `AGENTS.md` (native) |
| USAi mapping | `baseURL` in config | `OPENAI_BASE_URL` env var |
| Model selection | In config file | CLI flag or config |

---

## Next Steps

- [Full sbx CLI Guide](QUICKSTART_SBX.md) — Advanced sandbox management
- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Troubleshooting guide
- [SBX Patterns](../templates/SBX_PATTERNS.md) — Credential injection patterns
