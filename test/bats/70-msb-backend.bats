#!/usr/bin/env bats
#
# 70-msb-backend.bats — bats port of scripts/test-acq.d/70-msb-backend.sh (ADR-0025)
#
# msb backend: resolution, dispatch, doctor/list/version, host-readiness +
# version-floor checks, and secret set into the acq store. Resolution/prepare
# unit checks source acq in a subshell; dispatch checks use the real CLI + $CALLS.
#
# shellcheck shell=bats

# The host-config mount source is canonicalized (macOS /var -> /private/var), so
# compare against the physical stub dir.
setup() { acq_setup_stubs; REAL_STUBDIR=$(cd "$STUBDIR" && pwd -P); }
teardown() { acq_teardown_stubs; }

load 'helper'

# Source acq (definitions only) + an adapter in a clean subshell and run BODY.
_with_adapter() { # ADAPTER BODY
  run bash -c '
    adapter="$1"; shift
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/${adapter}.sh"
    set +e
    eval "$1"
  ' _ "$1" "$2"
}

_mk_unix_socket() {
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])' "$1" >/dev/null 2>&1 && [ -S "$1" ]
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

@test "msb: auto-detect prefers msb when both present and no sbx sandboxes" {
  rm -f "$STUBDIR/.sandbox_list"
  run bash -c '
    unset ACQ_BACKEND
    export XDG_CONFIG_HOME="'"$STUBDIR"'/noconfig"
    export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
    export PATH="'"$STUBDIR"':$PATH"
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    set +e
    _auto_detect_backend
    printf "backend=%s reason=%s\n" "$ACQ_AUTODETECT_BACKEND" "$ACQ_AUTODETECT_REASON"
  '
  assert_output --partial 'backend=msb reason=both-msb'
}

@test "msb: auto-detect falls back to sbx when only sbx is present" {
  run bash -c '
    unset ACQ_BACKEND
    export XDG_CONFIG_HOME="'"$STUBDIR"'/noconfig"
    export ACQ_TEST_INSTALLED_BACKENDS="sbx"
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    set +e
    _auto_detect_backend
    printf "backend=%s reason=%s\n" "$ACQ_AUTODETECT_BACKEND" "$ACQ_AUTODETECT_REASON"
  '
  assert_output --partial 'backend=sbx reason=sbx-only'
}

@test "msb: --backend msb resolves and loads the adapter" {
  _with_adapter msb 'unset ACQ_BACKEND; acq_resolve_backend msb; printf "%s\n" "$ACQ_RESOLVED_BACKEND"'
  assert_output --partial 'msb'
}

@test "msb: advertises SUPPORTS_SNAPSHOTS=1 because acq surfaces disk-state snapshot/restore" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; printf "%s" "$ACQ_BACKEND_SUPPORTS_SNAPSHOTS"'
  assert_output '1'
}

@test "msb: snapshot maps to a disk-state msb archive with date-stamped default output" {
  run env ACQ_BACKEND=msb ACQ_SNAPSHOT_DIR="$STUBDIR/snapshots" "$ACQ" snapshot mybox
  assert_success
  assert_regex "$(cat "$CALLS")" "msb snapshot create --from-sandbox mybox --guest-flush auto -o $STUBDIR/snapshots/mybox-[0-9]{8}T[0-9]{6}Z\.msb"
  [ "$(stat -c '%a' "$STUBDIR/snapshots" 2>/dev/null || stat -f '%Lp' "$STUBDIR/snapshots")" = "700" ]
  : > "$CALLS"
  mkdir -p "$STUBDIR/state/msb-restore" "$STUBDIR/provenance/msb" "$STUBDIR/ws"
  printf 'volume\t%s:%s\n' "$STUBDIR/ws" "$STUBDIR/ws" > "$STUBDIR/state/msb-restore/mybox.resources"
  local kit_record
  kit_record=$(printf '%s' mybox | cksum | cut -d' ' -f1)
  printf 'schema=1\nkit=%s\n' "$STUBDIR/custom-kit" > "$STUBDIR/provenance/msb/mybox.${kit_record}.kits"
  acq_host_config_write msb mybox agent opencode
  acq_host_config_write msb mybox workspace "$STUBDIR/ws"
  acq_host_config_write msb mybox generic-opencode generic-opencode
  acq_workspace_record_write msb mybox "$STUBDIR/ws"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" "$ACQ" snapshot mybox "$STUBDIR/mybox.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" "msb snapshot create --from-sandbox mybox --guest-flush auto -o $STUBDIR/mybox\.msb"
  [ "$(stat -c '%a' "$STUBDIR/mybox.msb" 2>/dev/null || stat -f '%Lp' "$STUBDIR/mybox.msb")" = "600" ]
  [ -f "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/mybox.msb").resources" ]
  [ -f "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/mybox.msb").state" ]
}

@test "msb: create with no workspace positional provisions without empty-array abort" {
  : > "$CALLS"
  run env ACQ_BACKEND=msb USAI_API_KEY="sk-ci-host" "$ACQ" create opencode
  assert_success
  refute_output --partial 'unbound variable'
  assert_regex "$(cat "$CALLS")" 'msb create --name opencode'
}

