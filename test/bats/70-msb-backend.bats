#!/usr/bin/env bats
#
# 70-msb-backend.bats — bats port of scripts/test-acq.d/70-msb-backend.sh (ADR-0025)
#
# msb backend: resolution, dispatch, doctor/list/version, host-readiness +
# version-floor checks, and secret set into the acq store. Resolution/prepare
# unit checks source acq in a subshell; dispatch checks use the real CLI + $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
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

@test "msb: advertises SUPPORTS_SNAPSHOTS=1 because acq surfaces native snapshot/restore" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; printf "%s" "$ACQ_BACKEND_SUPPORTS_SNAPSHOTS"'
  assert_output '1'
}

@test "msb: snapshot maps to msb snapshot create --full with date-stamped default output" {
  run env ACQ_BACKEND=msb ACQ_SNAPSHOT_DIR="$STUBDIR/snapshots" "$ACQ" snapshot mybox
  assert_success
  assert_regex "$(cat "$CALLS")" "msb snapshot create --from-sandbox mybox --full --guest-flush auto -o $STUBDIR/snapshots/mybox-[0-9]{8}T[0-9]{6}Z\.msb"
  : > "$CALLS"
  mkdir -p "$STUBDIR/state/msb-restore"
  printf 'volume\t%s:%s\n' "$STUBDIR/ws" "$STUBDIR/ws" > "$STUBDIR/state/msb-restore/mybox.resources"
  run env ACQ_BACKEND=msb "$ACQ" snapshot mybox "$STUBDIR/mybox.msb"
  assert_success
  assert_regex "$(cat "$CALLS")" "msb snapshot create --from-sandbox mybox --full --guest-flush auto -o $STUBDIR/mybox\.msb"
  [ -f "$STUBDIR/mybox.msb.resources" ]
}

@test "msb: restore maps to msb restore with inherited resources and re-derived vsock" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  mkdir -p "$STUBDIR/secrets" "$STUBDIR/ws"
  printf 'sk-restored\n' > "$STUBDIR/secrets/acq.usai"
  printf 'volume\t%s:%s\n' "$STUBDIR/ws" "$STUBDIR/ws" > "$STUBDIR/saved.msb.resources"
  : > "$CALLS"
  run env ACQ_BACKEND=msb SSH_AUTH_SOCK="$STUBDIR/agent.sock" "$ACQ" restore restored "$STUBDIR/saved.msb"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb restore $STUBDIR/saved\.msb --name restored --dangerously-inherit-resources --disk-only --external-mount-policy relaxed --volume $STUBDIR/ws:$STUBDIR/ws --vsock $STUBDIR/agent\.sock:3552/stream"
  assert_regex "$log" 'USAI_API_KEY=present'
  assert_regex "$log" 'socat UNIX-LISTEN:'
  [ -f "$STUBDIR/state/msb-restore/restored.resources" ]
}

@test "msb: restore without a snapshot picks the newest date-stamped snapshot for the sandbox" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  mkdir -p "$STUBDIR/snapshots" "$STUBDIR/ws2"
  : > "$STUBDIR/snapshots/mybox-20260920T010203Z.msb"
  : > "$STUBDIR/snapshots/mybox-20260921T010203Z.msb"
  printf 'volume\t%s:%s\n' "$STUBDIR/ws2" "$STUBDIR/ws2" > "$STUBDIR/snapshots/mybox-20260921T010203Z.msb.resources"
  : > "$STUBDIR/snapshots/mybox-z-not-a-date.msb"
  : > "$STUBDIR/snapshots/other-20260922T010203Z.msb"
  : > "$CALLS"
  run env ACQ_BACKEND=msb ACQ_SNAPSHOT_DIR="$STUBDIR/snapshots" SSH_AUTH_SOCK="$STUBDIR/agent.sock" "$ACQ" restore mybox
  assert_success
  assert_regex "$(cat "$CALLS")" "msb restore $STUBDIR/snapshots/mybox-20260921T010203Z\.msb --name mybox"
}

@test "sbx: snapshot/restore/recreate are acq-owned unsupported verbs, not backend passthrough" {
  run env ACQ_BACKEND=sbx "$ACQ" snapshot mybox
  assert_failure
  assert_output --partial 'does not support stateful snapshots'
  refute_regex "$(cat "$CALLS")" 'sbx snapshot'
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" restore restored "$STUBDIR/saved.sbx"
  assert_failure
  assert_output --partial 'does not support stateful restore'
  refute_regex "$(cat "$CALLS")" 'sbx restore'
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" recreate mybox
  assert_failure
  assert_output --partial 'does not support stateful recreate'
  refute_regex "$(cat "$CALLS")" 'sbx snapshot|sbx restore'
}

@test "msb: recreate snapshots, removes, then restores to the same name" {
  _mk_unix_socket "$STUBDIR/agent.sock" || skip "python3 AF_UNIX socket unavailable"
  : > "$CALLS"
  run env ACQ_BACKEND=msb SSH_AUTH_SOCK="$STUBDIR/agent.sock" "$ACQ" recreate mybox "$STUBDIR/recreate.msb"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb snapshot create --from-sandbox mybox --full --guest-flush auto -o $STUBDIR/recreate\.msb"
  assert_regex "$log" 'msb remove --force mybox'
  refute_regex "$log" 'msb volume rm'
  assert_regex "$log" "msb restore $STUBDIR/recreate\.msb --name mybox --dangerously-inherit-resources --vsock $STUBDIR/agent\.sock:3552/stream"
}

@test "msb: rm --snapshot snapshots before removing and does not restore" {
  : > "$CALLS"
  run env ACQ_BACKEND=msb "$ACQ" rm --snapshot mybox "$STUBDIR/rm.msb"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "msb snapshot create --from-sandbox mybox --full --guest-flush auto -o $STUBDIR/rm\.msb"
  assert_regex "$log" 'msb remove --force mybox'
  refute_regex "$log" 'msb restore'
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
