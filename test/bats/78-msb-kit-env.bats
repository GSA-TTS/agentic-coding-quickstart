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
  # Asserts the WRITE specifically (`>> /var/lib/acq/kit-env`), not any mention of
  # the path: a kit with no environment[] of its own still READS the merged marker
  # so its commands inherit the other kits' env (see ADR-0033) — that read is
  # expected here, an append is not.
  refute_regex "$(cat "$CALLS")" '>> /var/lib/acq/kit-env'
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

# --- merged kit env on kit lifecycle commands (ADR-0033) -------------------
#
# Kit env is guest-wide guest configuration, but on msb a kit's lifecycle
# commands used to run with only THAT kit's environment[]. The reported symptom:
# a `background: true` startup daemon (the Paseo kit's `paseo daemon`) launches
# agents, and those agents inherited only the daemon kit's vars — a team kit's
# OPENCODE_CONFIG (team instructions + a default-deny permission layer) was
# silently absent while the secrets were still present. The fix threads the
# MERGED env of the full effective kit set onto every lifecycle command.

# _env_merge_provision KITDIRS... — provision `mergebox` with the given local kit
# dirs as the full built-in kit set, in the order given (so the same two kits can
# be applied in either order). Echoes nothing; assertions read $CALLS.
_env_merge_provision() {
  : > "$CALLS"
  local a="$1" b="$2"
  run bash -c '
    a="$1"; b="$2"
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/merge-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/merge-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ZSCALER_KIT=k1; USAI_KIT=k2; PLAYBOOK_KIT=k3; GITSSHSIGN_KIT=k4
    nk="'"$STUBDIR"'/mergenokit"; mkdir -p "$nk"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "$nk/spec.yaml"
    _acq_msb_fetch_kit() {
      case "$1" in k1) printf "%s\n" "$a" ;; k2) printf "%s\n" "$b" ;; *) printf "%s\n" "$nk" ;; esac
    }
    acq_backend_provision mergebox shell /tmp >/dev/null 2>&1
  ' _ "$a" "$b"
}

# Write a kit dir that declares OPENCODE_CONFIG and has no commands.
_env_kit_config() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: team-kit
displayName: Team Kit
description: declares agent-runtime config other kits' commands must see
environment:
  OPENCODE_CONFIG: /home/agent/.config/opencode/team.jsonc
SPEC
}

# Write a kit dir whose commands span all three lifecycle phases, the startup one
# detached (the reported daemon shape).
_env_kit_daemon() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: daemon-kit
displayName: Daemon Kit
description: install + initFiles + a background startup daemon
environment:
  PASEO_OWN_VAR: own
commands:
  - phase: install
    user: "0"
    command:
      - sh
      - -c
      - echo INSTALL_CMD
  - phase: initFiles
    user: "0"
    command:
      - sh
      - -c
      - echo INITFILES_CMD
  - phase: startup
    user: "0"
    background: true
    command:
      - paseo-daemon
SPEC
}

@test "msb kit env (ADR-0033): merged env reaches a background startup daemon and every phase" {
  _env_kit_config "$STUBDIR/cfgkit"
  _env_kit_daemon "$STUBDIR/daemonkit"
  _env_merge_provision "$STUBDIR/cfgkit" "$STUBDIR/daemonkit"
  local log; log=$(cat "$CALLS")
  # The detached daemon exec carries the OTHER kit's var, not just its own.
  local bg; bg=$(printf '%s\n' "$log" | grep 'nohup' | head -n1)
  assert_regex "$bg" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
  assert_regex "$bg" '\-e PASEO_OWN_VAR=own'
  # install and initFiles too — the same guest-wide env contract.
  local inst; inst=$(printf '%s\n' "$log" | grep 'echo INSTALL_CMD' | head -n1)
  assert_regex "$inst" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
  local init; init=$(printf '%s\n' "$log" | grep 'echo INITFILES_CMD' | head -n1)
  assert_regex "$init" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
}

