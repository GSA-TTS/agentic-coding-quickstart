#!/usr/bin/env bats
# Runner contract tests use a tiny fake suite, never recursively run this suite.

load 'helper'

setup() {
  acq_setup_stubs
  RUNNER_ROOT="$STUBDIR/runner"
  mkdir -p "$RUNNER_ROOT/scripts" "$RUNNER_ROOT/test/vendor/bats-core/bin" "$RUNNER_ROOT/test/bats"
  cp "$REPO_ROOT/scripts/test-acq-bats" "$RUNNER_ROOT/scripts/test-acq-bats"
  cp "$REPO_ROOT/scripts/run-shellcheck" "$RUNNER_ROOT/scripts/run-shellcheck"
  cp "$REPO_ROOT/scripts/bats-shard" "$RUNNER_ROOT/scripts/bats-shard"
  cat > "$RUNNER_ROOT/test/vendor/bats-core/bin/bats" <<'STUB'
#!/bin/sh
printf 'bats-arg:%s\n' "$@"
exit "${TEST_BATS_STATUS:-0}"
STUB
  chmod +x "$RUNNER_ROOT/test/vendor/bats-core/bin/bats"
  touch "$RUNNER_ROOT/test/bats/a.bats" "$RUNNER_ROOT/test/bats/b.bats"
}

teardown() { acq_teardown_stubs; }

@test "runner: explicit arguments preserve timing and failure status" {
  run env ACQ_BATS_TIMING=1 TEST_BATS_STATUS=7 bash "$RUNNER_ROOT/scripts/test-acq-bats" --count 'a path.bats'
  assert_failure 7
  assert_line 'bats-arg:--timing'
  assert_line 'bats-arg:--count'
  assert_line 'bats-arg:a path.bats'
  refute_output --partial 'bats-arg:--jobs'
}

@test "runner: malformed worker counts and timing values fail before execution" {
  local jobs
  for jobs in 0 -1 abc 01 '2;exit' 999999999999999999999999999999; do
    run env ACQ_BATS_JOBS="$jobs" bash "$RUNNER_ROOT/scripts/test-acq-bats"
    assert_failure 2
    refute_output --partial 'bats-arg:'
  done
  run env ACQ_BATS_TIMING=invalid bash "$RUNNER_ROOT/scripts/test-acq-bats"
  assert_failure 2
}

@test "runner: serial execution has no implicit timing or jobs flags" {
  run env ACQ_BATS_TIMING=0 ACQ_BATS_JOBS=1 bash "$RUNNER_ROOT/scripts/test-acq-bats"
  assert_success
  assert_output "bats-arg:$RUNNER_ROOT/test/bats"
}

@test "runner: macOS CPU fallback selects file-level parallelism" {
  printf '#!/bin/sh\nexit 1\n' > "$STUBDIR/nproc"
  printf '#!/bin/sh\n[ "$*" = "-n hw.ncpu" ] || exit 1\nprintf "3\\n"\n' > "$STUBDIR/sysctl"
  printf '#!/bin/sh\nexit 0\n' > "$STUBDIR/parallel"
  chmod +x "$STUBDIR/nproc" "$STUBDIR/sysctl" "$STUBDIR/parallel"
  run env -u ACQ_BATS_JOBS ACQ_BATS_TIMING=1 bash "$RUNNER_ROOT/scripts/test-acq-bats"
  assert_success
  assert_line 'bats-arg:--jobs'
  assert_line 'bats-arg:3'
  assert_line 'bats-arg:--no-parallelize-within-files'
}

@test "runner: xargs fallback retains timing, runs every file and propagates failure" {
  cat > "$RUNNER_ROOT/test/vendor/bats-core/bin/bats" <<'STUB'
#!/bin/sh
printf 'bats-arg:%s\n' "$@"
case "$*" in *b.bats) exit 7 ;; *) exit 0 ;; esac
STUB
  run env ACQ_BATS_JOBS=2 ACQ_BATS_TIMING=1 TEST_BATS_STATUS=7 bash -c '
    command() {
      case "$*" in
        "-v parallel"|"-v rush") return 1 ;;
        *) builtin command "$@" ;;
      esac
    }
    export -f command
    exec bash "$1/scripts/test-acq-bats"
  ' _ "$RUNNER_ROOT"
  assert_failure 1
  assert_line "bats-arg:$RUNNER_ROOT/test/bats/a.bats"
  assert_line "bats-arg:$RUNNER_ROOT/test/bats/b.bats"
  assert_line 'bats-arg:--timing'
}

@test "runner: ACQ_BATS_SHARD runs only the selected files (serial path)" {
  printf '@test "x" {\n true\n}\n' > "$RUNNER_ROOT/test/bats/a.bats"
  printf '@test "y" {\n true\n}\n@test "z" {\n true\n}\n' > "$RUNNER_ROOT/test/bats/b.bats"
  run env ACQ_BATS_JOBS=1 ACQ_BATS_SHARD=1/2 bash "$RUNNER_ROOT/scripts/test-acq-bats"
  assert_success
  assert_line "bats-arg:$RUNNER_ROOT/test/bats/b.bats"
  refute_line "bats-arg:$RUNNER_ROOT/test/bats/a.bats"
  refute_line "bats-arg:$RUNNER_ROOT/test/bats"
  run env ACQ_BATS_JOBS=1 ACQ_BATS_SHARD=2/2 bash "$RUNNER_ROOT/scripts/test-acq-bats"
  assert_success
  assert_line "bats-arg:$RUNNER_ROOT/test/bats/a.bats"
  refute_line "bats-arg:$RUNNER_ROOT/test/bats/b.bats"
}

