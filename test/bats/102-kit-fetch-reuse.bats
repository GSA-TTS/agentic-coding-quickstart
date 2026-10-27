#!/usr/bin/env bats
# shellcheck shell=bats
# Real local Git objects and transport counting exercise invocation reuse offline.
load 'helper'

setup() {
  acq_setup_stubs
  export FETCH_LOG="$STUBDIR/fetch.log" SOURCE_REPO="$STUBDIR/source"
  mkdir -p "$SOURCE_REPO/kits/one/files" "$SOURCE_REPO/kits/two"
  printf 'first\n' > "$SOURCE_REPO/kits/one/spec.yaml"
  printf '#!/bin/sh\n' > "$SOURCE_REPO/kits/one/files/tool"
  chmod +x "$SOURCE_REPO/kits/one/files/tool"
  printf 'second\n' > "$SOURCE_REPO/kits/two/spec.yaml"
  printf 'root kit\n' > "$SOURCE_REPO/spec.yaml"
  printf 'tracked index\n' > "$SOURCE_REPO/index"
  printf 'tracked marker name\n' > "$SOURCE_REPO/verified"
  printf 'spec.yaml export-ignore\n' > "$SOURCE_REPO/kits/one/.gitattributes"
  ln -s tool "$SOURCE_REPO/kits/one/files/link"
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" init -q
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" add .
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.test commit -qm first
  PIN=$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
  export PIN
  printf 'changed\n' > "$SOURCE_REPO/kits/one/spec.yaml"
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" add .
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.test commit -qm second
  PIN2=$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
  export PIN2
  cat > "$STUBDIR/git" <<'GIT'
#!/usr/bin/env bash
args=("$@")
anon=0
while [ "${1:-}" = -c ]; do anon=1; shift 2; done
if [ "${1:-}" = fetch ]; then
  printf 'fetch\n' >> "$FETCH_LOG"
  if [ "${FAIL_FETCH:-0}" = 1 ] || { [ "${AUTH_ONLY:-0}" = 1 ] && [ "$anon" = 1 ]; }; then
    printf 'suppressed transport detail\n' >&2
    exit 1
  fi
  revision="${@: -1}"
  [ "${WRONG_REVISION:-0}" != 1 ] || revision="$PIN2"
  exec "$ACQ_TEST_REAL_GIT" -c protocol.file.allow=always fetch --depth 1 "$SOURCE_REPO" "$revision"
fi
exec "$ACQ_TEST_REAL_GIT" "${args[@]}"
GIT
  chmod +x "$STUBDIR/git"
  hash -r
  _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
  export REF="git+https://example.test/kits.git#ref=$PIN&dir=kits/one"
}

teardown() { acq_teardown_stubs; }

@test "reuse: eight materializations share one real pinned fetch across command substitutions" {
  local i path
  for i in 1 2 3 4 5 6 7 8; do
    path=$(kit_translate_fetch "$REF" "$STUBDIR/dest-$i")
    assert_equal "$(cat "$path/spec.yaml")" first
    assert [ -x "$path/files/tool" ]
    assert [ -L "$path/files/link" ]
    printf 'consumer edit\n' > "$path/spec.yaml"
  done
  path=$(kit_translate_fetch "${REF%dir=*}dir=kits/two" "$STUBDIR/other-kit")
  assert_equal "$(cat "$path/spec.yaml")" second
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
}

@test "reuse: repository URL and full revision both distinguish sources" {
  kit_translate_fetch "$REF" "$STUBDIR/a" >/dev/null
  touch "$STUBDIR/a/kits/one/stale"
  kit_translate_fetch "${REF/example.test/other.test}" "$STUBDIR/b" >/dev/null
  local path
  path=$(kit_translate_fetch "${REF/$PIN/$PIN2}" "$STUBDIR/a")
  assert_equal "$(cat "$path/spec.yaml")" changed
  assert [ ! -e "$path/stale" ]
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 3
}

@test "reuse: root kits and normalized subdirectories retain tracked payload" {
  local path
  path=$(kit_translate_fetch "${REF%dir=*}dir=." "$STUBDIR/a")
  assert_equal "$(cat "$path/spec.yaml")" 'root kit'
  assert_equal "$(cat "$path/index")" 'tracked index'
  path=$(kit_translate_fetch "${REF%dir=*}dir=././kits//./one/." "$STUBDIR/b")
  assert_equal "$(cat "$path/spec.yaml")" first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
}

@test "reuse: a materialization failure preserves the previous destination" {
  local path
  path=$(kit_translate_fetch "$REF" "$STUBDIR/a")
  run kit_translate_fetch "${REF%dir=*}dir=kits/missing" "$STUBDIR/a"
  assert_failure
  assert_equal "$(cat "$path/spec.yaml")" first
}

@test "reuse: another invocation root and symbolic refs fetch again" {
  kit_translate_fetch "$REF" "$STUBDIR/a" >/dev/null
  _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
  kit_translate_fetch "$REF" "$STUBDIR/a" >/dev/null
  kit_translate_fetch "${REF/$PIN/HEAD}" "$STUBDIR/a" >/dev/null
  kit_translate_fetch "${REF/$PIN/HEAD}" "$STUBDIR/a" >/dev/null
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 4
}

@test "reuse: authenticated fallback is reused only after successful verification" {
  export AUTH_ONLY=1
  kit_translate_fetch "$REF" "$STUBDIR/a" >/dev/null
  kit_translate_fetch "$REF" "$STUBDIR/b" >/dev/null
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
}

@test "reuse: failed fetch and wrong revision cannot publish a successful source" {
  run env FAIL_FETCH=1 bash -c '. "$REPO_ROOT/acq.backends/kit-translate.sh"; _ACQ_KIT_FETCH_ROOT=$1; kit_translate_fetch "$REF" "$2"' _ "$_ACQ_KIT_FETCH_ROOT" "$STUBDIR/a"
  assert_failure
  assert_output --partial 'failed to fetch remote kit'
  refute_output --partial 'suppressed transport detail'
  run env WRONG_REVISION=1 bash -c '. "$REPO_ROOT/acq.backends/kit-translate.sh"; _ACQ_KIT_FETCH_ROOT=$1; kit_translate_fetch "$REF" "$2"' _ "$_ACQ_KIT_FETCH_ROOT" "$STUBDIR/a"
  assert_failure
  assert_output --partial 'fetched revision does not match pinned commit'
  local path
  path=$(kit_translate_fetch "$REF" "$STUBDIR/a")
  assert_equal "$(cat "$path/spec.yaml")" first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 4
}

@test "reuse: cache hits still reject unsafe or missing subdirectories and credential URLs" {
  kit_translate_fetch "$REF" "$STUBDIR/a" >/dev/null
  run kit_translate_fetch "${REF%dir=*}dir=../escape" "$STUBDIR/b"
  assert_failure
  run kit_translate_fetch "${REF%dir=*}dir=kits/missing" "$STUBDIR/b"
  assert_failure
  assert_output --partial 'remote kit directory not found'
  run kit_translate_fetch "${REF/https:\/\//https://user:placeholder@}" "$STUBDIR/b"
  assert_failure
  refute_output --partial placeholder
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
}

@test "reuse: executable dispatch cleans private state after success and failure" {
  mkdir -p "$STUBDIR/tmp"
  run env TMPDIR="$STUBDIR/tmp" "$ACQ" version
  assert_success
  run env TMPDIR="$STUBDIR/tmp" "$ACQ" --backend invalid version
  assert_failure
  local entries=("$STUBDIR/tmp"/acq-kit-fetch.*)
  assert [ ! -e "${entries[0]}" ]
}
