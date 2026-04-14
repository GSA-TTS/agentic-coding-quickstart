# SBX Credential Injection Patterns

Quick reference for injecting credentials into Docker SBX sandboxes.

## Overview

| Method | Security | Use Case | Supported Services |
|--------|----------|----------|-------------------|
| **SBX Proxy** (recommended) | High - agent never sees token | Standard API endpoints | `anthropic`, `aws`, `cursor`, `github`, `google`, `groq`, `mistral`, `nebius`, `openai`, `xai` |
| **Direct Injection** (`-e`) | Medium - token in container env | Custom endpoints | Any service (USAi, GitLab, etc.) |

**Rule of thumb:** Use SBX proxy when available; use direct injection for custom endpoints.

---

## USAi (Direct Injection Required)

USAi uses a custom endpoint (`api.gsa.usai.gov`) that the SBX proxy doesn't recognize.

```bash
# Set on host
export USAI_API_KEY="your-key-here"

# Inject into sandbox
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode
```

---

## GitHub

### Method 1: SBX Proxy (Recommended)

```bash
# One-time setup - pipe from gh cli (avoids shell history)
gh auth token | sbx secret set -g github

# Verify
sbx secret ls

# Run - proxy handles auth automatically
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode
```

### Method 2: Direct Injection

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

GitLab is NOT a built-in SBX service.

### gitlab.com

```bash
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="your-gitlab-token" \
  -w $(pwd) SANDBOX_NAME opencode
```

### Self-Hosted GitLab (e.g., workshop.cloud.gov)

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

| Provider | SBX Proxy | Direct Injection | CLI to Extract Token |
|----------|-----------|------------------|---------------------|
| USAi | Not supported | `-e USAI_API_KEY="$USAI_API_KEY"` | N/A (manual) |
| GitHub | `sbx secret set -g github` | `-e GH_TOKEN="$(gh auth token)"` | `gh auth token` |
| GitLab.com | Not supported | `-e GITLAB_TOKEN="..."` | `glab config get token` |
| GitLab (self-hosted) | Not supported | `-e GITLAB_TOKEN="..." -e GITLAB_HOST="..."` | `glab config get --host HOST token` |

---

## Security Notes

1. **Prefer SBX proxy when available** - more secure, agent never sees token
2. **Pipe tokens from CLI tools** - avoids shell history (`gh auth token | sbx secret set -g github`)
3. **Scope tokens minimally** - only grant permissions the agent needs
4. **Tokens exist only in memory** - never written to disk inside container
5. **Review agent output** - before sharing logs, ensure no tokens leaked

For full security analysis, see [KNOWN_FAILURE_MODES.md Section 15](https://github.com/GSA-TTS/agentic-coding-quickstart/blob/main/docs/KNOWN_FAILURE_MODES.md#15-direct-credential-injection-for-git-providers-security-consideration).
