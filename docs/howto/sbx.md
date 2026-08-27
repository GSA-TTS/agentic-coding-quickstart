# sbx CLI How-To Guide

> The [README](../../README.md) is the quickstart. This is the detailed sbx
> how-to.
>
> **Note:** `msb` (microsandbox) is `acq`'s **default** backend. Use this `sbx`
> guide when you specifically want the Docker Sandboxes backend (for example, you
> already run Docker Sandboxes, or want its proxy-based credential store). See the
> [Backend Guide](../BACKEND_GUIDE.md) to choose between backends, or the
> [msb How-To](msb.md) for the default backend. This guide is
> the sbx **alternative**, not the recommended default (see
> [ADR-0024](../adr/0024-neutral-user-facing-docs-vs-backend-specific.md) for the
> neutral-first documentation convention).

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

If you have chosen the sbx backend, use the sbx CLI (not the Docker Desktop
UI) for federal compliance and automation. To choose between backends in the
first place, see the [Backend Guide](../BACKEND_GUIDE.md) — `msb` is `acq`'s
default.

---

## Prerequisites

| Requirement | How to Check | Notes |
|-------------|--------------|-------|
| sbx CLI | `sbx version` | Standalone tool, Docker Desktop not required |
| Docker account | `sbx login` succeeds | Your org may require a paid Docker subscription seat |
| USAi API key | — | **Nothing to get in advance** — `acq` prompts you and validates it on first run. Set ahead of time only when pre-seeding/scripting. |
| GitHub token | — | **Nothing to get in advance** — `acq` offers to scope one on first run when your workspace has GitHub repos. Optional, for code access. |

