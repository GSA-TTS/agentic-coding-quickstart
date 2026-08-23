#!/usr/bin/env bats
#
# 77-usai-rotate.bats — bats port of scripts/test-acq.d/77-usai-rotate.sh
# (ADR-0012 / ADR-0025)
#
# acq usai-rotate-api-key must dispatch through the resolved backend's
# acq_backend_rotate_key — NOT a hardcoded sbx script. On sbx it preserves the
# placeholder via `sbx secret set-custom`; on msb it issues NO sbx command.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "rotate(sbx): dispatches to sbx secret set-custom + validates in a throwaway sandbox" {
  printf 'placeholder-token USAI_API_KEY {}\n' > "$STUBDIR/sbx_ls"
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_BACKEND=sbx "$ACQ" usai-rotate-api-key
  local log
  log=$(cat "$CALLS")
  assert_regex "$log" 'sbx secret set-custom --host api\.gsa\.usai\.gov --env USAI_API_KEY'
  assert_regex "$log" 'sbx create --name acq-keycheck-'
}

@test "rotate(msb): issues NO sbx command, stores the key, re-feeds via msb modify" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  run env ACQ_SECRET_TEST_VALUE="new-usai-key" ACQ_BACKEND=msb "$ACQ" usai-rotate-api-key
  local log
  log=$(cat "$CALLS")
  refute_regex "$log" 'sbx '
  assert_regex "$log" 'msb modify'
  assert [ -f "$STUBDIR/secrets/acq.usai" ]
}

@test "rotate: both adapters define the acq_backend_rotate_key contract" {
  load_acq
  run command -v acq_backend_rotate_key
  assert_success
  run bash -c '. "'"${REPO_ROOT}"'/acq.backends/msb.sh"; command -v acq_backend_rotate_key'
  assert_success
}

@test "rotate: scripts/rotate-apikey is a thin shim with no direct sbx call" {
  run grep -qE '(^|[^[:alnum:]_])sbx[[:space:]]+secret' "$REPO_ROOT/scripts/rotate-apikey"
  assert_failure
}
