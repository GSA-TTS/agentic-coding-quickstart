#!/usr/bin/env bats
# shellcheck shell=bats
# Exercise the actual MSB fetch entry point against real offline Git objects.
load 'helper'

setup() {
  acq_setup_stubs
  unset ACQ_MSB_KIT_LOCAL_DIR FAIL_FETCH
  export ACQ_MSB_KIT_CACHE="$STUBDIR/custom cache" FETCH_LOG="$STUBDIR/fetch.log"
  export SOURCE_REPO="$STUBDIR/source" CONFIG_EXECUTED="$STUBDIR/config-executed"
  # shellcheck source=acq.backends/msb.sh
  . "$REPO_ROOT/acq.backends/msb.sh"
  mkdir -p "$SOURCE_REPO/kits/one/files"
  printf 'first\n' > "$SOURCE_REPO/kits/one/spec.yaml"
  printf '#!/bin/sh\n' > "$SOURCE_REPO/kits/one/files/tool"
  chmod +x "$SOURCE_REPO/kits/one/files/tool"
  ln -s tool "$SOURCE_REPO/kits/one/files/link"
  printf 'spec.yaml filter=legacy\n' > "$SOURCE_REPO/kits/one/.gitattributes"
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" init -q --template=
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" add .
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" -c commit.gpgsign=false \
    -c user.name=Fixture -c user.email=fixture@example.test commit -qm first
  PIN=$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
  REF="git+https://example.test/kits.git#ref=$PIN&dir=kits/one"
  # Historical layout is deliberately explicit, not derived from the new code.
  LEGACY="$ACQ_MSB_KIT_CACHE/git_https___example.test_kits.git_ref_${PIN}_dir_kits_one"
  export PIN REF LEGACY
  _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
  cat > "$STUBDIR/git" <<'GIT'
#!/usr/bin/env bash
args=("$@")
while [ "${1:-}" = -c ]; do shift 2; done
if [ "${1:-}" = fetch ]; then
  printf 'fetch\n' >> "$FETCH_LOG"
  [ "${FAIL_FETCH:-0}" != 1 ] || exit 1
  exec "$ACQ_TEST_REAL_GIT" -c protocol.file.allow=always fetch --depth 1 "$SOURCE_REPO" "${@: -1}"
fi
exec "$ACQ_TEST_REAL_GIT" "${args[@]}"
GIT
  chmod +x "$STUBDIR/git"
  hash -r
}

teardown() { acq_teardown_stubs; }

_seed_legacy_cache() {
  mkdir -p "$LEGACY"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" init -q --template=
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" remote add origin "$SOURCE_REPO"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config core.sparseCheckout true
  mkdir -p "$LEGACY/.git/info"
  printf 'kits/one/*\n' > "$LEGACY/.git/info/sparse-checkout"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" -c protocol.file.allow=always fetch -q --depth 1 origin "$PIN"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" -c core.hooksPath=/dev/null checkout -q FETCH_HEAD
  chmod 750 "$LEGACY" "$LEGACY/.git"
  chmod 640 "$LEGACY/.git/config"
}

_legacy_modes() (
  cd "$LEGACY" || exit 1
  find . -print | LC_ALL=C sort | while IFS= read -r entry; do
    printf '%s %s\n' "$(LC_ALL=C ls -ld "$entry" | cut -c1-10)" "$entry"
  done
)

_snapshot_legacy() {
  LEGACY_HEAD=$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" rev-parse HEAD)
  LEGACY_REFS=$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" show-ref --head)
  cp -pR "$LEGACY" "$STUBDIR/legacy-before"
  _legacy_modes > "$STUBDIR/modes-before"
}

_assert_legacy_unchanged() {
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" rev-parse HEAD)" "$LEGACY_HEAD"
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" show-ref --head)" "$LEGACY_REFS"
  cmp "$LEGACY/.git/config" "$STUBDIR/legacy-before/.git/config"
  diff -r "$STUBDIR/legacy-before" "$LEGACY"
  _legacy_modes > "$STUBDIR/modes-after"
  cmp "$STUBDIR/modes-before" "$STUBDIR/modes-after"
}

_assert_payload() {
  local path="$1" expected="$2" cache
  assert_equal "$(cat "$path/spec.yaml")" "$expected"
  assert [ -x "$path/files/tool" ]
  assert [ -L "$path/files/link" ]
  assert_equal "$(readlink "$path/files/link")" tool
  assert [ "$path" != "$LEGACY/kits/one" ]
  cache=$(cd "$ACQ_MSB_KIT_CACHE" && pwd -P)
  case "$path" in "$cache/"*) ;; *) return 1 ;; esac
  assert_equal "$(find "${path%/kits/one}" -name .git -print)" ''
}

