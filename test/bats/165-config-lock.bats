#!/usr/bin/env bats
#
# 165-config-lock.bats — Bash takes the config.yaml lock it shares with the
# Python acq.
#
# WHY THIS EXISTS
#
# Both implementations rewrite the whole config.yaml to change one key. Python
# serializes that read-modify-write with an OS lock Bash cannot take, so both
# also take the directory <state>/locks/config.lock.d (common.sh
# _acq_config_lock_acquire, Python lock.ConfigDirLock). Without it a Bash
# `backend set` and a Python `configure` at once could lose one change. The
# Python side, and the two together, are covered in py-acq/tests/test_config.py.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  export ACQ_STATE_DIR="$STUBDIR/state"
  LOCK="$ACQ_STATE_DIR/locks/config.lock.d"
  mkdir -p "$ACQ_STATE_DIR/locks"
}
teardown() { acq_teardown_stubs; }

load 'helper'

# _cfg SCRIPT — run SCRIPT in a fresh shell with acq's definitions loaded.
_cfg() {
  run bash -c 'ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1; shift; eval "$1"' bash "$ACQ" "$@"
}

# _hold OWNER — leave the lock directory as another command would.
_hold() {
  mkdir "$LOCK"
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1" > "$LOCK/owner"
  fi
}

_backend() {
  _cfg '_acq_config_read_field backend'
}

# _posix_only REASON — skip under Git Bash. There the directory's age, not its
# owner's PID, decides (the Windows test below covers that rule on every host).
_posix_only() {
  case "${OSTYPE:-}" in
    msys*|cygwin*) skip "$1" ;;
  esac
}

@test "config lock: a write holds the lock, owned by the writing shell, and releases it" {
  _cfg '_acq_config_write_field_locked() { cat "$ACQ_STATE_DIR/locks/config.lock.d/owner"; echo "self=$(exec sh -c "echo \$PPID")"; }
        _acq_config_write_field backend msb'
  assert_success
  owner_pid=$(printf '%s\n' "$output" | sed -n '1s/ .*//p')
  assert_line "self=$owner_pid"
  [ ! -e "$LOCK" ]
}

@test "config lock: a live holder makes the write wait, then fail with the recovery command" {
  _cfg '_acq_config_write_field backend sbx'
  assert_success
  # The bats shell is alive, so an owner line naming it is a live holder.
  _hold "$$ $(_acq_provider_input_process_identity "$$")"
  ACQ_MIGRATION_LOCK_TIMEOUT=0.4 _cfg '_acq_config_write_field backend msb'
  assert_failure
  assert_output --partial "could not take the config.yaml lock within 0.4s; another acq command holds $LOCK"
  assert_output --partial "rm -f -- '$LOCK/owner' && rmdir -- '$LOCK'"
  assert_output --partial "(see docs/KNOWN_FAILURE_MODES.md, section 79)"
  [ -d "$LOCK" ]
  _backend
  assert_output 'sbx'
}

@test "config lock: a directory with no owner is never removed, and the recovery command clears it" {
  _hold ""
  ACQ_MIGRATION_LOCK_TIMEOUT=0.2 _cfg '_acq_config_write_field backend msb'
  assert_failure
  [ -d "$LOCK" ]
  rm -f -- "$LOCK/owner" && rmdir -- "$LOCK"
  _cfg '_acq_config_write_field backend msb'
  assert_success
  _backend
  assert_output 'msb'
}

@test "config lock: a holder that exited is recovered" {
  _posix_only "Git Bash judges the config lock by its age"
  sh -c 'exit 0' &
  dead=$!
  wait "$dead" || true
  _hold "$dead Thu1Jan00:00:001970"
  ACQ_MIGRATION_LOCK_TIMEOUT=0 _cfg '_acq_config_write_field backend msb'
  assert_success
  [ ! -e "$LOCK" ]
  _backend
  assert_output 'msb'
}

@test "config lock: a reused PID (different identity) is recovered" {
  _posix_only "Git Bash judges the config lock by its age"
  _hold "$$ not-the-identity-of-this-process"
  ACQ_MIGRATION_LOCK_TIMEOUT=0 _cfg '_acq_config_write_field backend msb'
  assert_success
  [ ! -e "$LOCK" ]
}

@test "config lock: a symlinked lock is refused, never followed" {
  _posix_only "Git Bash's ln -s copies unless native symlinks are enabled"
  mkdir "$STUBDIR/elsewhere"
  ln -s "$STUBDIR/elsewhere" "$LOCK"
  ACQ_MIGRATION_LOCK_TIMEOUT=0 _cfg '_acq_config_write_field backend msb'
  assert_failure
  assert_output --partial "unsafe config.yaml lock: $LOCK"
  [ -z "$(ls -A "$STUBDIR/elsewhere")" ]
}

