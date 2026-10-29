---
title: "Shard the bash 3.2 CI suite and hand the interpreter to the shards"
description: "Why the bash 3.2 gate builds the interpreter once and runs the offline suite as a matrix of shards, and why it does not use the Docker Hub bash:3.2.57 image"
status: proposed
tier: 2
date: 2026-10-29
last_updated: "2026-10-29"
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["SA-11", "SA-15", "SR-3", "SR-4", "CM-3", "CM-5", "SI-7"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
related_files: [".github/workflows/bash32-compat.yml", "scripts/bats-shard", "scripts/test-acq-bats", "scripts/summarize-bats-timing", "scripts/fetch-bash32-oci.py", "docs/KNOWN_FAILURE_MODES.md", "docs/adr/0025-adopt-bats-core-for-test-suite.md", "docs/adr/0038-local-bash32-test-runner.md"]
---

# ADR-0039: Shard the bash 3.2 CI suite and hand the interpreter to the shards

## Context and Problem Statement

The required check `acq offline suite under bash 3.2` runs the whole offline suite
(about 1,060 tests in 60 files, and growing) under a bash 3.2.57 built from source,
in one job. The same code took 8.5 to 16 minutes depending on runner speed, and a
merge-queue run was cancelled at the old 15-minute limit with no failing test. The
suite already runs files in parallel with `xargs -P`, but a hosted runner has two
cores, so the longest files bound the wall time.

Splitting the suite across a job matrix fixes that, but it raises a provisioning
question. Today the one job restores or builds the interpreter itself
(`actions/cache`). With N parallel legs that means either N source builds on a cold
cache, all trying to save the same cache key, or a different way to get the
interpreter to each leg. The local runner added in ADR-0038 also has a digest-pinned
Docker Hub route (`scripts/fetch-bash32-oci.py`, no compile); the question is
whether CI should use it.

This is a CI pipeline change and a change to how a build input is provisioned, so it
is recorded here.

## Decision Drivers

- Wall time and its sensitivity to runner speed, with generous per-leg headroom.
- The required check name and its fail-closed behavior must not change: any failed,
  cancelled or unexpectedly skipped piece must fail the gate.
- Keep the supply-chain property the gate has today: the interpreter is built from a
  source tarball authenticated by a fingerprint-anchored OpenPGP signature.
- No cold-cache race, no new third-party action, no remote script execution.
- Test fidelity: the interpreter should behave like the one macOS ships (glibc-style
  build of 3.2.57), because the suite exists to catch macOS-only failures.

## Considered Options

1. **Each leg restores or builds the interpreter itself** (the current job, copied
   N times).
2. **Each leg fetches the digest-pinned Docker Hub `bash:3.2.57` image** with
   `scripts/fetch-bash32-oci.py`.
3. **One `prepare-bash32` job builds or restores the interpreter once and hands it
   to the legs as a run artifact** whose sha256 is passed as a job output.
4. One prepare job that only warms the cache, with each leg restoring it.

## Decision Outcome

Chosen: **option 3**, together with a 3-leg matrix.

- `changes` is unchanged (relevance filter; new scripts added to its path list).
- `prepare-bash32` restores the cached build or builds from source with the same
  signature-verified procedure as before, confirms `BASH_VERSION` is exactly
  `3.2.57`, packs `/opt/bash32` into a tarball, and uploads it as the run artifact
  `bash32-interpreter`. Its sha256 is a job output. It is the only job that touches
  the cache entry, so there is no concurrent-save race.
- `test-acq-bash32` is a matrix `shard: [1, 2, 3]` with `fail-fast: false`. Each leg
  downloads the tarball, checks it against the sha256 output (`sha256sum --check`),
  extracts it, and fails unless the interpreter reports exactly `3.2.57`. It then
  runs `ACQ_BATS_SHARD=<i>/<n> scripts/test-acq-bats` with the interpreter first on
  `PATH`, exactly as before, and `ACQ_BATS_TIMING=1`. `<n>` comes from
  `strategy.job-total`, so the shard count lives in one place.
- Each leg tees its output, writes a timing summary (`scripts/summarize-bats-timing`)
  under its own heading and uploads `bats-timing-<i>of<n>-<attempt>`. Both steps are
  advisory (`continue-on-error`) and cannot change the job result.
- `gate` keeps the name `acq offline suite under bash 3.2`. It now needs `changes`,
  `prepare-bash32` and `test-acq-bash32` and decides from the relevance output: for a
  relevant diff, prepare and the matrix job must both be `success` (the matrix job is
  `success` only if every leg is); for an irrelevant diff, both must be `skipped`;
  any other combination, including a prepare failure that skips the matrix, fails
  the gate. The shell logic was exercised against all 256 result combinations.

Why not the others:

- **Option 1** triples the 47-second build on a cold cache and makes three jobs race
  to save one cache key (the losers only warn, so it is wasteful rather than broken,
  but it is exactly the race to remove).
- **Option 2** is rejected for CI, kept as the local convenience in ADR-0038:
  - *Authentication.* The source route verifies Chet Ramey's detached signature
    against a key pinned by full fingerprint, so it authenticates the signer. The
    image route verifies a manifest digest and layer sha256 values that this repo
    pins, so it detects any change after the pin was chosen, but the pin itself was
    taken on trust from Docker Hub and nothing ties it to the bash maintainer. For a
    required merge gate that is a weaker chain, and it adds a second external
    service (`auth.docker.io`, `registry-1.docker.io`) to the gate's dependencies in
    place of the GNU mirrors.
  - *Availability.* Docker Hub limits anonymous pulls per source address, and GitHub
    runners share egress addresses with other tenants, so the gate's success would
    depend on a budget this repo does not control. Three legs fetching at once make
    that worse. A source build only needs one of five mirrors.
  - *Fidelity.* The image's bash is a musl (Alpine) build run through its own musl
    loader, not a glibc build. The rest of the suite's tools (git, python, coreutils)
    are glibc. bash calls libc for regular expressions (`[[ =~ ]]`), locale and
    collation, user lookup (`~user`, no NSS on musl), and signal and process
    plumbing, and the macOS target is neither. These can differ in edge cases the
    suite might one day exercise. A single full-suite run under the musl build
    passed every test file except `103-kit-fetch-lifecycle.bats` in a sandbox
    (ADR-0038), which is evidence, not proof, and it was one architecture.
  - *Known launcher limit.* Through the loader launcher `$BASH` is the raw binary, so
    `103-kit-fetch-lifecycle.bats`, which re-executes `"$BASH"`, fails under that
    route. CI must run the whole suite. With the launcher first on `PATH` and the
    test re-executing `bash` instead of `"$BASH"`, the file passes (checked), but that
    is a change to the test that the source-built interpreter does not need.
- **Option 4** works, but a cache restore can miss (eviction, or a restore-key
  mismatch) and then each leg needs its own recovery path. An artifact scoped to the
  run, verified by digest, has no such path: it is there, or the leg fails closed.

The artifact is not keyed by attempt number, so "Re-run failed jobs" (which re-runs
only the legs) still finds it, and so does the preserved sha256 output. Retention is
two days; after that a leg fails closed and a full re-run rebuilds it.

## Consequences

Good:

- Estimated wall time per shard, from logged per-file timings and a 4-worker
  scheduling simulation: about 2.8 to 3.3 minutes of test time on a fast runner and
  4.3 to 5.6 minutes on a slow one, against 8.2 and 15 minutes unsharded. A leg also
  spends about a minute on checkout, submodules, Python, the artifact download and
  the validator checkout (the logged unsharded job spent about a minute before its
  first test), and the prepare job takes about a minute with a warm cache (about 47
  seconds longer on a cold one). End to end that is roughly 5 to 6 minutes (fast)
  and 7 to 8 minutes (slow), excluding queue time. Each leg keeps the 25-minute
  timeout.
- The cache race is gone, the interpreter is built at most once per run, and no leg
  depends on a GNU mirror or on Docker Hub.
- The shard-selection script derives shards from the files on disk, so new test files
  join a shard automatically; balance is by `@test` count and may drift from wall
  time, which the per-leg timing summaries make visible.

Bad / to watch:

- One more job on the critical path (`prepare-bash32`, about a minute with a warm
  cache) and an extra artifact upload and download per run.
- Three runners' setup cost (checkout with submodules, `setup-python`, pip) is paid
  three times; it is cheap, but total runner minutes rise.
- The required check is still one name, but a failing leg now needs its own job log;
  the gate message reports the aggregate result and the run page lists the legs.
- Balance is by test count, not by measured cost. If one shard keeps running much
  longer than the others, adjust the weighting in `scripts/bats-shard` or add a leg.
- Option 2 stays available as a local fallback only. If CI ever has to use it, the
  trust and fidelity differences above need to be re-decided, not assumed away.

Compliance:

- The pipeline continues to build the test interpreter from a signer-authenticated
  source, with no new third-party action and no remote script (SR-3, SI-7, CM-5). The
  workflow change is reviewed as CI configuration (CM-3) and needs a human with the
  `workflow` scope to push it.

## Prerequisites

The workflow relies on `scripts/bats-shard` and `ACQ_BATS_SHARD` support in
`scripts/test-acq-bats`, on `scripts/summarize-bats-timing`, and on the ADR-0038
local runner it cross-references. Land those first; the run step fails closed if a
leg's runner did not report running its shard.

## Links

- [ADR-0025](0025-adopt-bats-core-for-test-suite.md): the bats suite and its parallelism.
- [ADR-0038](0038-local-bash32-test-runner.md): the local runner and its OCI route.
- [Known failure modes](../KNOWN_FAILURE_MODES.md): the required-check gate pattern and
  how to diagnose a shard or interpreter hand-off failure.
