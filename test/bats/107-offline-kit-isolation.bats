#!/usr/bin/env bats
# shellcheck shell=bats
load 'helper'

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

@test "offline kits: both fixtures belong to the test's disposable stub directory" {
  assert_equal "$ACQ_MSB_KIT_LOCAL_DIR" "$STUBDIR/acq-offline-kit"
  assert_equal "$ACQ_TEST_AGENT_KIT" "$STUBDIR/acq-opencode-kit"
  assert [ -f "$ACQ_MSB_KIT_LOCAL_DIR/spec.yaml" ]
  assert [ -f "$ACQ_TEST_AGENT_KIT/spec.yaml" ]
}

@test "offline kits: concurrent workers materialize only their own fixture" {
  local worker pids=() failed=0
  # All workers inherit the same BATS_RUN_TMPDIR, just like parallel bats
  # tests. Distinct contents expose cross-worker reads without relying on
  # winning the much smaller GNU cp stat/open race against a fixture rename.
  for worker in 1 2 3 4 5 6 7 8; do
    env PATH="$_STUB_BASE_PATH" bash -c '
      set -e
      . "$REPO_ROOT/scripts/test-acq-lib.sh"
      make_stubs
      trap cleanup_stubs EXIT
      load_acq
      _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
      printf "worker-%s\n" "$1" > "$ACQ_MSB_KIT_LOCAL_DIR/spec.yaml"
      ref="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=$ACQ_TEST_PATTERNS_REF&dir=integrations/isolation/acq-kits/usai-provider"
      for ((iteration=0; iteration<20; iteration++)); do
        path=$(kit_translate_fetch "$ref" "$STUBDIR/destination")
        [ "$(cat "$path/spec.yaml")" = "worker-$1" ] || exit 1
      done
    ' _ "$worker" > "$STUBDIR/worker-$worker.log" 2>&1 &
    pids+=("$!")
  done
  for worker in "${pids[@]}"; do
    wait "$worker" || failed=1
  done
  if [ "$failed" != 0 ]; then
    cat "$STUBDIR"/worker-*.log
  fi
  assert_equal "$failed" 0
}
