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
  [ -z "${INSERT_METADATA:-}" ] || mkdir -p "$INSERT_METADATA/.git"
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
  assert_equal "$(find "$_ACQ_KIT_FETCH_ROOT" -mindepth 1 -print)" ''
  run env WRONG_REVISION=1 bash -c '. "$REPO_ROOT/acq.backends/kit-translate.sh"; _ACQ_KIT_FETCH_ROOT=$1; kit_translate_fetch "$REF" "$2"' _ "$_ACQ_KIT_FETCH_ROOT" "$STUBDIR/a"
  assert_failure
  assert_output --partial 'fetched revision does not match pinned commit'
  assert_equal "$(find "$_ACQ_KIT_FETCH_ROOT" -mindepth 1 -print)" ''
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

@test "direct: failed refresh preserves payload and retries without Git metadata" {
  _ACQ_KIT_FETCH_ROOT=''
  export TMPDIR="$STUBDIR/direct-tmp"
  mkdir -p "$TMPDIR"
  local path
  path=$(kit_translate_fetch "$REF" "$STUBDIR/dest")
  assert_equal "$(cat "$path/spec.yaml")" first
  printf 'keep until success\n' > "$path/stale"
  run env FAIL_FETCH=1 bash -c '. "$REPO_ROOT/acq.backends/kit-translate.sh"; kit_translate_fetch "$REF" "$1"' _ "$STUBDIR/dest"
  assert_failure
  assert_output --partial 'failed to fetch remote kit'
  refute_output --partial 'suppressed transport detail'
  assert_equal "$(cat "$path/spec.yaml")" first
  assert_equal "$(cat "$path/stale")" 'keep until success'
  assert [ ! -e "$STUBDIR/dest/.git" ]
  assert_equal "$(find "$TMPDIR" -mindepth 1 -print)" ''
  path=$(kit_translate_fetch "${REF/$PIN/HEAD}" "$STUBDIR/dest")
  assert_equal "$(cat "$path/spec.yaml")" changed
  assert [ ! -e "$path/stale" ]
  assert [ -x "$path/files/tool" ]
  assert [ -L "$path/files/link" ]
  assert_equal "$(readlink "$path/files/link")" tool
  assert [ ! -e "$STUBDIR/dest/.git" ]
  kit_translate_fetch "${REF/$PIN/HEAD}" "$STUBDIR/dest" >/dev/null
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 5
  assert_equal "$(find "$TMPDIR" -mindepth 1 -print)" ''
}

@test "direct: materialization and wrong revision failures preserve a nonempty payload" {
  _ACQ_KIT_FETCH_ROOT=''
  mkdir -p "$STUBDIR/dest"
  printf 'old payload\n' > "$STUBDIR/dest/keep"
  run kit_translate_fetch "${REF%dir=*}dir=kits/missing" "$STUBDIR/dest"
  assert_failure
  assert_output --partial 'remote kit directory not found'
  run env WRONG_REVISION=1 bash -c '. "$REPO_ROOT/acq.backends/kit-translate.sh"; kit_translate_fetch "$REF" "$1"' _ "$STUBDIR/dest"
  assert_failure
  assert_output --partial 'fetched revision does not match pinned commit'
  assert_equal "$(cat "$STUBDIR/dest/keep")" 'old payload'
  local path
  path=$(kit_translate_fetch "$REF" "$STUBDIR/dest")
  assert_equal "$(cat "$path/spec.yaml")" first
  assert [ ! -e "$STUBDIR/dest/keep" ]
  assert [ ! -e "$STUBDIR/dest/.git" ]
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 3
}

@test "reuse: cache miss and hit refuse repositories and metadata before any fetch" {
  local bare="$STUBDIR/bare.git" mode dest
  "$ACQ_TEST_REAL_GIT" clone -q --bare "$SOURCE_REPO" "$bare"
  ln -s "$bare/objects" "$STUBDIR/metadata-alias"
  ln -s "$SOURCE_REPO" "$STUBDIR/repo-alias"
  mkdir -p "$STUBDIR/payload"
  printf 'keep\n' > "$STUBDIR/payload/sentinel"
  ln -s "$STUBDIR/payload" "$STUBDIR/payload-alias"
  # A consumer can forge this filename; it must never bless a destination.
  touch "$SOURCE_REPO/.git/acq-verified"
  cp "$SOURCE_REPO/.git/config" "$STUBDIR/config.before"
  for mode in miss hit; do
    if [ "$mode" = hit ]; then
      kit_translate_fetch "$REF" "$STUBDIR/safe" >/dev/null
      : > "$FETCH_LOG"
    fi
    for dest in "$SOURCE_REPO" "$SOURCE_REPO/new/child" \
        "$SOURCE_REPO/.git/objects" "$bare" "$bare/objects/new" \
        "$STUBDIR/metadata-alias" "$STUBDIR/metadata-alias/new" \
        "$STUBDIR/repo-alias/kits/one"; do
      run kit_translate_fetch "$REF" "$dest"
      assert_failure
      assert_output --partial 'refusing to fetch into a git repository'
    done
    for dest in '' / // /. /usr/.. "$STUBDIR/payload-alias"; do
      run kit_translate_fetch "$REF" "$dest"
      assert_failure
      assert_output --partial 'refusing to fetch into'
    done
    assert_equal "$(cat "$STUBDIR/payload/sentinel")" keep
    assert [ -L "$STUBDIR/payload-alias" ]
    assert [ ! -s "$FETCH_LOG" ]
    assert [ ! -e "$SOURCE_REPO/new" ]
    assert [ ! -e "$bare/objects/new" ]
    assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)" "$PIN2"
    assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$bare" rev-parse HEAD)" "$PIN2"
    cmp "$SOURCE_REPO/.git/config" "$STUBDIR/config.before"
  done
}