@test "msb kit env (ADR-0033): the merged env is the same in BOTH kit application orders" {
  _env_kit_config "$STUBDIR/cfgkit"
  _env_kit_daemon "$STUBDIR/daemonkit"
  # config kit applied FIRST (the order a per-kit marker read would also pass).
  _env_merge_provision "$STUBDIR/cfgkit" "$STUBDIR/daemonkit"
  local bg1; bg1=$(printf '%s\n' "$(cat "$CALLS")" | grep 'nohup' | head -n1)
  assert_regex "$bg1" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
  # daemon kit applied FIRST — the order that silently fails without a pre-pass:
  # the marker does not yet hold the config kit's entry when the daemon launches.
  _env_merge_provision "$STUBDIR/daemonkit" "$STUBDIR/cfgkit"
  local bg2; bg2=$(printf '%s\n' "$(cat "$CALLS")" | grep 'nohup' | head -n1)
  assert_regex "$bg2" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
}

@test "msb kit env (ADR-0033): a duplicate name resolves last-kit-wins on commands" {
  local k1="$STUBDIR/dupkit1" k2="$STUBDIR/dupkit2"
  mkdir -p "$k1" "$k2"
  cat > "$k1/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: dup-one
displayName: Dup One
description: sets GITLAB_HOST first and owns the command
environment:
  GITLAB_HOST: gitlab.first.gov
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo DUP_CMD
SPEC
  cat > "$k2/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: dup-two
displayName: Dup Two
description: overrides GITLAB_HOST from a later kit
environment:
  GITLAB_HOST: gitlab.second.gov
SPEC
  _env_merge_provision "$k1" "$k2"
  local cmd; cmd=$(printf '%s\n' "$(cat "$CALLS")" | grep 'echo DUP_CMD' | head -n1)
  # The command belongs to the EARLIER kit, yet must see the LATER kit's value —
  # the same resolution the session replay applies, and exactly once (never both).
  assert_regex "$cmd" '\-e GITLAB_HOST=gitlab\.second\.gov'
  refute_regex "$cmd" 'gitlab\.first\.gov'
}

# Guard test, not a bug reproduction: this passes BEFORE the merged-env change too
# (each kit then saw only its own env, so the question could not arise). It exists
# because widening the threaded env makes the failure reachable — if the merged set
# were also used to DECIDE the guards, one kit setting GIT_TERMINAL_PROMPT would
# disable GIT_TERMINAL_PROMPT=0/GIT_ASKPASS/SSH_ASKPASS for every other kit's
# commands, and a prompting kit command would block provision forever.
@test "msb kit env (ADR-0033): one kit's GIT_TERMINAL_PROMPT does not strip another kit's guards" {
  local gk="$STUBDIR/gitpromptkit" pk="$STUBDIR/plainkit"
  mkdir -p "$gk" "$pk"
  # A kit that deliberately opts out of the non-interactive git guards.
  cat > "$gk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: prompt-kit
displayName: Prompt Kit
description: opts itself out of the git guards
environment:
  GIT_TERMINAL_PROMPT: "1"
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo PROMPT_KIT_CMD
SPEC
  # A different kit that did NOT opt out: its commands must keep the guards, or a
  # prompting command would block provision forever.
  cat > "$pk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: plain-kit
displayName: Plain Kit
description: relies on the adapter's git guards
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo PLAIN_KIT_CMD
SPEC
  _env_merge_provision "$gk" "$pk"
  local log; log=$(cat "$CALLS")
  local plain; plain=$(printf '%s\n' "$log" | grep 'echo PLAIN_KIT_CMD' | head -n1)
  assert_regex "$plain" '\-e GIT_TERMINAL_PROMPT=0'
  assert_regex "$plain" '\-e GIT_ASKPASS=/bin/false'
  assert_regex "$plain" '\-e SSH_ASKPASS=/bin/false'
  refute_regex "$plain" 'GIT_TERMINAL_PROMPT=1'
  # The opting-out kit still gets its own value, and only that value.
  local prompt; prompt=$(printf '%s\n' "$log" | grep 'echo PROMPT_KIT_CMD' | head -n1)
  assert_regex "$prompt" '\-e GIT_TERMINAL_PROMPT=1'
  refute_regex "$prompt" 'GIT_TERMINAL_PROMPT=0'
}

