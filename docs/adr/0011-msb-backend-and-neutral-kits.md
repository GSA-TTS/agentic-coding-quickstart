---
title: "Add msb (microsandbox) Backend and Neutral hybrid/v1 Kit Translation"
status: accepted
date: 2026-07-16
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SA-17", "SC-7", "SC-8", "SC-28", "SI-10"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0011: Add msb (microsandbox) Backend and Neutral hybrid/v1 Kit Translation

> **Update (2026-07-31):** The default `ACQ_MSB_IMAGE` is now
> **`docker.io/docker/sandbox-templates:shell-docker`** — the same Ubuntu-based sbx
> agent-template image — **not** `node:22-bookworm`. The default therefore already
> ships the `agent` user, passwordless sudo, the four kit prerequisites, and an
> agent-writable npm global prefix, so the agent-user/sudo synthesis described
> below is now a *short-circuit* on the default image and applies only to a
> plain-OCI **override**. Where this ADR's original text (below) frames
> `node:22-bookworm` as the default, read it as the override example. See
> `docs/BACKEND_GUIDE.md` §"Base image requirements" for the current contract.
> (The original decision text is preserved unchanged for the historical record.)
>
> **Update (2026-08-27):** When no explicit image override is set, msb now
> derives the sbx agent-template image name from the requested agent
> (`docker.io/docker/sandbox-templates:<agent>-docker`, matching how `sbx run
> <agent>` selects its template; `claude` → `claude-code-docker` and `cursor` →
> `cursor-agent-docker` are the two product-name exceptions) and falls back to
> `docker.io/docker/sandbox-templates:shell-docker` only if the derived image is
> not found. This shortens startup for agents (e.g. `opencode`) whose template
> already bakes in the agent binary. See ADR-0022 and `docs/BACKEND_GUIDE.md`.

## Context and Problem Statement

[ADR-0010](0010-acq-pluggable-backends.md) introduced `acq`, a pluggable-backend
wrapper with a single backend adapter (`sbx.sh`). Phase 2 (1.2.0) adds a second
isolation backend — **msb (microsandbox)** — so teams can choose a FOSS microVM
runtime with no Docker seat.

Two backends cannot share sbx-only kit specs: `sbx run --kit` semantics, the sbx
credential model, and sbx-specific lifecycle phases do not map onto `msb`.
Without a shared vocabulary, each backend would need its own copy of every kit —
guaranteeing drift and doubling the maintenance and review surface.

This ADR is **Part B** of the Phase 2 handoff
(`docs/explorations/acq-handoff-2.0.md`). **Part A** (the patterns-repo half —
the neutral `hybrid/v1` kits, JSON schema, and registry) lands separately in
`agentic-coding-patterns` and produces the commit SHA this repo pins.

## Decision Drivers

- One neutral kit vocabulary shared by every backend (`sbx`, `msb`, later `ppp`).
- **No functional change for current sbx users** — kit payloads and behavior are
  carried verbatim; the observable sbx result is identical to Phase 1.
- No new runtime dependencies (parse the neutral spec with `awk`, not `yq`).
- Additive, non-breaking — adding `msb.sh` does not alter the core dispatch, and
  `qsbx` and its migration tests are left untouched (removal is Phase 4).
- Fail closed on ambiguity (a missing Part A merge SHA, an unverified msb flag).

## Considered Options

1. **Neutral `hybrid/v1` kits + a `kit-translate.sh` layer; sbx synthesizes an
   sbx-v2 kit, msb drives the neutral ops directly.** Chosen.
2. Give msb its own kit tree (`msb-kits/`). Rejected: guarantees drift, doubles
   review surface (the design doc explicitly rejects least-common-denominator
   duplication).
3. Teach `sbx` to consume `hybrid/v1` natively. Rejected: sbx's kit schema is
   owned by Docker; we cannot change it.

## Decision Outcome

**Chosen: Option 1.**

### New modules

- **`acq.backends/kit-translate.sh`** — the shared neutral-spec layer. It:
  - fetches a kit ref (remote `git+https#ref=&dir=` via sparse checkout, or a
    local dir) into a cache;
  - parses the `hybrid/v1` `spec.yaml` with `awk` (fields, `caps.network.allow`,
    `files[]`, `commands[]`, `environment`, `agentContext`, `backend_shortcuts`);
  - dispatches `backend_shortcuts.<backend>` (skip the generic path when a
    native primitive applies);
  - for **sbx**, synthesizes an equivalent **sbx-v2** kit directory
    (`spec.yaml` + `files/`) so `sbx --kit` / `sbx kit add` consume it exactly
    as before;
  - provides `kit_validate` for `acq kit validate`.
  - Multi-line command bodies are carried through the parser as **base64**
    tokens so literal block scalars survive as a single argv element.

