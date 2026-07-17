# acq Phase 2 — Implementation Handoff

> **Audience:** the implementing agent (and its reviewer) for Phase 2 of the
> `acq` pluggable-backend effort.
> **Long-form vision:** `docs/explorations/acq-design.md` (read §2, §3, §4, §6,
> §7, and §9 before starting; the appendix records what Phase 1 actually
> shipped and where it deviated from the vision).
> **Status of this doc:** scoped, ordered work plan. Follow it top to bottom.
> Where this handoff and `acq-design.md` disagree, **this handoff wins** for
> Phase 2 scope — the design doc is the aspirational target and includes items
> deliberately deferred past Phase 2.

---

## 0. TL;DR

Phase 2 adds a **second isolation backend (`msb`, microsandbox)** to `acq`, and
to make that possible introduces the **neutral `hybrid/v1` kit spec** so the two
backends share one kit vocabulary. It is delivered in **two parts, in order,
across two repos**:

- **Part A — `agentic-coding-patterns`** (do first, one PR): author the neutral
  `hybrid/v1` kits under `integrations/isolation/kits/`, add the JSON schema and
  registry, leave the old `sbx-kits/` as a one-release redirect. **Output: a
  merge-commit SHA.**
- **Part B — `agentic-coding-quickstart`** (do second, pinned to Part A's SHA):
  add `acq.backends/msb.sh` + `acq.backends/kit-translate.sh`, convert the
  existing `sbx.sh` to consume the neutral kits, add `acq kit …` subcommands,
  wire msb into detection/doctor/list, add CI verification, docs, and an ADR.

**The gate between them is hard:** Part B pins `PATTERNS_KIT_REF` to the commit
Part A produces. Do not start Part B's kit-ref repoint until Part A is merged
and you have that SHA.

---

## 1. Where Phase 1 left things (context you can rely on)

Phase 1 shipped in **PR #201** (`feat(acq): add pluggable-backend acq wrapper
(sbx driver) and deprecate qsbx`). What exists today on `main`:

| File | Role |
|------|------|
| `acq` | Entry point. Pre-parses `--backend`, resolves+loads a backend adapter, dispatches subcommands (`run`, `create`, `ls`, `stop`, `rm`, `exec`, `cp`, `ports`, `secret set`, `usai-rotate-api-key`, `version`, `doctor`, `backend list|set`). Unknown subcommands pass through to the backend CLI. |
| `acq.backends/common.sh` | Backend-agnostic logic: kit constants (the **same four sbx kit refs** as qsbx, pinned via `PATTERNS_KIT_REF`), backend resolution (flag → `ACQ_BACKEND` → XDG config → auto-detect), `slugify`/`derive_name`/`workspace_path`, USAi key validation, SSH/git advisories, `acq doctor` output. |
| `acq.backends/sbx.sh` | The **only** backend adapter today. Implements the `acq_backend_*` contract against the `sbx` CLI, plus capability flags and in-place kit healing (`acq_backend_ensure_kits_applied`). |
| `scripts/test-acq` | Offline unit harness (42 checks). Stubs `sbx`; asserts resolution order, name derivation, dispatch routing, secret command shapes, qsbx deprecation notice. |
| `qsbx` | Deprecated (silenceable notice) but fully functional. **Removed in Phase 4, not Phase 2.** |
| `docs/BACKEND_GUIDE.md` | Per-backend guide. msb is documented as "planned for 1.2.0"; Phase 2 flips it to shipped. |
| `docs/QUICKSTART.md` | acq quickstart + qsbx migration. |
| `docs/adr/0010-acq-pluggable-backends.md` | The Phase 1 ADR. **Defines the authoritative adapter contract** — read it. |

### 1.1 The adapter contract (from ADR-0010 §"Adapter contract")

Every `acq.backends/<name>.sh` is **sourced** and MUST define these functions
plus four capability-flag variables. `msb.sh` must implement all of them.

| Function | Purpose |
|----------|---------|
| `acq_backend_prepare` | Check CLI installed + version floor; fail closed |
| `acq_backend_provision NAME AGENT PATHS...` | Create sandbox, apply kits |
| `acq_backend_run NAME -- CMD...` | Run command inside; return exit status |
| `acq_backend_attach NAME [-- AGENT_ARGS...]` | Interactive attach (TTY) |
| `acq_backend_exists NAME` | 0 if sandbox exists, else 1 |
| `acq_backend_stop NAME` | Stop without removing |
| `acq_backend_terminate NAME` | Permanently remove |
| `acq_backend_cp SRC DST` | Copy in/out (NAME:path syntax) |
| `acq_backend_ports NAME [args...]` | List/publish ports |
| `acq_backend_list` | List sandboxes |
| `acq_backend_apply_kit NAME KITREF` | Apply a kit mid-life |
| `acq_backend_ensure_kits_applied NAME` | Heal a sandbox missing kits (used by `acq run` re-attach path) |
| `acq_backend_secret_set SERVICE [args...]` | Secret wrapper |
| `acq_backend_version` | Echo backend version string |
| `acq_backend_doctor` | Echo one matrix row for `acq doctor` |

Capability flags (declared at top of the adapter):
`ACQ_BACKEND_NAME`, `ACQ_BACKEND_SUPPORTS_PORT_FORWARD`,
`ACQ_BACKEND_SUPPORTS_SNAPSHOTS`, `ACQ_BACKEND_CAN_RESUME`,
`ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE`.

> The `acq` entry point calls `acq_backend_ensure_kits_applied` in the run
> re-attach path (`acq:223` and `acq:249`). `sbx.sh` implements it even though
> it is not in the ADR-0010 table verbatim — treat it as **part of the contract
> msb must satisfy** (it may be a no-op-with-warning if msb cannot heal in place;
> see §4.3).

---

## 2. Phase 2 scope (what "done" means)

### In scope

1. **Part A (patterns):** four `hybrid/v1` kits + schema + registry + redirect +
   patterns ADR.
2. **Part B (quickstart):**
   - `acq.backends/kit-translate.sh` — reads a neutral `spec.yaml`, emits the
     active backend's native primitives.
   - `acq.backends/msb.sh` — the microsandbox adapter (full contract).
   - `sbx.sh` + `common.sh` — converted to consume the neutral `kits/` from the
     new patterns SHA (repoint `PATTERNS_KIT_REF` + `PATTERNS_KIT_DIR`).
   - `_auto_detect_backend` gains an `msb` branch; `acq backend list` and
     `acq doctor` show a real msb row (today both hardcode "coming in 1.2.x").
   - `acq kit apply|list|validate` subcommands (design §2; deferred in Phase 1,
     see appendix deviation #4).
   - `scripts/verify-backends` (design §9) + new msb cases in `scripts/test-acq`.
   - Docs: flip `BACKEND_GUIDE.md` msb → shipped; update `QUICKSTART.md`; new
     quickstart **ADR-0011** (see §5).

### Out of scope (do NOT do these in Phase 2)

- **`ppp` backend** — that is Phase 3 (deferred/undecided).
- **Removing `qsbx`** — that is Phase 4 (2.0.0). Leave `qsbx`,
  `scripts/test-migrate-or-halt`, and `scripts/verify-migrate-live` in place.
- **Full unified swap-on-access secret model** (design §7.5) — implement only as
  much credential handling as msb needs to reach a 200 from the USAi models API.
  Keep `acq secret set` behavior otherwise as-is (thin per-backend wrapper).
- **New kits** beyond the existing four.
- **Removing `docs/QUICKSTART_SBX.md`** — deferred to Phase 4 (appendix
  deviation #7). Keep it; just cross-link.
- **Go/Python port** of `acq` — stays bash (ADR-0010).

---

## 3. Part A — `agentic-coding-patterns` (do first, one PR)

> Repo: `https://github.com/GSA-TTS/agentic-coding-patterns`. This repo is **not**
> checked out in the quickstart workspace — you will need it cloned/available.
> The current pinned commit the quickstart uses is
> `d2a379ff7cdff611d6d623a1ce7b21e543f76ea8` (patterns v1.5.0); the four kits
> live under `integrations/isolation/sbx-kits/{usai-provider-kit,playbook-kit,zscaler-ca-certificate,git-ssh-sign}`
> as `schemaVersion: "2"` sbx mixin specs today.

### A.1 Add the schema

Create `schemas/kit-hybrid-v1.schema.json` — a JSON Schema for the neutral spec
described in `acq-design.md §3`. Keep it **minimal**. It must validate:

- `schemaVersion: "hybrid/v1"`, `kind: mixin`, `name`, `displayName`,
  `description`.
- `caps.network.allow: [string]` (hostnames).
- `files[]`: `{ path (absolute), mode, content }`.
- `commands[]`: `{ phase: install|initFiles|startup, user, description, command: [string] }`.
- `agentContext: string`.
- `backend_shortcuts: { <backend>: {...} }` — keys must be known backends
  (`sbx`, `msb`, `ppp`).
- `backend_extras: { <backend>: {...} }` — free-form per backend.

### A.2 Create `integrations/isolation/kits/` with four converted kits

Convert each existing sbx kit to `hybrid/v1`. Preserve the existing `files/`
payloads verbatim (the `opencode.jsonc`, `merge-global-config.mjs`,
`ssh-signing-key-command`, and the embedded Zscaler PEM). Each kit dir:
`spec.yaml` + `files/` + `README.md` (with a **parity note**) +
`TROUBLESHOOTING.md` + `docs/decisions/` + `scripts/verify`.

Map the current sbx v2 semantics into neutral phases (design §3 lifecycle table):

- **`usai-provider`** — `caps.network.allow: [api.gsa.usai.gov]`; `files` for
  the two staged files; `commands` phase `startup` (user `1000`) running the
  merge script. `agentContext`: "USAi is your provider." No shortcuts.
  - Note the existing sbx kit uses `commands.startup` with `command:` as argv —
    carry that argv form into the neutral `command: [..]`.
- **`agentic-coding-playbook`** — `caps.network.allow: [github.com]` (+ any raw
  content host actually used); `commands` phase `startup` (agent user) doing the
  gated `git clone` + symlinks. Per design §6, extract the inline shell into a
  tested `files/home/playbook-clone.sh`. `agentContext`: playbook skills note.
- **`zscaler-ca-certificate`** — the current kit uses `initFiles` (stage cert in
  agent home) + `startup` (user `0`, `install` + `update-ca-certificates`).
  Carry both into neutral `commands` phases (`initFiles`, `startup`). **Add the
  msb backend shortcut:**
  ```yaml
  backend_shortcuts:
    msb:
      trust_host_cas: true
  ```
  Parity note in README: "msb uses `--trust-host-cas`; sbx (and ppp later) use
  the file-drop + `update-ca-certificates` mechanism. Guest ends up trusting the
  Zscaler CA either way."
- **`git-ssh-sign`** — `commands` phase `install` (user `0`) for the git system
  config; `files` phase `initFiles` (mode `0755`) for `ssh-signing-key-command`.
  No shortcut; SSH-agent forwarding is the common mechanism (msb uses
  `msb ssh authorize` + agent forwarding — documented, not a spec shortcut).

### A.3 Registry `integrations/isolation/kits.yaml`

Human-readable parity summary keyed by kit name → `backends` list + `parity`
prose. Use the four `parity` blocks in `acq-design.md §6` as the source text.
For Phase 2, list `backends: [sbx, msb]` (ppp arrives in Phase 3).

### A.4 Redirect the old home

Leave `integrations/isolation/sbx-kits/` in place for one release; replace its
`README.md` with a redirect pointing to `kits/`. Do not delete the old kit
contents yet (v3/Phase-4 cleanup).

### A.5 Patterns ADR

Add the patterns-repo ADR (design §12 calls it "ADR-0009" in the patterns repo —
**verify the next free ADR number in that repo and use it**; the "0009" in the
design doc is illustrative). Record: why the neutral spec, the four kits' new
shape, the msb `--trust-host-cas` shortcut for zscaler, the registry, the
one-release redirect.

### A.6 Part A verification

- JSON-schema-validate all four `spec.yaml` against `kit-hybrid-v1.schema.json`.
- Run each kit's `scripts/verify`.
- Repo's existing lint/CI green.
- **Record the merge-commit SHA. Part B needs it.**

---

## 4. Part B — `agentic-coding-quickstart` (do second, pin to Part A SHA)

> This is the repo you are in. Branch from `main`. Conventional-commit PR title
> (e.g. `feat(acq): add msb backend and neutral hybrid/v1 kit translation`).

### 4.1 Repoint the kit ref (the gate)

In `acq.backends/common.sh`, update:
- `PATTERNS_KIT_REF` → the SHA Part A produced.
- `PATTERNS_KIT_DIR` → `integrations/isolation/kits` (was `.../sbx-kits`).
- The four `*_KIT` refs → new dir names (`usai-provider`,
  `agentic-coding-playbook`, `zscaler-ca-certificate`, `git-ssh-sign` — note the
  playbook/usai dir names change from the `-kit` suffix; match Part A's actual
  dir names).

> **Do not** invent a SHA. If Part A is not yet merged, stop and report — this
> is a hard dependency (fail closed on ambiguity per AGENTS.md).

### 4.2 `acq.backends/kit-translate.sh`

New module, sourced by `common.sh`. Given a neutral `spec.yaml` and the active
backend name, produce that backend's native operations. Keep the real
per-backend work inside each adapter; this module is the shared parser +
shortcut/extras dispatcher (design §5 describes it as "small"). Responsibilities:

- Parse `spec.yaml` (no new runtime deps — the repo already uses `awk`/`jq`
  patterns; if you must add `yq`, that requires an ADR + approval per AGENTS.md
  — prefer avoiding it).
- Check `backend_shortcuts.<backend>` first; if present, signal the adapter to
  skip `caps`/`files`/`commands` for that kit.
- Otherwise expose the neutral `caps.network.allow`, `files[]`, `commands[]`,
  `agentContext` to the adapter in a consumable form.

### 4.3 `acq.backends/msb.sh`

Implement the full contract from §1.1 against the microsandbox CLI. Concrete
hookups (design §7 "Concrete adapter hookups" and §4 per-kit tables):

| Contract fn | msb implementation |
|-------------|--------------------|
| `acq_backend_prepare` | `msb --version` / `msb doctor`; fail closed with install hint if missing |
| `acq_backend_provision` | `msb create` with `--net-rule "allow@domain:HOST"` from each kit's `caps.network.allow`; `--trust-host-cas` when the zscaler shortcut is active; post-create `msb exec --user 0` for `install`-phase commands (idempotent, marker-gated); `msb exec` to drop `files` + run `initFiles`/`startup` |
| `acq_backend_run` | `msb exec NAME -- CMD...` |
| `acq_backend_attach` | `msb ssh NAME` (TTY) |
| `acq_backend_exists` | query `msb`'s sandbox list |
| `acq_backend_stop` / `terminate` | `msb stop` / `msb rm` |
| `acq_backend_cp` / `ports` | msb file-copy / `-p HOST:GUEST` |
| `acq_backend_list` | `msb`'s list |
| `acq_backend_apply_kit` | translate kit → `msb exec` command sequence |
| `acq_backend_ensure_kits_applied` | best-effort heal; if msb has no in-place add, print a warning + `acq rm && acq run` hint (do NOT silently destroy state) |
| `acq_backend_secret_set` | minimal: get the USAi key to the sandbox via msb's native secret/`--tls-intercept` path so the models API returns 200 |
| `acq_backend_version` / `doctor` | `msb` version string / one matrix row |

Capability flags: `ACQ_BACKEND_NAME="msb"`,
`SUPPORTS_PORT_FORWARD=1`, `SUPPORTS_SNAPSHOTS=1`, `CAN_RESUME=1`,
`SUPPORTS_CREDENTIAL_REWRITE=1` (per design §7 flag table; adjust to what msb
actually supports and note any gap).

> The exact `msb` subcommand/flag names must be **verified against the installed
> msb CLI** — the design doc's flags (`--net-rule`, `--trust-host-cas`,
> `--tls-intercept`, `msb ssh authorize`) are the intended shape but treat them
> as hypotheses until confirmed. If a flag differs, follow the real CLI and note
> the deviation in the ADR.

