#!/usr/bin/env bats
#
# 73-msb-kits-startup.bats — bats port of scripts/test-acq.d/73-msb-kits-startup.sh
# (ADR-0017, ADR-0025)
#
# msb kit application (all files + all commands, no-drop), the environment[]
# threading, the exec-based (not --script) command dispatch decision guards,
# install-marker idempotency, and the ADR-0017 create-time startup-script
# staging (generation, body fidelity, SI-10 quoting, multi-kit single-stake +
# no-drop, named-user path). Real provisions run in isolated subshells; the
# generated staged scripts are read back from ACQ_MSB_STARTUP_STAGE_DIR.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "msb: applies ALL kit files and ALL kit commands (no stdin-drain drop)" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/multi-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mk="'"$STUBDIR"'/multikit"; mkdir -p "$mk/files/home"
    printf "A\n" > "$mk/files/home/file_one"
    printf "B\n" > "$mk/files/home/file_two"
    cat >"$mk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit
displayName: Multi Kit
description: two files and two startup commands
files:
  - path: /home/agent/file_one
    mode: "0644"
    source: files/home/file_one
  - path: /home/agent/file_two
    mode: "0644"
    source: files/home/file_two
commands:
  - phase: startup
    user: "0"
    command: [sh, -c, echo CMD_ALPHA]
  - phase: startup
    user: "0"
    command: [sh, -c, echo CMD_BETA]
SPEC
    _acq_msb_apply_kit_dir multibox "$mk"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb copy ${STUBDIR}/multikit/files/home/file_one multibox:/home/agent/file_one"
  assert_regex "$log" "msb copy ${STUBDIR}/multikit/files/home/file_two multibox:/home/agent/file_two"
  assert_regex "$log" 'echo CMD_ALPHA'
  assert_regex "$log" 'echo CMD_BETA'
}

@test "msb env: kit environment[] threads -e NAME=value onto exec; an unsafe name is dropped" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/env-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ek="'"$STUBDIR"'/envkit"; mkdir -p "$ek"
    cat >"$ek/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: env-kit
displayName: Env Kit
description: environment vars threaded to msb exec
environment:
  GITLAB_HOST: gitlab.example.gov
  "1BAD": should-be-dropped
commands:
  - phase: startup
    user: "0"
    command: [sh, -c, echo CMD_WITH_ENV]
SPEC
    _acq_msb_apply_kit_dir envbox "$ek"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '-e GITLAB_HOST=gitlab.example.gov'
  assert_regex "$log" 'echo CMD_WITH_ENV'
  refute_regex "$log" '1BAD'
}

@test "#239: kit commands are staged via msb exec argv, never --script, never sh -c interpolation" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/noscript-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    nsk="'"$STUBDIR"'/noscriptkit"; mkdir -p "$nsk"
    cat >"$nsk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: noscript-kit
displayName: NoScript Kit
description: command body with metachars stays argv
commands:
  - phase: startup
    user: "0"
    command:
      - printf
      - "%s\n"
      - "hello; rm -rf /tmp/NS_PWNED"
SPEC
    _acq_msb_apply_kit_dir noscriptbox "$nsk"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec noscriptbox'
  assert_regex "$log" -- '-- printf'
  assert_regex "$log" 'hello; rm -rf /tmp/NS_PWNED'
  refute_regex "$log" -- '--script'
  refute_regex "$log" -- '--script-path'
  refute_regex "$log" 'sh -c printf'
}

@test "#239: an install-phase command is marker-gated in the exec path (run-once)" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/instmarker-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    imk="'"$STUBDIR"'/instmarkerkit"; mkdir -p "$imk"
    cat >"$imk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: instmarker-kit
displayName: InstMarker Kit
description: install command is marker-gated in the exec path
commands:
  - phase: install
    user: "0"
    command: [true]
SPEC
    _acq_msb_apply_kit_dir instmarkerbox "$imk"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "test -f '/var/lib/acq/install-"
  assert_regex "$log" "touch '/var/lib/acq/install-"
  assert_regex "$log" 'msb exec instmarkerbox -u 0'
}

