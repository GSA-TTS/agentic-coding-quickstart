# agentic-coding-playbook (sbx mixin kit)

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that delivers the
GSA [agentic-coding-playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
— the federal `AGENTS.md` rules and the Agent Skills — into a sandbox.

Unlike the `usai-opencode-provider` kit (which ships its config in `files/`),
this kit ships **no content**. At container **startup** it:

1. clones the playbook at a pinned ref into `~/.agentic-coding-playbook`, then
2. symlinks the playbook's `AGENTS.md` and skills into each supported agent's
   search paths.

See [`../docs/adr/0007-playbook-clone-at-startup-mixin-kit.md`](../docs/adr/0007-playbook-clone-at-startup-mixin-kit.md)
for why clone-at-startup (rather than a vendored submodule or a `files/`
payload).

## Usage

Apply alongside the provider kit (order does not matter):

```bash
sbx run --kit ./usai-opencode-provider --kit ./playbook-kit opencode /path/to/project
```

`qsbx` applies both kits automatically:

```bash
./qsbx run opencode /path/to/project
```

## Prerequisites

While the playbook repo is **private** (during rollout), the clone needs a
GitHub token. This kit does **not** declare its own `github` credential — the
built-in **opencode** base sandbox kit already declares one, and sbx rejects two
kits declaring the same credential service. That base credential (sentinel-swap
proxy injection) already authenticates the clone; this kit just allow-lists the
egress. Set the token once:

```bash
sbx secret set -g github
```

The sbx proxy injects it on the outbound clone — the container never sees the
real token. `qsbx` always uses the opencode base, so this works out of the box.
If you apply this kit on a **different** base agent whose kit doesn't declare
`github`, a private-repo clone has no credential and will fail (the kit degrades
gracefully — it warns and continues); make the playbook repo public or supply a
GitHub credential via that base. Once the repo is public, no token is needed.

## What it links

`AGENTS.md` is linked to each agent's user-level rules path; skills are linked
per the cross-agent [agentskills.io](https://agentskills.io) standard root
(`~/.agents/skills`) plus per-agent roots for agents that only scan their own
directory.

| Agent | Rules file linked | Skills root linked | Confidence |
|-------|-------------------|--------------------|-----------|
| OpenCode | `~/.config/opencode/AGENTS.md` | `~/.agents/skills` | high |
| Codex | `~/.codex/AGENTS.md` | `~/.agents/skills` | high |
| Droid (Factory.ai) | `~/.factory/AGENTS.md` | `~/.factory/skills` | high |
| Claude Code | `~/.claude/CLAUDE.md` | `~/.claude/skills` | high |
| GitHub Copilot CLI | `~/.copilot/copilot-instructions.md` | `~/.copilot/skills` | high |
| Cursor | — (rules live in app settings) | `~/.cursor/skills` | medium |
| Kiro | — (steering dir, not a rules file) | — (no confirmed skills dir) | low |
| Docker Agent (cagent) | — (instructions in agent YAML) | `~/.agents/skills` | high |

Notes:

- **`~/.agents/skills`** is read natively by Codex, OpenCode, Docker Agent, and
  Copilot CLI — one symlink root covers them all. The per-agent roots
  (`~/.claude/skills`, `~/.factory/skills`, `~/.cursor/skills`,
  `~/.copilot/skills`) cover agents that only scan their own directory.
- **Cursor / Kiro / Docker Agent** have no user-level rules *file* convention
  (rules live in app settings or the agent's YAML), so they get skills only.
- Low/medium-confidence rows should be **verified in-sandbox**; the kit links
  them best-effort and never fails if a path is wrong.

## Pinning the playbook version

The kit pins the playbook to `PLAYBOOK_REF` (an `environment.variables` entry in
`spec.yaml`, default the latest playbook release tag at commit time). To adopt a
newer playbook release, bump `PLAYBOOK_REF` in `spec.yaml` (keep it in sync with
the fallback default in the startup script) and recreate sandboxes. sbx does not
forward host env into startup commands, so exporting `PLAYBOOK_REF` on the host
has no effect — the value is fixed in the kit.

## Failure behavior

The startup command is **idempotent** and **non-fatal**:

- Clones once (clone-if-missing); no refetch on later starts.
- On clone failure (offline, missing token, bad ref) it **warns and exits 0** —
  the sandbox starts **without** the playbook rather than failing to create.
- Because startup runs on every container start, a sandbox created offline
  **self-heals**: the clone is retried on the next start once the network/token
  is available.

## Verifying

```bash
sbx kit validate ./playbook-kit
sbx run --kit ./usai-opencode-provider --kit ./playbook-kit opencode /tmp/pb-smoke
# inside the sandbox / via sbx exec:
sbx exec <sandbox> -- sh -c 'ls -l ~/.agents/skills && cat ~/.config/opencode/AGENTS.md | head'
# confirm the minimal egress set:
sbx policy log <sandbox>
```

Add any host shown in the policy log's blocked list to `caps.network.allow`.
