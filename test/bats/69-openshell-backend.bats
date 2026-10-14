#!/usr/bin/env bats

# OpenShell is explicit-only. These tests cover the pinned 0.1.4 local Docker
# contract without requiring an actual gateway or Docker daemon.

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

_openshell_create() {
  local project="$STUBDIR/project"
  mkdir -p "$project"
  run env ACQ_BACKEND=openshell ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 \
    ACQ_OPENSHELL_DRIVER=docker "$ACQ" create shell "$project"
}

@test "openshell: explicit backend resolves, lists, and reports its version" {
  run env ACQ_BACKEND=openshell "$ACQ" ls
  assert_success
  assert_regex "$(cat "$CALLS")" 'openshell sandbox list --output json'
  run env "$ACQ" backend list
  assert_output --partial 'openshell  v0.1.4 (explicit-only; experimental)'
}

@test "openshell: bind create maps image and workspace to driver config" {
  _openshell_create
  assert_success
  local line; line=$(grep '^openshell sandbox create' "$CALLS")
  assert_regex "$line" '--from docker\.io/docker/sandbox-templates:shell-docker'
  assert_regex "$line" 'driver-config-json.*"type":"bind"'
  assert_regex "$line" 'ACQ_WORKSPACE='
  assert [ -f "$STUBDIR/.openshell_created" ]
}

@test "openshell: neutral ACQ_IMAGE is creation-only --from input" {
  local project="$STUBDIR/image-project"; mkdir -p "$project"
  run env ACQ_BACKEND=openshell ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 ACQ_OPENSHELL_DRIVER=docker \
    ACQ_IMAGE=registry.example/acq:test "$ACQ" create shell "$project"
  assert_success
  assert_regex "$(grep '^openshell sandbox create' "$CALLS")" '--from registry\.example/acq:test'
}

@test "openshell: bind mode fails closed until explicitly enabled" {
  local project="$STUBDIR/no-bind"; mkdir -p "$project"
  run env ACQ_BACKEND=openshell "$ACQ" create shell "$project"
  assert_failure
  assert_output --partial 'ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1'
  refute_regex "$(cat "$CALLS")" 'openshell sandbox create'
}

@test "openshell: unavailable gateway blocks creation" {
  local project="$STUBDIR/no-gateway"; mkdir -p "$project"
  run env ACQ_BACKEND=openshell ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 STUB_OPENSHELL_NO_GATEWAY=1 \
    "$ACQ" create shell "$project"
  assert_failure
  assert_output --partial 'no usable selected gateway'
}

@test "openshell: readiness timeout cleans up the just-created sandbox" {
  local project="$STUBDIR/not-ready"; mkdir -p "$project"
  run env ACQ_BACKEND=openshell ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 STUB_OPENSHELL_NOT_READY=1 \
    ACQ_OPENSHELL_READY_TIMEOUT=0 "$ACQ" create shell "$project"
  assert_failure
  assert_regex "$(cat "$CALLS")" 'openshell sandbox delete shell-not-ready'
}

@test "openshell: readiness timeout cleans up clone scratch and source remote" {
  local project="$STUBDIR/clone-project" clones="$STUBDIR/clones"
  mkdir -p "$project"
  git -C "$project" init -q
  run env ACQ_BACKEND=openshell ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 STUB_OPENSHELL_NOT_READY=1 \
    ACQ_OPENSHELL_READY_TIMEOUT=0 ACQ_OPENSHELL_CLONES_DIR="$clones" "$ACQ" create --clone shell "$project"
  assert_failure
  assert_regex "$(cat "$CALLS")" 'openshell sandbox delete shell-clone-project'
  refute [ -d "$clones/shell-clone-project" ]
  run git -C "$project" remote get-url sandbox-shell-clone-project
  assert_failure
}

@test "openshell: non-shell creates and runs fail before provisioning" {
  local project="$STUBDIR/agent-project"; mkdir -p "$project"
  run env ACQ_BACKEND=openshell ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 "$ACQ" create opencode "$project"
  assert_failure
  assert_output --partial 'neutral kit translation and an agent entrypoint'
  refute_regex "$(cat "$CALLS")" 'openshell sandbox create'
  : > "$CALLS"
  run env ACQ_BACKEND=openshell ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 "$ACQ" run opencode "$project"
  assert_failure
  assert_output --partial 'GSA-TTS/agentic-coding-quickstart#577'
  refute_regex "$(cat "$CALLS")" 'openshell sandbox create'
}

@test "openshell: cp maps one sandbox endpoint to upload or download" {
  run env ACQ_BACKEND=openshell "$ACQ" cp local.txt box:/workspace/local.txt
  assert_success
  assert_regex "$(cat "$CALLS")" 'openshell sandbox upload box local.txt /workspace/local.txt'
  : > "$CALLS"
  run env ACQ_BACKEND=openshell "$ACQ" cp box:/workspace/out.txt out.txt
  assert_success
  assert_regex "$(cat "$CALLS")" 'openshell sandbox download box /workspace/out.txt out.txt'
}

@test "openshell: unsupported kits, ports, and secrets fail closed" {
  run env ACQ_BACKEND=openshell "$ACQ" ports box
  assert_failure
  assert_output --partial 'public service exposure are unsupported'
  run env ACQ_BACKEND=openshell "$ACQ" kit apply box openchamber
  assert_failure
  assert_output --partial 'neutral kit application is unsupported'
  run env ACQ_BACKEND=openshell "$ACQ" secret set -g usai
  assert_failure
  assert_output --partial 'providers and secrets are unsupported'
}
