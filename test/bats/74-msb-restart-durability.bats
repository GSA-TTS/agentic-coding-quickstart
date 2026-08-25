#!/usr/bin/env bats
#
# 74-msb-restart-durability.bats — bats port of
# scripts/test-acq.d/74-msb-restart-durability.sh (ADR-0017, #247, ADR-0025)
#
# acq start/restart verbs, acq_backend_start, start-if-stopped-on-attach, the
# ordering guarantees (readiness probe / stop<start<heal), sbx capability-gating,
# cli-kit reload on resume, best-effort restart, and secret re-export on start.
# Dispatch-level cases run a child `acq` process; helper-level cases source msb
# in a subshell. All inspect $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Return the 1-based line number of the first $CALLS line matching a fixed string.
_first_line() { printf '%s\n' "$2" | grep -n -- "$1" | head -n1 | cut -d: -f1; }

@test "0017: acq_backend_start calls 'msb start NAME'; sbx defines no acq_backend_start" {
  : > "$CALLS"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; acq_backend_start msbstartbox >/dev/null 2>&1'
  assert_regex "$(cat "$CALLS")" 'msb start msbstartbox'
  # load_acq sourced the sbx adapter into this @test shell.
  run command -v acq_backend_start
  assert_failure
}

@test "0017: acq start (msb) starts + heals; readiness probe precedes the first heal exec" {
  printf 'startbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'startbox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" start startbox
  assert_output --partial "started 'startbox'"
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb start startbox'
  assert_regex "$log" 'msb exec'
  local probe first
  probe=$(_first_line 'msb exec startbox -- sh -c echo ok' "$log")
  first=$(_first_line 'msb exec' "$log")
  assert [ -n "$probe" ]
  assert [ "$probe" -le "$first" ]
}

@test "0017: acq restart (msb) orders stop < start < heal-exec" {
  printf 'restartbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'restartbox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" restart restartbox
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb stop restartbox'
  assert_regex "$log" 'msb start restartbox'
  assert_regex "$log" 'msb exec'
  local s st e
  s=$(_first_line 'msb stop restartbox' "$log")
  st=$(_first_line 'msb start restartbox' "$log")
  e=$(_first_line 'msb exec' "$log")
  assert [ "$s" -lt "$st" ]
  assert [ "$st" -lt "$e" ]
}

@test "0017: acq start / restart with no name error and exit nonzero" {
  run env ACQ_BACKEND=msb "$ACQ" start
  assert_failure
  assert_output --partial 'start: missing sandbox name'
  run env ACQ_BACKEND=msb "$ACQ" restart
  assert_failure
  assert_output --partial 'restart: missing sandbox name'
}

@test "sbx: acq start / restart are capability-gated, point at acq run, never call sbx start" {
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" start sbxbox
  assert_failure
  assert_output --partial "no separate 'start' verb"
  assert_output --partial 'acq run sbxbox'
  refute_regex "$(cat "$CALLS")" 'sbx start'
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" restart sbxbox
  assert_failure
  assert_output --partial "no separate 'restart' verb"
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'sbx start'
  refute_regex "$log" 'sbx restart'
}

@test "0017: a stopped sandbox is started before the first heal exec (start-if-stopped)" {
  printf 'stoppedbox\n' > "$STUBDIR/.msb_sandbox_list"
  : > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; acq_backend_ensure_kits_applied stoppedbox >/dev/null 2>&1'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb start stoppedbox'
  local st e
  st=$(_first_line 'msb start stoppedbox' "$log")
  e=$(_first_line 'msb exec' "$log")
  assert [ "$st" -lt "$e" ]
}

@test "0017: a running sandbox is not re-started during heal (idempotent)" {
  printf 'livebox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'livebox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; acq_backend_ensure_kits_applied livebox >/dev/null 2>&1'
  refute_regex "$(cat "$CALLS")" 'msb start livebox'
}

@test "clikit-heal: a CLI --kit ref (ACQ_CLI_KITS) is applied during heal" {
  printf 'clikitbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'clikitbox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  local clikit="$STUBDIR/clikit"; mkdir -p "$clikit/files"
  cat > "$clikit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: clikit
displayName: CLI Kit
description: a CLI-supplied kit with a staged file
files:
  - path: /home/agent/clikit-marker
    mode: "0644"
    source: files/marker
SPEC
  printf 'CLIKIT_MARKER\n' > "$clikit/files/marker"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ACQ_CLI_KITS=("'"$clikit"'")
    _acq_msb_fetch_kit() { printf "%s\n" "'"$clikit"'"; }
    acq_backend_ensure_kits_applied clikitbox >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" 'clikitbox:/home/agent/clikit-marker'
}

