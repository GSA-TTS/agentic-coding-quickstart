#!/usr/bin/env bash
#
# 112-msb-ports — post-hoc port publish + LIST mode (ADR-0015, 10b2..10b11)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 10b2. ADR-0015: post-hoc `acq ports <sandbox> --publish H:G` on the msb backend
#       authorizes the acq-managed key (once), starts `msb ssh serve … --port <n>`,
#       and opens `ssh … -L 127.0.0.1:H:127.0.0.1:G …`. The key lives under acq
#       state (NOT ~/.ssh); ports/PIDs are recorded for teardown.
make_stubs; load_acq
: > "$CALLS"
# Pin the ephemeral serve port via the test seam (ACQ_MSB_FORCE_SERVE_PORT) so
# the `msb ssh serve … --port <n>` and `ssh -p <n>` argv are deterministic and
# the assertions below don't race the counter/$RANDOM value.
(
  export ACQ_MSB_FORCE_SERVE_PORT=54321
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 >/dev/null 2>&1
  # `msb ssh serve` and `ssh -L` are BACKGROUNDED by acq; wait for the stubbed
  # children to finish appending to $CALLS before the subshell exits, else the
  # `cat "$CALLS"` below races an incomplete log (test-side flake).
  wait
)
pub_log=$(cat "$CALLS")
assert_contains "msb ports: generates the acq-managed ssh key (ssh-keygen -t ed25519)" \
  "$pub_log" "ssh-keygen -t ed25519 -N  -f $STUBDIR/state/ssh/msb_id_ed25519"
assert_contains "msb ports: authorizes the acq public key via msb ssh authorize" \
  "$pub_log" "msb ssh authorize --file $STUBDIR/state/ssh/msb_id_ed25519.pub"
assert_contains "msb ports: starts msb ssh serve on an ephemeral loopback port" \
  "$pub_log" "msb ssh serve pbox --host 127.0.0.1 --port 54321"
assert_contains "msb ports: opens ssh -L 127.0.0.1:8080:127.0.0.1:3000 tunnel" \
  "$pub_log" "-L 127.0.0.1:8080:127.0.0.1:3000"
assert_contains "msb ports: ssh uses the acq-managed key (-i)" \
  "$pub_log" "-i $STUBDIR/state/ssh/msb_id_ed25519"
assert_contains "msb ports: ssh pins a dedicated known_hosts under acq state" \
  "$pub_log" "UserKnownHostsFile=$STUBDIR/state/ssh/known_hosts"
# NIT (review): ssh uses ONLY the acq -i key and ignores the user's ssh_config,
# so a loaded agent key can't burn MaxAuthTries and ~/.ssh/config can't alter
# the hermetic loopback tunnel.
assert_contains "msb ports: ssh pins IdentitiesOnly=yes (only the acq -i key)" \
  "$pub_log" "IdentitiesOnly=yes"
assert_contains "msb ports: ssh ignores user ssh_config (-F none)" \
  "$pub_log" "-F none"
# The recorded PID/state file exists after publishing (teardown target).
[ -f "$STUBDIR/state/ports/pbox.pids" ] \
  && pass "msb ports: records serve/ssh PIDs in acq state" \
  || fail "msb ports: records serve/ssh PIDs in acq state" "pbox.pids missing"
cleanup_stubs

# 10b2a. (review S2) A backgrounded `msb ssh serve` that dies immediately (e.g.
#        cannot bind) must NOT be reported as a successful publish: acq's
#        liveness probe should fail the publish non-zero, print no "published
#        host" line, and record no PID state file (nothing was actually forwarded).
make_stubs; load_acq
: > "$CALLS"
serve_die_out=$(
  export ACQ_MSB_FORCE_SERVE_PORT=54321 STUB_MSB_SERVE_DIE=1
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 2>&1
  echo "RC=$?"
  wait
)
assert_contains "msb ports(S2): dead serve fails the publish non-zero" "$serve_die_out" "RC=1"
assert_not_contains "msb ports(S2): dead serve prints no 'published host' success" "$serve_die_out" "published host"
[ ! -f "$STUBDIR/state/ports/pbox.pids" ] \
  && pass "msb ports(S2): dead serve records no PID state file" \
  || fail "msb ports(S2): dead serve records no PID state file" "pbox.pids should not exist"
cleanup_stubs

