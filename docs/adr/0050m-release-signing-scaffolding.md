---
title: "Release signing scaffolding"
status: accepted
date: 2026-11-11
decision_makers: ["Bret Mogilefsky", "William Zujkowski"]
category: architecture
nist_controls: ["CM-5", "SI-7", "SR-11"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0050m: Release signing scaffolding

Accepted on 2026-11-11: the project lead chose secret-gated signing scaffolding
that upstream can switch on, as recorded here.

## Context and Problem Statement

ADR-0042m supplies checksums, pinned runtimes and GitHub artifact attestations.
Users need provenance stronger than checksums downloaded beside an archive.
ADR-0048m also identifies platform policy restrictions on unsigned launchers.
Upstream owns release identities; the fork must build without those credentials.

## Decision

Publish the complete reusable asset build at the release-please tag, after the
existing release gate. Keep the builder free of publishing and of mandatory
secrets. Optional signing secrets are explicitly passed, scoped to signing steps,
and never exposed to pull request builds. All signing requires a non-PR event.

Use three independent opt-in families, detailed in
[release signing](../howto/release-signing.md):

- Sigstore keyless signing requires `ENABLE_COSIGN_SIGNING=true` and GitHub OIDC.
  Sign `SHA256SUMS`, publishing its verification bundle. The manifest enumerates
  every installer, archive, wheelhouse and provenance file, so this transitively
  binds all payload bytes to the workflow identity. Supplier pins authenticate
  build inputs; GitHub attestations cover every published file, including the
  checksum file and optional bundle.
- Windows Authenticode requires `ENABLE_WINDOWS_SIGNING=true`, the reusable
  workflow's `sign` input, and all Azure signing credentials. Sign `install.ps1`
  and `acq.ps1` before assembly; `acq.cmd` cannot carry an Authenticode signature.
  Preserve supplier signatures on the embedded Windows runtime.
- macOS Developer ID signing and notarization require
  `ENABLE_MACOS_SIGNING=true`, `sign`, and all Apple credentials. Sign runtime
  Mach-O executables and dylibs with hardened runtime and timestamps, then submit
  a zip to Apple and require acceptance. Always remove the temporary keychain
  and credential files. A tar.gz cannot be stapled; notarization covers the
  binaries through Apple's online service. Signing needs macOS, so the
  Apple-silicon archive is built natively on signed release calls; pull
  requests and unsigned runs cross-build it on Linux and check it statically.

The ordering is platform sign and notarize, pack, generate provenance and
checksums with `scripts/gen-install-assets`, sign checksums, attest every file,
then upload. There is no hand-maintained checksum list. The standalone validator
wheelhouses remain because `scripts/install-provider-input-wheelhouse` consumes
them; build them in the reusable workflow rather than a duplicate release job.

## Consequences

The fork remains unsigned by default. Missing credentials skip signing cleanly;
configured signing failures block publication. Upstream owns credentials,
certificate renewal, Azure permissions and Apple service availability. Signing
establishes identity and integrity; it does not make source trustworthy or grant
AppLocker/WDAC policy exceptions. Source scripts on macOS remain protected by the
checksum signature and attestations, not Developer ID signatures.

Release-please retains the repository writes needed to create its PR and tag.
Asset building needs only contents read; publication alone needs contents write,
attestations write and id-token write among the asset jobs.

## Verification

Offline workflow tests enforce gates, ordering, full-dist attestation, pins and
permissions. Credentialed platform execution is an upstream activation check.
Before activation, check the Azure action inputs against the README at the
pinned SHA; network access was unavailable while preparing this scaffolding.
