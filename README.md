# Agentic Coding Quickstart

> **Audience:** Government developers in the USAi pilot program  
> **Purpose:** Get AI coding agents running safely on your local machine in under 5 minutes

This guide helps you use AI coding agents (like OpenCode) inside isolated Docker sandboxes, connecting to government-approved API endpoints (USAi).

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. Running them in sandboxes provides:

- **Isolation:** Agent can't access your full system
- **Secret protection:** API keys never touch disk or logs
- **Reproducibility:** Same environment every time
- **Audit trail:** Clear boundaries for what the agent can do

## Prerequisites

- **SBX CLI** installed (`sbx --version` to verify)
- **USAi API key** from your agency's pilot program
- **Docker** running locally

## Quick Start (3 Commands)

```bash
# 1. Set your API key (on your host machine)
export USAI_API_KEY="your-api-key-here"

# 2. Clone this repo and create a sandbox
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
sbx create --name quickstart opencode .

# 3. Run OpenCode with USAi
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) quickstart opencode
```

That's it. You're now running an AI coding agent in an isolated container with USAi access.

## What's in This Repo

| File | Purpose |
|------|---------|
| `opencode.jsonc` | Pre-configured for USAi endpoints |
| `AGENTS.md` | Behavioral rules the agent follows |
| `docs/SBX_QUICKSTART.md` | Detailed setup walkthrough |
| `docs/KNOWN_FAILURE_MODES.md` | Troubleshooting guide |
| `docs/CODING_PRACTICES.md` | Secure coding standards |
| `templates/` | Files to copy into your own projects |

## Bootstrap Your Own Project

Want to use SBX + USAi in your own repository? Copy the template files:

```bash
# Set your target repo path
TARGET_REPO="/path/to/your/project"

# Copy the OpenCode config
cp templates/opencode.jsonc "$TARGET_REPO/"

# Copy the SBX patterns reference
mkdir -p "$TARGET_REPO/docs"
cp templates/SBX_PATTERNS.md "$TARGET_REPO/docs/"

# If you have an existing AGENTS.md, append the SBX addendum (skip the header)
tail -n +6 templates/AGENTS_SBX_ADDENDUM.md >> "$TARGET_REPO/AGENTS.md"
```

See [templates/BOOTSTRAP.md](templates/BOOTSTRAP.md) for detailed instructions.

### For Playbook Users

If you've bootstrapped your project using the [Agentic Coding Playbook](https://github.com/GSA-TTS/agentic-coding-playbook), the quickstart templates complement it:

- **Playbook** → Project structure, AGENTS.md, coding practices, risk assessment
- **Quickstart** → USAi configuration, SBX patterns, credential injection

## Key Commands

```bash
# Create a sandbox
sbx create --name my-sandbox opencode .

# Run OpenCode (always use this pattern for USAi)
sbx exec -it -e USAI_API_KEY="$USAI_API_KEY" -w $(pwd) my-sandbox opencode

# List your sandboxes
sbx ls

# Stop a sandbox
sbx stop my-sandbox

# Remove a sandbox
sbx rm my-sandbox
```

## Security Model

1. **All execution happens inside SBX containers** - isolated from your host
2. **Authorized endpoints only** - USAi, GitHub (via proxy), GitLab (via direct injection)
3. **Agent follows AGENTS.md rules** - explicit permissions and prohibitions

### Git Provider Credentials

For agents that need GitHub or GitLab access:

```bash
# GitHub (recommended: use SBX proxy)
gh auth token | sbx secret set -g github

# GitLab (direct injection required)
sbx exec -it \
  -e USAI_API_KEY="$USAI_API_KEY" \
  -e GITLAB_TOKEN="$(glab config get --host workshop.cloud.gov token)" \
  -e GITLAB_HOST="workshop.cloud.gov" \
  -w $(pwd) my-sandbox opencode
```

See [docs/SBX_QUICKSTART.md](docs/SBX_QUICKSTART.md) for full credential injection patterns.

### Known Limitation: API Key Visibility

**Risk:** With the current SBX tooling, the USAi API key is injected directly into the container environment via `-e USAI_API_KEY="$USAI_API_KEY"`. This means the agent process *can* read the key from the environment.

**Why this happens:** SBX's secret proxy only supports a fixed set of services (OpenAI, Anthropic, etc.) with hardcoded endpoints. Custom endpoints like USAi (`api.gsa.usai.gov`) bypass the proxy entirely.

**Mitigations in place:**
- Key is never written to disk or config files
- `AGENTS.md` rules prohibit the agent from printing/logging secrets
- Container isolation limits exposure scope
- Key only exists in memory during execution

**Upstream tracking:** This limitation is tracked in [docker/sbx-releases#35](https://github.com/docker/sbx-releases/issues/35) - "Feature Request: Configurable Secret Injection for Custom Services"

**Future state:** When SBX supports custom service mappings, we can use true proxy-based injection where the agent never sees the raw key.

## Troubleshooting

**OpenCode shows wrong providers (OpenAI, Anthropic, etc.)**
- Make sure you're in this repo's directory
- Use `-w $(pwd)` to set the working directory
- Verify `opencode.jsonc` exists

**Authentication failed**
- Check your API key: `echo "Length: ${#USAI_API_KEY}"`
- Ensure you're using `-e USAI_API_KEY="$USAI_API_KEY"` flag

**"Unknown agent" error**
- Use: `sbx create --name NAME opencode .` (note the `opencode .` at the end)

See `docs/KNOWN_FAILURE_MODES.md` for more troubleshooting help.

## Pilot Scope

This quickstart is part of a **limited government pilot** for evaluating AI coding agents. Current constraints:

- **Authorized endpoints only** - USAi, GitHub, and approved GitLab instances
- **Local development only** - not for production use
- **Pattern validation** - documenting what works and what doesn't

## Getting Help

- Check `docs/KNOWN_FAILURE_MODES.md` first
- Review `AGENTS.md` for agent behavior rules
- Contact your pilot program coordinator

## Contributing

Found a failure mode we haven't documented? Please add it to `docs/KNOWN_FAILURE_MODES.md` with:
1. Symptoms
2. Root cause
3. Fix

---

**Impact Level:** FIPS Low | **Data Classification:** Internal/Non-sensitive | **ATO Status:** Pre-ATO (pilot)
