# sbx CLI Quickstart Guide

> **Recommended for federal users** — Better automation, audit trails, and secure credential storage.

This guide walks you through setting up Docker Sandboxes using the `sbx` command-line interface to run AI coding agents with USAi.

## What is Docker Sandboxes?

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) runs AI coding agents in isolated microVM environments. Each sandbox gets its own Docker daemon, filesystem, and network—the agent can build containers, install packages, and modify files without touching your host system.

**Key benefits:**
- **Isolation** — Agent actions are contained; your host is protected
- **Reproducibility** — Same environment every time
- **Security** — Network policies control what the agent can access

## Why sbx CLI?

| Feature | sbx CLI | Docker Desktop UI |
|---------|---------|-------------------|
| Secure secret storage (keychain) | ✅ | ❌ (env vars only) |
| Full policy control | ✅ | Partial |
| CI/CD automation | ✅ | ❌ |
| Audit trail | ✅ | Limited |
| Scriptable setup | ✅ | ❌ |

For federal compliance and automation, sbx CLI is the recommended approach.

---

## Prerequisites

| Requirement | How to Check | Notes |
|-------------|--------------|-------|
| sbx CLI | `sbx version` | Standalone tool, Docker Desktop not required |
| USAi API key | From your GSA account | For Anthropic/Claude access |
| GitHub token | `gh auth token` | Optional, for code access |

> [!NOTE]
> Docker Desktop is **not required** to use sbx. The sbx CLI is a standalone tool.
> If you have Docker Desktop, your Docker subscription covers sbx licensing.

---

## Step 1: Install sbx CLI

```bash
# macOS
brew install docker/tap/sbx && sbx login

# Windows
winget install -h Docker.sbx && sbx login

# Linux (Ubuntu/Debian)
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm $USER
newgrp kvm
sbx login
```

**Verify installation:**

```bash
sbx version

# Expected output:
# Client Version:  v0.30.0 ...
# Server Version:  v0.30.0 ...
```

---

## Step 2: Configure Network Policy

Sandboxes use network policies to control what external services agents can access.

```bash
# Set default policy (first-time only)
sbx policy set-default balanced

# Allow USAi API endpoint
sbx policy allow network -g "api.gsa.usai.gov"

# Verify policies are set
sbx policy ls
```

### Understanding Network Policies

| Policy | Description | Use Case |
|--------|-------------|----------|
| `balanced` | Allows typical dev traffic (AI services, package registries) | **Recommended default** |
| `deny-all` | Blocks everything, explicit allowlist only | High-security environments |
| `allow-all` | All outbound traffic allowed | Testing only, not for GFE |

---

## Step 3: Store Your Secrets

Docker Sandboxes uses a secure secret store to inject credentials. Your API keys are stored in the **system keychain** and **auto-injected into sandboxes**.

### Store USAi API Key (Custom Endpoint)

USAi (`api.gsa.usai.gov`) is **not a built-in sbx service**, so you must use `sbx secret set-custom`:

```bash
# Store USAi API key for the custom endpoint
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"
```

> [!IMPORTANT]
> After setting or changing a custom secret, you must **delete and recreate** the sandbox for it to take effect.
> The `set-custom` command is experimental and may change in future sbx versions.

### Store Using Built-in Service Names

For built-in services (anthropic, github, openai, etc.), use the simpler syntax:

```bash
# For standard Anthropic endpoint (if not using USAi)
sbx secret set -g anthropic
# When prompted, enter your API key
```

### Store GitHub Token (for code access)

```bash
# Recommended: pipe from gh cli (never touches shell history)
gh auth token | sbx secret set -g github

# Or enter manually
sbx secret set -g github
# When prompted, paste output of: gh auth token
```

### Store GitLab Token (for self-hosted GitLab)

GitLab is **not a built-in sbx service**, so use `sbx secret set-custom`:

```bash
# For self-hosted GitLab (e.g., workshop.cloud.gov)
sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN --value "$GITLAB_TOKEN"

# Verify access inside sandbox
sbx exec SANDBOX_NAME sh -c 'curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://workshop.cloud.gov/api/v4/user | jq .username'
```

### Verify Stored Secrets

```bash
sbx secret ls
```

Expected output:
```
SCOPE      SERVICE        SECRET
(global)   USAI_API_KEY   api-ke******...******arNI
(global)   github         gho_Xb******...******oEtY
```