### 4.4 Convert `sbx.sh` to neutral kits

Today `sbx.sh` consumes the four sbx-v2 kit refs directly (`--kit <ref>`). After
Part A, the kits are `hybrid/v1`. Route sbx kit application through
`kit-translate.sh` so both backends share the vocabulary. Preserve existing sbx
behavior (in-place `sbx kit add` healing, `kit.allowedSources` allowlist
management, exec-ready polling). The observable result for an sbx user must be
identical to Phase 1.

### 4.5 Wire msb into detection/list/doctor

- `common.sh:_auto_detect_backend` — add an `msb` branch after the `sbx` check.
- `acq` `backend list` (currently prints `msb (not found)` / "Coming in 1.2.x")
  — show real detection.
- `common.sh:acq_print_doctor` — replace the hardcoded
  `msb_status="not found (coming in 1.2.x)"` with a real probe.

### 4.6 `acq kit` subcommands

Add to the `acq` dispatch: `kit list` (show the pinned kits), `kit validate
PATH` (schema-validate a neutral spec), `kit apply NAME KITREF` (call
`acq_backend_apply_kit`). See design §2 command table.

### 4.7 CI + tests

- `scripts/verify-backends` (design §9): for each **installed** backend, create a
  tiny sandbox, assert the four kits apply cleanly, USAi key round-trips to 200
  from a throwaway/mock, git signing works, playbook symlink appears. Skip a
  backend's row if it is not installed.
