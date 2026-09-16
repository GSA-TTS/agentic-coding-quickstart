---
title: "Windows-Native Secret Storage for acq"
status: accepted
date: 2026-09-13
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-6", "IA-5", "SC-28"]
impact_level: low
ato_relevance: no
risk_treatment: accept
supersedes: []
---

# ADR-0028: Windows-Native Secret Storage for `acq`

## Context and Problem Statement

`acq` keeps a host-side secret store (`acq.backends/secret-store.sh`) that both
backends read at provision time. It is backend-neutral by design and currently
selects between three mechanisms:

- `keychain-macos` — the macOS keychain via `security`;
- `keychain-linux` — the Linux keyring via `secret-tool`;
- `file` — a plain 0600 file fallback under
  `$XDG_DATA_HOME/acq/secrets/` when no OS keychain is available.

On Windows the store runs under Git Bash (MSYS). `uname -s` reports `MINGW*`
(not `Darwin`), and `secret-tool` is not present, so **every Windows host lands
on the plain `file` fallback**. NTFS does not enforce POSIX permission bits:
MSYS `chmod 0600` is approximated (files still report e.g. `644`, and only the
read-only attribute is real). The result is that on Windows, secrets are stored
**unencrypted at rest with no effective file-permission protection** — a real
weakness, since `acq`'s whole threat model for the store is host-side at-rest
confidentiality (the real value never enters the guest or argv).

This is the known Phase-2 gap. ADR-0026 states the full supported Windows path
"needs a Windows-native secret backend rather than relying on the Unix file
fallback," and the Windows preview install docs mark secret storage as
preview-only until this lands. The offline suite's 0600 assertions also cannot
pass on MSYS (documented in `KNOWN_FAILURE_MODES.md` §39).

## Decision Drivers

- **No elevation.** The Windows preview posture is explicitly no-admin; managed
  GSA devices cannot be assumed to allow elevation or feature toggles.
- **Runs from Git Bash.** The store is bash; the Windows mechanism must be
  reachable from MSYS without a compiled native helper if possible.
- **At-rest protection independent of POSIX permissions.** The fix must not
  depend on `chmod` semantics that NTFS cannot honor.
- **Stable store API.** Backend selection, key format (`acq.<service>` /
  `acq.<sandbox>.<service>`), the metadata sidecar, and the never-on-argv value
  flow must not change; only the read/write mechanism behind the backend does.
- **Offline-testable.** The bats suite must be able to force/stub the Windows
  backend without touching a real credential store, mirroring how
  `keychain-macos` is stubbed today.
- **User-scoped, least privilege.** A secret should be readable only by the same
  Windows account that wrote it.

## Considered Options

### Option A — DPAPI-encrypted file (recommended)

Keep the existing file-fallback layout, but encrypt each value at rest with
Windows **DPAPI** (`[System.Security.Cryptography.ProtectedData]`) scoped to the
current user, driven by a small PowerShell wrapper.

- No admin, no service/daemon, no new compiled helper — PowerShell ships in-box
  on every supported Windows edition and is always reachable from Git Bash.
- Encrypted data is tied to the user's DPAPI master key; on managed devices the
  machine/domain policy can additionally protect that master key (TPM / domain
  credentials).
- Offline-testable: a `keychain-windows` backend the harness can force, with a
  stub `powershell.exe` or a fixture, mirroring the existing `keychain-macos`
  stubbing approach (`ACQ_SECRET_SECURITY_BIN`-style override).
- Trade-offs: values are decryptable only by the same Windows user/machine
  (matches keychain semantics); each store/read pays a PowerShell subprocess
  hop; DPAPI is user-token-scoped rather than hardware-bound unless machine
  policy enforces it.

### Option B — Windows Credential Manager

Use the native Credential Manager, which is user-scoped and encrypted by the OS.

- `cmdkey.exe` can add and delete credentials but **cannot read secret values**,
  so reaching Credential Manager from Git Bash requires a custom helper — either
  a compiled `.exe` or a PowerShell `Add-Type` P/Invoke to the Credential Manager
  API.
- More moving parts and a new binary in the release bundle, which conflicts with
  the "no extra dependency" promise and the zip-only Windows preview packaging.
- Reasonable later increment if a lean in-box helper materializes.

