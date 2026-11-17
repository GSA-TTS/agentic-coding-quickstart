#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/uninstall.XXXXXX")"
  FIXTURE="$(cd -P "$FIXTURE" && pwd -P)"
  export HOME="$FIXTURE/home"
  mkdir -p "$HOME/.local/bin" "$FIXTURE/bin"
  export PATH="$FIXTURE/bin:/usr/bin:/bin"
  unset XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
  unset ACQ_STATE_DIR ACQ_INSTALL_CLONE_DIR ACQ_INSTALL_BIN_DIR MSB_HOME
  unset ACQ_SECRET_STORE_DIR ACQ_SECRET_FILE_DIR ACQ_SECRET_META_DIR ACQ_SECRET_INDEX_FILE
  unset ACQ_MSB_PORTS_DIR ACQ_MSB_CLONES_DIR ACQ_MSB_SSH_DIR ACQ_MSB_SSH_KEY
  . "$REPO_ROOT/acq.backends/uninstall-files.sh"
  # Capture the real cleanup body for isolated command-contract tests.
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

@test "uninstall help dispatches without backend discovery" {
  run bash "$REPO_ROOT/acq" uninstall --help
  [ "$status" = 0 ]
  [[ "$output" == *'Usage: acq uninstall'* ]]
}

@test "uninstall explicitly rejects backend globals" {
  run bash "$REPO_ROOT/acq" --backend msb uninstall
  [ "$status" = 2 ]
  [[ "$output" == *'backend-independent'* ]]
  run bash "$REPO_ROOT/acq" --backend=msb uninstall
  [ "$status" = 2 ]
}

@test "dry run lists sandboxes without stopping or deleting anything" {
  stub_msb
  mkdir -p "$HOME/.config/acq"
  run uninstall_main --dry-run
  [ "$status" = 0 ]
  [[ "$output" == *'Dry run. Nothing removed.'* ]]
  [ -d "$HOME/.config/acq" ]
  run grep -E '^(stop|rm) ' "$CALLS"
  [ "$status" = 1 ]
}

@test "noninteractive removal requires explicit confirmation" {
  run uninstall_main </dev/null
  [ "$status" = 1 ]
  [[ "$output" == *'No interactive terminal'* ]]
}

@test "historical SBX records allow preview but yes alone never authorizes deletion" {
  mkdir -p "$HOME/.local/state/acq/provenance/sbx"
  printf 'historical record\n' > "$HOME/.local/state/acq/provenance/sbx/old.env"
  run uninstall_main --dry-run </dev/null
  [ "$status" = 0 ]
  [[ "$output" == *'These are ACQ records, not sandbox disks.'* ]]
  run uninstall_main --yes </dev/null
  [ "$status" = 1 ]
  [ -f "$HOME/.local/state/acq/provenance/sbx/old.env" ]
  run uninstall_main --yes --confirm-no-sbx-sandboxes </dev/null
  [ "$status" = 0 ]
  [ ! -e "$HOME/.local/state/acq" ]
}

@test "installed SBX is not bypassed by sandbox-absence assertion" {
  printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/bin/sbx"
  chmod +x "$FIXTURE/bin/sbx"
  run uninstall_main --yes --confirm-no-sbx-sandboxes </dev/null
  [ "$status" = 1 ]
  [[ "$output" == *'SBX is installed at'* ]]
  [[ "$output" == *"sbx ls"* ]]
}

@test "Python SBX state also requires explicit absence confirmation" {
  mkdir -p "$HOME/.local/state/acq/sbx"
  run uninstall_main --yes </dev/null
  [ "$status" = 1 ]
  [ -d "$HOME/.local/state/acq/sbx" ]
}

@test "custom clone named acq never authorizes deletion of a project" {
  export ACQ_INSTALL_CLONE_DIR="$HOME/projects/acq"
  mkdir -p "$ACQ_INSTALL_CLONE_DIR"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -d "$ACQ_INSTALL_CLONE_DIR" ]
}

