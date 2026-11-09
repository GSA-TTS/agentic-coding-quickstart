---
title: "Legacy Bash/Bats test-suite classification inventory"
status: current
date: 2026-11-03
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["SA-11", "CA-2", "CA-7", "SI-2"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
related_adrs: ["0038m", "0039m", "0040m", "0041m", "0042m", "0043m", "0044m"]
related_files: ["test/vectors/manifest.json", "test/vectors/README.md", "test/bats/*.bats", "docs/spec/acq-v1.md"]
---

# Legacy Bash/Bats test-suite classification inventory

> AI-assisted; owner: Bret Mogilefsky.
>
> This document is the **classification slice** of the acq v1 rewrite. It
> classifies every legacy Bash/Bats test into the ADR-0039m retirement buckets
> and maps each to a language-neutral vector or a retirement decision. It
> classifies and commits a mapping only — it does **not** bulk-port or
> bulk-delete tests (ADR-0039m: "No bulk port or delete").

## Purpose and scope

The legacy suite is `test/bats/*.bats` plus its stub library
(`scripts/test-acq-lib.sh`) and host-side verifiers. It mixes three assertion
shapes that ADR-0039m deliberately separates:

1. **Subprocess CLI assertions** — the only shape that can prove a contract
   oracle ("driving the shipped CLI as a subprocess").
2. **In-process sourcing of Bash internals** — implementation detail, never
   contract evidence.
3. **Source-regex checks** over installer/script text — implementation detail.

This inventory names every file (and, where a file is mixed, its notable
blocks) against three buckets. It is **not** a port plan: retiring a test
happens only when the rewrite reaches the behavior it asserts
("retire-on-touch"), and each retirement cites the contract row it
contradicts or the vector that supersedes it.

## Buckets

| Bucket | Meaning | Maps to |
|---|---|---|
| **preserve** | Valuable **contract** behavior (documented command/flag, exit class, required-data field, precedence rule, security guarantee, migration) that must survive the rewrite. | Re-express as a Tier-1 vector (existing, or a named gap below). |
| **retire** | **DROP**-classified, **redundant**, or **obsolete** (in-process internals, source-regex, test-harness/tooling mechanics). | Name the ADR-0038m drop row, the "covered by vector X" cross-reference, or "implementation detail (ADR-0039m)". |
| **re-express** | Valuable behavior currently asserted **language-specifically** (in-process function call, Bash grammar, source regex, platform shell) that needs translation to a language-neutral vector. | A Tier-1 vector (new), or Tier-2/Tier-3 evidence for host-enforcement oracles. |

The scope's four-way *valuable / redundant / obsolete / language-specific*
maps onto these buckets: **valuable → preserve**, **redundant or obsolete →
retire**, **language-specific → re-express**.

## Method

Counts are measured from the checkout at `main` `c76b96c`: `@test` blocks in
`test/bats/*.bats` (64 files, **1053** tests). The vector cross-references
below are validated against `test/vectors/manifest.json` (the coverage
manifest). A "gap" is a valuable behavior with **no existing vector**; each
gap is a named follow-up in the final section.

---

## Summary

| Bucket | Files | Tests | Share |
|---|---|---|---|
| preserve (→ Tier-1 vector) | 25 | 539 | 51% |
| re-express (language-specific → neutral vector) | 29 | 443 | 42% |
| retire (DROP / redundant / obsolete) | 10 | 71 | 7% |
| **Total** | **64** | **1053** | 100% |

---

## Per-file inventory

Disposition column cites the ADR-0038m contract row (§1–§6, or the required
result-data list), an ADR-0040m/0041m/0042m obligation, a "covered by
`vector/id`" cross-reference, or a retire reason. Files are listed in
numeric-prefix order.

> **Legend — which document a section citation names:** every `§`-prefixed
> citation (`§1`–`§6`, the paragraph-line cites `§46`/`§48`/`§50`, and the
> named required-data rows such as `§secret set`, `§kit check`, `§ports`)
> refers to **ADR-0038m** — the *Portable acq v1 compatibility contract*.
> `§1` command/exit, `§2` output + required result data, `§3`
> config/state/precedence, `§4` paths, `§5` security, `§6` preserve/drop
> classification. References to `docs/spec/acq-v1.md` or to another ADR are
> always written out in full (never as a bare `§`).

### Harness, tooling, and host-verifier internals

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `00-shared-fixtures.bats` | 1 | retire | **Obsolete.** Asserts the stub-library fixture sees complete specs mid-write — tests the test harness, not `acq`. Implementation detail (ADR-0039m). |
| `01-test-runner.bats` | 9 | retire | **Obsolete.** Tests the bespoke bats runner (timing, worker counts, shellcheck runner, transport fixture). The runner is replaced by the two vector runners (ADR-0043m); not product behavior. |
| `150-exec-bits.bats` | 9 | retire | **Obsolete.** Tests the repo exec-bit fixer (repo hygiene tooling), not `acq` behavior. |
| `155-summarize-bats-timing.bats` | 19 | retire | **Obsolete.** Tests the CI timing-summarizer script, not `acq`. |
| `156-summarize-bats-timing-real.bats` | 7 | retire | **Obsolete.** Same as above (live-timing fixtures for the summarizer). |
| `145-verify-capture.bats` | 13 | retire | **Obsolete.** Tests the host-side `verify-backends` capture helper (pipe-idiom regression, CRLF normalization, grammar preflight). Host-verifier internals, never contract evidence. |

### Installer

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `05-install.bats` | 9 | preserve | Installer contract (ADR-0042m). Covered by `installer/help`, `installer/version`, `installer/usage-error`, `installer/dry-run`, `installer/checksum-fail-closed`, `installer/offline-install`, `installer/consent-declined`. **Gap:** "never elevates" and "never dumps env / hardcodes a secret" are not yet a vector. |
| `06-windows-install.bats` | 8 | re-express | Windows PowerShell installer (release-marker sync, zip checksum, consent-gated PATH, no elevation, no `iex` pipe, LOCALAPPDATA). Language-specific (PowerShell); needs Windows installer vectors + Tier-3 Windows qualification (ADR-0044m). |

### Core CLI: version, help, doctor, backend, dispatch, image, agents, naming

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `10-name-derivation.bats` | 4 | re-express | §create sandbox-name derivation (`--name` wins; agent+path slug). Pure in-process `slugify`/`derive_name` unit tests — the observable derived-name behavior is contract, asserted language-specifically. **Gap G4.** `slugify` internals → retire. |
| `55-version.bats` | 1 | preserve | §2 version identity. Covered by `cli/version-json`, `cli/version-human`. |
| `60-help.bats` | 18 | preserve | §1 command surface + usage exit 2. Help flags and bare-`acq` exit 2 are covered by `cli/usage-error`/`cli/usage-error-human`; `secret import`/`secret set-custom` are documented verbs. **Mixed → retire:** "backend help is appended for shared verbs / bare `secret`" asserts the **DROP** row "backend help for bare `secret`" (ADR-0038m §6). |
| `65-doctor-image-contract.bats` | 9 | preserve | §doctor diagnostic command + ADR-0030 image-contract diagnostics. Covered by `cli/doctor-json`, `cli/doctor-human`, `cli/doctor-unsupported`. **Mixed → retire:** the `doctor script:` blocks source `common.sh` and assert `acq_image_contract_doctor_script` internals (implementation detail). |
| `20-backend-resolution.bats` | 10 | re-express | §active_backend resolution (flag > env > config > auto-detect) is contract. Auto-detect default is covered by `cli/backend-list-none/unknown/default-msb`; the **flag>env>config precedence and PATH self-repair** are Bash-internal and are a **gap**. |
| `30-dispatch-routing.bats` | 45 | preserve | §1 command surface + §9 passthrough. Routing maps to `cli/lifecycle-*`, `cli/exec-*`, `cli/shell-*`, `cli/passthrough*`, `cli/github-scope-*`. **Mixed → retire:** `_classify_key_status` token classification and `project-env` direnv detection are in-process internals. |
| `35-image-override.bats` | 24 | re-express | §4 image-override precedence (ADR-0030, ADR-0022: `--image` → `ACQ_IMAGE` → `ACQ_MSB_IMAGE` → agent default) is contract but no vector pins it — **gap**. `_acq_image_registry_host`/`acq_registry_auth_hint` are Bash internals → retire. |
| `36-agent-catalog.bats` | 9 | re-express | Known-agent set + template naming is contract (the `create AGENT` surface validates against it, `cli/lifecycle-create-unknown-agent`). No vector pins the catalog/template mapping — **gap**. |

### Secrets and credentials

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `40-secret-set.bats` | 33 | preserve | §secret set/has + §48. Covered by `cli/secret-set-*`, `cli/secret-has-*`, `cli/secret-rm-*`, `cli/secret-sbx-unsupported`. **Mixed → retire:** `mask` (interactive masked input) is rendering, dropped by §50 "exact … prompt layout … not contracts"; **DROP** "scope-less secret set" (§6) is covered by `cli/secret-set-usage`. |
| `45-secret-store-unit.bats` | 20 | re-express | In-process secret-store unit. `secret rm`/`ls` observables map to `cli/secret-rm-*`/`cli/secret-ls-*`. The store itself (keys, scopes, 0600 file backend, DPAPI envelope and legacy migration through a fake PowerShell and the `dpapi_*` seam) is re-expressed for the Python store in `py-acq/tests/test_secretstore.py`, with a Bash↔Python byte round trip in `py-acq/tests/test_secretstore_bash.py`; real DPAPI remains a Windows Tier-3 qualification item (ADR-0028). |
| `71b-msb-secret-store-backends.bats` | 11 | re-express | keychain-linux/macos/file backends are platform-specific secret storage (ADR-0028); their logic (index, self-heal from sidecars, `security -i`, legacy file fallback) is re-expressed against fake `secret-tool`/`security` in `py-acq/tests/test_secretstore.py` and round-tripped with Bash in `py-acq/tests/test_secretstore_bash.py`; the real keychains remain host qualification items. multi-workspace mount + symlink canonicalization are §4 host/guest-path fidelity → **gap**. |
| `125-github-scope.bats` | 14 | preserve | ADR-0013 per-sandbox GitHub scoping. Covered by `cli/github-scope-json`, `cli/github-scope-no-value`, `cli/github-scope-sbx`. |
| `146-provider-verification.bats` | 28 | preserve | §provider-credential + host-verifier reachability. Covered by `cli/provider-credential-*`. **Mixed → re-express:** reachability/model-identity checks are Tier-2/Tier-3 evidence, not Tier-1 vectors. |
| `148-provider-credential-bindings.bats` | 56 | preserve | §provider-credential set/ls/rm + facts.json validation (ADR-0040m). Covered by `cli/provider-credential-*`. |
| `77-usai-rotate.bats` | 7 | preserve | ADR-0012/0040m key rotation. Covered by `cli/usai-rotate-*`. |

### Kits: list, validate, source, provenance, apply

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `50-kit-list-completeness.bats` | 12 | preserve | §kit list required data + §3 explicit empty provider selection. Covered by `cli/kit-list`. **Gap:** "explicit empty omits every provider kit" (a §3 rule) has no dedicated vector. |
| `80-kit-subcommands.bats` | 5 | preserve | §kit list/validate/apply. Covered by `cli/kit-list`, `cli/kit-validate-*`, `cli/kit-apply-unsupported`. |
| `85-kit-provenance.bats` | 23 | preserve | §kit check/update + provenance (ADR-0016). Covered by `cli/kit-check-*`, `cli/kit-update-*`. |
| `149-kit-source.bats` | 40 | preserve | §46/§2 kit-source registry. Covered by `cli/kit-source-*`. |
| `95-kit-ref-persistence.bats` | 7 | re-express | Persisted `--kit`/`ACQ_EXTRA_KITS` refs (ADR-0041m §3 state). No vector pins the round-trip — **gap**. |
| `100-kit-translate.bats` | 17 | re-express | Neutral → sbx-v2 spec translation is sbx-grammar-specific; the *observable* is `kit validate` (`cli/kit-validate-*`). Translation internals are Tier-2 implementation detail. |
| `101-sbx-grammar-acceptance.bats` | 3 | preserve | Tier-3 live: real sbx accepts acq's translator output. Host-enforcement/grammar oracle (ADR-0044m). |
| `102-kit-fetch-reuse.bats` | 9 | re-express | Pinned-fetch caching/reuse is git-internal. `kit-source` trust/full-ref observables are covered by `cli/kit-source-*`; fetch reuse is Tier-2. |
| `103-kit-fetch-lifecycle.bats` | 1 | retire | **Obsolete.** Kit-fetch process lifecycle (traps/signals) — implementation detail. |
| `104-kit-fetch-exit-latency.bats` | 1 | retire | **Obsolete.** Performance/latency of the fetch guardian — implementation detail. |

### Backend adapters and lifecycle

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `70-msb-backend.bats` | 20 | preserve | §active_backend + §version floor. Covered by `cli/backend-list-*`, `cli/backend-check-*`. **Mixed → re-express:** `backend set/unset` (persist default) is covered by `cli/backend-set*`, `cli/backend-unset*` and `cli/lifecycle-create-config-sbx`; `prepare`/`doctor --fix` host-readiness has no vector — **gap**. |
| `71-msb-provision-secrets.bats` | 14 | preserve | §secret binding + provision. Covered by `cli/create-msb-binds-usai`, `cli/secret-set-msb`, `cli/secret-ls-msb`, `cli/secret-rm-msb`, `cli/secret-has-msb-scoped-over-global`, `cli/lifecycle-create`. |
| `71c-msb-canonical-host-config.bats` | 2 | re-express | §4 host-path canonicalization before mount — host/guest-path fidelity → **gap**. |
| `72-msb-agent-user.bats` | 37 | preserve | §attach/exec/shell as agent user. Covered by `cli/attach-*`, `cli/exec-*`, `cli/shell-*`. **Mixed → re-express:** TERM forwarding, passwd-shell, workspace `-w` are Tier-2/Tier-3. |
| `73-msb-kits-startup.bats` | 14 | re-express | msb create-time startup staging (ADR-0017) is backend-internal; observable "startup command runs" is Tier-3. |
| `74-msb-restart-durability.bats` | 21 | re-express | §start/restart/stop ordering + secret re-export (no-leak, §5). `cli/lifecycle-stop` covers stop; `cli/start-msb`, `cli/restart-msb`, `cli/start-sbx-unsupported` and `cli/start-missing` cover start/restart and the secret re-export (G8). |
| `75-msb-kit-security.bats` | 8 | preserve | §kit validate reports hostile mode/phase/name (not silently drops). Covered by `cli/kit-validate-findings`. |
| `76-msb-dns.bats` | 13 | re-express | §DNS/resource defaults (ACQ_MSB_* overrides) — no vector — **gap** (Tier-2 provision detail + `lifecycle-create` observables). |
| `78-msb-kit-env.bats` | 9 | re-express | kit environment persistence/replay (ADR-0033). Language-specific. |
| `79-msb-merged-kit-env.bats` | 9 | re-express | Merged kit env (ADR-0033). Language-specific. |
| `79-msb-readonly-kit-files.bats` | 6 | re-express | §5 read-only host-authoritative kit files — host-enforcement; Tier-3 security oracle → **gap** for a Tier-1 vector. |
| `81-msb-node-invocation.bats` | 5 | re-express | msb foreground Node invocation (ADR-0036) — language-specific launcher. |
| `82-msb-legacy-sandbox.bats` | 3 | re-express | §3 migration of a legacy (no-record) msb sandbox — `cli/migration-forward` covers v0 records, not legacy-sandbox heal — **gap**. |
| `90-sbx-startup-kit.bats` | 39 | re-express | sbx startup-kit healing/refusal/recreate guidance (ADR-0037). Recreate guidance maps to `cli/security-recreate-*`; the rest is sbx-internal. |
| `91-sbx-readonly-warning.bats` | 2 | retire | **Obsolete.** Backend-specific warning rendering for readonly files — subsumed by the re-express of `79-msb-readonly-kit-files`. |

### Host-authoritative security, mount qualification, migration

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `81-msb-forged-guest-markers.bats` | 16 | re-express | §5 guest-writable state never authoritative — host-enforcement; Tier-3 security oracle → **gap** for a Tier-1 vector. |
| `83-msb-ro-host-config-record.bats` | 13 | re-express | §5 read-only host-config record fail-closed (ADR-0035). Maps to `cli/security-exception-*`; the record probing is Tier-3. |
| `84-msb-ro-mount-qualification.bats` | 40 | preserve | §5 host-enforcement oracle + canary (ADR-0044m). This is the **Tier-3 live security oracle** (ro-mount canary); preserve as Tier-3, not Tier-1. |
| `140-opencode-migration-gate.bats` | 28 | re-express | §3 migration gate + agent-kit gate (ADR-0030/0041m). `cli/migration-*` covers record migration; the opencode-specific gate has no vector — **gap**. |
| `147-provider-input-projection.bats` | 63 | re-express | Provider-input projection / safe_mkdir / canonical_path / locks (ADR-0041m state). Migration observables map to `cli/migration-*`; projection machinery is Tier-2. |

### Ports, volumes, egress, ssh-agent, clone, paths, configure

| File | Tests | Bucket | Disposition |
|---|---|---|---|
| `105-ports-background.bats` | 9 | preserve | §ports vocabulary (ADR-0014). Covered by `cli/ports-*` + `cli/kit-validate-*`. |
| `110-volumes.bats` | 12 | re-express | §4 volumes vocabulary (ADR-0023) — no vector — **gap**. terminate-cleanup maps to `cli/lifecycle-rm`. |
| `111-balanced-egress.bats` | 8 | re-express | §5 deny-by-default egress rules (ADR-0018/0019) — security; no vector — **gap**. |
| `112-msb-ports.bats` | 18 | preserve | §ports post-hoc publish (ADR-0015). Covered by `cli/ports-*`. |
| `113-host-port-override.bats` | 24 | preserve | §ports + `--publish` (ADR-0034). Covered by `cli/ports-*`; host-port contention is Tier-2/Tier-3. |
| `115-ssh-agent-forward.bats` | 38 | preserve | §6 **preserve-with-warning** "unavailable optional SSH-agent forwarding" (ADR-0021). No vector — **gap** (Tier-3 vsock route + Tier-2 probe). |
| `116-clone-option.bats` | 37 | re-express | §3 clone state (ADR-0027). No vector pins `--clone`/`ACQ_CLONE` — **gap**. |
| `117-msys-path-forms.bats` | 11 | re-express | §4 Windows host/guest path forms (ADR-0029) — Windows qualification → **gap**. |
| `120-workspace-preflight.bats` | 15 | re-express | §4 workspace preflight validation (path/identity) — language-specific validation; no vector — **gap**. |
| `130-progress.bats` | 9 | retire | **DROP** (ADR-0038m §50): "exact … progress rendering are not contracts"; only stream separation/no-progress is contract. |
| `135-configure.bats` | 28 | preserve | §2 noninteractive `configure` required data (effective key/value/source-layer, no secrets). **Mixed → retire:** interactive `prompt`/`multiselect` asserts prompt layout — DROP (§50 "non-interactive never infers consent; prompt layout not contract"). **Gap:** noninteractive configure output has no vector. |

---

## Mixed-file block detail

The primary bucket above is the file's dominant classification. The following
files are materially mixed and the notable off-bucket blocks are named so
retire-on-touch can proceed block by block:

* **`60-help.bats`** — retire the "bare `secret` appends backend help" block
  (DROP: backend help for bare `secret`, ADR-0038m §6); preserve the help-flag
  and `secret import`/`secret set-custom` blocks. `secret import` behavior is
  covered by `cli/secret-import-*` and by the Bash/Python store parity test in
  `py-acq/tests/test_secretstore_bash.py`.
* **`40-secret-set.bats`** — retire the `mask` interactive-mask block (§50
  rendering); the scope-less-`secret set` block is already a DROP covered by
  `cli/secret-set-usage`.
* **`30-dispatch-routing.bats`** — retire `_classify_key_status` and
  `project-env`/direnv blocks (in-process internals); preserve routing and
  passthrough blocks.
* **`35-image-override.bats`** — retire `_acq_image_registry_host` /
  `acq_registry_auth_hint` (Bash helper internals); re-express the image
  precedence and agent-default blocks as vectors.
* **`20-backend-resolution.bats`** — retire the PATH self-repair blocks
  (Bash `PATH` mutation internals); re-express the flag>env>config>auto-detect
  precedence as a vector.
* **`135-configure.bats`** — retire the `prompt`/`multiselect` interactive
  blocks (DROP: prompt layout); preserve the noninteractive config round-trip
  and `apply` blocks.
* **`146-provider-verification.bats`** — re-express the reachability /
  model-identity blocks as Tier-2/Tier-3 evidence; preserve the
  provider-credential binding blocks already covered by vectors.
* **`70-msb-backend.bats`** — `backend set/unset` is re-expressed as vectors;
  re-express `prepare` host-readiness as a new vector (gap); preserve
  version-floor and auto-detect blocks already covered.
* **`65-doctor-image-contract.bats`** — retire the `doctor script:` blocks
  (source `common.sh` and assert `acq_image_contract_doctor_script` internals —
  implementation detail); preserve the subprocess `acq doctor` blocks already
  covered by `cli/doctor-*`.
* **`10-name-derivation.bats`** — retire the `slugify` pure-function block
  (Bash string-munging internals); re-express the `derive_name` `--name`
  precedence and agent+path slug blocks as a create-name vector (gap G4).

---

## Gaps — valuable behaviors with no existing vector (named follow-ups)

These are behaviors the legacy suite asserts that **no current
`test/vectors/` vector pins**. Each is a named follow-up; none is silently
dropped. All are Tier-1 candidates unless marked Tier-3.

| # | Follow-up (working title) | Legacy evidence | Contract row |
|---|---|---|---|
| G1 | Backend resolution precedence (flag > env > config > auto-detect) | `20-backend-resolution.bats` | §active_backend (spec §4) |
| G2 | Image-override precedence (`--image` → `ACQ_IMAGE` → `ACQ_MSB_IMAGE` → agent default) | `35-image-override.bats` | §4 + ADR-0022/0030 |
| G3 | Agent catalog / template-image naming + known-agent set | `36-agent-catalog.bats` | §4 + ADR-0030 |
| G4 | Sandbox name derivation (`--name` wins; agent+path slug) | `10-name-derivation.bats` | §create surface |
| G5 | Clone option (`--clone` / `ACQ_CLONE`, scratch clone, origin carry) | `116-clone-option.bats` | §3 + ADR-0027 |
| G6 | Volumes vocabulary + terminate cleanup | `110-volumes.bats` | §4 + ADR-0023 |
| G7 | Balanced-egress rule translation (deny-by-default) | `111-balanced-egress.bats` | §5 + ADR-0018/0019 |
| G8 | start/restart durability + secret re-export (no-leak). Covered for the Python CLI by `cli/start-msb` and `cli/restart-msb` | `74-msb-restart-durability.bats` | §start/restart + §5 |
| G9 | Host/guest path fidelity (canonicalization, symlink, Windows forms) | `71c`, `117-msys-path-forms.bats` | §4 + ADR-0029 |
| G10 | Guest-tamper resistance / forged markers (host-authoritative) — Tier-3 | `81-msb-forged-guest-markers.bats` | §5 |
| G11 | Read-only host-config + mount qualification — Tier-3 | `83`, `84-msb-ro-mount-qualification.bats` | §5 + ADR-0035/0044m |
| G12 | OpenCode migration/agent-kit gate | `140-opencode-migration-gate.bats` | §3 + ADR-0030/0041m |
| G13 | Provider-input projection / state locks | `147-provider-input-projection.bats` | §3 + ADR-0041m |
| G14 | Windows installer (PowerShell) | `06-windows-install.bats` | ADR-0042m + ADR-0044m |
| G15 | Noninteractive `configure` output (effective key/value, no secrets) | `135-configure.bats` | §2 required data |
| G16 | SSH-agent forwarding (`--vsock` / `ACQ_FORWARD_HOST_SOCKETS`) | `115-ssh-agent-forward.bats` | §6 preserve-with-warning |
| G17 | Host-readiness `prepare` (`backend set/unset` persistence is now covered by `cli/backend-set*`, `cli/backend-unset*`) | `70-msb-backend.bats` | §3 + ADR-0040m |
| G18 | Kit-ref / `ACQ_EXTRA_KITS` persistence round-trip | `95-kit-ref-persistence.bats` | §3 + ADR-0041m |
| G19 | Installer elevation/secret-safety guard | `05-install.bats` | ADR-0042m |

The gaps marked Tier-3 (G10, G11) are host-enforcement oracles that cannot be
proven by a mock/stub Tier-1 vector; they map to ADR-0044m live transcripts
rather than a CLI vector.

---

## Retire-on-touch cross-reference (DROP rows → legacy tests)

| ADR-0038m DROP row | Legacy test(s) that assert it | Retire cites |
|---|---|---|
| backend help for bare `secret` | `60-help.bats` (bare-`secret` block) | §6 |
| scope-less secret set | `40-secret-set.bats` ("no scope errors") | §6 + `cli/secret-set-usage` |
| exact progress/rendering | `130-progress.bats` (animation frames) | §50 |
| prompt layout (interactive configure) | `135-configure.bats` (`prompt`/`multiselect`) | §50 |
| agent-to-shell fallback | (asserted inversely by `cli/attach-json`) | §48 |
| inspection-failure-as-empty | (asserted inversely by `cli/ports-inspect-failure`) | §48 |
| guest-writable trusted-state fallback | `81-msb-forged-guest-markers.bats`, `83`/`84` | §48 + §5 |

---

## Verification of this inventory

* Every `test/bats/*.bats` file is accounted for above (64 files, 1053 tests).
* Every `preserve` disposition cites a §1–§6 invariant or required-data row and
  (where one exists) a `test/vectors/` id from `manifest.json`.
* Every `retire` disposition names a DROP row, a "covered by vector" cross-ref,
  or "implementation detail (ADR-0039m)".
* Gaps G1–G19 are the valuable behaviors with no existing vector, recorded as
  named follow-ups per the contract requirement.

This inventory is referenced from `test/vectors/manifest.json` (`inventory`
field + `notes` entry) and `test/vectors/README.md`.