@test "fetch: hook Git environment cannot hide repositories or redirect private writes" {
  local mode dest="$STUBDIR/safe" index_before config_before
  index_before="$STUBDIR/index.before"; config_before="$STUBDIR/config.before"
  cp "$SOURCE_REPO/.git/index" "$index_before"
  cp "$SOURCE_REPO/.git/config" "$config_before"
  for mode in direct miss hit; do
    run env GIT_DIR="$SOURCE_REPO/.git" GIT_WORK_TREE="$SOURCE_REPO" \
      GIT_INDEX_FILE="$SOURCE_REPO/.git/index" GIT_COMMON_DIR="$SOURCE_REPO/.git" \
      GIT_OBJECT_DIRECTORY="$SOURCE_REPO/.git/objects" \
      GIT_CEILING_DIRECTORIES="$STUBDIR" \
      bash -c '
        . "$REPO_ROOT/acq.backends/kit-translate.sh"
        [ "$3" = direct ] || _ACQ_KIT_FETCH_ROOT=$2
        kit_translate_fetch "$REF" "$1" || exit 1
        [ "$GIT_DIR" = "$SOURCE_REPO/.git" ] || exit 1
        [ "$GIT_INDEX_FILE" = "$SOURCE_REPO/.git/index" ]
      ' _ "$dest" "$_ACQ_KIT_FETCH_ROOT" "$mode"
    assert_success
    assert_equal "$(cat "$dest/kits/one/spec.yaml")" first
    assert [ ! -e "$dest/.git" ]
    cmp "$SOURCE_REPO/.git/index" "$index_before"
    cmp "$SOURCE_REPO/.git/config" "$config_before"
    assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)" "$PIN2"
    assert_equal "$(cat "$SOURCE_REPO/kits/one/spec.yaml")" changed
  done
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
  # A bogus inherited repository must not make the real destination look safe.
  run env GIT_DIR="$STUBDIR/nonexistent.git" GIT_WORK_TREE="$STUBDIR/safe" \
    bash -c '. "$REPO_ROOT/acq.backends/kit-translate.sh"; _ACQ_KIT_FETCH_ROOT=$1; kit_translate_fetch "$REF" "$SOURCE_REPO"' _ "$_ACQ_KIT_FETCH_ROOT"
  assert_failure
  assert_output --partial 'refusing to fetch into a git repository'
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
  cmp "$SOURCE_REPO/.git/index" "$index_before"
  cmp "$SOURCE_REPO/.git/config" "$config_before"
}

@test "fetch: nested repositories and explicit-only bare layouts block direct miss and hit" {
  local root="$_ACQ_KIT_FETCH_ROOT" mode dest
  mkdir -p "$STUBDIR/nested/work" "$STUBDIR/nested/bare" "$STUBDIR/nested/gitfile/child"
  "$ACQ_TEST_REAL_GIT" clone -q "$SOURCE_REPO" "$STUBDIR/nested/work/child"
  "$ACQ_TEST_REAL_GIT" clone -q --bare "$SOURCE_REPO" "$STUBDIR/nested/bare/archive.git"
  printf 'gitdir: /missing\n' > "$STUBDIR/nested/gitfile/child/.git"
  mkdir -p "$STUBDIR/nested/link/child"
  ln -s /missing "$STUBDIR/nested/link/child/.git"
  "$ACQ_TEST_REAL_GIT" config --global safe.bareRepository explicit
  for mode in direct miss hit; do
    _ACQ_KIT_FETCH_ROOT="$root"
    [ "$mode" != direct ] || _ACQ_KIT_FETCH_ROOT=''
    if [ "$mode" = hit ]; then kit_translate_fetch "$REF" "$STUBDIR/safe" >/dev/null; fi
    : > "$FETCH_LOG"
    for dest in "$STUBDIR/nested/work" "$STUBDIR/nested/gitfile" "$STUBDIR/nested/link" \
        "$STUBDIR/nested/bare" "$STUBDIR/nested/bare/archive.git" \
        "$STUBDIR/nested/bare/archive.git/objects/new"; do
      run kit_translate_fetch "$REF" "$dest"
      assert_failure
      assert_output --partial 'refusing to fetch into a git repository'
    done
    assert [ ! -s "$FETCH_LOG" ]
    assert_equal "$(cat "$STUBDIR/nested/work/child/kits/one/spec.yaml")" changed
    assert_equal "$("$ACQ_TEST_REAL_GIT" --git-dir="$STUBDIR/nested/bare/archive.git" rev-parse HEAD)" "$PIN2"
    assert [ ! -e "$STUBDIR/nested/bare/archive.git/objects/new" ]
  done
}

