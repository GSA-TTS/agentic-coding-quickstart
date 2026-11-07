---
title: "acq coexistence mechanism (ACQ_IMPL runtime switch and --channel installer seam)"
status: accepted
date: 2026-11-07
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-5", "CM-10"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0046m: acq coexistence mechanism

## Context and Problem Statement

The Python `acq` v1 replacement (ADR-0042m) is complete and Tier-3-qualified on
Windows. Upstream will ship one installer and one `acq` command, but the Bash
wrapper is still the shipped entry point in this fork, and the Python
implementation lives beside it under `py-acq/`. Both expose an `acq` command, so
a user must be able to choose which implementation runs without the two colliding
on the `acq` name on their `PATH`. The coexistence mechanism must be proven on
this fork before it becomes the upstream release seam.

## Decision

The Bash `acq` is the neutral entry point over two implementations, selected by
an `ACQ_IMPL` environment variable:

- unset or `bash` — the existing Bash body (default unchanged);
- `python` — resolve and `exec` the Python implementation, forwarding argv and
  the exit status verbatim;
- any other value — fail closed with exit 2 and a clear message.

The Python implementation has a distinct, resolvable identity so it never
collides with the `acq` name: an `acq-python` launcher — a distinct script
(checked into the repo root and shipped in the release archive as an enumerated
component, then linked by the installer as `acq-python`, never as an alias of
`acq`) that runs the managed runtime `python -m acq_py` against `py-acq/src`.
The dispatcher's resolution order is:

1. `$ACQ_SCRIPT_DIR/acq-python` — the installer-linked launcher (the distinct
   identity);
2. `python -m acq_py` — the managed runtime (`$ACQ_SCRIPT_DIR/py-acq/runtime/...`)
   else `python3`/`python` on `PATH`, with `PYTHONPATH` pointed at
   `$ACQ_SCRIPT_DIR/py-acq/src`.

`ACQ_RUNTIME` is the single interpreter-path override, reused from
`acq_py/runtime.py`. On Windows there is no separate `acq-python` file: the
distinct identity is realized by the `acq.ps1` launcher's `ACQ_IMPL=python`
preamble, which resolves the same interpreter natively (the managed
`py-acq\runtime\python.exe`, else `python` on `PATH`) and runs `python -m acq_py`.

The installers (`install.sh` / `install.ps1`) accept a `--channel` flag. `python`
is the only channel and the default, so it parses and installs exactly what the
installer installs today; any other value fails closed with exit 2. On this fork
the flag is plumbing — it establishes the stable `--channel` interface upstream
will extend. On POSIX the installer links the distinct `acq-python` launcher to
`$INSTALL_DIR/acq-python` (the archive's enumerated `acq-python` component, never
the `acq` launcher) alongside the existing `acq` link.

The Python CLI's `version` output reports `"impl": "python"` (JSON and human) so
a bug report is unambiguous about which implementation produced it.

## Consequences

Default behavior is unchanged: an unset `ACQ_IMPL` and no `--channel` do exactly
what they do today. `ACQ_IMPL=python` reliably execs the Python implementation
from both a repo checkout (the checked-in `acq-python`) and an installed layout
(the installer's `acq-python` link), and the `python -m acq_py` fallback covers a
layout missing the launcher. The Bash-side installer merge and the deprecation
notice remain upstream concerns and are out of scope here.

## Verification

Tier-1 vectors and pytest cover: `ACQ_IMPL=python` dispatches to the Python
implementation (including the `version` `impl` field); unset/`bash` runs the Bash
body; `--channel python` parses and installs; and unknown `--channel` / `ACQ_IMPL`
values exit 2. A live transcript proves `./acq version` (Bash default),
`ACQ_IMPL=python ./acq version` (Python), and the installer fail-closed paths.