@test "symlinked and traversal roots are rejected" {
  mkdir -p "$HOME/outside"
  ln -s "$HOME/outside" "$HOME/.cache"
  run uninstall_main --yes
  [ "$status" = 1 ]
  run uninstall_validate_root "$HOME/../home/acq" acq
  [ "$status" = 1 ]
}

@test "unsafe custom SSH artifacts block removal" {
  export ACQ_MSB_SSH_KEY="$HOME/project/key"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [[ "$output" == *'ACQ_MSB_SSH_KEY uses a custom location'* ]]
}

@test "missing MSB with residual sandboxes preserves files" {
  mkdir -p "$HOME/.microsandbox/sandboxes/example"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -d "$HOME/.microsandbox/sandboxes/example" ]
}

@test "failed MSB listing cannot become an empty success" {
  printf '#!/bin/bash\nexit 1\n' > "$FIXTURE/bin/msb"
  chmod +x "$FIXTURE/bin/msb"
  mkdir -p "$HOME/.local/state/acq"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -d "$HOME/.local/state/acq" ]
}

@test "failed graceful stop prevents sandbox or state deletion" {
  stub_msb
  touch "$HOME/stop-fail"
  mkdir -p "$HOME/.local/state/acq"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -d "$HOME/.local/state/acq" ]
  run grep '^rm ' "$CALLS"
  [ "$status" = 1 ]
}

@test "PID-only records never cause a process to be killed" {
  uninstall_ports="$HOME/.local/state/acq/ports"
  mkdir -p "$uninstall_ports"
  printf '%s %s mapping' "$$" "$$" > "$uninstall_ports/example.pids"
  run uninstall_helpers
  [ "$status" = 1 ]
  [ -f "$uninstall_ports/example.pids" ]
  [[ "$output" == *'No process was killed.'* ]]
}

@test "regular unknown launcher fails closed even off PATH" {
  uninstall_bin="$HOME/.local/bin"
  printf 'user file\n' > "$uninstall_bin/acq"
  run uninstall_links
  [ "$status" = 1 ]
  [ -f "$uninstall_bin/acq" ]
}

@test "missing secret-tool preserves credential records" {
  uninstall_index="$HOME/.local/share/acq/secret-index"
  uninstall_meta="$HOME/.local/share/acq/secret-meta"
  uninstall_secrets="$HOME/.local/share/acq/secrets"
  mkdir -p "$(dirname "$uninstall_index")"
  printf 'acq.usai' > "$uninstall_index"
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ -f "$uninstall_index" ]
}

@test "unterminated credential index lines are processed" {
  uninstall_secret_tool_available() { return 0; }
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$CALLS"\n' > "$FIXTURE/bin/secret-tool"
  chmod +x "$FIXTURE/bin/secret-tool"
  uninstall_index="$HOME/.local/share/acq/secret-index"
  uninstall_meta="$HOME/.local/share/acq/secret-meta"
  uninstall_secrets="$HOME/.local/share/acq/secrets"
  mkdir -p "$(dirname "$uninstall_index")"
  printf 'acq.usai' > "$uninstall_index"
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  grep -Fx 'clear acq_key acq.usai' "$CALLS"
}

@test "clone origin traversal and symlinks cannot modify Git config" {
  uninstall_clones="$HOME/.local/state/acq/clones"
  mkdir -p "$uninstall_clones/example" "$HOME/project/.git"
  printf '%s\n' "$HOME/../home/project" > "$uninstall_clones/example/.origin"
  run uninstall_clone_remotes
  [ "$status" = 1 ]
  ln -s "$HOME/project" "$HOME/link"
  printf '%s\n' "$HOME/link" > "$uninstall_clones/example/.origin"
  run uninstall_clone_remotes
  [ "$status" = 1 ]
}

@test "standalone packaging works without any checkout at runtime" {
  run bash "$REPO_ROOT/scripts/build-uninstaller" "$FIXTURE/uninstall.command"
  [ "$status" = 0 ]
  [ -x "$FIXTURE/uninstall.command" ]
  run bash "$FIXTURE/uninstall.command" --help
  [ "$status" = 0 ]
  [[ "$output" == *'Usage: acq uninstall'* ]]
  run grep -E '^\s*(source|\.) ' "$FIXTURE/uninstall.command"
  [ "$status" = 1 ]
}

