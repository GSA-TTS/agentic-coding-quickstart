---
title: "Live cross-platform qualification matrix and transcript"
status: accepted
date: 2026-11-02
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["CA-2", "CA-7", "SA-11"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0044m: Live cross-platform qualification matrix and transcript

## Context and Problem Statement

The verification strategy settled that host-enforcement oracles require a
green live transcript against real MSB/SBX, real microVMs, and a native
Windows host, gating release and gating any PR that touches a security oracle.
It left the exact oracle list, the qualified platform/backend matrix, the
transcript contents and durability, and the BLOCKED/staleness/flakiness
handling open.

## Decision

Six oracles require Tier 3 (everything else stays Tier 1): the
host-enforced read-only trusted-config mount (ADR-0035/ADR-0037); secret
placeholder/proxy and swap-on-the-wire substitution and secret non-exposure;
real backend behaviour (kit apply, attach, boot contract, version
fail-closed); offline completeness (network-blocked install plus smoke);
the security-exception recreation flow (ADR-0041m); and native-Windows
ordinary-user operation.

The qualified matrix is: msb on Linux x86_64, Linux aarch64, macOS arm64,
macOS x86_64, and Windows x64 (floor ≥ 0.6.9, refusing 0.7.0–0.7.2, with
oracles 1–3 at ≥ 0.7.7); sbx on Linux x86_64, macOS arm64, and Windows x64
(floor ≥ 0.39.0). sbx on macOS x86_64 and Linux aarch64 is unqualified
(not claimed). Each matrix cell is in exactly one of three states:
qualified (green current transcript), unqualified (not claimed), or
blocked (attempted, no verdict).

A transcript records environment identity (OS build, arch, hypervisor
state), backend and version, glibc floor where relevant, the commit SHA,
artifact SHA-256, the commands run, observed output or a verified digest,
and a PASS/FAIL/BLOCKED verdict with the canonical one-pasteable signature
line already emitted by `scripts/qualify-msb-ro-mount`:
`RESULT <PASS|FAIL|BLOCKED> msb=<ver> image=<image> host=<os arch>
rev=<sha> dir=<abs path>` (the backend token generalises `msb=` to `sbx=`
for sbx cells). Transcripts are attached to the release and, for a PR
touching the Tier-3 surface, to that PR as artifacts with attestations where
available; they are not committed.

BLOCKED is a first-class recorded outcome, never a pass, distinct from an
unqualified (unclaimed) cell. The release gate is every qualified cell
holding a green current transcript; a PR touching the Tier-3 surface (below)
attaches a fresh transcript; the developer owns and runs the fleet. An unavailable
qualified cell records blocked and holds the gate.

A transcript is *current* while all of the following hold; otherwise it is
stale and the cell is blocked until regenerated:

- it was recorded within the last 90 days (the quarterly re-verification
  cadence, so re-verification is simply the age limit);
- its backend `major.minor` version equals the version under acceptance (a
  patch release does not expire it; a minor or major upgrade does);
- no change to the Tier-3 surface landed after it was recorded. The surface is
  the *contract-bearing* CLI modules (a whitelist of the `acq_py/*.py` modules
  the live cell oracle exercises — the `__main__` entrypoint, `cli.py`, and
  the adapter/state/migration/envelope/security/credential/kit modules it
  drives — *not* the whole `py-acq/src/acq_py/` package), the cell and
  ro-mount oracles (`scripts/qualify-backend-cell`,
  `scripts/qualify-msb-ro-mount`), and the run path of the harness
  (`qualification/__init__.py`, `__main__.py`, `cli.py`, `model.py`,
  `runner.py`, `repro.py`); the matrix, ledger and gate only read transcripts,
  so editing them expires nothing. A commit that touches none of these (a
  release-please version bump, changelog, docs, tests, CI) does not expire
  anything.

  The `version` command is deliberately *off* the surface: its data assembly
  and human/JSON output live together in `py-acq/src/acq_py/version_info.py`
  (the `run_version` handler was split out of `cli.py` for exactly this
  reason), and no oracle asserts the `version` command's exact output fields.
  A diff confined to the `version` output therefore does not make a recorded
  transcript stale. The other off-surface `acq_py` modules are the package
  version constant (`__init__.py`, so a version bump stays release-only),
  `doctor.py`/`runtime.py` (`acq doctor`, which no oracle asserts), and the
  deterministic test-only `_stub_*.py` backends. The whitelist is enforced by
  `test_every_acq_py_module_is_classified_as_surface_or_off_surface`, so a new
  module must be classified surface or off-surface, never left implicit.

The commit SHA and artifact SHA-256 are recorded as provenance, not as part of
the currency test: every release commit changes both without changing
behaviour, and treating them as binding would force a full live re-run of every
cell for each release. The same host fields (OS build, arch, hypervisor)
remain in the transcript; a different OS major version or hypervisor is a
different environment and is qualified by its own run. The trade-off, accepted
here, is that a release can ship non-surface changes that no live run covered;
those are covered by the Tier-1 vectors and Tier-2 tests, and a surface change
always requires a fresh transcript. The default sandbox image is a mutable tag,
so an upstream image change is bounded only by the 90-day limit. Backend
versions are compared as final `X.Y.Z`; an unknown, pre-release, or otherwise
unparseable version on either side is never current.

"No surface change since the transcript" is computed per transcript from its
recorded commit: the changes between that commit and the commit under
acceptance, restricted to the surface paths. The recorded commit SHA is
therefore the anchor for that computation (and provenance), even though it no
longer decides currency by itself.

A FAIL is confirmed real by re-running up to three attempts where the commit
SHA, artifact SHA-256, backend version, and OS build plus hypervisor state
must match (wall-clock time, transcript directory, nonce, and sandbox name may
differ); a result diverging across three attempts is flaky and is escalated to
a tracking issue plus KNOWN_FAILURE_MODES, never softened. (Within one run
these fields are fixed, so the rule detects genuinely nondeterministic
results.)

## Consequences

A release cannot be declared ready without a green current transcript (or an
unexpired waiver) on every qualified cell, and a Tier-3 surface change cannot merge without fresh live
evidence. A release that changes none of the Tier-3 surface needs no new live
run, which lets the release gate be evaluated automatically from existing
transcripts. A claimed cell may carry a dated, reasoned waiver in the ledger,
which lowers the bar: the gate reports it as waived and blocks again once it
expires. Cells that cannot reach a verdict are visible as blocked,
not silently dropped. The repository does not accumulate transcript files;
the durable reference is the release/PR artifact plus its hashes and
attestations.

## Verification

The matrix and the reproduction rule are themselves asserted by the
transcripts they govern: a green current transcript per qualified cell at
release, and a fresh transcript on any PR touching the Tier-3 surface.
`qualification.is_current` and `touches_surface` implement the currency test and
are covered by `py-acq/tests/test_qualification.py`. The ledger
(`docs/qualification-ledger.json`) records each run as metadata plus the SHA-256
of its `transcript.json`; `python -m qualification.gate check` evaluates the
release gate from it, and the `Tier-3 release gate` workflow runs that on every
PR, every push to `main`, and weekly. The ledger may carry dated, reasoned
waivers for a claimed cell that has no current transcript; a waiver lowers the
bar, is reported as such, and blocks again once it expires. The ledger is
self-reported and committed, so its integrity is a review control (CODEOWNERS
requires an admin's review of `docs/qualification-ledger.json`), not a technical
one; `transcript_sha256` helps only if the transcripts attached to the release
are audited against it. A run must be recorded at a commit that is on `main`.
