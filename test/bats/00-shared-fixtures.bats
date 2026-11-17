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
