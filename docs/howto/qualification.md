---
title: "Cross-Platform Qualification How-To (Tier-3)"
description: "How to run the six ADR-0044m Tier-3 qualification oracles and record honest PASS/FAIL/BLOCKED transcripts on macOS and Linux hosts"
status: canonical
tier: 3
last_updated: "2026-11-07"
audience: "developers"
keywords: ["qualification", "tier-3", "transcript", "msb", "sbx", "oracle", "adr-0044m", "matrix"]
related_files: ["docs/adr/0044m-live-cross-platform-qualification-matrix-and-transcript.md", "qualification/README.md", "docs/qualification-ledger.json", ".github/workflows/tier3-release-gate.yml", "scripts/qualify-backend-cell", "scripts/qualify-msb-ro-mount", "docs/KNOWN_FAILURE_MODES.md", "docs/adr/0035-host-authoritative-sandbox-config.md", "docs/adr/0041m-configuration-and-state-migration-behavior.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# Cross-Platform Qualification How-To (Tier-3)

> This is the **Tier-3 live-qualification** runbook for the Python `acq` v1
> replacement (ADR-0044m). It is the downstream consumer of the
> [`qualification/`](../../qualification/README.md) harness. It tells a human —
> or an agent on a macOS/Linux host — exactly how to run the six host-enforced
> oracles, compute the transcript identity fields honestly, and record the
> verbatim `RESULT` line. The on-host Windows x64 cells are already **green**;
> the remaining cells need macOS/Linux hosts.

---

## What this is

The acq v1 rewrite is functionally complete and the on-host Tier-3 milestone is
reached: both **Windows x64** cells qualified **PASS** against real msb 0.7.11
and sbx 0.51.0. The remaining ADR-0044m qualified cells require macOS/Linux
hosts that this Windows-only box cannot provide, so this runbook documents how
to qualify them.

Each cell is in exactly one of three states: **qualified** (green *current*
transcript), **unqualified** (not claimed), or **blocked** (attempted, no
verdict). `BLOCKED` is a first-class recorded outcome — never a pass — and it
holds the release gate.

---

## The matrix and version floors

The qualified matrix (ADR-0044m `QUALIFIED`):

| Backend | Claimed cells | Version floor | Windows x64 |
|---------|---------------|---------------|-------------|
| **msb** | linux-x86_64, linux-aarch64, macos-arm64, macos-x86_64, windows-x64 | ≥ 0.6.9 (refusing 0.7.0–0.7.2; oracles 1–3 need ≥ 0.7.7) | ✅ PASS |
| **sbx** | linux-x86_64, macos-arm64, windows-x64 | ≥ 0.39.0 (provider-credential set needs ≥ 0.51.0) | ✅ PASS |

**Already green:** `windows-x64` (both backends), produced by the same oracle
that is committed here (`scripts/qualify-backend-cell`).

**Remaining (need macOS/Linux hosts):**

- msb: `linux-x86_64`, `linux-aarch64`, `macos-arm64`, `macos-x86_64`
- sbx: `linux-x86_64`, `macos-arm64`

**Unqualified (not claimed, reported honestly, never a pass):** Windows ARM64,
musl libc, and sbx on macOS x86_64 and Linux aarch64.

---

## The six oracles

| # | Oracle | What it proves | Host(s) it needs |
|---|--------|----------------|------------------|
| 1 | ro-mount canary | msb enforces a `:ro` trusted-config mount | msb on KVM/HVF |
| 2 | secret non-exposure | secret set/ls/rm + provider-credential set/ls/rm round-trip; the value never appears in argv or output | sbx |
| 3 | real backend behaviour | create/ls/exec/rm boot contract + secret/provider-credential non-exposure (the committed cell oracle); kit apply, attach, version fail-closed asserted elsewhere | msb and sbx |
| 4 | offline completeness | network-blocked install + smoke | **blocked** (release automation) |
| 5 | security-exception recreation | strip the read-only-mount record, fail closed, recreate preserving secrets/identity | msb (ADR-0035) |
| 6 | native-Windows ordinary-user operation | ordinary-user (non-admin) Windows x64 | **done** |

### Oracle 1 — ro-mount canary

Optional, **non-gating**, corroborating evidence (ADR-0035). It is *not* what
`acq`'s read-only-mount gate depends on — the gate is the per-sandbox record
plus a version floor — but it proves the `:ro` volume is actually enforced by
this msb on this host. Requires msb on PATH and a KVM/HVF-capable host with
network access for the image pull. Run it **outside** any sandbox:

```bash
bash scripts/qualify-msb-ro-mount
```

It prints its own `RESULT <PASS|FAIL|BLOCKED> msb=<ver> …` line and writes its
evidence under `tmp/qualify-msb-ro-mount-<stamp>/`.

### Oracle 2 — secret non-exposure

Exercises the secret and (sbx-only) provider-credential round-trips and asserts
the throwaway value never appears in any captured stdout or stderr. On sbx the
secret verbs work (`sbx secret set/ls/rm` and `secret set-custom --value-stdin`);
on msb they fail closed (`unsupported_capability` — there is no secret store, so
there is nothing to leak).

```bash
V="$(sbx version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
python -m qualification run \
  --backend sbx --backend-version "$V" \
  --os "$(uname -s)" --os-build "$(uname -r)" --arch "$(uname -m)" \
  --hypervisor "$HYPERVISOR" \
  --image docker.io/docker/sandbox-templates:shell-docker \
  --rev "$(git rev-parse HEAD)" \
  --artifact-sha256 "$ARTIFACT_SHA256" \
  --transcript-dir "$TRANSCRIPT_DIR" \
  --timeout 900 \
  -- scripts/qualify-backend-cell --backend sbx
```

### Oracle 3 — real backend behaviour

The committed `scripts/qualify-backend-cell` oracle exercises the
create/ls/exec/rm boot contract and (on sbx) the secret/provider-credential
non-exposure round-trips. ADR-0044m's oracle 3 also names **kit apply**,
**attach**, and **version fail-closed**, which the cell oracle does **not**
exercise — those facets are asserted elsewhere:

- **version fail-closed** — Tier-1 subprocess vectors (`test/vectors`,
  `py-acq/tests/test_backends.py`).
- **attach** — Tier-2 implementation tests (`py-acq/tests/test_exec.py`).
- **kit apply** — the ADR-0030 devenv-base slice.

Run the cell oracle once per backend:

```bash
for B in msb sbx; do
  case "$B" in
    msb) V="$(msb --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" ;;
    sbx) V="$(sbx version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" ;;
  esac
  python -m qualification run \
    --backend "$B" --backend-version "$V" \
    --os "$(uname -s)" --os-build "$(uname -r)" --arch "$(uname -m)" \
    --hypervisor "$HYPERVISOR" \
    --image docker.io/docker/sandbox-templates:shell-docker \
    --rev "$(git rev-parse HEAD)" \
    --artifact-sha256 "$ARTIFACT_SHA256" \
    --transcript-dir "$TRANSCRIPT_DIR" \
    --timeout 900 \
    -- scripts/qualify-backend-cell --backend "$B"
done
```

> **Note on the oracle invocation.** The committed oracle is a shebang-executable
> Python script (`#!/usr/bin/env python3`), so the bare `scripts/qualify-backend-cell`
> form works on Linux/macOS (the remaining hosts). Windows does not honour the
> `#!` shebang for a bare path, so on Windows prefix it with `python`:
> `… -- python scripts/qualify-backend-cell --backend <B>`. The script drives the
> shipped CLI as `python -m acq_py` with `PYTHONPATH` pointing at `py-acq/src`
> relative to its own location, and derives its workspace from `tempfile`.

### Oracle 4 — offline completeness

**Blocked on release automation.** The installer's fail-closed presence checks
are proven offline against a fixture, but the live "install from the enumerated
offline asset set alone, then smoke" transcript has not been fabricated. See the
"Deferred: live offline-install completeness transcript (Tier-3)" note in
[`docs/KNOWN_FAILURE_MODES.md`](../KNOWN_FAILURE_MODES.md) for what the deferred
transcript must assert and the release-automation unblock trigger. Record this
cell **blocked**, never a pass.

### Oracle 5 — security-exception recreation (ADR-0041m)

Proves that a sandbox missing its host-enforced read-only trusted-config mount
fails closed, and that recreation preserves host records and secrets. The
sequence:

1. Create a sandbox and note its name.
2. Strip the read-only-mount record (or otherwise induce the security
   exception), then run a trusted operation (`acq run` / `acq exec`) and confirm
   it is refused with `security_exception`.
3. Recreate explicitly and consented:
   `acq create --recreate <name> --yes` — host records and secrets are
   preserved, the guest filesystem is lost.
4. Confirm the recreated sandbox works and the host-held records/secrets are
   intact.

Record the sequence and its observed refusal/recovery in the transcript.

### Oracle 6 — native-Windows ordinary-user operation

**Done.** Both Windows x64 cells qualified PASS as an ordinary (non-admin) user;
no further host is needed.

---

## Computing the identity fields honestly

Every transcript records a commit SHA, artifact SHA-256, backend version, OS
build, arch, and hypervisor state (ADR-0044m). Compute them on the target host —
never copy them from another host:

| Field | Command |
|-------|---------|
| `--rev` | `git rev-parse HEAD` |
| `--artifact-sha256` | SHA-256 of `git archive HEAD` (or of the release asset under acceptance) |
| `--os` | `uname -s` (Linux/Darwin); `Windows` on Windows |
| `--os-build` | `uname -r` (Linux); `sw_vers -productVersion` (macOS); `(Get-CimInstance Win32_OperatingSystem).Version` (Windows) |
| `--arch` | `uname -m` (x86_64/aarch64/arm64) — the harness's raw value; the ADR matrix *platform token* `windows-x64` is separate naming, not this value |
| `--hypervisor` | `kvm` (Linux, `/dev/kvm` present), `hvf` (macOS), `wsl2` (Windows) |
| `--backend-version` | `msb --version` / `sbx version`, passing the numeric core (e.g. `0.7.11`, `0.51.0`) |

`--artifact-sha256` from a clean tree:

```bash
git archive HEAD | sha256sum   # Linux
git archive HEAD | shasum -a 256   # macOS
```

`--glibc-floor` is optional and Linux-only (record the glibc floor where
relevant, else omit).

---

## Attaching and recording transcripts

Transcripts are **not committed** (ADR-0044m): the durable reference is the
release/PR artifact plus its hashes and attestations.

1. Run each cell with `--transcript-dir <dir>`; the harness writes
   `transcript.json` there and emits the two lines:

   ```text
   OUTCOME <PASS|FAIL|BLOCKED|FLAKY>
   RESULT <PASS|FAIL|BLOCKED> <backend>=<ver> image=<image> host=<os arch> rev=<sha> dir=<abs path>
   ```

2. Attach the transcript directory (and, where available, an attestation) to the
   release and — for a PR touching the Tier-3 surface — to that PR as an artifact.
3. Record the `RESULT` line plus the identity hashes in the release/PR notes;
   do not commit the transcript files themselves.

A `FAIL` is confirmed real only by reproducing on the same environment within
three attempts with matching identity fields (a diverging result is escalated
`FLAKY`, never softened). A transcript is current for 90 days, until the
backend's `major.minor` version changes, and until a change lands on the Tier-3
surface (`py-acq/src/acq_py/`, the two `scripts/qualify-*` oracles, and
`qualification/`); regenerate it then. The commit SHA and artifact SHA-256 are
provenance only: a release-please commit changes both without expiring
anything.

---

## Worked example — the Windows x64 PASS

The two green Windows x64 cells (run on this host with `--timeout 900`) produced
these reference `RESULT` lines; every host regenerates its own with its own
`--rev`, `--artifact-sha256`, `--os-build`, `--arch`, and `--hypervisor`:

```text
OUTCOME PASS
RESULT PASS msb=0.7.11 image=docker.io/docker/sandbox-templates:shell-docker host=Windows x86_64 rev=8b65b313b67241696ef4f2398b3ec0444e75bec8 dir=<transcript-dir>

OUTCOME PASS
RESULT PASS sbx=0.51.0 image=docker.io/docker/sandbox-templates:shell-docker host=Windows x86_64 rev=8b65b313b67241696ef4f2398b3ec0444e75bec8 dir=<transcript-dir>
```

Identity fields recorded in those transcripts (not on the `RESULT` line itself):

- `artifact-sha256`: `f6227011994a575d79bb177f8d8f48819d2a023cd4a12e96bdaf4aeb8abc4d09`
- `os-build`: `10.0.26200`
- `arch`: `x86_64`
- `hypervisor`: `wsl2`

---

## Recording a run and the release gate

A live run is evidence only once it is in the ledger, `docs/qualification-ledger.json`
(metadata and the SHA-256 of each `transcript.json`; never the transcript itself,
which goes on the release). After a green run on a host:

```bash
python -m qualification.gate record path/to/transcript.json
```

It derives the cell from the transcript's OS and architecture (pass `--platform`
to override) and appends one entry. Run the cell at a commit that is on `main`
(`--rev "$(git rev-parse HEAD)"`, as in the commands above): `record` refuses the
harness's all-zero default, and a commit that only existed on a squash-merged PR
branch is not in `main`'s history, so the gate could not resolve it. Every outcome
is recorded, not only `PASS`: the latest entry for a cell decides, so a recorded
`FAIL`, `BLOCKED` or `FLAKY` blocks a cell that had a current `PASS`. Commit the
ledger change through a normal PR; CODEOWNERS requires an admin's review of it,
because the ledger is self-reported evidence.
Per-attempt timestamps are in the transcript; for one written by an older harness,
pass `--recorded-at <ISO 8601 UTC>`.

