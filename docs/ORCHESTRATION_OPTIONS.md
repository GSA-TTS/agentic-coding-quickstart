---
title: "Orchestration Options: Single Pane of Glass for Worktrees, Sandboxes, Agents, Sessions"
description: "Options analysis for managing multiple AI coding agents across worktrees and SBX sandboxes from one control plane, including non-SBX L2 runtimes and SBX shimming"
status: informational
tier: 2
last_updated: "2026-06-24"
audience: "developers"
keywords: ["orchestration", "single-pane-of-glass", "worktree", "sandbox", "sbx", "openshell", "shim", "multiplexing", "dashboard", "agents"]
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
   L2  ISOLATION /       │   SBX microVM (DEFAULT, via qsbx / sbx)       │
       EXECUTION         │   own FS · own Docker · network policy        │
       BOUNDARY          │   alt: container · Unix-user · worktree-only  │
                         │   << THE SECURITY BOUNDARY — SBX is strongest>>│
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
or *beside* an L5 UI. **L2 is deliberately generalized**: SBX microVM is this
repo's default and the strongest boundary, but the section
[Native Isolation, Independent of SBX](#native-isolation-independent-of-sbx)
surveys the weaker alternatives the surveyed tools ship with.

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

## Native Isolation, Independent of SBX

Because the question "what if we used something other than SBX at L2?" is worth
answering, this section records what execution isolation each tool ships with
**on its own**, independent of Docker SBX. The short answer: **of the
orchestrators, none provides a boundary as strong as an SBX microVM**, and most
provide no execution containment at all. The exception is a *dedicated* L2
runtime — **NVIDIA OpenShell** — which is a peer of SBX, not an orchestrator.

**Isolation-strength spectrum (strongest → weakest):**

```
microVM / policy-driven container     container-per-session    Unix-user + sudo        worktree-only
(SBX default; OpenShell)              (vigilante, PLANNED)     (agor strict/insulated)  / none
   ▼                                      ▼                         ▼                       ▼
own kernel, FS, Docker,               shared host kernel,      shared host kernel,     no containment;
network policy; OpenShell adds        scoped creds, TTL        per-user FS perms,      filesystem
L7 egress + inference routing         teardown, gh proxy       needs root/sudoers      separation only
```

| Tool | Native isolation mechanism | Built-in? | Privilege footprint | Beyond worktrees? |
|------|----------------------------|-----------|---------------------|-------------------|
| **SBX (qsbx)** | microVM — own kernel/FS/Docker/network policy | This repo's default | Unprivileged host CLI | ✅ Strongest |
| **OpenShell** (L2 runtime, not an orchestrator) | Per-sandbox container/**microVM** via pluggable drivers (Docker/Podman/MicroVM/k8s) + declarative YAML policy across FS/network/process/inference; L7 egress proxy; credential injection as env (never on disk) | Shipping (**alpha**) | Gateway control-plane + container/VM runtime | ✅ Peer of SBX |
| **BiomeLab** | None of its own — **wraps `sbx`** (`internal/sandbox/sandbox.go`) | Delegates to SBX | Inherits SBX | ✅ via SBX |
| **vigilante** | **Planned** Docker-per-session: DinD, `gh` mirror→reverse-proxy repo scoping, HMAC short-lived tokens, ephemeral deploy keys, guaranteed TTL teardown (`SANDBOX.md`) | Planned, not shipped | Docker daemon access | ✅ (when built) |
| **agor** | Unix users/groups + `sudo` impersonation (`simple`/`insulated`/`strict`); **plus a shipping `executor_command_template` shim** — a pivot point that wraps *every* agent/git op (agor uses it for k8s pods; could wrap `sbx`) | Opt-in; `simple` = none; template = configurable runtime | **Root** for Unix mode; template runtime sets its own | ✅ Unix mode, **or any runtime via the executor template** |
| **AoE** | **Native Docker sandbox** (`docker exec -it <container> <tool>`; Podman/Apple Containers too), worktree→`/workspace`, auth dirs mounted, creds via env | Opt-in (`--sandbox`) | Docker daemon access | ✅ container-level |
| **Hive** | git worktrees only (containers are roadmap "Future Vision") | Built-in | None | ❌ |
| **OpenChamber** | git worktrees; Docker only for *deployment*, not per-agent | Built-in | None | ❌ |
| **dmux** | git worktrees + tmux panes | Built-in | None | ❌ |
| **ccswarm** | git worktrees + sensitive-path deny-list ("sandboxed execution" claim unbacked by any named tech) | Built-in | None | ❌ |

**Genuine non-SBX L2 alternatives, with caveats:**

- **NVIDIA OpenShell** is the strongest non-SBX L2 candidate found — a *dedicated
  sandbox runtime*, not an orchestrator. It isolates each sandbox in a
  container/**microVM** (pluggable Docker/Podman/MicroVM/k8s drivers), enforces a
  declarative YAML policy across **filesystem, network, process, and inference**
  (network/inference hot-reloadable), runs an **L7 egress proxy** (allow/deny per
  HTTP method+path), injects credentials as **env vars that never touch the
  sandbox filesystem**, and launches agents with the same UX as SBX
  (`openshell sandbox create -- claude|opencode|codex|copilot`). Its **Privacy
  Router** can strip caller creds and reroute model calls to a controlled
  backend — conceptually aligned with forcing all traffic through USAi. Caveats:
  **alpha / "single-player" / NVIDIA-led**, a heavier **gateway + driver**
  architecture than SBX's single CLI, and an inference model that assumes
  OpenAI/Anthropic-style provider env (USAi `baseURL` fit unverified). Apache-2.0.
  Adopting it would be an **SBX *replacement* at L2** — a much larger decision
  than adding an orchestrator, squarely ADR-`0005` territory.
- **vigilante's `SANDBOX.md`** is the closest *orchestrator-native* peer to SBX's
  posture: a container per session, a `gh` **mirror binary → reverse proxy** that
  scopes GitHub access to a single repo, HMAC-signed short-lived tokens, ephemeral
  deploy keys, and guaranteed TTL teardown. It is **planned, not shipped**, but
  the credential-scoping pattern is worth studying even if we stay on SBX — it
  complements the USAi/secret rules in `AGENTS.md`.
- **AoE's native Docker sandbox** is real and shipping: host tmux runs
  `docker exec -it <container> <tool>`, mounts the worktree at `/workspace`, and
  injects secrets via env (never argv). It is container-level (shared host
  kernel), Docker-only as composed (the `docker exec` call is hardcoded Rust, not
  a swappable driver), so it is not an SBX substitute — but it shows the
  orchestrator already expects a sandbox in the launch path.
- **agor's Unix-user model** is genuine OS-level isolation, but it is built for a
  **shared multi-user server** (Linux + systemd + PostgreSQL, private network)
  and requires a **root-privileged daemon** (`sudoers` granting `useradd`,
  `groupadd`, `chown`). Its threat model explicitly allows a malicious prompt to
  *"damage own files"* — it isolates *users from each other*, not the *agent from
  the host*. This cuts against `AGENTS.md` ("SBX is the security boundary", no
  privilege escalation) and the local-only constraint. See
  [agor's deployment model](#agor-local-vs-shared-server) below. **But agor also
  exposes a designed L2 shim — its `executor_command_template`** — which is a
  better fit for our purposes than its Unix mode; see
  [agor's executor template](#agor-executor-template) below.

> **Lima / nono:** specifically checked for and **found in none** of the surveyed
> *orchestrators*. No orchestrator uses Lima (lima-vm), nono, Firecracker, or
> gVisor — though AoE's docs do reference `nono` as an example sandbox *wrapper*
> for its command-override (see
> [Shimming SBX into non-isolating tools](#shimming-sbx-into-non-isolating-tools)).
> As dedicated L2 runtimes, **OpenShell** (above) and **nono** remain candidates a
> future ADR (`0005`) could weigh as SBX alternatives or complements at L2.

<a id="agor-local-vs-shared-server"></a>
### agor: local single-dev vs shared-server multi-user

agor **can** run locally for a single user — `npm install -g agor-live`,
`agor init`, `agor daemon start`, `agor open`, no sudo or PostgreSQL required
(`unix_user_mode: simple` and `branch_rbac: false` are the defaults, on SQLite).
But two facts hold in **either** deployment mode, and one tradeoff is inherent:

- **Local-mode caveat:** in `simple` mode there is **no execution isolation** —
  agents run as the daemon user on the host, exactly like Hive/dmux/OpenChamber.
  So used locally, agor still needs SBX underneath for a real boundary.
- **You cannot get agor's isolation without its server/privilege model.** The
  Unix-user containment only activates in `insulated`/`strict`, which require the
  root-privileged sudoers setup and target a shared server.
- **Always-on regardless of mode:** a persistent localhost **daemon + WebSocket +
  MCP HTTP endpoint** (a service/network surface to weigh against `AGENTS.md`).
  Its **BSL 1.1** license is **not** a blocker here — BSL only restricts using
  agor to offer a competing *hosted service* (e.g. agor.live's enterprise
  offering); internal/self-hosted use as a dev tool is permitted.

Net: agor's distinctive value (RBAC, per-user credential isolation, cost
accounting) is a **governance** story that only unlocks in the privileged
shared-server model; locally it is "another dashboard that still needs SBX" —
**unless** you use its executor-template shim (next).

<a id="agor-executor-template"></a>
### agor's executor template: a shipping L2-runtime shim

agor consolidates *all* isolated operations (agent prompts, git clone/branch,
terminals) behind a single **executor** process, and the daemon spawns that
executor through an admin-configurable **`executor_command_template`**. The
default is a local subprocess; a template string lets the admin wrap the spawn in
*any* runtime. agor's own user-facing docs use it to run each executor in an
ephemeral **k8s pod** (`kubectl run … -- agor-executor --stdin`).

**This is shipping, not aspirational.** Verified on `main` (commit `21edf7b`,
2026-06-24): the daemon reads `config.execution.executor_command_template`
(`apps/agor-daemon/src/index.ts` → `configureExecutor`), and `spawnExecutor`
branches between `spawnExecutorWithTemplate` and `spawnExecutorLocal`
(`apps/agor-daemon/src/utils/spawn-executor.ts`). The template is rendered and run
via `spawn('sh', ['-c', command])`, the JSON payload is written to the child's
stdin (`agor-executor --stdin`), and tests assert the k8s template renders
(`spawn-executor.configured.test.ts`). There is a typed config field
(`AgorExecutionSettings.executor_command_template`) and a dedicated user-facing
guide (`apps/agor-docs/pages/guide/containerized-execution.mdx`), separate from
the original exploration doc.

```yaml
# ~/.agor/config.yaml  (shipping config key)
execution:
  executor_command_template: |        # null/unset = local subprocess
    kubectl run executor-{task_id} --image=agor/executor:latest \
      --rm -i --restart=Never --overrides='{...}' -- agor-executor --stdin
```

Why this matters for SBX:

- **It is a clean L2-runtime seam at the *orchestrator* layer**, not the agent
  layer. Where the [shim section](#shimming-sbx-into-non-isolating-tools) wraps a
  per-agent launch, agor's template wraps the executor that performs the work —
  so a template like `sbx exec <sandbox> -- agor-executor --stdin` (or a
  qsbx-prepared equivalent) would route agor's execution through SBX **using a
  first-class, supported config knob**, no forking required.
- **The payload is JSON-over-stdin** (the executor reads `dataHome`, `env`, `cwd`,
  etc. from the payload, not ambient environment) — exactly what a sandbox
  boundary wants, since the runtime need not inherit host env.
- It is consistent with agor's trust model (executor = isolation boundary; daemon
  never touches the data filesystem), so layering SBX *reinforces* their design
  rather than fighting it.

Caveats / integration unknowns (about *fit*, not *existence*):

- **No path/worktree template variable.** The implemented substitution
  (`substituteTemplateVariables`) supports only `{task_id}`, `{command}`,
  `{unix_user}`, `{unix_user_uid}`, `{unix_user_gid}`, `{session_id}`,
  `{branch_id}`, `{log_level}` — **no `{cwd}`/`{worktree_path}`/`{data_home}`**.
  (The docs page also advertises `{repo_gid}`/`{branch_gid}`/etc. that the code
  does **not** implement — a docs-vs-code drift to be aware of.) So mounting a
  per-branch worktree into an `sbx` invocation isn't a template variable; agor's
  own k8s approach instead mounts the whole `data_home` PVC and keys off
  `{branch_id}`/`{session_id}`. Reconciling that with SBX per-worktree mounts (and
  carrying the [qsbx two values](#shimming-sbx-into-non-isolating-tools) inside)
  is the real integration work.
- **Daemon egress hop.** The `prompt` command expects the executor to reach the
  daemon over a Feathers WebSocket, so a sandboxed executor must still be allowed
  that one connection.
- agor's daemon/MCP network surface still applies regardless of executor runtime;
  its **BSL 1.1** license does **not** block this use (see
  [above](#agor-local-vs-shared-server)).

> **Reframing:** agor offers **two** isolation stories. Its *Unix-user* mode is a
> poor fit (root-privileged, shared-server). But its *executor-template* shim is a
> genuinely good fit — and a **shipping, tested** config knob, arguably the
> cleanest orchestrator-level seam surveyed for dropping in SBX/OpenShell/`nono`
> at L2, because the tool was explicitly designed to swap its execution runtime.
> Pilot-worthy; the remaining work is worktree-mount + qsbx-injection integration,
> not waiting on a feature to land.

---

## Tool Comparison

Grounded in each project's README and source (fetched 2026-06-24). "qsbx
values?" asks whether the tool can preserve global-config injection **and** the
USAi-via-`opencode.jsonc` path — most need `qsbx`/SBX underneath to do so.
OpenShell is listed for completeness as an **L2 runtime** (an SBX peer), not an
orchestrator, so its dashboard/governance columns read "n/a".

| Tool | Stack | Local vs server | Network surface | Worktree-aware | Native isolation tech | Agent-agnostic? | Governance / audit | License | qsbx values? |
|------|-------|-----------------|-----------------|----------------|-----------------------|-----------------|--------------------|---------|--------------|
| **BiomeLab** | Go / Fyne desktop | Local desktop app | Local; `gh`/`glab` API | Yes | **Wraps `sbx` microVM** (one sandbox/agent/repo) | **Yes** (detects Claude/Kiro/Copilot/Codex/OpenCode/Gemini) | re_gent (`rgt`) activity log, export JSON | MIT | Best fit — already SBX-native; could host qsbx injection (open Q) |
| **AoE** | Rust TUI + web/PWA | Local; optional remote (Tailscale/Cloudflare tunnel) | tmux local; tunnel + HTTPS when remote — **scrutinize** | Yes (worktree per session) | **Native Docker** (`docker exec -it`); not SBX | **Yes** (13+ CLIs incl. OpenCode) | Status detection; diff view; HTTP API | MIT | `--cmd-override` can inject `sbx exec` — clean shim seam |
| **Hive** | Electron / React | Local desktop app | Localhost Effect backend (free port) | Yes | Worktree-only (containers on roadmap) | Partial (OpenCode/Claude/Codex sessions) | Undo/redo; visual git | MIT | Needs SBX underneath; no sandbox layer |
| **OpenChamber** | TypeScript; desktop/web/PWA | Local **or** server + tunnels | Cloudflare tunnels, LAN bind options — **scrutinize** | Yes (isolated worktrees for multi-agent runs) | Worktree-only (Docker = deploy only) | **OpenCode-only** | Token/cost panels; git/PR in-app | MIT | OpenCode-bound; tunnel/LAN surface conflicts with network rules |
| **dmux** | Node / tmux | Local TUI | Local; optional OpenRouter for names | Yes (worktree per pane) | Worktree + tmux panes | **Yes** (11+ CLIs incl. OpenCode) | Lifecycle hooks; native notifications | MIT | Needs SBX underneath; optional OpenRouter call to flag |
| **vigilante** | Go | Local daemon/service | `gh` API; planned Docker mode | Yes (worktree per issue) | **Planned** container-per-session (gh reverse-proxy, TTL teardown — `SANDBOX.md`) | **Yes** (codex/claude/gemini/opencode) | Issue→PR trail, resume/redispatch/cleanup; "untrusted model" posture | Apache-2.0 | Issue-driven, not a dashboard; SBX support is future |
| **agor** | TS / FeathersJS daemon + React | Local (simple) **or** shared server (RBAC) | Localhost daemon, WebSocket, MCP endpoint; multiplayer when on server | Yes (branches = worktrees under `~/.agor/`) | Unix-user + `sudo`; **plus `executor_command_template`** (designed L2 shim — wrap executor in `sbx`/k8s/etc.) | **Yes** (Claude/Codex/Gemini/OpenCode/Copilot/Cursor) | RBAC/ACLs, per-prompt token+cost, durable history, MCP | BSL 1.1 (self-host OK) | Executor template can route execution through `sbx` (cleanest orchestrator-level seam); daemon/MCP surface to weigh |
| **ccswarm** | Rust | Local CLI engine | `gh` (issue ingest) | Yes (Claude `--worktree`) | Worktree + sensitive-path deny-list (no real sandbox) | Partial (claude/codex; copilot unsupported for codegen) | **NDJSON audit, replay/diff/undo, HITL gates, sensitive-path deny-list** | MIT | L4 engine, not L5 UI; pairs with audit/approval rules |
| **OpenShell** *(L2 runtime, not an orchestrator)* | Rust; gateway + driver | Local gateway; k8s/Helm option | **L7 egress proxy** (allow/deny per method+path); inference router | n/a (isolates whatever you run) | **microVM/container** + YAML policy (FS/net/process/inference) | **Yes** (`-- claude\|opencode\|codex\|copilot`; BYOC) | Policy decisions logged; k9s-style TUI | Apache-2.0 | An **SBX replacement** at L2, not a layer on top; would own USAi routing via its inference router (fit unverified) |

> **Agent-agnostic note (your OpenCode concern):** OpenChamber and Hive are
> OpenCode/Claude/Codex-bound (OpenChamber the most). BiomeLab, AoE, dmux,
> vigilante, agor, and ccswarm are broadly agent-agnostic — they detect or launch
> many CLIs rather than embedding one runtime. OpenShell (L2) is agent-agnostic by
> construction: it sandboxes whatever agent you launch inside it.

### Where each tool sits
- **L2 isolation runtimes (SBX peers):** SBX/qsbx (default), **OpenShell** (alpha).
- **L5 dashboards:** BiomeLab, Hive, OpenChamber, agor, dmux (TUI), **AoE** (TUI + web).
- **L4 governance / workflow engines:** ccswarm, vigilante (issue→PR orchestrators
  with audit + approval gates) — these can run *under* or *beside* an L5 UI.

A second, more decision-relevant axis is **deployment model**, because that is
where the local-only constraint bites harder than the L4/L5 line:

- **Local, single-developer:** BiomeLab, Hive, OpenChamber (local mode), dmux,
  ccswarm, vigilante, AoE (local TUI), **and agor in `simple` mode**.
- **Shared-server, multi-user:** **agor** with RBAC + Unix isolation
  (`insulated`/`strict`) — the only surveyed tool whose distinctive value assumes
  a team sharing one privileged server. agor spans L4+L5 (rich dashboard *and*
  governance), so it is kept in the L5 list above; its real misfit is this
  deployment axis, not its layer.

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

## Shimming SBX into Non-Isolating Tools

Most orchestrators above provide no execution boundary of their own. Rather than
wait for each to add native SBX support, we can **inject `sbx` at the point where
the orchestrator launches the agent** — a "shim." Whether that is possible, and
how cleanly, depends entirely on *how* each tool spawns the agent. Source review
(2026-06-24) found three *agent-launch* seam types, plus a fourth
*orchestrator-level* seam (agor's executor template).

### The three seam types

**(a) Explicit command / wrapper config — orchestrator *knowingly* calls the shim.**
The tool exposes a configurable agent command, so we point it at a wrapper (or an
`sbx exec …` string) directly. This is auditable and robust: the tool validates
and invokes exactly what we configured.

- **AoE** — per-agent `agent_command_override` (`aoe add --cmd-override …`),
  layered session→repo→profile→global, plus a `custom_agents` map; the override
  runs through a shell. AoE's own docs already show a *sandbox wrapper* of this
  exact shape: `opencode = nono run --profile opencode-dev --allow-cwd -- opencode`.
  Swap `nono …` for `sbx exec …` (or a qsbx-prepared wrapper) and AoE is sandboxed
  without code changes. AoE's PATH pre-check validates the *resolved wrapper*, so
  the bare agent need not even be on PATH.
- **Hive (Claude path)** — spawns a PTY subprocess with
  `command: claudeBinary || 'claude'`, `cwd = worktree`; `claudeBinary` is an
  explicit override (there is a `claude-binary-resolver`). Point it at a wrapper.

**(b) PATH override — orchestrator *unknowingly* sandboxed.**
The tool launches a bare binary name resolved via `$PATH`, with no command-config
knob. We place a shim script named `claude` / `opencode` / etc. earlier on `$PATH`
that re-execs the real agent inside `sbx`. Every surveyed tool `cd`s into the
worktree before launch, so the shim can read `$PWD` to pick/create the right
sandbox.

- **dmux** — agent is a hardcoded binary from a fixed registry, sent via
  `tmux send-keys`; **no** command-config exists, so PATH-override is the only
  launch-interception seam. Its `worktree_created` lifecycle hook
  (`DMUX_WORKTREE_PATH`) can *provision* the sandbox up front, but cannot rewrite
  the launch line — so hook + PATH-shim are complementary.
- **ccswarm** — `tokio::process::Command::new("claude")`, bare name, headless
  `-p` (non-PTY), `current_dir(worktree)`. PATH-shim works; no `-it` needed.
- AoE and Hive-Claude also accept a PATH-shim as a fallback to (a).

**(c) Server-API / SDK — no per-prompt subprocess to wrap.**
The tool talks to a long-lived agent *server* over HTTP (or an in-process SDK),
so there is no per-invocation process to intercept. The seam moves up: sandbox
the **server launch** instead, or point the tool at an external server you have
already placed inside a sandbox.

- **Hive (OpenCode default) & OpenChamber** — both spawn/connect to an
  `opencode serve` HTTP server, then drive it via the SDK/REST. There is no
  per-prompt subprocess. Shim options: (i) run `opencode serve` *inside* a
  qsbx-prepared sandbox and point the UI at it (OpenChamber: `OPENCODE_SKIP_START=true`
  + `OPENCODE_HOST`/`OPENCODE_PORT`; Hive: the `serve` launch command is itself
  configurable), or (ii) accept that the agent already runs in whatever
  environment hosts the server. Note: a sandboxed server still exposes an HTTP
  port to the host — weigh against `AGENTS.md` network rules.

**(d) Orchestrator-level runtime template — the tool wraps its *own* execution.**
The orchestrator exposes a config knob for how it spawns the worker that runs the
agent, so the wrapper applies to *every* operation, not a single agent launch.
This is the cleanest seam because the tool was *designed* to swap its runtime.

- **agor** — its `executor_command_template` (see
  [agor's executor template](#agor-executor-template)) wraps the executor process
  the daemon spawns for prompts/git/terminals. agor itself uses it to run
  executors in **k8s pods** (`kubectl run … -- agor-executor --stdin`); the same
  knob accepts `sbx exec <sandbox> -- agor-executor --stdin`. One supported config
  line routes all of agor's execution through SBX, no fork required — pending the
  worktree-mount and qsbx-injection open questions noted in that section.

### A worked shim sketch (illustrative — not a committed design)

A PATH-override wrapper for the implicit case (e.g. dmux/ccswarm). Saved as
`opencode` early on `$PATH`:

```bash
#!/usr/bin/env bash
# Re-exec the real agent inside a qsbx-prepared sandbox keyed to this worktree.
set -euo pipefail
sandbox="$(qsbx-sandbox-for "$PWD")"   # create-on-demand, keyed by worktree path
# qsbx-prepared sandbox already carries AGENTS.md + skills + opencode.jsonc (USAi).
exec sbx exec -it "$sandbox" -- opencode "$@"
```

For the explicit case (AoE), no script is needed — the same effect is one config
line: `agent_command_override.opencode = "sbx exec -it <sandbox> -- opencode"`.

### Per-tool best seam

| Tool | Launch mechanism (verified) | Best shim seam |
|------|-----------------------------|----------------|
| **AoE** | tmux pane; `agent_command_override` shell-wrapped; native `docker exec -it` | **(a)** config override → `sbx exec` (cleanest of all) |
| **Hive (Claude)** | PTY subprocess, `claudeBinary \|\| 'claude'`, `cwd=worktree` | **(a)** `claudeBinary` override, or **(b)** PATH shim |
| **dmux** | `tmux send-keys` of bare binary; `cd`s to worktree; `worktree_created` hook | **(b)** PATH shim (+ hook to pre-provision) |
| **ccswarm** | `Command::new("claude")` bare name, headless `-p`, `current_dir(worktree)` | **(b)** PATH shim (non-tty) |
| **Hive (OpenCode) / OpenChamber** | spawn `opencode serve` → SDK/HTTP | **(c)** sandbox the *server*, or attach external sandboxed server |
| **agor** | daemon spawns `agor-executor` via `executor_command_template` (default local subprocess) | **(d)** template → `sbx exec … -- agor-executor --stdin` (designed seam; cleanest at orchestrator level) |

### Hard problems every shim must solve

1. **Worktree → sandbox mount.** The shim must guarantee the current worktree is
   mounted in the target sandbox. Either create-on-demand keyed by `$PWD`, or
   pre-provision via a lifecycle hook (dmux `worktree_created`). This is also
   where the [L1 worktree↔`--clone`](#l1-deep-dive-git-worktree-vs-sbx---clone)
   reconciliation surfaces.
2. **Preserving the qsbx two values.** The sandbox the shim targets must still
   carry the global `AGENTS.md` + skills **and** the USAi `opencode.jsonc` — i.e.
   the shim must target a **qsbx-prepared** sandbox, never a bare `sbx`. Otherwise
   the agent loses its rules and its path to USAi.
3. **PTY passthrough.** Interactive tools (AoE, Hive-Claude, dmux panes) need
   `sbx exec -it`; headless callers (ccswarm `-p`) use plain `sbx exec`.
4. **Trust boundary (federal caveat).** A PATH-override shim the orchestrator does
   not know about is **bypassable** — an absolute-path call (`/usr/local/bin/claude`)
   or a pinned binary defeats it. So seam **(b)** is *defense-in-depth convenience,
   not a security boundary*; seam **(a)** is auditable and preferred where
   available. Neither replaces the requirement that the *real* boundary is SBX.

### The wrapper target is runtime-agnostic

The seam does not care *what* runtime it wraps. This repo's mandate is **SBX**, but
the same override/PATH-shim point accepts other L2 runtimes as drop-in
substitutes — e.g. `nono run … -- <agent>` (as AoE's docs show) or
`openshell sandbox create -- <agent>` /
[OpenShell](#native-isolation-independent-of-sbx). That keeps the analysis honest:
the shim is the *mechanism*; the chosen runtime (SBX today) is a policy decision an
ADR can revisit without changing the seam.

---

## Constraints & Open Questions

**Constraints (from `AGENTS.md`):**
- Local-only, SBX-native; no bypassing SBX for convenience.
- No secrets exposure; no new network listeners/reverse connections.
- Network egress limited to the approved endpoints; scrutinize any tool that
  opens tunnels (OpenChamber Cloudflare modes), binds LAN (OpenChamber, agor),
  or makes third-party calls (dmux → OpenRouter for branch names).
- No privilege escalation; SBX is the security boundary. **agor's `insulated`/
  `strict` isolation requires a root-privileged daemon** (`/etc/sudoers.d/agor`,
  `useradd`/`groupadd`/`chown`) — directly at odds with this rule.
- Dependencies require approval; no AGPL, GPL needs justification, exact pins.
  **agor is BSL 1.1**, which is fine for internal/self-hosted dev-tool use — BSL
  only restricts reselling agor as a competing *hosted service* (agor.live's
  enterprise offering). Not a blocker for this repo's use case.

**Open questions:**
1. Can BiomeLab's `--kit` / mount mechanism absorb qsbx's two values, or does
   qsbx wrap BiomeLab? (BiomeLab's `.biomelab/` notes ride along only because
   they sit *inside* the mounted worktree — that is **not** a general config-
   injection seam, and OpenCode won't read `opencode.jsonc` from the project
   root — so this resolves to "`--kit`, or qsbx prepares the sandbox", not mounts.)
2. L1 reconciliation: standardize on git worktrees mounted into sandboxes, keep
   SBX `--clone`, or support both per-task?
3. Is a governance/audit engine (ccswarm-style) needed as a distinct L4 layer for
   federal traceability, separate from the L5 UI?
4. **L2 alternatives:** should a future ADR evaluate **OpenShell** (microVM +
   policy + inference router), **nono**, **Lima**, or vigilante's container model
   as SBX alternatives/complements — or is SBX the settled boundary? (OpenShell's
   inference router vs USAi `baseURL` fit is the key unknown to test.)
5. **Shim strategy:** do we build one shared wrapper (`qsbx-sandbox-for "$PWD"`)
   targeted by both the explicit-config seam (AoE) and the PATH-override seam
   (dmux/ccswarm), or wait for native SBX support (BiomeLab)? Is the bypassable
   PATH-override seam acceptable as defense-in-depth under `AGENTS.md`?
6. **agor executor template:** the `executor_command_template` knob is **shipping**
   (verified on `main` `21edf7b`), so a template like
   `sbx exec <sandbox> -- agor-executor --stdin` is wirable today. The open work is
   *integration*: the implemented template variables are `{task_id}`/`{command}`/
   `{unix_user}`/`{unix_user_uid,gid}`/`{session_id}`/`{branch_id}`/`{log_level}` —
   **no `{cwd}`/worktree-path** — so how do we mount the per-branch worktree into
   the `sbx` invocation (agor's own k8s pattern mounts the whole `data_home` and
   keys off `{branch_id}`) and carry the
   [qsbx two values](#agor-executor-template) inside, while keeping the executor's
   one Feathers/WebSocket egress hop to the daemon?
7. For any adopted tool/service: which ADR (`0005`) and which security review?

**Next steps:** choose a direction among A/B/C, then open ADR `0005` before
adopting any dependency or standing up any service.

---

## References

- `docs/QUICKSTART_SBX.md` — sbx lifecycle, mounts, `--clone`, multiple workspaces
- `AGENTS.md` — network, secrets, and approval rules
- `docs/adr/0004-playbook-submodule-shared-config.md` — how shared config reaches the sandbox
- Tools: BiomeLab `github.com/mdelapenya/biomelab` (MIT) · Hive `github.com/morapelker/hive` (MIT) ·
  OpenChamber `github.com/btriapitsyn/openchamber` (MIT) · dmux `github.com/standardagents/dmux` (MIT) ·
  vigilante `github.com/aliengiraffe/vigilante` (Apache-2.0) · agor `github.com/preset-io/agor` (BSL 1.1) ·
  ccswarm `github.com/nwiizo/ccswarm` (MIT) · AoE `github.com/agent-of-empires/agent-of-empires` (MIT)
- L2 runtimes: SBX (this repo) · OpenShell `github.com/NVIDIA/OpenShell` (Apache-2.0, alpha) ·
  nono (referenced by AoE docs as a sandbox wrapper)
- Isolation sources: agor `multiplayer-unix-isolation.mdx` (Unix-user/sudo model) ·
  agor `executor_command_template` — **shipping** (`main` `21edf7b`):
  `apps/agor-daemon/src/utils/spawn-executor.ts` (`spawnExecutorWithTemplate` vs
  `spawnExecutorLocal`), `apps/agor-daemon/src/index.ts` (`configureExecutor`),
  `packages/core/src/config/types.ts` (`AgorExecutionSettings`),
  `spawn-executor.configured.test.ts`, docs `apps/agor-docs/pages/guide/containerized-execution.mdx`;
  original design in `context/explorations/executor-expansion.md` ·
  vigilante `SANDBOX.md` (planned container model) · BiomeLab `ARCHITECTURE.md`
  (`internal/sandbox/sandbox.go` wraps `sbx`; `.biomelab/` notes mounted via the worktree)
- Launch-seam sources: AoE `docs/guides/agent-override.md` + `src/agents.rs`
  (`agent_command_override`, `nono` wrapper example) · dmux `src/utils/agentLaunch.ts`
  (`AGENT_REGISTRY`, `tmux send-keys`) + `hooks.ts` (`worktree_created`) · ccswarm
  `providers/claude.rs` (`Command::new("claude")`, `-p`) · Hive `opencode-service.ts`
  (`opencode serve` + SDK) / `claude-cli-spawner.ts` (`claudeBinary`) · OpenChamber
  README (`OPENCODE_SKIP_START`/`OPENCODE_HOST`/`OPENCODE_PORT`)
</content>
</invoke>
