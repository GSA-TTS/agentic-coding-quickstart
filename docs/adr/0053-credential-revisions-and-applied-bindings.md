---
title: "Use opaque credential revisions and per-instance applied-binding records"
description: "Proposed crash-conservative credential transactions and a validated MSB apply snapshot"
status: proposed
tier: 2
date: 2026-11-20
last_updated: 2026-11-20
decision_makers: ["Bret Mogilefsky", "William Zujkowski"]
category: authentication-and-identity
nist_controls: ["IA-5", "AC-6", "CM-3", "SI-10", "SA-11"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
related_files:
  - py-acq/src/acq_py/secretstore.py
  - py-acq/src/acq_py/msb.py
  - py-acq/src/acq_py/lock.py
  - py-acq/src/acq_py/commands/secret.py
  - py-acq/src/acq_py/commands/creds.py
  - py-acq/src/acq_py/commands/lifecycle.py
  - py-acq/src/acq_py/sbx.py
  - docs/adr/0041m-configuration-and-state-migration-behavior.md
---

# ADR-0053: Use opaque credential revisions and per-instance applied-binding records

## Status and approval boundary

Proposed for human review; AI-assisted authorship by OpenCode. The listed decision
makers have not approved this record. This gate delivers only this ADR and its
embedded test plan. Implementation starts after the coordinator communicates
human approval. The number is provisional pending integration renumbering.
Index registration belongs to the documentation delivery slice.

## Context and Problem Statement

The Python secret store shares credential values and endpoint metadata with Bash.
MSB's existing `HeldRecord` identifies bindings for revocation but cannot establish
which credential was successfully delivered to a particular sandbox instance.
A preparation consumer needs a validated read-only snapshot of effective and
applied credential identity, including uncertainty after interrupted writes.

Names, scopes, successful configuration changes, and credential delivery are
different facts. A store-only import can change a value without contacting MSB;
MSB can retain side effects after a nonzero exit; a same-name recreation is a new
instance. Even schema-2 records cannot fence Bash writes to the shared store.

## Decision Drivers

- Persist neither credential values nor hashes or any other derivation of them
  in revision sidecars or binding records, including temporary files and errors.
- Resolve source, scope, revision and the actual delivered endpoint together.
- Make incomplete store writes and unconfirmed backend changes explicit.
- Preserve revocation knowledge and prevent stale writers from overwriting it.
- Use the existing portable advisory locks and atomic-write conventions, with
  Python 3.12 as declared in `py-acq/pyproject.toml`.
- Keep lifecycle preparation receipts, provider generation, routing identity and
  trusted artifact pins in the preparation owner's layer.

## Considered Options

1. **Separate credential-application file.** Duplicates sandbox binding ownership
   and adds a second per-sandbox record to synchronize and remove.
2. **Add fields to schema 1.** Older Python writers silently discard unknown
   fields on rewrite; their reads cannot validate the stronger contract.
3. **Extend `HeldRecord` with schema 2 and add per-key revision sidecars.** Keeps
   binding ownership together, makes older Python readers refuse the new record,
   and distinguishes committed store changes from incomplete ones.

## Decision Outcome

Choose option 3. This is a proposed Python-first implementation with reuse
unconditionally disabled, including after an apparently successful apply.

### Store revision transaction

Write `<state>/secret-rev/<key>.json`, where `<state>` is `state.state_dir()` and
`key` is a validated `acq.<service>` or `acq.<sandbox>.<service>` store key. Tests
must isolate this root separately from the value-store override. The record has
exactly `committed` and `pending`, each null or an opaque `r:` token generated
independently of the credential using at least 128 random bits. A missing record
means unknown; malformed or unreadable state is an explicit validation/read
failure. No reader repairs it. A committed deletion leaves a non-secret revision
tombstone; remove/re-add of the identical value still produces a new token.

All Python value and endpoint mutations pass through revision-aware choke points
in `store`, `delete`, `meta_store`, `meta_delete`, and `set_secret`:

1. Validate inputs and acquire the required store transaction lock.
2. Atomically persist `pending = new_token`, retaining the previous committed
   token or null. Failure here prevents any value or endpoint mutation.
3. Persist the requested value/deletion and endpoint changes. `set_secret` is one
   composite transaction: it cannot commit between its value and metadata writes.
   Composite deletion likewise covers both the value and endpoint removal.
4. Only after confirmed persistence, atomically write `committed = new_token`
   and `pending = null`. Never infer successful deletion from a discarded
   keychain-tool return code or swallowed metadata-unlink failure.

Each direct choke-point call is protected too; a caller already holding the store
lock uses an explicitly locked internal operation, never recursive acquisition
or an attempted shared-to-exclusive upgrade. Existing callers are audited and
adapted together. Pure representation migration of the same Windows value is
not a credential epoch change, but its write must participate in store exclusion
or be withheld by the read-only resolver.

Any pending token makes the effective revision unknown, even if `committed` still
names an earlier success. Failure or process death after step 2 leaves pending
state; after step 3 it may describe either old or new value/endpoint contents.
Neither reading nor applying those contents clears uncertainty. A metadata-only
write cannot clear a pending value transaction. Recovery requires an explicit
successful replacement or deletion covering the value and effective endpoint;
another partial mutation preserves uncertainty. No rollback claims the old
credential survived a failed tool call.

Use private directories/files (0700/0600 where supported), same-directory
exclusive temporary creation, file flush/fsync, atomic replacement, and directory
fsync where supported. These tests establish process-crash behavior. Atomic
rename is not a cross-backend power-loss transaction, Windows directory fsync is
not assumed, and native keychain persistence is only as strong as its confirmed
operation. No stronger host-power-loss guarantee is claimed.

### Effective source and endpoint

One resolver supplies an in-memory value separately from its non-secret identity:
`(source, scope, revision, env, host)`. Source is `sandbox`, `global`, or
`environment`; scope is the actual sandbox name for a sandbox source and null
otherwise, so a sandbox named `global` is unambiguous. Value selection preserves
sandbox-over-global precedence and the existing restricted provider-environment
fallback. Environment source always has null revision and unknown apply status.

Endpoint selection preserves the existing metadata and provider-pin rules.
Value scope and endpoint scope need not coincide: a sandbox endpoint may accompany
a global value. The resolver checks pending metadata transactions that affect
the selected endpoint as well as the selected value, and captures exact ENV@HOST.
Endpoint-only changes therefore invalidate equality even when the value's own
revision did not change. Unreadable candidates must not turn into positive
unchanged evidence. The old `BoundSecret.own` Boolean is not source evidence.

### HeldRecord schema 2

Keep `<state>/msb-secret-bindings/<existing-name-key>.json` and its existing
`sandbox`, `bindings`, `complete`, and `services` fields. Add:

- `instance`: an independent random token minted for every create attempt before
  MSB mutation. Same-name recreation never inherits prior apply evidence. An
  adopted legacy record starts with unknown evidence under a fresh local token;
  this is acq identity, not proof of an MSB-native instance identifier.
- `apply`: a service-keyed object. Each entry contains `source`, `scope`, `env`,
  `host`, `revision`, `applied_revision`, `attempt`, `status`, and `status_at`.
  Tokens are opaque random identities; `status_at` is UTC display information
  only and is never an ordering or reuse authority.

Write schema 2 only. Read schemas 1 and 2, preserving schema-1 binding/revocation
knowledge while treating absent apply metadata/services as unknown. Present but
malformed apply data, invalid tokens/types/statuses or inconsistent identity
fields fail explicitly with `state_schema_unsupported`; no reusable snapshot and
no reader-side repair. Preserve existing whole-record refusal behavior. Older
Python builds reject schema 2 through their existing exact-schema check.

An entry describes one attempt's exact target identity, not a mutable alias for
the current store. `applied_revision` is null until delivery of that target is
confirmed. Starting a different attempt clears its previous applied revision so
an old successful revision cannot be paired with a new endpoint or source.
Successful removal leaves no applied credential revision; its existing revocation
knowledge remains in `bindings`/`services`. A later fallback is a separate attempt.

### Lock order and write protocol

The order becomes lifecycle → provider-credential → secret-store → held-record.
The new per-record advisory lock is last, bounds its wait using the established
timeout policy, and is never held across an MSB call or earlier-lock acquisition.
It uses `exclusive_lock` (POSIX flock; Windows byte-range locking), not a new
platform-specific mechanism. Keep its lock file stable across record deletion.

All scoped as well as global store mutations take the store lock exclusively.
Hold that exclusion through the associated refeed/unbind, so global and scoped
backend writes cannot overlap. Create/start retain their lifecycle-then-shared-
store exclusion; remove/recreate cleanup must also exclude global refeed while
changing instance records. GitHub scoping, direct adapter convenience paths,
imports and prompt cleanup must participate without retaking caller-owned locks.
No global refeed takes a sandbox lifecycle lock while holding the store lock.

The leaf lock protects each fresh read-modify-write of the entire held record;
locking only the final `save` of an earlier copy would still lose updates.
Apply uses this protocol:

1. Capture the effective identity and value under store exclusion. Under the
   leaf lock, reload the current record, preserve unrelated services and
   revocation knowledge, and persist a new attempt with pending status before
   create/start/drop/modify. Environment-backed attempts remain unknown.
2. Release the leaf lock and invoke MSB using that captured value/endpoint. A
   failed pending write prevents the backend call. Keep outer exclusion during
   the operation; no interactive session is included in that exclusion.
3. On confirmed delivery, reload under the leaf lock and compare instance and
   attempt tokens. Also compare the captured source/scope/revision/endpoint to
   the current committed effective identity. Only a matching, non-pending store
   identity can become applied, with `applied_revision` equal to the captured
   delivered revision. Never replace it with a newer revision merely read at
   completion. A stale completion cannot resurrect a deleted record.
4. Nonzero exit, timeout, interruption, or ambiguous effect leaves failed,
   pending, or unknown evidence. No unchanged inference is permitted. A failed
   final record write leaves the already-persisted pending marker. Bindings that
   may still exist remain discoverable for revocation; apply status is not an
   excuse to erase them. Overlapping/uncertain attempts never establish applied.

An accepted modify requiring restart stays pending. Configuration acceptance
while stopped is not delivery: promote only after start, exec readiness and the
existing trust gates succeed. Create follows the same readiness/trust boundary.
Where the backend cannot prove whether a running modify is active, retain pending
rather than infer success from a zero return code. A running `start` no-op cannot
promote an earlier pending addition. Rollback removals invalidate before mutation.
Native MSB behavior remains subject to live qualification.

### Read-only snapshot and ownership

Expose `held_apply_snapshot(name) -> ApplySnapshot` with validated per-service
effective identity, applied evidence, instance and status. Read under shared
store exclusion and a consistent held-record read; the resolver does not perform
Windows read-time migration or repair. Lock bookkeeping may create lock files,
but the read never rewrites credential, revision or binding records.

Compare with the current committed effective store identity on every snapshot.
Persisted applied evidence with a different current identity reports pending;
missing/legacy evidence or pending store state reports unknown. Failed evidence
does not become applied through equality alone. Store-only writes invalidate
inheritors on read without eagerly editing each record, and unchanged scoped
bindings retain their identity after an unrelated global change.

`reuse_eligible` is **False unconditionally**. Bash and older writers can mutate
the shared store without reading schema 2 or advancing revision sidecars. This
record therefore does not establish writer control. Enabling reuse requires a
separate approved writer-control contract; environment credentials cannot qualify.
Preparation owns its receipt, bounded discovery, actual mounted generation,
routes, artifact pin and launch-time recheck. This change adds no automatic start
inside low-level exec helpers.

Both `secret-rev/` (including tombstones) and `msb-secret-bindings/` are acq-owned
state. Uninstall owns their removal according to its existing scope/retention
contract; deleting a revision sidecar otherwise means unknown, never unchanged.

### Corrections to the initial coordinator draft

Whole-file review of `msb.py`, `secretstore.py`, `lock.py`,
`commands/secret.py`, `commands/creds.py`, `commands/lifecycle.py`, and `sbx.py`
identified these necessary corrections, accepted by the coordinator for this ADR:

1. **Promotion:** record the captured delivered revision only after rechecking it
   against the current committed revision; the draft's completion-time assignment
   could incorrectly label an old delivery with a newer revision.
2. **Composite persistence:** `set_secret` currently calls `store` then
   `meta_store`. Independent commits leave a false complete window. Pending must
   cover both, and a later metadata-only write cannot legitimize an interrupted
   value write. Deletion needs confirmed tool/file results too.
3. **Lock coverage:** scoped `_credential_locks` currently takes no store lock;
   adapter GitHub scoping paths do not acquire a lifecycle lock themselves.
   A leaf lock alone protects JSON, not the ordering of backend side effects.
   The stronger outer store exclusion above is required at those callers.
4. **Delivery boundary:** readiness/trust gates follow `msb.create` and
   `msb.start` in `commands/lifecycle.py`. Returning from either adapter call
   alone is insufficient to promote apply evidence.
5. **Write inventory:** include `_rotate_one`, `rollback_start_bindings`, and
   `_clear_host_records`, plus direct `_sweep_unknown` mutations, scope-only
   reconciliation, remove/fallback, and prompt cleanup. Import is store-only;
   it invalidates through revision comparison and never claims backend apply.

The coordinator also corrected the inherited Python 3.9 instruction: this work
targets the declared Python 3.12 runtime and quality gates.

## Consequences

- Positive: secret-independent identity, explicit uncertainty, strict schema
  validation and source-correct snapshots support the preparation boundary.
- Negative: exclusive scoped store transactions reduce mutation concurrency;
  schema 2 prevents older Python builds from operating on these records.
- Conservative false negatives are deliberate: interrupted writes require
  explicit recovery, and delivery without sufficient backend proof stays pending.
- IA-5/AC-6 credential handling and SI-10 record validation are supported by this
  design; tests under SA-11 must establish implementation evidence. This local
  development tool is not an authorized production/hosted environment.
- Rollback does not downgrade schema or resurrect applied evidence. Use a reader
  that understands schema 2, or explicitly remove/recreate affected sandboxes.

## Short implementation test plan

For every behavior: failing test first, implementation, passing test, then a
targeted guard mutation that makes the test fail; restore and re-run. Record
commands, observed exits and assertions. Tests must prove the relevant write or
backend call ran; absence of execution is not success.

1. **Store/crash:** run a real child process through pending, value, metadata and
   commit writes; handshake at each boundary, kill the child, and inspect actual
   persisted files from another process. Prove pending survives both pre-value
   and post-value crashes, interrupted composite metadata, and metadata-only
   recovery attempts. Successful identical-value remove/re-add changes tokens.
   Exercise keychain failure results, sidecar I/O failure and all public callers.
2. **Schema/read:** schema 1 and missing service → unknown; valid schema 2;
   malformed apply/sidecar → explicit failure; older-reader refusal; reader
   leaves records byte-identical. Cover sandbox named `global`, scoped-only
   endpoint/global value, current revision changes, and environment source.
3. **Apply/failure:** assert pending is on disk before each backend effect;
   accepted restart-required modify remains pending; nonzero/timeout with
   simulated backend side effects cannot claim applied. Cover create/start gates,
   already-running start, same-binding rotation, drop/fallback, unknown sweep,
   rollback, store-only import, and stale attempt/instance promotion.
4. **Concurrency:** real processes and OS locks with deterministic barriers;
   global refeed versus scoped set, different-service updates, remove/recreate
   versus delayed completion, and crash lock release. Assert backend ordering,
   no lost binding updates and no record resurrection. Do not rely on sleeps
   alone. Run native Windows/macOS lock cases on their hosts.
5. **Exposure:** use synthetic sentinel credentials with the value store outside
   the isolated state root. Scan every state file, including temporary and lock
   files, for sentinels and representative encodings/digests; assert neither
   records nor snapshots, errors, stdout/stderr or argv contain them. Mutation
   deliberately writes the sentinel/hash to prove the scan detects it; code
   review verifies tokens have no dependency on value data.
6. **Verification:** focused `py-acq/tests` suites for store, MSB bindings, locks,
   secrets, provider credentials and lifecycle; repo-pinned ruff, mypy, bandit,
   Markdown and secrets checks for touched artifacts. Hosted CI runs the full
   suite. Two blocker-only read-only adversarial passes before push: general and
   concurrency/crash/exposure. Native MSB restart/delivery semantics, host power
   loss and cross-platform runs not executed here remain explicitly unverified.

## Links

- [State migration contract](0041m-configuration-and-state-migration-behavior.md)
- [Backend adapter contract](0040m-backend-adapter-capability-contract.md)
- [Python implementation guide](../../py-acq/README.md)
- Tracking: GSA-TTS/agentic-coding-quickstart#695; authoritative requirements in
  wz-gsa's 2026-11-20 17:08 UTC comment. Integration target:
  GSA-TTS/agentic-coding-quickstart#697.
- Coordinated ownership outside this implementation: stopped exec/shell in
  GSA-TTS/agentic-coding-quickstart#723; uninstall in
  GSA-TTS/agentic-coding-quickstart#712 and GSA-TTS/agentic-coding-quickstart#713.
