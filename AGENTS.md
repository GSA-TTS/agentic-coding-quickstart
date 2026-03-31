# AGENTS.md — Instructions for AI Coding Agents

This file tells AI coding agents how to work in this repository.

It is intentionally short, strict, and practical.

## Mandatory Reading

Before making any change, agents MUST read:

1. `AGENTS.md`
2. `docs/CODING_PRACTICES.md`

If these files conflict, follow the more restrictive rule.

## Project Summary

`agent-sandbox` is a small Python CLI that makes Docker Sandboxes usable with custom OpenAI-style APIs and OpenCode.

Current architecture:

- Python-first CLI
- project-local config in `.agent-sandbox/`
- project-local `opencode.json`
- explicit provider probing before launch
- structured audit logging
- named network policy profiles
- optional `sops-age` support for stronger local secret handling

## Default Workflow

The normal path should stay simple:

```bash
cp .env.example .env
$EDITOR .env
make init
make doctor
make probe
make run
```

This is the preferred workflow for both humans and agents.

Do not add extra setup steps unless there is a clear security or correctness reason.

## Commands

Use the Makefile first unless you have a specific reason not to.

```bash
make help
make init
make doctor
make probe
make config
make run
make dry-run
make stop
make remove
make logs
make netlogs
make encrypt
make decrypt
make lint
make format
make test
make clean
make distclean
```

Direct CLI usage:

```bash
python -m agent_sandbox --help
python -m agent_sandbox init .
python -m agent_sandbox doctor .
python -m agent_sandbox provider probe .
python -m agent_sandbox config render .
python -m agent_sandbox run .
```

## Repository Layout

```text
src/agent_sandbox/
  cli.py                # CLI only
  config.py             # config, env, repo-local state
  constants.py          # stable constants
  docker_sandbox.py     # sandbox planning + execution
  doctor.py             # prerequisite checks
  errors.py             # typed exceptions
  logging_utils.py      # structured logging + audit events
  models.py             # dataclasses / typed models
  opencode_config.py    # opencode.json rendering
  providers.py          # provider probing / model discovery
  secrets.py            # env and sops-age secret handling
  subprocess_runner.py  # subprocess boundary

tests/
  test_cli.py
  test_config.py
  test_docker_sandbox.py
  test_doctor.py
  test_logging_utils.py
  test_main.py
  test_opencode_config.py
  test_provider_probe.py
  test_secrets.py
  test_subprocess_runner.py
```

## Rules for Agents

### 1. Keep the workflow simple

Prefer boring, obvious UX.

Good:
- one clear command per task
- strong defaults
- project-local state
- readable output
- clear failures

Bad:
- extra bootstrap layers
- hidden magic
- optional complexity made mandatory
- feature flags for hypothetical futures

### 2. Respect module boundaries

- `cli.py` handles CLI wiring, messaging, and exit behavior
- `config.py` handles config and environment loading
- `providers.py` owns provider probing and response parsing
- `docker_sandbox.py` owns sandbox planning and execution
- `subprocess_runner.py` owns subprocess calls
- `logging_utils.py` owns audit logging
- `secrets.py` owns secret backend behavior
- `models.py` should stay side-effect free

Do not smear logic across modules.

### 3. Isolate side effects

- no subprocess calls outside `subprocess_runner.py`
- no direct network probing outside `providers.py`
- no secret backend logic outside `secrets.py`
- no logging shape drift outside `logging_utils.py`

### 4. Use typed errors

Raise project-specific exceptions where appropriate.

Do not swallow failures.
Do not use bare `except`.
Do not silently fall back to surprising behavior.

### 5. Preserve deterministic behavior

Changes MUST be deterministic and testable.

Avoid:
- hidden global state
- time-dependent behavior in core logic
- random values in business logic
- implicit environment reads outside config/secrets boundaries

### 6. Minimize dependencies

Before adding any dependency, ask:

- does the standard library already solve this?
- does this simplify the repo materially?
- will this make future maintenance easier?

If not, do not add it.

### 7. Do not reintroduce shell-era architecture

This repo used to be shell-first.

Do not reintroduce:
- large shell orchestration
- duplicated config sources
- ad hoc file parsing in shell
- new runtime-critical `.sh` logic unless there is no reasonable Python alternative

Small helper shell scripts are acceptable only when clearly justified.

## Testing Rules

Every functional change MUST include tests.

Minimum expectations:

- `ruff check src tests`
- `ruff format --check src tests`
- `pytest`
- `bandit -q -r src -c pyproject.toml`

Test behavior, not implementation details.

Mock:
- subprocess calls
- provider HTTP interactions
- filesystem state when practical

Do not require real Docker or real network access in normal tests.

## Security Rules

- never commit secrets
- never log secrets
- never hardcode credentials
- never use `shell=True`
- always pass subprocess args as lists
- validate all external input
- treat provider responses as untrusted input
- keep project-local runtime state in `.agent-sandbox/`

Supported secret backends:

- `env`
- `sops-age`

Keep `env` as the easy default.
Keep `sops-age` as the stronger optional path.

## Docs and UX Expectations

If you change user behavior, update:

- `README.md`
- `AGENTS.md`
- `docs/CODING_PRACTICES.md`
- `.env.example` if required env/config changed

Error messages should help a developer recover fast.
Help text should be direct and specific.
Defaults should be visible and unsurprising.

## Definition of Done

A change is not done unless:

- tests pass
- lint passes
- security scan passes
- docs stay accurate
- behavior remains simple and deterministic
- no secret handling regressions are introduced

## Final Instruction

Prefer the simplest correct implementation that is easy to test, easy to explain, and easy to maintain.
