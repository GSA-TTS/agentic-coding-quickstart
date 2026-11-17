#!/usr/bin/env bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/uninstall.XXXXXX")"
  FIXTURE="$(cd -P "$FIXTURE" && pwd -P)"
  export HOME="$FIXTURE/home"
  mkdir -p "$HOME/.local/bin" "$FIXTURE/bin"
  export PATH="$FIXTURE/bin:/usr/bin:/bin"
  unset XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
  unset ACQ_STATE_DIR ACQ_INSTALL_CLONE_DIR ACQ_INSTALL_BIN_DIR MSB_HOME
  unset ACQ_INSTALL_DIR
  unset ACQ_SECRET_STORE_DIR ACQ_SECRET_FILE_DIR ACQ_SECRET_META_DIR ACQ_SECRET_INDEX_FILE
  unset ACQ_MSB_PORTS_DIR ACQ_MSB_CLONES_DIR ACQ_MSB_SSH_DIR ACQ_MSB_SSH_KEY
  . "$REPO_ROOT/acq.backends/uninstall-files.sh"
  . "$REPO_ROOT/acq.backends/uninstall-installation.sh"
  # Capture the real cleanup body for isolated command-contract tests.
  # Consumed by the Keychain tests in 07-uninstall.bats.
  # shellcheck disable=SC2034
  MACOS_CLEANUP="$(declare -f uninstall_macos_secrets)"
  . "$REPO_ROOT/acq.backends/uninstall.sh"
  # HOME does not isolate macOS login Keychain. Never call /usr/bin/security
  # from offline tests, including tests of the production entry point.
  uninstall_macos_secrets() { printf 'Fixture Keychain cleanup only.\n'; }
  # HOME cannot isolate a desktop Secret Service either. Availability and calls
  # are explicit fixture functions, never the host executable or D-Bus session.
  uninstall_secret_tool_available() { return 1; }
  uninstall_secret_tool() { printf '%s\n' "$*" >> "$CALLS"; }
  # System prefixes are not isolated by HOME. Discovery of destructive tools
  # must see ONLY executables explicitly provided by this test's fixture.
  command() {
    if [ "${1:-}" = -v ]; then
      case "${2:-}" in npm|brew|msb|sbx|secret-tool)
        [ -x "$FIXTURE/bin/$2" ] || return 1
        printf '%s\n' "$FIXTURE/bin/$2"; return 0 ;;
      esac
    fi
    builtin command "$@"
  }
  # CI/sandbox may run as root; production still refuses sudo. Only this fixture
  # reports a regular user for the read-only inventory and isolated cleanup.
  id() { if [ "${1:-}" = -u ]; then printf '1000\n'; else command id "$@"; fi; }
  export CALLS="$FIXTURE/calls"
  : > "$CALLS"
}

stub_msb() {
  cat > "$FIXTURE/bin/msb" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  'ls -q') [ -f "$HOME/removed" ] || printf 'example\n' ;;
  'ls -q --running') printf 'example\n' ;;
  'stop --timeout 30 example') [ ! -f "$HOME/stop-fail" ] ;;
  'rm example') touch "$HOME/removed" ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$FIXTURE/bin/msb"
}
