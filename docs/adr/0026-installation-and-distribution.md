---
title: "Installation and Distribution of acq for Non-Technical Users"
status: accepted
date: 2026-08-24
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-15", "SR-3", "SR-11"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0026: Installation and Distribution of `acq` for Non-Technical Users

## Context and Problem Statement

Today the only documented way to get `acq` onto a machine is a manual
`git clone` followed by running `./acq` from inside the clone (README Step 2).
That is fine for developers, but the Quickstart's target audience explicitly
includes **new, non-technical users who are uncomfortable with the command
line**. For them the current flow has two problems:

1. **`acq` is not on `PATH`.** Users must `cd` into the clone and type `./acq`,
   or hand-craft a symlink. Neither is obvious to a non-technical user.
2. **There is no gentle "just install it" front door.** The natural instincts a
   newcomer might reach for do not serve a *bare* Mac:
   - `npm install …` fails with `command not found` because macOS ships no
     Node.js and — unlike `git` — provides **no shim that offers to install it**
     (see "The `git` vs `npm` asymmetry" below). The error is a dead end.
   - `brew install …` only works if Homebrew is already present.

We want an installation story that puts `acq` (and, at the user's option, the
`msb` sandbox runtime) on `PATH` with the least possible friction, without
compromising the federal security posture (no `sudo`, no silent `PATH` edits,
and a path to verifiable/pinned installs — available today via `--ref`/`--sha`,
default-pinned once release automation lands; see the Security posture section).

### Observed evidence from early non-technical users

Onboarding sessions with self-described "not very technical" users surfaced the
exact failure modes this ADR addresses, and constrain the solution space:

- **The `./acq`-from-the-wrong-folder trap hit multiple users.** After cloning,
  users ran `./acq run opencode ~/my-project` from their *project* directory (or
  their home directory) and got "no such file `./acq`", with no idea they had to
  `cd` back into the clone. At least two separate users hit this; one only
  recovered with an experienced colleague sitting next to them. Getting `acq`
  onto `PATH` removes this trap entirely — there is no "correct folder" to be in.
