---
title: "Provider-Neutral Adoption Validation"
description: "Offline and live procedures for validating provider-input adoption on SBX and MSB"
status: draft
tier: 2
last_updated: "2026-10-22"
audience: "developers"
keywords: ["provider", "validation", "sbx", "msb", "opencode", "offline"]
related_files: ["scripts/verify-backends", "test/bats/146-provider-verification.bats", "test/bats/147-provider-input-projection.bats", "docs/howto/acq.md"]
load_priority: "on-demand"
review_cycle: "quarterly"
---

# Provider-Neutral Adoption Validation

This procedure separates the preparatory offline checks from the live backend
validation required before provider-input adoption can be considered complete.
The Bats cases named below are **offline seam tests**. They use local fixtures
and stubs to verify internal wiring and control-flow; they are not E2E tests and
do not prove that SBX, MSB, USAi, or a fresh OpenCode process works on a real
host. Real projected parser validation requires a live backend run (see
"Live Validation Record" below).

## Offline Checks

Run the focused provider checks after initializing the Bats submodules:

```bash
./scripts/test-acq-bats test/bats/146-provider-verification.bats
./scripts/test-acq-bats test/bats/147-provider-input-projection.bats
```

Expected result: both commands complete successfully, with every Bats case
reported as `ok`. These checks prove that provider facts and projected inputs
are wired correctly in offline stubs, that URL and environment inputs flow
through the expected code paths, and that malformed facts fail closed without
invoking a backend or a network service. They do NOT prove that a real provider
kit returns valid values, that a real projected parser accepts or rejects
specific inputs, or that a live SBX or MSB run succeeds.

## Live Validation Record

Run on a sandbox-capable host (Docker for SBX, KVM/HVF for MSB), outside any
sandbox. Use a throwaway workspace created specifically for this validation; the
workspace directory must be removed after the run. Never paste or print a real
provider key; the verifier seeds a synthetic dummy value that only tests binding
and transport plumbing.

Record the observed command output, timestamp, backend version, and one of
`PASS`, `FAIL`, or `BLOCKED` for every row. `BLOCKED` is required when the
backend, virtualization, credentials, or released provider kit is unavailable
and the step cannot run. Do not use `PASS` for a row unless you observed the
actual command output.

| Check | SBX | MSB | Observed output / notes |
|---|---|---|---|
| Fresh `acq run opencode .` startup | FAIL | FAIL | 2026-10-24: backend create failed before startup. SBX treated the provider mount as a kit/primary workspace; MSB rejected an uncanonicalized host-config bind source. Fixes are consolidated in this draft; rerun required. |
| Fresh OpenCode process starts | BLOCKED | BLOCKED | Blocked by the observed create failures above; no process-start claim. |
| `acq exec NAME -- opencode models` consumes projected provider input | BLOCKED | BLOCKED | Blocked by the observed create failures above; no model-list claim. |
| Remove projected provider input and restart OpenCode | BLOCKED | BLOCKED | Record expected actionable failure or documented fallback |
| Malformed provider input is rejected before startup | BLOCKED | BLOCKED | Record exact validation error and exit status |
| `scripts/verify-backends --only <backend>` | FAIL | FAIL | SBX transcript: `tmp/provider-neutral-validation.aguo8ZPz/sbx.log`. MSB transcript: `tmp/provider-neutral-validation.ktM9ig5z/msb.log`. Both reached validated provider inputs before backend-specific create failure. |

### Preserved Live Evidence (2026-10-24)

The full host transcripts remain in the gitignored Quickstart `tmp/` directory.
The decisive output is preserved here so review does not depend on those local
files.

SBX reached provider validation, then failed before sandbox creation:

```text
provider input contract: validated 1 bundle(s)
error: primary workspace must be read/write (remove ':ro' or ':readonly')
```

MSB version `0.7.7` reached provider validation, then failed before sandbox
creation because the host-config bind source retained macOS `/var` spelling:

```text
provider input contract: validated 1 bundle(s)
error: invalid config: bind mount host path /var/folders/... goes through symlink /var;
use the resolved path /private/var/folders/... or add follow-root-symlinks
```

These are product failures, not environmental blocks. Both backend fixes are
included in this draft. Final validation remains blocked until Quickstart main
contains the trusted macOS system-alias canonicalizer used by the MSB adapter.

### Negative-Validation Procedure (malformed provider input)

This procedure proves that host-side provider validation rejects a malformed
selected kit before backend creation. It does not modify the read-only guest
projection. Run it separately for `sbx` and `msb` on a sandbox-capable host.

