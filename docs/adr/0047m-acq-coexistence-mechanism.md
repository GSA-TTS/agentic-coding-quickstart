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

# ADR-0047m: acq coexistence mechanism

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

## Correction (2026-11-09): the Python implementation is neither complete nor currently qualified

The Context section says the Python replacement "is complete and
Tier-3-qualified on Windows". That overstated its state when this ADR was
accepted, and it is not true now. The decision itself is unaffected: the
`ACQ_IMPL` switch, the distinct `acq-python` identity and the `--channel` seam
are what this ADR records. This note corrects only the premise. The text above
is left as written.

**Command surface.** On 2026-11-09 the Python CLI owns every subcommand that the
Bash `acq help` lists, so none of them falls through to the backend passthrough.
That includes `configure`, `start`, `restart`, `backend set`/`unset`,
`secret import` and `secret set --host/--env`. Some documented Bash flags are
still missing, and the Python CLI rejects each one as a usage error:

- none remain (see the updates below).

Update (2026-11-10): `--publish HOST:GUEST` on `run`/`create` and on
`ports NAME` are implemented in the Python CLI (`py-acq/README.md`, "Published
ports"), and so is `--no-update-check` on `run`, with the stale-sandbox check
it turns off; `--clone` on `run`/`create` is implemented too (next update).
None of them is in this list any more.

**Safety-relevant: `ACQ_CLONE` was silently ignored.** Bash treats `ACQ_CLONE=1`
like `--clone`, so the agent works on a disposable clone of the workspace. The
Python implementation did not read `ACQ_CLONE`, so a user who set it got the real
workspace mounted read-write with no warning. It now refuses `ACQ_CLONE=1` on
`create` and `run` with a usage error before anything runs (see `py-acq/README.md`),
until clone mode is implemented.

*Update (2026-11-10):* clone mode is ported. `--clone` and `ACQ_CLONE=1` now
run `create`/`run` on a disposable clone in the Python implementation too, with
the Bash adapter's isolation, refusals and on-disk layout (`py-acq/README.md`,
KNOWN_FAILURE_MODES §67).

The CLI-form gaps for multiple run/create workspaces, per-path `:ro`, opaque
`run ... -- AGENT_ARGS...`, and pre-verb `--image REF` / `--image=REF` are now
ported. Each workspace receives path and trusted-directory containment checks;
clone mode affects only the primary. Extra mounts and read-only markers persist
through recreate and are checked on re-attach; agent arguments remain specific
to each invocation. Image precedence and backend-specific argument dispatch
follow the Bash adapters. Evidence is in `py-acq/tests/test_cli_forms.py` and
the CLI-form rows in `test/vectors/manifest.json`; this is offline parity
evidence, not a new Tier-3 qualification.

*Kit parity update (2026-11-10):* `kit apply NAME KITREF` now uses the same
checked fetch/private local copy as create, retaining Python's full-commit pin
rule and neutral-kit validation. On msb, neutral volumes now map to named disks
and tmpfs at create, unioned last-wins by guest path, with Bash's CRC naming,
safety checks, cleanup after confirmed removal and mid-life skip notice
(ADR-0023). An empty recorded extras list is authoritative over the live
environment. Unlike the current Bash loader's empty-record fallback, Python
keeps that explicit empty selection empty. Python retains configured extras in
its record as well as env/CLI extras so restart and heal keep the complete
create-time kit set even after config changes. These recording choices and their
rationale are documented in `py-acq/README.md`, "Kits outside the bundle".
Sbx-native passthrough remains an accepted gap with `ACQ_IMPL=bash` as its
replacement: the checked Python loader and translator validate neutral fields,
and passing native specs through requires a separate validation path for native
payload references. Neutral-kit checks remain mandatory.