@test "msb cache: real legacy checkout survives upgrade and pinned reuse without transport" {
  _seed_legacy_cache
  _snapshot_legacy
  local path again
  path=$(_acq_msb_fetch_kit "$REF")
  _assert_payload "$path" first
  _assert_legacy_unchanged
  export FAIL_FETCH=1
  again=$(_acq_msb_fetch_kit "$REF")
  assert_equal "$again" "$path"
  _assert_payload "$again" first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _assert_legacy_unchanged
}

@test "msb cache: symbolic refs refresh payload while preserving legacy checkout" {
  _seed_legacy_cache
  _snapshot_legacy
  local path again
  path=$(_acq_msb_fetch_kit "${REF/$PIN/HEAD}")
  _assert_payload "$path" first
  printf 'changed\n' > "$SOURCE_REPO/kits/one/spec.yaml"
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" add .
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" -c commit.gpgsign=false \
    -c user.name=Fixture -c user.email=fixture@example.test commit -qm second
  again=$(_acq_msb_fetch_kit "${REF/$PIN/HEAD}")
  assert_equal "$again" "$path"
  _assert_payload "$again" changed
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
  _assert_legacy_unchanged
}

@test "msb cache: direct calls upgrade without an invocation reuse root" {
  _ACQ_KIT_FETCH_ROOT=''
  _seed_legacy_cache
  _snapshot_legacy
  local path
  path=$(_acq_msb_fetch_kit "$REF")
  _assert_payload "$path" first
  _assert_legacy_unchanged
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
}

@test "msb cache: failed upgrade retries without adopting or deleting legacy metadata" {
  _seed_legacy_cache
  _snapshot_legacy
  export FAIL_FETCH=1
  run _acq_msb_fetch_kit "$REF"
  assert_failure
  assert_output --partial 'failed to fetch remote kit'
  _assert_legacy_unchanged
  unset FAIL_FETCH
  local path
  path=$(_acq_msb_fetch_kit "$REF")
  _assert_payload "$path" first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 3
  _assert_legacy_unchanged
}

@test "msb cache: legacy executable configuration is neither adopted nor invoked" {
  _seed_legacy_cache
  mkdir -p "$STUBDIR/legacy-hooks"
  printf '#!/bin/sh\n: > "$CONFIG_EXECUTED"\n' > "$STUBDIR/legacy-hooks/post-checkout"
  chmod +x "$STUBDIR/legacy-hooks/post-checkout"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config core.hooksPath "$STUBDIR/legacy-hooks"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config filter.legacy.smudge ': > "$CONFIG_EXECUTED"; cat'
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config core.fsmonitor "$STUBDIR/legacy-hooks/post-checkout"
  _snapshot_legacy
  local path
  path=$(_acq_msb_fetch_kit "$REF")
  _assert_payload "$path" first
  assert [ ! -e "$CONFIG_EXECUTED" ]
  _assert_legacy_unchanged
}

@test "msb cache: namespace symlinks fail before transport or target mutation" {
  _seed_legacy_cache
  _snapshot_legacy
  mkdir -p "$STUBDIR/target"
  printf 'keep\n' > "$STUBDIR/target/sentinel"
  local target
  for target in "$STUBDIR/target" "$STUBDIR/missing" "$LEGACY"; do
    ln -s "$target" "$ACQ_MSB_KIT_CACHE/payload-v2"
    run _acq_msb_fetch_kit "$REF"
    assert_failure
    assert_output --partial 'refusing a symlink kit cache namespace'
    assert [ ! -s "$FETCH_LOG" ]
    assert_equal "$(readlink "$ACQ_MSB_KIT_CACHE/payload-v2")" "$target"
    assert_equal "$(cat "$STUBDIR/target/sentinel")" keep
    assert [ ! -e "$STUBDIR/missing" ]
    _assert_legacy_unchanged
    rm "$ACQ_MSB_KIT_CACHE/payload-v2"
  done
}

@test "msb cache: local kits and offline override do not depend on payload namespace" {
  mkdir -p "$ACQ_MSB_KIT_CACHE"
  ln -s "$STUBDIR/missing" "$ACQ_MSB_KIT_CACHE/payload-v2"
  assert_equal "$(_acq_msb_fetch_kit "$SOURCE_REPO/kits/one")" "$SOURCE_REPO/kits/one"
  export ACQ_MSB_KIT_LOCAL_DIR="$SOURCE_REPO/kits/one"
  assert_equal "$(_acq_msb_fetch_kit "$REF")" "$ACQ_MSB_KIT_LOCAL_DIR"
  assert [ ! -s "$FETCH_LOG" ]
}
