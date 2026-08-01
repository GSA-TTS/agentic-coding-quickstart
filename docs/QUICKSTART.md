---
title: "acq Backend Quickstart"
description: "Get running with acq, the pluggable-backend wrapper for agentic-coding-quickstart"
status: canonical
tier: 2
last_updated: "2026-07-15"
audience: "developers"
keywords: ["acq", "backend", "sbx", "msb", "quickstart", "sandbox"]
related_files: ["docs/BACKEND_GUIDE.md", "docs/QUICKSTART_SBX.md", "docs/adr/0010-acq-pluggable-backends.md", "docs/adr/0011-msb-backend-and-neutral-kits.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq Backend Quickstart

> **`acq` is the recommended entry point.** It replaces the deprecated `qsbx`
> and adds a pluggable-backend architecture. As of 1.2.0 it supports two
> backends — **sbx** (Docker Sandboxes) and **msb** (microsandbox) — sharing one
> neutral kit vocabulary. Migration from `qsbx` is seamless: replace `./qsbx`
> with `./acq` — the commands are identical on the sbx backend.

---

## Choose a backend

`acq` runs the same commands on either backend; you only choose the backend
once (install one, and it auto-detects). Pick the one that fits your environment:

| Backend | Install | Fits when |
|---------|---------|-----------|
| **sbx** | `brew install docker/tap/sbx && sbx login` | You have Docker and want the commercial product |
| **msb** | `curl -fsSL https://install.microsandbox.dev \| sh` | You want a FOSS microVM runtime, no Docker seat, snapshots |

See [docs/BACKEND_GUIDE.md](BACKEND_GUIDE.md) for a full comparison. `acq`
auto-detects an installed backend (sbx preferred when both are present); persist
a choice with `acq backend set <sbx|msb>` or `acq doctor`.

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

**Today (1.2.x), two backends ship: `sbx` and `msb`.** See
[docs/BACKEND_GUIDE.md](BACKEND_GUIDE.md) for per-backend details. A third
backend (`ppp` — Podman-Plus-Proxy) is deferred.

### Persist the default backend

```bash
# Write `backend: sbx` (or msb) to ~/.config/acq/config.yaml
./acq backend set sbx
./acq backend set msb

# Or run doctor and answer the prompt
./acq doctor
```

### Override for one invocation

```bash
./acq --backend sbx run opencode /proj
./acq --backend msb run opencode /proj
```

---

## Running on the msb backend

```bash
# 1. Install msb (microsandbox) and confirm the host is ready
curl -fsSL https://install.microsandbox.dev | sh
msb doctor          # checks KVM/HVF/WHP; msb doctor --fix to set up

# 2. Export the USAi key (msb binds it from a host env var at create; the real
#    value never enters the guest)
export USAI_API_KEY=<your-usai-key>

# 3. Run — acq auto-detects msb, or force it with --backend msb
./acq --backend msb run opencode /path/to/your/project
```

msb takes native shortcuts where it has a strictly-better primitive — e.g. the
Zscaler CA kit uses `--trust-host-cas` instead of the file-drop mechanism. Kit
behavior is otherwise identical across backends.

---

## Managing kits

Kits are authored once in the neutral `hybrid/v1` vocabulary and translated to
the active backend automatically. Inspect and manage them with:

```bash
./acq kit list                    # show the pinned kits + patterns ref
./acq kit validate ./my-kit/      # validate a neutral kit dir or spec.yaml
./acq kit apply my-sandbox KITREF # apply a kit to an existing sandbox
```

### Keeping existing sandboxes current

`acq` pins the built-in kit bundle to one commit of the patterns repo. **New**
sandboxes get the pinned bundle automatically; for an **existing** sandbox, `acq`
can tell you if it is behind and refresh it in place:

```bash
./acq kit check my-sandbox        # is this sandbox on the pinned bundle?
./acq kit update my-sandbox       # refresh the bundle in place (asks first)
```

`acq run` also offers a refresh when a sandbox is behind; it defaults to No and
never blocks a launch. Refreshes are in place (sessions, secrets, and project
files are kept). Skip the automatic check with `ACQ_UPDATE_CHECK=0` or
`./acq run --no-update-check`.

See [ADR-0016](adr/0016-kit-bundle-provenance-and-stale-refresh.md) for the full
design and trust model.

---

## Migration from qsbx

`qsbx` is deprecated as of 1.1.0 and is slated for removal in 3.0.0. Migration is
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

You can also apply an extra kit for a single `run`/`create` with `--kit`
(repeatable), instead of the env var:

```bash
# One-off: apply a local kit dir (or a git+https ref)
acq run opencode --kit ./my-local-kit .
acq create opencode --kit ./kit-a --kit git+https://github.com/acme/kits.git#ref=<sha>&dir=some-kit /proj
```

`--kit` refs are translated by `acq` exactly like `ACQ_EXTRA_KITS` entries (a
neutral `hybrid/v1` kit is converted to the active backend's format), so they
work with any backend — they are **not** forwarded raw to the backend CLI.

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
