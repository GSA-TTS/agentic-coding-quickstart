# Docker Sandboxes + USAi Addendum for AGENTS.md

> **Instructions:** Append this content to your existing AGENTS.md file.
> If you don't have an AGENTS.md, consider using the [Agentic Coding Playbook](https://github.com/GSA-TTS/agentic-coding-playbook) to generate one first.

---

## Docker Sandboxes Overview

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) runs AI coding agents in isolated microVM environments. There are two ways to use it:

| Method | Command Prefix | Best For |
|--------|----------------|----------|
| **Docker Desktop built-in** | `docker sandbox` | GFE Macs with managed Docker (4.58+) |
| **Standalone sbx CLI** | `sbx` | Full features, secret proxy |

## SBX-Specific Rules (Non-Negotiable)

### 1. No Secrets Exposure

The agent MUST NEVER:
- Print, log, or persist API keys, tokens, or credentials
- Hardcode secrets in source files, config files, or scripts
- Use `printenv`, `env`, or `echo $SECRET` in ways that expose values
- Include secrets in commit messages, comments, or documentation

All secrets MUST be accessed via:
- Docker Desktop: Environment variables set in shell config (read by Docker at startup)
- sbx CLI: Secret management (`sbx secret set`) or runtime injection (`-e` flag)

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

| Service | Docker Desktop | sbx CLI |
|---------|----------------|---------|
| USAi | `USAI_API_KEY` in shell config | `-e USAI_API_KEY="$USAI_API_KEY"` |
| GitHub | `GH_TOKEN` in shell config | `sbx secret set -g github` (recommended) |
| GitLab | `GITLAB_TOKEN` in shell config | `-e GITLAB_TOKEN="..."` |

See `docs/SBX_PATTERNS.md` for detailed credential injection patterns.

---

## Execution Patterns

### Docker Desktop

```bash
# Create sandbox
docker sandbox create --name SANDBOX_NAME opencode .

# Run (environment variables come from shell config)
docker sandbox run SANDBOX_NAME
```

### Standalone sbx CLI

#### Basic: USAi Only

```bash
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode
```

#### With GitHub (via proxy - recommended)

```bash
# One-time setup
gh auth token | sbx secret set -g github

# Run (GitHub auth handled by proxy)
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode
```

#### With GitLab (direct injection)

```bash
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host GITLAB_HOST token)" \
  -e GITLAB_HOST="GITLAB_HOST" \
  -w $(pwd) SANDBOX_NAME opencode
```

---

## Security Considerations

Direct credential injection (for USAi, GitLab) means the agent CAN see the token in the container environment. This is acceptable for the pilot because:

1. **Pre-ATO pilot** with low-impact data (no PII, no CUI)
2. **Tokens are scoped** - use minimal permissions
3. **Sandbox provides isolation** from host system
4. **Short-lived sessions** - tokens only in memory during execution

See the [Agentic Coding Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart) for full documentation on known failure modes and security considerations.
