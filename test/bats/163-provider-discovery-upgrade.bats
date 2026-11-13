#!/usr/bin/env bats
# shellcheck shell=bats
# Exercise provider discovery through the real fetcher with offline Git objects.
load 'helper'

setup() {
  acq_setup_stubs
  unset FAIL_FETCH ACQ_DEBUG
  export XDG_CACHE_HOME="$STUBDIR/custom cache" FETCH_LOG="$STUBDIR/fetch.log"
  export SOURCE_REPO="$STUBDIR/source" CONFIG_EXECUTED="$STUBDIR/config-executed"
  REPO='example.test/owner/kits'
  mkdir -p "$SOURCE_REPO/kits/alpha-provider" "$SOURCE_REPO/kits/not-a-provider"
  printf '{}\n' > "$SOURCE_REPO/kits/alpha-provider/provider-input.json"
  printf 'first\n' > "$SOURCE_REPO/kits/alpha-provider/spec.yaml"
  printf 'ordinary kit\n' > "$SOURCE_REPO/kits/not-a-provider/spec.yaml"
  printf 'provider-input.json filter=legacy\n' > "$SOURCE_REPO/kits/alpha-provider/.gitattributes"
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" init -q --template=
  _commit_source first
  PIN=$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
  NAMESPACE="$XDG_CACHE_HOME/acq/kit-sources/payload-v2"
  _discovery_paths HEAD
  _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
  cat > "$STUBDIR/git" <<'GIT'
#!/usr/bin/env bash
args=("$@")
while [ "${1:-}" = -c ]; do shift 2; done
if [ "${1:-}" = fetch ]; then
  printf 'fetch\n' >> "$FETCH_LOG"
  [ "${FAIL_FETCH:-0}" != 1 ] || exit 1
  GIT_ALLOW_PROTOCOL=file exec "$ACQ_TEST_REAL_GIT" -c protocol.file.allow=always fetch --depth 1 "$SOURCE_REPO" "${@: -1}"
fi
exec "$ACQ_TEST_REAL_GIT" "${args[@]}"
GIT
  chmod +x "$STUBDIR/git"
  hash -r
}

teardown() { acq_teardown_stubs; }

_commit_source() {
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" add .
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" -c commit.gpgsign=false \
    -c user.name=Fixture -c user.email=fixture@example.test commit -qm "$1"
}

_discovery_paths() {
  REF="$1"
  local seed
  # Reproduce the historical repo@ref checksum layout independently of the caller.
  seed=$(printf '%s@%s' "$REPO" "$REF" | cksum | cut -d' ' -f1)
  LEGACY="$XDG_CACHE_HOME/acq/kit-sources/$seed"
  PAYLOAD="$NAMESPACE/$seed"
}

