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
`acq`" means running it under Git Bash (MSYS), and a Windows 11 review showed that
this path depends on Unix tools and conventions Git Bash does not provide:

- MSYS `ps` has no `-o`. The kit-fetch guardian and the provider-input lock
  guardian both rely on it, so kit fetches and every provision/terminate failed
  silently until they were taught to read MSYS `/proc`.
- The provider-input helpers run `python3` heredocs that use `os.O_NOFOLLOW` and
  `os.O_DIRECTORY`. Git for Windows has no `python3`, and Windows CPython has
  neither flag, so a Bash `create`, `run` or `rm` still cannot complete there.
- Native Windows programs that the Bash path starts inherit Windows' executable
  search rules, which differ from the POSIX rules the Bash code was written for.

Windows also ships no Python. Its `python.exe` App Execution Alias only opens the
Microsoft Store. ADR-0042m already makes acq own an app-private runtime per
platform (python.org's embedded distribution on Windows), and the Windows release
archive now carries that runtime and acq's source. So the Python implementation
can run natively on Windows with no Git Bash and no system interpreter.

Each Git Bash incompatibility found so far needed its own fix and its own test
harness, and there is no Windows CI to catch the next one. The question is
whether Windows should keep defaulting to the implementation that needs a Unix
emulation layer.

## Decision

On Windows, `acq.cmd` and `acq.ps1` treat an unset `ACQ_IMPL` as `python`, and
run the managed runtime at `py-acq\runtime\python.exe`. `ACQ_IMPL=bash` stays
available as an explicit opt-in for the transition. On macOS and Linux the
ADR-0047m default (Bash) is unchanged.

The default flips only when every gate below holds. Until then this ADR stays
`proposed`, and the launchers keep the ADR-0047m behaviour.

1. **Runtime:** the Windows release archive ships the managed runtime and source,
   and `install.ps1` installs it from a release asset set.
2. **Credentials:** the Python msb adapter binds secrets to their hosts. Today the
   Python implementation has no msb secret path.
3. **Kits and egress:** the built-in kits are applied, and msb sandboxes get the
   deny-by-default egress policy.
4. **Migration:** existing Windows users' Bash-created state (sandboxes, secrets,
   provenance) is read or migrated by the Python implementation, so switching the
   default does not orphan their sandboxes.
5. **Proof:** a Windows CI job runs the pytest and vector suites and smoke-tests
   both launchers, and the Tier-3 `windows-x64` cell is re-recorded with an oracle
   that exercises secrets, kits and the read-only config mount.

## Consequences

- Windows users no longer need Git Bash for acq. The class of bugs that come from
  running Bash code under MSYS stops being reachable by default.
- Windows becomes the first platform where the Python implementation is the
  default. This stages the cutover described in `py-acq/README.md` (ADR-0041m: v1
  replaces Bash), starting where the Bash path is weakest, rather than a flag day
  across all platforms.
- Bash-path fixes that only matter under Git Bash become lower priority once the
  default flips, but they still apply while `ACQ_IMPL=bash` is supported.
- The managed runtime is now on Windows users' critical path, so its patch cadence
  in ADR-0042m (quarterly re-verify, out-of-band for critical/high CVEs) has to be
  followed. The pin must stay on a CPython line that still publishes Windows
  embeddable binaries; once a line goes security-only, python.org stops
  publishing them.
- `acq version` already reports `"impl"`, so bug reports show which
  implementation ran.

## Verification

When the gates are met, the change to the launchers is covered by:

- a Windows CI job showing that an unset `ACQ_IMPL` runs `py-acq\runtime\python.exe
  -m acq_py`, that `ACQ_IMPL=bash` still reaches Git Bash, and that an unknown
  value exits 2;
- an install from release assets with `install.ps1`, followed by `acq version`,
  `acq doctor` and a create/rm cycle on msb;
- the re-recorded Tier-3 `windows-x64` ledger entry.

## Links

- ADR-0041m (v1 replaces Bash), ADR-0042m (runtime ownership), ADR-0047m (coexistence)
- Tracking: mogul/agentic-coding-quickstart#107, #108, #109, #111, #122, #128
