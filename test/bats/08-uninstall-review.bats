#!/usr/bin/env bats

# Standalone fixtures never source the wizard or contact the desktop keyring.
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/uninstall-review.XXXXXX")"
  FIXTURE="$(cd -P "$FIXTURE" && pwd -P)"
  export HOME="$FIXTURE/home"
  export PATH="/usr/bin:/bin"
  mkdir -p "$HOME"
  . "$REPO_ROOT/acq.backends/uninstall-files.sh"
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
  uninstall_index="$HOME/secret-index"
  uninstall_meta="$HOME/secret-meta"
  uninstall_secrets="$HOME/secrets"
  mkdir -p "$uninstall_meta" "$uninstall_secrets"
  CALLS="$FIXTURE/calls"
  : > "$CALLS"
  unset CLEAR_RC SEARCH_RC SEARCH_OUTPUT
}

remote_fixture() {
  uninstall_clones="$HOME/clones"
  origin="$HOME/project"
  scratch="$uninstall_clones/example/project"
  config="$origin/.git/config"
  mkdir -p "$scratch/.git" "$origin/.git"
  printf '%s\n' "$origin" > "$uninstall_clones/example/.origin"
  git config --file "$config" remote.sandbox-example.url "$scratch"
}

assert_remote_preserved() {
  cp "$config" "$FIXTURE/config-before"
  run uninstall_clone_remotes
  [ "$status" = 1 ]
  cmp "$config" "$FIXTURE/config-before"
}

@test "remote removes exact scratch fetch URLs and matching push URLs" {
  remote_fixture
  git config --file "$config" --add remote.sandbox-example.url "$scratch"
  git config --file "$config" --add remote.sandbox-example.pushurl "$scratch"
  git config --file "$config" --add remote.sandbox-example.pushurl "$scratch"
  git config --file "$config" remote.origin.url unrelated
  run uninstall_clone_remotes
  [ "$status" = 0 ]
  run git config --file "$config" --get-regexp '^remote.sandbox-example\.'
  [ "$status" = 1 ]
  [ "$(git config --file "$config" remote.origin.url)" = unrelated ]
}

@test "remote preserves customized first fetch URL" {
  remote_fixture
  git config --file "$config" remote.sandbox-example.url customized
  git config --file "$config" --add remote.sandbox-example.url "$scratch"
  assert_remote_preserved
}

@test "remote preserves customized last fetch URL" {
  remote_fixture
  git config --file "$config" --add remote.sandbox-example.url customized
  assert_remote_preserved
}

@test "remote preserves customized push URL even with matching final push URL" {
  remote_fixture
  git config --file "$config" --add remote.sandbox-example.pushurl customized
  git config --file "$config" --add remote.sandbox-example.pushurl "$scratch"
  assert_remote_preserved
}

@test "remote preserves empty push URL" {
  remote_fixture
  git config --file "$config" --add remote.sandbox-example.pushurl ''
  assert_remote_preserved
}

@test "remote preserves customized last push URL" {
  remote_fixture
  git config --file "$config" --add remote.sandbox-example.pushurl "$scratch"
  git config --file "$config" --add remote.sandbox-example.pushurl customized
  assert_remote_preserved
}

@test "remote preserves a push-only remote without fetch ownership evidence" {
  remote_fixture
  git config --file "$config" --unset-all remote.sandbox-example.url
  git config --file "$config" remote.sandbox-example.pushurl "$scratch"
  assert_remote_preserved
}

@test "remote already absent remains an idempotent success" {
  remote_fixture
  git config --file "$config" --remove-section remote.sandbox-example
  run uninstall_clone_remotes
  [ "$status" = 0 ]
}

@test "remote preserves fetch URL with a trailing newline" {
  remote_fixture
  git config --file "$config" remote.sandbox-example.url "$scratch"$'\n'
  assert_remote_preserved
}

@test "remote preserves URL containing multiple newline-separated paths" {
  remote_fixture
  git config --file "$config" remote.sandbox-example.url "$scratch"$'\n'"$scratch"
  assert_remote_preserved
}

@test "remote preserves ambiguous scratch clone directories" {
  remote_fixture
  mkdir -p "$uninstall_clones/example/other/.git"
  assert_remote_preserved
}

@test "remote preserves symlinked scratch clone" {
  remote_fixture
  mv "$scratch" "$HOME/moved"
  ln -s "$HOME/moved" "$scratch"
  assert_remote_preserved
}

@test "remote preserves malformed Git config" {
  remote_fixture
  printf '[broken\n' >> "$config"
  assert_remote_preserved
}

@test "remote ignores includes rather than consuming included remote URLs" {
  remote_fixture
  git config --file "$FIXTURE/included" remote.sandbox-example.url customized
  git config --file "$config" include.path "$FIXTURE/included"
  run uninstall_clone_remotes
  [ "$status" = 0 ]
  [ "$(git config --file "$FIXTURE/included" remote.sandbox-example.url)" = customized ]
}

