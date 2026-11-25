# Preparation asset provenance

Source repository: <https://github.com/GSA-TTS/agentic-coding-patterns>

Source revision: `83c254a743f4b6fa539cafb1a453361a85e0691b`

License: CC0-1.0; the upstream root `LICENSE` is copied unchanged here.

Every upstream file below is copied byte-for-byte from that revision. Its path
inside this bundle equals its source path relative to the Patterns repository
root except for the validator filename mapping documented below.
`MANIFEST.json` is the machine-readable digest inventory: each `files`
entry records the byte size and SHA256 at the destination path. The application pins
the SHA256 of the complete manifest in `preparation_assets.py`; a modified
manifest cannot authorize modified payloads. The manifest additionally records
this application-authored provenance document's size and SHA256.

## Upstream source paths (nine files)

- `LICENSE`
- `scripts/validate_provider_input_contract.py`
- `integrations/isolation/schemas/acq-provider-input-bundle.schema.json`
- `integrations/isolation/schemas/acq-provider-input-bundle-v2.schema.json`
- `integrations/isolation/schemas/acq-provider-input-bundle-v3.schema.json`
- `integrations/isolation/schemas/acq-provider-facts.schema.json`
- `integrations/isolation/schemas/acq-neutral-model-catalog.schema.json`
- `integrations/isolation/schemas/provider-credential-bindings.json`
- `integrations/isolation/acq-kits/opencode/files/home/opencode-config/runtime-model-preparation.mjs`

## Local adaptations and scope

No upstream bytes, including the validator and license, are modified. The local
additions are `MANIFEST.json`, this provenance record, and the application-owned
verifier outside this directory. The one renamed destination is:

- Source: `scripts/validate_provider_input_contract.py`
- Destination: `scripts/validate_provider_input_contract.py.txt`

The `.txt` suffix makes the validator package data rather than a Python module
for installer byte-compilation. With the original `.py` suffix, ordinary pip
installation added `scripts/__pycache__/*.pyc`, which the closed-tree verifier
correctly rejected. No bytecode exception or `--no-compile` installation flag is
required with the renamed asset. A caller must pass the verified script path
explicitly to its approved Python interpreter, not import it as a module.
Keeping the upstream directory layout preserves the validator's relative schema
lookup despite the filename change. The five schemas form a closed static
reference set: the catalog's four `$ref` occurrences resolve to its own `$defs`;
the other schemas have no `$ref`. The test suite checks this on actual JSON.

This is a narrow host-preparation asset set, not an imported guest kit or a
refresh of the existing `kitbundle/`. The standalone runtime file is only made
available to the caller; verifying it does not execute it. Validator dependencies
are not vendored or installed by the asset verifier. Source refreshes require a
reviewed revision, byte-exact replacement, a regenerated digest inventory, an
updated application manifest pin, schema-closure inspection, and sandbox tests.