@test "0017: startup is staged via --script-path but never designated --entrypoint (removed knob inert)" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/ep-off-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/ep-off-stage"
    export ACQ_MSB_PERSIST_STARTUP_ENTRYPOINT=1
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    epk="'"$STUBDIR"'/epkit"; mkdir -p "$epk"
    cat >"$epk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: ep-kit
displayName: EP Kit
description: one startup command
commands:
  - phase: startup
    user: "0"
    command: [sh, -c, echo EP_MARKER]
SPEC
    _acq_msb_fetch_kit() { printf "%s\n" "$epk"; }
    acq_backend_provision epoffbox shell /tmp >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" -- '--script-path acq-startup:'
  refute_regex "$log" -- '--entrypoint'
}

@test "msb: acq start dispatch calls msb start (verb wired)" {
  printf 'mybox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'mybox\n' > "$STUBDIR/.msb_running_list"
  run env ACQ_BACKEND=msb "$ACQ" start mybox
  assert_regex "$(cat "$CALLS")" 'msb start mybox'
}

# Build a reload kit dir with one staged marker at $2 (its in-guest path).
_mk_reload_kit() {
  local dir="$1" marker="$2"
  mkdir -p "$dir/files"
  cat > "$dir/spec.yaml" <<RELOADSPEC
schemaVersion: "hybrid/v1"
kind: mixin
name: reload-kit
displayName: Reload Kit
description: a persisted --kit whose file proves the resume reload ran
files:
  - path: ${marker}
    mode: "0644"
    source: files/marker
RELOADSPEC
  printf 'RELOAD_MARKER\n' > "$dir/files/marker"
}

@test "cli-kits(dispatch): acq start reloads + heals the persisted --kit" {
  printf 'startreloadbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'startreloadbox\n' > "$STUBDIR/.msb_running_list"
  local rk="$STUBDIR/reloadkit"; _mk_reload_kit "$rk" "/home/agent/start-reload-marker"
  # ACQ_CLI_KITS/ACQ_EXTRA_KITS are read by acq_cli_kits_write (sourced).
  # shellcheck disable=SC2034
  ( ACQ_CLI_KITS=("$rk"); ACQ_EXTRA_KITS=""; acq_cli_kits_write msb startreloadbox )
  : > "$CALLS"
  run env ACQ_MSB_KIT_LOCAL_DIR="$rk" ACQ_BACKEND=msb "$ACQ" start startreloadbox
  assert_regex "$(cat "$CALLS")" 'startreloadbox:/home/agent/start-reload-marker'
}

@test "cli-kits(dispatch): acq start with NO record heals no extra kit (control)" {
  printf 'startnorecbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'startnorecbox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" start startnorecbox
  refute_regex "$(cat "$CALLS")" '/home/agent/start-norec-marker'
}

@test "cli-kits(dispatch): acq restart reloads + heals the persisted --kit" {
  printf 'restartreloadbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'restartreloadbox\n' > "$STUBDIR/.msb_running_list"
  local rk="$STUBDIR/reloadkit3"; _mk_reload_kit "$rk" "/home/agent/restart-reload-marker"
  # ACQ_CLI_KITS/ACQ_EXTRA_KITS are read by acq_cli_kits_write (sourced).
  # shellcheck disable=SC2034
  ( ACQ_CLI_KITS=("$rk"); ACQ_EXTRA_KITS=""; acq_cli_kits_write msb restartreloadbox )
  : > "$CALLS"
  run env ACQ_MSB_KIT_LOCAL_DIR="$rk" ACQ_BACKEND=msb "$ACQ" restart restartreloadbox
  assert_regex "$(cat "$CALLS")" 'restartreloadbox:/home/agent/restart-reload-marker'
}

@test "cli-kits(dispatch): acq run <sandbox> name-only re-attach reloads + heals the persisted --kit" {
  printf 'runreloadbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'runreloadbox\n' > "$STUBDIR/.msb_running_list"
  local rk="$STUBDIR/reloadkit4"; _mk_reload_kit "$rk" "/home/agent/run-reload-marker"
  # ACQ_CLI_KITS/ACQ_EXTRA_KITS are read by acq_cli_kits_write (sourced).
  # shellcheck disable=SC2034
  ( ACQ_CLI_KITS=("$rk"); ACQ_EXTRA_KITS=""; acq_cli_kits_write msb runreloadbox )
  : > "$CALLS"
  run env ACQ_UPDATE_CHECK=0 ACQ_MSB_KIT_LOCAL_DIR="$rk" ACQ_BACKEND=msb "$ACQ" run runreloadbox
  assert_regex "$(cat "$CALLS")" 'runreloadbox:/home/agent/run-reload-marker'
}

