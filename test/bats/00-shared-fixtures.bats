#!/usr/bin/env bats
# Shared specs must stay readable while another worker initializes its fixtures.
# shellcheck shell=bats

load 'helper'

@test "shared fixtures: readers see complete specs during another worker's writes" {
  run bash -c '
    printf() {
      case "$1" in
        *hybrid/v1*)
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
  ' _ "$REPO_ROOT"
  assert_success
}
