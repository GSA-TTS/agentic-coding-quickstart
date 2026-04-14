# Bootstrap Your Project for SBX + USAi

Copy the template files from this quickstart into your target repository to enable AI agent execution with Docker SBX and USAi.

## What Gets Copied

| File | Purpose | Required? |
|------|---------|-----------|
| `opencode.jsonc` | OpenCode configuration with USAi provider | Yes |
| `docs/SBX_PATTERNS.md` | Credential injection quick reference | Recommended |
| `AGENTS_SBX_ADDENDUM.md` | SBX rules to append to your AGENTS.md | If you have AGENTS.md |

## Quick Bootstrap

```bash
# Set your target repo path
TARGET_REPO="/path/to/your/project"

# Clone or ensure you have the quickstart
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git /tmp/quickstart

# Copy the OpenCode config
cp /tmp/quickstart/templates/opencode.jsonc "$TARGET_REPO/"

# Copy the SBX patterns reference
mkdir -p "$TARGET_REPO/docs"
cp /tmp/quickstart/templates/SBX_PATTERNS.md "$TARGET_REPO/docs/"

# If you have an existing AGENTS.md, append the SBX addendum (skip header instructions)
if [ -f "$TARGET_REPO/AGENTS.md" ]; then
  echo "" >> "$TARGET_REPO/AGENTS.md"
  echo "<!-- SBX + USAi Addendum -->" >> "$TARGET_REPO/AGENTS.md"
  tail -n +6 /tmp/quickstart/templates/AGENTS_SBX_ADDENDUM.md >> "$TARGET_REPO/AGENTS.md"
  echo "Appended SBX rules to AGENTS.md"
else
  echo "No AGENTS.md found. Consider using the Agentic Coding Playbook to generate one:"
  echo "https://github.com/GSA-TTS/agentic-coding-playbook"
fi

# Clean up
rm -rf /tmp/quickstart
```

## After Bootstrap

1. **Set your USAi API key** on the host:
   ```bash
   export USAI_API_KEY="your-key-here"
   ```

2. **Set up GitHub credentials** (if needed):
   ```bash
   gh auth token | sbx secret set -g github
   ```

3. **Create a sandbox** for your project:
   ```bash
   cd "$TARGET_REPO"
   sbx create --name my-project opencode .
   ```

4. **Run the agent**:
   ```bash
   sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) my-project opencode
   ```

## For Playbook Users

If you've already bootstrapped your project using the [Agentic Coding Playbook](https://github.com/GSA-TTS/agentic-coding-playbook), you already have an `AGENTS.md`. The quickstart adds:

1. **`opencode.jsonc`** - USAi-specific configuration (the playbook doesn't include this)
2. **SBX addendum** - Appended to your existing `AGENTS.md` with SBX-specific rules
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
