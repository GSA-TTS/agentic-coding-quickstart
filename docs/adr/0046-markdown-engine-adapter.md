---
title: "ADR-0046: Repository-owned Markdown engine adapter"
description: "Why npm, CI and pre-commit share one repository-owned Markdown lint adapter instead of invoking markdownlint-cli directly"
status: proposed
tier: 2
date: "2026-11-17"
last_updated: "2026-11-18"
---

# ADR-0046: Repository-owned Markdown engine adapter

## Context

Quickstart's npm script, Markdown workflow and pre-commit hooks invoke
markdownlint-cli 0.49.1 with an explicit `.markdownlint.jsonc`,
`.markdownlintignore` and `--dot "**/*.md"`. We need the same lint engine,
diagnostics and one-pass fixes without a general-purpose CLI dependency tree.

The implementation is adapted from GSA-TTS/agentic-coding-patterns commit
`ab218e0010dc91a88eb571916a414dfe7913c52e`, merged as
`fc6c9f84e335499ebb83fd19c6662c489cedebd5`. Source files are
`.github/linters/run-markdownlint.mjs`, `markdown-files.mjs` and their tests.
The primary reviewer verified that the source and merge trees are identical.

## Decision

Use `.github/linters/run-markdownlint.mjs` from all three entry points. Run it
from the repository root with Node 22 or later. It checks by default; `--fix`
performs one engine fix pass and relints; `--count-only` reports the same
selection without linting or writing. Unsupported arguments fail. The default
pre-commit hook remains check-only and `markdownlint-fix` remains manual.

Retain markdownlint 0.41.1, markdown-it 14.3.3 with HTML enabled, ignore 7.0.11,
jsonc-parser 3.3.1, linkify-it 5.0.2 and the other retained lockfile versions,
with one intentional exception: override KaTeX 0.16.47 to 0.18.2, matching the
reviewed Patterns adapter, to remediate GHSA-238p-pmpm-9mq7. The primary's fresh
baseline audit identified this low-severity advisory in the retained math
dependency chain; removing the CLI alone would not remove it. Diagnostic and
fix parity must be checked against the frozen baseline after this update.
Parse JSONC with the old
CLI's parser options, including comments and trailing commas, checking parse
errors before accepting the result. Require an object configuration, also for
`extends`. The historical `config.frontMatter` string stays an inert config
member, not a newly enabled engine option. Engine-default frontmatter and
inline directives remain effective.

Unlike Patterns, Quickstart has no hard-coded template, changelog or fixture
exclusions. `.markdownlintignore` is the exclusion authority, including its
case and negation behavior. Include hidden Markdown, Unicode/spaced names and
distinct lexical symlink aliases. Prune ignored directories before traversal:
negating a child of an ignored directory cannot reinclude it under gitignore
semantics. Do not enter `.git` metadata. Extension case follows the old CLI's
platform policy (case-folded on Darwin/Windows, case-sensitive on Linux).

## Intentional differences and limits

- Missing/unreadable required config or ignore files, malformed/non-object
  configs (including extended configs), empty selections and unsupported flags
  fail closed with exit 4. Config failures precede any fixes. The old CLI could
  silently accept some of these cases. `--count-only` validates selection, not
  config, and takes precedence over `--fix`.
- This is not a replacement CLI: no positional globs, executable configs,
  ambient rc discovery, YAML/TOML fallback or custom-rule command-line loading.
  Required and extended configuration is JSON/JSONC only.
- Root JSONC trailing commas are accepted. The old CLI's ambient loader rejected
  them before its JSONC parser ran; extended JSONC trailing commas already worked.
  A differential test records this intentional effect of removing that loader.
- Broken links, cycles and links outside the repository fail rather than being
  silently dropped. Ignored paths and Git metadata are pruned before resolving
  links, so irrelevant dependency trees cannot cause traversal failures.
- Fixes are not transactional across files. A later read/write failure can
  follow an earlier fix; review the worktree after failure.
- Lint errors exit 1; warnings alone exit 0. Diagnostics preserve the CLI's
  lexical filenames, locations, severity, sorting, detail and context.
- Simulated extension-case tests are not native filesystem qualification.
  Symlink privileges, permissions and case-insensitive mounts need native
  Darwin/Windows validation; Linux sandbox evidence cannot certify them.

## Validation and rollback

Ordinary regression tests run in CI and via `npm run test:markdownlint`.
For migration review, provision a separately frozen old CLI with the original
Quickstart lockfile and run the same tests with `MARKDOWNLINT_BASELINE_CLI`
pointing to its `markdownlint.js`. Optional parity tests compare real repository
selection and diagnostics, copied repository fix bytes, and discriminating
synthetic JSONC, ignore, alias, frontmatter and formatting cases. Without the
oracle they explicitly skip, not pass as parity evidence. All execution belongs
in the workspace sandbox. The Markdown workflow retains the high audit gate
and existing action pins.

Rollback restores the old linter manifest/lockfile and all three entry points
together; it does not require changing lint rules or Markdown content.
