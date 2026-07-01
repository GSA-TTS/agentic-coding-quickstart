# Agentic Coding Quickstart

> **Audience:** GSA teams using AI coding agents
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi

**In one sentence:** this quickstart gets you running an AI coding agent connected to USAi in under 5 minutes, using `sbx`.

**`sbx`** is a command-line tool from Docker — standalone, not part of Docker Desktop — that runs your AI coding agent inside an isolated sandbox, so the agent can only touch the files and network you allow.

## Agentic Coding Ecosystem

**Your journey:** This repository is part of a three-repo ecosystem.

| Repo                                                                                  | Purpose       | When to Use                           |
| ------------------------------------------------------------------------------------- | ------------- | ------------------------------------- |
| **[Quickstart](https://github.com/GSA-TTS/agentic-coding-quickstart)** (you are here) | Get running   | First day setup, sandboxing + USAi config    |
| **[Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)**                    | Do it right   | Repo setup, standards, best practices |
| **[Patterns](https://github.com/GSA-TTS/agentic-coding-patterns)**                    | Share & learn | Community patterns, lessons learned   |

Once you complete this Quickstart to get your environment working, use the Playbook to set up your projects properly, and visit Patterns to share what you learn.

---

## 5-Minute Quickstart

### Step 0: Prerequisites

You will run the commands in this guide from a terminal. Open one now:

<details>
<summary>How to open a terminal (click to expand)</summary>

- **macOS:** open **Terminal** — find it in Applications → Utilities, or press ⌘-Space, type "Terminal", and press Return.
- **Windows:** open **Windows Terminal** or **PowerShell** — press the Start button, type "Terminal" (or "PowerShell"), and press Enter.
- **Linux (Ubuntu):** press Ctrl-Alt-T, or search for "Terminal" in your applications menu.

</details>

Then make sure you have each of these ready:

| Requirement     | Notes                                                      |
| --------------- | ---------------------------------------------------------- |
| Package manager | Homebrew on macOS, `winget` on Windows, or `apt` on Ubuntu |
| Docker account | A Docker account to sign in with `sbx login`. Your organization may require a paid Docker subscription seat (see the note below). Docker Desktop is not required. |
| USAi API key    | [Create one](https://console.gsa.usai.gov/key-management), record it safely, and keep it handy            |
| GitHub CLI (`gh`) | (optional) GitHub's official command-line tool ([install](https://cli.github.com/)). It lets the coding agent work with your repos without you handling a token by hand. |
| GitHub personal access token | (optional) Needed only if you are **not** using the GitHub CLI |

<details>
<summary>How to verify each requirement (click to expand)</summary>

Run each command in your terminal. If a command isn't found, that requirement isn't installed yet.

- **Package manager** — `brew --version` (macOS), `winget --version` (Windows), or `apt --version` (Ubuntu). You should see a version number.
- **Docker account** — this is the one prerequisite you can't confirm until Step 2, since `sbx` isn't installed yet. It's confirmed when `sbx login` succeeds there.
- **USAi API key** — visit [the key-management console](https://console.gsa.usai.gov/key-management); you should see (or be able to create) a key. Have the token string ready to paste in Step 3.
- **GitHub CLI** — `gh auth status` should report that you're logged in.
- **GitHub personal access token** — only needed without the GitHub CLI; have the token string ready to paste in Step 3.

</details>

> [!NOTE]
> **About the Docker subscription.** `sbx login` signs in with a Docker account.
> In at least one organization we've seen, sign-in fails with a "Not enough
> seats" error unless you have a paid Docker subscription seat (see the
> troubleshooting callout in Step 2). Docker Desktop itself is **not required**
> to run `sbx` — but if you do have a Docker Desktop subscription, that already
> provides your seat. If you hit the seats error, ask your organization's Docker
> administrator to assign you one. For how Docker licensing works, see
> [Docker's subscription docs](https://docs.docker.com/subscription/).

### Step 1: Clone this repo (with the playbook submodule)

```bash
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
```

The remaining steps must be run from inside this cloned folder.

### Step 2: Install sbx CLI

The `sbx` CLI is a standalone tool — Docker Desktop is **not required** (you do
need a Docker account, and your org may require a paid seat; see the note in Step 0).

<details>
<summary>Show macOS install steps (click to expand)</summary>

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
>
> ---
>
> macOS may say sbx is not from a "trusted developer" and block it. In this case you will need to open System Preferences/Privacy
> & Security/Security, and click the "Allow anyway" button. Run `sbx login` again and click "Allow anyway" in the popup.

</details>

<details>
<summary>Show Windows install steps (click to expand)</summary>

```bash
winget install -h Docker.sbx
sbx login
```

</details>

<details>
<summary>Show Linux (Ubuntu) install steps (click to expand)</summary>

```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm $USER && newgrp kvm
sbx login
```

</details>

**Check it worked:** after `sbx login` finishes with no error, run `sbx version`.
You should see a line like `sbx version: v0.32.0 <sha>`.

> [!IMPORTANT]
> **If `sbx login` fails with a "Not enough seats" error**, like this:
>
> ```
> ERROR: sign-in failed: auth login failed: completing login: oauth2:
> "access_denied" "Not enough seats in organization '<your-org>'. Add more
> seats or contact your company administrator."
> ```
>
> you don't have a paid Docker seat yet (you may also see a red X in the browser
> tab that opened). Ask your organization's Docker administrator to assign you a
> seat, then run `sbx login` again.

### Step 3: Configure secrets and policy (once)

You only need to do this once per machine. Your USAi key and GitHub token are
stored in sbx's secret manager, and the network policy persists across sandboxes.

```bash
# 1. Set network policy (first-time only)
sbx policy init balanced

# 2. Allow USAi endpoint
sbx policy allow network "api.gsa.usai.gov"

# 3. Store your USAi API key securely (you will be prompted for it)
sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY

# 4. Store GitHub token (for code access)
# If you are using the GitHub CLI
brew install gh # (if not already installed)
gh auth login # (if not already authenticated to Github cli)
gh auth token | sbx secret set -g github --force

# If you are using a personal access token (classic); you will be prompted
sbx secret set -g github
```

**Check it worked:** run `sbx policy ls` — you should see `api.gsa.usai.gov`
in the list of allowed network destinations.

> [!NOTE]
> USAi API keys expire every 7 days; when one does, see
> [Troubleshooting](#troubleshooting) to rotate it.

### Step 4: Create and run a sandbox (as often as you like)

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
<summary><strong>Authentication failures (expired USAi key)</strong> (click to expand)</summary>

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
<summary><strong>Network policy blocks USAi</strong> (click to expand)</summary>

```bash
sbx policy allow network -g "api.gsa.usai.gov"
```

> Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent.

</details>

<details>
<summary><strong>"sbx policy init" fails right after first-time setup</strong> (click to expand)</summary>

The policy service may not have settled yet after `sbx login`. Retry the command:

```bash
sbx policy init balanced
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

### What `qsbx` applies

`qsbx` applies **three sbx mixin kits** (by pinned remote reference from the
community [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo) when it creates a sandbox, delivering everything declaratively:

- **`usai-provider`** — drops the USAi config at `~/usai-config/opencode.jsonc`
  and sets `OPENCODE_CONFIG` to point there (allow-listing USAi egress).
- **`agentic-coding-playbook`** — clones the playbook at startup into
  `~/.agentic-coding-playbook` and symlinks its `AGENTS.md` into each agent's
  rules path and its skills into `~/.agents/skills` (+ per-agent roots).
- **`zscaler-ca-certificate`** — installs the public Zscaler Root CA into the
  sandbox trust store (harmless off-Zscaler).

`qsbx` also handles the `sbx` prerequisites for you: it adds the kit source to
`sbx settings kit.allowedSources` (the v0.34 remote-kit allowlist) and requires
`sbx` ≥ 0.34.0 — no manual setup.

> While the playbook repo is private (during rollout), the clone needs a GitHub
> token — set it once with `sbx secret set -g github`. The sbx proxy injects it;
> the container never sees it. Once the repo is public this is unnecessary.

### Why the USAi key uses `set-custom`

USAi is not a built-in sbx service, so we store its key with
`sbx secret set-custom` (with an explicit `--host`) instead of `sbx secret set -g`.
The built-in `set -g` form only recognizes known providers.

### Key pre-validation

Before attaching, `qsbx` checks that the sandbox's USAi key still works. If it
has expired, it walks you through [rotating it](#troubleshooting) and
re-validates before launching the agent.

### How default USAi models are chosen

The `usai-provider` kit ships an `opencode.jsonc` with a generated USAi model
catalog, kept in sync with the USAi `/models` API so new projects start from a
current baseline. Default model policy:

- `model` tracks the highest available Opus generation
- `agent.compaction.model` tracks the highest available GPT generation
- `small_model` stays a curated fast/cheap fallback

It is still possible for a model listed by `/models` to fail at runtime for a
specific key or request. See
[docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md) for troubleshooting.
The catalog and its refresh tooling live with the kit in the patterns repo.

---
## Customizing your setup

`qsbx` applies a fixed set of three kits, pinned to a commit of the patterns
repo. To customize:

- **Adopt newer kits:** bump `PATTERNS_KIT_REF` near the top of `qsbx`.
- **Add your own kits on every run:** see [Advanced: extra kits](#advanced-extra-kits).
- **Change USAi models / provider config, rules, or skills:** contribute to the
  kits in the
  [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
  repo (`integrations/isolation/sbx-kits/`), where each kit and its design notes
  live.

---

## Advanced: extra kits

`qsbx` always applies its three built-in kits. To apply **additional** kits on
every invocation without repeating `--kit` flags, set `QSBX_EXTRA_KITS` to a
whitespace-separated list of kit references (local paths or remote refs):

```bash
export QSBX_EXTRA_KITS="./my-local-kit git+https://github.com/acme/kits.git#ref=<sha>&dir=some-kit"
```

Extras are applied **after** the built-in kits (so they win on any overlapping
config). They also work when re-running against an existing sandbox: adding a new
entry and re-running `qsbx run <existing-sandbox>` injects just the new kit via
`sbx kit add`.

If an extra kit is hosted somewhere other than `github.com/GSA-TTS/`, add its
scheme-less prefix so `qsbx` allowlists it on `sbx settings kit.allowedSources`:

```bash
export QSBX_EXTRA_KIT_SOURCES="github.com/acme/"
```

---

## Optional Integrations

- **Editor integrations (Zed, etc.)** — Editor task configs and setup guides now
  live in the community
  [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns/tree/main/integrations)
  repo under `integrations/`. (For example, the Zed editor integration is at
  `integrations/editors/zed/`.)
- **OpenCode Web** — Run OpenCode Web in the sandbox and reach it from your host
  browser for clipboard support and richer markdown rendering. The
  [`opencode-web.sh`](opencode-web.sh) script automates it; see the
  [OpenCode Web documentation](https://opencode.ai/docs/web).

---

## Staying Current

Once in a while, refresh this clone to pick up updates, and rotate your USAi key
when it expires (see [Troubleshooting](#troubleshooting)).

```bash
# Update the quickstart clone
git fetch && git pull

# Adopt newer kits (USAi config, playbook, CA): bump PATTERNS_KIT_REF near the
# top of qsbx to a newer agentic-coding-patterns commit, then recreate sandboxes.
```

> [!NOTE]
> **Resuming a sandbox after upgrading to the kit-based `qsbx`.** Sandboxes
> created before the kit migration have an outdated provider config or no
> playbook. The next time you `qsbx run opencode <path>` against such a sandbox,
> `qsbx` detects this and automatically injects the missing kit(s) with `sbx kit
> add` — no action needed. Restart the agent (or start a fresh session) so it
> re-reads the config and picks up the playbook. Requires `sbx` >= 0.34.0, which
> `qsbx` now enforces.

---

## What's Next?

1. **Set up your project properly** — Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
2. **Share what you learn** — Contribute to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** — Found something unclear? Open an issue or submit a PR

### Available Skills and Resources

The playbook provides reusable **agent skills** — step-by-step procedures for
common tasks. Skills follow the [agentskills.io](https://agentskills.io)
standard. When you launch a sandbox with `qsbx`, the `agentic-coding-playbook`
kit clones the playbook at startup and symlinks these into `~/.agents/skills`
(and per-agent roots) so your agent discovers them automatically; no separate
clone is needed.

| Source       | Skills                       | Examples                                                                            |
| ------------ | ---------------------------- | ----------------------------------------------------------------------------------- |
| **Playbook** | Federal compliance, security | `federal-security-controls-lookup`, `ato-package`, `code-review`, `cloudgov-deploy` |
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
| `qsbx`                              | sbx wrapper that applies the three community kits to each sandbox |
| `scripts/rotate-apikey`             | Rotate your USAi API key secret (`qsbx usai-rotate-api-key`) |
| `.pre-commit-config.yaml`           | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md`                         | Rules for working **on this quickstart repo**              |
| `docs/QUICKSTART_SBX.md`            | Full sbx CLI setup guide                                   |
| `docs/KNOWN_FAILURE_MODES.md`       | Troubleshooting guide                                      |

---

**Data Classification:** Internal/Non-sensitive
