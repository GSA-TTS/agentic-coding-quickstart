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

@test "provider-facts: URL syntax accepted by the shared contract reaches the verifier" {
  load_acq
  local facts="$STUBDIR/usai-url.env"
  cat > "$facts" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.example.gov
ACQ_PROVIDER_BASE_URL=https://api.example.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.example.gov/api/v1/models%2Fbeta+preview~v1?view=full&tag=a%2Bb
ACQ_PROVIDER_KEY_ENV=EXAMPLE_API_KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://example.gov/keys
ACQ_PROVIDER_BIND_HOSTS=api.example.gov
FACTS

  acq_provider_facts_load "$facts"
  assert_equal "$USAI_PROVIDER_MODELS_URL" "https://api.example.gov/api/v1/models%2Fbeta+preview~v1?view=full&tag=a%2Bb"
}

@test "provider-facts: malformed or injection-shaped URL fails before verifier use" {
  load_acq
  local facts="$STUBDIR/usai-bad-url.env"
  cat > "$facts" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.example.gov
ACQ_PROVIDER_BASE_URL=https://api.example.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.example.gov/api/v1/models$(touch injected)
ACQ_PROVIDER_KEY_ENV=EXAMPLE_API_KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://example.gov/keys
ACQ_PROVIDER_BIND_HOSTS=api.example.gov
FACTS

  run acq_provider_facts_load "$facts"
  assert_failure
  assert_equal "$USAI_PROVIDER_MODELS_URL" "https://api.gsa.usai.gov/api/v1/models"
  refute [ -e "$STUBDIR/injected" ]
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

@test "provider-facts: kit loader consumes artifact from a fetched kit" {
  load_acq
  local kit="$STUBDIR/provider-kit" cache="$STUBDIR/provider-cache"
  mkdir -p "$kit/provider-facts"
  cat > "$kit/provider-facts/usai.env" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.kit.gov
ACQ_PROVIDER_BASE_URL=https://api.kit.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.kit.gov/api/v1/models
ACQ_PROVIDER_KEY_ENV=KIT_API_KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://kit.gov/keys
ACQ_PROVIDER_BIND_HOSTS=api.kit.gov
FACTS

  acq_provider_facts_load_from_kit "$kit" "$cache"
  assert_equal "$USAI_PROVIDER_HOST" "api.kit.gov"
  assert_equal "$USAI_PROVIDER_KEY_ENV" "KIT_API_KEY"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "$kit/provider-facts/usai.env"
}

@test "provider-facts: kit loader keeps fallback when artifact is absent" {
  load_acq
  local kit="$STUBDIR/provider-kit-empty" cache="$STUBDIR/provider-cache-empty"
  mkdir -p "$kit"

  run acq_provider_facts_load_from_kit "$kit" "$cache"
  assert_failure 2
  assert_equal "$USAI_PROVIDER_HOST" "api.gsa.usai.gov"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "fallback"
}

@test "provider-facts: kit loader fails closed for invalid artifact" {
  load_acq
  local kit="$STUBDIR/provider-kit-bad" cache="$STUBDIR/provider-cache-bad"
  mkdir -p "$kit/provider-facts"
  cat > "$kit/provider-facts/usai.env" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.bad.gov
ACQ_PROVIDER_BASE_URL=https://api.bad.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.bad.gov/api/v1/models
ACQ_PROVIDER_KEY_ENV=BAD-KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://bad.gov/keys
ACQ_PROVIDER_BIND_HOSTS=api.bad.gov
FACTS

  run acq_provider_facts_load_from_kit "$kit" "$cache"
  assert_failure
  assert_equal "$USAI_PROVIDER_HOST" "api.gsa.usai.gov"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "fallback"
}


@test "provider-facts: wrapper preserves assignments from successful kit load (regression for #551)" {
  load_acq
  local kit="$STUBDIR/provider-kit-ok" cache="$STUBDIR/provider-cache-ok"
  mkdir -p "$kit/provider-facts"
  cat > "$kit/provider-facts/usai.env" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=custom.example.gov
ACQ_PROVIDER_BASE_URL=https://custom.example.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://custom.example.gov/api/v1/models
ACQ_PROVIDER_KEY_ENV=CUSTOM_API_KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://custom.example.gov/keys
ACQ_PROVIDER_BIND_HOSTS=custom.example.gov,models.custom.example.gov
FACTS

  acq_provider_facts_load_from_kit_or_fallback "$kit" "$cache"
  assert_equal "$USAI_PROVIDER_HOST" "custom.example.gov"
  assert_equal "$USAI_PROVIDER_BASE_URL" "https://custom.example.gov/api/v1"
  assert_equal "$USAI_PROVIDER_MODELS_URL" "https://custom.example.gov/api/v1/models"
  assert_equal "$USAI_PROVIDER_KEY_ENV" "CUSTOM_API_KEY"
  assert_equal "$USAI_PROVIDER_KEY_MGMT_URL" "https://custom.example.gov/keys"
  assert_equal "$USAI_PROVIDER_BIND_HOSTS" "custom.example.gov,models.custom.example.gov"
  assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "$kit/provider-facts/usai.env"
}

@test "provider-facts: wrapper preserves IFS and caller shell state (regression for #551 indirect)" {
  load_acq
  local kit="$STUBDIR/provider-kit-ok" cache="$STUBDIR/provider-cache-ok"
  mkdir -p "$kit/provider-facts"
  cat > "$kit/provider-facts/usai.env" <<'FACTS'
ACQ_PROVIDER_FACTS_SCHEMA=1
ACQ_PROVIDER_ID=usai
ACQ_PROVIDER_HOST=api.example.gov
ACQ_PROVIDER_BASE_URL=https://api.example.gov/api/v1
ACQ_PROVIDER_MODELS_URL=https://api.example.gov/api/v1/models
ACQ_PROVIDER_KEY_ENV=EXAMPLE_API_KEY
ACQ_PROVIDER_KEY_MGMT_URL=https://api.example.gov/keys
ACQ_PROVIDER_BIND_HOSTS=api.example.gov
FACTS

  # Snapshot IFS before call
  local _before_ifs="$IFS"
  # Call the wrapper
  acq_provider_facts_load_from_kit_or_fallback "$kit" "$cache"
  # Verify IFS is restored
  assert_equal "$IFS" "$_before_ifs"
  # Verify provider vars are assigned
  assert_equal "$USAI_PROVIDER_HOST" "api.example.gov"
}

@test "provider-facts: wrapper classifies loader results under errexit with custom IFS" {
  load_acq
  local diagnostics="$STUBDIR/provider-facts-diagnostics" rc actual_rc
  local _before_ifs

  for rc in 0 1 2 3 7; do
    USAI_PROVIDER_HOST="before.example.gov"
    USAI_PROVIDER_FACTS_SOURCE="before"
    IFS='|'
    _before_ifs="$IFS"
    acq_provider_facts_load_from_kit() {
      printf 'loader diagnostic for rc %s\n' "$rc" >&2
      if [ "$rc" -eq 0 ]; then
        USAI_PROVIDER_HOST="loaded.example.gov"
        USAI_PROVIDER_FACTS_SOURCE="loaded"
      fi
      return "$rc"
    }

    set -e
    if acq_provider_facts_load_from_kit_or_fallback kit cache 2>"$diagnostics"; then
      actual_rc=0
    else
      actual_rc=$?
    fi

    assert_equal "$IFS" "$_before_ifs"
    case "$rc" in
      0)
        assert_equal "$actual_rc" "0"
        assert_equal "$USAI_PROVIDER_HOST" "loaded.example.gov"
        assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "loaded"
        grep -Fqx "loader diagnostic for rc 0" "$diagnostics"
        ;;
      1)
        assert_equal "$actual_rc" "1"
        assert_equal "$USAI_PROVIDER_HOST" "before.example.gov"
        grep -Fqx "loader diagnostic for rc 1" "$diagnostics"
        ;;
      2)
        assert_equal "$actual_rc" "0"
        assert_equal "$USAI_PROVIDER_HOST" "api.gsa.usai.gov"
        assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "fallback"
        grep -Fqx "loader diagnostic for rc 2" "$diagnostics"
        ;;
      3)
        assert_equal "$actual_rc" "0"
        assert_equal "$USAI_PROVIDER_HOST" "api.gsa.usai.gov"
        assert_equal "$USAI_PROVIDER_FACTS_SOURCE" "fallback"
        grep -Fq "provider facts could not be fetched" "$diagnostics"
        grep -Fq "loader diagnostic for rc 3" "$diagnostics"
        ;;
      7)
        assert_equal "$actual_rc" "7"
        assert_equal "$USAI_PROVIDER_HOST" "before.example.gov"
        grep -Fqx "loader diagnostic for rc 7" "$diagnostics"
        ;;
    esac
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

@test "provider-facts: wrapper preserves unset caller IFS under set -u" {
  load_acq

  (
    set -u
    unset IFS
    acq_provider_facts_load_from_kit() {
      IFS='|'
      USAI_PROVIDER_HOST="loaded.example.gov"
      USAI_PROVIDER_FACTS_SOURCE="loaded"
      return 0
    }

    acq_provider_facts_load_from_kit_or_fallback kit cache

    [ -z "${IFS+x}" ]
    [ "$USAI_PROVIDER_HOST" = "loaded.example.gov" ]
    [ "$USAI_PROVIDER_FACTS_SOURCE" = "loaded" ]
  )
}

@test "provider-facts: fallback preserves unset caller IFS under set -u" {
  load_acq

  (
    set -u
    unset IFS
    acq_provider_facts_load_from_kit() { IFS='|'; return 2; }

    acq_provider_facts_load_from_kit_or_fallback kit cache

    [ -z "${IFS+x}" ]
    [ "$USAI_PROVIDER_HOST" = "api.gsa.usai.gov" ]
    [ "$USAI_PROVIDER_FACTS_SOURCE" = "fallback" ]
  )
}
