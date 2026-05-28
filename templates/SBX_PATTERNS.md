# Docker Sandboxes Credential Injection Patterns

Quick reference for injecting credentials into Docker Sandboxes using the standalone `sbx` CLI.

> [!IMPORTANT]
> The Docker Desktop-integrated `docker sandbox` commands are **deprecated**.
> Use the standalone `sbx` CLI instead.
> See [Docker's deprecation notice](https://docs.docker.com/reference/cli/docker/sandbox/).

## Installing sbx CLI

```bash
# macOS
brew install docker/tap/sbx

# Windows
winget install Docker.sbx
```

See [Docker Sandboxes documentation](https://docs.docker.com/ai/sandboxes/) for full details.

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
| **SBX Secret Store** (recommended) | High - stored in keychain, auto-injected | Any credential | Built-in services |
| **SBX Secret Set-Custom** | High - stored in keychain | Custom endpoints (USAi, GitLab) | Any custom host |
| **Direct Injection** (`-e`) | Medium - token in container env | One-off testing | Any service |

**Rule of thumb:** Use `sbx secret set -g` for built-in services (github, anthropic, etc.); use `sbx secret set-custom` for custom endpoints like USAi.

---

## USAi

USAi (`api.gsa.usai.gov`) is **not a built-in sbx service**. You must use `sbx secret set-custom`:

```bash
# Store securely in system keychain (required for USAi)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"

# Recreate sandbox to pick up new secret
sbx rm SANDBOX_NAME 2>/dev/null; sbx create --name SANDBOX_NAME opencode .

# Run - secrets auto-injected
sbx run SANDBOX_NAME
```

> [!IMPORTANT]
> After setting or changing a custom secret, you must **delete and recreate** the sandbox.

Or for one-off testing:
```bash
# Set on host
export USAI_API_KEY="your-key-here"

# Inject into sandbox
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) SANDBOX_NAME opencode
```

---

## GitHub

### Method 1: SBX Secret Store (Recommended)

GitHub is a **built-in service**, so use the simpler syntax:

```bash
# One-time setup - pipe from gh cli (avoids shell history)
gh auth token | sbx secret set -g github

# Verify
sbx secret ls

# Run - proxy handles auth automatically
sbx run SANDBOX_NAME
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

## GitLab (Custom Endpoint)

GitLab (especially self-hosted instances) requires `sbx secret set-custom`:

### Store in sbx secret (recommended)

```bash
# Store GitLab token for self-hosted instance
sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN --value "$GITLAB_TOKEN"

# Recreate sandbox to pick up new secret
sbx rm SANDBOX_NAME 2>/dev/null; sbx create --name SANDBOX_NAME opencode .
```

### Direct injection (one-off)

#### gitlab.com

```bash
sbx exec -it \
  -e GITLAB_TOKEN="your-gitlab-token" \
  -w $(pwd) SANDBOX_NAME opencode
```

#### Self-Hosted GitLab (e.g., workshop.cloud.gov)

```bash
sbx exec -it \
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

### sbx CLI (Recommended)

For agents needing USAi + GitHub + GitLab, first set up all secrets:

```bash
# One-time setup
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"
sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN --value "$GITLAB_TOKEN"
gh auth token | sbx secret set -g github

# Recreate sandbox
sbx rm SANDBOX_NAME 2>/dev/null; sbx create --name SANDBOX_NAME opencode .

# Run - all secrets auto-injected
sbx run SANDBOX_NAME
```

---

## Quick Reference

| Provider | Command | Notes |
|----------|---------|-------|
| USAi | `sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"` | Custom endpoint |
| GitHub | `gh auth token \| sbx secret set -g github` | Built-in service |
| GitLab (self-hosted) | `sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN --value "$GITLAB_TOKEN"` | Custom endpoint |

> [!IMPORTANT]
> After setting custom secrets, **delete and recreate** the sandbox for changes to take effect.

---

## Security Notes

1. **Use `sbx secret set-custom` for custom endpoints** like USAi (not `sbx secret set -g VARNAME`)
2. **Use `sbx secret set -g SERVICE` for built-in services** like github, anthropic
3. **Pipe tokens from CLI tools** - avoids shell history (`gh auth token | sbx secret set -g github`)
4. **Scope tokens minimally** - only grant permissions the agent needs
5. **Tokens exist only in memory** - never written to disk inside container
6. **Review agent output** - before sharing logs, ensure no tokens leaked

For full security analysis, see [KNOWN_FAILURE_MODES.md Section 15](https://github.com/GSA-TTS/agentic-coding-quickstart/blob/main/docs/KNOWN_FAILURE_MODES.md#15-direct-credential-injection-for-git-providers-security-consideration).
