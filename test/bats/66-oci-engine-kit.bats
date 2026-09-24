#!/usr/bin/env bats
#
# 66-oci-engine-kit.bats — optional OCI-engine capability kit selection (ADR-0030)
#
# The OCI-engine kit is off by default and opt-in via ACQ_ENABLE_OCI_KIT. Because
# the patterns-side kit body is unpublished (see ADR-0020/ADR-0030), selection is
# additionally gated on a readiness check (acq_oci_engine_kit_ready): opted in but
# not-ready must NOT add the ref and must emit one clear notice. These tests are
# fully offline — the readiness check is stubbed per case, so no network fetch or
# real kit is required. In-process (no `run` for the array assertions) mirrors
# 50-kit-list-completeness.bats; the notice-emitting case captures stderr.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "oci-kit: default (no opt-in) does not select the oci-engine kit" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  ACQ_ENABLE_OCI_KIT=""
  _build_kit_list

  local joined; joined=$(printf '%s\n' "${KITS[@]}")
  refute_regex "$joined" 'acq-kits/oci-engine'
  # Default identity is unchanged: four support kits, zscaler first.
  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "4"
  assert_equal "${#ACQ_KIT_NAMES[@]}" "4"
  assert_regex "${KITS[0]}" 'acq-kits/zscaler-ca-certificate'
}

@test "oci-kit: default does not pollute the acq kit list registry" {
  load_acq
  refute_regex "$(printf '%s\n' "${ACQ_KIT_NAMES[@]}")" 'oci-engine'
}

@test "oci-kit: opted-in but NOT ready adds no ref and emits one clear notice" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  ACQ_ENABLE_OCI_KIT=1
  # Force NOT-ready: the real current state (kit unpublished at the pinned ref).
  acq_oci_engine_kit_ready() { return 1; }

  # The ref-selection helper never emits the ref when not-ready...
  run _acq_selected_builtin_kit_refs
  assert_success
  refute_regex "$output" 'acq-kits/oci-engine'

  # ...and _build_kit_list emits the single fallback notice (Fix A moved the
  # notice to the parent shell so the once-guard survives the subshell).
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'"
    ACQ_EXTRA_KITS=""
    ACQ_CLI_KITS=()
    ACQ_ENABLE_OCI_KIT=1
    acq_oci_engine_kit_ready() { return 1; }
    _build_kit_list >/dev/null
    printf "%s\n" "${KITS[@]}"
  ' 2>&1
  assert_success
  assert_output --partial 'OCI engine kit requested but not available at the pinned patterns ref'
  refute_regex "$output" 'acq-kits/oci-engine'
  # The notice prints exactly once.
  local n; n=$(printf '%s\n' "$output" | grep -c 'OCI engine kit requested but not available')
  assert_equal "$n" "1"

  # And the kit list itself is unchanged (support-only, zscaler first).
  _build_kit_list
  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "4"
  assert_regex "${KITS[0]}" 'acq-kits/zscaler-ca-certificate'
  refute_regex "$(printf '%s\n' "${KITS[@]}")" 'acq-kits/oci-engine'
}

@test "oci-kit: notice prints EXACTLY ONCE across a 2x _build_kit_list lifecycle" {
  # The dispatcher calls _build_kit_list multiple times per invocation
  # (acq_resolve_backend, the run/create arm, the sbx forced-heal). Guarding on
  # a single call cannot catch that spam; drive two calls in ONE process and
  # assert the notice appears exactly once across both. This proves Fix A's
  # process-global once-guard, not just the per-call de-dup.
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'"
    ACQ_EXTRA_KITS=""
    ACQ_CLI_KITS=()
    ACQ_ENABLE_OCI_KIT=1
    # Force NOT-ready in-process; memoization must not affect the once-guard.
    acq_oci_engine_kit_ready() { return 1; }
    _build_kit_list >/dev/null
    _build_kit_list >/dev/null
  ' 2>&1
  assert_success
  local n
  n=$(printf '%s\n' "$output" | grep -c 'OCI engine kit requested but not available')
  assert_equal "$n" "1"
}

@test "oci-kit: opted-in AND ready appends the oci-engine ref after support kits" {
  load_acq
  ACQ_EXTRA_KITS=""
  ACQ_CLI_KITS=()
  ACQ_ENABLE_OCI_KIT=1
  # Stub readiness ready, mirroring 90-sbx-startup-kit.bats' agent-kit stubbing.
  acq_oci_engine_kit_ready() { return 0; }
  _build_kit_list

  # Appended after the four default support kits, before any agent/extras/CLI kits.
  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "5"
  assert_equal "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "5"
  assert_regex "${KITS[0]}" 'acq-kits/zscaler-ca-certificate'
  assert_regex "${KITS[4]}" 'acq-kits/oci-engine'
}

