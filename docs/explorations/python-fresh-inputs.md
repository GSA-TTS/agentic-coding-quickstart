# Packaged Python fresh inputs

`py-acq/src/acq_py/fresh_inputs.py` stages **only** the packaged USAi/OpenCode
profile for the MSB coordinator. It is not an arbitrary provider importer or a
launch lifecycle. The caller must admit that exact profile before calling it.
No provider code, normalizer, download, credential value or store is involved.

## Interface and ownership

- `prepare(name: str) -> PreparedInputs` returns a complete, unpublished
  generation under `provider_input.input_root("msb", name)/generations`.
- `read_existing(name: str, generation: Path) -> PreparedInputs` accepts the
  **absolute exact backend mount source**, not `current`, a guest path or a
  generation belonging to another sandbox. It reconstructs the receipt only
  after closed-inventory and byte-digest checks.
- Frozen `PreparedInputs` contains `generation: Path`, `guest_root: str`,
  `routing_digest: str`, `artifact_sha256: str`, `base_config_sha256: str`,
  `guest_artifact: str`, and `guest_base_config: str`.
- Use `provider_input.msb_flags(result.generation)` for the read-only mount.
  Runtime and base are at the generation root; provider data stays beneath
  `models/providers/usai`. `guest_root` is the generation root (the runtime's
  provider-input root), not its `models/providers` subdirectory.
- The coordinator owns backend acceptance, `provider_input.publish`, discard of
  unused generations, credentials, preparation, activation and lifecycle state.
  Neither helper reads or publishes the mutable `current` pointer.
- `FreshInputsError` subclasses `ProviderInputError` and carries the existing
  validation-failed code, a fixed diagnostic and fixed remediation. Input paths,
  source bytes and validator diagnostics do not enter that message.

## Verification and byte identity

The kit bundle gets a bounded closed-tree preflight before
`kitspec.verify_bundle()`. Extra files, empty directories, links, hard-linked
files, FIFOs and other special entries are refused. Selected source bytes are
checked again against that inventory's Git blob records. The trusted base comes
from `opencode/files/home/opencode-config/base-config.jsonc` in this bundle;
there is no whole-kit pin refresh. `preparation_assets.verify_assets()` must
succeed before the packaged runtime is read.

The exact v2 USAi manifest is projected explicitly to v3 using
`usai-openai-list/v1`, with no normalizer. Facts, catalog, converted manifest and
the verified provider spec are written to a private mode-0700 snapshot with
mode-0400 files. One call to `provider_validator.validate_bundles` validates the
entire selection (one provider) through the real packaged validator. Its
preinstalled pinned Python environment is required; nothing is installed here.
The snapshot is checked again for changes after validation. Materialization uses
the same retained immutable bytes, never a second read from the source kits.

An invisible `.staging.*` directory receives facts, snapshot, the explicit runtime
discovery descriptor, runtime artifact, base and a canonical closed receipt.
Only a completed tree is renamed to `generation.*`. Failures clean private
snapshots and staging; no half generation or pointer is published. Files are
mode 0444 and directories guest-traversable; the read-only backend mount is the
guest write barrier. Abrupt process death may leave a private staging directory,
but cannot expose it as a completed generation or current pointer.

Per-file bounds are 64 KiB facts/spec, 4 MiB catalog, 1 MiB manifest/runtime/base,
and 4 KiB receipt/descriptor. Kit preflight also limits the inventory to 128
files, 4 MiB per file and 16 MiB total. These are byte bounds, not guarantees on
parser memory or wall-clock execution of local filesystem operations. The
validator separately owns its input budgets, subprocess deadline and cleanup.

Routing SHA-256 is over canonical ASCII JSON with sorted keys, compact
separators and one trailing newline, shaped as
`{"facts": <full facts object>, "discovery": <full descriptor>}`. It includes
`baseUrl` as well as models URL, protocol, credential variable and host.
Artifact/base SHA-256 values cover their exact bytes. The receipt records size
and SHA-256 for every materialized payload and has no extensible inventory.

## Trust boundary and validation

Installed application data and provenance ancestors must remain trusted and
unchanged during verification and staging. No-follow descriptor-relative reads
protect child components. This is POSIX-only, as is the validator adapter.
Mode bits and a receipt do **not** authenticate against a same-account writer
who can alter both payload and receipt. `read_existing` is an integrity check
against a trusted-host receipt, not a signature or permission to activate live
configuration. It does not rerun validation or depend on the current installation
being identical to that which created the mounted generation.

`py-acq/tests/test_fresh_inputs.py` covers private snapshot/source swaps,
closed trees, invalid bundles/assets, validator rejection and mutation, partial
materialization cleanup, byte limits, exact-generation selection and tampering.
Most tests mock only the validator call; bundle verification and filesystem
operations are real. The opt-in `test_actual_packaged_validator` uses
`PREPARATION_TEST_VALIDATOR_PYTHON` to select the primary's isolated pinned runtime
and has no validator mock. Native mounting, runtime execution, activation and
combined lifecycle qualification belong to coordinator integration validation.

Implementation-worker status: tests were authored but not executed. Host
commands, tests, installs and commits were explicitly excluded from this lane.
