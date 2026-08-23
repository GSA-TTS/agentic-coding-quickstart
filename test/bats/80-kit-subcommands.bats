#!/usr/bin/env bats
#
# 80-kit-subcommands.bats — bats port of scripts/test-acq.d/80-kit-subcommands.sh
# (ADR-0025)
#
# acq kit list / validate / apply. Driven through the acq CLI via `run`, so the
# $CALLS log is inspected for the apply path's dispatch shape.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "kit list: shows the configured patterns ref and the built-in kits" {
  run "$ACQ" kit list
  local want_ref
  want_ref=$(
    # shellcheck disable=SC1090
    ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO_ROOT" . "$ACQ" >/dev/null 2>&1
    printf '%s' "$PATTERNS_KIT_REF"
  )
  assert_output --partial "$want_ref"
  assert_output --partial 'acq-kits'
  assert_output --partial 'usai-provider'
  assert_output --partial 'git-ssh-sign'
}

@test "kit validate: accepts a well-formed local neutral kit" {
  local kitdir="$STUBDIR/goodkit"
  mkdir -p "$kitdir/files/home"
  printf 'hello\n' > "$kitdir/files/home/thing"
  cat >"$kitdir/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: sample-kit
displayName: Sample Kit
description: A sample neutral kit for the offline test.
caps:
  network:
    allow:
      - example.com
files:
  - path: /home/agent/thing
    mode: "0644"
    source: files/home/thing
commands:
  - phase: startup
    user: "1000"
    command:
      - sh
      - -c
      - echo hi
SPEC
  run "$ACQ" kit validate "$kitdir"
  assert_success
  assert_output --partial 'OK'
}

@test "kit validate: rejects bad schemaVersion, name, path, source, and phase" {
  local badkit="$STUBDIR/badkit"
  mkdir -p "$badkit"
  cat >"$badkit/spec.yaml" <<'SPEC'
schemaVersion: "2"
kind: mixin
name: Bad_Name
displayName: Bad
description: bad kit
files:
  - path: relative/path
    mode: "0644"
    source: files/missing.txt
commands:
  - phase: bogusphase
    command:
      - true
SPEC
  run "$ACQ" kit validate "$badkit"
  assert_failure
  assert_output --partial 'hybrid/v1'
  assert_output --partial 'kebab-case'
  assert_output --partial 'absolute'
  assert_output --partial 'source not found'
  assert_output --partial 'unknown command phase'
}

@test "kit apply (msb): runs msb exec and stages NO create-time script (ADR-0017)" {
  local applykit="$STUBDIR/applykit"
  mkdir -p "$applykit"
  cat >"$applykit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: apply-kit
displayName: Apply Kit
description: kit applied mid-life
commands:
  - phase: startup
    user: "1000"
    command:
      - sh
      - -c
      - echo applied
SPEC
  run env ACQ_BACKEND=msb "$ACQ" kit apply mybox "$applykit"
  local log
  log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec mybox'
  # Mid-life apply is exec-based only: no create-time startup script, no create.
  refute_regex "$log" '--script-path acq-startup'
  refute_regex "$log" 'msb create'
}
