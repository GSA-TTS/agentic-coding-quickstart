# agent-sandbox

[![CI](https://github.com/GSA-TTS/agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/GSA-TTS/agent-sandbox/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/GSA-TTS/agent-sandbox?display_name=tag&logo=github)](https://github.com/GSA-TTS/agent-sandbox/releases)
[![License](https://img.shields.io/github/license/GSA-TTS/agent-sandbox)](LICENSE)

A small Python CLI that makes Docker Sandboxes usable with custom OpenAI-style APIs and OpenCode.

The workflow is intentionally boring:

```bash
cp .env.example .env
$EDITOR .env
make init
make doctor
make probe
make run
````

That is the default path. No forced encryption ceremony on day one. If you want stronger local secret handling later, `sops-age` is built in.

---

## Goals

* dead simple developer setup
* project-local config
* centralized structured logging
* explicit provider probing before launch
* named network policy profiles
* safe defaults
* low maintenance

---

## What this ships

* `agent-sandbox init` → creates `.agent-sandbox/config.toml`
* `agent-sandbox doctor` → validates local prerequisites
* `agent-sandbox provider probe` → validates OpenAI-compatible endpoint
* `agent-sandbox config render` → writes `opencode.json`
* `agent-sandbox run` → creates sandbox, applies policy, launches OpenCode
* `agent-sandbox logs` → shows JSONL audit log
* `agent-sandbox netlogs` → shows Docker network logs
* `agent-sandbox encrypt` / `decrypt` → optional `sops-age`

---

## Defaults

* secret backend: `env`
* sandbox template: `docker/sandbox-templates:opencode`
* policy profile: `balanced`
* project config path: `./opencode.json`
* audit log path: `.agent-sandbox/logs/agent-sandbox.log`

---

## Requirements

* Python 3.11+
* Docker (with Docker Sandboxes support)
* OpenCode

Optional:

* `sops` + `age` (for encrypted secrets)

---

## Quick start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"

cp .env.example .env
$EDITOR .env

make init
make doctor
make probe
make run
```

---

## Environment

Minimum required:

* `OPENAI_COMPAT_BASE_URL`
* `OPENAI_COMPAT_API_KEY`

Recommended:

* `OPENAI_COMPAT_PROVIDER_ID`
* `OPENAI_COMPAT_PROVIDER_NAME`
* `OPENAI_COMPAT_MODEL`
* `AGENT_SANDBOX_SECRET_BACKEND`
* `AGENT_SANDBOX_POLICY_PROFILE`
* `AGENT_SANDBOX_TEMPLATE`

Start with `.env.example`. Change only what you need.

---

## Common commands

```bash
make help
make init
make doctor
make probe
make config
make run
make dry-run
make logs
make netlogs
make stop
make remove
make lint
make test
```

---

## Example workflows

### Fast path

```bash
cp .env.example .env
$EDITOR .env
make init
make run
```

### Safer first run

```bash
cp .env.example .env
$EDITOR .env
make init
make doctor
make probe
make dry-run
make run
```

### Optional stronger local secret handling

```bash
cp .env.example .env
$EDITOR .env
make encrypt
make init
make doctor
make probe
make run
```

---

## Repository-local state

Runtime state is stored in:

```
.agent-sandbox/
```

Includes:

* config
* provider lock metadata
* audit logs

Generated config:

```
./opencode.json
```

These are local artifacts and should not be committed.

---

## Releases

This project uses:

* `CHANGELOG.md` → source of truth
* `VERSION` → release version
* `pyproject.toml` → package version
* Git tags (`vX.Y.Z`) → trigger releases

### Release process

1. Update:

```bash
CHANGELOG.md
VERSION
pyproject.toml
```

1. Commit:

```bash
git add .
git commit -m "chore(release): prepare vX.Y.Z"
```

1. Tag:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

1. GitHub Actions will:

* validate versions match
* extract release notes from `CHANGELOG.md`
* create the GitHub Release

---

## Design choices

This version intentionally removes shell orchestration.

Previous approach:

* shell scripts (`sandbox.sh`, `config.sh`)
* shell-based config generation
* mixed config sources

Current approach:

* Python-first CLI
* deterministic config generation
* explicit provider validation
* centralized logging
* isolated subprocess execution
* project-local state only

---

## Development

Install dev dependencies:

```bash
pip install -e ".[dev]"
```

Run checks:

```bash
ruff check src tests
ruff format --check src tests
pytest
bandit -q -r src -c pyproject.toml
```

Or:

```bash
make lint
make test
```

---

## Notes for AI agents

Agents MUST read:

* `AGENTS.md`
* `docs/CODING_PRACTICES.md`

Rules:

* keep changes small
* keep behavior deterministic
* add tests for all changes
* do not introduce unnecessary abstraction
* do not bypass security rules

---

## License

See [LICENSE](LICENSE)
