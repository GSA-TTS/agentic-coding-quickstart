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
description: overrides GITLAB_HOST from a later kit, and carries an awkward value
environment:
  GITLAB_HOST: gitlab.second.gov
  OPENCODE_CONFIG: /home/agent/a b.jsonc; touch /tmp/MERGE_PWNED
SPEC
  _env_merge_provision "$k1" "$k2"
  local cmd; cmd=$(printf '%s\n' "$(cat "$CALLS")" | grep 'echo DUP_CMD' | head -n1)
  # The command belongs to the EARLIER kit, yet must see the LATER kit's value —
  # the same resolution the session replay applies, and exactly once (never both).
  assert_regex "$cmd" '\-e GITLAB_HOST=gitlab\.second\.gov'
  refute_regex "$cmd" 'gitlab\.first\.gov'
  # A value with spaces and metacharacters crosses the merge as ONE token: it is
  # threaded as a single `-e` argv element, never re-split into a second variable
  # and never interpreted as shell syntax (SI-10).
  assert_regex "$cmd" '\-e OPENCODE_CONFIG=/home/agent/a b\.jsonc; touch /tmp/MERGE_PWNED'
  refute_regex "$cmd" '\-e touch'
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

@test "ADR-0033: mid-life 'kit apply' recovers the merged env from host config" {
  # A mid-life single-kit apply has NO full kit set to pre-merge, so it must fall
  # back to the env the sandbox already persisted in host config — otherwise
  # adding a daemon kit to a live sandbox reintroduces exactly the reported bug
  # for that kit.
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
    export STUB_RECORDED_KIT_ENV='OPENCODE_CONFIG=/home/agent/.config/opencode/team.jsonc'
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/kit-translate.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    seed_host_config msb midlifebox
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


# VALUE collision — the case a name-only ownership record cannot catch. The merge
# collapses a duplicate name to the LAST kit's value, so an earlier kit that
# declared GIT_TERMINAL_PROMPT=0 saw kit B's =1 on its own commands, with no
# GIT_ASKPASS/SSH_ASKPASS added either (the "owner declared it, leave it alone"
# branch). Reproduces a real regression: at base that command got its own 0.
#
# The two kits also cover the mirror requirement in one pass: kit B is a kit that
# deliberately opts ITSELF out, so its own override must survive intact (its value,
# exactly once, no acq-injected 0 alongside it) and both kits must still receive
# the other's NON-guard merged vars — proving the hole was closed by scoping the
# guards, not by disabling the merge.
@test "ADR-0033: two kits declaring the SAME guard name with different values" {
  local ka="$STUBDIR/guardvalkitA" kb="$STUBDIR/guardvalkitB"
  mkdir -p "$ka" "$kb"
  cat > "$ka/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: guardval-a
displayName: GuardVal A
description: owns a command and declares the safe guard value
environment:
  GIT_TERMINAL_PROMPT: "0"
  A_VAR: from-a
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
  B_VAR: from-b
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo GUARDVAL_B_CMD
SPEC
  _env_merge_provision "$ka" "$kb"
  local log a b na nb
  log=$(cat "$CALLS")
  # Kit A's command: its own value, never kit B's, and the ASKPASS guards absent
  # because A declared GIT_TERMINAL_PROMPT itself.
  a=$(printf '%s\n' "$log" | grep 'echo GUARDVAL_A_CMD' | head -n1)
  assert_regex "$a" '\-e GIT_TERMINAL_PROMPT=0'
  refute_regex "$a" 'GIT_TERMINAL_PROMPT=1'
  na=$(printf '%s\n' "$a" | tr ' ' '\n' | grep -c '^GIT_TERMINAL_PROMPT=')
  assert_equal "$na" "1"
  # Kit B's command: its own opt-out value stands, exactly once, with no
  # acq-injected 0 — a kit's intentional override is not clobbered.
  b=$(printf '%s\n' "$log" | grep 'echo GUARDVAL_B_CMD' | head -n1)
  assert_regex "$b" '\-e GIT_TERMINAL_PROMPT=1'
  refute_regex "$b" 'GIT_TERMINAL_PROMPT=0'
  nb=$(printf '%s\n' "$b" | tr ' ' '\n' | grep -c '^GIT_TERMINAL_PROMPT=')
  assert_equal "$nb" "1"
  # Both still receive the OTHER kit's non-guard merged vars: the guards were
  # scoped, the merge was not disabled.
  assert_regex "$a" '\-e B_VAR=from-b'
  assert_regex "$b" '\-e A_VAR=from-a'
}

@test "ADR-0033: mid-life 'kit apply' keeps its own env when the host append is lost" {
  # The persisted read can return a STALE non-empty host-config value that lacks
  # this kit's entries (step 2's append failed: it only warns). The kit's commands
  # must still carry its own environment[], winning over a stale value for the
  # same name, while keeping the other persisted entries.
  local mk="$STUBDIR/lostappendkit"; mkdir -p "$mk"
  cat > "$mk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: lostappend-kit
displayName: Lost Append Kit
description: added to a live sandbox whose marker append does not land
environment:
  OPENCODE_CONFIG: /fresh.jsonc
  LOST_OWN: yes
commands:
  - phase: startup
    user: "0"
    background: true
    command:
      - lostappend-daemon
SPEC
  : > "$CALLS"
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/lostappend-secrets"
    export STUB_RECORDED_KIT_ENV='OPENCODE_CONFIG=/stale.jsonc
OTHER_KIT_VAR=kept'
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    . "${REPO_ROOT}/acq.backends/kit-translate.sh"
    . "${REPO_ROOT}/acq.backends/msb.sh"
    seed_host_config msb lostappendbox
    acq_backend_apply_kit lostappendbox "$mk" >/dev/null 2>&1 )
  local bg; bg=$(printf '%s\n' "$(cat "$CALLS")" | grep 'nohup' | head -n1)
  assert_regex "$bg" '\-e LOST_OWN=yes'
  assert_regex "$bg" '\-e OPENCODE_CONFIG=/fresh\.jsonc'
  refute_regex "$bg" 'stale\.jsonc'
  assert_regex "$bg" '\-e OTHER_KIT_VAR=kept'
}

@test "ADR-0033: a backend-shortcut kit's environment[] is not merged into other kits" {
  # A kit with a backend_shortcuts.msb entry skips the generic apply path, so its
  # environment[] is never persisted for sessions. Merging it into other kits'
  # commands would make commands and sessions disagree on the guest env.
  local sk="$STUBDIR/shortcutkit"; mkdir -p "$sk"
  cat > "$sk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: shortcut-kit
displayName: Shortcut Kit
description: handled natively by msb; declares env that must stay unmerged
environment:
  SHORTCUT_VAR: leaked
backend_shortcuts:
  msb:
    trust_host_cas: true
SPEC
  _env_kit_daemon "$STUBDIR/daemonkit"
  _env_merge_provision "$sk" "$STUBDIR/daemonkit"
  local bg; bg=$(printf '%s\n' "$(cat "$CALLS")" | grep 'nohup' | head -n1)
  assert_regex "$bg" '\-e PASEO_OWN_VAR=own'
  refute_regex "$bg" 'SHORTCUT_VAR'
}
