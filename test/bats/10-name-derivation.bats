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

# The workspace basename is taken from the path made absolute and lexically
# normalised, as the Python implementation does, so both derive the same name.
@test "derive_name: the root derives agent-workspace, as the Python acq does" {
  run derive_name opencode /
  assert_output 'opencode-workspace'
  run derive_name opencode //
  assert_output 'opencode-workspace'
  run bash -c 'cd / && . "$1" >/dev/null 2>&1 && derive_name opencode' _ "${REPO_ROOT}/acq.backends/common.sh"
  assert_output 'opencode-workspace'
}

@test "derive_name: trailing '.' and '..' steps fold to the directory they name" {
  run derive_name opencode /srv/My-App/.
  assert_output 'opencode-my-app'
  run derive_name opencode /srv/My-App/sub/..
  assert_output 'opencode-my-app'
  run derive_name opencode /srv/..
  assert_output 'opencode-workspace'
  mkdir -p "$BATS_TEST_TMPDIR/Parent Dir/child"
  run bash -c 'cd "$2" && . "$1" >/dev/null 2>&1 && derive_name opencode .. && derive_name opencode x/../..' \
    _ "${REPO_ROOT}/acq.backends/common.sh" "$BATS_TEST_TMPDIR/Parent Dir/child"
  assert_line --index 0 'opencode-parent-dir'
  assert_line --index 1 'opencode-parent-dir'
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
  for bad in $'x\nbox' $'x\033]0;t\007' 'a:b' 'a/b' '../up' '..' '.' 'v1.2' '-flag' 'has space' ''; do
    run derive_name --name "$bad" opencode /proj
    assert_failure
    assert_output --partial 'invalid sandbox name'
    refute_output --partial $'\033'
  done
  run derive_name "--name=a:b" opencode /proj
  assert_failure
  assert_output --partial 'invalid sandbox name'
}

@test "derive_name: an explicit --name with underscores and dashes is accepted" {
  run derive_name --name My_box-v2 opencode /proj
  assert_success
  assert_output 'My_box-v2'
}

@test "derive_name: the invalid-name error points at the verbs for existing sandboxes" {
  run derive_name --name a.b opencode /proj
  assert_failure
  assert_output --partial "acq run NAME"
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

@test "lookup: a CRLF list line matches the bare name" {
  run _acq_list_has_line box "$(printf 'other\r\nbox\r\n')"
  assert_success
  run _acq_list_has_line box "$(printf 'other\r\nboxer\r\n')"
  assert_failure
  printf 'other\r\nbox\r\n' >"$STUBDIR/.msb_sandbox_list"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_exists box
  '
  assert_success
}

# Verbs that act on an existing sandbox take NAME as given. Names that could
# steer a host path (traversal, separators, control characters) are refused
# before the backend or any cleanup runs; any other name is passed through.
@test "name-form verbs: path-shaped and control-character names are refused" {
  local verb bad
  for verb in rm stop start restart exec shell ports; do
    for bad in '../x' 'a/b' 'a\b' '..' '.' $'x\ny' $'x\033]0;t\007'; do
      : >"$CALLS"
      run env ACQ_BACKEND=msb "$ACQ" "$verb" "$bad"
      assert_failure
      assert_output --partial 'refusing sandbox name'
      refute_output --partial $'\033'
      refute_regex "$(cat "$CALLS")" '^msb (remove|stop|start|exec|inspect)'
    done
  done
}

# attach, the kit verbs and create --recreate name an existing sandbox too, so
# they refuse the same path-shaped names before reaching the backend (as the
# Python implementation does).
@test "name-form verbs: attach, kit apply/check/update and create --recreate refuse path-shaped names" {
  local bad
  for bad in '../x' 'a/b' 'a\b' '..' '.' $'x\ny'; do
    : >"$CALLS"
    run env ACQ_BACKEND=msb "$ACQ" attach "$bad"
    assert_failure
    assert_output --partial 'acq: attach: refusing sandbox name'
    run env ACQ_BACKEND=msb "$ACQ" attach --flag "$bad"
    assert_failure
    assert_output --partial 'acq: attach: refusing sandbox name'
    run env ACQ_BACKEND=msb "$ACQ" attach -- "$bad"
    assert_failure
    assert_output --partial 'acq: attach: refusing sandbox name'
    run env ACQ_BACKEND=msb "$ACQ" kit apply "$bad" ./kit
    assert_failure
    assert_output --partial 'acq: kit apply: refusing sandbox name'
    run env ACQ_BACKEND=msb "$ACQ" kit check "$bad"
    assert_failure
    assert_output --partial 'acq: kit check: refusing sandbox name'
    run env ACQ_BACKEND=msb "$ACQ" kit update "$bad" --yes
    assert_failure
    assert_output --partial 'acq: kit update: refusing sandbox name'
    run env ACQ_BACKEND=msb "$ACQ" create --recreate "$bad"
    assert_failure
    assert_output --partial 'acq: create: refusing sandbox name'
    run env ACQ_BACKEND=msb "$ACQ" create "--recreate=$bad"
    assert_failure
    assert_output --partial 'acq: create: refusing sandbox name'
    refute_regex "$(cat "$CALLS")" '^msb '
  done
  # A trailing --recreate with no value is an empty name.
  run env ACQ_BACKEND=msb "$ACQ" create --recreate
  assert_failure
  assert_output --partial "acq: create: refusing sandbox name ''"
}

@test "name-form verbs: a path-safe attach name, and --recreate after --, pass the check" {
  : >"$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" attach 'odd.name:1'
  refute_output --partial 'refusing sandbox name'
  assert_regex "$(cat "$CALLS")" 'msb attach odd\.name:1'
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    _acq_recreate_name_check opencode . -- --recreate ../x && echo ok-after-dashdash
    _acq_recreate_name_check opencode . --kit k --recreate good-name && echo ok-good
  '
  assert_success
  assert_line ok-after-dashdash
  assert_line ok-good
}

@test "name-form verbs: rm ../victim leaves directories outside the state dir untouched" {
  export ACQ_MSB_CLONES_DIR="$STUBDIR/state-clones"
  mkdir -p "$ACQ_MSB_CLONES_DIR" "$STUBDIR/victim"
  : >"$STUBDIR/victim/keep"
  printf '../victim\n' >"$STUBDIR/.msb_sandbox_list"
  run env ACQ_BACKEND=msb "$ACQ" rm ../victim
  [ -f "$STUBDIR/victim/keep" ]
  assert_failure
  assert_output --partial 'refusing sandbox name'
  refute_regex "$(cat "$CALLS")" '^msb remove'
}

@test "name-form verbs: an unusual but path-safe name still reaches the backend" {
  : >"$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" stop 'odd.name:1'
  refute_output --partial 'refusing sandbox name'
  assert_regex "$(cat "$CALLS")" 'msb stop odd\.name:1'
}
