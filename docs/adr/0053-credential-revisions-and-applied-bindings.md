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

Approved for implementation by the user through the coordinator, including the
authority amendment below; AI-assisted authorship by OpenCode. Frontmatter stays
proposed until the integration review accepts the record. The number is
provisional pending integration renumbering.

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
Independent value/metadata location overrides or a backend switch can select a
different authority without changing the state directory or credential key.

## Decision Drivers

- Persist neither credential values nor hashes or any other derivation of them
  in revision sidecars or binding records, including temporary files and errors.
- Resolve source, scope, authority, revision and the actual delivered endpoint together.
- Make incomplete store writes and unconfirmed backend changes explicit.
- Preserve revocation knowledge and prevent stale writers from overwriting it.
- Use the existing portable advisory locks and atomic-write conventions, with
  Python 3.12 as declared in `py-acq/pyproject.toml`.
- Keep lifecycle preparation receipts, provider generation, routing identity and
  trusted artifact pins in the preparation owner's layer.

## Considered Options

1. **Separate apply file:** duplicates binding ownership and synchronization.
2. **Add fields to schema 1:** older writers silently discard unknown fields.
3. **HeldRecord schema 2 plus revision sidecars:** keeps binding ownership together,
   rejects older readers, and distinguishes committed from incomplete changes.

## Decision Outcome

Choose option 3, Python-first, with reuse unconditionally disabled even after apply.

### Store revision transaction

Write `<state>/secret-rev/<key>.json`, where `<state>` is `state.state_dir()` and
`key` is a validated `acq.<service>` or `acq.<sandbox>.<service>` store key. Tests
must isolate this root separately from the value-store override. Sidecar schema 1
has exactly `schema`, `committed`, `pending`, and `authority`. The schema is the
integer 1; committed/pending are each null or an opaque `r:` token generated
independently of the credential using at least 128 random bits. A missing record
means unknown; malformed or unreadable state is an explicit validation/read
failure. No reader repairs it. A committed deletion leaves a non-secret revision
tombstone; remove/re-add of the identical value still produces a new token.
`authority` identifies the committed revision's value and exact-scope metadata
stores as described below. Pending never changes that committed identity. A
two-field sidecar from the original proposal is legacy unknown, not schema 1.

All Python value and endpoint mutations pass through revision-aware choke points
in `store`, `delete`, `meta_store`, `meta_delete`, and `set_secret`:

1. Validate inputs and acquire the required store transaction lock.
2. Atomically persist `pending = new_token`, retaining the previous committed
   token or null. Failure here prevents any value or endpoint mutation.
3. Persist the requested value/deletion and endpoint changes. `set_secret` is one
   composite transaction: it cannot commit between its value and metadata writes.
   Composite deletion likewise covers both the value and endpoint removal.
4. Only after confirmed persistence and rechecking authority markers, atomically
   write `committed = new_token`, its `authority`, and `pending = null`.
   Never infer successful deletion from a discarded
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

### Authority amendment: identify the actual stores

