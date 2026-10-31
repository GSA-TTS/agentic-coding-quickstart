#!/usr/bin/env bats
# shellcheck shell=bats

# The Windows path guard (ADR-0038) vets each opened component against the
# vetted parent's resolved name. The comparison is pure once attributes and
# resolved names are supplied, so it is exercised here on any host with a fake
# volume. This does not prove what Windows reports for a short (8.3) name.

@test "path guard: component vetting accepts 8.3 aliases and rejects redirects" {
  run python3 "$BATS_TEST_DIRNAME/provider-input-pathguard-vet.py" \
    "$BATS_TEST_DIRNAME/../.."
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