@test "msb: snapshot preserves legacy provenance agent state" {
  mkdir -p "$STUBDIR/provenance/msb" "$STUBDIR/ws"
  local record
  record=$(printf '%s' legacybox | cksum | cut -d' ' -f1)
  printf 'schema=1\nbackend=msb\nagent=opencode\nworkspace_source=host\nworkspace=%s\n' "$STUBDIR/ws" > "$STUBDIR/provenance/msb/legacybox.${record}.env"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" "$ACQ" snapshot legacybox "$STUBDIR/legacy.msb"
  assert_success
  assert_regex "$(cat "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/legacy.msb").state")" $'agent\topencode'
  assert_regex "$(cat "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/legacy.msb").state")" $'workspace\t'"$STUBDIR/ws"
}

@test "msb: restore maps to msb restore with inherited resources and re-derived vsock" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  local sock_path="$STUBDIR/agent.sock"
  command -v realpath >/dev/null 2>&1 && sock_path=$(realpath "$sock_path")
  mkdir -p "$STUBDIR/secrets" "$STUBDIR/ws" "$STUBDIR/provenance/msb"
  printf 'sk-restored\n' > "$STUBDIR/secrets/acq.usai"
  : > "$STUBDIR/saved.msb"
  mkdir -p "$STUBDIR/state/msb-snapshots"
  printf 'volume\t%s:%s\n' "$STUBDIR/ws" "$STUBDIR/ws" > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/saved.msb").resources"
  printf 'schema=1\nkit=%s\n' "$STUBDIR/custom-kit" > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/saved.msb").kits"
  printf 'agent\topencode\nworkspace\t%s\ngeneric-opencode\tgeneric-opencode\nhost-workspace\t%s\n' "$STUBDIR/ws" "$STUBDIR/ws" > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/saved.msb").state"
  mkdir -p "$STUBDIR/custom-kit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: custom\ndisplayName: Custom\ndescription: custom\n' > "$STUBDIR/custom-kit/spec.yaml"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" SSH_AUTH_SOCK="$STUBDIR/agent.sock" "$ACQ" restore restored "$STUBDIR/saved.msb"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb restore $STUBDIR/state/msb-snapshots/\.restore\.[[:alnum:]]{6} --name restored --dangerously-inherit-resources --volume $REAL_STUBDIR/provenance/msb/restored\\.[0-9]+\\.config:$ACQ_HOST_CONFIG_GUEST_DIR:ro --volume $STUBDIR/ws:$STUBDIR/ws --vsock $STUBDIR/state/msb/ssh-agent/restored\.sock:3552/stream --secret USAI_API_KEY@api.gsa.usai.gov"
  assert_regex "$log" 'USAI_API_KEY=present'
  assert_regex "$log" 'socat UNIX-LISTEN:'
  assert_regex "$log" 'msb inspect restored --format json'
  assert_output --partial "re-applied kit startup"
  [ -f "$STUBDIR/state/msb-restore/restored.resources" ]
  assert_equal "$(acq_host_config_read msb restored agent)" opencode
  assert_equal "$(acq_host_config_read msb restored workspace)" "$STUBDIR/ws"
  assert_equal "$(acq_host_config_read msb restored generic-opencode)" generic-opencode
  assert_equal "$(acq_workspace_record_read msb restored)" "$STUBDIR/ws"
  local kit_record
  kit_record=$(printf '%s' restored | cksum | cut -d' ' -f1)
  assert [ -f "$STUBDIR/provenance/msb/restored.${kit_record}.kits" ]
  assert_regex "$(cat "$STUBDIR/provenance/msb/restored.${kit_record}.kits")" "$STUBDIR/custom-kit"
  [ -f "$STUBDIR/state/msb-restore/restored.resources" ]
}

@test "msb: restore without external workspace mounts re-applies kits" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  : > "$STUBDIR/disk-state.msb"
  : > "$CALLS"
  run env ACQ_BACKEND=msb SSH_AUTH_SOCK="$STUBDIR/agent.sock" "$ACQ" restore restored "$STUBDIR/disk-state.msb"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb restore $STUBDIR/state/msb-snapshots/\.restore\.[[:alnum:]]{6} --name restored --dangerously-inherit-resources --volume $REAL_STUBDIR/provenance/msb/restored\\.[0-9]+\\.config:$ACQ_HOST_CONFIG_GUEST_DIR:ro --vsock"
  assert_regex "$log" 'msb inspect restored --format json'
  assert_output --partial "re-applied kit startup"
}

