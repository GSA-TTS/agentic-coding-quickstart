# Agent Sandbox

[![CI](https://github.com/cloud-gov/agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/cloud-gov/agent-sandbox/actions/workflows/ci.yml)

Run AI coding agents in an isolated Docker sandbox with encrypted secrets and network controls.

**Stack:** Docker Desktop sandbox mode + OpenCode + SOPS/AGE

## Prerequisites

- **macOS only** (uses macOS Keychain for secret storage)
- Docker Desktop 4.50+ with sandbox mode enabled (Latest LTS: 4.62.0 as of Feb 2026)
- [SOPS](https://github.com/getsops/sops) v3.12.1, [AGE](https://github.com/FiloSottile/age) v1.3.1, and [jq](https://jqlang.github.io/jq/) v1.8.1: `brew install sops age jq`

## Quickstart

```bash
# 1. Install prerequisites and generate encryption key
make setup

# 2. Edit .env with your API keys and provider settings
vim .env

# 3. Discover models, generate config, and encrypt — all in one step
make quickstart

# 4. Launch sandbox with your project
make run REPO=~/my-project

# 5. Clean up when done
make clean
```

`make quickstart` validates your `.env`, discovers available models from your provider API, generates `opencode.jsonc` (with only your provider's models visible), and encrypts `.env` — all in one command. You can also run each step individually with `make models`, `make config`, and `make encrypt`.

## How It Works

1. **Setup** generates an AGE keypair. Private key stored in macOS Keychain, public key in `.sops.yaml`.
2. **Encrypt** uses SOPS+AGE to encrypt `.env` into `.env.enc`. The plaintext `.env` is deleted.
3. **Run** decrypts secrets to a temporary file (mode 600, auto-deleted on exit), creates a Docker sandbox, applies network isolation, and launches OpenCode with your project mounted.
4. **Network policy** blocks RFC 1918 ranges and cloud metadata endpoints while allowing internet access.

## Security Model

- **Secrets**: Encrypted at rest (SOPS/AGE), decrypted to temp file, injected via `--env-file`, cleaned up on exit
- **Network**: Private networks blocked (prevents lateral movement), cloud IMDS blocked (prevents credential theft)
- **Isolation**: Docker Desktop sandbox provides process isolation. Mounted workspace is writable by design.
- **Audit**: All operations logged to `~/.config/agent-sandbox/audit.log`

## Troubleshooting

If you encounter issues with AGE keys or encryption/decryption:

```bash
# Reset AGE keys and re-encrypt (fixes most key sync issues)
make reset-keys
```

This command:

1. Creates backups of your `.env`, `.env.enc`, and `.sops.yaml` files
2. Decrypts your secrets if possible with the current key
3. Generates fresh AGE keys and updates all configuration
4. Re-encrypts your environment variables with the new key

See [AGE-TROUBLESHOOTING.md](docs/AGE-TROUBLESHOOTING.md) for more details on key management, rotation, and team sharing.

See [docs/SECURITY.md](docs/SECURITY.md) for the full threat model.

## Commands

| Command | Description |
|---------|-------------|
| `make quickstart` | Validate, discover models, generate config, encrypt (all-in-one) |
| `make setup` | Install prerequisites, generate AGE key |
| `make run REPO=path` | Launch sandbox with project |
| `make validate` | Check configuration |
| `make clean` | Remove sandbox |
| `make encrypt` | Encrypt `.env` to `.env.enc` |
| `make decrypt` | Decrypt `.env.enc` for editing |
| `make models` | List available models from OpenAI-compatible API |
| `make config` | Generate `opencode.jsonc` from discovered models |
| `make version` | Print current version |
| `make release-patch` | Release patch version (x.y.Z+1) |
| `make release-minor` | Release minor version (x.Y+1.0) |
| `make release-major` | Release major version (X+1.0.0) |
| `make test` | Run all test suites (requires macOS with sops/age) |

## Model Discovery

OpenCode requires a `opencode.jsonc` config listing available models. Agent Sandbox can auto-discover models from any OpenAI-compatible API and generate this config:

```bash
# Set your provider URL and API key (or add to .env before encrypting)
export OPENAI_COMPAT_BASE_URL="https://api.gsa.usai.gov/api/v1"
export OPENAI_COMPAT_API_KEY="your-api-key"
export OPENAI_COMPAT_PROVIDER_NAME="gsa-usai"  # optional, default: custom-api

# List available models
make models

# Generate opencode.jsonc from discovered models
make config
```

The generated config includes:

- `enabled_providers` whitelist — **only your custom provider's models are shown** (hides all 75+ built-in providers)
- All discovered model IDs with human-readable names
- Context window and output token limits (when provided by the API)
- Automatic `small_model` selection (smallest context window model)
- API key referenced via `{env:OPENAI_COMPAT_API_KEY}` (not hardcoded)

Supports OpenAI, GSA USAi, vLLM, Ollama, and any `/v1/models`-compatible endpoint. Local endpoints (`localhost`, `127.0.0.1`) are exempt from HTTPS enforcement.

## Documentation

- [Quickstart Guide](docs/QUICKSTART.md)
- [SOPS/AGE Setup](docs/SOPS-SETUP.md)
- [Security Model](docs/SECURITY.md)
- [AI Agent Instructions](AGENTS.md)

## Previous Work

The enterprise version (NIST 800-53 compliance, federal hardening, multi-agent support) is preserved on the [`feature/enterprise-hardening`](https://github.com/cloud-gov/agent-sandbox/tree/feature/enterprise-hardening) branch.

## License

MIT
