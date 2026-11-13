# Tier-3 evaluator introduction

This package introduces the evaluator separately from the Python CLI integration,
so later pull requests can be judged by the base branch's rules rather than
their own evaluator code. It does not enable a workflow, publish a release, or
provide qualification evidence. With no ledger, `qualification.gate check`
fails; absence is not a passing qualification result.

## Provenance

The evaluator dependency closure is imported without code changes from
`GSA-TTS/agentic-coding-quickstart` commit
`05b4d90b67a4cd745cf023de97d42f1c92b8fc2f`, developed in the
`mogul/agentic-coding-quickstart` fork. It comprises eight Python files in this
directory and `py-acq/src/acq_py/hostexec.py`. The latter is loaded directly by
`qualification/hostexec.py`; copying only this directory is insufficient.
Both paths require administrator review through CODEOWNERS.

## Evaluation contract

On a subsequent PR, use a clean checkout of these base-branch rules with a
trusted Python interpreter and Git executable. Set PYTHONPATH to that checkout
only, keep the candidate repository as the working directory, fetch complete
history, and verify its expected HEAD. Clear Git redirection/config injection
variables and replacement refs. Candidate code must not execute in the evaluator
job before evaluation. Store reports in a fresh runner-temporary file rather
than a candidate-controlled path. Enforce a job timeout and treat every nonzero
exit as failure.

Ledger entries and waivers remain reviewed assertions. A waived cell is not a
qualified cell. Old or nonancestor transcript revisions must not be relabeled
as new evidence. The package does not authenticate who approved a waiver.

## Offline checks

Run `python -m unittest discover -s qualification/tests` in an isolated checkout.
Tests use synthetic data and temporary Git repositories. Live macOS, Windows
and Linux backend qualification belongs to the subsequent integration work.
