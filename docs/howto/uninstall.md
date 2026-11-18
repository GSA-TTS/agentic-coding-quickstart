---
title: "Remove ACQ and Microsandbox"
description: "Guided local removal, standalone Mac recovery, and verification."
status: canonical
tier: 2
last_updated: 2026-11-17
related_files: ["../../acq", "../../acq.backends/uninstall.sh", "../adr/0036-guided-acq-msb-uninstall.md"]
---

# Remove ACQ and Microsandbox

Use this guide to leave ACQ behind or start again with a clean installation.
The guided uninstaller removes **ACQ and all local Microsandbox (MSB) data**.
It does not remove SBX.

**Before continuing:** quit coding-agent sessions and recover any work you need
from sandboxes or temporary project clones. Removal permanently deletes that
work. Your original project folders and unrelated tools are preserved.

## If ACQ still works

Open Terminal and preview removal:

```sh
acq uninstall --dry-run
```

Then start the wizard:

```sh
acq uninstall
```

It lists the locations and packages found and asks you to confirm. Pressing
Return without answering cancels. Do not run it with `sudo`.

Before listing sandboxes, the wizard checks MSB's shared catalog-version policy.
Blocked migration releases, prereleases, and unknown builds stop even a preview
before opening the catalog. Restore a supported final MSB version before retrying.
Standalone `--help` exits immediately; other interactive results stay visible
until you press Return.

For an unattended removal, `acq uninstall --yes` skips the confirmation, not
safety checks. Only use it after reviewing the preview.

## If ACQ is broken or already removed (Mac)

1. Download **uninstall.command** from the
   [ACQ release assets](https://github.com/GSA-TTS/agentic-coding-quickstart/releases/latest).
   This asset is available starting with the release that introduces the wizard.
2. Save it in your Downloads folder. It contains the cleanup code itself; it
   does not reinstall ACQ or download code when opened.
3. Open the file. If macOS allows it to launch, Terminal opens with the wizard.
   Downloaded scripts may lack executable permission; double-click opening is
   not guaranteed. Do not disable Gatekeeper or remove quarantine protection.
4. If the file will not open, use Terminal instead. Paste this preview command:

   ```sh
   /bin/bash "$HOME/Downloads/uninstall.command" --dry-run
   ```

   Review the preview, then run:

   ```sh
   /bin/bash "$HOME/Downloads/uninstall.command"
   ```

5. Read the warning about sandbox-only work, then type `y` and press Return to
   confirm. macOS may request Keychain access to remove saved ACQ credentials.
6. Leave Terminal open until the result appears. The standalone wizard waits
   for Return before exiting so its results stay visible.

The download is a shell script, not a signed/notarized Mac application. You may
inspect it before running. Release `SHA256SUMS` includes its checksum.

## What is removed

- Installed ACQ packages found through Homebrew and the current npm global prefix.
- ACQ's managed clone and launcher under `~/.local/share/acq` and `~/.local/bin`.
- ACQ settings, state, and caches under `~/.config/acq`, `~/.local/state/acq`,
  and `~/.cache/acq`, including its offline validator runtime.
- All MSB sandboxes, volumes, images, credentials, and files under
  `~/.microsandbox`, plus recognized MSB Homebrew packages and command links.
- Saved ACQ credentials in macOS Keychain, including entries whose on-disk
  index was already removed. No credential values are displayed.
- Temporary `sandbox-NAME` Git remotes whose URLs still match ACQ's recorded
  clone locations. Changed or ambiguous remotes block cleanup for manual review.

Custom locations are detected but **not recursively deleted**. A custom path
could be an original project rather than disposable state, so the wizard stops
before removal and names the setting requiring manual review.

## If removal is incomplete

The wizard reports failure instead of claiming that everything is gone. It
preserves remaining cleanup records where possible. Rerunning skips components
already removed; removal is not transactional and does not restore deleted work.

- **MSB cannot list sandboxes:** restore a compatible MSB version so its catalog
  can be opened. The wizard will not delete sandbox data when it cannot establish
  which VMs need stopping.
- **A sandbox will not stop:** stop it manually, then retry. The wizard waits
  up to 30 seconds and never silently escalates to force-killing a VM.
- **A recorded forwarding process remains:** close sessions or restart the Mac,
  then retry. Legacy records lack process-start identity, so the wizard never
  kills a process based only on a stored PID.
- **Keychain access denied:** unlock your login keychain and allow the requested
  access, then retry.
- **Another installation remains:** the result names the command still found.
  Multiple Homebrew prefixes, npm installations, manually copied launchers, or
  custom install directories require reviewing that additional copy.

## What is intentionally kept

Original projects, Homebrew, npm, Git, shared PATH entries, manually cloned
checkouts, shell history, backups, and package-manager download caches are kept.
Deleting a stored credential does not revoke the token at its issuer. This is
local component removal, not forensic secure erasure.

Installer-marked MSB shell blocks are removed. ACQ's exact installer-added PATH
line is removed only when its bin directory has no remaining tools; user-added
PATH lines are kept. If SBX is still installed, this MSB-only wizard stops and
names its executable. Check `sbx ls` before removing SBX; do not remove shared
ACQ state while SBX sandboxes still need it. This wizard does not remove SBX's
native storage or daemon.

After SBX is uninstalled, historical ACQ records may remain in
`~/.local/state/acq/provenance/sbx` or `~/.local/state/acq/sbx`. These records are
not sandbox disks. The preview identifies them without blocking, but removal
requires a separate confirmation that no SBX sandboxes remain. If you already
verified an empty SBX inventory before uninstalling it, answer that confirmation
in the wizard. For unattended use, `--confirm-no-sbx-sandboxes` explicitly asserts
the same verification; `--yes` alone does not. Do not make this assertion if the
sandbox inventory is unknown. Restore SBX to check it first.

After success, open a new Terminal window before reinstalling or checking
commands. A missing `acq` command alone is not proof that all state was removed;
the wizard also checks the locations and packages it inventoried.

## Maintainer verification on a disposable Mac account

Build the exact standalone artifact from the checkout:

```sh
bash scripts/build-uninstaller "$HOME/Downloads/uninstall.command"
/bin/bash "$HOME/Downloads/uninstall.command" --dry-run
```

Verify cancellation before testing destructive removal. Use disposable
sandboxes and credentials, never valuable project work. Exercise:

1. Homebrew and standalone installs; npm if available.
2. No sandboxes, stopped sandboxes, and a running sandbox.
3. Keychain denial followed by a successful retry; orphaned ACQ Keychain entries.
4. A temporary clone's matching remote and a deliberately changed remote.
5. A forwarding helper still running, then retry after restarting the account.
6. Partial installs, symlinked state roots, and a custom install location.
7. Removal, repeated removal, and preservation of original project contents.
8. Actual browser-downloaded artifact opening, permissions, and security prompts
   once a release containing the artifact is available.

Record actual output. Offline tests cannot prove macOS Keychain, Homebrew, VM
shutdown, or downloaded-file opening behavior. See
[ADR-0036](../adr/0036-guided-acq-msb-uninstall.md) for the safety boundary.