# Provision helper that stages startup scripts to a per-test dir and keeps them.
_provision_staged() { # NAME STAGE_SUBDIR PRE_SNIPPET
  local name="$1" stage="$2" pre="$3"
  : > "$CALLS"
  run bash -c '
    name="$1"; stage="$2"; pre="$3"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1
    export ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/$stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_provision "$name" shell /tmp >/dev/null 2>&1
  ' _ "$name" "$stage" "$pre"
}
_staged_body() { cat "$(find "$STUBDIR/$1" -type f 2>/dev/null | head -n1)" 2>/dev/null; }

@test "0017: a startup command stages a create-time --script-path with a faithful body" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/su-secrets"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/startup-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    suk="'"$STUBDIR"'/startupkit"; mkdir -p "$suk"
    cat >"$suk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: startup-kit
displayName: Startup Kit
description: one agent-user startup command staged as a create-time script
commands:
  - phase: startup
    user: "1000"
    command: [sh, -c, echo STARTUP_MARKER_ALPHA]
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$suk"; }
    acq_backend_provision startupbox shell /tmp >/dev/null 2>&1
  '
  local log su_file body
  log=$(cat "$CALLS")
  assert_regex "$log" -- '--script-path acq-startup:'
  su_file=$(find "$STUBDIR/startup-stage" -type f 2>/dev/null | head -n1)
  body=$(cat "$su_file" 2>/dev/null)
  assert_regex "$body" '#!/bin/sh'
  assert_regex "$body" 'echo STARTUP_MARKER_ALPHA'
  assert_regex "$body" 'runuser -u agent'
  assert_regex "$body" 'HOME=/home/agent'
  assert_regex "$log" -- "--script-path acq-startup:${su_file}"
}

@test "0017: a background startup command is staged with nohup detach" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/bgsu-secrets"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/bgstartup-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    bsk="'"$STUBDIR"'/bgstartupkit"; mkdir -p "$bsk"
    cat >"$bsk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: bgstartup-kit
displayName: BG Startup Kit
description: a background startup supervisor staged with nohup detach
commands:
  - phase: startup
    user: "0"
    background: true
    command: [supervisor-loop-0017]
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$bsk"; }
    acq_backend_provision bgstartupbox shell /tmp >/dev/null 2>&1
  '
  local body; body=$(_staged_body bgstartup-stage)
  assert_regex "$body" 'nohup'
  assert_regex "$body" 'supervisor-loop-0017'
}

@test "0017: a kit with no startup command stages no acq-startup script" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/nostartup-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/nostartup-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    nsk2="'"$STUBDIR"'/nostartupkit"; mkdir -p "$nsk2"
    cat >"$nsk2/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: nostartup-kit
displayName: NoStartup Kit
description: only an install command, no startup phase
commands:
  - phase: install
    user: "0"
    command: [true]
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$nsk2"; }
    acq_backend_provision nostartupbox shell /tmp >/dev/null 2>&1
  '
  refute_regex "$(cat "$CALLS")" -- '--script-path acq-startup'
}

@test "0017: install stays exec-based (marker-gated); only startup is staged" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/mix-secrets"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/mix-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mxk="'"$STUBDIR"'/mixkit"; mkdir -p "$mxk"
    cat >"$mxk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: mix-kit
displayName: Mix Kit
description: install stays exec-based; startup is staged
commands:
  - phase: install
    user: "0"
    command: [sh, -c, echo INSTALL_ONLY_0017]
  - phase: startup
    user: "0"
    command: [sh, -c, echo STARTUP_ONLY_0017]
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$mxk"; }
    acq_backend_provision mixbox shell /tmp >/dev/null 2>&1
  '
  local log body
  log=$(cat "$CALLS")
  body=$(_staged_body mix-stage)
  assert_regex "$log" "test -f '/var/lib/acq/install-"
  assert_regex "$log" 'echo INSTALL_ONLY_0017'
  assert_regex "$body" 'echo STARTUP_ONLY_0017'
  refute_regex "$body" 'INSTALL_ONLY_0017'
}

@test "0017 (SI-10): a metachar startup body is single-quoted data; no secret value leaks; body is valid sh" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/inj-secrets"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/inj-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    printf "SUPER_SECRET_VALUE_0017\n" | acq_secret_store "$(_acq_secret_key usai injbox)" >/dev/null 2>&1
    injk="'"$STUBDIR"'/injstartupkit"; mkdir -p "$injk"
    cat >"$injk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: injstartup-kit
