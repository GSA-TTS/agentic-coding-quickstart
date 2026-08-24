# Agentic Coding Quickstart

> **Audience:** Federal teams using AI coding agents \
> **Purpose:** Get AI coding agents running safely inside isolated sandboxes, connected to USAi (the GSA-hosted LLM gateway at `api.gsa.usai.gov`)

**In one sentence:** this quickstart gets you running an AI coding agent connected to USAi in under 5 minutes, using `acq`, a CLI tool provided here.

**`acq`** is the entry point. It runs your agent inside an isolated sandbox and
configures the environment for federal usage. To provide that isolation, it uses **`msb`**
(microsandbox), a lightweight, open-source microVM runtime.

> acq is designed to support multiple isolation backends. A Docker Sandboxes (**`sbx`**) backend
> is also supported. See [docs/howto/sbx.md](docs/howto/sbx.md) for sbx setup and
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

You'll do three things: **open a terminal**, **install `acq`**, and **run it**.
You do **not** need to be a developer, and you do **not** need administrator
rights on your Mac.

### Step 1: Open a terminal

- **macOS:** press ⌘-Space, type "Terminal", press Return. (Or find it in
  Applications → Utilities.)

You'll type (or paste) the commands below into this window.

> **Not on an Apple Silicon Mac?** The sandbox needs hardware virtualization. See
> [prerequisites and other platforms](#prerequisites-and-other-platforms) below.

### Step 2: Install acq

Paste this one line and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/GSA-TTS/agentic-coding-quickstart/main/install.sh | sh
```

That's it — you don't have to choose *how* to install. The installer:

- **picks the best method already on your Mac** — Homebrew if you have it, then
  npm if you have it, otherwise a self-contained download — so you get automatic
  upgrades/uninstall if you already use a package manager, and a working setup
  either way,
- puts the `acq` command on your computer so you can run it from **any folder**,
- offers to install **msb** (the sandbox `acq` runs your agent inside), and
- **asks before** changing anything about your setup — it never edits your
  configuration without your OK, and it never needs administrator rights.

<details>
<summary>Prompted to install "Command Line Tools"? (click to expand)</summary>

acq needs Apple's **Command Line Tools** (they provide `git`, which acq uses).
If they aren't installed yet, the installer starts them for you and **waits**
while they install — you'll see a window titled **"Install Command Line
Developer Tools."** Click **Install** and accept the license. No administrator
rights are required.

**Can't find the window?** It sometimes opens **minimized in your Dock** rather
than in front of you — look there. The installer keeps waiting until the tools
finish, then continues on its own.

</details>

<details>
<summary>Prefer to look before you run it? (recommended) (click to expand)</summary>

You never have to pipe a script straight into your shell. Download it, read it,
then run it:

```bash
curl -fsSL -o install-acq.sh https://raw.githubusercontent.com/GSA-TTS/agentic-coding-quickstart/main/install.sh
less install-acq.sh      # read it
sh install-acq.sh --dry-run   # show what it WOULD do, changing nothing
sh install-acq.sh             # actually install
```

You can also force a specific method with `--method brew|npm|clone`.

</details>

<details>
<summary>Already use Homebrew or Node? (click to expand)</summary>

You don't need to do anything special — the one-line installer above **detects
Homebrew and npm automatically** and uses whichever you have (falling back to a
self-contained download if you have neither). Package-manager installs give you
`upgrade`/`uninstall` for free.

If you'd rather run the direct command yourself:

```bash
npm install -g github:GSA-TTS/agentic-coding-quickstart   # if you use Node/npm — works today
brew install GSA-TTS/tap/acq                              # if you use Homebrew — coming soon (tap not published yet)
```

</details>

### Step 3: Run it

Point `acq` at the folder you want the agent to work in (an existing project, or
a new empty folder you just made):

```bash
acq run opencode ~/my-project
```

That's it — you're now running an AI coding agent with USAi access and
restricted filesystem and network access. Repeat Step 3 for each project.

> [!NOTE]
> **The first run takes a minute or two.** `acq` boots a microVM, installs the
> coding agent, and fetches its configuration kits, showing progress as it goes.
> Later runs against the same project are much faster.

On first run, `acq` sets you up interactively — nothing to configure beforehand:

- **USAi key** — `acq` prompts you to paste a key and validates it. Create one at
  the [USAi key console](https://console.gsa.usai.gov/key-management) (keys expire
  every 7 days).
- **GitHub token** — when your project contains GitHub repos, `acq` offers to walk
  you through creating a repo-scoped token. You can decline and add one later.
- **Git signing** — `acq` warns if your commits won't sign/verify correctly, and
  tells you how to fix it.

`acq` injects secrets into the sandbox at runtime — the real values **never enter
the guest**.

---

### Prerequisites and other platforms

Almost nothing to gather in advance — `acq` walks you through the USAi key and
GitHub access on first run. What you do need:

| Requirement | Notes |
| --- | --- |
| A supported host | The sandbox uses hardware virtualization. You need **macOS on Apple Silicon** (Intel Macs are not supported), **Windows 11** with the Windows Hypervisor Platform (preview), or **Linux** (glibc, with `/dev/kvm`). More detail: [msb host setup](docs/howto/acq.md#msb-host-setup). |
| A terminal | macOS: Terminal (⌘-Space → "Terminal"). Windows: Windows Terminal / PowerShell. Linux: Ctrl-Alt-T. |
| USAi API key | `acq` prompts for it on first run. [Create one here](https://console.gsa.usai.gov/key-management). |

**Manual install (developers).** If you'd rather clone and run from the clone —
or want a specific tagged release — see [Manual install](#manual-install).

**Want the sbx backend instead of msb?** See the
[Backend Guide](docs/BACKEND_GUIDE.md) and [sbx How-To](docs/howto/sbx.md).

**Want to know what `acq` is doing under the hood?** See
[How It Works](#how-it-works).

**Working across multiple repos?** See
[Multiple Workspaces](docs/CONCEPTS.md#multiple-workspaces).

---

### Manual install

If you're comfortable in a terminal and prefer to run `acq` from a clone:

```bash
git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
./acq run opencode ~/my-project
```

You'll also need the `msb` sandbox runtime — install it without admin via
`curl -fsSL https://install.microsandbox.dev | sh` (or, if you have Homebrew,
`brew install superradcompany/tap/microsandbox`).

