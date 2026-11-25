# Upstream handoff

This branch brings the Python `acq` implementation and its supporting work, developed
in a personal fork that has since been retired, into
`GSA-TTS/agentic-coding-quickstart`. It records review inputs, not an acceptance
decision. Repository settings described here are checkout records, not a live
GitHub settings audit.

**Tracking.** What remains to land this work (the other PRs it depends on or
conflicts with, the checklist, and who decides what) is coordinated in
GSA-TTS/agentic-coding-quickstart#709, not in this file. This file keeps only the
review inputs below.

**ADR identifiers.** The fork's decisions carry an `m` suffix (`0038m` to `0052m`) so
they could be issued there without colliding with upstream numbers. They are renamed
to the next free upstream numbers, with every reference updated, right before this
branch merges; until then the `m` form is the identifier in all text and links, and
the mapping table below is the key. The old-to-new table will be added to the merge
PR description.

## What is included

- **Python implementation:** readable, stdlib-only runtime code in
  [`py-acq`](../py-acq/README.md), versioned JSON results, backend adapters,
  host-held configuration and state migration, and bundled pinned kits.
  `ACQ_IMPL` selects the implementation; Windows launchers default to Python,
  while the POSIX Bash entry point defaults to Bash (ADR-0047m/0048m).
- **Installers:** `install.sh` and `install.ps1` verify release archives and
  `provenance.json` against `SHA256SUMS`, accept an independent
  `--sha256`/`-Sha256` pin of that file, verify GitHub artifact attestations
  when `gh` is available, support offline sources and user-scope installation,
  use atomic PID-safe ownership markers, and expose the `python` channel. After
  installing they report sandbox prerequisites and offer, only interactively and
  on an explicit yes, to install the pinned msb. See
  [acq v1 installers](howto/acq.md#acq-v1-installers).
- **Qualification:** the [`qualification/`](../qualification/README.md) harness,
  language-neutral vectors, live backend oracles, and
  [`qualification-ledger.json`](qualification-ledger.json) implement three tiers
  of evidence. Supported platforms and currently qualified cells are different
  claims; offline tests do not establish live enforcement.
- **Release asset build:** `.github/workflows/build-assets.yml` builds every
  per-platform archive from pinned runtimes (python-build-standalone for POSIX,
  the python.org embed for Windows) and the exact-hash validator `wheelhouse/`
  as `installer/assets.json` enumerates them, generates `provenance.json`,
  enumerates the complete set with `scripts/gen-install-assets`, and installs it
  offline on Linux and Windows. On pull requests it runs as a dry run
  (uploading workflow artifacts only, cross-building `macos-arm64` on Linux
  because Apple-silicon runners did not start on the fork);
  `.github/workflows/release.yml` calls it at the release tag with `sign: true`
  (building `macos-arm64` natively on `macos-15`), runs secret-gated signing,
  attests every file in `dist`, and publishes the complete set to the GitHub
  Release (ADR-0042m, ADR-0050m).

## Suggested review order

1. Read [`docs/spec/acq-v1.md`](spec/acq-v1.md), its approval-status note,
   [`GLOSSARY.md`](../GLOSSARY.md), and ADR-0038m through ADR-0045m (then 0051m and 0052m, the acq-owned sbx base kit and msb base image).
2. Review migration and trust boundaries against ADR-0032/0035/0037, then the
   adapter capability contract and Python implementation notes. Read corrections
   and amendments in ADR-0046m/0047m/0048m as well as their original decisions.
3. Compare the vector manifest and
   [test-retirement inventory](test-retirement-inventory.md) with Tier-1 and
   Tier-2 checks; inspect the live transcript metadata and waivers separately.
   The ledger gate requires recorded revisions to be ancestors of the evaluated
   commit. Squashing or cherry-picking the branch may require new evidence.
4. Review installers, runtime provenance, release packaging and the
   [release setup guide](howto/release-gate-setup.md) together. Compare the
   enumerated assets with what the workflow actually produces.
5. Resolve the governance and administration choices below before relying on
   the proposed gates. All ADRs are linked in the [ADR index](adr/README.md).

## Fork ADR mapping (`m` identifiers, renamed before merge)

Statuses below are the recorded frontmatter statuses, not upstream approvals.
“None” means no upstream ADR is explicitly extended or superseded by this
record; sibling fork decisions are cited in the records themselves.

| ADR and title | Status | Summary | Upstream relationship |
|---|---|---|---|
| [0038m — Portable acq v1 compatibility contract](adr/0038m-portable-acq-v1-compatibility-contract.md) | accepted | Preserves deliberate commands, state and security semantics while defining structured results. | None; defines the replacement contract. |
| [0039m — Rewrite verification and test-retirement strategy](adr/0039m-rewrite-verification-and-test-retirement-strategy.md) | accepted | Separates subprocess contract evidence, implementation tests and live qualification. | Builds on the Bash suite adopted in ADR-0025; no formal supersession. |
| [0040m — Backend adapter capability contract](adr/0040m-backend-adapter-capability-contract.md) | accepted | Declares transport-neutral capabilities, error codes and trust ownership. | Supersedes ADR-0010's Adapter contract section. |
| [0041m — Configuration and state migration behavior](adr/0041m-configuration-and-state-migration-behavior.md) | accepted | Defines forward-only, atomic migration and consented security-exception recreation. | Extends ADR-0035 host authority; preserves ADR-0032 backend-state boundary. |
| [0042m — v1 installation, runtime ownership, and update channels](adr/0042m-installation-runtime-ownership-and-update-channels.md) | accepted | Specifies app-private CPython, checksum-verified archives and the offline asset set. | Continues the installation subject of ADR-0026; no formal supersession. |
| [0043m — Language-neutral test-vector format and runners](adr/0043m-language-neutral-test-vector-format-and-runners.md) | accepted | Defines JSON vectors, dual runners, normalization and sentinel conformance. | None. |
| [0044m — Live cross-platform qualification matrix and transcript](adr/0044m-live-cross-platform-qualification-matrix-and-transcript.md) | accepted | Defines live oracles, currency, waivers and the ledger gate. | Qualifies ADR-0035/0037 host enforcement; no formal supersession. |
| [0045m — Home-agent handoff and bounded autonomy contract](adr/0045m-home-agent-handoff-and-bounded-autonomy-contract.md) | accepted | Records fork-only authorization, retained gates, stop conditions and their enforcement limits. | None; fork governance. |
| [0046m — CLI dispatch layer and command modules](adr/0046m-cli-dispatch-and-command-modules.md) | accepted | Separates Python dispatch from command handlers and records remaining size-limit debt. | None. |
| [0047m — acq coexistence mechanism (ACQ_IMPL runtime switch and --channel installer seam)](adr/0047m-acq-coexistence-mechanism.md) | accepted | Defines implementation selection and installer channels; corrects earlier completeness claims. | None. |
| [0048m — Windows defaults to the Python implementation with acq's managed runtime](adr/0048m-windows-defaults-to-the-python-implementation.md) | accepted | Changes the Windows default and records gates still owed after the approved flip. | None; amends ADR-0047m's Windows default. |
| [0049m — CI-only Python quality tools, pinned with hashes](adr/0049m-ci-only-python-quality-tools.md) | accepted | Pins lint, typing, security and coverage tooling outside the runtime. | None. |
| [0050m — Release signing scaffolding](adr/0050m-release-signing-scaffolding.md) | accepted | Secret-gated Sigstore, Authenticode and macOS signing that is a no-op until upstream configures credentials. | None; extends ADR-0042m's release provenance. |
| [0051m — acq supplies the sbx sandbox base kit instead of a built-in agent](adr/0051m-sbx-base-kit-is-acq-owned.md) | accepted | Passes acq's own base kit to `sbx create` so a change in sbx's built-in agent kit format cannot break create. | Builds on ADR-0030 (acq's devenv base image). |
| [0052m — msb's shell agent and the ro-mount canary use acq's base image](adr/0052m-msb-base-image-is-acq-owned.md) | accepted | The Bash msb backend and the canary use the same base image as the Python backend. | Builds on ADR-0030. |

## Governance facts for upstream decision

- **Specification approval:** the spec records its merge on 2026-11-02, but no
  human approval of its user stories. Implementation proceeded although
  ADR-0045m deferred implementation until final specification approval. Upstream
  decides how to resolve that recorded status.
- **Historical red gates:** ADR-0045m's enforcement-status note records merges
  touching the Tier-3 surface while its gate was red, followed by later or still
  pending re-qualification. ADR-0048m records the project lead's Windows default
  approval before every original gate held. These records remain review inputs.
- **Fork precedence:** [`AGENTS.fork.md`](../AGENTS.fork.md) overrides AGENTS.md
  for fork authorization, attribution, approval boundaries and ADR lifecycle.
  Its authorization is fork-only; it does not grant upstream write authority.
  Upstream decides its disposition and any replacement policy. Its `m`-suffix
  rule is applied as described under "ADR identifiers" above: renumber at merge.
- **ADR-0045m gates:** distinct-agent review, human-only merging and fresh live
  evidence are recorded policy. Required checks and reviews are not enforced
  in the fork. The dated ADR note records PR-only, signed-commit, no-delete and
  no-force-push protections, but an empty required-check list and zero required
  approvals. The proposed release ruleset and CODEOWNERS review are not enforced;
  upstream chooses rulesets, owners, required checks and review requirements.
- **Ledger waivers:** two waivers for msb/Linux aarch64 and sbx/Linux x86_64
  expire on 2027-02-05 and cite the retired fork's qualification issue (the
  earlier msb/Linux x86_64 waiver was retired by a live PASS run). They are
  retained as evidence metadata, not silently transferred acceptance. Live
  qualification is tracked in GSA-TTS/agentic-coding-quickstart#709; new live runs
  can replace the waivers.
- **Releases and tokens:** `ENABLE_RELEASES` is recorded as unset in the fork.
  A fork experiment exercised the PR/gate/tag sequence but proposed `4.0.1`
  against a `4.1.1` manifest without release tags; that PR was closed. Upstream
  decides release enablement, version history, token ownership and permissions.
- **Signing:** ADR-0050m adds release steps for Sigstore keyless signing of
  `SHA256SUMS`, Windows Authenticode and macOS codesign plus notarization, each a
  no-op until its repository variable and credentials are set
  ([release signing](howto/release-signing.md)). Upstream decides whether to
  enable them, the signing identities, credential custody and access, and runtime
  patch ownership/cadence (still a proposal in `py-acq/README.md`). Artifact
  attestations and checksums do not supply OS code signing.

## CI and administration assumptions

`vars.ENABLE_RELEASES == 'true'` directly gates `Release PR` and
`Tier-3 release gate (release)`; `Release Tag` and asset jobs depend on them.
`secrets.RELEASE_PLEASE_TOKEN` is optional and falls back to `github.token`.
Actions must be allowed to open PRs, and release PRs must reliably receive
checks before a maintainer makes those checks required. No repository settings
are changed by this documentation.

ADR-0045m records these check contexts. They are candidates to reconcile with
upstream policy, not an enforced required-check list:

| Check name | Role |
|---|---|
| `pre-commit` | Hook checks, including ShellCheck and markdownlint |
| `Markdown Lint` | Markdown changes |
| `vectors` | Tier-1 corpus |
| `ruff, mypy, bandit and coverage` | Python quality |
| `acq offline suite under bash 3.2` | Stable aggregate over the Bash matrix |
| `Windows` | Stable Windows aggregate |
| `Conventional Commit Title` | PR title validation |
| `Tier-3 release gate` | Ledger check on PRs, main pushes and weekly runs |

The release workflow separately uses `Tier-3 release gate (release)` before
creating a tag. A PR uses the base branch's qualification rules; changing the
gate and satisfying it are separate reviews.

[CODEOWNERS](../.github/CODEOWNERS) has nine entries: `*` names
`@GSA-TTS/agentic-coding-team`; each of `/.github/workflows/`, `/AGENTS.md`,
`/SECURITY.md`, `/docs/qualification-ledger.json`, `/qualification/`,
`/scripts/qualify-backend-cell`, `/scripts/qualify-msb-ro-mount` and
`/.github/CODEOWNERS` names `@GSA-TTS/agentic-coding-admins`. Those teams cannot
own paths in the personal fork. Upstream must confirm team eligibility and
choose whether to require their reviews.

`qualification.host` publishes a `chore/ledger-*` branch and PR to the upstream
repository (the remote whose URLs are all `GSA-TTS/agentic-coding-quickstart`,
normally `origin`), or to a personal fork named with `--remote` (ADR-0044m, amendment
of 2026-11-14). It never pushes `main` or a tag and refuses any other `GSA-TTS`
repository. Whether an agent may run it without per-run approval, and whether
workflows should run on those branches, are maintainer decisions tracked in
GSA-TTS/agentic-coding-quickstart#709.

## Open work and the merge checklist

Moved to GSA-TTS/agentic-coding-quickstart#709, so there is one place to update:
landing the qualification evaluator (#699) first, reconciling this branch onto it,
renumbering the `m` ADRs, removing fork leftovers, repository settings and
CODEOWNERS, live Tier-3 qualification on each host, release and signing enablement,
and the cross-repository follow-ups. Two constraints from that checklist matter when
reading this branch:

- Merge with a merge commit, not squash or rebase, so revisions recorded in
  `docs/qualification-ledger.json` stay ancestors of `HEAD`; recorded entries cannot
  carry over a Tier-3 surface change or an ADR-renaming commit and are re-recorded
  after merge, on a commit that is on `main`.
- Offline tests, and local runs of the oracles that are not recorded as transcripts,
  are not live qualification evidence.
