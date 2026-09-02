#!/usr/bin/env bats
#
# 78-msb-kit-env.bats — msb kit environment[] persistence + session replay.
#
# A kit's environment[] block exists for agent-runtime config (see ADR-0011:
# OPENCODE_CONFIG-style vars). On msb the entries were only threaded onto the
# kit's own provisioning commands and never reached the agent session or
# `acq exec`/`acq shell` — the kit env silently no-op'd at runtime. The fix
# persists the validated entries to a root-owned guest marker
# (/var/lib/acq/kit-env, same pattern as /var/lib/acq/agent and
# /var/lib/acq/ssh-auth-sock) at apply time, and every session path reads the
# marker back and threads each entry as `msb exec -e NAME=value`.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "msb kit env: apply persists environment[] to /var/lib/acq/kit-env; unsafe name is dropped" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/kitenv-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ek="'"$STUBDIR"'/persistkit"; mkdir -p "$ek"
    cat >"$ek/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: persist-kit
displayName: Persist Kit
description: environment vars persisted for session replay
environment:
  OPENCODE_CONFIG: /home/agent/.config/opencode/kit.jsonc
  "1BAD": should-be-dropped
SPEC
    _acq_msb_apply_kit_dir envbox "$ek"
  '
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '/var/lib/acq/kit-env'
  assert_regex "$log" 'OPENCODE_CONFIG=/home/agent/\.config/opencode/kit\.jsonc'
  refute_regex "$log" '1BAD'
}

@test "msb kit env: a kit with no environment[] writes no kit-env marker" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/noenv-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    nk="'"$STUBDIR"'/noenvkit"; mkdir -p "$nk"
    cat >"$nk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: noenv-kit
displayName: NoEnv Kit
description: no environment block
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo CMD_NOENV
SPEC
    _acq_msb_apply_kit_dir envbox "$nk"
  '
  assert_success
  refute_regex "$(cat "$CALLS")" '/var/lib/acq/kit-env'
}

@test "msb kit env: acq exec replays persisted entries as -e flags; none when marker empty" {
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    export STUB_RECORDED_KIT_ENV="OPENCODE_CONFIG=/home/agent/oc.jsonc
RUBOCOP_PARALLELISM=4"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run sbox -- printenv OPENCODE_CONFIG >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '-e OPENCODE_CONFIG=/home/agent/oc\.jsonc'
  assert_regex "$log" '-e RUBOCOP_PARALLELISM=4'
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_KIT_ENV=
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run sbox -- git status >/dev/null 2>&1
  '
  refute_regex "$(cat "$CALLS")" 'OPENCODE_CONFIG'
}

@test "msb kit env: attach and shell replay persisted entries as -e flags" {
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9 STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1
    export STUB_RECORDED_KIT_ENV="OPENCODE_CONFIG=/home/agent/oc.jsonc"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_attach sbox </dev/null >/dev/null 2>&1 )
  '
  assert_regex "$(cat "$CALLS")" '-e OPENCODE_CONFIG=/home/agent/oc\.jsonc'
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    export STUB_RECORDED_KIT_ENV="OPENCODE_CONFIG=/home/agent/oc.jsonc"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_shell_exec sbox </dev/null >/dev/null 2>&1 )
  '
  assert_regex "$(cat "$CALLS")" '-e OPENCODE_CONFIG=/home/agent/oc\.jsonc'
}

@test "msb git identity: syncs global config and replays EMAIL fallback" {
  local home="$STUBDIR/git-home"
  mkdir -p "$home"
  git -c "safe.directory=*" config --file "$home/.gitconfig" user.name "Global User"
  git -c "safe.directory=*" config --file "$home/.gitconfig" user.email global@example.gov

  : > "$CALLS"
  run bash -c '
    export HOME="'"$home"'" GIT_CONFIG_NOSYSTEM=1 STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run sbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '-e ACQ_GIT_USER_NAME=Global User'
  assert_regex "$log" '-e ACQ_GIT_USER_EMAIL=global@example\.gov'
  assert_regex "$log" 'git config --global user.name'
  assert_regex "$log" 'git config --global user.email'
  assert_regex "$log" '-e EMAIL=global@example\.gov'
  refute_regex "$log" '-e GIT_AUTHOR_NAME=Global User'

  : > "$CALLS"
  run bash -c '
    export HOME="'"$home"'" GIT_CONFIG_NOSYSTEM=1 STUB_MSB_VERSION=0.6.9
    export STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_attach sbox </dev/null >/dev/null 2>&1 )
  '
  assert_regex "$(cat "$CALLS")" '-e EMAIL=global@example\.gov'

  : > "$CALLS"
  run bash -c '
    export HOME="'"$home"'" GIT_CONFIG_NOSYSTEM=1 STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_shell_exec sbox </dev/null >/dev/null 2>&1 )
  '
  assert_regex "$(cat "$CALLS")" '-e EMAIL=global@example\.gov'
}

