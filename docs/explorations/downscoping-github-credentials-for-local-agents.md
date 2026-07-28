# Down-scoping GitHub credentials for local AI coding agents / sandboxes

**Status:** research note (informational — not a decision)
**Question:** How do people automate *down-scoping* of GitHub credentials for a **local** wrapper (like `sbx`/devcontainer) that mounts local directories and injects a token, so an agent can only act on the repositories in the mounted workspace rather than the developer's whole GitHub account? (Not GitHub Actions CI — that's the easy case.)

> Scope note: This is a survey of *primary sources* (GitHub REST docs, GitHub CLI source, tool READMEs). All claims below are cited. Anything not directly stated in a source is flagged as inference.

---

## TL;DR

- The only GitHub mechanism that natively means **"a short-lived token scoped to a specific set of repos with specific permissions"** and can be minted **fully non-interactively from a local CLI** is a **GitHub App installation access token** (`POST /app/installations/{id}/access_tokens` with `repositories`/`permissions` in the body). It requires a **GitHub App + private key + the app installed** on the target account, but **no client secret and no web UI at token-mint time**. TTL is **1 hour**. This is the mainstream approach and there is mature local tooling for it (git credential helpers, `gh` extensions).
- `POST /applications/{client_id}/token/scoped` ("Create a scoped access token") **can** down-scope a user-to-server OAuth token to specific repos/permissions, **but it requires OAuth-App/GitHub-App HTTP Basic auth (`client_id:client_secret`)** — the client secret. A bare user OAuth token as bearer returns **404** (which is the documented behavior for invalid credentials on the `/applications/{client_id}/...` family). So it is **not** usable by a local wrapper that only holds the `gh` user token.
- `gh`'s own token comes from GitHub's **public OAuth App** (`client_id 178c6fc778ccc68e1d6a`). The client secret **is embedded in the open-source binary**, but using it to down-scope `gh`'s token is not a supported/first-class path and is fragile (see caveats). There is **no `gh` command** that down-scopes its own token.
- **Fine-grained PATs cannot be created programmatically.** There is **no REST/GraphQL/`gh` endpoint to create a fine-grained (or classic) PAT**; creation is strictly the web UI (`github.com/settings/personal-access-tokens/new`). Org-level PAT endpoints only *approve/deny/list/revoke* tokens users created — they do not mint them.

---

## 1. `POST /applications/{client_id}/token/scoped` — "Create a scoped access token"

**What it is (from the docs):** "Use a non-scoped user access token to create a repository-scoped and/or permission-scoped user access token. You can specify which repositories the token can access and which permissions are granted to the token. Invalid tokens will return 404 NOT FOUND." Body: `access_token` (required), `target`/`target_id`, `repositories`/`repository_ids`, `permissions{…}`.
Source: <https://docs.github.com/en/rest/apps/oauth-applications#create-a-scoped-access-token>

**Auth requirement (the key constraint):** The whole `/applications/{client_id}/...` endpoint family is authenticated with **HTTP Basic auth using the app's `client_id` as username and `client_secret` as password** — not the user token as bearer. GitHub's authentication guide states this explicitly: *"Some REST API endpoints for GitHub Apps and OAuth apps require you to use basic authentication… You will use the app's client ID as the username and the app's client secret as the password,"* with the example `curl … --user "YOUR_CLIENT_ID:YOUR_CLIENT_SECRET" … /applications/YOUR_CLIENT_ID/token`.
Source: <https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api#using-basic-authentication>

**Why a bare `gh` user token returns 404:** The same guide says a request with insufficient/invalid credentials to these endpoints returns **404 Not Found** (the endpoints deliberately return 404 for invalid tokens; see the "Check a token" endpoint note "Invalid tokens will return 404 NOT FOUND" and the "Failed login limit" section).
Sources:
- <https://docs.github.com/en/rest/apps/oauth-applications#check-a-token> (404 for invalid)
- <https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api#failed-login-limit>

**What it can do:** Yes — it down-scopes a **user-to-server** token (i.e. a GitHub-App user token, `ghu_`, or an OAuth-App token, `gho_`) to a subset of repos and a subset of permissions the user+app already hold. The response's `installation` object echoes the scoped `permissions` and `repository_selection`. This is genuinely a "downscope this user token" primitive.
Source (response schema with `Scoped Installation`): <https://docs.github.com/en/rest/apps/oauth-applications#check-a-token>

