#!/usr/bin/env bash
#
# 115-ssh-agent-forward — host ssh-agent forwarding via --vsock (ADR-0021)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 10c1..10c11. ADR-0021: host ssh-agent forwarding into the msb guest via
#              msb's `--vsock` flag (msb >= 0.6.9) + an in-guest socat bridge.
# ===========================================================================
# These exercise the neutral forward emitter (common.sh acq_host_socket_forwards
# + _acq_valid_vsock_port) and the msb adapter's translation to --vsock create
# flags, the version gate, the socat presence check, the bridge starter (from the
# in-provision flag AND from the persisted marker), and the SSH_AUTH_SOCK env
# injection into run/attach. bash can't bind an AF_UNIX socket, so we mint a real
# socket with python3 for the `[ -S ... ]` positive cases; a plain file models the
# "set but not a socket" case. All calls are logged to $CALLS and asserted there.

# Whether we can create a real unix socket at all (needs python3 with AF_UNIX).
# On a host without it, skip the socket-dependent asserts loudly rather than
# silently passing a weaker check.
_mk_unix_socket() {
  # $1 = path. Returns 0 iff a real socket was created there.
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])' "$1" >/dev/null 2>&1 && [ -S "$1" ]
}

# 10c1. create emits `--vsock <sock>:3552/stream` for the host ssh-agent when
#       SSH_AUTH_SOCK points at a REAL socket and msb >= 0.6.9. We call
#       _acq_msb_vsock_flags_into directly (the same helper acq_backend_provision
#       folds into `msb create … --vsock …`) and assert on the emitted flag.
make_stubs; load_acq
if _mk_unix_socket "$STUBDIR/agent.sock"; then
  c1_out=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent.sock" STUB_MSB_VERSION=0.6.9
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f; printf '%s\n' "${f[@]+"${f[@]}"}"
  )
  assert_contains "msb vsock(10c1): emits a --vsock flag for the host ssh-agent" "$c1_out" "--vsock"
  # canonicalize_path may resolve /tmp symlinks (e.g. macOS /var->/private/var),
  # so assert on the deterministic port/kind suffix rather than the full path.
  assert_contains "msb vsock(10c1): forward uses the fixed ssh-agent port/kind :3552/stream" "$c1_out" ":3552/stream"
else
  pass "msb vsock(10c1): SKIPPED (python3 AF_UNIX socket unavailable)"
fi
cleanup_stubs

# 10c2. No --vsock when neither SSH_AUTH_SOCK nor ACQ_FORWARD_HOST_SOCKETS is set:
#       forwarding is strictly opt-in (unsetting SSH_AUTH_SOCK is the opt-out).
make_stubs; load_acq
c2_out=$(
  unset SSH_AUTH_SOCK; unset ACQ_FORWARD_HOST_SOCKETS
  export STUB_MSB_VERSION=0.6.9
  . "${REPO_ROOT}/acq.backends/msb.sh"
  f=(); _acq_msb_vsock_flags_into f; printf '%s\n' "${f[@]+"${f[@]}"}"
)
assert_not_contains "msb vsock(10c2): no --vsock when no forward is requested" "$c2_out" "--vsock"
cleanup_stubs

# 10c3. Version gate: with a forward REQUESTED but msb 0.6.8 (below the 0.6.9
#       --vsock floor), the helper WARNS once and emits NO flags — forwarding is
#       opt-in convenience and must never turn a create into a hard failure.
make_stubs; load_acq
if _mk_unix_socket "$STUBDIR/agent.sock"; then
  c3_err=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent.sock" STUB_MSB_VERSION=0.6.8
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf '%s' "${f[@]+"${f[@]}"}"
  )
  assert_contains "msb vsock(10c3): sub-0.6.9 warns it needs the newer msb" "$c3_err" "needs msb >= 0.6.9"
  c3_out=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent.sock" STUB_MSB_VERSION=0.6.8
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}"
  )
  assert_not_contains "msb vsock(10c3): sub-0.6.9 emits no --vsock flag" "$c3_out" "--vsock"
else
  pass "msb vsock(10c3): SKIPPED (python3 AF_UNIX socket unavailable)"
fi
cleanup_stubs