@test "msb markers: ABSENT /var/lib/acq markers must not kill session verbs under set -e" {
  # acq runs under `set -euo pipefail`. On a sandbox whose /var/lib/acq markers
  # are absent (created before a marker existed, e.g. pre-kit-env sandboxes, or
  # no ssh-agent forwarding configured), the in-guest `cat` exits 1 inside the
  # command substitution and an unguarded assignment terminates acq before any
  # output — every exec/shell/attach against such a sandbox dies with rc 1 and
  # nothing on stdout/stderr (observed live for kit-env and ssh-auth-sock).
  # All STUB_RECORDED_* stay UNSET here so the stub exits 1 like real cat.
  : > "$CALLS"
  run bash -c '
    set -euo pipefail
    export STUB_MSB_VERSION=0.6.9
    unset STUB_RECORDED_KIT_ENV STUB_RECORDED_SSH_AUTH_SOCK STUB_RECORDED_AGENT STUB_RECORDED_WORKSPACE
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run sbox -- git status >/dev/null 2>&1
    echo RUN-SURVIVED
    ( _acq_msb_attach sbox </dev/null >/dev/null 2>&1 )
    echo ATTACH-SURVIVED
    ( _acq_msb_shell_exec sbox </dev/null >/dev/null 2>&1 )
    echo SHELL-SURVIVED
  '
  assert_success
  assert_output --partial 'RUN-SURVIVED'
  assert_output --partial 'ATTACH-SURVIVED'
  assert_output --partial 'SHELL-SURVIVED'
  assert_regex "$(cat "$CALLS")" 'exec -u agent -e HOME=/home/agent -w /home/agent sbox -- git status'
}

@test "msb kit env: heal rebuilds the marker — a var the kit no longer declares stops reaching sessions" {
  # The heal loop (and provision) applies the FULL effective kit set, so the
  # marker must be rebuilt from the current kits' environment[] each time. An
  # append-only marker would retain entries a kit stopped declaring: removed
  # runtime config (feature toggles, host selectors) would keep influencing
  # sessions indefinitely.
  : > "$CALLS"
  printf 'healbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'healbox\n' > "$STUBDIR/.msb_running_list"
  local hk="$STUBDIR/healkit"; mkdir -p "$hk"
  cat > "$hk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: heal-kit
displayName: Heal Kit
description: env entries across kit versions
environment:
  KEPT_VAR: stays
  STALE_VAR: dropped-in-v2
SPEC
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/heal-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/heal-stage"
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/kit-translate.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    # shellcheck disable=SC2034  # consumed by the sourced acq_backend_ensure_kits_applied
    ACQ_CLI_KITS=()
    _acq_msb_fetch_kit() { printf '%s\n' "$hk"; }
    acq_backend_ensure_kits_applied healbox >/dev/null 2>&1 )
  # Kit v2 drops STALE_VAR; the next heal must rebuild the marker without it.
  cat > "$hk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: heal-kit
displayName: Heal Kit
description: env entries across kit versions
environment:
  KEPT_VAR: stays
SPEC
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/heal-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/heal-stage"
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/kit-translate.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    # shellcheck disable=SC2034  # consumed by the sourced acq_backend_ensure_kits_applied
    ACQ_CLI_KITS=()
    _acq_msb_fetch_kit() { printf '%s\n' "$hk"; }
    acq_backend_ensure_kits_applied healbox >/dev/null 2>&1 )
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run healbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '-e KEPT_VAR=stays'
  refute_regex "$log" 'STALE_VAR'
}

@test "msb kit env: replay drops tampered names and keeps the last value for a duplicate" {
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    export STUB_RECORDED_KIT_ENV="BAD-NAME=x
GITLAB_HOST=gitlab.example.gov
GITLAB_HOST=gitlab.override.gov"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run sbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'BAD-NAME'
  assert_regex "$log" '-e GITLAB_HOST=gitlab\.override\.gov'
  refute_regex "$log" 'GITLAB_HOST=gitlab\.example\.gov'
}
