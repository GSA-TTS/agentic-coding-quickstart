---
title: "Guided Uninstaller Verification Transcript"
description: "AI-assisted review findings, local checks, and live macOS acceptance gate."
status: draft
tier: 2
last_updated: 2026-11-17
related_files: ["../howto/uninstall.md", "../adr/0042-guided-acq-msb-uninstall.md", "../../test/bats/07-uninstall.bats"]
---

# Guided Uninstaller Verification Transcript

AI-assisted implementation and review: OpenCode. Human host acceptance and
review remain required before marking the pull request ready. No real uninstall,
VM shutdown, or host credential deletion was executed by the agent.

## Adversarial Review

Human review follow-up requires shared MSB version gating before catalog access,
complete fetch/push destination validation before removing a temporary remote,
full pre-command global-option handling, deduplicated retry-safe Linux credential
cleanup, actual nonroot fixture identity, and terminal-backed help-exit coverage.
Native destructive acceptance remains a separate gate; isolated passes do not
certify actual credential-store, package-manager, or VM removal.

Follow-up verification: 68 isolated uninstall/review regressions pass under the
default Bash and verified Bash 3.2.57, including a PTY-backed immediate help exit,
combined globals, blocked versions, customized fetch/push URLs, actual nonroot
directory ownership, and mixed fallback/keyring credential migration. ShellCheck
and module secrets scanning pass. Adversarial review identified the mixed-store
case and it was corrected before submission. Linux no-match verification consumes
`secret-tool search` output without logging or retaining it; the tool can emit
secret values, so suppression is mandatory. Native removal acceptance is pending.

Repeated read-only agent reviews identified and resolved:

- Custom roots named `acq` could authorize project deletion: nondefault overrides
  now stop before cleanup; symlink/traversal roots are rejected.
- Clone origins could traverse symlinked ancestors: validate original config
  paths and safely resolve linked Git worktree configuration.
- Stored PIDs lacked start identity: never signal a process based on legacy PID
  records; preserve records and require closing sessions/restarting instead.
- Credential and PID final lines could be skipped: process unterminated records.
- Linux file fallback metadata was mistaken for a keyring-only record: distinguish
  fallback files from unresolved OS-store indexes/metadata.
- Unknown launchers returned success: fail closed and preserve them.
- Backend flags bypassed early dispatch: explicitly reject globals for uninstall.
- Empty arrays broke Bash 3.2 nounset: use guarded array expansion.
- Shell cleanup matched the wrong PATH spelling: match the installer's expanded
  path, retain shared PATH entries, and test empty-bin removal.
- Mac fixtures used symlinked temporary paths: canonicalize fixture HOME.
- Offline fixtures could reach real Keychain/Secret Service: isolate discovery
  and execution explicitly; command-contract tests use only fixture functions.
- System package managers and backends could escape fixture HOME: limit offline
  discovery to explicitly supplied fixture executables.
- Release checksum assertion omitted the new asset: update the downstream test
  and assert build, checksum, attestation, and upload wiring.

Final credential-isolation review reported no remaining actionable findings.

## Local Commands and Observed Results

Host follow-up: the original 29 isolated tests passed on macOS after redirecting
stdin. Test 4 inherited Terminal stdin and waited at a captured prompt; the test
now redirects its own stdin. A successful empty SBX inventory followed by SBX
package removal left historical ACQ provenance that incorrectly blocked preview.
Preview now identifies those records; deletion requires a separate sandbox-absence
assertion. A sub-agent adversarial review reported no actionable blockers.

Follow-up verification passed: 32 focused tests with disconnected stdin and again
under a real pseudo-terminal (`script -q -e -c 'bash scripts/test-acq-bats
test/bats/07-uninstall.bats'`), ShellCheck, Markdown lint, and Gitleaks on the
changed cleanup module. Live macOS destructive acceptance remains pending.

| Command | Observed result |
| --- | --- |
| `ACQ_BATS_JOBS=2 bash scripts/test-acq-bats` | PASS: 882 tests reported OK, zero failures, 8 environment-dependent skips; final fixture-isolation addition separately reverified below |
| `bash scripts/test-acq-bats test/bats/07-uninstall.bats` | PASS: 29 uninstall tests |
| `bash scripts/test-acq-bats test/bats/06-windows-install.bats test/bats/07-uninstall.bats` | PASS: 52 tests, 3 expected skips because `pwsh` is absent |
| `python3 -B scripts/test-probe-msb-startup.py` | PASS: 25 tests |
| `shellcheck --severity=warning acq acq.backends/uninstall-files.sh acq.backends/uninstall.sh scripts/build-uninstaller test/bats/06-windows-install.bats test/bats/07-uninstall.bats` | PASS with checksum-verified ShellCheck v0.11.0 |
| `bash -n acq acq.backends/uninstall.sh acq.backends/uninstall-files.sh scripts/build-uninstaller` | PASS |
| `npm run lint:md` | PASS |
| Parse release YAML and Markdown frontmatter with lockfile-installed `js-yaml`; parse package JSON | PASS |
| `bash scripts/build-uninstaller /tmp/opencode/uninstall.command` | PASS; executable, self-contained script produced |
| `shellcheck --severity=warning /tmp/opencode/uninstall.command` | PASS |
| `npm pack --dry-run --ignore-scripts --json` | PASS; both cleanup modules and builder included |
| `gitleaks dir --redact --no-banner` on PR files | PASS: no leaks with repository-pinned v8.30.1 |
| `git diff --check` | PASS |

The first full Bats run exceeded a 240-second timeout. A longer run completed
with one stale release-checksum assertion; that assertion was updated to verify
the new artifact rather than bypassing validation. A full rerun is required
after that correction. That rerun passed with zero failures. Its eight skips
were three unavailable PowerShell checks, three unavailable real-SBX grammar
checks, and two pinned-Patterns checks requiring the CI-provided checkout.
The final test-isolation change and additional regression were then verified
with the 29-test uninstall suite and 52-test combined suite, plus full batched
ShellCheck. No production behavior changed after the passing full run.

The repository-wide Gitleaks directory scan reported three existing false
positives: the public Bash signing fingerprint, a literal `PLACEHOLDER` fixture
authorization header, and the live verifier's public-key variable. No finding
was secret material; the PR-scoped scan found none. Scanner rules were not changed.

Installing the existing Markdown lockfile reported a Node engine warning:
`ini` requests Node 22.22.2+, while the sandbox has 22.22.1. Markdown lint
executed successfully. No dependency versions or lockfiles were modified.

## Live Acceptance: BLOCKED in Sandbox

Real macOS Bash 3.2, Homebrew installation removal, Keychain access prompts,
VM shutdown, and browser-downloaded `.command` opening cannot be validated in
this Linux sandbox. Follow the disposable-account procedure in
[the removal guide](../howto/uninstall.md). Record actual output before marking
the draft pull request ready. Offline passes are not evidence of live success.
