---
title: "Adopt bats-core for the acq offline unit suite"
status: proposed
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
full 1,139-assertion migration. The bespoke runner and bats coexist during the
pilot; both run in `scripts/test-acq` / CI.

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
  license/CVE review recorded at vendor time (see pilot commit).
- **ATO** — no boundary or data-flow change; the suite is offline/stubbed test
  tooling only. `ato_relevance: no`.

## Links

- `.shellcheckrc` — the `extended-analysis=false` dataflow-OOM fix this decision
  must not regress.
- `scripts/test-acq-lib.sh`, `scripts/test-acq.d/` — the current bespoke harness.
- bats-core: https://github.com/bats-core/bats-core (MIT)
- `docs/CODING_PRACTICES.md` §5 (dependency review), §12 (change safety).

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
last part is ported, then retire the bespoke runner. This ADR moves to
`accepted` once a migration issue is filed and the maintainer signs off.
