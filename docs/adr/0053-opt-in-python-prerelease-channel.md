---
title: "Use an isolated Python prerelease channel while Bash remains the default"
description: "M1 distribution, rollback, release isolation, fix carry-forward and acceptance plan for the Python replacement"
status: proposed
tier: 2
date: 2026-11-25
last_updated: "2026-11-25"
decision_makers: ["Peter (repository admin)", "Bret Mogilefsky", "William Zujkowski"]
category: deployment
nist_controls: ["CM-3", "CM-5", "SA-11", "SI-7", "SR-3", "AC-6"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
related_files: ["docs/adr/0042m-installation-runtime-ownership-and-update-channels.md", "docs/adr/0047m-acq-coexistence-mechanism.md", "docs/adr/0048m-windows-defaults-to-the-python-implementation.md", "docs/howto/acq.md", "release-please-config.json", "installer/assets.json"]
---

# ADR-0053: Use an isolated Python prerelease channel while Bash remains the default

## Context and Problem Statement

M1 merges the reconciled Python replacement into `main` as **opt-in**, not as
the new default. M2 replaces Bash with Python, including on Apple Silicon Macs.
Existing Bash installs, release tags and credentials must keep working during M1.
Intel macOS is out of scope for Python; do not remove its existing Bash release
assets as a side effect. This proposed ADR is a design and test plan, not an
implementation or approval to publish. Identifier 0053 follows this branch's
inventory, including 0052m; integration renumbers all retained identifiers once.

## Decision Drivers

- No silent upgrade from Bash to Python through any default installation route.
- Reproducible preview identity, managed runtime and exact release-byte evidence.
- Independent Bash release continuity; a red Python gate must remain red.
- Non-destructive back-out, explicit command ownership and bounded release work.
- Mainline fixes cannot silently disappear from the replacement.

## Verified Baseline

**VERIFIED** means source read, not a successful live installation. Local citations
are `file:line` at candidate `8dc78422a8c97bde8c27e1121e875ca233cf1890`.
`main@6acce0ce:file:line` means the separate Bash baseline read with `git show`.
GitHub reads below were made on 2026-11-25. **PROPOSED** means future work;
**ASSUMED** means an acceptance prerequisite not established by this investigation.

| Surface | VERIFIED fact and source |
|---|---|
| Candidate installer | `install.sh:38,84-90,147-150,181-184,203-213` bakes **0.1.0**, defaults `CHANNEL` to `python`, accepts `--ref` as a version and rejects all other channels (help says “the only channel supported on this fork”). It is not yet a dual-channel installer. |
| Candidate resolution | `install.sh:543-563` resolves the default to `releases/download/v${VERSION}`, or reads `--source` HTTPS/file/local assets; no latest-release lookup. `install.sh:666-694` verifies the optional SHA256SUMS pin, archive and provenance hashes before extraction. |
| Attestation | `install.sh:338-369,684` checks GitHub archive attestations when a capable `gh` exists. Missing verifier/attestation continues informationally; other verification errors fail. Checksums alone do not establish an independently trusted publisher. |
| Ownership | `install.sh:791-809,816-843,899-905` requires both launchers, Bash backend tree, Python runtime/source/wheelhouse, records owned entries and **overwrites both PATH links**. Existing preservation checks do not make that linking behavior opt-in-safe. |
| Bash installer | `main@6acce0ce:install.sh:35-66,342-360,412-419` bakes 4.2.1 / v4.2.1; auto picks brew, npm, clone (explicit SHA selects clone). Brew owns the version; explicit `--ref` is refused for brew. npm installs `github:GSA-TTS/agentic-coding-quickstart#${REF}`, not a registry dist-tag. Clone checks requested SHA when supplied. |
| Bash Windows | `main@6acce0ce:install.ps1:1-23,581-614` defaults version 4.2.1 and downloads `v${Version}/acq-windows-x64.zip`, verified against SHA256SUMS (custom URL requires a hash); it runs Bash through Git Bash. |
| Docs routes | `main@6acce0ce:docs/howto/acq.md:197-213,217-246` documents the installer, direct GitHub npm spec, brew formula and pinned Windows URL. Candidate `docs/howto/acq.md:223-259,300-318` distinguishes new installers from pinned upstream releases; Windows/npm support claims differ. |
| Runtime selection | `acq:63-65,817-891` loads common Bash logic before dispatch; unset/`bash` runs Bash, `python` prefers the **adjacent** `acq-python`, then managed/PATH runtime, unknown values exit 2. It does not find an independently installed preview via PATH. `acq-python:82-117` prefers managed runtime after an explicit override. |
| Windows divergence | `acq.ps1:3-6,145-153` defaults to Python, unlike POSIX. This is not acceptable for the shared M1 default launcher; see [Windows decision](0048m-windows-defaults-to-the-python-implementation.md). |
| Stable versions | `release-please-config.json:3-28` uses `simple`, stamping package.json, install.sh, install.ps1, README and how-to; `:29-37` additionally stamps Python metadata on the candidate. `.release-please-manifest.json:1-3` remains 4.2.1. The manifest is release-please's own state, **not** an extra-file entry. |
| Stable workflow | `main@6acce0ce:.github/workflows/release.yml:5-31,128-159` releases from main, builds Bash Windows ZIP, standalone installers, platform validator wheelhouses, SHA256SUMS and attestations; bakes the clone SHA into the installer asset. No ENABLE_RELEASES or Tier-3 dependency is present there. |
| Candidate workflow | `.github/workflows/release.yml:39-65,92-127,143-173` gates release PR creation/evaluation on ENABLE_RELEASES; tags depend on Tier-3, then build and publish attested assets. Copying this wholesale to main would block Bash releases. Workflow text about an unset fork variable is not proof of upstream repository settings. |
| Python assets | `installer/assets.json:13-66` enumerates `acq-macos-arm64.tar.gz`, `acq-linux-x86_64.tar.gz`, `acq-linux-aarch64.tar.gz`, `acq-windows-x64.zip`, provenance, checksums and four validator wheelhouses. No Intel Mac archive exists. `installer/provenance.json:3-22` is a template, not evidence of publication. |
| Asset build | `.github/workflows/build-assets.yml:1-16,83-117,246-254,312-322` builds/uploads workflow artifacts, not Releases; `scripts/gen-install-assets:38-78` checks enumeration and hashes installers, archives, wheelhouses and provenance. `scripts/assemble-release:30-44` and `scripts/gen-provenance:17-19` accept build version/revision overrides. |
| macOS evidence | `.github/workflows/build-assets.yml:97-110,324-335,364-401` cross-builds unsigned macOS PR artifacts; native arm64 installation/identity smoke runs only on non-PR events. This proves available test wiring, not a passing run or full install/upgrade/rollback coverage. |
| npm contents | `package.json:4,7-22,36-39` has version 4.2.1, only `acq` bin, Bash files/validator postinstall, darwin/linux restriction; it omits `acq-python` and `py-acq`. A dist-tag alone cannot turn these bytes into a functioning Python package. No registry publisher was found in the inspected release workflow. |

**VERIFIED external snapshots:** `gh api repos/GSA-TTS/homebrew-tap/contents/Formula/acq.rb`
returned blob `e89a2e7c6f39270e08ba48c6eb6183fb08b17daa`: `Formula/acq.rb:5-6`
pins the v4.2.1 tag tarball and hash; `:10-24` pins validator resources and uses
Homebrew Python 3.13; `:27-48` installs Bash/backends and a wrapper named `acq`.
It does not follow main or bundle the replacement. GitHub `releases/latest`
returned v4.2.1, `draft=false`, `prerelease=false`, with Bash assets.
The release PR API returned open `chore(main): release 4.3.0`, head `15f4fd87`.
These snapshots establish neither npm publishing access nor admin settings.

**VERIFIED release-please semantics:** the pinned action's `package.json:30-32`
declares `release-please ^17.6.0`. Library v17.6.0
`src/versioning-strategies/default.ts:91-104` bumps major for breaking commits
at >=1.0.0; `schemas/config.json:15-29,73-90` defines `versioning`,
`prerelease-type`, GitHub `prerelease` and tag prefix options. Its
`src/versioning-strategies/prerelease.ts:173-260` increments prerelease suffixes
and strips them if `prerelease` is false. The supplied main docs
`docs/customizing.md:37-47` explain `versioning: prerelease` together with
`prerelease: true`; confirm the pinned action's actual output before adopting it.
SemVer 2.0.0 standard precedence is `5.0.0-rc.1 < 5.0.0` (and both exceed 4.x).
Prerelease suffix and GitHub Release `prerelease` flag are separate concepts.
**ASSUMED:** GitHub latest-selection protection and npm dist-tag permissions work
as intended; explicitly set preview `prerelease=true`, `make_latest=false` and
verify `releases/latest` remains Bash before announcement. A suffix alone is not
a routing or gate policy.

## Considered Options and Recommended Outcome

Every recommendation below is **PROPOSED**, pending human acceptance and
implementation. No installer, workflow, release config or tap changes accompany
this ADR. Existing fork decisions remain historical; this changes their upstream
M1 application, not their recorded acceptance status.

### 1. Versioning, tags and the pending Bash release

Options: use 4.3.0-rc.N; use 5.0.0-rc.N; use a separate `python-*` non-SemVer
namespace. Recommend **v5.0.0-rc.1, then rc.2, etc.**, leaving every v4.x tag
and existing asset immutable. It advertises the eventual breaking replacement
without reserving Bash's next minor version. A 4.3.0 preview competes with the
pending stable version; a custom prefix complicates current `v${VERSION}` URLs.
Failure mode: preview tags can contaminate stable release discovery even when
GitHub marks them prerelease. The stable release-please path must be tested to
ignore v5 prereleases and stay anchored to its 4.x manifest; block M1 until that
is demonstrated, not repaired after an accidental 5.x release proposal.

Recommend finishing the pending 4.3.0 PR **as Bash before M1 merges**, after
ordinary stable review/checks. Do not close it, retarget it to Python or merge
it as rewrite approval. Reconcile its resulting stamps back into the candidate.
`feat(acq)!:` on main would otherwise make default release-please propose 5.0.0,
not preserve 4.3.0; below-1.0 options do not apply to 4.2.1. Recommend an M1
**squash** commit `feat(acq): add opt-in python preview`, without breaking footer,
only after all default Bash contracts are preserved. Keep the eventual breaking
commit for M2. If M1 actually breaks a default contract, fix it or delay merge;
do not hide a real break by changing the commit title.

### 2. Cut from main, with a manual preview publisher

Options: release from the rewrite branch; two release-please configs/manifests
on main; explicit preview publication from a fixed main commit. Recommend the
third: merge the opt-in-safe candidate, then a **dispatch-only, admin-approved
Python publisher** takes an immutable main SHA and explicit preview version.
It validates tag uniqueness, main ancestry, matching evidence and complete assets
before tagging; no default push trigger and no stable manifest update. At most
one candidate publishes at a time. Keep release-please on the Bash stable line
through M1; there is no second preview release PR to reconcile.

Failure mode: manual versions/stamps can drift. Build-time preview metadata,
installer baked version, ZIP/tar contents, provenance and npm package version
must all equal the explicit rc version while source identity equals the chosen
SHA. Stamp **staged release bytes only**; do not alter stable source stamps.
Build overrides exist but do not yet accomplish all this stamping. The current
build workflow's package.json comparisons must become channel-aware in future
implementation. Evidence must cover the final staged bytes, not just source.

Rewrite-branch publishing is useful for private workflow artifacts, but fails
the agreed M1 main-merge/evidence sequencing and can diverge from shipped fixes.
Two release-please lanes are supported in principle using separate state,
`versioning: prerelease`, `prerelease: true`, `prerelease-type: rc`; their failure
mode is shared-file stamping, tag discovery and two competing release PRs.
Do not enable prerelease on the existing stable config. A short-lived release
branch from the accepted main SHA is an alternative if admins require it, but
creates another fix-carry obligation and must preserve that source/evidence SHA.

### 3. Installation routes and runtime selection

Options: change the existing installer default; preserve it and add explicit
channel routing; add unrelated standalone installer names. Recommend
**install.sh defaults to bash**, with `--channel python` /
`ACQ_INSTALL_CHANNEL=python` selecting the separately pinned preview assets.
Flag wins over environment; unknown channel exits 2 before writes/network.
Keep stable `--method`, `--ref`, `--sha` semantics on the Bash path. Python
`--ref` is the version without leading v; require a preview pin or independently
maintained preview pointer, never GitHub `/latest`. Windows uses analogous
`-Channel python`; its unqualified installer/launcher stays Bash in M1.
Separate scripts avoid argument collisions but fragment the public entry point.
Failure mode: reusing shared version defaults or install roots routes users to
the wrong assets. Separate Bash and preview version resolution and ownership.

Install Python's source, app-private CPython, wheelhouse and provenance beside
Bash under a **separate preview installation root**, not the Bash managed clone
or shared data root. Expose only **acq-python** on PATH; never overwrite `acq`,
brew/npm-owned links, or a user's file. On Apple Silicon this is the supported
opt-in command, using the bundled arm64 runtime, not the Mac's system Python.
On Windows provide distinct `acq-python.cmd` / `acq-python.ps1` wrappers that
select Python without persisting environment changes. Those wrappers are new
requirements, not current archive components. Refuse unsupported Intel Macs.

Keep `ACQ_IMPL` dispatch on main for developers with an adjacent runtime.
For side-by-side installed testing prefer `acq-python`, **not** globally exported
`ACQ_IMPL=python`: stable brew/npm `acq` cannot find another installation's
adjacent runtime. Failure mode: source/runtime drift or wrong PATH identity;
identity output and resolved command paths are required acceptance assertions.

Homebrew options: replace `acq`, use `--HEAD`/versioned formula, second formula.
Recommend **GSA-TTS/tap/acq-python**, pinned to checksum-verified rc platform
assets, owning only `acq-python` and its private runtime. Leave `acq` unchanged.
HEAD is moving/unqualified; versioned formulae add maintenance without improving
the two-name contract. Failure mode: formula links or dependency cleanup collide;
prove coexistence and removal. Tap approval and arm64 packaging are not assumed.

npm options: overwrite `latest`; same-package preview dist-tag; second package.
Recommend the existing package's **python-preview** dist-tag, never `latest`,
with channel-specific packed files/bin and managed-runtime delivery verified
before publication. Same-package global installs replace one another: this is
**opt-in replacement**, not coexistence. Preserve the old Bash install receipt
and exact version. Use the installer/brew route when coexistence is required.
A second package avoids replacement but needs another namespace/publisher.
Failure mode: publishing defaults to latest, omitted runtime, or bin collision;
explicit tag and `npm pack`/installed-content tests are mandatory. Unqualified
GitHub npm installs follow repository defaults, not dist-tags: keep their `acq`
Bash and fix docs to use an immutable stable ref. Windows npm stays out of scope.

### 4. Back-out, coexistence and uninstall

Options: swap a shared `acq` link; select via global environment; distinct names
and ownership-aware removal. Recommend distinct names. Stop preview invocation,
remove any opt-in alias/ACQ_IMPL setting, refresh shell command caches (`hash -r`
on POSIX; new Windows shell), then run the original resolved Bash `acq`.
Remove preview **installation files only**, using their ownership receipt;
`brew uninstall acq-python` must leave `acq` and shared backend dependencies.
Never use a full environment/state/credential uninstaller as channel back-out.
Failure mode: same-root cleanup destroys the Bash clone, shared credential store
or projects; required preservation assertions are below.

For npm replacement, reinstall the **recorded stable version/spec**, restore
its bin links and verify identity; `npm uninstall` alone does not restore Bash.
Do not prescribe a registry version before confirming stable registry contents.

**VERIFIED compatibility limits:** `legacy_bash.py:1-24` only reads Bash state;
`migration.py:598-610,677-694` imports once under a lock.
`config.py:445-484` prepends a schema marker with backup/read-back recovery, so
“all Bash files are untouched” is too strong. `secretstore.py:23,59,278` shares
the secret index/metadata and macOS service label. `provider_creds.py:52,182`
writes Python records separately. The supplied Step A report observed offline
round trips and a stubbed end-to-end import, **not live keychain/backend proof**.
Bash retains its prior config; Python-only binding/kit-source changes do not
automatically propagate back. Explain this before preview mutation; back-out
preserves prior Bash behavior, not universal reverse synchronization. Do not
run both implementations' mutating commands concurrently during M1.

### 5. M2 default flip

Options: flip on merge; flip after time elapsed; explicit acceptance milestone.
Recommend M2 only after credential lifecycle/refresh integration, ownership-aware
uninstall, real install/upgrade/back-out evidence and current Tier-3 evidence
for every claimed cell (or valid, explicitly approved waivers). Resolve known
parity differences and native macOS/Windows policy/signing behavior. Admins
approve changing installer, runtime dispatcher (macOS included), brew formula,
npm latest and stable release automation together, with a documented rollback.
Then publish 5.0.0 via the stable line and retire the preview pointer; no rc
promotion by relabeling old bytes. Failure mode: a partial flip leaves channels
with different defaults; test every public route against the final version.

### 6. Carry main fixes until the rewrite lands

Options: periodic full merge; selective cherry-picks; automated lag check.
Recommend the integration owner merges **origin/main into
migration/python-cross-platform after each merged main PR, within one business
day**, through a signed integration PR (no rebase/force-push), preserving both
implementations and rerunning affected tests. Before final merge require
`git merge-base --is-ancestor origin/main <candidate>` and exact-head review.
After M1 lands, both implementations receive fixes on main; no standing rewrite
branch is needed. Automation counting N commits is a weak substitute for knowing
whether one commit changes behavior; cherry-picks lose ancestry and omissions.

Add a main PR checklist: “Does this change Bash behavior, shared config/state,
credentials, installer or release contracts? Does Python need the same change?”
Answer yes/no with evidence; when yes, file an owning issue immediately with
source PR/SHA, affected Python surface, test oracle, owner and unblock trigger.
Failure mode: human checklist/merge duty is missed. Coordinator checks daily;
unresolved parity issues block M1, and ancestry checks block stale integration.
These process tasks are tracked by the epic's M1 fix-carry/install work, not an
untracked promise; see Links / tracking.

### 7. Gate and administrator sequencing

Options: disable/waive the red gate wholesale; apply it to every Bash tag; split
stable and Python publication. Recommend the split. Preserve Bash's stable
release path and its required checks. The **Python preview publisher and M2
publisher require Tier-3 before tag/publication**; do not interpret prerelease
as permission to bypass qualification. Build-only workflow artifacts may be
produced while red, clearly unqualified and not advertised as M1 installs.
Merge and release are separate decisions: opt-in-safe code may merge first to
bind live transcripts to main, but M1 publication waits for current evidence.
Failure mode: a global required Python check blocks stable Bash PRs or a tag
appears before evaluation. Peter must approve channel-scoped required checks
and release graph before merge; keep red Python results visible, never fabricate
success. ENABLE_RELEASES/signing secrets/ledger custody are admin configuration,
not facts inferred from comments or an agent's permissions.

## Prerelease Test Plan

**PROPOSED acceptance; not run by this docs task.** Bind source SHA, rc version,
runtime/Patterns/backend/harness revisions, installer/archive/checksum digests,
OS/architecture, commands, observed output and exit statuses to each transcript.
Use disposable accounts/projects and synthetic credentials for destructive tests;
real authorized inference needs separately approved credentials, never log values.
Each stage reports PASS, FAIL or BLOCKED; a skipped native run is not PASS.

| Test | Required oracle |
|---|---|
| Defaults / stable continuity | On macOS arm64, Linux x86_64/aarch64, Windows x64: unqualified installer and `acq` remain Bash, before/after preview install/removal. Existing brew formula, tagged GitHub npm route and registry latest (if published) remain Bash. Run Bash's offline suite and a stable release-please dry run: next 4.x PR/tag unaffected by rc tags. |
| Opt-in install | Online pinned and offline `--source` / `-Source` installs select preview only when requested; default/flag/env precedence and invalid channels are checked. Read back `acq-python version --json` identity, exact rc/SHA, managed runtime path/version and provenance. No system Python needed; no new `acq` link or unexpected PATH edit. |
| macOS arm64 | Native Apple Silicon runner asserts arm64, exercises BSD utilities, install twice, upgrade rc.1→rc.2, invoke Python and Bash, remove preview and repeat removal. Include brew install/upgrade/uninstall coexistence and browser quarantine/signature behavior on a real disposable Mac. Intel refusal must occur before download. |
| Linux / Windows | Test both enumerated Linux architectures; Windows x64 PowerShell 5.1 and cmd distinct preview names, spaces/non-ASCII paths, execution policy and downloaded signature behavior. Preserve Git Bash default. Missing KVM/WHP blocks live sandbox evidence, not an invented pass. No Windows npm claim. |
| Package contents | npm packed preview contains its launcher, source and complete runtime-delivery contract; install with explicit dist-tag, then reinstall recorded Bash spec and verify links/version. Query latest before/after; preview publish must not move it. Formula pins immutable archive/hash; upgrades do not replace `acq`. |
| Preservation / rollback | Seed Bash config, provenance, global/scoped secret existence, index and sidecars. Trigger Python migration, test import idempotency and malformed/unpinned warnings, return to Bash. Original projects/unrelated files and Bash config semantics persist. Explicitly check Python-only changes are not promised as reverse-migrated. Preview-only removal leaves shared state, credentials, backend and Bash runtime intact. |
| Failure paths | Bad/missing archive/provenance checksums, wrong SHA256SUMS pin, missing runtime, unknown channel, interrupted upgrade, occupied bin link, running Windows executable, credential denial/cancellation and retry fail clearly without damaging stable install. Attestation errors fail; unavailable verification is disclosed. |
| Gate / publication | Red/missing/stale evidence prevents any Python tag/Release; independent Bash release still works. Valid evidence permits only the selected rc/SHA. Verify GitHub prerelease flag, latest remains Bash, asset completeness/hashes and source identity. Run native sandbox create/attach/refresh/inference and offline completeness per qualification contracts, not just CLI version smoke. |

## Rollout Checklist

- [ ] Peter accepts the decisions below; nominate integration/release and runtime-patch owners.
- [ ] Finish reviewed Bash 4.3.0; carry its stamps/fixes into the rewrite candidate.
- [ ] Implement isolated channel/version/root/bin contracts and channel-scoped release gates in separately approved PRs; do not merge today's installer/workflow defaults unchanged.
- [ ] Verify main-fix ancestry, parity issue closure, Bash default contracts and rc-tag isolation; finalize ADR numbering once and review the exact candidate.
- [ ] Merge opt-in-safe candidate to main with non-breaking squash message; record main-bound live Tier-3 evidence without disguising blocked cells.
- [ ] Build final staged rc assets; pass all native/package/back-out acceptance, security scans and independent review; authorize signing and publication of that exact set.
- [ ] Publish Python prerelease only, explicit npm preview tag and separate brew formula; verify GitHub latest/Bash routes again before announcing instructions and rollback limits.
- [ ] Observe preview defects through tracked issues; M2 has a separate acceptance/default-flip approval, not a date-based automatic promotion.

## Decisions Needed from Peter / the User

Recommendations first; each is answerable **yes/no**. A “no” requires a replacement
decision before implementation. These are not assertions that access is available.

1. **Yes recommended:** keep Bash 4.x and its pending release independent and cut manually versioned v5.0.0-rc.N from an accepted main SHA, with a non-breaking M1 squash and a separate breaking M2?
2. **Yes recommended:** approve Bash-default dual-channel installers, preview-only command/root, second brew formula and same-package npm python-preview replacement route (with explicit rollback)? Confirm tap/npm publish authority and actual stable registry availability before enabling those routes.
3. **Yes recommended:** require Tier-3 for preview publication/M2 but not Bash releases, and approve main-bound bootstrap merge sequencing, scoped required checks, release activation/signing identities and ledger custody? Red means no published preview yet.
4. **Yes recommended:** assign an owner to per-PR main carry-forward and make native migration/back-out, credential refresh, uninstall and current qualification evidence the M2 trigger?

## Consequences and Risk Treatment

Positive: default installs stay predictable; explicit preview identity and ownership
make back-out testable; manual preview publication avoids competing release PRs.
Negative: channel-aware staging/release discovery still needs engineering; npm
replacement cannot coexist in one global prefix; migration is not bidirectional.
CM-3/CM-5 separation of duties and SA-11 evidence apply to local development
distribution, not a production ATO claim. Human review is required before release.

Three highest-risk **ASSUMPTIONS**: stable release-please discovery can exclude
manual v5 rc tags; tap/npm authorities and channel-specific packaging are available;
native shared credentials/state and preview-only uninstall preserve rollback after
real mutations. All three have explicit failing oracles above. Do not announce M1
until they are verified or the unsupported route is explicitly removed from scope.

## Links / Tracking

- M1 channel implementation and fix-carry work: GSA-TTS/agentic-coding-quickstart#709; pending stable release: GSA-TTS/agentic-coding-quickstart#684.
- Credential refresh / M2 dependencies: GSA-TTS/agentic-coding-quickstart#695, GSA-TTS/agentic-coding-quickstart#726, GSA-TTS/agentic-coding-quickstart#727, GSA-TTS/agentic-coding-quickstart#728, GSA-TTS/agentic-coding-quickstart#730, GSA-TTS/agentic-coding-quickstart#731.
- Uninstall / native acceptance: GSA-TTS/agentic-coding-quickstart#711, GSA-TTS/agentic-coding-quickstart#710, GSA-TTS/agentic-coding-quickstart#712, GSA-TTS/agentic-coding-quickstart#713.
- Durable contracts: [runtime ownership](0042m-installation-runtime-ownership-and-update-channels.md), [coexistence](0047m-acq-coexistence-mechanism.md), [qualification](0044m-live-cross-platform-qualification-matrix-and-transcript.md), [macOS uninstall acceptance](0048-macos-uninstall-acceptance-workflow.md).

AI-assisted design by OpenCode; status remains proposed until human acceptance.

## Design Verification Transcript

Scoped docs-only plan approved by the coordinating human-authorized agent on
2026-11-25. Only this ADR and the ADR index change; no release behavior changes.

| Check / observed output | Result |
|---|---|
| `npm run lint:md` — repository Markdown adapter exited 0, no diagnostics | PASS |
| `pre-commit run --files docs/adr/0053-opt-in-python-prerelease-channel.md docs/adr/README.md` — hygiene, markdown, secrets and executable-mode checks passed; irrelevant code hooks reported no files | PASS |
| `pre-commit run gitleaks --all-files` — Detect hardcoded secrets: Passed | PASS |
| Read-only Python/YAML assertions — required MADR fields, related-file paths, local links in both changed files, unique ADR identifiers and index registration passed | PASS |
| `npm run test:markdownlint` — serial rerun: 24 passed, 0 failed, 5 baseline-dependent skips | PASS with disclosed skips |
| Initial adapter test run overlapped pre-commit's `npm ci`; missing dependency files caused 2 failures. Serial rerun after install completed resolved the race; no source changes | FAIL then reverified |
| Independent read-only blocker review against candidate/Bash sources and supplied plan — no blockers | PASS |
| `git diff --check` — no whitespace diagnostics | PASS |
| Local links checked by assertions; no standalone ADR/frontmatter/link validation script exists in this repo; CI external link job is advisory (`markdown-quality.yml:76-114`) | Local PASS; hosted check not run |
| App builds, native prerelease installs and Tier-3 qualification | Not applicable to docs-only change; rollout acceptance remains unexecuted |

Rollback of this design-only change is a reviewed revert of its commit; it has no
authentication, authorization or runtime effect. Future release implementations
require separate approval, checks and human review.
