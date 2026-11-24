# Local Python SDK preparation transport experiment

This is an **unpublished, unqualified adapter spike**, not activation of a product
dependency or a replacement for the frozen candidate. No SDK dependency, resolver,
CLI wiring, runtime installation, sandbox lifecycle operation, HTTP client, store,
file writer, generic broker or interactive terminal is added. AI assisted this
local implementation. No code or tests were executed during this edit-only task.

## Narrow interface and caller contract

`py-acq/src/acq_py/sdk_preparation.py` exposes asynchronous `prepare` accepting an
already connected SDK `Sandbox`, host-established `InvocationIdentity`, a fresh
caller-owned `CleanupState`, explicit guest environment, five trusted guest paths,
and finite execution/cleanup budgets. It uses `runtime_preparation.build_argv` and
`parse_result`; results are ephemeral protocol evidence, **not launch authority**.
No guest PID, output identity or SDK object establishes host identity.

The caller exclusively owns backend/runtime selection, name resolution and
connection, host identity and nonce, lifecycle locks, trusted artifact and config
digests, mount/path ownership, symlink exclusion, clean guest baseline environment,
CA provisioning and trust policy. SDK `env` values are overrides: passing a clean
dictionary does not clear ambient guest environment. Never supply real host
credentials. This adapter neither reads host environment nor authenticates guest
success claims. The caller must revalidate current identity under its barrier
before any consumption and enforce single use.

Actual SDK selection is `await Sandbox.get(name)`, then
`await handle.connect(timeout=...)`, outside this module. In 0.7.16 the default
execution backend opens a new agent connection **by name**. An old Sandbox object
does not fence arbitrary native name replacement. Cooperative lifecycle locks
exclude only cooperating writers. Qualification must explicitly test this race;
do not infer instance binding from the API's method names.

## Pinned surface

The lazy module seam loads only a preinstalled `microsandbox` reporting `0.7.16`
and obtains `Stdin` and `ExecEventType`. The exact release source reviewed was
commit `0fefb8f2fed3da964819afd222227dc1c5b0e78f`, tree
`c4e53c082f3513c88652253f964d00d485ca3499` (Python `sandbox.rs`, `exec.rs` and
release integration tests). Source identity is not native reproducibility proof;
the version check is not package integrity or trusted-install verification.

The execution is exactly one `sandbox.exec_stream(absolute_cmd, args, user="agent",
env=explicit_copy, timeout=budget, stdin=Stdin.null(), tty=False)`. No shell is
introduced. `ExecHandle.recv()` is the single consumptive surface. Control uses
the separately awaitable `ExecHandle.kill()`; this is **not** a managed job or
`Sandbox.kill()`. `wait`, `collect`, stdin writers, signal and resize are not
needed for preparation and are not called. No resolver configures SDK globals.

## Observation, bounds and cancellation

- Require one well-shaped STARTED before output or EXITED. Validate the PID as
  a non-boolean positive unsigned 32-bit integer, but never use it for control or
  identity. EXITED is a non-boolean signed 32-bit integer. Reject duplicate,
  unknown, malformed and out-of-order events, including events after EXITED.
- Consume binary stdout/stderr without text conversion. SDK `Vec<u8>` getters
  may expose `list[int]`; every element is checked without accepting booleans.
  Retain stdout only; count both streams against a combined cap no greater than
  the preparation protocol's 1024-byte bound. Oversize is refusal, never truncation
  followed by acceptance. Stderr and SDK/guest diagnostics are not returned.
- Only EXITED, then stream closure, then the existing strict success parser can
  yield a result. FAILED, EOF without EXITED, and dispatch errors are not proof
  that no guest process ran. STDIN_ERROR refuses even though it is nonterminal.
- A monotonic budget covers dispatch and receive, including fast/empty events;
  an independent, finite cleanup budget does not restart after cancellation.
  A timed-out/cancelled wait retains its one in-flight receive for cleanup rather
  than starting a second reader. Await control kill (unless exit was observed),
  then drain through observed EXITED and closure. Kill acknowledgement alone is
  not termination proof. Cleanup continues to enforce byte and protocol bounds.
- Cleanup runs inline, with cancellation shielded at individual SDK waits using
  `asyncio.wait`. Repeated cancellation is recorded, not allowed to reset the
  deadline or orphan a cleanup supervisor. The original `CancelledError` is
  re-raised, including its identity and arguments. If cancellation first arrives
  during error cleanup, cancellation becomes primary. No automatic redispatch.