# 10c4. SSH_AUTH_SOCK set but NOT a socket (points at a regular file): warn and
#       emit no forward. This is the guard against a stale/misconfigured env var
#       that would otherwise produce an opaque msb create failure.
make_stubs; load_acq
touch "$STUBDIR/not-a-socket"
c4_err=$(
  export SSH_AUTH_SOCK="$STUBDIR/not-a-socket" STUB_MSB_VERSION=0.6.9
  . "${REPO_ROOT}/acq.backends/msb.sh"
  f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf '%s' "${f[@]+"${f[@]}"}"
)
assert_contains "msb vsock(10c4): non-socket SSH_AUTH_SOCK warns 'not a socket'" "$c4_err" "not a socket"
c4_out=$(
  export SSH_AUTH_SOCK="$STUBDIR/not-a-socket" STUB_MSB_VERSION=0.6.9
  . "${REPO_ROOT}/acq.backends/msb.sh"
  f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}"
)
assert_not_contains "msb vsock(10c4): non-socket SSH_AUTH_SOCK emits no --vsock" "$c4_out" "--vsock"
cleanup_stubs

# 10c5. General ACQ_FORWARD_HOST_SOCKETS: a valid PATH:PORT/kind entry emits a
#       custom --vsock forward at the requested port/kind (not the ssh-agent one).
make_stubs; load_acq
if _mk_unix_socket "$STUBDIR/custom.sock"; then
  c5_out=$(
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="$STUBDIR/custom.sock:6000/stream" STUB_MSB_VERSION=0.6.9
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}"
  )
  assert_contains "msb vsock(10c5): general forward emits the requested :6000/stream" "$c5_out" ":6000/stream"
else
  pass "msb vsock(10c5): SKIPPED (python3 AF_UNIX socket unavailable)"
fi
cleanup_stubs

# 10c6. Invalid ACQ_FORWARD_HOST_SOCKETS entries are individually skipped with a
#       warning (fail-closed on the entry, never abort). Exercises common.sh
#       acq_host_socket_forwards directly (the neutral emitter the msb wrapper
#       consumes): a relative path, a reserved/invalid port on a REAL socket, and
#       a missing socket each warn and emit no line.
make_stubs; load_acq
if _mk_unix_socket "$STUBDIR/real.sock"; then
  # (a) relative path -> skipped with a warning. NB: canonicalize_path (realpath)
  #     resolves a relative path against the cwd BEFORE the absolute-path check,
  #     so a relative entry that does not exist as a socket is caught by the
  #     "not an existing socket" guard (the "not absolute" branch is only reached
  #     when canonicalization is unavailable). Either way the entry is skipped
  #     with a warning and emits no line — which is what matters here.
  c6a_err=$(
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="rel.sock:6000"
    . "${REPO_ROOT}/acq.backends/common.sh"
    acq_host_socket_forwards 2>&1 1>/dev/null
  )
  assert_contains "msb vsock(10c6a): relative-path forward warns + skips" "$c6a_err" "skipping"
  c6a_out=$(
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="rel.sock:6000"
    . "${REPO_ROOT}/acq.backends/common.sh"
    acq_host_socket_forwards 2>/dev/null
  )
  assert_eq "msb vsock(10c6a): relative-path forward emits no line" "" "$c6a_out"
  # (b) reserved/invalid port (123) on an EXISTING socket -> "invalid"
  c6b_err=$(
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="$STUBDIR/real.sock:123"
    . "${REPO_ROOT}/acq.backends/common.sh"
    acq_host_socket_forwards 2>&1 1>/dev/null
  )
  assert_contains "msb vsock(10c6b): reserved port 123 warns 'invalid'" "$c6b_err" "invalid"
  c6b_out=$(
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="$STUBDIR/real.sock:123"
    . "${REPO_ROOT}/acq.backends/common.sh"
    acq_host_socket_forwards 2>/dev/null
  )
  assert_eq "msb vsock(10c6b): reserved-port forward emits no line" "" "$c6b_out"
  # (c) missing socket -> "not an existing socket"
  c6c_err=$(
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="/nonexistent/x.sock:6000"
    . "${REPO_ROOT}/acq.backends/common.sh"
    acq_host_socket_forwards 2>&1 1>/dev/null
  )
  assert_contains "msb vsock(10c6c): missing-socket forward warns 'not an existing socket'" "$c6c_err" "not an existing socket"
  c6c_out=$(
    unset SSH_AUTH_SOCK
    export ACQ_FORWARD_HOST_SOCKETS="/nonexistent/x.sock:6000"
    . "${REPO_ROOT}/acq.backends/common.sh"
    acq_host_socket_forwards 2>/dev/null
  )
  assert_eq "msb vsock(10c6c): missing-socket forward emits no line" "" "$c6c_out"
