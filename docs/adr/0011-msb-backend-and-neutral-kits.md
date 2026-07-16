---
title: "Add msb (microsandbox) Backend and Neutral hybrid/v1 Kit Translation"
status: accepted
date: 2026-07-15
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SA-17", "SC-7", "SC-8", "SC-28"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0011: Add msb (microsandbox) Backend and Neutral hybrid/v1 Kit Translation

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
    `files[]`, `commands[]`, `agentContext`, `backend_shortcuts`);
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
  and the GitHub token → `--secret GITHUB_TOKEN@github.com`/`@api.github.com`,
  read from the acq secret store at provision into a transient env var (never
  argv, never the kit spec; the real value never enters the guest). Unlike sbx
  (whose
  templates supply the image), msb runs a plain OCI image: the default is the
  public `node:22-bookworm` (built on buildpack-deps, so it already ships
  node/git/curl/ca-certificates — the four kits' prerequisites — and pulls
  without registry auth). The adapter VERIFIES those tools are present and warns
  if a custom `ACQ_MSB_IMAGE` lacks them; it deliberately does NOT install them
  at runtime because the kit net-rules lock egress to the kits' own hosts, so a
  package mirror is unreachable during provision.

- **sbx-v2 command typing (translation):** sbx types `commands.install[].command`
  as a shell **string** but `commands.startup[]`/`initFiles[]` as an argv
  **sequence**. The synthesizer emits per-phase accordingly (install → block
  string, startup/initFiles → argv seq); mismatching yields sbx's "cannot
  unmarshal !!seq into string" / "!!str into []string".

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

### msb CLI flag verification

The msb flag/subcommand shapes used by the adapter were **verified against
`msb 0.6.6`** (`superradcompany/microsandbox` v0.6.6, linux/aarch64) via
`msb --tree` and per-command `--help`: `create --name --net-rule
allow@HOST --trust-host-cas --tls-intercept --secret ENV@HOST --volume`,
`exec [-u USER] -- CMD`, `list -q`, `stop`, `remove -f`, `copy`, `ssh`,
`ssh authorize`, `-p HOST:GUEST`, `doctor`.

## Consequences

- **Better:** one neutral kit vocabulary; msb reuses the same four kits; adding
  `ppp` (Phase 3) is again additive. Kit authoring is backend-agnostic.
- **Tradeoff:** the sbx path gained a translation step. Mitigated by carrying
  payloads verbatim and asserting the synthesized sbx-v2 output in `test-acq`;
  the observable sbx result is unchanged.
- **Compliance:** no new external services; the msb secret path keeps the real
  key out of the guest (SC-8/SC-28); network egress is allow-listed per kit
  (SC-7). Structural adapter change only (SA-8/SA-15/SA-17; CM-2/CM-3/CM-6).

## Validation

- `bash -n acq acq.backends/*.sh scripts/test-acq scripts/verify-backends` clean.
- `./scripts/test-acq` passes (79 checks, incl. msb + kit + translation cases).
- Neutral→sbx-v2 synthesis for all four kits parses as valid YAML (verified with
  a YAML parser during development).
- `npm run lint` (markdownlint, shellcheck, gitleaks, YAML/JSON) — run in CI.
- **Deferred, requires a sandbox-capable host (no nested sandboxes):**
  the full `acq run … --backend msb` create→exec→attach loop and the
  `scripts/verify-backends` msb row cannot run inside an sbx/msb sandbox and need
  host virtualization (`/dev/kvm` on Linux). The msb CLI flag shapes were
  verified against `msb 0.6.6`; the live loop is deferred and mirrors how
  ADR-0009/ADR-0010 defer live verification. Run `./scripts/verify-backends`
  on a sandbox-capable host and attach the transcript.

## Release gate (do not undraft until satisfied)

- **`PATTERNS_KIT_REF` must point at a real, merged Part A SHA** — it is
  currently a **provisional** pin at the `#221` PR head
  (`cd72ac27c368f51c3cb2044f609e71a10c90d6ab`, pre-merge) with a `TODO` in
  `common.sh`. Flip it to the Part A merge-commit SHA before undrafting.

## Links

- Design: `docs/explorations/acq-design.md` (long-form vision, §3–§7, §9)
- Handoff: `docs/explorations/acq-handoff-2.0.md` (Phase 2 scope; this is Part B)
- Related: [ADR-0010](0010-acq-pluggable-backends.md) (pluggable-backend seam;
  authoritative adapter contract), [ADR-0009](0009-require-sbx-0.35.0-in-place-kit-healing.md)
- Patterns Part A: `agentic-coding-patterns` neutral `acq-kits/` +
  `schemas/kit-hybrid-v1.schema.json` (PR #221)
- Deprecation timeline: `qsbx` frozen 1.1.0, removed 2.0.0 (Phase 4)
