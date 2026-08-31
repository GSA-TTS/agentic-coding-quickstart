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

## Why Sandboxes?

AI coding agents can read files, write code, and execute commands. That makes them potent agents of chaos if they're compromised. Running them in sandboxes provides:

- **Isolation** — Agent shouldn't be able to access the full host system; they should be limited both the filesystem and network access
- **Secret protection** — Secrets are injected into outgoing requests, so the actual secret is never available to the agent for exfiltration
- **Reproducibility** — Agents should have a consistent configuration tailored to their operating context every time they run
- **Audit trail** — Hard boundaries for what the agent can do, potentially logging violations

For the full comparison of the two backends and their tradeoffs, see [docs/BACKEND_GUIDE.md](docs/BACKEND_GUIDE.md).

---

## 5-Minute Quickstart

You'll do three things: **open a terminal**, **install `acq`**, and **run it**.
You do **not** need to be a developer, and you do **not** need administrator
rights on your Mac.

### Step 1: Open a terminal

- **macOS:** press ⌘-Space, type "Terminal", press Return. (Or find it in
  Applications → Utilities.)

You'll type (or paste) the commands below into this window.

> **Not on an Apple Silicon Mac?** The sandbox needs hardware virtualization
> (macOS on Apple Silicon, Windows 11 with the Windows Hypervisor Platform, or
> Linux with `/dev/kvm`). See
> [supported hosts and other platforms](docs/howto/acq.md#msb-host-setup).

### Step 2: Install acq

Paste this one line and press Return:

```bash
curl -fsSL https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v3.0.0/install.sh | sh # x-release-please-version
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
ACQ_VERSION=3.0.0 # x-release-please-version
curl -fsSLO "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v${ACQ_VERSION}/install.sh"
curl -fsSLO "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v${ACQ_VERSION}/SHA256SUMS"
shasum -a 256 -c SHA256SUMS
less install.sh              # read it
sh install.sh --dry-run      # show what it WOULD do, changing nothing
sh install.sh                # actually install
```

The release asset pins the default clone install to the release tag and verifies
that checkout against the release commit. You can also force a specific method
with `--method brew|npm|clone`.

</details>

> **Already use Homebrew or Node, or prefer to run from a clone?** The one-line
> installer detects and uses whichever package manager you have. For the direct
> commands, a manual clone install, or testing a tagged release, see
> [Installing acq](docs/howto/acq.md#installing-acq).

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
  the [USAi key console](https://gsa.usai.gov/console/key-management) (keys expire
  every 7 days).
- **GitHub token** — when your project contains GitHub repos, `acq` offers to walk
  you through creating a repo-scoped token. You can decline and add one later.
- **Git signing** — `acq` warns if your commits won't sign/verify correctly, and
  tells you how to fix it.

`acq` injects secrets into the sandbox at runtime — the real values **never enter
the guest**.

---

## First-Run Snags

The two things a first-timer most often hits are below. For everything else
(expired USAi keys, DNS resolution, unverified commits, stale branches, wrong
providers, auth/TLS failures, and more), see
**[docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)**.

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

---

## Learn More

- **How it works, customizing, extra kits, optional integrations (web UI, editors):**
  [docs/CONCEPTS.md](docs/CONCEPTS.md)
- **Deeper `acq` how-to, backend selection, manual install:**
  [docs/howto/acq.md](docs/howto/acq.md)
- **Choosing between the msb and sbx backends:**
  [docs/BACKEND_GUIDE.md](docs/BACKEND_GUIDE.md)
- **Working across multiple repos:**
  [Multiple Workspaces](docs/CONCEPTS.md#multiple-workspaces)

---

## What's Next?

1. **Set up your project properly** — Use the [Playbook](https://github.com/GSA-TTS/agentic-coding-playbook)
2. **Share what you learn** — Contribute to the [Patterns repo](https://github.com/GSA-TTS/agentic-coding-patterns)
3. **Help improve these docs** — Found something unclear? Open an issue or submit a PR

Once in a while, refresh your setup to pick up updates (via your package manager,
or `git fetch && git pull` in a clone), and
[rotate your USAi key](docs/howto/acq.md#rotate-your-usai-key) when it expires
(every 7 days).

The playbook also provides reusable **agent skills** — step-by-step procedures
for common tasks, following the [agentskills.io](https://agentskills.io)
standard. When you launch a sandbox with `acq`, the `agentic-coding-playbook` kit
symlinks these into `~/.agents/skills` so your agent discovers them automatically
— no separate checkout needed.

| Source       | Skills                       | Examples                                                                            |
| ------------ | ---------------------------- | ----------------------------------------------------------------------------------- |
| **Playbook** | Federal compliance, security | `federal-security-controls-lookup`, `ato-package`, `code-review`, `cloudgov-deploy` |
| **Patterns** | Development workflows        | `accessibility-review`, `uswds-prototype`, `test-generation`, `secure-code-review`  |

---

## Getting Help

1. **Troubleshooting:** [docs/KNOWN_FAILURE_MODES.md](docs/KNOWN_FAILURE_MODES.md)
2. **Agent behavior:** [AGENTS.md](AGENTS.md)
3. **Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md)
4. **Questions:** Open a [GitHub issue](https://github.com/GSA-TTS/agentic-coding-quickstart/issues)
5. **Platform issues:** support@usai.gov

---

**Data Classification:** Internal/Non-sensitive — the Quickstart is a **local development environment** for building Low/Moderate-impact code and projects, not an authorized production/hosted environment (no PII, no CUI).
