---
title: "msb How-To Guide"
description: "Detailed how-to for the msb (microsandbox) backend behind acq"
status: canonical
tier: 2
last_updated: "2026-08-24"
audience: "developers"
keywords: ["msb", "microsandbox", "backend", "acq", "howto", "sandbox"]
related_files: ["docs/BACKEND_GUIDE.md", "docs/CONCEPTS.md", "docs/howto/acq.md", "docs/howto/sbx.md", "docs/adr/0011-msb-backend-and-neutral-kits.md", "docs/adr/0024-neutral-user-facing-docs-vs-backend-specific.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# msb How-To Guide

> The [README](../../README.md) is the quickstart. This is the detailed msb
> how-to.
>
> **Note:** `msb` (microsandbox) is `acq`'s **default** backend, so most readers
> reach it simply by running `acq run opencode .` (see the
> [acq How-To](acq.md)). This guide collects the msb-specific mechanics the
> neutral docs deliberately do not abstract. For the sbx alternative, see the
> [sbx How-To](sbx.md); to choose between backends, see the
> [Backend Guide](../BACKEND_GUIDE.md). This is the symmetric msb peer to the sbx
> guide per the neutral-first documentation convention
> ([ADR-0024](../adr/0024-neutral-user-facing-docs-vs-backend-specific.md)).

This guide walks you through the [microsandbox](https://github.com/superradcompany/microsandbox)
(`msb`) backend, driven through `acq`, to run AI coding agents with USAi.

## What is microsandbox?

[microsandbox](https://github.com/superradcompany/microsandbox) is an
open-source (Apache-2.0) microVM runtime (libkrun). Each sandbox is a real
microVM with its own kernel, filesystem, and per-sandbox network policy. It runs
standard OCI images, needs no Docker account/seat, and supports snapshot/restore
and detached long-running sandboxes.

## Why msb?

| Property | msb (microsandbox) |
|----------|--------------------|
| Runtime | microVM (libkrun) |
| Account required | None — FOSS binary |
| Base images | Any OCI registry (Docker Hub, GHCR, …) |
| Secret handling | Host-env binding `--secret ENV@HOST` (values never enter the guest) |
| Host CA trust | Native `--trust-host-cas` (Zscaler shortcut) |

`msb` is `acq`'s default. Prefer it unless you specifically need Docker
Sandboxes — see the [Backend Guide](../BACKEND_GUIDE.md) for the full
strengths/tradeoffs comparison.

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| `msb` CLI | >= 0.6.8 | `--net-rule`, `--trust-host-cas`, `--secret`, `--net-default-egress`. Host ssh-agent forwarding (git signing) additionally needs msb >= 0.6.9 (`--vsock`; [ADR-0021](../adr/0021-msb-host-ssh-agent-forwarding-via-vsock.md)) — it warns and skips on older msb. |
| Host virtualization | — | Linux: KVM (`/dev/kvm`); macOS: HVF (Apple Silicon); Windows: WHP |

Run `msb doctor` to check host readiness (`msb doctor --fix` attempts setup).
`acq` runs this check automatically before create; set `ACQ_SKIP_MSB_DOCTOR=1`
to skip it.

## Step 1: Install msb

```bash
curl -fsSL https://install.microsandbox.dev | sh        # macOS / Linux
brew install superradcompany/tap/microsandbox           # Homebrew

# Verify
msb --version
```

<a id="msb-host-setup"></a>

### Host setup

If `msb doctor` reports the host is not ready, follow its guidance (`msb doctor
--fix` attempts the setup). Common items: enabling KVM on Linux
(`/dev/kvm` present and accessible) or Apple Virtualization on macOS. `acq`
surfaces the doctor output before it provisions a sandbox.

## Step 2: Select the backend

`msb` is the default, so no selection is needed for a fresh setup. To be
explicit or to switch back from sbx:

```bash
# Persist msb as the default backend
./acq backend set msb

# Or per-invocation
./acq --backend msb run opencode /proj

# Or via environment
export ACQ_BACKEND=msb
```

## Step 3: Store your secrets

On msb, secrets are **bound from host environment variables at create time**
(`--secret ENV@HOST`); the real values never enter the guest. Drive this through
`acq secret`:

```bash
# USAi API key (bound as USAI_API_KEY@api.gsa.usai.gov)
acq secret set usai

# GitHub token (bound per-sandbox, scoped to the GitHub hosts)
acq secret set github

# Any custom endpoint (generic host/env binding)
acq secret set gitlab --host workshop.cloud.gov --env GITLAB_TOKEN
```

`acq secret set <svc>` reads the value from your host environment (or prompts)
and records the `ENV@HOST` binding msb applies at create. See
[Credential Injection Methods](../../AGENTS.md#credential-injection-methods) and
the [Backend Guide](../BACKEND_GUIDE.md) for the full per-backend secret model.

> [!NOTE]
> Because msb binds secrets **at create time**, both the USAi key and any GitHub
> token must be in place *before* the sandbox is created. `acq run` / `acq create`
> handle this for you: on a fresh create they gate on the USAi key and offer to
> scope a GitHub token **before** provisioning, so a token you supply binds to the
> new sandbox. A token added after create would not bind to it (you can still add
> it live with `acq secret set` / `acq github-scope`, which re-feeds a running
> sandbox via `msb modify`).
>
> Because msb swaps the real value in on the wire, inspecting the guest
> environment is not automatically a leak — but never deliberately dump secret
> values (`echo $SECRET`, piping `env` to a log). See `AGENTS.md`.

## Step 4: Create your first sandbox

```bash
# Navigate to your project
cd /path/to/your/project

# Create and run a sandbox with OpenCode (msb is the default backend)
acq run opencode .
```

The sandbox boots and you land in the agent environment.

### Other supported agents

```bash
acq run claude .        # Claude Code
acq run codex .         # OpenAI Codex
acq run copilot .       # GitHub Copilot
acq run cursor .        # Cursor
acq run docker-agent .  # Docker agent
acq run droid .         # Droid
acq run gemini .        # Google Gemini
acq run kiro .          # Kiro
acq run shell .         # Just a shell (no agent)
```

This list is sourced from `acq.backends/agents.sh`; `prime-agent` is not added by
this change.

### Create with a custom name

```bash
acq create --name my-feature opencode .
acq run my-feature          # re-attach by name
```

### Multiple workspaces

Mounting extra directories works identically on both backends via `acq`; see the
canonical [Multiple Workspaces](../CONCEPTS.md#multiple-workspaces) concept. The
only msb-specific caveats: each host workspace path must already exist (msb does
not create the mount path), and symlinked host paths (notably macOS `$TMPDIR`)
are canonicalized to their real path before mounting.

## Step 5: Managing sandboxes

```bash
acq ls                      # list sandboxes
acq stop my-sandbox         # stop (preserves state)
acq run my-sandbox          # resume / re-attach by name
acq rm my-sandbox           # remove permanently
acq run my-sandbox          # interactive attach (relaunches the recorded agent)
acq shell my-sandbox        # interactive human shell (acq exec runs a command, not a TTY)
acq exec my-sandbox -- <cmd>   # run a one-off command in the sandbox
```

Unlike sbx, msb **can** stop and resume detached long-running sandboxes and
supports snapshot/restore natively (`msb snapshot …`); `acq` does not yet
surface a neutral `acq snapshot` verb (see the Backend Guide's
known-limitations note).

## Common commands reference

| Task | acq command | Raw msb equivalent |
|------|-------------|--------------------|
| List sandboxes | `acq ls` | `msb list` |
| Create sandbox | `acq run <agent> .` | `msb run …` |
| Stop sandbox | `acq stop <name>` | `msb stop <name>` |
| Resume sandbox | `acq run <name>` | `msb run <name>` |
| Remove sandbox | `acq rm <name>` | `msb remove <name>` |
| Run a command | `acq exec <name> -- <cmd>` | `msb exec <name> -- <cmd>` |
| Interactive shell | `acq shell <name>` | `msb exec -it <name> -- bash` |

The following are genuinely msb-specific mechanics the wrapper does not
abstract — use the raw `msb` command:

| Task | Command |
|------|---------|
| Check host readiness | `msb doctor` (`msb doctor --fix`) |
| Check version | `msb --version` |
| Self-update | `msb self update` |
| Import a local image | `msb image load -i <tar> -t <ref>` |
| Snapshots | `msb snapshot …` |

## msb-specific configuration

msb exposes a large set of `ACQ_MSB_*` (and neutral `ACQ_*`) tunables — base
image and pull policy, network egress tier, memory/CPU, DNS, host ssh-agent
forwarding, post-hoc port publishing, and OCI-engine provisioning. Rather than
duplicate them here, the authoritative reference is the
[Backend Guide → msb Backend](../BACKEND_GUIDE.md#msb-backend-microsandbox-default),
including:

- [Network egress tiers (`ACQ_NETWORK_TIER`)](../BACKEND_GUIDE.md#network-egress-tiers-acq_network_tier)
- [Custom base image (`--image` / `ACQ_IMAGE`)](../BACKEND_GUIDE.md#custom-base-image---image--acq_image)
- [Running OCI images inside the sandbox (podman)](../BACKEND_GUIDE.md#running-oci-images-inside-the-sandbox-podman)
- [Host ssh-agent forwarding (git signing)](../BACKEND_GUIDE.md#host-ssh-agent-forwarding-git-signing)

## Troubleshooting

For symptom-driven fixes (DNS, egress, image pulls, port publishing, git
signing, kit services after a resume, host virtualization), see
[`KNOWN_FAILURE_MODES.md`](../KNOWN_FAILURE_MODES.md) — the msb-tagged entries
cover the backend-specific failures.

A few quick msb pointers:

```bash
# Host not ready / boot fails
msb doctor            # then msb doctor --fix

# Guest can't resolve allow-listed hosts (the guest follows the host's
# resolvers by default; force one only if those cannot be used):
export ACQ_MSB_DNS_NAMESERVER=<reachable-resolver>

# Tunnel-only names (ZPA) fail in a sandbox created while the tunnel was down:
# acq relaxes msb's DNS rebind protection only when it sees 100.64/10 resolvers
# at create time. Recreate with it forced off:
ACQ_MSB_DNS_REBIND_PROTECTION=0 acq run opencode .

# A locally-built image won't pull (registry-less reference)
msb image load -i image.tar -t localhost/my-image:tag
ACQ_MSB_PULL=never acq run --image localhost/my-image:tag opencode .
```
