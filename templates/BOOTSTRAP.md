# Bootstrap Your Project for Docker Sandboxes + USAi

Copy the template files from this quickstart into your target repository to enable AI agent execution with Docker Sandboxes and USAi.

## Prerequisites

> [!IMPORTANT]
> The Docker Desktop-integrated `docker sandbox` commands are **deprecated**.
> Use the standalone `sbx` CLI instead.

**Install sbx CLI:**
```bash
# macOS
brew install docker/tap/sbx

# Windows
winget install Docker.sbx
```

See [Docker Sandboxes documentation](https://docs.docker.com/ai/sandboxes/) for details.

## What Gets Copied

| File | Purpose | Required? |
|------|---------|-----------|
| `opencode.jsonc` | OpenCode configuration with USAi provider | Yes (for OpenCode) |
| `.zed/tasks.json` | Pre-configured Tasks for the Zed editor | Recommended (if using Zed) |
| `docs/SBX_PATTERNS.md` | Credential injection quick reference | Recommended |
| `AGENTS_SBX_ADDENDUM.md` | Sandbox rules to append to your AGENTS.md | If you have AGENTS.md |

> [!NOTE]
> **Using Codex?** No config file is needed. Codex uses `OPENAI_API_KEY` and `OPENAI_BASE_URL`
> environment variables, which are injected via `sbx secret set-custom`. See the
> [Codex Quickstart Guide](../docs/QUICKSTART_CODEX.md) for details.

## Quick Bootstrap

```bash
# Set your target repo path
TARGET_REPO="/path/to/your/project"

# Clone or ensure you have the quickstart
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git /tmp/quickstart

# Copy the OpenCode config
cp /tmp/quickstart/templates/opencode.jsonc "$TARGET_REPO/"

# Copy Zed editor tasks configuration (optional, recommended if using Zed)
mkdir -p "$TARGET_REPO/.zed"
cp /tmp/quickstart/templates/zed-tasks.json "$TARGET_REPO/.zed/tasks.json"

# Copy the SBX patterns reference
mkdir -p "$TARGET_REPO/docs"
cp /tmp/quickstart/templates/SBX_PATTERNS.md "$TARGET_REPO/docs/"

# If you have an existing AGENTS.md, append the SBX addendum (skip header instructions)
if [ -f "$TARGET_REPO/AGENTS.md" ]; then
  echo "" >> "$TARGET_REPO/AGENTS.md"
  echo "<!-- Docker Sandboxes + USAi Addendum -->" >> "$TARGET_REPO/AGENTS.md"
  tail -n +6 /tmp/quickstart/templates/AGENTS_SBX_ADDENDUM.md >> "$TARGET_REPO/AGENTS.md"
  echo "Appended sandbox rules to AGENTS.md"
else
  echo "No AGENTS.md found. Consider using the Agentic Coding Playbook to generate one:"
  echo "https://github.com/GSA-TTS/agentic-coding-playbook"
fi

# Clean up
rm -rf /tmp/quickstart
```

## After Bootstrap

### Using sbx CLI (Recommended)

1. **Store your USAi API key securely** (USAi is a custom endpoint):
   ```bash
   sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"
   ```

2. **Set up GitHub credentials** (built-in service):
   ```bash
   gh auth token | sbx secret set -g github
   ```

3. **Create a sandbox** for your project:
   ```bash
   cd "$TARGET_REPO"
   sbx create --name my-project opencode .
   ```

4. **Run the agent** (secrets auto-injected from keychain):
   ```bash
   sbx run my-project
   ```

> [!NOTE]
> After changing secrets, you must **delete and recreate** the sandbox for changes to take effect.

### Using Docker Desktop (`docker sandbox`) — DEPRECATED

> [!WARNING]
> The `docker sandbox` command is deprecated by Docker.
> Migrate to the `sbx` CLI above.

<details>
<summary>Legacy instructions (click to expand)</summary>

1. **Set your USAi API key** in your shell config (`~/.bashrc` or `~/.zshrc`):
   ```bash
   echo 'export USAI_API_KEY="your-key-here"' >> ~/.zshrc
   source ~/.zshrc
   ```

2. **Restart Docker Desktop** (required for it to read the new env var)

3. **Create a sandbox** for your project:
   ```bash
   cd "$TARGET_REPO"
   docker sandbox create --name my-project opencode .
   ```

4. **Run the agent**:
   ```bash
   docker sandbox run my-project
   ```

</details>

## For Playbook Users

If you've already bootstrapped your project using the [Agentic Coding Playbook](https://github.com/GSA-TTS/agentic-coding-playbook), you already have an `AGENTS.md`. The quickstart adds:

1. **`opencode.jsonc`** - USAi-specific configuration (the playbook doesn't include this)
2. **Sandbox addendum** - Appended to your existing `AGENTS.md` with sandbox-specific rules
3. **`docs/SBX_PATTERNS.md`** - Quick reference for credential injection

The addendum is designed to complement, not conflict with, the playbook's AGENTS.md content.

## Customization

### Change the Default Model

Edit `opencode.jsonc`:
```jsonc
"model": "usai/gpt-4o"  // or claude_4_5_opus, gemini-2.5-pro, etc.
```

### Add/Remove Models

Edit the `models` section in `opencode.jsonc` based on your USAi API key entitlements.

### Change GitLab Host

If you use a different GitLab instance, update `AGENTS_SBX_ADDENDUM.md` and `docs/SBX_PATTERNS.md` to reference your host instead of `workshop.cloud.gov`.
