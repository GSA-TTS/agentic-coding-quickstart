---
title: "acq How-To Guide"
description: "Detailed how-to for acq, the pluggable-backend wrapper for agentic-coding-quickstart"
status: canonical
tier: 2
last_updated: "2026-08-21"
audience: "developers"
keywords: ["acq", "backend", "sbx", "msb", "howto", "sandbox"]
related_files: ["docs/BACKEND_GUIDE.md", "docs/CONCEPTS.md", "docs/howto/msb.md", "docs/howto/sbx.md", "docs/adr/0010-acq-pluggable-backends.md", "docs/adr/0011-msb-backend-and-neutral-kits.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq How-To Guide

> The [README](../../README.md) is the quickstart — the fast path to a running
> sandbox. This guide is the deeper how-to for `acq`, the entry point. It
> provides a pluggable-backend architecture supporting two backends — **msb**
> (microsandbox, the default) and **sbx** (Docker Sandboxes) — sharing one
> neutral kit vocabulary. Install a backend and `acq` runs the same commands on
> either one.

---

## Choose a backend

`acq` runs the same commands on either backend; you only choose the backend
once (install one, and it auto-detects). Pick the one that fits your environment:

| Backend | Install | Fits when |
|---------|---------|-----------|
| **msb** | `curl -fsSL https://install.microsandbox.dev \| sh` | You want a FOSS microVM runtime, no Docker seat, snapshots |
| **sbx** | `brew install docker/tap/sbx && sbx login` | You have Docker and want the commercial product |

See [docs/BACKEND_GUIDE.md](../BACKEND_GUIDE.md) for a full comparison. `acq`
auto-detects an installed backend (msb preferred when both are present); persist
a choice with `acq backend set <sbx|msb>` or `acq doctor`.

---

## Quick Start

> **msb is the default backend.** The steps below walk the **msb** path (what
> `acq` uses by default). If you specifically want the **sbx** backend, see
> [Prerequisites (sbx)](#step-1-alt-prerequisites-sbx) and
> [Running on the sbx backend](#running-on-the-sbx-backend). The common commands,
> secrets, and rotation subsections apply to either backend.

### Step 1: Prerequisites (msb)

Complete the standard setup in [README.md](../../README.md#5-minute-quickstart):

- Install the `msb` CLI: `curl -fsSL https://install.microsandbox.dev | sh`
- Run `msb doctor` (add `--fix` to set up KVM/HVF/WHP virtualization)
- Set your network policy

Re-run `msb doctor` once more after setup — a clean `doctor` pass is the quickest
way to confirm the host is ready before your first `acq run` (and, if an
established setup later starts failing every outbound call at once, a wipe +
reinstall then `msb doctor` is the first thing to try; see
[Troubleshooting](../BACKEND_GUIDE.md#troubleshooting)).

You do **not** need to gather a USAi key or GitHub token in advance — `acq`
prompts you for the USAi key on first run and offers to scope a GitHub token
when your workspace has GitHub repos. Set them ahead of time only when
pre-seeding a machine or scripting setup (see [Secrets](#secrets) below).

<h4 id="step-1-alt-prerequisites-sbx">Step 1 (alternate): Prerequisites (sbx)</h4>

To use the **sbx** backend instead:

- Install the `sbx` CLI (>= 0.38.0)
- Run `sbx login`
- Set your network policy

See [Running on the sbx backend](#running-on-the-sbx-backend) for the full sbx
walkthrough.

### Step 2: Run a sandbox

```bash
./acq run opencode /path/to/your/project
```

`/path/to/your/project` is the folder the agent works in — an **existing
project** or a **new, empty folder** you just created. If it's a software
project, run `git init .` in it first so the agent can track its changes.

That's it. `acq run` creates the sandbox if it doesn't exist, heals any missing
kits, validates your USAi key, and attaches the agent.

> [!NOTE]
> The **first** run boots a microVM, installs the agent, and fetches kits — a
> minute or two, with a progress spinner and status lines so you can follow
> along. Later runs are much faster. Set `ACQ_NO_PROGRESS=1` to silence the
> animation (plain status lines still print); `ACQ_DEBUG=1` also disables it in
> favor of a timestamped trace.

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

Setting secrets up front is **optional** — `acq run` validates your USAi key and
prompts you to set or rotate it when it's missing or expired, and offers to
scope a GitHub token when your workspace has GitHub repos. Set them explicitly
when you want to pre-seed a machine, script setup, or run in CI:

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

`acq` injects secrets into the sandbox at runtime; the real values never enter
the guest.

> [!WARNING]
> A broad token — one from `gh auth token`, or a classic PAT — carries
> **account-wide** scopes (`repo`, `workflow`, `delete_repo`, …). Stored globally
> (`-g`), it is injected into **every** sandbox, so an agent working on one
> project can act as you on **all** your repositories. Prefer a per-sandbox
> fine-grained token scoped to just the mounted repos:
>
> ```bash
> ./acq github-scope <sandbox-name> /path/to/your/project
> ```
>
> This is also what `acq run` offers interactively. Fine-grained tokens can't
> contribute to public repos you're not a member of or call the Checks API — fall
> back to a global token for those cases. See
> [ADR-0013](../adr/0013-per-sandbox-github-token-downscoping.md).

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
4. Auto-detect: first installed backend found (msb preferred, then sbx)

**Today (1.2.x), two backends ship: `msb` (default) and `sbx`.** See
[docs/BACKEND_GUIDE.md](../BACKEND_GUIDE.md) for per-backend details. A third
backend (`ppp` — Podman-Plus-Proxy) is deferred.

### Persist the default backend

```bash
# Write `backend: msb` (or sbx) to ~/.config/acq/config.yaml
./acq backend set msb
./acq backend set sbx

# Or run doctor and answer the prompt
./acq doctor
```

### Override for one invocation

```bash
./acq --backend sbx run opencode /proj
./acq --backend msb run opencode /proj
```

---

## Running on the msb backend (default)

```bash
# 1. Install msb (microsandbox) and confirm the host is ready
curl -fsSL https://install.microsandbox.dev | sh
msb doctor          # checks KVM/HVF/WHP; msb doctor --fix to set up

# 2. Provide the USAi key.
#    INTERACTIVE (recommended): skip this line — `acq run` prompts you for the
#    key on first run, or set it once with:  ./acq secret set -g usai
#    (prompts for the value; it never lands in argv or your shell history).
#
#    NON-INTERACTIVE / scripting / CI only: msb binds the key from a host env var
#    at create (the real value never enters the guest). Read it WITHOUT echoing
#    so it does not leak into shell history:
read -rs -p 'USAi API key: ' USAI_API_KEY; export USAI_API_KEY; echo

# 3. Run — acq auto-detects msb, or force it with --backend msb
./acq --backend msb run opencode /path/to/your/project
```

msb takes native shortcuts where it has a strictly-better primitive — e.g. the
Zscaler CA kit uses `--trust-host-cas` instead of the file-drop mechanism. Kit
behavior is otherwise identical across backends.

## Running on the sbx backend

```bash
# 1. Install the sbx CLI (>= 0.38.0) and authenticate
#    (see https://docs.docker.com/ai/sandboxes/ — the standalone sbx CLI,
#     NOT the deprecated `docker sandbox`)
sbx login
sbx policy set <your-network-policy>

# 2. Run — acq uses sbx when it is your only backend or you have existing sbx
#    sandboxes, or force it with --backend sbx
./acq --backend sbx run opencode /path/to/your/project
```

For sbx-specific detail (proxy secrets, network policy), see the
[full sbx guide](sbx.md). For the backend-neutral way to mount
multiple directories, see [Multiple Workspaces](../CONCEPTS.md#multiple-workspaces).

### msb host setup

msb runs each sandbox as a lightweight microVM, so the host must provide
hardware virtualization. `msb doctor` is the authoritative check (and
`msb doctor --fix` attempts supported setup changes); the per-platform
requirements below mirror the [microsandbox docs](https://microsandbox.dev):

**Linux** — a glibc-based distribution with KVM enabled.

```bash
# KVM device present?
test -e /dev/kvm && echo ok

# CPU virtualization exposed? (non-zero = vmx/svm present)
grep -Ec '(vmx|svm)' /proc/cpuinfo
```

A missing `/dev/kvm` (or a `0` from the second command) means virtualization is
disabled in firmware, unavailable on the machine, or hidden by an outer VM. If
your user lacks access to the device, add yourself to the `kvm` group once:

```bash
sudo usermod -aG kvm "$USER" && newgrp kvm
```

**macOS** — Apple Silicon (M-series). Intel Macs are **not supported** for the
local runtime, and Rosetta does not change that. Nothing to enable ahead of
time: Apple Silicon Macs include the hypervisor support msb uses.

**Windows 11** — Windows support is in **preview**. Local sandboxes need the
**Windows Hypervisor Platform** feature (this is separate from the
`VirtualMachinePlatform` feature that WSL2 and Docker Desktop enable):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart
```

`msb doctor --fix` can apply this for you from an elevated PowerShell window.

**Inside a cloud VM, CI runner, or another hypervisor** — the outer environment
must expose **nested virtualization** before `/dev/kvm` (or the equivalent) is
available to msb. Many hosted CI runners and cloud VMs do not enable it by
default.

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

See [ADR-0016](../adr/0016-kit-bundle-provenance-and-stale-refresh.md) for the full
design and trust model.

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

## Progress output

During the long, quiet phases of `acq run` (booting the microVM, installing the
agent, fetching/applying kits), `acq` prints status lines and — on an
interactive terminal — an animated spinner, so you can tell work is happening.

- **Interactive terminal:** spinner + status lines.
- **Piped / redirected / CI:** plain status lines only (no animation), so logs
  stay clean.
- `ACQ_NO_PROGRESS=1` — never animate; still print the plain status lines.
- `ACQ_DEBUG=1` — disables the spinner in favor of a timestamped trace.

Progress output goes to **stderr**, so a piped stdout stays uncluttered.

---

## Exec timeout tuning

The default timeout for waiting for the backend's exec (`sbx exec` / `msb exec`,
via `acq exec`) to become ready after a sandbox starts is 60 seconds. Override:

```bash
export ACQ_EXEC_READY_TIMEOUT=120
```

---

## See also

- [docs/BACKEND_GUIDE.md](../BACKEND_GUIDE.md) — per-backend strengths and tradeoffs
- [docs/howto/msb.md](msb.md) — detailed msb (microsandbox) reference (the default backend)
- [docs/howto/sbx.md](sbx.md) — detailed sbx CLI reference
- [docs/adr/0010-acq-pluggable-backends.md](../adr/0010-acq-pluggable-backends.md) — architecture decision
- [docs/KNOWN_FAILURE_MODES.md](../KNOWN_FAILURE_MODES.md) — troubleshooting