@test "oci-kit: ready + extras keeps oci before extras in the list" {
  load_acq
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit"
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_CLI_KITS=()
  # shellcheck disable=SC2034  # read by sourced _acq_selected_builtin_kit_refs
  ACQ_ENABLE_OCI_KIT=1
  acq_oci_engine_kit_ready() { return 0; }
  _build_kit_list

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "5"
  assert_equal "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "5"
  assert_regex "${KITS[4]}" 'acq-kits/oci-engine'
  assert_regex "$(printf '%s\n' "${KITS[@]}")" 'some-extra-kit'
}

@test "oci-kit: ready support kit stays outside the agent-kit boundary" {
  load_acq
  local agent_kit="$STUBDIR/opencode-kit"
  mkdir -p "$agent_kit"
  cat >"$agent_kit/spec.yaml" <<'SPEC'
hi
SPEC
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_EXTRA_KITS=""
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_CLI_KITS=()
  # shellcheck disable=SC2034  # read by sourced _acq_selected_builtin_kit_refs
  ACQ_ENABLE_OCI_KIT=1
  acq_oci_engine_kit_ready() { return 0; }
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  acq_agent_builtin_kit_ready() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$agent_kit"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "6"
  assert_equal "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "5"
  assert_regex "${KITS[4]}" 'acq-kits/oci-engine'
  assert_equal "${KITS[5]}" "$agent_kit"
}

@test "oci-kit: the emitted ref is acq-kits/oci-engine under the GSA-TTS allowlist" {
  load_acq
  local ref; ref=$(_acq_oci_engine_kit_ref)
  assert_regex "$ref" 'agentic-coding-patterns'
  assert_regex "$ref" 'acq-kits/oci-engine$'
  # Under the built-in source allowlist prefix (github.com/GSA-TTS/), so no
  # allowlist widening is needed. KIT_SOURCE_PREFIX is scheme-less; the ref is a
  # git+https URL, so match the host/org path segment.
  assert_regex "$ref" "github.com/GSA-TTS/"
  assert_equal "$KIT_SOURCE_PREFIX" "github.com/GSA-TTS/"
}

@test "oci-kit: readiness TRUE for a well-formed oci-engine mixin spec (offline)" {
  load_acq
  # Exercise the REAL acq_oci_engine_kit_ready validation branch offline: stub
  # only the network fetch to hand back a temp dir we populate with a spec.yaml.
  local kitdir; kitdir=$(mktemp -d)
  cat >"$kitdir/spec.yaml" <<'SPEC'
schemaVersion: hybrid/v1
kind: mixin
name: oci-engine
SPEC
  eval 'kit_translate_fetch() { printf "%s\n" "'"$kitdir"'"; }'
  run acq_oci_engine_kit_ready
  rm -rf "$kitdir"
  assert_success
}

@test "oci-kit: readiness FALSE for a wrong-name spec (offline)" {
  load_acq
  local kitdir; kitdir=$(mktemp -d)
  cat >"$kitdir/spec.yaml" <<'SPEC'
schemaVersion: hybrid/v1
kind: mixin
name: not-oci-engine
SPEC
  eval 'kit_translate_fetch() { printf "%s\n" "'"$kitdir"'"; }'
  run acq_oci_engine_kit_ready
  rm -rf "$kitdir"
  assert_failure
}

@test "oci-kit: readiness FALSE for a wrong-kind spec (offline)" {
  load_acq
  local kitdir; kitdir=$(mktemp -d)
  cat >"$kitdir/spec.yaml" <<'SPEC'
schemaVersion: hybrid/v1
kind: bundle
name: oci-engine
SPEC
  eval 'kit_translate_fetch() { printf "%s\n" "'"$kitdir"'"; }'
  run acq_oci_engine_kit_ready
  rm -rf "$kitdir"
  assert_failure
}

@test "oci-kit: env normalization treats off-ish values as off" {
  local v
  for v in "" 0 false no off FALSE No OFF; do
    run env ACQ_ENABLE_OCI_KIT="$v" bash -c '
      ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
      printf "%s" "${ACQ_ENABLE_OCI_KIT:-EMPTY}"
    '
    assert_output "EMPTY"
  done
}

@test "oci-kit: env normalization treats any other value as on" {
  local v
  for v in 1 true yes on YES enabled anything; do
    run env ACQ_ENABLE_OCI_KIT="$v" bash -c '
      ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
      printf "%s" "$ACQ_ENABLE_OCI_KIT"
    '
    assert_output "1"
  done
}