@test "empty isolated installation cleans defaults and preserves projects" {
  mkdir -p "$HOME/.config/acq" "$HOME/.cache/acq" "$HOME/.local/state/acq"
  mkdir -p "$HOME/.local/share/acq" "$HOME/.microsandbox" "$HOME/project"
  touch "$HOME/project/keep"
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ -f "$HOME/project/keep" ]
  [ ! -d "$HOME/.config/acq" ]
  run uninstall_main --yes
  [ "$status" = 0 ]
}

@test "empty Homebrew arrays are safe with nounset enabled" {
  set -u
  uninstall_formulas=()
  uninstall_npm=0
  [ "${#uninstall_formulas[@]}" = 0 ]
  [ "$uninstall_npm" = 0 ]
  run uninstall_packages
  [ "$status" = 0 ]
}

@test "Linux file fallback metadata does not require secret-tool" {
  uninstall_index="$HOME/.local/share/acq/secret-index"
  uninstall_meta="$HOME/.local/share/acq/secret-meta"
  uninstall_secrets="$HOME/.local/share/acq/secrets"
  mkdir -p "$uninstall_meta" "$uninstall_secrets"
  printf 'synthetic-fixture\n' > "$uninstall_secrets/acq.custom"
  printf 'example.invalid\tEXAMPLE\n' > "$uninstall_meta/acq.custom"
  run uninstall_linux_secrets
  [ "$status" = 0 ]
}

@test "matching remote from a linked worktree is safely removed" {
  command git init -q "$HOME/original"
  command git -C "$HOME/original" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm initial
  command git -C "$HOME/original" worktree add -qb fixture "$HOME/worktree"
  uninstall_clones="$HOME/.local/state/acq/clones"
  mkdir -p "$uninstall_clones/example/project/.git"
  printf '%s\n' "$HOME/worktree" > "$uninstall_clones/example/.origin"
  command git -C "$HOME/worktree" remote add sandbox-example "$uninstall_clones/example/project"
  run uninstall_clone_remotes
  [ "$status" = 0 ]
  run command git -C "$HOME/worktree" remote
  [ "$status" = 0 ]
  [[ "$output" != *sandbox-example* ]]
}

@test "Homebrew and npm installs are removed independently with correct names" {
  cat > "$FIXTURE/bin/brew" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  'list --formula') [ -f "$HOME/brew-removed" ] || printf 'acq\nmicrosandbox-acq\n' ;;
  'uninstall acq') ;;
  'uninstall microsandbox-acq') touch "$HOME/brew-removed" ;;
  *) exit 99 ;;
esac
STUB
  cat > "$FIXTURE/bin/npm" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  'root -g') printf '%s\n' "$HOME/npm" ;;
  'uninstall -g --ignore-scripts @gsa-tts/agentic-coding-quickstart')
    rm -rf "$HOME/npm/@gsa-tts/agentic-coding-quickstart" ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$FIXTURE/bin/brew" "$FIXTURE/bin/npm"
  mkdir -p "$HOME/npm/@gsa-tts/agentic-coding-quickstart"
  printf '{}\n' > "$HOME/npm/@gsa-tts/agentic-coding-quickstart/package.json"
  run uninstall_main --yes
  [ "$status" = 0 ]
  grep -Fx 'uninstall acq' "$CALLS"
  grep -Fx 'uninstall microsandbox-acq' "$CALLS"
  grep -Fx 'uninstall -g --ignore-scripts @gsa-tts/agentic-coding-quickstart' "$CALLS"
}

@test "changed temporary Git remote is preserved and blocks cleanup" {
  command git init -q "$HOME/project"
  uninstall_clones="$HOME/.local/state/acq/clones"
  mkdir -p "$uninstall_clones/example/project/.git"
  printf '%s\n' "$HOME/project" > "$uninstall_clones/example/.origin"
  command git -C "$HOME/project" remote add sandbox-example "$HOME/different"
  run uninstall_clone_remotes
  [ "$status" = 1 ]
  [ "$(command git -C "$HOME/project" config remote.sandbox-example.url)" = "$HOME/different" ]
}

