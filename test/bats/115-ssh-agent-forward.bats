#!/usr/bin/env bats
#
# 115-ssh-agent-forward.bats — bats port of scripts/test-acq.d/115-ssh-agent-forward.sh
# (ADR-0021, ADR-0025)
#
# Host ssh-agent forwarding into the msb guest via msb's --vsock flag + an
# in-guest socat bridge: the neutral forward emitter, msb --vsock translation,
# version/socket/port guards, the bridge starter (provision + persisted-marker
# paths), SSH_AUTH_SOCK env injection, and the base-image prereq check.
#
# Real AF_UNIX sockets are minted with python3 for the `[ -S ]` positive cases;
# socket-dependent tests `skip` when python3 lacks AF_UNIX. Backgrounded socat/
# ssh children are drained with `wait` inside each `run bash -c`.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Mint a real unix socket at $1; returns 0 iff one was created (needs python3).
_mk_unix_socket() {
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])' "$1" >/dev/null 2>&1 && [ -S "$1" ]
}

@test "vsock(10c1): create emits --vsock :3552/stream for a real host ssh-agent on msb >= 0.6.9" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  assert_output --partial '--vsock'
  assert_output --partial ':3552/stream'
}

@test "vsock(10c2): no --vsock when neither SSH_AUTH_SOCK nor ACQ_FORWARD_HOST_SOCKETS is set" {
  run bash -c '
    unset SSH_AUTH_SOCK ACQ_FORWARD_HOST_SOCKETS
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  refute_output --partial '--vsock'
}

@test "vsock(10c3): a forward requested on msb 0.6.8 warns and emits no flag (opt-in, never fatal)" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent.sock" STUB_MSB_VERSION=0.6.8
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf "%s" "${f[@]+"${f[@]}"}"
  '
  assert_output --partial 'needs msb >= 0.6.9'
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent.sock" STUB_MSB_VERSION=0.6.8
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  refute_output --partial '--vsock'
}

@test "vsock(10c4): SSH_AUTH_SOCK pointing at a non-socket warns and emits no --vsock" {
  touch "$STUBDIR/not-a-socket"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/not-a-socket" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf "%s" "${f[@]+"${f[@]}"}"
  '
  assert_output --partial 'not a socket'
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/not-a-socket" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  refute_output --partial '--vsock'
}

@test "vsock(10c5): a general ACQ_FORWARD_HOST_SOCKETS entry emits its requested port/kind" {
  _mk_unix_socket "$STUBDIR/custom.sock" || skip "python3 AF_UNIX socket unavailable"
  run bash -c '
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="'"$STUBDIR"'/custom.sock:6000/stream" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  assert_output --partial ':6000/stream'
}

@test "vsock(10c6): invalid ACQ_FORWARD_HOST_SOCKETS entries warn+skip, emit no line" {
  _mk_unix_socket "$STUBDIR/real.sock" || skip "python3 AF_UNIX socket unavailable"
  # (a) relative path
  run bash -c 'unset SSH_AUTH_SOCK; export ACQ_FORWARD_HOST_SOCKETS="rel.sock:6000"; . "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_host_socket_forwards 2>&1 1>/dev/null'
  assert_output --partial 'skipping'
  run bash -c 'unset SSH_AUTH_SOCK; export ACQ_FORWARD_HOST_SOCKETS="rel.sock:6000"; . "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_host_socket_forwards 2>/dev/null'
  assert_output ''
  # (b) reserved/invalid port on an existing socket
  run bash -c 'unset SSH_AUTH_SOCK; export ACQ_FORWARD_HOST_SOCKETS="'"$STUBDIR"'/real.sock:123"; . "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_host_socket_forwards 2>&1 1>/dev/null'
  assert_output --partial 'invalid'
  run bash -c 'unset SSH_AUTH_SOCK; export ACQ_FORWARD_HOST_SOCKETS="'"$STUBDIR"'/real.sock:123"; . "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_host_socket_forwards 2>/dev/null'
  assert_output ''
  # (c) missing socket
  run bash -c 'unset SSH_AUTH_SOCK; export ACQ_FORWARD_HOST_SOCKETS="/nonexistent/x.sock:6000"; . "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_host_socket_forwards 2>&1 1>/dev/null'
  assert_output --partial 'not an existing socket'
  run bash -c 'unset SSH_AUTH_SOCK; export ACQ_FORWARD_HOST_SOCKETS="/nonexistent/x.sock:6000"; . "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_host_socket_forwards 2>/dev/null'
  assert_output ''
}