else
  pass "msb vsock(10c6): SKIPPED (python3 AF_UNIX socket unavailable)"
fi
cleanup_stubs

# 10c7. _acq_valid_vsock_port boundaries: integer in 1..4294967294 and != 123.
#       Called directly on the loaded common.sh. Assert on the captured $?.
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/common.sh"
  set +e
  _acq_valid_vsock_port 0;          printf 'p0=%s\n'    "$?"
  _acq_valid_vsock_port 1;          printf 'p1=%s\n'    "$?"
  _acq_valid_vsock_port 123;        printf 'p123=%s\n'  "$?"
  _acq_valid_vsock_port 4294967294; printf 'pmax=%s\n'  "$?"
  _acq_valid_vsock_port 4294967295; printf 'pover=%s\n' "$?"
  _acq_valid_vsock_port abc;        printf 'pabc=%s\n'  "$?"
) > "$STUBDIR/portcheck.out" 2>/dev/null
c7=$(cat "$STUBDIR/portcheck.out")
assert_contains "msb vsock(10c7): port 0 is rejected"          "$c7" "p0=1"
assert_contains "msb vsock(10c7): port 1 is accepted"          "$c7" "p1=0"
assert_contains "msb vsock(10c7): reserved port 123 rejected"  "$c7" "p123=1"
assert_contains "msb vsock(10c7): port 4294967294 accepted"    "$c7" "pmax=0"
assert_contains "msb vsock(10c7): port 4294967295 rejected"    "$c7" "pover=1"
assert_contains "msb vsock(10c7): non-integer port rejected"   "$c7" "pabc=1"
cleanup_stubs

# 10c8. Bridge start (provision path): with the in-provision forwarding flag set,
#       _acq_msb_start_ssh_agent_bridge runs a `nohup socat UNIX-LISTEN … VSOCK-
#       CONNECT:2:3552` in the guest and records the guest sock path to the
#       /var/lib/acq/ssh-auth-sock persistence marker.
make_stubs; load_acq
(
  export STUB_MSB_VERSION=0.6.9
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _ACQ_MSB_SSH_AGENT_FORWARDING=1
  _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
  wait
)
c8_log=$(cat "$CALLS")
assert_contains "msb vsock(10c8): starts the in-guest socat UNIX-LISTEN bridge" \
  "$c8_log" "socat UNIX-LISTEN:'/home/agent/.acq/ssh-agent.sock'"
assert_contains "msb vsock(10c8): bridge connects to the ssh-agent vsock port (VSOCK-CONNECT:2:3552)" \
  "$c8_log" "VSOCK-CONNECT:2:'3552'"
assert_contains "msb vsock(10c8): records the guest sock in the persistence marker" \
  "$c8_log" "/var/lib/acq/ssh-auth-sock"
cleanup_stubs

# 10c9. Bridge start (acq_backend_start path): with NO in-provision flag, the
#       starter resolves the guest sock from the PERSISTED marker
#       (_acq_msb_ssh_auth_sock_for) and starts the bridge. A negative pair: with
#       the flag unset AND an EMPTY marker, it emits no socat call (forwarding was
#       never configured for this sandbox).
make_stubs; load_acq
(
  export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _ACQ_MSB_SSH_AGENT_FORWARDING=0
  _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
  wait
)
c9_log=$(cat "$CALLS")
assert_contains "msb vsock(10c9): start path reads the marker and starts the bridge" \
  "$c9_log" "socat UNIX-LISTEN:'/home/agent/.acq/ssh-agent.sock'"
# Negative: no flag, empty marker -> nothing to bridge.
make_stubs; load_acq
(
  export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _ACQ_MSB_SSH_AGENT_FORWARDING=0
  _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
  wait
)
c9n_log=$(cat "$CALLS")
assert_not_contains "msb vsock(10c9): empty marker + no flag starts no bridge" \
  "$c9n_log" "socat UNIX-LISTEN"
