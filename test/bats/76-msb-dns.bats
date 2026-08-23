#!/usr/bin/env bats
#
# 76-msb-dns.bats — bats port of scripts/test-acq.d/76-msb-dns.sh (ADR-0019/0025)
#
# msb provision must pass --dns-nameserver (the guest can't reach the host's
# corporate resolver), a generous default --memory/--cpus (msb's 512MiB/1vCPU
# OOM-kills a Node TUI), and honor / validate the ACQ_MSB_* overrides. Each case
# runs a real acq_backend_provision in an isolated subshell and inspects $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
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
    acq_backend_provision "$name" shell /tmp 2>&1 >/dev/null
  ' _ "$name" "$@"
}

@test "msb: provision sets --dns-nameserver 1.1.1.1 by default" {
  _provision dnsbox
  run cat "$CALLS"
  assert_output --partial '--dns-nameserver 1.1.1.1'
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