@test "msb: metadata-free restore clears stale name-scoped state" {
  mkdir -p "$STUBDIR/stale-workspace" "$STUBDIR/state/msb-restore"
  : > "$STUBDIR/disk-state.msb"
  printf 'volume\t%s:%s\n' "$STUBDIR/stale-workspace" "$STUBDIR/stale-workspace" > "$STUBDIR/state/msb-restore/restored.resources"
  acq_host_config_write msb restored agent opencode
  acq_host_config_write msb restored workspace "$STUBDIR/stale-workspace"
  acq_host_config_write msb restored generic-opencode generic-opencode
  acq_workspace_record_write msb restored "$STUBDIR/stale-workspace"
  acq_cli_kits_write msb restored /stale/kit
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" restore restored "$STUBDIR/disk-state.msb"
  assert_success
  refute_regex "$(cat "$CALLS")" "--volume $STUBDIR/stale-workspace:$STUBDIR/stale-workspace"
  [ ! -f "$STUBDIR/state/msb-restore/restored.resources" ]
  assert_equal "$(acq_host_config_read msb restored agent)" ""
  assert_equal "$(acq_host_config_read msb restored workspace)" ""
  assert_equal "$(acq_host_config_read msb restored generic-opencode)" ""
  assert_equal "$(acq_workspace_record_read msb restored)" ""
}

@test "msb: restore refuses an existing destination without clearing its state" {
  mkdir -p "$STUBDIR/existing-workspace" "$STUBDIR/state/msb-restore"
  : > "$STUBDIR/disk-state.msb"
  printf 'restored\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'volume\t%s:%s\n' "$STUBDIR/existing-workspace" "$STUBDIR/existing-workspace" > "$STUBDIR/state/msb-restore/restored.resources"
  acq_host_config_write msb restored agent opencode
  acq_workspace_record_write msb restored "$STUBDIR/existing-workspace"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" restore restored "$STUBDIR/disk-state.msb"
  assert_failure
  assert_output --partial "destination sandbox 'restored' already exists"
  refute_regex "$(cat "$CALLS")" 'msb restore'
  [ -f "$STUBDIR/state/msb-restore/restored.resources" ]
  assert_equal "$(acq_host_config_read msb restored agent)" opencode
  assert_equal "$(acq_workspace_record_read msb restored)" "$STUBDIR/existing-workspace"
}

@test "msb: restore preserves destination state when absence cannot be confirmed" {
  mkdir -p "$STUBDIR/existing-workspace" "$STUBDIR/state/msb-restore"
  : > "$STUBDIR/disk-state.msb"
  printf 'volume\t%s:%s\n' "$STUBDIR/existing-workspace" "$STUBDIR/existing-workspace" > "$STUBDIR/state/msb-restore/restored.resources"
  acq_host_config_write msb restored agent opencode
  acq_workspace_record_write msb restored "$STUBDIR/existing-workspace"
  : > "$CALLS"
  run env ACQ_BACKEND=msb STUB_MSB_LIST_FAIL=1 "$ACQ" restore restored "$STUBDIR/disk-state.msb"
  assert_failure
  assert_output --partial "could not confirm destination sandbox 'restored' is absent"
  refute_regex "$(cat "$CALLS")" 'msb restore'
  [ -f "$STUBDIR/state/msb-restore/restored.resources" ]
  assert_equal "$(acq_host_config_read msb restored agent)" opencode
  assert_equal "$(acq_workspace_record_read msb restored)" "$STUBDIR/existing-workspace"
}

@test "msb: restore binds the provider credential from the registry binding" {
  mkdir -p "$STUBDIR/secrets"
  printf 'restored-key\n' > "$STUBDIR/secrets/acq.usai"
  : > "$STUBDIR/disk-state.msb"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVIDER_CREDENTIAL_BINDINGS='usai=RESTORE_API_KEY@api.restore.example.gov' \
    "$ACQ" restore restored "$STUBDIR/disk-state.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb restore .* --secret RESTORE_API_KEY@api\.restore\.example\.gov'
}

@test "msb: restore ignores archive-adjacent resource sidecars" {
  mkdir -p "$STUBDIR/ws" "$STUBDIR/attacker"
  : > "$STUBDIR/untrusted.msb"
  printf 'volume\t%s:%s\n' "$STUBDIR/attacker" "$STUBDIR/attacker" > "$STUBDIR/untrusted.msb.resources"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" restore restored "$STUBDIR/untrusted.msb"
  assert_success
  refute_regex "$(cat "$CALLS")" "--volume $STUBDIR/attacker:$STUBDIR/attacker"
}

@test "msb: private staging keeps identical snapshot restores independent" {
  : > "$STUBDIR/shared.msb"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    first=$(_acq_msb_snapshot_stage "'"$STUBDIR"'/shared.msb") || exit 1
    second=$(_acq_msb_snapshot_stage "'"$STUBDIR"'/shared.msb") || exit 1
    [ "$first" != "$second" ] || exit 1
    [ -f "$first" ] && [ -f "$second" ] || exit 1
    rm -f "$first"
    [ ! -e "$first" ] && [ -f "$second" ] || exit 1
    rm -f "$second"
    printf "%s\n%s\n" "$first" "$second"
  '
  assert_success
  assert_line --index 0 --regexp "/msb-snapshots/\\.restore\\.[[:alnum:]]{6}$"
  assert_line --index 1 --regexp "/msb-snapshots/\\.restore\\.[[:alnum:]]{6}$"
}

@test "msb: restore fails when the guest never becomes exec-ready" {
  : > "$STUBDIR/unready.msb"
  : > "$CALLS"
  run env ACQ_BACKEND=msb STUB_MSB_EXEC_FAIL=1 ACQ_MSB_EXEC_READY_TIMEOUT=0 \
    "$ACQ" restore restored "$STUBDIR/unready.msb"
  assert_failure
  assert_output --partial "did not become exec-ready"
  refute_output --partial "acq: restored 'restored'."
}

