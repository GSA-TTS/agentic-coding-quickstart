#!/usr/bin/env bats
#
# 55-version.bats — bats port of scripts/test-acq.d/55-version.sh (ADR-0025)
#
# `acq version` exits 0 and reports the script path, the configured patterns kit
# ref (read from common.sh, not a hardcoded SHA), and a backend line.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "version: exits 0 and reports script path, kit ref, and backend" {
  run env ACQ_BACKEND=sbx "$ACQ" version
  assert_success
  assert_output --partial "$REPO_ROOT/acq"
  assert_output --partial 'backend:'

  # The reported patterns kit ref must be the CONFIGURED pin (from common.sh),
  # asserted as an invariant so this holds across pin bumps.
  local want_ref
  want_ref=$(
    # shellcheck disable=SC1090
    ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO_ROOT" . "$ACQ" >/dev/null 2>&1
    printf '%s' "$PATTERNS_KIT_REF"
  )
  assert_output --partial "$want_ref"
}

# The banner's git line reports on acq's own clone, even when the caller's
# environment exports a GIT_DIR naming another repository.
@test "version: an inherited GIT_DIR does not change the reported clone" {
  local other="$STUBDIR/other"
  mkdir -p "$other"
  (
    cd "$other" && git init -q -b other-branch-marker &&
      git -c user.email=t@example.gov -c user.name=t commit -q --allow-empty -m x
  )
  run env ACQ_BACKEND=sbx GIT_DIR="$other/.git" GIT_WORK_TREE="$other" "$ACQ" version
  assert_success
  refute_output --partial 'other-branch-marker'
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    assert_output --partial "@$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  fi
}