cleanup_stubs

# 10c10. socat missing: _acq_msb_check_socat warns and returns non-zero, so the
#        provision idiom `check_socat && start_bridge` short-circuits and NO
#        bridge is started. STUB_SOCAT_PRESENT=0 forces the guest probe to miss.
make_stubs; load_acq
c10_out=$(
  export STUB_MSB_VERSION=0.6.9 STUB_SOCAT_PRESENT=0
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _ACQ_MSB_SSH_AGENT_FORWARDING=1
  _acq_msb_check_socat sbox 2>&1; printf 'RC=%s\n' "$?"
)
assert_contains "msb vsock(10c10): missing socat returns non-zero" "$c10_out" "RC=1"
assert_contains "msb vsock(10c10): missing socat warns 'socat not found'" "$c10_out" "socat not found"
# The provision short-circuit must NOT start the bridge when socat is absent.
make_stubs; load_acq
(
  export STUB_MSB_VERSION=0.6.9 STUB_SOCAT_PRESENT=0
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _ACQ_MSB_SSH_AGENT_FORWARDING=1
  _acq_msb_check_socat sbox && _acq_msb_start_ssh_agent_bridge sbox
  wait
) >/dev/null 2>&1
c10_log=$(cat "$CALLS")
assert_not_contains "msb vsock(10c10): missing socat skips the bridge (no UNIX-LISTEN)" \
  "$c10_log" "socat UNIX-LISTEN"
cleanup_stubs

# 10c11. SSH_AUTH_SOCK injection: when the persistence marker is present,
#        acq_backend_run and the attach path add `-e SSH_AUTH_SOCK=<sock>` so
#        git/ssh in the guest reach the forwarded agent. A negative: with an
#        EMPTY marker, no SSH_AUTH_SOCK env is added.
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_run sbox -- git status >/dev/null 2>&1
)
c11_run_log=$(cat "$CALLS")
assert_contains "msb vsock(10c11): run injects SSH_AUTH_SOCK when marker present" \
  "$c11_run_log" "SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock"
# attach uses `exec msb …`, which replaces the shell — run it in a subshell so the
# exec targets the stub (logs, exits) without killing the harness.
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=/home/agent/.acq/ssh-agent.sock
  . "${REPO_ROOT}/acq.backends/msb.sh"
  ( _acq_msb_attach sbox </dev/null >/dev/null 2>&1 )
)
c11_att_log=$(cat "$CALLS")
assert_contains "msb vsock(10c11): attach injects SSH_AUTH_SOCK when marker present" \
  "$c11_att_log" "SSH_AUTH_SOCK="
# Negative: empty marker -> no SSH_AUTH_SOCK env on the run line.
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_SSH_AUTH_SOCK=
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_run sbox -- git status >/dev/null 2>&1
)
c11_neg_log=$(cat "$CALLS")
assert_not_contains "msb vsock(10c11): run omits SSH_AUTH_SOCK when marker empty" \
  "$c11_neg_log" "SSH_AUTH_SOCK="
# 10c12. (review MAJOR #1) The AUTOMATIC ssh-agent port is validated the SAME way
#        as the general path: an overridden ACQ_SSH_AGENT_VSOCK_PORT that is
#        invalid (reserved 123, or non-integer) must be rejected host-side with a
#        warning and emit NO --vsock, rather than reaching `msb create` as an
#        opaque failure (SI-10). A valid override still emits on that port.
make_stubs; load_acq
if _mk_unix_socket "$STUBDIR/agent.sock"; then
  c12_bad=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent.sock" STUB_MSB_VERSION=0.6.9 ACQ_SSH_AGENT_VSOCK_PORT=123
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>"$STUBDIR/c12.err"; printf '%s\n' "${f[@]+"${f[@]}"}"
    cat "$STUBDIR/c12.err"
  )
  assert_not_contains "msb vsock(10c12): invalid ssh-agent port emits no --vsock" "$c12_bad" "--vsock"
  assert_contains "msb vsock(10c12): invalid ssh-agent port warns (ACQ_SSH_AGENT_VSOCK_PORT)" "$c12_bad" "ACQ_SSH_AGENT_VSOCK_PORT"
  # A VALID override is honored on that port (route + emit agree on the value).
  c12_ok=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent.sock" STUB_MSB_VERSION=0.6.9 ACQ_SSH_AGENT_VSOCK_PORT=9000
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}"
  )
  assert_contains "msb vsock(10c12): valid ssh-agent port override is honored" "$c12_ok" ":9000/stream"
