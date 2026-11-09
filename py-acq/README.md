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

The coexistence mechanism (ADR-0047m) adds a runtime switch on the repo-root
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
* Sandbox names and workspace paths follow the Bash `acq` rules
  (`commands/common.py`). Without `--name`, the name is `AGENT-<slug>`, where the
  slug is the lowercased ASCII letters and digits of the workspace's last path
  component (the root gives `workspace`). An explicit `--name` must match
  `[A-Za-z0-9_-]+` and not start with `-`. Verbs that act on an existing sandbox
  (`stop`, `rm`, `exec`, `attach`, `shell`, `ports`, `kit apply|check|update`,
  `create --recreate`) refuse an empty name, `.`, `..`, and names containing `/`,
  `\` or control characters. A workspace path, and the path its symlinks resolve
  to, must not contain control characters or `:`. The backends split mount specs
  on `:`, and acq-py takes no `:ro` suffix. On Windows the colon of a drive letter
  (`C:\...`) is allowed, because msb's `--volume` source accepts it.
* `acq-py ls [--json]` — list sandboxes with `name`/`backend`/`state`
  (ADR-0038m §2).
* `acq-py stop NAME [--json]` and `acq-py rm NAME [--json]` — stop (state
  preserved) or remove a sandbox and its record.
* `acq-py [--json] exec NAME -- CMD...` — run a command non-interactively inside
  a sandbox as the unprivileged `agent` user; the child's exit status is acq's
  exit status (ADR-0038m §1). In `--json` mode the child's stdout is routed to
  stderr and one success envelope carrying `exit_code` is emitted on stdout.
  acq's own flags go before `NAME`: everything after it, including `--json` or
  `--backend`, is the guest command.
* `acq-py attach NAME [--json]` — attach to an existing sandbox, launching the
  recorded agent. The agent is read from host-authoritative state only; there is
  no agent-to-shell fallback (ADR-0038m §48). The non-interactive contract is
  deterministic: fail closed on a missing sandbox or a missing/unreadable host
  record, propagate status.
* `acq-py shell NAME [--json]` — open a shell in a sandbox: on msb the agent
  user's passwd shell as a login shell, on sbx `bash`.
* Sessions: when stdin is a terminal, `attach`, `shell` and `run` give the
  session a PTY (`msb exec -t`, `sbx exec -it`) and pass the host's `TERM` and
  `COLORTERM`; without one there is no PTY. Every session (`exec` too) gets
  `HOME=/home/agent` and the host git identity (`GIT_AUTHOR_*`,
  `GIT_COMMITTER_*`, and `EMAIL` or the global `user.email`). On msb, `attach`,
  `shell` and `run` also get `SHELL`, with or without a PTY; sbx templates set
  their own. `SSH_AUTH_SOCK` is passed only when the sandbox records a forwarded
  ssh-agent socket, never the host's own. A child killed by signal N gives exit
  status `128+N`. Ctrl-C goes to the child rather than killing it; when the
  child dies of a Ctrl-C that acq received too, acq dies of SIGINT as well, so a
  calling shell loop stops, and under `--json` no envelope is printed. A SIGINT
  sent only to the child gives an ordinary `130` with the envelope.
* Flag position: acq's own flags (`--json`, `--backend NAME`) may go anywhere
  before `--` for most verbs, so `acq ls --json` and `acq attach box --json`
  work. Only two places are strict: after the `exec` sandbox name, where tokens
  are the guest command (and `acq exec NAME --json -- CMD`, with nothing but
  acq flags before `--`, is refused as a usage error), and after a passthrough
  verb, where everything is forwarded to the backend.
* `acq-py cp SRC DST [--json]` — copy between a native host path and a POSIX
  guest path. Exactly one side is a `NAME:/guest/path` reference; host and guest
  types stay distinct (ADR-0038m §4). The host side is forwarded verbatim to the
  backend, which resolves it natively on the host, so a UNC/network host path
  (`\\server\share\...` / `//server/share/...`) is accepted the same way a
  plain-drive path is — consistent with the UNC workspace mount (ADR-0029).
  The `msb copy` status is preserved.