- Dispatch starts with `CleanupState.dispatched=True` and `uncertain=True`, before
  calling `exec_stream`. The state records STARTED, confirmed terminal and closure
  without mutating immutable invocation identity. Inspect it on **every** exit,
  including cancellation. `UncertainExecution` is a distinct error; cancellation
  with uncertain cleanup also carries that error as its cause. Caller must
  quarantine the attempt/instance, block launch/reuse/retry, retain its lifecycle
  barrier or equivalent exclusion, and arrange operator reconciliation. The
  adapter itself performs no quarantine storage or lifecycle actions.

Bounds here apply **after an SDK event is yielded**, not to native buffering or
allocation. Legacy peers can negotiate unbounded SDK queues. Cancelling a Python
future does not prove its Rust operation or guest process stopped; expiry abandons
those waits conservatively with uncertainty, not a termination claim. Python
event-loop responsiveness and cancellation-cooperative SDK awaitables are required;
this code cannot preempt a blocked native call or hostile coroutine. No wall-clock
guarantee against such behavior is claimed. Native cancellation, queue limits and
handle acquisition races still require independent qualification.

## Adapter-only tests and remaining qualification

`py-acq/tests/test_sdk_preparation.py` uses synchronous pytest tests wrapping
`asyncio.run`, with SDK-shaped event/control fakes injected at `_sdk_types`. No
additional test dependency is used. Cases cover fast split output, binary stderr,
malformed bytes/events/PIDs/statuses, ordering, combined caps, deadlines, blocked
receive, kill failure, no exit, cancellation during acquisition/receive and repeated
cancellation. These are **adapter-only** assertions, not PyO3/native proof.

Validation transcript for this editing task: **not run** (commands, source execution,
installation and commits prohibited). The next owner should statically review all
three files, then run the focused tests and applicable repository quality suite
only in the independently justified workspace sandbox. No passing result is claimed.

Before any production activation: separately approve dependency packaging and
architecture, qualify pinned native wheels on supported hosts, explicit offline
runtime/backend selection, actual stream byte/control/backpressure/cancellation
semantics, acquisition/name-replacement races and client-loss reconciliation.
Test real target guest CA/proxy/model refresh and bounded inference. Interactive
TTY/signal/resize and a generic transport remain deferred until preparation is
qualified; this spike provides no evidence for them. The local disposable Linux
import check did not execute a stream, and no public fake-peer injection seam was
found for the high-level Python API. Never fabricate a native runtime catalog or
socket and label it SDK qualification.

## Private process loader (local spike only)

`py-acq/src/acq_py/sdk_runtime.py` adds an inert-on-import, one-shot
`load_private_sdk(SDKRuntimeConfig) -> LoadedSDK`. It does not change the frozen
preparation adapter. This is not backend activation, packaging approval, a global
dependency, CI integration, an installer or a generic RPC service.

The trusted caller must own a **fresh, exclusive process** and an immutable private
payload for its entire lifetime. Supply canonical absolute paths (no symlink
components), the exact `0.7.16` extracted package and distribution metadata, an
independently trusted manifest digest, the payload-contained MSB executable and
firmware, an existing private runtime home, and an existing private config file
containing only the JSON object `{}`. The loader never creates these files. It
rejects group/world-writable payload entries, hardlinks, symlinks, special files,
bytecode and `.pth` files. Current scope is POSIX; other platforms refuse.

### Trust and resource bounds

The payload-root file `sdk-manifest.json` has this exact schema (all regular
payload files except the manifest itself must be listed):

```json
{
  "schema": 1,
  "version": "0.7.16",
  "files": {
    "microsandbox/__init__.py": {"size": 123, "sha256": "<64 lowercase hex characters>"},
    "microsandbox-0.7.16.dist-info/METADATA": {"size": 456, "sha256": "<64 lowercase hex characters>"}
  }
}
```

The numbers/digests above are illustrative, not a usable trust manifest. The
expected SHA-256 covers the manifest's exact bytes and must arrive separately
from an explicit trusted caller, never be read back from the same payload as its
own authority. Duplicate JSON keys, unknown fields, unsafe paths, missing or extra
files, extra distributions, wrong metadata name/version and mismatched hashes
refuse before SDK import. Files are restricted to `microsandbox/` and the exact
distribution metadata directory. The package import origin is checked before
import, and all imported SDK module origins and normal distribution discovery are
checked afterward. No `site.addsitedir` or `.pth` processing is used.

