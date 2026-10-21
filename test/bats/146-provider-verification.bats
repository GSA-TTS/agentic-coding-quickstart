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
    _sbx_secret_has_global_row() {
      local env_var="$1"
      [ -n "$env_var" ] || { echo "_sbx_secret_has_global_row: env_var required"; return 1; }
      sbx secret ls 2>/dev/null | awk -v env="$env_var" '"'"'
        $1 == "(global)" {
          for (i = 2; i <= NF; i++) if ($i == env) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
      '"'"'
    }
    seed_usai_secret() {
      local backend="$1" sandbox="$2"
      USAI_SEEDED_FOR=""
      printf '"'"'%s\n'"'"' "$VERIFY_USAI_DUMMY" | run_acq "seed-usai" --backend "$backend" secret set -g usai >/dev/null 2>&1 || true
      if [ "$backend" = "sbx" ]; then
        if ! _sbx_secret_has_global_row "$USAI_PROVIDER_KEY_ENV"; then
          sbx secret set-custom --host "$USAI_HOST" --env "$USAI_PROVIDER_KEY_ENV" \
            --value "$VERIFY_USAI_DUMMY" >/dev/null 2>&1 || true
        fi
      fi
      if run_acq "usai-present" --backend "$backend" secret has -g usai; then
        USAI_SEEDED_FOR="$sandbox"
      fi
    }
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
    _sbx_secret_has_global_row() {
      local env_var="$1"
      [ -n "$env_var" ] || { echo "_sbx_secret_has_global_row: env_var required"; return 1; }
      sbx secret ls 2>/dev/null | awk -v env="$env_var" '"'"'
        $1 == "(global)" {
          for (i = 2; i <= NF; i++) if ($i == env) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
      '"'"'
    }
    seed_usai_secret() {
      local backend="$1" sandbox="$2"
      USAI_SEEDED_FOR=""
      printf '"'"'%s\n'"'"' "$VERIFY_USAI_DUMMY" | run_acq "seed-usai" --backend "$backend" secret set -g usai >/dev/null 2>&1 || true
      if [ "$backend" = "sbx" ]; then
        if ! _sbx_secret_has_global_row "$USAI_PROVIDER_KEY_ENV"; then
          sbx secret set-custom --host "$USAI_HOST" --env "$USAI_PROVIDER_KEY_ENV" \
            --value "$VERIFY_USAI_DUMMY" >/dev/null 2>&1 || true
        fi
      fi
      if run_acq "usai-present" --backend "$backend" secret has -g usai; then
        USAI_SEEDED_FOR="$sandbox"
      fi
    }
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

@test "provider verification: shell metacharacters in URL are rejected" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="200" FAKE_RC=0
    check_usai_reachability sbx box "https://api.gsa.usai.gov/api/v1/models\"; whoami; echo \""
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi URL validation failed'
  assert_output --partial 'PASS=0 FAIL=1'
  refute_output --partial 'root'
}

@test "provider verification: URL with command substitution is rejected" {
  run bash -c "$(_check_reachability_harness)"'
    FAKE_OUTPUT="200" FAKE_RC=0
    check_usai_reachability sbx box "https://api.gsa.usai.gov/api/v1/models/\$(whoami)"
    printf "PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  '
  assert_success
  assert_output --partial 'FAIL=sbx: USAi URL validation failed'
  assert_output --partial 'PASS=0 FAIL=1'
}

@test "provider verification: production-equivalent URL validation works correctly" {
  run bash -c '
    REPO_ROOT="'"$REPO_ROOT"'"
    source="$(sed -n "/^_check_reachability_production_equivalent/,/^}/p" "$REPO_ROOT/scripts/verify-backends")"
    eval "$source"
    # Valid HTTPS URLs pass
    _check_reachability_production_equivalent sbx "https://api.example.com/v1/models" && echo "pass1=yes" || echo "pass1=no"
    # URLs with shell metacharacters fail
    _check_reachability_production_equivalent sbx "https://api.example.com/v1/models\"; whoami; echo" && echo "fail1=yes" || echo "fail1=no"
    # Command substitution fails
    _check_reachability_production_equivalent sbx "https://api.example.com/v1/models/\$(whoami)" && echo "fail2=yes" || echo "fail2=no"
  '
  assert_success
  assert_line 'pass1=yes'
  assert_line 'fail1=no'
  assert_line 'fail2=no'
}
