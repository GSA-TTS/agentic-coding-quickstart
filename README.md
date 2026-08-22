# Agentic Coding Quickstart

> **Audience:** Federal teams using AI coding agents \
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi (the GSA-hosted LLM gateway at `api.gsa.usai.gov`)

**In one sentence:** this quickstart gets you running an AI coding agent connected to USAi in under 5 minutes, using `acq`, a CLI tool provided here.

**`acq`** is the entry point. It runs your agent inside an isolated sandbox and
configures the environment for federal usage. To provide that isolation, it uses **`msb`**
(microsandbox), a lightweight, open-source microVM runtime.

> acq is designed to support multiple isolation backends. A Docker Sandboxes (**`sbx`**) backend
> is also supported. See [docs/QUICKSTART_SBX.md](docs/QUICKSTART_SBX.md) for sbx setup and
> [docs/BACKEND_GUIDE.md](docs/BACKEND_GUIDE.md) for how the two backends compare.

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

You will run the commands in this guide from a terminal. Open one now...

<details>
<summary>How to open a terminal (click to expand)</summary>

- **macOS:** open **Terminal** — find it in Applications → Utilities, or press ⌘-Space, type "Terminal", and press Return.
- **Windows:** open **Windows Terminal** or **PowerShell** — press the Start button, type "Terminal" (or "PowerShell"), and press Enter.
- **Linux (Ubuntu):** press Ctrl-Alt-T, or search for "Terminal" in your applications menu.

</details>

