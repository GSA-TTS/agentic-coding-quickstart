---
title: "Portable acq v1 compatibility contract"
status: accepted
date: 2026-11-01
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-3", "CM-3", "CM-6", "SA-8", "SC-8", "SI-10"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0038m: Portable acq v1 compatibility contract

## Context and Problem Statement

The Bash acq wrapper exposes lifecycle, credential, kit, trust, configuration, and diagnostic operations over msb and sbx. A Python replacement must preserve deliberate behavior without freezing Bash quirks or weakening host/guest security. Existing code and tests are evidence, not specification. Exact human rendering and internal file formats are not appropriate compatibility boundaries.

## Decision

Preserve every documented acq-owned command and meaningful flag by name; any rename requires a compatibility alias and migration. Keep backend-only capabilities explicitly nonportable and retain announced verbatim unknown-command passthrough. Internal helpers and test hooks are not public.

Use 0 for completed acq operations and successful query answers, 1 for acq operational/validation/support/incomplete failures, and 2 for acq usage errors. Preserve child/backend status for execution, attach, shell, copy, native port operations, and passthrough. Never report unqualified success after a required stage fails.

Retain human output by default and add opt-in versioned JSON for every query/diagnostic command. Success uses `{schema_version, command, data}`; identified command failure uses `{schema_version, command, error{code,message,remediation?}}`. Stdout contains one document and human diagnostics use stderr. Unknown fields are additive; required-field removal/meaning/type changes require a schema-version bump. Secret values and raw credential/proxy records are never fields.

Required result data is:
- `ls`: sandboxes with name/backend/state;
- `backend list`: active backend and installed/name/version records;
- `version`: acq/source/backend/backend-version/control-plane identity;
- `secret ls` and `secret has`: scope/service/injectability or value-state and non-secret bindings only;
- `provider-credential ls`: provider/key-env/hosts/source-layer;
- `kit-source ls`: repository/ref/directory/provider-kits/discovery-status;
- `kit list`: control-plane ref and effective built-in/provider/extra sets;
- `kit check`: sandbox/backend/local/applied refs and current/stale/unknown;
- `kit validate`: validity and coded findings;
- `ports`: declared host/guest mappings and create/post-hoc origin, not health;
- `doctor`: overall/check status with stable IDs and remediation;
- noninteractive `configure`: effective key/value/source-layer without secrets.

Preserve `${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml`, its documented keys, documented environment inputs, explicit empty provider selection, scoped-over-global credentials, and existing precedence. Recorded per-sandbox create choices outrank later ambient configuration on resume. Migrate existing names, agents, workspaces/mounts, images/clones, providers, bindings, kit provenance, host-authoritative config, provider generations, credentials, and clone/SSH/port state. Internal formats are not public; migration is atomic and non-destructive until verified.

Native host paths and POSIX guest paths are distinct types. Host mount sources never become guest cwd/target values implicitly. Unicode/spaces convert losslessly or fail; UNC/network paths require separate qualification. Exec argv after `--` is opaque. Only selected environment values cross; real credentials and private keys never do.

All trusted lifecycle data/code is host-held or host-enforced read-only. Guest-writable state is never authoritative, and kit code never executes on the host. Kits and the validation control plane use immutable full refs; durable trust is repository-granular; refresh is consented and records only success. Strict/balanced egress is deny-by-default and open requires confirmation. Unsupported/unparseable backend versions fail before mutation. Destination-pinned credentials, per-sandbox scoping, and no-secret-output rules are mandatory. Windows has no plaintext secret fallback. A legacy sandbox lacking a required enforceable guarantee fails closed and requires explicit recreation only for that security exception.

Preserve existing-sbx auto-detection, documented early-flag passthrough, successful current/stale/unknown kit checks, declared-port semantics, acq-consumed-field kit validation, and sbx raw-placeholder removal. Preserve with warning create-only reattach flags, the deprecated balanced-egress alias for one migration window, explicit best-effort source-discovery status, and unavailable optional SSH-agent forwarding. Drop ignored missing values, invalid persisted backends, false partial success, name-only provider-validation bypass, static kit listing, last-only repeated publish, backend help for bare `secret`, scope-less secret set, agent-to-shell fallback, inspection-failure-as-empty, and guest-writable trusted-state fallback.

Noninteractive operation never infers consent. Exact prose, tables, colors, prompt layout, and progress rendering are not contracts; stream separation, non-TTY/no-progress behavior, secret-free diagnostics, actionable remediation, and equivalent structured information are. Installer dry-run, consent, checksum, user-scope/no-elevation, and failure semantics remain while distribution channels are decided separately.

## Consequences

Existing users retain their command surface and state without inheriting every Bash accident. Scripts gain an explicit forward-compatible machine interface instead of depending on prose. Security guarantees take precedence over avoiding recreation for an unverifiable legacy sandbox. Implementation languages and internal storage formats may change without changing observable behavior.

## Verification

Maintain language-neutral acceptance cases for every command, exit class, required result field, precedence rule, migration, and disputed-behavior classification. Adversarial and live tests must establish guest-tamper resistance, immutable kit provenance, destination-bound secret substitution, no secret exposure, deny-by-default egress, version refusal, rotation, host/guest path fidelity, and explicit security-exception recreation. Mocks alone do not qualify backend enforcement.
