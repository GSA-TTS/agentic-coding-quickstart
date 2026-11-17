---
title: "Windows defaults to the Python implementation with acq's managed runtime"
status: accepted
date: 2026-11-08
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-5", "CM-7", "SI-7"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0048m: Windows defaults to the Python implementation with acq's managed runtime

## Context and Problem Statement

ADR-0047m keeps the Bash `acq` as the default on every platform, and selects the
Python implementation only when `ACQ_IMPL=python` is set. On Windows, "the Bash
`acq`" means running it under Git Bash (MSYS). A Windows 11 review found that this
path depends on Unix tools Git Bash does not provide:

- MSYS `ps` has no `-o`. The kit-fetch guardian and the provider-input lock
  guardian both rely on it, so under Git Bash every kit fetch and every
  provision/terminate fails silently on fork main. A pending fix teaches both to
  read MSYS `/proc` instead.
- The provider-input helpers run `python3` heredocs that use `os.O_NOFOLLOW` and
  `os.O_DIRECTORY`. Git for Windows has no `python3`, and Windows CPython has
  neither flag. So even with that fix, a Bash `create`, `run` or `rm` cannot
  complete on Windows.

Each incompatibility so far needed its own fix and its own test harness, and no
Windows CI exists to catch the next one.

Windows ships no Python. Its `python.exe` App Execution Alias is on the user
`PATH` by default. Run with arguments, as acq runs it, the alias only prints a
hint to install Python from the Microsoft Store and exits 9009. ADR-0042m makes
acq own an app-private runtime on each platform: python.org's embedded
distribution on Windows. A pending release change stages that runtime and acq's
source into the Windows archive, so an installed acq can run the Python
implementation natively, with no Git Bash and no system interpreter.

The question is whether Windows should keep defaulting to the implementation
that needs a Unix emulation layer.

## Decision

On Windows, `acq.cmd` and `acq.ps1` treat an unset `ACQ_IMPL` as `python`.
`ACQ_IMPL=bash` stays available as an explicit opt-in during the transition. On
macOS and Linux, and when the Bash `acq` script is run directly from a Git Bash
prompt, the ADR-0047m default (Bash) is unchanged.

Whenever the Python implementation is selected (explicitly today, and by default
once the gates below hold), the Windows launchers resolve the interpreter in this
order:

1. `ACQ_RUNTIME`, which must be an absolute path. This is how an IT-approved base
   runtime is selected; a relative value is refused.
2. The managed runtime at `py-acq\runtime\python.exe`.
3. The first `python.exe` found in a drive-rooted or UNC `PATH` entry that passes
   an isolated "Python 3.12 or newer" probe. Relative entries are never searched.
   Older interpreters and the App Execution Alias stub fail the probe and are
   skipped.

The chosen interpreter runs acq in safe-path mode (`-P`), so the current
directory never joins `sys.path`. If nothing qualifies, the launchers **fail
closed**, with a message that names the remedies (install from a release, install
Python 3.12+ on `PATH`, set `ACQ_RUNTIME`, or set `ACQ_IMPL=bash`). They never
silently fall back to Bash.

The default flips only when every gate below holds. Until then this ADR stays
`proposed`, and an unset `ACQ_IMPL` keeps the ADR-0047m behaviour.

1. **Runtime:**
   - an archive built by the release workflow's Windows build steps contains the
     managed runtime and acq's source;
   - `install.ps1 -Source <dir>` installs that archive;
   - the installed launcher reports `"impl": "python"` (`acq version`), and
     `acq doctor` reports the app-private runtime as present.

   This is checkable on the fork, which cuts no releases. The runtime's patch
   cadence, which ADR-0042m leaves to a separate decision and `py-acq/README.md`
   marks as a pending proposal, is settled and has an owner.
2. **Known gaps closed:** the open credential, kit/bootstrap/config and
   state/lifecycle issues for the Python implementation (see Links) are closed,
   with each finding in them fixed or explicitly accepted in the issue. Among
   other things, that covers:
   - secrets bound to their hosts on both backends;
   - the built-in kits being applied;
   - the persisted backend choice being honoured;
   - Bash-created state being read or migrated, so switching the default doesn't
     orphan existing sandboxes.
