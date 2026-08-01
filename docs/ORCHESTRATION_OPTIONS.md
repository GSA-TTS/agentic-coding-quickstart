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
   L1  ISOLATION UNIT    │   git worktree (mounted into the sandbox)     │
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

## L1 Deep-Dive: git worktrees (SBX `--clone` abandoned)

Branch isolation will use **git worktrees mounted into sandboxes**. SBX `--clone`
(an in-container clone exposed as a host git remote `sandbox-<name>`) has been
**abandoned as too fiddly** — it requires `git fetch sandbox-<name>` before
removal to avoid data loss, and most surveyed dashboards are worktree-native
anyway. Worktrees align with the tooling and avoid that footgun.

| Aspect | git worktree (chosen) | SBX `--clone` (abandoned) |
|--------|-----------------------|---------------------------|
| What it is | Extra working tree on the host, one per branch | In-container clone exposed as host git remote `sandbox-<name>` |
| Isolation strength | Filesystem only on host; **gains microVM isolation once mounted into a sandbox** | Full microVM (own FS/Docker/network) |
| Host footprint | One directory per task on host | Lived inside the sandbox |
| Cleanup | `git worktree remove` + dir delete | `sbx rm` + remote; **needs `git fetch` first** |
| Data-loss risk | Low | High if you forget the fetch — the abandonment reason |
| Tooling support | BiomeLab, Hive, dmux, agor, vigilante, ccswarm | Native to SBX only |

The pattern: create a **git worktree on the host** and **mount it into a sandbox**
(`sbx` supports extra workspace mounts; `qsbx` already mounts the clone `:ro`).
This is also how worktree-native dashboards stay SBX-native here, and matches
agor's model (it manages worktrees on a shared filesystem its executor mounts).

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
| **agor** — `simple` mode | None — agents run as the daemon user on the host | Default | None | ❌ (needs SBX underneath) |
| **agor** — `insulated`/`strict` | Unix users/groups + filesystem perms + `sudo` impersonation | Opt-in | **Root**: installs `/etc/sudoers.d/agor`, `useradd`/`groupadd`/`chown` | ✅ isolates users from each other |
| **agor** — executor template | Wraps the executor spawn in *any* runtime (`executor_command_template`); agor uses it for k8s pods, could wrap `sbx` | **Shipping** config knob | Inherits the chosen runtime's footprint | ✅ via whatever runtime you template in |
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
  backend — directly aligned with forcing all traffic through USAi, whose API is
  OpenAI-shaped and so fits OpenShell's OpenAI-style provider model. Caveats:
  **alpha / "single-player" / NVIDIA-led**, and a heavier **gateway + driver**
  architecture than SBX's single CLI. Apache-2.0.
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
ephemeral **k8s pod** (`kubectl run … -- agor-executor --stdin`). There's a dedicated user-facing
guide (`apps/agor-docs/pages/guide/containerized-execution.mdx`) focused on k8s 
(which is what the agor team themselves use for their notional hosted service).

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

