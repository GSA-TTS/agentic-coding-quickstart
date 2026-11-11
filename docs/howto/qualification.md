---
title: "Cross-Platform Qualification How-To (Tier-3)"
description: "How to run the six ADR-0044m Tier-3 qualification oracles and record honest PASS/FAIL/BLOCKED transcripts on macOS, Linux and Windows x64 hosts"
status: canonical
tier: 3
last_updated: "2026-11-09"
audience: "developers"
keywords: ["qualification", "tier-3", "transcript", "msb", "sbx", "oracle", "adr-0044m", "matrix"]
related_files: ["docs/howto/release-gate-setup.md", "docs/adr/0044m-live-cross-platform-qualification-matrix-and-transcript.md", "qualification/README.md", "docs/qualification-ledger.json", ".github/workflows/tier3-release-gate.yml", "scripts/qualify-backend-cell", "scripts/qualify-msb-ro-mount", "docs/KNOWN_FAILURE_MODES.md", "docs/adr/0035-host-authoritative-sandbox-config.md", "docs/adr/0041m-configuration-and-state-migration-behavior.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# Cross-Platform Qualification How-To (Tier-3)

> This is the **Tier-3 live-qualification** runbook for the Python `acq` v1
> replacement (ADR-0044m). It is the downstream consumer of the
> [`qualification/`](../../qualification/README.md) harness. It tells a human —
> or an agent on a macOS, Linux or Windows x64 host — exactly how to run the six host-enforced
> oracles, compute the transcript identity fields honestly, and record the
> verbatim `RESULT` line. The ledger, not this page, says which cells are
> current: `python3 -m qualification matrix` prints each cell's state.

---

## Qualify this host in one command

On any macOS, Linux (with `/dev/kvm`) or Windows x64 host that has `msb` and/or
`sbx` installed and logged in, with Python >= 3.12 (`python3` on macOS and Linux, where plain `python` is often
absent; `py -3.12` on Windows) and `gh` logged in to your fork,
from the root of a clean checkout whose `HEAD` is on your fork's `main`
(`git fetch <fork> && git switch --detach <fork>/main`; an older checkout that predates
this tool has no `qualification/` directory, and `python3 -m qualification.host` fails
with "No module named 'qualification'"):

> **sbx needs a usai key in sbx's own table.** The usai-provider kit is selected,
> and acq refuses a create whose provider key the backend cannot inject. On msb
> the oracle stores a throwaway key in its private acq store, but on sbx the key
> must be in sbx's global proxy table, which the oracle never writes (that would
> overwrite your key). Store one first with
> `acq --backend sbx secret set -g usai`. Without it the sbx cell reports
> **BLOCKED** (exit 2, "usai key") before anything is created.

```bash
python3 -m qualification.host       # Windows: py -3.12 -m qualification.host
```

