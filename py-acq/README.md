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

The coexistence mechanism (ADR-0046m) adds a runtime switch on the repo-root
Bash `acq`: `ACQ_IMPL=python` resolves and execs this Python implementation, so
the two can coexist behind one `acq` name. The Python implementation also has a
distinct, installer-linked identity — an `acq-python` launcher that runs the
managed runtime `python -m acq_py` against `py-acq/src` — so it is resolvable
without ever taking the `acq` name. `version` reports `"impl": "python"` for
unambiguous bug reports.

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
* `acq-py create --recreate NAME [--yes] [--json]` — the security-exception
  recreation (ADR-0035/0041m): recreate a sandbox whose read-only trusted-config
  mount is missing. Explicit and consent-gated — a non-interactive run without
  `--yes` refuses with `consent_required`; host records and secrets are
  preserved, only the guest filesystem is lost.
* `acq-py run AGENT PATH [--name N] [--image REF] [--json]` — create (if missing)
  then launch the agent in the foreground; `acq-py run NAME` re-attaches to an
  existing sandbox by name.
* `acq-py ls [--json]` — list sandboxes with `name`/`backend`/`state`
  (ADR-0038m §2).
* `acq-py stop NAME [--json]` and `acq-py rm NAME [--json]` — stop (state
  preserved) or remove a sandbox and its record.
* `acq-py exec NAME -- CMD... [--json]` — run a command non-interactively inside
  a sandbox as the unprivileged `agent` user; the child's exit status is acq's
  exit status (ADR-0038m §1). In `--json` mode the child's stdout is routed to
  stderr and one success envelope carrying `exit_code` is emitted on stdout.
* `acq-py attach NAME [--json]` — attach to an existing sandbox, launching the
  recorded agent. The agent is read from host-authoritative state only; there is
  no agent-to-shell fallback (ADR-0038m §48). The non-interactive contract is
  deterministic: fail closed on a missing sandbox or a missing/unreadable host
  record, propagate status; true PTY allocation is deferred to the live tier.
* `acq-py shell NAME [--json]` — open a login shell (`/bin/sh -l`) in a sandbox.
* `acq-py cp SRC DST [--json]` — copy between a native host path and a POSIX
  guest path. Exactly one side is a `NAME:/guest/path` reference; host and guest
  types stay distinct and a UNC/network host path fails closed (ADR-0038m §4).
  The `msb copy` status is preserved.
* `acq-py ports NAME [--json]` — report a sandbox's *declared* host/guest port
  mappings with origin (create-time), never listener health (ADR-0038m §2). A
  failed or unreadable `msb inspect` fails closed rather than reporting an empty
  list (ADR-0038m §48).
* `acq-py secret set (-g | SANDBOX) SERVICE [--json]` — store a secret. The value
  is read from **stdin only** (never argv) and forwarded to the backend on its
  stdin; the success envelope reports `scope`/`service`/`value_state` and never
  the value (ADR-0038m §secret set). A scope-less `secret set` is a usage error
  (ADR-0038m §48 drops scope-less secret set); an empty or whitespace-only stdin
  value is a `validation_failed` failure (exit 1). Exactly one terminal newline is
  stripped (plus a CRLF `\r`); any further trailing newlines are value content.
* `acq-py secret rm (-g | SANDBOX) SERVICE [--json]` — remove a secret. An absent
  secret fails closed with the `secret_missing` code; a backend that cannot answer
  fails closed with its accurate code (`backend_not_found`/`failure`) and never
  deletes (ADR-0040m).
* `acq-py secret ls [(-g | SANDBOX)] [--json]` — list secrets with
  `scope`/`service`/`value_state` (set/unset) only, never a value
  (ADR-0038m §2 secret ls required data). An unreadable, wrong-shape document, or
  wrong-shape *entry* fails closed with `secret_unreadable` — never silently
  dropped (ADR-0040m, ADR-0038m §48).
* `acq-py secret has (-g | SANDBOX) SERVICE` — a silent predicate (ADR-0038m):
  exit `0` when the secret is present, `1` when absent, `2` on a usage error. It
  prints nothing on stdout, even with `--json`. A backend that cannot answer (an
  unsupported backend, or a query failure) still exits `1` with stdout silent but
  announces a diagnostic on stderr so "cannot check" is not a silent false
  "absent".
* Any other subcommand is forwarded verbatim to the active backend binary with an
  announced stderr notice, preserving its exit status (spec user story #9).
* Exit codes (ADR-0038m §1): `0` success, `2` usage, `1` operational. A
  well-formed command acq cannot carry out (for example `doctor NAME` while no
  backend adapter is present) fails closed with exit `1` and the
  `unsupported_capability` code (ADR-0040m). The lifecycle verbs add
  `sandbox_not_found`, `sandbox_exists`, `validation_failed`, and `timeout`; the
  secret verbs add `secret_missing` and `secret_unreadable`; the state-migration
  slice adds `state_schema_unsupported` (a newer/unparseable/`min_reader`
  record), `migration_locked` (the migration lock was held by a concurrent
  invocation), `migration_failed` (an atomic record migration could not verify),
  and `security_exception` (a sandbox missing its read-only mount).
  `exec`, `attach`, `shell`, `cp`, and passthrough preserve the child/backend
  exit status rather than acq's own `0`/`1`.

## State migration (ADR-0041m)

acq owns migration of acq-hosted state records; backend-native state is never
migrated, and guest-writable state is never trusted. Before any mutating verb,
acq runs a synchronized forward-migration pre-step under an exclusive OS advisory
lock (`flock`/`fcntl` on POSIX, `msvcrt.locking` on Windows) that auto-releases on
crash: legacy v0 records migrate forward in place, a single tree-level generation
marker is written LAST so a partial migration is resumable, and a newer or
unparseable record (or a reader below a record's `min_reader`) is refused with a
stable code. Each record migrates atomically and non-destructively until
verified. Read-only diagnostics (`ls`, `doctor`) report rather than migrate.

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