- Extend `scripts/test-acq`: msb in resolution order, msb dispatch routing, msb
  doctor/list output, `acq kit` command shapes. Stub `msb` the way `sbx` is
  stubbed. Keep the harness offline.

### 4.8 Docs + ADR

- `docs/BACKEND_GUIDE.md` — move msb from "planned" to shipped; fill the
  capability table with real values; keep ppp as deferred.
- `docs/QUICKSTART.md` — add the "choose a backend" step (design §5 README
  sketch) and msb install line.
- New **`docs/adr/0011-msb-backend-and-neutral-kits.md`** (0010 is the last used
  number — confirm with `ls docs/adr/`). Record: the neutral `hybrid/v1`
  adoption, the msb adapter, the sbx-conversion, the patterns SHA pin, any msb
  CLI deviations from the design, and what stayed deferred (ppp, qsbx removal,
  full swap-on-access).

---

## 5. Known-drift callouts (do not re-introduce these)

The Phase 1 appendix in `acq-design.md` records deviations from the design doc.
Respect them so you do not fight the shipped code:

1. **Config path is XDG**, not `~/.acq/`:
   `${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml`. State →
   `${XDG_DATA_HOME:-$HOME/.local/share}/acq/`.
2. **ADR numbering is offset.** Design says quickstart "ADR-0008" and patterns
   "ADR-0009"; reality is quickstart **0010** (Phase 1) and **0011** (this
   phase). In patterns, verify the next free number.
