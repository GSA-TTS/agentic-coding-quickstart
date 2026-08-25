#!/usr/bin/env bats
#
# 111-balanced-egress.bats — bats pilot port of a representative subset of
# scripts/test-acq.d/111-balanced-egress.sh (ADR-0025).
#
# Pilot for the INTERNAL-UNIT end of the spectrum: unlike 20-backend-resolution
# (which drives resolution end-to-end), these tests source acq.backends/msb.sh
# and call its pure helpers directly — `_acq_msb_balanced_target`,
# `_acq_msb_balanced_port_ok`, `_acq_msb_balanced_rules_into`. This is exactly
# the shape that, in the legacy suite, needed globals read by sourced code and so
# drew SC2034. The pilot measures whether bats' `run` + subshell model reduces
# that (it does for output-captured cases: no shared global to flag).
#
# NOTE: this ports a SUBSET (the pure-function seams) — enough to evaluate the
# pattern. A full migration would port the remaining provision-integration cases.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Source the msb adapter once per test (isolated subshell). Kept as a helper so
# each @test reads as intent, not boilerplate.
_load_msb() { . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null; }

@test "balanced_target: multi-label glob **.h -> suffix *.h" {
  _load_msb
  run _acq_msb_balanced_target '**.github.com'
  assert_success
  assert_output '*.github.com'
}

@test "balanced_target: intra-label crl*.h broadens to parent suffix *.<parent>" {
  _load_msb
  run _acq_msb_balanced_target 'crl*.digicert.com'
  assert_success
  assert_output '*.digicert.com'
}

@test "balanced_target: exact domain passes through unchanged" {
  _load_msb
  run _acq_msb_balanced_target 'api.anthropic.com'
  assert_success
  assert_output 'api.anthropic.com'
}

@test "balanced_target: single-label suffix *.com is dropped (nonzero, no output)" {
  _load_msb
  run _acq_msb_balanced_target '*.com'
  assert_failure
  assert_output ''
}

@test "balanced_port_ok: 443 and 80 are valid" {
  _load_msb
  run _acq_msb_balanced_port_ok 443
  assert_success
  run _acq_msb_balanced_port_ok 80
  assert_success
}

@test "balanced_port_ok: 0, 70000, empty, and non-integer are rejected" {
  _load_msb
  run _acq_msb_balanced_port_ok 0;     assert_failure
  run _acq_msb_balanced_port_ok 70000; assert_failure
  run _acq_msb_balanced_port_ok '';    assert_failure
  run _acq_msb_balanced_port_ok '4a3'; assert_failure
}

# _acq_msb_balanced_rules_into writes into a caller-named array. bats' `run`
# captures stdout, so we print the array and assert on lines — no shared global
# leaks across the source boundary (the SC2034 seam the legacy version had).
@test "balanced_rules_into: translates a hosts file to msb allow rules" {
  _load_msb
  cat >"$STUBDIR/bal-hosts.txt" <<'HOSTS'
# a comment line

**.github.com:443
github.com:443
dhi.io:443
dhi.io:80
crl*.digicert.com:80
example.org
HOSTS
  run env ACQ_MSB_BALANCED_HOSTS_FILE="$STUBDIR/bal-hosts.txt" bash -c '
    . "'"${REPO_ROOT}"'/acq.backends/msb.sh" 2>/dev/null
    arr=()
    _acq_msb_balanced_rules_into arr 2>/dev/null
    printf "%s\n" "${arr[@]}"
  '
  assert_success
  assert_output --partial 'allow@dns'
  refute_output --partial 'allow@host:udp:53'
  assert_output --partial 'allow@*.github.com:tcp:443'
  assert_output --partial 'allow@github.com:tcp:443'
  assert_output --partial 'allow@dhi.io:tcp:443'
  assert_output --partial 'allow@dhi.io:tcp:80'
  assert_output --partial 'allow@*.digicert.com:tcp:80'
  assert_output --partial 'allow@example.org'
  refute_output --partial 'allow@:'
}

@test "balanced_rules_into: skips a malformed host but still emits gateway DNS" {
  _load_msb
  cat >"$STUBDIR/bal-bad.txt" <<'HOSTS'
bad;host:443
github.com:443
HOSTS
  run env ACQ_MSB_BALANCED_HOSTS_FILE="$STUBDIR/bal-bad.txt" bash -c '
    . "'"${REPO_ROOT}"'/acq.backends/msb.sh" 2>/dev/null
    arr=()
    _acq_msb_balanced_rules_into arr 2>/dev/null
    printf "%s\n" "${arr[@]}"
  '
  assert_success
  refute_output --partial 'bad;host'
  assert_output --partial 'allow@dns'
  refute_output --partial 'allow@host:udp:53'
}