* `acq-py ports NAME [--json]` — report a sandbox's *declared* host/guest port
  mappings with origin (create-time), never listener health (ADR-0038m §2). A
  failed or unreadable `msb inspect` fails closed rather than reporting an empty
  list (ADR-0038m §48).
* `acq-py secret set (-g | SANDBOX) SERVICE [--host HOST --env ENV] [--json]` —
  store a secret in the acq secret store, which is shared byte for byte with the
  Bash `acq` (`acq_py/secretstore.py`: macOS keychain, `secret-tool`, Windows
  DPAPI, or a 0600 file that is never used on Windows), then feed it to the
  backend on its stdin. The value never appears in argv or output; the success
  envelope reports `scope`/`service`/`value_state` only (ADR-0038m §secret set).
  A scope-less `secret set` is a usage error (ADR-0038m §48 drops scope-less
  secret set). An empty or whitespace-only value, a value with a newline or tab
  (after one terminal newline, plus a CRLF `\r`, is stripped), or input that is
  not valid UTF-8 is a `validation_failed` failure (exit 1) and nothing is
  stored. Service and sandbox names must match `[A-Za-z0-9_-]+` and not start
  with `-`; a sandbox named `global` is a sandbox scope. `--host`/`--env` record
  a custom endpoint and must be given together (`--host` alone works for a
  service with a known env var).
  **Typing a secret:** on a terminal the value is read with echo off after a
  prompt on stderr. Under Git Bash/mintty, native Windows Python sees a pipe
  rather than a console, so typed input cannot be hidden: acq prints a warning
  first. There, pipe the value instead (`printf '%s' "$TOKEN" | acq-py secret
  set -g usai`) or run from a native console (Windows Terminal, PowerShell, cmd).
* `acq-py secret import [SERVICE] [-g | SANDBOX] [--all] [--force] [--dry-run]
  [--json]` — copy known tokens from the host environment (`USAI_API_KEY`,
  `GITHUB_TOKEN`/`GH_TOKEN`, `GITLAB_TOKEN`, registered provider KEY_ENVs) into the
  acq secret store, as Bash `acq secret import` does. Needs no backend.
  Interactive by default (asks per service on a terminal, skips otherwise);
  `--all` never overwrites, `--force` does, `--dry-run` writes nothing.
* `acq-py secret rm (-g | SANDBOX) SERVICE [--accept-unconfirmed NAME[,NAME]]
  [--json]` — remove a secret. An absent secret fails closed with the
  `secret_missing` code; a backend that cannot answer fails closed with its
  accurate code (`backend_not_found`/`failure`) and never deletes (ADR-0040m).
  On msb the secret is first unbound from every sandbox acq recorded as holding
  it, and swept best-effort from sandboxes acq has no record for (created by the
  Bash `acq` or by `msb` directly). If a binding cannot be removed, or an
  unrecorded sandbox cannot be confirmed unbound, the secret is kept and the
  command fails with `unbind_failed`, naming the sandboxes.
  `--accept-unconfirmed NAME[,NAME]` (msb only) accepts the named unrecorded
  sandboxes staying unconfirmed: the removal then succeeds, the JSON data lists
  them under `unconfirmed`, and a note on stderr says they may still hold the
  binding. It never covers a recorded binding that failed. It is a stopgap
  until a live msb check settles what removing an unbound variable does (see
  `docs/KNOWN_FAILURE_MODES.md`), and can be retired then.
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
  Everything after the verb is forwarded, so acq's `--json`/`--backend` must
  come before it.