3. **`sbx secret set-custom` has no `--password-stdin`.** Secrets are piped via
   stdin. Don't reintroduce the flag.
4. **`acq secret set` requires an explicit scope** (`-g` or a sandbox name) — no
   silent global default.
5. **Adapter is bash**, mirroring the ABC in design §7 by convention. `msb.sh`
   follows `sbx.sh`'s shape, not a Python class.

---

## 6. Dangling reference to fix (housekeeping)

The Phase 1 handoff doc `docs/explorations/acq-handoff-1.1.md` was **lost** but
is still referenced by three files:

- `acq.backends/sbx.sh:5` — `# Implements the adapter contract defined in docs/explorations/acq-handoff-1.1.md §5.`
- `docs/BACKEND_GUIDE.md:155` — "implementing the contract in `docs/explorations/acq-handoff-1.1.md §5`".
- `docs/adr/0010-acq-pluggable-backends.md:136` — `- Handoff: docs/explorations/acq-handoff-1.1.md (this implementation scope)`.

The authoritative contract now lives in **ADR-0010 §"Adapter contract"**.
Repoint these three references to `docs/adr/0010-acq-pluggable-backends.md`
(§"Adapter contract") rather than the missing file. Do this as part of Part B
(it is a one-line touch in each and keeps the docs honest).