@test "vsock(10c7): _acq_valid_vsock_port accepts 1..4294967294 except 123" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"; set +e
    _acq_valid_vsock_port 0;          printf "p0=%s\n"    "$?"
    _acq_valid_vsock_port 1;          printf "p1=%s\n"    "$?"
    _acq_valid_vsock_port 123;        printf "p123=%s\n"  "$?"
    _acq_valid_vsock_port 4294967294; printf "pmax=%s\n"  "$?"
    _acq_valid_vsock_port 4294967295; printf "pover=%s\n" "$?"
    _acq_valid_vsock_port abc;        printf "pabc=%s\n"  "$?"
  '
  assert_line 'p0=1'
  assert_line 'p1=0'
  assert_line 'p123=1'
  assert_line 'pmax=0'
  assert_line 'pover=1'
  assert_line 'pabc=1'
}

@test "vsock(10c8): the provision bridge starts socat UNIX-LISTEN -> VSOCK-CONNECT and records the marker" {
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
    wait
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "socat UNIX-LISTEN:'/home/agent/\.acq/ssh-agent\.sock'"
  assert_regex "$log" "VSOCK-CONNECT:2:'3552'"
  assert_regex "$log" '/var/lib/acq/ssh-auth-sock'
}

@test "vsock(10c9): the start path reads the marker and starts the bridge; empty marker starts none" {
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=0
    _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
    wait
  '
  assert_regex "$(cat "$CALLS")" "socat UNIX-LISTEN:'/home/agent/\.acq/ssh-agent\.sock'"
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=0
    _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
    wait
  '
  refute_regex "$(cat "$CALLS")" 'socat UNIX-LISTEN'
}

@test "vsock(10c10): missing socat returns non-zero, warns, and the provision idiom skips the bridge" {
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_SOCAT_PRESENT=0
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_check_socat sbox 2>&1; printf "RC=%s\n" "$?"
  '
  assert_output --partial 'RC=1'
  assert_output --partial 'socat not found'
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_SOCAT_PRESENT=0
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_check_socat sbox && _acq_msb_start_ssh_agent_bridge sbox
    wait
  ' >/dev/null 2>&1 || true
  refute_regex "$(cat "$CALLS")" 'socat UNIX-LISTEN'
}

@test "vsock(10c11): SSH_AUTH_SOCK is injected on run/attach when the marker is present, omitted when empty" {
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run sbox -- git status >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" 'SSH_AUTH_SOCK=/home/agent/\.acq/ssh-agent\.sock'
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_attach sbox </dev/null >/dev/null 2>&1 )
  '
  assert_regex "$(cat "$CALLS")" 'SSH_AUTH_SOCK='
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run sbox -- git status >/dev/null 2>&1
  '
  refute_regex "$(cat "$CALLS")" 'SSH_AUTH_SOCK='
}

@test "vsock(10c12): an invalid ACQ_SSH_AGENT_VSOCK_PORT override is rejected; a valid one is honored" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent.sock" STUB_MSB_VERSION=0.6.9 ACQ_SSH_AGENT_VSOCK_PORT=123
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>"'"$STUBDIR"'/c12.err"; printf "%s\n" "${f[@]+"${f[@]}"}"
    cat "'"$STUBDIR"'/c12.err"
  '
  refute_output --partial '--vsock'
  assert_output --partial 'ACQ_SSH_AGENT_VSOCK_PORT'
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent.sock" STUB_MSB_VERSION=0.6.9 ACQ_SSH_AGENT_VSOCK_PORT=9000
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  assert_output --partial ':9000/stream'
}

@test "vsock(10c13): the --vsock route port and the socat VSOCK-CONNECT target agree under an override" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  : > "$CALLS"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent.sock" STUB_MSB_VERSION=0.6.9 ACQ_SSH_AGENT_VSOCK_PORT=9000
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf "ROUTE %s\n" "${f[@]+"${f[@]}"}"
    _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
    wait
  '
  assert_output --partial ':9000/stream'
  assert_regex "$(cat "$CALLS")" "VSOCK-CONNECT:2:'9000'"
}

