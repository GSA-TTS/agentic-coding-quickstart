# Architecture

- `src/agent_sandbox/cli.py` — Typer CLI
- `src/agent_sandbox/config.py` — central config and env loading
- `src/agent_sandbox/logging_utils.py` — JSONL audit logger
- `src/agent_sandbox/providers.py` — OpenAI-compatible probing
- `src/agent_sandbox/opencode_config.py` — deterministic `opencode.json` rendering
- `src/agent_sandbox/docker_sandbox.py` — Docker command planner and executor
- `src/agent_sandbox/secrets.py` — `env` and optional `sops-age` helpers
