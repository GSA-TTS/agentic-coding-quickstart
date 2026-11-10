#!/usr/bin/env bats
#
# 171-local-kit-hardlinks.bats — a local kit directory holding a regular file
# with more than one hard link is refused before it is used: the error names
# the file relative to the kit and the plain-copy remedy. Directories (whose
# link count is naturally above 1) are exempt, and a plain kit passes.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

_plain_kit() {
  local kit="$1"
  mkdir -p "$kit/files/sub/deeper"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: plain\n' > "$kit/spec.yaml"
  printf 'payload\n' > "$kit/files/sub/deeper/data.txt"
}

@test "local kit: a plain kit with nested directories passes" {
  load_acq
  local kit="$STUBDIR/plainkit"
  _plain_kit "$kit"
  run kit_translate_fetch "$kit" "$STUBDIR/unused"
  assert_success
  assert_output "$kit"
}

@test "local kit: a hard-linked file is refused, named relative to the kit, with the copy remedy" {
  load_acq
  local kit="$STUBDIR/linkkit"
  _plain_kit "$kit"
  printf 'host secret\n' > "$STUBDIR/elsewhere.txt"
  ln "$STUBDIR/elsewhere.txt" "$kit/files/sub/linked.txt"
  run kit_translate_fetch "$kit" "$STUBDIR/unused"
  assert_failure
  assert_output --partial 'local kit refused: files/sub/linked.txt has more than one hard link'
  assert_output --partial 'cp -R'
  refute_output --partial "$STUBDIR/elsewhere.txt"
  # A trailing slash on the kit path names the file the same way.
  run kit_translate_fetch "$kit/" "$STUBDIR/unused"
  assert_failure
  assert_output --partial 'local kit refused: files/sub/linked.txt has more than one hard link'
}

@test "local kit: two names for one file inside the kit are refused too" {
  load_acq
  local kit="$STUBDIR/twinkit"
  _plain_kit "$kit"
  ln "$kit/files/sub/deeper/data.txt" "$kit/files/twin.txt"
  run kit_translate_fetch "$kit" "$STUBDIR/unused"
  assert_failure
  assert_output --partial 'has more than one hard link'
}

@test "local kit: a plain copy made with cp -R passes" {
  load_acq
  local kit="$STUBDIR/linkkit2"
  _plain_kit "$kit"
  printf 'x\n' > "$STUBDIR/elsewhere2.txt"
  ln "$STUBDIR/elsewhere2.txt" "$kit/files/linked.txt"
  cp -R "$kit" "$STUBDIR/copykit"
  run kit_translate_fetch "$STUBDIR/copykit" "$STUBDIR/unused"
  assert_success
}

@test "sbx: a local kit with a hard-linked file is never handed to sbx" {
  load_acq
  unset ACQ_SBX_KIT_PASSTHROUGH
  local kit="$STUBDIR/sbxlinkkit" out rc=0
  _plain_kit "$kit"
  printf 'x\n' > "$STUBDIR/elsewhere3.txt"
  ln "$STUBDIR/elsewhere3.txt" "$kit/files/linked.txt"
  : > "$CALLS"
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$kit" 2>"$STUBDIR/t.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/t.err"
  assert_output --partial 'files/linked.txt has more than one hard link'
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
}