**Real-world constraints:**
- **Requires the client secret** (Basic auth). A local sandbox wrapper that only injects the developer's `gh`/user token cannot call it. (Inference from the Basic-auth requirement above.)
- Only works for **user-to-server** tokens tied to *that* `client_id`. You cannot down-scope an arbitrary PAT this way. (Inference from endpoint semantics — it is under `/applications/{client_id}/`.)
- The octokit strategy that wraps token creation/reset for OAuth explicitly says it **requires `client_secret` and "must not be exposed"** and cannot run in a browser/client — reinforcing that this whole family is a *confidential-client* (server-side) operation, not a local-client one.
  Source: <https://github.com/octokit/auth-oauth-user.js> ("`@octokit/auth-oauth-user` requires your app's `client_secret`, which must not be exposed…").

**Verdict for a local wrapper:** Not viable unless the wrapper is willing to hold an OAuth/GitHub-App **client secret** locally (which defeats much of the point and is a confidential-client anti-pattern on a dev machine).

---

## 2. Can a user down-scope the `gh` CLI token without the client secret?

**`gh`'s token identity:** `gh` performs an OAuth web/device flow against **GitHub's public "GitHub CLI" OAuth app**. In `cli/cli`'s source:

```go
// The "GitHub CLI" OAuth app
oauthClientID     = "178c6fc778ccc68e1d6a"
// This value is safe to be embedded in version control
oauthClientSecret = "34ddeff2b558a23d38fba8a6de74f086ede1cc0b"
minimumScopes := []string{"repo", "read:org", "gist"}
```

Source: <https://github.com/cli/cli/blob/trunk/internal/authflow/flow.go>

So `gh`'s token is a broad **OAuth-App user token** with `repo` scope (whole account), not a fine-grained token.

**Down-scoping it:**
- There is **no `gh` subcommand** to down-scope its own token. (Inference — no such command exists in the CLI; `gh` exposes `gh auth token` to *print* it, not to scope it.)
- Because `gh` is an **OAuth App** (not a fine-grained/GitHub App), even calling `POST /applications/178c6fc.../token/scoped` would need `client_id:client_secret` Basic auth (§1). The client secret is famously embedded in the binary ("This value is safe to be embedded in version control" per the source above), so it is *technically* obtainable — but:
  - OAuth-App tokens scoped via this endpoint are still **OAuth scopes** semantics, and the `repo` scope is all-or-nothing at the account level for *classic* scope; the endpoint's `repositories`/`permissions` do produce a repo-restricted token, but you are relying on an **undocumented-for-this-purpose** use of GitHub's own app credentials.
  - Relying on another product's embedded secret is fragile (it can rotate) and is **not a supported integration path**. (Inference / caveat.)

**Verdict:** No clean, supported technique. Treat `gh`'s token as broad and non-downscopable in practice.

---

## 3. Fine-grained PATs — any programmatic/non-interactive creation?

**Creation:** There is **no API to create a PAT** (fine-grained or classic). GitHub's own docs route creation exclusively through the web UI, and the fine-grained-PAT endpoint list contains only *read/approve/deny/revoke* operations, never a "create token" call.

- The org-level endpoints (`GET/POST /orgs/{org}/personal-access-token-requests`, `GET/POST /orgs/{org}/personal-access-tokens`) are for an **org admin (via a GitHub App) to list, approve, deny, or revoke** members' fine-grained PATs — **"Limited to revoking a token's existing access"** and **"Only GitHub Apps can use this endpoint."** None mints a token.
  Source: <https://docs.github.com/en/rest/orgs/personal-access-tokens>
- The list of endpoints a fine-grained PAT can *call* does not include any self-mint endpoint.
  Source: <https://docs.github.com/en/rest/authentication/endpoints-available-for-fine-grained-personal-access-tokens>

**Verdict:** Fine-grained PATs are **web-UI-only to create** — unusable for non-interactive local minting. Org automation can only *govern* (approve/revoke) them, not create them.

---

## 4. GitHub App installation tokens — the mainstream "downscope to specific repos, 1-hour" approach

**Endpoint:** `POST /app/installations/{installation_id}/access_tokens`, authenticated with a **JWT signed by the App's private key** (not a client secret). Body may include:
- `repositories` / `repository_ids` — "specify individual repositories that the installation access token can access… up to 500 repositories." Cannot exceed what the installation was granted.
- `permissions` — subset of the app's granted permissions.
- **TTL: "Installation tokens expire one hour from the time you create them."**

Sources:
- <https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app>
- <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app>

This is exactly "downscope to specific repos + specific permissions, short-lived." It is fully non-interactive given `{app_id/client_id, private_key, installation_id}`.

> Note (2026): GitHub is rolling out a stateless installation-token format (`ghs_APPID_JWT`); tools that assume a 40-char token may break. Source: the endpoint doc above.

### Tools that do this OUTSIDE Actions (local CLI)

