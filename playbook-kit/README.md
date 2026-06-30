# agentic-coding-playbook (sbx mixin kit)

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that delivers the
GSA [agentic-coding-playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
— the federal `AGENTS.md` rules and the Agent Skills — into a sandbox.

The kit ships **no content**. At container **startup** it:

1. clones the playbook at a pinned ref into `~/.agentic-coding-playbook`, then
2. symlinks the playbook's `AGENTS.md` and skills into each supported agent's
   search paths.

Clone-at-startup (rather than vendoring the playbook into the kit's `files/`)
keeps the kit tiny and lets the playbook version be pinned and bumped
independently. See [Failure behavior](#failure-behavior) for how it degrades
when the clone can't run.

## Usage

```bash
sbx run --kit <path-to-this-kit> opencode /path/to/project
```

The kit is a `mixin`, so it composes with other kits — apply it alongside an
agent/provider kit with additional `--kit` flags.

## Prerequisites

While the playbook repo is **private**, the clone needs a GitHub token. This kit
does **not** declare its own `github` credential — the built-in **opencode** base
sandbox kit already declares one, and sbx rejects two kits declaring the same
credential service. That base credential (sentinel-swap proxy injection)
authenticates the clone; this kit just allow-lists the GitHub egress. Set the
token once:

```bash
sbx secret set -g github
```

The sbx proxy injects it on the outbound clone — the container never sees the
real token. If you apply this kit on a **base agent whose kit doesn't declare
`github`**, a private-repo clone has no credential and will fail (the kit
degrades gracefully — it warns and continues); make the playbook repo public or
supply a GitHub credential via that base. Once the repo is public, no token is
needed.

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

## Troubleshooting

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## Design decisions

See [`docs/decisions/playbook-clone-at-startup.md`](docs/decisions/playbook-clone-at-startup.md)
— why the kit clones the playbook at startup (vs. a vendored copy or a `files/`
payload), `commands.startup` vs `commands.install`, pinning, and the GitHub
auth approach.

## Verifying

Run the bundled check on a host with `sbx` installed and logged in:

```bash
./scripts/verify
```

It validates the spec, creates a throwaway sandbox with the kit, and confirms
the playbook cloned and `AGENTS.md` + skills resolved at the agent paths. Set
`KEEP=1` to keep the sandbox for inspection.
