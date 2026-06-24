---
title: "Orchestration Options: Single Pane of Glass for Worktrees, Sandboxes, Agents, Sessions"
description: "Options analysis for managing multiple AI coding agents across worktrees and SBX sandboxes from one control plane"
status: informational
tier: 2
last_updated: "2026-06-24"
audience: "developers"
keywords: ["orchestration", "single-pane-of-glass", "worktree", "sandbox", "sbx", "multiplexing", "dashboard", "agents"]
related_files: ["docs/QUICKSTART_SBX.md", "AGENTS.md", "docs/adr/0004-playbook-submodule-shared-config.md"]
---

# Orchestration Options: A Single Pane of Glass

> **Status:** Informational / options analysis. **This document records no decision.**
> Adopting any tool, or adding any new service, is an ADR-gated and approval-required
> action per `AGENTS.md` (the next ADR would be `0005`).

This document maps the conceptual layers involved in managing multiple AI coding
agents — **worktrees → sandboxes → agents → sessions** — and surveys existing
"single pane of glass" tools against the constraints of this repository (SBX +
USAi + federal rules in `AGENTS.md`).

---

## Problem Statement

We want to run and supervise several coding agents at once without juggling six
terminal tabs. Concretely, the goals are:

| Goal | What it means |
|------|---------------|
| **Visibility / observability** | See every running agent, session, and its status in one place |
| **Orchestration / control** | Start, stop, route, and assign work from one interface |
| **Lifecycle management** | Create/destroy worktrees + sandboxes, manage pairing and cleanup |
| **Multiplexing parallel agents** | Run many agents on different tasks/branches and review their output |
| **Governance / audit** | Track what each agent did; enforce approval gates; traceability |

**Hard constraint:** the solution must run **local-only and SBX-native**. Per
`AGENTS.md`, all agent execution against USAi occurs inside SBX sandboxes; no
new hosted control plane, no bypassing SBX, no exposing secrets.

---

## The `qsbx` Baseline (Evaluation Criteria)

Whatever sits on top must not lose what `qsbx` already provides. `qsbx` exists
to deliver **two non-negotiable values**:

1. **Global agent config reaches the agent inside the sandbox.** `qsbx` symlinks
   the shared `AGENTS.md` and skills into the home locations OpenCode searches
   (`~/.config/opencode/AGENTS.md`, `~/.agents/skills`), so federal agent rules
   and skills apply in every sandbox.
2. **`opencode.jsonc` is mounted and used to reach USAi.** `qsbx` mounts this
   clone and symlinks `~/.config/opencode/opencode.jsonc`, which carries the USAi
   provider, `baseURL`, and API-key wiring.

> Any candidate L5 tool is scored on whether it **preserves these two values**,
> and whether it offers a **better mechanism** for them. We are open to changing
> `qsbx` if a tool does this more cleanly.

---

## Conceptual Layers

```
                         ┌──────────────────────────────────────────────┐
   L5  CONTROL PLANE     │   "Single pane of glass"                      │
       (single pane      │   visibility · orchestration · multiplexing   │
        of glass)        │   TUI / desktop GUI / local web dashboard     │
                         └───────────────────────┬──────────────────────┘
                                                 │ shells out to / drives
                         ┌───────────────────────┴──────────────────────┐
   L4  SESSION           │   Agent conversation: prompts, tool calls,    │
       (+ governance)    │   compaction, resume. Audit trail, HITL gates │
                         └───────────────────────┬──────────────────────┘
                                                 │ runs inside
                         ┌───────────────────────┴──────────────────────┐
   L3  AGENT             │   opencode / claude / codex / gemini ...      │
                         │   one agent per sandbox                       │
                         └───────────────────────┬──────────────────────┘
                                                 │ executes within
                         ┌───────────────────────┴──────────────────────┐
   L2  SANDBOX           │   SBX microVM (via qsbx / sbx)                │
       (security         │   own FS · own Docker · network policy        │
        boundary)        │   << THE SECURITY BOUNDARY >>                 │
                         └───────────────────────┬──────────────────────┘
                                                 │ bound to one
                         ┌───────────────────────┴──────────────────────┐
   L1  ISOLATION UNIT    │   git worktree   OR   SBX --clone             │
                         │   (one branch / one working tree per task)    │
                         └───────────────────────┬──────────────────────┘
                                                 │ derived from
                         ┌───────────────────────┴──────────────────────┐
   L0  REPOSITORY        │   git repo + branches                         │
                         └──────────────────────────────────────────────┘
```

The layers are not all owned by the same tool. Some surveyed tools are **L5
dashboards**; others are **L4 governance/workflow engines** that can sit *under*
or *beside* an L5 UI.

---

