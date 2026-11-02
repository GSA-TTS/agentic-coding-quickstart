# Glossary

Canonical terms settled by the acq v1 wayfinding decisions. Definitions are
taken verbatim from the resolution comments where each term was decided; the
source line names the ADR(s) that introduced the term. Near-duplicates across
records were merged to the most complete definition rather than kept twice.

## Terms

- **Adversarial review** — a distinct home-agent session that did not author the change, checking it against the seven resolutions and the compatibility contract's §5 non-negotiable security guarantees; it holds no approval authority. *(Source: ADR-0045)*

- **Assertion mode** — `exact`, `contains`, or `json` (the three comparison modes; regex is deliberately excluded). *(Source: ADR-0043)*

- **Backend adapter** — the per-backend implementation that satisfies the capability contract. *(Source: ADR-0040)*

- **Backend-specific passthrough** — Announced verbatim delegation to a native backend whose arguments, output, capabilities, and status are not portable acq contracts. *(Source: ADR-0038)*

- **Blocked** — a cell where an attempted run could not reach a verdict. Recorded, never a pass. *(Source: ADR-0044)*

- **Bounded standing authorization** — the pre-approved fork-only write classes, as distinct from per-action approval. *(Source: ADR-0045)*

- **Capability** — a named unit of backend behavior with a support level (`required`/`optional`/`unsupported`). *(Source: ADR-0040)*

- **Capability contract** — the transport-neutral, declared set of capabilities and their observable results a backend must satisfy. *(Source: ADR-0040)*

- **Contract oracle** — an observable behavior the compatibility contract requires (a §1–§5 invariant or a §6 classification row), independent of implementation language. *(Source: ADR-0039)*

- **Exception** — exactly three classes: security finding, privilege escalation, fork-boundary crossing. *(Source: ADR-0045)*

- **Forward migration** — a non-destructive, idempotent, forward-only upgrade of a record to the current state-schema version. *(Source: ADR-0041)*

- **Forward migration / rollback / recreation** — three distinct recovery paths; only forward migration and (for the security exception) recreation are used here. *(Source: ADR-0041)*

- **Generation marker** — a single tree-level checkpoint recording the highest completed migration generation; detects "behind / mid-migration / crashed", never a per-record data version. *(Source: ADR-0041)*

- **Host-authoritative state** — Configuration or code that acq trusts because it is held on the host or exposed through host-enforced read-only means, never because guest files are root-owned. *(Source: ADR-0038)*

- **Human oversight** — the human's decision moments: merge approval, every exception, license acceptance, and dependency installation. *(Source: ADR-0045)*

- **Implementation readiness** — authority to build the replacement, which waits until the final specification is approved and ADR-0038 through ADR-0045 are recorded. *(Source: ADR-0045)*

- **Install channel** — a delivery mechanism for first-time placement; distinct from the **update path** by which an installed acq moves to a newer release. *(Source: ADR-0042)*

- **Live transcript** — a durable, self-describing record of one Tier-3 run; its schema is defined in ADR-0044. *(Source: ADR-0044)*

- **Managed Python runtime** — the prebuilt CPython that executes acq's Python source, distinct from the **backend** (msb/sbx) and the **validator runtime**. *(Source: ADR-0042)*

- **Migration lock** — an exclusive OS advisory lock on the state root that serializes migration and auto-releases on process death. *(Source: ADR-0041)*

- **Mixed-version** — any pairing of an acq reader/writer version against a record or sandbox produced by a different version; resolved by the fail-closed matrix above. *(Source: ADR-0041)*

- **Native-state mapping** — the translation of a backend's state and error vocabulary into the portable vocabulary. *(Source: ADR-0040)*

- **Normalisation transform** — a declared, named rewrite applied to output before comparison (enumerated in §4). *(Source: ADR-0043)*

- **Offline asset set** — the complete, enumerated release bundle an air-gapped or restricted-network host needs, whose completeness is proven by a live offline install, not a manifest. *(Source: ADR-0042)*

