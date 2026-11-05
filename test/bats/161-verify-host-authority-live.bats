#!/usr/bin/env bats
#
# 161-verify-host-authority-live.bats — offline checks of scripts/verify-host-authority-live:
# argument parsing and --dry-run only. These prove the plan printer and the usage
# errors; they say nothing about live sbx or msb behavior (the script's live steps are
# run by a human on a sandbox-capable host and recorded in
# docs/VERIFY_PROVIDER_ADOPTION.md).
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

_hal() { bash "$REPO_ROOT/scripts/verify-host-authority-live" "$@"; }

@test "hal: --help prints usage and exits 0" {
  run _hal --help
  assert_success
  assert_output --partial 'Usage:  scripts/verify-host-authority-live'
  assert_output --partial '--dry-run'
}

@test "hal: --dry-run lists every automated step and the MANUAL instructions" {
  run _hal --dry-run
  assert_success
  assert_output --partial 'DRY RUN'
  assert_output --partial 'msb-ro-kit-create'
  assert_output --partial 'sbx-legacy-reseed'
  assert_output --partial 'MANUAL 1 '
  assert_output --partial 'MANUAL 7 '
}

@test "hal: --dry-run never invokes a backend (stub msb and sbx log nothing)" {
  : > "$CALLS"
  run _hal --dry-run
  assert_success
  [ ! -s "$CALLS" ]
}

@test "hal: --dry-run creates no output directory" {
  local d="$STUBDIR/hal-out"
  run _hal --dry-run --out "$d"
  assert_success
  [ ! -e "$d" ]
}

@test "hal: --backend msb limits the plan to msb steps" {
  run _hal --dry-run --backend msb
  assert_success
  assert_output --partial 'msb-ro-kit-heal'
  refute_output --partial 'sbx-baseline'
}

@test "hal: --backend=sbx and --only select exactly the named step" {
  run _hal --dry-run --backend=sbx --only sbx-baseline
  assert_success
  assert_output --partial 'sbx-baseline'
  refute_output --partial 'sbx-forged-heal [sbx]'
  refute_output --partial 'msb-exit-code'
}

@test "hal: --only accepts a comma list across backends" {
  run _hal --dry-run --only msb-exit-code,sbx-stale-refresh
  assert_success
  assert_output --partial 'msb-exit-code'
  assert_output --partial 'sbx-stale-refresh'
  refute_output --partial 'msb-ro-oci'
}

@test "hal: an unknown --only id is a usage error (exit 2)" {
  run _hal --dry-run --only no-such-step
  assert_failure 2
  assert_output --partial "unknown step id 'no-such-step'"
}

@test "hal: an invalid --backend is a usage error (exit 2)" {
  run _hal --dry-run --backend docker
  assert_failure 2
  assert_output --partial '--backend must be msb, sbx or both'
}

@test "hal: a non-numeric or zero timeout is a usage error (exit 2)" {
  run _hal --dry-run --step-timeout abc
  assert_failure 2
  assert_output --partial '--step-timeout must be a positive integer'
  run _hal --dry-run --create-timeout 0
  assert_failure 2
  assert_output --partial '--create-timeout must be a positive integer'
}

@test "hal: a flag missing its value is a usage error (exit 2)" {
  run _hal --out
  assert_failure 2
  assert_output --partial '--out needs a value'
}

@test "hal: an unknown argument is a usage error (exit 2)" {
  run _hal --frobnicate
  assert_failure 2
  assert_output --partial 'unknown argument: --frobnicate'
}

@test "hal: the dry-run plan echoes the timeouts and the output directory" {
  run _hal --dry-run --step-timeout 7 --create-timeout 9 --out /nonexistent/hal-dir
  assert_success
  assert_output --partial 'step timeout: 7s'
  assert_output --partial 'create timeout: 9s'
  assert_output --partial 'out dir  : /nonexistent/hal-dir'
}

@test "hal: the script is executable and has no bash 4 only constructs" {
  [ -x "$REPO_ROOT/scripts/verify-host-authority-live" ]
  run grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}|\|&|&>>' "$REPO_ROOT/scripts/verify-host-authority-live"
  assert_failure
}
