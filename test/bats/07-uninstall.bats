#!/usr/bin/env bats

load uninstall-fixture

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

@test "standalone packaging works without any checkout at runtime" {
  run bash "$REPO_ROOT/scripts/build-uninstaller" "$FIXTURE/uninstall.command"
  [ "$status" = 0 ]
  [ -x "$FIXTURE/uninstall.command" ]
  run bash "$FIXTURE/uninstall.command" --help </dev/null
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
  uninstall_state="$HOME/.local/state/acq"
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
  '--version') printf 'msb 0.7.7\n' ;;
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
  run grep -F 'bash scripts/build-uninstaller dist/uninstall.command' "$REPO_ROOT/.github/workflows/build-assets.yml"
  [ "$status" = 0 ]
  run grep -F '"recovery": ["uninstall.command"]' "$REPO_ROOT/installer/assets.json"
  [ "$status" = 0 ]
  run grep -F "subject-path: 'dist/**/*'" "$REPO_ROOT/.github/workflows/release.yml"
  [ "$status" = 0 ]
  run grep -F 'dist/* --clobber' "$REPO_ROOT/.github/workflows/release.yml"
  [ "$status" = 0 ]
}

@test "persisted Python SBX state blocks MSB-only removal without sbx installed" {
  mkdir -p "$HOME/.local/state/acq/sbx"
  printf '{"schema":1}\n' > "$HOME/.local/state/acq/sbx/example.json"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/.local/state/acq/sbx/example.json" ]
}

@test "tracking-ref removal preserves symbolic target local branches" {
  uninstall_state="$HOME/.local/state/acq"
  [ -n "$uninstall_state" ]
  command git init -q "$HOME/original"
  command git -C "$HOME/original" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm initial
  command git -C "$HOME/original" update-ref refs/heads/keep HEAD
  command git -C "$HOME/original" update-ref refs/remotes/sandbox-example/main HEAD
  command git -C "$HOME/original" symbolic-ref refs/remotes/sandbox-example/alias refs/heads/keep
  command git -C "$HOME/original" pack-refs --all
  run uninstall_tracking_refs "$HOME/original" sandbox-example remove
  [ "$status" = 0 ]
  run command git -C "$HOME/original" show-ref --verify refs/heads/keep
  [ "$status" = 0 ]
  run command git -C "$HOME/original" for-each-ref refs/remotes/sandbox-example/
  [ "$status" = 0 ]
  [ -z "$output" ]
}

@test "production recovery entry points ignore planted relative PATH commands" {
  printf '#!/bin/bash\ntouch "$HOME/planted-ran"\n' > "$FIXTURE/uname"
  chmod +x "$FIXTURE/uname"
  run bash "$REPO_ROOT/scripts/build-uninstaller" "$FIXTURE/uninstall.command"
  [ "$status" = 0 ]
  # Inventory reaches uname but unsafe custom roots stop before any backend call.
  run bash -c 'cd "$1"; ACQ_INSTALL_DIR=/unsafe PATH=".:/usr/bin:/bin:" /bin/bash "$2" --dry-run' _ "$FIXTURE" "$FIXTURE/uninstall.command"
  [ "$status" = 1 ]
  run bash -c 'cd "$1"; ACQ_INSTALL_DIR=/unsafe PATH=".:/usr/bin:/bin:" /bin/bash "$2" --dry-run' _ "$FIXTURE" "$REPO_ROOT/scripts/run-uninstaller"
  [ "$status" = 1 ]
  [ ! -f "$HOME/planted-ran" ]
}

@test "future schemas in all migrated record families block preview" {
  for relative in msb/example.json provider-credentials/example.json github-scope/msb/example.json \
    msb-secret-bindings/example.json kit-sources/example.json provenance/msb/example.json \
    kit-consent/msb/example.json kit-applied/msb/example.json generation; do
    mkdir -p "$(dirname "$HOME/.local/state/acq/$relative")"
    printf '{"schema":999}\n' > "$HOME/.local/state/acq/$relative"
    run uninstall_main --dry-run
    [ "$status" = 1 ]
    [ -f "$HOME/.local/state/acq/$relative" ]
    rm -f "$HOME/.local/state/acq/$relative"
  done
}

@test "broken system Python candidate falls back without masking invalid schemas" {
  mkdir -p "$HOME/.local/state/acq/msb"
  printf '{"schema":1}\n' > "$HOME/.local/state/acq/msb/example.json"
  # Intercept only the fixed parser paths; no real interpreter is replaced.
  uninstall_python_available() { return 0; }
  /usr/bin/python3() { printf 'broken fixture parser\n' >&2; return 1; }
  /usr/local/bin/python3() {
    if [ "${2:-}" = -c ]; then return 0; fi
    grep -q '"schema":1' "$3"
  }
  uninstall_state="$HOME/.local/state/acq"
  run uninstall_migrated_state
  [ "$status" = 0 ]
  printf '{"schema":999}\n' > "$HOME/.local/state/acq/msb/example.json"
  run uninstall_migrated_state
  [ "$status" = 1 ]
}

@test "Linux credential preflight fails before sandbox stop" {
  stub_msb
  mkdir -p "$HOME/.local/share/acq"
  printf 'acq.usai\n' > "$HOME/.local/share/acq/secret-index"
  run uninstall_main --yes
  [ "$status" = 1 ]
  run grep -E '^(stop|rm) ' "$CALLS"
  [ "$status" = 1 ]
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

@test "Homebrew uninstall disables autoremove and skips packages already gone" {
  uninstall_formulas=(acq microsandbox-acq)
  uninstall_npm=0
  brew() {
    case "$*" in
      'list --formula') [ -f "$HOME/brew-gone" ] || printf 'acq\nmicrosandbox-acq\n' ;;
      'uninstall acq')
        [ "${HOMEBREW_NO_AUTOREMOVE:-}" = 1 ] || return 99
        touch "$HOME/brew-gone" ;;
      *) return 99 ;;
    esac
  }
  run uninstall_packages
  [ "$status" = 0 ]
}