The Python implementation also has documented behaviour differences from Bash.
It reads the `extra_kits`, `provider_kit`, `scope_github_token` and
`default_agent` settings that `acq configure` writes, applies a kit outside its
pinned built-in bundle only when the ref is pinned to a full commit (fetching
and verifying that commit), and copies a local kit directory into acq's private
cache and checks it there before applying. It heals the recorded kit set on
re-attach, binds any newly added `msb` secrets while stopped before `msb start`,
and sets up host ssh-agent forwarding on msb as Bash does (the `--vsock` route,
the in-guest bridge and its restarts, ADR-0021), reading and writing the same
host-config key and route link, so a sandbox either implementation created keeps
its forward; the remaining differences from Bash are recorded in
`docs/KNOWN_FAILURE_MODES.md` (§55, §56, §69, §72, §73, §74, §93, §97). Backend
doctor diagnostics report both installed versions against the accepted floors
and MSB readiness; named diagnostics port the ADR-0030 guest probe with nonfatal
warnings and the existing JSON check records. The default backend offer is
terminal-only and defaults to No. Potentially installing MSB repair remains
advice only, never an automatic host mutation. Offline stub and vector tests
cover these paths; live qualification remains subject to the gate below. All
documented `acq`-owned commands and meaningful flags are now implemented in the
Python CLI, with the two explicit accepted gaps (`sbx`-native non-neutral kit
passthrough and `ACQ_ACTIVATE_PROJECT_ENV`) recorded in ADR-0048m gate 4. The
historical tracking issues are under Links below.

**Qualification.** PASS transcripts for both backends on `macos-arm64` and
`windows-x64` were recorded on 2026-11-07 and 2026-11-08, and for `msb` on
`linux-x86_64` on 2026-11-11 and 2026-11-12. They attest only to the tree at
their recorded revisions. Every later change to the Tier-3 surface
(`py-acq/src/acq_py/` among it) expires earlier transcripts, as ADR-0044m
requires. At upstream handoff (2026-11-12), `python3 -P -m qualification.gate check`
reports:

- seven claimed cells;
- one qualified (`msb/linux-x86_64`);
- four blocked, because the surface changed after their earlier transcripts were recorded (`macos-arm64` and `windows-x64` on both backends);
- two waived with no transcript (`sbx/linux-x86_64` and `msb/linux-aarch64`).

So the `Tier-3 release gate` stays red until the remaining six cells are
re-qualified against the release revision. `python3 -P -m qualification.gate check`
is the authority, not this note.

## Update (2026-11-10): Windows defaults to the Python implementation

ADR-0048m is accepted. On Windows, `acq.cmd` and `acq.ps1` now treat an unset
`ACQ_IMPL` as `python`, and `bash` is the explicit opt-in to the Git Bash path.
So "default behaviour is unchanged" (Consequences) and "unset or `bash`: the
existing Bash body" (Decision) now hold for the Bash `acq` script, which is
what runs on macOS and Linux and when that script is started directly from a
Git Bash prompt, but not for the Windows launchers. The `acq.ps1` resolution
described above also changed: the order is an absolute `ACQ_RUNTIME` (a
relative value is refused), the managed `py-acq\runtime\python.exe`, then a
drive-rooted or UNC `PATH` entry that passes an isolated 3.12+ probe, run with
`-P`, and it fails closed rather than starting Bash when nothing qualifies
(ADR-0048m, Decision).

## Update (2026-11-10): msb tuning and environment controls

Python now honours the Bash msb memory/CPU, pull-policy, DNS, upstream-proxy-CA
and workspace controls, plus `ACQ_DEBUG` tracing. Empty sizing values omit the
flags, invalid values retain Bash's warning/fallback rules, and CA path
preflight uses the shared refusal contract. Certificate inputs must be
nonempty readable regular files without symlink components; macOS detection
publishes successful exports atomically. The workspace override changes the
start directory, independently of mount roots and clone markers. Traces use
stderr and redact credentials. These items are removed from ADR-0048m gate 4's
accepted gaps; the remaining gaps and live qualification requirements still
apply. See `py-acq/README.md`, `py-acq/tests/test_msb_options.py` and the shared
CA refusal and invalid-tuning vectors in `test/vectors/cli/`.

## Links

- Command surface and parity gate: ADR-0038m, ADR-0048m
- Closed Python parity tracking issues: mogul/agentic-coding-quickstart#107 (credentials),
  mogul/agentic-coding-quickstart#108 (kits, bootstrap, trusted config),
  mogul/agentic-coding-quickstart#109 (state and lifecycle),
  mogul/agentic-coding-quickstart#168 (configure settings, implemented in
  mogul/agentic-coding-quickstart#188 and mogul/agentic-coding-quickstart#225)
- Re-qualification checklist: mogul/agentic-coding-quickstart#60
- Review finding this note answers: mogul/agentic-coding-quickstart#117
