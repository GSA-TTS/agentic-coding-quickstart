---
title: "Vendor the Playbook as a Submodule and Symlink Shared Config into the Sandbox Home"
status: superseded
date: 2026-06-11
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["CM-2", "CM-3", "SA-10", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
---

# ADR-0004: Vendor the Playbook as a Submodule and Symlink Shared Config into the Sandbox Home

> **Status: SUPERSEDED by [ADR-0005](0005-kits-from-patterns-and-agent-trust-model.md).**
> The git submodule and `qsbx`'s home-symlinking of `AGENTS.md`/skills described
> here were **removed**. The playbook, the USAi provider config, and the Zscaler
> CA are now delivered as sbx **mixin kits** hosted in the community
> [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
> repo (`integrations/isolation/sbx-kits/`); `qsbx` applies them by pinned remote
> reference. ADR-0005 records the new trust model (including the writable-clone
> tradeoff this ADR's read-only mount previously mitigated) and the migration
> path. This ADR is retained for historical context.

## Context and Problem Statement

ADR-0001 established SBX as the isolation layer, and this repository has been
reoriented from *propagating* config into other repos toward *mounting* one
shared global config into sandboxes. We now want the playbook's behavioral rules
(`AGENTS.md`) and agent skills (`.agents/skills`) to ride along with that shared
config, so a user gets a working agent — provider config, federal rules, and
skills — from a single mounted clone, with one place to update.

The original intuition was to point `OPENCODE_CONFIG_DIR` at a config directory
and let OpenCode discover `AGENTS.md` and `.agents/skills` relative to it. That
assumption needed to be verified before building on it.

## Decision Drivers

- **CM-2 (Baseline Configuration):** One auditable source for config, rules, and skills.
- **CM-3 (Configuration Change Control):** Playbook updates land via reviewable PRs.
- **SA-10 (Developer Configuration Management):** Pin third-party content to a known version.
- **SI-7 (Software/Information Integrity):** Deterministic, inspectable wiring.
- **Reuse over proliferation:** Avoid per-project copies of skills/rules.
- **Don't mutate the user's project:** Inject shared config without editing the app repo.

## Spike: how OpenCode actually resolves config

Before committing to a layout, we ran a throwaway empirical probe against
OpenCode 1.16.2. The probe built a scratch directory containing an
`opencode.jsonc` (with `"instructions": ["AGENTS.md"]`), an `AGENTS.md` carrying
a unique sentinel, and a `.agents/skills/<name>/SKILL.md` carrying another
sentinel; pointed `OPENCODE_CONFIG_DIR` at it; and ran two headless
`opencode run --dir <other-dir>` turns (so the project dir and config dir
differed) asking the agent to echo the AGENTS.md sentinel and to list its skills.

**Result: OpenCode does NOT read `AGENTS.md` or `.agents/skills` relative to
`OPENCODE_CONFIG_DIR`.** Neither sentinel appeared. A positive control confirmed
the harness worked: the skills probe instead surfaced a skill from the host's
global `~/.config/opencode/`, proving skills *can* be discovered — just not from
`OPENCODE_CONFIG_DIR`.

Per the OpenCode docs, rule and skill discovery is rooted at the **project
directory** (traversing upward) and the **home directory** locations:

- `~/.config/opencode/AGENTS.md`
- `~/.config/opencode/skills/<name>/SKILL.md`, `~/.agents/skills/<name>/SKILL.md`

`OPENCODE_CONFIG_DIR` governs `opencode.jsonc` resolution, not rules or skills.

## Considered Options

1. **`OPENCODE_CONFIG_DIR` → per-agent subdir** (original idea) — rejected: the
   spike shows AGENTS.md/skills are not discovered there.
2. **Symlink playbook content into the user's project workspace** — rejected:
   mutates the user's repo, which the mountable-config approach explicitly avoids.
3. **Symlink the shared config into the sandbox home search locations** —
   chosen. Matches where OpenCode actually looks; touches only the sandbox home,
   not the user's project.
4. **Sibling clone of the playbook (status quo)** — rejected: re-introduces a
   separate clone to manage and keep in sync.

## Decision Outcome

Chosen option: **vendor the playbook as a pinned git submodule, and have `qsbx`
symlink the shared config into the sandbox home at sandbox-create time.**

### Layout

A per-agent config subdirectory keeps room to add `claude/`, `codex/`, `gemini/`,
etc. later without another ADR:

```
agentic-coding-quickstart/
├── opencode/opencode.jsonc          # shared OpenCode config (real file)
├── opencode.jsonc -> opencode/opencode.jsonc   # root convenience/back-compat symlink
├── agentic-coding-playbook/         # pinned submodule (release tag)
└── AGENTS.md                        # rules for working ON this quickstart repo (NOT shared)
```

This repo's top-level `AGENTS.md` stays a real file — it governs work *on the
quickstart itself* and is intentionally distinct from the playbook's federal
`AGENTS.md` that agents load *in the sandbox*.

### Submodule pinning

The submodule is pinned to a **release tag** (initially `v0.11.0`), not a moving
branch. Bumps are explicit:

```bash
git submodule update --remote --merge agentic-coding-playbook
git add agentic-coding-playbook && git commit
```

### In-sandbox wiring (qsbx)

`sbx` mounts the clone at its host path inside the sandbox. After create, `qsbx`
runs `sbx exec` to symlink (backing up any pre-existing non-symlink target to
`*.qsbx-bak`):

| Sandbox home path | Target in mounted clone |
|-------------------|-------------------------|
| `~/.config/opencode/opencode.jsonc` | `opencode/opencode.jsonc` |
| `~/.config/opencode/AGENTS.md` | `agentic-coding-playbook/AGENTS.md` |
| `~/.agents/skills` | `agentic-coding-playbook/.agents/skills` |

(Inside the sandbox `HOME=/home/agent`.) This replaces the previous
`OPENCODE_CONFIG_DIR` persistent-env injection, which the spike showed was
insufficient for rules/skills.

### Mount mode: read-only for project work, read-write only to edit config

The shared `opencode.jsonc` carries the **permission policy** (`"bash": "ask"`,
`"edit": "ask"`, deny lists) that every sandbox loads. If the clone were mounted
read-write during ordinary project work, a prompt-injected agent in one sandbox
could rewrite that policy — plus the rules and skills — that all other sandboxes
subsequently trust. That is an unacceptable blast radius even at FIPS Low.

Decision:

- **Project work** (`qsbx run <agent> <project>`): the clone is mounted as an
  **extra workspace with `:ro`**. sbx enforces read-only on extra workspaces, so
  the agent can read the config/rules/skills but cannot modify the policy that
  governs other sandboxes.
- **Editing the shared config** (`qsbx run <agent> <clone-path>`, e.g.
  `qsbx run opencode .` from within the clone): qsbx detects that the target
  workspace *is* the clone and instead mounts it **read-write as the primary
  workspace** (sbx primary workspaces are always RW). It prints an explicit
  notice, skips the home-dir symlinks (the agent is editing the clone directly),
  and defaults the sandbox name to `qsbx-quickstart-config` (unless `--name` is
  given). Normal `"edit": "ask"` gating still applies, and changes only reach
  other sandboxes after the user reviews them with `git diff` and commits/pushes.

This keeps the policy-governing files writable only in a sandbox whose explicit
purpose is editing them — never incidentally writable during untrusted project
work. The `git diff` + commit step is the propagation gate.

### Positive Consequences

- One mounted clone provides config + rules + skills; edits propagate to every sandbox.
- Playbook version is pinned and bumped through review (SA-10, CM-3).
- The user's project repo is never modified.
- Extensible to other agents via sibling config subdirs.
- Project-work sandboxes cannot tamper with the shared permission policy (`:ro`).

### Negative Consequences

- The playbook is currently a **private** repo, so cloning requires access
  (`git clone --recurse-submodules` with a credentialed token). Acceptable: the
  quickstart is gated the same way today, and both are expected to go public.
- CI must avoid fetching/linting the submodule (private + separately linted);
  handled via `submodules: false` checkout default and lint/hook excludes.
- Symlink wiring assumes the sandbox home layout (`/home/agent`); documented and
  defensively guarded in `qsbx`.
- **Residual trust tradeoff:** the config-editing sandbox does have RW access to
  the shared policy. This is intentional and scoped to that explicit workflow;
  the safeguard is human `git diff` review before changes are committed and
  propagate. Acceptable for local-dev / FIPS Low.

### Compliance Consequences

- **CM-2:** Satisfied — single baseline for config/rules/skills in version control.
- **CM-3:** Satisfied — submodule bumps are reviewable PRs.
- **SA-10:** Satisfied — third-party playbook pinned to a release tag.
- **SI-7:** Satisfied — wiring is deterministic and inspectable in `qsbx`.

## Validation

The discovery spike (described above) was a throwaway harness run on the host; it
is not retained in the tree. Its conclusion — home-directory symlinking rather
than `OPENCODE_CONFIG_DIR` — is captured here and reflected in `qsbx`.

## Links

- Related: ADR-0001 (SBX isolation), `qsbx`
- Related: `AGENTS.md`, `README.md`
- [OpenCode rules precedence](https://opencode.ai/docs/rules/)
- [OpenCode skills](https://opencode.ai/docs/skills/)
