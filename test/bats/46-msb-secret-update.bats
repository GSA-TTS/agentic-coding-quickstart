#!/usr/bin/env bats
load helper
setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

@test "MSB rejected update fails visibly while preserving the stored key" {
  printf 'boxA\nboxB\n' > "$STUBDIR/.msb_sandbox_list"
  run bash -c 'printf "synthetic-key\n" | STUB_MSB_MODIFY_FAIL=boxA ACQ_BACKEND=msb "$1" secret set -g usai' _ "$ACQ"
  assert_failure
  assert_output --partial "failed to apply 'usai' to 'boxA'"
  assert_output --partial 'secret set boxA usai --restart'
  refute_output --partial 'synthetic-key'
  assert [ -s "$STUBDIR/secrets/acq.usai" ]
  assert_regex "$(cat "$CALLS")" 'msb modify boxB --secret USAI_API_KEY@api.gsa.usai.gov'
  refute_output --partial 'Applied to'
}

@test "MSB explicit scoped restart supplies other stored credentials" {
  printf 'restartbox\n' > "$STUBDIR/.msb_sandbox_list"
  mkdir -p "$STUBDIR/secrets"
  printf 'synthetic-github' > "$STUBDIR/secrets/acq.restartbox.github"
  run bash -c 'printf "synthetic-key\n" | STUB_MSB_MODIFY_RESTART_REQUIRED=1 ACQ_BACKEND=msb "$1" secret set restartbox usai --restart' _ "$ACQ"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb modify restartbox --secret USAI_API_KEY@api.gsa.usai.gov --restart'
  refute_regex "$(cat "$CALLS")" 'synthetic-key|synthetic-github'
}

@test "MSB propagation fails when sandbox discovery fails" {
  run bash -c '
    . "$1/acq.backends/msb.sh"
    _acq_msb_cli() { return 7; }
    acq_backend_secret_propagate -g usai
  ' _ "$REPO_ROOT"
  assert_failure
  assert_output --partial 'cannot list sandboxes'
  run bash -c '
    . "$1/acq.backends/msb.sh"
    _acq_msb_cli() { return 7; }
    acq_backend_secret_propagate demo usai
  ' _ "$REPO_ROOT"
  assert_failure
}

@test "MSB explicit restart restores startup after clearing transient credentials" {
  run bash -c '
    set -euo pipefail
    . "$1/acq.backends/msb.sh"
    _acq_msb_service_binding() { printf "TEST_KEY\ttest.invalid\n"; }
    acq_secret_resolve() { printf synthetic; }
    _acq_msb_bind_secrets_into() { export OTHER_KEY=synthetic; names+=(OTHER_KEY); }
    _acq_msb_cli() { return 0; }
    _acq_msb_wait_for_exec_ready() { [ "${TEST_KEY+x}${OTHER_KEY+x}" = "" ] && echo ready; }
    _acq_msb_start_ssh_agent_bridge() { echo bridge; }
    acq_cli_kits_load() { echo refs; }
    acq_backend_ensure_kits_applied() { echo kits; }
    _ACQ_MSB_SECRET_RESTART=1
    _acq_msb_secret_apply_one usai box
    _ACQ_MSB_SECRET_RESTART=0
    _acq_msb_secret_restore_startup() { return 9; }
    _acq_msb_secret_apply_one usai box
    _ACQ_MSB_SECRET_RESTART=1
    if _acq_msb_secret_apply_one usai box; then exit 1; fi
  ' _ "$REPO_ROOT"
  assert_success
}

@test "MSB restart recovery preserves the fail-soft bridge warning" {
  run bash -c '
    set -euo pipefail
    . "$1/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_ssh_agent_link_refresh() { return 0; }
    _acq_msb_cli() { return 9; }
    _acq_msb_wait_for_exec_ready() { return 0; }
    acq_cli_kits_load() { return 0; }
    acq_backend_ensure_kits_applied() { return 0; }
    _acq_msb_secret_restore_startup box
  ' _ "$REPO_ROOT"
  assert_success
  assert_output --partial "failed to start the ssh-agent bridge in 'box'"
}

@test "MSB global restart is rejected before storing or modifying anything" {
  run bash -c 'printf "synthetic-key\n" | ACQ_BACKEND=msb "$1" secret set -g usai --restart' _ "$ACQ"
  assert_failure
  assert_output --partial '--restart requires a named sandbox'
  assert [ ! -e "$STUBDIR/secrets/acq.usai" ]
  refute_regex "$(cat "$CALLS")" 'msb modify'
}

@test "MSB missing endpoint values never become restart authorization" {
  local flag
  for flag in --host --env; do
    run bash -c 'printf "synthetic-key\n" | ACQ_BACKEND=msb "$1" secret set box usai "$2" --restart' _ "$ACQ" "$flag"
    assert_failure
    assert_output --partial 'requires a value'
    assert [ ! -e "$STUBDIR/secrets/acq.box.usai" ]
    refute_regex "$(cat "$CALLS")" 'msb modify'
  done
}

@test "MSB global refeed resolves scoped value and endpoint separately" {
  run bash -c '
    . "$1/acq.backends/msb.sh"
    _acq_msb_service_binding() { printf "TEST_KEY\t%s.invalid\n" "$2"; }
    acq_secret_resolve() { printf "fixture-%s" "$2"; }
    _acq_msb_cli() {
      if [ "$1" = list ]; then printf "boxA\nboxB\n"; return; fi
      [ "$TEST_KEY" = "fixture-$2" ] || return 1
      [ "$4" = "TEST_KEY@$2.invalid" ] || return 1
      printf "verified %s\n" "$2" >&3
    }
    _acq_msb_secret_refeed usai "" TEST_KEY global.invalid 3>&1
    [ "${TEST_KEY+x}" != x ]
  ' _ "$REPO_ROOT"
  assert_success
  assert_line 'verified boxA'
  assert_line 'verified boxB'
  assert_line '2'
}

@test "MSB propagation reports partial failure" {
  printf 'boxA\nboxB\n' > "$STUBDIR/.msb_sandbox_list"
  mkdir -p "$STUBDIR/secrets"
  printf 'synthetic-key' > "$STUBDIR/secrets/acq.usai"
  run env ACQ_PROPAGATING_SECRET=1 STUB_MSB_MODIFY_FAIL=boxA ACQ_BACKEND=msb "$ACQ" secret _propagate -g usai
  assert_failure
  assert_output --partial "failed to apply 'usai' to 'boxA'"
}
