#!/usr/bin/env bats
#
# 76-msb-dns.bats — bats port of scripts/test-acq.d/76-msb-dns.sh (ADR-0019/0025)
#
# msb provision must leave guest DNS on the host's resolvers, turn msb's rebind
# protection off only when the host's own resolvers sit in 100.64/10 (ZPA, whose
# split-horizon answers are private-range), pass a generous default
# --memory/--cpus (msb's 512MiB/1vCPU OOM-kills a Node TUI), and honor /
# validate the ACQ_MSB_* overrides. Each case runs a real acq_backend_provision
# in an isolated subshell and inspects $CALLS. The host resolver listing is fed
# from a fixture (ACQ_TEST_HOST_RESOLVERS) so no case depends on the machine
# running the suite.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  printf 'nameserver 192.168.0.1\nnameserver 8.8.8.8\n' > "$STUBDIR/resolvers-public"
}
teardown() { acq_teardown_stubs; }

load 'helper'

# Run acq_backend_provision NAME with the given extra env, capturing both the
# $CALLS log (stdout of this helper) and any stderr warnings. `run` splits them:
# use `_provision_calls`/`_provision_stderr` as needed.
_provision() { # NAME ENV_ASSIGNMENTS...
  local name="$1"; shift
  : > "$CALLS"
  run bash -c '
    name="$1"; shift
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-$name"
    for kv in "$@"; do export "$kv"; done
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    _acq_msb_host_resolver_lines() { cat "${ACQ_TEST_HOST_RESOLVERS:-'"$STUBDIR"'/resolvers-public}"; }
    acq_backend_provision "$name" shell /tmp 2>&1 >/dev/null
  ' _ "$name" "$@"
}

@test "msb #439: provision leaves guest DNS on the host resolvers by default (no --dns-nameserver)" {
  _provision dnsbox
  run cat "$CALLS"
  refute_output --partial '--dns-nameserver'
}

_rebind_note='host resolvers are in 100.64/10 (ZPA); disabling guest DNS rebind protection'

@test "msb #439: auto disables rebind protection when a host resolver is in 100.64/10 (scutil format)" {
  printf '  nameserver[0] : 100.64.0.1\n  nameserver[1] : 100.64.0.2\n' > "$STUBDIR/resolvers-zpa"
  _provision rebindbox ACQ_TEST_HOST_RESOLVERS="$STUBDIR/resolvers-zpa"
  assert_output --partial "$_rebind_note"
  run cat "$CALLS"
  assert_output --partial '--no-dns-rebind-protection'
}

@test "msb #439: auto keeps rebind protection on a host without CGNAT resolvers" {
  _provision rebind2box
  refute_output --partial "$_rebind_note"
  run cat "$CALLS"
  refute_output --partial '--no-dns-rebind-protection'
}

@test "msb #439: auto matches any CGNAT resolver in a mixed list (resolv.conf format)" {
  printf 'nameserver 192.168.0.1\nnameserver 100.64.0.1\n' > "$STUBDIR/resolvers-mixed"
  _provision rebind3box ACQ_TEST_HOST_RESOLVERS="$STUBDIR/resolvers-mixed"
  run cat "$CALLS"
  assert_output --partial '--no-dns-rebind-protection'
}

@test "msb #439: auto matches 100.64.0.0/10 exactly, not all of 100/8" {
  printf 'nameserver 100.128.0.1\nnameserver 100.63.255.1\n' > "$STUBDIR/resolvers-near"
  _provision rebind4box ACQ_TEST_HOST_RESOLVERS="$STUBDIR/resolvers-near"
  run cat "$CALLS"
  refute_output --partial '--no-dns-rebind-protection'
  printf 'nameserver 100.127.255.254\n' > "$STUBDIR/resolvers-edge"
  _provision rebind5box ACQ_TEST_HOST_RESOLVERS="$STUBDIR/resolvers-edge"
  run cat "$CALLS"
  assert_output --partial '--no-dns-rebind-protection'
}

@test "msb #439: ACQ_MSB_DNS_REBIND_PROTECTION=1 keeps the protection even with a CGNAT resolver" {
  printf 'nameserver 100.64.0.1\n' > "$STUBDIR/resolvers-zpa"
  _provision rebind6box ACQ_MSB_DNS_REBIND_PROTECTION=1 ACQ_TEST_HOST_RESOLVERS="$STUBDIR/resolvers-zpa"
  refute_output --partial "$_rebind_note"
  run cat "$CALLS"
  refute_output --partial '--no-dns-rebind-protection'
}

@test "msb #439: ACQ_MSB_DNS_REBIND_PROTECTION=0 forces the protection off without a CGNAT resolver" {
  _provision rebind7box ACQ_MSB_DNS_REBIND_PROTECTION=0
  refute_output --partial "$_rebind_note"
  run cat "$CALLS"
  assert_output --partial '--no-dns-rebind-protection'
  _provision rebind8box ACQ_MSB_DNS_REBIND_PROTECTION=off
  run cat "$CALLS"
  assert_output --partial '--no-dns-rebind-protection'
}

@test "msb: ACQ_MSB_DNS_NAMESERVER override is honored; empty omits the flag" {
  _provision dns2box ACQ_MSB_DNS_NAMESERVER=9.9.9.9
  run cat "$CALLS"
  assert_output --partial '--dns-nameserver 9.9.9.9'

  _provision dns3box ACQ_MSB_DNS_NAMESERVER=
  run cat "$CALLS"
  refute_output --partial '--dns-nameserver'
}

@test "msb: provision sizes the guest generously by default (--memory 4G --cpus 2)" {
  _provision membox
  run cat "$CALLS"
  assert_output --partial '--memory 4G'
  assert_output --partial '--cpus 2'
}

@test "msb: ACQ_MSB_MEMORY / ACQ_MSB_CPUS overrides are honored" {
  _provision mem2box ACQ_MSB_MEMORY=8G ACQ_MSB_CPUS=4
  run cat "$CALLS"
  assert_output --partial '--memory 8G'
  assert_output --partial '--cpus 4'
}

@test "msb: empty ACQ_MSB_MEMORY / ACQ_MSB_CPUS omit the flags" {
  _provision mem3box ACQ_MSB_MEMORY= ACQ_MSB_CPUS=
  run cat "$CALLS"
  refute_output --partial '--memory'
  refute_output --partial '--cpus'
}

@test "msb: invalid ACQ_MSB_MEMORY/CPUS warn and never reach msb create" {
  _provision mem4box 'ACQ_MSB_MEMORY=4G; rm -rf /' ACQ_MSB_CPUS=two
  # _provision captured stderr+... into $output; the warnings are on stderr.
  assert_output --partial 'ignoring invalid ACQ_MSB_MEMORY'
  assert_output --partial 'ignoring invalid ACQ_MSB_CPUS'
  run cat "$CALLS"
  refute_output --partial 'rm -rf /'
  refute_output --partial 'msb create --name mem4box --memory 4G'
}
