#!/usr/bin/env bash
#
# 55-version — acq version output
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 7. acq version: exits 0, shows script path and backend
# ===========================================================================

make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" version 2>&1); rc=$?
assert_eq "version exits 0" "0" "$rc"
assert_contains "version: script path" "$out" "$REPO_ROOT/acq"
# Assert `version` reports the CONFIGURED pin (read from common.sh), not a
# hardcoded SHA — so this holds across pin bumps. Tests the invariant, not a commit.
# shellcheck disable=SC1090
_want_ref=$(ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO_ROOT" . "$ACQ" >/dev/null 2>&1; printf '%s' "$PATTERNS_KIT_REF")
assert_contains "version: patterns kit ref" "$out" "$_want_ref"
assert_contains "version: backend line" "$out" "backend:"
cleanup_stubs