## L1 Deep-Dive: git worktree vs SBX `--clone`

The repo currently has **no git-worktree usage**; branch isolation is done with
SBX `--clone`. Most surveyed dashboards are worktree-native, so this layer is
where adoption friction is highest.

| Aspect | git worktree | SBX `--clone` |
|--------|--------------|---------------|
| What it is | Extra working tree on the host, one per branch | In-container clone exposed as host git remote `sandbox-<name>` |
| Isolation strength | Filesystem only; shares host | Full microVM (own FS/Docker/network) |
| Host footprint | One directory per task on host | Lives inside the sandbox |
| Fit with SBX boundary | Needs mounting into a sandbox to gain isolation | Already inside the boundary |
| Cleanup | `git worktree remove` + dir delete | `sbx rm` removes clone + remote |
| Data-loss risk | Low | Must `git fetch sandbox-<name>` before removal |
| Tooling support | BiomeLab, Hive, dmux, agor, vigilante, ccswarm | Native to this repo / SBX |

A hybrid is possible: create a **git worktree on the host** and **mount it into a
sandbox** (`sbx` supports extra workspace mounts; `qsbx` already mounts the clone
`:ro`). This is the bridge most worktree-native dashboards would need to stay
SBX-native here.

---

## L5 Options (A / B / C) — No Decision

### Option A — Thin local TUI over `qsbx` / `sbx`
A terminal UI that shells out to existing commands (`qsbx run`, `sbx ls`,
`sbx exec`, `sbx stop`). Minimal new surface; trivially preserves the qsbx
baseline because it *is* qsbx. Lowest risk, least features.

### Option B — Localhost daemon + web UI aggregating OpenCode servers
A `127.0.0.1`-bound daemon that talks to one or more OpenCode servers (OpenCode
exposes a server on `4096`; see the commented `server` block in
`opencode/opencode.jsonc`). Richer UI, but introduces a service layer and a
network surface to scrutinize against `AGENTS.md`. Tends to bind the experience
to OpenCode.

### Option C — Adopt an existing tool behind a security gate
Pick one of the surveyed tools and wrap/configure it to stay SBX-native and
honor the qsbx baseline. Fastest to capability; requires an ADR, a security
review of its network/secrets behavior, and a plan for the qsbx two values.

---

## Tool Comparison

Grounded in each project's README (fetched 2026-06-24). "qsbx values?" asks
whether the tool can preserve global-config injection **and** the USAi-via-
`opencode.jsonc` path — most need `qsbx`/SBX underneath to do so.

| Tool | Stack | Local vs server | Network surface | Worktree-aware | SBX/sandbox-aware | Agent-agnostic? | Governance / audit | License | qsbx values? |
|------|-------|-----------------|-----------------|----------------|-------------------|-----------------|--------------------|---------|--------------|
| **BiomeLab** | Go / Fyne desktop | Local desktop app | Local; `gh`/`glab` API | Yes | **Yes — native `sbx` mode**, one sandbox/agent/repo | **Yes** (detects Claude/Kiro/Copilot/Codex/OpenCode/Gemini) | re_gent (`rgt`) activity log, export JSON | MIT | Best fit — already SBX-native; could host qsbx injection (open Q) |
| **Hive** | Electron / React | Local desktop app | Localhost Effect backend (free port) | Yes | No | Partial (OpenCode/Claude/Codex sessions) | Undo/redo; visual git | MIT | Needs SBX underneath; no sandbox layer |
| **OpenChamber** | TypeScript; desktop/web/PWA | Local **or** server + tunnels | Cloudflare tunnels, LAN bind options — **scrutinize** | Yes (isolated worktrees for multi-agent runs) | No | **OpenCode-only** | Token/cost panels; git/PR in-app | MIT | OpenCode-bound; tunnel/LAN surface conflicts with network rules |
| **dmux** | Node / tmux | Local TUI | Local; optional OpenRouter for names | Yes (worktree per pane) | No | **Yes** (11+ CLIs incl. OpenCode) | Lifecycle hooks; native notifications | MIT | Needs SBX underneath; optional OpenRouter call to flag |
| **vigilante** | Go | Local daemon/service | `gh` API; planned Docker mode | Yes (worktree per issue) | Planned (containerized mode in `SANDBOX.md`) | **Yes** (codex/claude/gemini/opencode) | Issue→PR trail, resume/redispatch/cleanup; "untrusted model" posture | Apache-2.0 | Issue-driven, not a dashboard; SBX support is future |
| **agor** | TS / FeathersJS daemon + React | **Self-hosted server + web UI** | Web UI, WebSocket, MCP endpoint, multiplayer | Yes (branches = worktrees under `~/.agor/`) | No (progressive **Unix** isolation, not containers) | **Yes** (Claude/Codex/Gemini/OpenCode/Copilot/Cursor) | RBAC/ACLs, per-prompt token+cost, durable history, MCP | **BSL 1.1 — flag** | Web/daemon surface + non-CC0 license conflict with constraints |
| **ccswarm** | Rust | Local CLI engine | `gh` (issue ingest) | Yes (Claude `--worktree`) | No | Partial (claude/codex; copilot unsupported for codegen) | **NDJSON audit, replay/diff/undo, HITL gates, sensitive-path deny-list** | MIT | L4 engine, not L5 UI; pairs with audit/approval rules |