3. **Sandbox-control parity:** on each Windows backend, the Python implementation
   applies these controls as the Bash implementation does:
   - credential binding;
   - network policy;
   - the read-only trusted config mount;
   - kits.

   A Tier-3 oracle assertion covers each control by checking its effect (for
   example, that a disallowed destination is actually blocked), not just that a
   flag was passed.
4. **Command parity:** every command the Bash `acq` accepts on Windows is
   implemented, or is listed in this ADR as an accepted gap with its replacement.
   `start` and `restart` are implemented on msb; on sbx both refuse with
   `unsupported_capability` and point to `acq run`, as Bash does. (`secret
   set-custom` is not a gap: Bash refuses it with guidance, and Python rejects it
   as an unknown subcommand.)
   `acq configure` is implemented, with two accepted gaps:
   - **The first-run offer.** Bash offers to run `acq configure` the first time
     `acq create`/`run` finds no `config.yaml`. Python does not prompt; the
     replacement is running `acq configure` once by hand. *Update
     (2026-11-10): no longer a gap; Python makes the offer, under the same
     conditions (`py-acq/README.md`, "configure").*
   - **The create-time kit picker.** Bash lets a single `acq create`/`run` change
     the opt-in kits for that sandbox. Python has no picker. It does not apply
     extra kits at all yet (see "Python reads the configure keys" under Links), so
     until it does the replacement is the Bash acq (`ACQ_IMPL=bash`), whose picker
     and `ACQ_EXTRA_KITS` still work. *Update (2026-11-10): no longer a gap;
     Python applies extra kits and has the picker, under the same conditions
     (`py-acq/README.md`, "configure"). So `acq configure` has no accepted gaps
     left.*

   The deliberate behaviour differences of the Python `configure` are listed in
   `py-acq/README.md` under "configure".
5. **Proof:**
   - a Windows CI job runs the pytest and vector suites, and smoke-tests both
     launchers on pull requests;
   - the Tier-3 `windows-x64` transcript is recorded from a gate-1 install with
     `ACQ_IMPL` unset;
   - the Tier-3 surface includes the launchers, `install.ps1`,
     `scripts/stage-windows-runtime` and `py-acq/src/acq_py/runtime.py`, so a
     change to that path makes the ledger stale.
6. **Documentation:** the Windows setup docs and README describe the managed
   runtime, the new default, `ACQ_IMPL=bash`, `ACQ_RUNTIME`, and the existing
   one-time `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` prerequisite
   (the launchers deliberately do not pass `-ExecutionPolicy Bypass`).

## Consequences

- Windows users no longer need Git Bash for acq. The class of bugs that come from
  running Bash code under MSYS stops being reachable by default.
- Windows becomes the first platform where the Python implementation is the
  default. This stages the cutover described in `py-acq/README.md` (ADR-0041m: v1
  replaces Bash), starting where the Bash path is weakest, rather than a flag day
  across all platforms.
- Bash-path fixes that only matter under Git Bash become lower priority once the
  default flips, but they still apply while `ACQ_IMPL=bash` is supported.
- The managed runtime is on Windows users' critical path. The pin must stay on a
  CPython line that still publishes Windows embeddable binaries; once a line goes
  security-only, python.org stops publishing them.
- The default path runs the runtime's PSF-signed `python.exe`, DLLs and `.pyd`
  modules, plus acq's unsigned Python and PowerShell sources, from a user-writable
  directory (`%LOCALAPPDATA%`). AppLocker's default path rules block executables
  there whatever their signature (ADR-0042m), so managed fleets need a publisher
  rule for the PSF certificate, or an IT-approved base runtime selected through
  `ACQ_RUNTIME`. Where AppLocker script rules are enforced, `acq.ps1` in
  `%LOCALAPPDATA%` also needs its own allowance.
- `acq version` already reports `"impl"`, so bug reports show which
  implementation ran.

## Verification

When the gates are met, the launcher change is covered by:

- **A Windows CI job showing that:**
  - an unset `ACQ_IMPL` runs `py-acq\runtime\python.exe -P -m acq_py`;
  - `ACQ_IMPL=bash` still reaches Git Bash;
  - an unknown value exits 2;
  - with no managed runtime, an absolute `ACQ_RUNTIME` is honoured and a relative
    one is refused;
  - the App Execution Alias stub and relative `PATH` entries are never selected;
  - with nothing qualifying, the launcher fails closed with the message.
- **An install** of a gate-1 archive with `install.ps1 -Source <dir>`, followed
  by `acq version`, `acq doctor` and a create/rm cycle on each Windows backend.
- **The re-recorded Tier-3 `windows-x64` ledger entry** described in gate 5.

## Amendment (2026-11-10): accepted; the default flips now

The project lead approved the flip on 2026-11-10, before every gate above holds.
This ADR is `accepted`, and from this change on `acq.cmd` and `acq.ps1` treat an
unset (or empty) `ACQ_IMPL` as `python`. The Decision section otherwise stands as
written: the interpreter order, `-P`, the fail-closed message (which names
`ACQ_IMPL=bash` among its remedies) and exit 2 for an unknown value. The
sentence "The default flips only when every gate below holds" no longer
applies. The gates stay as the record of what the default still owes. Gates
that need a live Tier-3 run or a release no longer block the default; they are
open follow-ups, tracked under Links.

| Gate | State | Evidence |
|------|-------|----------|
| 1. Runtime | Met, with one noted leftover | `.github/workflows/build-assets.yml` (called by `.github/workflows/release.yml`, ADR-0050m) stages the managed runtime (`scripts/stage-windows-runtime`), `py-acq`, `acq.ps1`, `acq.cmd`, and the exact-hash validator `wheelhouse/` into `acq-windows-x64.zip`, emits `provenance.json` and `SHA256SUMS`, and runs an offline `install.ps1 -Source dist` smoke test on `windows-latest`. An archive built the same way (the pinned 3.14.10 embeddable ZIP, its SHA-256 checked) was also installed with `install.ps1 -Source <dir>` on a Windows 11 VM, under Windows PowerShell 5.1 and the user's own `RemoteSigned` policy, with the profile and acq state directories redirected. With `ACQ_IMPL` unset, `acq version` reported `"impl": "python"` and `acq doctor` reported `app-private runtime present (python.org-embedded)`. `acq version` still ran with only `System32` on `PATH`, and with the runtime moved away as well it failed closed with the message. The Windows CI job runs the staged layout through `acq.cmd` with `ACQ_IMPL` unset. Leftover: the runtime patch cadence is still a proposal in `py-acq/README.md`, with no owner. |
| 2. Known gaps closed | Met | The findings this gate names are fixed in the Python implementation: secrets are bound to their hosts on both backends (msb `--secret ENV@HOST`, including binding newly added secrets on stopped sandboxes before `msb start`; sbx custom secrets); the built-in kits are applied (`kit_msb.py`, `kit_sbx.py`); the persisted backend is honoured; and Bash-created state is read and imported (`legacy_bash.py`, `migration.py`, reported by `acq doctor`). The three parity gap issues are closed; remaining live hardware checks are tracked with the re-qualification checklist (Links). |
| 3. Sandbox-control parity | Open | No Tier-3 oracle assertion has been run live on a Windows backend for credential binding, network policy, the read-only trusted-config mount or kits. The read-only mount is not requested on Windows by either implementation (KNOWN_FAILURE_MODES §54). Needs live Tier-3 runs; tracked with the re-qualification checklist (Links). |
| 4. Command parity | Met, with accepted gaps | Every subcommand the Bash `acq help` lists is implemented in the Python CLI (ADR-0047m, correction and its 2026-11-10 update), including clone mode, port publishing, the update check, the first-run offer and the kit picker. `start` and `restart` run on msb and refuse on sbx, as in Bash. The gaps a 2026-11-10 capability audit found are now ported: extra workspace paths with `:ro`, `acq run ... -- AGENT_ARGS`, `--image` before the verb, backend and named-sandbox `acq doctor`, external-ref `kit apply`, kit `volumes` on msb, the msb memory/CPU, pull-policy, DNS, upstream-proxy-CA and workspace overrides, and `ACQ_DEBUG` tracing. Two accepted gaps remain, each with `ACQ_IMPL=bash` as the replacement: passing sbx-native (non-neutral) kits through unchanged, and `ACQ_ACTIVATE_PROJECT_ENV` (waiting on direnv in the substrate). On Windows the Bash replacement is subject to the Git Bash limits in KNOWN_FAILURE_MODES §89. |
| 5a. Windows CI job | Met | `.github/workflows/windows.yml` runs pytest on Windows, which includes the vector corpus (`py-acq/tests/test_vectors.py`) and `py-acq/tests/test_windows_launchers.py`. It smoke-tests both launchers with `ACQ_IMPL` unset, `python` and `bash`, and runs a staged managed runtime through `acq.cmd` with `ACQ_IMPL` unset. |
| 5b. Tier-3 `windows-x64` transcript | Open | Needs a live Tier-3 run from a gate-1 install with `ACQ_IMPL` unset. Tracked with the re-qualification checklist (Links). |
| 5c. Tier-3 surface | Open | `TIER3_SURFACE` in `qualification/matrix.py` does not list the launchers, `install.ps1` or `scripts/stage-windows-runtime`, and `TIER3_SURFACE_EXCLUSIONS` excludes `runtime.py` under ADR-0044m's rule for modules reached only through `doctor`. The surface applies to every cell, so adding Windows-only files would also expire the macOS and Linux cells. Changing that is a qualification decision of its own, tracked with the re-qualification checklist (Links). |
| 6. Documentation | Met | The README, `docs/howto/acq.md` (the Windows install and validation sections), `docs/CONCEPTS.md`, `py-acq/README.md` and ADR-0047m describe the managed runtime, the Windows default, `ACQ_IMPL=bash`, `ACQ_RUNTIME` and the `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` prerequisite. |