> **Running `./acq` from the clone?** It only works from **inside** the
> `agentic-coding-quickstart` folder (that's where the `acq` file lives). If you
> get "no such file `./acq`", `cd` back into that folder first. The one-line
> installer in [Step 2](#step-2-install-acq) avoids this entirely by putting `acq`
> on your PATH.

<details>
<summary>Testing a specific tagged release? (click to expand)</summary>

After cloning, check out the tag:

```bash
git checkout v3.0.0-rc2
```

Git prints a message about a **"detached HEAD" state** — that's **normal, not an
error.** It just means you're on a specific snapshot. Run `acq` as usual; to go
back to the latest, run `git switch main`.

</details>

---

## Troubleshooting

If the happy path above didn't work, the most common issues are below. For
everything else (wrong providers, auth failures, TLS/certificate errors, and
more), see **[docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)**.

<details>
<summary><strong>"no such file or directory: ./acq"</strong> (click to expand)</summary>

This means `acq` isn't where you're typing the command. Two fixes:

- **Recommended:** install `acq` with the one-line installer in
  [Step 2](#step-2-install-acq). Then run `acq` (no `./`) from **any** folder.
- **If you cloned manually:** `./acq` only works from **inside** the
  `agentic-coding-quickstart` folder — that's where the `acq` file lives. `cd`
  back into it first (`cd ~/agentic-coding-quickstart`, or wherever you cloned
  it), then run `./acq run opencode ~/my-project`.

</details>

<details>
<summary><strong>"No developer tools were found" / git won't run</strong> (click to expand)</summary>

The first time your Mac uses `git`, it installs the Command Line Tools. If you
see `xcode-select: note: No developer tools were found, requesting install`,
run:

```bash
xcode-select --install
```

A pop-up window titled **"Install Command Line Developer Tools"** appears — click
**Install** and accept the license. **If you can't find the window, look in your
Dock** — it sometimes opens minimized there rather than in front of you. When it
finishes, re-run your command. (No administrator rights are required.)

</details>

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
signing key as a **Signing Key**: *Settings → SSH and GPG keys → New SSH key →
Key type: **Signing Key***. (The same key may already be an authentication key;
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
| `scripts/test-acq-bats`             | Offline unit suite for acq (bats-core) |
| `scripts/verify-backends`           | Live end-to-end backend verification (needs Docker or KVM) |
| `.pre-commit-config.yaml`           | Optional pre-commit hooks (secret detection, file hygiene) |
| `AGENTS.md`                         | Rules for working **on this quickstart repo**              |
| `docs/howto/acq.md`                 | acq how-to guide and backend selection                     |
| `docs/BACKEND_GUIDE.md`             | Per-backend strengths, tradeoffs, and configuration       |
| `docs/howto/msb.md`                 | msb (microsandbox) setup guide — the default backend       |
| `docs/howto/sbx.md`                 | sbx CLI setup guide — the alternative backend              |
| `docs/KNOWN_FAILURE_MODES.md`       | Troubleshooting guide                                      |

---

**Data Classification:** Internal/Non-sensitive — the Quickstart is a **local development environment** for building Low/Moderate-impact code and projects, not an authorized production/hosted environment (no PII, no CUI).
