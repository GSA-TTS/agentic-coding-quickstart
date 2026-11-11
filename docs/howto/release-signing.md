---
title: "Release signing setup"
status: proposed
last_updated: "2026-11-11"
audience: "maintainers"
---

# Release signing setup

ADR-0050m adds optional signing to the release path. Releases still require
`ENABLE_RELEASES=true` and a release-please-created tag. The fork leaves signing
disabled. Set the following repository variables and Actions secrets in Settings
> Secrets and variables > Actions. Never put credential values in source or logs.

## Sigstore keyless (every platform)

Set variable `ENABLE_COSIGN_SIGNING` to `true`. No secrets are required. The publish
job uses GitHub's OIDC identity (`id-token: write`) and cosign v3.1.4 to sign
`SHA256SUMS`, publishing `SHA256SUMS.sigstore.json`. The checksums enumerate all
payload assets, including standalone validator wheelhouses, and therefore cover
their bytes transitively. Supplier digest pins protect runtime inputs; GitHub
attestations cover every published file, including the checksum file and bundle.

Verify the workflow identity and issuer, then verify the payload checksums:

```sh
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github.com/OWNER/REPO/\.github/workflows/release\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
sha256sum --check SHA256SUMS
```

Replace OWNER/REPO with the trusted repository, escaping regex metacharacters.
Use the exact expected triggering workflow ref; the release workflow runs on
`main` while its reusable builder checks out the release tag. Do not accept an
unrestricted identity regex. GitHub attestations can also be checked with
`gh attestation verify FILE --repo OWNER/REPO` for each downloaded file.

## Windows Authenticode

Set variable `ENABLE_WINDOWS_SIGNING` to `true` and create all these secrets:

| Secret | Value |
|--------|-------|
| `AZURE_SIGNING_ENDPOINT` | regional Azure Trusted Signing endpoint |
| `AZURE_SIGNING_ACCOUNT` | signing account name |
| `AZURE_CERTIFICATE_PROFILE` | certificate profile name |
| `AZURE_TENANT_ID` | Microsoft Entra tenant ID |
| `AZURE_CLIENT_ID` | application/service principal client ID |
| `AZURE_CLIENT_SECRET` | service principal client credential |

In Azure, create a Trusted Signing account, complete identity validation, and
create a Public Trust certificate profile. Register an Entra application, create
a client credential, and assign its service principal the Trusted Signing
Certificate Profile Signer role scoped to that profile. Copy the account's
regional endpoint and names into the secrets above. Rotate the client credential
before expiry. This scaffolding uses client credentials; federated OIDC can
replace them in a separately reviewed activation change.

The reusable builder requires `sign=true`, a non-PR event, the variable, and all
six nonempty secrets. It signs `install.ps1` and `acq.ps1` before packing or hashing.
`acq.cmd` cannot carry an Authenticode signature; its integrity is covered by the
archive checksum signature and attestation. Supplier Windows runtime signatures
are preserved.

**Before enabling:** check Azure/artifact-signing-action's README at SHA
`c7ab2a863ab5f9a846ddb8265964877ef296ee82`. No network was available during
implementation. Confirm `endpoint`, `signing-account-name` (or
`trusted-signing-account-name`), `certificate-profile-name`, `azure-tenant-id`,
`azure-client-id`, `azure-client-secret`, `files-folder`, `files-folder-filter`,
and `files-folder-recurse`. Confirm PowerShell support and the `ps1` filter
syntax at that revision. Keep the gate off until those checks pass.

After downloading and verifying checksums, extract the Windows archive and run:

```powershell
Get-AuthenticodeSignature ./install.ps1 | Format-List Status,SignerCertificate
Get-AuthenticodeSignature ./acq.ps1 | Format-List Status,SignerCertificate
```

Require `Valid` and the expected publisher certificate. Signing does not override
fleet AppLocker or WDAC policy.

## macOS Developer ID and notarization

Set variable `ENABLE_MACOS_SIGNING` to `true` and create all these secrets:

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_BASE64` | base64 of the exported Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | `.p12` export password |
| `MACOS_SIGNING_IDENTITY` | full Developer ID Application identity, including team ID |
| `MACOS_KEYCHAIN_PASSWORD` | random password for the temporary CI keychain |
| `APPLE_API_KEY_BASE64` | base64 of the App Store Connect API private `.p8` key |
| `APPLE_API_KEY_ID` | App Store Connect key ID |
| `APPLE_API_ISSUER` | App Store Connect issuer UUID |

Join the Apple Developer Program. Create a Developer ID Application certificate
through Certificates, Identifiers & Profiles using a CSR from Keychain Access.
Export the installed certificate together with its private key as a
password-protected `.p12`; encode it locally and transfer it directly to the
Actions secret. In App Store Connect > Users and Access > Integrations, create a
team API key authorized for notarization (Developer role or higher), download the
private key once, and record its key ID and issuer. Encode that key directly into
the secret as well. Restrict who can read or rotate these credentials.

Both macOS legs require `sign=true`, a non-PR event, the variable and every secret.
They import the certificate into a temporary keychain, codesign all regular
Mach-O runtime files (executables, dylibs and extension modules) with hardened
runtime and timestamps, and submit a zip using `notarytool submit --wait`.
Cleanup runs with `always()`, including after signing failure. A tar.gz cannot be
stapled; notarization covers the binaries online and does not promise offline
Gatekeeper acceptance. A package installer remains outside this decision.

After checking release integrity and extracting the archive, inspect and verify:

```sh
codesign -dv --verbose=4 py-acq/runtime/bin/python3
codesign --verify --strict --verbose=2 py-acq/runtime/bin/python3
spctl --assess --type execute --verbose=4 py-acq/runtime/bin/python3
```

Check the expected Developer ID team. Repeat signature verification for runtime
dylibs and extension modules. Test a quarantined download on both supported
architectures before upstream activation; notarization may require runtime
entitlements specific to the pinned supplier build.

## Rollback and activation checks

Disable the affected `ENABLE_*_SIGNING` variable to return future builds to the
unsigned path. No secrets means skipped signing, even if its variable is set.
Configured credential or signing failures fail the build; they do not silently
publish unsigned bytes. Revoke compromised credentials and rotate them through
the service console. Do not replace published signed bytes without rebuilding
checksums, signatures and attestations; prefer a new release tag. Consumers can
pin the previous verified release while credentials are repaired.

Upstream activation requires checking the pinned Azure inputs, a credentialed
Windows signing run and both macOS notarization runs. These remain activation
checks tracked here because the offline fork cannot exercise those services.
