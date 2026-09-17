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

@test "provider-facts: transitional USAi fallback defaults remain neutral" {
  load_acq

  assert_equal "$USAI_PROVIDER_KIT_NAME" "usai-provider"
  assert_equal "$USAI_PROVIDER_HOST" "api.gsa.usai.gov"
  assert_equal "$USAI_PROVIDER_BASE_URL" "https://api.gsa.usai.gov/api/v1"
  assert_equal "$USAI_PROVIDER_KEY_ENV" "USAI_API_KEY"
  assert_equal "$USAI_PROVIDER_MODELS_URL" "https://api.gsa.usai.gov/api/v1/models"
  assert_equal "$USAI_PROVIDER_KEY_MGMT_URL" "https://gsa.usai.gov/console/key-management"
  assert_equal "$USAI_PROVIDER_BIND_HOSTS" "api.gsa.usai.gov"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "fallback"
  assert_regex "$USAI_KIT" "acq-kits/${USAI_PROVIDER_KIT_NAME}$"
  refute_regex "$USAI_PROVIDER_MODELS_URL" 'opencode'
}

@test "provider-facts: valid artifact overrides fallback defaults" {
  load_acq
  local facts="$STUBDIR/usai.env"
  cat > "$facts" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.example.gov
ACQ_PROVIDER_BASE_URL=https://api.example.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.example.gov/api/v1/models
ACQ_PROVIDER_KEY_ENV=EXAMPLE_API_KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://example.gov/keys
ACQ_PROVIDER_BIND_HOSTS=api.example.gov,models.example.gov
FACTS

  acq_provider_facts_load "$facts"
  assert_equal "$USAI_PROVIDER_HOST" "api.example.gov"
  assert_equal "$USAI_PROVIDER_BASE_URL" "https://api.example.gov/api/v1"
  assert_equal "$USAI_PROVIDER_MODELS_URL" "https://api.example.gov/api/v1/models"
  assert_equal "$USAI_PROVIDER_KEY_ENV" "EXAMPLE_API_KEY"
  assert_equal "$USAI_PROVIDER_KEY_MGMT_URL" "https://example.gov/keys"
  assert_equal "$USAI_PROVIDER_BIND_HOSTS" "api.example.gov,models.example.gov"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "$facts"
}

@test "provider-facts: missing artifact leaves fallback path available" {
  load_acq
  run acq_provider_facts_load "$STUBDIR/missing.env"
  assert_failure 2
  assert_equal "$USAI_PROVIDER_HOST" "api.gsa.usai.gov"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "fallback"
}

@test "provider-facts: invalid artifact fails closed without partial override" {
  load_acq
  local facts="$STUBDIR/bad-usai.env"
  cat > "$facts" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.bad.gov
ACQ_PROVIDER_BASE_URL=https://api.bad.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.bad.gov/api/v1/models
ACQ_PROVIDER_KEY_ENV=bad-key-name
ACQ_PROVIDER_KEY_MGMT_URL=https://bad.gov/keys
ACQ_PROVIDER_BIND_HOSTS=api.bad.gov
FACTS

  run acq_provider_facts_load "$facts"
  assert_failure
  assert_equal "$USAI_PROVIDER_HOST" "api.gsa.usai.gov"
  assert_equal "$USAI_PROVIDER_KEY_ENV" "USAI_API_KEY"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "fallback"
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

@test "agent-kits: opencode inference is visible while apply is deferred" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  _build_kit_list opencode

  run acq_selected_agent_kit_summary opencode
  assert_success
  assert_output 'agent=opencode kit=opencode entrypoint=opencode install_owner=kit start_owner=kit apply=deferred'
  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  refute_regex "$(printf '%s\n' "${KITS[@]}")" 'acq-kits/opencode'
}

@test "agent-kits: enabled built-in agent kit is appended after support bundle" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_builtin_kit_ref() { printf '%s#ref=%s&dir=%s/%s\n' "$PATTERNS_KIT_REPO" "$PATTERNS_KIT_REF" "$PATTERNS_KIT_DIR" "$1"; }
  _build_kit_list opencode

  assert_regex "${KITS[4]}" 'acq-kits/opencode$'
  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "5"
}

@test "agent-kits: explicit CLI kit suppresses implicit agent-kit inference" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=(/tmp/team-opencode)

  run acq_selected_agent_kit_summary opencode
  assert_failure
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
