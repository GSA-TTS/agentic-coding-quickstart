#!/usr/bin/env bats
# shellcheck shell=bats

@test "kit fetch lifecycle: foreground identity, cleanup, exec, traps, signals and nesting" {
  run python3 "$BATS_TEST_DIRNAME/kit-fetch-lifecycle.py" \
    "$BATS_TEST_DIRNAME/../.." "$BATS_TEST_TMPDIR" "${ACQ_BASH32_LAUNCHER:-$BASH}"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