```bash
set -eu
VERIFY_PROVIDER_ADOPTION_ROOT=$(mktemp -d \
  "${TMPDIR:-/tmp}/acq-provider-adoption.XXXXXX")
case "$VERIFY_PROVIDER_ADOPTION_ROOT" in
  "${TMPDIR:-/tmp}"/acq-provider-adoption.*) ;;
  *) echo "unsafe validation root" >&2; exit 1 ;;
esac
cleanup_provider_adoption() {
  case "${VERIFY_PROVIDER_ADOPTION_ROOT:-}" in
    "${TMPDIR:-/tmp}"/acq-provider-adoption.*)
      chmod -R u+w "$VERIFY_PROVIDER_ADOPTION_ROOT" 2>/dev/null || true
      rm -rf -- "$VERIFY_PROVIDER_ADOPTION_ROOT"
      ;;
  esac
}
trap cleanup_provider_adoption EXIT INT TERM

VERIFY_PROVIDER_ADOPTION_WS="$VERIFY_PROVIDER_ADOPTION_ROOT/workspace"
VERIFY_PROVIDER_ADOPTION_KIT="$VERIFY_PROVIDER_ADOPTION_ROOT/malformed-kit"
mkdir -p "$VERIFY_PROVIDER_ADOPTION_WS" "$VERIFY_PROVIDER_ADOPTION_KIT"
git -C "$VERIFY_PROVIDER_ADOPTION_WS" init -q
git -C "$VERIFY_PROVIDER_ADOPTION_WS" config user.email test@example.com
git -C "$VERIFY_PROVIDER_ADOPTION_WS" config user.name "acq verify"
printf '# provider adoption validation\n' \
  > "$VERIFY_PROVIDER_ADOPTION_WS/README.md"

cat > "$VERIFY_PROVIDER_ADOPTION_KIT/spec.yaml" <<'YAML'
schemaVersion: "hybrid/v1"
kind: mixin
name: malformed-provider-validation
displayName: Malformed provider validation
description: Deliberately malformed host-side provider input
YAML
printf '{this-is-not-json\n' \
  > "$VERIFY_PROVIDER_ADOPTION_KIT/provider-input.json"

BACKEND=sbx # repeat the procedure with BACKEND=msb
SANDBOX=provider-adoption-malformed-${BACKEND}
VALIDATION_LOG="$VERIFY_PROVIDER_ADOPTION_ROOT/malformed-${BACKEND}.log"
if ./acq --backend "$BACKEND" create opencode \
    "$VERIFY_PROVIDER_ADOPTION_WS" --name "$SANDBOX" \
    --kit "$VERIFY_PROVIDER_ADOPTION_KIT" \
    >"$VALIDATION_LOG" 2>&1; then
  echo "FAIL: malformed provider input reached backend creation" >&2
  ./acq --backend "$BACKEND" rm "$SANDBOX" >/dev/null 2>&1 || true
  exit 1
fi
cat "$VALIDATION_LOG"
if grep -Fq 'provider-input.json' "$VALIDATION_LOG" \
    && grep -Eqi 'json (decode|parse|syntax)|invalid json|schema validation|does not match.*schema' \
      "$VALIDATION_LOG"; then
  echo "PASS: malformed provider input was rejected before startup"
elif grep -Eqi 'not installed|unavailable|requires python|credential|virtualization|cannot connect|CLI not found on PATH' \
    "$VALIDATION_LOG"; then
  echo "BLOCKED: backend or host prerequisite prevented validation" >&2
  exit 2
else
  echo "FAIL: create failed without the expected provider-input diagnostic" >&2
  exit 1
fi
```

Record the non-zero exit status and exact host-side validation diagnostic. If
the selected backend or its host prerequisites are unavailable, record
`BLOCKED`; do not substitute an offline seam test. The guarded `EXIT` trap
removes only the uniquely named temporary root created by this procedure.

Run the positive live verifier separately, outside any sandbox:

```bash
./scripts/verify-backends --only sbx
./scripts/verify-backends --only msb
```

For the remaining positive and removal rows, run these commands once per
backend. Use a fresh throwaway workspace and record the real sandbox name from
`acq run` output:

```bash
BACKEND=sbx # repeat with BACKEND=msb
LIVE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/acq-provider-live.XXXXXX")
case "$LIVE_ROOT" in
  "${TMPDIR:-/tmp}"/acq-provider-live.*) ;;
  *) echo "unsafe live validation root" >&2; exit 1 ;;
esac
cleanup_provider_live() {
  case "${LIVE_ROOT:-}" in
    "${TMPDIR:-/tmp}"/acq-provider-live.*)
      chmod -R u+w "$LIVE_ROOT" 2>/dev/null || true
      rm -rf -- "$LIVE_ROOT"
      ;;
  esac
}
trap cleanup_provider_live EXIT INT TERM

git -C "$LIVE_ROOT" init -q
git -C "$LIVE_ROOT" config user.email test@example.com
git -C "$LIVE_ROOT" config user.name "acq verify"
printf '# live provider adoption validation\n' > "$LIVE_ROOT/README.md"

./acq --backend "$BACKEND" run opencode "$LIVE_ROOT"
SANDBOX='<sandbox-name-from-acq-output>'
./acq --backend "$BACKEND" exec "$SANDBOX" -- opencode models
./acq --backend "$BACKEND" rm "$SANDBOX"
```

To verify provider removal, create a second fresh sandbox with an empty
authoritative provider set by overriding the default provider kit selection in
a temporary test configuration. Record the exact override used and confirm that
`opencode models` no longer lists the removed provider. If the installed `acq`
version has no supported host-side way to omit the default provider kit, record
that row as `BLOCKED`; do not edit the read-only guest projection or claim a
mocked result as live evidence.

**Outcome recording:** Update the Live Validation Record table above with the
observed output, timestamp, and backend version for each row that ran. Do not
mark any row `PASS` from the offline Bats suite. Update the table only after the
real SBX/MSB flows have run and their output has been retained in the draft PR
verification transcript.
