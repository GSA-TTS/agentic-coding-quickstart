#!/usr/bin/env bats

load uninstall-fixture

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

@test "regular unknown launcher fails closed even off PATH" {
  uninstall_bin="$HOME/.local/bin"
  uninstall_install="$HOME/.local/share/acq"
  [ -n "$uninstall_install" ]
  printf 'user file\n' > "$uninstall_bin/acq"
  run uninstall_links
  [ "$status" = 1 ]
  [ -f "$uninstall_bin/acq" ]
}

@test "clone origin traversal and symlinks cannot modify Git config" {
  uninstall_state="$HOME/.local/state/acq"
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

@test "changed temporary Git remote is preserved and blocks cleanup" {
  # Consumed by uninstall_clone_remotes in the sourced production module.
  # shellcheck disable=SC2034
  uninstall_state="$HOME/.local/state/acq"
  command git init -q "$HOME/project"
  uninstall_clones="$HOME/.local/state/acq/clones"
  mkdir -p "$uninstall_clones/example/project/.git"
  printf '%s\n' "$HOME/project" > "$uninstall_clones/example/.origin"
  command git -C "$HOME/project" remote add sandbox-example "$HOME/different"
  run uninstall_clone_remotes
  [ "$status" = 1 ]
  [ "$(command git -C "$HOME/project" config remote.sandbox-example.url)" = "$HOME/different" ]
}

@test "Python ownership manifest removes runtime but preserves unowned files" {
  mkdir -p "$HOME/.local/share/acq/py-acq/runtime/bin"
  printf 'fixture\n' > "$HOME/.local/share/acq/py-acq/runtime/bin/python3"
  printf 'user-owned\n' > "$HOME/.local/share/acq/keep"
  printf '4.1.1\npy-acq\nacq-python\nREADME.md\n' > "$HOME/.local/share/acq/.acq-v1-install"
  printf 'owned readme\n' > "$HOME/.local/share/acq/README.md"
  touch "$HOME/.local/share/acq/acq-python"
  ln -s "$HOME/.local/share/acq/acq-python" "$HOME/.local/bin/acq-python"
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ -f "$HOME/.local/share/acq/keep" ]
  printf 'new user readme\n' > "$HOME/.local/share/acq/README.md"
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ -f "$HOME/.local/share/acq/README.md" ]
  [ ! -e "$HOME/.local/share/acq/py-acq" ]
  [ ! -L "$HOME/.local/bin/acq-python" ]
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ -f "$HOME/.local/share/acq/keep" ]
}

@test "header-only and custom install manifests cannot authorize recursive removal" {
  mkdir -p "$HOME/.local/share/acq"
  touch "$HOME/.local/share/acq/keep"
  printf '4.1.1\n' > "$HOME/.local/share/acq/.acq-v1-install"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/.local/share/acq/keep" ]
  export ACQ_INSTALL_DIR="$HOME/project/acq"
  run uninstall_main --dry-run
  [ "$status" = 1 ]
}

@test "hostile ownership manifest cannot escape its installation" {
  mkdir -p "$HOME/.local/share/acq" "$HOME/project"
  touch "$HOME/project/keep"
  printf '4.1.1\n../../project\n' > "$HOME/.local/share/acq/.acq-v1-install"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/project/keep" ]
}

@test "interrupted move-aside never reclaims a recreated user pathname" {
  mkdir -p "$HOME/.local/share/acq/.acq-uninstall-pending/py-acq"
  printf '4.1.1\npy-acq\n' > "$HOME/.local/share/acq/.acq-v1-install"
  mkdir -p "$HOME/.local/share/acq/py-acq"
  touch "$HOME/.local/share/acq/py-acq/user-owned"
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ -f "$HOME/.local/share/acq/py-acq/user-owned" ]
}

