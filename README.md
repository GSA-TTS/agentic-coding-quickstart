# Agentic Coding Quickstart

> **Audience:** GSA teams using AI coding agents
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi

This quickstart gets you from zero to running an AI coding agent with USAi in under 5 minutes using Docker Sandboxes.

## Agentic Coding Ecosystem

This repository is part of a three-repo ecosystem:

| Repo                                                                                  | Purpose       | When to Use                           |
| ------------------------------------------------------------------------------------- | ------------- | ------------------------------------- |
| **[Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart)** (you are here) | Get running   | First day setup, sbx + USAi config    |
| **[Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)**                    | Do it right   | Repo setup, standards, best practices |
| **[Patterns](https://github.com/GSA-TTS/agentic-coding-patterns)**                    | Share & learn | Community patterns, lessons learned   |

**Your journey:** Start here (Quickstart) to get your environment working, then use the Playbook to set up your projects properly, and visit Patterns to share what you learn.

---

## 5-Minute Quickstart

### Step 0: Clone this repo (with the playbook submodule)

```bash
git clone --recurse-submodules \
  https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
```

> [!NOTE]
> The playbook ships as a pinned git submodule under `agentic-coding-playbook/`.
> If you already cloned without `--recurse-submodules`, run
> `git submodule update --init`. You need access to the (currently private)
> playbook repo; your GitHub token covers it.

### Step 0b: Prerequisites

Before you start, make sure you have:

| Requirement     | Notes                                                      |
| --------------- | ---------------------------------------------------------- |
| Package manager | Homebrew on macOS, `winget` on Windows, or `apt` on Ubuntu |
| Docker account  | Required for `sbx login`                                   |
| USAi API key    | Export as `USAI_API_KEY` before configuring secrets        |
| GitHub CLI auth | Optional, but recommended for repository access            |

```bash
export USAI_API_KEY="your-usai-api-key"
```

> [!NOTE]
> Use the USAi console copy button when available. The key-management UI may display only a
> truncated portion of the key, which can look like the full value if you manually select it.

### Step 1: Install sbx CLI

The `sbx` CLI is a standalone tool — Docker Desktop is **not required**.

<details>
<summary>macOS</summary>

```bash
brew install docker/tap/sbx
sbx login
```

> [!NOTE]
> macOS may prompt you to approve helper binaries the first time you use `sbx`. Allow these if
> prompted:
>
> - `mkfs.erofs`
> - `mkfs.ext4`
> - `containerd-shim-nerdbox-v1`

</details>

<details>
<summary>Windows</summary>

```bash
winget install -h Docker.sbx
sbx login
```

</details>

<details>
<summary>Linux (Ubuntu)</summary>

```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm $USER && newgrp kvm
sbx login
```

</details>

> [!NOTE]
> `sbx login` requires a Docker account. Docker Desktop is not required, but if you have it,
> your Docker subscription covers sbx licensing.

### Step 2: Configure secrets and policy (once)

You only need to do this once per machine. Your USAi key and GitHub token are
stored in sbx's secret manager, and the network policy persists across sandboxes.

```bash
# 1. Set network policy (first-time only)
sbx policy set-default balanced

# 2. Allow USAi endpoint
sbx policy allow network -g "api.gsa.usai.gov"

# 3. Store your USAi API key securely (USAi is a custom endpoint, not built-in)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY --value "$USAI_API_KEY"

# 4. Store GitHub token (for code access)
gh auth token | sbx secret set -g github
```

> [!NOTE]
> `sbx policy set-default balanced` may need to be retried if the policy service has not settled
> yet after login or first-time setup.
>
> USAi is not a built-in sbx service, so we use `sbx secret set-custom` instead of
> `sbx secret set -g`. USAi API keys expire every 7 days. To rotate the secret in
> your existing sandboxes, follow the [Rotating USAI API Keys procedure](#rotating-usai-api-keys) below.

### Step 3: Create and run a sandbox (as often as you like)

This clone holds your shared global config (`opencode/opencode.jsonc`) plus the
playbook submodule (`agentic-coding-playbook/`). `qsbx` mounts the clone into the
sandbox and symlinks the config into the locations OpenCode searches under the
sandbox home:

- `~/.config/opencode/opencode.jsonc` → the shared config
- `~/.config/opencode/AGENTS.md` → the playbook's federal agent rules
- `~/.agents/skills` → the playbook's skills

So every sandbox you create picks up the same config, rules, and skills. Repeat
this for each project you want to work on.

```bash
./qsbx run opencode /path/to/your/project
```

`qsbx run` creates the sandbox (with this clone mounted **read-only**) if it
doesn't exist yet, then attaches. It uses the clone it lives in, so run it from
this checkout (or via a symlink to it); set `QUICKSTART_CLONE` only if you want
to override that.

The clone is mounted read-only for project work so a (possibly prompt-injected)
agent can't rewrite the permission policy, rules, or skills that every other
sandbox loads.

#### Customizing the shared config

To edit the shared config itself with an agent, point `qsbx` at the clone:

```bash
./qsbx run opencode .          # from inside the clone
# or: ./qsbx run opencode /path/to/agentic-coding-quickstart
```

qsbx detects that the target is the clone and mounts it **read-write** as the
primary workspace (and tells you so). Review the agent's changes with `git diff`
and commit/push before they propagate to other sandboxes.

That's it. You're now running an AI coding agent in an isolated container with USAi access.

**Staying current:** Once in a while, `git fetch` this clone (and
`git submodule update --remote --merge agentic-coding-playbook` to bump the
playbook) to pick up updates, and rotate your USAi key when it expires (see
[Rotating USAI API Keys](#rotating-usai-api-keys)).

**Need more details?** See the [Full sbx CLI Guide](docs/QUICKSTART_SBX.md).

**Working across multiple repos?** See [Multiple Workspaces](docs/QUICKSTART_SBX.md#multiple-workspaces) for mounting extra directories.

---

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. Running them in sandboxes provides:

- **Isolation** — Agent can't access your full system
- **Secret protection** — API keys injected via proxy, never touch disk
- **Reproducibility** — Same environment every time
- **Audit trail** — Clear boundaries for what the agent can do

---

## What's in This Repo

| File/Directory                      | Purpose                                                    |
| ----------------------------------- | ---------------------------------------------------------- |
| `opencode/opencode.jsonc`           | Pre-configured for USAi endpoints (shared config)          |
| `opencode.jsonc`                    | Convenience symlink to `opencode/opencode.jsonc`           |
| `agentic-coding-playbook/`          | Pinned submodule: federal `AGENTS.md` + agent skills       |
| `qsbx`                              | sbx wrapper that mounts this clone and links config in     |
| `rotate-apikey.sh`                  | Rotate your USAi API key secret in sbx                     |
| `.zed/tasks.json`                   | Pre-configured tasks for **Zed Editor**                    |
| `.pre-commit-config.yaml`           | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md`                         | Rules for working **on this quickstart repo**              |
| `docs/QUICKSTART_SBX.md`            | Full sbx CLI setup guide                                   |
| `docs/ZED_SETUP.md`                 | **Zed Editor** integration guide                           |
| `docs/KNOWN_FAILURE_MODES.md`       | Troubleshooting guide                                      |

---

## Zed Editor Integration (Optional)

If you use the **Zed Editor**, pre-configured tasks are available in `.zed/tasks.json`:

- **OpenCode: Run Agent** — Launch the agent in your sandbox
- **OpenCode: Environment Diagnostics** — Check that `sbx` is installed and your USAi key secret is set

See the **[Zed Editor Setup Guide](docs/ZED_SETUP.md)** for detailed instructions.

---

## OpenCode Web (Optional)

An alternative to running OpenCode in the terminal is to run OpenCode Web in the sandbox and access it from your host browser. This has a few benefits:

- Full support for copying text from the agent output to your host clipboard
- Richer visual interface with improved markdown rendering
- Easier navigation through long outputs and conversation history

To run OpenCode Web in a sandbox:

```bash
# In one terminal, start OpenCode Web
sbx run [your sandbox name] -- web --hostname 0.0.0.0 --port 4096

# In another terminal, publish the port to your host
sbx ports [your sandbox name] --publish 4096:4096
```

Then open `http://127.0.0.1:4096` in your browser.

A convenience script is available to automate this: [`opencode-web.sh`](opencode-web.sh)

For more information, see the [OpenCode Web documentation](https://opencode.ai/docs/web).

---

## Security Model

1. **All execution inside sbx containers** — Isolated from your host system
2. **Authorized endpoints only** — USAi, GitHub (via proxy)
3. **Secret proxy** — Agent never sees raw API keys when using `sbx secret`
4. **Agent follows AGENTS.md rules** — Explicit permissions and prohibitions

For Git provider credentials and advanced patterns, see [docs/QUICKSTART_SBX.md](docs/QUICKSTART_SBX.md).

---

## Troubleshooting

### Network policy blocks USAi

```bash
sbx policy allow network -g "api.gsa.usai.gov"
```

> Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent.

### "docker: unknown command: docker sbx" or "docker sandbox deprecated"

The `docker sandbox` command is deprecated. Install and use the standalone `sbx` CLI instead:

```bash
# macOS
brew install docker/tap/sbx

# Windows
winget install Docker.sbx
```

Then use `sbx` commands directly (e.g., `sbx run opencode .` instead of `docker sandbox run opencode .`).

### OpenCode shows wrong providers

Ensure `~/.config/opencode/opencode.jsonc` inside the sandbox is the symlink
into this clone. `qsbx` creates it (along with `AGENTS.md` and `~/.agents/skills`)
when it creates the sandbox; if you created the sandbox another way, the USAi
provider config won't be picked up. Re-create it with `qsbx run`, or link the
files manually.

### Authentication failed

```bash
# Check your secret is stored
sbx secret ls

# Re-set if needed
sbx secret set -g anthropic
```

If USAi authentication fails right after copying a newly created key, regenerate the key and use
the console copy button immediately instead of selecting the displayed text. The displayed value may
be truncated.

### Rotating USAi API keys

USAi API keys expire every 7 days. A stale API key is a common cause of authentication failures like:

```
Unauthorized: {"detail":"Not authenticated"}
```

To check if your key has expired:

1. Go to https://console.gsa.usai.gov/key-management
2. Under "My Keys", check the "Expires In" field. If the value is 0h0m, then the key has expired.

To rotate your key:

1. On the same page, choose "Rotate" from the "Actions" menu
2. Copy the new key using the console copy button
3. With the key in your paste buffer, update the secret in `sbx` by running

   ```bash
   ./rotate-apikey.sh
   ```

   The command will prompt you for the new key. Paste it when prompted. It will
   also validate that the new key works.

> [!NOTE]
> If you don't have a sandbox named, "opencode-agentic-coding-quickstart", then
> you'll need to manually validate the key with:
>
> ```bash
> # Should return HTTP 200. A 401/403 means the key is invalid or expired.
> sbx exec <sandbox-name> -- sh -c \
>   'curl -sS -o /dev/null -w "%{http_code}\n" \
>    -H "Authorization: Bearer $USAI_API_KEY" \
>    https://api.gsa.usai.gov/api/v1/models'
> ```

If the placeholder value hasn't changed, your existing sandboxes will automatically use the new key.

#### Troubleshooting

If you're still having authentication issues after rotation:

1. Verify the secret is set:

   ```bash
   sbx secret ls -g | grep USAI_API_KEY
   ```

2. As a last resort, recreate your sandbox:
   > ⚠️ **Warning:** This destroys all sandbox state including uncommitted work.
   ```bash
   sbx rm <sandbox-name>
   ```

### How default USAI models are chosen

The `opencode.jsonc` in this repo includes a generated USAI model catalog.
This repository keeps that section in sync with the USAI `/models` API so new
projects start from a current baseline.

Default model policy:

- `model` tracks the highest available Opus generation
- `agent.compaction.model` tracks the highest available GPT generation
- `small_model` stays a curated fast/cheap fallback

The generated catalog improves discoverability, but it is still possible for a
model listed by `/models` to fail at runtime for a specific key or request. See
[docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md) for troubleshooting.

To refresh the model catalog locally:

```bash
export USAI_API_KEY="your-key-here"
npm run sync:usai-models
```

For more troubleshooting, see [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md).

---

## What's Next?

1. **Set up your project properly** — Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
2. **Share what you learn** — Contribute to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** — Found something unclear? Open an issue or submit a PR

### Available Skills and Resources

The playbook (vendored here as the `agentic-coding-playbook/` submodule) provides
reusable **agent skills** — step-by-step procedures for common tasks. Skills
follow the [agentskills.io](https://agentskills.io) standard. When you launch a
sandbox with `qsbx`, these are symlinked to `~/.agents/skills` so OpenCode
discovers them automatically; no separate clone is needed.

| Source       | Skills                       | Examples                                                                            |
| ------------ | ---------------------------- | ----------------------------------------------------------------------------------- |
| **Playbook** (submodule) | Federal compliance, security | `federal-security-controls-lookup`, `ato-package`, `code-review`, `cloudgov-deploy` |
| **Patterns** | Development workflows        | `accessibility-review`, `uswds-prototype`, `test-generation`, `secure-code-review`  |

To bump the playbook to a newer release:

```bash
git submodule update --remote --merge agentic-coding-playbook
git add agentic-coding-playbook && git commit -m "chore: bump playbook submodule"
```

---

## Getting Help

1. **Troubleshooting:** [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)
2. **Agent behavior:** [AGENTS.md](AGENTS.md)
3. **Questions:** [agentic-coding Slack channel](https://gsa.enterprise.slack.com/archives/C0B44531QLE)
4. **Platform issues:** support@usai.gov

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

**Data Classification:** Internal/Non-sensitive
