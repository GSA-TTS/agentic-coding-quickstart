# Qualification harness (ADR-0044m)

Tier-3 transcript tooling for the Python `acq` v1 replacement — **not CLI code**.
It emits the verbatim `RESULT` signature line, reports the
qualified/unqualified/blocked matrix honestly, and enforces the 3-attempt
reproduction rule for a `FAIL`. The live Tier-3 run (real MSB/SBX, real microVMs,
a native Windows host) is the downstream consumer; this package builds the
tooling and makes it testable offline against a fake backend.

> AI-assisted; owner: Bret Mogilefsky.

## Run

```text
python -m qualification --help
python -m qualification matrix --json
python -m qualification run --backend msb --backend-version 0.7.7 \
    --os Linux --os-build 6.1.0 --arch x86_64 --hypervisor native \
    --image img -- python -c "raise SystemExit(0)"
```

## The verbatim `RESULT` signature

Every run emits exactly two lines on stdout, the second of which is the canonical
one-pasteable signature (ADR-0044m):

```text
OUTCOME <PASS|FAIL|BLOCKED|FLAKY>
RESULT <PASS|FAIL|BLOCKED> <backend>=<ver> image=<image> host=<os arch> rev=<sha> dir=<abs path>
```

The `RESULT` verdict is restricted to `PASS`/`FAIL`/`BLOCKED`. The backend token
is `msb=` or `sbx=`. `host` is the `<os> <arch>` token (e.g. `Linux x86_64`);
`dir` is the transcript directory, or `none` when no evidence directory is
written (offline harness self-test).

## `OUTCOME` and the 3-attempt reproduction rule

The `OUTCOME` line is the settled disposition, and the process exit code carries
it: `0` pass, `1` fail, `2` blocked, `3` flaky (escalation).

A `FAIL` is confirmed real only by reproducing on the same environment within
three attempts. The binding identity fields — commit SHA, artifact SHA-256,
backend version, OS build, and hypervisor state — must match across attempts;
wall-clock time, the transcript directory, a nonce, and the sandbox name may
differ. A result that diverges across attempts, or whose binding identity
diverges, is escalated `FLAKY` (exit 3), never softened and never reported as a
definitive `FAIL`. A `FAIL` with fewer than two attempts has no reproduction
evidence and is likewise `FLAKY`.

`BLOCKED` is a first-class recorded verdict, never a pass and never a silent
skip. A missing command, a timeout, an oracle exiting `2`, or an unqualified cell
records `BLOCKED`.

## The matrix

`python -m qualification matrix` reports every platform/backend cell, reading the
committed ledger (`--ledger` to point elsewhere), in exactly one of these states:

* `qualified` — a claimed cell holding a green *current* transcript (recorded
  within 90 days, at the backend's current `major.minor`, with no Tier-3 surface
  change since, where the surface is the CLI source tree, the two oracles, and
  this harness's run path, minus the `version`/`doctor` command modules — the
  exact list is `TIER3_SURFACE` in `qualification/matrix.py`; the commit SHA and
  artifact hash are provenance only);
* `waived` — a claimed cell without one, covered by an unexpired ledger waiver;
* `unqualified` — a cell that is not claimed (reported honestly, never a pass);
* `blocked` — a claimed cell without a green current transcript (holds the gate).

These are the release gate's verdicts (`python -m qualification.gate check`), with
the reason for each one that is not `qualified`.

The claimed cells are (ADR-0044m): msb on Linux x86_64, Linux aarch64, macOS
arm64, and Windows x64; sbx on Linux x86_64, macOS arm64, and Windows x64.
Windows ARM64, musl, macOS x86_64 (every backend), and sbx on Linux aarch64 are
unqualified (not claimed).

## Qualify a host

`python -m qualification.host` runs the cell oracle for this host, records the
green runs in the ledger, and opens the ledger PR. See
[`docs/howto/qualification.md`](../docs/howto/qualification.md).

## The ledger and the release gate

`python -m qualification.gate record transcript.json` appends a run to
`docs/qualification-ledger.json` (metadata and the transcript's hash). `python -m
qualification.gate check` evaluates the release gate from that ledger. `record`
refuses a transcript that did not run the committed cell oracle on its own host; the
gate checks each entry against the repository (oracle hash at its revision, host vs
cell, no duplicate transcripts) but never sees transcripts, so the ledger's admin
review remains the control against forged evidence. On a pull request CI runs the
gate from the base branch, so a PR cannot loosen the rules it is judged by. `python -m
qualification.gate verify-evidence --base <rev> <pr-body>` checks the transcripts a
ledger PR inlines: each is the file byte for byte, so its SHA-256 is a recorded
`transcript_sha256`, and it must reproduce its entry; every entry added since `<rev>`
needs exactly one such block, and none may be duplicated or hidden in an HTML comment. See
[`docs/howto/qualification.md`](../docs/howto/qualification.md).

## No secret value

A transcript records hashes, versions, and the command line, plus a SHA-256
digest of observed output — never the raw output, never an environment dump,
never a credential, and never a host-local path (the transcript directory is
written as `<transcript-dir>` and an absolute command-line path keeps only its last
component, as `<local>/python3`). It is written in one canonical byte form (sorted
keys, two-space indent, ASCII, LF, one trailing newline), so the published copy is
the hashed file. The harness never injects a secret into argv and never
records `os.environ`; a secret an oracle happens to print is reduced to its
digest before it can reach the transcript.

## Tests

Offline, no backend required:

```text
python -m pytest py-acq/tests -q                                  # pytest runner + unit tests
scripts/run-vectors --acq "python -m acq_py"                     # independent Bash runner
```

Unit guards live in `py-acq/tests/test_qualification*.py`, the cell oracle's in
`py-acq/tests/test_qualify_backend_cell.py`; subprocess-boundary evidence lives in
`test/vectors/qualification/`.
