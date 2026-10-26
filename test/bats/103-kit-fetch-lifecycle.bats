#!/usr/bin/env bats
# shellcheck shell=bats

@test "kit fetch lifecycle: foreground identity, cleanup, exec, traps, signals and nesting" {
  run python3 "$BATS_TEST_DIRNAME/kit-fetch-lifecycle.py" \
    "$BATS_TEST_DIRNAME/../.." "$BATS_TEST_TMPDIR" "$BASH"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
