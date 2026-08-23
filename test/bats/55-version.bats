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
