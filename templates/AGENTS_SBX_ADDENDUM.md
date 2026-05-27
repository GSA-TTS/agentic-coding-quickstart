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

| Service | sbx CLI (Secret Store) | sbx CLI (Direct) |
|---------|------------------------|------------------|
| USAi | `sbx secret set -g USAI_API_KEY` | `-e USAI_API_KEY="$USAI_API_KEY"` |
| GitHub | `sbx secret set -g github` | `-e GH_TOKEN="$(gh auth token)"` |
| GitLab | `sbx secret set -g GITLAB_TOKEN` | `-e GITLAB_TOKEN="..."` |

See `docs/SBX_PATTERNS.md` for detailed credential injection patterns.

---

## Execution Patterns

### sbx CLI (Recommended)

#### Basic: USAi Only

```bash
# Store secret (one-time)
sbx secret set -g USAI_API_KEY

# Run (secrets auto-injected)
sbx run SANDBOX_NAME
```

#### With GitHub (via secret store)

```bash
# One-time setup
sbx secret set -g github
# Enter: output of `gh auth token`

# Run (GitHub auth handled automatically)
sbx run SANDBOX_NAME
```

#### With GitLab (direct injection)

```bash
sbx exec -it \
  -e GITLAB_TOKEN="$(glab config get --host GITLAB_HOST token)" \
  -e GITLAB_HOST="GITLAB_HOST" \
  -w $(pwd) SANDBOX_NAME opencode
```

---

## Security Considerations

Direct credential injection (for USAi, GitLab) means the agent CAN see the token in the container environment. This is acceptable for the Pre-ATO environment because:

1. **Pre-ATO environment** with low-impact data (no PII, no CUI)
2. **Tokens are scoped** - use minimal permissions
3. **Sandbox provides isolation** from host system
4. **Short-lived sessions** - tokens only in memory during execution

See the [Agentic Coding Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart) for full documentation on known failure modes and security considerations.
