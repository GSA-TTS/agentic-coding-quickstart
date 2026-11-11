#!/usr/bin/env bats
# shellcheck shell=bats
# Exercise the SBX caller with real Git objects and translation, offline.
load 'helper'

setup() {
  acq_setup_stubs
  unset ACQ_SBX_KIT_PASSTHROUGH FAIL_FETCH ACQ_DEBUG
  export ACQ_SBX_KIT_CACHE="$STUBDIR/sbx-cache"
  export SOURCE_REPO="$STUBDIR/source" FETCH_LOG="$STUBDIR/fetch.log"
  mkdir -p "$SOURCE_REPO/kits/one/files"
  cat > "$SOURCE_REPO/kits/one/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: upgrade-kit
files:
  - path: /home/agent/config
    mode: "0644"
    source: files/config
SPEC
  printf 'first\n' > "$SOURCE_REPO/kits/one/files/config"
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" init -q --template=
  _sbx_upgrade_commit first
  PIN=$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
  REF='git+https://example.test/kits.git#ref=HEAD&dir=kits/one'
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
  _sbx_upgrade_legacy
}

teardown() { acq_teardown_stubs; }

_sbx_upgrade_commit() {
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" add .
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" -c commit.gpgsign=false \
    -c user.name=Fixture -c user.email=fixture@example.test commit -qm "$1"
}

_sbx_upgrade_paths() {
  SLUG=$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '_')
  LEGACY="$ACQ_SBX_KIT_CACHE/fetch/$SLUG"
  PAYLOAD="$ACQ_SBX_KIT_CACHE/fetch-payload-v2/$SLUG"
  TRANSLATED="$ACQ_SBX_KIT_CACHE/v2/$SLUG"
}

_sbx_upgrade_legacy() {
  _sbx_upgrade_paths
  mkdir -p "$(dirname "$LEGACY")"
  "$ACQ_TEST_REAL_GIT" clone -q --no-hardlinks "$SOURCE_REPO" "$LEGACY"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config upgrade.sentinel preserve
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" update-ref refs/heads/sentinel "$PIN"
  printf 'uncommitted legacy bytes\n' > "$LEGACY/kits/one/files/config"
  printf 'untracked legacy bytes\n' > "$LEGACY/keep"
  SNAPSHOT=$(mktemp -d "$STUBDIR/legacy-before.XXXXXX")
  cp -R "$LEGACY/." "$SNAPSHOT/"
}

_sbx_upgrade_assert_legacy() {
  # Includes the dirty payload, config, refs, index and object bytes.
  diff -r "$SNAPSHOT" "$LEGACY"
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" rev-parse HEAD)" "$PIN"
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" config upgrade.sentinel)" preserve
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" rev-parse refs/heads/sentinel)" "$PIN"
}

_sbx_upgrade_translate() {
  _acq_sbx_translate_kit "$REF" > "$STUBDIR/result" 2> "$STUBDIR/diagnostic"
  assert_equal "$(cat "$STUBDIR/result")" "$TRANSLATED"
  assert_equal "$(kit_spec_field "$TRANSLATED/spec.yaml" schemaVersion)" 2
  assert_equal "$(cat "$TRANSLATED/files/config")" "$1"
  assert_equal "$(find "$PAYLOAD" -name .git -print)" ''
  assert_equal "$(cat "$STUBDIR/diagnostic")" ''
  _sbx_upgrade_assert_legacy
}

_sbx_upgrade_refused() {
  # A failed fetch must never hand SBX a ref that bypasses acq validation.
  run _acq_sbx_translate_kit "$REF" > "$STUBDIR/result" 2> "$STUBDIR/diagnostic"
  assert_failure
  assert_output --partial "not applying"
  _sbx_upgrade_assert_legacy
}

@test "sbx upgrade: legacy symbolic repository yields a translated neutral kit flag" {
  # shellcheck disable=SC2034  # read by sourced _acq_sbx_kit_flags
  KITS=("$REF")
  run _acq_sbx_kit_flags
  assert_success
  assert_output "$(printf '%s\n%s' --kit "$TRANSLATED")"
  assert_equal "$(kit_spec_field "$TRANSLATED/spec.yaml" schemaVersion)" 2
  assert_equal "$(cat "$TRANSLATED/files/config")" first
  assert_equal "$(find "$PAYLOAD" -name .git -print)" ''
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _sbx_upgrade_assert_legacy
}

