# Python fresh-preparation protocol consumer

Status: experimental, protocol-only slice. No backend or launch path calls this
module. It is not end-to-end fresh preparation, authentication, or reuse authority.

## Implemented boundary

[`runtime_preparation.py`](../../py-acq/src/acq_py/runtime_preparation.py) consumes
the Patterns guest preparation CLI's actual protocol. The producer sources are
`integrations/isolation/acq-kits/opencode/files/home/opencode-config/runtime-preparation-source.mjs`
(`runtimePreparationMain` and its top-level failure handler) and
`integrations/providers/usai/scripts/runtime-model-outcome.mjs` (`parseFailure`)
in the agentic-coding-patterns repository.

- `InvocationIdentity` is a frozen, slotted record of host-established attempt
  nonce, sandbox instance, exact generation, routing digest, artifact SHA-256 and
  base-config SHA-256. Its three identifiers are opaque ASCII tokens (1–256
  characters, beginning with a letter or digit, then letters, digits, `.`, `_`,
  `:`, or `-`); digests are exactly 64 lowercase hexadecimal characters.
- `build_argv` takes five explicit absolute guest POSIX paths: trusted Node,
  standalone artifact, provider root, global config directory and base config.
  It returns a tuple with fixed flags and `--mode live-required`, without shell
  evaluation, environment defaults, extra flags, credential values or I/O.
  Paths must be normalized, non-root, printable and at most 4096 characters,
  without backslashes or `..` components. Spaces remain part of one argument.
- `parse_result` requires a real integer exit status and at most 1024 bytes of
  strict UTF-8 stdout. Success requires exit zero and exactly `sourceOutcome`
  equal to `live` and `metadataOutcome` equal to `not-requested`, `unavailable`,
  or `available-unverified`. Metadata is never treated as verified membership.
  Duplicate keys, non-finite constants, non-string values, extra fields,
  malformed JSON, snapshot results and oversized output refuse.
- Every nonzero exit fails. Exit 1 may carry the closed five-key
  `acq-runtime-model-outcome/v1` failure envelope. Only the producer's exact
  stage/reason/class combinations enter error diagnostics. Transient failures
  still fail; neither transient classification nor an old file permits reuse.
  Other exits (including signal exits) yield a fixed abnormal-exit error.
  No stderr is accepted, echoed or stored; malformed stdout is not echoed.
- The frozen result binds the successful protocol response to the expected
  host identity. `require_current(result, current)` compares all six fields
  before consumption, rejecting a changed attempt, instance, generation,
  routing, artifact or base config. No persistence, global result cache or
  cross-invocation reuse is provided.

These are ordinary Python records, not unforgeable capabilities. Shape checks
and equality do not authenticate an artifact, a guest, provider membership or
host facts. The producer does not echo identity: the host must associate the
captured response with the exact invocation it started, not relabel saved output.
Within-invocation repeated comparison is possible; this pure API does not mint a
single-use token or guard against a malicious Python caller.

## Host integration prerequisites (not implemented)

The next integration must establish these conditions before enabling a launch
barrier. None is implied by a passing parser test:

1. **Validated assets and packaging:** supply the standalone producer artifact,
   its validator assets and the required v3 packaging. Verify artifact and base
   config bytes against trusted digests. This slice does not update bundled kits,
   kit specs, provider-input formats, pins or staging/mount adapters.
2. **Immutable host identity:** mint a new unpredictable nonce for every attempt;
   identify the actual sandbox instance rather than a reusable name; bind the
   exact immutable generation and effective routing. Do not use a `current`
   alias. Digests must come from trusted bytes/canonical routing inputs, never
   credential values. Map the generation identifier to the exact guest root.
3. **Trusted guest execution:** verify paths, ownership, permissions, symlink
   boundaries and read-only assets in the guest namespace. Lexical path checks
   cannot do this. Keep credentials out of argv and logs. Provide an approved
   guest environment and CA configuration, with no injected Node preload hooks.
4. **Bounded execution contract:** an accepted backend callback or host adapter
   must execute this argv without a shell, cap stdout *during collection*, bound
   or discard stderr without exposing it, enforce an overall deadline, propagate
   cancellation and supervise/await all children through termination. Only then
   pass its completed status and bytes to `parse_result`. Checking the length of
   already captured bytes does not make an uncontrolled subprocess bounded.
   This module does not implement a runner, timeout or cancellation mechanism.
5. **Lifecycle and reload:** hold a host lifecycle barrier across identity
   establishment, execution, current-identity comparison and consumption. Drop
   the result when the attempt ends or any identity component changes. A retry
   gets a fresh nonce and preparation; failure never revives prior evidence.
   Launch gating, reload, crash recovery and cancellation-safe lifecycle changes
   remain separate work. There is no SDK or dispatcher here.

## Offline validation

[`test_runtime_preparation.py`](../../py-acq/tests/test_runtime_preparation.py)
covers valid producer shapes, every failure classification, invalid combinations,
nonzero exits, strict parsing and byte boundaries, runtime type checks, lexical
paths, all identity mismatches, immutability and static import-side-effect checks.
Fixtures are synthetic protocol documents, not evidence of a live producer run.

The primary should run the following inside the reviewed workspace sandbox from
`py-acq/`, with the repository's pinned tooling, then run applicable wider gates:

```sh
python -m pytest tests/test_runtime_preparation.py
python -m ruff check src/acq_py/runtime_preparation.py
python -m mypy src/acq_py/runtime_preparation.py
python -m bandit -c pyproject.toml src/acq_py/runtime_preparation.py
```

No host execution or test pass is claimed by this implementation slice.