@test "bookkeeping sentinel symlinks and directories fail before deletion" {
  mkdir -p "$HOME/.local/share/acq"
  printf '4.1.1\nREADME.md\n' > "$HOME/.local/share/acq/.acq-v1-install"
  touch "$HOME/.local/share/acq/README.md" "$HOME/keep"
  ln -s "$HOME/keep" "$HOME/.local/share/acq/.acq-uninstalled"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/.local/share/acq/README.md" ]
  rm "$HOME/.local/share/acq/.acq-uninstalled"
  mkdir "$HOME/.local/share/acq/.acq-uninstalled"
  run uninstall_main --yes
  [ "$status" = 1 ]
}

@test "absent owned entry remains relinquished after failed manifest update" {
  mkdir -p "$HOME/.local/share/acq"
  printf '4.1.1\nREADME.md\n' > "$HOME/.local/share/acq/.acq-v1-install"
  original_drop="$(declare -f uninstall_manifest_drop)"
  uninstall_manifest_drop() { return 1; }
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -d "$HOME/.local/share/acq/.acq-uninstall-pending/README.md" ]
  printf 'new user file\n' > "$HOME/.local/share/acq/README.md"
  eval "$original_drop"
  run uninstall_main --yes
  [ "$status" = 0 ]
  grep -Fx 'new user file' "$HOME/.local/share/acq/README.md"
}

@test "installer refuses unfinished uninstall transactions" {
  run grep -F 'rerun uninstall.command before reinstalling' "$REPO_ROOT/install.sh"
  [ "$status" = 0 ]
}

@test "orphaned uninstall evidence never authorizes legacy recursive removal" {
  mkdir -p "$HOME/.local/share/acq"
  touch "$HOME/.local/share/acq/user-document" "$HOME/.local/share/acq/.acq-uninstalled"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/.local/share/acq/user-document" ]
  rm "$HOME/.local/share/acq/.acq-uninstalled"
  mkdir "$HOME/.local/share/acq/.acq-uninstall-pending"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/.local/share/acq/user-document" ]
}

@test "unknown pending payload blocks before sandbox or owned file deletion" {
  stub_msb
  mkdir -p "$HOME/.local/share/acq/.acq-uninstall-pending"
  printf '4.1.1\nREADME.md\n' > "$HOME/.local/share/acq/.acq-v1-install"
  touch "$HOME/.local/share/acq/README.md" "$HOME/.local/share/acq/.acq-uninstall-pending/unknown"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/.local/share/acq/README.md" ]
  [ ! -s "$CALLS" ]
}

@test "unsupported pending payload blocks before deletion" {
  mkdir -p "$HOME/.local/share/acq/.acq-uninstall-pending"
  printf '4.1.1\nREADME.md\n' > "$HOME/.local/share/acq/.acq-v1-install"
  touch "$HOME/.local/share/acq/README.md"
  mkfifo "$HOME/.local/share/acq/.acq-uninstall-pending/LICENSE"
  run uninstall_main --yes
  [ "$status" = 1 ]
  [ -f "$HOME/.local/share/acq/README.md" ]
}

@test "exhausted installation retains ownership evidence for safe reruns" {
  mkdir -p "$HOME/.local/share/acq"
  printf '4.1.1\nREADME.md\n' > "$HOME/.local/share/acq/.acq-v1-install"
  touch "$HOME/.local/share/acq/README.md"
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ -f "$HOME/.local/share/acq/.acq-v1-install" ]
  touch "$HOME/.local/share/acq/user-document"
  run uninstall_main --yes
  [ "$status" = 0 ]
  [ -f "$HOME/.local/share/acq/user-document" ]
}

@test "read-only provider generation directories can be removed" {
  mkdir -p "$HOME/.local/state/acq/provider-input/msb/example/generation"
  printf 'fixture\n' > "$HOME/.local/state/acq/provider-input/msb/example/generation/facts.json"
  chmod 0444 "$HOME/.local/state/acq/provider-input/msb/example/generation/facts.json"
  chmod 0555 "$HOME/.local/state/acq/provider-input/msb/example/generation"
  run uninstall_remove_root "$HOME/.local/state/acq" acq
  [ "$status" = 0 ]
  [ ! -e "$HOME/.local/state/acq" ]
}