> **Agent-agnostic note (your OpenCode concern):** OpenChamber and Hive are
> OpenCode/Claude/Codex-bound (OpenChamber the most). BiomeLab, dmux, vigilante,
> agor, and ccswarm are broadly agent-agnostic — they detect or launch many CLIs
> rather than embedding one runtime.

### Where each tool sits
- **L5 dashboards:** BiomeLab, Hive, OpenChamber, agor, dmux (TUI).
- **L4 governance / workflow engines:** ccswarm, vigilante (issue→PR orchestrators
  with audit + approval gates) — these can run *under* or *beside* an L5 UI.

---

## BiomeLab as a Pilot Candidate

> **Candidate, not a decision.** Recorded here for a future ADR/spike.

BiomeLab is the strongest architectural fit because it is the only surveyed tool
that is **already SBX-native** (its recommended mode is one `sbx` sandbox per
agent per repo) **and** agent-agnostic (it detects Claude/Kiro/Copilot/Codex/
OpenCode/Gemini rather than embedding one runtime). It also ships a desktop
dashboard, PR/MR status, per-worktree notes mounted into the sandbox, a
dependency-status panel for `gh`/`glab`/`sbx`/`rgt`, and a `re_gent` audit trail.

A pilot would test:

- **Does it preserve the qsbx baseline?** Specifically, can BiomeLab's sandbox
  creation carry (a) the global `AGENTS.md` + skills injection and (b) the
  `opencode.jsonc`/USAi wiring — via its `--kit` mechanism and/or its
  worktree-mount behavior — or does `qsbx` need to wrap/feed BiomeLab? **(Open
  research question; not investigated here.)**
- **Network/secrets posture** under `AGENTS.md` (it calls `gh`/`glab` APIs).
- **Worktree ↔ SBX `--clone`** reconciliation at L1.

Independently of which L5 UI is chosen, **ccswarm's governance model** (NDJSON
audit trails with replay/diff/undo, HITL approval gates, sensitive-path
deny-list) is worth evaluating against the audit and approval requirements in
`AGENTS.md`.

---

## Constraints & Open Questions

**Constraints (from `AGENTS.md`):**
- Local-only, SBX-native; no bypassing SBX for convenience.
- No secrets exposure; no new network listeners/reverse connections.
- Network egress limited to the approved endpoints; scrutinize any tool that
  opens tunnels (OpenChamber Cloudflare modes), binds LAN (OpenChamber, agor),
  or makes third-party calls (dmux → OpenRouter for branch names).
- Dependencies require approval; no AGPL, GPL needs justification, exact pins.
  **agor is BSL 1.1** — non-CC0 and source-available-with-restrictions; flag for
  licensing review.

**Open questions:**
1. Can BiomeLab's `--kit` / mount mechanism absorb qsbx's two values, or does
   qsbx wrap BiomeLab?
2. L1 reconciliation: standardize on git worktrees mounted into sandboxes, keep
   SBX `--clone`, or support both per-task?
3. Is a governance/audit engine (ccswarm-style) needed as a distinct L4 layer for
   federal traceability, separate from the L5 UI?
4. For any adopted tool/service: which ADR (`0005`) and which security review?

**Next steps:** choose a direction among A/B/C, then open ADR `0005` before
adopting any dependency or standing up any service.

---

## References

- `docs/QUICKSTART_SBX.md` — sbx lifecycle, mounts, `--clone`, multiple workspaces
- `AGENTS.md` — network, secrets, and approval rules
- `docs/adr/0004-playbook-submodule-shared-config.md` — how shared config reaches the sandbox
- Tools: BiomeLab `github.com/mdelapenya/biomelab` (MIT) · Hive `github.com/morapelker/hive` (MIT) ·
  OpenChamber `github.com/openchamber/openchamber` (MIT) · dmux `github.com/standardagents/dmux` (MIT) ·
  vigilante `github.com/aliengiraffe/vigilante` (Apache-2.0) · agor `github.com/preset-io/agor` (BSL 1.1) ·
  ccswarm `github.com/nwiizo/ccswarm` (MIT)
</content>
</invoke>