It detects the host (OS build, architecture, hypervisor), runs the cell oracle
through the harness for each backend claimed on this platform, records the green
runs in the ledger (retiring the cell's waiver if it has one), then commits the
ledger change in a throwaway worktree branched from your fork's **current** `main`
(not the revision tested, so a run that finishes while another host's ledger PR lands
still merges cleanly and keeps that host's entries), pushes a new
`chore/ledger-<platform>-<time>` branch to your **fork** remote, and opens a PR **into the fork's `main`** (with `gh`,
or it prints the URL). Merge that PR as usual. It never pushes to the upstream
repository (every fetch and push URL of the remote is checked), never touches your
checkout, and records only green runs unless you pass `--record-failures`.

It works from any ledger state, so use it for the first run of a cell, to renew a
stale or expiring one, after a Tier-3 surface change, and after a backend upgrade.
Re-running is safe. A backend whose CLI is missing is reported `SKIPPED`, not
recorded. If the installed backend's `major.minor` is not the ledger's accepted one it
stops before the long run; install the accepted version or pass
`--accept-backend-version`. That moves the accepted version in the same PR, only for a
backend whose run went green, and the PR lists the cells on other platforms that stop
being qualified because of it (they must be re-run). If publishing fails after a long
run, the transcripts are kept and the error prints the `gate record` commands to use.
Remotes must be plain `https://github.com/<you>/<repo>` or `git@github.com:<you>/<repo>`
URLs for a personal fork (ssh host aliases, enterprise hosts and the upstream
organisation are refused).

| Option | Effect |
|--------|--------|
| `--dry-run` | print the host, revision, per-cell state and the PR target; run nothing. A condition that would stop a real run is reported as `WOULD REFUSE` (exit 2) after the plan, so a preview from any branch still shows the plan |
| `--only-stale` | skip cells that are already current |
| `--no-publish` | record into this checkout's ledger only; no branch, push or PR |
| `--backend msb` / `--backend sbx` | run one backend (repeatable) |
| `--remote NAME` | fork remote to publish to (default: the only non-upstream remote) |
| `--record-failures` | also record `FAIL`/`FLAKY` outcomes (published like any other) |
| `--accept-backend-version` | move the ledger's accepted backend version to the installed one |
| `--timeout SECONDS` | per attempt (a `FAIL` is retried up to 3 times; default 1800) |

Exit status: `0` every selected backend passed or was already current, `1` a
`FAIL`/`FLAKY`, `2` anything else (a skipped or blocked backend, or a precondition
failed and nothing ran). Alpine/musl hosts and an x86_64 Python under Rosetta are
refused, since they would mislabel the cell, and so is a backend below the ADR-0044m
floors (msb below 0.7.7 or in 0.7.0–0.7.2, sbx below 0.39.0), since a run on it is not
evidence.

The ledger PR carries each `transcript.json` inline, byte for byte, in a collapsed
block with its SHA-256: the lines inside the block, each ending in a newline, are the
file, and hash to the `transcript_sha256` its ledger entry records. Anyone can check
a ledger PR from the PR alone, in a checkout of its branch:

```bash
git fetch origin     # the merge-base below must be computed against the current main
gh pr view <number> --json body -q .body \
  | python3 -m qualification.gate verify-evidence --base "$(git merge-base origin/main HEAD)" -
```

It prints `OK <sha256>` for each block whose hash is recorded and whose entry the
block reproduces field for field. With `--base` it also requires exactly one such
block for every entry the PR adds to the ledger (compared with the ledger as committed
at that revision) and reports `MISSING` for an entry with none and `EXTRA` for a block
that stands for any other entry. Without `--base` a body that leaves an entry out still
passes, so always give it. It always rejects a block shown twice (`DUPLICATE`) and a
block inside an HTML comment (`HIDDEN`), which GitHub does not render and so no
reviewer sees. It exits `0` only when there is no problem. Once the PR is open,
the copies the run leaves under `tmp/qualify-out-<time>/` are therefore disposable.
(A transcript is ~1 KB of metadata and hashes: verdict, the oracle's argv, versions,
host identity, commit and artifact SHA, and a *digest* of the observed output. The
harness never records raw output, the environment or a host-local path: the
transcript directory is written as `<transcript-dir>` and an absolute command-line
path keeps only its last component, as in `<local>/python3`, because a local path
names the operator's account. The `RESULT` line's `dir=` value is replaced in the
PR body.) The sections below are what that command runs, for reference and for
debugging a single step.

## What this is

The runbook for producing Tier-3 evidence for each claimed cell of the ADR-0044m
matrix. The ledger (`docs/qualification-ledger.json`) is the record of which cells
hold a current green transcript; `python3 -m qualification matrix` (or
`python3 -m qualification.gate check`) prints it.

Each cell is in exactly one of three states: **qualified** (green *current*
transcript), **unqualified** (not claimed), or **blocked** (attempted, no
verdict). `BLOCKED` is a first-class recorded outcome — never a pass — and it
holds the release gate.

---

## The matrix and version floors

The qualified matrix (ADR-0044m `QUALIFIED`):

| Backend | Claimed cells | Version floor | Windows x64 |
|---------|---------------|---------------|-------------|
| **msb** | linux-x86_64, linux-aarch64, macos-arm64, windows-x64 | ≥ 0.6.9 (refusing 0.7.0–0.7.2; oracles 1–3 need ≥ 0.7.7) | claimed |
| **sbx** | linux-x86_64, macos-arm64, windows-x64 | ≥ 0.39.0 (provider-credential set needs ≥ 0.51.0) | claimed |

The floors are enforced, not advisory (`version_problem` in `qualification/matrix.py`):
the gate blocks a cell whose latest entry, or whose accepted backend version, is below
them or in msb's refused range; the ledger refuses to accept such a version; and
`qualification.host` will not run on one. Since the cell oracle exercises oracles 1–3,
an msb run is evidence only at 0.7.7 or later.

Which cells are current is the ledger's to say, not this page's:
`python3 -m qualification matrix`. The macOS arm64 and Windows x64 runs recorded so
far were made with the earlier cell oracle, which did not check credentials, kits or
the read-only mount; any change to the oracle expires them (it is on the Tier-3
surface), so every cell needs a run with the current oracle.

**Unqualified (not claimed, reported honestly, never a pass):** Windows ARM64,
musl libc, macOS x86_64 (Intel Mac, every backend), and sbx on Linux aarch64.

---

## The six oracles

| # | Oracle | What it proves | Host(s) it needs |
|---|--------|----------------|------------------|
| 1 | read-only trusted-config mount | in the cell's own guest the mount is `ro`, a write fails with EROFS and the host directory is unchanged; acq records the mount; the canary (run by the cell oracle) shows this msb keeps `:ro` against remounts | msb on KVM/HVF |
| 2 | secret binding and non-exposure | a credential bound before create shows up in the guest as a non-empty placeholder, the value is in neither the guest's environment nor PID 1's, and secret / provider-credential set/ls/rm never print it; swap-on-the-wire is not checked (see below) | msb and sbx |
| 3 | real backend behaviour | create/ls/exec/rm boot contract and built-in kit apply (the committed cell oracle); attach and version fail-closed asserted elsewhere | msb and sbx |
| 4 | offline completeness | network-blocked install + smoke | **blocked** (release automation) |
| 5 | security-exception recreation | strip the read-only-mount record, fail closed, recreate preserving secrets/identity | msb (ADR-0035) |
| 6 | native-Windows ordinary-user operation | ordinary-user (non-admin) Windows x64 | **done** |

### Oracle 1 — read-only trusted-config mount

On msb cells the cell oracle checks, in the cell's **own** guest, the effect of the
read-only trusted-config mount (ADR-0035/ADR-0041m):

- `/proc/mounts` lists `/var/lib/acq/host` (where acq mounts the sandbox's host-config
  directory) with the `ro` option;
- a write there, as root when `sudo -n` works, fails with EROFS (`Read-only file
  system`), not merely with a permission error;
- the host directory acq keeps for the sandbox
  (`$XDG_STATE_HOME/acq/provenance/msb/<sandbox>.<checksum>.config`, the layout both
  implementations use) is byte-identical after the attempt.

On Windows acq never requests this mount, because msb's Windows filesystem backend
has not been reviewed for read-only enforcement (ADR-0048m). The oracle reports that
as `BLOCKED` with the reason, not `FAIL`: the windows-x64 msb cell cannot qualify until
that review is done or the cell is waived.

It also checks that acq's sandbox record declares the mount (`ro_host_config`, what
acq's own fail-closed gate keys on), and runs the committed canary. The canary shows,
in a sandbox of its own, that this msb keeps a `:ro` volume read-only even when the
guest tries to remount it read-write; the cell oracle does not attempt a remount in its
own guest. Canary exit `1` together with its `RESULT FAIL` line fails the cell; exit
`0` counts only with its `RESULT PASS` line; anything else, a timeout, or no usable
`bash` makes it `BLOCKED`. The canary's sandbox is given this run's nonce name
(`acq-qual-ro-<nonce>`, via `QUALIFY_SANDBOX_NAME`), and teardown removes it too, in
case the canary was stopped before its own cleanup ran. On Windows the WSL launcher (`System32\bash.exe`,
and the Store alias) is never used, since it would run the canary inside a WSL
distribution; Git Bash is looked for in its install locations, then any other `bash`
on the absolute `PATH` entries. The canary always uses the default image: the oracle
removes `QUALIFY_IMAGE` and `EXPECT_SHA`, and `ACQ_QUALIFY_OUT_DIR` is dropped with the
other `ACQ_*` variables; `STEP_TIMEOUT` and `EXEC_TIMEOUT` are honoured. To run the
canary alone, **outside** any sandbox:

```bash
bash scripts/qualify-msb-ro-mount
```

It prints its own `RESULT <PASS|FAIL|BLOCKED> msb=<ver> …` line and writes its
evidence under `tmp/qualify-msb-ro-mount-<stamp>/`.

### Oracle 2 — secret binding and non-exposure

Before creating the sandbox the cell oracle binds a throwaway value with
`acq provider-credential set` for the host `qualify.invalid` (reserved, so it can never
resolve; value on stdin only). Inside the guest the bound variable must hold a
non-empty placeholder, and the value must appear in neither `env` nor
`/proc/1/environ`. If `/proc/1/environ` cannot be read, even with `sudo -n`, that is
reported and the cell is `BLOCKED`, not passed. Host-side, `secret set/ls/rm` and
`provider-credential set/ls/rm` must never print it; on msb the secret is set the way
AGENTS.md documents for a service that is not built in
(`secret set -g <service> --host qualify.invalid --env <nonce variable>`). Both
backends are checked: AGENTS.md documents a credential path on msb (`--secret
ENV@HOST`) as well as on sbx. The Python implementation keeps msb secrets in the acq
secret store and binds them as `--secret ENV@HOST` at create (running sandboxes are
updated with `msb modify --secret`/`--secret-rm`); a live msb run of this step is
still to be recorded.

Swap-on-the-wire (the real value, not the placeholder, reaching the bound host) is
**not** checked: it needs an endpoint that reports what it received, and the oracle
sends nothing to hosts outside the approved list. This is tracked in
`docs/KNOWN_FAILURE_MODES.md` ("Tier-3 oracle facets the cell oracle cannot check
unattended").

The run never touches the operator's own credentials or acq state. Every acq
subprocess gets a private configuration and state tree (`XDG_CONFIG_HOME`,
`XDG_STATE_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `ACQ_STATE_DIR`,
`ACQ_SECRET_STORE_DIR`), deleted afterwards. The sandbox, the secret service, the
provider id and the credential variable all carry a per-run nonce, so nothing in a
backend's own store can be overwritten, and the sbx teardown removes only the custom
secrets whose variables are this run's. The names are printed to stderr before
anything else, so a run that is killed outright can be cleaned up by hand. `HOME` is
kept, because the backend CLIs keep their login, daemon and image cache there. The
caller's `ACQ_*` variables are not passed to acq (a stub seam such as
`ACQ_MSB_BIN=__stub__` would otherwise turn a live run into a stubbed one), except
those ending in `_TIMEOUT`, such as `ACQ_MSB_READY_TIMEOUT`, which only tune timing.
`PYTHONPATH` is fixed to this checkout's `py-acq/src`, the CLI runs under
`python -P -s` (no current directory and no user site-packages on `sys.path`), and
`msb`, `sbx` and `bash` are resolved by acq's own resolver (`acq_py.hostexec`) from
absolute `PATH` entries only, never the current directory, and only as `.exe` files
on Windows.

The harness tooling follows the same rules. `qualification.host` starts its Python
children (the harness, and the gate check before a publish) with `-P` and a
`PYTHONPATH` fixed to the checkout it was imported from, never yours, so the oracle
it runs inherits that fixed value too. `git`, `gh` and the backend CLIs it calls
(and the gate's and ledger's `git` calls) are resolved with the same resolver.

**Aborts.** When a run outlives the harness's `--timeout`, the harness sends SIGTERM
(CTRL_BREAK on Windows), waits a grace period (a quarter of the timeout, at most 300
seconds) and only then kills it. Ctrl+C on the harness is passed on too: the harness
sends the oracle the same SIGTERM (CTRL_BREAK on Windows, where the oracle runs in a
process group of its own and never sees the console's Ctrl+C) and waits the same
grace period before killing it. On POSIX a terminal's Ctrl+C also reaches the oracle
directly as SIGINT; the forwarded SIGTERM is what reaches it when only the harness
was interrupted, for example by a supervisor's `kill -INT`. The harness checks for
Ctrl+C at least once a second while it waits, Windows included. The oracle turns the
first signal into a normal exit and tears down, and from then on swallows any further
one, so it cannot cut short the stop of the step it was waiting on or the teardown.
The oracle runs each acq call and the canary in a process group of its own and stops
a group the same way (SIGTERM, a grace period, then kill), so an interrupted
`msb create` or canary run cleans up instead of leaving a sandbox behind. On Windows each of them also runs in a Job object of its own: the
kill terminates the job, which holds that call's processes and nothing else, and if
the oracle is killed outright the job takes them down with it. A process that a call
starts with `CREATE_BREAKAWAY_FROM_JOB` leaves the job and survives the kill; that is
intended (a backend may detach its daemon that way), because the job is a cleanup
tool, not a security boundary. A backend daemon that a call
starts without detaching is stopped with it; start the daemon before the run (see
`docs/KNOWN_FAILURE_MODES.md`). The oracle is also given a deadline (`ACQ_QUALIFY_DEADLINE`) that ends one grace
period before the timeout; at the deadline it stops starting steps, tears down and
reports `BLOCKED`; a step the deadline cut short is `BLOCKED` too, not `FAIL`.
Teardown always tries to remove the nonce-named sandbox, canary sandbox, secret and
provider binding, whether or not the run saw them created.

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
  --timeout 1800 \
  -- scripts/qualify-backend-cell --backend sbx
```

### Oracle 3 — real backend behaviour

The committed `scripts/qualify-backend-cell` oracle exercises the
create/ls/exec/rm boot contract (the exec probe prints a number the guest computes,
so a backend that echoes the command instead of running it cannot pass) and
**kit apply**: the guest must have the file the pinned usai-provider kit places
(`/home/agent/usai-config/model-catalog-snapshot.json`), which shows the built-in
kits were applied at create (on sbx this needs the usai key described above). ADR-0044m's oracle 3 also names **attach** and
**version fail-closed**, which the cell oracle does **not** exercise:

- **version fail-closed** — Tier-1 subprocess vectors (`test/vectors`,
  `py-acq/tests/test_backends.py`).
- **attach** — Tier-2 implementation tests (`py-acq/tests/test_exec.py`).

The control checks (oracles 1–3) all run and each failure is printed as
`FAIL: <step>: <why>`, so one run lists everything that is missing; a boot-contract
failure stops the run.

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
    --timeout 1800 \
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
surface (the CLI source tree, the two `scripts/qualify-*` oracles, and the
harness's run path — minus the `version`/`doctor` command modules; the exact
list is `TIER3_SURFACE`/`TIER3_SURFACE_EXCLUSIONS` in `qualification/matrix.py`);
regenerate it then. The commit SHA and artifact SHA-256 are
provenance only: a release-please commit changes both without expiring
anything.

---

## Worked example — the Windows x64 PASS

The two green Windows x64 cells (run with the earlier cell oracle and
`--timeout 900`) produced these reference `RESULT` lines; every host regenerates its own with its own
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
python3 -m qualification.gate record path/to/transcript.json   # Windows: py -3.12 -m ...
```

It derives the cell from the transcript's OS and architecture and appends one
entry. `--platform` can only restate that cell (or `linux-musl` for a Linux run): a
run is evidence for the host it ran on, and the recorded arch and hypervisor must be
that cell's (`kvm` on Linux, `hvf` on macOS, `wsl2` on Windows). `record` also
refuses a transcript unless every attempt ran exactly
`scripts/qualify-backend-cell --backend <the transcript's backend>` (directly or
after the Python interpreter), and it stores the SHA-256 of that oracle as committed
at the run's revision, so run it in a checkout that has that revision. It also
refuses a transcript that could not be published verbatim: one not in the harness's
canonical byte form (sorted keys, two-space indent, ASCII, LF, one trailing newline;
re-serializing or a CRLF conversion breaks it) or one that records a host-local path.
Those come only from an older harness; re-run the cell. These
command and platform checks happen only in `record`, on your machine. The gate never
sees the transcript: it checks each entry against the repository (the committed
oracle's name and its hash at the entry's revision, arch and hypervisor against the
cell, no transcript hash filed twice, a full revision that is an ancestor of the
commit being evaluated). A hand-written entry that passes those is caught only by
the admin review of the ledger PR and an audit of the transcript it inlines against
`transcript_sha256` (`python3 -m qualification.gate verify-evidence`, above). Run the cell at a commit that is on `main`
(`--rev "$(git rev-parse HEAD)"`, as in the commands above): `record` refuses the
harness's all-zero default, and a commit that only existed on a squash-merged PR
branch is not in `main`'s history, so the gate could not resolve it. Every outcome
is recorded, not only `PASS`: the latest entry for a cell decides, so a recorded
`FAIL`, `BLOCKED` or `FLAKY` blocks a cell that had a current `PASS`. Commit the
ledger change through a normal PR. The ledger is self-reported evidence, so the
PR needs an admin's review. CODEOWNERS enforces that review only when the named
teams can own paths in the repository and code-owner review is required by its
ruleset. Without those settings, the maintainer's audit is the control; see
[`release-gate-setup.md`](release-gate-setup.md), step 3 and its status note.
Per-attempt timestamps are in the transcript; for one written by an older harness,
pass `--recorded-at <ISO 8601 UTC>`.

The gate, `python3 -m qualification.gate check`, runs in CI (`Tier-3 release gate`)
on every PR, every push to `main`, and weekly. It needs no live run: for each of
the seven claimed cells it takes the latest ledger entry and passes it only if the
verdict is `PASS`, it is under 90 days old, its backend version meets the floors and
its `major.minor` equals `accepted_backend_versions` in the ledger, and no file on the Tier-3 surface
(`TIER3_SURFACE` in `qualification/matrix.py` — the CLI source tree, the two oracles, and the harness's run path, minus the `version`/`doctor` command modules) changed between its recorded
revision and `HEAD`. A release-please commit changes none of those, so releases do
not expire anything. Anything the gate cannot establish fails closed. On a pull
request CI runs the gate's code and rules (`qualification/`) from the base branch,
so a PR is judged by the rules already on `main`: a PR that changes the surface,
the claimed cells or the gate takes effect only after it merges.

When a backend is upgraded, change `accepted_backend_versions` in the same PR:
cells recorded at the old `major.minor` become blocked until re-run.

A cell without a current transcript can carry a **waiver** in the ledger: a reason,
an `expires` date, and optionally an issue. A waived cell does not block the gate
but is reported as `waived` in the job summary, and a waiver that has expired blocks
again. Waivers lower the bar; keep them short and remove each one as its cell is
recorded.

Making it hold a release (maintainer setup is collected in
[`docs/howto/release-gate-setup.md`](release-gate-setup.md)): `release.yml` already
consults the gate when `ENABLE_RELEASES` is `true`; otherwise the release jobs
do not run. `Release PR` and the release gate are directly gated on that repository
variable, and the remaining jobs depend on them. It is split into `Release PR` -> `Tier-3 release gate (release)`
-> `Release Tag`, so a stale cell leaves no tag and no GitHub Release.

Making it a **required status check** on `main` is a separate step, and the order
matters. A release PR opened with the default `GITHUB_TOKEN` may not get
`pull_request` checks at all, or may get them held for approval (both have been seen
upstream), and a required check that never reports leaves the PR unmergeable. Set the
`RELEASE_PLEASE_TOKEN` secret first (`release.yml` already prefers it over
`github.token`), watch one real release PR report the check, and only then require
it. See [`release-gate-setup.md`](release-gate-setup.md).

## Honest BLOCKED handling

- An unavailable, or attempted-but-no-green, cell records **BLOCKED** — never a
  pass, never a silent skip.
- A missing backend CLI is a BLOCKED precondition: `scripts/qualify-backend-cell`
  exits `2` (the harness reports `OUTCOME BLOCKED`).
- On msb, no usable `bash` (for the ro-mount canary), or a canary that exits with
  anything but `0` or `1`, is BLOCKED too, unless another step failed; so is an
  unreadable `/proc/1/environ`, and a run that reaches its deadline.
- Any step failure prints `FAIL: <step>` to stderr and exits `1` (the harness
  applies the 3-attempt reproduction rule).
- Oracle 4 stays **blocked** until release automation assembles and publishes
  the per-platform offline archives (see `docs/KNOWN_FAILURE_MODES.md`); do not
  fabricate a transcript for it.