@test "vsock(10c15): an emitted forward prints a one-time trust-boundary notice" {
  _mk_unix_socket "$STUBDIR/agent15.sock" || skip "python3 AF_UNIX socket unavailable"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent15.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}" >/dev/null
  '
  assert_output --partial 'forwarding your host ssh-agent'
  assert_output --partial 'unset SSH_AUTH_SOCK to opt out'
  assert_output --partial 'ssh-add -c'
  # At most once per process.
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent15.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    { f=(); _acq_msb_vsock_flags_into f; f=(); _acq_msb_vsock_flags_into f; } 2>&1 1>/dev/null
  '
  local n; n=$(printf '%s\n' "$output" | grep -c 'forwarding your host ssh-agent' || true)
  assert_equal "$n" "1"
}

@test "vsock(10c14): an unsafe/relative ACQ_MSB_SSH_AGENT_GUEST_SOCK falls back to default; a safe one is honored" {
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 ACQ_MSB_SSH_AGENT_GUEST_SOCK="/x'"'"'; touch /tmp/PWNED; :'"'"'"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    printf "%s\n" "$ACQ_MSB_SSH_AGENT_GUEST_SOCK"
  '
  assert_output '/home/agent/.acq/ssh-agent.sock'
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 ACQ_MSB_SSH_AGENT_GUEST_SOCK="/home/agent/.acq/custom-agent.sock"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    printf "%s\n" "$ACQ_MSB_SSH_AGENT_GUEST_SOCK"
  '
  assert_output '/home/agent/.acq/custom-agent.sock'
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 ACQ_MSB_SSH_AGENT_GUEST_SOCK="relative/agent.sock"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    printf "%s\n" "$ACQ_MSB_SSH_AGENT_GUEST_SOCK"
  '
  assert_output '/home/agent/.acq/ssh-agent.sock'
}

@test "vsock(10c16): re-attach to a RUNNING sandbox re-drives the forward (bridge + marker, no 'msb start')" {
  _mk_unix_socket "$STUBDIR/agent16.sock" || skip "python3 AF_UNIX socket unavailable"
  # Running sandbox that carries the create-time --vsock route on the ssh-agent
  # port; a local empty kit dir so the heal's kit loop does no network fetch.
  printf 'reattachbox\n' >"$STUBDIR/.msb_sandbox_list"
  printf 'reattachbox\n' >"$STUBDIR/.msb_running_list"
  printf '{"active_config":{"vsock":{"routes":[{"host_socket":"/private/var/run/x/Listeners","port":3552}]}}}\n' >"$STUBDIR/.msb_inspect_json"
  mkdir -p "$STUBDIR/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' >"$STUBDIR/nokit/spec.yaml"
  : > "$CALLS"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent16.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_ensure_kits_applied reattachbox >/dev/null 2>&1
    wait
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "socat UNIX-LISTEN:'/home/agent/\.acq/ssh-agent\.sock'"
  assert_regex "$log" '/var/lib/acq/ssh-auth-sock'
  # A running sandbox must NOT be routed through acq_backend_start.
  refute_regex "$log" 'msb start'
}

