# acq-py — Python skeleton for acq v1 (foundation slice)

This directory is the Python replacement for the repo-root Bash `acq` wrapper.
It is the **foundation slice**: the project skeleton, the CLI entrypoint, the
structured-output envelope, managed-runtime resolution, and the vector runners'
corpus. Backend adapters and the remaining command surface arrive in later
slices.

> AI-assisted; owner: Bret Mogilefsky.

## Layout decision and coexistence plan

The new code lives under `py-acq/` (package `acq_py`, console script `acq-py`);
the language-neutral test corpus lives under `test/vectors/`; the Bash vector
runner is `scripts/run-vectors`. This deliberately does **not** touch the legacy
tree:

| Path | Legacy (unchanged) | New (this slice) |
|------|--------------------|------------------|
| `acq`, `acq.backends/`, `scripts/*` (except `run-vectors`), `test/bats/` | shipped Bash CLI + suite | untouched |
| `py-acq/` | — | Python package + pytest runner |
| `test/vectors/` | — | language-neutral corpus + manifest |
| `scripts/run-vectors` | — | Bash vector runner |
| `.github/workflows/python-vectors.yml` | — | vectors CI lane |

The Python console script is named `acq-py` during coexistence. When the Python
implementation reaches feature parity, the `acq` name transfers to it and the
Bash wrapper is retired (the "cutover" slice). ADR-0041m is explicit that v1
replaces Bash and maintains no coexistence guarantee; this naming defers that
rename so the two can never collide on a user's `PATH`.

## Quick start

```text
python -m pip install ./py-acq          # no runtime dependencies
acq-py version --json
```

```text
{"schema_version": 1, "command": "version", "data": {"acq_version": "0.1.0", ...}}
```

Or run from source without installing:

```text
PYTHONPATH=py-acq/src python -m acq_py version --json
```

## The CLI (foundation surface)

* `acq-py version` — human version/identity output (ADR-0042m).
* `acq-py doctor` — human diagnostic output (ADR-0038m §doctor): an overall
  `status` plus a check list, each with a stable `id`, `status`, `message`, and
  optional `remediation`. In this slice the checks are `runtime` (managed-runtime
  resolution, ADR-0042m) and `backend` (adapter availability, ADR-0040m).
* `acq-py version --json` and `acq-py doctor --json` (and `acq-py --json version`
  / `acq-py --json doctor`) — the structured-output envelope (ADR-0038m §2):
  `{"schema_version", "command", "data"}` on success,
  `{"schema_version", "command", "error": {"code", "message", "remediation?"}}`
  on failure. One document on stdout; diagnostics on stderr.
* `acq-py backend list [--json]` — detected backends (sbx/msb) with
  `active_backend` plus per-backend `name`/`installed`/`version` records
  (ADR-0038m §2). Read-only: an unknown/unparseable version reports `"unknown"`
  and never fails the query.
* `acq-py backend check NAME [--json]` — the version floor, fail closed
  (ADR-0040m): exit `0` when `NAME` is installed and supported, else exit `1`
  with `backend_not_found`, `backend_version_unsupported`, or
  `backend_version_unknown`. No mutation occurs.
* `acq-py create AGENT PATH [--name N] [--image REF] [--json]` — create a sandbox
  (detached) through the MSB adapter, wait for exec-readiness, and record a
  host-authoritative state record carrying `schema=N` (ADR-0041m).
* `acq-py run AGENT PATH [--name N] [--image REF] [--json]` — create (if missing)
  then launch the agent in the foreground; `acq-py run NAME` re-attaches to an
  existing sandbox by name.
* `acq-py ls [--json]` — list sandboxes with `name`/`backend`/`state`
  (ADR-0038m §2).
* `acq-py stop NAME [--json]` and `acq-py rm NAME [--json]` — stop (state
  preserved) or remove a sandbox and its record.
* Exit codes (ADR-0038m §1): `0` success, `2` usage, `1` operational. A
  well-formed command acq cannot carry out (for example `doctor NAME` while no
  backend adapter is present) fails closed with exit `1` and the
  `unsupported_capability` code (ADR-0040m). The lifecycle verbs add
  `sandbox_not_found`, `sandbox_exists`, `validation_failed`, and `timeout`.

Detection and the reported version are overridable for reproducible, offline
tests: `ACQ_SBX_INSTALLED`/`ACQ_MSB_INSTALLED` (`"0"`/`"1"`) and
`ACQ_SBX_VERSION`/`ACQ_MSB_VERSION` (a forced version string).

## Managed runtime (ADR-0042m)

**Supplier (settled):** Python.org embedded on Windows; python-build-standalone
install-only archives on macOS and Linux. An IT-approved base interpreter is the
optional per-fleet fallback. `acq_py/runtime.py` resolves the runtime to use and
never downloads one; acquisition (download + checksum + provenance) belongs to
the installer slice.

**Patch cadence (PROPOSAL — pending developer decision, not yet settled):**
re-verify and re-pin the managed runtime and dependency wheelhouse on the
existing quarterly review cadence (the same cadence that governs re-verifying
backend patterns and Tier-3 transcripts), with an immediate out-of-band patch
for any critical/high CVE affecting the bundled CPython or wheelhouse. The
developer is the decider here; this proposal is flagged rather than adopted.

## Testing

Two runners consume the same `test/vectors/` corpus and must agree on the
sentinel golden set (ADR-0043m):

```text
python -m pytest py-acq/tests -q      # pytest runner + coverage manifest
scripts/run-vectors --acq "python -m acq_py"   # Bash runner (jq)
```

See `../test/vectors/README.md` for the vector schema, assertion modes, and
normalisation transforms. Contract evidence is subprocess-only (ADR-0039m);
the sentinel set covers every assertion mode (`exact`/`contains`/`json`) and
every normalisation transform (`abspath`/`tmpdir`/`crlf`/`timing`/`order`/`json`).
