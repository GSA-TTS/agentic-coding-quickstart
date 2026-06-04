# Codex (OpenAI) Quickstart Guide

> **For teams using OpenAI Codex CLI** — Run Codex inside Docker Sandboxes with USAi.

This guide walks you through setting up [OpenAI Codex CLI](https://github.com/openai/codex) to work with USAi inside Docker Sandboxes.

## Why Codex + USAi?

Codex is OpenAI's agentic coding CLI (built in Rust). It uses its own config system (`config.toml`) and a custom provider definition to point at USAi's Chat Completions API.

> [!IMPORTANT]
> Codex uses its **own config system** (`config.toml`), not the Python SDK env var `OPENAI_BASE_URL`.
> USAi also does not support the Responses API (`/v1/responses`) that Codex defaults to — it must
> be told to use the Chat Completions API (`/v1/chat/completions`) via `wire_api = "chat-completions"`.

This repo ships a `.codex/config.toml` that handles all of this automatically.

**Key benefits:**

- **Config file provided** — `.codex/config.toml` wires USAi as the provider out of the box
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

Only one secret is needed: `OPENAI_API_KEY` (the SBX proxy swaps it with the real USAi key when Codex calls `api.gsa.usai.gov`).

```bash
# Store USAi API key as OPENAI_API_KEY
sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_API_KEY --value "$USAI_API_KEY"

# Store GitHub token (optional, for code access)
gh auth token | sbx secret set -g github
```

> [!IMPORTANT]
> After setting or changing the `OPENAI_API_KEY` secret, you must **delete and recreate** the sandbox for it to take effect.

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

# Run Codex — .codex/config.toml routes requests to USAi automatically
sbx run codex . -- -m gpt-5.4-latest-guardrails-defaultv2
```

That's it. Codex will start inside the sandbox with USAi access.

---

## How It Works

| What | Value | Purpose |
|------|-------|---------|
| `OPENAI_API_KEY` SBX secret | Placeholder swapped by proxy | Authentication — real key injected by SBX when Codex calls `api.gsa.usai.gov` |
| `.codex/config.toml` `model_provider` | `usai` | Selects the USAi provider |
| `.codex/config.toml` `base_url` | `https://api.gsa.usai.gov/api/v1` | Routes requests to USAi |
| `.codex/config.toml` `wire_api` | `chat-completions` | Uses `/v1/chat/completions` (USAi does not support `/v1/responses`) |

Codex loads `.codex/config.toml` from the project root automatically. No extra flags needed.

---

## Model Selection

USAi exposes OpenAI models with specific names. Specify a USAi model name explicitly via `-m`:

```bash
sbx run codex . -- -m gpt-5.4-latest-guardrails-defaultv2
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

## Configuration File

This repo ships `.codex/config.toml` which wires Codex to USAi automatically:

```toml
model_provider = "usai"
model = "gpt-5.4-latest-guardrails-defaultv2"

[model_providers.usai]
name     = "USAi"
base_url = "https://api.gsa.usai.gov/api/v1"
env_key  = "OPENAI_API_KEY"
wire_api = "chat-completions"
```

The key setting is `wire_api = "chat-completions"` — USAi does not implement the Responses API
(`/v1/responses`) that Codex defaults to. Without this, requests return a 404.

---

## Running with Make

```bash
# From the quickstart directory
make run-codex
```

This runs `sbx run codex . -- -m gpt-5.4-latest-guardrails-defaultv2`. Provider config is picked up from `.codex/config.toml` automatically.

To override the default model:

```bash
make run-codex CODEX_MODEL=gpt-5.2-latest-guardrails-defaultv2
```

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

# Re-set the API key credential
sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_API_KEY --value "$USAI_API_KEY"

# Recreate sandbox (required after changing secrets)
sbx rm SANDBOX_NAME && make run-codex
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
| Configuration | `opencode.jsonc` | `.codex/config.toml` |
| Provider setup | Explicit `baseURL` in JSONC config | `model_providers.usai` in `config.toml` |
| Wire API | Responses API | Chat Completions (required for USAi) |
| Instruction files | `AGENTS.md`, `CLAUDE.md`, custom | `AGENTS.md` (native) |
| Model selection | In config file | `.codex/config.toml` or `-m` flag |

---

## Next Steps

- [Full sbx CLI Guide](QUICKSTART_SBX.md) — Advanced sandbox management
- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Troubleshooting guide
- [SBX Patterns](../templates/SBX_PATTERNS.md) — Credential injection patterns