@test "vsock(10c17): the re-drive is a strict no-op without both a forward AND a --vsock route" {
  _mk_unix_socket "$STUBDIR/agent17.sock" || skip "python3 AF_UNIX socket unavailable"
  printf 'rbox\n' >"$STUBDIR/.msb_sandbox_list"
  printf 'rbox\n' >"$STUBDIR/.msb_running_list"
  # (a) route present, but NO host forward requested -> no bridge.
  printf '{"active_config":{"vsock":{"routes":[{"host_socket":"/private/var/run/x/Listeners","port":3552}]}}}\n' >"$STUBDIR/.msb_inspect_json"
  : > "$CALLS"
  run bash -c '
    unset SSH_AUTH_SOCK ACQ_FORWARD_HOST_SOCKETS
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_ensure_ssh_agent_forward rbox >/dev/null 2>&1
    wait
  '
  refute_regex "$(cat "$CALLS")" 'socat UNIX-LISTEN'
  # (b) forward requested, but the sandbox has NO --vsock route -> no bridge.
  printf '{"active_config":{"network":{}}}\n' >"$STUBDIR/.msb_inspect_json"
  : > "$CALLS"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent17.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_ensure_ssh_agent_forward rbox >/dev/null 2>&1
    wait
  '
  refute_regex "$(cat "$CALLS")" 'socat UNIX-LISTEN'
  # (c) forward requested, and a PUBLISHED PORT equals the vsock port but there is
  #     NO vsock route: the route probe requires a `vsock` key too, so this must
  #     NOT be mistaken for a route (review nit: tighten anchoring). No bridge.
  printf '{"active_config":{"network":{"ports":[{"port":3552}]}}}\n' >"$STUBDIR/.msb_inspect_json"
  : > "$CALLS"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent17.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_ensure_ssh_agent_forward rbox >/dev/null 2>&1
    wait
  '
  refute_regex "$(cat "$CALLS")" 'socat UNIX-LISTEN'
}

@test "vsock(10c17b): re-attach warns when host agent is set but no route exists" {
  _mk_unix_socket "$STUBDIR/agent17b.sock" || skip "python3 AF_UNIX socket unavailable"
  printf 'rbox\n' >"$STUBDIR/.msb_sandbox_list"
  printf 'rbox\n' >"$STUBDIR/.msb_running_list"
  printf '{"active_config":{"network":{}}}\n' >"$STUBDIR/.msb_inspect_json"
  : > "$CALLS"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent17b.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_ensure_ssh_agent_forward rbox 2>&1
    wait
  '
  assert_success
  assert_output --partial 'has no ssh-agent --vsock route'
  assert_output --partial 'SSH_AUTH_SOCK will not be set in the guest'
  assert_output --partial 'same name after wiping msb state'
  refute_regex "$(cat "$CALLS")" 'socat UNIX-LISTEN'
}

@test "vsock(10c18): the route probe matches the real msb 0.6.12 vsock shape" {
  # The real shape (confirmed on msb 0.6.12) is
  #   "vsock":{"routes":[{"host_socket":"…/Listeners","port":3552}]}
  # The probe must accept it (has both a `vsock` key and the port token) and must
  # reject a same-port published port with no `vsock` key.
  printf 'pbox\n' >"$STUBDIR/.msb_sandbox_list"
  printf 'pbox\n' >"$STUBDIR/.msb_running_list"
  printf '%s\n' '{"vsock":{"routes":[{"host_socket":"/private/var/run/x/Listeners","port":3552}]}}' \
    >"$STUBDIR/.msb_inspect_json"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_has_ssh_agent_vsock_route pbox; printf "RC=%s\n" "$?"
  '
  assert_output --partial 'RC=0'
  printf '%s\n' '{"network":{"ports":[{"port":3552}]}}' >"$STUBDIR/.msb_inspect_json"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_has_ssh_agent_vsock_route pbox; printf "RC=%s\n" "$?"
  '
  assert_output --partial 'RC=1'
}

@test "vsock(10c19): a stale --vsock route (host reboot) warns with the recreate remedy, not silently" {
  # After the bridge + marker are (re)placed, the forwarded-agent liveness probe
  # runs `ssh-add -l` over the guest sock. The reboot dead-bridge signature is
  # exit 1 with "communication with agent failed" (the socat listener socket is
  # PRESENT, but its vsock backend is dead, so ssh-add connects then the agent
  # protocol fails — NOT exit 2, which is only a missing socket). The starter
  # must classify that as unreachable and SURFACE the recreate remedy.
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_AGENT_UNREACHABLE=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge stalebox 2>&1
    wait
  '
  assert_output --partial 'UNREACHABLE'
  assert_output --partial 'HOST REBOOT'
  assert_output --partial 'acq rm stalebox'
}

@test "vsock(10c19b): a missing agent socket (exit 2) also warns" {
  # The other unreachable shape: the socket path itself cannot be opened,
  # ssh-add exits 2 "Error connecting to agent". Must also warn.
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_AGENT_NO_SOCKET=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge nosockbox 2>&1
    wait
  '
  assert_output --partial 'UNREACHABLE'
  assert_output --partial 'acq rm nosockbox'
}

