---
title: "Python Migration Uninstall Compatibility"
description: "Integration changes, adversarial review, and draft acceptance gates."
status: draft
tier: 2
last_updated: 2026-11-17
related_files: ["../howto/uninstall.md", "../adr/0036-guided-acq-msb-uninstall.md", "../../py-acq/tests/test_uninstall.py"]
---

# Python Migration Uninstall Compatibility

This companion integrates the shared guided remover into the Python migration.
The legacy implementation's transcript is retained separately; it does not
constitute evidence for this branch's native-platform behavior.

## Changed contracts

- Python command catalogue, parser, and early dispatch recognize uninstall.
- Both source and release entry points use the same shared Bash engine.
- Release archives package recovery beside Python source; the shared release
  asset is enumerated, checksummed, attested, and uploaded by the new pipeline.
- Ownership manifest controls removal of runtime/source/launchers, preserving
  unrelated files and ownership evidence on retry.
- Legacy and Python clone/forwarding layouts remain compatible. Git tracking-ref
  cleanup preserves local branches and symbolic-ref targets.
- Existing local isolated Python parses schema-versioned state before deletion;
  unknown schemas and unavailable parsers block instead of triggering migration.
- Installed SBX blocks the MSB-only wizard. Historical records permit preview;
  removal requires a separate assertion that no SBX sandboxes remain.

## Adversarial review

First integration review found ownership/retry, relative PATH, persisted SBX,
tracking-ref, preflight, schema-family, source-path, and packaging issues.
The corresponding guards and regression tests were added. Known errors are
checked before confirmation wherever read-only inspection is possible.
OS credential denial can still happen after stopping sandboxes and is reported
as incomplete removal; credentials and metadata are not silently discarded.

Follow-up adversarial review found four blockers: orphaned transaction evidence
could select legacy recursive removal, pending children escaped preflight, two
JSON families were omitted, and a broken first parser prevented fallback. All
were fixed with regressions. Re-review reported no remaining blockers. Exhausted
ownership receipts intentionally remain; they prevent later user files from
being reclaimed after interruption or retry.

## Verification

Observed local checks (OpenCode AI agent, Linux aarch64, unprivileged user):

| Check | Result |
| --- | --- |
| `scripts/test-acq-bash32 test/bats/07-uninstall.bats test/bats/08-uninstall-transactions.bats` with verified 3.2.57 | PASS: 50 tests after follow-up review fixes and split |
| Bash 3.2 syntax preflight on recovery modules/entry points | PASS |
| Focused Python uninstall/install/release/runtime tests | Earlier PASS: 57 tests; current uninstall/install rerun PASS: 36 tests |
| Ruff on Python source; mypy and Bandit on uninstall handler | PASS |
| ShellCheck on changed shell modules/installer/tests | PASS |
| `npm run lint:md` and `git diff --check` | PASS |
| Wheel and sdist build with pinned setuptools | PASS after correcting sdist path resolution |
| Installed wheel with `PYTHONPATH` unset and `-I` | Packaged recovery resolves and help executes |
| Wheel recovery vs standalone builder bytes | Identical |

Review loops additionally repaired interruption ownership for absent entries,
validated bookkeeping sentinel types, rejected reinstall during pending removal,
and changed wheel/sdist generation to platform-neutral build output. An executable
offline installer regression verifies refusal preserves the manifest and launcher.
Generated source artifacts never override the checkout's current recovery code.

The first broad Python and Bash attempts exceeded 15-minute limits. The broad
Python attempt showed an updated command-catalog assertion needing the new
handler module; that consumer was corrected. Qualification fixture commits
then failed because `/etc/gitconfig` requires SSH signing and isolated HOME
does not hold the developer's signing identity. Test-only command-scope
`commit.gpgsign=false` and `tag.gpgsign=false` allowed all 267 qualification
tests to pass; no global settings or production signing requirements changed.
A terminal-restoration assertion passed isolated reruns on both baseline and
integration. Full suites are rerun with longer limits; no timeout is a pass.

The uninstall safety matrix is split into command/backend tests and installation
transaction tests, each below 400 lines, with one shared isolated fixture. Final
sub-agent review confirmed no dropped tests and automatic runner/shard discovery.
The generated standalone artifact exceeds 400 lines by concatenation, not separate
maintenance. Source modules remain bounded.

A broad Python rerun stopped at a provider-key test that inherited the session's
credential environment. The exact test passes with `USAI_API_KEY` and
`GITHUB_TOKEN` unset; neither value was inspected or printed. A full sanitized
rerun remains pending; this targeted pass is not a full-suite pass.

Focused Python command tests, isolated Bash cleanup tests, Ruff, mypy, Bandit,
ShellCheck, Markdown and Bash 3.2 syntax checks are run before submission.
Full Python/Bash suites are recorded at their observed revisions, with later
targeted re-verification identified explicitly. No mock pass certifies live
Keychain, MSB shutdown, download opening, or macOS utilities.

Native Mac acceptance remains blocked in this Linux sandbox. Use the disposable
account procedure in the removal guide, including a Python installation with
unowned files, a missing runtime, migrated records, and repeated removal.