> [!NOTE]
> Docker Desktop is **not required** to use sbx. The sbx CLI is a standalone tool.
> `sbx login` signs in with a Docker account. In at least one organization we've
> seen, sign-in fails with a "Not enough seats in organization" error unless you
> have a paid Docker subscription seat. If you have a Docker Desktop subscription,
> that already provides your seat; otherwise ask your organization's Docker
> administrator to assign you one. For how Docker licensing works, see
> [Docker's subscription docs](https://docs.docker.com/subscription/).

---

## Step 1: Install sbx CLI

```bash
# macOS
brew install docker/tap/sbx && sbx login
```

> Don't have Homebrew? Install it from [brew.sh](https://brew.sh) first.

```bash
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

# Expected output (single line):
# sbx version: v0.32.0 <commit-sha>
```

---

## Step 2: Configure Network Policy

Sandboxes use network policies to control what external services agents can access.

```bash
# Set default policy (first-time only)
sbx policy init balanced

# Allow USAi API endpoint
sbx policy allow network "api.gsa.usai.gov"

# Verify policies are set
sbx policy ls
```

> **macOS:** the first time `sbx policy init balanced` builds a sandbox
> filesystem, macOS Gatekeeper may block `mkfs.erofs` with *"…cannot be opened
> because the developer cannot be verified"* — but only if you also have Homebrew
> `erofs-utils` installed (sbx invokes `mkfs.erofs` from `$PATH` and picks up the
> unnotarized Homebrew copy instead of its own notarized bundled one). Fix:
> `brew uninstall erofs-utils` (so sbx uses its bundled binary), or approve the
> Homebrew binary via **System Settings → Privacy & Security → "Allow Anyway"**
> and re-run. `xattr -d com.apple.quarantine` does **not** work. Details:
> [KNOWN_FAILURE_MODES.md](../KNOWN_FAILURE_MODES.md#26-macos-gatekeeper-blocks-mkfserofs-at-sbx-policy-init-path-shadowing).

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
# sbx prompts for the key
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY
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

> **Prefer a per-sandbox scoped token.** A global GitHub token (below) is
> injected into *every* sandbox, giving each one access to *all* your
> repositories. For least privilege, let `acq` scope a **fine-grained** token to
> just the repos in your workspace — on `acq run` it detects the mounted repos
> and guides you, or run it explicitly:
>
> ```bash
> acq github-scope <sandbox-name> /path/to/your/project
> ```
>
> See [ADR-0013](../adr/0013-per-sandbox-github-token-downscoping.md) for the
> rationale and the alternatives considered. Fine-grained tokens can't
> contribute to public repos you're not a member of or call the Checks API —
> use the global token below for those cases.

**Deprecated (broad, global) path** — kept for back-compat:

```bash
# Recommended: pipe from gh cli (never touches shell history)
brew install gh # (if not already installed)
gh auth login # (if not already authenticated to Github cli)
gh auth token | sbx secret set -g github --force

# Or enter manually
sbx secret set -g github
# When prompted, paste output of: gh auth token
```

### Store GitLab Token (for self-hosted GitLab)

GitLab is **not a built-in sbx service**, so use `sbx secret set-custom`:

```bash
# For self-hosted GitLab (e.g., workshop.cloud.gov). sbx prompts for the token.
sbx secret set-custom -g --host workshop.cloud.gov --env GITLAB_TOKEN

# Verify access inside sandbox
acq exec SANDBOX_NAME -- sh -c 'curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://workshop.cloud.gov/api/v4/user | jq .username'
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
| USAi (`api.gsa.usai.gov`) | `sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY` |
| GitLab (self-hosted) | `sbx secret set-custom -g --host gitlab.example.com --env GITLAB_TOKEN` |

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
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY
acq rm my-sandbox && acq create --name my-sandbox opencode .
```

---

## Step 4: Create Your First Sandbox

```bash
# Navigate to your project
cd /path/to/your/project

# Create and run sandbox with OpenCode
acq run opencode .
```

The sandbox will start and you'll be inside the agent environment.

### Other Supported Agents

```bash
acq run claude .        # Claude Code
acq run codex .         # OpenAI Codex
acq run copilot .       # GitHub Copilot
acq run cursor .        # Cursor
acq run docker-agent .  # Docker agent
acq run droid .         # Droid
acq run gemini .        # Google Gemini
acq run kiro .          # Kiro
acq run shell .         # Just a shell (no agent)
```

This list is sourced from `acq.backends/agents.sh`; `prime-agent` is not added by
this change.

### Create with Custom Name

```bash
# Create with a specific name
acq create --name my-feature opencode .

# Then run it (re-attach by name)
acq run my-feature
```

---

## Step 5: Managing Sandboxes

```bash
# List all sandboxes
acq ls

# Stop a sandbox (preserves state)
acq stop my-sandbox

# Resume a stopped sandbox (re-attach by name)
acq run my-sandbox

# Remove a sandbox permanently
acq rm my-sandbox

# Shell into a running sandbox (interactive attach)
acq run my-sandbox

# Remove all sandboxes — no acq equivalent; this is an sbx-specific bulk op
sbx rm --all
```

> [!NOTE]
> `acq` covers the common run/ls/stop/rm/shell/exec operations on either
> backend. One form shown here stays raw `sbx`: **`sbx rm --all`** (no
> `acq rm --all` bulk removal exists). An interactive human shell is
> `acq shell <name>`; `acq run <name>` re-attaches the agent.

---

## Common Commands Reference

| Task | acq command | Raw sbx equivalent |
|------|-------------|--------------------|
| List sandboxes | `acq ls` | `sbx ls` |
| Create sandbox | `acq run <agent> .` | `sbx run <agent> .` |
| Stop sandbox | `acq stop <name>` | `sbx stop <name>` |
| Resume sandbox | `acq run <name>` | `sbx run --name <name>` |
| Remove sandbox | `acq rm <name>` | `sbx rm <name>` |
| Run a command | `acq exec <name> -- <cmd>` | `sbx exec <name> -- <cmd>` |
| Interactive shell | `acq shell <name>` | `sbx exec -it <name> bash` |
| Copy files | `acq cp ./file.txt <name>:/path/` | `sbx cp ./file.txt <name>:/path/` |

The following are genuinely sbx-specific mechanics the wrapper does not
abstract — use the raw `sbx` command:

| Task | Command |
|------|---------|
| Check version | `sbx version` |
| Remove all sandboxes | `sbx rm --all` |
| **Secrets** | |
| List secrets | `sbx secret ls` |
| Add secret | `sbx secret set -g <service>` |
| Remove secret | `sbx secret rm -g <service>` |
| **Policies** | |
| List policies | `sbx policy ls` |
| Set default | `sbx policy init balanced` |
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
4. See [Known Failure Modes](../KNOWN_FAILURE_MODES.md) for more

---

## Advanced: CI/CD Setup

For non-interactive environments (GitHub Actions, GitLab CI):

```bash
# Set policy non-interactively
sbx policy init balanced

# Store secrets from environment variables (pipe to avoid prompts)
echo "$ANTHROPIC_API_KEY" | sbx secret set -g anthropic
echo "$GITHUB_TOKEN" | sbx secret set -g github --force

# Login with PAT (personal access token)
echo "$DOCKER_PAT" | sbx login --password-stdin --username "$DOCKER_USER"
```

### Example GitHub Actions Workflow

```yaml
- name: Setup sbx
  run: |
    sbx policy init balanced
    sbx policy allow network -g "api.gsa.usai.gov"
    echo "${{ secrets.ANTHROPIC_API_KEY }}" | sbx secret set -g anthropic

- name: Run agent
  run: sbx run opencode . -- --task "run tests"
```

---

## Multiple Workspaces

Mounting extra directories alongside the primary workspace is a **backend-neutral**
feature: the `acq run <agent> <primary> [extra][:ro] ...` syntax works
identically on sbx and msb. The canonical description — syntax, semantics,
constraints, and security guidance — lives in
[Multiple Workspaces](../CONCEPTS.md#multiple-workspaces).

The only sbx-specific angle is how multi-workspace mounts interact with the
`--clone` remote-clone lifecycle, covered below under
[Clone Mode + Multiple Workspaces](#clone-mode--multiple-workspaces).

---

## Working with Git Branches

For branch isolation, use the `--clone` flag which creates an in-container clone of your repository:

```bash
# Create sandbox with an in-container clone (changes accessible via git remote)
sbx create --clone --name feature-work opencode .

# The sandbox works on a private clone; commits are accessible via:
# git fetch sandbox-feature-work
```

> [!NOTE]
> `--clone` replaced the earlier `--branch` flag in sbx v0.31.0. If your CLI does not recognize
> `--clone`, update to the latest version.
>
> Removing a clone-mode sandbox deletes the in-sandbox clone. Any commits you have not fetched
> (`git fetch sandbox-<name>`) or pushed to an upstream remote are lost.

### Understanding the Git Remote Lifecycle

When you use `--clone`, the sandbox exposes its clone as a Git remote named `sandbox-<name>` on
your host repository:

| Event | Effect |
|-------|--------|
| `sbx create --clone` | Adds `sandbox-<name>` remote to your host `.git/config` |
| `sbx stop` | Git daemon stops; `git fetch sandbox-<name>` fails until restart |
| `sbx run` (restart) | Git daemon restarts on a new port; CLI updates remote URL automatically |
| `sbx rm` | Removes sandbox, clone, daemon, and the `sandbox-<name>` remote entry |

**Safe pattern before removal:**

```bash
# Fetch any uncommitted work first
git fetch sandbox-feature-work

# Then remove
sbx rm feature-work
```

### Direct Mode Alternative

Alternatively, check out the branch on your host before creating the sandbox:

```bash
# On host: switch to feature branch
git checkout feature/login

# Create sandbox - it mounts the current branch
acq run opencode .
```

### Clone Mode + Multiple Workspaces

Clone mode and multiple workspaces work together. When using both:

```bash
sbx create --clone --name feature-work opencode ~/my-app ~/shared-libs:ro
```

- The primary workspace (`~/my-app`) is cloned inside the sandbox
- Extra workspaces (`~/shared-libs:ro`) are mounted as-is (not cloned)
- Use `git fetch sandbox-feature-work` to retrieve commits from the cloned primary

---

## Security Reminders

1. **Never print your API key**: Use `${#VAR}` to check length, not `echo $VAR`
2. **Never commit secrets**: The `opencode.jsonc` uses `${USAI_API_KEY}` variable substitution
3. **Always use SBX**: Don't run agents directly on host with credentials
4. **Review agent output**: Before sharing logs, ensure no secrets leaked
5. **Use `sbx secret set` for persistent storage**: More secure than environment variables
6. **Pipe tokens from CLI tools**: Avoids shell history exposure (e.g., `gh auth token | sbx secret set -g github --force`)

---

## Migrating from `docker sandbox`

The Docker Desktop-integrated `docker sandbox` command is deprecated. For the
`sbx` equivalents, see
[Known Failure Modes — Migrating from `docker sandbox`](../KNOWN_FAILURE_MODES.md#18-migrating-from-docker-sandbox).

---

## Next Steps

- [Known Failure Modes](../KNOWN_FAILURE_MODES.md) — Common issues and solutions
- [Coding Practices](https://github.com/GSA-TTS/agentic-coding-playbook/blob/main/docs/CODING_PRACTICES.md) — Secure coding standards (GSA agentic-coding-playbook)

---

## Getting Help

- **GitHub Issues:** [agentic-coding-quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart/issues)
- **Docker Docs:** [docs.docker.com/ai/sandboxes](https://docs.docker.com/ai/sandboxes/)