@test "runner: ACQ_BATS_SHARD xargs fallback runs only the selected files" {
  printf '@test "x" {\n true\n}\n' > "$RUNNER_ROOT/test/bats/a.bats"
  printf '@test "y" {\n true\n}\n@test "z" {\n true\n}\n' > "$RUNNER_ROOT/test/bats/b.bats"
  run env ACQ_BATS_JOBS=2 ACQ_BATS_SHARD=1/2 bash -c '
    command() {
      case "$*" in
        "-v parallel"|"-v rush") return 1 ;;
        *) builtin command "$@" ;;
      esac
    }
    export -f command
    exec bash "$1/scripts/test-acq-bats"
  ' _ "$RUNNER_ROOT"
  assert_success
  assert_line "bats-arg:$RUNNER_ROOT/test/bats/b.bats"
  refute_line "bats-arg:$RUNNER_ROOT/test/bats/a.bats"
}

@test "runner: invalid ACQ_BATS_SHARD fails closed before running any test" {
  local spec
  for spec in 0/2 3/2 x 1/2/3 9/9; do
    run env ACQ_BATS_JOBS=1 ACQ_BATS_SHARD="$spec" bash "$RUNNER_ROOT/scripts/test-acq-bats"
    assert_failure 2
    refute_output --partial 'bats-arg:'
  done
}

@test "runner: explicit file arguments ignore ACQ_BATS_SHARD" {
  run env ACQ_BATS_SHARD=1/2 bash "$RUNNER_ROOT/scripts/test-acq-bats" 'only.bats'
  assert_success
  assert_line 'bats-arg:only.bats'
}

@test "runner: an ACQ_BATS_SHARD exported by the CI leg does not leak into runner tests" {
  # acq_setup_stubs (this test's setup) must have cleared it.
  [ -z "${ACQ_BATS_SHARD:-}" ]
}

@test "shellcheck runner: validates workers and preserves a failing batch" {
  cat > "$STUBDIR/shellcheck" <<'STUB'
#!/bin/sh
printf 'shellcheck-arg:%s\n' "$@"
case "$*" in *bad.sh) exit 3 ;; *) exit 0 ;; esac
STUB
  chmod +x "$STUBDIR/shellcheck"
  local files=(good-1.sh good-2.sh good-3.sh good-4.sh good-5.sh good-6.sh good-7.sh good-8.sh bad.sh)
  run env SHELLCHECK_JOBS=2 bash "$RUNNER_ROOT/scripts/run-shellcheck" "${files[@]}"
  assert_failure
  assert_line 'shellcheck-arg:good-1.sh'
  assert_line 'shellcheck-arg:good-8.sh'
  assert_line 'shellcheck-arg:bad.sh'
  run env SHELLCHECK_JOBS=999999999999999999999999999999 bash "$RUNNER_ROOT/scripts/run-shellcheck" good.sh
  assert_failure 2
}

@test "shellcheck runner: termination reaches an active lint child" {
  cat > "$STUBDIR/shellcheck" <<'STUB'
#!/bin/sh
printf '%s\n' "$$" > "$STUBDIR/shellcheck.pid"
trap 'touch "$STUBDIR/shellcheck.terminated"; exit 0' TERM
while :; do sleep 1; done
STUB
  chmod +x "$STUBDIR/shellcheck"
  run bash -c '
    SHELLCHECK_JOBS=2 bash "$1/scripts/run-shellcheck" active.sh &
    runner=$!
    while [ ! -f "$2/shellcheck.pid" ]; do sleep 0.05; done
    kill -TERM "$runner"
    wait "$runner"
    status=$?
    test -f "$2/shellcheck.terminated"
    exit "$status"
  ' _ "$RUNNER_ROOT" "$STUBDIR"
  assert_failure 143
  [ -f "$STUBDIR/shellcheck.terminated" ]
}

@test "transport fixture: real projection is offline and local Git still works" {
  run acq_provider_input_prepare sbx offlinebox
  assert_success
  [ -d "$output/models/providers" ]
  git init -q "$STUBDIR/local-repo"
  run git -C "$STUBDIR/local-repo" rev-parse --is-inside-work-tree
  assert_success
  assert_output true
  run env GIT_ALLOW_PROTOCOL=none bash -c 'ACQ_SOURCE_ONLY=1 . "$ACQ_SCRIPT_DIR/acq"; kit_translate_fetch "$USAI_KIT" "$STUBDIR/rejected"'
  assert_failure
}

@test "transport fixture: an unknown pinned revision cannot silently use the fixture" {
  run kit_translate_fetch "${PATTERNS_KIT_REPO}#ref=0000000000000000000000000000000000000000&dir=${PATTERNS_KIT_DIR}/usai-provider" "$STUBDIR/unknown"
  assert_failure
}
