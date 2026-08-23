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
