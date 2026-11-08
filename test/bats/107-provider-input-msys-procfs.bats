#!/usr/bin/env bats
# shellcheck shell=bats

@test "provider-input guardian and lock identity work without ps -o via the MSYS procfs (Git Bash)" {
  [ -d /proc/self ] || skip "needs a Linux /proc to emulate the MSYS layout from"
  run python3 "$BATS_TEST_DIRNAME/provider-input-msys-procfs.py" \
    "$BATS_TEST_DIRNAME/../.." "$BATS_TEST_TMPDIR" "$BASH"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
