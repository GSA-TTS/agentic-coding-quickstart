#!/usr/bin/env bats
#
# 101-kit-source-confinement.bats — a kit's files[] payload must come from the
# kit directory itself. Sources are relative to the kit, stay inside it with
# symlinks resolved, and recorded local kit refs are absolute so they name the
# same kit wherever a later start/restart runs.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# A kit dir with one in-kit payload file, plus a file next to (outside) it.
_mk_kit() {
  local kit="$1"
  mkdir -p "$kit/files"
  printf 'inside\n' > "$kit/files/ok"
  printf 'outside\n' > "$(dirname "$kit")/outside.txt"
  cat > "$kit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: conf-kit
displayName: Conf
description: source confinement
files:
  - path: /home/agent/ok
    source: files/ok
SPEC
}

@test "kit_spec_files drops absolute and parent-directory sources" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    k="'"$STUBDIR"'/k"; mkdir -p "$k"
    cat > "$k/spec.yaml" <<'"'"'SPEC'"'"'
files:
  - path: /home/agent/a
    source: files/ok
  - path: /home/agent/b
    source: /etc/hostname
  - path: /home/agent/c
    source: files/../../outside.txt
  - path: /home/agent/d
    source: ../outside.txt
SPEC
    kit_spec_files "$k/spec.yaml" 2>&1
  '
  assert_output --partial $'/home/agent/a\t\t\tfiles/ok'
  assert_output --partial 'unsafe source: /etc/hostname'
  assert_output --partial 'unsafe source: files/../../outside.txt'
  assert_output --partial 'unsafe source: ../outside.txt'
  refute_output --partial $'/home/agent/b\t'
  refute_output --partial $'/home/agent/c\t'
  refute_output --partial $'/home/agent/d\t'
}

@test "kit_source_within accepts in-kit files and in-kit links, refuses the rest" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    k="'"$STUBDIR"'/kit"; mkdir -p "$k/files/sub"; printf x > "$k/files/ok"
    printf y > "'"$STUBDIR"'/outside.txt"
    ln -s ok "$k/files/inlink"
    ln -s ../../outside.txt "$k/files/outlink"
    ln -s "'"$STUBDIR"'" "$k/files/outdir"
    for s in files/ok files/inlink files/outlink files/outdir/outside.txt files/missing files/sub /etc/hostname files/../files/ok; do
      if kit_source_within "$k" "$s"; then echo "OK $s"; else echo "NO $s"; fi
    done
  '
  assert_line 'OK files/ok'
  assert_line 'OK files/inlink'
  assert_line 'NO files/outlink'
  assert_line 'NO files/outdir/outside.txt'
  assert_line 'NO files/missing'
  assert_line 'NO files/sub'
  assert_line 'NO /etc/hostname'
  assert_line 'NO files/../files/ok'
}

@test "kit validate reports a source that resolves outside the kit" {
  local kit="$STUBDIR/vk"
  _mk_kit "$kit"
  ln -s ../../outside.txt "$kit/files/link"
  cat >> "$kit/spec.yaml" <<'SPEC'
  - path: /home/agent/link
    source: files/link
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_validate "'"$kit"'" 2>&1; echo "RC=$?"'
  assert_output --partial 'file source must be a regular file inside the kit directory: files/link'
  assert_output --partial 'RC=1'
}

@test "kit validate accepts a kit whose sources stay inside it" {
  local kit="$STUBDIR/goodkit"
  _mk_kit "$kit"
  ln -s ok "$kit/files/alias"
  cat >> "$kit/spec.yaml" <<'SPEC'
  - path: /home/agent/alias
    source: files/alias
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_validate "'"$kit"'" 2>&1; echo "RC=$?"'
  assert_output --partial 'RC=0'
}

@test "sbx materialization refuses a payload symlink that leaves the kit" {
  local kit="$STUBDIR/sk" out="$STUBDIR/sbx-out"
  _mk_kit "$kit"
  ln -s ../../outside.txt "$kit/files/link"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$kit"'" "'"$out"'" 2>&1; echo "RC=$?"'
  assert_output --partial 'kit payload symlink points outside the kit: files/link'
  assert_output --partial 'RC=1'
  [ ! -e "$out/files/link" ]
}

@test "sbx materialization still copies a payload with in-kit symlinks" {
  local kit="$STUBDIR/sk2" out="$STUBDIR/sbx-out2"
  _mk_kit "$kit"
  ln -s ok "$kit/files/alias"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$kit"'" "'"$out"'" >/dev/null 2>&1; echo "RC=$?"'
  assert_output --partial 'RC=0'
  [ -L "$out/files/alias" ]
  [ "$(cat "$out/files/ok")" = inside ]
}

@test "cli-kits: a relative local kit ref is recorded as an absolute path" {
  load_acq
  mkdir -p "$STUBDIR/proj/mykit"
  local abs
  abs=$(cd -P "$STUBDIR/proj/mykit" && pwd -P)
  ACQ_CLI_KITS=("./mykit"); ACQ_EXTRA_KITS="./mykit"
  (cd "$STUBDIR/proj" && acq_cli_kits_write msb relbox)
  ACQ_CLI_KITS=(); ACQ_EXTRA_KITS=""
  cd "$STUBDIR"
  acq_cli_kits_load msb relbox
  assert_equal "${#ACQ_CLI_KITS[@]}" "1"
  assert_equal "${ACQ_CLI_KITS[0]}" "$abs"
  assert_equal "$ACQ_EXTRA_KITS" "$abs"
}

@test "cli-kits: a relative ref left in an older record is ignored with a warning" {
  load_acq
  local file
  file=$(_acq_cli_kits_file msb oldbox)
  mkdir -p "$(dirname "$file")"
  printf 'schema=1\nkit=./old-kit\nkit=/kits/abs\nextra=rel-extra\n' > "$file"
  ACQ_CLI_KITS=(); ACQ_EXTRA_KITS=""
  run acq_cli_kits_load msb oldbox
  assert_output --partial "ignoring recorded relative kit path './old-kit'"
  assert_output --partial "ignoring recorded relative kit path 'rel-extra'"
  acq_cli_kits_load msb oldbox 2>/dev/null
  assert_equal "${#ACQ_CLI_KITS[@]}" "1"
  assert_equal "${ACQ_CLI_KITS[0]}" "/kits/abs"
  assert_equal "$ACQ_EXTRA_KITS" ""
}