| Tool | Lang | What it does | Source |
|---|---|---|---|
| **`Link-/gh-token`** | Go | `gh` CLI extension **and** standalone binary: `gh token generate --key key.pem --app-id … --installation-id …` → prints `{token, expires_at, permissions}`. Also `revoke`, `installations`. Works with GHES. | <https://github.com/Link-/gh-token> |
| **`actions/create-github-app-token`** | JS | Official Action; "creates an installation access token using `POST /app/installations/{id}/access_tokens`," supports `repositories:` and `permission-*:` inputs, auto-revokes in `post`. Local use is possible but it's an Action wrapper. | <https://github.com/actions/create-github-app-token> |
| **`slawekzachcial/gha-token`** | Go | CLI to mint installation tokens (listed as similar-art by `gh-token`). | <https://github.com/slawekzachcial/gha-token> |
| **`jakewilkins/apptokit`** | Ruby | CLI for app/installation tokens. | <https://github.com/jakewilkins/apptokit> |
| **`@octokit/auth-app`** (implied) | JS | Octokit strategy that mints/refreshes installation tokens from `{appId, privateKey, installationId}` — no client secret. | <https://github.com/octokit> (auth-app) |

`octoherd`, `peter-murray/workflow-application-token-action`, `getsentry/action-github-app-token`, `navikt/github-app-token-generator` are all Action-oriented variants of the same primitive (listed by `gh-token`'s "similar projects").
Source: <https://github.com/Link-/gh-token> ("Similar projects").

---

## 5. Devcontainer / sandbox / "AI agent" per-workspace credential scoping

Concrete prior art found:

- **`AmadeusITGroup/gh-app-auth`** — a `gh` CLI extension that is *purpose-built* for the exact pattern in question: it is a **git credential helper** that mints **GitHub-App installation tokens** and routes them **per repository URL prefix** ("longest-prefix matching"), so different orgs/repos get different apps. Tokens are cached **in-memory only (55-min TTL, not persisted to disk)**, private keys held in the OS keyring. It ships a `.devcontainer/`. Config example routes `github.com/myorg/` → a specific `app_id`/`installation_id`.
  Source: <https://github.com/AmadeusITGroup/gh-app-auth>
  - Usage: `git config --global credential."https://github.com/myorg".helper "!gh app-auth git-credential --pattern 'github.com/myorg/*'"`.
  - This is the closest thing to "scope git credentials per-workspace" as a maintained tool.

- **Anthropic Claude Code devcontainer** — does **not** scope the token; it scopes the **network** instead. `init-firewall.sh` builds an `ipset` allowlist from `api.github.com/meta` and drops all other egress, so a broad token can only talk to GitHub (and a few allowlisted hosts). This is the "network boundary instead of credential boundary" approach — relevant because it's the same trust model as this repo's SBX boundary.
  Source: <https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh>

- General pattern (inference): none of the mainstream sandbox tools down-scope the *user's* token to the mounted repos automatically; they either (a) inject a broad token and rely on an **isolation/network boundary** (Claude Code, and this repo's SBX model per `AGENTS.md`), or (b) swap in a **GitHub-App installation token via a credential helper** (`gh-app-auth`, `git-credential-github-app`).

---

## 6. `gh` extensions / community tools that mint scoped/installation tokens locally

- **`Link-/gh-token`** (`gh token generate …`) — §4. 400★. <https://github.com/Link-/gh-token>
- **`AmadeusITGroup/gh-app-auth`** (`gh app-auth …`) — §5, credential-helper + per-prefix routing. <https://github.com/AmadeusITGroup/gh-app-auth>

No community tool was found that mints a **fine-grained PAT** or that down-scopes the **`gh` user token** locally (consistent with §2/§3 constraints).

---

## 7. Git credential-helper approaches (dynamic, per-remote, short-lived token)

Yes — this is well-trodden **for GitHub Apps** (not for user tokens). A credential helper is invoked by git per-remote with the host/path, so it can hand out a **repo/org-scoped installation token** keyed on the remote:

| Helper | Lang | Notes | Source |
|---|---|---|---|
| **`bdellegrazie/git-credential-github-app`** | Go | Credential helper for GitHub Apps; **per-installation credential contexts** with `useHttpPath=true` so each `github.com/<org>` maps to its own installation; pairs with `git-credential-cache` (token TTL 1h → cache ≥2h). Can `generate` the recommended gitconfig. | <https://github.com/bdellegrazie/git-credential-github-app> |
| **`ericnorris/git-credential-github-app`** | Go | Credential helper with **GCP KMS** support (private key never on disk; IAM controls *use* of the key). `--client-id --installation-id`. | <https://github.com/ericnorris/git-credential-github-app> |
| **`mackee/git-credential-github-apps`** | Go | Credential helper; can resolve installation ID from org name; caches token until expiry. | <https://github.com/mackee/git-credential-github-apps> |
| **`westphahl/git-credential-github-app-auth`** | Rust | Same idea. | <https://github.com/westphahl/git-credential-github-app-auth> |
| **`uw-ipd/git-credential-github-app-auth`** | Python | Same idea. | <https://github.com/uw-ipd/git-credential-github-app-auth> |

