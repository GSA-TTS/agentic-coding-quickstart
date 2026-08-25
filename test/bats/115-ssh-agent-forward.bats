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
  printf '{"active_config":{"vsock":[{"port":3552}]}}\n' >"$STUBDIR/.msb_inspect_json"
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
  printf '{"active_config":{"vsock":[{"port":3552}]}}\n' >"$STUBDIR/.msb_inspect_json"
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
