# Quickstart Guide

## 1. Install Prerequisites

**macOS only.** This tool requires macOS for Keychain-based secret storage.

```bash
# Docker Desktop 4.50+ (sandbox mode required)
# Download from https://docker.com/products/docker-desktop

# SOPS, AGE (encryption), and jq (JSON parsing)
brew install sops age jq
```

Verify Docker sandbox support:

```bash
docker sandbox ls
```

If this errors, update Docker Desktop to 4.50+ and ensure sandbox mode is enabled.

## 2. Clone and Configure

```bash
git clone https://github.com/cloud-gov/agent-sandbox.git
cd agent-sandbox
```

Edit `.env` with your API provider settings (required fields):

```bash
vim .env
```

**Required settings:**
- `OPENAI_COMPAT_BASE_URL` — API endpoint (e.g., `https://api.example.gov/api/v1`)
- `OPENAI_COMPAT_API_KEY` — API key for your provider

**Recommended settings:**
- `GITHUB_TOKEN` — Fine-grained PAT for git operations (see [GitHub Token Setup](#github-token-setup) below)

**Optional pass-through keys** (only if your agent needs them):
- `ANTHROPIC_API_KEY` — for Claude-based agents
- `OPENAI_API_KEY` — for GPT-based agents
- `OPENROUTER_API_KEY` — for multi-provider routing

## 3. Run Quickstart

```bash
make quickstart
```

This single command automatically:
1. Generates AGE encryption key (stored in macOS Keychain)
2. Creates `.sops.yaml` with your public key
3. Validates GitHub token (if configured)
4. Discovers models from your API provider
5. Generates `opencode.json` config
6. Encrypts `.env` to `.env.enc` (deletes plaintext)

## 4. Launch Sandbox

```bash
make start REPO=~/my-project
```

OpenCode launches inside the sandbox with:
- Your project mounted read-write (the agent can modify files in REPO)
- API keys injected as environment variables via `docker sandbox exec --env-file`
- Network isolation applied (no LAN access, no cloud metadata)
- Git identity inherited from host

## 5. Verify Isolation

Inside the sandbox, confirm network policy:

```bash
# Should timeout (RFC 1918 blocked)
curl -s --max-time 3 http://10.0.0.1

# Should timeout (cloud metadata blocked)
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/

# Should succeed (internet allowed)
curl -s https://api.github.com/zen
```

## 6. Clean Up

```bash
make clean
```

Verify the sandbox was removed:

```bash
docker sandbox ls  # Should not show agent-sandbox
```

## GitHub Token Setup

To enable git operations (clone, commit, push, create PRs) inside the sandbox, you need a GitHub Personal Access Token (PAT) with the correct scopes.

### What the Token Allows

| Operation | Allowed |
|-----------|---------|
| Clone repositories | ✅ |
| Create branches | ✅ |
| Commit and push | ✅ |
| Create pull requests | ✅ |
| Monitor CI status | ✅ |
| **Merge pull requests** | ❌ (requires human review) |
| **Change repo settings** | ❌ |

### Creating the Token

```bash
make setup-github
```

This opens a pre-configured GitHub token creation page in your browser with:
- **Name:** `agent-sandbox`
- **Expiration:** 90 days
- **Scopes:** `contents:write`, `pull_requests:write`, `actions:read`

After creating the token:
1. Copy the token (starts with `github_pat_`)
2. Add it to your `.env` file:
   ```
   GITHUB_TOKEN=github_pat_xxxxxxxxxxxx
   ```
3. Run `make quickstart` to encrypt

### Adding Token After Initial Setup

If you already ran quickstart without a GitHub token:

```bash
make decrypt          # Decrypt .env for editing
vim .env              # Add GITHUB_TOKEN=github_pat_...
make encrypt          # Re-encrypt
```

## Editing Secrets Later

```bash
make decrypt    # Creates .env from .env.enc
vim .env        # Edit values
make encrypt    # Re-encrypts and removes plaintext
```

## Resuming an Interrupted Session

If you're interrupted while working and need to pick up where you left off, Docker sandboxes persist until explicitly removed.

### Check if Your Sandbox Still Exists

```bash
docker sandbox ls
```

Look for a sandbox named `agent-sandbox` (or your custom `SANDBOX_NAME`).

### Resume an Existing Sandbox

```bash
make resume
```

This reconnects to the existing sandbox. Note that secrets from your `.env.enc` are **not** re-injected — the sandbox uses whatever environment was set when it was created.

### Recommended: Clean and Restart (Fresh Secrets)

For the cleanest experience with fresh secret injection:

```bash
make clean                    # Remove existing sandbox
make start REPO=~/my-project  # Create fresh sandbox with secrets
```

### Why Fresh Sandboxes Are Recommended

| Fresh Sandbox | Resumed Sandbox |
|---------------|-----------------|
| Secrets freshly decrypted and injected | Secrets from previous session (may be stale) |
| Network policy freshly applied | Network policy persists |
| Clean environment | May have accumulated state |
| Audit log shows new session | Continues previous session |

### What Happens If You Run `make start` With Existing Sandbox

The command will detect the existing sandbox and show options:

```
Sandbox 'agent-sandbox' already exists.
Options:
  1. Resume: docker sandbox exec -it agent-sandbox opencode
  2. Clean and restart: make clean && make start REPO=/path
```

You must run `make clean` first to create a fresh sandbox.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Docker sandbox not available` | Update Docker Desktop to 4.50+ and enable sandbox mode |
| `AGE key not in Keychain` | Run `make quickstart` again |
| `sops not found` | `brew install sops` |
| `jq not found` | `brew install jq` |
| `.sops.yaml has placeholder key` | Run `make quickstart` — AGE key generation may have failed |
| Sandbox won't start | `make clean` then retry |
| Network blocks not applying | Check Docker Desktop version supports `docker sandbox network proxy` |
| Git operations fail | Run `make setup-github` and add token to `.env` |
| GitHub token invalid | Token may have expired — create a new one with `make setup-github` |
