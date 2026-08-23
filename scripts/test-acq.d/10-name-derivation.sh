#!/usr/bin/env bash
#
# 10-name-derivation — slugify / derive_name
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 1. slugify / derive_name: name-derivation behavior
# ===========================================================================

make_stubs; load_acq

slug=$(slugify "My_App-2")
assert_eq "slugify basic" "my-app-2" "$slug"

slug=$(slugify "with space")
assert_eq "slugify space" "with-space" "$slug"

slug=$(slugify "UPPER")
assert_eq "slugify upper" "upper" "$slug"

slug=$(slugify "under_score")
assert_eq "slugify underscore" "under-score" "$slug"

# derive_name with explicit --name
name=$(derive_name --name my-sandbox opencode /proj)
assert_eq "derive_name explicit --name" "my-sandbox" "$name"

# derive_name from agent + path
name=$(derive_name opencode /home/user/my-project)
assert_eq "derive_name agent+path" "opencode-my-project" "$name"

# derive_name agent-only (uses $PWD basename)
cwd_base=$(slugify "$(basename "$PWD")")
name=$(derive_name opencode)
assert_eq "derive_name agent-only" "opencode-${cwd_base}" "$name"

cleanup_stubs

