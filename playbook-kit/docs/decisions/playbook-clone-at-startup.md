# Decision: Deliver the playbook by cloning it at sandbox startup

**Status:** accepted

## Context

This kit delivers the GSA
[agentic-coding-playbook](https://github.com/GSA-TTS/agentic-coding-playbook) —
the federal `AGENTS.md` rules and the Agent Skills — into a sandbox, for every
supported agent. The playbook is its own repository and is deliberately
technology-agnostic (no sbx-specific scaffolding).

The natural-seeming approaches don't work:

- **Ship the playbook content in the kit's `files/` tree.** The sbx kit loader
  walks `files/home` with no ignore mechanism, so it would pack the *entire*
  playbook (docs, examples, and a `.git` pointer that's meaningless in the
  container). And it only dereferences **file** symlinks, not directory symlinks
  — so a single `files/home/.../skills -> playbook/.agents/skills` link can't
  ship the skills tree; only fragile per-file symlinks would.
- **Vendor the playbook as a git submodule** and symlink it in at runtime. This
  contaminates the host repo with submodule plumbing and ties delivery to a
  wrapper script rather than the kit itself.

## Decision

**Clone the playbook at container startup** instead of shipping its content. The
kit carries no playbook content in `files/`. Its `commands.startup` script:

1. `git clone --depth 1 --branch "$PLAYBOOK_REF"` into
   `~/.agentic-coding-playbook` (clone-if-missing; no refetch on later starts);
2. symlinks `AGENTS.md` into each agent's user-level rules path and each skill
   subdirectory into the cross-agent `~/.agents/skills` root plus per-agent
   roots;
3. is **idempotent** and **non-fatal**: on any failure it warns and `exit 0`, so
   the sandbox starts without the playbook and **self-heals** on a later start.

### Why `commands.startup`, not `commands.install`

`install` runs once at create, and a failure fails `sbx create`. `startup` runs
on every start (idempotent), so a sandbox created offline self-heals when the
network/credential returns, and a clone failure degrades gracefully rather than
blocking creation. The playbook is an enhancement, not a hard dependency, so
graceful degradation is the right posture.

### Pinning

`environment.variables.PLAYBOOK_REF` pins the playbook to a release tag (the
startup script falls back to the same literal). To adopt a newer release, bump
`PLAYBOOK_REF` and recreate sandboxes. sbx does not forward host env into startup
commands, so the override is the spec value, not an ambient `export`.

### Authentication (while the playbook repo is private)

A private-repo clone needs a GitHub token. This kit does **not** declare its own
`github` credential: the built-in **opencode** base sandbox kit already declares
one, and sbx composition rejects two kits declaring the same credential service
(`credential for service "github" defined in both ...`). The base credential
(sentinel-swap proxy injection) authenticates the clone; this kit only
allow-lists the GitHub egress under `caps.network` (network allow-lists union
across kits; credentials do not). The token never enters the container; the user
sets it once with `sbx secret set -g github`. Applied on a base agent whose kit
does not declare `github`, a private clone has no credential and fails
gracefully. Once the repo is public, no token is needed.

### Per-agent link targets

`AGENTS.md` is linked to each agent's user-level rules path; skills go to the
[agentskills.io](https://agentskills.io) standard root `~/.agents/skills` plus
per-agent roots for agents that only scan their own directory. See the README's
table. Cursor/Kiro support is lower-confidence and should be verified in-sandbox.

## Consequences

### Positive

- Fully declarative playbook delivery to all supported agents.
- The playbook repo stays technology-agnostic — no sbx scaffolding added to it.
- No committed duplication, no shipped `.git`/cruft; the kit stays tiny.
- Graceful degradation + self-heal on transient network loss.

### Negative / residual

- A create/start-time **network dependency** on GitHub; offline creation yields
  no playbook (degrades gracefully; no hard failure).
- An interim GitHub credential is required while the repo is private.
- `sbx kit validate` can't exercise the clone end-to-end; the real test is a live
  `sbx run` (see `scripts/verify`).
- Cursor/Kiro paths are best-effort; verify in-sandbox.
