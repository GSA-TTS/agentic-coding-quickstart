# agentic-coding-quickstart v2 — Design Summary

A pluggable isolation layer for the GSA agentic-coding-quickstart ecosystem. One `acq` command, three isolation backends, one consistent developer experience.

---

## 1. Context

**Today (v1):** `qsbx` is a ~700-line bash wrapper around Docker `sbx` CLI. It applies four pinned sbx mixin kits (from `agentic-coding-patterns/integrations/isolation/sbx-kits/`) to configure each sandbox: USAi provider setup, playbook clone, Zscaler CA cert, and git SSH commit signing. This works and is well-tested, but it couples the quickstart to a single isolation vendor (Docker) and a single kit vocabulary (sbx's `spec.yaml` v2).

**Going forward (v2):** We want to demonstrate more than one isolation option _natively_ in the quickstart so teams can choose the backend that fits their environment and trust model:

| Backend | What it is | Fits when |
|---|---|---|
| **`sbx`** | Docker Sandboxes CLI (`sbx run` …) — the v1 foundation. Closed-source product, requires Docker login [for unspecified reasons](https://github.com/docker/sbx-releases/issues/321#issuecomment-4926359032). | You already have Docker and want the commercial product, and your org has seats. |
| **`ppp`** | Podman Machine + mitmproxy WireGuard (the design in `ppp-spec.md`). FOSS Go binary, per-sandbox VM, single host-side proxy. Positioned as a composition of mature OSS tools (Podman + mitmproxy + WireGuard + OS keychain) rather than a from-scratch reimplementation. | You want no Docker dependency, no paid seat, full audit across sandboxes, and reproducible builds. |
| **`msb`** | microsandbox (`msb run` …) — open source, FOSS-licensed microVM runtime from Super Rad Company. SDK + CLI. | You want SDK-first automation, snapshot/restore, MCP integration, or cloud-host option. |

All three: microVM isolation, network policy, secret injection without secrets entering the guest, capability for audit/trail.

**Replaces:** the `qsbx` wrapper entirely. v2 ships as `acq` (agentic-coding-quickstart). v2 is a 2.0.0 release with no back-compat for pre-kit-era `qsbx` consumers; session migration and kit healing logic are removed.

---

## 2. The `acq` command

`acq` is the single entry point in the quickstart repo. One user invocation creates a sandbox, applies the standard community kits, validates the USAi key, and attaches the agent.

```bash
acq run opencode /path/to/your/project
acq run opencode /path/to/your/project --backend msb
acq run opencode /path/to/your/project --backend ppp
```

Backend selection (in priority order):

1. `--backend <name>` flag
2. `ACQ_BACKEND` env var
3. `backend:` in `~/.acq/config.yaml`
4. Auto-detect: try `sbx version` → `msb doctor` → `ppp version` in order; first one found wins

If only one backend is installed, that one wins silently. If multiple are installed and none is selected, `acq` prints the candidates and exits with a hint to set `ACQ_BACKEND`.

### Commands

The `acq` command surface mirrors the subset of `sbx`/`msb`/`ppp` operations the quickstart actually uses. Everything else (raw platform commands, advanced features) is still available by calling the underlying backend directly — `acq` documents that escape hatch but doesn't try to wrap every flag.

| Command | What it does |
|---|---|
| `acq run AGENT PATH [...] [-- AGENT_ARGS...]` | Create+attach or re-attach |
| `acq create AGENT PATH [...]` | Create detached sandbox |
| `acq ls` | List sandboxes (all backends) |
| `acq stop NAME` | Stop without removing |
| `acq rm NAME` | Permanently remove |
| `acq exec NAME -- COMMAND...` | Run command inside |
| `acq cp SRC DST` | Copy file in/out (`NAME:path` syntax) |
| `acq ports NAME [--publish ...]` | List or publish ports |
| `acq usai-rotate-api-key` | Rotate stored USAi key (unaffected by backend) |
| `acq version` | Show `acq` version + detected backend + its version |
| `acq doctor` | Check prerequisites for all installed backends |
| `acq backend set <NAME>` | Persist default in `~/.acq/config.yaml` |
| `acq backend list` | List detected/installed backends |
| `acq kit apply NAME KIT_REF` | Apply an extra mixin kit to an existing sandbox |
| `acq kit list` | Show the standard pinned kits |
| `acq kit validate PATH` | Validate a neutral spec kit |

### Standard behavior regardless of backend

- **Name derivation:** `<agent>-<slug-of-basename>` (e.g., `opencode-my-tts-app`). Without `--name`, derived; with `--name`, used as-is.
- **Kit apply at create:** `acq run` and `acq create` apply the four pinned community kits (see section 4) using the active backend's native mechanism. Pinning is via a prominent `ACQ_KIT_REF` variable at the top of `acq` (one-line reviewable bump).
- **Pre-attach checks (advisory, never fail closed for soft warnings):**
  - Validate the sandbox's USAi key (cURL to models endpoint inside the sandbox). If invalid/expired, offer to rotate via `acq usai-rotate-api-key`.
  - Warn if no SSH signing key in `ssh-add -L` (for git-ssh-sign kit).
  - Warn if no repo-local `user.email` (for GitHub-verified commits).
- **Multi-workspace:** `acq run opencode ~/my-app ~/my-other-app:ro` — forward the extra mounts to the backend's mount mechanism.
- **Pass-through:** unknown `acq` subcommands are forwarded to the active backend's CLI untouched (rare; documented escape hatch).
- **Config search path:** `~/.acq/config.yaml` → `<repo>/.acqrc` → env vars → CLI flags.
- **`acq doctor`** is platform-aware: it checks what's installed, prints a matrix `[sbx: installed v0.34.0] [ppp: not found] [msb: installed v0.6.1]`, and asks `Choose default backend [sbx/msb/ppp]:` to write to `~/.acq/config.yaml`.

---

## 3. The neutral kit spec (Option 3 — hybrid)

A new schema in the patterns repo: `spec.yaml` with `schemaVersion: "hybrid/v1"`. It captures the **declarative** parts of a kit (network allows, files to drop, commands to run, agent context) in a backend-agnostic vocabulary, plus **backend shortcuts** for primitives that are strictly better native-per-backend than the general mechanism.

### Schema

```yaml
schemaVersion: "hybrid/v1"
kind: mixin
name: usai-provider
displayName: USAi Provider (OpenCode)
description: |
  Configure the agent to use the GSA USAi OpenAI-compatible endpoint as its
  model provider, with egress allow-listed. Targets OpenCode today.

caps:
  network:
    allow:
      - api.gsa.usai.gov

files:
  - path: /home/agent/usai-config/opencode.jsonc
    mode: "0644"
    content: |
      <inline or !include reference>
  - path: /home/agent/usai-config/merge-global-config.mjs
    mode: "0755"
    content: |
      <inline or !include>

commands:
  - phase: startup
    user: "1000"
    description: Merge USAi provider config into the global OpenCode config
    command: [node, /home/agent/usai-config/merge-global-config.mjs, --source, /home/agent/usai-config/opencode.jsonc, --global-dir, /home/agent/.config/opencode]

agentContext: |
  ## USAi Provider
  Your model provider is configured to use USAi (api.gsa.usai.gov).
  ...

# Backends MAY declare shortcuts that replace the declarative path with a
# native primitive. Adapters check this section first; a shortcut for the
# kit means the adapter ignores `caps`, `files`, `commands` for this backend.
backend_shortcuts:
  msb:
    # e.g., trust-host-cas is a native msb flag — way better than file-drop
    # Only present when a backend has a strictly-better primitive.
  sbx: {}
  ppp: {}

# Backends MAY also declare extra native config that the neutral spec
# doesn't model (e.g., ppp's addon hook). Declared under `backend_extras`
# so it's explicit and version-controlled along with the kit.
backend_extras:
  ppp:
    addon_inject:
      header_name: "x-api-key"
      secret_service: "usai"
      host_match: "api.gsa.usai.gov"
```

### Lifecycle phases (neutral vocabulary)

| Phase | Runs as | When | sbx maps to | msb maps to | ppp maps to |
|---|---|---|---|---|---|
| `install` | root | create time, once | `commands.install` | one-off `msb exec --user 0` post-create, idempotent | first-boot part of `provision.sh` (gated by `/var/lib/sbx/.provisioned`) |
| `initFiles` | agent uid (1000) | every start, after base image setup | `commands.initFiles` | `msb exec` post-start | every-boot part of `provision.sh` |
| `startup` | configurable (default agent uid) | every start, after initFiles | `commands.startup` | `msb exec` post-start, after initFiles | every-boot part of `provision.sh` after initFiles block |
| `agent_context` | n/a | always present in agent's context root | `agentContext` (in `~/.agents/context/`) | written to `~/.agents/context/<kit-name>.md` after start | same |

Adapters are allowed to collapse phases when the backend has no semantic difference (e.g., msb has no "install at create" hook — `install` becomes "exec once, gated by a marker file").

### Backend shortcuts

A per-backend section under `backend_shortcuts:` declares when to bypass the file-drop / command-run path entirely and use a native primitive. Adapters check this first; if present, the kit's `caps`, `files`, `commands` are ignored for that backend.

This is how we avoid least-common-denominator drift: a native primitive that's strictly better (msb's `--trust-host-cas` replacing an entire file-drop + cert-install kit) short-circuits the general mechanism. States the capability and how to use it; no manual file-drop dance.

### Backend extras

A per-backend section under `backend_extras:` declares _additional_ configuration the neutral spec doesn't model, kept in the same `spec.yaml` so review covers it. This is where ppp's addon-only behaviors (header rewriting, custom secrets substitution) live side-by-side with the kit's neutral declaration.

### Validation

`acq kit validate PATH`:

- The spec passes JSON-schema validation against `schemas/kit-hybrid-v1.schema.json`.
- All declared `backend_shortcuts` reference known backends in the registry.
- All `files` paths are absolute inside the sandbox and resolvable from the kit's `files/` directory.
- All `commands` reference files that exist after `files`+`initFiles` phases run.
- Cross-backend parity is **advisory** (not enforced): every kit must list a parity note in the kit's README noting any intentional capability gap per backend. The validator emits a warning if a `backend_shortcuts.<backend>.skip: true` is set without a parity note.

---

## 4. The four kits, mapped

For 2.0.0, the four existing sbx kits become four hybrid-v1 kits in `agentic-coding-patterns/integrations/isolation/kits/` (new neutral home; the old `sbx-kits/` stays around for one release as a redirect). Each kit is a single `spec.yaml` + `files/` + `README.md` + `TROUBLESHOOTING.md` + `docs/decisions/` + `scripts/verify`.

### 4.1 `usai-provider` — agent model provider configuration

Semantic intent: configure the agent to use the GSA USAi OpenAI-compatible endpoint, with egress allow-listed, config merged into OpenCode's global path at startup without clobbering an existing config.

Declarative parts (shared across backends):
- `caps.network.allow: [api.gsa.usai.gov]`
- `files`: the same `opencode.jsonc` and `merge-global-config.mjs` used today (no backend changes them)
- `commands` (phase: startup): `node merge-global-config.mjs --source .../opencode.jsonc --global-dir ...opencode`
- `agentContext`: agent-friendly notice that USAi is the configured provider

Per-backend implementation:

| Backend | What the adapter does |
|---|---|
| sbx | Emit sbx v2 `caps.network.allow`, `files`, `commands.startup`, `agentContext` — identical to today's kit |
| msb | `msb create` with `--net-rule "allow@domain:api.gsa.usai.gov"`; `msb exec` to drop `files`; `msb exec` to run the startup command after every `msb start`. Kit's `caps.network.allow` lines become `--net-rule` flags at create time. |
| ppp | Append `api.gsa.usai.gov` to `$PPP_STATE/sandboxes/<name>/policy.yaml`; copy `files/` in via `podman machine ssh` + `podman cp`; append the startup command to the every-boot provision script |

Secret: the USAi API key is **not** in this kit. `acq` owns the secret model end-to-end via the unified swap-on-access mechanism documented in section 7.5 (Secret model). The user runs `acq secret set usai --host api.gsa.usai.gov` once for a global key (used by all sandboxes), and optionally `acq secret set usai --host api.gsa.usai.gov --sandbox <name>` for a per-sandbox key (overrides the global key for that sandbox). This supports USAi's anticipated billing-code charge-back model: each sandbox can carry its own key associated with a specific billing code. `acq` stores the key in its host keychain and writes a `CredentialRewriteRule` into the active backend's MITM path (sbx's proxy / msb's `--tls-intercept` / ppp's mitmproxy addon). The agent makes requests with no `Authorization` header; the MITM proxy injects it on the way out. The real USAi key never enters the sandbox.

### 4.2 `agentic-coding-playbook` — startup playbook clone + skill symlinks

Semantic intent: clone the agentic-coding-playbook repo at startup into `~/.agentic-coding-playbook`, pin a known-good commit, symlink `AGENTS.md` + skills into per-agent search paths.

Declarative parts:
- `caps.network.allow`: `github.com` (and any helper hosts — e.g. GH raw content)
- `commands` (phase: startup, runs as agent): shell `git clone --quiet https://github.com/GSA-TTS/agentic-coding-playbook.git ~/.agentic-coding-playbook` (gated by `test -d ~/.agentic-coding-playbook/.git || git clone ...`), then symlink `AGENTS.md` → `~/.config/opencode/AGENTS.md`, skills → `~/.agents/skills/`.
- `agentContext`: note about playbook skills available

Backends map to the same `caps` + `commands` machinery; no shortcuts needed. GH token handled as a swap-on-access secret via `acq secret set github --host github.com --host api.github.com` (see section 5 — Secret model). The MITM path injects `Authorization: token <real>` on git/HTTPS and API outbound.

### 4.3 `zscaler-ca-certificate` — install a public CA into guest trust store

Semantic intent: install the public Zscaler Root CA into the guest's system trust store so outbound HTTPS works through Zscaler-intercepting proxies.

Declarative parts (used by sbx and ppp):
- `files`: `/home/agent/zscaler-ca.crt` (`mode: 0644`, PEM content)
- `commands` (phase: startup, user: 0): `install -m 0644 /home/agent/zscaler-ca.crt /usr/local/share/ca-certificates/zscaler-ca.crt && update-ca-certificates`

**Backend shortcut (the showcase):**

```yaml
backend_shortcuts:
  msb:
    trust_host_cas: true
```

The `msb` adapter emits `--trust-host-cas` at `msb create` and **ignores** `files`/`commands` for this kit. Since the host already trusts the Zscaler CA (installed by the org's Zscaler rollout), `--trust-host-cas` propagates that trust into the guest at boot — strictly better than the explicit file-drop and `update-ca-certificates` dance. No re-inventing the wheel.

`sbx` and `ppp` absence of that shortcut means they fall through to the file-drop mechanism. Kit README parity note: "msb uses `--trust-host-cas`; sbx and ppp use the file-drop mechanism. Behavior is equivalent: the guest ends up trusting the Zscaler CA."

### 4.4 `git-ssh-sign` — sign git commits with forwarded host SSH key

Semantic intent: configure git to sign commits and tags with the forwarded host SSH agent key; fail closed if no key is loaded; don't write key material at create/startup time (the agent may not have connected yet).

Declarative parts:
- `commands` (phase: install, user: 0): git system config — `gpg.format ssh`, `commit.gpgSign true`, `tag.gpgSign true`, `gpg.ssh.defaultKeyCommand /home/agent/.config/git/ssh-signing-key-command`, `gpg.ssh.allowedSignersFile /home/agent/.config/git/allowed_signers`
- `files` (phase: initFiles, mode: 0755): `/home/agent/.config/git/ssh-signing-key-command` — the existing script that reads `ssh-add -L` at signing time

Backend-specific native primitives:

| Backend | SSH forwarding mechanism |
|---|---|
| sbx | Existing: SSH agent socket forwarded into the sandbox |
| msb | `msb ssh authorize --file ~/.ssh/id_ed25519.pub` registers the key with the sandbox's host-controlled sshd; `msb ssh <name>` attaches with agent forwarding. Adapter issues `msb ssh authorize ...` post-create. |
| ppp | `podman machine ssh` uses ssh-agent forwarding; `acq` runs `podman machine ssh -A <name>` from the host to propagate SSH_AUTH_SOCK. Adapter documents the `-A` requirement. |

No backend shortcuts needed; SSH-agent forwarding is the common mechanism, and each backend has its own way to enable it.

---

## 5. Quickstart repo changes

The quickstart v2 repo (`agentic-coding-quickstart` at tag `v2.0.0`) is _narrower_ than v1. It contains:

```
acq                         # the active wrapper (replaces qsbx)
acq.backends/               # per-backend adapter modules (sourced by acq)
  sbx.sh                    # adapter: invokes sbx CLI
  msb.sh                    # adapter: invokes msb CLI
  ppp.sh                    # adapter: invokes ppp binary or acq's own ppp subcommand
  common.sh                 # name derivation, USAi key check, git identity check, ssh-agent check
  kit-translate.sh          # neutral-spec → native flags (small; the real work per backend is in each adapter)
scripts/
  rotate-apikey             # unchanged — backend-agnostic (uses backend exec, cURL)
  verify-backends           # CI: for each installed backend, create/test a sandbox
docs/
  QUICKSTART.md             # new 5-minute quickstart with the backend-chooser
  BACKEND_GUIDE.md          # covers each backend's strengths and tradeoffs
  KNOWN_FAILURE_MODES.md    # trimmed (no migration/kit-heal entries)
  adr/
    0008-pluggable-isolation-backends.md   # this design
  risk-assessment.md        # updated: per-backend notes
README.md                   # rewritten for v2
AGENTS.md                   # unchanged
CHANGELOG.md                # v2.0.0 entry
package.json                # acq shell completion helpers
```

**Removed (no longer needed for v2):**
- `qsbx` (replaced by `acq`)
- `opencode-web.sh` (stays too — still useful; backend-agnostic — `acq run` mounts the same files)
- ADRs 0003, 0004 (superseded by 0005; kept for history)
- `docs/QUICKSTART_SBX.md` (replaced by `docs/QUICKSTART.md` + per-backend sections)

### README (rewritten for v2)

```
5-Minute Quickstart (v2)

Step 0: Prerequisites
  - Package manager
  - USAi API key

Step 1: Install a backend (choose one)

  sbx  (your org already pays Docker)  → brew install docker/tap/sbx && sbx login
  ppp  (in-house, FOSS, no Docker seat) → brew install GSA-TTS/tap/ppp && ppp setup
  msb  (SDK-ready, cloud option)       → curl -fsSL https://install.microsandbox.dev | sh

Step 2: Install acq

  git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
  cd agentic-coding-quickstart
  ./acq doctor    # detects installed backends, asks to set default

Step 3: Configure secrets and policy (once)

  ./acq secret set usai --host api.gsa.usai.gov        # store USAi key (prompted, global)
  ./acq secret set github --host github.com --host api.github.com --env GH_TOKEN  # GitHub token
  ./acq policy init balanced                            # default network policy

  # Optional: per-sandbox USAi key for billing-code charge-backs
  ./acq secret set usai --host api.gsa.usai.gov --sandbox my-project-sandbox

Step 4: Create and run a sandbox

  ./acq run opencode /path/to/your/project
```

Note that "Install a backend" is the only step where the v2 user makes a choice. Everything after that is identical across backends — `acq` handles translation under the hood.

---

## 6. Patterns repo changes

The patterns repo (`agentic-coding-patterns`) gets a neutral `_kits/` home that replaces the backend-specific `sbx-kits/`:

```
integrations/isolation/
  kits/                                # new: hybrid/v1 neutral home
    usai-provider/
      spec.yaml                        # hybrid/v1
      files/
        home/usai-config/
          opencode.jsonc               # unchanged from v1
          merge-global-config.mjs      # unchanged from v1
      README.md
      TROUBLESHOOTING.md
      docs/decisions/
      scripts/verify
    agentic-coding-playbook/
      spec.yaml
      files/
        home/playbook-clone.sh         # NEW: extracted from the inline shell into a tested script
      README.md
      ...
    zscaler-ca-certificate/
      spec.yaml
      files/
        home/zscaler-ca.crt
      README.md
      ...
    git-ssh-sign/
      spec.yaml
      files/
        home/.config/git/ssh-signing-key-command
      README.md
      ...

  # The old sbx-kits/ directory is left for one release as a redirect.
  # ADR 0009 in patterns repo records the migration and the parity
  # decision (msb's --trust-host-cas replaces the file-drop path for
  # the zscaler kit on msb).
  sbx-kits/
    README.md   # "Redirected to kits/. See v2 design notes."
    # ... old contents kept readable for historical reference, stale

  kits.yaml                              # registry: name → backends + parity notes
```

`kits.yaml` (registry) is the human-readable parity summary:

```yaml
kits:
  usai-provider:
    backends: [sbx, msb, ppp]
    parity: |
      All three backends allow-list api.gsa.usai.gov and run the
      merged-config script. Secret stored per-backend (see backend docs).
  agentic-coding-playbook:
    backends: [sbx, msb, ppp]
    parity: |
      All three backends allow-list github.com and run the clone+symlink
      script at sandbox startup. GH token handled per-backend.
  zscaler-ca-certificate:
    backends: [sbx, msb, ppp]
    parity: |
      msb uses --trust-host-cas (host CAs auto-imported into guest);
      sbx and ppp use the file-drop + update-ca-certificates mechanism.
      Behavioral parity: guest ends up trusting the Zscaler CA.
  git-ssh-sign:
    backends: [sbx, msb, ppp]
    parity: |
      All three backends forward the host SSH agent. SSH key resolution
      command runs at signing time; no key material stored at create.
```

### Migration from sbx-kits (in patterns repo)

A v1→v2 migration ADR records that `sbx-kits/` content moves to `kits/` and adopts hybrid/v1 neutral spec. A pinned `ACQ_KIT_REF` commit SHA in `acq` points at a commit of `agentic-coding-patterns` that has both the old and new homes; v3 drops the old home.

---

## 7. How `acq` translates a kit to a backend

When `acq run opencode ./my-app` runs, `acq` does the following for **each of the four pinned kits**:

1. Fetch the kit from the pinned `ACQ_KIT_REF` (git+https, SHA-verified like v1).
2. Read `spec.yaml`. Validate it.
3. Check `backend_shortcuts.<active_backend>`. If a shortcut is declared, the adapter emits the native flags/operations and skips steps 4–6.
4. Emit `caps.network.allow` entries as the backend's network-policy primitives (sbx: kit YAML at create; msb: `--net-rule` flags; ppp: append to per-sandbox `policy.yaml`).
5. Copy `files/` into the sandbox via the backend's file-copy mechanism (sbx: kit's `files/` → sbx handles internally; msb: `msb exec` + heredoc or `msb cp` equivalent; ppp: `podman machine ssh` + `podman cp`).
6. Append `commands[]` to the backend's startup hook (sbx: kit's `commands.install/initFiles/startup` phases natively; msb: `msb exec` post-create and post-start; ppp: every-boot `provision.sh` snippets, gated appropriately by phase).
7. Check `backend_extras.<active_backend>`. Apply any backend-specific extras (e.g., ppp's `addon_inject` becomes a row added to `$PPP_DATA/sandboxes/<name>/addon-config.yaml` that the ppp mitmproxy addon reads at next SIGHUP).
8. Write `agentContext:` into the agent's `~/.agents/context/<kit-name>.md` (the backend's exec handles writing; text identical across backends).

### Adapter contract (per backend) — ABC with ClassVar capability flags

Adopted from Omnigent's `SandboxLauncher` ABC pattern (see `Prior Art: Omnigent` section below): a small abstract interface with three `@abstractmethod` methods every backend must implement, a handful of optional methods that raise `BackendCapabilityError` by default, and `ClassVar` flags gating coarse capabilities. Fail-fast before doing remote work.

This is expressed as a Python ABC for the design contract. v2.0.0 ships a bash implementation of the same shape; v2.1 may port to Go or Python directly, at which point the ABC maps 1:1.

```python
class IsolationBackend(ABC):
    # Identity + capabilities (declared as code, not YAML)
    name: ClassVar[str]                                  # "sbx" | "msb" | "ppp"
    supports_port_forward: ClassVar[bool] = False        # can publish guest ports to host
    supports_snapshots: ClassVar[bool] = False           # can save/restore VM disk
    can_resume: ClassVar[bool] = True                    # stop and re-attach with state preserved
    supports_credential_rewrite: ClassVar[bool] = True  # native MITM path for swap-on-access

    # Mandatory primitives (every backend MUST implement)
    @abstractmethod
    def prepare(self) -> None: ...
        """Host-side check — verify CLI installed and prerequisites met.
        Raises if backend unusable. Idempotent."""
    @abstractmethod
    def provision(self, name: str, agent: str, paths: list[str], kits: list[str]) -> str: ...
        """Create the sandbox, apply kits, return the sandbox id.
        Kits are the pinned ACQ_KIT_REF references; adapter translates to
        whatever the backend's native kit mechanism is."""
    @abstractmethod
    def run(self, sandbox_id: str, command: list[str], *, check: bool = True) -> CommandResult: ...
        """Run a command in the sandbox; return exit code + stdout + stderr."""

    # Optional primitives — each raises BackendCapabilityError by default
    # with a remediation hint naming the escape hatch (per Omnigent's
    # SandboxCapabilityError pattern). Override per backend when supported.
    def attach(self, sandbox_id: str) -> None: ...
        """Interactive attach (TTY). Default raises BackendCapabilityError."""
    def put(self, sandbox_id: str, local_path: str, remote_path: str) -> None: ...
        """Copy a file in. Default raises; sbx/msb/ppp all override."""
    def stream_exec(self, sandbox_id: str, command: list[str], *, pty: bool = False) -> Process: ...
        """Streaming exec; default raises."""
    def stop(self, sandbox_id: str) -> None: ...
        """Stop without removing. Default raises — mandatory for us actually, TODO promote to abstract."""
    def terminate(self, sandbox_id: str, *, force: bool = False) -> None: ...
        """Permanently remove. Default raises; mandatory in practice, TODO promote."""
    def resume(self, sandbox_id: str) -> None: ...
        """Re-start a stopped sandbox. Default raises if can_resume=False."""
    def forward_local_port(self, sandbox_id: str, port: int) -> ContextManager[None]: ...
        """SSH -L semantics; raises if supports_port_forward=False."""
    def install_credential_rewrite(self, sandbox_id: str, rule: CredentialRewriteRule) -> None: ...
        """Configure the MITM path for swap-on-access (see Secret model below).
        Default raises if supports_credential_rewrite=False."""
    def apply_kit(self, sandbox_id: str, kit_ref: str) -> None: ...
        """Apply a kit to an existing sandbox (mid-life). Default raises for backends
        without a 'kit add' equivalent — `acq` falls back to recreate."""
    def list_sandboxes(self) -> list[SandboxInfo]: ...
        """List all sandboxes known to this backend. Default raises."""
```

The wrapper's common logic (name derivation, USAi key check via `run(curl)`, git identity check, SSH agent check, kit translations) lives in `common.sh` and calls the adapter's abstract methods. Each backend adapter is the only place that knows its backend's specific CLI shape; unknown subcommands pass through untouched (escape hatch).

### Concrete adapter hookups

| Abstract method | sbx adapter | msb adapter | ppp adapter |
|---|---|---|---|
| `provision(NAME, AGENT, PATHS, KITS)` | `sbx create --name NAME --kit K1 --kit K2 ... AGENT PATHS` (each hybrid spec.yaml → translated to sbx v2 spec.yaml at a temp dir) | `msb create IMAGE --name NAME` + `--net-rule` from kit caps + post-create `msb exec` to drop files + run install commands | `ppp create --name NAME --cpus --memory AGENT PATH` + policy append + provision script assemble |
| `run(SBX, cmd)` | `sbx exec NAME -- cmd...` | `msb exec NAME -- cmd...` | `ppp exec NAME -- cmd...` |
| `stop(SBX)` | `sbx stop NAME` | `msb stop NAME` | `ppp stop NAME` |
| `terminate(SBX)` | `sbx rm NAME --force` | `msb rm NAME` | `ppp rm NAME --force` |
| `attach(SBX)` | `sbx run --name NAME` | `msb ssh NAME` | `ppp run --name NAME` (TTY) |
| `forward_local_port(SBX, port)` | `sbx ports NAME --publish ...` | `msb ... -p HOST:GUEST` | `ppp ports NAME --publish ...` |
| `apply_kit(SBX, REF)` | `sbx kit add NAME REF` | translate kit → `msb exec` commands | translate kit → append to `policy.yaml` + `provision.sh` |
| `install_credential_rewrite(SBX, RULE)` | synthesize `sbx secret set-custom --host HOST --env VAR ...` (sbx proxy does the rewrite) | emit `--tls-intercept` config + msb-native secret binding at create; post-create `msb exec` writes a rewrite rule if needed | append the rule to `$PPP_DATA/sandboxes/<NAME>/addon-config.yaml` (the ppp mitmproxy addon reads it at next SIGHUP) |

Capability flags per backend:

| `ClassVar` | sbx | msb | ppp |
|---|---|---|---|
| `supports_port_forward` | True | True | True |
| `supports_snapshots` | False (sbx has templates, different shape) | True | True (via qcow2 snapshots — TODO) |
| `can_resume` | True | True | True |
| `supports_credential_rewrite` | True | True | True |

---

## 7.5 Secret model — unified swap-on-access across backends

Adopted from Omnigent's `credential_proxy` design (`designs/SANDBOX_CREDENTIAL_PROXY.md`, PR #236). The key insight: every backend already has an L7 MITM path for egress allow-listing, so secret injection is **a rewrite rule on the same MITM**, not a per-backend storage problem.

### One secret store, one command

`acq` owns the secret store. The user runs the same command regardless of backend:

```bash
# Global USAi key (used by all sandboxes that don't have their own)
acq secret set usai --host api.gsa.usai.gov
# prompted for the key; stored in host keychain under "acq.usai"

# Per-sandbox USAi key (overrides the global key for this sandbox)
acq secret set usai --host api.gsa.usai.gov --sandbox my-project-sandbox
# stored under "acq.my-project-sandbox.usai" — takes precedence over "acq.usai"

acq secret set github --host github.com --host api.github.com
acq secret set anthropic                              # built-in service, known host
```

Secrets live in the OS keychain (macOS Keychain / Windows Credential Manager / Linux Secret Service) via `go-keyring`, with an `age`-encrypted fallback at `$XDG_DATA_HOME/acq/secrets.age` when no keychain backend is available. Entries are keyed as `acq.<service>` (global) or `acq.<sandbox>.<service>` (sandbox-scoped).

**Per-sandbox scoping and USAi charge-backs:** A sandbox-scoped key always takes precedence over the global key for the same service. This supports USAi's anticipated billing-code model: each sandbox can carry its own USAi API key associated with a specific billing code, so usage is attributed to the right cost center without every agent needing to know the key. The `CredentialRewriteRule` installed for the sandbox resolves the keychain entry by checking `acq.<sandbox>.<service>` first, then falling back to `acq.<service>`. The agent never sees either key — both are injected by the MITM path on outbound requests.

The real secret **never** crosses into the sandbox. `acq` holds it; the backend's MITM path injects it on outbound requests. Each backend's adapter has a `install_credential_rewrite(sandbox_id, rule)` method that wires the rule into its native proxy:

| Backend | What `install_credential_rewrite` does |
|---|---|
| **sbx** | Synthesizes the equivalent of `sbx secret set-custom --host HOST --env VAR ...` from `acq`'s keychain into the sbx proxy config. The sbx proxy does the rewrite on outbound. |
| **msb** | Emits `--tls-intercept` config + msb's native secret binding at create time. Post-create `msb exec` writes a rewrite rule if the msb native path needs one. |
| **ppp** | Appends a `CredentialRewriteRule` to `$PPP_DATA/sandboxes/<NAME>/addon-config.yaml` that the ppp mitmproxy addon reads at next SIGHUP. The addon queries the Go parent via UDS for the real key (cache miss → keychain read). |

### Two modes (named explicitly, was previously conflated)

**1. Swap-on-access (default):**

The agent makes an HTTP request to `api.gsa.usai.gov` with **no** `Authorization` header. The MITM proxy intercepts, injects `Authorization: Bearer <real_key>` (or `x-api-key: <real_key>` for Anthropic-style APIs), and forwards upstream. Nothing credential-shaped ever enters the sandbox. Works for `curl`, `python` SDKs, `node`, `git over HTTPS` — anything that uses HTTP and omits auth.

**2. Opt-in placeholder (only when the client gates before network):**

Some clients refuse to issue a request without a token in hand (e.g., `gh` short-circuits with "authentication required" before touching the network). For these, `acq` mints a non-secret `acq_placeholder_<32 random bytes>` placeholder and injects it into the named env var (`GH_TOKEN`, `USAI_API_KEY`, etc.). The client emits the placeholder; the MITM proxy swaps it for the real secret on the way out.

**Cross-host leak guard (from Omnigent):** if the placeholder is replayed against any host other than the one it was minted for, the proxy returns **HTTP 403**. This prevents an agent from using the placeholder to authenticate against an unintended destination.

The user opts into placeholder mode per-secret:

```bash
acq secret set github --host github.com --host api.github.com --env GH_TOKEN
#                                                                          ^ opt-in placeholder
```

Without `--env`, swap-on-access is used (default). With `--env`, the placeholder is injected into that env var inside the sandbox.

### `CredentialRewriteRule` (the data structure)

```python
@dataclass(frozen=True)
class CredentialRewriteRule:
    host: str                       # e.g. "api.gsa.usai.gov"
    scheme: str                     # "bearer" | "basic" | "x-api-key" | "token"
    secret_service: str             # base keychain key, e.g. "acq.usai"
    sandbox: str | None = None      # sandbox name for per-sandbox scoping; None = global only
    synthetic: str | None = None    # "acq_placeholder_..." if opt-in placeholder, None for swap-on-access
    env_name: str | None = None     # which env var to inject the placeholder into (opt-in only)
    username: str | None = None     # for basic auth; defaults to "x-access-token"
```

The `secret_service` field is a **reference** to the keychain entry — never the real secret value. When `sandbox` is set, the MITM path resolves the key by checking `acq.<sandbox>.<service>` first, then falling back to `acq.<service>` (global). This rule is safe to serialize to `addon-config.yaml` / checkpoint files / logs. The real secret is fetched lazily by the MITM path on cache miss.

### Trust hygiene hardening (adopted from Omnigent)

Three rules that must hold across all backends:

1. **Real secret never in argv.** The MITM path must never shell out with the real secret on the command line (it would be visible via `ps` / `/proc/<pid>/environ`). The ppp addon uses UDS IPC (`$PPP_DATA/secret.sock`); the sbx adapter uses `sbx secret set-custom --password-stdin` (piped, not argv); the msb adapter uses the SDK's in-process binding. `acq`'s own CLI reads the secret via `--password-stdin` or a TTY prompt — never a CLI arg.

2. **Real secret never serialized.** `CredentialRewriteRule` holds a `secret_service` reference, not the value. The rule is safe to write to `addon-config.yaml`, to `sandbox.json`, to logs, and to diagnostic dumps. The real value lives only in the keychain and the MITM path's in-memory cache (TTL 60s, cleared on SIGHUP). This mirrors Omnigent's `SandboxPolicy.to_jsonable` excluding `real_secret`.

3. **CA bundle host-only.** The MITM CA's private key (`~/.mitmproxy/mitmproxy-ca.pem` for ppp, `~/.microsandbox/tls/ca.key` for msb, sbx's internal CA) must live on a host-only path and never be readable from inside any sandbox. The guest only receives the **public** cert (via `--import-native-ca` / `http://mitm.it/cert/pem` / msb's auto-trust). This prevents a compromised sandbox from tampering with what upstream certs the parent trusts.

### Pre-attach key validation (backend-agnostic, with per-sandbox awareness)

`acq run` validates the sandbox's USAi key before attaching by `run`-ning a `curl` against the models API inside the sandbox. The MITM path injects whichever key resolves for this sandbox (per-sandbox `acq.<sandbox>.usai` first, then global `acq.usai`), so the validation works identically across backends and respects per-sandbox scoping. If the key is expired, `acq` prompts: "Is this a per-sandbox key or your global key?" and walks the user through the appropriate `acq secret set usai --host api.gsa.usai.gov [--sandbox <name>]` (re-store) + `acq usai-rotate-api-key` (the helper).

### What this replaces from v1 / earlier design drafts

- Eliminates the per-backend `backend__secret_set` divergence. The user runs one `acq secret set` command; the adapter handles translation to the backend's native MITM.
- Names the two modes (swap-on-access vs. opt-in placeholder) explicitly. Previously the ppp addon did "inject Authorization / strip client keys" without naming which mode was default or when to pick the other.
- Adds the **cross-host leak guard** (403 on placeholder replayed against a non-minted host) — not present in any earlier design.
- Makes the "never serialize the real secret" rule explicit (was implicit in the ppp UDS design but never stated as a hard rule).
- Makes the "CA bundle host-only" rule explicit (was a side-detail of `podman machine init --import-native-ca`).

---

## 8. Concrete DX walkthrough: choosing a backend

### Scenario A: federal team with Docker seats, wants the commercial sbx path

```bash
brew install docker/tap/sbx
sbx login

git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
./acq doctor
# detects sbx installed; writes backend: sbx to ~/.acq/config.yaml

./acq secret set usai --host api.gsa.usai.gov       # store USAi key (prompted)
gh auth token | ./acq secret set github --host github.com --host api.github.com --env GH_TOKEN

./acq run opencode /path/to/my-project
# acq detects ~/.acq/config.yaml == sbx, calls sbx adapter, applies kits, attaches
```

### Scenario B: open-source team without Docker, choosing the FOSS ppp backend

```bash
brew install GSA-TTS/tap/ppp
ppp setup                          # installs mitmdump etc.

git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
./acq doctor
# detects ppp only; writes backend: ppp

./acq secret set usai --host api.gsa.usai.gov
./acq run opencode /path/to/my-project
# acq runs ppp adapter, allocates UDP port for the WG instance,
# spawns podman machine, provisions, attaches
```

### Scenario C: dev-experience team building SDK automation on top of msb

```bash
curl -fsSL https://install.microsandbox.dev | sh

git clone https://github.com/GSA-TTS/agentic-coding-quickstart.git
cd agentic-coding-quickstart
ACQ_BACKEND=msb ./acq doctor
# detects msb; writes backend: msb

./acq secret set usai --host api.gsa.usai.gov
./acq run opencode /path/to/my-project --backend msb
# acq runs msb adapter; uses --tls-intercept --trust-host-cas flags
# (zscaler kit takes its backend_shortcut path; no file-drop needed)
```

In all three scenarios, the user typed **the same `acq` commands**. Only the backend install was different. That's the v2 promise.

---

## 9. CI and verification

`scripts/verify-backends` (run in GitHub Actions) creates a tiny sandbox for each installed backend and verifies:

- The four pinned kits apply cleanly with no parity warnings.
- The USAi key (a CI-only throwaway) round-trips to a 200 from a mock models endpoint.
- Git commit signing produces a signed commit inside the sandbox.
- The playbook clone symlink appears at the agent's `AGENTS.md` path.

Each backend has an install matrix row in CI. If a backend isn't installed at the runner, those tests are skipped. If it is installed and tests fail, the PR is blocked.

Kit authors run `acq kit validate PATH` locally. The patterns repo CI runs `scripts/verify` for each kit for each available backend.

---

## 10. Open items

- **Neutral spec schema file**: needs JSON Schema (`schemas/kit-hybrid-v1.schema.json`) and a validator. Short — the schema is intentionally minimal.
- **`acq` implementation language**: bash now (matching `qsbx`), with a path to Go once we're confident the shape is stable. v2.0.0 ships bash; v2.1 if needed Go-rewrites for cross-platform Windows support.
- **`ppp` binary name**: resolved — Podman Plus Proxy (`ppp`). The design is documented in `ppp-spec.md`. The name communicates the build-on-existing-OSS positioning: Podman for the VM, mitmproxy for the proxy, and `ppp` for everything else.
- **Per-backend install instructions in README**: I sketched Homebrew for all three; needs `winget` and `apt` rows per backend — see `docs/BACKEND_GUIDE.md`.
- **Kits directory move in patterns repo**: small coordination cost. Tag patterns repo at v2.0.0 with both `kits/` and `sbx-kits/` redirects; `acq` pins to that commit until v3.
- **Kit parity testing**: CI must run each kit's `scripts/verify` against each installed backend. Two test matrices (`kits × backends`).
- **USAi key per backend**: `acq`'s unified secret store means the USAi key lives in the `acq.usai` keychain entry, not per-backend. If a v1 user has it stored in `sbx secret`, `acq doctor` can detect and offer to import it into `acq`'s keychain. One-time migration tooling, not front-and-center.
- **Windows support**: `acq` bash works on WSL and Git Bash. ppp on Windows is subject to the WSL2 WireGuard risk documented in `ppp-spec.md`. `sbx` on Windows is fully supported. `msb` Windows is in preview per their docs. Document per-backend platform support explicitly in `BACKEND_GUIDE.md`.
- **MITM rewrite path per backend**: `acq`'s unified swap-on-access model (section 7.5) means each backend's adapter has an `install_credential_rewrite` implementation. sbx translates to `sbx secret set-custom`; msb uses `--tls-intercept` + native secret binding; ppp writes a `CredentialRewriteRule` to `addon-config.yaml`. The user never sees these details — `acq secret set` is the one command.
- **Long-tail parity disputes**: A kit author who wants to add a feature only one backend supports either (a) uses `backend_shortcuts`/`backend_extras`, or (b) splits the kit per backend (Option 2 escape hatch). The registry's parity note tracks it either way.

---

## 11. Prior Art: Omnigent

The adapter ABC (section 7), the unified swap-on-access secret model (section 7.5), and the three trust-hygiene rules are adopted from [Omnigent](https://github.com/omnigent-ai/omnigent), an open-source AI agent meta-harness (Apache 2.0). Three details that informed the design:

1. **`SandboxLauncher` ABC + `ClassVar` capability flags + raising-default optionals** (Omnigent `omnigent/onboarding/sandboxes/base.py`) — replaced our earlier flat `backend__*` bash function list. Omnigent's pattern of 3 abstract methods + optional methods that raise with a remediation hint, plus sparse `ClassVar[bool]` capability gates, is cleaner than a flat function list and maps directly to a Python ABC (which `acq` can adopt when it moves from bash to Python/Go in v2.1).

2. **Credential proxy with swap-on-access + opt-in placeholder + cross-host leak guard** (Omnigent PR #236, `designs/SANDBOX_CREDENTIAL_PROXY.md`, `omnigent/inner/credential_proxy.py`) — replaced our earlier per-backend `backend__secret_set` divergence. The key insight is that every backend already has an L7 MITM path for egress allow-listing, so secret injection is a rewrite rule on the same MITM, not a per-backend storage problem. Omnigent's two-mode distinction (swap-on-access default; opt-in `oa_cred_*` placeholder with 403 on cross-host replay) and trust hygiene (real secret never in argv / serialized policy config; CA bundle host-only) are directly adopted.

3. **Capability model as code, not YAML** (Omnigent `omnigent/harness_capabilities.py`) — capabilities are `Enum` axes + a frozen `@dataclass` + `.as_dict()` for a catalog, asserted in tests. We adopt this for `acq`'s backend capability flags (the `ClassVar` pattern) rather than inventing a YAML capability schema that would drift from the implementation.

### What we do differently from Omnigent

Omnigent's design has three weaknesses we improve on:

- **No entry-point plugin model for sandbox backends.** Omnigent keeps sandbox providers in-tree (static dict + lazy import); only _harnesses_ use entry points. For `acq`, if GSA ever wants a classified/air-gapped backend, we should support entry-point plugins for backends too (`acq.community.backend` group with a frozen-`@dataclass` `BackendContribution` and collision-rejecting validator). v2.0.0 ships the three in-tree backends; v2.1 can add the entry-point seam.

- **Per-provider YAML parsers are repetitive.** Omnigent's `parse_sandbox_config()` has bespoke `_parse_modal_image` / `_parse_daytona_env` helpers in one giant function. Each `acq` backend should expose `BackendClass.config_spec() -> type[BaseModel]` and the central config loader dispatches generically.

- **No composable "kit" unit.** Omnigent layers (`egress_rules`, `credential_proxy`, `container_image`, repo workspace, snapshot) are separate YAML knobs that only compose by hand. For our quickstart persona, a user wants `kit: gsa-coding-python` not 40 lines of per-knob config. `acq` keeps the hybrid-v1 kit spec — it's the right abstraction for the audience.

---

## 12. ADR chefs

Two ADRs will record this design:

**agentic-coding-quickstart ADR-0008**: "Pluggable isolation backends via `acq`; hybrid v1 neutral kit spec; unified swap-on-access secret model (adopted from Omnigent)." Records: why we chose Option 3 (hybrid), the three backends, what we deliberately don't promise (parity is best-effort + documented, not enforced), the qsbx→acq replacement, the adapter ABC pattern (from Omnigent's `SandboxLauncher`), the credential-proxy model (from Omnigent's PR #236), the target date for v2.0.0.

**agentic-coding-patterns ADR-0009**: "Move sbx-kits → kits/ with hybrid/v1 spec; preserve one-release redirect." Records: why the neutral spec, the four kits' new shape, the msb `--trust-host-cas` shortcut for zscaler-ca, the registry file, the migration path from v1 sbx-kits.

Both will reference this document (`docs/adr/agentic-coding-quickstart-v2-design.md` or the equivalent path in the quickstart repo) as the long-form design.

---

## 13. Out of scope for v2.0.0

- Session migration from v1.0.x `qsbx` sandboxes (v1 consumers are an early cohort; `acq rm && acq run` is the documented upgrade path — honestly users keep their work in git, not in sandbox session history).
- Kit healing for sandboxes created before a kit was added (we redesign the workflow; not bringing the v1 healing code forward).
- New community kits beyond the four (usai-provider, playbook, zscaler-ca, git-ssh-sign). v2 is about pluggability, not adding more kits.
- Cloud-hosted ppp or msb deployments. v2 is local-first.
- New built-in services beyond what `sbx secret set` already knows (anthropic, github, openai, google, aws, groq, mistral).
- `--clone` semantics across backends (sbx has it; msb and ppp would need host-side git clone + mount). v2 documents `--clone` as sbx-only and degrades to a friendly error on other backends with a manual workaround. v2.1 can add support.

---

## Appendix: Implementation Status

> **Implementation is underway in phases.** This appendix tracks what has shipped, what
> is in progress, and where the delivered code deviates from the design above.

### Phase timeline

| Phase | Target release | Change | Status |
|-------|----------------|--------|--------|
| **Phase 1** | 1.1.0 | Add `acq` (sbx driver only), deprecate `qsbx` | **Shipped** |
| **Phase 2** | 1.2.0 | Add `msb` driver; neutral hybrid/v1 kit spec; `acq-kits/` move in patterns | **Shipped** |
| **Phase 3** | 1.3.0 | Add `ppp` driver | Deferred / undecided |
| **Phase 4** | 2.0.0 | `acq` becomes primary; remove `qsbx` | Planned |

### What is implemented (Phase 1 / 1.1.0)

- **`acq` entry point** (`acq`, `chmod +x`) — full command surface for the
  qsbx-parity subset plus `backend`/`doctor`:
  `run`, `create`, `ls`, `stop`, `rm`, `exec`, `cp`, `ports`, `secret set`,
  `usai-rotate-api-key`, `version`, `doctor`, `backend list`, `backend set`.
  Unknown subcommands pass through to the active backend CLI.
- **`acq.backends/common.sh`** — backend-agnostic logic: kit constants (same
  four sbx-kit refs, same pinned `PATTERNS_KIT_REF` as qsbx), backend
  resolution (`--backend` flag → `ACQ_BACKEND` env → XDG config → auto-detect),
  `slugify`/`derive_name`, USAi key validation, SSH-signing and git-identity
  advisories.
- **`acq.backends/sbx.sh`** — sbx adapter implementing the bash equivalent of
  the `IsolationBackend` contract: all `acq_backend_*` functions, capability
  flags, kit-source allowlist management, exec-ready polling, in-place kit
  healing (`acq_backend_ensure_kits_applied`), and `acq_backend_secret_set`.
- **`scripts/test-acq`** — offline unit harness (42 tests): backend resolution
  order, name derivation, dispatch routing, qsbx deprecation notice, and
  `acq secret set` command shapes.
- **`qsbx`** — one-line silenceable deprecation notice added
  (`QSBX_SILENCE_DEPRECATION=1`); otherwise unchanged and fully functional.
- **Docs:** `docs/QUICKSTART.md` (acq quickstart + migration guide),
  `docs/BACKEND_GUIDE.md` (per-backend tradeoffs), `docs/adr/0010-acq-pluggable-backends.md`.
- **README / AGENTS.md / CONTRIBUTING.md** updated to recommend `acq`.

### Deviations from this design doc

The following are **deliberate deductions** for Phase 1 (1.1.x), recorded here so readers
can distinguish "not done yet" from "done differently":

1. **XDG config path, not `~/.acq/`.** The design draft uses `~/.acq/config.yaml`
   (§2, §7.5). The implementation uses
   `${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml` — consistent with
   OpenCode's `~/.config/opencode/` and the design's own `secrets.age` fallback
   which already assumed `$XDG_DATA_HOME`. Recorded in ADR-0010.

2. **Bash adapter, not Python ABC.** §7 specifies a Python `IsolationBackend`
   ABC; the note says "v2.0.0 ships a bash implementation of the same shape."
   Phase 1 (1.1.x) ships that bash implementation. Function-level parity with the ABC
   contract is maintained; a Go/Python port is a future option.

3. **No neutral hybrid/v1 kit spec.** §3 describes `schemaVersion: "hybrid/v1"`
   and `kit-translate.sh`. Phase 1 (1.1.x) pins the **same four sbx-kit refs** as qsbx
   unchanged — no kit translation layer, no new schema, no `kits/` move in the
   patterns repo. These land in Phase 2 (1.2.x) when a second backend actually needs a
   neutral vocabulary.

4. **No `acq kit apply|list|validate`, no `acq policy`, no `acq secret` swap-on-access model.**
   These are deferred to Phase 2+ (1.2.x+). `acq secret set` is a thin wrapper over the
   sbx secret CLI for the current release.

5. **ADR number is 0010, not 0008.** The design says "ADR-0008". ADRs 0008 and
   0009 were already in use in this repo (stale-placeholder recovery and
   in-place kit healing). The pluggable-backend ADR is `docs/adr/0010-acq-pluggable-backends.md`.

6. **`qsbx` is not removed.** §5 says "`qsbx` replaced by `acq`". In Phase 1 (1.1.x),
   `qsbx` is deprecated (notice + docs) but fully functional; it is scheduled
   for removal in Phase 4 (2.0.0). `scripts/test-migrate-or-halt` and
   `scripts/verify-migrate-live` are also retained until Phase 4 (2.0.0).

7. **`docs/QUICKSTART_SBX.md` not yet replaced.** §5 says it is replaced by
   `docs/QUICKSTART.md` + per-backend sections. Phase 1 (1.1.x) adds `docs/QUICKSTART.md`
   (acq-focused) alongside the existing `docs/QUICKSTART_SBX.md` (kept as
   detailed sbx reference). Full replacement deferred to Phase 4 (2.0.0).

8. **`kit-translate.sh` not present.** The repo layout in §5 lists
   `acq.backends/kit-translate.sh`. This file is not needed until a second
   backend requires kit translation; it is omitted in Phase 1 (1.1.x).

9. **`scripts/verify-backends` not present.** §5 lists a CI verification
   script. Not implemented in Phase 1 (1.1.x); live sbx verification is deferred (this
   environment runs inside an sbx sandbox and cannot create nested sandboxes).

10. **`sbx secret set-custom` does not support `--password-stdin`.** The
    handoff doc (§9) specified `--password-stdin` as the preferred form for
    custom secrets. Verified against the actual sbx 0.35.0 CLI: the flag does
    not exist on `set-custom`. The implementation reads the secret via `read -rs`
    (interactive) or stdin (piped) and pipes it to sbx, keeping it out of argv.
    The `--password-stdin` flag is only available on `sbx secret set --registry`.

11. **`acq secret set` requires explicit scope (`-g` or sandbox name).** The
    handoff doc (§9) shows all examples with `-g` (global). The implementation
    makes scope mandatory — omitting it errors immediately rather than silently
    defaulting to global. This mirrors `sbx secret set` / `set-custom` and
    prevents accidentally overwriting the global USAi key during testing.
    Use `acq secret set -g usai` for global, or `acq secret set SANDBOX usai`
    to scope to a single sandbox. All other `acq secret` subcommands
    (`ls`, `rm`, `import`, `set-custom`, `--help`) pass through to sbx unchanged.

### What is implemented (Phase 2 / 1.2.0)

Phase 2 adds the **msb (microsandbox) backend** and the **neutral `hybrid/v1`
kit vocabulary** with a translation layer. Recorded in
`docs/adr/0011-msb-backend-and-neutral-kits.md`. Delivered:

- **`acq.backends/kit-translate.sh`** — the shared neutral-spec layer: fetches a
  kit ref (remote `git+https#ref=&dir=` via sparse checkout, or a local dir),
  parses the `hybrid/v1` `spec.yaml` with `awk` (no `yq`), dispatches
  `backend_shortcuts.<backend>`, synthesizes an sbx-v2 kit dir for the sbx
  backend, and provides `kit_validate` for `acq kit validate`. Multi-line
  command bodies are carried as base64 tokens so literal block scalars survive.
- **`acq.backends/msb.sh`** — the microsandbox adapter (full ADR-0010 contract).
  Drives the neutral ops directly: `caps.network.allow` → `--net-rule`,
  `files[]` → `msb copy`, `commands[]` → `msb exec` (install marker-gated),
  zscaler shortcut → `--trust-host-cas`, USAi key → `--secret ENV@HOST`.
- **`acq.backends/sbx.sh`** — kit application routed through `kit-translate.sh`
  (synthesizes a local sbx-v2 kit before `sbx --kit`/`sbx kit add`); observable
  behavior for sbx users is unchanged.
- **`acq.backends/common.sh`** — `PATTERNS_KIT_REF`/`DIR` repointed to the
  neutral `acq-kits/` tree; `_auto_detect_backend` gains `msb` (sbx preferred);
  real msb probe in `acq doctor`.
- **`acq`** — real msb row in `backend list`; new `kit list|validate|apply`.
- **`scripts/verify-backends`** — per-installed-backend live E2E check (design
  §9). **`scripts/test-acq`** — msb + `acq kit` + neutral→sbx-v2 translation
  cases (offline, stubs `msb`).
- **Docs** — `BACKEND_GUIDE.md` msb section flipped to shipped;
  `QUICKSTART.md` gains a "choose a backend" step and the msb run flow.

### Additional deviations from this design doc (Phase 2)

1. **Kit home is `acq-kits/`, not `kits/`.** The handoff §4.1 said
   `integrations/isolation/kits`; Part A (patterns repo) shipped
   `integrations/isolation/acq-kits/` — a reviewer asked for the explicit
   `acq` association. This repo pins `acq-kits/`, and neutral specs reference
   payloads via a `source:` field under each kit's `files/` tree. Kit dir names
   also dropped the `-kit` suffix (`usai-provider-kit` → `usai-provider`).

2. **No `yq` runtime dependency.** §10 flags the neutral spec needs a
   validator; the parser is `awk`-based (no new dependency). Multi-line command
   bodies are base64-framed to survive block scalars through the shell pipeline.
   The authoritative JSON Schema lives in the patterns repo
   (`schemas/kit-hybrid-v1.schema.json`); `acq kit validate` does structural
   checks without a full JSON-schema engine.

3. **Secrets are acq-owned (bash keychain subset of §7.5), not sbx-specific.**
   Phase 2 adds `acq.backends/secret-store.sh`: one store keyed
   `acq.<service>` / `acq.<sandbox>.<service>` (sandbox scope wins) in the OS
   keychain (`security`/`secret-tool`) with a `0600` file fallback. `acq secret
   set` writes there; BOTH backends read from it at provision — sbx feeds its
   proxy (`sbx secret set`/`set-custom`, piped), msb binds `--secret ENV@HOST`
   (USAi + GitHub) from a transient env var. The value never enters the guest,
   never appears in argv, and is never serialized. This is the bash subset of
   §7.5; the full Go/`go-keyring`/`age` + MITM `CredentialRewriteRule` +
   swap-on-access placeholder component remains a larger future effort. The
   earlier "msb uses raw host-env `--secret`, unified store deferred" note is
   superseded.

4. **msb `ports` is create/run-time only** (msb 0.6.6 has no post-hoc ports
   verb), and **msb `ensure_kits_applied` re-applies kits idempotently** rather
   than a state-preserving in-place add (msb has no `sbx kit add` equivalent;
   it never silently destroys state).

5. **msb provides the kits' `agent`/uid-1000 + /home/agent contract itself,
   plus several live-bring-up fixes.**
   The kits assume the sbx agent-template user (`agent`, HOME=/home/agent, run
   as `-u 1000`). A plain OCI base has no such user (node:22-bookworm ships
   `node` at uid 1000), which caused the usai `node merge-global-config.mjs`
   MODULE_NOT_FOUND and the playbook-clone failure (both ran as the wrong
   user/home). The adapter creates the `agent` user at provision (idempotent,
   offline), chowns staged `/home/agent` files to it, and runs uid-1000 kit
   commands as `agent` with `HOME=/home/agent` (addressed by name, not literal
   uid). Other gotchas found during live bring-up, all fixed:
   (i) the kit files/commands apply loops buffer their records into arrays
   first — an inner `msb copy`/`msb exec` consumes the loop's stdin, which
   silently dropped every file/command after the first (this was the actual
   cause of the missing `merge-global-config.mjs`, not the earlier copy-race
   theory; `msb` exec/copy persistence itself was verified fine);
   (ii) the host workspace is mounted at a fixed guest path
   (`/home/agent/workspace`), because msb won't create the host path and
   mishandles an identical host:guest `/tmp` mount;
   (iii) `--dns-nameserver` (default `1.1.1.1`) is passed to `msb create`,
   because the host's corporate/VPN resolver is unreachable from the microVM
   (verified: with it, the models API resolves and returns 401/200 and github
   returns 200);
   (iv) a sandbox that isn't exec-ready after create is a HARD failure —
   `msb create` returns 0 even when the guest fails to START, so earlier runs
   were false successes.

6. **`PATTERNS_KIT_REF` is provisionally pinned to the Part A PR head**
   (`#221`, pre-merge) with a `TODO` in `common.sh`. Per the handoff §4.1 hard
   gate, the Part B PR stays in draft until this is flipped to the Part A
   merge-commit SHA.

7. **`scripts/verify-backends` live run is deferred.** The script exists
   (design §9) but the full `acq run … --backend msb` loop cannot run inside a
   sandbox (no nested sandboxes) and needs host virtualization. The msb CLI flag
   shapes were verified against `msb 0.6.6`; the live loop is deferred to a
   sandbox-capable host, mirroring ADR-0009/ADR-0010.
