#!/usr/bin/env bats
#
# 70-msb-backend.bats — bats port of scripts/test-acq.d/70-msb-backend.sh (ADR-0025)
#
# msb backend: resolution, dispatch, doctor/list/version, host-readiness +
# version-floor checks, and secret set into the acq store. Resolution/prepare
# unit checks source acq in a subshell; dispatch checks use the real CLI + $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Source acq (definitions only) + an adapter in a clean subshell and run BODY.
_with_adapter() { # ADAPTER BODY
  run bash -c '
    adapter="$1"; shift
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/${adapter}.sh"
    set +e
    eval "$1"
  ' _ "$1" "$2"
}

@test "msb: auto-detect prefers msb when both present and no sbx sandboxes" {
  rm -f "$STUBDIR/.sandbox_list"
  run bash -c '
    unset ACQ_BACKEND
    export XDG_CONFIG_HOME="'"$STUBDIR"'/noconfig"
    export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
    export PATH="'"$STUBDIR"':$PATH"
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    set +e
    _auto_detect_backend
    printf "backend=%s reason=%s\n" "$ACQ_AUTODETECT_BACKEND" "$ACQ_AUTODETECT_REASON"
  '
  assert_output --partial 'backend=msb reason=both-msb'
}

@test "msb: auto-detect falls back to sbx when only sbx is present" {
  run bash -c '
    unset ACQ_BACKEND
    export XDG_CONFIG_HOME="'"$STUBDIR"'/noconfig"
    export ACQ_TEST_INSTALLED_BACKENDS="sbx"
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    set +e
    _auto_detect_backend
    printf "backend=%s reason=%s\n" "$ACQ_AUTODETECT_BACKEND" "$ACQ_AUTODETECT_REASON"
  '
  assert_output --partial 'backend=sbx reason=sbx-only'
}

@test "msb: --backend msb resolves and loads the adapter" {
  _with_adapter msb 'unset ACQ_BACKEND; acq_resolve_backend msb; printf "%s\n" "$ACQ_RESOLVED_BACKEND"'
  assert_output --partial 'msb'
}

@test "msb: advertises SUPPORTS_SNAPSHOTS=0 (matches acq's surfaced verbs, #225)" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; printf "%s" "$ACQ_BACKEND_SUPPORTS_SNAPSHOTS"'
  assert_output '0'
}

@test "msb: ls/stop/rm/exec dispatch to the msb verbs (exec as agent user)" {
  run env ACQ_BACKEND=msb "$ACQ" ls
  assert_regex "$(cat "$CALLS")" 'msb list'
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" stop mybox
  assert_regex "$(cat "$CALLS")" 'msb stop mybox'
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" rm mybox
  assert_regex "$(cat "$CALLS")" 'msb remove --force mybox'
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" exec mybox -- echo hi
  assert_regex "$(cat "$CALLS")" 'msb exec -u agent -e HOME=/home/agent mybox -- echo hi'
}

@test "msb: version and backend list report the real msb version" {
  run env ACQ_BACKEND=msb "$ACQ" version
  assert_output --partial 'backend:     msb'
  assert_output --partial '0.6.9'
  run env "$ACQ" backend list
  assert_output --partial 'msb  v0.6.9'
  refute_output --partial 'Coming in 1.2.x'
}

@test "backend set/unset: persists a default then clears it (idempotent)" {
  run bash -c '
    export XDG_CONFIG_HOME="'"$STUBDIR"'/xdg"
    cfg="$XDG_CONFIG_HOME/acq/config.yaml"
    "'"$ACQ"'" backend set sbx >/dev/null 2>&1
    [ -f "$cfg" ] && grep -q "^backend: sbx" "$cfg" && printf "set=yes\n" || printf "set=no\n"
    "'"$ACQ"'" backend unset >/dev/null 2>&1
    [ -f "$cfg" ] && printf "file-after=present\n" || printf "file-after=gone\n"
    "'"$ACQ"'" backend unset >/dev/null 2>&1 && printf "unset-idempotent=yes\n" || printf "unset-idempotent=no\n"
  '
  assert_output --partial 'set=yes'
  assert_output --partial 'file-after=gone'
  assert_output --partial 'unset-idempotent=yes'
}

