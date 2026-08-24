#!/usr/bin/env bats
#
# 105-ports-background.bats — bats port of scripts/test-acq.d/105-ports-background.sh
# (ADR-0014, ADR-0025)
#
# Neutral publishedPorts + background vocabulary: neutral parse -> sbx-v2 ports +
# msb -p; the deprecated backend_extras.sbx fallback (with warning) and its
# suppression by a neutral list; SI-10 validation; detached background commands
# on msb vs preserved-flag on sbx; absence no-op; and the host-column regression.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "pp: neutral publishedPorts parse to records; msb -p HOST:GUEST; sbx-v2 ports block" {
  local ppkit="$STUBDIR/ppkit" ppout="$STUBDIR/ppout"
  mkdir -p "$ppkit"
  cat >"$ppkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: pp-kit
displayName: PP Kit
description: neutral publishedPorts
publishedPorts:
  - guest: 3000
    host: 8080
    protocol: tcp
    name: ui
  - guest: 4096
    protocol: tcp
    name: api
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$ppkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial "$(printf '3000\ttcp\tui\t8080')"
  assert_output --partial "$(printf '4096\ttcp\tapi\t4096')"

  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_port_flags_into arr "'"$ppkit"'/spec.yaml"; printf "%s\n" "${arr[@]}"
  '
  assert_output --partial '8080:3000'
  assert_output --partial '4096:4096'
  assert_output --partial '-p'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$ppkit"'" "'"$ppout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$ppout/spec.yaml")
  assert_regex "$spec" 'ports:'
  refute_regex "$spec" 'publishedPorts:'
  assert_regex "$spec" '- container: 3000'
  assert_regex "$spec" '- container: 4096'
}

@test "pp: the legacy backend_extras.sbx.publishedPorts still translates but warns DEPRECATION" {
  local lpkit="$STUBDIR/lpkit"; mkdir -p "$lpkit"
  cat >"$lpkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: legacy-pp-kit
displayName: Legacy PP Kit
description: deprecated sbx-only ports
backend_extras:
  sbx:
    publishedPorts:
      - container: 3000
        protocol: tcp
        name: web
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$lpkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial "$(printf '3000\ttcp\tweb\t3000')"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$lpkit"'/spec.yaml" 2>&1 >/dev/null'
  assert_output --partial 'DEPRECATION'
  assert_output --partial 'backend_extras.sbx.publishedPorts'
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_port_flags_into arr "'"$lpkit"'/spec.yaml" 2>/dev/null; printf "%s\n" "${arr[@]}"
  '
  assert_output --partial '3000:3000'
}

@test "pp: a neutral list suppresses the deprecated fallback (no warning)" {
  local bothkit="$STUBDIR/bothkit"; mkdir -p "$bothkit"
  cat >"$bothkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: both-kit
displayName: Both Kit
description: neutral wins over legacy
publishedPorts:
  - guest: 5000
    name: neutral-port
backend_extras:
  sbx:
    publishedPorts:
      - container: 9999
        name: legacy-port
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$bothkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial '5000'
  refute_output --partial '9999'
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$bothkit"'/spec.yaml" 2>&1 >/dev/null'
  refute_output --partial 'DEPRECATION'
}

@test "pp: invalid publishedPorts entries are dropped+warned and reported by kit validate" {
  local badpkit="$STUBDIR/badpkit"; mkdir -p "$badpkit"
  cat >"$badpkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bad-pp-kit
displayName: Bad PP Kit
description: invalid published ports dropped
publishedPorts:
  - guest: 99999
    name: too-big
  - guest: 3000
    protocol: sctp
    name: bad-proto
  - guest: 3001
    name: "bad name!"
  - guest: 3002
    host: notanumber
  - guest: 3003
    protocol: tcp
    name: ok
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$badpkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial '3003'
  refute_output --partial '99999'
  refute_output --partial '3000'
  refute_output --partial '3001'
  refute_output --partial '3002'
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$badpkit"'/spec.yaml" 2>&1 >/dev/null'
  assert_output --partial 'invalid guest port'
  assert_output --partial 'invalid protocol'
  assert_output --partial 'unsafe name'
  assert_output --partial 'invalid host port'
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_validate "'"$badpkit"'/spec.yaml" 2>&1'
  assert_output --partial 'invalid publishedPorts entry'
}

