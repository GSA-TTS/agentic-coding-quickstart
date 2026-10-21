#!/usr/bin/env bats
#
# 140-opencode-migration-gate.bats - regression gate for moving
# `acq run opencode .` to the ADR-0030 agent-kit/devenv model.
#
# These tests intentionally freeze the current observable contracts only. They do
# not implement agent kits or dev environments. A future migration can rewrite the
# internals, but these surfaces must stay stable across both backends.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  unset ACQ_REQUIRED_AGENT_KIT ACQ_DEFAULT_OPENCODE_GENERIC
}
teardown() { acq_teardown_stubs; }

load 'helper'

_mk_repo() { # PATH
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'one\n' >"$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" -c user.email=t@example.gov -c user.name=t -c commit.gpgsign=false commit -q -m init
}

_msb_run_gate() { # [ENV KEY=VAL...] -- ARGS...
  local env_kv=()
  while [ "$1" != "--" ]; do env_kv+=("$1"); shift; done
  shift
  run bash -c '
    tag="$1"; shift
    export ACQ_MSB_KIT_PASSTHROUGH=1 ACQ_UPDATE_CHECK=0
    export ACQ_STATE_DIR="'"$STUBDIR"'/state-$tag"
    while [ "$1" != "--" ]; do export "$1"; shift; done
    shift
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-$tag"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL\n" | acq_secret_store "$(_acq_secret_key usai)" >/dev/null
    ACQ_BACKEND=msb "'"$ACQ"'" "$@" 2>&1 >/dev/null
  ' _ "$BATS_TEST_NUMBER" ${env_kv[@]+"${env_kv[@]}"} -- "$@"
}

_seed_sbx_usai() {
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
}

_create_line() { printf '%s\n' "$(cat "$CALLS")" | grep "^$1 create"; }

@test "migration gate: common kit order is built-ins, ACQ_EXTRA_KITS, then CLI --kit" {
  load_acq
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_EXTRA_KITS="/extra/env-one /extra/env-two"
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_CLI_KITS=("/extra/cli-one" "/extra/cli-two")
  _build_kit_list

  assert_equal "${KITS[0]}" "$ZSCALER_KIT"
  assert_equal "${KITS[1]}" "$USAI_KIT"
  assert_equal "${KITS[2]}" "$PLAYBOOK_KIT"
  assert_equal "${KITS[3]}" "$GITSSHSIGN_KIT"
  assert_equal "${KITS[4]}" "/extra/env-one"
  assert_equal "${KITS[5]}" "/extra/env-two"
  assert_equal "${KITS[6]}" "/extra/cli-one"
  assert_equal "${KITS[7]}" "/extra/cli-two"
}

_mk_opencode_agent_kit() { # PATH [schema] [kit-name] [agent-name] [entrypoint]
  mkdir -p "$1"
  cat >"$1/spec.yaml" <<SPEC
schemaVersion: "${2:-hybrid/v1}"
kind: mixin
name: ${3:-opencode}
displayName: OpenCode Agent Kit
description: test fixture only
agent:
  name: ${4:-opencode}
  entrypoint: ${5:-opencode}
SPEC
}

@test "agent kit gate: valid opencode artifact enables inferred built-in kit" {
  ACQ_TEST_AGENT_KIT="$STUBDIR/opencode-kit"
  _mk_opencode_agent_kit "$ACQ_TEST_AGENT_KIT"
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$ACQ_TEST_AGENT_KIT"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "5"
  assert_equal "${KITS[4]}" "$ACQ_TEST_AGENT_KIT"
  assert_regex "$(acq_selected_agent_kit_summary opencode)" 'apply=enabled'
}

