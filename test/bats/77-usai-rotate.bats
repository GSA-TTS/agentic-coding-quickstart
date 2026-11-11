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
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY placeholder-token ****\n' > "$STUBDIR/sbx_ls"
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_BACKEND=sbx "$ACQ" usai-rotate-api-key
  local log
  log=$(cat "$CALLS")
  assert_regex "$log" 'sbx secret set-custom --host api\.gsa\.usai\.gov --env USAI_API_KEY'
  assert_regex "$log" 'sbx create --name acq-keycheck-'
}

@test "rotate(sbx): provider facts key env drives placeholder update" {
  load_acq
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov KIT_API_KEY ph-kit ****\n' > "$STUBDIR/sbx_ls"
  export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
  export USAI_PROVIDER_KEY_ENV=KIT_API_KEY
  export ACQ_PROPAGATING_SECRET=1
  run acq_backend_rotate_key

  local log
  log=$(cat "$CALLS")
  assert_success
  assert_regex "$log" 'sbx secret set-custom --host api\.gsa\.usai\.gov --env KIT_API_KEY --placeholder ph-kit'
}

@test "rotate(msb): stores the key and re-feeds via msb modify" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  cp "$STUBDIR/.msb_sandbox_list" "$STUBDIR/.msb_running_list"
  run env ACQ_SECRET_TEST_VALUE="new-usai-key" ACQ_BACKEND=msb "$ACQ" usai-rotate-api-key
  local log
  log=$(cat "$CALLS")
  refute_regex "$log" 'sbx secret set-custom'
  assert_regex "$log" 'msb modify'
  assert [ -f "$STUBDIR/secrets/acq.usai" ]
}

@test "rotate(msb): also propagates to existing sbx sandboxes" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  cp "$STUBDIR/.msb_sandbox_list" "$STUBDIR/.msb_running_list"
  printf 'legacy-sbx\n' > "$STUBDIR/.sandbox_list"
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY ph-existing ****\n' > "$STUBDIR/sbx_ls"
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_SECRET_TEST_VALUE="new-usai-key" ACQ_BACKEND=msb "$ACQ" usai-rotate-api-key
  local log
  log=$(cat "$CALLS")
  assert_success
  assert_regex "$log" 'msb modify runningbox --secret USAI_API_KEY@api\.gsa\.usai\.gov'
  assert_regex "$log" 'sbx secret set-custom --host api\.gsa\.usai\.gov --env USAI_API_KEY --placeholder ph-existing'
  assert_output --partial "propagating 'usai' to existing sbx sandbox"
}

@test "rotate(sbx): propagation guard does not replay stale store value to msb" {
  load_acq
  mkdir -p "$STUBDIR/secrets"
  printf 'OLD-STALE-KEY\n' > "$STUBDIR/secrets/acq.usai"
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  # shellcheck disable=SC2034  # read by acq_propagate_usai_rotation
  ACQ_RESOLVED_BACKEND=sbx
  run acq_propagate_usai_rotation
  local log
  log=$(cat "$CALLS")
  assert_success
  assert_output --partial "not propagating sbx USAi rotation to msb"
  refute_regex "$log" 'msb modify runningbox --secret USAI_API_KEY@api\.gsa\.usai\.gov'
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

@test "rotate(sbx): duplicate global USAi entries are refused, not consolidated" {
  printf 'CUSTOM SECRETS\nSCOPE TARGETS ENV PLACEHOLDER SECRET\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupa ****\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupb ****\n' > "$STUBDIR/sbx_ls"
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_BACKEND=sbx "$ACQ" usai-rotate-api-key
  assert_failure
  assert_output --partial 'sbx holds 2 custom secrets for USAI_API_KEY on api.gsa.usai.gov in the global scope'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupa -f'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupb -f'
  assert_output --partial 'a running sandbox may hold one of these placeholders'
  assert_output --partial 'then re-run: acq usai-rotate-api-key'
  refute_output --partial 'consolidating'
  refute_regex "$(cat "$CALLS")" 'sbx secret (rm|set-custom)|sbx create'
}

@test "rotate(sbx): a same-env entry on another host or in a sandbox is not a duplicate" {
  load_acq
  printf 'CUSTOM SECRETS\n(global) usai.alt.example.gov USAI_API_KEY ph-alt ****\nsomebox api.gsa.usai.gov USAI_API_KEY ph-box ****\n(global) api.gsa.usai.gov USAI_API_KEY ph-main ****\n' > "$STUBDIR/sbx_ls"
  export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
  export ACQ_PROPAGATING_SECRET=1
  run acq_backend_rotate_key
  assert_success
  assert_regex "$(cat "$CALLS")" 'sbx secret set-custom --host api\.gsa\.usai\.gov --env USAI_API_KEY --placeholder ph-main'
  refute_regex "$(cat "$CALLS")" 'sbx secret rm'
}

@test "rotate(msb): propagation to sbx refuses duplicate global USAi entries" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'legacy-sbx\n' > "$STUBDIR/.sandbox_list"
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupa ****\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupb ****\n' > "$STUBDIR/sbx_ls"
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_SECRET_TEST_VALUE="new-usai-key" ACQ_BACKEND=msb "$ACQ" usai-rotate-api-key
  assert_failure
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupa -f'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupb -f'
  refute_regex "$(cat "$CALLS")" 'sbx secret (rm|set-custom)'
}