@test "msb: restore without a snapshot picks the newest date-stamped snapshot for the sandbox" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  mkdir -p "$STUBDIR/snapshots" "$STUBDIR/ws2"
  printf 'older-archive\n' > "$STUBDIR/snapshots/mybox-20260920T010203Z.msb"
  printf 'newest-archive\n' > "$STUBDIR/snapshots/mybox-20260921T010203Z.msb"
  mkdir -p "$STUBDIR/state/msb-snapshots"
  printf 'volume\t%s:%s\n' "$STUBDIR/ws2" "$STUBDIR/ws2" > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/snapshots/mybox-20260921T010203Z.msb").resources"
  printf 'not-a-date-archive\n' > "$STUBDIR/snapshots/mybox-z-not-a-date.msb"
  printf 'other-sandbox-archive\n' > "$STUBDIR/snapshots/other-20260922T010203Z.msb"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_SNAPSHOT_DIR="$STUBDIR/snapshots" SSH_AUTH_SOCK="$STUBDIR/agent.sock" "$ACQ" restore mybox
  assert_success
  assert_regex "$(cat "$CALLS")" "msb restore $STUBDIR/state/msb-snapshots/\.restore\.[[:alnum:]]{6} --name mybox"
  assert_regex "$(cat "$CALLS")" 'restore-archive=newest-archive'
  refute_regex "$(cat "$CALLS")" 'restore-archive=(older|not-a-date|other-sandbox)'
}

@test "sbx: snapshot/restore/recreate are acq-owned unsupported verbs, not backend passthrough" {
  run env ACQ_BACKEND=sbx "$ACQ" snapshot mybox
  assert_failure
  assert_output --partial 'does not support sandbox snapshots'
  refute_regex "$(cat "$CALLS")" 'sbx snapshot'
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" restore restored "$STUBDIR/saved.sbx"
  assert_failure
  assert_output --partial 'does not support sandbox restore'
  refute_regex "$(cat "$CALLS")" 'sbx restore'
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" recreate mybox
  assert_failure
  assert_output --partial 'does not support sandbox recreate'
  refute_regex "$(cat "$CALLS")" 'sbx snapshot|sbx restore'
}

@test "msb: recreate snapshots, removes, then restores to the same name" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  local sock_path="$STUBDIR/agent.sock"
  command -v realpath >/dev/null 2>&1 && sock_path=$(realpath "$sock_path")
  mkdir -p "$STUBDIR/state/msb-restore" "$STUBDIR/ws"
  printf 'volume\t%s:%s\n' "$STUBDIR/ws" "$STUBDIR/ws" > "$STUBDIR/state/msb-restore/mybox.resources"
  : > "$CALLS"
  run env ACQ_BACKEND=msb SSH_AUTH_SOCK="$STUBDIR/agent.sock" "$ACQ" recreate mybox "$STUBDIR/recreate.msb"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb snapshot create --from-sandbox mybox --guest-flush auto -o $STUBDIR/recreate\.msb"
  assert_regex "$log" 'msb remove --force mybox'
  refute_regex "$log" 'msb volume rm'
  assert_regex "$log" "msb restore $STUBDIR/state/msb-snapshots/\.restore\.[[:alnum:]]{6} --name mybox --dangerously-inherit-resources --volume $REAL_STUBDIR/provenance/msb/mybox\\.[0-9]+\\.config:$ACQ_HOST_CONFIG_GUEST_DIR:ro --volume $STUBDIR/ws:$STUBDIR/ws --vsock $STUBDIR/state/msb/ssh-agent/mybox\.sock:3552/stream"
  assert_regex "$log" 'msb inspect mybox --format json'
  assert_output --partial "kit startup re-applied"
}

@test "msb: rm --snapshot snapshots before removing and does not restore" {
  acq_host_config_write msb mybox agent opencode
  acq_workspace_record_write msb mybox "$STUBDIR"
  acq_cli_kits_write msb mybox
  printf 'acq-mybox-volume\n' > "$STUBDIR/.msb_volume_list"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" rm --snapshot mybox "$STUBDIR/rm.msb"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb snapshot create --from-sandbox mybox --guest-flush auto -o $STUBDIR/rm\.msb"
  assert_regex "$log" 'msb remove --force mybox'
  refute_regex "$log" 'msb restore'
  assert_regex "$log" 'msb volume rm'
  assert_equal "$(acq_host_config_read msb mybox agent)" ""
  assert_equal "$(acq_workspace_record_read msb mybox)" ""
  assert_equal "$(acq_provenance_field msb mybox schema)" ""
  local kit_record
  kit_record=$(printf '%s' mybox | cksum | cut -d' ' -f1)
  [ ! -f "$STUBDIR/provenance/msb/mybox.${kit_record}.kits" ]
}

