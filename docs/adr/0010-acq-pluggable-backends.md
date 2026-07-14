---
title: "Introduce acq Pluggable-Backend Wrapper and Deprecate qsbx"
status: accepted
date: 2026-07-14
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SA-17"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0010: Introduce acq Pluggable-Backend Wrapper and Deprecate qsbx

## Context and Problem Statement

`qsbx` is the current wrapper around the `sbx` CLI. It provides sandbox
create/attach, kit application, USAi key validation, and advisories. It works
well but has two structural limitations:

1. **It is `sbx`-only.** The shape of the CLI is baked into `qsbx` — there is
   no seam where a different isolation runtime (e.g. microsandbox, Podman) can
   be substituted without rewriting the wrapper.
2. **Its name encodes the backend.** `qsbx` makes the implementation detail
   visible in every documented command and in users' muscle memory.

A second backend (`msb` — microsandbox) is planned for 1.2.0. Before it ships,
the architecture needs a formal adapter seam so adding `msb.sh` is purely
additive and does not require editing the core dispatch.

## Decision Drivers

- **Additive, non-breaking.** 1.1.0 adds `acq` without changing or
  removing `qsbx`. `qsbx` remains fully functional until 2.0.0.
- **Bash + adapter directory.** Matches the existing `qsbx` tech stack; proven
  code moves verbatim (no rewrite). A Go/Python port is a possible future
  (noted in the design doc), not now.
- **XDG config.** The config file belongs at
  `${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml` — consistent with
  OpenCode (`~/.config/opencode/`) and other tooling in this ecosystem. The
  design doc drafts `~/.acq/` but this ADR corrects it.
- **Minimal footprint.** No new runtime dependencies. Config parsed with
  `awk`/`grep` (one key). Kit constants are copied from `qsbx` for 1.1.x and
  diverge only when 1.2.x introduces neutral kits.

## Considered Options

1. **Add `acq` (sbx driver) alongside `qsbx`, deprecate `qsbx`.** Chosen.
2. **Refactor `qsbx` in place** to support backends via an env var. Rejected:
   changes `qsbx` behavior, entangles the deprecation story, harder to test.
3. **Skip the wrapper entirely and document raw sbx.** Rejected: loses the
   kit application, USAi key validation, and advisory logic that users depend on.

## Decision Outcome

**Chosen: Option 1.**

- New file `acq` (bash, `chmod +x`). Sources `acq.backends/common.sh`
  (backend-agnostic logic, resolution, shared utilities) and dispatches through
  `acq_backend_*` functions defined by the active backend adapter
  (`acq.backends/sbx.sh` for 1.1.x).
- `acq` is the recommended entry point from 1.1.0 onward.
- `qsbx` gains a one-line stderr deprecation notice (silenceable via
  `QSBX_SILENCE_DEPRECATION=1`) but is otherwise unchanged.
- `qsbx` will be removed in 2.0.0.

### Adapter contract (backend `acq.backends/*.sh` files)

Each backend file is sourced and must define the following functions plus four
capability flag variables:

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
| `acq_backend_secret_set SERVICE [args...]` | Thin secret wrapper |
| `acq_backend_version` | Echo backend version string |
| `acq_backend_doctor` | Echo one matrix row for `acq doctor` output |

Capability flags (`ACQ_BACKEND_SUPPORTS_PORT_FORWARD`, etc.) allow `common.sh`
to gate features and future backends to declare gaps.

### Backend resolution order

1. `--backend <name>` flag
2. `ACQ_BACKEND` env var
3. `backend:` key in `${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml`
4. Auto-detect: first installed backend (`sbx version`)

### XDG config path correction

The design document (`docs/explorations/acq-design.md`) used `~/.acq/…` as
the config path. **This ADR corrects it to
`${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml`** (XDG Base Directory
standard). Future state data lives at
`${XDG_DATA_HOME:-$HOME/.local/share}/acq/`. The design doc's own
`secrets.age` fallback already assumed `$XDG_DATA_HOME`, so this is a
correction, not a change.

## Consequences

- **Better:** users have a stable, backend-agnostic CLI. Adding `msb` in 1.2.0
  is purely additive (one new `acq.backends/msb.sh`).
- **Tradeoff (temporary):** two entry points exist during 1.1.x–1.x lifecycle.
  Mitigated by the deprecation notice and docs update.
- **Compliance:** no change to attack surface, no new external services,
  no data classification change (CM-2/CM-3/CM-6). The adapter seam is a
  structural improvement (SA-8/SA-15/SA-17).
- **Testing:** offline unit harness `scripts/test-acq` covers backend
  resolution, dispatch routing, secret command shapes, kit list completeness,
  and the qsbx deprecation notice.

## Validation

- `bash -n acq acq.backends/*.sh scripts/test-acq` clean.
- `./scripts/test-acq` passes (42 of 42 checks).
- `npm run lint` (markdownlint, shellcheck, gitleaks, YAML/JSON) clean.
- **Deferred, requires a sandbox-capable host on sbx 0.35.0+:**
  `acq run opencode <path>` end-to-end cannot run inside an sbx sandbox
  (no nested sandboxes). Document in the PR — mirror how ADR-0009 defers
  `./scripts/verify-migrate-live`.

## Links

- Design: `docs/explorations/acq-design.md` (long-form vision)
- Handoff: `docs/explorations/acq-handoff-1.1.md` (this implementation scope)
- Deprecation timeline: `qsbx` frozen 1.1.0, removed 2.0.0
- Related: [ADR-0009](0009-require-sbx-0.35.0-in-place-kit-healing.md) (sbx version floor)