@test "vsock(10c20): a reachable forwarded agent produces NO stale-route warning" {
  # Default stub models ssh-add -l as reachable WITH keys (exit 0); the starter
  # must stay quiet — no false stale-route warning on a healthy bridge.
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge livebox 2>&1
    wait
  '
  refute_output --partial 'UNREACHABLE'
  # Reachable but EMPTY keyring: exit 1 WITH the "no identities" message. This is
  # a HEALTHY agent (just no keys loaded) and MUST NOT warn — the discriminator
  # from the reboot case (also exit 1) is the message text, not the exit code.
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_AGENT_NO_KEYS=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge emptybox 2>&1
    wait
  '
  refute_output --partial 'UNREACHABLE'
}

@test "vsock(10c20b): the warn-return never aborts the caller under set -e" {
  # _acq_msb_warn_if_agent_unreachable returns non-zero when it warns; every
  # production caller must `|| true` it so a warning cannot abort a verb under
  # `set -euo pipefail`. Assert the bridge starter (its caller) still returns 0
  # even when the probe warns.
  run bash -c '
    set -euo pipefail
    export STUB_MSB_VERSION=0.6.9 STUB_AGENT_UNREACHABLE=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge abortbox >/dev/null 2>&1
    printf "RC=%s\n" "$?"
    wait
  '
  assert_output --partial 'RC=0'
}

@test "vsock(10c21): the liveness probe is skipped (no warning) when ssh-add is absent in the guest" {
  # Without ssh-add in the guest the probe cannot run; it must SKIP silently
  # rather than warn (the forward may still be fine — we just cannot assert it).
  local pq="$STUBDIR/pq21"; mkdir -p "$pq"
  cat >"$pq/msb" <<'PQ'
#!/usr/bin/env bash
snip=""; prev=""; for a in "$@"; do [ "$prev" = "-c" ] && { snip="$a"; break; }; prev="$a"; done
case "$1" in --version) echo "msb 0.6.9"; exit 0;; esac
case "$snip" in
  *"command -v ssh-add"*) exit 1 ;;   # ssh-add ABSENT
  *) exit 0 ;;
esac
PQ
  chmod +x "$pq/msb"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    export PATH="'"$pq"':$PATH"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_warn_if_agent_unreachable skipbox /home/agent/.acq/ssh-agent.sock 2>&1
    printf "RC=%s\n" "$?"
  '
  refute_output --partial 'UNREACHABLE'
  assert_output --partial 'RC=0'
}

@test "msb: the base-image prereq check warns on missing tools, silent when present or skipped" {
  local pq="$STUBDIR/pq"; mkdir -p "$pq"
  cat >"$pq/msb" <<'PQ'
#!/usr/bin/env bash
snip=""; prev=""; for a in "$@"; do [ "$prev" = "-c" ] && { snip="$a"; break; }; prev="$a"; done
case "$1" in --version) echo "msb 0.6.9"; exit 0;; esac
case "$snip" in *"command -v"*) printf '%s' "${MSB_MISSING:-}"; exit 0;; esac
exit 0
PQ
  chmod +x "$pq/msb"
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"; . "'"$REPO_ROOT"'/acq.backends/common.sh"
    export PATH="'"$pq"':$PATH" MSB_MISSING=" node git"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_check_prereqs testbox 2>&1
  '
  assert_output --partial 'missing kit prerequisite'
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"; . "'"$REPO_ROOT"'/acq.backends/common.sh"
    export PATH="'"$pq"':$PATH" MSB_MISSING=""
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_check_prereqs testbox 2>&1
  '
  refute_output --partial 'missing kit prerequisite'
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"; . "'"$REPO_ROOT"'/acq.backends/common.sh"
    export PATH="'"$pq"':$PATH" MSB_MISSING=" node" ACQ_MSB_SKIP_PREREQ_CHECK=1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_check_prereqs testbox 2>&1
  '
  refute_output --partial 'missing kit prerequisite'
}

