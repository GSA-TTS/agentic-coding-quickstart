---
title: "acq Backend Guide"
description: "Per-backend strengths, tradeoffs, and configuration for acq"
status: canonical
tier: 2
last_updated: "2026-07-15"
audience: "developers"
keywords: ["acq", "backend", "sbx", "msb", "microsandbox", "tradeoffs"]
related_files: ["docs/QUICKSTART.md", "docs/QUICKSTART_SBX.md", "docs/adr/0010-acq-pluggable-backends.md", "docs/adr/0011-msb-backend-and-neutral-kits.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq Backend Guide

`acq` supports multiple isolation backends behind one command surface. As of
1.2.0, two backends ship: **sbx** (Docker Sandboxes) and **msb**
(microsandbox). Kits are authored once in the neutral `hybrid/v1` vocabulary and
translated to each backend's native mechanism (see
[ADR-0011](adr/0011-msb-backend-and-neutral-kits.md)).

| Backend | Version | Status | Description |
|---------|---------|--------|-------------|
| **sbx** | 1.1.0 | Shipped | Docker-based sbx CLI from Docker Inc |
| **msb** | 1.2.0 | Shipped | microsandbox — lightweight microVM isolation (FOSS) |
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

## msb Backend (microsandbox, 1.2.0)

The **msb** backend wraps [microsandbox](https://github.com/superradcompany/microsandbox),
an open-source (Apache-2.0) microVM runtime. It is a good fit when you want a
FOSS runtime with no Docker account/seat, snapshot/restore, or an SDK-first
automation story.

### Overview

- microVM isolation (libkrun) with per-sandbox network policy
- Runs standard OCI images (Docker Hub, GHCR, any registry)
- Native host-CA trust propagation (`--trust-host-cas`)
- Native TLS interception + host-env secret binding (`--secret ENV@HOST`) so
  credentials never enter the guest
- Snapshot/restore and detached long-running sandboxes

### Strengths

- **No Docker account required** — FOSS binary, `msb self update` to upgrade
- **Zscaler CA shortcut**: the `zscaler-ca-certificate` kit takes msb's native
  `--trust-host-cas` path instead of the file-drop + `update-ca-certificates`
  dance (behavioral parity — the guest trusts the Zscaler CA either way)
- **Secret injection**: the USAi key is bound from a host env var at create time
  (`--secret USAI_API_KEY@api.gsa.usai.gov`); the real value never enters the VM
- **Snapshots**: `msb snapshot` supports save/restore

### Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| `msb` CLI | >= 0.6.0 | `--net-rule`, `--trust-host-cas`, `--secret` used by acq |
| Host virtualization | — | Linux: KVM (`/dev/kvm`); macOS: HVF (Apple Silicon); Windows: WHP |

Run `msb doctor` to check host readiness (`msb doctor --fix` attempts setup).

### Installation

```bash
curl -fsSL https://install.microsandbox.dev | sh        # macOS / Linux
brew install superradcompany/tap/microsandbox           # Homebrew
```

### Configuration

```bash
# Persist msb as the default backend
./acq backend set msb

# Per-invocation override
./acq --backend msb run opencode /proj

# Environment override
export ACQ_BACKEND=msb
```

Tunables:

| Env var | Default | Meaning |
|---------|---------|---------|
| `ACQ_MSB_IMAGE` | `ghcr.io/gsa-tts/agentic-coding-quickstart/opencode:latest` | OCI image for provisioned sandboxes |
| `ACQ_MSB_KIT_CACHE` | `$XDG_CACHE_HOME/acq/kits` | where fetched neutral kits are materialized |

### Secrets

msb binds secrets from **host environment variables** at create time. The real
value is never inlined into the sandbox config and never enters the guest:

```bash
export USAI_API_KEY=<your-usai-key>
./acq --backend msb run opencode /path/to/project
# acq binds USAI_API_KEY@api.gsa.usai.gov automatically at create.
```

`acq secret set usai` on the msb backend prints this guidance rather than
writing to a store. A unified cross-backend secret store is planned (see
[ADR-0011](adr/0011-msb-backend-and-neutral-kits.md)); it is out of scope for
1.2.0.

### Capability flags

| Flag | Value | Meaning |
|------|-------|---------|
| `ACQ_BACKEND_SUPPORTS_PORT_FORWARD` | 0 | No post-hoc `acq ports`; publish at create/run via `-p HOST:GUEST` |
| `ACQ_BACKEND_SUPPORTS_SNAPSHOTS` | 1 | `msb snapshot` save/restore |
| `ACQ_BACKEND_CAN_RESUME` | 1 | `msb stop` / `msb start` preserve state |
| `ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE` | 1 | `--secret ENV@HOST` + `--tls-intercept` |

### Differences from sbx

| Feature | sbx | msb |
|---------|-----|-----|
| Isolation | Container (microVM) | microVM (libkrun) |
| Kit format | Neutral `hybrid/v1` → sbx-v2 (synthesized) | Neutral `hybrid/v1` → `msb` operations |
| Zscaler CA | file-drop + `update-ca-certificates` | native `--trust-host-cas` shortcut |
| Secret model | proxy `secret set-custom` | host-env `--secret ENV@HOST` |
| Port forwarding | `acq ports` (post-hoc) | published at create/run (`-p`) only |
| In-place kit heal | `sbx kit add` (state-preserving, 0.35.0+) | re-apply kits idempotently (no state-preserving add) |

### Known limitations

- **Ports are set at create/run time**, not post-hoc. `acq --backend msb ports`
  prints the correct mechanism instead of forwarding.
- **No state-preserving in-place kit add.** `acq_backend_ensure_kits_applied`
  re-applies kits idempotently; for a clean rebuild use `acq rm && acq run`.
- **Unified secret store deferred.** msb uses its native host-env `--secret`
  binding for 1.2.0.

> **Live end-to-end note:** the full `acq run … --backend msb` loop and the
> `scripts/verify-backends` msb row cannot run inside an sbx/msb sandbox (no
> nested sandboxes) and require host virtualization (`/dev/kvm` on Linux). The
> msb CLI flag shapes used by the adapter were verified against `msb 0.6.6`;
> the create→exec→attach loop is deferred to a sandbox-capable host (mirrors
> ADR-0010's deferred sbx verification). See
> [ADR-0011](adr/0011-msb-backend-and-neutral-kits.md).

---

## ppp Backend (deferred)

The Podman-Plus-Proxy (ppp) backend is on hold — planned but not scheduled.
See `docs/explorations/` for the design notes when available.

---

## Backend resolution order

`acq` resolves the backend in this priority order (highest wins):

1. `--backend <name>` flag (per-invocation override)
2. `ACQ_BACKEND` environment variable
3. `backend:` key in `~/.config/acq/config.yaml`
4. Auto-detect: first installed backend (`sbx` preferred, then `msb`)

If multiple backends are installed and none is explicitly selected, `acq`
auto-detects in the order above (sbx wins when both are present). Use
`--backend`, `ACQ_BACKEND`, or `acq backend set` to pick msb explicitly.

---

## Troubleshooting

Set `ACQ_DEBUG=1` to trace backend CLI invocations and kit fetch/translate
steps to stderr (no secret values are printed):

```bash
ACQ_DEBUG=1 ./acq --backend msb create shell /path/to/project
```

`scripts/verify-backends` supports `-v`/`--verbose` (stream every acq command
and its output live) and `-k`/`--keep` (leave a failing sandbox up for manual
inspection):

```bash
./scripts/verify-backends -v
```

---

## Adding a new backend (implementer notes)

1. Create `acq.backends/<name>.sh` implementing the contract in
   [ADR-0010 §"Adapter contract"](adr/0010-acq-pluggable-backends.md).
2. Set the capability flags at the top of the file.
3. Implement all required `acq_backend_*` functions. Consume the neutral
   `hybrid/v1` kits via `acq.backends/kit-translate.sh` (parse the spec, honor
   `backend_shortcuts.<name>`, then emit your backend's native operations).
4. Add auto-detect to `_auto_detect_backend` in `acq.backends/common.sh`.
5. Add the backend to `acq backend list` and `acq_print_doctor`.
6. Write tests in `scripts/test-acq` (stub the CLI) and a row in
   `scripts/verify-backends`.
7. Document it here.

---

## Kits: the neutral hybrid/v1 vocabulary

Kits are authored once in the neutral `hybrid/v1` spec (in the patterns repo
under `integrations/isolation/acq-kits/`) and translated per backend by
`acq.backends/kit-translate.sh`:

- **sbx** — the neutral spec is synthesized into an sbx-v2 kit directory
  (`spec.yaml` + `files/`), then applied via `sbx --kit` / `sbx kit add`. The
  observable result is identical to the pre-1.2 sbx kits.
- **msb** — the neutral spec is fetched and driven directly: network allows
  become `--net-rule` flags, files are `msb copy`'d in, and `commands` run via
  `msb exec`. A `backend_shortcuts.msb` (e.g. zscaler `trust_host_cas`) uses the
  native primitive instead.

Manage kits with `acq kit list | validate PATH | apply NAME KITREF`.

---

## Shipped in 1.2.0

- `acq kit apply|list|validate` — kit management subcommands
- Neutral `hybrid/v1` kit spec + `kit-translate.sh` (multi-backend kits)
- `msb` (microsandbox) backend

## Still deferred

- Full unified swap-on-access secret model across backends (msb uses its native
  host-env `--secret` binding for now)
- `acq policy …` — network policy subcommands
- `ppp` (Podman-Plus-Proxy) backend
- Removal of `qsbx` (Phase 4 / 2.0.0)