Limits are 1 MiB manifest/metadata, 1,024 files, 1,024 directories, depth 16,
64 MiB per payload file, and 256 MiB total file content. Hashing streams chunks of
at most 1 MiB through bounded regular-file reads. These limits accommodate the
inspected Linux ARM wheel's approximately 109 MB unpacked payload (largest file
approximately 46 MB); they are not an archive decompression policy. Acquisition
and safe extraction are outside this loader. Build the private payload without
compiled caches and start the child with `-B`; arbitrary preexisting caches are
not silently ignored. The wheel's SBOM is covered when present, not treated as a
complete vulnerability or license qualification.

Digest checks are **not** a sandbox for untrusted Python/native code. The manifest
signer/caller, interpreter, standard library, import machinery, dynamic linker,
and all payload code remain trusted. A writable owner can race verification and
subsequent imports; file checks do not replace caller-enforced immutability and
exclusive ownership. Native dependent libraries are not transitively authenticated
by this Python manifest. Never use an untrusted directory as the private payload.

### Process-wide selection and failure

Before calling the loader, establish exactly `MSB_PATH`, `MSB_LIBKRUNFW_PATH`,
`MSB_HOME`, and `MSB_CONFIG_PATH` matching the supplied paths; all other `MSB_*`
variables refuse. Bytecode writes must already be disabled. Dynamic-loader
override variables and Python startup overrides refuse. The library verifies the
environment rather than mutating its caller's environment. Start a child with a
minimal explicit environment, not a copy of the host credential environment.

Any ambient `microsandbox` module **or submodule**, even a `None` module-cache
entry, refuses before initialization. The first attempt is serialized and marks
the process attempted before validation/import. Partial failure is poisoned:
there is no unimport, global reset, fallback, reinstall or retry. Successful
identical repeats return the same handle; different configuration requires a new
process. The caller must not mutate environment, SDK globals, import paths or
payload after initialization, nor reload the loader to evade this lifetime rule.

Actual public wheel evidence confirms `set_default_backend(BackendKind.LOCAL)`;
this is called before the first default-backend read. Then
`default_backend_kind()`/`default_backend_info()` must report local, with no URL
or profile, and `resolve_runtime()` **without per-call overrides** must return
the exact caller binary and firmware. No Rust-only setter names are assumed, no
installer/ensure-runtime call occurs, and PATH discovery is not used. The public
`RuntimeConfig(home, msb_path, libkrunfw_path)` is not a process-default setter.

**Remaining acceptance gap:** the inspected public `ResolvedRuntime` exposes
binary/firmware/origin, not effective home. Exact `MSB_HOME` plus an empty user
config establishes input intent but does not by itself rule out a managed-policy
home override. The primary must provide an inspected effective-home accessor
before this loader can claim effective-home verification. This spike must not be
used to authorize preparation or native execution while that criterion is open.

### Fixed disposable probe and tests

The module entry point supports only one operation: bounded stdin JSON
`{"operation":"load","config":{...SDKRuntimeConfig fields...}}`. It emits a
small fixed success/refusal JSON record, never native objects, paths, tracebacks
or native diagnostics. The disposable probe suppresses SDK stdout/stderr at file
descriptor level; the library API does not redirect process output. Input is
capped at 16 KiB. The caller must close stdin and externally impose a process
deadline; a byte bound does not preempt blocked input or native code. There is no
arbitrary execution operation, generic command forwarding or lifecycle call.

`py-acq/tests/test_sdk_runtime.py` clearly labels its fake SDK fixtures. The
optional actual-wheel load-only subprocess test is selected with
`PRIVATE_SDK_PROBE_CONFIG` (absolute path to trusted JSON config fields) and
`PRIVATE_SDK_PROBE_PYTHON` (explicit Python executable). These non-`ACQ_*` names
survive the existing test environment scrub; the child receives a fresh explicit
environment. The parent harness enforces a 30-second timeout. Skipping this test
does not provide actual-wheel evidence, and passing it does not qualify native
streaming, cancellation, isolation or guest execution.

Worker validation for these loader edits: **not run**. Commands, tests, installs,
commits and pushes are prohibited in this edit-only task. The primary owns static
review and all execution in the approved workspace sandbox; the frozen adapter
and its tests were not modified.

## Explicit-context two-package loader prototype (0.8.2 local spike)

`py-acq/src/acq_py/sdk_context_runtime.py` adds a separate, inert-on-import
`load_private_sdk_context(SDKContextRuntimeConfig) -> LoadedSDKContext` prototype
targeting the `0.8.2` split-wheel architecture (`microsandbox==0.8.2` plus
`microsandbox-core==0.8.2`) and explicit `LocalContext` binding. The existing
`0.7.16` preparation adapter (`sdk_preparation.py`) and single-package loader
(`sdk_runtime.py`) remain untouched for side-by-side comparison.

