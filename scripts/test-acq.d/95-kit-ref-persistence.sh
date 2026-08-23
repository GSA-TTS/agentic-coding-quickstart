#!/usr/bin/env bash
#
# 95-kit-ref-persistence — CLI/extra kit-ref restart durability
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 9r. CLI/extra kit-reference persistence (restart durability)
# ===========================================================================
# A sandbox created with `--kit <ref>` (ACQ_CLI_KITS) or ACQ_EXTRA_KITS must have
# those refs persisted host-side at provision and reloaded on start/restart, so a
# resume heal re-runs their startup services (the Paseo/openchamber daemon case).
# These drive the helpers directly (host-side, no exec); ACQ_PROVENANCE_DIR is
# isolated per-test by make_stubs.

# 9r1. Round-trip: write ACQ_CLI_KITS, then a shell with an EMPTY in-memory set
#      reloads exactly what was persisted.
make_stubs; load_acq
ACQ_CLI_KITS=("/kits/paseo" "git+https://example.com/x.git#dir=k")
ACQ_EXTRA_KITS=""
acq_cli_kits_write msb clibox
# Simulate a fresh `acq start` shell: nothing in memory.
ACQ_CLI_KITS=()
acq_cli_kits_load msb clibox
assert_eq "cli-kits: reload count" "2" "${#ACQ_CLI_KITS[@]}"
assert_eq "cli-kits: reload ref 0" "/kits/paseo" "${ACQ_CLI_KITS[0]}"
assert_eq "cli-kits: reload ref 1" "git+https://example.com/x.git#dir=k" "${ACQ_CLI_KITS[1]}"
cleanup_stubs

# 9r2. Empty record is authoritative: a sandbox created with NO cli/extra kits
#      writes a record whose reload CLEARS any stale in-memory refs (never
#      resurrects a ref from an unrelated invocation).
make_stubs; load_acq
ACQ_CLI_KITS=(); ACQ_EXTRA_KITS=""
acq_cli_kits_write msb emptybox
ACQ_CLI_KITS=("/stale/leftover")
acq_cli_kits_load msb emptybox
assert_eq "cli-kits: empty record clears in-memory refs" "0" "${#ACQ_CLI_KITS[@]}"
cleanup_stubs

# 9r3. Legacy sandbox (NO record at all) is a no-op: reload leaves the in-memory
#      set untouched (pre-fix behavior; nothing to resurrect, nothing to clear).
make_stubs; load_acq
ACQ_CLI_KITS=("/still/here")
acq_cli_kits_load msb legacybox     # no record written
assert_eq "cli-kits: no record leaves memory untouched" "1" "${#ACQ_CLI_KITS[@]}"
assert_eq "cli-kits: no record keeps the ref" "/still/here" "${ACQ_CLI_KITS[0]}"
cleanup_stubs

# 9r4. ACQ_EXTRA_KITS (env-supplied, whitespace-split) is persisted and reloaded
#      into ACQ_EXTRA_KITS; the record does not clobber env when it has no extras.
make_stubs; load_acq
ACQ_CLI_KITS=(); ACQ_EXTRA_KITS="/kits/a /kits/b"
acq_cli_kits_write msb extrabox
ACQ_EXTRA_KITS=""; ACQ_CLI_KITS=()
acq_cli_kits_load msb extrabox
assert_contains "cli-kits: reloads extra kit a" "$ACQ_EXTRA_KITS" "/kits/a"
assert_contains "cli-kits: reloads extra kit b" "$ACQ_EXTRA_KITS" "/kits/b"
cleanup_stubs

# 9r5. Backend keying: same name under msb vs sbx does not alias.
make_stubs; load_acq
ACQ_CLI_KITS=("/kits/msbonly"); ACQ_EXTRA_KITS=""
acq_cli_kits_write msb dupname
ACQ_CLI_KITS=("SENTINEL")
acq_cli_kits_load sbx dupname        # no sbx record -> untouched
assert_eq "cli-kits: sbx read does not see msb record" "SENTINEL" "${ACQ_CLI_KITS[0]}"
cleanup_stubs

# 9r6. Provision persists the CLI kit ref on msb (write-after-success), and a
#      subsequent heal with an EMPTY in-memory set — after a reload — re-applies
#      that kit (its staged file lands via `msb copy`). This is the end-to-end
#      #33/Paseo path: create with --kit, then resume, and the kit's startup is
#      restored WITHOUT re-passing --kit.
make_stubs; load_acq
printf 'clidurable\n' > "$STUBDIR/.msb_sandbox_list"
printf 'clidurable\n' > "$STUBDIR/.msb_running_list"
_clikit="$STUBDIR/clidurable-kit"; mkdir -p "$_clikit/files"
cat > "$_clikit/spec.yaml" <<'CLIDURSPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: clidurable-kit
displayName: CLI Durable Kit
description: a CLI-supplied kit with a staged file
files:
  - path: /home/agent/clidurable-marker
    mode: "0644"
    source: files/marker
CLIDURSPEC
printf 'CLIDURABLE_MARKER\n' > "$_clikit/files/marker"
# Provision with the kit in ACQ_CLI_KITS (as the run/create arm would set it).
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/clidur-secrets"
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/clidur-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # shellcheck disable=SC2030
  ACQ_CLI_KITS=("$_clikit")
  _acq_msb_fetch_kit() { printf '%s\n' "$_clikit"; }
  acq_backend_provision clidurable shell /tmp >/dev/null 2>&1
)
# The persisted record must exist and name the kit.
_recf=$(find "$ACQ_PROVENANCE_DIR" -name '*.kits' 2>/dev/null | head -n1)
assert_contains "cli-kits: provision persisted the --kit ref" "$(cat "$_recf" 2>/dev/null)" "$_clikit"
# Now a fresh resume shell: empty in-memory set, reload, then heal. The kit's
# file must be (re)applied during the heal.
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/clidur-secrets"
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/clidur-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # shellcheck disable=SC2031
  ACQ_CLI_KITS=()
  _acq_msb_fetch_kit() { printf '%s\n' "$_clikit"; }
  acq_cli_kits_load msb clidurable
  acq_backend_ensure_kits_applied clidurable >/dev/null 2>&1
)
_heal_log=$(cat "$CALLS")
assert_contains "cli-kits: resume heal re-applies the reloaded --kit (file copied)" \
  "$_heal_log" "clidurable:/home/agent/clidurable-marker"
cleanup_stubs

