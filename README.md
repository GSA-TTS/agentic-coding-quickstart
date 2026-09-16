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
You do **not** need to be a developer. Windows support is currently a preview
path for Windows 11 machines with virtualization enabled (see Step 1).

### Step 1: Open a terminal

Open a terminal — **Terminal** (macOS) or **PowerShell** (Windows). You'll type
(or paste) the commands below into this window.

> **Before you start:** the sandbox runs on your machine's hardware
> virtualization. Apple Silicon Macs are ready to go. Windows 11 needs the
> **Windows Hypervisor Platform** enabled — see the box below. Linux needs KVM
> (`/dev/kvm`). For the full platform requirements, see
> [supported hosts](docs/howto/acq.md#msb-host-setup).

<details>
<summary><strong>Windows: enable virtualization</strong> (click to expand)</summary>

The sandbox runs a lightweight microVM using the **Windows Hypervisor Platform**
(WHP). Your Windows 11 machine needs it enabled. Open an **elevated** PowerShell
window — in the Start menu, right-click **PowerShell** and choose **Run as
administrator** — then run:

```powershell
# Enable WHP, then restart your computer.
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
```

Restart when it finishes. After that, the installer (or `msb doctor`) will confirm
the host is ready. On a work or managed device you may not be able to enable it
yourself — ask your IT administrator to turn on "Windows Hypervisor Platform."
If it can't be enabled, the installer stops with a clear message telling you so.

</details>

### Step 2: Install acq

Run the one-line installer for your shell.

**Terminal (macOS/Linux):**

<!-- x-release-please-start-version -->

```bash
curl -fsSL https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v3.1.0/install.sh | sh
```

<!-- x-release-please-end -->

**PowerShell (Windows):**

<!-- x-release-please-start-version -->

```powershell
irm https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v3.1.0/install.ps1 | iex
```

<!-- x-release-please-end -->

That's it — you don't have to choose *how* to install. The installer:

- **picks the best method already on your computer** — Homebrew or npm on
  macOS/Linux, or the GitHub release zip on Windows — so you get automatic
  upgrades/uninstall if you already use a package manager, and a working setup
  either way,
- puts the `acq` command on your computer so you can run it from **any folder**,
- installs anything `acq` needs to run — the sandbox runtime, and on Windows a
  small Linux-style shell — **asking before each change**, and never needing
  administrator rights.

**Answer "yes" to each prompt** — it may take a few minutes. When it finishes,
**close and reopen your terminal** so the new `acq` command is available, then
continue to Step 3. (On Windows, the installer stops with clear guidance if
virtualization isn't enabled — see the box in Step 1.)

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

You never have to pipe a script straight into your shell. If you have the GitHub
CLI (`gh`), you can also verify the release asset attestations before running
anything:

```bash
ACQ_VERSION=3.1.0 # x-release-please-version
curl -fsSLO "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v${ACQ_VERSION}/install.sh"
curl -fsSLO "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v${ACQ_VERSION}/SHA256SUMS"
gh attestation verify install.sh --repo GSA-TTS/agentic-coding-quickstart
gh attestation verify SHA256SUMS --repo GSA-TTS/agentic-coding-quickstart
shasum -a 256 -c --ignore-missing SHA256SUMS
less install.sh              # read it
sh install.sh --dry-run      # show what it WOULD do, changing nothing
sh install.sh                # actually install
```

By default, the macOS/Linux installer uses the best package manager already
available on your host: Homebrew, then npm, then a managed git clone. Homebrew
and npm rely on the published package/formula release path. The release asset's
baked commit SHA is used only by the clone fallback (or `--method clone`) to
verify that the clone landed on the release commit embedded in the installer. To
pin to an independent, explicit commit, use `--method clone --sha <40-char-commit>`.

For Windows preview installs, download and inspect the PowerShell installer
instead:

```powershell
$AcqVersion = "3.1.0" # x-release-please-version
$BaseUrl = "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v$AcqVersion"
Invoke-WebRequest "$BaseUrl/install.ps1" -OutFile install.ps1
Get-Content .\install.ps1
.\install.ps1 -DryRun
.\install.ps1
```

`SHA256SUMS` also lists `install.ps1` and the Windows zip, so the macOS/Linux
check above uses `--ignore-missing` to skip entries you didn't download.

Running `.\install.ps1` (and the installed `acq` command, via `acq.cmd`) needs a
PowerShell execution policy that permits local scripts; on a default Windows 11
client that is `Restricted`, and the commands fail with `PSSecurityException`
until you allow scripts — see the execution-policy note in
[First-Run Snags](#first-run-snags). The `irm ... | iex` one-liner is unaffected
(piped text is not a script file).

</details>

> **Already use Homebrew or Node, or prefer to run from a clone?** The one-line
> installer detects and uses whichever package manager you have. For the direct
> commands, a manual clone install, or testing a tagged release, see
> [Installing acq](docs/howto/acq.md#installing-acq).

### Step 3: Run it

Point `acq` at the folder you want the agent to work in. The easiest is the
folder you're already in:

```bash
acq run opencode .
```

To use a new folder, create it with `mkdir my-project`, move into it with
`cd my-project`, then run `acq run opencode .` there. (These commands work in
both PowerShell and the macOS/Linux terminal.)

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

The things a first-timer most often hits are below. For everything else
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

<details>
<summary><strong>"acq is not recognized as the name of a cmdlet"</strong> (Windows)</summary>

This means the new `acq` command isn't on your PATH in this window. **Close and
reopen PowerShell**, then try again. If it still isn't found, re-run the Step 2
installer and answer **yes** when it asks to add `acq` to your PATH.

</details>

<details>
<summary><strong>"...cannot be loaded because running scripts is disabled on this system"</strong> (Windows)</summary>

This is PowerShell's **execution policy** blocking a `.ps1` file. Windows 11
client defaults to `Restricted`, which refuses to run script files — so the
inspect-first steps (`.\install.ps1 -DryRun`, `.\install.ps1`) and the installed
`acq` command (which runs through `acq.cmd`) all fail with `PSSecurityException`.
The `irm ... | iex` one-liner still works, because piped text is not a script
file.

To allow local scripts for **your user only**, then re-run the command:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

`RemoteSigned` runs local scripts but still requires a signature on scripts
downloaded from the internet. On a **managed device** the policy may be set by
Group Policy — ask your IT administrator rather than changing it yourself.

</details>

<details>
<summary><strong>"Windows Hypervisor Platform is not enabled"</strong> (Windows)</summary>

The sandbox can't start without virtualization. Enable it from an **elevated**
PowerShell (`Enable-WindowsOptionalFeature -Online -FeatureName
HypervisorPlatform -All`), restart your computer, and try again — see the box in
Step 1. On a managed device, ask your IT administrator to enable it.

</details>

---

## Learn More

- **How it works, customizing, extra kits, optional integrations (web UI, editors):**
  [docs/CONCEPTS.md](docs/CONCEPTS.md)
- **Deeper `acq` how-to, backend selection, manual install, Windows preview validation:**
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
