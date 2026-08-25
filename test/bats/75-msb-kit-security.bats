#!/usr/bin/env bats
#
# 75-msb-kit-security.bats — bats port of scripts/test-acq.d/75-msb-kit-security.sh
# (ADR-0025)
#
# SECURITY guards for kit translation on msb: hostile file `mode`, command
# `user`, unsafe paths, and env var names must be rejected/dropped and NEVER
# interpolated into a root shell or msb argv. Also the home-dir ownership fix
# (#234): the top-most created subtree under /home/agent is chowned recursively
# by NAME. Each case runs the real helpers in an isolated subshell; the injected
# payloads are asserted absent from the recorded $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "sec: a hostile file mode is dropped with a warning and emits no file record" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    ik="'"$STUBDIR"'/injkit"; mkdir -p "$ik/files"; printf "x\n" > "$ik/files/evil"
    cat >"$ik/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: inj-kit
displayName: Inj
description: hostile mode
files:
  - path: /home/agent/evil
    mode: "0644; touch /tmp/PWNED"
    source: files/evil
SPEC
    kit_spec_files "$ik/spec.yaml" 2>&1
  '
  assert_output --partial 'invalid mode'
  # No actual file record (a non-"kit-translate:" line) was emitted.
  local records
  records=$(printf '%s\n' "$output" | grep -v '^kit-translate:' || true)
  assert_equal "$records" ""
}

@test "sec: msb copy/chmod refuses non-octal mode + unsafe path, never via sh -c" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_copy_file_verified secbox /etc/hostname "/home/agent/ok" "0644; touch /tmp/PWNED" 2>&1
    _acq_msb_copy_file_verified secbox /etc/hostname "/home/agent/a;b" "0644" 2>&1
  '
  assert_output --partial 'non-octal mode'
  assert_output --partial 'unsafe path'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'chmod 0644;'
  refute_regex "$log" 'PWNED'
}

@test "sec (#234): chowns the top-most created home subtree recursively by name" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/home-own-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_copy_file_verified hobox /etc/hostname "/home/agent/.local/bin/opencode" "0755" >/dev/null 2>&1
    _acq_msb_copy_file_verified hobox /etc/hostname "/home/agent/direct-file" "0644" >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'chown -R -P agent /home/agent/\.local'
  refute_regex "$log" 'chown -R -P agent /home/agent/\.local/bin/opencode'
  refute_regex "$log" 'chown -R -P agent /home/agent '
  refute_regex "$log" 'chown -R 1000'
  assert_regex "$log" 'chown -R -P agent /home/agent/direct-file'
}

@test "sec: a hostile command user is dropped by kit_spec_commands" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    uk="'"$STUBDIR"'/userkit"; mkdir -p "$uk"
    cat >"$uk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: user-kit
displayName: User
description: hostile user
commands:
  - phase: startup
    user: "0 -- sh -c touch/tmp/PWNED"
    command:
      - true
SPEC
    kit_spec_commands "$uk/spec.yaml" 2>&1
  '
  assert_output --partial 'unsafe user'
  refute_output --partial '__CMD__'
}

@test "kit validate: reports (not silently drops) hostile mode + bad phase" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    vk="'"$STUBDIR"'/valkit"; mkdir -p "$vk/files"; printf "x\n" > "$vk/files/f"
    cat >"$vk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: val-kit
displayName: Val
description: bad mode + bad phase
files:
  - path: /home/agent/f
    mode: "0644; rm -rf /"
    source: files/f
commands:
  - phase: bogus-phase
    user: "0"
    command:
      - true
SPEC
    kit_validate "$vk" 2>&1; echo "RC=$?"
  '
  assert_output --partial 'mode must be a 4-digit octal string'
  assert_output --partial 'unknown command phase'
  assert_output --partial 'RC=1'
}

@test "kit validate: reports an invalid environment variable name" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    evk="'"$STUBDIR"'/envvalkit"; mkdir -p "$evk"
    cat >"$evk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: env-val-kit
displayName: Env Val
description: bad env var name
environment:
  GOOD_VAR: ok
  "1BAD": nope
SPEC
    kit_validate "$evk" 2>&1; echo "RC=$?"
  '
  assert_output --partial 'invalid env var name'
  assert_output --partial 'RC=1'
}
