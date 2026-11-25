#!/usr/bin/env bats
# Each test owns its offline kit specs (under its private stub dir), published once
# and never replaced, so a concurrent copy never sees a changed file (#721).
# shellcheck shell=bats

load 'helper'

@test "shared fixtures: a repeated publication keeps the stub's file identity and bytes" {
  run bash -c '
    source "$1/scripts/test-acq-lib.sh" || exit 97
    make_stubs || exit 98
    trap cleanup_stubs EXIT
    for dir in acq-offline-kit acq-opencode-kit; do
      ln "$STUBDIR/$dir/spec.yaml" "$BATS_TEST_TMPDIR/$dir.before" || exit 95
      cp "$STUBDIR/$dir/spec.yaml" "$BATS_TEST_TMPDIR/$dir.bytes" || exit 96
    done
    _acq_test_offline_kits || exit 99
    for dir in acq-offline-kit acq-opencode-kit; do
      [ "$STUBDIR/$dir/spec.yaml" -ef "$BATS_TEST_TMPDIR/$dir.before" ] || exit 92
      cmp "$STUBDIR/$dir/spec.yaml" "$BATS_TEST_TMPDIR/$dir.bytes" || exit 93
    done
  ' _ "$REPO_ROOT"
  assert_success
}

@test "shared fixtures: conflicting existing content is refused without replacement" {
  local target="$BATS_TEST_TMPDIR/conflicting-spec"
  printf 'original\n' > "$target"
  run _acq_test_publish_spec "$target" $'different\n'
  assert_failure
  [ "$(cat "$target")" = original ]
}

@test "shared fixtures: directory and symlink destinations are refused without writes" {
  local directory="$BATS_TEST_TMPDIR/destination" link="$BATS_TEST_TMPDIR/link"
  mkdir "$directory"
  ln -s "$directory" "$link"
  run _acq_test_publish_spec "$directory" $'content\n'
  assert_failure
  run _acq_test_publish_spec "$link" $'content\n'
  assert_failure
  [ -z "$(ls -A "$directory")" ]
  [ -L "$link" ]
}

# The stub setup must keep acq's caches away from the developer's own, even when
# their shell exports cache locations: generated kits (sbx startup-barrier specs)
# otherwise pile up in the real ~/.cache.
@test "stub setup: the XDG cache and both kit caches are inside the stub dir" {
  run env XDG_CACHE_HOME=/nonexistent/dev-cache ACQ_SBX_KIT_CACHE=/nonexistent/dev-sbx-kits \
    ACQ_MSB_KIT_CACHE=/nonexistent/dev-msb-kits bash -c '
      source "$1/scripts/test-acq-lib.sh"
      make_stubs
      printf "%s\n" "$STUBDIR" "$XDG_CACHE_HOME" "$ACQ_SBX_KIT_CACHE" "$ACQ_MSB_KIT_CACHE"
      cleanup_stubs
    ' _ "$REPO_ROOT"
  assert_success
  local stub="${lines[0]}"
  [ -n "$stub" ]
  assert_line --index 1 "$stub/home/.cache"
  assert_line --index 2 "$stub/home/.cache/acq/sbx-kits"
  assert_line --index 3 "$stub/home/.cache/acq/kits"
}