# --- Managed ssh-agent route link (ADR-0021 amendment: reboot-proof route) ----
# msb dials the --vsock host_socket path per guest connection and follows
# symlinks, so acq routes the automatic ssh-agent forward through a per-sandbox
# symlink it owns and re-points on every bridge (re)start. The route therefore
# survives a host reboot that gives the host agent a new socket path.

@test "vsock(10c22): create with a sandbox name routes the ssh-agent forward via the managed link, not the raw path" {
  _mk_unix_socket "$STUBDIR/agent22.sock" || skip "python3 AF_UNIX socket unavailable"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent22.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f linkbox 2>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}"
    printf "LINK=%s\n" "$(readlink "$ACQ_STATE_DIR/msb/ssh-agent/linkbox.sock")"
  '
  assert_line "--vsock"
  assert_line "$STUBDIR/state/msb/ssh-agent/linkbox.sock:3552/stream"
  refute_output --partial "agent22.sock:3552"
  # The link resolves to the canonical agent socket.
  local want; want=$(realpath "$STUBDIR/agent22.sock" 2>/dev/null || readlink -f "$STUBDIR/agent22.sock")
  assert_line "LINK=$want"
}

@test "vsock(10c23): without a sandbox name the raw canonical path is kept; custom forwards stay canonicalized" {
  _mk_unix_socket "$STUBDIR/agent23.sock" || skip "python3 AF_UNIX socket unavailable"
  _mk_unix_socket "$STUBDIR/custom23.sock" || skip "python3 AF_UNIX socket unavailable"
  ln -s "$STUBDIR/custom23.sock" "$STUBDIR/custom23.link"
  local want_a want_c
  want_a=$(realpath "$STUBDIR/agent23.sock" 2>/dev/null || readlink -f "$STUBDIR/agent23.sock")
  want_c=$(realpath "$STUBDIR/custom23.sock" 2>/dev/null || readlink -f "$STUBDIR/custom23.sock")
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent23.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  assert_line "$want_a:3552/stream"
  refute_output --partial 'ssh-agent/'
  # A custom ACQ_FORWARD_HOST_SOCKETS entry given as a symlink is still resolved
  # to its target even when a name is supplied (only the automatic ssh-agent
  # forward is routed through the managed link).
  run bash -c '
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="'"$STUBDIR"'/custom23.link:6000/stream" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f custombox 2>/dev/null; printf "%s\n" "${f[@]+"${f[@]}"}"
  '
  assert_line "$want_c:6000/stream"
  refute_output --partial 'custom23.link'
  [ ! -e "$STUBDIR/state/msb/ssh-agent/custombox.sock" ]
}

@test "vsock(10c24): the bridge (re)start re-points an existing managed link at the current SSH_AUTH_SOCK" {
  _mk_unix_socket "$STUBDIR/old24.sock" || skip "python3 AF_UNIX socket unavailable"
  _mk_unix_socket "$STUBDIR/new24.sock" || skip "python3 AF_UNIX socket unavailable"
  local want; want=$(realpath "$STUBDIR/new24.sock" 2>/dev/null || readlink -f "$STUBDIR/new24.sock")
  # Create-time link pointing at the pre-reboot agent path.
  mkdir -p "$STUBDIR/state/msb/ssh-agent"
  ln -s "$STUBDIR/old24.sock" "$STUBDIR/state/msb/ssh-agent/rebootbox.sock"
  # Resume path (acq_backend_start shape): no provision flag, marker present.
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/new24.sock" STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=0
    _acq_msb_start_ssh_agent_bridge rebootbox >/dev/null 2>&1
    wait
    printf "LINK=%s\n" "$(readlink "$ACQ_STATE_DIR/msb/ssh-agent/rebootbox.sock")"
  '
  assert_line "LINK=$want"
  # The replace left no temp link behind.
  run bash -c 'ls "'"$STUBDIR"'/state/msb/ssh-agent"'
  assert_output 'rebootbox.sock'
  # A sandbox without a managed link (pre-amendment route) gets none invented.
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/new24.sock" STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=0
    _acq_msb_start_ssh_agent_bridge legacybox >/dev/null 2>&1
    wait
  '
  [ ! -L "$STUBDIR/state/msb/ssh-agent/legacybox.sock" ]
}

