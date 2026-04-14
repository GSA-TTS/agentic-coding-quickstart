---
title: "Use Docker SBX as Isolation Layer for USAi Agent Execution"
status: accepted
date: 2026-04-14
decision_makers: ["William Zujkowski"]
category: infrastructure
nist_controls: ["AC-6", "SC-7", "SC-39", "SI-7"]
impact_level: low
ato_relevance: yes-boundary
risk_treatment: mitigate
---

# ADR-0001: Use Docker SBX as Isolation Layer for USAi Agent Execution

## Context and Problem Statement

We need a secure way to allow developers to experiment with AI coding agents while
preventing credential leakage, maintaining compliance alignment (FedRAMP patterns),
supporting OpenAI-compatible APIs (USAi endpoints), and avoiding direct exposure
of secrets to agent runtimes.

Traditional local development setups expose API keys directly to shell environments,
config files, and agent processes. This creates unnecessary risk.

## Decision Drivers

- **AC-6 (Least Privilege):** Agent processes should only have access to required resources
- **SC-7 (Boundary Protection):** Clear separation between host and agent execution environment
- **SC-39 (Process Isolation):** Agent execution must be isolated from other processes
- **SI-7 (Software/Information Integrity):** Prevent agents from modifying host systems
- **Agency policy:** Secrets must not be persisted in repos or config files

## Considered Options

1. **Docker SBX (Sandboxed Containers)** — Isolated container execution with
   runtime secret injection
2. **Direct Local Execution** — Run agents directly on developer machine
3. **Custom Wrapper CLI** — Build abstraction layer around agent execution
4. **Remote-Only Execution (CI/CD)** — All agent execution happens in CI pipelines

## Decision Outcome

Chosen option: **Docker SBX (Sandboxed Containers)**, because it provides strong
isolation between agent and host while maintaining fast local iteration cycles
and enabling secure secret injection without persistence.

### Architecture Overview

```
[ Developer Machine ]
        |
        v
[ SBX Container ]
        |
        +--> Agent Runtime (OpenCode / others)
        |
        +--> Injected Secrets (SBX-managed)
        |
        v
[ USAi API Endpoint ]
```

### Key Implementation Elements

1. **SBX as Isolation Layer**
   - All agents run inside SBX containers
   - Host environment is treated as untrusted boundary
   - Working directory constraints enforced

2. **Secret Injection via SBX**
   - Secrets managed through SBX secret mechanism
   - Injected at runtime, not persisted in repo or config
   - Environment variables never printed or logged

3. **OpenAI-Compatible API Usage**
   - USAi endpoints used via `baseURL` configuration
   - `Authorization: Bearer <key>` header format
   - Compatible with OpenCode and similar agent frameworks

4. **Config-Driven Agent Setup**
   - `opencode.jsonc` defines provider, models, endpoint configuration
   - Minimal configuration preferred over custom scripts
   - No unnecessary abstraction layers

### Positive Consequences

- Strong isolation between agent and host
- Reduced risk of credential leakage
- Reproducible developer environments
- Compatible with multiple agent frameworks
- Fast local iteration cycle

### Negative Consequences

- Additional setup complexity (SBX tooling)
- Rapidly evolving SBX tooling (breaking changes likely)
- Debugging may be less straightforward than local execution

### Compliance Consequences

- **AC-6:** Satisfied — agents operate with minimal privileges within container
- **SC-7:** Satisfied — container boundary enforces separation
- **SC-39:** Satisfied — process isolation via containerization
- **SI-7:** Partially addressed — host system protected, but container integrity
  depends on image provenance
- **SSP Impact:** Update boundary diagram to include SBX containers

## Alternatives Considered

### Direct Local Execution

Rejected because:
- Secrets exposed directly to agent runtime
- No isolation between agent and host processes
- Higher risk of credential leakage via logs/history

### Custom Wrapper CLI

Partially rejected because:
- SBX tooling is rapidly evolving
- Additional abstraction layer adds maintenance burden
- Redundant with SBX capabilities

### Remote-Only Execution (CI/CD)

Rejected because:
- Slower iteration cycle
- Harder to debug interactively
- Less developer-friendly for experimentation
- Overkill for sandbox/testing purposes

## Links

- [NIST SP 800-53 Rev 5 — AC-6 Least Privilege](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [NIST SP 800-53 Rev 5 — SC-7 Boundary Protection](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [SBX Documentation](https://sbx.dev/docs) (if available)
- Related: `AGENTS.md` — Agent behavioral rules for this repository
