---
title: "Tier-3 evaluator introduction"
description: "Inactive evaluator foundation, provenance, trust contract, and offline validation"
status: proposed
tier: 2
last_updated: "2026-11-16"
---

# Tier-3 evaluator introduction

This package introduces the evaluator separately from the Python CLI integration,
so later pull requests can be judged by the base branch's rules rather than
their own evaluator code. It does not enable a release gate, publish a release, or
provide qualification evidence. With no ledger, `qualification.gate check`
fails; absence is not a passing qualification result.

## Provenance

The evaluator dependency closure was initially imported without code changes from
`GSA-TTS/agentic-coding-quickstart` commit
`05b4d90b67a4cd745cf023de97d42f1c92b8fc2f`, developed in the
`mogul/agentic-coding-quickstart` fork. It comprises eight Python files in this
directory and `py-acq/src/acq_py/hostexec.py`. Review follow-up adds strict
transcript validation and immutable base-entry checks, extracts ledger schema
and evidence helpers, and adds offline regressions. A behavior-neutral inline
of exit classification keeps the runner's single-attempt function within the
function-size limit. The resolver remains
unchanged. It is loaded directly by
`qualification/hostexec.py`; copying only this directory is insufficient.
Both paths require administrator review through CODEOWNERS. The scoped adoption
decision and narrow resolver size exception are in
[ADR-0040](../docs/adr/0040-qualification-evaluator-introduction.md).

## Evaluation contract

On a subsequent PR, use a clean checkout of these base-branch rules with a
trusted Python interpreter and Git executable. Run `python -P` with PYTHONPATH
set to that checkout as its sole, absolute entry (no empty or relative entries).
Keep the candidate repository as the working directory, fetch complete
history, and verify its expected HEAD. Clear Git redirection/config injection
variables and replacement refs. Candidate code must not execute in the evaluator
job before evaluation. Store reports in a fresh runner-temporary file rather
than a candidate-controlled path. Enforce a job timeout and treat every nonzero
exit as failure.

Use a trusted Python >=3.11 executable, clear inherited Python startup/path
overrides, disable user-site loading, and then set the one evaluator path:

```sh
PYTHONPATH="$TRUSTED_EVALUATOR" "$TRUSTED_PYTHON" -B -s -P -m qualification.gate check
```

The variables above are trusted absolute paths supplied by the reviewed job,
not candidate inputs. The available bootstrap command is `qualification.gate`;
the broader `python -m qualification` CLI is not included here.

Ledger entries and waivers remain reviewed assertions. A waived cell is not a
qualified cell. Old or nonancestor transcript revisions must not be relabeled
as new evidence. The package does not authenticate who approved a waiver.

## Offline checks

Run `python3 -B -s -m unittest discover -s qualification/tests -v` inside an
independently isolated sandbox, not merely a separate checkout. The
`test-qualification` pre-commit hook runs that same suite and is selected for
evaluator/resolver/config changes. The existing hosted Pre-commit workflow runs
all hooks on all files, so it also executes these tests without activating a
release qualification gate.
Tests use synthetic data and temporary directories, including a Git-backed
qualification/surface-change/ancestry check, real recording and base-relative
same-hash mutation rejection. They check canonical attempts, derived outcomes,
binding identities, and visible evidence blocks. See ADR-0040 for the
discriminating negative-control plan. Live macOS, Windows
and Linux backend qualification belongs to the subsequent integration work.
