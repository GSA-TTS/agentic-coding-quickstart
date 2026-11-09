#!/usr/bin/env bats
#
# 10-name-derivation.bats — bats port of scripts/test-acq.d/10-name-derivation.sh
# (ADR-0025)
#
# Pure-function unit tests for slugify / derive_name. acq_setup_stubs runs
# load_acq, which sources acq's functions into this @test's shell, so we call
# them directly (no `run` needed for the pure ones; used where we assert output).
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "slugify: lowercases, replaces separators with dashes" {
  run slugify "My_App-2"
  assert_output 'my-app-2'
  run slugify "with space"
  assert_output 'with-space'
  run slugify "UPPER"
  assert_output 'upper'
  run slugify "under_score"
  assert_output 'under-score'
}

@test "derive_name: explicit --name wins" {
  run derive_name --name my-sandbox opencode /proj
  assert_output 'my-sandbox'
}

@test "derive_name: agent + path -> agent-<pathslug>" {
  run derive_name opencode /home/user/my-project
  assert_output 'opencode-my-project'
}

@test "derive_name: agent-only uses \$PWD basename" {
  local cwd_base
  cwd_base=$(slugify "$(basename "$PWD")")
  run derive_name opencode
  assert_output "opencode-${cwd_base}"
}

# Names flow into backend argv, `msb list -q` line lookups, state-file keys and
# terminal output. A derived name must be a single-line slug whatever the
# directory is called, and an explicit --name that cannot be used safely is
# refused rather than passed through.

@test "slugify: newlines, escapes and other control characters collapse to one dash" {
  run slugify $'my\nproj'
  assert_output 'my-proj'
  run slugify $'a\033]0;title\007b'
  assert_output 'a-0-title-b'
  run slugify $'tab\there\r'
  assert_output 'tab-here'
}

@test "slugify: matches the Python implementation (ASCII a-z0-9 only)" {
  run slugify 'Café Ünïcode'
  assert_output 'caf-n-code'
  run slugify '--x__y--'
  assert_output 'x-y'
}

@test "derive_name: a workspace basename with a newline yields a single-line slug" {
  run derive_name opencode $'/tmp/my\nproj'
  assert_success
  assert_output 'opencode-my-proj'
  assert_equal "${#lines[@]}" 1
}

@test "derive_name: a \$PWD basename with a newline yields a single-line slug" {
  local d="$STUBDIR/"$'odd\nname'
  mkdir -p "$d"
  cd "$d"
  run derive_name opencode
  assert_success
  assert_output 'opencode-odd-name'
}

@test "derive_name: an explicit --name outside [A-Za-z0-9._-] is refused" {
  local bad
  for bad in $'x\nbox' $'x\033]0;t\007' 'a:b' 'a/b' '../up' '..' '.' '-flag' 'has space' ''; do
    run derive_name --name "$bad" opencode /proj
    assert_failure
    assert_output --partial 'invalid sandbox name'
    refute_output --partial $'\033'
  done
  run derive_name "--name=a:b" opencode /proj
  assert_failure
  assert_output --partial 'invalid sandbox name'
}

@test "derive_name: an explicit --name with dots, underscores and dashes is accepted" {
  run derive_name --name My_box.v2-x opencode /proj
  assert_success
  assert_output 'My_box.v2-x'
}

@test "lookup(msb): a name with a newline never matches an unrelated listed sandbox" {
  printf 'box\nother\n' >"$STUBDIR/.msb_sandbox_list"
  printf 'box\n' >"$STUBDIR/.msb_running_list"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    set +e
    acq_backend_exists "$(printf "nope\nbox")" && echo exists=yes || echo exists=no
    _acq_msb_is_running "$(printf "nope\nbox")" && echo running=yes || echo running=no
    _acq_msb_confirm_absent "$(printf "nope\nbox")" && echo absent=confirmed || echo absent=unconfirmed
    acq_backend_exists "" && echo empty=yes || echo empty=no
    acq_backend_exists box && echo box=yes || echo box=no
  '
  assert_line 'exists=no'
  assert_line 'running=no'
  assert_line 'absent=unconfirmed'
  assert_line 'empty=no'
  assert_line 'box=yes'
}

@test "lookup(sbx): a name with a newline never matches an unrelated listed sandbox" {
  printf 'box\nother\n' >"$STUBDIR/.sandbox_list"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    set +e
    acq_backend_exists "$(printf "nope\nbox")" && echo exists=yes || echo exists=no
    _acq_sbx_confirm_absent "$(printf "nope\nbox")" && echo absent=confirmed || echo absent=unconfirmed
    acq_backend_exists box && echo box=yes || echo box=no
  '
  assert_line 'exists=no'
  assert_line 'absent=unconfirmed'
  assert_line 'box=yes'
}