@test "pp: absence of publishedPorts is a no-op for parse and msb flags" {
  local nonekit="$STUBDIR/nonekit"; mkdir -p "$nonekit"
  cat >"$nonekit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: none-kit
displayName: None Kit
description: no ports at all
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_published_ports "'"$nonekit"'/spec.yaml" 2>&1'
  assert_output ''
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_port_flags_into arr "'"$nonekit"'/spec.yaml" 2>&1; printf "%s" "${arr[@]:-}"
  '
  assert_output ''
}

@test "bg: background:true surfaces in the __CMD__ record; a non-boolean coerces to false+warn" {
  local bgkit="$STUBDIR/bgkit"; mkdir -p "$bgkit"
  cat >"$bgkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bg-kit
displayName: BG Kit
description: background startup command
commands:
  - phase: startup
    user: "1000"
    background: true
    command:
      - sh
      - -c
      - |
        while true; do sleep 5; done
  - phase: startup
    user: "1000"
    background: maybe
    command:
      - node
      - /home/agent/run.mjs
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_commands "'"$bgkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial "$(printf '__CMD__\tstartup\t1000\ttrue')"
  assert_output --partial "$(printf '__CMD__\tstartup\t1000\tfalse')"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_commands "'"$bgkit"'/spec.yaml" 2>&1 >/dev/null'
  assert_output --partial 'background must be true|false'
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_validate "'"$bgkit"'/spec.yaml" 2>&1'
  assert_output --partial 'command background must be true|false'
}

@test "bg(msb): a background startup command runs detached (nohup &); foreground is awaited" {
  local bgk="$STUBDIR/bgk2"; mkdir -p "$bgk"
  cat >"$bgk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bg2-kit
displayName: BG2 Kit
description: background + foreground startup
commands:
  - phase: startup
    user: "0"
    background: true
    command:
      - supervisor-loop
  - phase: startup
    user: "0"
    command:
      - foreground-cmd
SPEC
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/bg-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_run_commands bgbox "'"$bgk"'/spec.yaml"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'nohup'
  assert_regex "$log" 'supervisor-loop'
  assert_regex "$log" -- '-- foreground-cmd'
}

@test "bg(sbx): the translator preserves background: true without wrapping in nohup" {
  local sbgkit="$STUBDIR/sbgkit" sbgout="$STUBDIR/sbgout"
  mkdir -p "$sbgkit"
  cat >"$sbgkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: sbg-kit
displayName: SBG Kit
description: background startup on sbx
commands:
  - phase: startup
    user: "1000"
    background: true
    command:
      - sh
      - -c
      - |
        sh /home/agent/supervisor.sh &
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$sbgkit"'" "'"$sbgout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$sbgout/spec.yaml")
  assert_regex "$spec" '  startup:'
  assert_regex "$spec" '        - sh'
  assert_regex "$spec" 'sh /home/agent/supervisor\.sh &'
  assert_regex "$spec" 'background: true'
  refute_regex "$spec" 'nohup'
  refute_regex "$spec" '& &'
  local n; n=$(printf '%s\n' "$spec" | grep -cE '(^|[^&])&([^&]|$)')
  assert_equal "$n" "1"
}

@test "pp: an entry with guest+host but no protocol/name keeps the host column (regression)" {
  local hokit="$STUBDIR/hokit" hoout="$STUBDIR/hoout"
  mkdir -p "$hokit"
  cat >"$hokit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: host-only-kit
displayName: Host Only Kit
description: guest plus host with no protocol or name
publishedPorts:
  - guest: 3000
    host: 8080
SPEC
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_port_flags_into arr "'"$hokit"'/spec.yaml"; printf "%s\n" "${arr[@]}"
  '
  assert_output --partial '8080:3000'
  refute_output --partial '3000:3000'
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$hokit"'" "'"$hoout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$hoout/spec.yaml")
  assert_regex "$spec" '- container: 3000'
  refute_regex "$spec" 'protocol: 8080'
}
