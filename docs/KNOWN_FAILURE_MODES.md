---
title: "Known Failure Modes"
description: "Real-world failure patterns when using Docker SBX + USAi + agent frameworks"
status: canonical
tier: 2
last_updated: "2026-07-08"
audience: "developers"
keywords: ["debugging", "troubleshooting", "sbx", "usai", "failures"]
---

# Known Failure Modes

This document captures real-world failure patterns when using Docker SBX + USAi + agent frameworks. If you're hitting something weird, it's probably in here.

---

## 1. "Unknown Agent" Error on sbx create

### Symptoms

- `sbx create my-sandbox` fails
- Error: `unknown agent "my-sandbox"`

### Root Cause

SBX `create` command requires an agent type (e.g., `opencode`, `claude`, `shell`) and a workspace path.

### Fix

Use the correct syntax:
```bash
# Correct: specify agent type and path
sbx create opencode .

# With custom name
sbx create --name my-sandbox opencode .
```

Available agents: `claude`, `codex`, `copilot`, `docker-agent`, `gemini`, `kiro`, `opencode`, `shell`

---

## 2. API Key Works in UI but Fails in Agent

### Symptoms

- Works in Swagger / web UI
- Fails in agent or CLI
- Error: `authentication failed` or `401 Unauthorized`

### Likely Causes

- Incorrect header format
- Missing `Bearer` prefix
- Wrong environment variable injection

### Fix

Ensure header format is correct:
```
Authorization: Bearer <API_KEY>
```

Confirm SBX injected env var is present inside container:
```bash
sbx exec -it <sandbox> sh
echo $USAI_API_KEY
```

---

## 3. Agent Cannot See API Key / USAi Authentication Fails

### Symptoms

- Agent fails silently or errors on auth
- OpenCode shows generic providers instead of USAi
- `{"detail":"Authentication failed"}` from USAi API

### Root Cause

SBX's secret proxy only works with **standard provider endpoints**. USAi uses a custom `baseURL` (`https://api.gsa.usai.gov/api/v1`), which the proxy doesn't recognize.

When you use `sbx secret set -g openai`, SBX:
1. Stores your key
2. Sets `OPENAI_API_KEY=proxy-managed` in the container
3. Intercepts requests to `api.openai.com` and injects the real key

But requests to `api.gsa.usai.gov` bypass this proxy entirely.

### Fix

Store the key as a custom secret so sbx injects it for you:

```bash
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY
```

Recreate the sandbox so the secret takes effect. `opencode.jsonc` reads the
injected value via `{env:USAI_API_KEY}`.

---

## 4. Secrets Accidentally Printed

### Symptoms

- API key appears in logs/output
- Key visible in terminal history

### Root Cause

- Debugging via `printenv` or `env`
- Logging config objects that contain credentials
- Shell history capturing secret values

### Fix

- Never print full environment
- Mask values if debugging required
- Use `set +o history` before working with secrets
- Review agent logs before sharing

---

## 5. Incorrect baseURL

### Symptoms

- Model list fails
- 404 or unexpected API errors
- Connection refused

### Root Cause

Wrong endpoint format in configuration.

### Fix

Use the correct format:
```
https://api.gsa.usai.gov/api/v1
```

NOT:
- Missing `/api/v1` suffix
- Swagger UI URL
- Documentation endpoint
- Trailing slash issues

---

## 6. SBX CLI Behavior Changes

### Symptoms

- Commands stop working between runs
- Flags behave differently than expected
- Documentation doesn't match actual behavior

### Root Cause

SBX tooling is rapidly evolving with frequent breaking changes.

### Fix

- Check `sbx --help` for current syntax
- Check `sbx <command> --help` for subcommand options
- Revalidate commands before assuming code failure
- Avoid scripting around unstable flags
- Pin to specific SBX versions if possible

---

## 7. Agent Tries to Escape Sandbox

### Symptoms

- Attempts to access host filesystem paths
- Unexpected file path errors
- Permission denied on paths that "should" exist

### Root Cause

Agent assumes host filesystem layout, not container layout.

### Fix

