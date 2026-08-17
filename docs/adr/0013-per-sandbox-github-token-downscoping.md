---
title: "Constrain the GitHub Token Per-Sandbox to the Mounted Repositories"
status: accepted
date: 2026-07-24
decision_makers: ["Bret Mogilefsky"]
category: security
nist_controls: ["AC-3", "AC-6", "IA-5", "SC-12", "AU-2", "CM-7"]
impact_level: low
ato_relevance: yes-process
risk_treatment: mitigate
supersedes: []
---

# ADR-0013: Constrain the GitHub Token Per-Sandbox to the Mounted Repositories

## Context and Problem Statement

The quickstart's "Configure secrets and policy" step (README Step 3,
`docs/QUICKSTART_SBX.md`) tells the user to store their GitHub credential **once,
globally**:

```bash
gh auth token | sbx secret set -g github --force
```

`gh auth token` emits the user's `gh` CLI OAuth token, which carries broad
account-wide scopes (typically `repo`, `workflow`, `delete_repo`, `gist`,
`admin:ssh_signing_key`, `read:org`, …). Stored `-g` (global), the sbx proxy
injects it into **every** sandbox for **every** project. The result: an agent
working on project A can act as the user on **all** of the user's GitHub
repositories — read private code, push, delete repos — none of which is in the
sandbox's mounted workspace.

This violates least privilege (AC-6). The sandbox's filesystem is already
constrained to the mounted paths (ADR-0001); its GitHub authority should be
similarly constrained to the repositories those paths actually contain.

We want each sandbox to hold a GitHub credential scoped to only the repos in its
mounted workspace, derived from the `.git` remotes found there.

## Decision

`acq` **detects the GitHub repositories in the mounted workspace** (by parsing
`remote.origin.url` of each `.git` directory, reusing the capped, symlink-safe
scan already in `warn_if_no_git_identity`) and, on `acq run` and `acq create`,
**guides the user to mint a GitHub fine-grained personal access token (PAT)
scoped to exactly those repositories**, stored **sandbox-scoped**
(`acq.<sandbox>.github`) rather than globally.

Concretely:

- A new `github_scope_sandbox` flow builds a **pre-filled fine-grained-PAT
  creation URL** (`https://github.com/settings/personal-access-tokens/new?…`)
  with `target_name=<owner>`, a name derived from the sandbox, `expires_in=30`,
  and the minimal default permissions `contents=write` + `pull_requests=write` +
  `issues=write` + `actions=read` (`metadata:read` and the read levels are
  implied). `actions=read` lets the agent read the Actions workflow-run status
  that surfaces most PR checks (fine-grained PATs cannot call the Checks API — a
  GitHub limitation, see Consequences). The default is deliberately held to
  least privilege: `actions` is **read-only** (write additionally grants
  cancel-runs and delete-logs/artifacts, which cut against the AU-2 audit
  consequence below), and **no `workflows` scope** is requested by default
  (`workflows=write` grants create/edit of `.github/workflows/*` — a CI
  privilege-escalation vector: a workflow the agent can author runs with the
  repo's `GITHUB_TOKEN` and secrets). Users who need agent-driven re-runs or
  workflow edits widen the scope in the GitHub form (the notice tells them how).
  The user clicks it, selects **only** the named repositories, generates the
  token, and pastes it back.
- The token is read from the TTY (never argv), stored in the acq-neutral secret
  store keyed `acq.<sandbox>.github`, and fed to the sbx proxy as the `github`
  built-in for that sandbox — the same injection path as a global github secret,
  the agent never sees the value.
- On `acq run` and `acq create`, when the workspace has GitHub repos **and no
  sandbox-scoped github secret exists** (whether or not a broad global one
  exists), `acq` prints an advisory and, on an interactive TTY, offers
  `[continue / scope now]` (default: continue). This follows the repo's
  **warn-not-block** convention
  (matching `warn_if_no_ssh_signing_key` / `warn_if_no_git_identity`) — it never
  blocks a run and is a no-op in CI / non-TTY.
- The global `sbx secret set -g github` path is **deprecated in the docs** (kept
  working for back-compat), and the per-sandbox scoped flow becomes the
  documented default.

Multiple distinct owners in one workspace are handled by guiding one token per
owner (fine-grained PATs are single-owner by design).

## Considered Alternatives (rejected)

Investigation (`docs/explorations/downscoping-github-credentials-for-local-agents.md`)
established that most "automatic downscoping" paths are not available to a local
wrapper that only holds the user's `gh` token:

1. **`POST /applications/{client_id}/token/scoped`** ("create a scoped access
   token") — *can* downscope a user-to-server OAuth token to specific
   repos/permissions, **but requires OAuth-App HTTP Basic auth
   (`client_id:client_secret`)**. A bare `gh` user token as bearer returns
   `404` (verified). `acq` does not hold `gh`'s client secret, so this is not
   usable. **Rejected.**

2. **Downscope the `gh` token directly** — there is no `gh` subcommand or
   supported API to narrow an existing user token. **Rejected.**

3. **Programmatically mint a fine-grained PAT** — there is **no API and no `gh`
   command** to create a fine-grained (or classic) PAT; creation is web-UI only.
   The org endpoints only approve/deny/list/revoke. We therefore **guide** the
   web-UI creation (with a pre-filled URL) rather than automate it. This is the
   accepted approach; the "no API" limitation is why it is guided, not silent.

4. **GitHub App installation token** (`POST /app/installations/{id}/access_tokens`
   with `repositories`/`permissions`) — the *only* fully-automatable per-repo
   path (JWT auth, 1-hour TTL, no client secret, no web UI). Mature local tooling
   exists (`Link-/gh-token`, `AmadeusITGroup/gh-app-auth`,
   `bdellegrazie/git-credential-github-app`). **Deferred, not rejected:** it
   requires a registered GitHub App, the App installed on the GSA-TTS account,
   and `acq` holding the App's private key — an org-admin dependency that would
   block shipping. This is the recommended future evolution once such an App
   exists; at that point the same `github_scope_sandbox` seam can mint an
   installation token automatically instead of guiding a PAT.

5. **Jentic One credential broker** — brokers **REST/HTTP** calls with
   per-operation `allow`/`deny` below the token's own scopes, and the agent never
   holds the upstream token. But it **cannot broker git-over-HTTPS**
   (`git clone`/`fetch`/`push` use the smart-HTTP protocol, which is not
   OpenAPI-describable and not registrable), must run **outside** the agent's
   sandbox to preserve its trust boundary, and is **Public Beta** ("not
   recommended for production"). It would only constrain `gh api`-style REST
   actions, not the core git loop. **Out of scope.**

6. **Network egress firewall** (Anthropic Claude Code's `init-firewall.sh`
   pattern; and this repo's existing `sbx policy allow network`) — constrains
   **where** traffic goes (allowlist GitHub + USAi, drop the rest), which is a
   valuable exfiltration control, but **cannot** constrain **which repository**
   an authenticated GitHub request touches. It does not solve this problem.
   **Out of scope for this ADR** (the SBX/egress boundary remains the complementary
   control per ADR-0001).

## Consequences

- **Least privilege (AC-6):** a compromised or prompt-injected agent in one
  sandbox can only reach the repositories that sandbox mounts, with the
  permissions the user granted — not the user's entire GitHub account.
- **One manual step per new sandbox:** minting a fine-grained PAT is web-UI only,
  so scoping a new sandbox requires a browser round-trip. The pre-filled URL and
  named repo list minimize the friction; the flow is skippable (warn-not-block).
- **Fine-grained PAT limitations apply:** fine-grained PATs cannot contribute to
  public repos where the user is not a member, cannot be used by outside
  collaborators, cannot access multiple orgs at once, and cannot call the Checks
  API. The docs note these so users know when to fall back to the (broader)
  global token.
- **msb backend:** `msb` binds the `github` secret to the REST API and
  git-transport hosts (`msb.sh`; see ADR-0011). A static re-verification against
  msb 0.6.9 found the substitution engine rewrites the `Authorization: Basic`
  header git smart-HTTP uses, so a scoped token is eligible for injection on both
  REST and HTTPS git transport without the real value entering the guest — the
  same least-privilege scoping this ADR describes applies unchanged. The live
  git clone/push confirmation on a KVM host is still pending (ADR-0011), so treat
  msb git-HTTPS auth as eligible-but-not-yet-live-verified.
- **Deprecation, not removal:** the global path keeps working, so existing setups
  are not broken; new guidance steers to per-sandbox scoping.
- **Audit (AU-2):** scoping is per-sandbox and named, so which credential a
  sandbox holds is discoverable via the acq secret store keys.

## Validation

- Offline unit coverage in `scripts/test-acq`: remote-URL → `owner/repo` parsing
  (https + ssh + `.git` suffix), pre-filled-URL construction, multi-owner
  handling, and that the advisory fires exactly when
  (workspace has repos) ∧ (no sandbox-scoped github secret) — independent of
  whether a global secret exists.
- Live end-to-end (minting a real PAT, injecting it, and confirming a
  scoped push succeeds while an out-of-scope repo is denied) is a manual
  verification step recorded in the PR, since it requires a real GitHub account
  and browser.

## Links

- Exploration: `docs/explorations/downscoping-github-credentials-for-local-agents.md`
- Related: ADR-0001 (SBX isolation is the complementary boundary),
  ADR-0005 (github token needed for the private playbook clone),
  ADR-0011 (msb github-secret binding + git-HTTPS substitution eligibility),
  ADR-0012 (backend-neutral secret handling)
- GitHub docs: "Managing your personal access tokens" (fine-grained PAT URL
  pre-fill parameters), "Create a scoped access token" (requires client secret),
  "Create an installation access token for an app".