@test "installer shell blocks removed but shared PATH and user lines survive" {
  uninstall_bin="$HOME/.local/bin"
  cat > "$HOME/.zshrc" <<'RC'
# >>> microsandbox >>>
export MSB_HOME=old
# <<< microsandbox <<<
# Added by acq install.sh — put acq on PATH
export PATH="$HOME/.local/bin:$PATH"
export USER_SETTING=kept
RC
  touch "$uninstall_bin/unrelated-tool"
  run uninstall_shell_config
  [ "$status" = 0 ]
  run grep 'MSB_HOME=old' "$HOME/.zshrc"
  [ "$status" = 1 ]
  grep -F 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc"
  grep -F 'export USER_SETTING=kept' "$HOME/.zshrc"
}

@test "running sandbox names are validated too" {
  cat > "$FIXTURE/bin/msb" <<'STUB'
#!/bin/bash
case "$*" in
  'ls -q') ;;
  'ls -q --running') printf '%s\n' '--label=foreign' ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$FIXTURE/bin/msb"
  run uninstall_main --yes
  [ "$status" = 1 ]
}

@test "empty bin removes actual installer-expanded PATH block" {
  uninstall_bin="$HOME/.local/bin"
  printf '# Added by acq install.sh — put acq on PATH\nexport PATH="%s:$PATH"\nexport USER_SETTING=kept\n' "$uninstall_bin" > "$HOME/.zshrc"
  run uninstall_shell_config
  [ "$status" = 0 ]
  run grep -F 'Added by acq install.sh' "$HOME/.zshrc"
  [ "$status" = 1 ]
  run grep -F 'export PATH=' "$HOME/.zshrc"
  [ "$status" = 1 ]
  grep -F 'export USER_SETTING=kept' "$HOME/.zshrc"
}

@test "macOS Keychain cleanup removes every owned item without retrieving values" {
  # The function text comes exclusively from the checked-in trusted module.
  eval "$MACOS_CLEANUP"
  uninstall_security() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$1" in
      find-generic-password) [ ! -f "$HOME/keychain-cleared" ] || return 44 ;;
      delete-generic-password) touch "$HOME/keychain-cleared" ;;
      *) return 99 ;;
    esac
  }
  run uninstall_macos_secrets
  [ "$status" = 0 ]
  grep -Fx 'delete-generic-password -s acq-secret-store' "$CALLS"
  run grep -E -- '(^| )-w( |$)' "$CALLS"
  [ "$status" = 1 ]
}

@test "macOS Keychain denied deletion is not a successful cleanup" {
  eval "$MACOS_CLEANUP"
  uninstall_security() {
    case "$1" in find-generic-password) return 0 ;; *) return 36 ;; esac
  }
  run uninstall_macos_secrets
  [ "$status" = 1 ]
  [[ "$output" == *'Keychain deletion was denied'* ]]
}

@test "release builds checksums attests and uploads the standalone wizard" {
  run grep -F 'bash scripts/build-uninstaller dist/uninstall.command' "$REPO_ROOT/.github/workflows/release.yml"
  [ "$status" = 0 ]
  run grep -F 'sha256sum install.sh install.ps1 uninstall.command' "$REPO_ROOT/.github/workflows/release.yml"
  [ "$status" = 0 ]
  run grep -F '            dist/uninstall.command' "$REPO_ROOT/.github/workflows/release.yml"
  [ "$status" = 0 ]
  run grep -F 'dist/install.ps1 dist/uninstall.command dist/acq-windows-x64.zip' "$REPO_ROOT/.github/workflows/release.yml"
  [ "$status" = 0 ]
}

@test "offline discovery cannot reach system package managers or backends" {
  for tool in npm brew msb sbx secret-tool; do
    run command -v "$tool"
    [ "$status" = 1 ]
  done
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ ! -s "$CALLS" ]
}
