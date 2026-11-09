---
title: "CI-only Python quality tools, pinned with hashes"
status: accepted
date: 2026-11-08
decision_makers: ["Bret Mogilefsky", "William Zujkowski"]
category: development-process
nist_controls: ["SA-11", "SA-15", "SR-3", "CM-7"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0049m: CI-only Python quality tools, pinned with hashes

## Context and Problem Statement

The Python implementation in `py-acq/` had pytest and nothing else in CI. No
linter, type checker, security linter or coverage measure ran on it. A review
found about 25 genuine `Optional` to `str` mismatches that mypy reports and
in-process branch coverage of 66%, and none of it was visible in CI.

`AGENTS.md` asks for an ADR before adding a dependency, and it requires exact
pins, approved registries and licences without AGPL. ADR-0042m keeps acq's
runtime stdlib-only and offline. Any tool added for quality must therefore stay
out of what acq installs or ships.

## Decision

Add four PyPI tools to CI, as development dependencies only:

- ruff, the linter, with an explicit rule set (`E4`, `E7`, `E9`, `F`, `I`,
  `UP`, `B`) so that a ruff upgrade cannot change the gate on its own
- mypy, the type checker
- bandit, the security linter, which skips only B404 and B603 because acq
  exists to run backend CLIs by argv list
- pytest-cov, which reports in-process branch coverage against a `fail_under`
  floor

All four run on `py-acq/src` in `.github/workflows/python-quality.yml`. Their
configuration lives in `py-acq/pyproject.toml`. The gates started at zero
findings, with every existing finding fixed, so there is no baseline file. A
false positive gets a per-line suppression that states its reason. The skip
lists do not grow to clear one.

**Scope.** These are CI-only tools. They are not runtime dependencies, they are
not in `[project.dependencies]`, and nothing in the release archives or the
managed runtime includes them. A developer runs them in a throwaway virtual
environment.

**Pinning.** `py-acq/requirements-quality.txt` pins every package exactly,
transitive dependencies included, with SHA-256 hashes for each distribution.
CI installs it with `pip install --require-hashes --no-deps --only-binary :all:`,
so pip resolves nothing by itself, a substituted artifact fails the install, and
no source distribution is built. The Windows job installs the same file to get
pytest. pytest's pin matches `requirements-dev.txt` and `pyproject.toml`.

**Cooldown.** A version must have been on PyPI for at least seven days before
it is adopted. This matches the cooldown `dependabot.yml` already applies to
every other ecosystem here, and lets a compromised release be caught and pulled
before it reaches CI.

**Licences.** The adopted set is MIT, Apache-2.0, BSD, PSF-2.0 and MPL-2.0
(pathspec, a mypy dependency). Nothing is AGPL or GPL.

**Updates.** Dependabot's `pip` entry for `/py-acq` proposes weekly grouped
updates with the seven-day cooldown, covering `requirements-dev.txt` and
`requirements-quality.txt`. A manual update edits the top-level pins and
regenerates the file with a hash-generating resolver, using an exclude-newer
date seven days back. The command is in the file's header. An update that adds
findings either fixes them or suppresses each one with its reason in the same
change.

## Consequences

Type, lint and security regressions in `py-acq/src` fail a pull request, and so
does a drop in coverage. CI downloads about twenty packages from PyPI for the
quality job. acq's offline, stdlib-only runtime is unaffected. The
hash-locked file is long and is meant to be regenerated rather than edited by
hand. Each tool upgrade can surface new findings, which the upgrade must
resolve. `tests/` is not linted yet.

## Verification

`python-quality.yml` runs on every pull request, push to `main` and merge group.
A finding or a coverage drop below the floor fails it. Installing with
`--require-hashes --no-deps` proves that the file is complete and that the
artifacts match.
