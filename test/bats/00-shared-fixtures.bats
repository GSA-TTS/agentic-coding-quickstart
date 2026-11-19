#!/usr/bin/env bats
# Shared specs must stay readable while another worker initializes its fixtures.
# shellcheck shell=bats

load 'helper'

@test "shared fixtures: readers see complete specs during another worker's writes" {
  run bash -c '
    printf() {
      case "$*" in
        *hybrid/v1*)
          : > "$BATS_TEST_TMPDIR/write-intercepted"
          local spec
          for spec in "$BATS_RUN_TMPDIR/acq-offline-kit/spec.yaml" \
                      "$BATS_RUN_TMPDIR/acq-opencode-kit/spec.yaml"; do
            if ! grep -q "schemaVersion:" "$spec"; then
              echo "reader observed an incomplete shared spec" >&2
              exit 91
            fi
          done
          ;;
      esac
      builtin printf "$@"
    }
    # Redirection happens before printf: inspect the published paths at the
    # exact write boundary instead of relying on scheduler timing to hit it.
    source "$1/scripts/test-acq-lib.sh"
    [ -f "$BATS_TEST_TMPDIR/write-intercepted" ] || exit 94
  ' _ "$REPO_ROOT"
  assert_success
}

@test "shared fixtures: helper reload preserves published file identity and bytes" {
  run bash -c '
    for dir in acq-offline-kit acq-opencode-kit; do
      ln "$BATS_RUN_TMPDIR/$dir/spec.yaml" "$BATS_TEST_TMPDIR/$dir.before"
    done
    source "$1/scripts/test-acq-lib.sh"
    for dir in acq-offline-kit acq-opencode-kit; do
      [ "$BATS_RUN_TMPDIR/$dir/spec.yaml" -ef "$BATS_TEST_TMPDIR/$dir.before" ] || exit 92
      cmp "$BATS_RUN_TMPDIR/$dir/spec.yaml" "$BATS_TEST_TMPDIR/$dir.before" || exit 93
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
