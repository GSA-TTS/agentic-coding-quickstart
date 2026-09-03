#!/usr/bin/env bats
#
# 112-msb-ports.bats — bats port of scripts/test-acq.d/112-msb-ports.sh (ADR-0015,
# ADR-0025)
#
# Post-hoc `acq ports <sandbox> --publish H:G` on msb (backgrounded `msb ssh
# serve` + `ssh -L`), liveness failure handling, key-authorize-once, distinct
# serve ports, SI-10 validation, teardown, traversal guards, and LIST mode.
# Because acq BACKGROUNDS the serve/ssh children, every publish body runs in a
# `run bash -c '... ; wait'` so the stubbed children finish appending to $CALLS
# before we read it (avoids the concurrency flake the legacy suite guarded).
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "msb ports: publish generates+authorizes the acq key once, serves, and opens the -L tunnel" {
  run bash -c '
    export ACQ_MSB_FORCE_SERVE_PORT=54321
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports pbox --publish 8080:3000 >/dev/null 2>&1
    wait
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "ssh-keygen -t ed25519 -N  -f $STUBDIR/state/ssh/msb_id_ed25519"
  assert_regex "$log" "msb ssh authorize --file $STUBDIR/state/ssh/msb_id_ed25519.pub"
  assert_regex "$log" 'msb ssh serve pbox --host 127.0.0.1 --port 54321'
  assert_regex "$log" -- '-L 127.0.0.1:8080:127.0.0.1:3000'
  assert_regex "$log" -- "-i $STUBDIR/state/ssh/msb_id_ed25519"
  assert_regex "$log" "UserKnownHostsFile=$STUBDIR/state/ssh/known_hosts"
  assert_regex "$log" 'IdentitiesOnly=yes'
  assert_regex "$log" -- '-F none'
  assert [ -f "$STUBDIR/state/ports/pbox.pids" ]
}

@test "msb ports(S2): a serve that dies immediately fails the publish, no state recorded" {
  run bash -c '
    export ACQ_MSB_FORCE_SERVE_PORT=54321 STUB_MSB_SERVE_DIE=1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports pbox --publish 8080:3000 2>&1
    echo "RC=$?"
    wait
  '
  assert_output --partial 'RC=1'
  refute_output --partial 'published host'
  assert [ ! -f "$STUBDIR/state/ports/pbox.pids" ]
}

@test "msb ports(S2): a forward that dies immediately fails the publish, no state recorded" {
  run bash -c '
    export ACQ_MSB_FORCE_SERVE_PORT=54321 STUB_SSH_DIE=1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports pbox --publish 8080:3000 2>&1
    echo "RC=$?"
    wait
  '
  assert_output --partial 'RC=1'
  refute_output --partial 'published host'
  assert [ ! -f "$STUBDIR/state/ports/pbox.pids" ]
}

@test "msb ports: a second publish reuses the key, refreshes auth, and opens its own tunnel" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports pbox --publish 8080:3000 >/dev/null 2>&1
    wait
    : > "'"$CALLS"'"
    acq_backend_ports pbox --publish 9090:4000 >/dev/null 2>&1
    wait
  '
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'ssh-keygen'
  assert_regex "$log" 'msb ssh authorize'
  assert_regex "$log" -- '-L 127.0.0.1:9090:127.0.0.1:4000'
}

@test "msb ports: stale acq authorization marker does not skip msb authorize" {
  mkdir -p "$STUBDIR/state/ssh"
  : > "$STUBDIR/state/ssh/.authorized"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports pbox --publish 8080:3000 >/dev/null 2>&1
    wait
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb ssh authorize'
}

@test "msb ports: two publishes in one process get distinct serve ports" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports mpbox --publish 8080:3000 >/dev/null 2>&1
    acq_backend_ports mpbox --publish 9090:4000 >/dev/null 2>&1
    wait
  '
  local lines ports
  lines=$(wc -l < "$STUBDIR/state/ports/mpbox.pids" | tr -d ' ')
  ports=$(awk '{print $3}' "$STUBDIR/state/ports/mpbox.pids" | sort -u | wc -l | tr -d ' ')
  assert_equal "$lines" "2"
  assert_equal "$ports" "2"
}