# 10b2b. (review S2) A backgrounded `ssh -L` forward that dies immediately (e.g.
#        ExitOnForwardFailure fires) must NOT be reported as success: the publish
#        fails non-zero, tears the serve listener back down, and records no state.
make_stubs; load_acq
: > "$CALLS"
fwd_die_out=$(
  export ACQ_MSB_FORCE_SERVE_PORT=54321 STUB_SSH_DIE=1
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 2>&1
  echo "RC=$?"
  wait
)
assert_contains "msb ports(S2): dead forward fails the publish non-zero" "$fwd_die_out" "RC=1"
assert_not_contains "msb ports(S2): dead forward prints no 'published host' success" "$fwd_die_out" "published host"
[ ! -f "$STUBDIR/state/ports/pbox.pids" ] \
  && pass "msb ports(S2): dead forward records no PID state file" \
  || fail "msb ports(S2): dead forward records no PID state file" "pbox.pids should not exist"
cleanup_stubs

# 10b3. `acq ports --publish` authorizes the key ONCE — a second publish reuses
#       the existing key and the .authorized marker (no re-keygen, no re-authorize).
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 >/dev/null 2>&1
  wait                # let the 1st publish's backgrounded serve/ssh log first
  : > "$CALLS"   # clear, then a SECOND publish
  acq_backend_ports pbox --publish 9090:4000 >/dev/null 2>&1
  wait                # drain the 2nd publish's backgrounded children before read
)
pub2_log=$(cat "$CALLS")
assert_not_contains "msb ports: 2nd publish does not re-run ssh-keygen" "$pub2_log" "ssh-keygen"
assert_not_contains "msb ports: 2nd publish does not re-authorize the key" "$pub2_log" "msb ssh authorize"
assert_contains "msb ports: 2nd publish still opens its own -L tunnel" "$pub2_log" "-L 127.0.0.1:9090:127.0.0.1:4000"
cleanup_stubs

# 10b3a. Two publishes in the SAME process must get DISTINCT serve ports.
#        No seam here — this exercises the real distinct-per-call selection. The
#        recorded state file has one line per publish: `<serve_pid> <ssh_pid>
#        <sport> <mapping>`; assert the two <sport> columns differ.
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports mpbox --publish 8080:3000 >/dev/null 2>&1
  acq_backend_ports mpbox --publish 9090:4000 >/dev/null 2>&1
  wait
)
mp_ports=$(awk '{print $3}' "$STUBDIR/state/ports/mpbox.pids" 2>/dev/null | sort -u | wc -l | tr -d ' ')
mp_lines=$(wc -l < "$STUBDIR/state/ports/mpbox.pids" 2>/dev/null | tr -d ' ')
{ [ "$mp_lines" = "2" ] && [ "$mp_ports" = "2" ]; } \
  && pass "msb ports: two publishes in one process get DISTINCT serve ports" \
  || fail "msb ports: two publishes in one process get DISTINCT serve ports" "lines=$mp_lines distinct-ports=$mp_ports"
cleanup_stubs

# 10b4. SI-10: invalid --publish values are REJECTED before any ssh/serve call.
#       0, 70000 (>65535), and non-integer "abc:def" all fail non-zero with no
#       ssh/serve/keygen in the call log.
for bad in "0:3000" "8080:70000" "abc:def" "8080"; do
  make_stubs; load_acq
  : > "$CALLS"
  rc=0
  bad_out=$(
    . "${REPO_ROOT}/acq.backends/msb.sh"
    acq_backend_ports badbox --publish "$bad" 2>&1
  ) || rc=$?
  bad_log=$(cat "$CALLS")
  [ "$rc" -ne 0 ] && pass "msb ports: rejects invalid --publish '$bad' (non-zero exit)" \
    || fail "msb ports: rejects invalid --publish '$bad' (non-zero exit)" "rc=$rc"
  assert_not_contains "msb ports: '$bad' reaches no ssh -L" "$bad_log" "-L 127.0.0.1"
  assert_not_contains "msb ports: '$bad' reaches no msb ssh serve" "$bad_log" "msb ssh serve"
  cleanup_stubs
done

# 10b5. Capability flag: msb now advertises post-hoc port forwarding (ADR-0015).
flag_val=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  printf '%s' "$ACQ_BACKEND_SUPPORTS_PORT_FORWARD"
)
assert_eq "msb: SUPPORTS_PORT_FORWARD is now 1 (post-hoc publish wired)" "1" "$flag_val"