@test "msb: rm --snapshot refuses clone-backed workspaces without deleting them" {
  local clone="$STUBDIR/state/clones/mybox/workspace"
  mkdir -p "$clone"
  printf 'uncommitted work\n' > "$clone/sentinel"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" rm --snapshot mybox "$STUBDIR/rm.msb"
  assert_failure
  assert_output --partial "refusing clone-backed sandbox"
  [ -f "$clone/sentinel" ]
  refute_regex "$(cat "$CALLS")" 'msb snapshot create|msb remove'
}

@test "msb: snapshot refuses clone-backed workspaces before writing an archive" {
  local clone="$STUBDIR/state/clones/mybox/workspace"
  mkdir -p "$clone"
  printf 'uncommitted work\n' > "$clone/sentinel"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" snapshot mybox "$STUBDIR/snapshot.msb"
  assert_failure
  assert_output --partial "refusing clone-backed sandbox"
  [ -f "$clone/sentinel" ]
  refute_regex "$(cat "$CALLS")" 'msb snapshot create'
}

@test "msb: recreate refuses clone-backed workspaces before removal" {
  local clone="$STUBDIR/state/clones/mybox/workspace"
  mkdir -p "$clone"
  printf 'uncommitted work\n' > "$clone/sentinel"
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" recreate mybox "$STUBDIR/recreate.msb"
  assert_failure
  assert_output --partial "refusing clone-backed sandbox"
  [ -f "$clone/sentinel" ]
  refute_regex "$(cat "$CALLS")" 'msb snapshot create|msb remove'
}

@test "msb: restore clears conflicting environment extra kits when snapshot has none" {
  : > "$STUBDIR/saved.msb"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_EXTRA_KITS=conflicting-kit "$ACQ" restore restored "$STUBDIR/saved.msb"
  assert_success
  refute_regex "$(cat "$CALLS")" 'conflicting-kit'
}

@test "msb: strict restore kit heal fails for an extra kit apply failure" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_fetch_kit() { printf "/tmp/%s\n" "$1"; }
    _acq_msb_merge_kit_env_into() { eval "$1=()"; }
    _acq_msb_reset_kit_env() { :; }
    _acq_msb_apply_kit_dir() { [ "$2" != /tmp/extra ]; }
    _acq_msb_heal_kit_set box 1 --strict builtin extra
  '
  assert_failure
}

@test "msb: ls/stop/rm/exec dispatch to the msb verbs (exec as agent user)" {
  run env ACQ_BACKEND=msb "$ACQ" ls
  assert_regex "$(cat "$CALLS")" 'msb list'
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" stop mybox
  assert_regex "$(cat "$CALLS")" 'msb stop mybox'
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" rm mybox
  assert_regex "$(cat "$CALLS")" 'msb remove --force mybox'
  : > "$CALLS"
  # Neutralize the host git identity (HOME/XDG config, EMAIL/GIT_* env) so the
  # exec line is the same on a dev machine with a global identity and in CI.
  run env -u EMAIL -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$STUBDIR/nohome" XDG_CONFIG_HOME="$STUBDIR/noconfig" GIT_CONFIG_NOSYSTEM=1 \
    ACQ_BACKEND=msb "$ACQ" exec mybox -- echo hi
  assert_regex "$(cat "$CALLS")" 'msb exec -u agent -e HOME=/home/agent -w /home/agent mybox -- echo hi'
}

@test "msb: version and backend list report the real msb version" {
  run env ACQ_BACKEND=msb "$ACQ" version
  assert_output --partial 'backend:     msb'
  assert_output --partial '0.6.9'
  run env "$ACQ" backend list
  assert_output --partial 'msb  v0.6.9'
  refute_output --partial 'Coming in 1.2.x'
}

@test "backend set/unset: persists a default then clears it (idempotent)" {
  run bash -c '
    export XDG_CONFIG_HOME="'"$STUBDIR"'/xdg"
    cfg="$XDG_CONFIG_HOME/acq/config.yaml"
    "'"$ACQ"'" backend set sbx >/dev/null 2>&1
    [ -f "$cfg" ] && grep -q "^backend: sbx" "$cfg" && printf "set=yes\n" || printf "set=no\n"
    "'"$ACQ"'" backend unset >/dev/null 2>&1
    [ -f "$cfg" ] && printf "file-after=present\n" || printf "file-after=gone\n"
    "'"$ACQ"'" backend unset >/dev/null 2>&1 && printf "unset-idempotent=yes\n" || printf "unset-idempotent=no\n"
  '
  assert_output --partial 'set=yes'
  assert_output --partial 'file-after=gone'
  assert_output --partial 'unset-idempotent=yes'
}

@test "msb: doctor shows the installed msb version, not the old placeholder" {
  run bash -c 'printf "n\n" | "$1" doctor' _ "$ACQ"
  assert_output --partial 'msb: installed v0.6.9'
  refute_output --partial 'coming in 1.2.x'
}

@test "msb: acq_backend_prepare is silent on a ready host" {
  _with_adapter msb 'out=$(acq_backend_prepare 2>&1); printf "%s" "$out"'
  refute_output --partial "isn't ready"
}

