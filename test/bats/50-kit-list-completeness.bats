#!/usr/bin/env bats
#
# 50-kit-list-completeness.bats — bats port of
# scripts/test-acq.d/50-kit-list-completeness.sh (ADR-0025)
#
# Verifies the built-in kit set (KITS / ACQ_KIT_NAMES, populated by load_acq),
# the zscaler-first ordering invariant, and the doc count-drift guard (#278).
# In-process: reads the arrays acq builds, so no `run` for those.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "kits: built-in set is present" {
  local joined
  joined=$(printf '%s\n' "${KITS[@]}")
  assert_regex "$joined" 'acq-kits/usai-provider'
  assert_regex "$joined" 'acq-kits/agentic-coding-playbook'
  assert_regex "$joined" 'acq-kits/zscaler-ca-certificate'
  assert_regex "$joined" 'acq-kits/git-ssh-sign'
}

@test "kits: zscaler-ca-certificate is applied first (CA trust before network)" {
  assert_regex "${KITS[0]}" 'acq-kits/zscaler-ca-certificate'
}

@test "kits: count matches the documented set and no doc hardcodes an English count" {
  assert_equal "${#ACQ_KIT_NAMES[@]}" "4"
  local doc bad
  for doc in "$REPO_ROOT/README.md" "$REPO_ROOT/AGENTS.md"; do
    bad=$(grep -Eic "\b(four|five|three|six|two) (built-in |mixin )?kits\b" "$doc" || true)
    assert_equal "$bad" "0"
  done
}