---

## 7. Verification checklist (Part B, before opening the PR)

- [ ] `bash -n acq acq.backends/*.sh scripts/test-acq scripts/verify-backends` clean.
- [ ] `./scripts/test-acq` passes (all checks, including new msb cases).
- [ ] `npm run lint` (markdownlint, shellcheck, gitleaks, YAML/JSON) clean.
- [ ] `PATTERNS_KIT_REF` points at a real, merged Part A SHA (not a placeholder).
- [ ] `acq doctor`, `acq backend list`, `acq version` show msb correctly.
- [ ] sbx path still behaves identically to Phase 1 (regression).
- [ ] Deviations from the design doc recorded in ADR-0011 **and** appended to the
      `acq-design.md` appendix (add a "What is implemented (Phase 2 / 1.2.0)"
      subsection + any new deviations — mirror the Phase 1 appendix format).
- [ ] **Live end-to-end note:** like ADR-0010's validation, full
      `acq run … --backend msb` cannot run inside an sbx sandbox (no nested
      sandboxes). Document this the way ADR-0009/0010 document deferred live
      verification; run it on a sandbox-capable host if available and capture the
      transcript.

---

## 8. PR discipline (per AGENTS.md)

- Two PRs (patterns Part A, then quickstart Part B), each with Context / Plan /
  Verification transcript / Rollback / Security impact.
- Conventional-commit PR titles (squash-merge; the title becomes the release
  commit). `feat(acq): …` for Part B; match the patterns repo's convention for
  Part A.
- PR-level "AI-assisted" disclosure. `Co-authored-by:` trailer optional.
- Do not remove `qsbx` or its migration tests — that is Phase 4.
- Fail closed on ambiguity (missing Part A SHA, unknown msb flag) — stop and ask
  rather than guessing.