@test "msb: prepare auto-runs 'msb doctor --fix' (announced) and stays silent on success" {
  _with_adapter msb 'STUB_MSB_DOCTOR_FIXABLE=1 acq_backend_prepare 2>&1'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb doctor --fix'
  assert_output --partial "running 'msb doctor --fix'"
  assert_output --partial 'ACQ_SKIP_MSB_DOCTOR=1'
  refute_output --partial "isn't ready"
}

@test "msb: an unfit, unfixable host surfaces one actionable message, no hard-fail" {
  _with_adapter msb 'out=$(STUB_MSB_DOCTOR_UNFIT=1 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial "isn't ready to run microVMs"
  assert_output --partial 'agentic-coding@gsa.gov'
  assert_output --partial 'RC=0'
}

@test "msb: ACQ_SKIP_MSB_DOCTOR=1 opts out of the readiness check" {
  _with_adapter msb 'STUB_MSB_DOCTOR_UNFIT=1 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1'
  refute_output --partial "isn't ready"
  refute_regex "$(cat "$CALLS")" 'msb doctor'
}

@test "msb: version floor rejects sub-0.6.9, accepts 0.6.9" {
  # acq_backend_prepare `exit`s on the floor violation, so run it in a command
  # substitution (a subshell) to keep this shell alive to report RC.
  _with_adapter msb 'out=$(STUB_MSB_VERSION=0.6.8 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial '0.6.9'
  assert_output --partial 'RC=1'
  _with_adapter msb 'out=$(STUB_MSB_VERSION=0.6.9 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); printf "%s\nRC=%s\n" "$out" "$?"'
  assert_output --partial 'RC=0'
}

@test "msb: rejects blocked 0.7.0 through 0.7.2 but accepts 0.7.3" {
  for version in 0.7.0 0.7.1 0.7.2; do
    _with_adapter msb "out=\$(STUB_MSB_VERSION=$version ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); rc=\$?; printf \"%s\\nRC=%s\\n\" \"\$out\" \"\$rc\""
    assert_output --partial "refuses msb $version"
    assert_output --partial '0.7.0-0.7.2'
    assert_output --partial 'RC=1'
  done
  _with_adapter msb 'out=$(STUB_MSB_VERSION=0.7.3 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); printf "%s\nRC=%s\n" "$out" "$?"'
  assert_output --partial 'RC=0'
}

@test "msb: unparseable version output fails closed with diagnostics" {
  _with_adapter msb 'out=$(STUB_MSB_VERSION=dev-build ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial 'could not determine a supported final msb version'
  assert_output --partial 'unparseable'
  assert_output --partial 'RC=1'
}

@test "msb: failed version probe fails closed even with parseable output" {
  _with_adapter msb 'out=$(STUB_MSB_VERSION=0.7.3 STUB_MSB_VERSION_RC=42 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial 'could not determine a supported final msb version'
  assert_output --partial 'RC=1'
}

@test "msb: prerelease versions do not satisfy the fixed final release" {
  _with_adapter msb 'out=$(STUB_MSB_VERSION=0.7.3-rc1 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial 'could not determine a supported final msb version'
  assert_output --partial 'prerelease'
  assert_output --partial 'RC=1'
}

@test "sbx: version floor rejects sub-0.39.0 naming both causes, accepts 0.39.0" {
  # 0.38.x is BELOW the floor: acq emits the ACQ_WORKSPACE marker through
  # `sbx create --env` on every workspace create, and --env only exists from
  # sbx 0.39.0 — an unknown flag fails the whole create, not just the marker.
  # Same subshell isolation as the msb floor test: prepare `exit`s on violation.
  _with_adapter sbx 'out=$(STUB_SBX_VERSION=0.38.0 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial '0.39.0'
  assert_output --partial '--env'
  assert_output --partial 'RC=1'
  _with_adapter sbx 'out=$(STUB_SBX_VERSION=0.37.9 acq_backend_prepare 2>&1); rc=$?; printf "%s\nRC=%s\n" "$out" "$rc"'
  assert_output --partial 'v2 kit grammar'
  assert_output --partial 'RC=1'
  _with_adapter sbx 'out=$(STUB_SBX_VERSION=0.39.0 acq_backend_prepare 2>&1); printf "%s\nRC=%s\n" "$out" "$?"'
  assert_output --partial 'RC=0'
  refute_output --partial 'requires sbx'
}

@test "msb: the doctor calls redirect stdin so a prompting doctor cannot hang acq" {
  if ! command -v timeout >/dev/null 2>&1; then skip "no 'timeout' available"; fi
  local hang_rc=0
  { sleep 30; } | timeout 8 bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    STUB_MSB_DOCTOR_FIXABLE=1 STUB_MSB_DOCTOR_READS_STDIN=1 acq_backend_prepare
  ' >/dev/null 2>&1 || hang_rc=$?
  # 124 == timed out == the redirect regression.
  assert_not_equal "$hang_rc" "124"
}

@test "msb: secret set usai/github store in the acq store and confirm" {
  run bash -c 'ACQ_SECRET_TEST_VALUE="my-usai-key" ACQ_BACKEND=msb "$1" secret set -g usai' _ "$ACQ"
  assert_output --partial 'acq secret store'
  assert [ -f "$STUBDIR/secrets/acq.usai" ]
  run bash -c 'ACQ_SECRET_TEST_VALUE="ghp_x" ACQ_BACKEND=msb "$1" secret set -g github' _ "$ACQ"
  assert_output --partial 'acq secret store'
  assert [ -f "$STUBDIR/secrets/acq.github" ]
}

