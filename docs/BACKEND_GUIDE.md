---
title: "acq Backend Guide"
description: "Per-backend strengths, tradeoffs, and configuration for acq"
status: canonical
tier: 2
last_updated: "2026-08-04"
audience: "developers"
keywords: ["acq", "backend", "sbx", "msb", "microsandbox", "tradeoffs"]
related_files: ["docs/QUICKSTART.md", "docs/QUICKSTART_SBX.md", "docs/adr/0010-acq-pluggable-backends.md", "docs/adr/0011-msb-backend-and-neutral-kits.md", "docs/adr/0014-neutral-port-publish-and-background-vocab.md", "docs/adr/0015-msb-post-hoc-port-publish-via-ssh.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# acq Backend Guide

`acq` supports multiple isolation backends behind one command surface. As of
the **2.x** release line, two backends ship: **sbx** (Docker Sandboxes) and
**msb** (microsandbox). Kits are authored once in the neutral `hybrid/v1`
vocabulary and translated to each backend's native mechanism (see
[ADR-0011](adr/0011-msb-backend-and-neutral-kits.md)).

| Backend | Status | Description |
|---------|--------|-------------|
| **sbx** | Shipped | Docker-based sbx CLI from Docker Inc |
| **msb** | Shipped | microsandbox — lightweight microVM isolation (FOSS); **default backend** |
| **ppp** | Phase 3 / in development | Podman-Plus-Proxy backend ([GSA-TTS/ppp](https://github.com/GSA-TTS/ppp)) |

---

## sbx Backend

### Overview

The **sbx** backend wraps the [sbx CLI](https://docs.docker.com/ai/sandboxes/)
from Docker Inc. It provides:

- Container-based isolation
- Declarative kit composition (mixin kits applied at create time)
- Built-in secret proxy injection (secrets never enter the container)
- SSH key forwarding for git signing
- Persistent sandbox state across sessions

### Strengths

- **Production-ready**: Docker-backed, mature tooling
- **Secret proxy**: USAi key, GitHub token, and other secrets are injected by
  the proxy — the agent never sees them directly
- **Kit ecosystem**: Reuses all four community kits unchanged (`usai-provider`,
  `agentic-coding-playbook`, `zscaler-ca-certificate`, `git-ssh-sign`)
- **In-place healing**: Missing kits are added with `sbx kit add` on reconnect
  without losing sandbox state (requires sbx >= 0.35.0)
- **Port forwarding**: Supports `--publish` for exposing agent web UIs

### Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| `sbx` CLI | >= 0.35.0 | `sbx kit add` requires 0.35.0 for in-place healing |
| Docker account | any | Required for `sbx login` |
| Docker subscription seat | (org-dependent) | Some orgs require paid seats |
| Linux/ARM64 | 0.36.x+ | sbx 0.35.x has no Linux/ARM64 build; wait for 0.36.x |

### Installation

See [README.md](../README.md#step-2-install-sbx-cli) for step-by-step
install instructions for macOS, Windows, and Linux.

### Configuration

```bash
# Persist sbx as the backend
./acq backend set sbx

# Per-invocation override
./acq --backend sbx run opencode /proj

# Environment override
export ACQ_BACKEND=sbx
```

### Capability flags

| Flag | Value | Meaning |
|------|-------|---------|
| `ACQ_BACKEND_SUPPORTS_PORT_FORWARD` | 1 | `acq ports` is supported |
| `ACQ_BACKEND_SUPPORTS_SNAPSHOTS` | 0 | No snapshot support |
| `ACQ_BACKEND_CAN_RESUME` | 1 | Sandboxes persist between sessions |
| `ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE` | 1 | Secret proxy injection |

### Known limitations

- No Linux/ARM64 build for sbx 0.35.x; wait for sbx 0.36.x
- `sbx kit add` (healing) is experimental; see
  [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md)
- The sbx `docker sandbox` commands (deprecated by Docker) must not be used;
  use `sbx` CLI directly

---

## msb Backend (microsandbox, default)

The **msb** backend wraps [microsandbox](https://github.com/superradcompany/microsandbox),
an open-source (Apache-2.0) microVM runtime. It is a good fit when you want a
FOSS runtime with no Docker account/seat, snapshot/restore, or an SDK-first
automation story.

### Overview

- microVM isolation (libkrun) with per-sandbox network policy
- Runs standard OCI images (Docker Hub, GHCR, any registry)
- Native host-CA trust propagation (`--trust-host-cas`)
- Native TLS interception + host-env secret binding (`--secret ENV@HOST`) so
  credentials never enter the guest
- Snapshot/restore and detached long-running sandboxes

### Strengths

- **No Docker account required** — FOSS binary, `msb self update` to upgrade
- **Zscaler CA shortcut**: the `zscaler-ca-certificate` kit takes msb's native
  `--trust-host-cas` path instead of the file-drop + `update-ca-certificates`
  dance (behavioral parity — the guest trusts the Zscaler CA either way)
- **Secret injection**: the USAi key and a GitHub token are bound from host env
  vars at create time (`--secret USAI_API_KEY@api.gsa.usai.gov`,
  `--secret GITHUB_TOKEN@api.github.com`); the real values never enter the VM.
  **Any** custom-endpoint secret stored with `acq secret set SVC --host H --env E`
  is bound generically the same way — no fixed usai/github table
- **Snapshots**: microsandbox has a full `msb snapshot` CLI verb
  (create/list/inspect/verify/remove/save/load, `run --from-snapshot`), but
  `acq` does not surface it — wiring `acq snapshot` is beyond sbx parity, so
  `SUPPORTS_SNAPSHOTS=0` reflects what `acq` surfaces (not what msb can do); see
  Known limitations

### Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| `msb` CLI | >= 0.6.0 | `--net-rule`, `--trust-host-cas`, `--secret` used by acq |
| Host virtualization | — | Linux: KVM (`/dev/kvm`); macOS: HVF (Apple Silicon); Windows: WHP |

Run `msb doctor` to check host readiness (`msb doctor --fix` attempts setup).

### Installation

```bash
curl -fsSL https://install.microsandbox.dev | sh        # macOS / Linux
brew install superradcompany/tap/microsandbox           # Homebrew
```

### Configuration

```bash
# Persist msb as the default backend
./acq backend set msb

# Per-invocation override
./acq --backend msb run opencode /proj

# Environment override
export ACQ_BACKEND=msb
```

Tunables:

| Env var | Default | Meaning |
|---------|---------|---------|
| `ACQ_MSB_IMAGE` | `docker.io/docker/sandbox-templates:shell-docker` | Base OCI image (the sbx agent-template: ships the `agent` user + passwordless sudo, node/git/curl/ca-certificates, and an agent-writable npm global prefix). A custom override must be pullable and ship these prerequisites. |
| `ACQ_MSB_SKIP_PREREQ_CHECK` | (unset) | Skip the base-image prerequisite presence check |
| `ACQ_SKIP_MSB_DOCTOR` | (unset) | Skip the automatic host-readiness check (`msb doctor`, and the `msb doctor --fix` it runs when the host is not ready). Set when the check is unreliable in your environment or you prefer to run it yourself. |
| `ACQ_OPENCODE_POSTINSTALL_TIMEOUT` | `120` | Seconds to bound opencode's in-guest `postinstall.mjs` (which fetches a platform binary) so a wedged registry can't hang `acq run`; used only when the guest provides `timeout` |
| `ACQ_MSB_OPENCODE_PKG` | `opencode-ai` | npm package spec for the opencode install (pin e.g. `opencode-ai@1.2.3`) |
| `ACQ_MSB_NPM_HOSTS` | `registry.npmjs.org` | npm registry host(s) to allow-list for the agent install (space-separated; set for an internal mirror) |
| `ACQ_MSB_BALANCED_EGRESS` | `1` (on) | Apply the sbx-`balanced` egress baseline at create (`--net-default-egress deny` + an `allow@host:tcp:port` rule per vendored entry + gateway-DNS rules `allow@host:udp:53` + `allow@host:tcp:53`). The deny-default is **egress only** — ingress keeps msb's baseline `allow` so published ports stay reachable (ADR-0019). Set `0`/`false`/`no`/`off`/empty to disable and fall back to kit-only egress (no deny-default emitted). See ADR-0018. |
| `ACQ_MSB_BALANCED_HOSTS_FILE` | `<repo>/acq.backends/msb-balanced-hosts.txt` | Path to the vendored host list (a verbatim mirror of `sbx policy inspect local-policy`). Override for a site-specific egress set. |
| `ACQ_MSB_WORKSPACE` | (first workspace) | Agent's **starting directory** (`-w`) on attach. Does NOT change the mount, which is always host-path:host-path; overrides only where the agent starts. |
| `ACQ_MSB_MEMORY` | `4G` | Guest RAM at create (`-m`); `4G`/`4096`/`512M` (bare = MiB). Set empty to use msb's 512 MiB default |
| `ACQ_MSB_CPUS` | `2` | Guest vCPU count at create (`-c`); set empty to use msb's 1-vCPU default |
| `ACQ_MSB_DNS_NAMESERVER` | `1.1.1.1` | Guest DNS resolver (set empty to use msb's default) |
| `ACQ_MSB_KIT_CACHE` | `$XDG_CACHE_HOME/acq/kits` | where fetched neutral kits are materialized |
| `ACQ_MSB_EXEC_READY_TIMEOUT` | `60` | Seconds to wait for a freshly-created sandbox to accept `msb exec` (create starts asynchronously) |
| `ACQ_MSB_SSH_DIR` | `$XDG_STATE_HOME/acq/ssh` | Directory holding acq's managed SSH key for post-hoc port publishing (ADR-0015) |
| `ACQ_MSB_SSH_KEY` | `$ACQ_MSB_SSH_DIR/msb_id_ed25519` | Managed SSH private key used to open `ssh -L` port tunnels |
| `ACQ_MSB_SSH_KNOWN_HOSTS` | `$ACQ_MSB_SSH_DIR/known_hosts` | known_hosts file for the managed port-forward SSH |
| `ACQ_MSB_SSH_USER` | `root` | Guest user for the post-hoc port-forward SSH session |
| `ACQ_MSB_PORTS_DIR` | `$XDG_STATE_HOME/acq/ports` | Per-sandbox state for post-hoc published-port tunnels (serve + ssh PIDs) |

### DNS / name resolution

msb hands the guest the **host's** DNS resolvers, but a corporate/VPN resolver
(e.g. a `172.16.x` or Zscaler address) is typically **unreachable from the
microVM's network namespace** — so the guest can't resolve even the
allow-listed kit hosts (`api.gsa.usai.gov`, `github.com`) and every outbound
request fails with `Could not resolve host`. The msb backend therefore passes
`--dns-nameserver` (default `1.1.1.1`, a public resolver reachable from the
microVM) to `msb create`. Override `ACQ_MSB_DNS_NAMESERVER` if `1.1.1.1` is
blocked in your environment, or set it empty to fall back to msb's default (only
if your host resolver is reachable from the guest).

### Network egress (sbx-`balanced` parity)

sbx ships a **`balanced`** network policy (the recommended sbx default) that
allows a broad set of developer hosts — AI services, package registries,
code/container hosts, cloud infrastructure, OS package mirrors, and
certificate-validation endpoints — and blocks everything else. msb has no
equivalent default; its egress is deny-by-default with only the hosts the kits
declare (plus the npm registry when installing an agent).

To reach parity, the msb backend applies the **same host set as sbx `balanced`
by default**: at create it emits `--net-default-egress deny` plus one
`allow@<host>:tcp:<port>` rule per entry in the vendored list
`acq.backends/msb-balanced-hosts.txt` (a verbatim mirror of `sbx policy inspect
local-policy`), plus gateway-DNS rules (`allow@host:udp:53` +
`allow@host:tcp:53`) for name resolution. Egress is therefore
*restricted to* the balanced set (deny-by-default + allowlist), composed with the
kits' own `caps.network.allow` rules.

- **Egress only.** The deny-default is scoped to egress (`--net-default-egress`,
  not the symmetric `--net-default`). Ingress keeps msb's baseline `allow`, so
  create-time `-p HOST:GUEST` published ports stay reachable — a symmetric deny
  would RST inbound to them (see [ADR-0019](adr/0019-msb-balanced-egress-is-egress-only.md)).
- **Disable** with `ACQ_MSB_BALANCED_EGRESS=0` (falls back to kit-only egress; no
  deny-default is emitted, so `acq` does not restrict egress in that mode).
- **Customize** by pointing `ACQ_MSB_BALANCED_HOSTS_FILE` at your own list.
- **Wildcards / ports:** sbx `**.host` / `*.host` become msb domain-suffix
  `*.host`; the intra-label glob `crl*.digicert.com` is broadened to
  `*.digicert.com` (msb has no intra-label glob — this is logged and is the one
  spot the msb set is intentionally wider than sbx); a host on both `:80` and
  `:443` yields two rules.
- **Drift:** the vendored file is a point-in-time snapshot. Re-sync it from `sbx
  policy inspect local-policy` on the quarterly review cadence (see
  `docs/KNOWN_FAILURE_MODES.md`).

See [ADR-0018](adr/0018-msb-balanced-egress-baseline.md) for the full rationale,
and [ADR-0019](adr/0019-msb-balanced-egress-is-egress-only.md) for why the
deny-default is egress-only.

### Guest memory and vCPU

msb defaults a sandbox to **512 MiB of RAM and 1 vCPU**, and the microVM has
**no swap** — so a process that exceeds guest RAM is OOM-killed by the guest
kernel and simply prints `Killed`. A Node.js agent TUI like `opencode` blows past
512 MiB immediately, which looked like "opencode starts, then the terminal dies".
sbx sizes its agent templates generously; a plain msb
base does not, so the msb backend passes `--memory 4G --cpus 2` at create by
default. Tune with `ACQ_MSB_MEMORY` / `ACQ_MSB_CPUS` (set either empty to fall
back to msb's own default). Memory takes a single-char unit suffix — `G`/`g` =
GiB, `M`/`m` = MiB, bare number = MiB — so `4G`, `4096`, and `4g` are equivalent.

### Workspace mounting

msb does **not** create the host mount path, so each host workspace path must
already exist — `acq` errors clearly if one does not.

The msb backend mounts every workspace at the **same absolute path inside the
guest** (matching sbx's multi-workspace semantics — see
`docs/QUICKSTART_SBX.md`): `acq run opencode /my/repo` makes the repo appear at
`/my/repo` in the sandbox. Extra workspaces and a trailing `:ro` marker work the
same as sbx:

```bash
acq --backend msb run opencode ~/projects/app ~/projects/lib:ro
# mounts ~/projects/app (rw) and ~/projects/lib (ro), each at its host path
```

**Starting directory:** the agent starts in the **primary** (first) workspace,
matching sbx (`docs/QUICKSTART_SBX.md`: "Primary workspace — the first path;
agent starts here"). Override the start dir with `ACQ_MSB_WORKSPACE`.

**Symlinked host paths are canonicalized.** msb cannot mount a symlinked host
path — it fails to start with `mount ...: Not a directory (os error 20)`, even
when mapped to a shallow guest target (verified on msb 0.6.6). The most common
case is **macOS `$TMPDIR`**, a per-user `/var/folders/...` tree reached through
the `/var` → `/private/var` symlink: any workspace under `$TMPDIR` / `/tmp`
fails. `acq` therefore resolves each workspace to its real, symlink-free path
(e.g. `/private/var/...`) before mounting. A directory under `$HOME` mounts
fine; prefer one over a temp dir if you hit this.

> **Why not remap under `/home/agent`?** An earlier version mounted the
> workspace under the agent home (`/home/agent/workspace`). But `msb create`
> performs the mount *before* `acq` can create the `agent` user and its
> `/home/agent` directory (that happens post-create, once the guest is
> exec-ready), so on a plain base image the mount failed with
> `mount ...: Not a directory (os error 20)`. Mounting at the
> host's own (canonicalized) absolute path avoids that ordering problem entirely
> and matches what sbx does.

Note the async-boot caveat:

> **`msb create` starts asynchronously.** `msb create` returns success even if
> the sandbox later fails to *start* (e.g. a bad mount). `acq` therefore treats
> "sandbox not exec-ready within `ACQ_MSB_EXEC_READY_TIMEOUT`" as a **hard
> provision failure** and points you at `msb logs --source system <name>` —
> rather than proceeding against a sandbox that never came up.

### Base image and prerequisites

Unlike sbx (whose agent templates supply the image via a template mechanism),
the msb backend runs an OCI image directly and layers the kits on top. By
default it uses the **same** sbx agent-template image
(`docker/sandbox-templates:shell-docker`); a custom override may be any OCI
image. The four pinned kits need
`node` (usai merge), `git` (playbook clone + signing), `curl`, and
`ca-certificates`/`update-ca-certificates` (zscaler) **already present in the
base image**.

These are **not** installed at runtime: the kit network rules lock egress to the
kits' own hosts (`api.gsa.usai.gov`, `github.com`, `codeload.github.com`), so a
package mirror is unreachable during provision. The default
`docker/sandbox-templates:shell-docker` image (the sbx agent-template) already
ships all four tools and pulls from Docker Hub without auth. Before applying
kits, the adapter **verifies** the tools are present and warns if any are
missing (it does not try to install them). A custom override must ship them too.

**The agent binary.** sbx's agent templates bake the requested agent (e.g.
`opencode`) into the image; a plain msb base has no agent. So at provision the
msb adapter **installs the agent it was asked to run**. For `opencode` this is
`npm install -g opencode-ai` (node is a verified prerequisite), and the adapter
allow-lists the npm registry host (`registry.npmjs.org`) at create so the
default-deny guest egress permits the download. The install is idempotent: it is
skipped when the binary is already present (e.g. a pre-baked `ACQ_MSB_IMAGE`) and
marker-gated against re-apply. `shell` installs nothing; an agent with no known
recipe that is also absent from the base image produces a clear warning (bake it
into `ACQ_MSB_IMAGE`). Tunables: `ACQ_MSB_OPENCODE_PKG` (npm spec, e.g.
`opencode-ai@1.2.3`), `ACQ_MSB_NPM_HOSTS` (registry host(s) to allow-list, for an
internal mirror).

**The base-image contract (Docker `shell-docker`).** sbx's templates are built on
`docker/sandbox-templates:shell-docker` — which acq now also uses as the default
`ACQ_MSB_IMAGE`, so msb matches sbx by construction. The synthesis below exists
only for a plain-OCI **override**: on the default image it is a short-circuit.

#### Base image requirements

A base image for the msb backend (a custom `ACQ_MSB_IMAGE` override) must provide,
mirroring the sbx
[published base-image requirements](https://docs.docker.com/ai/sandboxes/customize/kit-reference/#base-image-requirements):

- A non-root **`agent` user with passwordless sudo**. (Unlike sbx, acq does **not**
  require this user to be UID 1000 — it is addressed by name, so it works even when
  1000 is already taken, e.g. by `node` on `node:22-bookworm`.)
- A **`/home/agent`** home directory owned by `agent`.
- **HTTP proxy env** (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) **preserved across sudo**.
- The **agent binary** (baked into the image, or installed via a kit's install
  command — for `opencode`, acq runs `npm install -g opencode-ai`).
- The four kit prerequisites present: `node`, `git`, `curl`,
  `update-ca-certificates`.

**Build on `docker/sandbox-templates:shell-docker` to get all of these for free**
— it is the default `ACQ_MSB_IMAGE`, so msb matches sbx out of the box.

For a plain-OCI override (e.g. `node:22-bookworm`, which has `node` at uid 1000 and
no `agent`, no sudoers rule) that meets none of the first three, the msb adapter
**idempotently synthesizes** them at provision: it creates the `agent` user with
`HOME=/home/agent` (offline via `useradd`/`adduser`), chowns the staged
`/home/agent` files to it, drops a passwordless-sudo rule in `/etc/sudoers.d`, and
adds a sudoers `env_keep` for the proxy variables. It addresses the user by name
(not the literal uid 1000), so it works even when 1000 is already taken.

**How attach launches the agent.** sbx's `sbx run --name` re-launches the
baked-in agent. On msb the adapter reproduces that with `msb exec -t` — the one
primitive that allocates a PTY (so a full-screen agent TUI renders), runs as the
unprivileged `agent` user (`-u agent`), starts in the workspace (`-w`), and gives
the session a sane `$SHELL`. It execs the agent recorded at provision, falling
back to an interactive `/bin/sh -l` as `agent` — never a root shell, never msb's
default interactive shell (the base image's Node REPL) — for a `shell` sandbox or
if the agent binary is somehow missing.

To use your own image, set `ACQ_MSB_IMAGE` to one that also provides node, git,
curl, and ca-certificates:

```bash
export ACQ_MSB_IMAGE=ghcr.io/your-org/agent-base:latest   # must have node/git/curl/ca-certificates
# ACQ_MSB_SKIP_PREREQ_CHECK=1   # optional: silence the presence check
```

If the image requires registry auth, log in with your container tooling (e.g.
`docker login ghcr.io`) before running `acq`.

### Secrets

Credentials are owned by **acq's backend-neutral secret store** (not sbx's).
Set a secret once with `acq secret set`; both backends read it from the same
store at provision:

```bash
./acq secret set -g usai            # prompts; stored under acq.usai
./acq secret set -g github          # prompts; stored under acq.github
./acq secret set my-sandbox usai    # sandbox-scoped; overrides the global key
```

The store lives in the host OS keychain when available (macOS `security`, Linux
`secret-tool`) with a `0600` file fallback under `$XDG_DATA_HOME/acq/secrets/`.
Entries are keyed `acq.<service>` (global) or `acq.<sandbox>.<service>`
(sandbox-scoped); a sandbox-scoped key takes precedence over the global one for
the same service (supporting USAi per-sandbox billing-code keys).

At `acq run`/`create`, the **msb** backend reads the value from the store,
exports it into a transient host env var, and binds it with
`msb --secret ENV@HOST`. msb puts a **placeholder** (`$MSB_<env>`) in the guest;
when the guest sends that placeholder to an allowed host over **intercepted TLS**
(`--tls-intercept`, which acq enables), msb swaps in the real value on the wire —
so the credential **never enters the guest** and **never appears in argv**.
`acq secret set` also re-feeds running sandboxes with `msb modify --secret` so a
rotated key takes effect without recreating the sandbox.

- **USAi** binds to `api.gsa.usai.gov`. The USAi provider sends the key as an
  `Authorization: Bearer` header, which msb substitutes correctly.
- **GitHub** binds to `api.github.com` **only** (the REST host). msb substitutes
  the token on the `Authorization: Bearer` header path there, so kits fetch
  private GitHub content via the REST API. A `git clone` over HTTPS to
  `github.com`/`codeload.github.com` is **not** substituted — see the known
  limitation below.
- **Any other custom endpoint**: a
  service stored with `acq secret set SVC --host H --env E` records a **non-secret
  endpoint sidecar** (host + env only) in the acq store; the msb backend then binds
  it generically at provision via `--secret ENV@HOST` — no fixed usai/github table.
  `HOST` may be a comma-separated multi-host list. Absent a sidecar, a service with
  no compiled-in mapping is stored but not bound (acq tells you to supply
  `--host`/`--env`).

Feeding the **sbx** proxy depends on the sbx secret type (per the sbx CLI):

- **Built-in services** (`github`, `anthropic`, …): the value is piped to
  `sbx secret set <service>` on **stdin** (never argv). If the secret already
  exists, `acq` stops and prints the exact `sbx secret rm …` command rather than
  answering sbx's overwrite prompt.
- **Custom endpoints** (`usai` and any `--host/--env` service): `sbx secret
  set-custom` has **no stdin input** — the value would have to go on argv via
  `--value` (visible in shell history), which violates the no-argv rule. So
  `acq` stores the value in the acq store and then, from a **terminal**, runs
  `sbx secret set-custom` interactively so you enter it once at sbx's own
  prompt. When piped non-interactively (or on the msb backend), `acq` stores the
  value and prints the exact `sbx secret set-custom …` command for you to run.
  (On msb no sbx step is needed — msb reads the acq store directly.)

This is the bash subset of the design's §7.5 unified secret model; the full
Go/keychain MITM component (age fallback, `CredentialRewriteRule`,
swap-on-access placeholders) remains a larger future effort tracked separately.

> **Migration:** if you previously stored the USAi key with `sbx secret …`, run
> `acq secret set -g usai` once to move it into the acq store (the value is
> re-prompted). To pull tokens straight from your shell environment instead, run
> `acq secret import` — it scans for known service vars (`USAI_API_KEY`,
> `GITHUB_TOKEN`/`GH_TOKEN`, `GITLAB_TOKEN`) and stores each in the acq store
> (global by default; pass a SANDBOX to scope — a second bare token after a
> SERVICE is the SANDBOX, not a second service). It prompts before each import
> and before overwriting; `--all` imports non-interactively (skipping existing),
> `--force` (or `-f`) overwrites, and `--dry-run` previews without writing. A
> value containing a newline or tab is refused (the single-line store cannot hold
> it intact).
>
> **Overwriting:** `acq secret set` is non-destructive toward sbx — if sbx
> already holds the secret it stops with an `sbx secret rm …` hint rather than
> silently replacing it. The acq store copy is always updated.

### Known limitations (msb)

- **Private GitHub repos: use the REST API, not `git clone`.** msb substitutes
  an injected credential for the `Authorization: Bearer` header on the
  **REST API** (`api.github.com`) — verified on msb 0.6.7 (an authenticated
  request returns full rate-limit headers; a private-repo source-tarball fetch
  succeeds). It does **not** substitute git's smart-HTTP transport to
  `github.com` / `codeload.github.com`, so a `git clone` (or `gh repo clone`,
  which shells out to git) of a private repo fails auth/TLS there. This was the
  origin of the private-repo `git clone` limitation.

  **Resolution:** kits that need private GitHub content fetch it via the REST
  API instead of git. The `agentic-coding-playbook` kit now fetches the repo
  **source tarball** from `api.github.com/repos/<repo>/tarball/<ref>` (verifying
  the extracted `AGENTS.md` against a pinned sha256), so it works on **both**
  backends. acq binds `GITHUB_TOKEN@api.github.com` on msb (single host — a
  multi-host binding trips a known microsandbox bug). Store a
  token with `acq secret set -g github` (or `gh auth token | acq secret set -g
  github`); absent a token the kit degrades gracefully (warns, no rules/skills).
  Upstream git-transport substitution remains unfixed in microsandbox, but kits no
  longer depend on it.

### Capability flags

| Flag | Value | Meaning |
|------|-------|---------|
| `ACQ_BACKEND_SUPPORTS_PORT_FORWARD` | 1 | Post-hoc `acq ports <sandbox> --publish HOST:GUEST` is **implemented**: `acq_backend_ports` opens `msb ssh serve` on an ephemeral loopback port against a running sandbox and tunnels the guest port to the host with OpenSSH `-L` (no re-create), using an acq-managed ed25519 key and tearing the serve/ssh pair down on `acq stop`/`rm` ([ADR-0015](adr/0015-msb-post-hoc-port-publish-via-ssh.md)). Create/run publish via neutral `publishedPorts` → `-p HOST:GUEST` also ships. **Live-verified** on a KVM-capable host via `scripts/verify-ports-live` (happy-path publish + host-reaches-guest, LIST, fail-closed on a busy host port, teardown) |
| `ACQ_BACKEND_SUPPORTS_SNAPSHOTS` | 0 | msb has a full `msb snapshot` CLI verb, but `acq` exposes **no `snapshot` verb** to invoke it. Wiring one is beyond sbx parity (sbx has none), so the flag reflects what `acq` surfaces (`0`), not what msb can do |
| `ACQ_BACKEND_CAN_RESUME` | 1 | `msb stop` / `msb start` preserve state |
| `ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE` | 1 | `--secret ENV@HOST` + `--tls-intercept` (header substitution on REST/API hosts; git smart-HTTP transport not substituted — use the REST API) |

### Differences from sbx

| Feature | sbx | msb |
|---------|-----|-----|
| Isolation | Container (microVM) | microVM (libkrun) |
| Kit format | Neutral `hybrid/v1` → sbx-v2 (synthesized) | Neutral `hybrid/v1` → `msb` operations |
| Zscaler CA | file-drop + `update-ca-certificates` | native `--trust-host-cas` shortcut |
| Secret model | proxy `secret set-custom` | host-env `--secret ENV@HOST` |
| Secret binding breadth | 7 built-in services + any custom `--host/--env` endpoint | usai + github + **any** custom `--host/--env` endpoint bound generically via `--secret ENV@HOST` (shipped) |
| Snapshots | not supported (`SUPPORTS_SNAPSHOTS=0`) | `msb snapshot` verb exists but **not surfaced by `acq`** (beyond-parity; `SUPPORTS_SNAPSHOTS=0`) |
| Port forwarding | `acq ports` (post-hoc) | create/run (`-p`) via neutral `publishedPorts` now (shipped); **plus** post-hoc `acq ports --publish` via `msb ssh serve` + `ssh -L` now implemented (ADR-0015) — live end-to-end verification pending a KVM host |
| Agent binary | supplied by the sbx agent template | installed at provision on a plain base (`npm install -g opencode-ai`), then launched on attach |
| OpenCode web UI | `openchamber` acq kit (publishes port 4096) | same kit once it declares `backends: [sbx, msb]` against the released patterns schema (neutral port/background vocab consumed by both backends; the patterns repo's openchamber kit) |
| In-place kit heal | `sbx kit add` (state-preserving, 0.35.0+) | re-apply kits idempotently (no state-preserving add) |

### Known limitations

- **Ports: create/run publish shipped; post-hoc implemented (live e2e pending).**
  Kits declare ports in the **neutral top-level `publishedPorts`** vocabulary
  (`{guest, host?, protocol?, name?}`), which both backends now consume — on msb
  each entry maps to a create/run-time `-p HOST:GUEST`
  ([ADR-0014](adr/0014-neutral-port-publish-and-background-vocab.md), shipped
  on `feat/msb-parity`). The legacy sbx-only `backend_extras.sbx.publishedPorts`
  block still works for one release with a deprecation warning. The neutral
  fields are read *defensively* (absence is a silent no-op); with the released
  patterns schema + openchamber kit (both merged) they now light up
  end-to-end — the openchamber kit declares
  `publishedPorts`/`background` neutrally and both backends consume it.
  A **post-hoc** path is now **implemented**:
  `acq --backend msb ports <sandbox> --publish HOST:GUEST` runs `msb ssh serve`
  on an ephemeral loopback port against a running sandbox and tunnels the guest
  port to the host over OpenSSH `-L` with no re-create, using an acq-managed
  ed25519 key (never the user's `~/.ssh`) and tearing the serve/ssh pair down on
  `acq stop`/`rm`
  ([ADR-0015](adr/0015-msb-post-hoc-port-publish-via-ssh.md)); this
  is what flips `SUPPORTS_PORT_FORWARD=1`. **Live end-to-end verification is
  still pending** — the real forward needs a KVM-capable host, so run
  `scripts/verify-backends` on such a host per the ADR-0011 periodic-validation
  cadence (see the live end-to-end note below) before treating it as verified
  working. (`msb -p` also accepts `BIND_ADDR:HOST:GUEST` and `/udp`, but acq
  stays TCP + loopback for sbx parity.)
- **No state-preserving in-place kit add.** `acq_backend_ensure_kits_applied`
  re-applies kits idempotently; for a clean rebuild use `acq rm && acq run`.
- **Snapshots not surfaced.** `msb snapshot` is a full CLI verb, but `acq`
  exposes no `snapshot` verb, so `SUPPORTS_SNAPSHOTS=0`. Wiring it is beyond sbx
  parity (sbx has no snapshots), so the flag reflects what `acq` surfaces rather
  than the verb being built.
- **Browser-based OpenCode is via the `openchamber` kit.** The former
  `opencode-web.sh` helper has been removed; use the `openchamber` acq kit, which
  publishes the OpenCode server port (4096) plus the OpenChamber UI (3000) with a
  supervised lifecycle. The neutral port/background vocabulary is consumed by
  both backends (ADR-0014), and the openchamber kit has been republished against
  the released patterns schema to declare `backends: [sbx, msb]` (merged);
  the browser-OpenCode path is now covered on msb, not just sbx.

> **Live end-to-end note (msb verification cadence).** The full
> `acq run … --backend msb` loop and the `scripts/verify-backends` msb row
> cannot run inside an sbx/msb sandbox (no nested sandboxes) and require host
> virtualization (`/dev/kvm` on Linux), so they do **not** run in CI. Run
> `scripts/verify-backends` **on a KVM-capable host after each release and after
> ≥3 behavior-affecting fixes** (per the AGENTS.md §8.3 periodic-validation
> cadence) and capture the transcript. The msb CLI command/flag surface used by
> the adapter was confirmed against a live `msb --tree` on **msb 0.6.7**
> (released 2026-07-27). See
> [ADR-0011](adr/0011-msb-backend-and-neutral-kits.md).

---

## ppp Backend (Phase 3, in development)

The Podman-Plus-Proxy (ppp) backend is being developed in
[GSA-TTS/ppp](https://github.com/GSA-TTS/ppp) and is targeted for Phase 3 — it
is not part of this release. When it lands, it will implement the same adapter
contract ([ADR-0010](adr/0010-acq-pluggable-backends.md)) and consume the same
neutral `hybrid/v1` kits via `kit-translate.sh`, so adding it is additive (a new
`acq.backends/ppp.sh` + a detection branch), with no change to the sbx or msb
paths. See `docs/explorations/acq-design.md` §"ppp" for the intended mapping.

---

## Backend resolution order

`acq` resolves the backend in this priority order (highest wins):

1. `--backend <name>` flag (per-invocation override)
2. `ACQ_BACKEND` environment variable
3. `backend:` key in `~/.config/acq/config.yaml`
4. Auto-detect: first installed backend (`msb` preferred, then `sbx`)

If multiple backends are installed and none is explicitly selected, `acq`
auto-detects in the order above (msb wins when both are present). Use
`--backend`, `ACQ_BACKEND`, or `acq backend set` to pick sbx explicitly.

---

## Troubleshooting

Set `ACQ_DEBUG=1` to trace backend CLI invocations and kit fetch/translate
steps to stderr (no secret values are printed):

```bash
ACQ_DEBUG=1 ./acq --backend msb create shell /path/to/project
```

`scripts/verify-backends` supports `-v`/`--verbose` (stream every acq command
and its output live) and `-k`/`--keep` (leave a failing sandbox up for manual
inspection):

```bash
./scripts/verify-backends -v
```

A `WARN` line marks a known, tracked limitation — it is surfaced every run but
does **not** count as a failure, so a clean run still exits 0. (The former msb
private-repo playbook `WARN` is gone: the playbook kit now fetches via the REST
API and is a hard-required `pass` on both backends, given a stored github token.)

---

## Adding a new backend (implementer notes)

1. Create `acq.backends/<name>.sh` implementing the contract in
   [ADR-0010 §"Adapter contract"](adr/0010-acq-pluggable-backends.md).
2. Set the capability flags at the top of the file.
3. Implement all required `acq_backend_*` functions. Consume the neutral
   `hybrid/v1` kits via `acq.backends/kit-translate.sh` (parse the spec, honor
   `backend_shortcuts.<name>`, then emit your backend's native operations).
4. Add auto-detect to `_auto_detect_backend` in `acq.backends/common.sh`.
5. Add the backend to `acq backend list` and `acq_print_doctor`.
6. Write tests in `scripts/test-acq` (stub the CLI) and a row in
   `scripts/verify-backends`.
7. Document it here.

---

## Kits: the neutral hybrid/v1 vocabulary

Kits are authored once in the neutral `hybrid/v1` spec (in the patterns repo
under `integrations/isolation/acq-kits/`) and translated per backend by
`acq.backends/kit-translate.sh`:

- **sbx** — the neutral spec is synthesized into an sbx-v2 kit directory
  (`spec.yaml` + `files/`), then applied via `sbx --kit` / `sbx kit add`. The
  observable result is identical to the pre-1.2 sbx kits.
- **msb** — the neutral spec is fetched and driven directly: network allows
  become `--net-rule` flags, files are `msb copy`'d in, and `commands` run via
  `msb exec`. A `backend_shortcuts.msb` (e.g. zscaler `trust_host_cas`) uses the
  native primitive instead.

The neutral vocabulary is: `caps.network.allow`, `files[]`, `commands[]`,
`environment`, `agentContext`, `backend_shortcuts`, and `backend_extras`.

**`environment` (guest env vars).** A flat map of `NAME → value` for
**non-secret** guest environment variables (e.g. `OPENCODE_CONFIG`,
`OPENCODE_TUI_CONFIG`, `GITLAB_HOST`). Names must be POSIX identifiers
(`^[A-Za-z_][A-Za-z0-9_]*$`; an invalid name is dropped with a warning and
reported by `acq kit validate`); values are plain strings. It maps to sbx-v2
`environment.variables` (synthesized) and to `msb exec -e NAME=value` (per-exec).
**Secrets do NOT go here** — use the credential/secret path (`acq secret …`);
the kit spec never carries a secret value.

> **Note (cross-repo, satisfied):** the authoritative `environment` schema
> property and its field-level validator live in the patterns repo
> (`schemas/kit-hybrid-v1.schema.json`, `validate-kits.py`), shipped in patterns
> **v1.7.0**. `PATTERNS_KIT_REF` is pinned to the patterns **v1.8.0**
> release commit (`f5fb887`); the pin is only advanced to a tagged release,
> per the fail-closed cross-repo gating.

Manage kits with `acq kit list | validate PATH | apply NAME KITREF`.

### Kit-bundle provenance and stale-sandbox refresh

`acq` records, host-side, which built-in bundle ref each sandbox was built from
(under `${XDG_STATE_HOME:-$HOME/.local/state}/acq/provenance/<backend>/<name>.env`;
override with `ACQ_PROVENANCE_DIR`). It compares that against the **local**
`PATTERNS_KIT_REF` to detect drift:

- `acq kit check SANDBOX` — report `current` / `stale` / `unknown` (read-only).
- `acq kit update SANDBOX [--yes]` — reapply the bundle in place to the pinned
  ref, preserving sandbox state. `--yes` is honored **only** on this explicit
  command.
- `acq run` on an existing sandbox that is behind the pin **offers** a refresh:
  interactive, default No, EOF declines, and it **never blocks** a launch. A
  non-interactive run prints one advisory and continues.
- Opt out with `ACQ_UPDATE_CHECK=0` or `acq run --no-update-check`.

Backend behavior: **sbx** injects any absent built-in kits during the heal pass;
**msb** re-applies all built-in kits idempotently. Both rewrite provenance only
after a successful apply. Staleness is an exact-ref mismatch against the local
pin (no git ancestry, no network) — the local checkout is the source of truth.
See [ADR-0016](adr/0016-kit-bundle-provenance-and-stale-refresh.md).

---

## Shipped

- `acq kit apply|list|validate` — kit management subcommands
- Neutral `hybrid/v1` kit spec + `kit-translate.sh` (multi-backend kits)
- `msb` (microsandbox) backend, with agent install/launch on a plain base image
- Backend-neutral USAi key rotation ([ADR-0012](adr/0012-backend-neutral-key-rotation.md))
- Per-sandbox GitHub token downscoping ([ADR-0013](adr/0013-per-sandbox-github-token-downscoping.md))
- sbx port-publish carry + `--kit <ref>` interception
- Neutral top-level `publishedPorts` + `background` vocab consumed by **both**
  backends (msb maps to create/run `-p HOST:GUEST`; background startup commands
  run detached), with a deprecated `backend_extras.sbx.publishedPorts` fallback
  ([ADR-0014](adr/0014-neutral-port-publish-and-background-vocab.md)) — the
  neutral fields light up end-to-end with the released patterns schema +
  openchamber kit (merged)
- msb `SUPPORTS_SNAPSHOTS=0` — `acq` surfaces no snapshot verb (msb's own verb
  exists; wiring is beyond parity)
- Generic custom-endpoint secret binding on msb — usai + github + **any** custom
  `--host/--env` endpoint bound via `--secret ENV@HOST` from a non-secret endpoint
  sidecar
- Post-hoc port publish on msb — `acq ports <sandbox> --publish HOST:GUEST`
  via `msb ssh serve` + OpenSSH `-L` against a running sandbox (acq-managed ed25519
  key, serve/ssh teardown on `acq stop`/`rm`); flips `SUPPORTS_PORT_FORWARD=1`
  ([ADR-0015](adr/0015-msb-post-hoc-port-publish-via-ssh.md)). **Implemented,
  not yet live-verified** — live end-to-end run needs a KVM host per the ADR-0011
  `scripts/verify-backends` cadence

## Shipped later

- `acq kit check|update` + host-side kit-bundle provenance and stale-sandbox
  refresh (see ADR-0016)
- Removal of the deprecated `qsbx` wrapper (3.0.0)

## Still deferred

- Live end-to-end verification of msb **post-hoc port publish**
  (`acq ports --publish` via `msb ssh serve` + `ssh -L`) on a KVM-capable host —
  code is implemented and the review's liveness fix landed, but the real
  forward has not yet been exercised end-to-end (`scripts/verify-backends` covers
  the kit/agent/USAi rows, not `--publish`), so run it per the
  [ADR-0011](adr/0011-msb-backend-and-neutral-kits.md) periodic-validation
  cadence before treating the tunnel as verified working
- `acq snapshot` verb (beyond sbx parity; msb's own `msb snapshot` verb is not
  surfaced)
- Full Go/keychain swap-on-access secret component of design §7.5 (age fallback,
  `CredentialRewriteRule`); acq ships the bash keychain subset (see Secrets)
- `acq policy …` — network policy subcommands
- `ppp` (Podman-Plus-Proxy) backend — Phase 3, in development at
  [GSA-TTS/ppp](https://github.com/GSA-TTS/ppp)
- Advisory "your Quickstart checkout is behind origin" check
