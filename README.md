# Agentic Coding Quickstart

> **Audience:** GSA teams using AI coding agents
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi

This quickstart gets you from zero to running an AI coding agent with USAi in under 5 minutes using Docker Sandboxes.

## Agentic Coding Ecosystem

This repository is part of a three-repo ecosystem:

| Repo | Purpose | When to Use |
|------|---------|-------------|
| **[Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart)** (you are here) | Get running | First day setup, sbx + USAi config |
| **[Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)** | Do it right | Repo setup, standards, best practices |
| **[Patterns](https://github.com/GSA-TTS/agentic-coding-patterns)** | Share & learn | Community patterns, lessons learned |

**Your journey:** Start here (Quickstart) to get your environment working, then use the Playbook to set up your projects properly, and visit Patterns to share what you learn.

---

## 5-Minute Quickstart

### Step 0: Prerequisites

Before you start, make sure you have:

| Requirement | Notes |
|-------------|-------|
| Package manager | Homebrew on macOS, `winget` on Windows, or `apt` on Ubuntu |
| Docker account | Required for `sbx login` |
| USAi API key | Export as `USAI_API_KEY` before configuring secrets |
| GitHub CLI auth | Optional, but recommended for repository access |

```bash
export USAI_API_KEY="your-usai-api-key"
```

> [!NOTE]
> Use the USAi console copy button when available. The key-management UI may display only a
> truncated portion of the key, which can look like the full value if you manually select it.

### Step 1: Install sbx CLI

The `sbx` CLI is a standalone tool — Docker Desktop is **not required**.

<details>
<summary>macOS</summary>

```bash
brew install docker/tap/sbx
sbx login
```

> [!NOTE]
> macOS may prompt you to approve helper binaries the first time you use `sbx`. Allow these if
> prompted:
> - `mkfs.erofs`
> - `mkfs.ext4`
> - `containerd-shim-nerdbox-v1`

</details>

<details>
<summary>Windows</summary>

```bash
winget install -h Docker.sbx
sbx login
```

</details>

<details>
<summary>Linux (Ubuntu)</summary>

```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm $USER && newgrp kvm
sbx login
```

</details>

> [!NOTE]
> `sbx login` requires a Docker account. Docker Desktop is not required, but if you have it,
> your Docker subscription covers sbx licensing.

### Step 2: Configure and Run

```bash
# 1. Set network policy (first-time only)
sbx policy set-default balanced

# 2. Allow USAi endpoint
sbx policy allow network -g "api.gsa.usai.gov"

# 3. Store your USAi API key securely (USAi is a custom endpoint, not built-in)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"

# 4. Store GitHub token (for code access)
gh auth token | sbx secret set -g github

# 5. Start a sandbox in your project
cd /path/to/your/project
sbx run opencode .
```

> [!NOTE]
> `sbx policy set-default balanced` may need to be retried if the policy service has not settled
> yet after login or first-time setup.
>
> USAi is not a built-in sbx service, so we use `sbx secret set-custom` instead of
> `sbx secret set -g`. If you change the secret, you must **delete and recreate** the sandbox for
> it to take effect.

That's it. You're now running an AI coding agent in an isolated container with USAi access.

**Need more details?** See the [Full sbx CLI Guide](docs/QUICKSTART_SBX.md).

**Working across multiple repos?** See [Multiple Workspaces](docs/QUICKSTART_SBX.md#multiple-workspaces) for mounting extra directories.

---

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. Running them in sandboxes provides:

- **Isolation** — Agent can't access your full system
- **Secret protection** — API keys injected via proxy, never touch disk
- **Reproducibility** — Same environment every time
- **Audit trail** — Clear boundaries for what the agent can do

---

## What's in This Repo

| File/Directory | Purpose |
|----------------|---------|
| `opencode.jsonc` | Pre-configured for USAi endpoints |
| `.zed/tasks.json` | Pre-configured tasks for **Zed Editor** |
| `.pre-commit-config.yaml` | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md` | Behavioral rules the agent follows |
| `docs/QUICKSTART_SBX.md` | Full sbx CLI setup guide |
| `docs/QUICKSTART_DOCKER_DESKTOP.md` | ~~Docker Desktop setup guide~~ (deprecated) |
| `docs/ZED_SETUP.md` | **Zed Editor** integration guide |
| `docs/KNOWN_FAILURE_MODES.md` | Troubleshooting guide |
| `templates/` | Files to copy into your own projects |

---

## Zed Editor Integration (Optional)

If you use the **Zed Editor**, pre-configured tasks are available in `.zed/tasks.json`:

- **OpenCode: Run Agent** — Launch the agent in your sandbox
- **OpenCode: Environment Diagnostics** — Run `make doctor`

See the **[Zed Editor Setup Guide](docs/ZED_SETUP.md)** for detailed instructions.

---

## OpenCode Web (Optional)

An alternative to running OpenCode in the terminal is to run OpenCode Web in the sandbox and access it from your host browser. This has a few benefits:

- Full support for copying text from the agent output to your host clipboard
- Richer visual interface with improved markdown rendering
- Easier navigation through long outputs and conversation history

To run OpenCode Web in a sandbox:

```bash
# In one terminal, start OpenCode Web
sbx run [your sandbox name] -- web --hostname 0.0.0.0 --port 4096

# In another terminal, publish the port to your host
sbx ports [your sandbox name] --publish 4096:4096
```

Then open `http://127.0.0.1:4096` in your browser.

A convenience script is available to automate this: [`opencode-web.sh`](opencode-web.sh)

For more information, see the [OpenCode Web documentation](https://opencode.ai/docs/web).

---

## Security Model

1. **All execution inside sbx containers** — Isolated from your host system
2. **Authorized endpoints only** — USAi, GitHub (via proxy)
3. **Secret proxy** — Agent never sees raw API keys when using `sbx secret`
4. **Agent follows AGENTS.md rules** — Explicit permissions and prohibitions

For Git provider credentials and advanced patterns, see [docs/QUICKSTART_SBX.md](docs/QUICKSTART_SBX.md).

---

## Troubleshooting

### Network policy blocks USAi

```bash
sbx policy allow network -g "api.gsa.usai.gov"
```

> Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent.

### "docker: unknown command: docker sbx" or "docker sandbox deprecated"

The `docker sandbox` command is deprecated. Install and use the standalone `sbx` CLI instead:

```bash
# macOS
brew install docker/tap/sbx

# Windows
winget install Docker.sbx
```

Then use `sbx` commands directly (e.g., `sbx run opencode .` instead of `docker sandbox run opencode .`).

### OpenCode shows wrong providers

Ensure you're in a directory with `opencode.jsonc`. For sbx, the workspace is auto-mounted.

### Authentication failed

```bash
# Check your secret is stored
sbx secret ls

# Re-set if needed
sbx secret set -g anthropic
```

If USAi authentication fails right after copying a newly created key, regenerate the key and use
the console copy button immediately instead of selecting the displayed text. The displayed value may
be truncated.

### Rotating USAi API keys

USAi API keys expire every 7 days. A stale API key is a common cause of authentication failures like:

```
Unauthorized: {"detail":"Not authenticated"}
```

To check if your key has expired:

1. Go to https://console.gsa.usai.gov/key-management
2. Under "My Keys", check the "Expires In" field. If the value is 0h0m, then the key has expired.

To rotate your key:

1. On the same page, choose "Rotate" from the "Actions" menu
2. Copy the new key using the console copy button
3. Update the secret in sbx:

```bash
# Get the current placeholder name
placeholder=$(sbx secret ls -g | grep USAI_API_KEY | awk '{print $4}')

# Rotate the secret with your new key
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --placeholder $placeholder
```

The `sbx secret` command will prompt you for the new key.

If the placeholder value hasn't changed, you should be able to
continue working. If you're still having authentication issues, you
may need to run `sbx rm <sandbox>` for each of your sandboxes.

### How default USAI models are chosen

The quickstart `templates/opencode.jsonc` includes a generated USAI model catalog.
This repository keeps that section in sync with the USAI `/models` API so new
projects start from a current baseline.

Default model policy:

- `model` tracks the highest available Opus generation
- `agent.compaction.model` tracks the highest available GPT generation
- `small_model` stays a curated fast/cheap fallback

The generated catalog improves discoverability, but it is still possible for a
model listed by `/models` to fail at runtime for a specific key or request. See
[docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md) for troubleshooting.

To refresh the model catalog locally:

```bash
export USAI_API_KEY="your-key-here"
make sync-models
```

For more troubleshooting, see [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md).

---

## Bootstrap Your Own Project

Want to use sbx + USAi in your own repository? Use the `init-project.sh` script to automatically provision any directory (new or existing) with all necessary configuration files.

### Quick Start

```bash
# Provision a new or existing project directory
./init-project.sh /path/to/your/project
```

### What Gets Provisioned

The script copies these files to your target directory:

| File | Purpose |
|------|---------|
| `AGENTS.md` | Behavioral rules for AI agents |
| `opencode.jsonc` | Pre-configured USAi endpoints |
| `Makefile` | Helper commands (`make setup`, `make doctor`, etc.) |
| `.zed/tasks.json` | Zed Editor task integration |
| `README.md` | Generated project README (only if it doesn't exist) |

The script also:
- Initializes a git repository (if not already initialized)
- Preserves existing files (won't overwrite your README.md)
- Works with both empty and populated directories

### Example

```bash
# From the quickstart directory
cd /path/to/agentic-coding-quickstart

# Provision your project
./init-project.sh /path/to/my-existing-app

# Result:
# [OK] AGENTS.md
# [OK] opencode.jsonc
# [OK] Makefile
# [OK] .zed/tasks.json
# [OK] Git repository initialized (if needed)
```

### Next Steps After Provisioning

```bash
cd /path/to/your/project
make setup    # Clone playbook and check dependencies
make doctor   # Verify your environment
```

**Alternative (Manual):** If you prefer manual setup, see [templates/BOOTSTRAP.md](templates/BOOTSTRAP.md) for detailed instructions.

---

## What's Next?

1. **Set up your project properly** — Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
2. **Share what you learn** — Contribute to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** — Found something unclear? Open an issue or submit a PR

### Available Skills and Resources

The Playbook and Patterns repos include reusable **agent skills** that provide step-by-step procedures for common tasks. Skills follow the [agentskills.io](https://agentskills.io) standard and are auto-discovered by OpenCode, Codex, and other tools.

| Repo | Skills | Examples |
|------|--------|----------|
| **Playbook** | Federal compliance, security | `federal-security-controls-lookup`, `ato-package`, `code-review`, `cloudgov-deploy` |
| **Patterns** | Development workflows | `accessibility-review`, `uswds-prototype`, `test-generation`, `secure-code-review` |

**Skills location:** `.agents/skills/<skill-name>/SKILL.md`

To use skills in your project, clone the playbook alongside your workspace:

```bash
# Recommended workspace structure
my-workspace/
├── my-app/                       # Your project
├── agentic-coding-playbook/      # Skills and standards
└── agentic-coding-patterns/      # Community patterns
```

Agents can then reference skills from the playbook when working on your project.

---

## Getting Help

1. **Troubleshooting:** [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)
2. **Agent behavior:** [AGENTS.md](AGENTS.md)
3. **Questions:** [agentic-coding Slack channel](https://gsa.enterprise.slack.com/archives/C0B44531QLE)
4. **Platform issues:** support@usai.gov

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

**Data Classification:** Internal/Non-sensitive
# CI trigger
