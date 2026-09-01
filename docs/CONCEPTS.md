---
title: "acq Concepts"
description: "Backend-neutral concepts for working with acq sandboxes (workspaces, mounts)"
status: canonical
tier: 2
last_updated: "2026-08-21"
audience: "developers"
keywords: ["acq", "concepts", "workspace", "mount", "backend-neutral", "sbx", "msb"]
related_files: ["docs/howto/acq.md", "docs/BACKEND_GUIDE.md", "docs/adr/0010-acq-pluggable-backends.md", "docs/adr/0011-msb-backend-and-neutral-kits.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq Concepts

Cross-cutting concepts for working with `acq` sandboxes. These apply to **both**
backends (sbx and msb) because `acq` presents one neutral interface over both.
For per-backend strengths, tradeoffs, and caveats, see the
[Backend Guide](BACKEND_GUIDE.md).

---

## Multiple Workspaces

You can mount additional directories alongside the primary workspace when
creating a sandbox. This is useful when you need to reference multiple repos or
folders from one sandbox session — for example, editing an app while reading a
reference library or the playbook.

`acq` supports the multi-workspace positional list on **both** backends with
identical syntax, so this is the canonical, backend-neutral way to mount extra
directories.

### Syntax

```bash
acq run <agent> <primary-workspace> [extra-workspace][:ro] ...
# e.g.
acq run opencode ~/projects/app ~/projects/lib:ro
```

- **Primary workspace** — the first path. The agent starts here, and it is
  mounted read/write.
- **Extra workspaces** — additional paths the agent can access. Each mounts at
  its **absolute host path** inside the sandbox (e.g. `~/projects/lib` appears at
  `/Users/you/projects/lib`), matching across backends.
- **`:ro` suffix** — mounts that extra workspace read-only. Recommended for
  reference repos so the agent cannot modify them.
- **Mounts are fixed at creation** — you cannot add or remove workspaces from an
  existing sandbox. To change mounts, remove the sandbox (`acq rm <name>`) and
  recreate it with the new paths.

The same positional list works with `acq create` when you want to name a sandbox
without attaching immediately:

```bash
acq create <agent> <primary-workspace> [extra-workspace][:ro] ...
```

### Example: app repo + read-only reference

```bash
# Primary: your app (read/write)
# Secondary: the playbook, read-only reference
acq run opencode ~/projects/my-app ~/projects/agentic-coding-playbook:ro
```

The agent can edit `~/projects/my-app` and read from
`~/projects/agentic-coding-playbook` without risk of modifying the reference
content.

### Disposable primary: `--clone`

By default the primary workspace is the **real host checkout**, mounted
read/write. Pass `--clone` (or set `ACQ_CLONE=1`) at create to run the agent on
a **disposable clone** of the primary instead: the agent branches, commits, and
experiments without touching your checkout, and you pull finished work back
explicitly on the host:

```bash
acq run opencode --clone ~/projects/my-app
# ... agent works on a private clone ...
git fetch sandbox-<name>     # run in ~/projects/my-app: pulls agent branches
```

The primary must be the **root of a git repository**. Secondary workspaces are
unaffected. Like the mounts themselves, `--clone` applies **at creation only**.
A clone carries **committed state only** — no gitignored/untracked files and no
uncommitted edits; commit first, or copy specific files in with `acq cp` (e.g.
a needed `.env`). Removing the sandbox (`acq rm`) discards the clone, with a
warning if it still holds commits you have not fetched. See
[ADR-0027](adr/0027-neutral-clone-option.md) for the design and the per-backend
mechanics.

### Security recommendation

Prefer read-only (`:ro`) mounts for secondary workspaces unless the agent
genuinely needs write access. This limits accidental modification and reduces
the blast radius of agent errors.

> [!WARNING]
> Mounted directories expose **all content** to the agent, including `.env`
> files, `.git/config` (which may contain tokens), and any secrets in the
> mounted path. Mount only what the agent needs. Prefer selective, targeted
> mounts over mounting parent or home directories.

### Backend caveats

The syntax and semantics above are identical across backends, but each backend
has a few mechanics worth knowing. Rather than duplicate them here, see the
[Backend Guide](BACKEND_GUIDE.md) for:

- **msb** — each host workspace path must already exist (msb does not create the
  host mount path), and symlinked host paths (notably macOS `$TMPDIR`) are
  canonicalized to their real path before mounting.
- **sbx** — `--clone` uses the backend's native in-container clone, whose
  lifecycle interacts with multi-workspace mounts; see the
  [sbx how-to guide](howto/sbx.md) for the sbx-specific clone story.
- **msb** — `--clone` is emulated with a managed host-side scratch clone
  mounted in place of the primary; see the
  [Backend Guide](BACKEND_GUIDE.md#disposable-primary-clone) for mechanics and
  the divergences from sbx (a git clone carries committed state only).

---

## How It Works

This explains the mechanics behind the [README](../README.md) quickstart — read
it when you want to customize or troubleshoot.

### What happened when you ran the `acq` command?

`acq run` created the sandbox for that path (if it didn't exist yet) and mounted
your project into it. Then it configured the coding agent (`opencode`) to pick up
configuration for using the USAi provider and made sure the agent was provisioned
with custom guidance and relevant skills for working in the federal context — all
delivered by kits fetched from the pinned patterns release, not from the
quickstart clone.

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
  [Commits show "Unverified" on GitHub](KNOWN_FAILURE_MODES.md#22-signed-commits-show-unverified-on-github).

### How the USAi key is injected

`acq` stores the USAi API key in its own secret store
(`./acq secret set -g usai`) with an explicit associated endpoint
(`api.gsa.usai.gov`) and injects it into requests at runtime — the real value
stays out of the guest.

### Key pre-validation

Before attaching, `acq` checks that the sandbox's USAi key works. If none is set
yet, or it has expired, `acq` prompts you to paste a key (or rotate it — see
[Rotate your USAi key](howto/acq.md#rotate-your-usai-key)) and re-validates
before launching the agent.

### How default USAi models are chosen

The `usai-provider` kit ships an `opencode.jsonc` with a generated USAi model
catalog, kept in sync with the USAi `/models` API so new projects start from a
current baseline. See the kit definition in the agentic-coding-patterns
repository for details.

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
- **Adopt newer kit versions:** bump `PATTERNS_KIT_REF` near the top of
  `acq.backends/common.sh`.

### Advanced: extra kits

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

- **Web UI** — The OpenCode text UI is functional but constraining. By running
  the Paseo kit, you can interact with sandboxed agents via a feature-rich web UI
  that includes clipboard support and richer markdown rendering. Use the
  [`paseo` acq kit](https://github.com/GSA-TTS/agentic-coding-patterns/tree/main/integrations/isolation/acq-kits/paseo),
  then open <http://localhost:6767> in your browser.
- **Editor integrations** — Editor task configs and setup guides live in the
  community [agentic-coding-patterns](https://github.com/GSA-TTS/agentic-coding-patterns/tree/main/integrations)
  repo under `integrations/`. (For example, the Zed editor integration is at
  `integrations/editors/zed/`.)