# 10b6. TEARDOWN: acq_backend_terminate (rm) and acq_backend_stop both clean up
#       the recorded serve/ssh PIDs + state file for the sandbox (defensive:
#       killing dead PIDs is a no-op, and a missing state file is fine).
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports rmbox --publish 8080:3000 >/dev/null 2>&1
  [ -f "$STUBDIR/state/ports/rmbox.pids" ] || exit 3
  acq_backend_terminate rmbox >/dev/null 2>&1
)
[ ! -f "$STUBDIR/state/ports/rmbox.pids" ] \
  && pass "msb ports: acq rm tears down recorded port state" \
  || fail "msb ports: acq rm tears down recorded port state" "rmbox.pids still present"
# stop path + defensive no-op on a sandbox that never published a port.
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports stopbox --publish 7000:7000 >/dev/null 2>&1
  acq_backend_stop stopbox >/dev/null 2>&1
  acq_backend_terminate neverbox >/dev/null 2>&1   # no state file -> must not error
) && pass "msb ports: stop tears down; teardown of an un-published sandbox is a no-op" \
  || fail "msb ports: stop tears down; teardown of an un-published sandbox is a no-op" "teardown errored"
[ ! -f "$STUBDIR/state/ports/stopbox.pids" ] \
  && pass "msb ports: acq stop removes recorded port state" \
  || fail "msb ports: acq stop removes recorded port state" "stopbox.pids still present"
cleanup_stubs

# 10b7. Path-traversal guard: an unsafe sandbox name (slash / leading '..') must
#       NOT let the per-sandbox PID state path escape ACQ_MSB_PORTS_DIR on either
#       the record (>>) or teardown (rm -f) path. record is a fail-closed no-op;
#       teardown of an unsafe name touches no file outside the ports dir.
make_stubs; load_acq
: > "$CALLS"
mkdir -p "$STUBDIR/state/ports"
canary="$STUBDIR/state/traversal-canary.pids"
printf 'DO-NOT-DELETE\n' >"$canary"
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # record with a traversal name must write nothing outside the ports dir.
  _acq_msb_ports_record "../traversal-canary" 111 222 20001 8080:3000 >/dev/null 2>&1
  # teardown with a traversal name must not rm -f the canary above it.
  _acq_msb_ports_teardown "../traversal-canary" >/dev/null 2>&1
)
[ -f "$canary" ] \
  && pass "msb ports: unsafe sandbox name cannot escape state dir (rm -f/append guarded)" \
  || fail "msb ports: unsafe sandbox name cannot escape state dir (rm -f/append guarded)" "canary deleted"
[ ! -e "$STUBDIR/state/traversal-canary.pids.pids" ] \
  && pass "msb ports: unsafe sandbox name records no state file" \
  || fail "msb ports: unsafe sandbox name records no state file" "escaped record written"
rm -f "$canary" 2>/dev/null || true
cleanup_stubs

# 10b8. LIST mode: `acq ports <name>` with NO --publish is a QUERY, not an
#       error. It must exit 0 and print lines CONTAINING the published port
#       numbers so openchamber verify's `grep -q <port>` matches. Two sources:
#       (a) create-time `-p` NAT mappings via `msb inspect --format json`, and
#       (b) acq-recorded post-hoc ssh -L tunnels. Both surfaced together.
make_stubs; load_acq
# (a) plant a create-time published-ports JSON fixture for `msb inspect` using the
#     REAL msb 0.6.7 shape: ports live under active_config.network.ports[] as
#     {host_port, guest_port, host_bind, protocol}. host_bind carries a dotted IP
#     (127.0.0.1) that must NOT be mistaken for port digits. The third entry binds
#     host_bind to a colon-bearing "127.0.0.1:9" form (the exact shape that caused
#     the live bug) so the no-junk assert below is a TRUE regression guard: the old
#     parser split that colon and emitted `guest 9 -> host 127.0.0.1:1`, while the
#     current parser keys on the explicit *_port fields and yields 8443 correctly.
printf '%s\n' '{"active_config":{"network":{"ports":[{"guest_port":3000,"host_bind":"127.0.0.1","host_port":3000,"protocol":"tcp"},{"guest_port":4096,"host_bind":"127.0.0.1","host_port":4096,"protocol":"tcp"},{"guest_port":8443,"host_bind":"127.0.0.1:9","host_port":8443,"protocol":"tcp"}]}},"name":"listbox","status":"Running"}' \
  >"$STUBDIR/.msb_inspect_json"