- **Homebrew cannot be *assumed* for the target audience on GSA GFE.** A user
  could not install Homebrew because installing it **requires administrator
  rights**. Not all GFE accounts lack admin — many developers have admin as part
  of a developer profile — but a *non-technical* newcomer generally does not, and
  cannot be assumed to. The `curl`-based paths (both `acq`'s installer and
  microsandbox's) worked **without admin** and were repeatedly called out as a
  major reduction in barrier to entry. This means the front door must **not
  require** Homebrew, while still *using* it automatically when it happens to be
  present (see method selection below).
- **The Xcode Command Line Tools prompt is easy to miss.** The CLT install
  dialog that `git` triggers can appear minimized in the Dock rather than in
  front of the user, stalling a newcomer who is watching the terminal. The
  installer and README should tell users to look for that pop-up (including in
  the Dock) explicitly.
- **Interim workarounds users invented — a shell alias or a hand-made symlink
  into `~/.local/bin` — all require walking a neophyte through editing dotfiles**,
  which is exactly the friction we are trying to remove. An installer that offers
  (with consent) to add the `PATH` line is the humane version of this.

These observations reinforce the decision drivers below and, in particular, the
choice of a no-admin `curl | sh` installer as the primary path rather than
Homebrew or npm.

### The `git` vs `npm` asymmetry (why npm cannot be the front door)

A common assumption is that `npm`, like `git`, will prompt a fresh Mac to
install what it needs. It does not:

- **`git`** is backed by an Apple *shim* at `/usr/bin/git`. The first invocation
  on a clean Mac triggers a **GUI dialog** offering to install the Command Line
  Tools (CLT). One click installs `git`, `clang`, `make`, etc.
- **`node`/`npm` have no shim.** There is no `/usr/bin/npm`. On a bare Mac,
  `npm` yields `zsh: command not found: npm` with **no pop-up and no next step**.
  Getting `npm` requires the user to already know it comes from Node.js and to
  install Node (nodejs.org `.pkg`, or Homebrew, or a version manager) first —
  precisely the reasoning a non-technical user cannot be expected to perform.

Therefore `npm` is only reasonable as a *convenience for users who already have
Node*, never as the primary path.

### Can we avoid the `git` / Command Line Tools dependency?

We explored a **hash-confirmed tarball** install to avoid requiring `git` (and
therefore the macOS Command Line Tools, CLT): download the release tarball with
`curl`, verify it against a published `SHA256SUMS` (fail-closed on mismatch),
and extract it — all with tools macOS already ships (`curl`, `shasum`, `tar`).

We decided **not** to pursue this, because it does not actually remove the CLT
dependency — it only defers it:

- **`acq` itself needs `git` at runtime.** The tool shells out to `git` for
  version introspection (`acq version` reports `branch@commit`) and users are
  immediately guided to `git init` their project so the agent can track changes.
  A user who installed via tarball would hit the CLT prompt on their very first
  real `acq` command instead of during install — a *worse* experience, because
  it happens after they think setup is finished.
- **The integrity win is available without the tarball.** Git objects are
  content-addressed, so pinning the clone to a **full commit SHA** is itself a
  cryptographic integrity check — the checkout cannot succeed with tampered
  content. That gives us hash-confirmed provenance without a second archive
  install path; release automation still publishes `SHA256SUMS` for installer
  asset verification.

So the CLT dependency is unavoidable for this tool; the right move is to make it
**painless and early** rather than to engineer around it. The installer's clone
method therefore **proactively triggers and waits for the CLT install** (via
`xcode-select --install`, no admin required), guiding the user to the dialog —
including the fact that it can open **minimized in the Dock**, a real stumbling
point observed in onboarding — and polls until `git` is usable before
continuing. This turns the previously fatal "git not found" into a handled,
guided step.

## Decision Drivers

- **Zero-to-installed on a bare Mac** — the front door must work on a machine
  with nothing but what macOS ships (`curl`; the installer then sets up `git`
  via the CLT install, which needs no admin).
- **No administrator rights required** — managed GSA GFE accounts are not
  admins. The front door must not depend on anything that needs `sudo` or admin
  to install (this rules Homebrew out as the primary path, since installing
  Homebrew itself requires admin).
- **`acq` on `PATH`** — after install, the user types `acq`, not `./acq` from a
  clone.
- **Never touch the user's `PATH` without consent** — offer to add the line,
  and if declined, print the exact line for them to add themselves.
- **Federal security posture** — release asset defaults pin to a release tag and
  canonical release commit SHA, published checksums, inspect-first supported, no
  `sudo`, install into a user-writable prefix.
- **Preserve `acq version` introspection and easy updates** — the on-disk layout
  should keep `acq`'s git-based version reporting and support in-place updates.
- **Minimal new surface** — reuse the existing `acq`/kit machinery and `msb`
  install methods rather than inventing new runtime dependencies.

## Considered Options

### Getting `acq` on PATH — one front door that picks the best available method

There is a **single** entry point — the hardened `curl … | sh` installer — so a
newcomer never has to *decide* how to install. `curl` ships with macOS, so the
front door works on a bare machine. The installer then **auto-selects the best
method already available on the host**, in this order, so users who happen to
have a package manager get its upgrade/uninstall semantics for free:

1. **Homebrew, if `brew` is already present** → `brew install GSA-TTS/tap/acq`.
   Idiomatic for a Bash CLI, auditable/versioned formula, and — crucially —
   `brew upgrade` / `brew uninstall` lifecycle. The installer **never installs
   Homebrew itself** (that needs administrator rights, which a non-technical
   newcomer generally lacks); it only *uses* brew when it is already there.
2. **npm, if `npm` is already present** → `npm install -g
   github:GSA-TTS/agentic-coding-quickstart`. Gives `npm -g` upgrade/uninstall
   semantics for users who already have Node. Not a *front* door itself, because
   on a bare Mac `npm` does not exist and — unlike `git` — offers no install
   prompt (see the asymmetry section above).
3. **Managed git clone + launcher symlink (fallback)** → the always-works path
   that needs nothing but `curl` and `git`. Chosen when neither brew nor npm is
   present, which is the expected case for the true target audience.

The installer supports overriding the auto-selection (`--method brew|npm|clone`)
and, regardless of method, uses no `sudo`, supports inspect-first / `--dry-run`,
and asks consent before any `PATH` change.

**Deferred — signed, notarized `.pkg` (double-clickable).** The best possible UX
for a non-technical user (pure GUI, no terminal for the install step), but
requires an Apple Developer ID certificate and notarization pipeline — an
organizational hurdle out of scope for this increment. Revisit if the
installer proves insufficient.

> **Increment note:** in this PR the **npm branch is fully wired** (the
> `package.json` `bin`/`files` fields ship an `acq` launcher, so
> `npm install -g github:GSA-TTS/agentic-coding-quickstart` puts `acq` on
> `PATH`). The **brew branch is stubbed** — the installer detects `brew` and
> reports what it *would* run, but the formula lives in a separate
> `GSA-TTS/homebrew-tap` repository that does not exist yet (deferred below). The
> **clone fallback is fully functional**, so the front door works end-to-end
> today regardless of which method is selected; the brew branch lights up once
> the tap is created.

### On-disk layout

1. **Managed git clone + launcher symlink.** Chosen for the **clone fallback**
   method. The installer does a shallow clone to a fixed, user-writable location
   (default `${XDG_DATA_HOME:-$HOME/.local/share}/acq`) and symlinks the `acq`
   launcher into a user-writable `PATH` directory (default `$HOME/.local/bin`).
   This preserves `acq version`'s `branch@commit` git introspection and supports
   in-place updates via `git pull` (or installer re-run). The brew and npm
   methods instead delegate lifecycle to those package managers and do not use
   this layout.
2. **Non-git file tree + launcher.** Rejected: `acq version` would report
   `unknown`, and updates would be a full re-download rather than a fast pull.

### Installing the sandbox runtime (`msb`)

- **Offer to install `msb` alongside `acq`** (with consent), reusing the
  README's existing methods (`brew install superradcompany/tap/microsandbox`, or
  `curl -fsSL https://install.microsandbox.dev | sh`). Chosen so a non-technical
  user reaches a working state in one flow. `--no-msb` opts out.

