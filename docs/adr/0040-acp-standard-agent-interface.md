---
title: "Adopt Agent Client Protocol (ACP) via acq acp as the Standard Programmatic Agent Interface"
description: "Why acq exposes a stdio-clean, non-interactive acp subcommand for IDE and orchestrator clients such as Zed"
status: accepted
tier: 2
date: 2026-11-13
last_updated: "2026-11-13"
decision_makers: ["William Zujkowski"]
category: architecture
nist_controls: ["AC-3", "AC-6", "CM-2", "CM-5", "CM-6", "SA-8", "SA-15", "SC-7", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
related_files: ["acq", "acq.backends/agents.sh", "acq.backends/common.sh", "docs/adr/0030-agent-kits-on-devenv-base.md", "docs/adr/0035-host-authoritative-sandbox-config.md", "docs/howto/acq.md"]
---

# ADR-0040: Adopt Agent Client Protocol (ACP) via `acq acp` as the Standard Programmatic Agent Interface

## Context and Problem Statement

[ADR-0030](0030-agent-kits-on-devenv-base.md) established the target layering for
`acq`:

```text
User / control plane          (CLI, Zed / IDE, Agor-like UI, future Factory UI)
  -> Normalized session API   (acq)
  -> Harness adapter layer    (OpenCode, Goose, Claude Code, Gemini, Pi, ...)
  -> Environment / capability (kits + devenv)
  -> Sandbox control layer    (acq lifecycle, credentials, network, mounts)
  -> Backends                 (msb, sbx)
```

Today `acq` exposes two execution modes across the `Normalized session API ->
Harness adapter layer` boundary:

1. **`acq run` (`acq_backend_attach`)** — interactive human TUI session over a
   **PTY** (`msb exec -t` / `sbx run`).
2. **`acq exec` (`acq_backend_run`)** — raw one-shot command execution over
   non-interactive pipes (`msb exec` / `sbx exec` without `-t`).

Desktop editors and multi-agent orchestrators (such as Zed, JetBrains, Neovim,
and ACP-native clients) use the **Agent Client Protocol (ACP)**
(<https://agentclientprotocol.com/>): a newline-delimited JSON-RPC 2.0 protocol
over `stdin`/`stdout` (`stdio`). Coding harnesses supported by `acq` — notably
OpenCode (`opencode acp`) and Goose (`goose acp`) — implement ACP natively,
including session listing, resumption, forking, MCP transport, and client-side
human-in-the-loop permission prompts (`session/request_permission`).

However, an ACP client cannot invoke `acq run` directly, and wrapping `acq create`
+ `acq exec` externally is fragile for three reasons:

1. **PTY line-discipline corruption:** `acq run` allocates a PTY (`-t`), which
   translates `\n` to `\r\n`, echoes control characters, and injects terminal
   escape sequences into `stdout`, breaking JSON-RPC 2.0 framing.
2. **Prologue stdout contamination:** Provisioning, kit healing, and backend
   prepare steps must never emit a single non-JSON-RPC byte to `stdout` (`fd 1`)
   before the agent's ACP server takes over the stream.
3. **Interactive stdin deadlocks:** When an IDE spawns an ACP server, `stdin` is
   a JSON-RPC pipe rather than a human terminal. Any interactive prompt during
   create or re-attach (`acq configure` first-run picker, `acq github-scope`
   prompt, or stale-bundle refresh prompt) would either block indefinitely or
   consume JSON-RPC bytes from `stdin`.

## Decision Drivers

- **Keep the sandbox as the security boundary (`SC-7`, `AC-6`):** The IDE or UI
  client runs on the host while the coding agent and all tool executions run
  inside the `msb` or `sbx` sandbox. Provider credentials (`USAI_API_KEY`) and
  scoped repository tokens (`GITHUB_TOKEN`) stay bound to the sandbox's wire
  injector and never enter the host IDE's environment.
- **Zero-port transport by default (`CM-7`):** Bridging ACP over `stdio` via the
  backend's existing exec channel requires no published TCP ports, no host
  listeners, and no bearer-token management between host IDE and guest.
- **1:1 workspace path alignment:** Because `acq` mounts the primary workspace at
  the identical path inside the guest (`$ws`) and sets `-w "$ws"`, ACP `cwd` and
  `file://` URIs resolve across host and guest without path rewriting on macOS
  and Linux.
- **Preserve host-authoritative configuration ([ADR-0035](0035-host-authoritative-sandbox-config.md)):**
  ACP sessions must use the same host-authoritative config store and read-only
  provider-input projection as `acq run`.
- **Keep core `acq` bash 3.2 compatible with zero new runtime dependencies:**
  `acq` does not need to parse JSON-RPC itself if it acts as a stdout-clean
  lifecycle orchestrator that `exec`s the sandboxed agent's ACP entrypoint over
  `acq_backend_run`.

## Considered Options

1. **Require users to write custom host wrapper scripts around `acq create` +
   `acq exec`.** Rejected: every user must rediscover how to suppress prompts,
   redirect prologue output to `stderr`, derive sandbox names, heal stopped
   sandboxes on resume, and pass `--cwd`.
2. **Bridge ACP over a published TCP/HTTP port (`--publish`).** Rejected as the
   default: publishing a TCP port per editor window introduces port allocation
   management and local network exposure when ACP is natively designed for
   `stdio`. (TCP/HTTP remains available via opt-in kits like `openchamber` and
   `paseo` for browser UIs.)
3. **Add a first-class `acq acp` subcommand backed by `acq_backend_run` and
   agent-kit ACP entrypoint metadata.** Chosen.

## Decision Outcome

Chosen option: **Option 3 — add `acq acp` as a standard programmatic subcommand**.

### 1. CLI Surface

```text
acq acp [AGENT] [PATH ...] [--kit REF]... [--image REF] [--clone]
        [--no-provider-kits] [--no-update-check] [-- AGENT_ACP_ARGS...]
acq acp SANDBOX_NAME [-- AGENT_ACP_ARGS...]
```

When invoked with `AGENT PATH` (for example `acq acp opencode .`), `acq` creates
the sandbox if it does not yet exist, or resumes and heals it if it already
exists, then launches the agent's ACP server inside the sandbox over clean
`stdio`. When invoked with an existing `SANDBOX_NAME`, `acq` resumes/heals that
sandbox and launches its recorded agent's ACP server.

### 2. Four Normative Invariants of `acq acp`

1. **Stdout-Purity Gate (`fd 1` reserved for JSON-RPC):**
   During the entire `acq acp` prologue (backend preparation, workspace preflight,
   create-or-heal, provider key validation, and OpenCode postinstall check),
   `stdout` (`fd 1`) is redirected to `stderr` (`fd 2`). Original `stdout` is
   restored only for the final `acq_backend_run` invocation that streams the
   sandboxed agent's ACP server.
2. **Non-Interactive Fail-Closed Execution:**
   `acq acp` sets `ACQ_NO_PROMPT=1` and `ACQ_UPDATE_CHECK=0` before running any
   provisioning or re-attach step. Interactive pickers (`acq configure`,
   `create_time_kit_picker`, `advise_github_scope`, `maybe_offer_bundle_refresh`)
   never read from `stdin`. If a required provider credential is missing or
   invalid, `acq acp` fails closed with an actionable diagnostic on `stderr` and
   a non-zero exit status rather than prompting on `stdin`.
3. **Pipe-Clean Bidirectional Streaming Execution (No PTY):**
   `acq acp` sets `ACQ_SESSION_KIND="acp"` and invokes `acq_backend_run`
   (`msb exec --stream` / `sbx exec -i`, never `-t` / `acq_backend_attach`).
   On `msb`, `--stream` is required so `msb exec` streams `stdin`/`stdout`
   bidirectionally line-by-line without waiting for `stdin` EOF and without a
   PTY; on `sbx`, `-i` keeps `stdin` open without allocating a PTY. The command
   runs as the unprivileged `agent` user (`HOME=/home/agent`) in the recorded
   workspace (`-w "$ws"`, `ACQ_WORKSPACE="$ws"`) with forwarded `SSH_AUTH_SOCK`,
   host git identity, and kit `environment[]` applied.
4. **Agent ACP Entrypoint Resolution:**
   `acq.backends/agents.sh` defines `acq_agent_kit_acp_entrypoint` (and
   `acq.backends/common.sh` defines `acq_build_acp_argv`), mapping `opencode`
   to `opencode acp` (with the working directory set via `acq_backend_run`'s
   `-w "$ws"`, matching OpenCode v2's `opencode acp` CLI contract) and other
   ACP-capable agents to `<agent> acp`. Passing `shell` to `acq acp` is rejected
   with usage exit 2 because an interactive shell is not an ACP server.
   Additional arguments after `--` are appended to the default ACP command (if
   they begin with `-`) or treated as an explicit command override inside the
   sandbox (matching `acq run`'s post-`--` escape semantics).

### 3. Session Persistence and Memory Caching

Because OpenCode's ACP server advertises `loadSession: true` and
`sessionCapabilities: { list, resume, fork, close }`, sessions created through
`acq acp` are persisted in `/home/agent/.local/share/opencode/opencode.db` inside
the sandbox:

- **Across IDE restarts and `acq stop` / `acq start`:** Session state persists
  automatically in the sandbox's root filesystem (or on a dedicated ext4 disk
  when paired with a kit declaring `volumes:` per [ADR-0023](0023-neutral-volumes-kit-vocabulary.md)).
- **Hot in-memory caching:** When paired with a background `opencode serve`
  process in the sandbox (or while the `msb` microVM remains running), the
  guest's filesystem page cache and SQLite WAL stay warm in microVM RAM across
  ACP client reconnects.

## Consequences

### Positive Consequences

- Any ACP-compatible editor or orchestrator (such as Zed via `agent_servers`)
  can launch a federally configured, sandboxed agent with a single `acq acp
  opencode .` command.
- Secrets remain isolated to the sandbox wire injector (`USAI_API_KEY` and
  per-sandbox `GITHUB_TOKEN` never enter the host IDE).
- Both `msb` and `sbx` backends are supported with identical CLI syntax.

### Negative Consequences

- Because `acq acp` runs non-interactively (`ACQ_NO_PROMPT=1`), users must store
  their provider credential (`acq secret set -g usai`) at least once in a
  terminal before launching a brand-new sandbox from a headless IDE. `acq acp`
  surfaces this exact recovery command on `stderr` when the key is missing.

### Compliance Consequences

- **AC-6 / SC-7:** Enforces least privilege and boundary protection between the
  host IDE UI and the sandboxed agent execution environment.
- **CM-5:** Human-in-the-loop tool approvals (`ask` rules in the OpenCode
  permission policy) flow natively through ACP's `session/request_permission`
  RPC to the host IDE.
- **SI-10:** Agent tokens and post-`--` arguments are validated before reaching
  backend exec argv.

## Validation

- `scripts/run-shellcheck` clean across `acq`, `acq.backends/*.sh`, and
  `test/bats/*.bats`.
- Offline Bats tests in `test/bats/30-dispatch-routing.bats`,
  `test/bats/36-agent-catalog.bats`, and `test/bats/60-help.bats` verify:
  - `acq acp --help` and `acq help` documentation.
  - `acq acp opencode <workspace>` provisions if missing, emits zero prologue
    bytes on `stdout`, and dispatches `msb exec` / `sbx exec` (without `-t`)
    running `opencode acp --cwd <workspace>`.
  - `acq acp <sandbox>` heals an existing sandbox and launches the recorded
    agent's ACP server.
  - `acq acp shell <workspace>` fails closed with exit status 2.
