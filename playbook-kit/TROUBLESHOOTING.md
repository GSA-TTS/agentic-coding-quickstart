# Troubleshooting — agentic-coding-playbook kit

These are failure modes specific to the playbook kit, which clones the GSA
playbook at container startup and links its `AGENTS.md` + skills into each
agent's search paths.

## No playbook rules or skills in the sandbox

**Symptoms:** `~/.agents/skills` is empty; the agent has no federal `AGENTS.md`;
`~/.agentic-coding-playbook` is missing.

**Cause:** the startup clone didn't run or failed. The startup command is
non-fatal — on failure it warns and lets the sandbox start without the playbook.

**Fix / diagnose:**

- Check startup logs for the kit's warning (it names the likely cause).
- **Missing GitHub token (private repo).** While the playbook repo is private the
  clone needs auth. Set it once: `sbx secret set -g github`. The kit relies on
  the **opencode base kit's** `github` credential — applying the kit on a base
  agent that doesn't declare `github` leaves the clone unauthenticated.
- **Egress blocked.** Confirm `github.com` / `codeload.github.com` were allowed:
  `sbx policy log <sandbox>`; add blocked hosts to `caps.network.allow`.
- **Bad ref.** Confirm `PLAYBOOK_REF` in `spec.yaml` names a real tag/branch.
- **Self-heal:** the clone is retried on every container start, so once the
  network/token is fixed, stop/start the sandbox (or `sbx kit add <sandbox>
  <kit>` then restart) and it will clone.

## Skills are present but the agent doesn't use them

**Cause:** the agent reads skills from a path this kit didn't populate. The kit
links `~/.agents/skills` (the cross-agent standard) plus per-agent roots
(`~/.claude/skills`, `~/.factory/skills`, `~/.cursor/skills`, `~/.copilot/skills`).

**Fix:** confirm your agent's expected skills directory is among those (see the
README's table) and that the symlinks resolve:
`sbx exec <sandbox> -- sh -c 'ls -l ~/.agents/skills'`. Cursor/Kiro support is
lower-confidence — verify in-sandbox and adjust the kit's link targets if needed.

## Playbook is pinned to an old version

**Cause:** the kit pins `PLAYBOOK_REF`, and an existing clone is never re-fetched
(clone-if-missing only).

**Fix:** bump `PLAYBOOK_REF` in `spec.yaml`, then recreate the sandbox (or remove
`~/.agentic-coding-playbook` inside it and restart so the kit re-clones).

## `AGENTS.md` links are dangling

**Cause:** the clone partially failed, or the playbook layout changed.

**Fix:** confirm `~/.agentic-coding-playbook/AGENTS.md` exists; if not, re-clone
(see the self-heal note above). The kit links best-effort and never fails the
sandbox start on a missing link target.
