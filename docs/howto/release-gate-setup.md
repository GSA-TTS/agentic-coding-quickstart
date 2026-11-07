---
title: "Release Gate Setup (maintainer)"
description: "The repository settings and token that make the Tier-3 release gate hold a release, so merging the release PR needs no manual verification"
status: canonical
tier: 3
last_updated: "2026-11-07"
audience: "maintainers"
keywords: ["release", "release-please", "tier-3", "gate", "branch protection", "required check", "token"]
related_files: ["docs/howto/qualification.md", "docs/adr/0044m-live-cross-platform-qualification-matrix-and-transcript.md", ".github/workflows/release.yml", ".github/workflows/tier3-release-gate.yml", ".github/CODEOWNERS"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# Release Gate Setup (maintainer)

The goal: **merging the release-please PR is the only manual step in a release**, and
it is held automatically when a Tier-3 cell is stale, blocked, or waived past its
expiry (ADR-0044m).

The code side is done. `release.yml` is split so the gate sits **before the tag and
the GitHub Release exist**:

| Job | What it does |
|-----|--------------|
| `Release PR` | keeps the release PR up to date (`skip-github-release`) |
| `Tier-3 release gate (release)` | every claimed cell holds a current green transcript or an unexpired waiver |
| `Release Tag` | creates the tag and the GitHub Release (`skip-github-pull-request`) |
| `Validator Wheelhouse`, `Release Assets` | build and upload, after the tag |

A failing gate therefore leaves **no tag and no Release**. `tier3-release-gate.yml`
reports the same check on pull requests, pushes to `main`, and weekly.

Where you see the failure depends on step 2 below. With `RELEASE_PLEASE_TOKEN` set,
the check appears on the release PR and you fix the cell before merging. Without it,
the check cannot run on the PR, so the first failure happens on the push after you
merge: the release PR is merged but untagged, and no new release PR is opened until
the gate passes and `Release Tag` runs. That state resolves itself on the next green
push to `main` — nothing is lost, but the release is stalled until the cell is
re-qualified.

What remains is repository configuration, which only a maintainer can do.

## 1. Let release-please open its PR (required — releases are broken without it)

If `release.yml` fails on `main` with:

```text
release-please failed: GitHub Actions is not permitted to create or approve pull requests.
```

then no release PR is created at all. Fix it either way:

- **Settings > Actions > General > Workflow permissions**: tick *Allow GitHub Actions
  to create and approve pull requests*. Simplest, and enough to unblock releases.
- **Or** add the token in step 2, which also fixes this.

Verify: re-run the latest `Release` workflow (Actions > Release > Re-run all jobs) and
confirm a `chore(main): release X.Y.Z` PR appears.

## 2. Give release-please its own token (needed for step 3)

A PR opened with the default `GITHUB_TOKEN` does **not** trigger `pull_request`
workflows, so the gate never reports on the release PR and cannot be required.

1. Create a fine-grained PAT on the account that should author release PRs, scoped
   to this repository, with **Contents: read and write** and **Pull requests: read
   and write** (a GitHub App token works too).
2. Settings > Secrets and variables > Actions > New repository secret, named
   `RELEASE_PLEASE_TOKEN`.

A PAT carries its own permissions and ignores the workflow's `permissions:` blocks,
which is worth knowing when reading `release.yml`.

Both release-please jobs already use `secrets.RELEASE_PLEASE_TOKEN || github.token`,
so adding the secret is the whole change; nothing to edit.

Verify: the next release PR shows the token owner as author, and the
`Tier-3 release gate` check appears on it.

## 3. Require the gate on `main` (do this only after step 2)

Settings > Branches (or Rules) > the `main` protection rule:

- **Require status checks to pass**, and add **`Tier-3 release gate`**.
- **Require review from Code Owners** — this is what enforces the `CODEOWNERS` rule
  on `docs/qualification-ledger.json` (the ledger is self-reported evidence, so its
  integrity is a review control).

> Requiring the check before step 2 makes the release PR unmergeable: the check
> would never report on it.

Verify: open a throwaway PR and confirm `Tier-3 release gate` is listed as required.

## 4. Keep the cells current

The gate is only as good as the ledger. Run
`python3 -m qualification.host` on each host when its cell goes stale — 90 days, a
backend `major.minor` change, or a change to the Tier-3 surface. See
[`docs/howto/qualification.md`](qualification.md) and the checklist issue it points
to. `python3 -m qualification.gate check` shows the current state at any time.

## What a release looks like when this is done

1. Conventional commits land on `main`; release-please keeps a release PR open.
2. The release PR carries the `Tier-3 release gate` check. It is red when a cell is
   stale, so you qualify that host and merge afterwards.
3. Merging the PR runs the gate again on `main`; only if it passes does `Release Tag`
   create the tag and the Release, and the wheelhouse and asset jobs publish.
4. Nothing else is manual. A stale cell stops the release rather than being noticed
   by a human, or missed.