_seed_legacy_cache() {
  mkdir -p "$LEGACY"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" init -q --template=
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" remote add origin "$SOURCE_REPO"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config core.sparseCheckout true
  mkdir -p "$LEGACY/.git/info"
  printf 'kits/*\n' > "$LEGACY/.git/info/sparse-checkout"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" -c protocol.file.allow=always fetch -q --depth 1 origin "$PIN"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" -c core.hooksPath=/dev/null checkout -q FETCH_HEAD
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" update-ref refs/heads/preserved "$PIN"
  printf 'user edits\n' > "$LEGACY/kits/alpha-provider/spec.yaml"
  printf 'untracked content\n' > "$LEGACY/keep"
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

_assert_discovery() {
  run acq_kit_source_provider_kits "$REPO" "$REF" kits
  assert_success
  assert_output "$(printf '%s\t%s\t%s\tkits' "$1" "$REPO" "$REF")"
  assert [ -f "$PAYLOAD/kits/$1/provider-input.json" ]
  assert_equal "$(find "$PAYLOAD" -name .git -print)" ''
}

@test "provider discovery: symbolic cache upgrade refreshes payload and preserves legacy repository" {
  _seed_legacy_cache
  _snapshot_legacy
  _assert_discovery alpha-provider
  assert_equal "$(cat "$PAYLOAD/kits/alpha-provider/spec.yaml")" first
  _assert_legacy_unchanged
  mv "$SOURCE_REPO/kits/alpha-provider" "$SOURCE_REPO/kits/beta-provider"
  _commit_source second
  _assert_discovery beta-provider
  assert [ ! -e "$PAYLOAD/kits/alpha-provider" ]
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
  _assert_legacy_unchanged
}

@test "provider discovery: failed upgrade stays best effort and retries without legacy fallback" {
  _seed_legacy_cache
  _snapshot_legacy
  export FAIL_FETCH=1
  run acq_kit_source_provider_kits "$REPO" "$REF" kits
  assert_success
  assert_output ''
  assert [ ! -e "$PAYLOAD/kits" ]
  _assert_legacy_unchanged
  unset FAIL_FETCH
  _assert_discovery alpha-provider
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 3
  _assert_legacy_unchanged
}

@test "provider discovery: failed symbolic refresh preserves payload and retries normally" {
  _seed_legacy_cache
  _snapshot_legacy
  _assert_discovery alpha-provider
  cp -pR "$PAYLOAD" "$STUBDIR/payload-before"
  export FAIL_FETCH=1
  run acq_kit_source_provider_kits "$REPO" "$REF" kits
  assert_success
  assert_output ''
  diff -r "$STUBDIR/payload-before" "$PAYLOAD"
  unset FAIL_FETCH
  mv "$SOURCE_REPO/kits/alpha-provider" "$SOURCE_REPO/kits/beta-provider"
  _commit_source second
  _assert_discovery beta-provider
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 4
  _assert_legacy_unchanged
}

@test "provider discovery: pinned upgrade reuses private source without adopting legacy metadata" {
  _discovery_paths "$PIN"
  _seed_legacy_cache
  _snapshot_legacy
  _assert_discovery alpha-provider
  export FAIL_FETCH=1
  _assert_discovery alpha-provider
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _assert_legacy_unchanged
}

@test "provider discovery: direct upgrade never invokes legacy executable configuration" {
  _ACQ_KIT_FETCH_ROOT=''
  _seed_legacy_cache
  mkdir -p "$STUBDIR/legacy-hooks"
  printf '#!/bin/sh\n: > "$CONFIG_EXECUTED"\n' > "$STUBDIR/legacy-hooks/post-checkout"
  chmod +x "$STUBDIR/legacy-hooks/post-checkout"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config core.hooksPath "$STUBDIR/legacy-hooks"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config filter.legacy.smudge ': > "$CONFIG_EXECUTED"; cat'
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config core.fsmonitor "$STUBDIR/legacy-hooks/post-checkout"
  _snapshot_legacy
  _assert_discovery alpha-provider
  assert [ ! -e "$CONFIG_EXECUTED" ]
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _assert_legacy_unchanged
}

@test "provider discovery: namespace symlinks yield no kits without transport or target mutation" {
  _seed_legacy_cache
  _snapshot_legacy
  mkdir -p "$STUBDIR/target"
  printf 'keep\n' > "$STUBDIR/target/sentinel"
  local target
  for target in "$STUBDIR/target" "$STUBDIR/missing" "$LEGACY"; do
    ln -s "$target" "$NAMESPACE"
    run acq_kit_source_provider_kits "$REPO" "$REF" kits
    assert_success
    assert_output ''
    assert [ ! -s "$FETCH_LOG" ]
    assert_equal "$(readlink "$NAMESPACE")" "$target"
    assert_equal "$(cat "$STUBDIR/target/sentinel")" keep
    assert_equal "$(find "$STUBDIR/target" -mindepth 1 -print)" "$STUBDIR/target/sentinel"
    assert [ ! -e "$STUBDIR/missing" ]
    _assert_legacy_unchanged
    rm "$NAMESPACE"
  done
}

@test "provider discovery: repository namespace yields no kits without mutation or legacy fallback" {
  _seed_legacy_cache
  _snapshot_legacy
  mkdir -p "$NAMESPACE"
  "$ACQ_TEST_REAL_GIT" -C "$NAMESPACE" init -q --template=
  cp -pR "$NAMESPACE" "$STUBDIR/namespace-before"
  run acq_kit_source_provider_kits "$REPO" "$REF" kits
  assert_success
  assert_output ''
  assert [ ! -s "$FETCH_LOG" ]
  diff -r "$STUBDIR/namespace-before" "$NAMESPACE"
  _assert_legacy_unchanged
}

@test "provider discovery: repository in payload destination is preserved rather than adopted" {
  _seed_legacy_cache
  _snapshot_legacy
  mkdir -p "$PAYLOAD"
  "$ACQ_TEST_REAL_GIT" -C "$PAYLOAD" init -q --bare --template=
  cp -pR "$PAYLOAD" "$STUBDIR/payload-before"
  run acq_kit_source_provider_kits "$REPO" "$REF" kits
  assert_success
  assert_output ''
  assert [ ! -s "$FETCH_LOG" ]
  diff -r "$STUBDIR/payload-before" "$PAYLOAD"
  _assert_legacy_unchanged
}