Key design detail (from `bdellegrazie`): set **narrow `credential.<context>` first** with `useHttpPath = true`, put the broad `https://github.com` cache last. This gives you *per-org/per-repo* token issuance driven by the remote URL — i.e. effectively "per-workspace" if the workspace's remotes determine which installation is used.
Source: <https://github.com/bdellegrazie/git-credential-github-app>

`hub`/`gfold` are **not** relevant here (`hub` is a legacy wrapper; `gfold` is a repo-status tool) — no dynamic scoped-token issuance. (Inference — neither advertises credential-helper token minting.)

---

## Structured comparison

| Mechanism | (a) What | (b) Fully automatable from local CLI, no web UI? | (c) Prerequisites | (d) Token TTL | (e) Sources |
|---|---|---|---|---|---|
| **GitHub App installation token** (`POST /app/installations/{id}/access_tokens`) | Short-lived token scoped to chosen repos + permissions | **Yes** (JWT from private key; `repositories`/`permissions` in body) | GitHub App + private key + app installed on target; `installation_id` | **1 hour** | docs/apps#create-an-installation-access-token; generating-an-installation-access-token |
| **`token/scoped`** (`POST /applications/{client_id}/token/scoped`) | Downscope an existing user-to-server token to repos/perms | **No** — needs `client_id:client_secret` Basic auth | OAuth/GitHub App **client secret** + a user-to-server token for that app | Inherits/echoes user token (no independent short TTL) | rest/apps/oauth-applications#create-a-scoped-access-token; authentication#using-basic-authentication |
| **`gh` user token down-scope** | Scope `gh`'s OAuth token | **No supported path** | Would need `gh`'s embedded client secret; fragile | n/a | cli/cli authflow/flow.go |
| **Fine-grained PAT** | Repo/permission-scoped PAT | **No** — web-UI-only to create | Human at github.com; org can only approve/revoke | up to 1 year (user-chosen) | rest/orgs/personal-access-tokens; endpoints-available-for-fine-grained-pats |
| **Git credential helper (App-based)** | Per-remote dynamic installation token | **Yes** | Same as installation token (App+key+install) + git config | 1 hour (cached) | bdellegrazie / ericnorris / mackee credential helpers |
| **Network boundary (no downscope)** | Broad token, restrict egress | **Yes** | Firewall/sandbox | n/a | claude-code init-firewall.sh |

---

## Which approaches are realistic for a local sandbox wrapper (`acq`/`sbx`) to adopt

1. **GitHub App installation token, minted at sandbox start, scoped to the mounted repos** — *the realistic "true down-scope" option.*
   - Wrapper reads the workspace's git remotes → resolves `owner/repo` → calls `POST /app/installations/{id}/access_tokens` with `repository_ids` + minimal `permissions` (e.g. `contents:write, pull_requests:write`).
   - Inject the resulting `ghs_…` token (1-hour TTL) instead of the broad `gh` token.
   - Prereqs the org must accept: **register one GitHub App, install it, hold its private key** (ideally in KMS/keyring, cf. `ericnorris`). No client secret, no web UI at runtime.
   - Reuse existing tooling rather than build: `Link-/gh-token` (mint) or `AmadeusITGroup/gh-app-auth` (credential-helper + per-prefix routing) or `bdellegrazie/git-credential-github-app` (pure helper). Watch the 2026 `ghs_APPID_JWT` token-format change.

2. **Git-credential-helper (App-based), configured per-org context** — same primitive as (1) but issued lazily per-remote; good when a workspace spans multiple orgs. `bdellegrazie` / `AmadeusITGroup` patterns.

3. **Keep the broad token but rely on the isolation/network boundary** — this is what Claude Code does and matches this repo's stated model (`AGENTS.md`: "SBX is the security boundary"). Lowest friction, but does **not** limit which repos the token can touch — only which *hosts* it can reach. Acceptable only if the sandbox boundary is trusted and the token can't exfiltrate.

**Not realistic:** `token/scoped` (needs a client secret on the dev box), down-scoping the `gh` token (no supported path), and programmatic fine-grained-PAT creation (web-UI-only).

---

## Follow-ups worth tracking (not done here)

- Verify the 2026 stateless installation-token format (`ghs_APPID_JWT`) against whatever consumes the token in the sandbox.
- If option (1) is pursued: file an ADR (new external dependency + new auth flow → ADR trigger per repo `AGENTS.md` §Engineering Discipline) covering GitHub App registration, private-key storage (KMS/keyring vs file), and installation-ID discovery.
