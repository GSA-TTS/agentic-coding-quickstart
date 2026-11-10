---
title: "Backend adapter capability contract"
status: accepted
date: 2026-11-01
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-3", "AC-4", "CM-3", "SA-8", "SA-17", "SC-7"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: ["0010-acq-pluggable-backends.md §Adapter contract"]
---

# ADR-0040m: Backend adapter capability contract

## Context and Problem Statement

The seam between the acq orchestrator and a backend adapter is implicit:
a sourced Bash file exposing `acq_backend_*` functions plus
`ACQ_BACKEND_*` flag variables, with optional capabilities discovered two
inconsistent ways (`command -v` function probes and capability flag
variables). A Python replacement must preserve deliberate behavior without
freezing the Bash function table, and must support CLI adapters now
without assuming future adapters are subprocess wrappers.

## Decision

Define the seam as a transport-neutral capability contract: it specifies
what an adapter must do and the observable result, not how. Each adapter
declares a capability record — backend name, nullable detected version,
and a capability map with a support level (`required` | `optional` |
`unsupported`) per capability — read once by the orchestrator. V1 ships
subprocess-calling adapters for msb and sbx only; the contract does not
require subprocess.

The declared capability set is: detect, version, provision, list, exec,
attach, shell, stop, remove, copy, ports, kit-apply, secret-write/rm,
secret-list, key-rotate, key-present, kit-source-revoke, start/restart,
provenance, and doctor. The 23 common obligations and 4 backend-specific
obligations (`start`/`restart` msb-only; `key_present`/
`kit_source_revoked` sbx-only) realize these capabilities. An
`unsupported` or absent capability requested by a user fails closed with
exit 1, the `unsupported_capability` code, and remediation.

> **Reconciliation note (2026-11-05):** the initial capability assignment
> (`secret_ls` msb-only, `secret-list` unsupported on sbx) was written against the
> deterministic stubs, which assumed an msb `secret` subcommand that does not
> exist. Live verification against the real CLIs (msb 0.7.11 / sbx 0.50.1)
> inverted it: sbx has `secret set/ls/rm` and so owns `secret-list` (msb has no
> standalone secret store — its secrets are per-sandbox `--secret ENV@HOST`
> bindings on create/start plus `--secret-rm` on `modify`, a provider-credential
> concern). `key-rotate` (the `rotate` subcommand) exists on neither backend and
> is unsupported on both. `kit-apply` is msb-only in this slice and runs in-guest
> via `msb exec` (no `kit-apply` subcommand); `kit-source-revoke` is sbx-only via
> `sbx settings get/set kit.allowedSources` (no `kit-source-revoke` subcommand).
>
> **Reconciliation note (2026-11-09):** msb now declares `secret-write`,
> `secret-rm` and `secret-list` as `required`. It still has no `secret`
> subcommand: the values live in the acq secret store shared with the Bash
> adapter, are bound as `--secret ENV@HOST` at create, and reach running
> sandboxes through `msb modify --secret`/`--secret-rm`. `key-present` stays an
> sbx-only obligation (msb holds no proxy table); `secret has` on msb is answered
> from the store and the adapter's binding table. Because msb offers no binding
> listing acq relies on, the adapter records host-side which sandbox holds which
> binding (an empty record too, so a missing one means "unknown"); `secret rm`
> unbinds exactly those, sweeps unknown sandboxes best-effort, and if a binding
> cannot be removed or an unknown sandbox cannot be confirmed unbound it keeps
> the stored value and fails with `unbind_failed` so the removal can be retried.
>
> **Reconciliation note (2026-11-09, rotation):** `key-rotate` is now `required`
> on both backends, although neither has a `rotate` subcommand. As in the Bash
> adapters (ADR-0012), rotation stores the new key in the acq secret store and
> re-feeds the sandboxes that use it: msb through `msb modify --secret`, sbx by
> re-setting each custom secret with `secret set-custom --placeholder P
> --value-stdin` (sbx >= 0.51.0), which keeps the placeholder running sandboxes
> were injected with (ADR-0008). Rotation does not call the provider, so it never
> returns `provider_unreachable`/`provider_auth_failed`; the key is checked at
> the next attach. Every backend to be re-fed is checked before the key is
> stored, so a refusal changes nothing. A sandbox that misses the new key, or
> an installed backend below acq's floor that may hold it, fails the command
> (exit 1, naming it in `error.backends`), and re-running the rotation retries
> it. On sbx, rotation also overwrites every sandbox-scoped custom secret for
> the key that acq did not store (such as an ADR-0008 rebind, or one added by
> hand with `sbx secret set-custom --sandbox`): acq treats such an entry as a
> copy of the global key. Only a sandbox with its own `usai` value in the acq
> store (`acq secret set NAME usai`) keeps it. After each `set-custom` acq
> re-reads the listing and requires the entry to keep its placeholder; that
> sbx does so is not yet verified live (KNOWN_FAILURE_MODES 57).
>
> These sbx refusals apply only when sbx is the active backend. When sbx is
> installed but not the active backend, no sbx problem blocks the rotation:
> a secret list that cannot be read (`sbx secret ls` fails, times out, or
> returns something unreadable), an `sbx ls` timeout while resolving the
> `global` label, any listing acq refuses (duplicate global entries, an
> ambiguous label, a row with no usable placeholder), or an sbx below 0.51.0
> that holds the key. The rotation goes ahead on msb and reports sbx as not
> re-fed (exit 1), as Bash rotates msb and fails only the sbx propagation. The
> active backend's own refusals still come first, before the store write, and
> name the backend. Each sbx and msb call a rotation makes while it holds the
> usai provider lock (sbx `secret ls`, `ls` and `set-custom`; msb `list` and
> `modify`) is bounded by `ACQ_ROTATE_TIMEOUT` (default 120 s, the Bash
> adapter's `ROTATE_VALIDATE_TIMEOUT`; it must be more than 0, and 0 or any
> other invalid value falls back to the default with a warning); a call that
> times out counts as a failure: of that sandbox for `set-custom` or `modify`,
> of the whole backend's re-feed for a listing. Outside a rotation, every
> sandbox listing (msb `list`, sbx `ls`, behind `ls` and the existence and
> running checks) is bounded by `ACQ_LIST_TIMEOUT` (default 60 s, more than 0,
> with the same fallback); a listing that times out fails the command with
> `timeout`. An installed msb that fails acq's
> version check is never run, since any msb command opens its catalog and may
> migrate it one way (ADR-0032): whether it holds the key is read from acq's
> binding records alone, and every record counts, including one left by a
> sandbox removed outside acq. That fails safe (exit 1), and the remediation
> names the sandboxes the records cover and says that, once msb passes the
> version check, `acq --backend msb rm NAME` clears a stale record. Unlike Bash, which propagates only from msb to sbx and needs an
> existing sbx entry, the Python acq also re-feeds msb after a rotation on sbx
> (it always stores the key first) and, as the active backend, creates a
> missing global sbx entry. A global sbx entry that took the new key is
> reported as `global: updated` (or `created`) in that backend's result.