* Exit codes (ADR-0038m §1): `0` success, `2` usage, `1` operational. A
  well-formed command acq cannot carry out (for example `doctor NAME` while no
  backend adapter is present) fails closed with exit `1` and the
  `unsupported_capability` code (ADR-0040m). The lifecycle verbs add
  `sandbox_not_found`, `sandbox_exists`, `validation_failed`, and `timeout`; the
  secret verbs add `secret_missing`, `secret_unreadable` and `unbind_failed`; the state-migration
  slice adds `state_schema_unsupported` (a newer/unparseable/`min_reader`
  record), `migration_locked` (the migration lock was held by a concurrent
  invocation), `migration_failed` (an atomic record migration could not verify),
  and `security_exception` (a sandbox missing its read-only mount).
  `exec`, `attach`, `shell`, `cp`, and passthrough preserve the child/backend
  exit status rather than acq's own `0`/`1`.

## configure (ADR-0031)

`acq-py configure` ports the Bash `acq configure`. It first prints the current
settings (to stderr, in the Bash layout). At a terminal it then asks the Bash
questions with the Bash defaults (opt-in kits, the GitHub-token scoping default,
the provider kit) and writes the same three `config.yaml` keys through
`acq_py/config.py`: `extra_kits`, `scope_github_token` and `provider_kit`. Other
keys, including unknown ones, are kept. Without a terminal (or with
`ACQ_NO_PROMPT`, `ACQ_NO_PROGRESS` or `--json`) nothing is written; `--json`
lists each setting as `key`, `value`, `source` and `honoured_by_python`.

**The three keys take effect only under the Bash acq for now.** The Python acq
does not read `extra_kits`, `provider_kit` or `scope_github_token` yet, so both
the report and `--json` (`"honoured_by_python": false`) say so.

Deliberate differences from Bash:

* **Schema marker.** A `config.yaml` that Python creates starts with `schema: 1`
  (ADR-0041m); Bash's writer never adds it. An existing file is changed only in
  the keys written, and only after the forward migration, which runs just before
  the first write (so cancelling leaves a legacy file untouched) and refuses a
  newer schema up front.
* **Offline provider list.** The provider-kit picker offers the shipped default
  and the provider kits Python already knows about (the control plane's, and any
  a registered source is known to publish). It never fetches a kit source, so it
  can list fewer kits than Bash, which fetches every trusted source.
* **Layer reporting.** The report shows the value Python would use, with its
  layer: `--backend` (flag), `ACQ_BACKEND`, `ACQ_EXTRA_KITS`, `ACQ_PROVIDER_KITS`
  and `ACQ_PROVIDER_CREDENTIAL_BINDINGS` (env), the config, or the default. Bash
  shows only `config.yaml`. Kit sources and provider-credential bindings come
  from Python's own registries, and each binding carries its own layer. The
  human report marks a flag or env value with `[from X]`; otherwise it matches
  Bash line for line, plus a note about the keys above. Userinfo in a kit ref
  (`https://user:token@host`) is shown as `***@host`.
* **Stricter failures.** A `config.yaml` write that fails exits 1 (Bash ignores
  it), a malformed `ACQ_PROVIDER_CREDENTIAL_BINDINGS` is `validation_failed`, and
  an unknown `--backend` is a usage error. Ctrl-C exits 130; SIGTERM and SIGHUP
  restore the terminal and exit 128 plus the signal number.
* **Not ported.** The first-run offer and the create-time kit picker (accepted
  gaps in ADR-0048m).

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

The version floor is checked against the program the adapter actually runs, so
an `ACQ_MSB_BIN`/`ACQ_SBX_BIN` override is probed with `--version`/`version` and
refused before any mutation when it is below the floor. Detection and the
reported version are overridable for reproducible, offline tests:
`ACQ_SBX_INSTALLED`/`ACQ_MSB_INSTALLED` (`"0"`/`"1"`) and
`ACQ_SBX_VERSION`/`ACQ_MSB_VERSION` (a forced version string). `"0"` (force
absent) is honoured everywhere; `"1"` and a forced version are honoured only
while that backend's `ACQ_*_BIN` is `__stub__`, so they can never skip the floor
for a real binary.

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

## Built-in kit bundle

