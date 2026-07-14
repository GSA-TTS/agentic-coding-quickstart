---
title: "acq Backend Guide"
description: "Per-backend strengths, tradeoffs, and configuration for acq"
status: canonical
tier: 2
last_updated: "2026-07-14"
audience: "developers"
keywords: ["acq", "backend", "sbx", "msb", "microsandbox", "tradeoffs"]
related_files: ["docs/QUICKSTART.md", "docs/QUICKSTART_SBX.md", "docs/adr/0010-acq-pluggable-backends.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq Backend Guide

`acq` is designed to support multiple isolation backends. Today (1.1.x), only
the **sbx** backend ships. Additional backends are planned:

| Backend | Version | Status | Description |
|---------|---------|--------|-------------|
| **sbx** | 1.1.0 | Shipped | Docker-based sbx CLI from Docker Inc |
| **msb** | 1.2.0 (planned) | Coming | microsandbox — lightweight VM-based isolation |
| **ppp** | Deferred | Not scheduled | Podman-Plus-Proxy backend |

---

## sbx Backend (default, 1.1.x)

### Overview

The **sbx** backend wraps the [sbx CLI](https://docs.docker.com/ai/sandboxes/)
from Docker Inc. It provides:

- Container-based isolation
- Declarative kit composition (mixin kits applied at create time)
- Built-in secret proxy injection (secrets never enter the container)
- SSH key forwarding for git signing
- Persistent sandbox state across sessions

### Strengths

- **Production-ready**: Docker-backed, mature tooling
- **Secret proxy**: USAi key, GitHub token, and other secrets are injected by
  the proxy — the agent never sees them directly
- **Kit ecosystem**: Reuses all four community kits unchanged (`usai-provider`,
  `agentic-coding-playbook`, `zscaler-ca-certificate`, `git-ssh-sign`)
- **In-place healing**: Missing kits are added with `sbx kit add` on reconnect
  without losing sandbox state (requires sbx >= 0.35.0)
- **Port forwarding**: Supports `--publish` for exposing agent web UIs

### Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| `sbx` CLI | >= 0.35.0 | `sbx kit add` requires 0.35.0 for in-place healing |
| Docker account | any | Required for `sbx login` |
| Docker subscription seat | (org-dependent) | Some orgs require paid seats |
| Linux/ARM64 | 0.36.x+ | sbx 0.35.x has no Linux/ARM64 build; wait for 0.36.x |

### Installation

See [README.md](../README.md#step-2-install-sbx-cli) for step-by-step
install instructions for macOS, Windows, and Linux.

### Configuration

```bash
# Persist sbx as the default backend
./acq backend set sbx

# Per-invocation override
./acq --backend sbx run opencode /proj

# Environment override
export ACQ_BACKEND=sbx
```

### Capability flags

| Flag | Value | Meaning |
|------|-------|---------|
| `ACQ_BACKEND_SUPPORTS_PORT_FORWARD` | 1 | `acq ports` is supported |
| `ACQ_BACKEND_SUPPORTS_SNAPSHOTS` | 0 | No snapshot support |
| `ACQ_BACKEND_CAN_RESUME` | 1 | Sandboxes persist between sessions |
| `ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE` | 1 | Secret proxy injection |

### Known limitations

- No Linux/ARM64 build for sbx 0.35.x; wait for sbx 0.36.x
- `sbx kit add` (healing) is experimental; see
  [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md)
- The sbx `docker sandbox` commands (deprecated by Docker) must not be used;
  use `sbx` CLI directly

---

## msb Backend (planned for 1.2.0)

> **Not yet available.** This section documents the planned design.

The **msb** backend will wrap [microsandbox](https://github.com/microsandbox/microsandbox),
a lightweight VM-based isolation tool with a simpler dependency footprint than
Docker.

### Planned strengths

- No Docker account required
- Lower memory/CPU overhead
- Suitable for Linux environments where Docker is unavailable or undesirable
- Will become the auto-detect default in 1.2.0 once available

### Differences from sbx

| Feature | sbx | msb (planned) |
|---------|-----|---------------|
| Isolation | Container | VM |
| Secret proxy | Builtin | Planned (different mechanism) |
| Kit format | sbx v2 mixin | Neutral `acq` hybrid/v1 spec (planned) |
| Credential rewrite | Yes | Planned |
| Port forwarding | Yes | Planned |

### Migration path

When msb lands in 1.2.0, `acq` will auto-detect it. If both sbx and msb are
installed, `acq` will prompt you to pick one and persist the choice via
`acq doctor`. Existing sbx sandboxes are unaffected.

---

## ppp Backend (deferred)

The Podman-Plus-Proxy (ppp) backend is on hold — planned but not scheduled.
See `docs/explorations/` for the design notes when available.

---

## Backend resolution order

`acq` resolves the backend in this priority order (highest wins):

1. `--backend <name>` flag
2. `ACQ_BACKEND` environment variable
3. `backend:` key in `~/.config/acq/config.yaml`
4. Auto-detect: first available backend (`sbx version`, then `msb version`)

If multiple backends are installed and none is explicitly selected, `acq`
prints the candidates and exits with a hint to set `ACQ_BACKEND`. (Only
relevant once msb/ppp exist alongside sbx.)

---

## Adding a new backend (implementer notes)

1. Create `acq.backends/<name>.sh` implementing the contract in
   `docs/explorations/acq-handoff-1.1.md §5`.
2. Set the four capability flags at the top of the file.
3. Implement all required `acq_backend_*` functions.
4. Add auto-detect to `_auto_detect_backend` in `acq.backends/common.sh`.
5. Add the backend to the `acq backend list` output in `acq`.
6. Write tests in `scripts/test-acq`.
7. Document it here.

---

## Coming in 1.2.x

- `acq kit apply|list|validate` — kit management subcommands
- Full swap-on-access secret model (unified across backends)
- `acq policy …` — network policy subcommands
- Neutral hybrid/v1 kit spec for multi-backend kits
- `msb` backend
