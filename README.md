# Agentic Coding Quickstart

> **Audience:** GSA teams using AI coding agents
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi

This quickstart gets you from zero to running an AI coding agent with USAi in under 5 minutes using the standalone `sbx` CLI.

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
> You need access to the (currently private) playbook repo; if you can see this,
> your GitHub token covers it. The playbook ships as a pinned git submodule
> under `agentic-coding-playbook/`. (If you already cloned without `--recurse-submodules`, run
> `git submodule update --init`.)

### Step 0b: Prerequisites

Before you start, make sure you have:

| Requirement     | Notes                                                      |
| --------------- | ---------------------------------------------------------- |
| Package manager | Homebrew on macOS, `winget` on Windows, or `apt` on Ubuntu |
| Docker account  | Required for `sbx login`                                   |
| USAi API key    | [Create one](https://console.gsa.usai.gov/key-management), record it safely, and keep it handy            |
| GitHub CLI auth'd | Optional, but recommended for repository access            |
| GitHub personal access token | Optional, but needed if you are not using the GitHub CLI |

### Step 1: Install sbx CLI

The `sbx` CLI is a standalone tool — Docker Desktop is **not required**.

<details>
<summary>macOS</summary>

```bash
brew trust docker/tap
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
> ___
> macOS may say sbx is not from a "trusted developer" and block it. In this case you will need to open System Preferences/Privacy
> & Security/Security, and click the "Allow anyway" button. Run `sbx login` again and click "Allow anyway" in the popup. 

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
sbx policy allow network "api.gsa.usai.gov"

# 3. Store your USAi API key securely (you will be prompted for it)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY

# 4. Store GitHub token (for code access)
# If you are using the GitHub CLI
brew install gh # (if not already installed)
gh auth login # (if not already authenticated to Github cli)
gh auth token | sbx secret set -g github

# If you are using a personal access token (classic); you will be prompted
sbx secret set -g github
```

> [!NOTE]
> USAi API keys expire every 7 days; when one does, see
> [Troubleshooting](#troubleshooting) to rotate it.

### Step 3: Create and run a sandbox (as often as you like)

```bash
./qsbx run opencode /path/to/your/project
```

That's it. You're now running an AI coding agent with USAi access and restricted filesystem and network access.  Repeat this to create sandboxes for each project you want to work on.

**Want to know more about what `qsbx` is doing under the hood?** See [How It Works](#how-it-works).

**Need more details?** See the [Full sbx CLI Guide](docs/QUICKSTART_SBX.md).

**Working across multiple repos?** See [Multiple Workspaces](docs/QUICKSTART_SBX.md#multiple-workspaces) for mounting extra directories.

---

## Troubleshooting

If the happy path above didn't work, the two most common issues are below. For
everything else (wrong providers, auth failures, TLS/certificate errors, and
more), see **[docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)**.

<details>
<summary><strong>Authentication failures (expired USAi key)</strong></summary>

USAi API keys expire every 7 days, which is the most common cause of errors like:

```
Unauthorized: {"detail":"Not authenticated"}
```

The simplest fix: end your session, then run `./qsbx run opencode <path>` again.
`qsbx` validates the key on attach and walks you through rotating it when needed.

To rotate the key explicitly outside that workflow:

1. Open https://console.gsa.usai.gov/key-management
2. Choose "Rotate" from the "Actions" menu for your key
3. Copy the new key using the console copy button
4. With the key in your paste buffer, run:

   ```bash
   ./qsbx usai-rotate-api-key
   ```

   (or run the underlying `scripts/rotate-apikey` directly). It prompts for the
   new key, then validates it in a temporary sandbox.

</details>

<details>
<summary><strong>Network policy blocks USAi</strong></summary>

```bash
sbx policy allow network -g "api.gsa.usai.gov"
```

> Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent.

</details>

<details>
<summary><strong>"sbx policy set-default" fails right after first-time setup</strong></summary>

The policy service may not have settled yet after `sbx login`. Retry the command:

```bash
sbx policy set-default balanced
```

</details>

---

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. That makes them potent agents of chaos if they're compromised. Running them in sandboxes provides:

- **Isolation** — Agent shouldn't be able to access the full host system; they should be limited both the filesystem and network access
- **Secret protection** — By using proxy that injects secrets into outgoing requests, the actual secret is never available to the agent for exfiltration
- **Reproducibility** — Agents should have a consistent configuration tailored to their operating context every time they run
- **Audit trail** — Hard boundaries for what the agent can do, potentially logging violations

For more details on this sandbox implementation and discussion of advanced patterns, see [docs/QUICKSTART_SBX.md](docs/QUICKSTART_SBX.md).

---

## How It Works

You can skip this section to get started — it explains the mechanics behind the
quickstart for when you want to customize or troubleshoot.

### What happened when I ran the `qsbx` command?

`qsbx run` created the sandbox for that path (if it didn't exist yet) using the underlying `sbx` command, making sure that this clone was accessible inside it. Then it configured the coding agent (`opencode`) to pick up configuration for using the USAi provider and made sure the agent was provisioned with custom guidance and relevant skills for working in the federal context.

### What `qsbx` mounts and links

This clone holds your shared global config (`opencode/opencode.jsonc`) plus the
playbook submodule (`agentic-coding-playbook/`). `qsbx` mounts the clone into the
sandbox and symlinks the config into the locations OpenCode searches under the
sandbox home:

- `~/.config/opencode/opencode.jsonc` → the shared config
- `~/.config/opencode/AGENTS.md` → the playbook's federal agent rules
- `~/.agents/skills` → the playbook's skills

So every sandbox you create picks up the same config, rules, and skills. `qsbx`
uses the clone it lives in, so run it from this checkout (or via a symlink to it);
set `QUICKSTART_CLONE` only if you want to override that.

### Why the USAi key uses `set-custom`

USAi is not a built-in sbx service, so we store its key with
`sbx secret set-custom` (with an explicit `--host`) instead of `sbx secret set -g`.
The built-in `set -g` form only recognizes known providers.

### Read-only by default

For project work, this clone is mounted **read-only** so a (possibly
prompt-injected) agent can't rewrite the permission policy, rules, or skills that
every other sandbox loads.

### Key pre-validation

Before attaching, `qsbx` checks that the sandbox's USAi key still works. If it
has expired, it walks you through [rotating it](#troubleshooting) and
re-validates before launching the agent.

### How default USAi models are chosen

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
# Prompt for the key (no echo)
read -rs USAI_API_KEY && export USAI_API_KEY
npm run sync:usai-models
```

---
## Customizing the shared config

You can always edit the shared config in this clone by hand, but you may also use an agent to work on it! To edit it using an agent, point `qsbx` at the clone:

```bash
./qsbx run opencode .          # from inside the clone
# or: qsbx run opencode /path/to/agentic-coding-quickstart
```

qsbx detects that the target is the clone and mounts it **read-write** as the
primary workspace (and tells you so). Review the agent's changes carefully. You probably want to test them by starting another sandbox up and trying them out.

Note that changes to the config are visible across all sandboxes that mount it, but agents don't reload their config on the fly. To have them reread the shared configuration, you can exit them and run `qsbx run opencode /path/to/your/project -- -c` to continue the existing session where you left off.

When you're done, you probably want to version-control your customizations. We recommend that you commit them to a local branch in this clone. That way you can pull changes from main into your branch when needed.

---

## Optional Integrations

- **Zed Editor** — Pre-configured tasks in `.zed/tasks.json` let you launch the
  agent and run diagnostics from the editor. See the [Zed Editor Setup Guide](docs/ZED_SETUP.md).
- **OpenCode Web** — Run OpenCode Web in the sandbox and reach it from your host
  browser for clipboard support and richer markdown rendering. The
  [`opencode-web.sh`](opencode-web.sh) script automates it; see the
  [OpenCode Web documentation](https://opencode.ai/docs/web).

---

## Staying Current

Once in a while, refresh this clone and the playbook to pick up updates, and
rotate your USAi key when it expires (see [Troubleshooting](#troubleshooting)).

```bash
# Update the quickstart clone
git fetch

# Bump the playbook submodule to a newer release
git submodule update --remote --merge agentic-coding-playbook
git add agentic-coding-playbook && git commit -m "chore: bump playbook submodule"
```

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

## What's in This Repo

| File/Directory                      | Purpose                                                    |
| ----------------------------------- | ---------------------------------------------------------- |
| `opencode/opencode.jsonc`           | Pre-configured for USAi endpoints (shared config)          |
| `opencode.jsonc`                    | Convenience symlink to `opencode/opencode.jsonc`           |
| `agentic-coding-playbook/`          | Pinned submodule: federal `AGENTS.md` + agent skills       |
| `qsbx`                              | sbx wrapper that mounts this clone and links config in     |
| `scripts/rotate-apikey`             | Rotate your USAi API key secret (`qsbx usai-rotate-api-key`) |
| `.zed/tasks.json`                   | Pre-configured tasks for **Zed Editor**                    |
| `.pre-commit-config.yaml`           | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md`                         | Rules for working **on this quickstart repo**              |
| `docs/QUICKSTART_SBX.md`            | Full sbx CLI setup guide                                   |
| `docs/ZED_SETUP.md`                 | **Zed Editor** integration guide                           |
| `docs/KNOWN_FAILURE_MODES.md`       | Troubleshooting guide                                      |

---

**Data Classification:** Internal/Non-sensitive
