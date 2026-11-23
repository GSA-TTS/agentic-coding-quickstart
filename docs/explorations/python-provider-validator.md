# Python provider-validator adapter

`py-acq/src/acq_py/provider_validator.py` is an offline adapter, not a lifecycle
integration or a provider-code runner. It requires the independently verified
packaged preparation assets and a **preinstalled, host-trusted** interpreter.

## Contract

- `validate_bundles([absolute_manifest_path, ...], python_override=None,
  credential_bindings=None, timeout=30.0)` requires a nonempty list or tuple of
  at most eight explicit v3 manifests, matching the pinned Patterns runtime's
  `RUNTIME_LIMITS.providers`.
  Missing, unreadable, nonregular, oversized, duplicate-file and ambiguous JSON
  inputs fail closed. The pinned validator performs the full contract checks.
- `validate_empty_selection()` is the separate no-effect operation for a caller
  that has already successfully established an empty selection. Passing `[]`,
  `None`, a string, or a missing path to `validate_bundles` is not that operation.
  Neither operation searches the repository for manifests.
- The caller creates private snapshots first, including the referenced files,
  and keeps them immutable through validation and subsequent materialization.
  This adapter does not make arbitrary mutable provider directories safe against
  races, nor does its path preflight replace the pinned contract validator.
- `verify_assets()` is mandatory before interpreter probing. No user-authored
  asset inventory, validator or schema directory is accepted. Asset verification
  failures propagate as fixed `AssetError`s. Credential bindings default to the
  verified packaged file. An optional `credential_bindings` path accepts a
  caller-owned immutable merged binding snapshot: an absolute, readable,
  non-symlink regular file, nonempty and at most 1 MiB. Bindings are data, not
  executable code; their contract is checked by the pinned CLI. The caller owns
  the trust decision and immutable snapshot, including its ancestor directories.
- One isolated metadata probe requires exactly PyYAML 6.0.3 and jsonschema
  4.26.0. One subsequent pinned CLI call contains **all** selected `--bundle`
  arguments, explicit `--schema-dir` and host-owned `--credential-bindings`.
  Both commands use `-I`. No installation, Bash invocation, network operation,
  provider normalizer execution, state write or lifecycle change is introduced.

## Runtime resolution and bounds

The explicit `python_override` or `ACQ_PROVIDER_INPUT_PYTHON` must be one absolute
executable filename; it is not a shell command and never searches PATH. The
lexical path is retained so resolving a venv symlink cannot discard its installed
packages. Without an override, resolution follows the existing setup layout:
`ACQ_PROVIDER_INPUT_DATA_DIR`, or the absolute XDG data base (default
`~/.local/share`) plus `acq/provider-input-validator`, then
`provider-input-validator.current/{bin/python3,Scripts/python.exe,python.exe}`.
Relative XDG values are ignored; relative explicit overrides are refused. There
is no bootstrap fallback. The host operator remains responsible for trusting the
interpreter and its installed packages; metadata versions are not a signature.

Native Windows is refused before process creation: this narrow implementation
does not pretend that POSIX pipe selectors provide Windows process guarantees.
The existing `hostexec.run_captured` does not cap collected output, so this module
owns a small POSIX-only capture helper. It uses null stdin, a fixed `/` working
directory, a private process group and a combined 64 KiB stdout/stderr cap. The
child environment is exactly `PATH=/usr/bin:/bin`, `LANG=C`, `LC_ALL=C`: no host
secrets, proxies, loader preloads, Python overrides or shell startup environment
are inherited. One monotonic deadline starts before bounded input inspection and
is shared by asset verification, binding inspection, probe and validation; it is
checked around file inspection and before each process. Filesystem calls are not
interruptible by this deadline, so a stalled filesystem remains an OS-level
limitation. The finite timeout is at most 300 seconds. On completion or failure
it kills the host-validator process group,
closes pipes without unbounded draining, and allows at most one additional second
to reap the direct process. Escaped process groups and abrupt parent termination
are not contained by this helper; it is not a sandbox for a malicious interpreter.
There is **no claim that killing a CLI cleans up guest processes**.

Diagnostics are fixed refusals: neither raw subprocess output, candidate paths,
package metadata strings nor validator tracebacks are surfaced. Captured output
is bounded and discarded by the public API, including on successful validation.

## Validation status and handoff

`py-acq/tests/test_provider_validator.py` contains real bounded subprocess tests
using explicitly synthetic executables and synthetic distribution metadata, plus
negative manifest/path checks and a set-wide argument assertion. These establish
adapter behavior, not upstream validator/schema qualification. Asset tests check
the fail-before-probe seam and tampering with a private copy of the real packaged
validator; the asset lane owns the full inventory/digest tamper suite.
Additional fixtures exercise the minimal-environment canary, default and explicit
host binding arguments, invalid binding paths, the eight-provider bound and input
inspection consuming the shared deadline. SIGTERM cancellation cleanup remains a
review/qualification question; no signal-handling framework is added here.

No tests or commands were executed on the host during implementation. The primary
must combine the preparation-assets lane and run this suite and the repository's
applicable quality gates in its reviewed isolated environment before acceptance.
This slice does not enable v3 manifests in existing lifecycle paths.