- Enforce working directory constraints in AGENTS.md
- Avoid granting unnecessary volume mounts
- Configure agent with container-relative paths
- Review agent file access patterns

---

## 8. Model Appears Available but Fails at Runtime

### Symptoms

- `/models` endpoint lists the model
- Inference requests fail with errors
- "Model not found" despite being listed

### Root Cause

- Model not actually enabled for your API key
- Backend routing mismatch
- Model requires specific parameters not provided

### Fix

- Test with minimal request first
- Confirm model entitlement with USAi provider
- Check if model requires specific `max_tokens` or other params
- Try a different model to isolate the issue

---

## 9. Long Timeouts / Hanging Requests

### Symptoms

- Requests never return
- Agent appears stuck
- Eventually fails with timeout

### Root Cause

- Missing timeout configuration
- Network routing issues inside container
- DNS resolution failures
- Proxy misconfiguration

### Fix

Set explicit timeouts in config:
```json
{
  "requestTimeout": 30000,
  "chunkTimeout": 5000
}
```

Check network connectivity from inside container:
```bash
sbx exec <sandbox> curl -I https://api.gsa.usai.gov/api/v1/models
```

---

## 10. Overcomplicated Setup

### Symptoms

- Too many scripts to run
- Hard to reproduce environment
- Works on one machine, fails on another
- Debugging requires tribal knowledge

### Root Cause

Over-engineering instead of testing. Adding layers when simplicity would work.

### Fix

- Delete unnecessary wrapper scripts
- Prefer 1 config file + 1 command
- Document the minimal reproduction steps
- If setup takes more than 3 commands, simplify

---

## 11. False Sense of Security

### Symptoms

- Assuming "it's in a container so it's safe"
- Relaxing secret handling because of SBX
- Not reviewing agent outputs

### Reality

Containers are NOT perfect isolation:
- Container escapes exist
- Mounted volumes expose host data
- Network access can leak information
- Logs may be captured outside container

### Fix

- Treat SBX as a strong boundary, not absolute
- Continue to avoid exposing secrets at all costs
- Review agent outputs before sharing
- Don't mount sensitive host directories
- Apply defense in depth

---

## 12. Environment Variable Naming Conflicts

### Symptoms

- Agent uses wrong API key
- Configuration seems ignored
- Unexpected behavior with correct config

### Root Cause

Multiple tools expecting different env var names:
- `OPENAI_API_KEY`
- `USAI_API_KEY`
- `API_KEY`
- Tool-specific variations

### Fix

- Check tool documentation for expected variable names
- Set all expected variations if needed
- Use explicit config file settings over env vars when possible

---

## 13. Config File Not Found in Container

### Symptoms

- Agent starts with defaults
- Custom configuration ignored
- "Config file not found" warnings

### Root Cause

Config file exists on host but not mounted into container.

### Fix

Ensure config is in the mounted working directory. When using `sbx run` or `sbx create`, the current directory is automatically mounted:

```bash
# Run from the directory containing your config
cd /path/to/project-with-config
sbx run opencode .
```

Or copy config into an existing container:

```bash
sbx cp ./opencode.jsonc my-sandbox:/workspace/
```

---

## 14. SBX Proxy Doesn't Work with Custom baseURL (Security Implication)

### Symptoms

- `sbx secret set -g openai` succeeds
- But USAi authentication still fails
- `OPENAI_API_KEY=proxy-managed` in container
- Must inject the key via a custom secret instead

### Root Cause

SBX's secret proxy intercepts requests to **known provider endpoints** (like `api.openai.com`) and injects credentials. Custom `baseURL` endpoints like USAi (`api.gsa.usai.gov`) are not proxied.

### Security Implication

**For custom endpoints, the agent CAN see the API key.**

With proxy-based injection (standard providers):
- Agent sees: `OPENAI_API_KEY=proxy-managed`
- Real key is injected at the proxy level
- Agent never has access to the raw credential

With a custom secret (USAi/custom endpoints):
- Agent sees: `USAI_API_KEY=<actual-key-value>`
- Key exists in container environment
- Agent process can read it

