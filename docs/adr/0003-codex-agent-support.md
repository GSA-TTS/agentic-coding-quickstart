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

**Chosen option: Option 1** — Document Codex integration using standard environment variable
mapping.

### Rationale

- **Simplest approach:** Codex uses standard OpenAI SDK environment variables. By setting
  `OPENAI_BASE_URL=https://api.gsa.usai.gov/api/v1` and `OPENAI_API_KEY=$USAI_API_KEY`,
  Codex works without any custom configuration files.
- **No wrapper needed:** The sbx secret store can inject these variables directly.
- **AGENTS.md support:** Codex reads `AGENTS.md` natively, so security rules and behavioral
  constraints are automatically enforced.
- **Consistent with existing patterns:** Uses the same `sbx secret set-custom` pattern
  already documented for USAi.

## Technical Details

### Environment Variable Mapping

| Codex Variable | USAi Equivalent | Purpose |
|---------------|-----------------|---------|
| `OPENAI_API_KEY` | `$USAI_API_KEY` | Authentication |
| `OPENAI_BASE_URL` | `https://api.gsa.usai.gov/api/v1` | Endpoint routing |

### Model Name Mapping

Codex requests models by OpenAI names. USAi exposes models with guardrails suffixes:

| Codex Expects | USAi Provides |
|--------------|---------------|
| `gpt-5.4` (or similar) | `gpt-5.4-latest-guardrails-defaultv2` |
| `gpt-5.2` (or similar) | `gpt-5.2-latest-guardrails-defaultv2` |

Users may need to specify the full USAi model name via `codex --model MODEL_NAME`.

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
- Codex default model may not match USAi's available models (requires `--model` flag)
- Two environment variables needed vs. OpenCode's single config file approach

### Risks

- **Low:** USAi model catalog may change, requiring documentation updates
- **Low:** Codex CLI updates may change environment variable behavior

## Related Decisions

- [ADR-0001](0001-sbx-usai-agent-execution-architecture.md) — SBX as isolation layer
