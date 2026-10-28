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

@test "provider selection: unset preserves the USAi default" {
  load_acq
  # shellcheck disable=SC2034 # _build_kit_list reads this global dynamically
  unset ACQ_PROVIDER_KITS_FROM_ENV ACQ_PROVIDER_KITS_FROM_CLI
  # shellcheck disable=SC2034 # _build_kit_list reads this global dynamically
  ACQ_PROVIDER_KITS=""
  _build_kit_list

  assert_equal "${KITS[1]}" "$USAI_KIT"
  assert_equal "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "4"
}

@test "provider selection: explicit empty omits every provider kit" {
  load_acq
  # shellcheck disable=SC2034 # _build_kit_list reads this global dynamically
  ACQ_PROVIDER_KITS=""
  # shellcheck disable=SC2034 # _build_kit_list reads this global dynamically
  ACQ_PROVIDER_KITS_FROM_ENV=1
  # shellcheck disable=SC2034 # _build_kit_list reads this global dynamically
  ACQ_PROVIDER_KITS_FROM_CLI=""
  _build_kit_list

  assert_equal "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "3"
  refute_regex "$(printf '%s\n' "${KITS[@]}")" 'acq-kits/usai-provider'
  refute acq_usai_provider_selected
}

@test "provider selection: an explicit ref replaces the default provider ref" {
  load_acq
  # shellcheck disable=SC2034 # _build_kit_list reads this global dynamically
  ACQ_PROVIDER_KITS="$STUBDIR/missing-provider-kit"
  # shellcheck disable=SC2034 # _build_kit_list reads this global dynamically
  ACQ_PROVIDER_KITS_FROM_ENV=1

  _build_kit_list
  assert_equal "${KITS[1]}" "$STUBDIR/missing-provider-kit"
}

@test "kits: count matches the documented set and no doc hardcodes an English count" {
  assert_equal "${#ACQ_KIT_NAMES[@]}" "4"
  local doc bad
  for doc in "$REPO_ROOT/README.md" "$REPO_ROOT/AGENTS.md"; do
    bad=$(grep -Eic "\b(four|five|three|six|two) (built-in |mixin )?kits\b" "$doc" || true)
    assert_equal "$bad" "0"
  done
}














@test "agent-kits: default kit list is support-only" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  _build_kit_list

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  refute_regex "$(printf '%s\n' "${KITS[@]}")" 'acq-kits/opencode'
}

@test "agent-kits: shell kit list is support-only" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  _build_kit_list shell

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  refute_regex "$(printf '%s\n' "${KITS[@]}")" 'acq-kits/opencode'
}

@test "agent-kits: opencode inference applies the built-in agent kit" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  _build_kit_list opencode

  run acq_selected_agent_kit_summary opencode
  assert_success
  assert_output 'agent=opencode kit=opencode entrypoint=opencode install_owner=kit start_owner=kit apply=enabled'
  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "5"
  assert_regex "$(printf '%s\n' "${KITS[@]}")" '/acq-opencode-kit'
}

@test "agent-kits: enabled built-in agent kit is appended after support bundle" {
  load_acq
  ACQ_TEST_AGENT_KIT="$STUBDIR/enabled-opencode-kit"
  mkdir -p "$ACQ_TEST_AGENT_KIT"
  cat >"$ACQ_TEST_AGENT_KIT/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: opencode
agent:
  name: opencode
  entrypoint: opencode
SPEC
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$ACQ_TEST_AGENT_KIT"; }
  _build_kit_list opencode

  assert_equal "${KITS[4]}" "$ACQ_TEST_AGENT_KIT"
  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "5"
}

@test "agent-kits: explicit CLI kit preserves the selected-kit notice" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=(/tmp/team-opencode)

  run acq_selected_agent_kit_summary opencode
  assert_success
  assert_output --partial 'agent=opencode kit=opencode'
  _build_kit_list opencode
  local joined; joined=$(printf '%s\n' "${KITS[@]}")
  assert_regex "$joined" '/tmp/team-opencode'
  refute_regex "$joined" 'acq-kits/opencode'
}

@test "agent-kits: ACQ_EXTRA_KITS never drive implicit selection" {
  load_acq
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_EXTRA_KITS="/tmp/opencode"
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_CLI_KITS=()
  _build_kit_list shell

  run acq_selected_agent_kit_summary shell
  assert_failure
  assert_regex "$(printf '%s\n' "${KITS[@]}")" '/tmp/opencode'
}