@test "vsock(10c25): an unset or non-socket SSH_AUTH_SOCK at start leaves the link alone and never fails the verb" {
  mkdir -p "$STUBDIR/state/msb/ssh-agent"
  ln -s "$STUBDIR/gone.sock" "$STUBDIR/state/msb/ssh-agent/holdbox.sock"
  touch "$STUBDIR/not-a-socket25"
  run bash -c '
    set -euo pipefail
    unset SSH_AUTH_SOCK
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock STUB_AGENT_UNREACHABLE=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=0
    _acq_msb_start_ssh_agent_bridge holdbox 2>&1
    printf "RC=%s\n" "$?"
    wait
  '
  assert_output --partial 'RC=0'
  assert_output --partial 'UNREACHABLE'
  # The warning must not claim the link was re-pointed: nothing to point it at.
  assert_output --partial 'NOT re-pointed'
  refute_output --partial 'just re-pointed'
  assert_equal "$(readlink "$STUBDIR/state/msb/ssh-agent/holdbox.sock")" "$STUBDIR/gone.sock"
  run bash -c '
    set -euo pipefail
    export SSH_AUTH_SOCK="'"$STUBDIR"'/not-a-socket25" STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=0
    _acq_msb_start_ssh_agent_bridge holdbox >/dev/null 2>&1
    printf "RC=%s\n" "$?"
    wait
  '
  assert_output --partial 'RC=0'
  assert_equal "$(readlink "$STUBDIR/state/msb/ssh-agent/holdbox.sock")" "$STUBDIR/gone.sock"
}

@test "vsock(10c26): acq rm removes the managed link but never the agent socket it points at" {
  _mk_unix_socket "$STUBDIR/agent26.sock" || skip "python3 AF_UNIX socket unavailable"
  mkdir -p "$STUBDIR/state/msb/ssh-agent"
  ln -s "$STUBDIR/agent26.sock" "$STUBDIR/state/msb/ssh-agent/rmbox.sock"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_terminate rmbox >/dev/null 2>&1; printf "RC=%s\n" "$?"
  '
  assert_output --partial 'RC=0'
  [ ! -L "$STUBDIR/state/msb/ssh-agent/rmbox.sock" ]
  [ -S "$STUBDIR/agent26.sock" ]
}

@test "vsock(10c27): the unreachable warning names the one-time recreate for a legacy route, and the host agent for a managed one" {
  # (a) legacy route (no managed link): recreate once; afterwards start heals it.
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_AGENT_UNREACHABLE=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge oldbox 2>&1
    wait
  '
  assert_output --partial 'UNREACHABLE'
  assert_output --partial 'acq rm oldbox'
  assert_output --partial 'once'
  # (b) managed route: the link is already re-pointed, so the remedy is the host
  #     agent, not a recreate.
  _mk_unix_socket "$STUBDIR/agent27.sock" || skip "python3 AF_UNIX socket unavailable"
  mkdir -p "$STUBDIR/state/msb/ssh-agent"
  ln -s "$STUBDIR/agent27.sock" "$STUBDIR/state/msb/ssh-agent/newbox.sock"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent27.sock" STUB_MSB_VERSION=0.6.9 STUB_AGENT_UNREACHABLE=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge newbox 2>&1
    wait
  '
  assert_output --partial 'UNREACHABLE'
  refute_output --partial 'acq rm newbox'
  assert_output --partial 'ssh-agent/newbox.sock'
  assert_output --partial 'just re-pointed'
}

