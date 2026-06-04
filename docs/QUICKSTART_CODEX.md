# Codex (OpenAI) Quickstart Guide

> **For teams using OpenAI Codex CLI** — Run Codex inside Docker Sandboxes with USAi.

This guide walks you through setting up [OpenAI Codex CLI](https://github.com/openai/codex) to work with USAi inside Docker Sandboxes.

## Why Codex + USAi?

Codex is OpenAI's agentic coding CLI (built in Rust). Since USAi exposes an **OpenAI-compatible API**, Codex works natively by pointing its custom model provider at the USAi endpoint via its `-c` config override flags.

> [!IMPORTANT]
> Codex uses its **own config system** (`config.toml`), not the Python SDK env var `OPENAI_BASE_URL`.
> Setting `OPENAI_BASE_URL` as an env var has **no effect** on the Codex CLI.

**Key benefits:**

- **No config files needed** — provider base URL is passed as a one-time CLI flag at startup
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

The base URL is **not a secret** — it is passed as a Codex config flag at startup (see Step 3).

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

# Run Codex in a sandbox, routing requests to USAi
sbx run codex . -- \
  -c 'openai_base_url="https://api.gsa.usai.gov/api/v1"' \
  -m gpt-5.4-latest-guardrails-defaultv2
```

That's it. Codex will start inside the sandbox with USAi access.

---

## How It Works

| What | Value | Purpose |
|------|-------|---------|
| `OPENAI_API_KEY` SBX secret | Placeholder swapped by proxy | Authentication — real key injected by SBX when Codex calls `api.gsa.usai.gov` |
| `-c openai_base_url` | `"https://api.gsa.usai.gov/api/v1"` | Redirects the built-in `openai` provider to USAi |

Codex (the Rust CLI) uses its own config system. The `-c openai_base_url` flag overrides the built-in OpenAI provider's base URL for that run. No files are written or modified.

---

## Model Selection

USAi exposes OpenAI models with specific names. When you launch Codex directly, specify a USAi model name explicitly via `-m`:

```bash
# Use a specific model (check USAi catalog for available names)
sbx run codex . -- \
  -c 'openai_base_url="https://api.gsa.usai.gov/api/v1"' \
  -m gpt-5.4-latest-guardrails-defaultv2
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

Codex uses a TOML config file (`~/.codex/config.toml`) for persistent settings. For USAi integration the `-c` flags used by `make run-codex` are sufficient — no file is needed.

If you want to persist the provider config in the user-level config file instead (inside the sandbox home):

```toml
# ~/.codex/config.toml inside the sandbox (user-level only)
openai_base_url = "https://api.gsa.usai.gov/api/v1"
model = "gpt-5.4-latest-guardrails-defaultv2"
```

> [!NOTE]
> `openai_base_url` is blocked in project-level `.codex/config.toml` by Codex's security model.
> It can only be set in the user-level `~/.codex/config.toml` inside the container.

---

## Running with Make

```bash
# From the quickstart directory
make run-codex
```

This runs `sbx run codex . -- -c 'openai_base_url="https://api.gsa.usai.gov/api/v1"' -m gpt-5.4-latest-guardrails-defaultv2`, with the same `OPENAI_API_KEY` credential check as `make run-agent`.

To override the default model:

```bash
make run-codex CODEX_MODEL=gpt-5.2-latest-guardrails-defaultv2
```

To override the base URL (e.g. for a different USAi region):

```bash
make run-codex CODEX_BASE_URL=https://us-east.api.gsa.usai.gov/api/v1
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
| Configuration | `opencode.jsonc` | `-c` CLI flags or `~/.codex/config.toml` |
| Provider setup | Explicit `baseURL` in JSONC config | `-c model_providers.*` flags at run time |
| Instruction files | `AGENTS.md`, `CLAUDE.md`, custom | `AGENTS.md` (native) |
| USAi mapping | `baseURL` in config | `-c model_providers.usai.base_url` flag |
| Model selection | In config file | `-m` flag or config |

---

## Next Steps

- [Full sbx CLI Guide](QUICKSTART_SBX.md) — Advanced sandbox management
- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Troubleshooting guide
- [SBX Patterns](../templates/SBX_PATTERNS.md) — Credential injection patterns
