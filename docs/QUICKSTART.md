---
title: "acq Backend Quickstart"
description: "Get running with acq, the pluggable-backend wrapper for agentic-coding-quickstart"
status: canonical
tier: 2
last_updated: "2026-07-14"
audience: "developers"
keywords: ["acq", "backend", "sbx", "quickstart", "sandbox"]
related_files: ["docs/BACKEND_GUIDE.md", "docs/QUICKSTART_SBX.md", "docs/adr/0010-acq-pluggable-backends.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq Backend Quickstart

> **`acq` is the recommended entry point** as of version 1.1.0. It replaces
> `qsbx` and adds a pluggable-backend architecture. For now, it defaults to
> the **sbx** backend and the same four kits as `qsbx`. Migration is seamless:
> replace `./qsbx` with `./acq` — the commands are identical on the sbx backend.

---

## Quick Start (sbx backend)

### Step 1: Prerequisites

Complete the standard setup in [README.md](../README.md#5-minute-quickstart):

- Install the `sbx` CLI (>= 0.35.0)
- Run `sbx login`
- Set your network policy and secrets (USAi key, GitHub token)

### Step 2: Run a sandbox

```bash
./acq run opencode /path/to/your/project
```

That's it. `acq run` creates the sandbox if it doesn't exist, heals any missing
kits, validates your USAi key, and attaches the agent.

### Step 3: Common commands

| Command | What it does |
|---------|-------------|
| `./acq run opencode /proj` | Create+attach (or re-attach) a sandbox |
| `./acq create opencode /proj` | Create detached (no attach) |
| `./acq ls` | List your sandboxes |
| `./acq stop NAME` | Stop a sandbox |
| `./acq rm NAME` | Remove a sandbox |
| `./acq exec NAME -- CMD` | Run a command inside a sandbox |
| `./acq cp SRC DST` | Copy files in/out (NAME:path syntax) |
| `./acq version` | Show acq version + active backend |
| `./acq doctor` | Backend health check + write default config |

### Secrets

```bash
# USAi key — global (available to all sandboxes)
./acq secret set -g usai

# USAi key — scoped to one sandbox only (safe for testing)
./acq secret set my-sandbox usai

# GitHub token — global
./acq secret set -g github

# Arbitrary custom endpoint — global
./acq secret set -g myservice --host api.example.com --env MY_API_KEY
```

### Rotate your USAi key

```bash
./acq usai-rotate-api-key
```

---

## Backend Selection

`acq` resolves the active backend in this priority order:

1. `--backend <name>` flag (per-invocation override)
2. `ACQ_BACKEND` environment variable
3. `backend:` in `~/.config/acq/config.yaml`
4. Auto-detect: first installed backend found

**Today (1.1.x), only the `sbx` backend is available.** A second backend
(`msb` — microsandbox) is planned for 1.2.0. See
[docs/BACKEND_GUIDE.md](BACKEND_GUIDE.md) for per-backend details.

### Persist the default backend

```bash
# Write `backend: sbx` to ~/.config/acq/config.yaml
./acq backend set sbx

# Or run doctor and answer the prompt
./acq doctor
```

### Override for one invocation

```bash
./acq --backend sbx run opencode /proj
```

---

## Migration from qsbx

`qsbx` is deprecated as of 1.1.0 and will be removed in 2.0.0. Migration is
**fully backward-compatible**: replace `./qsbx` with `./acq` in all commands.

| Old command | New command | Notes |
|-------------|-------------|-------|
| `./qsbx run opencode /proj` | `./acq run opencode /proj` | Identical semantics |
| `./qsbx create opencode /proj` | `./acq create opencode /proj` | Identical |
| `./qsbx ls` | `./acq ls` | Identical |
| `./qsbx usai-rotate-api-key` | `./acq usai-rotate-api-key` | Identical |
| `./qsbx version` | `./acq version` | Shows backend info too |

`QSBX_EXTRA_KITS` and `QSBX_EXTRA_KIT_SOURCES` are now `ACQ_EXTRA_KITS` and
`ACQ_EXTRA_KIT_SOURCES`. The `QSBX_*` vars are not read by `acq`.

---

## Advanced: extra kits

```bash
# Apply an extra kit on every invocation
export ACQ_EXTRA_KITS="./my-local-kit git+https://github.com/acme/kits.git#ref=<sha>&dir=some-kit"

# Allow a new kit source prefix
export ACQ_EXTRA_KIT_SOURCES="github.com/acme/"
```

---

## Exec timeout tuning

The default timeout for waiting for `sbx exec` to become ready after a sandbox
starts is 60 seconds. Override:

```bash
export ACQ_EXEC_READY_TIMEOUT=120
```

---

## See also

- [docs/BACKEND_GUIDE.md](BACKEND_GUIDE.md) — per-backend strengths and tradeoffs
- [docs/QUICKSTART_SBX.md](QUICKSTART_SBX.md) — detailed sbx CLI reference
- [docs/adr/0010-acq-pluggable-backends.md](adr/0010-acq-pluggable-backends.md) — architecture decision
- [docs/KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md) — troubleshooting
