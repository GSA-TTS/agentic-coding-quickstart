---
title: "Coding Standards — Compact Reference"
description: "LLM-optimized coding standards for inclusion in code generation context (~500 words)"
status: canonical
tier: 1
load_priority: task-context
audience: ["agents"]
keywords: ["coding", "code generation", "standards", "compact", "prompt"]
related_files: ["docs/CODING_PRACTICES.md"]
---

<!-- LOAD: task-context — Load this for code generation tasks. For full details, load docs/CODING_PRACTICES.md -->
<!-- DERIVED FROM: docs/CODING_PRACTICES.md — this is a compact distillation, not a separate source of truth -->

# Coding Standards (Compact)

Apply these rules when generating or modifying code. For full rationale and examples, see `docs/CODING_PRACTICES.md`.

## Input/Output

- Validate ALL external input server-side with schema validation (Zod, Pydantic, JSON Schema)
- Use parameterized queries for ALL database operations — never string concatenation
- Allowlist over denylist for input filtering
- Context-appropriate output encoding (HTML, URL, SQL)
- Never expose internal details (stack traces, file paths, versions) in error responses

## Secrets

- Never in source code, config files, logs, or error messages
- Use approved key management: Vault, AWS Secrets Manager, Azure Key Vault, or env vars
- Log "secret present: yes/no" — never log the value itself

## Dependencies

- Pin exact versions (no `^` or `~` ranges)
- Commit lock files (package-lock.json, poetry.lock, go.sum)
- No critical or high CVEs in dependency tree
- Verify package names match intended packages (typosquatting defense)

## Authentication & Authorization

- Authenticate every endpoint that accesses non-public data
- Server-side authorization checks — never rely on client-side
- Use framework-native session management

## Error Handling & Logging

- Explicit error handling — no empty catch blocks
- Structured logging with correlation IDs
- Never log PII, secrets, or tokens
- Document AI assistance at PR level; per-commit `Co-Authored-By` is optional

## Crypto

- FIPS-validated algorithms only (AES-256, SHA-256/384/512, RSA-2048+, ECDSA P-256+)
- No custom crypto implementations
- TLS 1.2+ for all network communication

## Architecture

- Functions ≤ 50 lines, files ≤ 400 lines, cyclomatic complexity ≤ 10, parameters ≤ 5
- Single responsibility — if you need "and" to describe what a function does, split it
- Document decisions as ADRs when choosing between alternatives
- Interfaces before implementations — design by contract

## Testing

- Write tests alongside code (TDD preferred: red → green → refactor)
- Cover happy path + edge cases + error cases
- Regression test for every bug fix
- No test dependencies on execution order

## Security Checks Before Commit

- [ ] No secrets in diff (API keys, tokens, passwords)
- [ ] Input validation on all new endpoints/functions
- [ ] No `eval()`, `exec()`, or `innerHTML` with external data
- [ ] Dependencies pinned with no known CVEs
- [ ] Error messages don't leak internal details