@test "msb: restore keeps an explicit provider selection through the kit heal" {
  mkdir -p "$STUBDIR/secrets" "$STUBDIR/ws" "$STUBDIR/provenance/msb" "$STUBDIR/state/msb-snapshots" "$STUBDIR/prov-kit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: prov-kit\ndisplayName: Prov\ndescription: prov\n' > "$STUBDIR/prov-kit/spec.yaml"
  : > "$STUBDIR/psel.msb"
  printf 'agent\topencode\nprovider-selection\texplicit\nprovider-kits\t%s\n' "$STUBDIR/prov-kit" \
    > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/psel.msb").state"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" "$ACQ" restore pselbox "$STUBDIR/psel.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb restore .* --name pselbox '
  local prov; prov=$(cat "$STUBDIR/provenance/msb/pselbox."*.env)
  assert_regex "$prov" 'provider_selection=explicit'
  assert_regex "$prov" "provider_kits=$STUBDIR/prov-kit"
}

@test "msb: restore of a default-selection snapshot heals to the default selection" {
  mkdir -p "$STUBDIR/provenance/msb" "$STUBDIR/state/msb-snapshots"
  : > "$STUBDIR/pdef.msb"
  printf 'agent\topencode\nprovider-selection\tdefault\nprovider-kits\t\n' \
    > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/pdef.msb").state"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" "$ACQ" restore pdefbox "$STUBDIR/pdef.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb restore .* --name pdefbox '
  local prov
  prov=$(cat "$STUBDIR"/provenance/msb/pdefbox.*.env 2>/dev/null) || prov=""
  refute_regex "$prov" 'provider_selection=explicit'
}

# Seed the four kinds of name-scoped metadata a previous incarnation of the
# destination can leave behind (resources, CLI kits, provenance, host config).
_seed_retained_restore_metadata() { # NAME
  local n="$1" sum
  sum=$(printf '%s' "$n" | cksum | cut -d' ' -f1)
  mkdir -p "$STUBDIR/state/msb-restore" "$STUBDIR/provenance/msb"
  printf 'volume\t%s:%s\n' "$STUBDIR/old-ws" "$STUBDIR/old-ws" > "$STUBDIR/state/msb-restore/$n.resources"
  printf 'schema=1\nkit=/retained/kit\n' > "$STUBDIR/provenance/msb/$n.$sum.kits"
  printf 'schema=1\nbackend=msb\nagent=opencode\nretained=yes\n' > "$STUBDIR/provenance/msb/$n.$sum.env"
  acq_host_config_write msb "$n" agent opencode
}

@test "msb: backend rejection of the archive preserves retained destination metadata" {
  : > "$STUBDIR/rejected.msb"
  mkdir -p "$STUBDIR/provenance/msb"
  export ACQ_PROVENANCE_DIR="$STUBDIR/provenance"
  _seed_retained_restore_metadata rejbox
  local sum; sum=$(printf '%s' rejbox | cksum | cut -d' ' -f1)
  : > "$CALLS"
  run env ACQ_BACKEND=msb STUB_MSB_RESTORE_FAIL=17 "$ACQ" restore rejbox "$STUBDIR/rejected.msb"
  assert_failure 17
  assert_regex "$(cat "$CALLS")" 'msb restore .* --name rejbox '
  assert [ -f "$STUBDIR/state/msb-restore/rejbox.resources" ]
  assert_regex "$(cat "$STUBDIR/state/msb-restore/rejbox.resources")" "$STUBDIR/old-ws"
  assert_regex "$(cat "$STUBDIR/provenance/msb/rejbox.$sum.kits")" '/retained/kit'
  assert_regex "$(cat "$STUBDIR/provenance/msb/rejbox.$sum.env")" 'retained=yes'
  assert_equal "$(acq_host_config_read msb rejbox agent)" opencode
  # No staged archive is left behind either.
  run bash -c 'ls -A "$1"/state/msb-snapshots 2>/dev/null | grep -c "^\.restore\."' _ "$STUBDIR"
  assert_output 0
}

@test "msb: restore runs the backend under the destination lifecycle lock" {
  : > "$STUBDIR/locked.msb"
  mkdir -p "$STUBDIR/provenance/msb"
  local sum; sum=$(printf '%s' lockrest | cksum | cut -d' ' -f1)
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" \
    STUB_MSB_RESTORE_LOCK_DIR="$STUBDIR/provenance/provider-input/msb/lockrest.$sum.lock" \
    "$ACQ" restore lockrest "$STUBDIR/locked.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" 'restore-lock-held'
  assert [ ! -e "$STUBDIR/provenance/provider-input/msb/lockrest.$sum.lock" ]
}

