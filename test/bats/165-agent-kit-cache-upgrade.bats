#!/usr/bin/env bats
# shellcheck shell=bats
# Real readiness/validation callers and Git objects; only transport is stubbed.
load 'helper'

setup() {
  acq_setup_stubs
  unset FAIL_FETCH ACQ_DEBUG ACQ_TEST_AGENT_KIT
  export SOURCE_REPO="$STUBDIR/source" FETCH_LOG="$STUBDIR/fetch.log"
  export ACQ_STATE_DIR="$STUBDIR/custom state"
  # shellcheck disable=SC2034  # read by sourced _acq_agent_builtin_kit_ref
  PATTERNS_KIT_REPO='git+https://example.test/kits.git'
  PATTERNS_KIT_REF=HEAD
  # shellcheck disable=SC2034  # read by sourced _acq_agent_builtin_kit_ref
  PATTERNS_KIT_DIR=kits
  # shellcheck disable=SC2034  # read by sourced acq_agent_builtin_kit_ready
  ACQ_AGENT_KIT_READY_CACHE=''
  mkdir -p "$SOURCE_REPO/kits/opencode"
  cat > "$SOURCE_REPO/kits/opencode/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: opencode
agent:
  name: opencode
  entrypoint: opencode
SPEC
  printf 'first\n' > "$SOURCE_REPO/kits/opencode/payload"
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" init -q --template=
  _agent_upgrade_commit first
  PIN=$("$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
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
  _agent_upgrade_legacy
}

teardown() { acq_teardown_stubs; }

_agent_upgrade_commit() {
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" add .
  "$ACQ_TEST_REAL_GIT" -C "$SOURCE_REPO" -c commit.gpgsign=false \
    -c user.name=Fixture -c user.email=fixture@example.test commit -qm "$1"
}

_agent_upgrade_legacy() {
  LEGACY="$ACQ_STATE_DIR/agent-kit-validation/opencode"
  NAMESPACE="$ACQ_STATE_DIR/agent-kit-validation-payload-v2"
  PAYLOAD="$NAMESPACE/opencode"
  mkdir -p "$(dirname "$LEGACY")"
  "$ACQ_TEST_REAL_GIT" clone -q --no-hardlinks "$SOURCE_REPO" "$LEGACY"
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" config upgrade.sentinel preserve
  "$ACQ_TEST_REAL_GIT" -C "$LEGACY" update-ref refs/heads/sentinel "$PIN"
  printf 'dirty legacy payload\n' > "$LEGACY/kits/opencode/payload"
  printf 'untracked legacy bytes\n' > "$LEGACY/keep"
  SNAPSHOT=$(mktemp -d "$STUBDIR/legacy-before.XXXXXX")
  cp -R "$LEGACY/." "$SNAPSHOT/"
}

_agent_upgrade_assert_legacy() {
  # Includes dirty/untracked bytes, config, refs, index and Git objects.
  diff -r "$SNAPSHOT" "$LEGACY"
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" rev-parse HEAD)" "$PIN"
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" config upgrade.sentinel)" preserve
  assert_equal "$("$ACQ_TEST_REAL_GIT" -C "$LEGACY" rev-parse refs/heads/sentinel)" "$PIN"
}

_agent_upgrade_ready() {
  # Each run models a fresh readiness decision, without changing the existing
  # per-shell yes/no readiness memoization. Fetch reuse still shares files.
  run acq_agent_builtin_kit_ready opencode
  assert_success
  assert_output ''
  assert_equal "$(cat "$PAYLOAD/kits/opencode/payload")" "$1"
  assert_equal "$(find "$PAYLOAD" -name .git -print)" ''
  _agent_upgrade_assert_legacy
}

_agent_upgrade_refused() {
  run acq_agent_builtin_kit_ready opencode
  assert_failure
  assert_output --partial 'refusing'
  assert [ ! -e "$FETCH_LOG" ]
  _agent_upgrade_assert_legacy
}

@test "agent upgrade: production readiness selects a valid kit beside a legacy repository" {
  _agent_upgrade_ready first
  run acq_selected_agent_kit_summary opencode
  assert_success
  assert_output --partial 'apply=enabled'
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
  _agent_upgrade_assert_legacy
}

@test "agent upgrade: symbolic readiness refreshes metadata-free payload" {
  _agent_upgrade_ready first
  printf 'stale\n' > "$PAYLOAD/kits/opencode/stale"
  printf 'second\n' > "$SOURCE_REPO/kits/opencode/payload"
  _agent_upgrade_commit second
  _agent_upgrade_ready second
  assert [ ! -e "$PAYLOAD/kits/opencode/stale" ]
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
}

@test "agent upgrade: failed refresh preserves payload and the next readiness decision retries" {
  _agent_upgrade_ready first
  printf 'second\n' > "$SOURCE_REPO/kits/opencode/payload"
  _agent_upgrade_commit second
  export FAIL_FETCH=1
  run acq_agent_builtin_kit_ready opencode
  assert_failure
  assert_output --partial 'failed to fetch remote kit'
  assert_equal "$(cat "$PAYLOAD/kits/opencode/payload")" first
  _agent_upgrade_assert_legacy
  unset FAIL_FETCH
  _agent_upgrade_ready second
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 4
}

@test "agent upgrade: pinned readiness reuses verified source and repairs consumer edits" {
  PATTERNS_KIT_REF="$PIN"
  _agent_upgrade_ready first
  printf 'consumer edit\n' > "$PAYLOAD/kits/opencode/payload"
  _agent_upgrade_ready first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
  _agent_upgrade_ready first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 2
}

@test "agent upgrade: failed pinned fetch leaves no reusable success and retries" {
  # shellcheck disable=SC2034  # read by sourced _acq_agent_builtin_kit_ref
  PATTERNS_KIT_REF="$PIN"
  export FAIL_FETCH=1
  run acq_agent_builtin_kit_ready opencode
  assert_failure
  assert_output --partial 'failed to fetch remote kit'
  assert_equal "$(find "$_ACQ_KIT_FETCH_ROOT" -mindepth 1 -print)" ''
  _agent_upgrade_assert_legacy
  unset FAIL_FETCH
  _agent_upgrade_ready first
  _agent_upgrade_ready first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 3
}

@test "agent upgrade: fetched invalid agent metadata never reports ready" {
  cat > "$SOURCE_REPO/kits/opencode/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: opencode
agent:
  name: opencode
  entrypoint: wrong
SPEC
  _agent_upgrade_commit invalid
  run acq_agent_builtin_kit_ready opencode
  assert_failure
  assert_output ''
  assert_equal "$(kit_spec_agent_field "$PAYLOAD/kits/opencode/spec.yaml" entrypoint)" wrong
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _agent_upgrade_assert_legacy
}

@test "agent upgrade: symlink namespace cannot replace metadata-free target payload" {
  local target="$STUBDIR/old-payload"
  mkdir -p "$target/opencode"
  printf 'preserve\n' > "$target/opencode/keep"
  ln -s "$target" "$NAMESPACE"
  _agent_upgrade_refused
  assert [ -L "$NAMESPACE" ]
  assert_equal "$(cat "$target/opencode/keep")" preserve
  assert [ ! -e "$target/opencode/kits" ]
}

@test "agent upgrade: symlink leaf preserves the legacy repository target" {
  mkdir -p "$NAMESPACE"
  ln -s "$LEGACY" "$PAYLOAD"
  _agent_upgrade_refused
  assert [ -L "$PAYLOAD" ]
  assert_equal "$(readlink "$PAYLOAD")" "$LEGACY"
}

@test "agent upgrade: repository namespace obstruction is preserved" {
  cp -R "$LEGACY" "$NAMESPACE"
  _agent_upgrade_refused
  diff -r "$SNAPSHOT" "$NAMESPACE"
  assert [ ! -e "$PAYLOAD" ]
}

@test "agent upgrade: repository leaf obstruction is preserved" {
  mkdir -p "$NAMESPACE"
  cp -R "$LEGACY" "$PAYLOAD"
  _agent_upgrade_refused
  diff -r "$SNAPSHOT" "$PAYLOAD"
}

@test "agent upgrade: explicit base directory is honored despite obstructed default namespace" {
  ln -s "$LEGACY" "$NAMESPACE"
  local ref explicit="$STUBDIR/explicit"
  ref=$(_acq_agent_builtin_kit_ref opencode)
  run acq_validate_agent_builtin_kit_ref opencode "$ref" "$explicit"
  assert_success
  assert_output ''
  assert_equal "$(cat "$explicit/kits/opencode/payload")" first
  assert [ ! -e "$explicit/.git" ]
  assert [ -L "$NAMESPACE" ]
  # Explicit repositories are refused, not silently relocated to the default.
  run acq_validate_agent_builtin_kit_ref opencode "$ref" "$LEGACY"
  assert_failure
  assert_output --partial 'refusing'
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
  _agent_upgrade_assert_legacy
}

@test "agent upgrade: local validation ignores the remote default namespace" {
  ln -s "$LEGACY" "$NAMESPACE"
  run acq_validate_agent_builtin_kit_ref opencode "$SOURCE_REPO/kits/opencode"
  assert_success
  assert_output ''
  assert [ ! -e "$FETCH_LOG" ]
  _agent_upgrade_assert_legacy
}

@test "agent upgrade: unset state directory uses the versioned per-user state fallback" {
  export TMPDIR="$STUBDIR/tmp"
  mkdir -p "$TMPDIR"
  # Seed the old layout under the resolved user state root, then unset the knob.
  export XDG_STATE_HOME="$STUBDIR/state-fallback"
  unset ACQ_STATE_DIR
  ACQ_STATE_DIR=$(acq_state_dir)
  _agent_upgrade_legacy
  unset ACQ_STATE_DIR
  _agent_upgrade_ready first
  assert_equal "$(wc -l < "$FETCH_LOG" | tr -d ' ')" 1
}