list_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # (b) also seed a recorded post-hoc tunnel so both sources appear.
  _acq_msb_ports_record listbox 111 222 54321 9090:8080
  acq_backend_ports listbox
) ; list_rc=$?
assert_eq "msb ports: LIST mode (no --publish) exits 0 (query, not error)" "0" "$list_rc"
printf '%s\n' "$list_out" | grep -q 3000 \
  && pass "msb ports: LIST surfaces create-time port 3000 (grep -q 3000 matches)" \
  || fail "msb ports: LIST surfaces create-time port 3000" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -q 4096 \
  && pass "msb ports: LIST surfaces create-time port 4096 (grep -q 4096 matches)" \
  || fail "msb ports: LIST surfaces create-time port 4096" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -q 8080 \
  && pass "msb ports: LIST surfaces post-hoc recorded guest port 8080" \
  || fail "msb ports: LIST surfaces post-hoc recorded guest port 8080" "out=[$list_out]"
# The create-time lines must be EXACT (no host_bind dotted-IP or SocketAddr digits
# leaking in as ports). The old numeric-pairing parser split the colon in the
# third entry's host_bind ("127.0.0.1:9") and emitted `guest 9 -> host 127.0.0.1:1`
# instead of the real 8443:8443 mapping — these asserts fail against that old code.
printf '%s\n' "$list_out" | grep -q 'sandbox 3000 -> host 127.0.0.1:3000 (create-time -p)' \
  && pass "msb ports: LIST prints exact create-time mapping for 3000 (no host_bind leak)" \
  || fail "msb ports: LIST exact create-time mapping for 3000" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -q 'sandbox 8443 -> host 127.0.0.1:8443 (create-time -p)' \
  && pass "msb ports: LIST maps colon-bearing host_bind entry to real port 8443 (not split)" \
  || fail "msb ports: LIST exact create-time mapping for 8443 (colon-bearing host_bind)" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -Eq '127\.0\.0\.1:(1|9|16|00|256)( |$)' \
  && fail "msb ports: LIST must NOT emit host_bind-derived junk ports" "out=[$list_out]" \
  || pass "msb ports: LIST emits no host_bind-derived junk ports (IP/SocketAddr not split)"
cleanup_stubs

# 10b9. LIST mode is graceful when there are NO ports at all (no inspect fixture,
#       no recorded tunnel): exit 0, no crash, empty (or portless) output.
make_stubs; load_acq
# none_out captures output only to confirm no crash; we assert on the exit code.
# shellcheck disable=SC2034
none_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports emptybox
) ; none_rc=$?
assert_eq "msb ports: LIST with zero ports exits 0 (empty list not an error)" "0" "$none_rc"
cleanup_stubs

# 10b10. LIST mode degrades gracefully when msb's JSON has NO recognizable port
#        field (defensive: unknown field name / jq absent). Must NOT crash; still
#        exit 0. Here inspect returns JSON with an unrelated shape.
make_stubs; load_acq
printf '{"name":"absentbox","state":"running"}\n' >"$STUBDIR/.msb_inspect_json"
absent_rc=0
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports absentbox
) >/dev/null 2>&1 || absent_rc=$?
assert_eq "msb ports: LIST exits 0 when no port field found in msb JSON" "0" "$absent_rc"
cleanup_stubs

# 10b10a. LIST mode under the REAL `set -euo pipefail` acq runs with. This is the
#         regression guard for the live-host bug: when inspect has no ports, the
#         dependency-free `grep` (and jq) emit nothing and exit non-zero, which
#         under `set -e` aborted _acq_msb_ports_from_inspect BEFORE its return 0,
#         unwinding out of acq_backend_ports past its `return 0` and surfacing
#         rc=1 to the caller. The rest of test-acq runs WITHOUT -e, so it could
#         not catch this — assert it explicitly here with errexit ON.
make_stubs; load_acq
printf '{"active_config":{"network":{"ports":[]}}}\n' >"$STUBDIR/.msb_inspect_json"
strict_rc=0
(
  set -euo pipefail
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports emptybox
) >/dev/null 2>&1 || strict_rc=$?
assert_eq "msb ports: LIST exits 0 under set -euo pipefail with empty ports (live-host regression)" "0" "$strict_rc"
cleanup_stubs

# 10b11. Genuinely bad args still error (unsupported argument), LIST mode does
#        NOT swallow a bogus flag like --frobnicate.
make_stubs; load_acq
bad_rc=0
bad_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports badargbox --frobnicate 2>&1
) || bad_rc=$?
[ "$bad_rc" -ne 0 ] \
  && pass "msb ports: unsupported arg (--frobnicate) still errors non-zero" \
  || fail "msb ports: unsupported arg (--frobnicate) still errors non-zero" "rc=$bad_rc"
assert_contains "msb ports: unsupported arg names the offending flag" "$bad_out" "unsupported argument"
cleanup_stubs