The record is a declaration; conformance is proven, not trusted: each
declared capability is asserted by a Tier-1 subprocess vector (working, or
fail-closed for `unsupported`), and host-enforcement capabilities require
a Tier-3 live transcript.

Register a stable error-code vocabulary beyond the `usage`/`failure`
minimum: `backend_not_found`, `backend_version_unsupported`,
`backend_version_unknown`, `sandbox_not_found`, `sandbox_exists`,
`unsupported_capability`, `secret_missing`, `secret_unreadable`,
`provider_unreachable`, `provider_auth_failed`, `validation_failed`, and
`timeout`. Every backend-native failure maps to a code + message +
optional remediation; raw backend text is never a portable field. Adapters
map native state into the portable `running`/`stopped`/`unknown`,
nullable version, and `current`/`stale`/`unknown` vocabularies.

The seam owns sandbox identity, agent, workspace/mount, provider,
credential-binding, kit-ref/provenance, and network-tier authority, all
host-authoritative per ADR-0035. The backend owns the mechanism and
reports outcomes; it never decides trust. Host and guest path/value types
follow the compatibility contract §4; the adapter owns translation, the
seam validates it.

## Consequences

Capabilities are discovered from one declared record instead of scattered
function probes and flag variables. A future non-subprocess adapter can
satisfy the same contract without reworking the orchestrator. A diverged
or incomplete declaration is caught by the conformance vectors rather than
silently dropping portable behavior. Error handling gains a stable
machine-readable vocabulary that never leaks backend text as a contract.

## Verification

Every declared capability has a Tier-1 subprocess vector; every
`unsupported` capability has a fail-closed vector; error mapping and path
round-trip are vector-asserted; host-enforcement capabilities have a green
Tier-3 live transcript at release and on any PR touching them.
