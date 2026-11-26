#!/usr/bin/env bash
# Bats supplies status; the loaded production module consumes fixture variables.
# shellcheck disable=SC2154

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
  . "$REPO_ROOT/acq.backends/msb-version-policy.sh"
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
  if [ "$(id -u)" = 0 ]; then
    id() { if [ "${1:-}" = -u ]; then printf '1000\n'; else command id "$@"; fi; }
  fi
  export CALLS="$FIXTURE/calls"
  : > "$CALLS"
}

remote_fixture() {
  uninstall_state="$HOME/.local/state/acq"
  uninstall_clones="$uninstall_state/clones"
  origin="$HOME/project"
  scratch="$uninstall_clones/example/project"
  config="$origin/.git/config"
  command git init -q "$origin"
  command git -C "$origin" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm initial
  command git -C "$origin" update-ref refs/heads/keep HEAD
  cp "$origin/.git/refs/heads/keep" "$FIXTURE/keep-before"
  command git -C "$origin" symbolic-ref refs/remotes/sandbox-example/alias refs/heads/keep
  mkdir -p "$scratch/.git"
  printf '%s\n' "$origin" > "$uninstall_clones/example/.origin"
  command git config --file "$config" remote.sandbox-example.url "$scratch"
}

assert_remote_preserved() {
  cp "$config" "$FIXTURE/config-before"
  run uninstall_clone_remotes check
  [ "$status" = 1 ]
  run uninstall_clone_remotes
  [ "$status" = 1 ]
  cmp "$config" "$FIXTURE/config-before"
  cmp "$origin/.git/refs/heads/keep" "$FIXTURE/keep-before"
  # Malformed config is deliberately unparseable, so inspect the loose ref file.
  grep -Fx 'ref: refs/heads/keep' "$origin/.git/refs/remotes/sandbox-example/alias"
}

linux_secret_fixture() {
  uninstall_index="$HOME/secret-index"
  uninstall_meta="$HOME/secret-meta"
  uninstall_secrets="$HOME/secrets"
  mkdir -p "$uninstall_meta" "$uninstall_secrets"
  unset CLEAR_RC SEARCH_RC SEARCH_OUTPUT
  uninstall_secret_tool_available() { return 0; }
  uninstall_secret_tool() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$1" in
      clear) return "${CLEAR_RC:-0}" ;;
      search)
        [ "${SEARCH_OUTPUT:-}" = '' ] || printf '%s\n' "$SEARCH_OUTPUT"
        return "${SEARCH_RC:-0}" ;;
      *) return 99 ;;
    esac
  }
}

stub_msb() {
  cat > "$FIXTURE/bin/msb" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  '--version') printf 'msb 0.7.7\n' ;;
  'ls -q') [ -f "$HOME/removed" ] || printf 'example\n' ;;
  'ls -q --running') printf 'example\n' ;;
  'stop --timeout 30 example') [ ! -f "$HOME/stop-fail" ] ;;
  'rm example') touch "$HOME/removed" ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$FIXTURE/bin/msb"
}