- **`acq.backends/secret-store.sh`** — the acq-owned, backend-neutral secret
  store (the design's §7.5 model, as a thin bash subset). Credentials are no
  longer sbx-specific: one store keyed `acq.<service>` / `acq.<sandbox>.<service>`
  (sandbox scope wins), stored in the OS keychain (macOS `security`, Linux
  `secret-tool`) with a `0600` file fallback. `acq secret set` writes here; both
  adapters read from here at provision. Trust hygiene per §7.5: the value is
  read from TTY/stdin (never argv), never serialized into kit specs/config/logs,
  and file entries are `0600`. Feeding each backend's runtime respects the real
  CLI contract: sbx built-in services take the value on **stdin**
  (`sbx secret set`), while sbx **custom endpoints** (`set-custom`) have no stdin
  and would require `--value` on argv — so acq runs `set-custom` interactively
  (sbx prompts) from a terminal, or (piped/non-interactive) stores the value and
  prints the exact command instead of exposing it on argv. `acq secret set` is
  non-destructive: if sbx already holds the secret it stops with an
  `sbx secret rm …` hint. The full Go/`go-keyring`/`age`/MITM
  `CredentialRewriteRule` component of §7.5 remains a larger future effort.

- **`acq.backends/msb.sh`** — the microsandbox adapter implementing the full
  ADR-0010 contract against the `msb` CLI. It fetches each neutral kit and
  drives the parsed operations directly: `caps.network.allow` → `--net-rule
  allow@HOST` (bare FQDN); `files[]` → `msb copy`; `commands[]` → `msb exec` (install
  phase marker-gated for idempotency); the zscaler `backend_shortcuts.msb`
  → `--trust-host-cas`; the USAi key → `--secret USAI_API_KEY@api.gsa.usai.gov`
  with `--tls-intercept` (required for substitution), read from the acq secret
  store at provision into a transient env var (never argv, never the kit spec;
  the guest gets only a placeholder). `acq secret set` re-feeds running sandboxes
  via `msb modify --secret`. The **GitHub token is bound to the REST API and
  git-transport hosts**
  (`GITHUB_TOKEN@github.com,api.github.com,codeload.github.com`): msb substitutes
  the token on the wire for REST API calls, and git smart-HTTP is **eligible**
  because git carries its credential in an `Authorization: Basic` header that
  msb's substitution path rewrites (see the "GitHub git-HTTPS substitution
  eligibility" note below), so the real token never enters the guest. Kits still
  may use REST tarballs for reproducibility, but HTTPS git transport is eligible
  for substitution.
  Unlike sbx (whose
  templates supply the image), msb runs a plain OCI image: the default is the
  public `node:22-bookworm` (built on buildpack-deps, so it already ships
  node/git/curl/ca-certificates — the four kits' prerequisites — and pulls
  without registry auth). The adapter VERIFIES those tools are present and warns
  if a custom `ACQ_MSB_IMAGE` lacks them; it deliberately does NOT install them
  at runtime because the kit net-rules lock egress to the kits' own hosts, so a
  package mirror is unreachable during provision. It also **creates the `agent`
  user (HOME=/home/agent)** the kits assume (the sbx agent-template contract) —
  a plain base has no such user (node:22-bookworm has `node` at uid 1000) — and
  runs the kits' uid-1000 commands as `agent` (by name, with HOME set), chowning
  staged `/home/agent` files to it. It **mounts each host workspace at the same
  absolute path in the guest** (sbx-parity; see the workspace-mount note below) —
  an earlier revision remapped to a fixed `/home/agent/workspace`, which failed
  because `msb create` mounts before the `agent` user/home exist.
  It passes **`--dns-nameserver`** (default `1.1.1.1`) because msb hands the
  guest the host's resolvers, which for a corporate/VPN resolver are unreachable
  from the microVM (otherwise the guest can't resolve even allow-listed hosts).
  It treats a sandbox that is **not exec-ready** after create as a HARD failure:
  `msb create` returns 0 even when the guest fails to START (async boot), so the
  only reliable readiness signal is that `msb exec` works.

- **sbx-v2 command typing (translation):** sbx v2 expresses lifecycle hooks under
  `setup`. It types `setup.install[].command` as a shell **string** and
  `setup.startup[].command` as an argv **sequence**. The synthesizer emits
  per-phase accordingly (install → block string, startup/initFiles → argv seq,
  with neutral `initFiles` ordered before `startup` under `setup.startup`);
  mismatching yields sbx's "cannot unmarshal !!seq into string" / "!!str into
  []string".

### Changed modules

- **`acq.backends/common.sh`** — `PATTERNS_KIT_REF`/`PATTERNS_KIT_DIR` repointed
  to the neutral `acq-kits/` tree; sources `kit-translate.sh`;
  `_auto_detect_backend` gains an `msb` branch (sbx preferred, then msb);
  `acq_print_doctor` probes a real msb version.
- **`acq.backends/sbx.sh`** — kit application routed through
  `kit-translate.sh` (`_acq_sbx_translate_kit` synthesizes a local sbx-v2 kit
  from each neutral kit before `sbx --kit`/`sbx kit add`). An
  `ACQ_SBX_KIT_PASSTHROUGH` escape hatch keeps the offline test harness from
  fetching.
- **`acq`** — `backend list` shows a real msb row; new `kit list|validate|apply`
  subcommands.
- **`scripts/verify-backends`** (new) — per-installed-backend live E2E check.
- **`scripts/test-acq`** — msb resolution/dispatch/doctor/list cases, `acq kit`
  cases, and neutral→sbx-v2 translation cases (stubs `msb` like `sbx`; offline).

### msb capability flags

`SUPPORTS_PORT_FORWARD=0` (msb has no post-hoc ports verb — ports are published
at create/run time via `-p HOST:GUEST`; the flag gates the sbx-style post-hoc
`acq ports`, so it is 0 for msb), `SUPPORTS_SNAPSHOTS=1`, `CAN_RESUME=1`,
`SUPPORTS_CREDENTIAL_REWRITE=1`.

### Deviations from the design doc / handoff (recorded per §5, §7)

- **Kit home is `acq-kits/`, not `kits/`.** The handoff §4.1 said
  `integrations/isolation/kits`; Part A (patterns) shipped
  `integrations/isolation/acq-kits/` (a reviewer asked for the explicit `acq`
  association). This repo pins `acq-kits/`. Neutral specs reference payloads via
  a `source:` field under each kit's `files/` tree.
- **Kit dir names dropped the `-kit` suffix** (`usai-provider-kit` →
  `usai-provider`, `playbook-kit` → `agentic-coding-playbook`), matching Part A.
- **No `yq` dependency.** The neutral spec is parsed with `awk`; multi-line
  command bodies are base64-framed to survive block scalars.
- **msb `ports` is create/run-time only.** msb 0.6.6 has no post-hoc ports verb;
  `acq --backend msb ports` prints the `-p HOST:GUEST` mechanism instead of
  forwarding.
- **msb secret model is native host-env `--secret`,** not the unified
  swap-on-access store (out of scope for Phase 2 per the handoff §2). `acq
  secret set usai` on msb prints host-env guidance.
- **msb `ensure_kits_applied` re-applies idempotently** rather than a
  state-preserving in-place add (msb has no `sbx kit add` equivalent); it never
  silently destroys state.

### Agent install + base-image contract + attach (fix for quickstart#228)

The initial 1.2.0 msb adapter provisioned a sandbox with the four kits but
**never installed or launched the requested agent** (`opencode`): `msb create`
booted a plain `node:22-bookworm`, no step installed opencode, and
`acq_backend_attach` ran a bare `msb ssh NAME` — dropping the user into a **root
shell with no agent** (reported in
[quickstart#228](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/228)).
Both defects stem from the adapter ignoring the AGENT token that
`acq_backend_provision`/`attach` receive. On sbx this "just works" because the
agent **template supplies the binary and its launch wiring**; msb runs a plain
base and must reproduce that itself. The fix makes the msb adapter satisfy the
same contract sbx's templates provide, keyed off the
[Docker base-image requirements](https://docs.docker.com/ai/sandboxes/customize/kit-reference/#base-image-requirements)
for `docker/sandbox-templates:shell-docker`:

- **Install the agent** (`_acq_msb_install_agent`). The AGENT token is read from
  the first positional at provision. `opencode` → `npm install -g opencode-ai`
  (node is already a verified prerequisite), with the npm registry host
  (`registry.npmjs.org`) allow-listed at create so the default-deny egress
  permits the download. Idempotent: skipped if the binary is already present
  (a pre-baked `ACQ_MSB_IMAGE`) and marker-gated. `shell` is a no-op; an unknown,
  absent agent warns (bake it into `ACQ_MSB_IMAGE`). Tunables:
  `ACQ_MSB_OPENCODE_PKG`, `ACQ_MSB_NPM_HOSTS`.
- **Satisfy the base-image contract** (`_acq_msb_ensure_agent_user`, extended).
  In addition to the `agent`/`/home/agent` user it already created, it now adds
  **passwordless sudo** (`/etc/sudoers.d/90-acq-agent`) and preserves the
  **HTTP proxy env across sudo** (`env_keep` in `/etc/sudoers.d/91-acq-proxy-env`)
  — the two remaining published requirements a plain base lacks. Idempotent +
  marker-gated; a base without `sudo` is non-fatal (acq runs root steps as
  `-u 0` directly).
- **Launch the agent on attach** (`acq_backend_attach` → `_acq_msb_attach`).
  Reproduces `sbx run --name`'s "re-launch the baked-in agent" behavior with
  `msb exec -t -u agent -w <workspace> -e SHELL=/bin/sh NAME -- <agent>` — the one
  msb primitive that allocates a PTY (so a full-screen agent TUI renders; `msb
  ssh` has no tty flag), runs as the unprivileged `agent` user, and starts in the
  workspace. The agent to run is recorded at provision (`/var/lib/acq/agent`) so
  the name-only re-attach path (`acq run <sandbox>`) still launches it. Falls back
  to an interactive `/bin/sh -l` **as the agent user** (never root, never msb's
  Node-REPL default) for `shell` sandboxes or a missing binary.

Egress note: this adds one create-time allow-list host (the npm registry) only
when an installable agent is requested; it does not widen egress for `shell`.

### Guest sizing (follow-up to quickstart#228)

Installing and launching the agent (above) exposed a further defect on the same
report: `opencode` **started and was immediately `Killed`**. msb defaults a
sandbox to **512 MiB of RAM and 1 vCPU** and the microVM has **no swap**, so a
Node.js TUI that exceeds guest RAM is OOM-killed by the guest kernel (surfacing
only as `Killed`). sbx's agent templates are sized generously; a plain msb base
inherits the small default. The adapter therefore passes **`--memory 4G --cpus 2`**
at create, tunable via `ACQ_MSB_MEMORY` / `ACQ_MSB_CPUS` (empty = fall back to
msb's own default). Values are validated before reaching the create line (memory
to msb's `[0-9GMgm.]` SIZE grammar, cpus to a positive integer) so a stray value
cannot smuggle another flag onto `msb create`.

### Workspace mount at the host path (fix for PR #230)

An earlier revision mounted the host workspace at a **fixed guest path**
(`/home/agent/workspace`). That failed on a plain base image with
`mount ...: Not a directory (os error 20)`: `msb create` performs the mount at
**create time**, which is *before* the adapter can create the `agent` user and
its `/home/agent` directory (that happens post-create, once the guest is
exec-ready). Mounting into a not-yet-existent `/home/agent` therefore aborted
the sandbox boot.

The adapter now mounts **each workspace at its own absolute host path in the
guest** (`--volume <host>:<host>[:ro]`), matching sbx's multi-workspace
semantics (`docs/QUICKSTART_SBX.md`: "All workspaces appear inside the sandbox at
their absolute host paths"). This sidesteps the create-time ordering problem and
restores sbx parity. Multiple workspaces and a trailing `:ro` marker are
supported (`workspace_paths` in `common.sh` enumerates them). The agent's
starting directory is recorded at provision (`/var/lib/acq/workspace`) for the
name-only re-attach path: it is the **primary (first) workspace**, matching sbx.
`ACQ_MSB_WORKSPACE` overrides the start dir.

A second, related failure: msb **cannot mount a symlinked host path**. It fails
to start with the same `os error 20` even mapped to a shallow guest target
(verified on msb 0.6.6). The common case is **macOS `$TMPDIR`**, a per-user
`/var/folders/...` tree reached through the `/var` → `/private/var` symlink. The
adapter therefore canonicalizes each workspace to its real, symlink-free path
(`canonicalize_path` in `common.sh`) before mounting, and `scripts/verify-backends`
no longer places its test workspace under `$TMPDIR`.

### msb CLI flag verification

The msb flag/subcommand shapes used by the adapter were **verified against
`msb 0.6.6`** (`superradcompany/microsandbox` v0.6.6, linux/aarch64) via
`msb --tree` and per-command `--help`: `create --name --net-rule
allow@HOST --trust-host-cas --tls-intercept --secret ENV@HOST --volume`,
`exec [-u USER] -- CMD`, `list -q`, `stop`, `remove -f`, `copy`, `ssh`,
`ssh authorize`, `-p HOST:GUEST`, `doctor`.

## Consequences

- **Better:** one neutral kit vocabulary; msb reuses the same four kits; adding
  `ppp` (Phase 3, in development at
  [GSA-TTS/ppp](https://github.com/GSA-TTS/ppp)) is again additive. Kit authoring
  is backend-agnostic.
- **Tradeoff:** the sbx path gained a translation step. Mitigated by carrying
  payloads verbatim and asserting the synthesized sbx-v2 output in `test-acq`;
  the observable sbx result is unchanged.
- **Compliance:** no new external services; the msb secret path keeps the real
  key out of the guest (SC-8/SC-28); network egress is allow-listed per kit
  (SC-7). Structural adapter change only (SA-8/SA-15/SA-17; CM-2/CM-3/CM-6).
- **Untrusted-input hardening (SI-10):** kit specs are semi-trusted external
  input (patterns repo / `ACQ_EXTRA_KITS`) that drive a root shell in the guest,
  so the translation layer validates every field before it reaches a shell
  context: `files[].mode` must be octal, `files[].path`/`source` and
  `commands[].user` are charset-restricted, `commands[].phase` must be a known
  lifecycle phase, `environment` var NAMES must match
  `^[A-Za-z_][A-Za-z0-9_]*$`, and `caps.network.allow` hosts are
  hostname-validated.
  Offending records are dropped with a warning (and reported by `acq kit
  validate`). Defense-in-depth: the msb adapter also re-checks mode/path at the
  point of use and passes `chmod`/`chown` arguments as argv, never interpolated
  into `sh -c`. Command argv is base64-tokenized and passed as separate argv, so
  a kit command is never reassembled into a joined shell string.
- **TLS interception scope:** `--tls-intercept` is enabled **guest-wide** (not
  scoped to a single host) — it must be, because msb only substitutes secret
  placeholders on connections it can see into, and the guest auto-trusts the
  interception CA. Secret *substitution* remains host-scoped (`--secret
  ENV@HOST`), but interception itself covers all guest egress on the intercepted
  ports. This is a broader/less-transparent posture than sbx's proxy injection;
  it is the microsandbox model and the price of the microVM boundary. Disable
  with `ACQ_MSB_NO_TLS_INTERCEPT` (secrets then won't substitute).
- **Private GitHub content:** kits may fetch private GitHub content via pinned
  REST tarballs for reproducibility, and acq binds GitHub credentials to the
  REST API plus HTTPS git-transport hosts
  (`GITHUB_TOKEN@github.com,api.github.com,codeload.github.com`). msb
  substitutes the placeholder on those hosts, so direct HTTPS clone/push is
  eligible for secret injection without the real token entering the guest. The
  credential-substitution path for git smart-HTTP was live-confirmed against
  msb 0.6.9 with `scripts/verify-git-https-secret-msb`, which authenticated a
  private-repo `git ls-remote` using only the guest placeholder.
- **GitHub git-HTTPS substitution (live-confirmed against msb 0.6.9):** the msb
  secret-substitution engine substitutes a placeholder only on a TLS-intercepted
  connection whose SNI/authority matches the bound host (the `--tls-intercept`
  requirement is unchanged in 0.6.9). Its request rewriting covers HTTP request
  **headers** — including an `Authorization: Basic <base64(user:token)>` value,
  which it base64-decodes, substitutes the placeholder in, and re-encodes — plus
  URL query params and (opt-in) identity-encoded request bodies. Git's
  smart-HTTP transport carries its credential in exactly that `Authorization:
  Basic` header on every request (both the `GET .../info/refs` and the `POST
  .../git-upload-pack` / `git-receive-pack`), and the credential does **not**
  ride the request body. The 0.6.9 engine does **not** rewrite non-identity
  (e.g. gzipped) bodies, HTTP/2 DATA-frame bodies, or fixed-length bodies larger
  than 16 MiB — it blocks a request rather than send a placeholder wrong — but
  git's gzipped pack-negotiation body carries no credential, so that limit does
  not gate the auth header. On paper, therefore, a git clone/push over
  intercepted HTTPS to a bound github host is **eligible** for header
  substitution in 0.6.9. This is the static reading of the 0.6.9 source
  (`crates/network/lib/secrets/handler.rs`, `.../config.rs`) and docs
  (`docs/security/secrets.mdx`); the 0.6.6→0.6.9 diff shows no change to the
  header/Basic-auth substitution path and nothing added or removed for
  git/smart-HTTP specifically. The runtime path was then live-confirmed on a
  KVM-capable host with `scripts/verify-git-https-secret-msb`: a private-repo
  `git ls-remote` succeeded using only the guest placeholder as the URL
  credential, proving msb intercepted the TLS connection and rewrote git's
  `Authorization: Basic` header without the real token entering the guest.

### `environment` vocabulary (guest env vars)

The neutral `hybrid/v1` spec originally modeled `caps.network.allow`, `files[]`,
`commands[]`, and `agentContext` — but had **no way to express guest environment
variables**. A downstream team (this PR's review, comment 5004158773) needs
`environment.variables`-style config (`OPENCODE_CONFIG`, `OPENCODE_TUI_CONFIG`,
`GITLAB_HOST`) as a first-class kit mechanism, and the two former sbx-v2 kits
that used env (`playbook-kit`, `openchamber`) had been re-expressing it as inline
`KEY=val \` prefixes on their startup commands — a workaround, not a vocabulary.

**Added:** a top-level `environment` block — a flat map of `NAME → value` (both
strings). The translate layer:

- **sbx:** synthesizes the native sbx-v2 `environment: { variables: { … } }`
  block (the mechanism the pre-Phase-2 kits used). sbx sets these in the guest
  environment natively; no `commands` workaround.
- **msb:** threads each `NAME=value` onto the kit's lifecycle commands as
  `msb exec -e NAME=value` (msb's native per-exec env flag, already used for
  `HOME=/home/agent`), scoping the env to the kit's own commands.

> **Update (2026-08-26):** The command-only scoping above dropped exactly the
> agent-runtime config (`OPENCODE_CONFIG`-style vars) this vocabulary was
> motivated by. The msb adapter now also persists the validated entries to a
> root-owned guest marker (`/var/lib/acq/kit-env`, the same pattern as
> `/var/lib/acq/agent` and `/var/lib/acq/ssh-auth-sock`) and replays them as
> `-e` flags on every session path (attach, `acq exec`, `acq shell`), matching
> sbx's sandbox-level env semantics. Names are re-validated on replay (tampered
> marker defense) and the last value wins for a duplicate name (kits append in
> application order, so a later kit overrides an earlier one).

Deliberately minimal (YAGNI): **static string values only** — no interpolation,
no references to `files[]`-staged paths (a kit needing a computed value uses a
`commands[]` step, as before). Env var **names** are validated against
`^[A-Za-z_][A-Za-z0-9_]*$` and an unsafe name is dropped with a warning (and
reported by `acq kit validate`), because a name reaches the guest environment and
possibly a shell. **Secrets do NOT go here** — they continue through the backend
credential/secret path (sbx proxy, msb `--secret ENV@HOST`), never the kit spec.

> **Cross-repo dependency (satisfied):** the authoritative `environment` schema
> property + the field-level validator live in the **patterns** repo
> (`schemas/kit-hybrid-v1.schema.json`, `validate-kits.py`, PR #227), and the
> playbook kit's REST-tarball fetch (the quickstart#203 fix) landed in
> patterns#269. Both are merged to patterns `main`, and `PATTERNS_KIT_REF`
> (`acq.backends/common.sh`) is pinned to `3fcde8e` (the #269 merge commit on
> `main`, which includes #227). The release gate is satisfied.

## Live verification (msb, on a KVM host)

Confirmed working end-to-end on a sandbox-capable host (msb 0.6.7) via
`scripts/verify-backends` (15/15) and an interactive `acq run opencode`:
`msb create` (with `--dns-nameserver`, `--tls-intercept`, `--trust-host-cas`,
each workspace mounted at its **own absolute host path**, `agent` user created
at a free uid with an agent-owned `/home/agent`), USAi key substitution (models
API returns a real status over intercepted TLS), the playbook fetched via the
REST tarball and linked, git-ssh-sign config, zscaler CA trust, and all kit
files/commands applied. The agent is launched with `msb exec -t` (PTY) as the
unprivileged `agent` user in the workspace. Several msb behaviors were
discovered and worked around here (recorded so they aren't re-litigated):
`msb create` returns 0 even on async start failure (→ exec-ready gate);
identical host:guest `/tmp` mounts silently fail (→ fixed guest mount point);
the host resolver is unreachable from the microVM (→ `--dns-nameserver`); the
kits assume an `agent`/`/home/agent` user a plain base lacks (→ create it);
secret substitution requires `--tls-intercept` and, per a static re-verification
against msb 0.6.9 plus live verification with
`scripts/verify-git-https-secret-msb`, rewrites HTTP request headers (including
the `Authorization: Basic` value git smart-HTTP uses). git-over-HTTPS auth to a
bound GitHub host is therefore live-confirmed for a private-repo `git ls-remote`
using only the guest placeholder.

## Validation

- `bash -n acq acq.backends/*.sh scripts/test-acq scripts/verify-backends` clean.
- `./scripts/test-acq` passes (incl. msb + kit + translation +
  untrusted-input-hardening cases, and the quickstart#228 regression cases:
  agent install, base-image contract — passwordless sudo + proxy `env_keep` —
  and attach-launches-agent-as-agent-user).
- Neutral→sbx-v2 synthesis for all four kits parses as valid YAML (verified with
  a YAML parser during development).
- `npm run lint` (markdownlint, shellcheck, gitleaks, YAML/JSON) — run in CI.
- **Deferred, requires a sandbox-capable host (no nested sandboxes):**
  the full `acq run … --backend msb` create→install→exec→attach loop and the
  `scripts/verify-backends` msb rows (now including the `opencode`-installed
  assertion added for quickstart#228) cannot run inside an sbx/msb sandbox and
  need host virtualization (`/dev/kvm` on Linux). The msb CLI flag shapes were
  verified against `msb 0.6.6`, and the git-HTTPS secret-substitution behavior
  was re-verified statically and live-confirmed with a private-repo
  `git ls-remote` against `msb 0.6.9`; the remaining live loop mirrors how
  ADR-0009/ADR-0010 defer live verification. Run `./scripts/verify-backends`
  on a sandbox-capable host and attach the transcript. **The quickstart#228 fix
  (agent install + attach launch) is verified offline via the stubbed harness;
  its live create→install→attach path still needs a KVM host run.**

## Release gate (satisfied)

- **`PATTERNS_KIT_REF` points at a merged, released SHA.** `common.sh` is pinned
  to the patterns **v1.7.0** release commit
  `9c277c09ed4ad45fd11709d6b048a58adc785443`, which includes Part A (the neutral
  acq-kits + schema, #221), the openchamber conversion (#224), and the
  `environment` vocabulary (#227 + the review follow-up #228). Pinning to a
  release tag mirrors Phase 1's v1.5.0 pin. The acq-kits and the kit-hybrid-v1
  schema (with `environment`) are present at this commit, and a live
  sparse-fetch + neutral→sbx-v2 translation of the kits was verified against the
  patterns kit tree.

## Links

- Design: `docs/explorations/acq-design.md` (long-form vision, §3–§7, §9)
- Handoff: `docs/explorations/acq-handoff-2.0.md` (Phase 2 scope; this is Part B)
- Related: [ADR-0010](0010-acq-pluggable-backends.md) (pluggable-backend seam;
  authoritative adapter contract), [ADR-0009](0009-require-sbx-0.35.0-in-place-kit-healing.md)
- Patterns Part A: `agentic-coding-patterns` neutral `acq-kits/` +
  `schemas/kit-hybrid-v1.schema.json` (PR #221)
- Deprecation timeline: `qsbx` frozen 1.1.0, removed 2.0.0 (Phase 4)
