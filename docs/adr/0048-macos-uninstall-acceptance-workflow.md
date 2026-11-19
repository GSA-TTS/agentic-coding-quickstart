---
title: "Run the guided uninstaller's macOS acceptance on GitHub-hosted runners"
description: "A dispatch-only workflow that exercises the guided uninstaller against synthetic state and a temporary keychain on hosted macOS, and what it cannot prove"
status: proposed
tier: 2
date: 2026-11-19
last_updated: "2026-11-19"
decision_makers: ["Bret Mogilefsky"]
category: development-process
nist_controls: ["SA-11", "SA-15", "CM-3", "CM-5", "AC-6", "SI-7"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
related_files: [".github/workflows/macos-uninstall-acceptance.yml", "scripts/test-uninstall-macos", "scripts/uninstall-acceptance-lib.sh", "scripts/uninstall-acceptance-helper.py", "test/bats/167-macos-uninstall-acceptance.bats", "docs/howto/macos-uninstall-acceptance.md", "docs/adr/0039-bash32-ci-shard-matrix-and-interpreter-handoff.md"]
---

# ADR-0048: Run the guided uninstaller's macOS acceptance on GitHub-hosted runners

## Context and Problem Statement

The guided ACQ and MSB uninstaller removes files, Homebrew packages and macOS
Keychain items. Its offline suite uses stubs, so it cannot show that the real
`security`, BSD userland, `/bin/bash` 3.2.57 and Homebrew behave as the stubs
assume. Earlier manual runs found failures that no stub reproduced: `rm` refusing
read-only cache generations, and Homebrew's `No such keg` when uninstalling a
dependency that the first uninstall had already removed. Manual acceptance on a
disposable Mac account is still required before release, but a repeatable hosted
run can catch most of these regressions on every candidate commit.

The uninstaller may not be on `main` when this is needed, so the check must be
able to test an arbitrary ref without that ref containing the workflow.

This adds a CI pipeline, so it is recorded here.

## Decision Drivers

- Real macOS tooling, not stubs, for the paths that touch the filesystem and Keychain.
- Safe by construction: a destructive harness must not be runnable by accident.
- Testable against a branch or commit that does not contain the workflow.
- Honest reporting: a stage that did not run must never read as a pass.
- No new third-party action, no secrets, no write permission.

## Considered Options

1. Add the stages to the existing PR workflows (`pull_request` on macOS).
2. A manual `workflow_dispatch` workflow that tests a chosen ref.
3. Rely only on manual acceptance on a developer's disposable account.

## Decision Outcome

Chosen: **option 2**.

- `.github/workflows/macos-uninstall-acceptance.yml` is `workflow_dispatch` only, with
  `permissions: {}` at the top and `contents: read` on its single job. It runs on
  `macos-15` (Apple Silicon) and `macos-15-intel`, `fail-fast: false`, 30-minute limit.
- Two checkouts, both without persisted credentials and with actions pinned by SHA:
  `harness` (the ref the workflow was dispatched on, supplying
  `scripts/test-uninstall-macos`) and `subject` (the required `ref` input). The
  harness and the code under test therefore do not need to be the same commit.
- The `ref` input reaches shell only through `env:`, is validated against a narrow
  character set before use, and the run fails closed if the subject has no
  `scripts/build-uninstaller`. A 40-hex ref is also passed as `--expect-sha`.
- `scripts/test-uninstall-macos` refuses to run unless `CI=true`,
  `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`, the host is macOS and the
  user is not root. It also requires the subject to be under `GITHUB_WORKSPACE` and
  its output under `RUNNER_TEMP`.
- Everything it destroys is synthetic and disposable: a throwaway `HOME` under
  `RUNNER_TEMP`, and a temporary keychain that it creates, unlocks, makes the only
  entry of the user search list, and deletes on exit. The previous search list and
  default keychain are restored. The wizard runs under `env -i` with a minimal `PATH`,
  so runner tokens and the real `HOME` are not visible to it.
- No privilege escalation: refusing stand-ins for `sudo` and `doas` lead the wizard's
  `PATH`, and its command trace (`bash -x`) is scanned for them in command position.
  A missing trace fails the check rather than passing it vacuously.
- Stages: build; seed; `--dry-run`; cancel (answered on a pseudo-terminal);
  `--yes` removal including a read-only nested cache tree that first proves plain `rm`
  fails on it; a repeat run; the SBX-record refusal and both confirmation routes; and an
  optional Homebrew stage. Each asserts what was removed, that the Keychain item is gone
  (`security find-generic-password` exits 44), that an original project (including a
  symlink into it) and unrelated files are byte-identical. Every wizard run, whichever
  route, is also checked for secret-like placeholder text in both captured streams.
- The helper that runs the wizard gives it its own session and process group, applies the
  timeout to the whole run (including waiting for exit after the terminal closes), and ends
  anything left in the group on every exit path, so cleanup never races a surviving child.
- If the helper itself is interrupted (SIGTERM, SIGHUP or SIGINT, for example a cancelled job),
  it records the first signal, stops the command's group the same way (SIGTERM, a short grace,
  SIGKILL) and closes the pseudo-terminal, then notes the interruption in the captured output and
  on stderr and exits 128 plus the signal number. The harness therefore sees a nonzero status and
  fails the stage, and the command cannot write after the helper has gone. A later signal during
  that cleanup is ignored so cleanup is never cut short.
