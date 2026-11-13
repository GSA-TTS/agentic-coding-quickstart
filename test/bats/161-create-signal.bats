#!/usr/bin/env bats
#
# 161-create-signal.bats — Ctrl-C (or SIGTERM, or SIGHUP) during `acq create`.
#
# The spinner composes its INT/TERM/EXIT traps over the provisioning subshell's
# (acq.backends/progress.sh). A terminal Ctrl-C reaches acq's whole process
# group while the backend `create` is still running, so the chained handlers must
# reap the backend child, run the uncreated-attempt cleanup exactly once, and
# still end with 130 (SIGINT), 143 (SIGTERM) or 129 (SIGHUP) rather than an
# arbitrary status.
#
# create-signal.py drives the real `acq create` against the stub backends with a
# blocking `create` and a PTY on stderr (so the spinner animates), signals once
# the backend child is registered, and asserts status and cleanup. No polling of
# timing-sensitive windows: every step waits on an observable marker.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "create: Ctrl-C, SIGTERM and SIGHUP with the spinner active clean up once and exit 130/143/129" {
  run python3 "$BATS_TEST_DIRNAME/create-signal.py" "$REPO_ROOT" "$STUBDIR" "$BASH"
  printf '%s\n' "$output"
  assert_success
  assert_line 'PASS sbx-sigint status 130'
  assert_line 'PASS msb-sigint status 130'
  # acq waits for the subshell's cleanup before it exits, as for Ctrl-C.
  assert_line 'PASS sbx-sigterm status 143'
  assert_line 'PASS msb-sigterm status 143'
  # A closed terminal (group SIGHUP) is handled the same way, with 129.
  assert_line 'PASS sbx-sighup status 129'
  assert_line 'PASS msb-sighup status 129'
  # A SIGTERM to acq's PID alone is not forwarded: provisioning finishes first.
  assert_line 'PASS sbx-sigterm-pid status 143'
  assert_line 'PASS msb-sigterm-pid status 143'
}

# spin-signal-window.py delivers SIGINT at fixed points of acq_spin_start (while
# the frames are chosen, while each prior trap is captured, before each spinner
# trap is installed, and while animating) and SIGKILLs the shell mid-animation.
# Each must leave no animator running and the cursor visible; the signal cases
# must also run the caller's INT and EXIT handlers exactly once and exit 130.
@test "spinner start: a signal at any point leaves no animator and restores the cursor" {
  run python3 "$BATS_TEST_DIRNAME/spin-signal-window.py" "$REPO_ROOT" "$BASH" "$STUBDIR"
  printf '%s\n' "$output"
  assert_success
  local point
  for point in frames capture install-exit install-int install-term running owner; do
    assert_line "PASS $point"
  done
}
