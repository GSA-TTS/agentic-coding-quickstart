---
title: "Apply the git-ssh-sign Kit by Default for SSH Commit Signing"
status: accepted
date: 2026-07-02
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["CM-2", "CM-6", "IA-5", "SR-3", "SC-12", "SC-13", "SC-17", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0006: Apply the git-ssh-sign Kit by Default for SSH Commit Signing

> **Editorial note (control correction):** In-text mappings below cite the NIST
> SP 800-53 control **SA-12 (Supply Chain Protection)**, which was **withdrawn in
> Rev 5** and incorporated into **SR-3 (Supply Chain Controls and Processes)**.
> The original prose is preserved as a historical record; read every "SA-12" here
> as its successor **SR-3**. (The frontmatter mapping has been updated to SR-3.)

## Context and Problem Statement

[ADR-0005](0005-kits-from-patterns-and-agent-trust-model.md) established that
`qsbx` applies sbx mixin kits from
[agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns) by
a single pinned `PATTERNS_KIT_REF`. At that point three kits were applied:
`usai-provider`, `agentic-coding-playbook`, and `zscaler-ca-certificate`.

Commits produced inside a sandbox were **unsigned**. Federal guidance favors
attributable, integrity-verified commits (SI-7, SC-17), and unsigned agent
commits make it harder to distinguish agent-authored changes from tampering in
the history. The patterns repo has since vendored a `git-ssh-sign` mixin kit
(PR #200), which signs commits/tags using the SSH key **forwarded from the
host's SSH agent** — the private key never enters the sandbox.

The question: should `qsbx` apply `git-ssh-sign` to every sandbox by default,
and at which pinned ref?

## Decision

### Bump `PATTERNS_KIT_REF` to include git-ssh-sign

Advance the single `PATTERNS_KIT_REF` from `598a57c…` to
`b791e04a4dd6b97fe2cf172897e8cb3e9ddef1a1` (patterns `main` at the PR #200
merge, which adds `git-ssh-sign`). The three existing kits are unchanged between
those commits, so this bump is purely additive. Pinning by full SHA continues to
defeat content substitution through the ZScaler TLS-inspecting proxy (SA-12,
SI-7), per ADR-0005.

### Apply git-ssh-sign as a fourth default kit

Add `GITSSHSIGN_KIT` to the built-in `KITS` list, so every `qsbx`-created
sandbox signs commits and tags by default:

- The kit writes the signing config to the **system** gitconfig at create time
  (`gpg.format ssh`, `commit.gpgSign true`, `tag.gpgSign true`) and resolves the
  signing key at commit time from the forwarded SSH agent
  (`gpg.ssh.defaultKeyCommand`). No key material is written into the sandbox at
  create/startup (SC-12, IA-5).
- The **private key never leaves the host** (SC-12/SC-13): only the SSH agent is
  forwarded, and signing reads the public key via `ssh-add -L`.
- If no key is loaded on the host, the kit **fails closed** — commits are refused
  with a clear error rather than silently unsigned.

### `qsbx` warns up front when no host key is loaded

Because the kit fails closed at commit time, `qsbx` checks the host SSH agent
before attaching (`warn_if_no_ssh_signing_key`) and prints an advisory with the
fix (`ssh-add ~/.ssh/id_ed25519`) if no key is loaded. This is **advisory only**
— it never blocks attach, since the user may not intend to commit in that
session.

## Consequences

- **BREAKING:** committing inside a `qsbx`-created sandbox now requires an SSH
  key loaded in the **host** SSH agent. With no key loaded, commits and tags
  **fail closed** (are refused) rather than being created unsigned. Users who
  previously committed from a sandbox without any SSH agent setup must now run
  `ssh-add <key>` on the host first. `qsbx` warns up front, and non-committing
  work is unaffected. (See also the migration note in the README.)
- **Better:** commits/tags from sandboxes are signed and attributable by
  default, with the signing key never entering the sandbox. Verification of
  a signed commit against an identity is a follow-on step the user controls
  (matching `user.email` to a verified GitHub identity, and registering the key
  as a *signing* key). `qsbx` surfaces a missing identity up front and the
  quickstart documents the end-to-end path; see
  [ADR-0007](0007-commit-verification-identity-guidance.md) and
  [patterns#211](https://github.com/GSA-TTS/agentic-coding-patterns/issues/211).
- **New host dependency:** committing inside a sandbox now requires an SSH key
  loaded in the host agent. Without it, commits fail closed. The up-front warning
  mitigates surprise; non-committing work is unaffected.
- **Signed-commit expectations:** downstream repos with branch protection
  requiring signed commits are now satisfied by default from sandboxes.
- The change is a one-line ref bump plus one kit entry, consistent with
  ADR-0005's model. Kit-internal rationale (vendored from
  `docker/sbx-kits-contrib`, schemaVersion 1→2) lives with the kit in the
  patterns repo (`docs/decisions/`).

## Validation

- `qsbx` verified on sbx v0.34.0 (macOS host): a fresh `qsbx run` stands up a
  sandbox with all four kits applied; with a host SSH key loaded, `git commit`
  inside the sandbox produces a signed commit (`git log --show-signature`); with
  no key loaded, `qsbx` prints the advisory before attaching and commits fail
  closed with the kit's error.
- Kit-level behavior is validated by the kit's own `scripts/verify` in the
  patterns repo.

## Links

- Related: [ADR-0005](0005-kits-from-patterns-and-agent-trust-model.md) (kits by
  pinned reference), [ADR-0001](0001-sbx-usai-agent-execution-architecture.md)
  (SBX isolation)
- Kit: `agentic-coding-patterns/integrations/isolation/sbx-kits/git-ssh-sign`
  (added in patterns PR #200)
