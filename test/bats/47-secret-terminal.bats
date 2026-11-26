#!/usr/bin/env bats
load helper
setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

@test "secret terminal: paste, typing, backspace, EOF, signals and stty failure" {
  command -v python3 >/dev/null || skip 'python3 required for pseudo-terminal checks'
  run python3 "$REPO_ROOT/test/secret-terminal.py" "$REPO_ROOT" "$STUBDIR"
  assert_success
  assert_output --partial 'terminal checks passed'
}
