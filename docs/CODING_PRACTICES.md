---
title: "Coding Practices for agent-sandbox"
status: canonical
audience: "humans + AI coding agents"
load_priority: "always"
---

# Coding Practices — agent-sandbox

This document defines how code MUST be written, structured, and tested in this repository.

It is optimized for:

- AI-assisted development
- security-conscious environments
- long-term maintainability with minimal team overhead

All contributors — human or AI — MUST follow these rules.

## 0. Core Principles

These are non-negotiable:

1. Correctness > Safety > Simplicity > Performance
2. Determinism over cleverness
3. Explicit over implicit
4. Tested behavior over assumed behavior
5. Small, composable modules over large abstractions

If a change violates these, it is wrong.

## 1. LLM-Specific Rules

AI-generated code is treated as untrusted input.

### Required Behavior

- MUST be reviewed by a human before merge
- MUST include tests for all new behavior
- MUST not introduce hidden side effects
- MUST not introduce new dependencies without justification
- MUST follow all rules in this document

### Prohibited Patterns

AI-generated code MUST NOT:

- invent APIs or libraries
- guess behavior of external systems
- introduce speculative abstractions
- silently swallow errors
- bypass validation or logging

### Determinism Requirement

All logic MUST be:

- deterministic given the same inputs
- testable without external systems
- mockable at boundaries

## 2. Architecture Rules

### Module Boundaries

| Module | Responsibility |
|------|--------|
| `cli.py` | user interface only |
| `config.py` | config and env handling |
| `providers.py` | API probing and normalization |
| `docker_sandbox.py` | sandbox planning and execution |
| `subprocess_runner.py` | system calls |
| `logging_utils.py` | logging and audit |
| `secrets.py` | secret handling |
| `models.py` | data structures only |

Rules:

- no cross-layer leakage
- no business logic in CLI
- no I/O in models
- no subprocess calls outside `subprocess_runner.py`

### Side Effects

Side effects MUST be isolated:

- subprocess calls → `subprocess_runner.py`
- filesystem writes → explicit functions
- network calls → `providers.py` only

Everything else should be pure logic where practical.

## 3. Code Style

- Python 3.11+
- type hints REQUIRED
- Ruff MUST pass
- Bandit MUST pass
- max line length: 100

### Function Constraints

- ≤ 50 lines when practical
- ≤ 5 parameters when practical
- single responsibility

### Naming

- verbs for functions: `load_settings`
- nouns for data: `Settings`
- avoid abbreviations
- avoid generic names like `data`, `obj`, or `thing`

## 4. Configuration and Environment

Rules:

- all config must flow through `config.py`
- no direct `os.environ` usage outside config/secrets boundaries without clear reason
- no hardcoded values that should be configurable

Validation:

- validate environment variables
- validate CLI arguments
- validate API responses

Fail fast. Fail clearly.

## 5. Secrets Handling

Rules:

- NEVER hardcode secrets
- NEVER log secrets
- MUST use supported backends:
  - `env`
  - `sops-age`

Behavior:

- secrets accessed through `secrets.py`
- encryption/decryption must be explicit
- no implicit fallback logic

## 6. Subprocess and System Calls

Rules:

- ALL subprocess calls go through `SubprocessRunner`
- NEVER use `shell=True`
- ALWAYS pass args as lists

Bad:

```python
subprocess.run("docker sandbox create ...", shell=True)
```

Good:

```python
runner.run(["docker", "sandbox", "create", ...])
```

## 7. Logging and Audit

Requirements:

- JSON structured logs
- no secrets in logs
- must include timestamp, event name, and result

Use `audit_event(...)`, not ad hoc `print(...)` for audit behavior.

## 8. Error Handling

Rules:

- no silent failures
- no bare `except`
- use typed errors

## 9. Testing

Requirements:

- ALL new behavior must have tests
- tests must run locally with `pytest`

Test design:

- test behavior, not implementation
- mock external systems
- no network calls in tests
- no real Docker usage in normal tests

Required coverage areas:

- CLI commands
- config parsing
- provider probing
- sandbox planning
- subprocess invocation
- secrets handling

## 10. Dependencies

Rules:

- minimal dependencies
- MUST justify new dependency
- MUST pin versions
- avoid abandoned or unnecessary packages

## 11. Simplicity Rules

MUST NOT:

- add plugin systems
- add framework layers
- add config abstractions prematurely
- build for hypothetical use cases

MUST:

- solve the current problem only
- prefer direct implementation
- refactor only when needed

## 12. Change Safety

Required workflow:

1. write failing test
2. implement fix
3. ensure tests pass
4. refactor safely

Every bug fix MUST include a regression test.

## 13. Security Alignment

This project aligns generally with:

- NIST SP 800-53
- NIST SSDF (SP 800-218A)
- OWASP guidance for LLM and agentic systems

## 14. Definition of Done

A change is complete only if:

- tests pass
- lint passes
- security scan passes
- behavior is deterministic
- logs are correct
- no secrets are exposed
- documentation is updated when needed

## Final Rule

Choose the simplest correct implementation that can be tested easily.
