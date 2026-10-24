#!/usr/bin/env bats
# Foreground Node kit dispatch, exact argv, and lifecycle boundaries (ADR-0036).
# shellcheck shell=bats

load 'helper'

setup() {
  acq_setup_stubs
  . "$REPO_ROOT/acq.backends/msb.sh"
  _acq_msb_cli() { _node_test_cli "$@"; }
  export NODE_TEST_STATUS=0
  cat > "$STUBDIR/node" <<'SH'
#!/bin/sh
printf '%s\0' "$@" > "$STUBDIR/node-argv"
printf '%s\0' "$HOME" "$KIT_VALUE" "$GIT_TERMINAL_PROMPT" > "$STUBDIR/node-env"
printf 'node stdout\n'
printf 'node stderr\n' >&2
exit "$NODE_TEST_STATUS"
SH
  chmod +x "$STUBDIR/node"
}

teardown() { acq_teardown_stubs; }

# Capture the real argv boundary, then execute the guest command locally. Only
# synthetic test values enter this fixture; user selection is asserted in argv.
_node_test_cli() (
  printf '%s\0' "$@" > "$STUBDIR/exec-argv"
  printf 'call\n' >> "$STUBDIR/exec-count"
  shift 2
  while [ "$1" != -- ]; do
    case "$1" in
      -u) shift 2 ;;
      -e) export "${2?}"; shift 2 ;;
      *) return 99 ;;
    esac
  done
  shift
  "$@"
)

@test "msb Node: foreground preserves exact argv, user, HOME, env and streams" {
  local phase
  local args=(node '/path with spaces/script.mjs' '' 'two words' '$(exit 31); *' "a'b\"c" $'line1\nline2')
  for phase in initFiles startup; do
    run _acq_msb_exec_command nodebox "$phase" 1000 false _acq_msb_no_guards \
      'KIT_VALUE=literal $(false); *' -- "${args[@]}"
    assert_success
    assert_line 'node stdout'
    assert_line 'node stderr'
    printf '%s\0' exec nodebox -u agent -e HOME=/home/agent \
      -e 'KIT_VALUE=literal $(false); *' -e GIT_TERMINAL_PROMPT=0 \
      -e GIT_ASKPASS=/bin/false -e SSH_ASKPASS=/bin/false \
      -- sh -c '"$@"' sh "${args[@]}" > "$STUBDIR/expected"
    cmp "$STUBDIR/expected" "$STUBDIR/exec-argv"
    printf '%s\0' "${args[@]:1}" > "$STUBDIR/expected"
    cmp "$STUBDIR/expected" "$STUBDIR/node-argv"
    printf '%s\0' /home/agent 'literal $(false); *' 0 > "$STUBDIR/expected"
    cmp "$STUBDIR/expected" "$STUBDIR/node-env"
  done
}

@test "msb Node: foreground launcher returns child status, caller retains warning behavior" {
  export NODE_TEST_STATUS=17 KIT_VALUE=test
  run _acq_msb_exec_foreground nodebox -u agent -e HOME=/home/agent -- node ignored
  assert_failure 17
  assert_line 'node stderr'
  run _acq_msb_exec_command nodebox startup agent false _acq_msb_no_guards -- node ignored
  assert_success
  assert_line "acq(msb): warning: startup command failed for 'nodebox'"
}

@test "msb Node: install failure is retryable, success uses original argv marker and skips rerun" {
  local marker
  marker="install-$(printf '%s\0' node 'script path' '' | cksum | cut -d' ' -f1)"
  export NODE_TEST_STATUS=17 KIT_VALUE=test
  run _acq_msb_exec_command nodebox install agent false _acq_msb_no_guards -- node 'script path' ''
  assert_success
  assert_line "acq(msb): warning: install command failed for 'nodebox'"
  run acq_host_config_has msb nodebox "$marker"
  assert_failure
  export NODE_TEST_STATUS=0
  run _acq_msb_exec_command nodebox install agent false _acq_msb_no_guards -- node 'script path' ''
  assert_success
  acq_host_config_has msb nodebox "$marker"
  run _acq_msb_exec_command nodebox install agent false _acq_msb_no_guards -- node 'script path' ''
  assert_success
  [ "$(wc -l < "$STUBDIR/exec-count" | tr -d ' ')" = 2 ]
}

@test "msb Node: background retains exact detach form and other executables stay direct" {
  _acq_msb_cli() { printf '%s\0' "$@" > "$STUBDIR/exec-argv"; }
  # Passed by array name to the adapter's Bash 3.2-compatible helper.
  # shellcheck disable=SC2034
  local uf=(-u agent) ef=(-e HOME=/home/agent)
  _acq_msb_exec_run nodebox startup agent true uf ef -- node 'script path' ''
  printf '%s\0' exec nodebox -u agent -e HOME=/home/agent \
    -- sh -c 'nohup "$@" >/dev/null 2>&1 & exit 0' sh node 'script path' '' > "$STUBDIR/expected"
  cmp "$STUBDIR/expected" "$STUBDIR/exec-argv"
  local executable
  for executable in printf /usr/bin/node env; do
    _acq_msb_exec_run nodebox startup agent false uf ef -- "$executable" 'two words' ''
    printf '%s\0' exec nodebox -u agent -e HOME=/home/agent \
      -- "$executable" 'two words' '' > "$STUBDIR/expected"
    cmp "$STUBDIR/expected" "$STUBDIR/exec-argv"
  done
}

@test "msb Node: calibration probe offline tests" {
  run python3 -B "$REPO_ROOT/scripts/test-probe-msb-node-startup.py"
  assert_success
  assert_line 'OK'
}
