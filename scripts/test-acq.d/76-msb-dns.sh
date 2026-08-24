#!/usr/bin/env bash
#
# 76-msb-dns — provision --dns-nameserver + ACQ_MSB_DNS_NAMESERVER (8p-8q)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 8p. msb provision passes --dns-nameserver so the guest can resolve allow-listed
#     hosts (the host's corporate resolver is unreachable from the microVM).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dns-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision dnsbox shell /tmp >/dev/null 2>&1
)
dns_log=$(cat "$CALLS")
assert_contains "msb: provision sets --dns-nameserver" "$dns_log" "--dns-nameserver 1.1.1.1"
cleanup_stubs

# 8q. ACQ_MSB_DNS_NAMESERVER override + disable (empty = omit the flag).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dns2-secrets" ACQ_MSB_DNS_NAMESERVER="9.9.9.9"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision dns2box shell /tmp >/dev/null 2>&1
)
assert_contains "msb: DNS nameserver override honored" "$(cat "$CALLS")" "--dns-nameserver 9.9.9.9"
cleanup_stubs

make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dns3-secrets" ACQ_MSB_DNS_NAMESERVER=""
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision dns3box shell /tmp >/dev/null 2>&1
)
assert_not_contains "msb: empty DNS nameserver omits the flag" "$(cat "$CALLS")" "--dns-nameserver"
cleanup_stubs

# 8q2. msb provision sizes the guest generously by default (memory + cpus).
#      msb's 512 MiB / 1 vCPU default OOM-kills a Node.js agent TUI (opencode
#      prints "Killed" on launch), so acq passes a generous default at create.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision membox shell /tmp >/dev/null 2>&1
)
mem_log=$(cat "$CALLS")
assert_contains "msb: provision sets a generous default --memory" "$mem_log" "--memory 4G"
assert_contains "msb: provision sets default --cpus" "$mem_log" "--cpus 2"
cleanup_stubs

# 8q3. ACQ_MSB_MEMORY / ACQ_MSB_CPUS overrides are honored.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem2-secrets" ACQ_MSB_MEMORY="8G" ACQ_MSB_CPUS="4"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mem2box shell /tmp >/dev/null 2>&1
)
mem2_log=$(cat "$CALLS")
assert_contains "msb: ACQ_MSB_MEMORY override honored" "$mem2_log" "--memory 8G"
assert_contains "msb: ACQ_MSB_CPUS override honored" "$mem2_log" "--cpus 4"
cleanup_stubs

# 8q4. Empty ACQ_MSB_MEMORY / ACQ_MSB_CPUS omit the flags (fall back to msb's
#      own default), and an invalid value is rejected with a warning (not passed
#      through, so it can't smuggle another flag onto the create line).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem3-secrets" ACQ_MSB_MEMORY="" ACQ_MSB_CPUS=""
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mem3box shell /tmp >/dev/null 2>&1
)
mem3_log=$(cat "$CALLS")
assert_not_contains "msb: empty ACQ_MSB_MEMORY omits the flag" "$mem3_log" "--memory"
assert_not_contains "msb: empty ACQ_MSB_CPUS omits the flag" "$mem3_log" "--cpus"
cleanup_stubs

make_stubs; load_acq
: > "$CALLS"
mem_bad_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem4-secrets" ACQ_MSB_MEMORY="4G; rm -rf /" ACQ_MSB_CPUS="two"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mem4box shell /tmp 2>&1 >/dev/null
)
mem4_log=$(cat "$CALLS")
assert_contains "msb: invalid ACQ_MSB_MEMORY warns" "$mem_bad_out" "ignoring invalid ACQ_MSB_MEMORY"
assert_contains "msb: invalid ACQ_MSB_CPUS warns" "$mem_bad_out" "ignoring invalid ACQ_MSB_CPUS"
# The injected payload (`4G; rm -rf /`) must never reach `msb create` as a memory
# value. Assert the specific injection is absent from the create invocation rather
# than the bare substring `rm -rf` (which legitimately appears elsewhere, e.g. the
# OCI self-test's temp-dir cleanup).
assert_not_contains "msb: invalid memory value not passed to create" "$mem4_log" "rm -rf /"
assert_not_contains "msb: injected memory not on msb create" "$mem4_log" "msb create --name mem4box --memory 4G"
cleanup_stubs
