#!/usr/bin/env bats
#
# 156-summarize-bats-timing-real.bats — checks scripts/summarize-bats-timing against
# what the pinned bats-core really prints with --timing: trimmed captures under
# test/bats/fixtures plus live runs of bats and scripts/test-acq-bats. The
# hand-written TAP in 155-summarize-bats-timing.bats cannot catch a parser that
# disagrees with the real formatter, so this file exists to make that impossible.
#
# shellcheck shell=bats

load 'helper'

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  SUMMARIZE="$REPO_ROOT/scripts/summarize-bats-timing"
  W="$BATS_TEST_TMPDIR"
  TESTS="$W/tests"
  mkdir -p "$TESTS"
}

summarize() { python3 "$SUMMARIZE" --tests-dir "$TESTS" "$@"; }

# The fixtures under test/bats/fixtures are trimmed captures from the pinned
# bats-core (test/vendor/bats-core) so the parser is checked against what bats
# really prints, not against syntax this file invented. The live tests below
# re-capture the same streams so a bats bump cannot silently break the parser.

FIXTURES="$BATS_TEST_DIRNAME/fixtures"

real_tests_dir() {
  local t='@test'
  printf '%s "fast one" { true; }\n%s "name with in 5ms inside" { true; }\n' "$t" "$t" > "$TESTS/60-real.bats"
  printf '%s "skipped one" { true; }\n%s "bare skip" { true; }\n%s "fails" { true; }\n%s "slow one" { true; }\n' "$t" "$t" "$t" "$t" >> "$TESTS/60-real.bats"
}

@test "summarize: parses the raw bats --timing stream (in Nms)" {
  real_tests_dir
  run summarize --log "$FIXTURES/bats-raw-timing.tap" --wall-seconds 10
  assert_success
  assert_output --partial 'Tests reported | 6 (2 passed, 2 failed, 2 skipped)'
  assert_output --partial 'Summed test time | 1.1s'
  assert_output --partial '| 1 | 1.1s | 60-real.bats | slow one |'
  assert_output --partial '| 60-real.bats | 6 |'
  refute_output --partial 'No per-test timings'
  refute_output --partial '(unmapped)'
}

@test "summarize: parses the bats-format-tap stream (# in N ms, # timeout after N s)" {
  real_tests_dir
  run summarize --log "$FIXTURES/bats-formatter-tap-timing.tap" --wall-seconds 10
  assert_success
  assert_output --partial 'Tests reported | 6 (2 passed, 2 failed, 2 skipped)'
  assert_output --partial 'Summed test time | 1.1s'
  assert_output --partial '| 1 | 1.0s | 60-real.bats | slow one |'
  refute_output --partial 'No per-test timings'
  refute_output --partial '(unmapped)'
}

@test "summarize: a test name containing 'in 5ms' keeps its full name in both formats" {
  real_tests_dir
  printf '1..1\nok 1 name with in 5ms inside in 19ms\n' > "$W/a.tap"
  printf '1..1\nok 1 name with in 5ms inside # in 28 ms\n' > "$W/b.tap"
  printf '1..1\nok 1 name with in 5ms inside\n' > "$W/c.tap"
  run summarize --log "$W/a.tap"
  assert_output --partial '| name with in 5ms inside |'
  run summarize --log "$W/b.tap"
  assert_output --partial '| name with in 5ms inside |'
  assert_output --partial '| 1 | 28ms | 60-real.bats | name with in 5ms inside |'
  run summarize --log "$W/c.tap"
  assert_output --partial 'No per-test timings'
}

# Run the pinned bats from a clean environment: this file already runs inside
# bats, whose BATS_* variables would otherwise leak into the inner run.
inner_bats() {
  env -i PATH="$PATH" HOME="$W" TMPDIR="$W" "$@"
}

make_tiny_suite() {
  local t='@test'
  mkdir -p "$W/tiny"
  printf '%s "tiny pass in 5ms" { sleep 0.01; }\n%s "tiny skip" { skip "why"; }\n%s "tiny fail" { false; }\n' \
    "$t" "$t" "$t" > "$W/tiny/tiny.bats"
}

@test "summarize: live pinned bats --timing output (raw and formatter) is understood" {
  make_tiny_suite
  local bats="$REPO_ROOT/test/vendor/bats-core/bin/bats"
  inner_bats "$bats" --timing "$W/tiny/tiny.bats" > "$W/live-raw.tap" 2>&1 || true
  inner_bats "$bats" --timing --tap --report-formatter tap -o "$W" "$W/tiny/tiny.bats" > "$W/live-fmt.tap" 2>&1 || true
  local f
  for f in live-raw live-fmt; do
    run summarize --log "$W/$f.tap" --tests-dir "$W/tiny" --json "$W/$f.json"
    assert_success
    assert_output --partial 'Tests reported | 3 (1 passed, 1 failed, 1 skipped)'
    refute_output --partial 'No per-test timings'
    refute_output --partial '(unmapped)'
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["timed"] >= 2 else 1)' "$W/$f.json"
    assert_success
  done
}

@test "summarize: live scripts/test-acq-bats output (explicit file and whole-suite runner) is understood" {
  make_tiny_suite
  local root="$W/runner"
  mkdir -p "$root/scripts" "$root/test/vendor" "$root/test/bats"
  cp "$REPO_ROOT/scripts/test-acq-bats" "$root/scripts/test-acq-bats"
  ln -s "$REPO_ROOT/test/vendor/bats-core" "$root/test/vendor/bats-core"
  cp "$W/tiny/tiny.bats" "$root/test/bats/a-tiny.bats"
  sed 's/tiny/other/g' "$W/tiny/tiny.bats" > "$root/test/bats/b-other.bats"
  inner_bats ACQ_BATS_TIMING=1 bash "$root/scripts/test-acq-bats" "$root/test/bats/a-tiny.bats" > "$W/run-file.log" 2>&1 || true
  inner_bats ACQ_BATS_TIMING=1 ACQ_BATS_JOBS=2 bash "$root/scripts/test-acq-bats" > "$W/run-suite.log" 2>&1 || true
  run summarize --log "$W/run-file.log" --tests-dir "$root/test/bats"
  assert_success
  assert_output --partial 'Tests reported | 3 (1 passed, 1 failed, 1 skipped)'
  refute_output --partial 'No per-test timings'
  run summarize --log "$W/run-suite.log" --tests-dir "$root/test/bats" --wall-seconds 5
  assert_success
  assert_output --partial 'Tests reported | 6 (2 passed, 2 failed, 2 skipped)'
  assert_output --partial '(2 workers)'
  refute_output --partial 'No per-test timings'
  refute_output --partial '(unmapped)'
}

@test "summarize: near-miss duration suffixes are part of the name, never a timing" {
  local variant
  for variant in 'x in 5 ms' 'x # in 5 ms ' 'x in 5ms ' 'x in -5ms'; do
    printf '1..1\nok 1 %s\n' "$variant" > "$W/nm.tap"
    run summarize --log "$W/nm.tap"
    assert_success
    assert_output --partial 'No per-test timings'
  done
}

@test "summarize: a broken install (missing sibling modules) still exits 0 with a note" {
  mkdir -p "$W/lonely"
  cp "$SUMMARIZE" "$W/lonely/summarize-bats-timing"
  printf '1..1\nok 1 x in 5ms\n' > "$W/l.tap"
  run python3 "$W/lonely/summarize-bats-timing" --log "$W/l.tap"
  assert_success
  assert_output --partial 'could not be produced'
}