Good news: there's very little to gather in advance. You need a supported
computer and a way to run these commands — `acq` walks you through the USAi key
and GitHub access interactively on first run (see [Step 3](#step-3-create-and-run-a-sandbox)).

| Requirement     | Notes                                                      |
| --------------- | ---------------------------------------------------------- |
| A supported host for microVMs | msb uses hardware virtualization. You need one of:<ul><li>**macOS** — Apple Silicon (Intel Macs are not supported)</li><li>**Windows 11** — with the Windows Hypervisor Platform enabled (preview)</li><li>**Linux** — glibc-based, with KVM enabled (`/dev/kvm` present)</li></ul>If you need more detail than this, see [msb host setup](docs/QUICKSTART.md#msb-host-setup) for per-platform particulars. |
| `git`           | Already installed on macOS and on the supported Linux hosts — **nothing to do**. (On macOS, the first time you run a `git` command the system may offer to install the Command Line Tools; accept it.) Check with `git --version`. |
| USAi API key    | **Required, but `acq` guides you** — on first run `acq` prompts you to paste a key and validates it, so you need not configure anything beforehand. You will need to [create a key](https://console.gsa.usai.gov/key-management) (do it now or when prompted); USAi keys expire every 7 days. <p>Running **non-interactively** (CI/piped) has no prompt, so the key must be set in advance — see [Secrets](docs/QUICKSTART.md#secrets).</p> |
| GitHub token | **Nothing to get in advance** — `acq` offers to walk you through creating a repo-scoped token on first run, when your project contains GitHub repos. You can decline and add one later. <p>(A token lets the agent authenticate to GitHub, work with private repositories, and act on your behalf — open PRs, push to branches, etc.)</p> |

### Step 1: Install microsandbox (msb)

msb is a standalone, open-source (Apache-2.0) microVM runtime (a host-level tool, independent of this repository). Install it on your machine:

```bash
# With Homebrew, our preference at GSA TTS:
brew install superradcompany/tap/microsandbox
```

> Don't have Homebrew? Install it from [brew.sh](https://brew.sh), or use the
> `curl` installer below (which needs no Homebrew).

or

```bash
# More generally, on macOS, Linux, or WSL (Windows):
curl -fsSL https://install.microsandbox.dev | sh
```

### Step 2: Clone this repo

```bash
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
```

The `acq` command in Step 3 is run from inside this cloned folder.

<details>
<summary>Testing a specific tagged release? (click to expand)</summary>

To try a specific tagged version, check it out after cloning:

```bash
git checkout v3.0.0-rc1
```

Git will print a message about being in a **"detached HEAD" state**. That is
**normal — it is not an error.** It just means you're looking at a specific
tagged snapshot rather than a branch. You can run `acq` exactly as described
below. To go back to the latest development version, run `git switch main`.

</details>

### Step 3: Create and run a sandbox

```bash
./acq run opencode /path/to/your/project
```

`/path/to/your/project` is the folder you want the agent to work in. It can be
an **existing project** or a **new, empty folder** you just made for this — your
choice. If the folder is (or will be) a software project, initialize git in it
first so the agent can track its changes:

```bash
mkdir -p ~/my-project        # a new folder, if you don't have one yet
cd ~/my-project
git init .                   # recommended if this is for software development
```

Then point `acq` at it (e.g. `./acq run opencode ~/my-project`).

That's it. You're now running an AI coding agent with USAi access and restricted
filesystem and network access. Repeat this to create sandboxes for each project
you want to work on.

> [!NOTE]
> **The first run does real work and takes a minute or two.** `acq` boots a
> microVM, installs the coding agent, and fetches its configuration kits. It
> shows a progress spinner and status lines as it goes, so you can watch each
> phase — later runs against the same project are much faster. (To silence the
> animation, e.g. in a script, set `ACQ_NO_PROGRESS=1`; plain status lines still
> print.)

On first run, `acq` sets you up interactively — nothing to configure beforehand:

- **USAi key** — `acq` validates your key and, if none is set (or it has
  expired), prompts you to paste one and stores it. Have your key from the
  [prerequisites](#step-0-prerequisites) handy.
- **GitHub token** — when your workspace contains GitHub repos, `acq` offers to
  walk you through creating a repo-scoped token so the agent can access them.
  You can decline and add one later.
- **Git signing** — `acq` warns if your host has no SSH key loaded or the repo
  has no `user.email`, so your sandbox commits sign and verify correctly.

`acq` injects secrets into the sandbox at runtime — the real values **never
enter the guest**. To set secrets ahead of time (for CI or scripted setups),
see [Secrets](docs/QUICKSTART.md#secrets) in the acq Quickstart.

> [!NOTE]
> Sandboxes sign your git commits with your host SSH key on **both** backends —
> sbx forwards the host ssh-agent implicitly, and msb forwards it via `--vsock`
> (msb >= 0.6.9) — both triggered simply by having your host `SSH_AUTH_SOCK` set,
> so `ssh-add` your signing key first. For those commits to
> show **Verified** on GitHub you need, one time: a GitHub-verified `user.email`
> set **in the project** (repo-local config, since the sandbox has its own home
> and does not see your host global git config) and your **public** signing key
> registered on GitHub as a _Signing Key_. See
> [Commits show "Unverified" on GitHub](#troubleshooting) below.

**Want to know more about what `acq` is doing under the hood?** See [How It Works](#how-it-works).

**Need more details, or want to use the sbx backend instead?** See the
[acq Quickstart](docs/QUICKSTART.md), the [Backend Guide](docs/BACKEND_GUIDE.md),
and the [Full sbx CLI Guide](docs/QUICKSTART_SBX.md).

**Working across multiple repos?** Mounting extra directories works on either
backend via `acq`; the command syntax and examples are documented in
[Multiple Workspaces](docs/CONCEPTS.md#multiple-workspaces).

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
workspace, which is mounted) reaches the sandbox. So `acq` checks the repo's
effective git `user.email` before attaching and warns if it's unset. To fix it
(one time, in the project):

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
- **Secret protection** — Secrets are injected into outgoing requests, so the actual secret is never available to the agent for exfiltration
- **Reproducibility** — Agents should have a consistent configuration tailored to their operating context every time they run
- **Audit trail** — Hard boundaries for what the agent can do, potentially logging violations

For a full comparison of the two backends and their tradeoffs, see [docs/BACKEND_GUIDE.md](docs/BACKEND_GUIDE.md).

---

## How It Works

You can skip this section to get started — it explains the mechanics behind the
quickstart for when you want to customize or troubleshoot.

### What happened when I ran the `acq` command?

`acq run` created the sandbox for that path (if it didn't exist yet) and mounted your project into it. Then it configured the coding agent (`opencode`) to pick up configuration for using the USAi provider and made sure the agent was provisioned with custom guidance and relevant skills for working in the federal context — all delivered by kits fetched from the pinned patterns release, not from this clone.

### What `acq` applies

`acq` applies its **built-in mixin kits** (by pinned remote reference from the
community [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
repo) when it creates a sandbox:

- **`usai-provider`** — stages the USAi config at `~/usai-config/opencode.jsonc`
  and, at startup, merges it into OpenCode's global config at
  `~/.config/opencode/opencode.jsonc` (allow-listing USAi egress). It composes
  with, rather than clobbers, any existing global config.
- **`agentic-coding-playbook`** — installs the playbook at startup into
  `~/.agentic-coding-playbook` (a pinned REST tarball on patterns v1.8.0+; older
  bundles cloned it) and symlinks its `AGENTS.md` into each agent's
  rules path and its skills into `~/.agents/skills` (+ per-agent roots).
- **`zscaler-ca-certificate`** — installs the public Zscaler Root CA into the
  sandbox trust store (harmless if Zscaler isn't in use).
- **`git-ssh-sign`** — signs git commits and tags with the SSH key forwarded
  from your host's SSH agent; the private key never enters the sandbox. Load a
  key on the host first (`ssh-add ~/.ssh/id_ed25519`) — without one, commits fail
  with a clear error, and `acq` warns you before attaching. Signing alone does
  not make a commit GitHub-**Verified**; see
  [Commits show "Unverified" on GitHub](#troubleshooting).

### How the USAi key is injected

`acq` stores the USAi API key in its own secret store
(`./acq secret set -g usai`) with an explicit associated endpoint (`api.gsa.usai.gov`) and
injects it into requests at runtime — the real value stays out of the guest.

### Key pre-validation

Before attaching, `acq` checks that the sandbox's USAi key works. If none is set
yet, or it has expired, `acq` prompts you to paste a key (or
[rotate it](#troubleshooting)) and re-validates before launching the agent.

### How default USAi models are chosen

The `usai-provider` kit ships an `opencode.jsonc` with a generated USAi model
catalog, kept in sync with the USAi `/models` API so new projects start from a
current baseline. See the kit definition in the agentic-coding-patterns repository for details.

---
## Customizing your setup

`acq` applies a fixed set of built-in kits, pinned to a commit of the patterns
repo. To customize:

- **Add your own kits on every run:** see [Advanced: extra kits](#advanced-extra-kits).
- **Change USAi models / provider config, rules, or skills:** contribute to the
  kits in the
  [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns)
  repo (`integrations/isolation/acq-kits/`), where each kit and its design notes
  live.
- **Adopt newer kit versions:** bump `PATTERNS_KIT_REF` near the top of `acq.backends/common.sh`.

---

## Advanced: extra kits

`acq` always applies its built-in kits. To apply **additional** kits on
every invocation without repeating `--kit` flags, set `ACQ_EXTRA_KITS` to a
whitespace-separated list of kit references (local paths or remote refs):

```bash
export ACQ_EXTRA_KITS="./my-local-kit git+https://github.com/acme/kits.git#ref=<sha>&dir=some-kit"
```

Extras are applied **after** the built-in kits (so they win on any overlapping
config). They also work when re-running against an existing sandbox: adding a new
entry and re-running `acq run <existing-sandbox>` injects just the new kit.

If an extra kit is hosted somewhere other than `github.com/GSA-TTS/`, add its
scheme-less prefix so `acq` allowlists it:

```bash
export ACQ_EXTRA_KIT_SOURCES="github.com/acme/"
```

---

## Optional Integrations

- **Web UI** — The OpenCode text UI is functional but constraining. By running the Paseo kit, you can interact with sandboxed agents via a feature-rich web UI that includes clipboard support and richer markdown rendering. Use the
  [`paseo` acq kit](https://github.com/GSA-TTS/agentic-coding-patterns/tree/main/integrations/isolation/acq-kits/paseo), then open <http://localhost:6767> in your browser.
- **Editor integrations** — Editor task configs and setup guides now live in the community [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns/tree/main/integrations) repo under `integrations/`. (For example, the Zed editor integration is at `integrations/editors/zed/`.)

---

## Staying Current

Once in a while, refresh this clone to pick up updates, and rotate your USAi key
when it expires (see [Troubleshooting](#troubleshooting)).

```bash
# Update the quickstart clone
git fetch && git pull

```

---

## What's Next?

1. **Set up your project properly** — Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
2. **Share what you learn** — Contribute to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** — Found something unclear? Open an issue or submit a PR

### Available Skills and Resources

The playbook provides reusable **agent skills** — step-by-step procedures for
common tasks. Skills follow the [agentskills.io](https://agentskills.io)
standard. When you launch a sandbox with `acq`, the `agentic-coding-playbook`
kit installs the playbook at startup (a pinned tarball on patterns v1.8.0+) and
symlinks these into `~/.agents/skills`
(and per-agent roots) so your agent discovers them automatically; no separate
checkout is needed.

| Source       | Skills                       | Examples                                                                            |
| ------------ | ---------------------------- | ----------------------------------------------------------------------------------- |
| **Playbook** | Federal compliance, security | `federal-security-controls-lookup`, `ato-package`, `code-review`, `cloudgov-deploy` |
| **Patterns** | Development workflows        | `accessibility-review`, `uswds-prototype`, `test-generation`, `secure-code-review`  |

---

## Getting Help

1. **Troubleshooting:** [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)
2. **Agent behavior:** [AGENTS.md](AGENTS.md)
3. **Questions:** Open a [GitHub issue](https://github.com/GSA-TTS/agentic-coding-quickstart/issues)
4. **Platform issues:** support@usai.gov

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## What's in This Repo

| File/Directory                      | Purpose                                                    |
| ----------------------------------- | ---------------------------------------------------------- |
| `acq`                               | Entry point — pluggable-backend wrapper (msb by default, or sbx) |
| `acq.backends/`                     | Backend adapters (`common.sh`, `sbx.sh`, `msb.sh`, `kit-translate.sh`, `secret-store.sh`, `progress.sh`) |
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

**Data Classification:** Internal/Non-sensitive — the Quickstart is a **local development environment** for building Low/Moderate-impact code and projects, not an authorized production/hosted environment (no PII, no CUI).