@test "fetch: rechecks nested metadata after transport without following payload links" {
  mkdir -p "$STUBDIR/dest"
  printf 'keep\n' > "$STUBDIR/dest/old"
  export INSERT_METADATA="$STUBDIR/dest/new-repo"
  run kit_translate_fetch "$REF" "$STUBDIR/dest"
  assert_failure
  assert_output --partial 'refusing to fetch into a git repository'
  assert_equal "$(cat "$STUBDIR/dest/old")" keep
  assert [ -d "$INSERT_METADATA/.git" ]
  unset INSERT_METADATA
  mkdir -p "$STUBDIR/links"
  ln -s "$SOURCE_REPO" "$STUBDIR/links/repo-link"
  ln -s /missing "$STUBDIR/links/broken-link"
  kit_translate_fetch "$REF" "$STUBDIR/links" >/dev/null
  assert_equal "$(cat "$SOURCE_REPO/kits/one/spec.yaml")" changed
  assert [ -L "$STUBDIR/links/kits/one/files/link" ]
}

@test "publish: final move failure restores old bytes and retry cleans private staging" {
  local dest="$STUBDIR/dest" mode
  export TMPDIR="$STUBDIR/source-tmp"
  mkdir -p "$TMPDIR"
  export REAL_MV
  REAL_MV=$(command -v mv)
  cat > "$STUBDIR/mv" <<'MV'
#!/usr/bin/env bash
case "$2" in
  */.acq-kit-publish.*/payload)
    # Publication must not move from the source temp filesystem. Enforce the
    # sibling-stage contract even when this fixture has only one filesystem.
    [ "$(dirname "$(dirname "$2")")" = "$(dirname "$3")" ] || exit 2
    [ "${FAIL_PUBLISH:-0}" != 1 ] || exit 1 ;;
  */.acq-kit-publish.*/backup) [ "${FAIL_ROLLBACK:-0}" != 1 ] || exit 1 ;;
esac
exec "$REAL_MV" "$@"
MV
  chmod +x "$STUBDIR/mv"
  hash -r
  kit_translate_fetch "$REF" "$dest" >/dev/null
  printf 'old bytes\n' > "$dest/old"
  for mode in restored retained direct; do
    export FAIL_PUBLISH=1 FAIL_ROLLBACK=0
    [ "$mode" != retained ] || export FAIL_ROLLBACK=1
    [ "$mode" != direct ] || _ACQ_KIT_FETCH_ROOT=''
    run kit_translate_fetch "$REF" "$dest"
    assert_failure
    assert_output --partial 'failed to publish remote kit'
    local stages=("$STUBDIR"/.acq-kit-publish.*)
    if [ "$mode" != retained ]; then
      assert_equal "$(cat "$dest/old")" 'old bytes'
      assert_equal "$(cat "$dest/kits/one/spec.yaml")" first
      assert [ ! -e "${stages[0]}" ]
    else
      assert_output --partial 'previous payload retained at'
      assert_equal "$(cat "${stages[0]}/backup/old")" 'old bytes'
      assert_equal "$(cat "${stages[0]}/backup/kits/one/spec.yaml")" first
      "$REAL_MV" -- "${stages[0]}/backup" "$dest"
      rm -rf -- "${stages[0]}"
    fi
  done
  unset FAIL_PUBLISH FAIL_ROLLBACK
  kit_translate_fetch "$REF" "$dest" >/dev/null
  assert [ ! -e "$dest/old" ]
  assert_equal "$(cat "$dest/kits/one/spec.yaml")" first
  local stages=("$STUBDIR"/.acq-kit-publish.*)
  assert [ ! -e "${stages[0]}" ]
  assert_equal "$(find "$TMPDIR" -mindepth 1 -print)" ''
}
