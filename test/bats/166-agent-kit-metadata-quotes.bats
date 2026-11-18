#!/usr/bin/env bats
# shellcheck shell=bats
# Agent metadata quoting through the real awk parser: quoted scalars are valid
# YAML, so the readiness gate must accept them exactly as it accepts bare ones.
load 'helper'

setup() {
  acq_setup_stubs
  KITDIR="$STUBDIR/kit"
  mkdir -p "$KITDIR"
}

teardown() { acq_teardown_stubs; }

_write_spec() {
  local name_value="$1" entry_value="$2"
  cat > "$KITDIR/spec.yaml" <<SPEC
schemaVersion: "hybrid/v1"
kind: mixin
name: opencode
agent:
  name: ${name_value}
  entrypoint: ${entry_value}
SPEC
}

@test "agent metadata: single-quoted name and entrypoint are unquoted" {
  _write_spec "'opencode'" "'opencode'"
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" name)" opencode
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" entrypoint)" opencode
}

@test "agent metadata: double-quoted name and entrypoint are unquoted" {
  _write_spec '"opencode"' '"opencode"'
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" name)" opencode
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" entrypoint)" opencode
}

@test "agent metadata: bare values are unchanged" {
  _write_spec opencode opencode
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" name)" opencode
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" entrypoint)" opencode
}

@test "agent metadata: only a matching surrounding quote pair is stripped" {
  _write_spec "'opencode" "opencode'"
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" name)" "'opencode"
  assert_equal "$(kit_spec_agent_field "$KITDIR/spec.yaml" entrypoint)" "opencode'"
}

@test "agent metadata: readiness gate accepts single-quoted name and entrypoint" {
  _write_spec "'opencode'" "'opencode'"
  run acq_validate_agent_builtin_kit_dir opencode "$KITDIR"
  assert_success
}

@test "agent metadata: readiness gate accepts double-quoted name and entrypoint" {
  _write_spec '"opencode"' '"opencode"'
  run acq_validate_agent_builtin_kit_dir opencode "$KITDIR"
  assert_success
}

@test "agent metadata: readiness gate still rejects a wrong quoted entrypoint" {
  _write_spec "'opencode'" "'wrong'"
  run acq_validate_agent_builtin_kit_dir opencode "$KITDIR"
  assert_failure
}