### Closed two-package payload and dependency closure

In `0.8.2`, the platform-specific `microsandbox` wheel ships the native PyO3
extension (`_microsandbox.abi3.so`) and bundled runtime binaries (`msb`,
`libkrunfw`), registers itself as the native provider in the pure-Python
`microsandbox_core` package, and re-exports the `microsandbox_core` public
surface. The private payload directory must contain both extracted packages and
both distribution metadata directories:

- `microsandbox/` and `microsandbox-0.8.2.dist-info/`
- `microsandbox_core/` and `microsandbox_core-0.8.2.dist-info/`

Every regular file under `payload_root` (except `sdk-manifest.json` itself) must
appear in the caller-authenticated manifest (`version: "0.8.2"`) and reside under
one of those four top-level directories. Before importing either module,
`_metadata` verifies that `importlib.metadata.distributions(path=[payload_root])`
discovers **exactly two** distributions located at `payload_root`:

- `microsandbox` at version `0.8.2` with exact `Requires-Dist` equal to
  `["microsandbox-core==0.8.2"]`
- `microsandbox-core` at version `0.8.2` with no `Requires-Dist` entries

Any missing core package, extra distribution, version mismatch, or dependency
mismatch refuses before import. Preloaded-module checks refuse if `sys.modules`
already contains `microsandbox`, `microsandbox.*`, `microsandbox_core`, or
`microsandbox_core.*` (including `None` cache entries). Both package specs are
verified before import, and post-import `_origins` checks verify that every
loaded module in either namespace resolves strictly inside its respective package
directory (`payload_root/microsandbox` or `payload_root/microsandbox_core`) and
is listed in the verified manifest.

### Explicit `LocalContext` binding without default-backend mutation

Unlike `0.7.16`, `load_private_sdk_context` never calls `set_default_backend` or
mutates process-wide backend selection. Instead, it verifies
`sdk.version() == "0.8.2"` and constructs an explicit local context:

```python
context = sdk.LocalContext(home=config.home, config_path=config.config_path)
```

It verifies that `context` is an instance of both `sdk.LocalContext` and
`sdk.Context`, that `context.kind` equals `sdk.ContextKind.LOCAL` (`"local"`),
and that `context.sandboxes.context.kind` is also bound to `LOCAL`. Constructing
`LocalContext` binds `home` and `config_path` lazily without opening or migrating
the SQLite catalog (`db/msb.db`). Because `LocalContext(home=..., config_path=...)`
does not accept `msb_path` or `libkrunfw_path` parameters, the loader separately
constrains the runtime binary and firmware via `MSB_PATH` and `MSB_LIBKRUNFW_PATH`
environment verification and confirms that `sdk.resolve_runtime()` returns those
exact payload-contained paths.

**Remaining acceptance gap:** Python `LocalContext` exposes `.kind` and resource
collections (`.sandboxes`, `.volumes`, `.snapshots`, `.checkpoints`), not
`LocalContext::config().home()`. In `0.8.2` Rust `prepare_for_local_backend`,
machine-wide managed policy (`/etc/microsandbox/managed.json` on Linux,
`/Library/Application Support/microsandbox/managed.json` on macOS) overlays
`LocalContext(home=...)` last. Passing `home` and an empty `config_path`
captures explicit constructor intent without mutating process-wide backend
defaults, but does not by itself prove effective-home absence of managed
overrides; this load-only prototype therefore claims no execution authority.

### Disposable 0.8.2 load-only probe and tests

Running `python -B -s -P -m acq_py.sdk_context_runtime` reads the same bounded
16 KiB JSON load request on stdin, verifies idempotent `load_private_sdk_context`
execution and `context.kind == "local"`, confirms that no `db/` directory or
`*.db*` catalog files were created in `config.home`, and writes
`{"ok":true,"version":"0.8.2","context":"local"}` on exit `0` or
`{"ok":false,"error":"sdk-context-runtime-refused"}` on exit `1`.

`py-acq/tests/test_sdk_context_runtime.py` exercises fake two-package fixtures
covering idempotent load, keyword-only `LocalContext` construction, absence of
`set_default_backend` calls, empty `home` preservation, preloaded-module refusal
across both namespaces, two-package dependency closure, cross-package origin
contamination, and poison-on-failure semantics. Its optional actual-wheel
subprocess probe is gated by `PRIVATE_SDK082_PROBE_CONFIG` and
`PRIVATE_SDK082_PROBE_PYTHON` and asserts that `config.home` remains empty after
the load-only probe completes.