- **Worktree mount is a filesystem concern, largely solved by agor's design.**
  agor creates and manages the branch worktree on a **shared filesystem**
  (`data_home`) *before* the executor runs, and the executor reads `dataHome` from
  its payload. So the sandbox doesn't need a per-worktree template variable — it
  mounts `data_home` (the same model agor uses for k8s, where executor pods mount
  the `data_home` PVC) and the worktree is already present at a path the executor
  knows. The implemented template variables (`{task_id}`, `{command}`,
  `{unix_user}`, `{unix_user_uid}`, `{unix_user_gid}`, `{session_id}`,
  `{branch_id}`, `{log_level}`; **no `{cwd}`**) are sufficient given this. (Minor:
  the docs page advertises `{repo_gid}`/`{branch_gid}`/etc. the code does **not**
  implement — a docs-vs-code drift, not blocking.) The remaining work is wiring
  the `data_home` mount into the `sbx` invocation and carrying the
  [qsbx two values](#shimming-sbx-into-non-isolating-tools) inside.
- **Daemon egress hop.** The `prompt` command expects the executor to reach the
  daemon over a Feathers WebSocket, so a sandboxed executor must still be allowed
  that one connection.
- agor's daemon/MCP network surface still applies regardless of executor runtime;
  its **BSL 1.1** license does **not** block this use (see
  [above](#agor-local-vs-shared-server)).

> **Reframing:** agor offers **two** isolation stories. Its *Unix-user* mode is a
> poor fit (root-privileged, shared-server). But its *executor-template* shim is a
> genuinely good fit — arguably the cleanest orchestrator-level seam surveyed for dropping in SBX/OpenShell/`nono`
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
| **agor** — `simple` mode | TS / FeathersJS daemon + React | Local, single-dev | Localhost daemon, WebSocket, MCP endpoint | Yes (branches = worktrees under `~/.agor/`) | None — runs as daemon user on host | **Yes** (Claude/Codex/Gemini/OpenCode/Copilot/Cursor) | RBAC/ACLs, per-prompt token+cost, durable history, MCP | BSL 1.1 (self-host OK) | No isolation — needs SBX underneath |
| **agor** — `insulated`/`strict` | TS / FeathersJS daemon + React | Shared server, multi-user | Localhost daemon + WebSocket + MCP; multiplayer | Yes (branches = worktrees under `~/.agor/`) | Unix-user + `sudo`; **needs root** | **Yes** (same) | RBAC/ACLs, per-prompt token+cost, durable history, MCP | BSL 1.1 (self-host OK) | Isolates users from each other, not agent from host; root-privileged |
| **agor** — executor template | TS / FeathersJS daemon + React | Local or server | Daemon + WebSocket + MCP; runtime adds its own | Yes (branches = worktrees under `~/.agor/`) | **`executor_command_template`** — wrap executor in `sbx`/k8s/etc. | **Yes** (same) | RBAC/ACLs, per-prompt token+cost, durable history, MCP | BSL 1.1 (self-host OK) | Executor template can route execution through `sbx` (cleanest orchestrator-level seam); daemon/MCP surface to weigh |
| **ccswarm** | Rust | Local CLI engine | `gh` (issue ingest) | Yes (Claude `--worktree`) | Worktree + sensitive-path deny-list (no real sandbox) | Partial (claude/codex; copilot unsupported for codegen) | **NDJSON audit, replay/diff/undo, HITL gates, sensitive-path deny-list** | MIT | L4 engine, not L5 UI; pairs with audit/approval rules |
| **OpenShell** *(L2 runtime, not an orchestrator)* | Rust; gateway + driver | Local gateway; k8s/Helm option | **L7 egress proxy** (allow/deny per method+path); inference router | n/a (isolates whatever you run) | **microVM/container** + YAML policy (FS/net/process/inference) | **Yes** (`-- claude\|opencode\|codex\|copilot`; BYOC) | Policy decisions logged; k9s-style TUI | Apache-2.0 | An **SBX replacement** at L2, not a layer on top; could own USAi routing via its inference router (USAi is OpenAI-shaped) |

> **Agent-agnostic note (your OpenCode concern):** OpenChamber and Hive are
> OpenCode/Claude/Codex-bound (OpenChamber the most). BiomeLab, AoE, dmux,
> vigilante, agor, and ccswarm are broadly agent-agnostic — they detect or launch
> many CLIs rather than embedding one runtime. OpenShell (L2) is agent-agnostic by
> construction: it sandboxes whatever agent you launch inside it.

> **agor's three rows** above are the *same product* in different configurations,
> not three tools: `simple` (local, no isolation), `insulated`/`strict` (shared
> server, root-privileged Unix isolation), and the `executor_command_template`
> shim (runtime-pluggable). They are split out because their isolation, network,
> and federal-fit characteristics differ enough to warrant separate evaluation.

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

## Shimming SBX into Non-Isolating Tools

> **De-emphasized.** The per-agent shim approaches in this section (seams (a)–(c))
> are considered **too fragile** to pursue as a primary direction — PATH-overrides
> are bypassable and command-wrapping is brittle across tool upgrades. They are
> retained here for completeness. The durable seam is the **orchestrator-level
> runtime template** (seam (d), agor's `executor_command_template`), covered in the
> [Pilot Candidates](#pilot-candidates) section.

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
   where the [L1 worktree mounting](#l1-deep-dive-git-worktrees-sbx---clone-abandoned)
   detail surfaces.
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

## Pilot Candidates

> **Candidates, not decisions.** Recorded here for a future ADR/spike. Two tools
> stand out for different reasons: **BiomeLab** is already SBX-native; **agor**
> offers a seam to make its execution SBX-native.

### BiomeLab — the SBX-native dashboard

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
- **Worktree mounting at L1** — how BiomeLab's worktree gets into the sandbox,
  given SBX `--clone` is abandoned in favor of mounted worktrees.

### agor — the executor-template route to SBX

agor warrants a pilot for a different reason than BiomeLab: it is *not* SBX-native
today, but its **`executor_command_template`** (see
[agor's executor template](#agor-executor-template)) is a first-class, supported
seam for making it so — wrap the executor in `sbx exec … -- agor-executor --stdin`
and all of agor's execution routes through SBX without forking. In exchange you
get agor's richer governance surface (branch RBAC, per-prompt token/cost
accounting, durable history, MCP endpoint) that BiomeLab lacks.

A pilot would test:

- **Worktree availability in the sandbox** *(largely resolved by design)*. agor
  manages the branch worktree on a **shared filesystem** (`data_home`) *before*
  the executor runs, and the executor receives `dataHome` in its payload — the
  same model agor uses for k8s (executor pods mount the `data_home` PVC). So the
  pilot only needs to mount `data_home` into the `sbx` sandbox; the worktree is
  already there. No per-worktree template variable is required despite the absent
  `{cwd}`. Remaining detail: confirm the `data_home` mount path inside the sandbox
  matches what the executor's payload expects.
- **Does it preserve the qsbx baseline?** Can the sandboxed executor carry the
  global `AGENTS.md` + skills and the `opencode.jsonc`/USAi wiring — i.e. is the
  template pointed at a **qsbx-prepared** sandbox?
- **Daemon egress hop.** The `prompt` command needs the executor to reach the
  daemon over a Feathers WebSocket; confirm a sandboxed executor retains exactly
  that one connection and nothing more under `AGENTS.md` network rules.
- **`simple` mode is mandatory here.** Use agor's local `simple` mode (no
  root-privileged Unix isolation) and let SBX be the boundary — never the
  `insulated`/`strict` sudoers model, which conflicts with `AGENTS.md`.

> **BiomeLab vs agor framing:** BiomeLab is the lower-effort pilot (isolation is
> already SBX); the open work is config injection. agor is the higher-ceiling
> pilot (more governance); since agor already manages the worktree on shared
> storage before the executor runs, its open work is mainly mounting `data_home`
> into the sandbox and qsbx injection through the template. They are not mutually
> exclusive — a spike could evaluate both against the same task.

Independently of which dashboard is chosen, the project's audit/approval
requirements warrant a distinct governance evaluation — see open question 3.

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
   qsbx wrap BiomeLab?
2. **L1 worktrees.** With SBX `--clone` abandoned (too fiddly), standardize on git
   worktrees mounted into sandboxes. Open detail: worktree layout and how each is
   mounted into its sandbox.
3. Is a governance/audit engine needed as a distinct L4 layer for federal
   traceability, separate from the L5 UI? Candidates: ccswarm's model (NDJSON
   audit, HITL gates, deny-list) and **re_gent** (`github.com/regent-vcs/re_gent`),
   which BiomeLab already uses for its activity log — worth evaluating directly.
4. **L2 runtime — SBX is not settled.** If a better alternative exists we should
   adopt it. Plan to **evaluate OpenShell** (microVM + policy + inference router;
   it has made significant progress, and its inference router can route USAi
   traffic since USAi is OpenAI-shaped) as an SBX successor/complement. `nono` is
   excluded for now — it does not appear to offer sufficient isolation — though
   that can be re-checked at evaluation time.
5. ~~Shim strategy~~ — **de-emphasized.** The PATH-override/wrapper shim approach
   (seams (a)–(c)) is fragile and is not a preferred direction; agor's
   orchestrator-level executor template (seam (d)) is the durable seam if a
   shim-style integration is pursued at all.
6. **agor executor template:** the `executor_command_template` knob makes a template like
   `sbx exec <sandbox> -- agor-executor --stdin` wirable today. Worktree access
   is largely solved by agor's design — it manages the branch worktree on a shared
   `data_home` filesystem before the executor runs (the same model as its k8s PVC
   mount), so the sandbox just mounts `data_home`. The open work is *integration*: carry the
   [qsbx two values](#agor-executor-template) into the sandbox, match the
   `data_home` mount path to the executor's payload, and keep the executor's one
   Feathers/WebSocket egress hop to the daemon.
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
- Governance candidates: ccswarm `github.com/nwiizo/ccswarm` ·
  re_gent `github.com/regent-vcs/re_gent` (BiomeLab's activity log uses it)
- Isolation sources: agor `multiplayer-unix-isolation.mdx` (Unix-user/sudo model) ·
  agor `executor_command_template` — shipped in (`main` `21edf7b`):
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
