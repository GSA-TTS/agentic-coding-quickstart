---
title: "Commit Verification: Guide Identity Setup, Warn on Missing Identity"
status: accepted
date: 2026-07-03
decision_makers: ["Bret Mogilefsky"]
category: configuration-management
nist_controls: ["AC-6", "CM-6", "IA-5", "PL-4", "SC-17", "SI-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0007: Commit Verification — Guide Identity Setup, Warn on Missing Identity

## Context and Problem Statement

[ADR-0006](0006-git-ssh-sign-kit.md) made `qsbx` apply the `git-ssh-sign` kit by
default, so commits from a sandbox are **signed** with the SSH key forwarded from
the host's agent. Signing, however, is not the same as GitHub's **Verified**
badge. GitHub marks an SSH-signed commit **Verified** only when **both**:

1. the commit's `user.email` matches an email **verified on the committer's
   GitHub account**, and
2. the **public** signing key is registered on that account **as a _signing_
   key** (not just an authentication key).

The `git-ssh-sign` kit deliberately does not set `user.email` / `user.name`
(identity belongs in the base/provider layer, not a signing mixin), and neither
do the sibling kits (`usai-provider`, `agentic-coding-playbook`,
`zscaler-ca-certificate`). Net effect: a standard `qsbx` sandbox produces
**signed-but-Unverified** commits until the user configures a verified identity
and registers a signing key. This is the gap raised upstream in
[agentic-coding-patterns#211](https://github.com/GSA-TTS/agentic-coding-patterns/issues/211).

The question for **this** repo (the `qsbx` wrapper): what should the wrapper do
about the identity gap, given that the kit-level fix (a `git-identity` mixin, or
having the provider/base kit set identity) lives in the patterns repo?

## Decision

`qsbx` owns **documentation plus a thin, advisory host-side check**. It does
**not** set or forward a git identity automatically.

### 1. Warn, do not enforce (`warn_if_no_git_identity`)

Before attaching, `qsbx` checks whether a `user.email` will resolve for commits
inside the sandbox and, if not, prints an advisory (mirroring the existing
`warn_if_no_ssh_signing_key`): commits will be signed but show **Unverified**
until the user sets a GitHub-verified identity and registers the signing key as a
_Signing Key_. The advisory is **purely informational** — it prints to stderr,
never blocks attach, and never changes the exit path. It fails open if `git` is
absent.

### 2. Check only the repo-local identity (the sole tier the sandbox sees)

The critical constraint: **only the workspace's repo-local git identity crosses
into the sandbox.** sbx mounts the workspace (so the repo's `.git/config` is
visible at the same absolute path), but the sandbox has its **own empty home
directory** — the host's **global** (`~/.gitconfig`) and system git identity are
**not** present inside it. So `qsbx` inspects **only** the repo-local config
(`git -C <path> config --local user.email`). A plain `git config` lookup would
fall through to the host global and give a **false negative** — staying silent
even though the sandbox will have no identity — which is exactly the failure this
check must catch.

On the attach-by-name form of `qsbx run` (no workspace path in the args) there is
nothing host-side that reliably predicts the sandbox identity, so the check is a
**no-op** there rather than consulting the (irrelevant) host global config.

### 3. Do not inject or forward identity

`qsbx` will not write `user.email`/`user.name` into the sandbox or forward the
host's global identity automatically. Injecting identity is a behavior change
that belongs closer to the provider/base layer and warrants its own decision in
the patterns repo; forwarding silently would also weaken least-privilege
clarity (AC-6) about where a committer identity came from. The wrapper's job is
to make the requirement **visible and easy to satisfy**, not to satisfy it
covertly.

### 4. Document the end-to-end path

The README gains a Troubleshooting entry ("Commits show 'Unverified' on
GitHub") and a Step-3 note covering the two GitHub requirements, the fix, and the
key point that identity must be set **repo-local** (not `--global`) to reach the
sandbox; both cross-reference the kit's `TROUBLESHOOTING.md`. A
`docs/KNOWN_FAILURE_MODES.md` entry captures the same as a tracked failure mode.

## Consequences

- **Better:** the verification requirement is surfaced up front and is easy to
  satisfy; users are not left puzzling over why signed commits show
  "Unverified." Because the check consults only the repo-local config — the sole
  identity tier the sandbox can see — it neither misses the missing-identity case
  (which a host-global lookup would) nor nags repos that already set a local
  identity.
- **Boundary respected:** the wrapper adds no identity mechanism of its own. The
  actual kit-level fix (a `git-identity` mixin or provider-kit identity) remains
  tracked upstream in patterns#211; this repo does not fork that decision.
- **Advisory only:** a missing identity never blocks work — consistent with the
  signing-key warning and with treating identity as user-owned. A user who
  ignores the advisory still gets signed (if Unverified) commits.
- **Limitation:** on the attach-by-name form `qsbx` has no workspace path and the
  host global identity is irrelevant (it never reaches the sandbox), so the check
  is a no-op there — a project that relies on repo-local identity is simply not
  re-checked on plain re-attach. Acceptable for an advisory; noted in the code.

## Validation

- Offline unit checks of `warn_if_no_git_identity` and the new `workspace_path`
  helper: a repo with a repo-local `user.email` is silent **even when a host
  global identity is present**; a repo with no local identity **still warns**
  despite a host global (the false-negative the reviewer caught); an empty path
  is a no-op; the advisory always exits 0; `workspace_path` extracts the second
  positional and strips a `:ro` suffix. (See the ad-hoc harness used during
  development; behavior mirrors `warn_if_no_ssh_signing_key`.)
- `bash -n qsbx` clean; shellcheck (`--severity=warning`) and gitleaks clean;
  markdownlint clean; `./scripts/test-migrate-or-halt` unaffected (33/33).

## Links

- Related: [ADR-0006](0006-git-ssh-sign-kit.md) (git-ssh-sign kit by default),
  [ADR-0005](0005-kits-from-patterns-and-agent-trust-model.md) (kits by pinned
  reference)
- Upstream tracking: [agentic-coding-patterns#211](https://github.com/GSA-TTS/agentic-coding-patterns/issues/211)
  (end-to-end verification / identity gap in the kits)
- Kit troubleshooting: `agentic-coding-patterns/integrations/isolation/sbx-kits/git-ssh-sign/TROUBLESHOOTING.md`
- [GitHub: About commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification)