@test "msb ports: invalid --publish values are rejected before any ssh/serve/keygen" {
  local bad
  for bad in "0:3000" "8080:70000" "abc:def" "8080"; do
    : > "$CALLS"
    run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; acq_backend_ports badbox --publish "$1" 2>&1' _ "$bad"
    assert_failure
    local log; log=$(cat "$CALLS")
    refute_regex "$log" -- '-L 127.0.0.1'
    refute_regex "$log" 'msb ssh serve'
  done
}

@test "msb: SUPPORTS_PORT_FORWARD is 1 (post-hoc publish wired)" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null; printf "%s" "$ACQ_BACKEND_SUPPORTS_PORT_FORWARD"'
  assert_output '1'
}

@test "msb ports: rm and stop tear down recorded port state; un-published teardown is a no-op" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports rmbox --publish 8080:3000 >/dev/null 2>&1
    [ -f "'"$STUBDIR"'/state/ports/rmbox.pids" ] || exit 3
    acq_backend_terminate rmbox >/dev/null 2>&1
  '
  assert [ ! -f "$STUBDIR/state/ports/rmbox.pids" ]
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports stopbox --publish 7000:7000 >/dev/null 2>&1
    acq_backend_stop stopbox >/dev/null 2>&1
    acq_backend_terminate neverbox >/dev/null 2>&1
  '
  assert_success
  assert [ ! -f "$STUBDIR/state/ports/stopbox.pids" ]
}

@test "msb ports: an unsafe sandbox name cannot escape the state dir on record/teardown" {
  mkdir -p "$STUBDIR/state/ports"
  local canary="$STUBDIR/state/traversal-canary.pids"
  printf 'DO-NOT-DELETE\n' >"$canary"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_ports_record "../traversal-canary" 111 222 20001 8080:3000 >/dev/null 2>&1
    _acq_msb_ports_teardown "../traversal-canary" >/dev/null 2>&1
  '
  assert [ -f "$canary" ]
  assert [ ! -e "$STUBDIR/state/traversal-canary.pids.pids" ]
}

@test "msb ports: LIST mode surfaces create-time + post-hoc ports without host_bind junk" {
  printf '%s\n' '{"active_config":{"network":{"ports":[{"guest_port":3000,"host_bind":"127.0.0.1","host_port":3000,"protocol":"tcp"},{"guest_port":4096,"host_bind":"127.0.0.1","host_port":4096,"protocol":"tcp"},{"guest_port":8443,"host_bind":"127.0.0.1:9","host_port":8443,"protocol":"tcp"}]}},"name":"listbox","status":"Running"}' \
    >"$STUBDIR/.msb_inspect_json"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_ports_record listbox 111 222 54321 9090:8080
    acq_backend_ports listbox
  '
  assert_success
  assert_output --partial '3000'
  assert_output --partial '4096'
  assert_output --partial '8080'
  assert_output --partial 'sandbox 3000 -> host 127.0.0.1:3000 (create-time -p)'
  assert_output --partial 'sandbox 8443 -> host 127.0.0.1:8443 (create-time -p)'
  refute_output --regexp '127\.0\.0\.1:(1|9|16|00|256)( |$)'
}

@test "msb ports: LIST mode with zero ports exits 0 (empty list, not an error)" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; acq_backend_ports emptybox'
  assert_success
}

@test "msb ports: LIST degrades gracefully when the JSON has no recognizable port field" {
  printf '{"name":"absentbox","state":"running"}\n' >"$STUBDIR/.msb_inspect_json"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; acq_backend_ports absentbox >/dev/null 2>&1'
  assert_success
}

@test "msb ports: LIST exits 0 under set -euo pipefail with empty ports (live-host regression)" {
  printf '{"active_config":{"network":{"ports":[]}}}\n' >"$STUBDIR/.msb_inspect_json"
  run bash -c '
    set -euo pipefail
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ports emptybox >/dev/null 2>&1
  '
  assert_success
}

@test "msb ports: a genuinely bad arg (--frobnicate) still errors, not swallowed by LIST mode" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; acq_backend_ports badargbox --frobnicate 2>&1'
  assert_failure
  assert_output --partial 'unsupported argument'
}