### Why Use `sbx secret` Instead of Shell Export?

| Feature | `sbx secret` | Shell Export (`export VAR=...`) |
|---------|--------------|--------------------------------|
| Persists across sessions | ✅ | ❌ |
| Stored encrypted (keychain) | ✅ | ❌ |
| Never in shell history | ✅ | ❌ (unless you're careful) |
| Works in CI/CD | ✅ | ✅ |
| Audit trail | ✅ | ❌ |
| Auto-injected into sandboxes | ✅ | ❌ |

**Bottom line:** `sbx secret` is more secure and convenient.

### Supported Services & Custom Variables

**Built-in services** (with special handling):

| Service | Variables Injected | Use Case |
|---------|-------------------|----------|
| `anthropic` | `ANTHROPIC_API_KEY` | Claude / Anthropic |
| `github` | `GH_TOKEN`, `GITHUB_TOKEN` | Code access, PRs |
| `openai` | `OPENAI_API_KEY` | OpenAI models |
| `google` | `GEMINI_API_KEY`, `GOOGLE_API_KEY` | Gemini models |
| `aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | AWS Bedrock |
| `groq` | `GROQ_API_KEY` | Groq inference |
| `mistral` | `MISTRAL_API_KEY` | Mistral models |

### Custom Endpoints (like USAi)

For custom API endpoints that aren't built-in services, use `sbx secret set-custom`:

| Endpoint | Command |
|----------|---------|
| USAi (`api.gsa.usai.gov`) | `sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"` |
| GitLab (self-hosted) | `sbx secret set-custom -g --host gitlab.example.com --env GITLAB_TOKEN --value "$GITLAB_TOKEN"` |

> [!WARNING]
> The `sbx secret set -g VARNAME` syntax does **not** work for custom variables like `USAI_API_KEY`.
> You must use `sbx secret set-custom` with the `--host` parameter.

### Managing Secrets

```bash
# List all secrets
sbx secret ls

# List only global secrets
sbx secret ls -g

# Remove a secret
sbx secret rm -g anthropic

# Update a secret (set it again, then recreate sandbox)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$NEW_KEY"
sbx rm my-sandbox && sbx create --name my-sandbox opencode .
```

---

## Step 4: Create Your First Sandbox

```bash
# Navigate to your project
cd /path/to/your/project

# Create and run sandbox with OpenCode
sbx run opencode .
```

The sandbox will start and you'll be inside the agent environment.

### Other Supported Agents

```bash
sbx run claude .      # Claude Code
sbx run copilot .     # GitHub Copilot
sbx run cursor .      # Cursor
sbx run codex .       # OpenAI Codex
sbx run gemini .      # Google Gemini
sbx run shell .       # Just a shell (no agent)
```

### Create with Custom Name

```bash
# Create with a specific name
sbx create --name my-feature opencode .

# Then run it
sbx run my-feature
```

---

## Step 5: Managing Sandboxes

```bash
# List all sandboxes
sbx ls

# Stop a sandbox (preserves state)
sbx stop my-sandbox

# Resume a stopped sandbox
sbx run my-sandbox

# Remove a sandbox permanently
sbx rm my-sandbox

# Remove all sandboxes
sbx rm --all

# Shell into a running sandbox
sbx exec -it my-sandbox bash
```

---

## Common Commands Reference

| Task | Command |
|------|---------|
| Check version | `sbx version` |
| List sandboxes | `sbx ls` |
| Create sandbox | `sbx run <agent> .` |
| Stop sandbox | `sbx stop <name>` |
| Resume sandbox | `sbx run <name>` |
| Remove sandbox | `sbx rm <name>` |
| Shell access | `sbx exec -it <name> bash` |
| Copy files | `sbx cp ./file.txt <name>:/path/` |
| **Secrets** | |
| List secrets | `sbx secret ls` |
| Add secret | `sbx secret set -g <service>` |
| Remove secret | `sbx secret rm -g <service>` |
| **Policies** | |
| List policies | `sbx policy ls` |
| Set default | `sbx policy set-default balanced` |
| Allow domain | `sbx policy allow network -g "domain.com"` |
| Check logs | `sbx policy log` |
| **Troubleshooting** | |
| Run diagnostics | `sbx diagnose` |
| Reset everything | `sbx reset --preserve-secrets` |

---

## Troubleshooting

### Secret Not Working

```bash
# Verify secret is stored
sbx secret ls

# Check the service name is correct
sbx secret set --help  # Lists supported services

# Re-set the secret if needed
sbx secret set -g anthropic
```

### Network Access Denied

```bash
# Check policy logs for blocked requests
sbx policy log

# Add the missing domain
sbx policy allow network -g "blocked-domain.com"

# Verify policies
sbx policy ls
```

### Sandbox Won't Start

```bash
# Run diagnostics
sbx diagnose

# Check Docker is running
docker info

# Reset if needed (preserves your secrets)
sbx reset --preserve-secrets
```

### USAi Connection Issues

1. Verify USAi endpoint is allowed: `sbx policy ls`
2. Check your API key is set: `sbx secret ls`
3. Check policy logs: `sbx policy log`
4. See [Known Failure Modes](KNOWN_FAILURE_MODES.md) for more

---

## Advanced: CI/CD Setup

For non-interactive environments (GitHub Actions, GitLab CI):

```bash
# Set policy non-interactively
sbx policy set-default balanced

# Store secrets from environment variables (pipe to avoid prompts)
echo "$ANTHROPIC_API_KEY" | sbx secret set -g anthropic
echo "$GITHUB_TOKEN" | sbx secret set -g github

# Login with PAT (personal access token)
echo "$DOCKER_PAT" | sbx login --password-stdin --username "$DOCKER_USER"
```

### Example GitHub Actions Workflow

```yaml
- name: Setup sbx
  run: |
    sbx policy set-default balanced
    sbx policy allow network -g "api.gsa.usai.gov"
    echo "${{ secrets.ANTHROPIC_API_KEY }}" | sbx secret set -g anthropic

- name: Run agent
  run: sbx run opencode . -- --task "run tests"
```

---

## Working with Git Branches

Create isolated sandboxes for different branches:

```bash
# Create sandbox with Git worktree for a feature branch
sbx create --branch=feature/login opencode .

# Work in isolation - changes stay on that branch
sbx run opencode-myproject
```

---

## Security Reminders

1. **Never print your API key**: Use `${#VAR}` to check length, not `echo $VAR`
2. **Never commit secrets**: The `opencode.jsonc` uses `${USAI_API_KEY}` variable substitution
3. **Always use SBX**: Don't run agents directly on host with credentials
4. **Review agent output**: Before sharing logs, ensure no secrets leaked
5. **Use `sbx secret set` for persistent storage**: More secure than environment variables
6. **Pipe tokens from CLI tools**: Avoids shell history exposure (e.g., `gh auth token | sbx secret set -g github`)

---

## Migrating from `docker sandbox`

> [!NOTE]
> The Docker Desktop-integrated `docker sandbox` command is deprecated.
> If you're currently using `docker sandbox`, migrate to `sbx`:

| Deprecated Command | New Command |
|-------------------|-------------|
| `docker sandbox create --name NAME opencode .` | `sbx create --name NAME opencode .` |
| `docker sandbox run NAME` | `sbx run NAME` |
| `docker sandbox exec NAME cmd` | `sbx exec NAME cmd` |
| `docker sandbox ls` | `sbx ls` |
| `docker sandbox rm NAME` | `sbx rm NAME` |

Your existing sandboxes and secrets will continue to work with the `sbx` CLI.

### Migration from Pre-v0.9.0

If you previously used `make create-sandbox`, you may have an orphaned `quickstart` sandbox that is no longer used. The new `make run-agent` uses `sbx run` which manages sandboxes automatically.

To clean up the old sandbox:

```bash
# Check for old sandbox
sbx ls | grep quickstart

# Remove if present (optional - it won't interfere, just wastes disk space)
sbx rm quickstart
```

The new workflow is simpler:
- Old: `make create-sandbox` then `make run-agent`
- New: `make run-agent` (creates sandbox automatically via `sbx run`)

---

## Next Steps

- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Common issues and solutions
- [Coding Practices](CODING_PRACTICES.md) — Secure coding standards
- [Docker Desktop Alternative](QUICKSTART_DOCKER_DESKTOP.md) — If you prefer GUI

---

## Getting Help

- **Slack:** #agentic-coding (GSA internal)
- **GitHub Issues:** [agentic-coding-quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart/issues)
- **Docker Docs:** [docs.docker.com/ai/sandboxes](https://docs.docker.com/ai/sandboxes/)