else
  pass "msb vsock(10c12): SKIPPED (python3 AF_UNIX socket unavailable)"
fi
cleanup_stubs

# 10c13. (review MAJOR #2) The published --vsock route port and the in-guest socat
#        bridge's VSOCK-CONNECT target must be the SAME value even when the user
#        overrides ACQ_SSH_AGENT_VSOCK_PORT. Otherwise the route is on one port and
#        socat connects to another -> a silently dead bridge. Assert both agree.
make_stubs; load_acq
if _mk_unix_socket "$STUBDIR/agent.sock"; then
  : > "$CALLS"
  (
    export SSH_AUTH_SOCK="$STUBDIR/agent.sock" STUB_MSB_VERSION=0.6.9 ACQ_SSH_AGENT_VSOCK_PORT=9000
    . "${REPO_ROOT}/acq.backends/msb.sh"
    # Route port (what --vsock publishes) and bridge port (what socat connects to)
    # both derive from the SAME resolved constant.
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf 'ROUTE %s\n' "${f[@]+"${f[@]}"}"
    _acq_msb_start_ssh_agent_bridge sbox >/dev/null 2>&1
    wait
  )
  c13=$(cat "$CALLS")
  c13_route=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent.sock" STUB_MSB_VERSION=0.6.9 ACQ_SSH_AGENT_VSOCK_PORT=9000
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}"
  )
  assert_contains "msb vsock(10c13): route uses the overridden port" "$c13_route" ":9000/stream"
  assert_contains "msb vsock(10c13): socat bridge connects to the SAME overridden port" \
    "$c13" "VSOCK-CONNECT:2:'9000'"
else
  pass "msb vsock(10c13): SKIPPED (python3 AF_UNIX socket unavailable)"
fi

# 10c15. (review NON-BLOCKING) The implicit ssh-agent forward is surfaced as a
#        CONSCIOUS choice: when a forward is emitted, the msb helper prints a
#        one-time notice naming the SSH_AUTH_SOCK opt-out and the ssh-add -c
#        mitigation (ADR-0021). A user who always exports SSH_AUTH_SOCK otherwise
#        forwards their agent silently. (Uses a DISTINCT socket path: 10c13 above
#        already bound $STUBDIR/agent.sock, and _mk_unix_socket cannot re-bind an
#        existing socket path.)
if _mk_unix_socket "$STUBDIR/agent15.sock"; then
  c15_err=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent15.sock" STUB_MSB_VERSION=0.6.9
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}" >/dev/null
  )
  assert_contains "msb vsock(10c15): forward prints a trust-boundary notice" "$c15_err" "forwarding your host ssh-agent"
  assert_contains "msb vsock(10c15): notice names the SSH_AUTH_SOCK opt-out" "$c15_err" "unset SSH_AUTH_SOCK to opt out"
  assert_contains "msb vsock(10c15): notice surfaces the ssh-add -c mitigation" "$c15_err" "ssh-add -c"
  # The notice is printed at most ONCE per process even if the helper runs twice.
  c15_count=$(
    export SSH_AUTH_SOCK="$STUBDIR/agent15.sock" STUB_MSB_VERSION=0.6.9
    . "${REPO_ROOT}/acq.backends/msb.sh"
    f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}" >/dev/null
    # Invoke a SECOND time in the same process: the notice must NOT repeat
    # (guarded by the module-scope _ACQ_MSB_SSH_AGENT_NOTICE_SHOWN flag). Reuse
    # the same array and read it so shellcheck sees the assignment used.
    f=(); _acq_msb_vsock_flags_into f 2>&1 1>/dev/null; printf '%s\n' "${f[@]+"${f[@]}"}" >/dev/null
  ) 2>&1
  n=$(printf '%s\n' "$c15_count" | grep -c "forwarding your host ssh-agent" || true)
  assert_eq "msb vsock(10c15): notice prints at most once per process" "1" "$n"