## Decision Outcome

Chosen: **a single hardened `curl … | sh` front door that auto-selects the best
install method already on the host** — Homebrew if `brew` is present, else npm if
`npm` is present, else a managed git clone + launcher symlink. Users who have a
package manager get its upgrade/uninstall semantics automatically; everyone else
gets the always-works clone fallback. The installer also **offers to install
`msb`** with the user's consent.

`PATH` is never modified without explicit consent; when declined, the installer
prints the exact line for the user to add.

### Scope of the initial increment (this PR)

In bounds now:

- This ADR (`0026`, `status: accepted`).
- `install.sh` — the hardened installer with brew → npm → clone auto-selection
  (the **clone** and **npm** branches fully functional; the **brew branch
  stubbed** pending the external tap repo).
- `package.json` `bin`/`files` wiring so the npm branch actually installs `acq`.
- **Optional commit-SHA pinning** (`--sha` / `ACQ_INSTALL_SHA`). The clone method
  can pin to a full 40-char commit SHA and verifies `HEAD` equals it after
  checkout, failing closed (and cleaning up) on mismatch — git objects are
  content-addressed, so a matching SHA *is* a cryptographic integrity check.
- **Release asset commit-SHA pinning by default.** `release-please` updates the
  installer release version marker. When a release is created, the release
  workflow checks out the release commit, writes that exact commit SHA into the
  `install.sh` asset, generates `SHA256SUMS`, and uploads both files to the
  GitHub release. Users who install from the release asset get a default clone
  target of the release tag plus a default `--sha`-equivalent integrity check
  against the release commit.
- **release-please manages `package.json`'s `version`.** An `extra-files` entry in
  `release-please-config.json` bumps `$.version` on each release so the npm
  package version tracks the release manifest (currently `2.0.0`) instead of a
  hand-maintained placeholder. A second `extra-files` entry bumps the installer
  release version marker so its default ref follows the package version.
- README streamlining + install instructions.

Deferred — only the work that **must** happen outside this repository (tracked
as issues):

- Creating the `GSA-TTS/homebrew-tap` repository and the `acq` formula, then
  un-stubbing the installer's brew branch. (External repo — cannot be done from
  this repo; tracked as an issue.)

### Security posture

- **No `sudo`.** Everything installs under the user's home; the `PATH` dir is
  user-writable.
- **Pinning is the release-asset default.** The installer accepts `--ref <tag>`
  and `--sha <full-commit>` (the latter is integrity-checked against the checked
  out `HEAD`, failing closed on mismatch — a content-addressed check). The source
  tree default ref is the current release tag, while release automation publishes
  an `install.sh` asset with the canonical release commit SHA embedded as the
  default SHA.
- **Verifiable.** Release automation publishes `SHA256SUMS` next to the installer
  asset. Inspect-first is supported: download `install.sh`, verify it with
  `SHA256SUMS`, read it, and use `--dry-run` before installing.
- **Consent-gated side effects.** `PATH` edits and `msb` installation each
  require explicit consent; declining is always a safe, documented fallback.
- **Idempotent.** Re-running updates an existing install rather than duplicating
  it.
