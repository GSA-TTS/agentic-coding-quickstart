#!/usr/bin/env bats
#
# 79-msb-merged-kit-env.bats — msb kit environment[] is guest-wide for kit
# lifecycle commands (ADR-0033).
#
# Companion to 78-msb-kit-env.bats, which covers the environment[] marker and its
# SESSION replay. This file covers the LIFECYCLE-COMMAND side: the merged
# whole-kit-set env threaded onto install/initFiles/startup, its order
# independence, duplicate resolution, the mid-life and heal paths, and the
# per-kit ownership of the non-interactive git guards.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

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

@test "ADR-0033: merged env reaches a background startup daemon and every phase" {
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

@test "ADR-0033: the merged env is the same in BOTH kit application orders" {
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

@test "ADR-0033: a duplicate name resolves last-kit-wins on commands" {
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

# --- the git guards belong to the kit whose command is running ------------
#
# Widening the threaded env makes a whole failure class reachable: if the MERGED
# set were also used to decide the guards, one kit could disable
# GIT_TERMINAL_PROMPT=0/GIT_ASKPASS/SSH_ASKPASS for every other kit's commands,
# and a prompting kit command blocks provision forever (the adapter's own comment
# records the playbook kit hanging there). The next three tests pin the two ways
# a kit could reach another kit's guards — NAME collision and VALUE collision —
# plus the case that must keep working: a kit's own intentional override.

# NAME collision. Passes at base too (each kit then saw only its own env, so the
# question could not arise); it guards the widening rather than reproducing a bug.
@test "ADR-0033: one kit's GIT_TERMINAL_PROMPT does not strip another kit's guards" {
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

@test "ADR-0033: mid-life 'kit apply' recovers the merged env from the marker" {
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

@test "ADR-0033: the heal path also merges, daemon kit applied first" {
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

@test "ADR-0033: the merge re-validates names and never re-splits a value" {
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


# VALUE collision — the case a name-only ownership record cannot catch. The merge
# collapses a duplicate name to the LAST kit's value, so an earlier kit that
# declared GIT_TERMINAL_PROMPT=0 saw kit B's =1 on its own commands, with no
# GIT_ASKPASS/SSH_ASKPASS added either (the "owner declared it, leave it alone"
# branch). Reproduces a real regression: at base that command got its own 0.
@test "ADR-0033: two kits declaring the SAME guard name with different values" {
  # Kit A owns the command and declares the safe value; kit B, merged later,
  # declares the opt-out. Kit A's command must keep kit A's value.
  local ka="$STUBDIR/guardvalkitA" kb="$STUBDIR/guardvalkitB"
  mkdir -p "$ka" "$kb"
  cat > "$ka/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: guardval-a
displayName: GuardVal A
description: owns the command and declares the safe guard value
environment:
  GIT_TERMINAL_PROMPT: "0"
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo GUARDVAL_A_CMD
SPEC
  cat > "$kb/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: guardval-b
displayName: GuardVal B
description: a later kit opting ITSELF out of the guards
environment:
  GIT_TERMINAL_PROMPT: "1"
  TEAM_VAR: shared
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo GUARDVAL_B_CMD
SPEC
  _env_merge_provision "$ka" "$kb"
  local log; log=$(cat "$CALLS")
  # Kit A's command: its own value, never kit B's.
  local a; a=$(printf '%s\n' "$log" | grep 'echo GUARDVAL_A_CMD' | head -n1)
  assert_regex "$a" '\-e GIT_TERMINAL_PROMPT=0'
  refute_regex "$a" 'GIT_TERMINAL_PROMPT=1'
  # Kit B's command: its own opt-out value, never kit A's.
  local b; b=$(printf '%s\n' "$log" | grep 'echo GUARDVAL_B_CMD' | head -n1)
  assert_regex "$b" '\-e GIT_TERMINAL_PROMPT=1'
  refute_regex "$b" 'GIT_TERMINAL_PROMPT=0'
  # Both still receive the other kit's NON-guard merged vars.
  assert_regex "$a" '\-e TEAM_VAR=shared'
  assert_regex "$b" '\-e TEAM_VAR=shared'
}

@test "ADR-0033: a kit's own guard override is not clobbered by the merged set" {
  # The mirror of the finding: fixing value-collision must not stop a kit from
  # overriding the guards for ITS OWN commands. Its own value appears once, with
  # no conflicting duplicate, and acq's GIT_TERMINAL_PROMPT=0 is not added.
  local ok="$STUBDIR/ownoverridekit" ck="$STUBDIR/ownotherkit"
  mkdir -p "$ok" "$ck"
  cat > "$ok/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: own-override
displayName: Own Override
description: deliberately opts itself out of the git guards
environment:
  GIT_TERMINAL_PROMPT: "1"
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo OWN_OVERRIDE_CMD
SPEC
  cat > "$ck/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: own-other
displayName: Own Other
description: contributes only a non-guard var
environment:
  OPENCODE_CONFIG: /home/agent/.config/opencode/team.jsonc
SPEC
  _env_merge_provision "$ok" "$ck"
  local cmd n
  cmd=$(printf '%s\n' "$(cat "$CALLS")" | grep 'echo OWN_OVERRIDE_CMD' | head -n1)
  assert_regex "$cmd" '\-e GIT_TERMINAL_PROMPT=1'
  refute_regex "$cmd" 'GIT_TERMINAL_PROMPT=0'
  n=$(printf '%s\n' "$cmd" | tr ' ' '\n' | grep -c '^GIT_TERMINAL_PROMPT=')
  assert_equal "$n" "1"
  # And it still receives the other kit's merged non-guard var.
  assert_regex "$cmd" '\-e OPENCODE_CONFIG=/home/agent/\.config/opencode/team\.jsonc'
}