An authority is null (unknown) or an object with `kind`, `id`, and `location`.
`id` is an independent random `a:` token of 128 bits. `location` is SHA-256 of
the normalized absolute real directory path, never of credential data; paths
and environment values are not persisted. `kind` distinguishes `file`, `dpapi`,
`metadata`, and `provider-pin`. Path fingerprints are not secret protection.
The revision sidecar's `authority` is `{value: authority-or-null,
metadata: authority-or-null}` for its exact key; the apply identity additionally
records the endpoint actually selected, which may come from another scope.

For file/DPAPI stores, put a schema-1 marker containing that authority object in
`<file_dir>/.acq-authority-<kind>.json`; use a separate metadata marker in
`<meta_dir>/.acq-authority-metadata.json`. Marker kind and location must match
the current resolver's backend and real directory, including independently
selected metadata directories. Do not identify the value store from its index.
Built-in endpoints (github, an unpinned usai) use a fixed `builtin-v1` tag plus
exact ENV@HOST. Clarification made during implementation: provider-pin records get
no marker yet, so an endpoint taken from any pin layer reads unknown.

Reads never mint markers. A missing marker or mismatched kind/location yields
unknown; malformed/unreadable marker contents fail explicitly without echoing
contents. Only a successful explicit store/pin write establishes a usable marker
and committed revision. A marker can be published before the value write, but
cannot legitimize an old revision: a crash still leaves the revision pending or
its authority absent/mismatched. A write can replace a location-mismatched marker
with a fresh identity after invalidation, never reuse its old token. All existing
keys without matching revision evidence remain unknown after marker creation.

The current macOS and Linux keychain helpers do not report the selected keychain
or collection identity. A marker beside the index cannot establish that identity.
Consequently their value authority is null and snapshots report unknown revision
even after a successful write; no native directory or marker is invented. This is
a deliberate refinement of the coordinator's per-backend marker suggestion.
macOS legacy-file fallback and Windows legacy-plaintext fallback likewise report
unknown, even if a file marker exists. DPAPI encrypted-file reads use the actual
file directory marker; a failed decrypt establishes no value identity.

Selecting pre-existing store B with state S formerly used for A never inherits
A's revision: B's missing marker or different identity yields unknown. A backend
switch is also unknown until that backend's authority can be established and a
new write commits it. Endpoint-directory switches, including absent metadata
falling through to a pin, cannot preserve evidence from the previous endpoint
authority. Returning to A after B overwrote the sidecar remains unknown until a
new write. Copying A's marker to a different real directory fails location match.

Marker creation and validation run within store exclusion before the held-record
lock. Use the private atomic-write protocol above; re-read markers before commit
and promotion. A missing marker is not repaired by snapshot, metadata-only writes
cannot establish an unknown value authority, and authority changes cannot clear
an interrupted transaction. Cooperating invocations use the same state-root lock;
different state roots sharing stores and out-of-band marker/value replacements
are unversioned writers, covered by the unconditional reuse prohibition.

### Effective source and endpoint

One resolver supplies an in-memory value separately from its non-secret identity:
`(source, scope, authority, revision, env, host)`. Source is `sandbox`, `global`, or
`environment`; scope is the actual sandbox name for a sandbox source and null
otherwise, so a sandbox named `global` is unambiguous. Value selection preserves
sandbox-over-global precedence and the existing restricted provider-environment
fallback. Environment source always has null revision and unknown apply status.
The effective `authority` has `value` and `endpoint` identities. Endpoint identity
includes its layer, exact scope and store marker (or the built-in version tag).

Endpoint selection preserves the existing metadata and provider-pin rules.
Value scope and endpoint scope need not coincide: a sandbox endpoint may accompany
a global value. The resolver checks pending metadata transactions that affect
the selected endpoint as well as the selected value, and captures exact ENV@HOST.
Endpoint-only changes therefore invalidate equality even when the value's own
revision did not change. Unreadable candidates must not turn into positive
unchanged evidence. The old `BoundSecret.own` Boolean is not source evidence.
Recompute authority from the same value/endpoint reads; never trust the sidecar's
authority without matching the current stores. Any missing, mismatched or unknown
participating authority yields null effective revision and unknown status.

### HeldRecord schema 2

Keep `<state>/msb-secret-bindings/<existing-name-key>.json` and its existing
`sandbox`, `bindings`, `complete`, and `services` fields. Add:

- `instance`: an independent random token minted for every create attempt before
  MSB mutation. Same-name recreation never inherits prior apply evidence. An
  adopted legacy record starts with unknown evidence under a fresh local token;
  this is acq identity, not proof of an MSB-native instance identifier.
- `apply`: a service-keyed object. Each entry contains `source`, `scope`, `env`,
  `host`, `authority`, `revision`, `applied_revision`, `attempt`, `status`, and `status_at`.
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
   attempt tokens. Also compare the captured source/scope/authority/revision/endpoint to
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
Unknown or mismatched authority also reports unknown, not merely pending, and
cannot promote applied evidence from store A as evidence for store B.

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
Authority markers are acq-owned metadata beside their respective stores, including
override locations. Uninstall follows those stores' ownership/retention policy;
it must not recursively remove an operator-selected store directory. Marker
removal invalidates evidence and never deletes credentials by itself.

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

The coordinator confirmed the declared Python 3.12 runtime and quality gates.

## Consequences

- Secret-independent identity and strict validation support preparation snapshots.
- Exclusive transactions reduce concurrency; schema 2 rejects older readers.
- Interrupted writes require recovery; unproven delivery stays pending.
- Keychain values, fallback reads and unmarked legacy stores have unknown
  authority; file/DPAPI markers prove cooperative location identity only.
- IA-5/AC-6/SI-10 guide the design; SA-11 tests establish implementation evidence.
- This is a local development tool, not an authorized hosted environment.
- Rollback requires a schema-2 reader or explicit sandbox removal/recreation.

## Short implementation test plan

For every behavior: red, implement, green, mutate its guard to prove red, restore
and re-run. Record commands, exits and assertions proving the relevant operation ran.

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
5. **Authority:** real two-store A-then-B test with a fixed state root, B both
   unmarked and previously marked; copied-marker/different-location refusal;
   backend switch; macOS file fallback; Windows legacy fallback; missing marker
   and legacy sidecar; independently switched endpoint metadata; pin-layer change.
   Assert old apply evidence never equals B's identity. Each gets a guard
   mutation; include crash during marker creation and marker change before commit.
6. **Exposure:** use synthetic sentinel credentials with the value store outside
   the isolated state root. Scan every state file, including temporary and lock
   files, for sentinels and representative encodings/digests; assert neither
   records nor snapshots, errors, stdout/stderr or argv contain them. Mutation
   deliberately writes the sentinel/hash to prove the scan detects it; code
   review verifies tokens have no dependency on value data. Also scan every
   authority marker and its temporary files outside state, leaving actual value
   files out of that non-secret scan; prove injected leaks there are detected.
7. **Verification:** focused `py-acq/tests` suites for store, MSB bindings, locks,
   secrets, provider credentials and lifecycle; repo-pinned ruff, mypy, bandit,
   Markdown and secrets checks for touched artifacts. Hosted CI runs the full
   suite. Two blocker-only read-only adversarial passes before push: general and
   concurrency/crash/exposure. Native MSB restart/delivery semantics, host power
   loss and cross-platform runs not executed here remain explicitly unverified.

## Links

- [State migration contract](0041m-configuration-and-state-migration-behavior.md)
- [Backend adapter contract](0040m-backend-adapter-capability-contract.md)
- [Python implementation guide](../../py-acq/README.md)
- Requirements: GSA-TTS/agentic-coding-quickstart#695, wz-gsa's 2026-11-20 17:08 UTC comment.
- Integration: GSA-TTS/agentic-coding-quickstart#697; stopped exec/shell: GSA-TTS/agentic-coding-quickstart#723.
- Uninstall ownership: GSA-TTS/agentic-coding-quickstart#712 and GSA-TTS/agentic-coding-quickstart#713.
