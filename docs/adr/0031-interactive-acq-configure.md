---
title: "Interactive `acq configure` for extra kits and token-scoping defaults"
status: accepted
date: 2026-09-20
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["AC-6", "CM-6", "IA-5", "SA-15", "SR-3"]
impact_level: low
ato_relevance: no
risk_treatment: n/a
supersedes: []
---

# ADR-0031: Interactive `acq configure` for extra kits and token-scoping defaults

## Context and Problem Statement

`acq` always applies four built-in kits (`zscaler-ca-certificate`,
`usai-provider`, `agentic-coding-playbook`, `git-ssh-sign`). The only levers for
**opt-in** kits are `--kit <ref>` on `run`/`create` and the `ACQ_EXTRA_KITS` env
var — both must be re-supplied on every invocation and neither is discoverable.
A new user has no way to learn that opt-in community kits (`openchamber`,
`paseo`) exist, and no way to enable one durably. Separately, per-sandbox GitHub
token scoping (ADR-0013) surfaces only as a bare `[y/N]` nudge inside the run
flow, with no persisted default.

How should a user discover and durably configure opt-in kits and their
token-scoping default, without adding a heavyweight TUI dependency and without
changing the security model?

## Decision Drivers

- **Discoverability** — the opt-in kit catalog should be visible and
  self-documenting, not tribal knowledge.
- **Durability** — a choice should persist across invocations rather than being
  re-typed each run.
- **Right granularity** — a global default plus per-sandbox deviations matches
  real usage (set once; override for the odd sandbox).
- **Supply-chain minimalism (SR-3)** — the repo posture is "one clone, no extra
  deps"; a cosmetic picker must not pin `gum`/`fzf`/`whiptail`.
- **Least privilege (AC-6, IA-5)** — the token-scoping default must not weaken
  ADR-0013: it sets only the *default answer* to the existing per-sandbox
  scoping prompt; fine-grained-PAT minting stays per-sandbox.
- **Fail-open in CI (SA-15)** — non-interactive/piped runs must behave exactly
  as they do today (take defaults, never block).

## Considered Options

1. **Status quo** — keep `--kit`/`ACQ_EXTRA_KITS` only. Zero work, but leaves the
   discoverability and durability gaps unaddressed.
2. **A pinned TUI dependency** (`gum`/`fzf`/`whiptail`/`dialog`) driving a rich
   selector. Nicer out of the box, but adds a CVE-scanned, license-checked host
   dependency for purely cosmetic output — contrary to the onboarding this repo
   exists to provide, and inconsistent with the `progress.sh` design note.
3. **Hand-rolled interactive picker + `acq configure` + `config.yaml`
   persistence** (chosen). A ~40-line bash multiselect modeled on the existing
   `progress.sh`/`install.sh` conventions, a new `acq configure` command, global
   defaults in the file that already holds `backend:`, and per-sandbox deviations
   reusing the existing per-sandbox kit records.

## Decision Outcome

Chosen: **option 3**.

- **New `acq.backends/prompt.sh`** — `acq_prompt_multiselect` and
  `acq_prompt_confirm`. Stderr-only chrome, gated on an interactive TTY
  (`[ -t 0 ]` for input, `[ -t 2 ]` for stderr color), colored with the same
  `install.sh` SGR scheme, bash-3.2 safe, caller labels escape-sanitized (as in
  `progress.sh`). Honors an `ACQ_NO_PROMPT` opt-out and an `ACQ_PROMPT_TEST_INPUT`
  test hook (mirroring `ACQ_SECRET_TEST_VALUE`). Non-TTY / opted-out degrades to
  documented defaults and never blocks.
- **Opt-in kit catalog** — sourced from the already-pinned patterns bundle
  (`PATTERNS_KIT_REF` / `PATTERNS_KIT_DIR`, `integrations/isolation/acq-kits/`):
  `openchamber`, `paseo`. `prime-agent` is a skeleton at the current pin and is
  intentionally omitted until functional. Custom refs remain available through
  `ACQ_EXTRA_KITS` and `--kit`, but are not stored in durable config. The four
  built-ins are shown **inline as frozen rows** at the top of the same picker —
  always checked, dimmed, tagged
  "(always applied)", cursor-skipped, and never toggleable — rather than in a
  separate banner, so the full applied set reads as one list.
- **`acq configure` command** — shows current config, runs the multiselect over
  the opt-in catalog, then a confirm for the token-scoping default, and writes
  the result to `config.yaml`. Auto-offered once on first run (no `config.yaml`
  yet AND interactive), writing a minimal config so it never nags again.
- **Config schema** — `config.yaml` gains flat keys `extra_kits:` and
  `scope_github_token:` alongside the existing `backend:`. The single-key awk
  parser is generalized to read/write named flat keys, preserving the existing
  `backend:` line and the "no YAML dependency" convention. The config directory
  and file are written private to the user, and the flat-key reader ignores
  indented/nested YAML so hand-edited structure is not mistaken for a top-level
  setting.
- **`acq create`/`run`** — pre-populate the picker from the global defaults, fold
  the selection into the existing `ACQ_EXTRA_KITS`/`ACQ_CLI_KITS` path (so it
  flows through `_build_kit_list` → `acq_cli_kits_write`), and thereby persist
  per-sandbox deviations in the existing per-sandbox kit record (ADR-0017),
  reloaded on resume by `acq_cli_kits_load`.
- **Token-scoping default** — the stored preference only pre-answers the existing
  `advise_github_scope` prompt; `github_scope_sandbox` still mints a fine-grained
  PAT scoped to the sandbox's repos (ADR-0013 unchanged).

## Consequences

**Positive**

- Opt-in kits become discoverable and durable; onboarding improves with no new
  dependency.
- Global-default + per-sandbox-deviation granularity is achieved by reusing
  existing config and per-sandbox record mechanisms — minimal new surface.
- CI/non-interactive behavior is unchanged (fail-open by construction).

**Negative / trade-offs**

- A hand-rolled multiselect is less capable than a real TUI library (no mouse,
  simple key handling). Accepted per the minimalism driver.
- `config.yaml` now carries more than one key; the awk parser is generalized but
  remains a deliberately small, flat-only reader.

**Compliance implications**

- **AC-6 / IA-5 (least privilege, credentials):** the token-scoping preference is
  a UI default only; no broadening of token scope. ADR-0013's per-sandbox
  fine-grained PAT flow is authoritative.
- **SR-3 (supply chain):** no new runtime dependency is introduced.
- **SA-15 (development process):** covered by new offline bats tests driving the
  prompt via `ACQ_PROMPT_TEST_INPUT` and asserting `config.yaml` round-trips and
  non-TTY defaulting.

## Links / tracking

- Implements GSA-TTS/agentic-coding-quickstart#499.
- Builds on ADR-0013 (per-sandbox GitHub token downscoping), ADR-0017 (msb
  create-time startup + persisted CLI/extra kit refs), ADR-0010/0011 (pluggable
  backends and neutral kits).
- Complementary to, and distinct from, the per-repo `.acq/` config proposal in
  GSA-TTS/agentic-coding-quickstart#232 (repo-committed config vs. user-global
  config).
