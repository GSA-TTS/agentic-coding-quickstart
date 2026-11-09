---
title: "Windows defaults to the Python implementation with acq's managed runtime"
status: proposed
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
   Today the Python CLI lacks `start` and `restart`. (`secret set-custom` is not
   a gap: Bash refuses it with guidance, and Python rejects it as an unknown
   subcommand.)
   `acq configure` is implemented, with two accepted gaps:
   - **The first-run offer.** Bash offers to run `acq configure` the first time
     `acq create`/`run` finds no `config.yaml`. Python does not prompt; the
     replacement is running `acq configure` once by hand.
   - **The create-time kit picker.** Bash lets a single `acq create`/`run` change
     the opt-in kits for that sandbox. Python has no picker. It does not apply
     extra kits at all yet (see "Python reads the configure keys" under Links), so
     until it does the replacement is the Bash acq (`ACQ_IMPL=bash`), whose picker
     and `ACQ_EXTRA_KITS` still work.

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

## Links

- ADR-0041m (v1 replaces Bash), ADR-0042m (runtime ownership), ADR-0047m
  (coexistence)
- Credential gaps: mogul/agentic-coding-quickstart#107
- Kit, bootstrap and trusted-config gaps: mogul/agentic-coding-quickstart#108
- State, migration and lifecycle gaps: mogul/agentic-coding-quickstart#109
- Python reads the configure keys (`extra_kits`, `provider_kit`, `scope_github_token`): mogul/agentic-coding-quickstart#168
- Release assets: mogul/agentic-coding-quickstart#111
- Windows CI: mogul/agentic-coding-quickstart#122
- Bash `create`/`rm` under Git Bash: mogul/agentic-coding-quickstart#128