@test "Linux credential keys are deduplicated across index and metadata" {
  printf 'acq.usai\nacq.usai\nacq.github' > "$uninstall_index"
  touch "$uninstall_meta/acq.usai" "$uninstall_meta/acq.github" "$uninstall_meta/acq.gitlab"
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ "$(wc -l < "$CALLS")" -eq 3 ]
  [ "$(grep -c '^clear acq_key acq.usai$' "$CALLS")" -eq 1 ]
  [ "$(grep -c '^clear acq_key acq.github$' "$CALLS")" -eq 1 ]
  [ "$(grep -c '^clear acq_key acq.gitlab$' "$CALLS")" -eq 1 ]
}

@test "Linux metadata-only file fallback is skipped even when secret-tool is available" {
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ ! -s "$CALLS" ]
  [ -f "$uninstall_secrets/acq.usai" ]
}

@test "Linux metadata-only file fallback is skipped when secret-tool is unavailable" {
  uninstall_secret_tool_available() { return 1; }
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ ! -s "$CALLS" ]
}

@test "Linux indexed migration clears keyring even with an old file fallback" {
  printf 'acq.usai\nacq.usai\n' > "$uninstall_index"
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ "$(cat "$CALLS")" = 'clear acq_key acq.usai' ]
  [ -f "$uninstall_secrets/acq.usai" ]
}

@test "Linux indexed migration verifies absence after a clear no-match" {
  printf 'acq.usai\n' > "$uninstall_index"
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  CLEAR_RC=1
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ "$(cat "$CALLS")" = $'clear acq_key acq.usai\nsearch --all acq_key acq.usai' ]
}

@test "Linux indexed migration preserves both copies after clear and search errors" {
  printf 'acq.usai\n' > "$uninstall_index"
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  CLEAR_RC=1 SEARCH_RC=1
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ -f "$uninstall_index" ]
  [ -f "$uninstall_meta/acq.usai" ]
  [ -f "$uninstall_secrets/acq.usai" ]
  [ "$(cat "$CALLS")" = $'clear acq_key acq.usai\nsearch --all acq_key acq.usai' ]
}

@test "Linux indexed migration fails closed without secret-tool despite fallback" {
  uninstall_secret_tool_available() { return 1; }
  printf 'acq.usai\n' > "$uninstall_index"
  touch "$uninstall_meta/acq.usai" "$uninstall_secrets/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ -f "$uninstall_index" ]
  [ -f "$uninstall_meta/acq.usai" ]
  [ -f "$uninstall_secrets/acq.usai" ]
  [ ! -s "$CALLS" ]
}

@test "Linux unresolved metadata fails without secret-tool" {
  uninstall_secret_tool_available() { return 1; }
  touch "$uninstall_meta/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ -f "$uninstall_meta/acq.usai" ]
}

@test "Linux clear no-match succeeds only after successful empty search" {
  printf 'acq.usai\n' > "$uninstall_index"
  CLEAR_RC=1
  run uninstall_linux_secrets
  [ "$status" = 0 ]
  [ "$(cat "$CALLS")" = $'clear acq_key acq.usai\nsearch --all acq_key acq.usai' ]
}

@test "Linux clear failure plus search error preserves records" {
  printf 'acq.usai\n' > "$uninstall_index"
  CLEAR_RC=1 SEARCH_RC=1
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ -f "$uninstall_index" ]
}

@test "Linux surviving locked item blocks cleanup without exposing output" {
  printf 'acq.usai\n' > "$uninstall_index"
  CLEAR_RC=1 SEARCH_OUTPUT=$'[/1]\nlabel = fixture item'
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [[ "$output" != *'fixture item'* ]]
  [[ "$output" != *'[/1]'* ]]
}

@test "Linux search output is consumed even on a failing search" {
  printf 'acq.usai\n' > "$uninstall_index"
  CLEAR_RC=1 SEARCH_RC=1 SEARCH_OUTPUT='fixture output sentinel'
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [[ "$output" != *'fixture output sentinel'* ]]
}

@test "Linux blank item output is not mistaken for an empty search" {
  printf 'acq.usai\n' > "$uninstall_index"
  CLEAR_RC=1 SEARCH_OUTPUT=$'\n'
  run uninstall_linux_secrets
  [ "$status" = 1 ]
}

@test "Linux invalid clear status never becomes successful absence" {
  printf 'acq.usai\n' > "$uninstall_index"
  CLEAR_RC=2
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "Linux fallback symlink is never accepted as a file credential" {
  touch "$HOME/unrelated"
  ln -s "$HOME/unrelated" "$uninstall_secrets/acq.usai"
  touch "$uninstall_meta/acq.usai"
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ ! -s "$CALLS" ]
}

@test "Linux invalid and symlinked index records fail closed" {
  printf 'acq.invalid key\n' > "$uninstall_index"
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ ! -s "$CALLS" ]
  mv "$uninstall_index" "$HOME/other-index"
  ln -s "$HOME/other-index" "$uninstall_index"
  run uninstall_linux_secrets
  [ "$status" = 1 ]
  [ ! -s "$CALLS" ]
}