else
  pass "msb vsock(10c15): SKIPPED (python3 AF_UNIX socket unavailable)"
fi
unset -f _mk_unix_socket
cleanup_stubs

# 10c14. (review NIT) The ACQ_MSB_SSH_AGENT_GUEST_SOCK override is interpolated
#        into a root/agent `sh -c` string, so it MUST be validated on the WHOLE
#        string (not just the leading chars): a crafted absolute path carrying a
#        single quote / `$(...)` must be rejected and fall back to the safe
#        default, closing an sh -c break-out. A safe override is honored.
make_stubs; load_acq
c14_bad=$(
  export STUB_MSB_VERSION=0.6.9 ACQ_MSB_SSH_AGENT_GUEST_SOCK="/x'; touch /tmp/PWNED; :'"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  printf '%s\n' "$ACQ_MSB_SSH_AGENT_GUEST_SOCK"
)
assert_eq "msb vsock(10c14): unsafe guest-sock override falls back to default" \
  "/home/agent/.acq/ssh-agent.sock" "$c14_bad"
c14_ok=$(
  export STUB_MSB_VERSION=0.6.9 ACQ_MSB_SSH_AGENT_GUEST_SOCK="/home/agent/.acq/custom-agent.sock"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  printf '%s\n' "$ACQ_MSB_SSH_AGENT_GUEST_SOCK"
)
assert_eq "msb vsock(10c14): safe guest-sock override is honored" \
  "/home/agent/.acq/custom-agent.sock" "$c14_ok"
c14_rel=$(
  export STUB_MSB_VERSION=0.6.9 ACQ_MSB_SSH_AGENT_GUEST_SOCK="relative/agent.sock"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  printf '%s\n' "$ACQ_MSB_SSH_AGENT_GUEST_SOCK"
)
assert_eq "msb vsock(10c14): non-absolute guest-sock override falls back to default" \
  "/home/agent/.acq/ssh-agent.sock" "$c14_rel"
cleanup_stubs

# 10c. msb prerequisite check: warns when the base image lacks a kit tool, and
#      is silent when all are present / when ACQ_MSB_SKIP_PREREQ_CHECK is set.
#      (Uses a dedicated msb stub whose `command -v` loop reports the missing set.)
make_stubs; load_acq
PQSTUB="$STUBDIR/pq"; mkdir -p "$PQSTUB"
cat >"$PQSTUB/msb" <<'PQ'
#!/usr/bin/env bash
snip=""; prev=""; for a in "$@"; do [ "$prev" = "-c" ] && { snip="$a"; break; }; prev="$a"; done
case "$1" in --version) echo "msb 0.6.9"; exit 0;; esac
# The prereq check runs a snippet containing "command -v"; emit MSB_MISSING.
case "$snip" in *"command -v"*) printf '%s' "${MSB_MISSING:-}"; exit 0;; esac
exit 0
PQ
chmod +x "$PQSTUB/msb"
missing_out=$(
  export ACQ_SCRIPT_DIR="$REPO_ROOT"; . "${REPO_ROOT}/acq.backends/common.sh"
  export PATH="$PQSTUB:$PATH" MSB_MISSING=" node git"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_check_prereqs testbox 2>&1
)
assert_contains "msb: prereq check warns on missing tools" "$missing_out" "missing kit prerequisite"
present_out=$(
  export ACQ_SCRIPT_DIR="$REPO_ROOT"; . "${REPO_ROOT}/acq.backends/common.sh"
  export PATH="$PQSTUB:$PATH" MSB_MISSING=""
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_check_prereqs testbox 2>&1
)
assert_not_contains "msb: prereq check silent when all present" "$present_out" "missing kit prerequisite"
skip_out=$(
  export ACQ_SCRIPT_DIR="$REPO_ROOT"; . "${REPO_ROOT}/acq.backends/common.sh"
  export PATH="$PQSTUB:$PATH" MSB_MISSING=" node" ACQ_MSB_SKIP_PREREQ_CHECK=1
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_check_prereqs testbox 2>&1
)
assert_not_contains "msb: prereq check honors SKIP flag" "$skip_out" "missing kit prerequisite"
cleanup_stubs

