---
title: "msb Version Policy and Sandbox-State Migration Recovery"
status: accepted
date: 2026-09-25
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["CM-2", "CM-3", "CM-6", "SA-8", "SA-11", "SI-17", "SR-3", "SR-11"]
impact_level: low
ato_relevance: no
risk_treatment: mitigate
supersedes: ["0026"]
---

# ADR-0032: msb Version Policy and Sandbox-State Migration Recovery

## Context and Problem Statement

`msb` (microsandbox) keeps its sandbox catalog in a versioned database under
`$MSB_HOME`. Opening that catalog with a newer `msb` **migrates it in place**,
and the 0.6 → 0.7 transition crossed a boundary the older line cannot read back:

```text
database schema is newer than this msb binary; applied migration
"m20260910_000001_snapshot_groups" is not in this binary's migration prefix
```

Two users reached exactly that state. The sequence that produces it needs no
mistake on the user's part — installing `msb` the documented way is enough:

1. A host has working 0.6.x sandboxes.
2. Anything installs a newer `msb` (`msb self update`, `brew upgrade`, or the
   upstream one-line installer, which always resolves to the newest release).
3. Any `msb` command then migrates the catalog forward.
4. Every 0.6.x `msb` on that host now refuses, including read-only `msb list`.

`msb` 0.7.0 through 0.7.2 had a further defect: they could reject persisted
sandbox configurations they had themselves written, so the migrated state was
not reliably usable even by the version that migrated it. Upstream fixed that in
**0.7.3** and now documents 0.7.0–0.7.2 as releases with "compatibility gaps
addressed in v0.7.3" ([upstream migration
guide](https://docs.microsandbox.dev/migrations/v0.7)).

This is a **correctness and data-durability** problem for `acq`, not a cosmetic
one: the failing commands are the ones a user runs to find out what they have
(`acq ls`), and the sandbox state at risk is the user's work.

Three separate questions had to be answered:

1. **Which `msb` versions may `acq` use?**
2. **How does `acq` install a specific `msb`,** given that neither upstream
   distribution channel can install anything but the newest release?
3. **What does `acq` do for a host that is already stranded?**

### The distribution channels cannot express a pin

Both upstream install vectors resolve the version at run time:

- `curl -fsSL https://install.microsandbox.dev | sh` takes no version argument
  and reads `releases/latest`.
- Every release additionally publishes `install.sh` as a release asset, and
  those copies are **byte-identical** — so
  `.../releases/download/v0.6.18/install.sh` *looks* like a pin and installs
  whatever is newest. An earlier revision of this work used exactly that URL and
  was wrong to.
- `superradcompany/tap/microsandbox` (Homebrew) tracks the newest release by
  construction.
- `msb self update` targets the newest release; upstream confirms it "cannot
  select a specific version."

So a version policy is unenforceable through the upstream channels. `acq` must
place the artifact itself.

### Rolling back is ordering-sensitive, and the wrong order wedges the install

`msb self downgrade` builds its rollback plan from the **running** binary's own
migration metadata. Only a binary whose metadata covers the applied set can
revert it. Upstream states this: "Run `msb self downgrade` from the newer CLI
**before** replacing it… Only the newer CLI contains the rollback steps for its
migrations."

Attempting the downgrade from the older binary does not merely fail. It records
an operation journal at
`$MSB_HOME/db/self-downgrade/<operation-id>/journal.json`, and `msb` then
refuses **every** command from **every** version until that operation reaches
`phase: complete`:

```text
error: self_downgrade_recovery_required: resume the active downgrade recorded at
       …/db/self-downgrade/<id>/journal.json
```

The refusal is deliberate and unconditional — upstream checks for it before
opening the database at all (`refuse_incomplete_self_downgrade`, called from
local-backend startup in 0.7.3). When the journal records a transition the
running binary cannot complete, the demand is unsatisfiable. Verified against
real 0.6.18 / 0.7.2 / 0.7.3 binaries: resuming with the journal's own recorded
target, with a different target, and from each of the three binaries all fail
identically, and `self downgrade` exposes no abort or clear flag.

"Try the downgrade with the `msb` I have" is the reflexive user action. It turns
a recoverable version mismatch into an apparent brick.

## Decision Drivers

- **Never silently touch user sandbox state.** A version mismatch must fail
  closed with an explanation, not migrate and hope.
- **Fail before the damage, not after.** The guard has to run before any command
  that opens the catalog.
- **Prefer the recovery that rewrites nothing.**
- **Claims about upstream behavior must be verified live**, not inferred — this
  is a claim about how three real binaries behave against real state
  (AGENTS.md "Periodic Re-Verification"; playbook §8.3).
- **A pinned install must be verifiable** — a version policy that depends on an
  unpinnable channel is not a policy.
- **Same policy on every host.** A Windows host must not accept an `msb` the
  POSIX path refuses.

## Considered Options

### Which versions to accept

1. **Floor only (`>= 0.6.9`).** Status quo before this work. Accepts the blocked
   releases, so it does not address the problem.
2. **Floor plus a blocked range, with the fixed line accepted (chosen).**
   `>= 0.6.9`, refusing `0.7.0`–`0.7.2`, accepting `0.7.3+`.
3. **Ceiling (`>= 0.6.9, < 0.7.0`).** Simpler to express, but freezes `acq` on a
   line upstream has moved off and would need another change to unblock.

### How to install a pinned version

1. **Upstream installer with a versioned asset URL.** Does not pin (above).
   Rejected on the evidence.
2. **Release bundle + the release's own published `checksums.sha256` (chosen).**
   Two files, one verification, layout matching upstream's
   (`$MSB_HOME/bin`, `$MSB_HOME/lib`, `~/.local/bin` links).
3. **Vendor the binary.** Removes the network dependency but makes this repo a
   binary distributor and a supply-chain participant. Rejected.

### How to recover a stranded host

1. **Roll back to the pinned version.** The only option before 0.7.3 existed.
   Mutates state, is ordering-sensitive, and can be refused outright when
   snapshot groups exist.
2. **Move forward to the fixed line (chosen as the default offer).** Rewrites
   nothing.
3. **Tell the user to delete `$MSB_HOME`.** Destroys their sandboxes. Never.

## Decision Outcome

### 1. Version policy

`acq` accepts `msb >= 0.6.9`, **refuses `0.7.0`–`0.7.2`**, and accepts
`0.7.3` or newer. The floor is unchanged and independently motivated
(`--net-rule` grammar, `--trust-host-cas`, `--secret`, `--net-default-egress`,
the release-build `allow@dns` parser fix; see
[ADR-0011](0011-msb-backend-and-neutral-kits.md) and
[ADR-0018](0018-msb-balanced-egress-baseline.md)).

The policy constants are duplicated in four places —
`acq.backends/msb.sh`, `install.sh`, `install.ps1`, and
`scripts/verify-msb-pin` — because three of them must run standalone
(the installers are fetched and piped; the verifier is a developer tool). Each
copy carries a comment saying the set must stay in lockstep. `test/bats/06-windows-install.bats`
pins the Windows copy against `install.sh` so that particular drift fails a test
rather than shipping.

The runtime guard is split in two so it can be applied proportionately:

- `acq_backend_check_version` — presence plus version policy only. One
  `msb --version`; no network, no host mutation.
- `acq_backend_prepare` — the above plus the `msb doctor` host-readiness probe.

Provisioning verbs (`run`, `create`) call `prepare`. Verbs that merely touch
**existing** state (`ls`, `stop`, `start`, `rm`, `exec`, …) call
`check_version` through `acq_backend_guard_version`. Before that split those
verbs reached `msb` unguarded and surfaced the raw upstream error instead of
`acq`'s explanation — which is the exact moment a stranded user most needs the
explanation. `acq.backends/sbx.sh` implements the same split for contract
parity, even though on `sbx` the two currently do the same work.

### 2. Installing a specific version

`install.sh` installs the pinned **0.6.18** when it must install or repair
`msb`, by fetching the release bundle and verifying it against that release's
published `checksums.sha256`. The `libkrunfw` filename and ABI are derived
**from the artifact**, never hardcoded — a hardcoded name is precisely the bug
found in upstream's own Homebrew formula, where `libkrunfw.so.5.2.1` had been
stale since 0.6.8 while the bundles shipped `5.6.1`. Verification and ABI
validation both complete before anything is written, so a malformed bundle
cannot leave a half-installed runtime.

Homebrew hosts get `GSA-TTS/tap/microsandbox-acq` instead, so `brew` keeps
owning what it installed. Because that formula and upstream's own
`microsandbox` formula both own `bin/msb`, the installer offers to
`brew uninstall` upstream's before installing ours rather than letting Homebrew
fail on the link conflict.

The tap also carries keg-only `microsandbox-acq@0.6.18` and
`microsandbox-acq@0.7.3`. Keg-only matters: nothing is symlinked, so versions
coexist and cannot shadow the `msb` on `PATH`. That is what makes them usable
for "run the downgrade with the binary that performed the migration" when that
binary has already been uninstalled. A **blocked** release is deliberately not
published as a formula — shipping a convenient way to install a version we tell
people to avoid would be a mixed message. `scripts/verify-msb-pin` fetches
0.7.2 by pinned URL and checksum instead.

`install.ps1` mirrors all of this. It previously had **no** `msb` version guard
at all and installed via unpinned `irm … | iex`, so a Windows host could land on
a blocked release. It now carries the same constants, a component-wise version
comparator (not `[version]`, so a build suffix cannot throw mid-install), the
same blocked/too-old/unparseable handling, and a pinned install from the
checksum-verified release bundle. It also checks for an in-use `msb.exe` before
copying, because Windows cannot overwrite a running image, and fails with an
actionable message rather than a sharing violation mid-copy. **The Windows path
remains untested on a real Windows host.**

### 3. Recovery, forward first

For a blocked `msb` that has **already** migrated the catalog, `acq` offers
`msb self update` (the fixed line) **first**, and falls back to the rollback
only if that is declined or does not land on an accepted version.

Forward is strictly safer, and that is verifiable rather than assumed. The
applied-migration lists are strict prefixes of one another — 0.6.18 has 25,
0.7.2 has 27, 0.7.3 has 28, each extending the last:

| From → to | Migrations added |
|---|---|
| 0.6.18 → 0.7.2 | `m20260829_000001_split_snapshot_identity`, `m20260910_000001_snapshot_groups` |
| 0.7.2 → 0.7.3 | `m20260922_000001_migrate_secret_config` |

So the fixed line reads an already-migrated catalog directly: no rollback plan,
no database backup dance, no `affects_user_data` step, and none of the refusals
a downgrade can hit. Upstream reached the same conclusion independently — "If
v0.7.0–v0.7.2 reports unsupported persisted sandbox configuration, upgrade to
v0.7.3 and retry first. A v0.7.2 database can upgrade directly; no downgrade to
v0.6 is needed."

`msb self update` is the right tool here *precisely because* it targets the
newest release: during this window the newest release is the fixed one. That
coupling is why the result is **re-checked** rather than assumed — if upstream
ships something newer that `acq` has not cleared, the post-update version check
catches it and falls back to the pin.

The pin remains the default for a **fresh** install, where there is no migrated
catalog and nothing to recover.

### 4. Guarding the wedge

Two guards, because the wedge is reachable by hand even though `acq` will not
create it:

- **`recover_migrated_catalog` refuses to drive a rollback with a binary older
  than the blocked line.** This is what makes the wedge unreachable *through*
  `acq`. It points the user at the keg-only formulae instead, which is also
  upstream's documented remedy ("Reinstall the release that last migrated the
  home… then run `msb self downgrade` from that newer binary").
- **`clear_stale_downgrade_journal` detects a pre-existing wedge** and offers to
  remove **only** the `self-downgrade/<operation-id>/` directory.

On that second guard, note what upstream says: *"Do not delete the catalog or
edit migration history to bypass the refusal."* That instruction is correct and
this guard does not violate it. The distinction is worth stating explicitly,
because the paths look similar:

| Upstream says do not touch | What this guard removes |
|---|---|
| the catalog database (`$MSB_HOME/db/*.db`) | — never touched |
| migration history (the applied-migrations table **inside** that database) | — never touched |
| retained downgrade backups | — never touched |
| any sandbox state, snapshots, or images | — never touched |
| | `$MSB_HOME/db/self-downgrade/<id>/` — the journal for one **incomplete operation** |

The journal is a lock, not a record of schema state: `phase != complete` means
"an operation is in flight," and upstream's own downgrade path *retires* the
journal on success rather than keeping it. Removing it therefore abandons an
operation that never began mutating the database — it does not bypass a schema
check, and the catalog it leaves behind is bit-identical. After removal, a
correctly-ordered downgrade succeeds normally (verified). The guard is
consent-gated, prints the exact path, and is deliberately incapable of removing
anything else.

Where upstream's instruction **does** bind is the case it was written for:
deleting the database, or editing the applied-migrations table, to make an older
binary accept a newer catalog. `acq` never does that and never suggests it.

### 5. Verification

`scripts/verify-msb-pin` verifies every claim above against **real msb
binaries** — mocks would prove none of it. Each check runs against a throwaway
`MSB_HOME` **and** a throwaway `HOME`; both are required, because
`msb self downgrade` writes command symlinks into `$HOME/.local/bin` and a
script isolating only `MSB_HOME` silently replaces the caller's real `msb` link
(observed during development). It creates no sandbox and boots no VM, so unlike
the other `verify-*` scripts it needs no virtualization and can run inside a
sandbox.

It covers: the unpinnable upstream installer and its byte-identical per-release
copies; the pinned bundle install; the stranding reproduction; the forward
recovery; the correctly-ordered rollback; the wrong-order wedge and its escape;
the snapshot-group downgrade refusal; and the keg-only formula layout.

## Consequences

- **Positive:** a blocked `msb` cannot silently migrate sandbox state through
  `acq`; a stranded host has a documented, state-preserving recovery; the pinned
  install is checksum-verified and derives nothing from a hardcoded filename;
  Windows is no longer a hole in the policy; the distribution claims are
  verified live rather than asserted.
- **Negative / trade-off:** the version policy is duplicated in four files, and
  only the Windows copy is drift-tested. Fresh installs land on 0.6.18 rather
  than the newest release, so a new user starts one line behind upstream — a
  deliberate trade of currency for a state format that can be rolled back.
- **Negative:** `install.sh` executes no upstream code, but it does download
  release artifacts from GitHub; the checksum is fetched from the same release,
  so this verifies integrity against the published manifest, not provenance.
- **Scope:** the blocked range is a fixed historical window. When `acq` moves
  its floor to `0.7.3` or newer, the range, the pin, the keg-only formulae, and
  `verify-msb-pin`'s blocked-version checks all become dead weight and should be
  removed together.
- **Windows remains a preview path** and this ADR's Windows claims are
  code-review-level only.

## Links

- [Upstream: Migrating from v0.6 to v0.7](https://docs.microsandbox.dev/migrations/v0.7)
  — upstream's account of the migration, the forward-first recommendation, the
  downgrade ordering requirement, and the snapshot-group refusal.
- [ADR-0011: msb backend and neutral kits](0011-msb-backend-and-neutral-kits.md)
  — the backend adapter contract these guards live in.
- [ADR-0018: msb balanced egress baseline](0018-msb-balanced-egress-baseline.md)
  — the `allow@dns` macro behind the independent 0.6.9 floor.
- [ADR-0026: installation and distribution](0026-installation-and-distribution.md)
  — the installer this version policy was added to.
- `docs/KNOWN_FAILURE_MODES.md` §35 — the user-facing symptoms and recovery.
- `docs/BACKEND_GUIDE.md` (msb backend) — the supported version table.
- `scripts/verify-msb-pin` — the live verification of every behavioral claim here.