@test "vsock(10c28): a link path that would overflow sun_path falls back to a short hashed name under the same dir" {
  _mk_unix_socket "$STUBDIR/agent28.sock" || skip "python3 AF_UNIX socket unavailable"
  # Pad the state dir to ~70 bytes so "<dir>/msb/ssh-agent/<60-char name>.sock"
  # exceeds the 103-byte macOS sun_path budget while the hashed basename
  # ("h<cksum>.sock", <= 16 bytes) still fits. The temp dir differs per host, so
  # pad relative to it rather than assuming its length.
  local deep pad
  deep="$STUBDIR/state"
  pad=$(( 70 - ${#deep} ))
  [ "$pad" -le 0 ] && [ "${#deep}" -gt 72 ] && skip "temp dir too long for the sun_path window"
  [ "$pad" -gt 0 ] && deep="$deep/$(printf 'd%.0s' $(seq 1 "$pad"))"
  local longname="a-rather-long-sandbox-name-for-the-sun-path-overflow-case-x"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent28.sock" STUB_MSB_VERSION=0.6.9 ACQ_STATE_DIR="'"$deep"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f "'"$longname"'" 2>/dev/null
    p="${f[1]%%:3552/stream}"; printf "PATH=%s\nLEN=%s\n" "$p" "$(printf "%s" "$p" | wc -c | tr -d " ")"
    [ -L "$p" ] && printf "ISLINK=1\n"
  '
  assert_output --partial "PATH=$deep/msb/ssh-agent/h"
  refute_output --partial "$longname"
  assert_output --partial 'ISLINK=1'
  local len; len=$(printf '%s\n' "$output" | sed -n 's/^LEN=//p')
  [ "$len" -le 103 ]
}

@test "vsock(10c29): an unsafe sandbox name never becomes a link path; the raw route is used instead" {
  _mk_unix_socket "$STUBDIR/agent29.sock" || skip "python3 AF_UNIX socket unavailable"
  local want; want=$(realpath "$STUBDIR/agent29.sock" 2>/dev/null || readlink -f "$STUBDIR/agent29.sock")
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent29.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f "../escape" 2>"'"$STUBDIR"'/c29.err"; printf "%s\n" "${f[@]+"${f[@]}"}"
    cat "'"$STUBDIR"'/c29.err"
  '
  assert_line "$want:3552/stream"
  # The fallback is announced, not silent: the route will go stale on a reboot.
  assert_output --partial 'cannot manage the ssh-agent route'
  [ ! -e "$STUBDIR/state/msb/ssh-agent" ] || [ -z "$(ls -A "$STUBDIR/state/msb/ssh-agent")" ]
  # For such a name the legacy warning must not promise that a recreate self-heals.
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_AGENT_UNREACHABLE=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=1
    _acq_msb_start_ssh_agent_bridge my.app 2>&1
    wait
  '
  assert_output --partial 'UNREACHABLE'
  assert_output --partial 'acq rm my.app'
  refute_output --partial 'one-time recreate'
  assert_output --partial "letters, digits, '_' and '-'"
}

@test "vsock(10c30): a link that cannot be replaced is reported as such, never blamed on SSH_AUTH_SOCK or the name" {
  _mk_unix_socket "$STUBDIR/agent30.sock" || skip "python3 AF_UNIX socket unavailable"
  # (a) at start: the managed link exists but a regular file now sits at the
  #     temp-link name's parent... simplest reproducible failure is a read-only
  #     link dir, so the atomic replace cannot mint its temp link.
  mkdir -p "$STUBDIR/state/msb/ssh-agent"
  ln -s "$STUBDIR/gone30.sock" "$STUBDIR/state/msb/ssh-agent/rofs.sock"
  chmod 555 "$STUBDIR/state/msb/ssh-agent"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent30.sock" STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock STUB_AGENT_UNREACHABLE=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _ACQ_MSB_SSH_AGENT_FORWARDING=0
    _acq_msb_start_ssh_agent_bridge rofs 2>&1
    wait
  '
  chmod 755 "$STUBDIR/state/msb/ssh-agent"
  assert_output --partial 'could not re-point'
  assert_output --partial 'UNREACHABLE'
  assert_output --partial 'NOT re-pointed'
  assert_output --partial 'ssh-agent/rofs.sock'
  assert_output --partial 'Fix or remove'
  refute_output --partial 'just re-pointed'
  refute_output --partial 'names your live agent'
  # (b) at create: a valid name whose link cannot be created is not told its
  #     name is wrong; the warning names the link path instead.
  chmod 555 "$STUBDIR/state/msb/ssh-agent"
  run bash -c '
    export SSH_AUTH_SOCK="'"$STUBDIR"'/agent30.sock" STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f okname 2>&1 1>/dev/null
  '
  chmod 755 "$STUBDIR/state/msb/ssh-agent"
  assert_output --partial 'cannot manage the ssh-agent route'
  assert_output --partial 'ssh-agent/okname.sock'
  refute_output --partial "letters, digits"
}
