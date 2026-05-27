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
| **SBX Secret Store** (recommended) | High - stored in keychain, auto-injected | Any credential | Built-in services + custom vars |
| **Direct Injection** (`-e`) | Medium - token in container env | One-off testing | Any service |

**Rule of thumb:** Use `sbx secret set -g` for any credential you use regularly; use `-e` only for one-off testing.

---

## USAi

USAi uses a custom endpoint (`api.gsa.usai.gov`). Store the key using `sbx secret`:

```bash
# Store securely in system keychain (recommended)
sbx secret set -g USAI_API_KEY
# Enter your key when prompted

# Run - secrets auto-injected
sbx run SANDBOX_NAME
```

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

GitLab credentials are not auto-injected. Use `sbx secret` or direct injection.

### Store in sbx secret (recommended)

```bash
# Store GitLab token
sbx secret set -g GITLAB_TOKEN
# Enter your token when prompted

# For self-hosted, also store the host
sbx secret set -g GITLAB_HOST
# Enter: workshop.cloud.gov (or your host)
```

### Direct injection (one-off)

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

### sbx CLI (Recommended)

For agents needing USAi + GitHub + GitLab:

```bash
# Assumes: gh logged in, glab logged in, secrets stored in sbx

sbx exec -it \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) SANDBOX_NAME opencode
```

> **Note:** If you've set secrets via `sbx secret set -g`, they are auto-injected.

---

## Quick Reference

| Provider | sbx CLI (Secret Store) | sbx CLI (Direct) |
|----------|------------------------|------------------|
| USAi | `sbx secret set -g USAI_API_KEY` | `-e USAI_API_KEY="$USAI_API_KEY"` |
| GitHub | `sbx secret set -g github` | `-e GH_TOKEN="$(gh auth token)"` |
| GitLab.com | `sbx secret set -g GITLAB_TOKEN` | `-e GITLAB_TOKEN="..."` |
| GitLab (self-hosted) | + `sbx secret set -g GITLAB_HOST` | + `-e GITLAB_HOST="..."` |

---

## Security Notes

1. **Prefer sbx secret store** - more secure, stored in system keychain
2. **Pipe tokens from CLI tools** - avoids shell history (`gh auth token | sbx secret set -g github`)
3. **Scope tokens minimally** - only grant permissions the agent needs
4. **Tokens exist only in memory** - never written to disk inside container
5. **Review agent output** - before sharing logs, ensure no tokens leaked

For full security analysis, see [KNOWN_FAILURE_MODES.md Section 15](https://github.com/GSA-TTS/agentic-coding-quickstart/blob/main/docs/KNOWN_FAILURE_MODES.md#15-direct-credential-injection-for-git-providers-security-consideration).
