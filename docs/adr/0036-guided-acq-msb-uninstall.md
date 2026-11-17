---
title: "Use a Shared Offline ACQ and MSB Uninstaller"
description: "Define guided removal scope, failure handling, and standalone macOS delivery."
status: proposed
tier: 2
date: 2026-11-17
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-3", "CM-5", "SI-17", "SA-11"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
---

# ADR-0036: Use a Shared Offline ACQ and MSB Uninstaller

## Context and Problem Statement

Users need to remove broken or partially removed installations without knowing
whether Homebrew, npm, or a managed clone installed ACQ. Deleting state first
loses the records needed to clean up forwarding processes, temporary Git
remotes, and Keychain credentials. MSB self-uninstall does not stop VMs or
remove Homebrew packages.

## Decision Drivers

- Preserve original projects and unrelated development tools.
- Warn about work stored only in sandboxes or disposable clones.
- Never claim success when cleanup or verification fails.
- Work without ACQ, network downloads, Python, or new dependencies.
- Restrict this flow to MSB users; never remove SBX.

## Considered Options

1. Document a sequence of shell commands.
2. Provide a shared Bash wizard through ACQ and a standalone Mac download.
3. Build a signed and notarized graphical Mac application.

## Decision Outcome

Use option 2. `acq uninstall` dispatches before normal backend resolution.
`scripts/build-uninstaller` packages that same implementation into a
self-contained `uninstall.command`, with a terminal pause after completion.
The release publishes the script, checksum, and provenance without additional
workflow permissions. A documented Bash fallback avoids requiring executable
download permissions or bypassing macOS security controls.

The generated download intentionally exceeds the 400-line source-file limit:
it concatenates two maintained modules (each below the limit) so recovery needs
neither a working installation nor runtime code downloads. It is not separately
edited; the builder and packaging tests keep it tied to those source modules.

Inventory and confirmation precede deletion. Managed helper processes and Git
remotes are handled while state still exists. Credentials are removed from the
OS store before deleting their index. Settings, caches, packages, and launchers
are removed only after sandbox cleanup succeeds. Missing or broken MSB with
remaining sandbox data blocks removal rather than guessing that no VM is running.

## Consequences

Installed SBX blocks removal of shared ACQ state. Historical ACQ SBX records
alone do not block a dry run: they are metadata, not proof that sandboxes remain.
When SBX is missing, destructive removal requires a separate human assertion
that no SBX sandboxes remain. `--yes` does not supply that assertion; the explicit
`--confirm-no-sbx-sandboxes` option does. SBX native storage and daemon remain
outside scope. Unknown inventory requires restoring SBX to check it, not guessing.

- A partially removed ACQ installation can be cleaned without reinstalling ACQ.
- The scope is local ACQ/MSB-owned components, not forensic erasure or remote
  credential revocation. Backups, manually copied checkouts, package-manager
  download caches, and original project folders remain untouched.
- Custom deletion roots must be user-owned, non-symlinked, and narrowly named;
  ambiguous layouts require manual review rather than broad recursive deletion.
- A Terminal wizard is not a signed GUI application. Opening the downloaded
  file and real Keychain/VM behavior require live macOS acceptance testing.
- Destructive phases have no automatic rollback; users must recover needed
  sandbox-only work before confirming removal.

## Verification

### Python migration integration

The Python command registers uninstall as an owned verb and dispatches before
state migration or backend resolution. POSIX release archives embed the generated
recovery script beside the Python package. The source checkout delegates through
`scripts/run-uninstaller`; neither entry point inherits relative PATH entries.
Windows removal remains unsupported and returns an explicit refusal.

The `.acq-v1-install` manifest authorizes individual top-level release entries,
including the private runtime and `acq-python` launcher. Unknown entries, empty
manifests, and custom roots fail closed. A remaining unowned file keeps its
ownership manifest across repeated runs. System Python is never removed.

Schema-versioned sandbox/provider/GitHub-scope records are validated by a local
isolated system Python parser before deletion; no runtime is installed or state migrated.
If no parser is available, removal blocks rather than guessing. The recovery
wizard can run without ACQ's runtime when a system parser is available, and
legacy state requires no parser. Tracking refs are removed with `--no-deref`,
preserving symbolic targets and local branches.

Offline regression tests cover cancellation, unsafe paths, command dispatch,
partial failure, installation discovery, and standalone packaging. Live Mac
acceptance must cover Homebrew and standalone installs, Keychain prompts,
running VMs, and downloaded-file opening before advertising a tested GUI flow.
