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

## 2. Clone and Setup

```bash
git clone https://github.com/cloud-gov/agent-sandbox.git
cd agent-sandbox
make setup
```

This will:
- Verify Docker Desktop, sops, age, and jq are installed
- Generate an AGE keypair (private key stored in macOS Keychain)
- Create `.sops.yaml` with your public key
- Copy `.env.example` to `.env`

## 3. Configure Secrets

Edit `.env` with your API keys:

```bash
vim .env
```

At minimum, set:
- `ANTHROPIC_API_KEY` — primary key for Anthropic-based agents (Claude/OpenCode)

Optional pass-through keys (only if your agent needs them):
- `OPENAI_API_KEY` — for agents that call the OpenAI API directly
- `OPENROUTER_API_KEY` — for agents that use OpenRouter for multi-provider routing

Then encrypt:

```bash
make encrypt
```

This encrypts `.env` into `.env.enc` and deletes the plaintext file.

## 4. Launch Sandbox

```bash
make run REPO=~/my-project
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

## Editing Secrets Later

```bash
make decrypt    # Creates .env from .env.enc
vim .env        # Edit values
make encrypt    # Re-encrypts and removes plaintext
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Docker sandbox not available` | Update Docker Desktop to 4.50+ and enable sandbox mode |
| `AGE key not in Keychain` | Run `make setup` again |
| `sops not found` | `brew install sops` |
| `jq not found` | `brew install jq` |
| `.sops.yaml has placeholder key` | Run `make setup` — AGE key generation may have failed |
| Sandbox won't start | `make clean` then retry |
| Network blocks not applying | Check Docker Desktop version supports `docker sandbox network proxy` |
