# Docker Sandboxes + USAi Addendum for AGENTS.md

> **Instructions:** Append this content to your existing AGENTS.md file.
> If you don't have an AGENTS.md, consider using the [Agentic Coding Playbook](https://github.com/GSA-TTS/agentic-coding-playbook) to generate one first.

---

## Docker Sandboxes Overview

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) runs AI coding agents in isolated microVM environments.

> [!IMPORTANT]
> The Docker Desktop-integrated `docker sandbox` commands are **deprecated**.
> Use the standalone `sbx` CLI instead.
> See [Docker's deprecation notice](https://docs.docker.com/reference/cli/docker/sandbox/).

**Install sbx CLI:**
```bash
# macOS
brew install docker/tap/sbx

# Windows
winget install Docker.sbx
```

## SBX-Specific Rules (Non-Negotiable)

### 1. No Secrets Exposure

The agent MUST NEVER:
- Print, log, or persist API keys, tokens, or credentials
- Hardcode secrets in source files, config files, or scripts
- Use `printenv`, `env`, or `echo $SECRET` in ways that expose values
- Include secrets in commit messages, comments, or documentation

All secrets MUST be accessed via:
- sbx CLI: Secret management (`sbx secret set -g`) or runtime injection (`-e` flag)

### 2. Assume You Are Untrusted

Agents must behave as if:
- The runtime environment is monitored
- Outputs may be logged and reviewed
- Any exposed secret is considered compromised

### 3. Sandbox Is the Security Boundary

All agent execution MUST:
- Occur inside Docker Sandboxes when working with USAi endpoints
- Avoid direct host interaction unless explicitly required
- Avoid writing outside the working directory
- Respect container filesystem boundaries

### 4. Config-First Approach

Agents should:
- Prefer modifying configuration files over writing custom scripts
- Use `opencode.jsonc` (or equivalent) for model/provider setup
- Avoid introducing unnecessary abstraction layers
- Document configuration changes clearly

---

## Network Access

- **Authorized external endpoints:**
  - `https://api.gsa.usai.gov/api/v1` (USAi API)
  - `https://api.github.com` (GitHub API - via proxy)
  - `https://workshop.cloud.gov` (GitLab API - GSA workshop instance, if applicable)
- **TLS requirement:** TLS 1.2+ for all connections

### Credential Injection Methods

| Service | Command | Notes |
|---------|---------|-------|
| USAi | `sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"` | Custom endpoint |
| Codex (via USAi) | `sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_API_KEY --value "$USAI_API_KEY"` | Maps OpenAI vars to USAi |
| GitHub | `gh auth token \| sbx secret set -g github` | Built-in service |
| GitLab | `sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN --value "$GITLAB_TOKEN"` | Custom endpoint |

> [!IMPORTANT]
> USAi and GitLab are **not built-in sbx services**. You must use `sbx secret set-custom` with the `--host` parameter.
> After changing secrets, **delete and recreate** the sandbox for changes to take effect.

See `templates/SBX_PATTERNS.md` for detailed credential injection patterns.

---

## Execution Patterns

### sbx CLI (Recommended)

#### Basic: USAi Only

```bash
# Store secret (one-time) - USAi requires set-custom
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"

# Create/recreate sandbox
sbx rm SANDBOX_NAME 2>/dev/null; sbx create --name SANDBOX_NAME opencode .

# Run (secrets auto-injected)
sbx run SANDBOX_NAME
```

#### With GitHub (built-in service)

```bash
# One-time setup
gh auth token | sbx secret set -g github

# Run (GitHub auth handled automatically)
sbx run SANDBOX_NAME
```

#### With GitLab (custom endpoint)

```bash
# Store secret
sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN --value "$GITLAB_TOKEN"

# Recreate sandbox and run
sbx rm SANDBOX_NAME 2>/dev/null; sbx create --name SANDBOX_NAME opencode .
sbx run SANDBOX_NAME
```

#### With Codex (OpenAI CLI via USAi)

Codex uses its own config system (`.codex/config.toml`), **not** the `OPENAI_BASE_URL` env var.
This repo ships a `.codex/config.toml` that configures the USAi provider automatically.

```bash
# Store USAi API key as OPENAI_API_KEY (only secret needed - one-time)
sbx secret set-custom -g --host api.gsa.usai.gov --env OPENAI_API_KEY --value "$USAI_API_KEY"

# Run Codex - .codex/config.toml handles base URL and wire API
sbx run codex . -- -m gpt-5.4-latest-guardrails-defaultv2

# Or use Make (easiest)
make run-codex
```

> [!NOTE]
> `OPENAI_BASE_URL` has no effect on Codex CLI. Provider config is in `.codex/config.toml`.

---

## Security Considerations

Direct credential injection (for USAi, GitLab) means the agent CAN see the token in the container environment. This is acceptable for the Pre-ATO environment because:

1. **Pre-ATO environment** with low-impact data (no PII, no CUI)
2. **Tokens are scoped** - use minimal permissions
3. **Sandbox provides isolation** from host system
4. **Short-lived sessions** - tokens only in memory during execution

See the [Agentic Coding Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart) for full documentation on known failure modes and security considerations.
