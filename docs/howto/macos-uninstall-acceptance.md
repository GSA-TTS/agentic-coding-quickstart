---
title: "Run the macOS uninstall acceptance workflow"
description: "Dispatch the hosted macOS acceptance run for the guided uninstaller and read its summary"
status: canonical
tier: 2
last_updated: "2026-11-19"
audience: "developers"
keywords: ["macos", "uninstall", "acceptance", "github actions", "keychain"]
related_files: ["../../.github/workflows/macos-uninstall-acceptance.yml", "../../scripts/test-uninstall-macos", "../adr/0048-macos-uninstall-acceptance-workflow.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# Run the macOS uninstall acceptance workflow

This workflow tests the guided uninstaller on GitHub-hosted macOS runners using
synthetic files and a temporary keychain. It does not touch anything of yours and
does not replace the manual checks on a disposable Mac account. See
[ADR-0048](../adr/0048-macos-uninstall-acceptance-workflow.md) for scope and limits.

## Run it

Pick the commit to test. The workflow file must be on the default branch, and the
tested commit must contain `scripts/build-uninstaller`.

```sh
gh workflow run macos-uninstall-acceptance.yml -f ref=<commit-sha>
```

Add `-f homebrew=true` to also install the real `GSA-TTS/tap/acq` formula and its
`microsandbox-acq` dependency on the runner, then remove them with the wizard.

Find the run with `gh run list --workflow macos-uninstall-acceptance.yml`, then open
it with `gh run view <run-id> --web`. Use a full commit SHA when you need the run to
fail if the checkout is any other commit.

## Read the result

The `macos-15` (Apple Silicon) runner has its own job summary. It starts with
the tested commit, the runner image, the macOS and bash versions, and the SHA-256 of
the built `uninstall.command`. A table follows, with one row per stage:

| Result | Meaning |
| --- | --- |
| PASS | The stage ran and every assertion held. |
| FAIL | A stage ran and an assertion failed; the detail names it. |
| BLOCKED | Not run because an earlier stage failed. |
| ABORTED | The script exited during the stage. |
| NOT-EXERCISED | Deliberately not run, for example Homebrew when the input is false or the formulae cannot be installed. Never a pass. |

The overall verdict is PASS only when every required stage passed. The summary ends
with the list of behaviors this workflow cannot check. The artifact
`macos-uninstall-acceptance-<runner>` holds `results.json`, the built uninstaller and
each wizard run's output (`logs/*.out`, plus `logs/*.err` command traces), kept for 14 days.

The last row, `cleanup`, covers putting the keychain search list and default keychain back,
deleting the temporary keychain and removing the working directory. Each is verified rather
than assumed. If any step fails or cannot be verified the row is FAIL and names the step, the
verdict is FAIL and the job fails, even when every other stage passed.

If a run is cancelled while a wizard is running, the helper that runs it stops the
wizard's whole process group before it exits (status 128 plus the signal number) and
notes `interrupted by SIG...` in that run's `logs/*.out` and on stderr. An interrupted run
is never recorded as a pass.

## Reproduce a failure

The harness refuses to run unless it is on a GitHub-hosted macOS runner, so it cannot
be run on your own Mac. Read the stage's log in the artifact, then follow the
"Maintainer verification" section of `docs/howto/uninstall.md` (added by the guided uninstaller change) on a
disposable account.