@test "msb kit env (ADR-0033): mid-life 'kit apply' recovers the merged env from the marker" {
  # A mid-life single-kit apply has NO full kit set to pre-merge, so it must fall
  # back to the env the sandbox already persisted — otherwise adding a daemon kit
  # to a live sandbox reintroduces exactly the reported bug for that kit.
  printf 'OPENCODE_CONFIG=/home/agent/.config/opencode/team.jsonc\n' > "$STUBDIR/.kit_env"
  local mk="$STUBDIR/midlifekit"; mkdir -p "$mk"
  cat > "$mk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: midlife-kit
displayName: Midlife Kit
description: added to a live sandbox; its own env plus what is already persisted
environment:
  MIDLIFE_OWN: yes
commands:
  - phase: startup
    user: "0"
    background: true
    command:
      - midlife-daemon
SPEC
  : > "$CALLS"
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/midlife-secrets"
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/kit-translate.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    acq_backend_apply_kit midlifebox "$mk" >/dev/null 2>&1 )
  local bg; bg=$(printf '%s\n' "$(cat "$CALLS")" | grep 'nohup' | head -n1)
  assert_regex "$bg" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
  assert_regex "$bg" '\-e MIDLIFE_OWN=yes'
}

@test "msb kit env (ADR-0033): the heal path also merges, daemon kit applied first" {
  # The heal (acq start/restart, re-attach) is the OTHER full-set path, and it is
  # the one that restarts a kit's daemon on resume. Same pre-pass requirement: the
  # daemon kit is healed FIRST here, so a per-kit marker read would give it an env
  # missing the config kit's var.
  printf 'healmergebox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'healmergebox\n' > "$STUBDIR/.msb_running_list"
  _env_kit_config "$STUBDIR/cfgkit"
  _env_kit_daemon "$STUBDIR/daemonkit"
  : > "$CALLS"
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/healmerge-secrets"
    export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/healmerge-stage"
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/kit-translate.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    # shellcheck disable=SC2034  # read by the sourced acq_backend_ensure_kits_applied
    ACQ_CLI_KITS=()
    nk="$STUBDIR/healmergenokit"; mkdir -p "$nk"
    printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "$nk/spec.yaml"
    # Resolve by CALL ORDER rather than by kit ref, so the built-in kit refs stay
    # untouched: the heal fetches them in list order, so call 1 is the daemon kit
    # and call 2 the config kit — the daemon applied FIRST.
    printf 0 > "$STUBDIR/.healmerge_n"
    _acq_msb_fetch_kit() {
      local n; n=$(cat "$STUBDIR/.healmerge_n")
      printf '%s' "$((n + 1))" > "$STUBDIR/.healmerge_n"
      case "$n" in
        0) printf '%s\n' "$STUBDIR/daemonkit" ;;
        1) printf '%s\n' "$STUBDIR/cfgkit" ;;
        *) printf '%s\n' "$nk" ;;
      esac
    }
    acq_backend_ensure_kits_applied healmergebox >/dev/null 2>&1 )
  local bg; bg=$(printf '%s\n' "$(cat "$CALLS")" | grep 'nohup' | head -n1)
  assert_regex "$bg" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
  assert_regex "$bg" '\-e PASEO_OWN_VAR=own'
}

@test "msb kit env (ADR-0033): the merge re-validates names and never re-splits a value" {
  # The merge helper is a second place kit-derived NAME=value tokens flow through,
  # so it re-applies the kit_spec_env charset itself (defense in depth), and each
  # token stays ONE array element so a value with spaces or metacharacters is
  # never re-split into a second variable (SI-10).
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    m=()
    _acq_msb_dedupe_env_into m "BAD-NAME=x" "=noname" "noequals" \
      "OPENCODE_CONFIG=/home/agent/a b.jsonc; touch /tmp/PWNED" "OK=1"
    printf "TOKEN[%s]\n" ${m[@]+"${m[@]}"}
  '
  assert_success
  refute_output --partial 'BAD-NAME'
  refute_output --partial 'noequals'
  assert_output --partial 'TOKEN[OPENCODE_CONFIG=/home/agent/a b.jsonc; touch /tmp/PWNED]'
  assert_output --partial 'TOKEN[OK=1]'
}
