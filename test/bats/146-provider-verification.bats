#!/usr/bin/env bats
#
# 146-provider-verification.bats — regressions for provider verification.
#
# shellcheck shell=bats

load 'helper'

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

# ---------------------------------------------------------------------------
# Blocker 1 + 2 regressions: source-state isolation and direct-invocation guard
# ---------------------------------------------------------------------------

@test "source-state regression: sourcing verify-backends with VERIFY_BACKENDS_SOURCE_ONLY=1 does not mutate caller XDG_CONFIG_HOME" {
  run bash -c '
    export XDG_CONFIG_HOME="/sentinel-xdg-before"
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    printf "%s\n" "$XDG_CONFIG_HOME"
  '
  assert_success
  assert_output "/sentinel-xdg-before"
}

@test "source-state regression: sourcing verify-backends with VERIFY_BACKENDS_SOURCE_ONLY=1 does not mutate caller ACQ_EXTRA_KITS" {
  run bash -c '
    export ACQ_EXTRA_KITS="caller-kit-a caller-kit-b"
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    printf "%s\n" "${ACQ_EXTRA_KITS:-EMPTY}"
  '
  assert_success
  assert_output "caller-kit-a caller-kit-b"
}

@test "source-state regression: sourcing verify-backends with VERIFY_BACKENDS_SOURCE_ONLY=1 does not override existing EXIT trap" {
  run bash -c '
    _trap_fired=0
    trap '"'"'_trap_fired=1'"'"' EXIT
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    # The caller trap must not have been overwritten; if it were, the sentinel
    # would not appear in the EXIT output. We test by reading current trap state.
    current_trap=$(trap -p EXIT 2>/dev/null)
    case "$current_trap" in
      *_trap_fired*) printf "EXIT trap preserved\n" ;;
      *) printf "EXIT trap LOST: %s\n" "$current_trap"; exit 1 ;;
    esac
  '
  assert_success
  assert_output "EXIT trap preserved"
}

@test "source-state regression: VERIFY_BACKENDS_SOURCE_ONLY=1 direct -h invocation fails with status 2 and actionable message" {
  run bash -c 'VERIFY_BACKENDS_SOURCE_ONLY=1 "'"$REPO_ROOT"'/scripts/verify-backends" -h'
  assert_failure 2
  assert_output --partial 'VERIFY_BACKENDS_SOURCE_ONLY=1 requires sourcing this script'
  assert_output --partial 'Usage:'
}

@test "source-state regression: VERIFY_BACKENDS_SOURCE_ONLY=1 direct invocation (no flags) fails with status 2 and actionable message" {
  run bash -c 'VERIFY_BACKENDS_SOURCE_ONLY=1 "'"$REPO_ROOT"'/scripts/verify-backends"'
  assert_failure 2
  assert_output --partial 'VERIFY_BACKENDS_SOURCE_ONLY=1 requires sourcing this script'
}

_check_reachability_harness() {
  export REPO_ROOT
  cat <<'PRELUDE'
    set -u
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    source "$REPO_ROOT/scripts/verify-backends"
    PASS=0 FAIL=0 LAST_OUT="" LAST_ARGS=""
    pass() { PASS=$((PASS + 1)); }
    fail() { FAIL=$((FAIL + 1)); printf 'FAIL=%s\n' "$1"; }
    dump() { :; }
    run_acq() { LAST_ARGS="$*"; LAST_OUT="$FAKE_OUTPUT"; return "${FAKE_RC:-0}"; }
PRELUDE
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
    sbx() {
      case "${1:-} ${2:-}" in
        "secret ls") printf "CUSTOM SECRETS\nSCOPE TARGETS ENV PLACEHOLDER\n" ;;
        "secret set-custom") printf "set-custom %s\n" "$*" >> "$CALLS" ;;
      esac
    }
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    run_acq() { return 0; }
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
    sbx() {
      case "${1:-} ${2:-}" in
        "secret ls") printf "CUSTOM SECRETS\nSCOPE TARGETS ENV PLACEHOLDER\n(global) custom.example.gov CUSTOM_API_KEY placeholder\n" ;;
        "secret set-custom") printf "unexpected seed\n" >> "$CALLS" ;;
      esac
    }
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    run_acq() { return 0; }
    _sbx_secret_has_global_row() { return 0; }
    seed_usai_secret sbx box
  '
  assert_success
  refute [ -f "$calls" ]
}

@test "provider verification: provider facts drive the models URL (offline wiring seam, not live projection validation)" {
  # This is an offline seam test: it checks that the variable assignments exist
  # in verify-backends so the wiring is correct. It does NOT prove that a real
  # provider kit returns valid values or that a live SBX/MSB run works.
  run grep -n 'USAI_MODELS_URL="\$USAI_PROVIDER_MODELS_URL"' \
    "$REPO_ROOT/scripts/verify-backends"
  assert_success
  run grep -n 'USAI_HOST="\$USAI_PROVIDER_HOST"' \
    "$REPO_ROOT/scripts/verify-backends"
  assert_success
}