- **Oracle** — the contract invariant a vector proves; cited by the vector's `oracle` field so a green cell is *named* evidence (per the verification strategy's definition-of-done). *(Source: ADR-0043)*

- **Oracle isolation** — the rules that keep a test from reading or mutating the developer's real config, credentials, git identity, live sandboxes, or host files. *(Source: ADR-0039)*

- **Planning transfer** — authority to run the remaining wayfinding (spec authoring, decomposition, orchestration) now, because the compatibility/security/feasibility/verification constraints are coherent. *(Source: ADR-0045)*

- **Portable contract** — Observable behavior guaranteed across every supported backend and platform, independent of implementation language. *(Source: ADR-0038)*

- **Provisioning / installation / update / operation** — four distinct phases. Provisioning is one-time IT enablement (WHP, execution/network policy); installation is first placement of acq plus its runtime; update moves an installed acq to a newer release; operation is ordinary `acq run`. *(Source: ADR-0042)*

- **Qualification matrix** — the set of qualified cells plus the backend version floor each must be at-or-above. *(Source: ADR-0044)*

- **Qualified** — a *(platform × backend × backend-version)* cell holding a green, current Tier-3 transcript against the artifact/commit under acceptance. Supported ≠ qualified. *(Source: ADR-0044)*

- **Qualified / Unqualified / Blocked** — the three matrix states. *(Source: ADR-0044)*

- **Record** — a durable acq-hosted artifact acq reads to make decisions (`config.yaml`, a provenance record, a per-sandbox host-config entry, a secret-store envelope). Distinct from **cache** (regenerable) and **backend state** (owned by msb/sbx, never acq-migrated). *(Source: ADR-0041)*

- **Recreation** — the consent-gated teardown and re-provision of a sandbox, used only for the security exception, preserving host-held records and secrets. *(Source: ADR-0041)*

- **Retire-on-touch** — a test is retired only when the rewrite reaches the behavior it asserts, and each retirement names the contract row it contradicts. *(Source: ADR-0039)*

- **Runner** — a program that executes a vector against the CLI under test and reports pass/fail. Bash and pytest are the v1 runners; a future language writes one. *(Source: ADR-0043)*

- **Seam** — the boundary between the acq orchestrator and a backend adapter, defined by the capability contract. *(Source: ADR-0040)*

- **Semantic migration** — Preservation of supported settings, credentials, and live state across implementation/format changes without treating internal filenames or encodings as public contracts. *(Source: ADR-0038)*

- **Stale transcript** — a transcript whose recorded commit/artifact/backend-version/OS-build no longer matches what is under acceptance. *(Source: ADR-0044)*

- **State-schema version** — the integer stamped as the first field of a record, describing the encoding that wrote it. Distinct from the §2 structured-output **result-schema version** (`schema_version`); the two never share a number space. *(Source: ADR-0041)*

- **Structured result** — An explicitly requested, versioned JSON document on stdout, with human diagnostics kept on stderr. *(Source: ADR-0038)*

- **Supported platform** — an OS/arch cell the install decision commits to ship for (Windows x64, macOS arm64, macOS x86_64, Linux x86_64, Linux aarch64). Fixed; not reopened here. *(Source: ADR-0044)*

- **Test vector** — one immutable, self-describing JSON record of a single CLI invocation and its expected observable result, plus the isolation it requires. Data, never behaviour. *(Source: ADR-0039, ADR-0043)*

- **Tier 1 / Tier 2 / Tier 3** — fast subprocess gate (CI) / implementation unit+integration (CI, non-contract) / live cross-platform acceptance (release gate, PR gate for security oracles). *(Source: ADR-0039)*

- **Unqualified** — a cell deliberately not claimed (no transcript is expected or counted against it). *(Source: ADR-0044)*

- **Vector corpus** — the directory tree of vectors, one file per vector, grouped by contract section. *(Source: ADR-0043)*