@test "0017 N1: restart is best-effort — a failed msb stop still proceeds to start" {
  printf 'bouncebox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'bouncebox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run env STUB_MSB_STOP_FAIL=1 ACQ_BACKEND=msb "$ACQ" restart bouncebox
  assert_success
  assert_output --partial 'stop failed; attempting start anyway'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb stop bouncebox'
  assert_regex "$log" 'msb start bouncebox'
}

@test "0017 N2b: the unsupported-backend start guard emits a clear message and exits nonzero" {
  run bash -c '
    unset -f acq_backend_start 2>/dev/null || true
    ACQ_RESOLVED_BACKEND=faux
    if ! command -v acq_backend_start >/dev/null 2>&1; then
      echo "acq: the ${ACQ_RESOLVED_BACKEND} backend does not support start" >&2
      exit 1
    fi
    exit 0
  '
  assert_failure
  assert_output --partial 'does not support start'
}

@test "0017: acq_backend_start re-exports the persisted secrets before msb start, no leak, no linger" {
  printf 'secretstartbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'secretstartbox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run bash -c '
    unset USAI_API_KEY GITHUB_TOKEN GH_TOKEN
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sstart-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL-VALUE\n" | acq_secret_store "$(_acq_secret_key usai)"
    printf "GH-REAL-VALUE\n"   | acq_secret_store "$(_acq_secret_key github)"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_start secretstartbox >/dev/null 2>&1
    printf "usai-lingers=%s\n" "${USAI_API_KEY:+yes}"
    printf "github-lingers=%s\n" "${GITHUB_TOKEN:+yes}"
  '
  assert_output --partial 'usai-lingers='
  refute_output --partial 'usai-lingers=yes'
  refute_output --partial 'github-lingers=yes'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'USAI_API_KEY=present'
  assert_regex "$log" 'GITHUB_TOKEN=present'
  assert_regex "$log" 'msb start secretstartbox'
  refute_regex "$log" 'USAI-REAL-VALUE'
  refute_regex "$log" 'GH-REAL-VALUE'
}

@test "0017: the run<stopped> path also re-exports the secret before msb start" {
  printf 'stoppedsecbox\n' > "$STUBDIR/.msb_sandbox_list"
  : > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run bash -c '
    unset USAI_API_KEY GITHUB_TOKEN GH_TOKEN
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/stoppedsec-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL-VALUE\n" | acq_secret_store "$(_acq_secret_key usai)"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_ensure_kits_applied stoppedsecbox >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'USAI_API_KEY=present'
  assert_regex "$log" 'msb start stoppedsecbox'
}

@test "0017: start re-exports a generic custom-endpoint secret too, no value leak" {
  printf 'customstartbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'customstartbox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run bash -c '
    unset USAI_API_KEY GITHUB_TOKEN GH_TOKEN
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/customstart-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    acq_secret_meta_store mysvc "" "api.example.gov" "MYCUSTOM_TOKEN"
    printf "CUSTOM-REAL-VALUE\n" | acq_secret_store "$(_acq_secret_key mysvc)"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    msb() { if [ "${1:-}" = "start" ] && [ -n "${MYCUSTOM_TOKEN:-}" ]; then printf "MYCUSTOM_TOKEN=present\n" >>"'"$CALLS"'"; fi; command "'"$STUBDIR"'/msb" "$@"; }
    acq_backend_start customstartbox >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'MYCUSTOM_TOKEN=present'
  refute_regex "$log" 'CUSTOM-REAL-VALUE'
}

@test "0017 refactor: provision still binds USAi + GitHub via --secret and never leaks values" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/provref-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL-VALUE\n" | acq_secret_store "$(_acq_secret_key usai)"
    printf "GH-REAL-VALUE\n"   | acq_secret_store "$(_acq_secret_key github)"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_provision provrefbox shell /tmp >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" -- '--secret USAI_API_KEY@api\.gsa\.usai\.gov'
  assert_regex "$log" -- "--secret $MSB_GITHUB_SECRET_BINDING"
  refute_regex "$log" 'USAI-REAL-VALUE'
  refute_regex "$log" 'GH-REAL-VALUE'
}