### Option C — Keep the plain file fallback on Windows (status quo)

- No new code, but secrets at rest with no permission protection on NTFS — fails
  the at-rest confidentiality expectation this store exists to meet. Rejected.

### Option D — msb-native secret storage

Let the `msb` runtime own Windows secrets.

- `msb`'s model is binding a value from a host environment variable at create
  time (`--secret ENV@HOST`); it does not itself store credentials that `acq`
  can call. Not applicable at the `acq` store layer today. Rejected for this
  increment.

## Decision Outcome

Adopt **Option A: DPAPI-encrypted file** as the Windows-native backend, named
`keychain-windows` to mirror `keychain-macos` / `keychain-linux` and gated to
Windows hosts (MSYS/MINGW), with the plain `file` backend remaining as the
fallback for exotic or headless cases where PowerShell is unavailable.

Because the Windows backend reuses the plaintext fallback's file path, every
value it writes is wrapped in a **versioned envelope**: a first line of
`acq-dpapi-v1` followed by the base64 ciphertext. Stored plaintext is always a
single line, so a first line equal to the header can never be a plaintext value
and the two shapes are unambiguous. That makes a backend switch safe in both
directions:

- The Windows backend reads an **unmarked** file as a legacy plaintext value
  (written by the `file` backend before this backend existed) and re-encrypts it
  in place, so an upgrade neither loses the secret nor leaves the plaintext at
  rest.
- The plaintext `file` backend sees a **marked** envelope it cannot decrypt and
  fails closed, rather than exporting the base64 blob as the secret.

The store API, key format, and metadata sidecar are unchanged; only the
read/write mechanism behind the Windows backend differs. Status is `accepted`;
the `keychain-windows` backend and its offline tests land in this stack.

## Consequences

- **Positive:** secrets on Windows are encrypted at rest; user-scoped; no admin;
  no new dependency beyond in-box PowerShell; a legacy plaintext entry is
  migrated to the envelope the first time it is read; offline-testable; and it
  unblocks the Windows preview secret-storage caveat from ADR-0026 and the
  install docs.
- **Trade-offs:** a PowerShell subprocess per secret operation; same-user-only
  decryption; reliance on the user's DPAPI master key (with machine/domain
  policy as the hardening lever); the 0600-based tests remain macOS/Linux-only
  and the Windows path no longer depends on them (the `KNOWN_FAILURE_MODES.md`
  §39 note narrows accordingly).

## Validation

- Round-trip store/read on a real Windows 11 host (value written via the backend,
  read back, never on argv or in a trace): `acq secret set -g usai` wrote DPAPI
  ciphertext (not plaintext on disk), `acq secret ls` listed the row without
  printing the value, and `acq secret rm -g usai` removed it.
- Envelope handling verified on the same host: an unmarked legacy plaintext value
  is read and re-encrypted in place, a marked envelope that DPAPI cannot decrypt
  fails closed, and the plaintext `file` backend fails closed on a marked envelope.
- Offline bats: a forceable/stubbable `keychain-windows` backend plus static
  contract tests, mirroring the `keychain-macos` stub approach.
- The full suite passes with the new `keychain-windows` coverage; the
  `KNOWN_FAILURE_MODES.md` §39 note now scopes the 0600 limitation to
  macOS/Linux only.

The cross-user negative test is **not** performed in this increment; see
Deferred-work tracking.

## Links

- [ADR-0026: Installation and Distribution](0026-installation-and-distribution.md)
  — the Windows preview path and the increment-2 secret-storage caveat.
- `acq.backends/secret-store.sh` — the store and its current backends.
- `docs/KNOWN_FAILURE_MODES.md` §39 — the 0600-on-NTFS limitation.
- GSA-TTS/agentic-coding-quickstart#461 — the Windows support epic.

### Deferred-work tracking

- Cross-user negative test: confirm a value written under one Windows account
  fails to read under another (DPAPI `CurrentUser` scope). The offline stub cannot
  exercise real DPAPI user scoping, so this needs a second account on a real
  Windows host.
- Revisit Windows Credential Manager (Option B) if a lean in-box helper becomes
  available for the release bundle.
- Optional DPAPI hardening for managed devices: document machine/domain policy
  that protects the DPAPI master key (TPM / domain credentials).