@test "agent kit gate: valid opencode artifact stays deferred while disabled" {
  ACQ_TEST_AGENT_KIT="$STUBDIR/opencode-kit-disabled"
  _mk_opencode_agent_kit "$ACQ_TEST_AGENT_KIT"
  acq_agent_builtin_kit_enabled() { return 1; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$ACQ_TEST_AGENT_KIT"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "${#KITS[@]}" "4"
  assert_regex "$(acq_selected_agent_kit_summary opencode 2>/dev/null)" 'apply=deferred'
}

@test "agent kit gate: missing opencode artifact fails before generic-default provisioning" {
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$STUBDIR/missing-opencode-kit"; }

  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_REQUIRED_AGENT_KIT=opencode
  run _build_kit_list opencode

  assert_failure
  assert_output --partial 'required built-in opencode kit is unavailable'
}

@test "agent kit gate: wrong opencode kit name fails closed" {
  local kit="$STUBDIR/wrong-name-kit"
  _mk_opencode_agent_kit "$kit" "hybrid/v1" "not-opencode"
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$kit"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "${#KITS[@]}" "4"
}

@test "agent kit gate: wrong opencode kit schema fails closed" {
  local kit="$STUBDIR/wrong-schema-kit"
  _mk_opencode_agent_kit "$kit" "sbx/v1" "opencode"
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$kit"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "${#KITS[@]}" "4"
}

@test "agent kit gate: wrong agent metadata name fails closed" {
  local kit="$STUBDIR/wrong-agent-name-kit"
  _mk_opencode_agent_kit "$kit" "hybrid/v1" "opencode" "not-opencode" "opencode"
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$kit"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "${#KITS[@]}" "4"
}

@test "agent kit gate: wrong agent metadata entrypoint fails closed" {
  local kit="$STUBDIR/wrong-agent-entrypoint-kit"
  _mk_opencode_agent_kit "$kit" "hybrid/v1" "opencode" "opencode" "not-opencode"
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$kit"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "${#KITS[@]}" "4"
}

@test "agent kit gate: nested agent metadata does not satisfy direct fields" {
  local kit="$STUBDIR/nested-agent-kit"
  mkdir -p "$kit"
  cat >"$kit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: opencode
agent:
  metadata:
    name: opencode
    entrypoint: opencode
SPEC
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$kit"; }

  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "${#KITS[@]}" "4"
}

@test "agent kit gate: explicit --kit cannot suppress required inferred opencode kit" {
  local cli="$STUBDIR/cli-kit"
  mkdir -p "$cli"
  acq_agent_builtin_kit_enabled() { [ "$1" = "opencode" ]; }
  local built_in="$STUBDIR/opencode-kit"
  _mk_opencode_agent_kit "$built_in"
  _acq_agent_builtin_kit_ref() { printf '%s\n' "$built_in"; }
  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_CLI_KITS=("$cli")

  # shellcheck disable=SC2034  # read by sourced _build_kit_list
  ACQ_REQUIRED_AGENT_KIT=opencode
  _build_kit_list opencode

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "5"
  assert_equal "${#KITS[@]}" "6"
  assert_equal "${KITS[4]}" "$built_in"
  assert_equal "${KITS[5]}" "$cli"
}

@test "agent kit gate: shell remains no-agent-kit" {
  acq_agent_builtin_kit_enabled() { return 0; }

  _build_kit_list shell

  assert_equal "$ACQ_BUILTIN_KIT_COUNT" "4"
  assert_equal "${#KITS[@]}" "4"
}

@test "migration gate(msb): run opencode --clone preserves clone markers, image, kit order, and boot volumes" {
  local proj="$STUBDIR/migproj" extra="$STUBDIR/extra-kit" cli="$STUBDIR/cli-kit"
  _mk_repo "$proj"
  mkdir -p "$extra" "$cli"
  cat >"$extra/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: extra-kit
displayName: Extra Kit
description: env extra kit with boot-time volume
volumes:
  - path: /cache
    size: 256m
SPEC
  cat >"$cli/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: cli-kit
displayName: CLI Kit
description: cli kit wins repeated boot-time volume path
volumes:
  - path: /cache
    size: 512m
  - path: /scratch
    type: tmpfs
    size: 64m
SPEC

  _msb_run_gate ACQ_EXTRA_KITS="$extra" ACQ_IMAGE=localhost/acq-migration:test \
    STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1 STUB_RECORDED_WORKSPACE="$proj" -- \
    run opencode --clone --kit "$cli" "$proj" -- --version

  local line repo scratch
  load_acq
  line=$(_create_line msb)
  repo=$(canonicalize_path "$proj")
  scratch="$STUBDIR/state-$BATS_TEST_NUMBER/clones/opencode-migproj/migproj"

  assert_regex "$line" "--volume $(canonicalize_path "$scratch"):${repo}( |$)"
  refute_regex "$line" "--volume ${repo}:${repo}"
  assert_regex "$line" "--env ACQ_WORKSPACE=${repo}( |$)"
  assert_regex "$line" '--env ACQ_CLONE=1( |$)'
  assert_regex "$line" 'localhost/acq-migration:test$'
  assert_regex "$line" '--mount-named acq-opencode-migproj-cache-[0-9]+:/cache:kind=disk,size=512m'
  assert_regex "$line" '--tmpfs /scratch:64m'
  refute_regex "$line" 'size=256m'

  local log
  log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec -t -u agent -w .* opencode-migproj -- opencode --version'
}

@test "migration gate(msb): ACQ_CLONE=1 run opencode matches --clone markers" {
  local proj="$STUBDIR/envclone-msb"
  _mk_repo "$proj"

  _msb_run_gate ACQ_CLONE=1 STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1 \
    STUB_RECORDED_WORKSPACE="$proj" -- run opencode "$proj" -- --version

  local line repo scratch
  load_acq
  line=$(_create_line msb)
  repo=$(canonicalize_path "$proj")
  scratch="$STUBDIR/state-$BATS_TEST_NUMBER/clones/opencode-envclone-msb/envclone-msb"
  assert_regex "$line" "--volume $(canonicalize_path "$scratch"):${repo}( |$)"
  assert_regex "$line" "--env ACQ_WORKSPACE=${repo}( |$)"
  assert_regex "$line" '--env ACQ_CLONE=1( |$)'
  refute_regex "$line" '--clone'
  assert_regex "$(cat "$CALLS")" 'msb exec -t -u agent -w .* opencode-envclone-msb -- opencode --version'
}

@test "migration gate(msb): generic-state persistence failure removes the new sandbox" {
  local proj="$STUBDIR/msb-generic-state-write-fail"
  _mk_repo "$proj"
  acq_host_config_write() { return 1; }

  run env ACQ_MSB_KIT_PASSTHROUGH=1 \
    bash -c '. "$1/acq.backends/common.sh"; . "$1/acq.backends/msb.sh"; acq_host_config_write() { return 1; }; acq_backend_provision msbgenericstatefail opencode "$2"' \
    _ "$REPO_ROOT" "$proj"

  assert_failure
  assert_output --partial 'could not record completed generic OpenCode state'
  assert_regex "$(cat "$CALLS")" 'msb remove --force msbgenericstatefail'
}

@test "migration gate(msb): failed required OpenCode kit removes the new sandbox" {
  local proj="$STUBDIR/msb-generic-kit-fail"
  _mk_repo "$proj"

  run env ACQ_MSB_KIT_PASSTHROUGH=1 \
    bash -c '. "$1/acq.backends/common.sh"; . "$1/acq.backends/msb.sh"; _acq_msb_apply_kit_dir() { return 1; }; acq_backend_provision msbgenerickitfail opencode "$2"' \
    _ "$REPO_ROOT" "$proj"

  assert_failure
  assert_output --partial 'required OpenCode kit did not fully apply'
  assert_regex "$(cat "$CALLS")" 'msb remove --force msbgenerickitfail'
  run acq_host_config_has msb msbgenerickitfail generic-opencode
  assert_failure
}

@test "migration gate(msb): acq exec remains non-login; acq shell uses the agent login shell" {
  printf 'migbox\n' >"$STUBDIR/.msb_sandbox_list"
  printf 'migbox\n' >"$STUBDIR/.msb_running_list"

  run env -u EMAIL -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$STUBDIR/nohome" XDG_CONFIG_HOME="$STUBDIR/noconfig" GIT_CONFIG_NOSYSTEM=1 \
    STUB_AGENT_PASSWD_SHELL=/bin/bash ACQ_BACKEND=msb \
    bash -c '. "$1/acq.backends/common.sh"; acq_host_config_write msb migbox workspace /workspace; exec "$2" exec migbox -- pwd' \
    _ "$REPO_ROOT" "$ACQ"
  assert_success
  local exec_line
  exec_line=$(grep '^msb exec -u agent .* migbox -- pwd' "$CALLS")
  assert_regex "$exec_line" '-w /workspace'
  refute_regex "$exec_line" ' -t '
  refute_regex "$exec_line" 'SHELL=/bin/bash'
  refute_regex "$exec_line" '/bin/bash -l'

  : >"$CALLS"
  run env -u EMAIL -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$STUBDIR/nohome" XDG_CONFIG_HOME="$STUBDIR/noconfig" GIT_CONFIG_NOSYSTEM=1 \
    TERM=xterm-256color STUB_AGENT_PASSWD_SHELL=/bin/bash ACQ_BACKEND=msb \
    bash -c '. "$1/acq.backends/common.sh"; acq_host_config_write msb migbox workspace /workspace; exec "$2" shell migbox' \
    _ "$REPO_ROOT" "$ACQ"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb exec -t -u agent -w /workspace -e TERM=xterm-256color -e SHELL=/bin/bash migbox -- /bin/bash -l'
}

@test "migration gate(sbx): run opencode keeps native clone, workspace markers, image template, and kit order" {
  local proj="$STUBDIR/sbxproj"
  _mk_repo "$proj"
  _seed_sbx_usai
  run env ACQ_BACKEND=sbx ACQ_EXTRA_KITS="/extra/env-one /extra/env-two" ACQ_IMAGE=ghcr.io/acq/migration:v1 \
    STUB_KEY_STATUS=200 STUB_OPENCODE_OK=1 "$ACQ" run opencode --clone --kit /extra/cli-one "$proj" -- --version
  assert_success

  local line logical
  line=$(_create_line sbx)
  logical=$(cd "$proj" && pwd)
  assert_regex "$line" '--clone'
  assert_regex "$line" "--env ACQ_WORKSPACE=${logical}( |$)"
  assert_regex "$line" '--env ACQ_CLONE=1( |$)'
  assert_regex "$line" '--template ghcr\.io/acq/migration:v1'
  assert_regex "$line" '--kit /extra/env-one .*--kit /extra/env-two .*--kit /extra/cli-one'
  assert_regex "$(cat "$CALLS")" 'sbx run --name opencode-sbxproj opencode -- --version'
}

@test "migration gate(sbx): ACQ_CLONE=1 run opencode matches --clone markers" {
  local proj="$STUBDIR/envclone-sbx"
  _mk_repo "$proj"
  _seed_sbx_usai
  run env ACQ_BACKEND=sbx ACQ_CLONE=1 STUB_KEY_STATUS=200 STUB_OPENCODE_OK=1 \
    "$ACQ" run opencode "$proj" -- --version
  assert_success

  local line logical
  line=$(_create_line sbx)
  logical=$(cd "$proj" && pwd)
  assert_regex "$line" '--clone'
  assert_regex "$line" "--env ACQ_WORKSPACE=${logical}( |$)"
  assert_regex "$line" '--env ACQ_CLONE=1( |$)'
  assert_regex "$(cat "$CALLS")" 'sbx run --name opencode-envclone-sbx shell -- -lc exec.*sh opencode --version'
}

@test "migration gate(sbx): generic default attach launches kit entrypoint and preserves -- escape" {
  local proj="$STUBDIR/sbx-generic-attach"
  _mk_repo "$proj"
  _seed_sbx_usai
  run env ACQ_BACKEND=sbx STUB_KEY_STATUS=200 STUB_OPENCODE_OK=1 \
    "$ACQ" create opencode --name genericattach "$proj"
  assert_success
  printf 'genericattach\n' >"$STUBDIR/.sandbox_list"
  local create_line
  create_line=$(_create_line sbx)
  assert_regex "$create_line" " shell ${proj}$"
  assert_equal "$(printf '%s\n' "$create_line" | grep -o 'acq-opencode-kit' | wc -l | tr -d ' ')" "1"

  : >"$CALLS"
  run env ACQ_BACKEND=sbx ACQ_UPDATE_CHECK=0 "$ACQ" run genericattach
  assert_success
  assert_regex "$(cat "$CALLS")" 'sbx run --name genericattach shell -- -lc exec.*sh opencode'

  : >"$CALLS"
  run env ACQ_BACKEND=sbx ACQ_UPDATE_CHECK=0 "$ACQ" run genericattach -- --version
  assert_success
  assert_regex "$(cat "$CALLS")" 'sbx run --name genericattach shell -- -lc exec.*sh opencode --version'

  : >"$CALLS"
  run env ACQ_BACKEND=sbx ACQ_UPDATE_CHECK=0 "$ACQ" run genericattach -- sh -c 'echo escape'
  assert_success
  assert_regex "$(cat "$CALLS")" 'sbx run --name genericattach shell -- -lc exec.*sh sh -c echo escape'
  refute_regex "$(cat "$CALLS")" 'opencode sh -c'
}

@test "migration gate(sbx): generic default fails closed when launch-mode persistence fails" {
  local proj="$STUBDIR/sbx-generic-mode-write-fail"
  _mk_repo "$proj"
  _seed_sbx_usai
  # shellcheck disable=SC2034 # read by acq_backend_provision
  ACQ_DEFAULT_OPENCODE_GENERIC=1
  acq_host_config_write sbx genericwritefail generic-opencode legacy-opencode
  acq_host_config_write() { return 1; }

  run acq_backend_provision genericwritefail opencode "$proj"

  assert_failure
  assert_output --partial 'could not record OpenCode launch mode'
  assert_regex "$(_create_line sbx)" ' shell '
  run acq_host_config_has sbx genericwritefail generic-opencode
  assert_failure
  assert_regex "$(cat "$CALLS")" 'sbx rm --force genericwritefail'
}

@test "migration gate(sbx): provenance persistence failure removes the new sandbox" {
  local proj="$STUBDIR/sbx-generic-provenance-write-fail"
  _mk_repo "$proj"
  _seed_sbx_usai
  acq_provenance_write() { return 1; }

  run acq_backend_provision genericprovenancefail opencode "$proj"

  assert_failure
  assert_output --partial 'could not record provenance'
  assert_regex "$(cat "$CALLS")" 'sbx rm --force genericprovenancefail'
  refute_regex "$(cat "$CALLS")" '^sbx run '
}

@test "migration gate(sbx): lost generic launch mode refuses legacy attach grammar" {
  local proj="$STUBDIR/sbx-generic-mode-lost"
  _mk_repo "$proj"
  _seed_sbx_usai
  run env ACQ_BACKEND=sbx STUB_KEY_STATUS=200 STUB_OPENCODE_OK=1 \
    "$ACQ" create opencode --name genericmodelost "$proj"
  assert_success
  printf 'genericmodelost\n' >"$STUBDIR/.sandbox_list"
  acq_host_config_clear sbx genericmodelost generic-opencode

  : >"$CALLS"
  run env ACQ_BACKEND=sbx ACQ_UPDATE_CHECK=0 "$ACQ" run genericmodelost

  assert_failure
  assert_output --partial 'cannot determine OpenCode launch mode'
  refute_regex "$(cat "$CALLS")" '^sbx run --name genericmodelost opencode'
  refute_regex "$(cat "$CALLS")" '^sbx run --name genericmodelost shell'
}

@test "migration gate(sbx): prior generic launch-mode record keeps the shell launcher" {
  local proj="$STUBDIR/sbx-generic-mode-prior"
  _mk_repo "$proj"
  _seed_sbx_usai
  run env ACQ_BACKEND=sbx STUB_KEY_STATUS=200 STUB_OPENCODE_OK=1 \
    "$ACQ" create opencode --name genericmodeprior "$proj"
  assert_success
  printf 'genericmodeprior\n' >"$STUBDIR/.sandbox_list"
  acq_host_config_write sbx genericmodeprior generic-opencode 1

  : >"$CALLS"
  run env ACQ_BACKEND=sbx ACQ_UPDATE_CHECK=0 "$ACQ" run genericmodeprior -- --version

  assert_success
  assert_regex "$(cat "$CALLS")" 'sbx run --name genericmodeprior shell -- -lc exec.*sh opencode --version'
}

@test "migration gate(sbx): failed same-name create retains the existing launch mode" {
  local proj="$STUBDIR/sbx-generic-mode-existing"
  _mk_repo "$proj"
  printf 'genericmodeexisting\n' >"$STUBDIR/.sandbox_list"
  acq_host_config_write sbx genericmodeexisting generic-opencode generic-opencode

  run acq_backend_provision genericmodeexisting opencode "$proj"

  assert_failure
  assert_output --partial "sandbox 'genericmodeexisting' already exists"
  assert_equal "$(acq_host_config_read sbx genericmodeexisting generic-opencode)" generic-opencode
  refute_regex "$(cat "$CALLS")" '^sbx create '
}

@test "migration gate(sbx): unavailable name lookup and failed create retain launch mode" {
  local proj="$STUBDIR/sbx-generic-mode-ls-fail"
  _mk_repo "$proj"
  acq_host_config_write sbx genericmodelsfail generic-opencode generic-opencode

  run env STUB_SBX_LS_FAIL=1 STUB_SBX_CREATE_FAIL=1 \
    bash -c '. "$1/acq.backends/common.sh"; . "$1/acq.backends/sbx.sh"; acq_backend_provision genericmodelsfail opencode "$2"' \
    _ "$REPO_ROOT" "$proj"

  assert_failure
  assert_equal "$(acq_host_config_read sbx genericmodelsfail generic-opencode)" generic-opencode
  assert_regex "$(cat "$CALLS")" 'sbx create --name genericmodelsfail'
  refute_regex "$(cat "$CALLS")" 'sbx rm --force genericmodelsfail'
}

@test "migration gate(sbx): replacement create overwrites a stale launch mode" {
  local proj="$STUBDIR/sbx-generic-mode-replacement"
  _mk_repo "$proj"
  _seed_sbx_usai
  # shellcheck disable=SC2034 # read by acq_backend_provision
  ACQ_DEFAULT_OPENCODE_GENERIC=1
  acq_host_config_write sbx genericmodereplacement generic-opencode legacy-opencode

  run acq_backend_provision genericmodereplacement opencode "$proj"

  assert_success
  assert_equal "$(acq_host_config_read sbx genericmodereplacement generic-opencode)" generic-opencode
  assert_regex "$(_create_line sbx)" ' shell '
}
