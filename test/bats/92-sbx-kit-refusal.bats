#!/usr/bin/env bats
#
# 92-sbx-kit-refusal.bats — on sbx, a kit whose payload fails acq's checks is
# never handed to sbx: translation returns non-zero with no output, and create,
# mid-life apply and the heal stop instead of passing sbx a raw or empty ref.
# Runs with the offline passthrough disabled so the real translation runs.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; unset ACQ_SBX_KIT_PASSTHROUGH; }
teardown() { acq_teardown_stubs; }

load 'helper'

# A neutral kit whose files/ tree links to a file outside the kit.
_bad_neutral_kit() {
  local kit="$1"
  mkdir -p "$kit/files"
  printf 'x\n' > "$kit/files/ok"
  printf 'outside\n' > "$STUBDIR/outside.txt"
  ln -s "$STUBDIR/outside.txt" "$kit/files/out"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: bad\ndisplayName: Bad\ndescription: d\n' > "$kit/spec.yaml"
}

@test "sbx: translation of a refused neutral kit fails with no output" {
  local kit="$STUBDIR/badkit" errf="$STUBDIR/t.err" out rc=0
  _bad_neutral_kit "$kit"
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$kit" 2>"$errf") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$errf"
  assert_output --partial 'kit translation failed; not applying'
  refute_output --partial 'passing ref through'
}

@test "sbx: an sbx-v2 kit with a payload link outside the kit is refused" {
  local kit="$STUBDIR/v2kit" out rc=0
  mkdir -p "$kit/files"
  printf 'outside\n' > "$STUBDIR/outside.txt"
  ln -s "$STUBDIR/outside.txt" "$kit/files/out"
  printf 'schemaVersion: "2"\nname: v2\n' > "$kit/spec.yaml"
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$kit" 2>"$STUBDIR/v2.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/v2.err"
  assert_output --partial 'payload links outside the kit'
}

@test "sbx: mid-life apply of a refused kit fails without calling sbx kit add" {
  local kit="$STUBDIR/applykit" rc=0
  _bad_neutral_kit "$kit"
  : > "$CALLS"
  ACQ_SBX_KIT_CACHE="$STUBDIR/cache" acq_backend_apply_kit applybox "$kit" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
}

@test "sbx: kit add with an empty kit path fails without calling sbx" {
  : > "$CALLS"
  run _acq_sbx_kit_add emptybox ""
  assert_failure
  assert_output --partial 'no usable kit to add'
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
}

@test "sbx: provision with a refused extra kit never creates the sandbox" {
  local kit="$STUBDIR/provkit" rc=0
  _bad_neutral_kit "$kit"
  : > "$CALLS"
  (
    export ACQ_SBX_KIT_CACHE="$STUBDIR/cache" ACQ_EXTRA_KITS="$kit"
    acq_test_stub_provider_input_boundary
    acq_backend_provision provbox shell "$STUBDIR"
  ) > "$STUBDIR/prov.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  run cat "$STUBDIR/prov.out"
  assert_output --partial 'a kit could not be prepared'
  refute_regex "$(cat "$CALLS")" '^sbx (create|run)'
}