@test "msb: restore refuses while another lifecycle operation holds the destination lock" {
  : > "$STUBDIR/busy.msb"
  mkdir -p "$STUBDIR/provenance/msb"
  _seed_retained_restore_metadata busybox
  local sum lock
  sum=$(printf '%s' busybox | cksum | cut -d' ' -f1)
  lock="$STUBDIR/provenance/provider-input/msb/busybox.$sum.lock"
  mkdir -p "$lock"
  printf '%s %s\n' "$$" "$(ps -o lstart= -p $$ | tr -d '[:space:]')" > "$lock/owner"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 \
    "$ACQ" restore busybox "$STUBDIR/busy.msb"
  rm -f "$lock/owner"; rmdir "$lock"
  assert_failure
  refute_regex "$(cat "$CALLS")" 'msb restore'
  assert [ -f "$STUBDIR/state/msb-restore/busybox.resources" ]
}

@test "msb: restore binds credentials from the snapshot selection, not the caller's, when disabled" {
  mkdir -p "$STUBDIR/secrets" "$STUBDIR/state/msb-snapshots"
  printf 'sk-stored\n' > "$STUBDIR/secrets/acq.usai"
  : > "$STUBDIR/off.msb"
  printf 'agent\topencode\nprovider-selection\texplicit\nprovider-kits\t\n' \
    > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/off.msb").state"
  : > "$CALLS"
  # The caller's environment selects the default provider; the snapshot saved "none".
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" "$ACQ" restore offbox "$STUBDIR/off.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb restore .* --name offbox '
  refute_regex "$(cat "$CALLS")" 'msb restore .*--secret USAI_API_KEY@'
  refute_regex "$(cat "$CALLS")" 'USAI_API_KEY=present'
}

@test "msb: restore ignores retained destination provider facts when the snapshot disabled providers" {
  mkdir -p "$STUBDIR/secrets" "$STUBDIR/state/msb-snapshots" "$STUBDIR/provenance/msb"
  printf 'sk-stored\n' > "$STUBDIR/secrets/acq.usai"
  : > "$STUBDIR/off2.msb"
  printf 'agent\topencode\nprovider-selection\texplicit\nprovider-kits\t\n' \
    > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/off2.msb").state"
  # A retained provider-credentials record from the destination's previous life.
  export ACQ_PROVENANCE_DIR="$STUBDIR/provenance"
  acq_host_config_write msb factbox provider-credentials \
    "$(printf 'usai\tUSAI_API_KEY\tapi.gsa.usai.gov\thttps://api.gsa.usai.gov/api/v1/models\topenai')"
  assert [ -n "$(acq_host_config_read msb factbox provider-credentials)" ]
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" restore factbox "$STUBDIR/off2.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb restore .* --name factbox '
  refute_regex "$(cat "$CALLS")" 'msb restore .*--secret USAI_API_KEY@'
  refute_regex "$(cat "$CALLS")" 'USAI_API_KEY=present'
}

@test "msb: restore binds the default provider from a default snapshot despite a disabling caller" {
  mkdir -p "$STUBDIR/secrets" "$STUBDIR/state/msb-snapshots"
  printf 'sk-stored\n' > "$STUBDIR/secrets/acq.usai"
  : > "$STUBDIR/on.msb"
  printf 'agent\topencode\nprovider-selection\tdefault\nprovider-kits\t\n' \
    > "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/on.msb").state"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVIDER_KITS= ACQ_PROVENANCE_DIR="$STUBDIR/provenance" "$ACQ" restore onbox "$STUBDIR/on.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb restore .* --name onbox .*--secret USAI_API_KEY@api\.gsa\.usai\.gov'
}

@test "msb: restore with no stored or environment credentials works under set -u" {
  : > "$STUBDIR/nocred.msb"
  : > "$CALLS"
  # Explicit `bash` so the Bash 3.2 runner's PATH shim, not the shebang, decides
  # the interpreter; bash 3.2 rejects an unguarded empty-array expansion.
  run env -u USAI_API_KEY -u GITHUB_TOKEN -u GH_TOKEN ACQ_BACKEND=msb bash "$ACQ" restore nocredbox "$STUBDIR/nocred.msb"
  assert_success
  refute_output --partial 'unbound variable'
  assert_regex "$(cat "$CALLS")" 'msb restore .* --name nocredbox '
  refute_regex "$(cat "$CALLS")" 'msb restore .*--secret'
}

@test "msb: snapshot sidecar records the provider selection of the source sandbox" {
  mkdir -p "$STUBDIR/provenance/msb" "$STUBDIR/ws"
  local record
  record=$(printf '%s' selbox | cksum | cut -d' ' -f1)
  printf 'schema=1\nbackend=msb\nprovider_selection=explicit\nprovider_kits=%s\nagent=opencode\n' "$STUBDIR/prov-kit" \
    > "$STUBDIR/provenance/msb/selbox.${record}.env"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_PROVENANCE_DIR="$STUBDIR/provenance" "$ACQ" snapshot selbox "$STUBDIR/sel.msb"
  assert_success
  local state; state=$(cat "$STUBDIR/state/msb-snapshots/$(_sha256 "$STUBDIR/sel.msb").state")
  assert_regex "$state" $'provider-selection\texplicit'
  assert_regex "$state" $'provider-kits\t'"$STUBDIR/prov-kit"
}
