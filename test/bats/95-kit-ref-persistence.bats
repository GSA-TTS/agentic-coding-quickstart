#!/usr/bin/env bats
#
# 95-kit-ref-persistence.bats — bats port of
# scripts/test-acq.d/95-kit-ref-persistence.sh (ADR-0025)
#
# CLI/extra kit-reference persistence (restart durability): a sandbox created
# with `--kit <ref>` (ACQ_CLI_KITS) or ACQ_EXTRA_KITS must persist those refs at
# provision and reload them on start/restart so a resume heal re-runs their
# startup services. These call the helpers in-process; per-@test subshell
# isolation keeps ACQ_PROVENANCE_DIR (set by make_stubs) private per test.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "cli-kits: round-trip write then reload into an empty in-memory set" {
  load_acq
  ACQ_CLI_KITS=("/kits/paseo" "git+https://example.com/x.git#dir=k")
  ACQ_EXTRA_KITS=""
  acq_cli_kits_write msb clibox
  ACQ_CLI_KITS=()
  acq_cli_kits_load msb clibox
  assert_equal "${#ACQ_CLI_KITS[@]}" "2"
  assert_equal "${ACQ_CLI_KITS[0]}" "/kits/paseo"
  assert_equal "${ACQ_CLI_KITS[1]}" "git+https://example.com/x.git#dir=k"
}

@test "cli-kits: an empty record is authoritative and clears stale refs" {
  load_acq
  ACQ_CLI_KITS=(); ACQ_EXTRA_KITS=""
  acq_cli_kits_write msb emptybox
  ACQ_CLI_KITS=("/stale/leftover")
  acq_cli_kits_load msb emptybox
  assert_equal "${#ACQ_CLI_KITS[@]}" "0"
}

@test "cli-kits: no record at all is a no-op (in-memory set untouched)" {
  load_acq
  ACQ_CLI_KITS=("/still/here")
  acq_cli_kits_load msb legacybox
  assert_equal "${#ACQ_CLI_KITS[@]}" "1"
  assert_equal "${ACQ_CLI_KITS[0]}" "/still/here"
}

@test "cli-kits: ACQ_EXTRA_KITS is persisted and reloaded" {
  load_acq
  ACQ_CLI_KITS=(); ACQ_EXTRA_KITS="/kits/a /kits/b"
  acq_cli_kits_write msb extrabox
  ACQ_EXTRA_KITS=""; ACQ_CLI_KITS=()
  acq_cli_kits_load msb extrabox
  assert_regex "$ACQ_EXTRA_KITS" '/kits/a'
  assert_regex "$ACQ_EXTRA_KITS" '/kits/b'
}

@test "cli-kits: backend keying — an sbx read does not see an msb record" {
  load_acq
  ACQ_CLI_KITS=("/kits/msbonly"); ACQ_EXTRA_KITS=""
  acq_cli_kits_write msb dupname
  ACQ_CLI_KITS=("SENTINEL")
  acq_cli_kits_load sbx dupname
  assert_equal "${ACQ_CLI_KITS[0]}" "SENTINEL"
}

# End-to-end (#33 / Paseo): provision with --kit persists the ref; a later resume
# with an EMPTY in-memory set reloads it and the heal re-applies the kit's file.
@test "cli-kits: provision persists --kit and resume heal re-applies it" {
  load_acq
  printf 'clidurable\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'clidurable\n' > "$STUBDIR/.msb_running_list"
  local clikit="$STUBDIR/clidurable-kit"
  mkdir -p "$clikit/files"
  cat > "$clikit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: clidurable-kit
displayName: CLI Durable Kit
description: a CLI-supplied kit with a staged file
files:
  - path: /home/agent/clidurable-marker
    mode: "0644"
    source: files/marker
SPEC
  printf 'CLIDURABLE_MARKER\n' > "$clikit/files/marker"

  # Provision with the kit in ACQ_CLI_KITS (as the run/create arm sets it).
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/clidur-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/clidur-stage"
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    ACQ_CLI_KITS=("$clikit")
    _acq_msb_fetch_kit() { printf '%s\n' "$clikit"; }
    acq_backend_provision clidurable shell /tmp >/dev/null 2>&1 )

  local recf
  recf=$(find "$ACQ_PROVENANCE_DIR" -name '*.kits' 2>/dev/null | head -n1)
  run cat "$recf"
  assert_output --partial "$clikit"

  # Fresh resume shell: empty in-memory set, reload, then heal re-applies the file.
  : > "$CALLS"
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/clidur-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/clidur-stage"
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    ACQ_CLI_KITS=()
    _acq_msb_fetch_kit() { printf '%s\n' "$clikit"; }
    acq_cli_kits_load msb clidurable
    acq_backend_ensure_kits_applied clidurable >/dev/null 2>&1 )
  run cat "$CALLS"
  assert_output --partial 'clidurable:/home/agent/clidurable-marker'
}