@test "sbx upgrade: symbolic refresh replaces stale payload without touching legacy metadata" {
  _sbx_upgrade_translate first
  printf 'stale\n' > "$PAYLOAD/kits/one/stale"
  printf 'second\n' > "$SOURCE_REPO/kits/one/files/config"
  _sbx_upgrade_commit second
  _sbx_upgrade_translate second
  assert [ ! -e "$PAYLOAD/kits/one/stale" ]
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
}

@test "sbx upgrade: failed symbolic refresh preserves payload and a later call retries" {
  _sbx_upgrade_translate first
  printf 'second\n' > "$SOURCE_REPO/kits/one/files/config"
  _sbx_upgrade_commit second
  export FAIL_FETCH=1
  _sbx_upgrade_refused
  assert_equal "$(cat "$PAYLOAD/kits/one/files/config")" first
  assert_equal "$(cat "$TRANSLATED/files/config")" first
  unset FAIL_FETCH
  _sbx_upgrade_translate second
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 4
}

@test "sbx upgrade: pinned calls reuse verified source but rematerialize consumer edits" {
  REF="${REF/HEAD/$PIN}"
  _sbx_upgrade_legacy
  _sbx_upgrade_translate first
  printf 'consumer edit\n' > "$PAYLOAD/kits/one/files/config"
  printf 'consumer edit\n' > "$TRANSLATED/files/config"
  _sbx_upgrade_translate first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
  _sbx_upgrade_translate first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
}

@test "sbx upgrade: failed pinned fetch is not reused on retry" {
  REF="${REF/HEAD/$PIN}"
  _sbx_upgrade_legacy
  export FAIL_FETCH=1
  _sbx_upgrade_refused
  assert_equal "$(find "$_ACQ_KIT_FETCH_ROOT" -mindepth 1 -print)" ''
  assert [ ! -e "$TRANSLATED" ]
  unset FAIL_FETCH
  _sbx_upgrade_translate first
  _sbx_upgrade_translate first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 3
}

@test "sbx upgrade: symlink namespace cannot redirect fetches into metadata-free legacy payload" {
  local target="$STUBDIR/old-payload"
  mkdir -p "$target/$SLUG/kits/one"
  printf 'preserve\n' > "$target/$SLUG/kits/one/keep"
  ln -s "$target" "$ACQ_SBX_KIT_CACHE/fetch-payload-v2"
  _sbx_upgrade_refused
  assert [ -L "$ACQ_SBX_KIT_CACHE/fetch-payload-v2" ]
  assert_equal "$(cat "$target/$SLUG/kits/one/keep")" preserve
  assert [ ! -e "$target/$SLUG/kits/one/spec.yaml" ]
  assert [ ! -e "$FETCH_LOG" ]
}

@test "sbx upgrade: symlink leaf preserves its legacy repository target" {
  mkdir -p "$(dirname "$PAYLOAD")"
  ln -s "$LEGACY" "$PAYLOAD"
  _sbx_upgrade_refused
  assert [ -L "$PAYLOAD" ]
  assert_equal "$(readlink "$PAYLOAD")" "$LEGACY"
  assert [ ! -e "$FETCH_LOG" ]
}

@test "sbx upgrade: repository obstructing the new namespace is preserved" {
  local namespace="$ACQ_SBX_KIT_CACHE/fetch-payload-v2"
  cp -R "$LEGACY" "$namespace"
  _sbx_upgrade_refused
  diff -r "$SNAPSHOT" "$namespace"
  assert [ ! -e "$PAYLOAD" ]
  assert [ ! -e "$FETCH_LOG" ]
}

@test "sbx upgrade: repository obstructing the new payload leaf is preserved" {
  mkdir -p "$(dirname "$PAYLOAD")"
  cp -R "$LEGACY" "$PAYLOAD"
  _sbx_upgrade_refused
  diff -r "$SNAPSHOT" "$PAYLOAD"
  assert [ ! -e "$FETCH_LOG" ]
}

@test "sbx upgrade: local kits remain independent of the remote fetch namespace" {
  ln -s "$ACQ_SBX_KIT_CACHE/fetch" "$ACQ_SBX_KIT_CACHE/fetch-payload-v2"
  REF="$SOURCE_REPO/kits/one"
  local slug
  slug=$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '_')
  run _acq_sbx_translate_kit "$REF"
  assert_success
  assert_output "$ACQ_SBX_KIT_CACHE/v2/$slug"
  assert_equal "$(kit_spec_field "$output/spec.yaml" schemaVersion)" 2
  assert [ ! -e "$FETCH_LOG" ]
  _sbx_upgrade_assert_legacy
}
