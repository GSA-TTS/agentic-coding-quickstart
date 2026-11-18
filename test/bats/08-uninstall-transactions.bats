#!/usr/bin/env bats
# Variables are initialized and consumed by the explicitly loaded fixture.
# shellcheck disable=SC2034,SC2154

load uninstall-fixture

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
  [ "$(command id -u)" != 0 ] || skip 'requires actual nonroot ownership'
  mkdir -p "$HOME/.local/state/acq/provider-input/msb/example/generation"
  printf 'fixture\n' > "$HOME/.local/state/acq/provider-input/msb/example/generation/facts.json"
  chmod 0444 "$HOME/.local/state/acq/provider-input/msb/example/generation/facts.json"
  chmod 0555 "$HOME/.local/state/acq/provider-input/msb/example/generation"
  run uninstall_remove_root "$HOME/.local/state/acq" acq
  [ "$status" = 0 ]
  [ ! -e "$HOME/.local/state/acq" ]
}

@test "production inventory refuses root without weakening ownership checks" {
  id() { if [ "${1:-}" = -u ]; then printf '0\n'; else command id "$@"; fi; }
  run uninstall_main --dry-run
  [ "$status" = 1 ]
  [[ "$output" == *'not with sudo'* ]]
}

@test "combined repeated globals cannot forward uninstall to a backend" {
  for args in '--image example' '--image=example' '--backend msb --image example' '--image=example --backend=msb' '--backend msb --backend msb'; do
    # Fixed fixture arguments, not paths or external data.
    # shellcheck disable=SC2086
    run bash "$REPO_ROOT/acq" $args uninstall --dry-run
    [ "$status" = 2 ]
    [[ "$output" == *'without global options'* ]]
  done
}

@test "blocked unknown and prerelease MSB never opens catalog even for preview" {
  for version in 0.7.0 0.7.1 0.7.2 0.6.8 0.7.7-rc1 0.7.7+build unknown; do
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$CALLS"\nif [ "$1" = --version ]; then printf "msb %s\\n"; else exit 99; fi\n' "$version" > "$FIXTURE/bin/msb"
    chmod +x "$FIXTURE/bin/msb"
    : > "$CALLS"
    run uninstall_main --dry-run
    [ "$status" = 1 ]
    [ "$(cat "$CALLS")" = --version ]
  done
}

