#!/usr/bin/env bats
# shellcheck shell=bats

@test "kit fetch guardian: exit is not delayed by the tick and nothing outlives the owner" {
  run python3 "$BATS_TEST_DIRNAME/kit-fetch-exit-latency.py" \
    "$BATS_TEST_DIRNAME/../.." "$BATS_TEST_TMPDIR" "$BASH"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