- Cleanup is part of the result, not best-effort-and-forget. Every cleanup step always runs
  (restore the search list and default keychain in each environment that changed them, delete
  the temporary keychain, remove the work directory), but none is trusted on its exit code:
  the search list and default keychain are read back and compared with the saved originals,
  and the keychain file and work directory are checked to be gone. Any failure is recorded as
  a `cleanup` stage with status FAIL naming the step; `cleanup` is a required stage, so the
  verdict is FAIL and the script exits nonzero even when every other stage passed.
- Reporting: `results.tsv`, `results.json` and a Markdown step summary list the tested
  commit, runner image, macOS and bash versions, and each stage as PASS, FAIL, BLOCKED
  (an earlier stage failed), ABORTED, or NOT-EXERCISED. The verdict is PASS only when
  every required stage is PASS. NOT-EXERCISED is never counted as a pass.

### What it cannot prove

Real MSB sandboxes (GitHub documents nested virtualization as unsupported on
arm64 macOS runners and is silent for Intel, so none is created); Keychain denial and retry (needs an interactive
prompt); a forwarding process surviving until a reboot; temporary clone remote cleanup;
npm removal; refusal when SBX is installed; and opening a browser-downloaded
`uninstall.command` (Gatekeeper, quarantine). Those remain manual acceptance, which
this workflow supplements and does not replace. The Homebrew stage is skipped, and
reported as NOT-EXERCISED, whenever Homebrew or the tap formulae cannot be installed
on the runner. The temporary keychain is not the login keychain, so its unlock and
partition-list behavior can differ from a user's.

## Consequences

Good:

- A regression in removal ordering, read-only tree handling, Keychain deletion or
  project preservation fails a named stage with logs, before a human runs it.
- The same workflow validates a pull request's exact head without changing that pull
  request.

Bad / to watch:

- The harness and its helper were developed and rehearsed on Linux with a stand-in for
  `security`; its first real macOS run is the first evidence for macOS-specific
  behavior. Expect to fix assumptions on that run.
- Hosted macOS minutes are billed at a higher rate; the workflow is manual for that
  reason. Enabling it on `pull_request` would need a new decision.
- The Homebrew stage installs real formulae from `GSA-TTS/tap`; a tap or formula change
  can fail it independent of the uninstaller.
- A `workflow_dispatch` workflow must exist on the default branch before the Actions UI
  or `gh workflow run` can dispatch it, so it needs a push by someone with the
  `workflow` scope.

Compliance:

- No new action, no secret, read-only token, credentials not persisted (SR-3, AC-6,
  CM-5). Expression injection is avoided by passing inputs through `env:`, pinned by
  `test/bats/167-macos-uninstall-acceptance.bats`, which also checks each of those
  properties against mutated copies of the workflow (SA-11).

## Links

- [ADR-0039](0039-bash32-ci-shard-matrix-and-interpreter-handoff.md): CI conventions
  this workflow follows, and the bash 3.2 gate that lists these files as inputs.
- GSA-TTS/agentic-coding-quickstart#710: tracks manual host acceptance of the guided
  uninstaller, which this workflow supports but does not close.
- GSA-TTS/agentic-coding-quickstart#712: the guided uninstaller change this validates.
- [How to run it](../howto/macos-uninstall-acceptance.md)
