#!/usr/bin/env bats
#
# 164-rm-signal.bats — SIGTERM, SIGHUP or Ctrl-C during `acq rm`.
#
# The terminate step runs in a subshell that holds the sandbox lock and the
# backend remove, with its own HUP/INT/TERM cleanup. acq runs it through
# acq_run_signal_deferred (acq.backends/progress.sh), as it runs create, so a
# signal to acq's process group ends acq only after that cleanup: the backend
# child reaped and the lock released, then 143, 129 or 130.
#
# rm-signal.py drives the real `acq rm` against the stub backends with a
# blocking remove, signals the group once the backend child is registered, and
# asserts status and cleanup. Every step waits on an observable marker.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "rm: a group SIGTERM, SIGHUP or Ctrl-C exits only after the terminate cleanup, with 128+N" {
  run python3 "$BATS_TEST_DIRNAME/rm-signal.py" "$REPO_ROOT" "$STUBDIR" "$BASH"
  printf '%s\n' "$output"
  assert_success
  local backend
  for backend in sbx msb; do
    assert_line "PASS rm-$backend-sigterm status 143"
    assert_line "PASS rm-$backend-sighup status 129"
    assert_line "PASS rm-$backend-sigint status 130"
  done
}