The Verification section is met in part:

- **Met:** the CI job's launcher cases. `py-acq/tests/test_windows_launchers.py`
  covers each bullet: the default runs `py-acq\runtime\python.exe -P -m acq_py`;
  `ACQ_IMPL=bash` reaches Git Bash; an unknown value exits 2; with no managed
  runtime, an absolute `ACQ_RUNTIME` is honoured and a relative one refused; a
  `python.exe` that fails the probe, the real App Execution Alias stub (where
  present) and relative `PATH` entries are skipped; and with nothing qualifying
  the launcher fails closed without starting Bash. On the Windows 11 VM these
  tests passed under Windows PowerShell 5.1 and PowerShell 7.4, and
  `test/bats/06-windows-install.bats` passed under Git Bash.
- **Met in part:** the install of a gate-1 archive with `acq version` and
  `acq doctor` (gate 1 above). The create/rm cycle on each Windows backend is
  still open; it needs live backends.
- **Open:** the re-recorded Tier-3 `windows-x64` ledger entry (gate 5b).

## Links

- ADR-0041m (v1 replaces Bash), ADR-0042m (runtime ownership), ADR-0047m
  (coexistence)
- Credential gaps (closed): mogul/agentic-coding-quickstart#107
- Kit, bootstrap and trusted-config gaps (closed): mogul/agentic-coding-quickstart#108
- State, migration and lifecycle gaps (closed): mogul/agentic-coding-quickstart#109
- Python reads the configure keys (`extra_kits`, `provider_kit`, `scope_github_token`, `default_agent`; closed): mogul/agentic-coding-quickstart#168
- Python clone-mode port (closes the gate-4 clone gap): mogul/agentic-coding-quickstart#216
- Release assets (closed): mogul/agentic-coding-quickstart#111
- Windows CI (closed): mogul/agentic-coding-quickstart#122
- Bash `create`/`rm` under Git Bash (closed): mogul/agentic-coding-quickstart#128
- Tier-3 re-qualification, including the `windows-x64` transcript (gate 5b), the
  Windows sandbox-control oracle assertions (gate 3) and the Tier-3 surface
  (gate 5c): mogul/agentic-coding-quickstart#60
- Offline-install completeness transcript, which needs a release:
  mogul/agentic-coding-quickstart#61