### Mitigations

1. **AGENTS.md rules** prohibit printing/logging secrets
2. **Container isolation** limits exposure scope
3. **No persistence** - key never written to disk
4. **Memory only** - key exists only during execution

### Fix

Store the key as a custom secret so sbx injects it into the sandbox:

```bash
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY
```

Your `opencode.jsonc` should use variable substitution:
```json
{
  "provider": {
    "usai": {
      "options": {
        "apiKey": "{env:USAI_API_KEY}"
      }
    }
  }
}
```

### Upstream Tracking

This limitation is tracked in **[docker/sbx-releases#35](https://github.com/docker/sbx-releases/issues/35)** - "Feature Request: Configurable Secret Injection for Custom Services"

When implemented, this will allow defining custom service mappings so the proxy can inject credentials for endpoints like USAi without exposing the raw key to the agent.

---

## 15. Direct Credential Injection for Git Providers (Security Consideration)

### Context

GitHub is a built-in SBX service (`sbx secret set -g github`), but GitLab is not. This means:
- **GitHub**: Uses the proxy (recommended)
- **GitLab**: Must use a custom secret (`sbx secret set-custom -g --host <host> --env GITLAB_TOKEN`)

### Security Assessment for MVP

| Concern | Severity | Mitigation |
|---------|----------|------------|
| Token visible in container env | Low | Container is isolated, short-lived |
| Token in shell history | Low | sbx prompts for the value; never typed on the command line |
| Token in process list | Low | Stored secret injected by sbx, not passed via process args |
| Agent could exfiltrate token | Medium | Agent already has network access; proxy doesn't prevent this |
| Token logged by agent | Medium | AGENTS.md prohibits; pre-commit hooks catch committed secrets |

### Key Insight

**The SBX proxy doesn't prevent a malicious agent from exfiltrating credentials** - it prevents the agent from *seeing* them directly. A compromised agent could still make authenticated API calls and exfiltrate data through those APIs.

The real security boundary is:
1. **Sandbox isolation** - container can't escape to host
2. **Trusted agent software** - OpenCode, Claude Code, etc. are vetted
3. **Scoped tokens** - use minimal scopes (e.g., `repo`, not admin)
4. **Short-lived sessions** - tokens only in memory during execution

### Acceptable for MVP Because

1. **Pre-ATO environment** with low-impact data (no PII, no CUI)
2. **Tokens are scoped** - not admin/owner tokens
3. **Sandbox provides isolation** from host system
4. **Direct injection is a documented SBX pattern** - shown in their own docs
5. **Upstream tracking exists** - this is a known gap, not a workaround hack

### Recommendations

1. **Use SBX proxy when available** - GitHub supports it, use `sbx secret set -g github`
2. **Scope tokens minimally** - only grant permissions the agent actually needs
3. **Rotate tokens periodically** - treat injected tokens as potentially exposed
4. **Review agent outputs** - before sharing logs, ensure no tokens leaked
5. **Monitor API usage** - watch for unexpected patterns

If GitHub auth in an existing sandbox starts failing after token rotation,
force-refresh the stored global GitHub secret from the host:

```bash
gh auth token | sbx secret set -g github --force
```

### Upstream Tracking

- **SBX custom service support**: [docker/sbx-releases#35](https://github.com/docker/sbx-releases/issues/35)
- **Helper script exploration**: [GSA-TTS/agentic-coding-quickstart#15](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/15)

### Related

See also: [Section 14 - SBX Proxy Doesn't Work with Custom baseURL](#14-sbx-proxy-doesnt-work-with-custom-baseurl-security-implication)

---

## 16. SSL/TLS Certificate Error: "unable to get local issuer certificate"

### Symptoms

- OpenCode crashes or fails to connect to USAi
- Error: `unable to get local issuer certificate`
- Occurs on GFE (Government Furnished Equipment) networks

### Root Cause

On federal/GFE networks, secure internet traffic is often intercepted and decrypted using a custom Root Certificate Authority (CA) for security inspection.

Because the sandboxed container runs a vanilla Linux environment, it does not automatically trust your host's GFE custom root certificate. When Node.js tries to establish a TLS connection to `https://api.gsa.usai.gov/api/v1`, it rejects the connection because it cannot verify the custom certificate chain.

### Fix

To resolve this during local development, you can tell Node.js to ignore TLS validation errors inside the sandbox using `NODE_TLS_REJECT_UNAUTHORIZED=0`.

> **⚠️ SECURITY WARNING:** Disabling TLS validation bypasses certificate verification, which is a significant security risk. This workaround should **only** be used:
> - For debugging TLS issues in isolated local development environments
> - **Never** with real credentials or production endpoints
> - **Never** in CI/CD pipelines or shared environments

#### Workaround: Pass Environment Variable via SBX

The `sbx run` command does **not** support the `-e` flag for environment variables. Use the two-step `create` + `exec` pattern instead:

```bash
# For debugging TLS issues only - never use with real credentials

# Step 1: Create the sandbox (or skip if it already exists)
sbx create --name debug-sandbox opencode .

# Step 2: Run with environment variable
sbx exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 debug-sandbox opencode
```

Alternatively, combine into a single line:

```bash
sbx create --name debug-sandbox opencode . 2>/dev/null || true && \
sbx exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 debug-sandbox opencode
```

**Important:** Only `sbx exec` supports the `-e` flag, not `sbx run`.

---

## 17. Chose "Open" Network Policy by Mistake

### Symptoms

- Selected "Open" network policy during first sbx run
- Security concern: Open policy allows access to internal GSA resources

### Root Cause

"Open" policy allows all network traffic without restrictions, which is a security risk on GFE (Government Furnished Equipment) machines.

### Fix

Reset and reconfigure:
```bash
# Reset policy (will prompt for new choice)
sbx policy reset

# Choose "Balanced" when prompted, then add USAi
sbx policy allow network "api.gsa.usai.gov"

# Verify
sbx policy ls
```

### Prevention

Always choose "Balanced" (Option 2) when prompted. The Balanced policy allows typical dev traffic while blocking internal network access.

---

## 18. Migrating from `docker sandbox`

### Symptoms

- You're using deprecated `docker sandbox ...` commands
- Want to know the `sbx` CLI equivalents

### Root Cause

The Docker Desktop-integrated `docker sandbox` command is deprecated. The standalone `sbx` CLI replaces it and does not require Docker Desktop.

### Fix

Migrate to the equivalent `sbx` commands:

| Deprecated Command | New Command |
|-------------------|-------------|
| `docker sandbox create --name NAME opencode .` | `sbx create --name NAME opencode .` |
| `docker sandbox run NAME` | `sbx run --name NAME` |
| `docker sandbox exec NAME cmd` | `sbx exec NAME cmd` |
| `docker sandbox ls` | `sbx ls` |
| `docker sandbox rm NAME` | `sbx rm NAME` |

Your existing sandboxes and secrets will continue to work with the `sbx` CLI.

---

## 19. OpenCode Shows Wrong Providers

### Symptoms

- OpenCode lists generic providers instead of USAi
- Custom USAi model catalog missing

### Root Cause

The USAi provider config is not loaded in the sandbox. With `acq`, it is
delivered by the `usai-provider` **kit** (applied by pinned remote reference
from the agentic-coding-patterns repo), which stages an `opencode.jsonc` at
`~/usai-config/` and, at startup, merges it into OpenCode's global config at
`~/.config/opencode/opencode.jsonc` (the kit no longer sets `OPENCODE_CONFIG`).
`acq` applies it alongside the `agentic-coding-playbook` and
`zscaler-ca-certificate` kits. This symptom appears when the sandbox was created
without `acq` (so the kits were not applied), or with a plain backend `run`
(e.g. `sbx run` / `msb run`) without the kit refs.

**Upgrading an existing sandbox (pre-kit).** A sandbox created before the kit
migration has no USAi provider config and no playbook clone. `acq` now **heals
it in place**: the next time you `acq run` against such a sandbox, it detects the
missing kit(s) and injects them (on sbx via `sbx kit add`). As of `sbx` 0.35.0
`sbx kit add` **recreates the sandbox container with the augmented kit set and
preserves state**, so your work and sessions survive — no export/recreate/import
dance, and no manual steps.

> **Historical note.** Earlier releases could *not* auto-heal in place: on
> `sbx` ≤ 0.34.x, `sbx kit add` failed (`failed to read tar header: unexpected
> EOF`) on any kit shipping a static file — including the `usai-provider` kit
> ([docker/sbx-releases#133][sbx133]). `sbx` 0.35.0 fixed this, so `acq` requires
> `sbx` >= 0.35.0 on the sbx backend and heals unconditionally.

`acq` waits for the sandbox to be ready for exec before probing (right after a
create or a cold start, exec fails with `inspect exec: context deadline
exceeded` for a few seconds; `acq` polls until a trivial exec succeeds) so a
cold-start delay is not misread as "kit absent".

> **Detecting a pre-kit sandbox.** `acq` decides a kit is missing by checking for
> the kit's footprint (e.g. the USAi config file), classifying on the probe's
> **stdout** (`present`/`absent`), never its exit status — `test -f` exits
> non-zero when the file is absent, which is indistinguishable from a genuine
> exec failure, so an exit-status check would wrongly treat "file absent" as
> "probe failed" and skip healing.

[sbx133]: https://github.com/docker/sbx-releases/issues/133

### Fix

Usually there is nothing to do — re-running `acq run opencode <path>` against
the sandbox heals it in place (state preserved). If a kit injection fails, `acq`
prints the exact manual recovery command. You can also run it yourself; remote
kit sources must be allowlisted first (`acq` does this automatically, but by hand
on the sbx backend it is):

```bash
sbx settings set kit.allowedSources '["docker.io/","github.com/GSA-TTS/"]'
REPO="git+https://github.com/GSA-TTS/agentic-coding-patterns.git"
DIR="integrations/isolation/acq-kits"
sbx kit add SANDBOX "${REPO}#ref=<sha>&dir=${DIR}/usai-provider"
sbx kit add SANDBOX "${REPO}#ref=<sha>&dir=${DIR}/agentic-coding-playbook"
sbx kit add SANDBOX "${REPO}#ref=<sha>&dir=${DIR}/zscaler-ca-certificate"
```

As a last resort, recreate the sandbox from scratch (this discards the sandbox's
session/context):

```bash
sbx rm --force SANDBOX          # discard the sandbox (irreversible)
./acq run opencode /path/to/your/project
```

---

## 20. Authentication Failed After Copying a New Key

### Symptoms

- USAi authentication fails immediately after creating/copying a key
- Key looks correct but is rejected

### Root Cause

The displayed key value in the console may be truncated when selected by hand, so the stored secret is incomplete.

### Fix

Regenerate the key and use the console **copy button** immediately instead of selecting the displayed text. Then confirm the secret is stored:

```bash
sbx secret ls -g | grep USAI_API_KEY
```

If problems persist, see [Section 2](#2-api-key-works-in-ui-but-fails-in-agent) and [Section 3](#3-agent-cannot-see-api-key--usai-authentication-fails). As a last resort, recreate the sandbox (this destroys all sandbox state, including uncommitted work):

```bash
sbx rm <sandbox-name>
```

---

## 21. SBX Fails to Start with Host Path `chdir` Error

### Symptoms

- `acq run opencode ...` exits after printing an OCI runtime error
- Error includes: `OCI runtime exec failed: chdir to '/Users/.../your-project': no such file or directory`
- The agent process may exit before opening an interactive session

### Root Cause

SBX cached sandbox metadata can point at a workspace path that no longer exists or is not mounted inside the container. This is most likely after moving, renaming, or reprovisioning a project, or after reusing an old sandbox with a stale workspace path.

### Fix

Find the stale sandbox and recreate it from the current workspace:

```bash
sbx ls
sbx rm <sandbox-name>
./acq run opencode /path/to/your/project
```

For this quickstart clone itself, the default sandbox name is derived as
`<agent>-<clone-folder>` — for `./acq run opencode .` in a clone named
`agentic-coding-quickstart` that is `opencode-agentic-coding-quickstart`:

```bash
sbx rm opencode-agentic-coding-quickstart
./acq run opencode .
```

If you used an explicit sandbox name, remove that same name and rerun with the same `--name` value:

```bash
sbx rm my-project
./acq run --name my-project opencode /path/to/your/project
```

---

## 22. Signed Commits Show "Unverified" on GitHub

### Symptoms

- Commits made inside a sandbox are signed (`git log --show-signature` looks
  fine locally) but GitHub shows an **Unverified** badge, or no badge.
- `acq` printed a note before attaching: *"no repo-local git user.email is set
  for this project."*

### Root Cause

The `git-ssh-sign` kit signs commits, but GitHub only marks an SSH-signed commit
**Verified** when **both** are true:

1. the commit's `user.email` is an email **verified on your GitHub account**, and
2. your **public** signing key is registered on that account **as a Signing
   Key** (Settings → SSH and GPG keys → New SSH key → Key type: **Signing
   Key**) — an authentication-only key does not verify commits.

No kit sets `user.email` / `user.name` (identity is user-owned, not something a
signing mixin should inject). Crucially, the sandbox has its **own home
directory**, so your host's **global** `~/.gitconfig` identity is **not visible
inside it** — only the project's **repo-local** identity (stored in the mounted
workspace) reaches the sandbox. A host global `user.email` alone therefore yields
signed-but-Unverified commits.

### Fix

Set the identity **repo-local** (inside the project, so the mount carries it into
the sandbox — a host `--global` value will not):

```bash
git config user.email you@verified-on-github.example
git config user.name  "Your Name"
```

Then register the **public** half of your signing key on GitHub as a **Signing
Key**, and make a **new** commit — verification applies going forward. `acq`
checks the project's **repo-local** `user.email` before attaching (the only tier
the sandbox can see) and warns if it is unset. For signing mechanics and more
failure modes, see the kit's
[`TROUBLESHOOTING.md`](https://github.com/GSA-TTS/agentic-coding-patterns/blob/main/integrations/isolation/acq-kits/git-ssh-sign/TROUBLESHOOTING.md).

> The end-to-end verification/identity gap in the kits themselves is tracked
> upstream in
> [agentic-coding-patterns#211](https://github.com/GSA-TTS/agentic-coding-patterns/issues/211);
> the quickstart-side decision (docs + advisory) is recorded in
> [ADR-0007](adr/0007-commit-verification-identity-guidance.md).

---

## 23. USAi 401 in an Existing Sandbox After Deleting/Recreating the Global Secret

### Symptoms

- A **fresh** sandbox authenticates to USAi fine, but an **existing** sandbox
  keeps failing with **HTTP 401** from the models API.
- You recently **deleted the global USAi secret and re-added it** (rather than
  using `acq usai-rotate-api-key`), and/or you had a stray `USAI_API_KEY`
  exported in your shell (`.zshrc`/`.bashrc`) that you commented out.
- `acq run` printed something like:

  ```text
  The global USAi key works in a fresh sandbox, but 'opencode-workspace' still
  fails with HTTP 401. This usually means the existing sandbox has a stale
  USAI_API_KEY placeholder from before rotation.

  Could not read the sandbox's USAI_API_KEY placeholder. Aborting attach.
  ```

- The `usai-provider` config (`opencode.jsonc`) **is** loaded — OpenCode shows
  the USAi provider and correct `baseURL` — so this is **not** the pre-kit
  migration case in [Section 19](#19-opencode-shows-wrong-providers). The config
  is fine; only the injected credential fails to resolve.

### Root Cause

USAi is injected as a **custom secret** (`sbx secret set-custom`), which is
**not** proxied. Instead, sbx bakes a **placeholder token** into each sandbox's
`USAI_API_KEY` at creation time, and the sbx proxy resolves that placeholder to
the real global secret value at request time.

When you **delete and re-add** the global secret (as opposed to rotating it in
place), sbx mints a **new placeholder**. A newly created sandbox picks up the new
placeholder, but an **existing** sandbox still carries the **old** placeholder —
which the proxy can no longer resolve. The proxy then injects an **empty**
`USAI_API_KEY`, so USAi returns 401. Reading the sandbox's baked-in value can
even come back **empty**, which is why older versions hit a hard
`Could not read the sandbox's USAI_API_KEY placeholder. Aborting attach.`
dead-end here.

> Contrast with `acq usai-rotate-api-key` (`scripts/rotate-apikey`), which
> **preserves the existing placeholder** across rotation on purpose — so running
> sandboxes keep resolving. Deleting + re-adding the secret defeats that.

### Fix (automatic)

On attach, `acq run` validates the sandbox's USAi key (`check_key`) and, when it
is not `200`, prints the rotate steps and offers to **rotate the key in place**
(`acq usai-rotate-api-key`), then re-validates before attaching. Rotation
preserves the placeholder, so this resolves the common expired-key case:

```bash
./acq run opencode /path/to/your/project
```

> **Note (stale-placeholder recovery).** The deeper two-route recovery for this
> exact 401-after-delete-and-re-add case — session-preserving recreate, or a
> non-destructive sandbox-scoped rebind to the current global placeholder — is a
> `qsbx`-only feature (see [ADR-0008](adr/0008-usai-placeholder-recovery.md)) and
> is **not yet ported to `acq`**. On `acq`, if an in-place rotate does not clear
> the 401 (because the stored *placeholder* — not the key value — is stale), use
> the manual rebind below or recreate the sandbox.

### Fix (manual)

Either recreate the sandbox:

```bash
sbx rm --force <sandbox-name>
./acq run opencode /path/to/your/project
```

…or rebind the existing sandbox to the current global placeholder. First read
the current placeholder from the global secret list, then bind a sandbox-scoped
secret to it (sbx prompts for the key value):

```bash
# The value in the USAI_API_KEY column is the current placeholder:
sbx secret ls -g | grep USAI_API_KEY

sbx secret set-custom <sandbox-name> --host api.gsa.usai.gov \
  --env USAI_API_KEY --placeholder <current-placeholder>
```

> **Do not** bind to the sandbox's *old* placeholder — that is the value that
> stopped resolving. Always bind to the **current global** one.

### Prevention

- Rotate with `acq usai-rotate-api-key`, which preserves the placeholder so
  existing sandboxes keep working. Avoid deleting + re-adding the global secret.
- Remove any `export USAI_API_KEY=...` from your shell profile — the sandbox gets
  its value from sbx injection, and a host env var only causes confusion.

### Related

- [Section 3 — Agent Cannot See API Key / USAi Authentication Fails](#3-agent-cannot-see-api-key--usai-authentication-fails)
- [Section 14 — SBX Proxy Doesn't Work with Custom baseURL](#14-sbx-proxy-doesnt-work-with-custom-baseurl-security-implication)
- [Section 20 — Authentication Failed After Copying a New Key](#20-authentication-failed-after-copying-a-new-key)
- Decision record: [ADR-0008](adr/0008-usai-placeholder-recovery.md)

---

## 24. Pulled/Switched a Branch but acq Still Shows Old Behavior

### Symptoms

- You `git pull` or `git checkout` a branch with a fix, but `acq` still
  prints wording or behaves in a way that only exists in an **older** version.
- `git pull origin <branch>` prints **`Already up to date.`** yet nothing changes.
- You are `cd`'d into a quickstart clone, but the behavior does not match the
  code you see in that clone's `acq`.

### Root Cause

Two independent traps, often combined:

1. **`git pull origin <branch>` does not switch you to that branch.** `pull` =
   `fetch` + `merge FETCH_HEAD` into the branch you are **currently on**.
   `Already up to date` means the *merge* was a no-op — **not** that your working
   tree now contains the branch. If you never ran `git switch <branch>` /
   `git checkout <branch>`, your working tree still has the old `acq`.

2. **An `acq` on your `PATH` points at a *different* clone.** If `acq` is
   invoked by bare name (not `./acq`), the shell resolves it via
   `PATH`. A symlink in `~/bin` or `/usr/local/bin` may point at a **different
   clone** than the one you edited/pulled. `acq` follows that symlink to find
   its own directory, so it runs the *other* clone's code — you update clone A
   and execute clone B.

A related variant: exporting `QUICKSTART_CLONE` overrides where sibling helper
scripts are located, which can also make "which clone is in effect" confusing.

### Fix

First, ask acq which file and clone are actually running:

```bash
acq version
```

It prints the resolved script path, the clone directory, and that clone's git
branch@commit (and flags if the tree is dirty or `QUICKSTART_CLONE` is set).
Compare the branch/commit against what you expect.

Then, depending on which trap you hit:

- **Wrong branch checked out:** switch (don't just pull):

  ```bash
  git switch fix/your-branch      # or: git checkout fix/your-branch
  git rev-parse --abbrev-ref HEAD # confirm
  ```

- **Running a different clone via a PATH symlink:** either run the clone you
  updated directly, or re-point the symlink:

  ```bash
  # Run the clone you actually updated:
  ./acq run opencode <your-project>

  # …or see where the installed one lives and re-point it:
  readlink -f "$(command -v acq)"
  ```

When you run `acq run` from inside one quickstart clone while the executing
`acq` lives in another, acq now prints a startup note pointing this out.

### Prevention

- Use `git switch <branch>` to change branches; treat `Already up to date` as a
  signal to check `git rev-parse --abbrev-ref HEAD`, not confirmation.
- Keep a single canonical clone, and make any `acq` on `PATH` a symlink to
  that clone's `acq`. Run `acq version` when in doubt.

---

## 25. `acq run` Prompts for a GitHub Username/Password During Kit Fetch

### Symptoms

Running `acq run …` prints an interactive prompt and then fails:

```
Username for 'https://github.com': you@agency.gov
Password for 'https://you%40agency.gov@github.com':
kit-translate: failed to fetch git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=…&dir=…
kit-translate:   remote: Invalid username or token. Password authentication is not supported for Git operations.
```

You may already be authenticated with the `gh` CLI (`gh auth status` is green).

### Root Cause

`gh auth login` authenticates the **`gh` CLI**, not plain **git**. The acq kit
fetch uses `git` directly. If your machine has a global git credential helper or
a `url.<x>.insteadOf` rewrite (common in enterprise/egress setups), git tries to
*authenticate* to the kit source and — failing — drops into an interactive
prompt (and GitHub disabled git password auth in 2021, so it can't succeed).

### Fix

Wire git to use your `gh` token, once:

```
gh auth setup-git
```

If it still prompts, you likely have a rewrite forcing auth on the clone —
inspect it with:

```
git config --global --get-regexp 'url\..*insteadOf'
```

### Prevention

As of #207, acq's kit fetch is **non-interactive**: it sets `GIT_TERMINAL_PROMPT=0`
and first attempts an anonymous fetch with any inherited credential helper /
`github.com` `insteadOf` rewrite neutralized (so an unauthenticated fetch
proceeds without prompting), then retries once with your system git config
(still prompt-disabled) for sources that require auth (enterprise mirror, etc.).
It can no longer hang on a
prompt; a genuine failure now prints this remedy.

### Related

- Issue #207 (non-interactive fetch), #208 (docs + loud fallback).

---

## Debugging Checklist

When something fails, work through this list:

1. [ ] Is the secret actually in the container? (`echo $VAR_NAME`)
2. [ ] Is the endpoint URL exactly correct? (no typos, correct path)
3. [ ] Is the auth header format correct? (`Bearer` prefix)
4. [ ] Can the container reach the network? (`curl` test)
5. [ ] Is the config file actually being read? (add debug logging)
6. [ ] Did SBX CLI syntax change? (`sbx --help`)
7. [ ] Is this a known model/entitlement issue? (test with different model)

---

## Contributing

When you discover a new failure mode:

1. Document the symptoms clearly
2. Identify the root cause
3. Provide a minimal fix
4. Add it to this document
5. Consider if it indicates a gap in AGENTS.md rules