The built-in kits (the four support kits and the `opencode` agent kit) ship as
package data in `src/acq_py/kitbundle/`, a byte-exact copy of the Patterns
control plane at `CONTROL_PLANE_REF` (`src/acq_py/kits.py`, equal to
`PATTERNS_KIT_REF` in `acq.backends/common.sh`). `kitbundle/MANIFEST.json`
records the ref and each file's git blob id and size; `upstream_mode` is
informational. `src/acq_py/kitspec.py` parses and selects kits from it, so acq
never fetches a built-in kit during ordinary operation (ADR-0042m).

To bump the pin, change both refs, then regenerate the bundle and commit it
with the bump:

```sh
scripts/refresh-kitbundle                    # reads the pinned tree through `gh api`
scripts/refresh-kitbundle --checkout DIR     # or from a Patterns clone that has the pin
python -m pytest py-acq/tests/test_kitspec.py -q
```

The tests check the bundled files against the manifest and the refs against
each other. The networked pre-commit job (`.github/workflows/pre-commit.yml`)
also runs `scripts/refresh-kitbundle --check` against its checkout of Patterns
at the pin, which fails when any manifest blob id differs from
`git ls-tree -r <ref>`.

## Testing

Two runners consume the same `test/vectors/` corpus and must agree on the
sentinel golden set (ADR-0043m):

```text
python -m pytest py-acq/tests -q      # pytest runner + coverage manifest
scripts/run-vectors --acq "python -m acq_py"   # Bash runner (jq)
```

On Windows, a global `commit.gpgsign` (for example 1Password's `op-ssh-sign`)
makes `git commit` fail inside the tests' temporary repos. Neutralize the
inherited config for a hermetic run:

```sh
# GIT_CONFIG_GLOBAL="" does not help: git falls back to ~/.gitconfig.
GIT_CONFIG_GLOBAL=NUL GIT_CONFIG_NOSYSTEM=1 python -m pytest py-acq/tests -q
```

With the override, the suite is expected to pass on Windows; the Windows CI job
(`.github/workflows/windows.yml`) runs it on every relevant pull request. The
`install.sh` tests that need a supported platform are skipped there, because
`install.sh` refuses Windows hosts and `install.ps1` is the Windows installer.
Without the override, roughly 30 failures in `test_qualification_host.py` and
`test_qualification_gate.py` come from that signing hook, not the code under
test.

See `../test/vectors/README.md` for the vector schema, assertion modes, and
normalisation transforms. Contract evidence is subprocess-only (ADR-0039m);
the sentinel set covers every assertion mode (`exact`/`contains`/`json`) and
every normalisation transform (`abspath`/`tmpdir`/`crlf`/`timing`/`order`/`json`).

### Quality gates

`.github/workflows/python-quality.yml` runs ruff, mypy and bandit on `src/`
and fails when pytest's in-process branch coverage drops below the
`fail_under` floor in `pyproject.toml`. The tools are CI-only, pinned with
hashes in `requirements-quality.txt` (policy: ADR-0049m). To run the gates
locally, use a throwaway virtual environment and run the commands from
`py-acq/`:

```sh
python -m pip install --require-hashes --no-deps --only-binary :all: -r requirements-quality.txt
python -m ruff check src
python -m mypy
python -m bandit -c pyproject.toml -r src
python -m pytest -q --cov --cov-report=term
```

The gates started at zero findings, so there is no baseline. A finding that
is a false positive gets a targeted suppression with its reason on the same
line, such as `# nosec B105 # an error code`. Do not widen the skip lists in
`pyproject.toml` to clear one.

### Windows

`.github/workflows/windows.yml` runs on a Windows runner when a pull request
touches Windows-relevant paths. It runs pytest, smoke tests of `acq.cmd` and
`acq.ps1` for both `ACQ_IMPL` paths, `install.ps1 -DryRun` under PowerShell 7
and Windows PowerShell 5.1, the release job's managed-runtime staging and
smoke check, and a Git Bash run of `55-version.bats` and
`06-windows-install.bats`.
