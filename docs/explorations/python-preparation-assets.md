# Python preparation assets

The Python application owns a separate, offline `preparation_bundle/` under
`py-acq/src/acq_py/`. It is not a provider-supplied manifest or a refreshed kit
bundle. The preparation verifier does not execute assets, fetch dependencies,
discover providers, or change the existing kit selection policy.

`preparation_assets.verify_assets()` takes no caller-selected root and returns
frozen `VerifiedAssets` paths for the validator, schema directory, credential
bindings, and standalone runtime artifact, plus the Patterns source revision.
The private root constant exists for fixture patching, not as a user override.
The application pins the SHA256 of `MANIFEST.json` before parsing it. The manifest
records the size and SHA256 of all ten payload files, including the nine
byte-exact upstream files and application-authored provenance. The complete tree
is closed: extra files, hidden files, extra directories, missing files, symlinks,
and nonregular payloads are rejected. Manifest reads are capped at 16 KiB;
payload reads at their recorded sizes (at most 1 MiB), plus one overrun byte.
Failures use a fixed diagnostic without echoing paths or manifest data.

## Source and schema closure

Patterns is pinned at `83c254a743f4b6fa539cafb1a453361a85e0691b`.
The bundle's `PROVENANCE.md` records source paths and the one destination rename;
`MANIFEST.json` records destination paths and digests. Upstream `LICENSE` is
included unchanged. The upstream `scripts/validate_provider_input_contract.py`
is shipped byte-for-byte as `scripts/validate_provider_input_contract.py.txt`.
The validator's relative `scripts/` and `integrations/isolation/schemas/` layout
is retained, so its schema lookup is unchanged. Callers pass the verified script
path explicitly to their approved Python interpreter rather than importing it.

Static inspection of the actual five JSON schemas found four `$ref` occurrences,
all in `acq-neutral-model-catalog.schema.json`: `#/$defs/model`, twice
`#/$defs/cost`, and `#/$defs/releaseDateSource`. All resolve within that same
document. The bundle v1/v2/v3 and provider-facts schemas have no `$ref`. There
are no external schema references to fetch. The schema closure test walks the
actual JSON documents and resolves each reference without invoking upstream
code or a network resolver.

## Packaging and validation

Explicit package-data patterns cover the manifest, provenance, license,
validator, schema JSON, and runtime JavaScript for setuptools wheel and sdist
builds. The vendored directory is excluded from Python package discovery and
application lint/type/coverage scans: upstream source must remain byte-exact,
not reformatted as application code. The shipped license is also declared in
project license metadata.

An initial ordinary pip installation byte-compiled the validator when it had a
`.py` suffix, adding `scripts/__pycache__/*.pyc` and causing verification to fail.
The `.py.txt` destination prevents installer compilation without changing source
bytes, weakening the closed-tree check, or requiring users to install with
`--no-compile`. Extra bytecode and cache directories remain verification errors.

`py-acq/tests/test_preparation_assets.py` checks the real application pin, every
file's presence and digest, size mutations, manifest reauthorization attempts,
closed paths, symlinks, FIFO rejection, fixed diagnostics, schema closure, and
package-data pattern coverage. A standard-library `compileall` regression copies
the bundle and checks that installer-style compilation leaves it verifiable and
without bytecode; a separate synthetic `.py` positive control proves compilation
was active without executing any script. This test adds no build dependency to
the normal unit suite. Synthetic repinned manifests are labeled as such and
exercise malformed metadata checks; they are not upstream validation runs.

Before accepting this slice, regenerate the manifest and application pin after
any bundle change, then run the tests in the workspace sandbox. Build fresh wheel
and sdist artifacts from clean inputs, inspect both for byte-exact assets and the
renamed validator, and install the wheel into a clean target using ordinary pip
compilation (no `--no-compile`). Verify the installed package from outside the
checkout so source imports cannot mask missing assets. Also build and install a
wheel from the sdist, and repeat installed verification. Static glob coverage
and the compilation regression alone do not prove built artifact contents or
successful installed verification. Exercise the pinned validator's valid/refused
input cases separately with its approved preinstalled dependencies.

## Trust boundary

This is package integrity checking, not a hostile-writer filesystem snapshot or
a signature for the application itself. Anyone able to replace application code
can also replace its manifest pin. Returned paths are not open descriptors and
must remain in an application installation not writable by provider code between
verification and use. The caller owns provider snapshots and execution policy.
This module does not install the validator's `jsonschema`/`yaml` dependencies or
activate manifest-v3 providers in the existing shared kit bundle.
