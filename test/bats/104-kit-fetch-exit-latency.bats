#!/usr/bin/env bats
# shellcheck shell=bats

load 'helper'

# The guardian's stderr is discarded, so a guardian that dies before it writes
# its ready file must not leave acq exiting 1 with no message at all. A `sh`
# that exits at once stands in for a guardian that cannot start (the guardian
# is the only thing acq runs through `sh` before it is ready).
@test "kit fetch guardian: one that dies before it is ready is reported" {
  acq_setup_stubs
  mkdir -p "$BATS_TEST_TMPDIR/deadsh"
  printf '#!/bin/bash\nexit 1\n' > "$BATS_TEST_TMPDIR/deadsh/sh"
  chmod +x "$BATS_TEST_TMPDIR/deadsh/sh"
  PATH="$BATS_TEST_TMPDIR/deadsh:$PATH" run "$BASH" "$REPO_ROOT/acq" version
  acq_teardown_stubs
  assert_failure 1
  assert_output --partial 'acq: the kit-fetch cleanup helper exited before it was ready'
}

@test "kit fetch guardian: exit is not delayed by the tick and nothing outlives the owner" {
  run python3 "$BATS_TEST_DIRNAME/kit-fetch-exit-latency.py" \
    "$BATS_TEST_DIRNAME/../.." "$BATS_TEST_TMPDIR" "$BASH"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
