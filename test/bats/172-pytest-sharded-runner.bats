#!/usr/bin/env bats
# scripts/test-py-acq-sharded: local, bounded invocation of CI's pytest shards.

load 'helper'

setup() {
  acq_setup_stubs
  RUNNER_ROOT="$STUBDIR/runner"
  mkdir -p "$RUNNER_ROOT/scripts" "$RUNNER_ROOT/py-acq/tests"
  cp "$REPO_ROOT/scripts/test-py-acq-sharded" "$RUNNER_ROOT/scripts/test-py-acq-sharded"
  cat > "$STUBDIR/fake-python" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PYTEST_CALLS"
if [ "${PYTEST_SLEEP:-0}" = 1 ]; then
  printf '%s\n' "$$" >> "$PYTEST_CHILD_PIDS"
  trap 'printf stopped\\n >> "$PYTEST_STOPPED"; exit 0' TERM
  while :; do sleep 1; done
fi
case "$*" in
  *--acq-shard\ 2/4*) printf 'shard-two-failed\n'; exit 7 ;;
  *) printf 'ran:%s\n' "$*" ;;
esac
STUB
  chmod +x "$STUBDIR/fake-python"
  export PYTEST_CALLS="$STUBDIR/calls"
}

teardown() { acq_teardown_stubs; }

@test "py-acq sharded runner: rejects invalid shard and worker counts before pytest" {
  local value
  for value in 0 01 abc '2;exit' 999999999999999999999999999999; do
    run env ACQ_PYTEST_PYTHON="$STUBDIR/fake-python" ACQ_PYTEST_JOBS="$value" \
      bash "$RUNNER_ROOT/scripts/test-py-acq-sharded"
    assert_failure 2
    [ ! -e "$STUBDIR/calls" ]
  done
  run env ACQ_PYTEST_PYTHON="$STUBDIR/fake-python" ACQ_PYTEST_SHARDS=0 \
    bash "$RUNNER_ROOT/scripts/test-py-acq-sharded"
  assert_failure 2
  [ ! -e "$STUBDIR/calls" ]
}

@test "py-acq sharded runner: dispatches every CI-equivalent shard and aggregates failures" {
  run env ACQ_PYTEST_PYTHON="$STUBDIR/fake-python" ACQ_PYTEST_JOBS=2 \
    bash "$RUNNER_ROOT/scripts/test-py-acq-sharded"
  assert_failure 1
  assert_line '===== pytest shard 1/4 ====='
  assert_line '===== pytest shard 2/4 ====='
  assert_line '===== pytest shard 3/4 ====='
  assert_line '===== pytest shard 4/4 ====='
  assert_line 'shard-two-failed'
  [ "$(wc -l < "$STUBDIR/calls" | tr -d ' ')" -eq 4 ]
  local shard
  for shard in 1 2 3 4; do
    grep -F -- "-p scripts.pytest_shard py-acq/tests --acq-shard $shard/4 -v --tb=short -ra --show-capture=no" "$STUBDIR/calls"
  done
}

@test "py-acq sharded runner: signal stops and reaps every launched shard" {
  export PYTEST_CHILD_PIDS="$STUBDIR/child-pids"
  export PYTEST_STOPPED="$STUBDIR/stopped"
  env ACQ_PYTEST_PYTHON="$STUBDIR/fake-python" ACQ_PYTEST_JOBS=2 PYTEST_SLEEP=1 \
    bash "$RUNNER_ROOT/scripts/test-py-acq-sharded" >"$STUBDIR/runner.out" 2>&1 &
  local runner=$!
  local tries=0
  while [ "$(wc -l < "$PYTEST_CHILD_PIDS" 2>/dev/null || echo 0)" -lt 2 ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$(wc -l < "$PYTEST_CHILD_PIDS")" -eq 2 ] || fail 'runner did not launch two shards'
  kill -TERM "$runner"
  kill -TERM "$runner" 2>/dev/null || true
  if wait "$runner"; then
    fail 'runner did not preserve SIGTERM exit status'
  else
    runner_status=$?
  fi
  [ "$runner_status" -eq 143 ] || fail 'runner did not preserve SIGTERM exit status'
  [ "$(wc -l < "$PYTEST_STOPPED")" -eq 2 ] || fail 'runner did not terminate every launched shard'
  local child
  while IFS= read -r child; do
    ! kill -0 "$child" 2>/dev/null || fail "shard child survived: $child"
  done < "$PYTEST_CHILD_PIDS"
}

@test "py-acq sharded runner: explicit pytest arguments stay focused and unsharded" {
  run env ACQ_PYTEST_PYTHON="$STUBDIR/fake-python" ACQ_PYTEST_JOBS=invalid \
    bash "$RUNNER_ROOT/scripts/test-py-acq-sharded" py-acq/tests/test_cli.py -k version
  assert_success
  assert_output 'ran:-m pytest py-acq/tests/test_cli.py -k version'
  [ "$(cat "$STUBDIR/calls")" = '-m pytest py-acq/tests/test_cli.py -k version' ]
}

@test "py-acq sharded runner: remains parseable by the portable Bash subset" {
  run bash --posix -n "$RUNNER_ROOT/scripts/test-py-acq-sharded"
  assert_success
}
