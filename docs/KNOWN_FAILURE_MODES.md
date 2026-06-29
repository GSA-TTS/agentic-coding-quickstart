---
title: "Known Failure Modes"
description: "Real-world failure patterns when using Docker SBX + USAi + agent frameworks"
status: canonical
tier: 2
last_updated: "2026-06-02"
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

The USAi provider config is not loaded in the sandbox. With `qsbx`, the config is
delivered by applying this clone as an sbx **kit** (`--kit`), which sets
`OPENCODE_CONFIG` to `~/usai-config/opencode.jsonc`; `qsbx` separately symlinks
the playbook's `AGENTS.md` and `~/.agents/skills`. This symptom appears when the
sandbox was created without `qsbx` (so neither the kit nor the symlinks were
applied), or with `sbx run` directly but without `--kit .`.

### Fix

If the sandbox already exists, inject the kit into it without recreating it
(replace `SANDBOX` with the sandbox name from `sbx ls`):

```bash
sbx kit add SANDBOX /path/to/agentic-coding-quickstart
```

> `sbx kit add` is currently EXPERIMENTAL and may change in future releases. It
> applies the kit's files, init files, and startup commands to the running
> container — enough to deliver the USAi provider config. (Restart the agent so
> it re-reads `OPENCODE_CONFIG`.)

Otherwise, create the sandbox with the kit applied. With `qsbx` this is
automatic:

```bash
./qsbx run opencode /path/to/your/project
```

Or apply the kit directly with plain `sbx`:

```bash
sbx run --kit /path/to/agentic-coding-quickstart opencode /path/to/your/project
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

- `qsbx run opencode ...` exits after printing an OCI runtime error
- Error includes: `OCI runtime exec failed: chdir to '/Users/.../your-project': no such file or directory`
- The agent process may exit before opening an interactive session

### Root Cause

SBX cached sandbox metadata can point at a workspace path that no longer exists or is not mounted inside the container. This is most likely after moving, renaming, or reprovisioning a project, or after reusing an old sandbox with a stale workspace path.

### Fix

Find the stale sandbox and recreate it from the current workspace:

```bash
sbx ls
sbx rm <sandbox-name>
./qsbx run opencode /path/to/your/project
```

For this quickstart clone itself, the default `qsbx` sandbox name is `qsbx-quickstart-config`:

```bash
sbx rm qsbx-quickstart-config
./qsbx run opencode .
```

If you used an explicit sandbox name, remove that same name and rerun with the same `--name` value:

```bash
sbx rm my-project
./qsbx run --name my-project opencode /path/to/your/project
```

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
