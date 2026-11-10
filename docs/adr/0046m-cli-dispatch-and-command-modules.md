---
title: "CLI dispatch layer and command modules"
status: accepted
date: 2026-11-07
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["SA-8", "SA-15", "SA-17"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0046m: CLI dispatch layer and command modules

## Context and Problem Statement

`py-acq/src/acq_py/cli.py` grew to 2721 lines holding three different things: the
argparse surface, every command handler, and the helpers those handlers share.
Two costs followed. Reviewing a one-verb change meant reading the whole file, and
the file's size defeated the size limits the coding practices ask for. More
sharply, the whole of `py-acq/src/acq_py/` is on the Tier-3 surface (ADR-0044m),
so *any* edit to *any* verb expired every live qualification transcript and
forced a re-run on every host in the fleet — the surface narrowing could not help
while one file held everything.

## Decision

`cli.py` owns the **argparse surface and the dispatch only**: `build_parser`,
`main`, and the two verbs whose handlers are a few lines each (`backend`,
`doctor`). Every other handler lives in a module under
`py-acq/src/acq_py/commands/`, grouped by the verb family a reader would look
for:

| module | verbs |
|--------|-------|
| `common` | no verbs: the adapter seam, the usage/operational failure envelopes, backend and workspace resolution, secret-scope parsing |
| `lifecycle` | `create`, `run`, `create --recreate`, `ls`, `stop`, `rm` |
| `session` | `exec`, `attach`, `shell`, `cp`, `ports`, verbatim passthrough |
| `secret` | `secret set`/`rm`/`ls`/`has` |
| `creds` | `provider-credential`, `github-scope`, `usai-rotate-api-key` |
| `kit` | `kit` list/validate/apply/check/update, `kit-source` add/ls/rm |

`common` exists because nine helpers are genuinely shared across families; it is
the single place the exit-code contract (0 success, 2 usage, 1 operational) and
the failure vocabulary are expressed, so the families cannot drift apart.

The names the command modules own that callers address are **re-exported from
`cli`** as aliases, so `cli.<name>` keeps resolving. They are aliases and not
indirections: each handler reads a name from its owning module, so substituting
one in a test means patching it there. The adapter modules are imported in `cli`
for the same addressing reason.

`doctor` and `version_info` stay **lazily imported** inside their handlers. That
is the ADR-0044m surface closure: they are the only `acq_py` modules off the
Tier-3 surface, so importing either at startup would let a break in them kill the
contract commands the live oracle drives while the gate still called the
transcripts current.

## Consequences

A change to one verb family touches one module, so review is bounded and the file
sizes fall within the coding-practice limits. The dispatch is readable in one
screen, which is what makes a missing verb visible.

The Tier-3 cost does not disappear: `commands/*` is under the
`py-acq/src/acq_py/` prefix and therefore on the surface, so a handler change
still expires every cell. What changes is that the *reason* is now legible — the
diff names the family that changed — and that the groundwork exists to narrow the
surface per-module later, which was impossible while one file held every verb.

Two invariants are now asserted rather than assumed: every advertised verb must
have a dispatch arm whose body calls a handler that exists, and every re-export
must be the owning module's object rather than a copy. Both fail under mutation
(an arm deleted, an arm gutted, an alias replaced by a wrapper or a duplicate
literal), so a later split cannot quietly strand a verb.

The split itself was mechanical: blocks were relocated by exact AST source range,
no test file was changed, and the 150-vector contract corpus passed unchanged —
which is the evidence that the refactor altered no behaviour.

## Verification

`python -m pytest py-acq/tests -q` (501 tests) and
`scripts/run-vectors --acq "python -m acq_py"` (150 contract vectors) pass
unchanged from before the split. `test_cli.py` carries the dispatch and
re-export guards; `test_off_surface_modules_are_not_loaded_by_cli` (ADR-0044m)
asserts the lazy-import closure in a fresh interpreter.

## Correction (2026-11-09): two statements above are inaccurate

The decision is unchanged. The record above is left as written, and these
corrections apply:

- **"The file sizes fall within the coding-practice limits."** The split made
  each file smaller. But the coding standard in AGENTS.md sets a 50-line limit on
  functions, and the split did not meet it. On 2026-11-09, ten functions in
  `cli.py` and `commands/*.py` exceed 50 lines. The longest are `cli._dispatch`
  (202 lines) and `cli.build_parser` (194). The others run from 51 to 66 lines:
  `run_cp`, `run_kit_source_rm`, `run_secret_import`, `run_recreate`,
  `run_attach`, `run_kit_update`, `_set_locked` and `_remove_credential`. They are
  open coding-standard debt. The split did not resolve them.
- **"`doctor` and `version_info` … are the only `acq_py` modules off the Tier-3
  surface."** `TIER3_SURFACE_EXCLUSIONS` in `qualification/matrix.py` also
  excludes `runtime.py` (reached only through `doctor`) and the two
  deterministic test backends, `_stub_msb.py` and `_stub_sbx.py`. That list, not
  this ADR, is authoritative.

Since this ADR, verbs have been added outside the module table above. The
`configure` handler lives in its own `commands/configure` module. `start` and
`restart` are in `lifecycle`, and `secret import` is in `secret`. The rule that
`cli.py` owns only the argparse surface and the dispatch still holds.
