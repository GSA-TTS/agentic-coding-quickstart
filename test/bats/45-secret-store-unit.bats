#!/usr/bin/env bats
#
# 45-secret-store-unit.bats — bats port of scripts/test-acq.d/45-secret-store-unit.sh
# (ADR-0025)
#
# Direct unit tests of acq.backends/secret-store.sh (store/resolve/has/delete,
# 0600 perms) and the managed-secret-rm classifier + msb live add/rotate/unbind
# paths. Helpers are sourced in isolated subshells; CLI paths use the real
# dispatch with stubbed backends and inspect $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "store: resolve global/scoped/fallback, has present/absent, 0600 perms" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/unit-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "GLOBALV\n" | acq_secret_store "$(_acq_secret_key usai)"
    printf "SBXV\n"    | acq_secret_store "$(_acq_secret_key usai mybox)"
    printf "resolve-global=%s\n" "$(acq_secret_resolve usai)"
    printf "resolve-scoped=%s\n" "$(acq_secret_resolve usai mybox)"
    printf "resolve-fallback=%s\n" "$(acq_secret_resolve usai otherbox)"
    acq_secret_has usai && printf "has-usai=yes\n" || printf "has-usai=no\n"
    acq_secret_has nope && printf "has-nope=yes\n" || printf "has-nope=no\n"
  '
  assert_line 'resolve-global=GLOBALV'
  assert_line 'resolve-scoped=SBXV'
  assert_line 'resolve-fallback=GLOBALV'
  assert_line 'has-usai=yes'
  assert_line 'has-nope=no'
  local perms
  perms=$(stat -c '%a' "$STUBDIR/unit-secrets/acq.usai" 2>/dev/null \
    || stat -f '%Lp' "$STUBDIR/unit-secrets/acq.usai" 2>/dev/null || echo '?')
  assert_equal "$perms" "600"
}

@test "delete: removes an entry, is scoped, and is idempotent" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/del-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "GV\n" | acq_secret_store "$(_acq_secret_key github)"
    printf "SV\n" | acq_secret_store "$(_acq_secret_key github mybox)"
    acq_secret_delete "$(_acq_secret_key github mybox)" && printf "del-scoped-rc=0\n"
    acq_secret_get "$(_acq_secret_key github mybox)" >/dev/null 2>&1 && printf "scoped-still=yes\n" || printf "scoped-still=no\n"
    acq_secret_get "$(_acq_secret_key github)" >/dev/null 2>&1 && printf "global-still=yes\n" || printf "global-still=no\n"
    acq_secret_delete "$(_acq_secret_key github mybox)" && printf "del-absent-rc=0\n"
    acq_secret_delete "$(_acq_secret_key github)" && printf "del-global-rc=0\n"
    acq_secret_get "$(_acq_secret_key github)" >/dev/null 2>&1 && printf "global-after=yes\n" || printf "global-after=no\n"
  '
  assert_line 'del-scoped-rc=0'
  assert_line 'scoped-still=no'
  assert_line 'global-still=yes'
  assert_line 'del-absent-rc=0'
  assert_line 'del-global-rc=0'
  assert_line 'global-after=no'
}

@test "secret rm(msb): removes the store entry and live-unbinds via msb modify --secret-rm" {
  load_acq
  printf 'rmbox\n' > "$STUBDIR/.msb_sandbox_list"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/rm-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "TOK\n" | acq_secret_store "$(_acq_secret_key github rmbox)"
    acq_secret_has github rmbox && printf "before=yes\n" || printf "before=no\n"
    ACQ_BACKEND=msb "'"$ACQ"'" secret rm rmbox github >/dev/null 2>&1
    acq_secret_has github rmbox && printf "after=yes\n" || printf "after=no\n"
  '
  assert_line 'before=yes'
  assert_line 'after=no'
  assert_regex "$(cat "$CALLS")" 'msb modify rmbox --secret-rm GITHUB_TOKEN'
}

@test "secret rm -g(msb): sweeps all running sandboxes" {
  load_acq
  printf 'boxA\nboxB\n' > "$STUBDIR/.msb_sandbox_list"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/rmg-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "K\n" | acq_secret_store "$(_acq_secret_key usai)"
    ACQ_BACKEND=msb "'"$ACQ"'" secret rm -g usai >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb modify boxA --secret-rm USAI_API_KEY'
  assert_regex "$log" 'msb modify boxB --secret-rm USAI_API_KEY'
}

@test "secret set(msb): live-rotates github into a running sandbox, value never on argv" {
  load_acq
  printf 'setbox\n' > "$STUBDIR/.msb_sandbox_list"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/set-secrets"
    export ACQ_SECRET_TEST_VALUE="ghp_SECRETVALUE"
    ACQ_BACKEND=msb "'"$ACQ"'" secret set setbox github >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb modify setbox --secret $MSB_GITHUB_SECRET_BINDING"
  refute_regex "$log" 'ghp_SECRETVALUE'
  refute_regex "$log" 'env GITHUB_TOKEN='
}

@test "secret set -g(msb): sweeps all running sandboxes (stdin-loop regression)" {
  load_acq
  printf 'sboxA\nsboxB\n' > "$STUBDIR/.msb_sandbox_list"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/setg-secrets"
    export ACQ_SECRET_TEST_VALUE="usai-key-value"
    ACQ_BACKEND=msb "'"$ACQ"'" secret set -g usai >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb modify sboxA --secret USAI_API_KEY@api.gsa.usai.gov'
  assert_regex "$log" 'msb modify sboxB --secret USAI_API_KEY@api.gsa.usai.gov'
}

@test "classify: _acq_is_managed_secret_rm distinguishes managed from passthrough" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    _acq_is_managed_secret_rm -g github       && printf "g-github=managed\n"  || printf "g-github=passthru\n"
    _acq_is_managed_secret_rm mybox usai      && printf "box-usai=managed\n"  || printf "box-usai=passthru\n"
    _acq_is_managed_secret_rm somePlaceholder && printf "lone=managed\n"      || printf "lone=passthru\n"
    _acq_is_managed_secret_rm -g unknownsvc   && printf "g-unknown=managed\n" || printf "g-unknown=passthru\n"
  '
  assert_line 'g-github=managed'
  assert_line 'box-usai=managed'
  assert_line 'lone=passthru'
  assert_line 'g-unknown=passthru'
}

@test "orphan (#300): a stored non-builtin service is managed and removable" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/orphan/secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    k=$(_acq_secret_key opencode-pic-blm-cxworks)
    printf "orphan-value" | acq_secret_store "$k" >/dev/null 2>&1
    acq_secret_get "$k" >/dev/null 2>&1 && printf "stored=yes\n"
    _acq_is_managed_secret_rm -g opencode-pic-blm-cxworks && printf "orphan=managed\n" || printf "orphan=passthru\n"
    _acq_is_managed_secret_rm -g never-stored-svc && printf "absent=managed\n" || printf "absent=passthru\n"
    acq_secret_delete "$k" >/dev/null 2>&1
    acq_secret_get "$k" >/dev/null 2>&1 && printf "after=present\n" || printf "after=gone\n"
  '
  assert_line 'stored=yes'
  assert_line 'orphan=managed'
  assert_line 'absent=passthru'
  assert_line 'after=gone'
}

@test "secret rm(msb): a lone token fails closed and never invokes 'msb secret'" {
  load_acq
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" secret rm openchamber-setup
  assert_failure
  assert_output --partial 'scope required'
  refute_regex "$(cat "$CALLS")" 'msb secret'
}