- **One remaining unpinned leg, called out honestly.** The optional `msb` install,
  when no Homebrew is present, runs the upstream
  `curl -fsSL https://install.microsandbox.dev | sh`; that upstream installer is
  outside our control and is not pinned/checksummed by us. It is consent-gated
  (and, under `--yes`, authorized by the same blanket opt-in as the `PATH` edit).
  The `acq` clone install is pinned by default when the release asset is used;
  npm and explicit `--ref` overrides resolve the ref the user chooses.

> **Control Mapping:** CM-2 (Baseline Configuration), CM-3 (Configuration Change
> Control), CM-6 (Configuration Settings), SA-8 (Security Engineering
> Principles), SA-15 (Development Process), SR-3 (Supply Chain Controls),
> SR-11 (Component Authenticity).

## Consequences

- **Positive:** a bare-Mac, non-technical user gets `acq` (and optionally `msb`)
  on `PATH` from a single pasted command; developers keep the manual clone;
  brew and npm serve users who prefer them; `acq version` and updates keep
  working.
- **Negative / trade-off:** `curl | bash` carries a cultural stigma in security
  circles; we mitigate with pinning, checksums, inspect-first, no-`sudo`, and
  consent gates, but cannot fully eliminate the pattern short of the deferred
  signed `.pkg`.
- **Maintenance:** release automation must keep publishing `SHA256SUMS`, and
  (once the tap lands) the formula must track releases. The formula work remains
  deferred because it lives outside this repository.

## Validation

- **Offline / static:** `install.sh` passes `shellcheck --severity=warning`;
  README passes the repo markdown lint (`npm run lint:md`); the offline acq
  suite (`scripts/test-acq-bats`, bats-core per ADR-0025) continues to pass (the
  installer does not change `acq` dispatch).
- **npm packaging:** `npm pack --dry-run` ships exactly the runtime footprint
  (`acq`, `acq.backends/`, plus `package.json`/`README`/`LICENSE`); a global
  install (`npm install -g <spec>`) creates an `acq` launcher on `PATH` that
  resolves its script dir through the npm symlink and runs (`acq version` reports
  the module path and backend). The npm install is not a git checkout, so
  `acq version` reports "not a git clone" for the commit line — expected.
- **SHA pinning:** with `--sha <full-40-hex>` the clone method checks that commit
  out and verifies `HEAD` equals it, failing closed (and removing the partial
  clone) when the SHA is absent or mismatched; a malformed SHA, or `--sha` with a
  non-clone method, is rejected at argument parse. Verified live against a local
  checkout (matching SHA succeeds and prints "verified HEAD matches"; a
  well-formed but absent SHA fails closed and cleans up).
- **release-please version sync:** `release-please-config.json` carries an
  `extra-files` entry (`type: json`, `jsonpath: $.version`) so the next release
  bumps `package.json`'s `version`; `npm pack --dry-run` reports the manifest
  version (`2.0.0`) rather than a placeholder. A generic extra-file marker keeps
  `install.sh`'s `DEFAULT_RELEASE_VERSION` aligned with the release version.
- **Release assets:** on release creation, `.github/workflows/release.yml` checks
  out the release commit, copies `install.sh`, injects that exact commit into the
  release asset's `DEFAULT_RELEASE_SHA`, generates `SHA256SUMS`, and uploads both
  assets to the GitHub release.
- **Manual (bare-Mac reviewer):** on a clean macOS account, run the pinned
  one-liner; confirm `acq` resolves on `PATH` (after accepting the offered
  `PATH` line or adding the printed line), `acq version` reports the pinned
  `branch@commit`, and `--dry-run` performs no writes. Decline paths (`PATH`
  edit declined, `--no-msb`) leave a working `acq` and print correct guidance.
- **Live end-to-end:** verify after the first release containing this automation
  is published by downloading the `install.sh` and `SHA256SUMS` release assets,
  checking the checksum, and confirming `sh install.sh --dry-run --method clone`
  reports the release tag and canonical commit SHA.

## Links

- [ADR-0010: acq pluggable backends](0010-acq-pluggable-backends.md) — the
  `acq` wrapper and its XDG config location this install layout is consistent
  with.
- [ADR-0011: msb backend and neutral kits](0011-msb-backend-and-neutral-kits.md)
  — the `msb` runtime this installer optionally installs.
- microsandbox install methods: <https://install.microsandbox.dev> and the
  `superradcompany/tap/microsandbox` Homebrew tap.
- Related code/docs (this increment): `install.sh`, `README.md`,
  `release-please-config.json`.

### Deferred-work tracking

- Homebrew tap + formula (un-stub the brew branch):
  <https://github.com/GSA-TTS/agentic-coding-quickstart/issues/407>