@test "provider verification: the reachability input is the provider's models URL" {
  # Offline seam: the URL handed to the reachability probe comes from the
  # provider's endpoints (now shipped constants instead of a fetched facts file).
  run bash -c '
    set -u
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    ACQ="'"$REPO_ROOT"'/acq"
    ACQ_SOURCE_ONLY=1
    export ACQ_SOURCE_ONLY
    load_provider_facts
    USAI_MODELS_URL=https://models.example.gov/v2/catalog
    FAKE_OUTPUT=200 FAKE_RC=0 LAST_ARGS=
    run_acq() { LAST_ARGS="$*"; LAST_OUT="$FAKE_OUTPUT"; return "$FAKE_RC"; }
    check_usai_reachability msb box "$USAI_MODELS_URL"
    case "$LAST_ARGS" in
      *"verify https://models.example.gov/v2/catalog"*) ;;
      *) printf "unexpected projected input: %s\n" "$LAST_ARGS"; exit 1 ;;
    esac
  '
  assert_success
}

@test "provider verification: load_provider_facts yields the shipped default endpoints" {
  run bash -c '
    set -u
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    ACQ="'"$REPO_ROOT"'/acq"
    ACQ_SOURCE_ONLY=1
    export ACQ_SOURCE_ONLY
    load_provider_facts
    printf "%s\n%s\n" "$USAI_HOST" "$USAI_MODELS_URL"
  '
  assert_success
  assert_output --partial 'api.gsa.usai.gov'
  assert_output --partial 'https://api.gsa.usai.gov/api/v1/models'
}

@test "provider verification: acq source failure is actionable and does not fall through (offline seam with syntax error)" {
  # Offline seam: proves that when acq cannot be sourced (e.g. syntax error or
  # missing file), load_provider_facts surfaces a useful root-cause diagnostic
  # and returns non-zero before invoking acq_provider_facts_load_from_kit_or_fallback.
  # Uses a missing file to trigger a real source failure without a live acq process.
  run bash -c '
    set -u
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    ACQ="$STUBDIR/missing-acq"
    load_provider_facts 2>"$STUBDIR/diagnostics"; rc=$?
    cat "$STUBDIR/diagnostics"
    exit "$rc"
  '
  assert_failure
  assert_output --partial 'verify-backends: unable to source acq from'
  refute_output --partial 'acq_provider_facts_load_from_kit_or_fallback: command not found'
}

@test "provider verification: acq source failure categorizes stderr without replaying it" {
  # Offline seam: proves that source stderr selects an actionable category but
  # is never replayed verbatim, even when it contains secret-like text.
  local bad_acq="$STUBDIR/bad-acq.sh"
  printf '#!/usr/bin/env bash\necho "syntax error SENTINEL_SECRET_VALUE" >&2\nreturn 1\n' \
    > "$bad_acq"
  run bash -c '
    set -u
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    ACQ="'"$bad_acq"'"
    load_provider_facts 2>&1; rc=$?
    exit "$rc"
  '
  assert_failure
  assert_output --partial 'verify-backends: unable to source acq from'
  assert_output --partial 'cause: shell syntax error'
  refute_output --partial 'SENTINEL_SECRET_VALUE'
  refute_output --partial 'acq_provider_facts_load_from_kit_or_fallback: command not found'
}

