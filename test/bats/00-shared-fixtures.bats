#!/usr/bin/env bats
# Shared specs must stay readable while another worker initializes its fixtures.
# shellcheck shell=bats

load 'helper'

teardown() { acq_teardown_stubs; }

@test "provider boundary: load_acq stays offline after common loads" {
  acq_setup_stubs
  _acq_provider_input_control_plane() { echo 'unexpected release fetch' >&2; return 91; }
  run acq_provider_input_prepare sbx offlinebox
  assert_success
  [[ "$output" == */generations/generation.test.* ]]
}

@test "provider boundary: child common load stays offline and preserves later overrides" {
  acq_setup_stubs
  run bash -c '
    source "$ACQ_SCRIPT_DIR/acq.backends/common.sh"
    _acq_provider_input_control_plane() { echo "unexpected release fetch" >&2; return 91; }
    generation=$(acq_provider_input_prepare msb childbox) || exit
    [[ "$generation" == */generations/generation.test.* ]] || exit 92
    acq_provider_input_prepare() { return 73; }
    acq_provider_input_prepare msb childbox
  '
  assert_failure 73
  assert_output ''
}

@test "provider boundary: executable dispatch stays offline after common loads" {
  acq_setup_stubs
  ACQ_TEST_REAL_GIT=$(command -v git)
  export ACQ_TEST_REAL_GIT
  cat > "$STUBDIR/git" <<'STUB'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    fetch|clone|ls-remote)
      printf 'unexpected git transport\n' >> "$STUBDIR/network-attempts"
      exit 91 ;;
  esac
done
exec "$ACQ_TEST_REAL_GIT" "$@"
STUB
  cat > "$STUBDIR/curl" <<'STUB'
#!/bin/sh
printf 'unexpected curl invocation\n' >> "$STUBDIR/network-attempts"
exit 91
STUB
  chmod +x "$STUBDIR/git" "$STUBDIR/curl"
  run env ACQ_BACKEND=msb USAI_API_KEY=offline-test-key \
    ACQ_TEST_USAI_KIT="$ACQ_MSB_KIT_LOCAL_DIR" \
    "$ACQ" create shell "$STUBDIR" --name offlinebox
  assert_success
  [ ! -e "$STUBDIR/network-attempts" ]
  local root
  root=$(acq_provider_input_root msb offlinebox)
  compgen -G "$root/generations/generation.test.*" >/dev/null
}

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
