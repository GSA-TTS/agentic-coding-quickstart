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
    USAI_MODELS_URL="https://api.gsa.usai.gov/api/v1/models"
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

@test "provider verification: curl HTTP 000 is a reachability failure" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="000" FAKE_RC=0
    check_usai_reachability sbx box
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi host not reachable from guest (egress/net-rule?)'
  assert_output --partial 'PASS=0 FAIL=1'
}

@test "provider verification: non-default provider key seeds and passes presence check" {
  local calls="$STUBDIR/provider-verification-calls"
  run bash -c '
    set -u
    VERIFY_USAI_DUMMY=synthetic
    USAI_HOST=custom.example.gov
    USAI_PROVIDER_KEY_ENV=CUSTOM_API_KEY
    USAI_SEEDED_FOR=
    LAST_OUT=
    CALLS="'"$calls"'"
    run_acq() { return 0; }
    sbx() {
      case "${1:-} ${2:-}" in
        "secret ls") printf "CUSTOM SECRETS\nSCOPE TARGETS ENV PLACEHOLDER\n" ;;
        "secret set-custom") printf "set-custom %s\n" "$*" >> "$CALLS" ;;
      esac
    }
    eval "$(awk "/^seed_usai_secret\\(\\) \\{$/, /^\\}$/ { print }" \
      "'"$REPO_ROOT"'/scripts/verify-backends")"
    seed_usai_secret sbx box
  '
  assert_success
  assert [ -f "$calls" ]
  run cat "$calls"
  assert_output --partial 'set-custom'
  assert_output --partial 'CUSTOM_API_KEY'
  refute_output --partial 'USAI_API_KEY'
}

@test "provider verification: existing non-default SBX row is reused" {
  local calls="$STUBDIR/provider-verification-calls"
  run bash -c '
    set -u
    VERIFY_USAI_DUMMY=synthetic
    USAI_HOST=custom.example.gov
    USAI_PROVIDER_KEY_ENV=CUSTOM_API_KEY
    USAI_SEEDED_FOR=
    CALLS="'"$calls"'"
    run_acq() { return 0; }
    sbx() {
      case "${1:-} ${2:-}" in
        "secret ls") printf "CUSTOM SECRETS\nSCOPE TARGETS ENV PLACEHOLDER\n(global) custom.example.gov CUSTOM_API_KEY placeholder\n" ;;
        "secret set-custom") printf "unexpected seed\n" >> "$CALLS" ;;
      esac
    }
    eval "$(awk "/^seed_usai_secret\\(\\) \\{$/, /^\\}$/ { print }" \
      "'"$REPO_ROOT"'/scripts/verify-backends")"
    seed_usai_secret sbx box
  '
  assert_success
  refute [ -f "$calls" ]
}

@test "provider verification: provider facts drive the models URL" {
  run grep -n 'USAI_MODELS_URL="\$USAI_PROVIDER_MODELS_URL"' \
    "$REPO_ROOT/scripts/verify-backends"
  assert_success
  run grep -n 'USAI_HOST="\$USAI_PROVIDER_HOST"' \
    "$REPO_ROOT/scripts/verify-backends"
  assert_success
}
