---
title: "Deliver the Playbook as a Clone-at-Startup Mixin Kit; Remove the Submodule"
status: accepted
date: 2026-06-30
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["CM-2", "CM-3", "SA-10", "SC-7", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
---

# ADR-0007: Deliver the Playbook as a Clone-at-Startup Mixin Kit

## Context and Problem Statement

ADR-0004 vendored the `agentic-coding-playbook` as a git submodule and had
`qsbx` symlink its `AGENTS.md` + skills into the sandbox home at attach time.
ADR-0005/0006 moved the USAi provider config into a declarative sbx **mixin
kit**. The remaining imperative piece was the playbook delivery. We want it
declarative too — and delivered to **all** the agents sbx supports, not just
OpenCode — without contaminating the (deliberately technology-agnostic)
playbook repo with sbx-specific scaffolding.

We explored shipping the playbook content inside the kit's `files/` tree (via
the submodule or a copy). The sbx loader (`spec/artifact.go`) defeats that two
ways:

1. **It can't skip files.** `enumerateDirFiles` blindly walks all of
   `files/home`; there is no ignore mechanism. A submodule placed there ships
   its entire tree (docs, examples, `.git`) into every sandbox. The submodule's
   `.git` is a *file* pointing `gitdir: ../.git/modules/...` — out of the
   artifact root — which is meaningless in the container.
2. **It only dereferences *file* symlinks.** `filepath.Walk` does not recurse a
   symlinked *directory*, so a `files/home/.../skills -> submodule/.agents/skills`
   directory symlink cannot ship the skills tree; only per-file symlinks would,
   which is fragile and needs a generator.

So a `files/`-based payload forces either copying the playbook into the kit
(committed duplication, ships cruft) or a brittle per-file symlink generator.

## Decision

**Clone the playbook at container startup instead of shipping its content.**
A new `playbook-kit/` mixin (`name: agentic-coding-playbook`) carries no
`files/` payload. Its `commands.startup` script:

1. `git clone --depth 1 --branch "$PLAYBOOK_REF"` the playbook into
   `~/.agentic-coding-playbook` (clone-if-missing; no refetch on later starts);
2. symlinks `AGENTS.md` into each agent's user-level rules path and each skill
   subdirectory into the cross-agent `~/.agents/skills` root (+ per-agent roots);
3. is **idempotent** and **non-fatal**: on any failure it warns and `exit 0`, so
   the sandbox starts without the playbook and **self-heals** on a later start.

The git submodule and all of `qsbx`'s AGENTS.md/skills symlinking (and the
read-only clone mount that existed to feed it) are **removed**. `qsbx` now
applies two kits: `--kit <clone> --kit <clone>/playbook-kit`.

### Why `commands.startup`, not `commands.install`

`install` runs once at create and a failure fails `sbx create`. `startup` runs
every start (idempotent), so a sandbox created offline self-heals when the
network/credential returns, and a clone failure degrades gracefully instead of
blocking creation. That matches the requirement that the playbook is an
enhancement, not a hard dependency.

### Pinning

`environment.variables.PLAYBOOK_REF` pins the playbook to a release tag
(default `v0.12.1`, the latest at commit time); the script falls back to the
same literal. This preserves the explicit, reviewed version-bump gate the
submodule provided (bump = edit `spec.yaml` + recreate). sbx does not forward
host env into startup commands, so the override is the spec value, not an
ambient `export`.

### Authentication (interim)

The playbook repo is **private during rollout**, so the clone needs a GitHub
token. The kit does **not** declare its own `github` credential: the base
opencode sandbox template already declares one, and sbx composition rejects two
kits declaring the same credential service (`credential for service "github"
defined in both "opencode" and "agentic-coding-playbook"` — pitfall #8). The
template's GitHub credential (sentinel-swap proxy injection) already
authenticates the clone; this kit only allow-lists the GitHub egress under
`caps.network` (network lists union across kits; credentials do not). The real
token never enters the container. Users set it once with `sbx secret set -g
github`. Once the repo is public no token is needed.

### Per-agent targets

| Agent | Rules file | Skills root | Confidence |
|-------|-----------|-------------|-----------|
| OpenCode | `~/.config/opencode/AGENTS.md` | `~/.agents/skills` | high |
| Codex | `~/.codex/AGENTS.md` | `~/.agents/skills` | high |
| Droid | `~/.factory/AGENTS.md` | `~/.factory/skills` | high |
| Claude Code | `~/.claude/CLAUDE.md` | `~/.claude/skills` | high |
| Copilot CLI | `~/.copilot/copilot-instructions.md` | `~/.copilot/skills` | high |
| Cursor | — (app settings) | `~/.cursor/skills` | medium |
| Kiro | — (steering dir) | — (unconfirmed) | low |
| Docker Agent | — (agent YAML) | `~/.agents/skills` | high |

`~/.agents/skills` (the agentskills.io standard root) covers Codex, OpenCode,
Docker Agent, and Copilot natively. Linking is best-effort; low/medium rows
should be verified in-sandbox.

## Consequences

### Positive

- Fully declarative playbook delivery to all supported agents (CM-3, SA-10).
- Playbook repo stays technology-agnostic — no sbx scaffolding added to it.
- No committed duplication, no shipped `.git`/cruft, OCI-publish-ready.
- Graceful degradation + self-heal on transient network loss.
- `qsbx` shrinks: submodule, read-only mount, and home-symlinking all removed.

### Negative / Residual

- **New create/start-time network dependency** (SC-7): every sandbox clones from
  GitHub. Offline/airgapped creation yields no playbook (degrades gracefully;
  no hard failure). We accept this for a dev quickstart and will watch how often
  offline bites in practice.
- **Interim GitHub credential** required while the repo is private.
- Clone-at-startup means `sbx kit validate` can't exercise the kit end-to-end;
  the real test is a live `sbx run` (documented in the kit README).
- Per-agent paths for Cursor/Kiro are low/medium confidence; verify in-sandbox.

## Validation

- Startup script unit-checked offline against: already-cloned home (links all
  rules + skills, silent), missing clone with failing `git` (warns, exits 0,
  self-heal on next start), and idempotent re-run.
- `sbx kit validate ./playbook-kit` → VALID.
- Live: `sbx run --kit . --kit ./playbook-kit opencode <proj>` → clone present,
  `~/.agents/skills/<skill>/SKILL.md` and `~/.config/opencode/AGENTS.md` resolve;
  `sbx policy log` pins the minimal egress set.

## Links

- Supersedes: ADR-0004 (submodule + home-symlink mechanism)
- Related: ADR-0005 (provider kit), ADR-0006 (config co-tenancy), `playbook-kit/`
- [sbx kit lifecycle](https://docs.docker.com/ai/sandboxes/customize/kits/),
  [agentskills.io](https://agentskills.io)
