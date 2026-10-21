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
    PASS=0 FAIL=0 LAST_OUT="" LAST_ARGS=""
    pass() { PASS=$((PASS + 1)); }
    fail() { FAIL=$((FAIL + 1)); printf 'FAIL=%s\n' "$1"; }
    dump() { :; }
    run_acq() { LAST_ARGS="$*"; LAST_OUT="$FAKE_OUTPUT"; return "${FAKE_RC:-0}"; }
PRELUDE
  awk '/^check_usai_reachability\(\) \{$/,/^\}$/ { print }' \
    "$REPO_ROOT/scripts/verify-backends"
}

@test "provider verification: failed reachability command is a failure" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="noisy-error" FAKE_RC=7
    check_usai_reachability sbx box "https://api.gsa.usai.gov/api/v1/models"
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi reachability command failed (exit 7)'
  assert_output --partial 'PASS=0 FAIL=1'
}

@test "provider verification: non-HTTP output is not reachability success" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="noisy-error" FAKE_RC=0
    check_usai_reachability sbx box "https://api.gsa.usai.gov/api/v1/models"
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi host did not return a valid HTTP status'
  assert_output --partial 'PASS=0 FAIL=1'
}

@test "provider verification: curl HTTP 000 is a reachability failure" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="000" FAKE_RC=0
    check_usai_reachability sbx box "https://api.gsa.usai.gov/api/v1/models"
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi host not reachable from guest (egress/net-rule?)'
  assert_output --partial 'PASS=0 FAIL=1'
}

@test "provider verification: shared-contract URL punctuation reaches curl unchanged" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="200" FAKE_RC=0
    url="https://api.example.gov/v1/models%2Fbeta+preview~v1?tag=a%2Bb"
    check_usai_reachability sbx box "$url"
    printf "ARGS=[%s]\n" "$LAST_ARGS"
  '
  assert_success
  assert_output --partial 'ARGS=[exec usai-reach --backend sbx exec box -- sh -c curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$1" verify https://api.example.gov/v1/models%2Fbeta+preview~v1?tag=a%2Bb]'
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
    source="$(awk "/^seed_usai_secret\(\) \{$/,/^}$/" "'"$REPO_ROOT"'/scripts/verify-backends")"
    eval "$source"
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
    _sbx_secret_has_global_row() { return 0; }
    source="$(awk "/^seed_usai_secret\(\) \{$/,/^}$/" "'"$REPO_ROOT"'/scripts/verify-backends")"
    eval "$source"
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

@test "provider verification: seeded credential is required for an installed backend" {
  run bash -c '
    set -u
    REPO_ROOT="'"$REPO_ROOT"'"
    source="$(awk "/^seed_usai_secret\(\) \{$/,/^}$/" "$REPO_ROOT/scripts/verify-backends")"
    require_source="$(awk "/^require_usai_seed\(\) \{$/,/^}$/" "$REPO_ROOT/scripts/verify-backends")"
    status_source="$(awk "/^verification_succeeded\(\) \{$/,/^}$/" "$REPO_ROOT/scripts/verify-backends")"
    eval "$source"
    eval "$require_source"
    eval "$status_source"
    VERIFY_USAI_DUMMY=synthetic
    USAI_HOST=api.example.gov
    USAI_PROVIDER_KEY_ENV=EXAMPLE_API_KEY
    USAI_SEEDED_FOR=""
    PASS=0 FAIL=0
    fail() { FAIL=$((FAIL + 1)); printf "FAIL=%s\n" "$1"; }
    unseed_usai_secret() { USAI_SEEDED_FOR=""; }
    _sbx_secret_has_global_row() { return 0; }
    sbx() { :; }
    run_acq() {
      case "$1" in
        seed-usai) printf "SEED_RC=%s\n" "${SEED_RC:-0}"; return "${SEED_RC:-0}" ;;
        usai-present) return "${PRESENT_RC:-0}" ;;
      esac
    }
    SEED_RC=7 PRESENT_RC=1
    require_usai_seed sbx box || true
    if verification_succeeded; then final_rc=0; else final_rc=$?; fi
    printf "FAILED_SEED_FAIL=%s FINAL_RC=%s\n" "$FAIL" "$final_rc"
    FAIL=0 USAI_SEEDED_FOR="" SEED_RC=0 PRESENT_RC=0
    if require_usai_seed sbx box; then success=yes; else success=no; fi
    printf "SUCCESS=%s FAIL=%s\n" "$success" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: required provider credential could not be seeded/bound'
  assert_line 'FAILED_SEED_FAIL=1 FINAL_RC=1'
  assert_line 'SUCCESS=yes FAIL=0'
}

@test "provider verification: every installed-backend seed path requires a credential" {
  run grep -n 'require_usai_seed "\$backend" "\$name"' "$REPO_ROOT/scripts/verify-backends"
  assert_success
  assert [ "${#lines[@]}" -eq 2 ]

  run grep -n 'require_usai_seed "\$backend" "\$aname"' "$REPO_ROOT/scripts/verify-backends"
  assert_success
  assert [ "${#lines[@]}" -eq 1 ]

  run grep -n 'skipped (verifier did not seed' "$REPO_ROOT/scripts/verify-backends"
  assert_failure
}

@test "provider verification: lost post-provision binding fails and cleans up" {
  run bash -c '
    REPO_ROOT="'"$REPO_ROOT"'"
    cleanup_source="$(awk "/^cleanup_failed_backend_verification\(\) \{$/,/^}$/" "$REPO_ROOT/scripts/verify-backends")"
    status_source="$(awk "/^verification_succeeded\(\) \{$/,/^}$/" "$REPO_ROOT/scripts/verify-backends")"
    eval "$cleanup_source"
    eval "$status_source"
    FAIL=1 KEEP="" CALLS=""
    unseed_usai_secret() { CALLS="${CALLS} usai:$1:$2"; }
    unseed_github_secret() { CALLS="${CALLS} github:$1:$2"; }
    _stop_ephemeral_agent() { CALLS="${CALLS} stop-agent"; }
    run_acq() { CALLS="${CALLS} $1:$2:$3:$4:$5"; }

    cleanup_failed_backend_verification msb box
    if verification_succeeded; then final_rc=0; else final_rc=$?; fi
    printf "CALLS=%s\nFINAL_RC=%s\n" "$CALLS" "$final_rc"
  '
  assert_success
  assert_output --partial 'usai:msb:box'
  assert_output --partial 'github:msb:box'
  assert_output --partial 'stop-agent'
  assert_output --partial 'rm:--backend:msb:rm:box'
  assert_line 'FINAL_RC=1'
}
