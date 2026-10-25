#!/usr/bin/env bats
#
# 83-msb-ro-host-config-record.bats — ADR-0035 Mechanism 2: whether the :ro
# host-config mount may carry readonly kit code is a HOST-recorded create fact
# (host key ro-host-config), never the answer of a guest-executed probe. The
# record means "the create passed the :ro volume flag and the sandbox became
# exec-ready"; it does not prove the guest mount works (a disagreeing probe only
# warns, and acq never degrades to a guest copy on that disagreement).
#
# A passwordless-sudo guest controls `sh`/`test`, so a probe result must not be
# able to flip the staged-:ro path to the guest-writable copy (or the reverse).
# The stubs below answer the guest probe CONTRARY to the host record.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

_ro_kit() { # DIR
  local k="$1"; mkdir -p "$k/files"
  printf 'console.log("merge");\n' > "$k/files/merge.mjs"
  cat >"$k/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: ro-code-kit
displayName: RO Code Kit
description: trusted startup code
files:
  - path: /home/agent/cfg/merge.mjs
    mode: "0755"
    source: files/merge.mjs
    readonly: true
commands:
  - phase: startup
    user: "1000"
    command:
      - node
      - /home/agent/cfg/merge.mjs
SPEC
}

# Apply KITDIR to NAME; extra env (KEY=VAL ...) precedes "--"; set RECORD=1 to
# seed the host record first.
_apply() { # NAME KITDIR RECORD [ENV...]
  local name="$1" kit="$2" record="$3"; shift 3
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-'"$name"'"
    for kv in '"${*:-:}"'; do export "$kv" 2>/dev/null || true; done
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    [ "'"$record"'" = 1 ] && acq_host_config_write msb "'"$name"'" ro-host-config 1
    _acq_msb_apply_kit_dir "'"$name"'" "'"$kit"'" 2>&1
  '
}

@test "ro record: host record wins when the guest probe reports the mount missing" {
  local k="$STUBDIR/k1"; _ro_kit "$k"
  _apply recmissing "$k" 1 STUB_HOST_CONFIG_MOUNT=0
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'node /var/lib/acq/host/kit-files/'
  refute_regex "$log" 'msb copy .*recmissing:/home/agent/cfg/merge\.mjs'
  assert_output --partial 'does not confirm it is present'
  assert_output --partial 'does not fall back to a guest copy'
}

@test "ro record: host record wins when the guest probe reports the mount writable" {
  local k="$STUBDIR/k2"; _ro_kit "$k"
  _apply recwritable "$k" 1 STUB_HOST_CONFIG_WRITABLE=1
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'node /var/lib/acq/host/kit-files/'
  refute_regex "$log" 'msb copy .*recwritable:/home/agent/cfg/merge\.mjs'
  assert_output --partial 'finds it WRITABLE'
  assert_output --partial 'may be able to modify'
}

@test "ro record: a confirming probe is silent" {
  local k="$STUBDIR/k3"; _ro_kit "$k"
  _apply recquiet "$k" 1
  assert_success
  refute_output --partial 'host-config mount but a guest probe'
  assert_regex "$(cat "$CALLS")" 'node /var/lib/acq/host/kit-files/'
}

@test "ro record: no record takes the safe path even when the guest probe says read-only" {
  local k="$STUBDIR/k4"; _ro_kit "$k"
  _apply norecord "$k" 0
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb copy .*norecord:/home/agent/cfg/merge\.mjs'
  refute_regex "$log" '/var/lib/acq/host/kit-files'
  assert_output --partial 'has no ADR-0035 read-only host-config record'
}

@test "ro record: a value other than 1 is not a record" {
  local k="$STUBDIR/k5"; _ro_kit "$k"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-badval"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    acq_host_config_write msb badval ro-host-config 0
    _acq_msb_apply_kit_dir badval "'"$k"'" 2>&1
  '
  assert_success
  refute_regex "$(cat "$CALLS")" '/var/lib/acq/host/kit-files'
}

@test "ro record: successful create plus exec-ready records ro-host-config" {
  local k="$STUBDIR/k6"; _ro_kit "$k"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-prov"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_fetch_kit() { printf "%s\n" "'"$k"'"; }
    acq_backend_provision recprov shell /tmp >/dev/null 2>&1
  '
  local cfg; cfg=$(ls -d "$ACQ_PROVENANCE_DIR"/msb/recprov.*.config | head -n1)
  assert_equal "$(cat "$cfg/ro-host-config")" "1"
}

@test "ro record: a failed create records nothing" {
  local k="$STUBDIR/k7"; _ro_kit "$k"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-fail"
    export STUB_MSB_CREATE_FAIL_IMAGE=docker.io/docker/sandbox-templates:shell-docker
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_fetch_kit() { printf "%s\n" "'"$k"'"; }
    acq_backend_provision recfail shell /tmp >/dev/null 2>&1
  '
  assert_failure
  assert_regex "$(cat "$CALLS")" 'msb create '
  run bash -c 'ls "'"$ACQ_PROVENANCE_DIR"'"/msb/recfail.*.config/ro-host-config 2>&1'
  assert_failure
}

@test "ro record: clear_instance_state helper removes a stale record" {
  local k="$STUBDIR/k8"; _ro_kit "$k"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-stale"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    acq_host_config_write msb stalebox ro-host-config 1
    acq_host_config_clear_instance_state msb stalebox
    acq_host_config_has msb stalebox ro-host-config
  '
  assert_failure
}

# Provision-level pins: the record is written only after exec-ready, and a fresh
# provision clears stale instance state itself (not just the helper in isolation).
_prov_msb() { # NAME KITDIR [ENV...]  (runs provision with a seeded stale record)
  local name="$1" kit="$2"; shift 2
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-'"$name"'"
    export ACQ_MSB_EXEC_READY_TIMEOUT=1
    for kv in '"${*:-:}"'; do export "$kv" 2>/dev/null || true; done
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    acq_host_config_write msb "'"$name"'" ro-host-config 1
    acq_host_config_write msb "'"$name"'" install-stale 1
    _acq_msb_fetch_kit() { printf "%s\n" "'"$kit"'"; }
    acq_backend_provision "'"$name"'" shell /tmp >/dev/null 2>&1
  '
}

@test "ro record: create ok but never exec-ready leaves no ro-host-config record" {
  local k="$STUBDIR/k9"; _ro_kit "$k"
  # Replace the stub msb with one whose create succeeds and exec never does.
  cat >"$STUBDIR/msb" <<'MSBSTUB'
#!/usr/bin/env bash
{ printf 'msb'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  --version|-V) printf 'msb %s\n' "${STUB_MSB_VERSION:-0.7.7}" ;;
  create) exit 0 ;;
  exec) exit 1 ;;
  *) exit 0 ;;
esac
MSBSTUB
  chmod +x "$STUBDIR/msb"
  _prov_msb notready "$k"
  assert_failure
  assert_regex "$(cat "$CALLS")" 'msb create '
  run bash -c 'ls "'"$ACQ_PROVENANCE_DIR"'"/msb/notready.*.config/ro-host-config 2>&1'
  assert_failure
}

@test "ro record: provision itself clears stale instance state before recording" {
  local k="$STUBDIR/k10"; _ro_kit "$k"
  _prov_msb staleprov "$k"
  local cfg; cfg=$(ls -d "$ACQ_PROVENANCE_DIR"/msb/staleprov.*.config | head -n1)
  assert_equal "$(cat "$cfg/ro-host-config")" "1"
  [ ! -e "$cfg/install-stale" ]
}
