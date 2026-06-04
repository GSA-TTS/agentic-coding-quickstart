---
title: "Add Codex (OpenAI CLI) as a Supported Agent"
status: accepted
date: 2026-06-04
decision_makers: ["William Zujkowski"]
category: tooling
nist_controls: ["AC-6", "SC-7"]
impact_level: low
ato_relevance: no
risk_treatment: accept
---

# ADR-0003: Add Codex (OpenAI CLI) as a Supported Agent

## Context and Problem Statement

The repository currently documents OpenCode as the primary agent with detailed configuration
(`opencode.jsonc`), while other agents (Claude Code, GitHub Copilot, Cursor, Gemini) are
referenced as sbx-supported but lack integration guidance. OpenAI's Codex CLI is a popular
agentic coding tool that teams are requesting to use with USAi.

Since USAi exposes an OpenAI-compatible API, Codex should work by mapping standard OpenAI
environment variables to the USAi endpoint. We need to document this pattern and provide
first-class support.

## Decision Drivers

- Teams requesting Codex support for USAi integration
- USAi already exposes an OpenAI-compatible API (same format Codex expects)
- `sbx run codex .` is already supported by the sbx CLI
- Codex natively reads `AGENTS.md` (no additional instruction file needed)
- Minimal configuration needed — environment variables only

## Considered Options

1. **Document Codex integration with environment variable mapping** — Map `OPENAI_API_KEY`
   and `OPENAI_BASE_URL` to USAi
2. **Require a wrapper script** — Create a script that sets env vars before launching Codex
3. **Do not support Codex** — Only support OpenCode as the primary agent

## Decision Outcome

**Chosen option: Updated to Option 1b** — Use Codex's own `-c` config override flags to wire the USAi provider at run time.

### Rationale

- **Root cause discovered:** The Codex CLI is built in Rust and uses its own config system (`config.toml`). It does **not** read `OPENAI_BASE_URL` — that is an OpenAI Python SDK env var, not a Codex env var. Setting it via SBX secrets has no effect.
- **Correct mechanism:** Codex's `-c key=value` CLI flag overrides config at startup. Passing `-c openai_base_url=...` redirects the built-in `openai` provider to USAi for that run. This is simpler than a custom `model_providers.*` entry and requires no `name` field.
- **`model_providers.*` approach rejected:** Codex validates that every custom provider entry has a non-empty `name`; setting fields one by one via `-c` flags triggers this error before all flags are applied.
- **SBX proxy still handles the API key:** `OPENAI_API_KEY` (stored via `sbx secret set-custom --host api.gsa.usai.gov`) is still a valid SBX secret — the sandbox sees it as a placeholder, and the proxy injects the real key in request headers when Codex calls `api.gsa.usai.gov`.
- **AGENTS.md support:** Codex reads `AGENTS.md` natively, so security rules and behavioral constraints are automatically enforced.
- **Consistent with existing patterns:** `sbx run ... -- AGENT_FLAGS` is the documented SBX pattern for passing agent arguments.

## Technical Details

### Provider Configuration (via -c flag)

| `-c` Flag | Value | Purpose |
|-----------|-------|---------|
| `openai_base_url` | `"https://api.gsa.usai.gov/api/v1"` | Redirects the built-in `openai` provider to USAi |

### SBX Secret (API key only)

| SBX Secret | Env var in container | How it works |
|------------|---------------------|--------------|
| `OPENAI_API_KEY` (stored with `--host api.gsa.usai.gov`) | Placeholder value | SBX proxy swaps placeholder with real key in `Authorization` header when Codex calls `api.gsa.usai.gov` |

`OPENAI_BASE_URL` is **not stored as a secret** — it has no effect on the Codex CLI and must not be used.

### Model Name Mapping

Codex requests models by OpenAI names. USAi exposes models with guardrails suffixes:

| Codex Expects | USAi Provides |
|--------------|---------------|
| `gpt-5.4` (or similar) | `gpt-5.4-latest-guardrails-defaultv2` |
| `gpt-5.2` (or similar) | `gpt-5.2-latest-guardrails-defaultv2` |

Direct Codex invocations may need the full USAi model name via `codex --model MODEL_NAME`.
The quickstart Makefile defaults `make run-codex` to `gpt-5.4-latest-guardrails-defaultv2`.

### Network Policy

No changes needed — `api.gsa.usai.gov` is already in the allowed network policy.

## Consequences

### Positive

- Teams can use Codex with USAi immediately
- No new infrastructure or configuration files required
- Consistent security model (sandbox isolation, secret injection)
- Codex reads AGENTS.md natively — rules are enforced without extra setup

### Negative

- Model name differences between OpenAI and USAi may confuse users
- Direct Codex invocations require the `-c openai_base_url` and `-m` flags (handled transparently by `make run-codex`)
- Users who previously stored `OPENAI_BASE_URL` as an SBX secret will have an unused secret — it can be removed with `sbx secret rm`

### Risks

- **Low:** USAi model catalog may change, requiring documentation updates
- **Low:** Codex CLI updates may change how `openai_base_url` is applied

## Related Decisions

- [ADR-0001](0001-sbx-usai-agent-execution-architecture.md) — SBX as isolation layer