@test "provider verification: seeded credential is required for an installed backend" {
  run bash -c '
    set -u
    REPO_ROOT="'"$REPO_ROOT"'"
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "$REPO_ROOT/scripts/verify-backends"
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
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "$REPO_ROOT/scripts/verify-backends"
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

# ---------------------------------------------------------------------------
# Identity-bound provider model check (snapshot vs rendered config vs CLI)
# ---------------------------------------------------------------------------

_identity_check() { # OUTPUT -> prints PASS/FAIL counters and verifier output
  OUT="$1" run bash -c '
    REPO_ROOT="'"$REPO_ROOT"'"
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "$REPO_ROOT/scripts/verify-backends"
    PASS=0 FAIL=0
    if verify_provider_model_identity sbx usai "$OUT"; then rc=0; else rc=$?; fi
    printf "RC=%s PASS=%s FAIL=%s\n" "$rc" "$PASS" "$FAIL"
  '
}

@test "model identity: exact match across snapshot, config and CLI passes" {
  _identity_check $'SNAPSHOT a\nSNAPSHOT b\nCONFIG b\nCONFIG a\nCLI a\nCLI b'
  assert_success
  assert_output --partial 'match the projected usai snapshot (2 models)'
  assert_line 'RC=0 PASS=1 FAIL=0'
}

@test "model identity: a stale unrelated usai model in the CLI output fails" {
  _identity_check $'SNAPSHOT a\nCONFIG a\nCLI stale-model'
  assert_success
  assert_output --partial 'CLI usai models differ'
  assert_output --partial '| stale-model'
  assert_output --partial '| a'
  assert_line 'RC=1 PASS=0 FAIL=1'
}

@test "model identity: a model missing from the rendered config fails" {
  _identity_check $'SNAPSHOT a\nSNAPSHOT b\nCONFIG a\nCLI a\nCLI b'
  assert_success
  assert_output --partial 'CONFIG usai models differ'
  assert_output --partial 'missing from CONFIG'
  assert_line 'RC=1 PASS=0 FAIL=1'
}

@test "model identity: an extra model in the rendered config fails" {
  _identity_check $'SNAPSHOT a\nCONFIG a\nCONFIG extra\nCLI a'
  assert_success
  assert_output --partial 'unexpected in CONFIG'
  assert_output --partial '| extra'
  assert_line 'RC=1 PASS=0 FAIL=1'
}

@test "model identity: an empty snapshot cannot bind identity and fails" {
  _identity_check $'CONFIG a\nCLI a'
  assert_success
  assert_output --partial 'snapshot lists no models'
  assert_line 'RC=1 PASS=0 FAIL=1'
}

@test "model identity: guest script reads snapshot, rendered config and CLI output" {
  command -v node >/dev/null || skip "node not available"
  local root="$STUBDIR/pir" home="$STUBDIR/idhome" bin="$STUBDIR/idbin"
  mkdir -p "$root/models/providers/usai" "$home/.config/opencode" "$bin"
  printf '{"schemaVersion":"acq-neutral-model-catalog/v1","providerId":"usai","models":[{"id":"m1"},{"id":"m2"}]}\n' \
    > "$root/models/providers/usai/snapshot.json"
  printf '// acq-provider-config-state: abc\n{"provider":{"usai":{"models":{"m1":{},"m2":{}}},"other":{"models":{"zz":{}}}}}\n' \
    > "$home/.config/opencode/opencode.jsonc"
  printf '#!/bin/sh\nprintf "usai/m1\\nusai/m2\\nother/zz\\n"\n' > "$bin/opencode"
  chmod +x "$bin/opencode"
  run bash -c '
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    export ACQ_PROVIDER_INPUT_ROOT="'"$root"'" HOME="'"$home"'" PATH="'"$bin"':$PATH"
    sh -c "$PROVIDER_MODEL_IDENTITY_SCRIPT" sh usai
  '
  assert_success
  assert_output $'SNAPSHOT m1\nSNAPSHOT m2\nCONFIG m1\nCONFIG m2\nCLI m1\nCLI m2'
}

@test "model identity: the live verifier no longer relies on a bare usai/ prefix grep" {
  run grep -n 'opencode models | grep -q' "$REPO_ROOT/scripts/verify-backends"
  assert_failure
}

_identity_guest_fixture() { # OPENCODE_EXIT -> sets ID_ROOT ID_HOME ID_BIN
  ID_ROOT="$STUBDIR/pir2" ID_HOME="$STUBDIR/idhome2" ID_BIN="$STUBDIR/idbin2"
  mkdir -p "$ID_ROOT/models/providers/usai" "$ID_HOME/.config/opencode" "$ID_BIN"
  printf '{"schemaVersion":"acq-neutral-model-catalog/v1","providerId":"usai","models":[{"id":"m1"},{"id":"m2"}]}\n' \
    > "$ID_ROOT/models/providers/usai/snapshot.json"
  printf '// acq-provider-config-state: abc\n{"provider":{"usai":{"models":{"m1":{},"m2":{}}}}}\n' \
    > "$ID_HOME/.config/opencode/opencode.jsonc"
  printf '#!/bin/sh\nprintf "usai/m1\\nusai/m2\\n"\nexit %s\n' "$1" > "$ID_BIN/opencode"
  chmod +x "$ID_BIN/opencode"
}

_run_identity_guest() {
  run bash -c '
    VERIFY_BACKENDS_SOURCE_ONLY=1
    export VERIFY_BACKENDS_SOURCE_ONLY
    . "'"$REPO_ROOT"'/scripts/verify-backends"
    export ACQ_PROVIDER_INPUT_ROOT="'"$ID_ROOT"'" HOME="'"$ID_HOME"'" PATH="'"$ID_BIN"':$PATH"
    sh -c "$PROVIDER_MODEL_IDENTITY_SCRIPT" sh usai 2>&1
    echo "GUEST_RC=$?"
  '
}

@test "model identity: opencode models exiting non-zero fails even when its output matches" {
  command -v node >/dev/null || skip "node not available"
  _identity_guest_fixture 7
  _run_identity_guest
  assert_success
  assert_output --partial 'opencode models failed (exit 7)'
  assert_line 'GUEST_RC=1'
  refute_output --partial 'CLI m1'
}

@test "model identity: opencode models exiting zero with matching output still passes" {
  command -v node >/dev/null || skip "node not available"
  _identity_guest_fixture 0
  _run_identity_guest
  assert_success
  assert_output --partial 'CLI m1'
  assert_output --partial 'CLI m2'
  assert_line 'GUEST_RC=0'
}
