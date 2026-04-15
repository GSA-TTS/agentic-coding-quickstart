# Docker Sandboxes Credential Injection Patterns

Quick reference for injecting credentials into Docker Sandboxes (both Docker Desktop and standalone sbx CLI).

## Two Ways to Use Docker Sandboxes

| Method | Install | Command Prefix | Credential Handling |
|--------|---------|----------------|---------------------|
| **Docker Desktop built-in** | None (Docker Desktop 4.58+) | `docker sandbox` | Shell config + restart Docker |
| **Standalone sbx CLI** | Homebrew/Winget/apt | `sbx` | `-e` flags or `sbx secret set` |

See [Docker Sandboxes documentation](https://docs.docker.com/ai/sandboxes/) for installation.

## Network Policy Configuration (Required)

When first running sandbox commands, you'll be prompted to choose a network policy.

> **⚠️ Do NOT choose "Open" on GFE machines** — it allows the agent to access internal GSA network resources.

**Recommended setup:**
```bash
# Choose "Balanced" when prompted, then add USAi endpoint:
sbx policy allow network "api.gsa.usai.gov"

# Verify
sbx policy ls
```

If you accidentally chose "Open", reset and reconfigure:
```bash
sbx policy reset
# Choose "Balanced", then:
sbx policy allow network "api.gsa.usai.gov"
```

---

## Credential Methods Overview

| Method | Security | Use Case | Supported Services |
|--------|----------|----------|-------------------|
| **Shell Config** (Docker Desktop) | Medium - Docker reads from shell | All services | Any environment variable |
| **SBX Proxy** (sbx CLI) | High - agent never sees token | Standard API endpoints | `anthropic`, `aws`, `cursor`, `github`, `google`, `groq`, `mistral`, `nebius`, `openai`, `xai` |
| **Direct Injection** (`-e`) | Medium - token in container env | Custom endpoints | Any service (USAi, GitLab, etc.) |

**Rule of thumb:** 
- Docker Desktop: Add to shell config, restart Docker
- sbx CLI: Use proxy when available; use `-e` for custom endpoints

---

## USAi

USAi uses a custom endpoint (`api.gsa.usai.gov`) that the SBX proxy doesn't recognize.

### Docker Desktop

```bash
# Add to ~/.bashrc or ~/.zshrc
export USAI_API_KEY="your-key-here"

# Source and COMPLETELY restart Docker Desktop (Quit → Reopen)
source ~/.zshrc
# Then restart Docker Desktop from menu/taskbar

# Run
docker sandbox run SANDBOX_NAME
```

### Standalone sbx CLI

```bash
# Set on host
export USAI_API_KEY="your-key-here"

# Inject into sandbox
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode
```

---

## GitHub

### Docker Desktop

```bash
# Add to ~/.bashrc or ~/.zshrc
export GH_TOKEN="$(gh auth token)"
# Or: export GITHUB_TOKEN="your-pat"

# Source and restart Docker Desktop
```

### Standalone sbx CLI

#### Method 1: SBX Proxy (Recommended)

```bash
# One-time setup - pipe from gh cli (avoids shell history)
gh auth token | sbx secret set -g github

# Verify
sbx secret ls

# Run - proxy handles auth automatically
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode
```

#### Method 2: Direct Injection

```bash
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GH_TOKEN="$(gh auth token)" \
  -w $(pwd) SANDBOX_NAME opencode
```

### Verify GitHub Access

```bash
# With proxy - use dummy token, proxy injects real one
sbx exec SANDBOX_NAME sh -c 'curl -s -H "Authorization: Bearer test" https://api.github.com/user | jq .login'

# With direct injection
sbx exec -e GH_TOKEN="$(gh auth token)" SANDBOX_NAME sh -c 'curl -s -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user | jq .login'
```

---

## GitLab (Direct Injection Required)

GitLab is NOT a built-in service for either method.

### Docker Desktop

```bash
# Add to ~/.bashrc or ~/.zshrc
export GITLAB_TOKEN="your-gitlab-token"
export GITLAB_HOST="workshop.cloud.gov"  # for self-hosted

# Source and restart Docker Desktop
```

### Standalone sbx CLI

#### gitlab.com

```bash
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="your-gitlab-token" \
  -w $(pwd) SANDBOX_NAME opencode
```

#### Self-Hosted GitLab (e.g., workshop.cloud.gov)

```bash
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) SANDBOX_NAME opencode
```

### Verify GitLab Access

```bash
sbx exec -e GITLAB_TOKEN="$GITLAB_TOKEN" -e GITLAB_HOST="workshop.cloud.gov" SANDBOX_NAME \
  sh -c 'curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://$GITLAB_HOST/api/v4/user | jq .username'
```

---

## Combined: All Services

### Docker Desktop

Add all variables to shell config:
```bash
# ~/.bashrc or ~/.zshrc
export USAI_API_KEY="your-usai-key"
export GH_TOKEN="$(gh auth token)"
export GITLAB_TOKEN="your-gitlab-token"
export GITLAB_HOST="workshop.cloud.gov"
```

Then restart Docker Desktop and run: `docker sandbox run SANDBOX_NAME`

### Standalone sbx CLI

For agents needing USAi + GitHub + GitLab:

```bash
# Assumes: gh logged in, glab logged in, USAI_API_KEY set, github secret in SBX

sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) SANDBOX_NAME opencode
```

> **Note:** If you've set GitHub via `sbx secret set -g github`, omit `-e GH_TOKEN` - the proxy handles it.

---

## Quick Reference

| Provider | Docker Desktop | sbx CLI (Proxy) | sbx CLI (Direct) |
|----------|----------------|-----------------|------------------|
| USAi | `USAI_API_KEY` in shell config | N/A | `-e USAI_API_KEY="$USAI_API_KEY"` |
| GitHub | `GH_TOKEN` in shell config | `sbx secret set -g github` | `-e GH_TOKEN="$(gh auth token)"` |
| GitLab.com | `GITLAB_TOKEN` in shell config | N/A | `-e GITLAB_TOKEN="..."` |
| GitLab (self-hosted) | `GITLAB_TOKEN` + `GITLAB_HOST` | N/A | `-e GITLAB_TOKEN="..." -e GITLAB_HOST="..."` |

---

## Security Notes

1. **Docker Desktop:** Restart required after changing shell config
2. **Prefer SBX proxy when available** (sbx CLI) - more secure, agent never sees token
3. **Pipe tokens from CLI tools** - avoids shell history (`gh auth token | sbx secret set -g github`)
4. **Scope tokens minimally** - only grant permissions the agent needs
5. **Tokens exist only in memory** - never written to disk inside container
6. **Review agent output** - before sharing logs, ensure no tokens leaked

For full security analysis, see [KNOWN_FAILURE_MODES.md Section 15](https://github.com/GSA-TTS/agentic-coding-quickstart/blob/main/docs/KNOWN_FAILURE_MODES.md#15-direct-credential-injection-for-git-providers-security-consideration).
