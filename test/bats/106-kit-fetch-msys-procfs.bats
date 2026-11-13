#!/usr/bin/env bats
# shellcheck shell=bats

@test "kit fetch guardian: survives a ps without -o via the MSYS procfs (Git Bash)" {
  [ -d /proc/self ] || skip "needs a Linux /proc to emulate the MSYS layout from"
  run python3 "$BATS_TEST_DIRNAME/kit-fetch-msys-procfs.py" \
    "$BATS_TEST_DIRNAME/../.." "$BATS_TEST_TMPDIR" "$BASH"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
