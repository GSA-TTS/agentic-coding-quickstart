---
title: "Adopt bats-core for the acq offline unit suite"
description: "Bats isolation, offline fixtures, and measured test-runner performance"
tier: 2
last_updated: "2026-10-23"
status: accepted
date: 2026-08-23
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["SA-11", "SA-15", "SR-3", "CM-2"]
impact_level: low
ato_relevance: no
risk_treatment: n/a
supersedes: []
---

# ADR-0025: Adopt bats-core for the acq offline unit suite

## Context and Problem Statement

The acq offline unit suite is ~8,000 lines of bespoke Bash split across a shared
harness (`scripts/test-acq-lib.sh`) and numbered parts (`scripts/test-acq.d/NN-*.sh`),
sourced in-process by a thin runner. It has grown organically to 1,139 assertions
using hand-rolled `assert_eq`/`assert_contains` helpers and a shared mutable
`PASS`/`FAIL` counter. Three maintainability concerns motivated this decision:

1. **Isolation** — parts run in one shell and share mutable global state
   (`STUBDIR`, `CALLS`, exported env). A test that forgets `cleanup_stubs` can
   leak into the next; there is no per-test sandboxing.
2. **Approachability** — a large pile of bespoke Bash is hard for a new
   contributor to read, run selectively, or extend confidently.
3. **Lint churn** — because the code-under-test is driven by *sourcing*
   `acq`/`msb.sh` and setting globals for them to read, ShellCheck (which
   analyzes one file at a time) reports those globals as SC2034 "appears
   unused", forcing scattered `# shellcheck disable` directives.

We want the suite to be performant, reproducible, isolated, and approachable.

## Decision Drivers

- **Test isolation (SA-11)** — per-test state isolation prevents cross-test
  leakage and the associated flaky-test risk.
- **Approachability / maintainability (SA-15)** — named `@test` blocks, a
  standard runner, selective test execution, and TAP output lower the barrier
  for contributors versus bespoke Bash.
- **Reduce lint-suppression churn** — fewer SC2034 suppressions at the source,
  not just centralized.
- **Supply-chain minimalism (SR-3)** — the repo's posture is "keep it minimal";
  any new dependency must be pinned, reviewed, and justified.
- **Do no harm to the OOM fix** — the shellcheck memory blow-up was just fixed
  by disabling the dataflow pass (ADR-adjacent, see `.shellcheckrc`); the test
  tooling must not reintroduce it.

## Considered Options

1. **Status quo + `.shellcheckrc` centralization** — keep the bespoke harness;
   move SC2034 suppressions into a scoped `.shellcheckrc`. Zero new deps, but
   addresses neither isolation nor approachability, and does not fix SC2034 at
   root cause.
2. **Adopt bats-core** (with `bats-support` + `bats-assert`), vendored and
   pinned — rewrite the suite as `@test` blocks with `setup`/`teardown`
   isolation, driving the acq CLI via `run`.
3. **Adopt a non-Bash test runner** (e.g. a Python harness invoking `acq`) —
   strong isolation and assertions, but a language mismatch with a Bash-first
   repo and a heavier dependency footprint.

## Decision Outcome

Chosen option: **Option 2 (bats-core), validated first by a two-part pilot**,
because it is the only option that materially improves test **isolation** and
**approachability** while being idiomatic for a Bash-first project. Empirical
findings established before this decision:

- ShellCheck 0.11 handles bats natively as a shell dialect (auto-detected from
  the `.bats` extension; `man shellcheck` "--shell"), so `.bats` files lint
  without a preprocessor.
