# agent-sandbox

A small Python CLI that makes Docker Sandboxes usable with custom OpenAI-style APIs and OpenCode.

The workflow is intentionally boring:

```bash
cp .env.example .env
$EDITOR .env
make init
make run REPO=.
```

That is the default path. No forced encryption ceremony on day one. If you want stronger local secret handling later, `sops-age` is built in.

## Goals

- dead simple developer setup
- project-local config
- centralized structured logging
- explicit provider probing before launch
- named network policy profiles
- safe defaults
- low maintenance

## Current alignment

This project is aligned to Docker Sandboxes as an experimental microVM-based feature with reusable templates and network policy tooling, and to OpenCode's project-local config and custom provider support. citeturn383177search0turn383177search1turn383177search3

## What this ships

- `agent-sandbox init` creates `.agent-sandbox/config.toml`
- `agent-sandbox doctor` checks local prerequisites
- `agent-sandbox provider probe` validates an OpenAI-compatible endpoint
- `agent-sandbox config render` writes `opencode.json` into the repo
- `agent-sandbox run` creates a Docker sandbox, applies policy, and launches OpenCode
- `agent-sandbox logs` shows the local JSONL audit log
- `agent-sandbox netlogs` tails Docker network logs
- `agent-sandbox encrypt` / `decrypt` support optional `sops-age`

## Defaults

- secret backend: `env`
- sandbox template: `docker/sandbox-templates:opencode`
- policy profile: `balanced`
- project config path: `./opencode.json`
- audit log path: `.agent-sandbox/logs/agent-sandbox.log`

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
make run REPO=.
```

## Opinionated choices

This refactor intentionally drops most shell orchestration. The old repo centered everything around `sandbox.sh`, `config.sh`, Make targets, and shell-based model/config generation. This version keeps the same core concerns but moves them into typed Python modules with centralized config and logging. fileciteturn7file2 fileciteturn7file3