@test "standalone help exits under a real terminal without Return" {
  run bash "$REPO_ROOT/scripts/build-uninstaller" "$FIXTURE/uninstall.command"
  [ "$status" = 0 ]
  run python3 - "$FIXTURE/uninstall.command" <<'PY'
import os, pty, subprocess, sys
master, slave = pty.openpty()
process = None
try:
    process = subprocess.Popen(['/bin/bash', sys.argv[1], '--help'], stdin=slave,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = process.communicate(timeout=5)
    assert process.returncode == 0, err
    assert b'Press Return' not in out
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    os.close(slave)
PY
  [ "$status" = 0 ]
}

@test "all fetch and push URLs must match before remote or tracking refs change" {
  remote_fixture
  for key in url pushurl; do
    for value in customized '' "$scratch"$'\n' "$scratch"$'\n'"$scratch"; do
      command git config --file "$config" --add "remote.sandbox-example.$key" "$value"
      assert_remote_preserved
      command git config --file "$config" --unset-all "remote.sandbox-example.$key"
      command git config --file "$config" remote.sandbox-example.url "$scratch"
    done
  done
  command git config --file "$config" --unset-all remote.sandbox-example.url
  command git config --file "$config" remote.sandbox-example.pushurl "$scratch"
  assert_remote_preserved
}

@test "matching repeated remote URLs preserve check mode and no-deref ref cleanup" {
  remote_fixture
  command git config --file "$config" --add remote.sandbox-example.url "$scratch"
  command git config --file "$config" --add remote.sandbox-example.pushurl "$scratch"
  command git config --file "$config" --add remote.sandbox-example.pushurl "$scratch"
  cp "$config" "$FIXTURE/config-before"
  run uninstall_clone_remotes check
  [ "$status" = 0 ]
  cmp "$config" "$FIXTURE/config-before"
  command git -C "$origin" show-ref --verify refs/remotes/sandbox-example/alias
  run uninstall_clone_remotes
  [ "$status" = 0 ]
  command git -C "$origin" show-ref --verify refs/heads/keep
  [ -z "$(command git -C "$origin" for-each-ref refs/remotes/sandbox-example/)" ]
  run uninstall_clone_remotes
  [ "$status" = 0 ]
}

@test "ambiguous symlinked and malformed scratch remote evidence is preserved" {
  remote_fixture
  mkdir -p "${scratch%/*}/other/.git"
  assert_remote_preserved
  mv "${scratch%/*}/other" "$HOME/other"
  mv "$scratch" "$HOME/moved"
  ln -s "$HOME/moved" "$scratch"
  assert_remote_preserved
  rm "$scratch"
  mv "$HOME/moved" "$scratch"
  printf '[broken\n' >> "$config"
  assert_remote_preserved
}

@test "Linux mixed indexed fallback deduplicates and preserves nonmutating preflight" {
  linux_secret_fixture
  printf 'acq.usai\nacq.usai\nacq.github' > "$uninstall_index"
  touch "$uninstall_meta/acq.usai" "$uninstall_meta/acq.github" "$uninstall_meta/acq.gitlab"
  touch "$uninstall_secrets/acq.usai" "$uninstall_secrets/acq.gitlab"
  run uninstall_linux_secrets check
  [ "$status" = 0 ]
  [ ! -s "$CALLS" ]
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ "$(cat "$CALLS")" = $'clear acq_key acq.usai\nclear acq_key acq.github' ]
  [ -f "$uninstall_secrets/acq.usai" ]
  uninstall_secret_tool_available() { return 1; }
  run uninstall_linux_secrets check
  [ "$status" = 1 ]
}

@test "Linux metadata-only fallback skips service whether available or missing" {
  linux_secret_fixture
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  uninstall_secret_tool_available() { return 1; }
  run uninstall_linux_secrets check
  [ "$status" = 0 ]
  [ ! -s "$CALLS" ]
  rm "$uninstall_secrets/acq.usai"
  ln -s "$HOME/unrelated" "$uninstall_secrets/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 1 ]
}

@test "Linux no-match clear requires successful empty search without leaking records" {
  linux_secret_fixture
  printf 'acq.usai\n' > "$uninstall_index"
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  CLEAR_RC=1
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ "$(cat "$CALLS")" = $'clear acq_key acq.usai\nsearch --all acq_key acq.usai' ]
  for scenario in search-error locked blank invalid-clear; do
    SEARCH_RC=0 SEARCH_OUTPUT='' CLEAR_RC=1
    case "$scenario" in
      search-error) SEARCH_RC=1; SEARCH_OUTPUT='fixture sentinel' ;;
      locked) SEARCH_OUTPUT=$'[/1]\nfixture sentinel' ;;
      blank) SEARCH_OUTPUT=$'\n' ;;
      invalid-clear) CLEAR_RC=2 ;;
    esac
    run uninstall_linux_secrets
    [ "$status" = 1 ]
    [[ "$output" != *'fixture sentinel'* ]]
    [ -f "$uninstall_index" ]
    [ -f "$uninstall_meta/acq.usai" ]
    [ -f "$uninstall_secrets/acq.usai" ]
  done
}

@test "Linux invalid and symlinked credential records fail before mutation" {
  linux_secret_fixture
  printf 'acq.invalid key\n' > "$uninstall_index"
  run uninstall_linux_secrets check
  [ "$status" = 1 ]
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  mv "$uninstall_index" "$HOME/other-index"
  ln -s "$HOME/other-index" "$uninstall_index"
  run uninstall_linux_secrets check
  [ "$status" = 1 ]
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ ! -s "$CALLS" ]
}