- `-x`/`--external-sources` (which bats' `load` idiom tempts) re-triggers the
  memory blow-up — a **single** part with `-x` and the dataflow pass on OOMed at
  ~1.9 GB. The pilot therefore MUST NOT enable `-x`, and the `.shellcheckrc`
  `extended-analysis=false` remains in force.
- `-x` does **not** clear SC2034 across the source boundary — confirmed by
  experiment. So bats reduces SC2034 only for tests converted to subprocess
  (`run`) invocation; tests that unit-test internal `_acq_*` functions in-process
  still require suppression.

The pilot converts one CLI-heavy part (`20-backend-resolution`) and one
internal-unit part (`111-balanced-egress`) to measure the real isolation and
SC2034-reduction gains on both ends of the spectrum before committing to the
full migration. The bespoke runner and bats coexist during the pilot; both run
in CI. (See "Migration Completed" below for the final outcome.)

### Positive Consequences

- Per-`@test` subshell isolation eliminates cross-test state leakage and the
  shared `PASS`/`FAIL` coupling.
- Named tests, TAP output, and selective runs improve approachability and
  failure diagnostics.
- CLI-driving tests converted to `run` drop their SC2034 globals entirely.
- bats is a widely-used, actively-maintained, MIT-licensed standard.

### Negative Consequences

- Three new vendored dependencies (bats-core, bats-support, bats-assert) to pin,
  review, and keep updated.
- Migration cost is high (1,139 assertions across ~30 parts) — mitigated by
  piloting before committing.
- Two test idioms coexist during migration, a temporary cognitive cost.
- Internal-function unit tests still need `# shellcheck disable=SC2034` and the
  `extended-analysis=false` setting; bats does not fix those at root cause.

### Compliance Consequences

- **SA-11 / SA-15** — strengthened developer testing and a more maintainable
  development process; no control gap introduced.
- **SR-3** — new dependencies are vendored and pinned by commit SHA, with a
  license/CVE review recorded at vendor time (see the vendoring commit).
- **ATO** — no boundary or data-flow change; the suite is offline/stubbed test
  tooling only. `ato_relevance: no`.

## Pilot Results (measured 2026-08-23)

Two parts were ported to `test/bats/` and run via `scripts/test-acq-bats`
(vendored bats-core v1.14.0):

- `20-backend-resolution.bats` (CLI/resolution-heavy) — 10 `@test`s
- `111-balanced-egress.bats` (internal-function unit) — 8 `@test`s
- All 18 pass; suite runs in ~3.4s.

Measured against the goals and the SC2034 question:

- **SC2034 / suppression churn** — the ported `.bats` files carry **zero**
  `# shellcheck disable` directives; the only suppression in the pilot is a
  single SC1091 in `helper.bash` for sourcing the shared harness. ShellCheck
  0.11 lints `.bats` natively (as a shell dialect) and the pilot files are
  clean under the repo `.shellcheckrc`.
- **Isolation** — proven: a variable leaked in one `@test` is `unset` in the
  next (per-test subshell). No shared `PASS`/`FAIL` counter.
- **Assertion honesty** — the legacy `20-backend-resolution.sh` had **12** cases
  wrapped as `( … ) 2>/dev/null; pass "…"`, where the outer `pass` fires
  regardless of the inner assertion. The bats port has none: a failed
  `assert_*` fails the `@test`.
- **Dependencies** — bats-core (MIT), bats-support (0BSD), bats-assert (CC0),
  vendored as SHA-pinned submodules under `test/vendor/`; licenses reviewed and
  federal-compatible.
- **OOM guard honored** — the pilot does not enable `-x`; `.shellcheckrc`
  `extended-analysis=false` remains in force.

Conclusion: bats delivers the isolation and approachability gains and removes
the SC2034 churn for these parts. Recommendation is to proceed with an
incremental migration (part-by-part), keeping both runners green in CI until the
last part is ported, then retire the bespoke runner.

## Migration Completed (2026-08-24)

The full migration is done and this ADR is `accepted` (maintainer:
bret.mogilefsky@gsa.gov). All 22 `scripts/test-acq.d/NN-*.sh` parts were ported
to `test/bats/*.bats` (one commit per part) and the bespoke `scripts/test-acq`
runner + `scripts/test-acq.d/` were removed. Final state:

- **340 `@test`s** across 31 `test/bats/*.bats` files; `./scripts/test-acq-bats`
  green. (The legacy suite reported ~1,139 hand-rolled assertions; many collapsed
  into single richer `@test`s, and the 12 unconditional-`pass` cases became real
  assertions.)
- `scripts/test-acq-lib.sh` is retained as the shared **stub library** (sbx/msb/
  ssh stubs, `make_stubs`/`load_acq`, offline kit-dir, `MSB_GITHUB_SECRET_BINDING`),
  sourced by `test/bats/helper.bash`. Its hand-rolled `pass`/`fail`/`assert_*`
  and `PASS`/`FAIL` counters were removed (bats-assert + bats tally replace them).
- CI: the `test-acq` pre-commit hook now runs `scripts/test-acq-bats`; the
  bash 3.2 gate runs the bats suite under a built bash 3.2.57.
- SC2034 churn: the ported `.bats` carry only three `# shellcheck disable=SC2034`
  directives, all on one internal-function unit test that sets a global read by
  sourced production code (the irreducible case identified above); every
  CLI-driven test is suppression-free.
- Parallelism: the per-`@test` isolation (private `$STUBDIR`; `ACQ_SECRET_STORE_DIR`
  / `ACQ_STATE_DIR` / `ACQ_PROVENANCE_DIR` all rooted there) makes the files
  safe to run concurrently. `scripts/test-acq-bats` runs across files with
  `bats --jobs` when GNU parallel (or rush) is on `PATH` — measured ~115s → ~60s
  — and falls back to serial otherwise. CI installs GNU parallel so the fast
  path is deterministic.
- Within-file parallelism is intentionally left OFF (`--no-parallelize-within-files`),
  and this was measured, not assumed. Running the backgrounded-`ssh`/`socat` port
  files (112/105/115) and the provision-heavy files (72/74) under `bats --jobs 4`
  within files was **flake-free** (5/5 clean each; full suite 340/340 across
  repeated runs) — the isolation holds. But on the 2–4 vCPU machines this suite
  targets (dev laptops, CI runners) it is consistently **~2x slower**: across-files
  already saturates the cores, so adding bats' per-`@test` worker orchestration
  is pure overhead with no spare cores to exploit. Head-to-head at `-j4`:
  across-only ~46–54s vs. across+within ~87–97s. So `--no-parallelize-within-files`
  is a performance choice, not a safety one; revisit only if the suite ever runs
  on a host with many idle cores relative to the file count.

## Performance investigation (2026-10-23)

Successful main-branch CI runs showed the Bats hook increasing from 105 seconds
on October 2 to 285 seconds on October 6 and 615 seconds on October 23. Test count
grew from 546 to 823 over the same interval: growth alone did not explain the
nearly sixfold runtime increase.

Profiling found two avoidable costs:

- Provider-input preparation calls `kit_translate_fetch` directly, bypassing the
  MSB adapter's offline kit override. Ordinary tests repeatedly fetched remote
  pinned kits. The shared harness now supplies an exact-pin Git transport fixture
  while preserving real local Git, production ref parsing, and projection logic.
  The fixture lives below test-specific executables on PATH so tests can wrap it
  without accidentally overwriting their own delegate. Unknown remote requests
  fail locally. The real validator tests consume CI's pre-fetched pinned checkout.
- Several successful SBX reattach/heal fixtures did not answer readiness or
  feature probes, so tests waited through production retry budgets. Those
  success fixtures now answer the probes; timeout and failure tests retain their
  explicit failure behavior. The forced agent-kit refresh test also asserts
  success rather than swallowing its failed readiness result.

Eleven setup functions also loaded acq twice; the redundant immediate load was
removed. Mutable per-test state and real guardian/signal/locking tests remain
isolated and unchanged. No production timeout or validation behavior was modified.

Observed inside a two-CPU Linux sandbox using file-level xargs parallelism:

| Measurement | Before | After |
|-------------|--------|-------|
| SBX forced agent-kit refresh test | 60.6 s | 1.0 s |
| SBX startup barrier/attach test | 74.0 s | 2.3 s |
| Full suite | exceeded 20-minute command limit | 9 min 8 s |

The full run passed with eight environment skips (three PowerShell, three real
SBX grammar, two externally provisioned Patterns-validator checks). The targeted
timings are same-sandbox measurements; sandbox load varied and these are not
claims about post-change GitHub CI latency. A fresh CI run is required to measure
that. The pre-change timeout is a lower bound, not a completed baseline.

The runner exposes `ACQ_BATS_TIMING=1` through native, serial, and fallback paths;
CI retains timing output for successful tests. macOS CPU detection now falls back
to `sysctl`, and invalid worker counts fail early. Both CI lanes run the pinned
validator tests within the full suite instead of repeating the entire projection
test file separately. File-level parallelism remains the default.

### Verification transcript and remaining environment checks

AI-assisted verification on October 23, 2026:

- `ACQ_BATS_TIMING=1 ACQ_BATS_JOBS=2 bash scripts/test-acq-bats`: passed,
  9m08.128s, 829 tests reported, eight environment skips. The subsequently added
  fallback-status regression passed in the focused seven-test runner file.
- `bash scripts/test-acq-bats --timing test/bats/01-test-runner.bats`: seven
  tests passed, including invalid arguments, macOS CPU fallback, xargs failure
  propagation, exact-pin transport, and real local Git behavior.
- ShellCheck at warning severity over the runner, harness, and all Bats files:
  passed; `bash -n` over the runner and harness: passed.
- `scripts/fix-exec-bits --check` and `git diff --check`: passed.
- Markdownlint on both changed documents: passed. Installation reported the
  existing `ini@7.0.0` Node engine mismatch (sandbox Node 22.22.1).
- Both workflow YAML files parsed successfully with PyYAML.
- `python3 -B scripts/test-probe-msb-startup.py`: 25 tests passed.
- `pre-commit run --all-files --show-diff-on-failure`: BLOCKED during hook
  environment installation, before hooks ran. The sandbox Python 3.14 pip
  environment raised `ssl.SSLError: NO_CERTIFICATE_OR_CRL_FOUND` while loading
  its CA bundle. Full hook verification, including gitleaks, must run after a
  working hook environment is available or in the normal CI environment.
- Bash 3.2 and the pinned external validator remain CI checks: those runtimes
  were unavailable locally. The workflow environment now supplies the pinned
  validator to the whole suite; confirm both validator tests execute rather
  than skip in the next CI run, and record its wall time for comparison.

The next CI run is the pickup trigger for the outstanding full-hook, Bash 3.2,
external-validator, and GitHub-runner timing verification above. No live backend
VM was created; the sandbox cannot run nested backend verification.

### Follow-up performance work (2026-10-23)

The post-change PR runner reported 830 tests and a 255-second modern-Bash Bats
hook. The slowest test was the MSB serve-PID teardown regression at 30.5 seconds;
the next port-related tests ranged from 8 to 16 seconds. The fixture, not the
production implementation, was responsible for the largest delays: the custom
serve stub launched `sleep 30` as a child and the test waited for that child after
killing the wrapper. The stub now execs its long-lived process, so teardown waits
for the exact PID being asserted. The generic SSH stub also reaps its temporary
listener when terminated. Test-only healthy settle windows are 0.1 seconds;
production defaults remain one second, and death/no-listener paths keep explicit
failure coverage.

The same follow-up adds `scripts/run-shellcheck`: batches remain capped at eight
files but run with up to four concurrent jobs (or `SHELLCHECK_JOBS=1` for serial
diagnosis). The cap keeps concurrency below the previously documented ShellCheck
memory risk. The runner rejects invalid or out-of-range job counts and preserves
the failure status of any lint batch.

Local two-CPU measurements after the follow-up:

| Measurement | Before | After |
|-------------|--------|-------|
| MSB serve-PID teardown regression | 30.2 s | 0.33 s |
| MSB port teardown regression | 10.9 s | 2.8 s |
| Port and host-port files combined | 120.6 s | 60.5 s |
| Representative ShellCheck inputs | serial 17.4 s | parallel 7.8 s |

These are local measurements; CI wall-clock verification remains required.

## Links

- `.shellcheckrc` — the `extended-analysis=false` dataflow-OOM fix this decision
  must not regress.
- `scripts/test-acq-lib.sh` — the retained shared stub library.
- `test/bats/` — the suite; `scripts/test-acq-bats` — the runner.
- bats-core: https://github.com/bats-core/bats-core (MIT)
- `docs/CODING_PRACTICES.md` §5 (dependency review), §12 (change safety).
