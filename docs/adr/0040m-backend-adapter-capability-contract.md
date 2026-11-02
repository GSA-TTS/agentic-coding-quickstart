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
obligations (`start`/`secret_ls` msb-only; `key_present`/
`kit_source_revoked` sbx-only) realize these capabilities. An
`unsupported` or absent capability requested by a user fails closed with
exit 1, the `unsupported_capability` code, and remediation.

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
