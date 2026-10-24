#!/usr/bin/env bats
# shellcheck shell=bats
load 'helper'
setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

@test "test environment: python stays usable after HOME is isolated" {
  run python3 -c 'import os, sys; print(os.path.realpath(sys.executable))'
  assert_success
  assert_output "$ACQ_TEST_HOST_PYTHON"
  assert_equal "$MISE_AUTO_INSTALL" 0
  assert_equal "$GIT_ALLOW_PROTOCOL" file
}

@test "test environment: physical temp root excludes host symlink aliases" {
  mkdir -p "$STUBDIR/physical" "$STUBDIR/shims"
  ln -s "$STUBDIR/physical" "$STUBDIR/alias"
  run bash -c '
    source "$REPO_ROOT/scripts/test-acq-env.sh"
    TMPDIR="$STUBDIR/alias"
    acq_test_prepare_environment
    printf "%s\n" "$TMPDIR"
  '
  assert_success
  assert_output "$(cd "$STUBDIR/physical" && pwd -P)"
}

@test "test environment: replacing fixture python cannot overwrite host runtime" {
  refute [ -L "$STUBDIR/python3" ]
  local before
  before=$(cksum "$ACQ_TEST_HOST_PYTHON")
  printf '#!/bin/sh\nprintf "fixture-only\\n"\n' > "$STUBDIR/python3"
  run python3
  assert_success
  assert_output fixture-only
  assert_equal "$(cksum "$ACQ_TEST_HOST_PYTHON")" "$before"
  run "$ACQ_TEST_HOST_PYTHON" -c 'print(42)'
  assert_success
  assert_output 42
}

@test "test environment: resolves a shim once before changing HOME" {
  mkdir -p "$STUBDIR/shims" "$STUBDIR/new-home"
  cat > "$STUBDIR/shims/python3" <<'SH'
#!/bin/sh
[ "$MISE_AUTO_INSTALL" = 0 ] || exit 92
[ "$HOME" = "$EXPECTED_HOME" ] || exit 93
exec "$ACQ_TEST_HOST_PYTHON" "$@"
SH
  chmod +x "$STUBDIR/shims/python3"
  run bash -c '
    export EXPECTED_HOME="$HOME"
    PATH="$STUBDIR/shims:$PATH"
    source "$REPO_ROOT/scripts/test-acq-env.sh"
    acq_test_prepare_environment || exit
    HOME="$STUBDIR/new-home"
    python3 -c "print(42)"
  '
  assert_success
  assert_output 42
}