The gate, `python -m qualification.gate check`, runs in CI (`Tier-3 release gate`)
on every PR, every push to `main`, and weekly. It needs no live run: for each of
the eight claimed cells it takes the latest ledger entry and passes it only if the
verdict is `PASS`, it is under 90 days old, its backend `major.minor` equals
`accepted_backend_versions` in the ledger, and no file on the Tier-3 surface
(`TIER3_SURFACE` in `qualification/matrix.py`: the CLI source, the two oracles, and the harness's run path) changed between its recorded
revision and `HEAD`. A release-please commit changes none of those, so releases do
not expire anything. Anything the gate cannot establish fails closed.

When a backend is upgraded, change `accepted_backend_versions` in the same PR:
cells recorded at the old `major.minor` become blocked until re-run.

A cell without a current transcript can carry a **waiver** in the ledger: a reason,
an `expires` date, and optionally an issue. A waived cell does not block the gate
but is reported as `waived` in the job summary, and a waiver that has expired blocks
again. Waivers lower the bar; keep them short and remove each one as its cell is
recorded.

Making it hold a release: the check only informs unless `Tier-3 release gate` is a
required status check on `main` (repository settings, not code). **Do not require
it yet.** release-please opens its PR with the default `GITHUB_TOKEN`, and GitHub
does not run `pull_request` workflows for PRs that token creates, so the check
would never report on the release PR and a required check would leave it
unmergeable. First give release-please a PAT or GitHub App token (the `token`
input of `release-please-action` in `release.yml`); then the check runs on the
release PR and can be required. Until then the gate runs on every push to `main`
and weekly, and `release.yml` does not consult it.

## Honest BLOCKED handling

- An unavailable, or attempted-but-no-green, cell records **BLOCKED** — never a
  pass, never a silent skip.
- A missing backend CLI is a BLOCKED precondition: `scripts/qualify-backend-cell`
  exits `2` (the harness reports `OUTCOME BLOCKED`).
- Any step failure prints `FAIL: <step>` to stderr and exits `1` (the harness
  applies the 3-attempt reproduction rule).
- Oracle 4 stays **blocked** until release automation assembles and publishes
  the per-platform offline archives (see `docs/KNOWN_FAILURE_MODES.md`); do not
  fabricate a transcript for it.