@test "msb: doctor shows the installed msb version, not the old placeholder" {
  run bash -c 'printf "n\n" | "$1" doctor' _ "$ACQ"
  assert_output --partial 'msb: installed v0.6.9'
  refute_output --partial 'coming in 1.2.x'
}

@test "msb: acq_backend_prepare is silent on a ready host" {
  _with_adapter msb 'out=$(acq_backend_prepare 2>&1); printf "%s" "$out"'
  refute_output --partial "isn't ready"
}

@test "msb: prepare auto-runs 'msb doctor --fix' (announced) and stays silent on success" {
  _with_adapter msb 'STUB_MSB_DOCTOR_FIXABLE=1 acq_backend_prepare 2>&1'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb doctor --fix'
  assert_output --partial "running 'msb doctor --fix'"
  assert_output --partial 'ACQ_SKIP_MSB_DOCTOR=1'
  refute_output --partial "isn't ready"
}

@test "msb: an unfit, unfixable host surfaces one actionable message, no hard-fail" {
  _with_adapter msb 'out=$(STUB_MSB_DOCTOR_UNFIT=1 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial "isn't ready to run microVMs"
  assert_output --partial 'agentic-coding@gsa.gov'
  assert_output --partial 'RC=0'
}

@test "msb: ACQ_SKIP_MSB_DOCTOR=1 opts out of the readiness check" {
  _with_adapter msb 'STUB_MSB_DOCTOR_UNFIT=1 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1'
  refute_output --partial "isn't ready"
  refute_regex "$(cat "$CALLS")" 'msb doctor'
}

@test "msb: version floor rejects sub-0.6.9, accepts 0.6.9" {
  _with_adapter msb 'STUB_MSB_VERSION=0.6.8 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1; printf "RC=%s\n" "$?"'
  assert_output --partial '0.6.9'
  assert_output --partial 'RC=1'
  _with_adapter msb 'out=$(STUB_MSB_VERSION=0.6.9 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); printf "%s\nRC=%s\n" "$out" "$?"'
  assert_output --partial 'RC=0'
}

@test "sbx: version floor rejects sub-0.38.0 with the v2-grammar cause, accepts 0.38.0" {
  _with_adapter sbx 'STUB_SBX_VERSION=0.37.9 acq_backend_prepare 2>&1; printf "RC=%s\n" "$?"'
  assert_output --partial '0.38.0'
  assert_output --partial 'v2 kit grammar'
  assert_output --partial 'RC=1'
  _with_adapter sbx 'out=$(STUB_SBX_VERSION=0.38.0 acq_backend_prepare 2>&1); printf "%s\nRC=%s\n" "$out" "$?"'
  assert_output --partial 'RC=0'
  refute_output --partial 'requires sbx'
}

@test "msb: the doctor calls redirect stdin so a prompting doctor cannot hang acq" {
  if ! command -v timeout >/dev/null 2>&1; then skip "no 'timeout' available"; fi
  local hang_rc=0
  { sleep 30; } | timeout 8 bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    STUB_MSB_DOCTOR_FIXABLE=1 STUB_MSB_DOCTOR_READS_STDIN=1 acq_backend_prepare
  ' >/dev/null 2>&1 || hang_rc=$?
  # 124 == timed out == the redirect regression.
  assert_not_equal "$hang_rc" "124"
}

@test "msb: secret set usai/github store in the acq store and confirm" {
  run bash -c 'ACQ_SECRET_TEST_VALUE="my-usai-key" ACQ_BACKEND=msb "$1" secret set -g usai' _ "$ACQ"
  assert_output --partial 'acq secret store'
  assert [ -f "$STUBDIR/secrets/acq.usai" ]
  run bash -c 'ACQ_SECRET_TEST_VALUE="ghp_x" ACQ_BACKEND=msb "$1" secret set -g github' _ "$ACQ"
  assert_output --partial 'acq secret store'
  assert [ -f "$STUBDIR/secrets/acq.github" ]
}
