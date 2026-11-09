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

ADR-0047m keeps the Bash `acq` as the default on every platform and selects the
Python implementation only when `ACQ_IMPL=python` is set. On Windows, "the Bash
`acq`" means running it under Git Bash (MSYS). A Windows 11 review found that this
path depends on Unix tools Git Bash does not provide:

- MSYS `ps` has no `-o`. The kit-fetch guardian and the provider-input lock
  guardian both rely on it, so on fork main every kit fetch and every
  provision/terminate fails silently under Git Bash. A pending fix teaches both to
  read MSYS `/proc` instead.
- The provider-input helpers run `python3` heredocs that use `os.O_NOFOLLOW` and
  `os.O_DIRECTORY`. Git for Windows has no `python3`, and Windows CPython has
  neither flag, so even with that fix a Bash `create`, `run` or `rm` cannot
  complete on Windows (mogul/agentic-coding-quickstart#128).

Each incompatibility so far needed its own fix and its own test harness, and there
is no Windows CI to catch the next one (mogul/agentic-coding-quickstart#122).

Windows ships no Python. Its `python.exe` App Execution Alias, which is on the
user `PATH` by default, only prints a hint to install Python from the Microsoft
Store and exits 9009. ADR-0042m makes acq own an app-private runtime on each
platform (python.org's embedded distribution on Windows). A pending release
change stages that runtime and acq's source into the Windows archive, so an
installed acq can run the Python implementation natively, with no Git Bash and
no system interpreter.

The question is whether Windows should keep defaulting to the implementation
that needs a Unix emulation layer.

## Decision

On Windows, `acq.cmd` and `acq.ps1` treat an unset `ACQ_IMPL` as `python`.
`ACQ_IMPL=bash` stays available as an explicit opt-in during the transition. On
macOS and Linux, and when the Bash `acq` script is run directly from a Git Bash
prompt, the ADR-0047m default (Bash) is unchanged.

With `ACQ_IMPL` unset or `python`, the launchers use the managed runtime at
`py-acq\runtime\python.exe`. Without one, as in a git checkout, they use a Python
3.12+ found only in absolute `PATH` entries, never the WindowsApps alias. If no
such Python exists, they **fail closed**, with a message that names both
remedies (install from a release, or set `ACQ_IMPL=bash`). They never silently
fall back to Bash.

The default flips only when every gate below holds. Until then this ADR stays
`proposed`, and the launchers keep the ADR-0047m behaviour.

1. **Runtime:** the Windows release archive ships the managed runtime and source,
   and `install.ps1` installs it from a published release asset set
   (mogul/agentic-coding-quickstart#111). The runtime's patch cadence, which
   ADR-0042m leaves to a separate decision and `py-acq/README.md` marks as a
   pending proposal, is settled and owned.
2. **Credentials, on both backends** (mogul/agentic-coding-quickstart#107):
   - msb binds secrets to their hosts;
   - sbx `secret set -g usai` binds the key to the USAi host, instead of silently
     storing an unbound service secret;
   - key rotation works;
   - `github-scope` actually downscopes the token it records as scoped.
3. **Kits, egress and trusted config** (mogul/agentic-coding-quickstart#108):
   - the built-in kits are applied;
   - the sbx bootstrap (`acq run opencode .`) is accepted;
   - the read-only trusted config mount is established;
   - msb sandboxes get the deny-by-default egress policy.
4. **State and lifecycle** (mogul/agentic-coding-quickstart#109):
   - Bash-created state (sandboxes, secrets, provenance) is read or migrated, so
     switching the default doesn't orphan existing sandboxes;
   - `rm` removes the kit-applied record;
   - config migration is crash-safe;
   - lifecycle commands are serialized by a lock.
5. **Command parity:** every command the Bash `acq` accepts on Windows is
   implemented, or listed here as an accepted gap with its replacement. Today the
   Python CLI lacks `configure`, `start`, `restart` and `secret set-custom`.
6. **Proof:**
   - a Windows CI job runs the pytest and vector suites and smoke-tests both
     launchers (mogul/agentic-coding-quickstart#122);
   - the Tier-3 `windows-x64` transcript is recorded from an `install.ps1`
     install with `ACQ_IMPL` unset. It shows `"impl": "python"` from
     `py-acq\runtime\python.exe`, and an oracle that exercises secrets, kits and
     the read-only config mount;
   - the Tier-3 surface includes the launchers, `install.ps1`,
     `scripts/stage-windows-runtime` and `py-acq/src/acq_py/runtime.py`, so a
     change to that path makes the ledger stale.
7. **Documentation:** the Windows setup docs and README describe the managed
   runtime, the new default, and `ACQ_IMPL=bash`.

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
- The default path runs an unsigned `python.exe` and native `.pyd` modules from a
  user-writable directory (`%LOCALAPPDATA%`). As ADR-0042m notes, AppLocker or
  WDAC policies can block that, so managed fleets may need an allow rule or an
  IT-approved base runtime.
- `acq version` already reports `"impl"`, so bug reports show which
  implementation ran.

## Verification

When the gates are met, the launcher change is covered by:

- **A Windows CI job showing that:**
  - an unset `ACQ_IMPL` runs `py-acq\runtime\python.exe -m acq_py`;
  - `ACQ_IMPL=bash` still reaches Git Bash;
  - a checkout with no runtime and no Python fails closed with the message;
  - an unknown value exits 2.
- **An install** from release assets with `install.ps1`, followed by
  `acq version`, `acq doctor` and a create/rm cycle on each Windows backend.
- **The re-recorded Tier-3 `windows-x64` ledger entry** described in gate 6.

## Links

- ADR-0041m (v1 replaces Bash), ADR-0042m (runtime ownership), ADR-0047m
  (coexistence)
- Tracking: mogul/agentic-coding-quickstart#107,
  mogul/agentic-coding-quickstart#108, mogul/agentic-coding-quickstart#109,
  mogul/agentic-coding-quickstart#111, mogul/agentic-coding-quickstart#122,
  mogul/agentic-coding-quickstart#128
