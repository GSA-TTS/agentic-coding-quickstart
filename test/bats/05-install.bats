#!/usr/bin/env bats

# Tests for the acq v1 installer (install.sh) — ADR-0042m. The installer is the
# Python-v1 front door: a checksum-verified, user-scoped install of the enumerated
# offline asset set (readable source + bundled managed runtime + wheelhouse), with
# dry-run, consent, and update-by-reinstall. These tests run the real script
# against the checked-in offline fixture (test/fixtures/installer) and assert the
# fail-closed checksum/dry-run/consent behavior.

load './helper.bash'

setup() {
  acq_setup_stubs
  export XDG_DATA_HOME="$STUBDIR/xdg-data"
  unset ACQ_INSTALL_DIR ACQ_INSTALL_BIN_DIR ACQ_INSTALL_SOURCE
}

teardown() {
  acq_teardown_stubs
}

_install_dir() {
  printf '%s/acq' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

@test "installer: --help exits 0 and prints usage" {
  run sh "$REPO_ROOT/install.sh" --help
  assert_success
  assert_output --partial 'install acq'
}

@test "installer: --version exits 0" {
  run sh "$REPO_ROOT/install.sh" --version
  assert_success
  assert_output --partial 'install.sh'
}

@test "installer: an unknown option is a usage error (exit 2)" {
  run sh "$REPO_ROOT/install.sh" --bogus
  assert_failure 2
  assert_output --partial 'unknown option'
}

@test "installer: --dry-run prints a plan and performs no writes" {
  run sh "$REPO_ROOT/install.sh" --dry-run
  assert_success
  assert_output --partial '[dry-run]'
  # No install dir, no bin dir, no launcher link.
  [ ! -e "$(_install_dir)" ]
  [ ! -e "$HOME/.local/bin" ]
}

@test "installer: installs offline from the enumerated asset set" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  assert_output --regexp 'verified acq-(macos|linux)-(arm64|x86_64|aarch64)\.tar\.gz'
  # The bundled runtime and the launcher are laid down.
  [ -e "$(_install_dir)/py-acq/runtime/bin/python3" ]
  [ -L "$HOME/.local/bin/acq" ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "installer: a checksum mismatch fails closed (exit 1, no install)" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer-bad" --yes
  assert_failure
  assert_output --partial 'checksum mismatch'
  [ ! -e "$(_install_dir)" ]
}

@test "installer: consent is never inferred non-interactively" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer"
  assert_success
  assert_output --partial 'Not changing your PATH'
  [ ! -e "$HOME/.bash_profile" ]
  [ ! -e "$HOME/.profile" ]
}

@test "installer: never elevates (no elevation invocation)" {
  # The installer documents non-elevation ("no sudo") in comments and --help
  # prose; that wording must not read as an invocation, but a real elevation
  # command (a line whose first word is sudo/pkexec/runas, or an osascript
  # "with administrator privileges") must be caught.
  grep -q 'no sudo' "$REPO_ROOT/install.sh" || fail "documentation of non-elevation missing"

  run grep -nE '^[[:space:]]*(sudo|pkexec|runas)[[:space:]]|osascript .*with administrator privileges' \
    "$REPO_ROOT/install.sh"
  assert_failure
}

@test "installer: never dumps the environment or hardcodes a secret" {
  run grep -E 'printenv|API_KEY=|TOKEN=|PASSWORD=|SECRET=' "$REPO_ROOT/install.sh"
  assert_failure
}
