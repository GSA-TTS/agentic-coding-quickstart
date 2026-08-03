# Agentic Coding Quickstart

> **Audience:** GSA teams using AI coding agents
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi

**In one sentence:** this quickstart gets you running an AI coding agent connected to USAi in under 5 minutes, using `acq`, a CLI tool provided here.

**`acq`** is the entry point. It presents one command surface over two
pluggable isolation backends and applies a federally-configured set of kits:

| Backend | What it is | Needs |
| ------- | ---------- | ----- |
| **msb** (microsandbox) — **default** | FOSS microVM runtime | Host virtualization (KVM/HVF/WHP). No Docker account or seat. |
| **sbx** (Docker Sandboxes) | Docker's sandbox CLI | A Docker account (your org may require a paid seat). Docker Desktop **not** required. |

`acq` auto-detects an installed backend — **msb is preferred when both are
present** — or you can pick one explicitly with `--backend`, `ACQ_BACKEND`, or
`acq backend set`. The same commands and the same kits work on either backend;
see [docs/BACKEND_GUIDE.md](docs/BACKEND_GUIDE.md) for the full comparison.

This guide leads with the default **msb** path. If you'd rather use Docker
Sandboxes, jump to [Using the sbx backend](#using-the-sbx-backend).

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
| Host virtualization | msb runs a microVM, so it needs hardware virtualization: **KVM** (`/dev/kvm`) on Linux, **HVF** on Apple Silicon macOS, **WHP** on Windows. Run `msb doctor` after Step 2 to check (and `msb doctor --fix` to set up). |
| USAi API key    | [Create one](https://console.gsa.usai.gov/key-management), record it safely, and keep it handy            |
| GitHub CLI (`gh`) | (optional) GitHub's official command-line tool ([install](https://cli.github.com/)). It lets the coding agent work with your repos without you handling a token by hand. |
| GitHub personal access token | (optional) Needed only if you are **not** using the GitHub CLI |

<details>
<summary>How to verify each requirement (click to expand)</summary>

Run each command in your terminal. If a command isn't found, that requirement isn't installed yet.

- **Host virtualization** — you can't confirm this until Step 2, since `msb` isn't installed yet. It's confirmed when `msb doctor` reports the host is ready.
- **USAi API key** — visit [the key-management console](https://console.gsa.usai.gov/key-management); you should see (or be able to create) a key. Have the token string ready to paste in Step 3.
- **GitHub CLI** — `gh auth status` should report that you're logged in.
- **GitHub personal access token** — only needed without the GitHub CLI; have the token string ready to paste in Step 3.

</details>

### Step 1: Clone this repo

```bash
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
```

The remaining steps must be run from inside this cloned folder.

### Step 2: Install microsandbox (msb)

msb is a standalone, open-source (Apache-2.0) microVM runtime — **no Docker
account or seat is required.**

```bash
curl -fsSL https://install.microsandbox.dev | sh    # macOS / Linux
# or, with Homebrew:
brew install superradcompany/tap/microsandbox
```

**Check it worked:** run `msb doctor`. It reports whether your host is ready to
run microVMs (KVM on Linux, HVF on Apple Silicon, WHP on Windows). If something
is missing, `msb doctor --fix` attempts to set it up.

> [!IMPORTANT]
> **acq requires `msb` ≥ 0.6.0** — the release where the `--net-rule`,
> `--trust-host-cas`, and `--secret` flags that `acq` relies on are available.
> Update at any time with `msb self update`.
>
> **On Linux, your user needs access to `/dev/kvm`.** If `msb doctor` reports a
> permission problem, add yourself to the `kvm` group once:
>
> ```bash
> sudo usermod -aG kvm "$USER" && newgrp kvm
> ```

### Step 3: Configure secrets (once)

`acq` owns a backend-neutral secret store, so you set your secrets once and they
work on whichever backend you run. msb binds each secret to its endpoint at
create time; the real value **never enters the guest** (msb substitutes it on
the wire over intercepted TLS).

```bash
# 1. Store your USAi API key (you will be prompted for it)
./acq secret set -g usai

# 2. Store a GitHub token (for code access)
#
# RECOMMENDED — scope a token per-sandbox to just the repos you mount. On
# `acq run`, if a sandbox has no repo-scoped token, acq detects the repos in
# your workspace and walks you through creating a fine-grained token limited to
# them. You can also do it explicitly:
#   acq github-scope <sandbox-name> /path/to/your/project
#
# If you use the GitHub CLI:
gh auth login                          # if not already authenticated
gh auth token | ./acq secret set -g github

# Or store a personal access token directly (you will be prompted):
./acq secret set -g github
```

> [!WARNING]
> `gh auth token` and classic PATs carry **account-wide** scopes (`repo`,
> `workflow`, `delete_repo`, …). Stored globally (`-g`), that broad authority is
> injected into **every** sandbox — an agent working on one project can act as
> you on **all** your repositories. Prefer a per-sandbox fine-grained token
> scoped to the mounted repos (see `acq github-scope` above and
> [ADR-0013](docs/adr/0013-per-sandbox-github-token-downscoping.md)).
> Fine-grained tokens can't contribute to public repos you're not a member of or
> call the Checks API — fall back to the global token for those cases.

**Check it worked:** run `./acq secret ls` — you should see your `usai` (and
`github`) entries in the store.

> [!NOTE]
> USAi API keys expire every 7 days; when one does, see
> [Troubleshooting](#troubleshooting) to rotate it.
>
> Sandboxes also sign your git commits with your host SSH key. For those commits
> to show **Verified** on GitHub you need, one time: a GitHub-verified
> `user.email` set **in the project** (repo-local config, since the sandbox has
> its own home and does not see your host global git config) and your **public**
> signing key registered on GitHub as a _Signing Key_. See
> [Commits show "Unverified" on GitHub](#troubleshooting) below.

### Step 4: Create and run a sandbox (as often as you like)

```bash
./acq run opencode /path/to/your/project
```

That's it. You're now running an AI coding agent with USAi access and restricted filesystem and network access. Repeat this to create sandboxes for each project you want to work on.

**Want to know more about what `acq` is doing under the hood?** See [How It Works](#how-it-works).

**Need more details?** See the [acq Quickstart](docs/QUICKSTART.md) and the [Backend Guide](docs/BACKEND_GUIDE.md).

**Working across multiple repos?** See [Multiple Workspaces](docs/QUICKSTART_SBX.md#multiple-workspaces) for mounting extra directories.

---

## Using the sbx backend

Prefer Docker's sandbox runtime? `acq` runs the exact same commands on **sbx**.
The only differences are installation and how secrets are injected (via the sbx
proxy rather than msb's on-the-wire substitution).

### Step 1: Install the sbx CLI

The `sbx` CLI is a standalone tool — Docker Desktop is **not required** (you do
need a Docker account, and your org may require a paid seat; see the note below).

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

Add Docker's official apt repository (verified by its signed GPG key), then
install `docker-sbx` — instead of piping a remote script into a root shell:

```bash
# 1. Add Docker's apt repo with its verified signing key
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 2. Install the sbx package from the now-trusted repo
sudo apt-get update
sudo apt-get install -y docker-sbx
sudo usermod -aG kvm "$USER" && newgrp kvm
sbx login
```

See [Docker's apt install docs](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository).

</details>

**Check it worked:** after `sbx login` finishes with no error, run `sbx version`.
You should see a line like `sbx version: v0.35.0 <sha>`.

> [!IMPORTANT]
> **The sbx backend requires `sbx` ≥ 0.35.0.** This is the release where `sbx
> kit add` recreates a sandbox with the added kit while preserving its state,
> which is how `acq` heals sandboxes created by an older version (see
> [Staying Current](#staying-current)).
>
> **Linux/ARM64 note:** sbx `0.35.x` publishes **no Linux/ARM64 build** (deferred
> to `0.36.x` per the sbx release notes). On a Linux/ARM64 host you can't yet
> install a version that meets this floor — use the msb backend instead, run
> `acq` on an x86_64 host, or wait for the `0.36.x` release.
>
> **About the Docker subscription.** `sbx login` signs in with a Docker account.
> In at least one organization we've seen, sign-in fails with a "Not enough
> seats" error unless you have a paid Docker subscription seat. Docker Desktop
> itself is **not required** to run `sbx` — but if you do have a Docker Desktop
> subscription, that already provides your seat. If you hit the seats error, ask
> your organization's Docker administrator to assign you one. For how Docker
> licensing works, see [Docker's subscription docs](https://docs.docker.com/subscription/).

### Step 2: Configure secrets and run

Secrets are still owned by `acq`'s backend-neutral store, so the same
`./acq secret set` commands from [Step 3 above](#step-3-configure-secrets-once)
apply. On sbx, `acq` feeds the value into sbx's own secret manager (custom
endpoints like USAi are entered once at sbx's interactive prompt so the value
never lands on the command line). Then run against sbx explicitly:

```bash
./acq --backend sbx run opencode /path/to/your/project

# Or persist sbx as your backend so you don't repeat the flag:
./acq backend set sbx
```

For the full sbx CLI reference (network policy, multiple workspaces, proxy
patterns), see the [Full sbx CLI Guide](docs/QUICKSTART_SBX.md).

---

## Troubleshooting

If the happy path above didn't work, the most common issues are below. For
everything else (wrong providers, auth failures, TLS/certificate errors, and
more), see **[docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)**.

<details>
<summary><strong>Authentication failures (expired USAi key)</strong> (click to expand)</summary>

USAi API keys expire every 7 days, which is the most common cause of errors like:

```
Unauthorized: {"detail":"Not authenticated"}
```

The simplest fix: end your session, then run `./acq run opencode <path>` again.
`acq` validates the key on attach and walks you through rotating it when needed.

To rotate the key explicitly outside that workflow:

1. Open https://console.gsa.usai.gov/key-management
2. Choose "Rotate" from the "Actions" menu for your key
3. Copy the new key using the console copy button
4. With the key in your paste buffer, run:

   ```bash
   ./acq usai-rotate-api-key
   ```

   (or run the underlying `scripts/rotate-apikey` directly — a thin shim that
   forwards to `acq usai-rotate-api-key`). It prompts for the new key, then
   validates it in a temporary sandbox. Rotation runs through the active
   backend (msb or sbx), so it works regardless of which backend you use.

</details>

<details>
<summary><strong>msb: guest can't resolve hosts / every request fails</strong> (click to expand)</summary>

If outbound requests fail with `Could not resolve host`, your host's DNS
resolver is likely a corporate/VPN address that is unreachable from the
microVM's network namespace. `acq` passes a public resolver (`1.1.1.1`) to the
guest by default; override it if `1.1.1.1` is blocked in your environment:

```bash
export ACQ_MSB_DNS_NAMESERVER=<a-resolver-reachable-from-the-guest>
```

See [docs/BACKEND_GUIDE.md](docs/BACKEND_GUIDE.md#dns--name-resolution) for details.

</details>

<details>
<summary><strong>sbx: network policy blocks USAi</strong> (click to expand)</summary>

```bash
sbx policy allow network -g "api.gsa.usai.gov"
```

> Do NOT use "Open" policy on GFE — it exposes internal GSA resources to the agent.

</details>

<details>
<summary><strong>Commits show "Unverified" on GitHub</strong> (click to expand)</summary>

Sandboxes sign commits with the SSH key forwarded from your host (the
`git-ssh-sign` kit). A signed commit is only marked **Verified** on GitHub when
**both** of these are true — signing alone is not enough:

1. The commit's `user.email` is an email **verified on your GitHub account**, and
2. Your **public** signing key is registered on that account **as a Signing
   Key** (not just an authentication key).

No kit sets your identity, and — importantly — the sandbox has its **own home
directory**, so your host's **global** git config (`~/.gitconfig`) is **not
visible inside it**. Only the project's **repo-local** identity (stored in the
workspace, which is mounted) reaches the sandbox. So `acq` checks the project's
local `user.email` before attaching and warns if it's unset. To fix it (one
time, in the project):

**Step 1 — set a GitHub-verified identity in the project** (repo-local, so the
sandbox sees it — run this inside the project directory):

```bash
git config user.email you@verified-on-github.example
git config user.name  "Your Name"
```

**Step 2 — register your signing key on GitHub.** Add the **public** half of your
signing key as a **Signing Key**: _Settings → SSH and GPG keys → New SSH key →
Key type: **Signing Key**_. (The same key may already be an authentication key;
add it again as a signing key.)

Then make a **new** commit — verification applies going forward.

> Prefer a global identity? You can instead set `user.email` in a git config
> that lives **inside the mounted workspace** (repo-local is simplest). A plain
> `git config --global` on your host will **not** carry into the sandbox.

For the signing mechanics and more failure modes, see the kit's
[`TROUBLESHOOTING.md`](https://github.com/GSA-TTS/agentic-coding-patterns/blob/main/integrations/isolation/acq-kits/git-ssh-sign/TROUBLESHOOTING.md).

</details>

<details>
<summary><strong>Pulled a branch but acq behaves like the old version</strong> (click to expand)</summary>

`git pull origin <branch>` does **not** switch you to that branch — it merges
into the branch you are already on, so `Already up to date` does not mean your
working tree changed. Also, if `acq` is on your `PATH` (e.g. a symlink in
`~/bin`), it may resolve to a **different clone** than the one you edited.

Ask acq which file and clone are actually running:

```bash
./acq version
```

It prints the resolved script path, the clone directory, and that clone's
`branch@commit`. If it isn't what you expect, either `git switch <branch>` in the
clone you run from, or re-point your `acq` symlink. See
[docs/KNOWN_FAILURE_MODES.md §24](docs/KNOWN_FAILURE_MODES.md).

</details>

---

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. That makes them potent agents of chaos if they're compromised. Running them in sandboxes provides:

- **Isolation** — Agent shouldn't be able to access the full host system; they should be limited both the filesystem and network access
- **Secret protection** — Secrets are injected into outgoing requests (msb substitutes them on the wire; sbx uses a proxy), so the actual secret is never available to the agent for exfiltration
- **Reproducibility** — Agents should have a consistent configuration tailored to their operating context every time they run
- **Audit trail** — Hard boundaries for what the agent can do, potentially logging violations

For a full comparison of the two backends and their tradeoffs, see [docs/BACKEND_GUIDE.md](docs/BACKEND_GUIDE.md).

---

## How It Works

You can skip this section to get started — it explains the mechanics behind the
quickstart for when you want to customize or troubleshoot.

### What happened when I ran the `acq` command?

`acq run` created the sandbox for that path (if it didn't exist yet) using the active backend (`msb` by default), making sure that this clone was accessible inside it. Then it configured the coding agent (`opencode`) to pick up configuration for using the USAi provider and made sure the agent was provisioned with custom guidance and relevant skills for working in the federal context.

### What `acq` applies

`acq` applies **four mixin kits** (by pinned remote reference from the
community [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo) when it creates a sandbox, delivering everything declaratively. Kits are
authored once in a neutral vocabulary and translated to whichever backend is
active:

- **`usai-provider`** — stages the USAi config at `~/usai-config/opencode.jsonc`
  and, at startup, merges it into OpenCode's global config at
  `~/.config/opencode/opencode.jsonc` (allow-listing USAi egress). It composes
  with, rather than clobbers, any existing global config, and no longer sets
  `OPENCODE_CONFIG`.
- **`agentic-coding-playbook`** — clones the playbook at startup into
  `~/.agentic-coding-playbook` and symlinks its `AGENTS.md` into each agent's
  rules path and its skills into `~/.agents/skills` (+ per-agent roots).
- **`zscaler-ca-certificate`** — installs the public Zscaler Root CA into the
  sandbox trust store (harmless off-Zscaler). On msb this uses the native
  `--trust-host-cas` shortcut instead of the file-drop mechanism.
- **`git-ssh-sign`** — signs git commits and tags with the SSH key forwarded
  from your host's SSH agent; the private key never enters the sandbox. Load a
  key on the host first (`ssh-add ~/.ssh/id_ed25519`) — without one, commits fail
  with a clear error, and `acq` warns you before attaching. Signing alone does
  not make a commit GitHub-**Verified**; see
  [Commits show "Unverified" on GitHub](#troubleshooting).

On the sbx backend, `acq` also handles the `sbx` prerequisites for you: it adds
the kit source to `sbx settings kit.allowedSources` (the remote-kit allowlist)
and requires `sbx` ≥ 0.35.0 — no manual setup.

> While the playbook repo is private (during rollout), the clone needs a GitHub
> token — set it once with `./acq secret set -g github`. The backend injects it;
> the container never sees it. Once the repo is public this is unnecessary.

### How the USAi key is injected

USAi is not a built-in service on either backend, so `acq` stores its key in its
own backend-neutral secret store (`./acq secret set -g usai`) with an explicit
endpoint (`api.gsa.usai.gov`). At create time msb binds it with
`--secret USAI_API_KEY@api.gsa.usai.gov` (substituted on the wire), and on sbx
`acq` feeds it to `sbx secret set-custom`. Either way the real value stays out of
the guest.

### Key pre-validation

Before attaching, `acq` checks that the sandbox's USAi key still works. If it
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

`acq` applies a fixed set of four kits, pinned to a commit of the patterns
repo. To customize:

- **Adopt newer kits:** bump `PATTERNS_KIT_REF` near the top of `acq.backends/common.sh`.
- **Add your own kits on every run:** see [Advanced: extra kits](#advanced-extra-kits).
- **Change USAi models / provider config, rules, or skills:** contribute to the
  kits in the
  [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
  repo (`integrations/isolation/acq-kits/`), where each kit and its design notes
  live.

---

## Advanced: extra kits

`acq` always applies its four built-in kits. To apply **additional** kits on
every invocation without repeating `--kit` flags, set `ACQ_EXTRA_KITS` to a
whitespace-separated list of kit references (local paths or remote refs):

```bash
export ACQ_EXTRA_KITS="./my-local-kit git+https://github.com/acme/kits.git#ref=<sha>&dir=some-kit"
```

Extras are applied **after** the built-in kits (so they win on any overlapping
config). They also work when re-running against an existing sandbox: adding a new
entry and re-running `acq run <existing-sandbox>` injects just the new kit.

If an extra kit is hosted somewhere other than `github.com/GSA-TTS/`, add its
scheme-less prefix so `acq` allowlists it (on sbx, this is added to
`sbx settings kit.allowedSources`):

```bash
export ACQ_EXTRA_KIT_SOURCES="github.com/acme/"
```

---

## Optional Integrations

- **Editor integrations (Zed, etc.)** — Editor task configs and setup guides now
  live in the community
  [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns/tree/main/integrations)
  repo under `integrations/`. (For example, the Zed editor integration is at
  `integrations/editors/zed/`.)
- **OpenCode Web** — Run OpenCode in the sandbox and reach it from your host
  browser for clipboard support and richer markdown rendering. Use the
  [`openchamber` acq kit](https://github.com/GSA-TTS/agentic-coding-patterns/tree/main/integrations/isolation/acq-kits/openchamber),
  which runs `opencode serve` on host-published port 4096 (plus the OpenChamber
  UI on 3000) via a supervised lifecycle, on both backends.

---

## Staying Current

Once in a while, refresh this clone to pick up updates, and rotate your USAi key
when it expires (see [Troubleshooting](#troubleshooting)).

```bash
# Update the quickstart clone
git fetch && git pull

# Adopt newer kits (USAi config, playbook, CA): bump PATTERNS_KIT_REF near the
# top of acq.backends/common.sh to a newer agentic-coding-patterns commit, then
# recreate sandboxes.
```

> [!NOTE]
> **Resuming a sandbox created by an older `acq`.** Sandboxes created before the
> kit migration have an outdated provider config or no playbook. The next time you
> `acq run opencode <path>` against such a sandbox, `acq` detects the missing
> kit(s) and re-applies them. On the sbx backend (≥ 0.35.0) `sbx kit add`
> recreates the sandbox with the added kit while **preserving its state**, so your
> work and sessions survive; on msb the built-in kits are re-applied idempotently.
> Restart the agent (or start a fresh session) so it re-reads the config and picks
> up the playbook.

### Migrating an existing clone off the playbook submodule

Earlier versions vendored the playbook as a git submodule at
`agentic-coding-playbook/`. The kits now live in the
[agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo and `acq` fetches them at sandbox-create time, so the submodule is gone. If
you cloned before that change, `git pull` leaves an orphaned submodule directory;
clean it up once:

```bash
git submodule deinit -f agentic-coding-playbook 2>/dev/null || true
git rm -f agentic-coding-playbook 2>/dev/null || true
rm -rf .git/modules/agentic-coding-playbook agentic-coding-playbook
```

No sandbox impact — the playbook is delivered by the `agentic-coding-playbook`
kit, not the submodule.

---

## What's Next?

1. **Set up your project properly** — Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
2. **Share what you learn** — Contribute to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** — Found something unclear? Open an issue or submit a PR

### Available Skills and Resources

The playbook provides reusable **agent skills** — step-by-step procedures for
common tasks. Skills follow the [agentskills.io](https://agentskills.io)
standard. When you launch a sandbox with `acq`, the `agentic-coding-playbook`
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
| `acq`                               | Entry point — pluggable-backend wrapper (msb by default, or sbx) |
| `acq.backends/`                     | Backend adapters (`common.sh`, `sbx.sh`, `msb.sh`, `kit-translate.sh`, `secret-store.sh`) |
| `scripts/rotate-apikey`             | Rotate your USAi API key secret (`acq usai-rotate-api-key`) |
| `scripts/test-acq`                  | Offline unit harness for acq |
| `scripts/verify-backends`           | Live end-to-end backend verification (needs Docker or KVM) |
| `.pre-commit-config.yaml`           | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md`                         | Rules for working **on this quickstart repo**              |
| `docs/QUICKSTART.md`                | acq quickstart and backend selection guide                |
| `docs/BACKEND_GUIDE.md`             | Per-backend strengths, tradeoffs, and configuration       |
| `docs/QUICKSTART_SBX.md`            | Full sbx CLI setup guide                                   |
| `docs/KNOWN_FAILURE_MODES.md`       | Troubleshooting guide                                      |

---

**Data Classification:** Internal/Non-sensitive
