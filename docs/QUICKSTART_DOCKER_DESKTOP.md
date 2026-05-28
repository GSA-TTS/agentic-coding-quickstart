# Docker Desktop Quickstart Guide

> [!CAUTION]
> **DEPRECATED:** The Docker Desktop-integrated `docker sandbox` commands are deprecated by Docker.
> Please use the standalone **[sbx CLI Guide](QUICKSTART_SBX.md)** instead.
>
> See [Docker's deprecation notice](https://docs.docker.com/reference/cli/docker/sandbox/).

---

## Migration to sbx CLI

If you're currently using `docker sandbox` commands, migrate to `sbx`:

| Deprecated Command | New Command |
|-------------------|-------------|
| `docker sandbox create` | `sbx create` |
| `docker sandbox run opencode .` | `sbx run opencode .` |
| `docker sandbox exec` | `sbx exec` |
| `docker sandbox ls` | `sbx ls` |
| `docker sandbox rm` | `sbx rm` |
| `docker sandbox stop` | `sbx stop` |

**Install sbx CLI:**

```bash
# macOS
brew install docker/tap/sbx

# Windows
winget install Docker.sbx
```

**Your existing sandboxes and secrets will continue to work with the `sbx` CLI.**

**[Continue to sbx CLI Guide](QUICKSTART_SBX.md)**

---

## Legacy Documentation (Deprecated)

> [!WARNING]
> The following documentation is preserved for reference only.
> The `docker sandbox` commands will stop working in a future Docker Desktop release.

This guide covers using Docker Desktop's graphical interface to run AI coding agents with USAi.

---

## Why Consider sbx CLI Instead?

| Feature | sbx CLI | Docker Desktop UI |
|---------|---------|-------------------|
| Secure secret storage (keychain) | ✅ | ❌ |
| Full policy control | ✅ | Partial |
| CI/CD automation | ✅ | ❌ |
| Audit trail | ✅ | Limited |
| Federal compliance | ✅ Better | ⚠️ Limited |

**Note:** Even with Docker Desktop UI, you'll need the `sbx` command for some features like secure secret storage.

---

## Prerequisites

| Requirement | How to Check | Notes |
|-------------|--------------|-------|
| Docker Desktop 4.41+ | Check About dialog | Must be recent version |
| USAi API key | From your GSA account | For Anthropic/Claude access |
| GitHub token | `gh auth token` | Optional, for code access |

---

## Step 1: Verify Docker Desktop Version

1. Open Docker Desktop
2. Click the **gear icon** (Settings) in top-right
3. Click **About** or check the version in the window title
4. Ensure version is **4.41 or later**

**Older version?** Update Docker Desktop from [docker.com/products/docker-desktop](https://docker.com/products/docker-desktop)

---

## Step 2: Configure Network Policy

Even with Docker Desktop UI, network policies are configured via the `sbx` command:

```bash
# Set default policy
sbx policy set-default balanced

# Allow USAi endpoint
sbx policy allow network -g "api.gsa.usai.gov"
```

---

## Step 3: Configure API Credentials

### Option A: Shell Environment Variables (Simpler but Less Secure)

Add to your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
export ANTHROPIC_API_KEY="your-usai-api-key"
export GITHUB_TOKEN="your-github-token"
```

Then reload:
```bash
source ~/.zshrc  # or ~/.bashrc
```

### Option B: Use sbx secret (Recommended)

Even when using Docker Desktop UI, you can use `sbx secret` for better security:

```bash
# Store USAi key securely (USAi is a custom endpoint)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"

# Store GitHub token (built-in service)
gh auth token | sbx secret set -g github

# Verify
sbx secret ls
```

> [!NOTE]
> After setting secrets, you must **delete and recreate** the sandbox for changes to take effect.

**Why `sbx secret` is better:**

| Feature | `sbx secret` | Environment Variables |
|---------|--------------|----------------------|
| Stored in keychain (encrypted) | ✅ | ❌ |
| Persists across sessions | ✅ | Only if in shell profile |
| Never in shell history | ✅ | Risk of exposure |
| Agent never sees raw key | ✅ | ❌ |

---

## Step 4: Create a Sandbox

### Via `docker sandbox` Command

```bash
# Navigate to your project
cd /path/to/your/project

# Create and run sandbox
docker sandbox run opencode .
```

### Via Docker Desktop UI (if available)

1. Open Docker Desktop
2. Look for **Sandboxes** in the left sidebar
3. Click **Create Sandbox**
4. Select your agent (e.g., OpenCode, Claude)
5. Choose your project directory
6. Click **Create**

> **Note:** UI availability depends on Docker Desktop version and configuration.

---

## Step 5: Managing Sandboxes

### Via Command Line

```bash
# List sandboxes
docker sandbox ls

# Stop a sandbox
docker sandbox stop <name>

# Remove a sandbox
docker sandbox rm <name>
```

### Via Docker Desktop UI

- **View sandboxes:** Click "Sandboxes" in sidebar
- **Stop:** Click stop button next to sandbox
- **Remove:** Click trash icon
- **Terminal:** Click terminal icon for shell access

---

## Supported Agents

| Agent | Command |
|-------|---------|
| OpenCode | `docker sandbox run opencode .` |
| Claude Code | `docker sandbox run claude .` |
| GitHub Copilot | `docker sandbox run copilot .` |
| Cursor | `docker sandbox run cursor .` |

---

## Troubleshooting

### Sandboxes Not Visible in Docker Desktop

1. Verify Docker Desktop is 4.41+
2. Check Settings > Features in development
3. Restart Docker Desktop

### API Key Not Working

1. Check environment variable is set: `echo $ANTHROPIC_API_KEY`
2. Restart terminal after setting variables
3. **Better:** Switch to `sbx secret` for reliable credential injection

### Network Access Issues

```bash
# Check what's being blocked
sbx policy log

# Add missing domain
sbx policy allow network -g "missing-domain.com"
```

### General Issues

```bash
# Run diagnostics
sbx diagnose

# Reset (preserves secrets if using sbx secret)
sbx reset --preserve-secrets
```

---

## Switching to sbx CLI

Ready for more control? Switch to the [sbx CLI Guide](QUICKSTART_SBX.md):

1. Your existing sandboxes will continue to work
2. Migrate credentials to secure storage:
   ```bash
   sbx secret set -g anthropic
   sbx secret set -g github
   ```
3. Remove environment variables from shell profile (optional)
4. Use `sbx` commands instead of `docker sandbox`

---

## Command Comparison

| Task | Docker Desktop | sbx CLI |
|------|---------------|---------|
| Run sandbox | `docker sandbox run opencode .` | `sbx run opencode .` |
| List sandboxes | `docker sandbox ls` | `sbx ls` |
| Stop | `docker sandbox stop <name>` | `sbx stop <name>` |
| Remove | `docker sandbox rm <name>` | `sbx rm <name>` |
| **Store secret** | ❌ Not available | `sbx secret set -g <service>` |
| **Set policy** | ❌ Not available | `sbx policy set-default balanced` |

---

## Next Steps

- [sbx CLI Guide](QUICKSTART_SBX.md) — **Recommended:** Full-featured command line approach
- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Common issues and solutions
- [Coding Practices](CODING_PRACTICES.md) — Secure coding standards

---

## Getting Help

- **Slack:** #agentic-coding (GSA internal)
- **GitHub Issues:** [agentic-coding-quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart/issues)
- **Docker Docs:** [docs.docker.com/ai/sandboxes](https://docs.docker.com/ai/sandboxes/)