@test "config lock: a file in place of the lock directory is refused" {
  : > "$LOCK"
  ACQ_MIGRATION_LOCK_TIMEOUT=0 _cfg '_acq_config_write_field backend msb'
  assert_failure
  assert_output --partial "unsafe config.yaml lock: $LOCK (not a directory)"
  [ -f "$LOCK" ] && [ ! -s "$LOCK" ]
}

@test "config lock: losing the owner-file race never removes the winner's owner" {
  # mkdir is not atomic in every coreutils (uutils mkdir reports success to
  # concurrent callers), so the exclusive owner-file create decides. Here the
  # directory and the winner's owner already exist when this take runs.
  _hold "$$ $(_acq_provider_input_process_identity "$$")"
  _cfg 'mkdir() { return 0; }; _acq_config_lock_take "$ACQ_STATE_DIR/locks/config.lock.d" "1 x"'
  assert_failure
  run cat "$LOCK/owner"
  assert_output "$$ $(_acq_provider_input_process_identity "$$")"
}

@test "config lock: on Windows a fresh directory is held and an old one recovered" {
  # Neither Git Bash nor native Python can check the other's PID there, so the
  # directory's age decides (_ACQ_CONFIG_LOCK_WINDOWS_STALE_S).
  _hold "4242 unverified"
  ACQ_MIGRATION_LOCK_TIMEOUT=0.2 _cfg 'OSTYPE=msys; _acq_config_write_field backend msb'
  assert_failure
  assert_output --partial "could not take the config.yaml lock"
  touch -t 202001010000 "$LOCK"
  ACQ_MIGRATION_LOCK_TIMEOUT=0.2 _cfg 'OSTYPE=msys; _acq_config_write_field backend msb'
  assert_success
  [ ! -e "$LOCK" ]
}

# _bash_writer ID COUNT — write key bID COUNT times, failing on the first error.
_bash_writer() {
  timeout 600 bash -c 'ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1
    i=1
    while [ "$i" -le "$3" ]; do
      _acq_config_write_field "b$2" "$i" || { echo "bash writer $2 failed at write $i" >&2; exit 1; }
      i=$((i + 1))
    done' bash "$ACQ" "$1" "$2"
}

# _wait_writers LOG PID... — wait for every writer; fail if any did.
_wait_writers() {
  local log="$1" pid rc=0
  shift
  for pid in "$@"; do
    wait "$pid" || rc=1
  done
  [ "$rc" -eq 0 ] || { echo "a writer failed or ran out of time:" >&2; cat "$log" >&2; return 1; }
}

@test "config lock: parallel Bash writers all succeed and lose no change" {
  # A holder that releases between a waiter's failed mkdir and its look at the
  # directory must make the waiter try again, never report an unsafe lock.
  export ACQ_MIGRATION_LOCK_TIMEOUT=60
  local log="$STUBDIR/writers.log" pids="" id ids="1 2 3 4 5 6" writes=30
  # Process creation is slow under Git Bash, so fewer writers and writes there.
  case "${OSTYPE:-}" in msys*|cygwin*) ids="1 2 3" writes=6 ;; esac
  for id in $ids; do
    _bash_writer "$id" "$writes" 2>>"$log" &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  _wait_writers "$log" $pids
  run grep -c unsafe "$log"
  assert_output 0
  for id in $ids; do
    _cfg "_acq_config_read_field b$id"
    assert_output "$writes"
  done
  [ ! -e "$LOCK" ]
}

@test "config lock: parallel Bash and Python writers all succeed and lose no change" {
  _posix_only "native Windows Python is checked by the Windows interop run"
  command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' ||
    skip "needs python3 >= 3.12 for the Python acq"
  export ACQ_MIGRATION_LOCK_TIMEOUT=60
  local log="$STUBDIR/writers.log" pids="" id
  for id in 1 2 3; do
    _bash_writer "$id" 25 2>>"$log" &
    pids="$pids $!"
    PYTHONPATH="$REPO_ROOT/py-acq/src" timeout 120 python3 -c '
import sys
from acq_py import config
for i in range(1, 26):
    config.write_field("p" + sys.argv[1], str(i))
' "$id" 2>>"$log" &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  _wait_writers "$log" $pids
  for id in 1 2 3; do
    _cfg "_acq_config_read_field b$id; _acq_config_read_field p$id"
    assert_output $'25\n25'
  done
  [ ! -e "$LOCK" ]
}

@test "config lock: an invalid wait falls back to the default bound" {
  _cfg 'ACQ_MIGRATION_LOCK_TIMEOUT=1.2 _acq_config_lock_ticks
        ACQ_MIGRATION_LOCK_TIMEOUT=abc _acq_config_lock_ticks
        ACQ_MIGRATION_LOCK_TIMEOUT=1.2.3 _acq_config_lock_ticks'
  assert_success
  assert_output $'6\n25\n25'
}
