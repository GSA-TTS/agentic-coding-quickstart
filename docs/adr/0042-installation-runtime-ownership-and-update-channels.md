---
title: "v1 installation, runtime ownership, and update channels"
status: accepted
date: 2026-11-01
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["SA-4", "SR-3", "SR-11", "CM-5", "CM-10", "SI-7"]
impact_level: moderate
ato_relevance: no
risk_treatment: mitigate
supersedes: []
---

# ADR-0042: v1 installation, runtime ownership, and update channels

## Context and Problem Statement

acq v1 replaces the Bash wrapper with inspectable Python source run under a
managed runtime. The compatibility contract preserves the installer's dry-run,
consent, checksum, user-scope/no-elevation, and failure semantics and forbids
opportunistic runtime/dependency installation during ordinary operation, but
leaves the channels, runtime supplier, signing, offline assets, update
ownership, and platform matrix to this decision. The research established that
Windows has an official embedded runtime, macOS an IT-installed framework, and
Linux a distro or prebuilt supplier, and that none of winget, a `.pkg`, or a
plain archive is interchangeable.

## Decision

The managed Python runtime is app-private and uniformly managed: a prebuilt
CPython is bundled beside readable acq source on every platform — Python.org
embedded on Windows, python-build-standalone install-only archives on macOS and
Linux — with an IT-approved base interpreter as an optional per-fleet
alternative. acq owns patching and provenance for the app-private runtime and
the dependency wheelhouse; the exact supplier and patch cadence are a separate
decision.

The supported ordinary-user install path is a plain, checksum-verified
archive/installer (`curl|sh install.sh` on POSIX, the verified
`acq-windows-x64.zip` on Windows). brew and npm are convenience channels only;
winget is not relied upon; a signed/notarized `.pkg` remains deferred.

Updates land only by user invocation: re-running the installer against the
pinned, checksum-verified release, failing closed on mismatch. There is no
automatic self-update and no new `acq update` command; ordinary operation never
reaches the network for acq's own assets.

The offline asset set is readable source, the managed runtime per
platform/arch, the exact-hash wheelhouse, launcher scripts, `SHA256SUMS`, a
provenance manifest, and GitHub artifact attestations; completeness is proven
by a live offline-install transcript, not asserted.

Provenance rests on GitHub artifact attestations, `SHA256SUMS`, and a pinned
supplier provenance manifest with retained notices. OS code signing and
notarization are deferred to a later increment.

`version` reports `acq_version` (SemVer), `source_revision` (the baked release
commit SHA), and nullable `backend`/`backend_version` plus
`kit_control_plane_ref`.

Supported: Windows x64, macOS arm64 + x86_64, Linux x86_64 + aarch64. Windows
ARM64 and musl are out of scope for v1.

## Consequences

Existing users install and update through the same no-admin, checksum-verified
front door without inheriting a user-managed Python or a network dependency at
runtime. acq carries a runtime patching and provenance obligation that did not
exist for the Bash wrapper. Unsigned artifacts in a user-writable location
cannot execute on a fleet enforcing default AppLocker/WDAC rules or Gatekeeper,
so deployment there is unproven until signing lands. Windows ARM64 and musl
users are not served by v1.

## Verification

A Tier-1 vector asserts each installer entry option and its fail-closed
checksum/dry-run/consent behavior; a Tier-3 live transcript proves a
network-blocked host installs from the enumerated offline set alone and runs a
sandbox, and that `version` reports the baked release identity on a non-git
install.