displayName: InjStartup Kit
description: metachar startup body stays quoted data (SI-10)
commands:
  - phase: startup
    user: "0"
    command:
      - printf
      - "%s\n"
      - "hello; rm -rf /tmp/STARTUP_PWNED"
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$injk"; }
    acq_backend_provision injbox shell /tmp >/dev/null 2>&1
  '
  local log inj_file body
  log=$(cat "$CALLS")
  inj_file=$(find "$STUBDIR/inj-stage" -type f 2>/dev/null | head -n1)
  body=$(cat "$inj_file" 2>/dev/null)
  assert_regex "$body" "'hello; rm -rf /tmp/STARTUP_PWNED'"
  refute_regex "$body" 'SUPER_SECRET_VALUE_0017'
  refute_regex "$log" 'SUPER_SECRET_VALUE_0017'
  assert [ -n "$inj_file" ]
  run sh -n "$inj_file"
  assert_success
}

@test "0017: the staged startup body carries git guards + kit env, env prefix busybox-safe" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/fidel-secrets"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/fidel-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    fdk="'"$STUBDIR"'/fidelkit"; mkdir -p "$fdk"
    cat >"$fdk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: fidel-kit
displayName: Fidelity Kit
description: startup body carries git guards + a kit environment var
environment:
  GITLAB_HOST: gitlab.example.gov
commands:
  - phase: startup
    user: "0"
    command: [sh, -c, echo FIDELITY_MARKER]
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$fdk"; }
    acq_backend_provision fidelbox shell /tmp >/dev/null 2>&1
  '
  local body; body=$(_staged_body fidel-stage)
  assert_regex "$body" 'GIT_TERMINAL_PROMPT=0'
  assert_regex "$body" 'GIT_ASKPASS=/bin/false'
  assert_regex "$body" 'SSH_ASKPASS=/bin/false'
  assert_regex "$body" 'GITLAB_HOST=gitlab.example.gov'
  assert_regex "$body" 'env '
  refute_regex "$body" 'env --'
}

@test "0017: two kits with startup commands stake exactly one script but both run post-create" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/multi2-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/multi2-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mk1="'"$STUBDIR"'/multikit1"; mkdir -p "$mk1"
    cat >"$mk1/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit-one
displayName: Multi Kit One
description: first kit with a startup command
commands:
  - phase: startup
    user: "0"
    command: [sh, -c, echo MULTI_STARTUP_ONE]
SPEC
    mk2="'"$STUBDIR"'/multikit2"; mkdir -p "$mk2"
    cat >"$mk2/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit-two
displayName: Multi Kit Two
description: second kit with a startup command
commands:
  - phase: startup
    user: "0"
    command: [sh, -c, echo MULTI_STARTUP_TWO]
SPEC
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    USAI_KIT="k1"; PLAYBOOK_KIT="k2"; ZSCALER_KIT="k3"; GITSSHSIGN_KIT="k4"
    _acq_msb_fetch_kit() {
      case "$1" in
        k1) printf "%s\n" "$mk1" ;;
        k2) printf "%s\n" "$mk2" ;;
        *)  printf "%s\n" "'"$STUBDIR"'/nokit" ;;
      esac
    }
    acq_backend_provision multibox shell /tmp >/dev/null 2>&1
  '
  local log stakes
  log=$(cat "$CALLS")
  stakes=$(printf '%s\n' "$log" | grep -c -- '--script-path acq-startup:')
  assert_equal "$stakes" "1"
  assert_regex "$log" 'echo MULTI_STARTUP_ONE'
  assert_regex "$log" 'echo MULTI_STARTUP_TWO'
}

@test "0017: a named non-agent user emits su <user> -c, not the agent runuser path" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/named-secrets"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/named-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    nmk="'"$STUBDIR"'/namedkit"; mkdir -p "$nmk"
    cat >"$nmk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: named-kit
displayName: Named Kit
description: startup command as a named non-agent user
commands:
  - phase: startup
    user: "postgres"
    command: [sh, -c, echo NAMED_USER_MARKER]
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$nmk"; }
    acq_backend_provision namedbox shell /tmp >/dev/null 2>&1
  '
  local body; body=$(_staged_body named-stage)
  assert_regex "$body" "su 'postgres' -c"
  assert_regex "$body" 'echo NAMED_USER_MARKER'
  refute_regex "$body" 'runuser -u agent'
}
