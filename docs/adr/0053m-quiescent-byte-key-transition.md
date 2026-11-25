---
title: "Refuse ambiguous legacy mutations and preserve existing state"
description: "Bounded non-ASCII refusal without automatic legacy key migration"
status: proposed
tier: 2
date: 2026-11-25
decision_makers: ["Bret Mogilefsky"]
category: security
nist_controls: ["CM-3", "CM-5", "SI-7", "SI-17"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
related_files: ["docs/adr/0041m-configuration-and-state-migration-behavior.md", "acq.backends/common.sh", "py-acq/src/acq_py/lock.py"]
---

# ADR-0053m: Fail-closed limited legacy transition

## Context and Problem Statement

Legacy Bash state paths inherit locale-dependent `tr` behavior. The Python
reader uses UTF-8 byte keys, while macOS UTF-8 Bash can produce character keys.
Normalizing old paths would lose discoverability and could split lifecycle
locks. The legacy locale/tool mappings are not bounded by the support contract.

## Decision Drivers

- Preserve legacy records, provider generations and live mount references.
- Avoid guessing aliases or renaming state while an older process can write.
- Retain useful ASCII operations and read-only diagnostics.

## Considered Options

1. Normalize and migrate keys after a quiescence scan: discarded. A paused old
   process can resume after the scan; updated code cannot enforce its cooperation.
2. Acquire all legacy aliases: deferred. Complete historical locale/tool mapping
   coverage is not established; the two observed keys are not exhaustive.
3. Refuse affected operations before writes: the user-approved limited policy.

## Decision

Updated Bash and Python refuse non-ASCII sandbox mutations before acquiring
target locks or changing backend/state/credentials. Explicit targets are checked
before migration/fetch initialization. Global credential operations first list
the complete candidate sandbox set on installed backends and validate every
name; an unavailable listing refuses rather than partially processing targets.
The listing is read-only. It deliberately includes inactive/unbound candidates
instead of guessing which binding a later fanout may use.

Import uses its parsed sandbox scope; copy uses its actual sandbox-reference
semantics. Plain port queries and provider-credential listing remain read-only.
Invalid secret syntax/value refusals retain their no-backend-access ordering.
Validated secret input is passed directly to the handler in memory, never logged
or persisted by the preflight. The lifecycle lock has a defensive refusal too.

The early target-set check is a precondition for the invocation, not a new
cross-version global lock protocol. It does not retroactively constrain old
binaries, arbitrary backend-native changes, or new targets created externally
after enumeration. Existing credential/create serialization remains unchanged.

Legacy path spelling is retained. No automatic migration, reset, alias rename,
generation relocation, or sandbox recreation is performed. Refusal recommends
a new ASCII sandbox name or explicit operator-managed maintenance, without
promising that a rename or migration is safe. Read-only diagnostics can retain
their existing unknown/missing reports; exhaustive Unicode state lookup is not
claimed. Unrestricted Unicode mutation parity is withdrawn.

## Consequences

Existing ASCII behavior remains supported. A global operation is refused if any
listed candidate name is ambiguous, even if it might not receive that service.
Operators must manage unsupported legacy state explicitly. Broad compatibility
and preserving migration remain deferred in the existing private remediation
record; this decision does not claim they are implemented.

## Verification

Command and child-process tests cover explicit and mixed global target refusal
before writes, parser forms, preserved read-only behavior, ASCII exclusion and
the retained locale-mapping witness. Mutation controls must reopen refusal or
confinement regressions. Native macOS remains hosted-CI evidence; local Bash 3.2
and modeled BSD utility behavior do not constitute native acceptance.

## References

- [State migration](0041m-configuration-and-state-migration-behavior.md).
- Apple `text_cmds` commit `592aaf8a50aa5810ee8183df20f0ba48bb23aa7e`,
  `tr/str.c` (`genrange`) and `tr/tr.c`: multibyte numeric ranges, single-byte
  collated ranges, inherited locale and wide input/output. Source inspection
  explains why a two-key alias assumption is not a complete contract.
