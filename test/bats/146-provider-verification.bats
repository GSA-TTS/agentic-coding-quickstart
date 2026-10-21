#!/usr/bin/env bats
#
# 146-provider-verification.bats — regressions for provider verification.
#
# shellcheck shell=bats

load 'helper'

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

_check_reachability_harness() {
  cat <<'PRELUDE'
    set -u
    PASS=0 FAIL=0 LAST_OUT=""
    pass() { PASS=$((PASS + 1)); }
    fail() { FAIL=$((FAIL + 1)); printf 'FAIL=%s\n' "$1"; }
    dump() { :; }
    run_acq() { LAST_OUT="$FAKE_OUTPUT"; return "${FAKE_RC:-0}"; }
PRELUDE
  awk '/^check_usai_reachability\(\) \{$/,/^\}$/ { print }' \
    "$REPO_ROOT/scripts/verify-backends"
}

@test "provider verification: failed reachability command is a failure" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="noisy-error" FAKE_RC=7
    check_usai_reachability sbx box
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi reachability command failed (exit 7)'
  assert_output --partial 'PASS=0 FAIL=1'
}

@test "provider verification: non-HTTP output is not reachability success" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="noisy-error" FAKE_RC=0
    check_usai_reachability sbx box
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi host did not return an HTTP status'
  assert_output --partial 'PASS=0 FAIL=1'
}
