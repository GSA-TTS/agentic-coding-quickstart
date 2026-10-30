#!/usr/bin/env bats
#
# 155-summarize-bats-timing.bats — contract tests for scripts/summarize-bats-timing,
# the advisory CI helper that turns `ACQ_BATS_TIMING=1` TAP output into a Markdown
# job summary and a JSON record. It must never fail a job, must degrade gracefully
# on missing or partial input, and must treat test names as untrusted text.
#
# shellcheck shell=bats

load 'helper'

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  SUMMARIZE="$REPO_ROOT/scripts/summarize-bats-timing"
  W="$BATS_TEST_TMPDIR"
  TESTS="$W/tests"
  mkdir -p "$TESTS"
  # Declared via printf: a literal @test line inside a heredoc would be
  # rewritten by bats' own preprocessor.
  local t='@test'
  printf '%s "alpha one" { true; }\n%s "alpha two" { true; }\n%s "alpha | pipe" { true; }\n' "$t" "$t" "$t" > "$TESTS/10-alpha.bats"
  printf '%s "beta one" { true; }\n%s "beta shared" { true; }\n' "$t" "$t" > "$TESTS/20-beta.bats"
  printf '%s "gamma shared" { true; }\n%s "beta shared" { true; }\n' "$t" "$t" > "$TESTS/30-gamma.bats"
}

summarize() { python3 "$SUMMARIZE" --tests-dir "$TESTS" "$@"; }

@test "summarize: reports totals, slowest tests and files, and the timeout margin" {
  cat > "$W/ok.tap" <<'EOF'
test-acq-bats: workers=2; per-test timings include setup and teardown
1..5
ok 1 alpha one in 1500ms
ok 2 alpha two in 500ms
ok 3 beta one in 9000ms
ok 4 gamma shared in 40ms
ok 5 alpha | pipe in 10ms # skip not today
EOF
  run summarize --log "$W/ok.tap" --timeout-minutes 25 --wall-seconds 600
  assert_success
  assert_output --partial 'Tests reported | 5 (4 passed, 0 failed, 1 skipped)'
  assert_output --partial 'Summed test time | 11.0s'
  assert_output --partial '10m 00s wall, 0.0x parallel (2 workers)'
  assert_output --partial 'Margin to 25 min job timeout | 15m 00s left, suite used 40%'
  assert_output --partial '| 1 | 9.0s | 20-beta.bats | beta one |'
  assert_output --partial '| 1 | 20-beta.bats | 1 | 9.0s | 9.0s |'
  assert_output --partial '| 2 | 10-alpha.bats | 3 | 2.0s | 1.5s |'
  refute_output --partial '::warning'
}

@test "summarize: tests with the same name in several files are not guessed at" {
  printf '1..1\nok 1 beta shared in 5ms\n' > "$W/amb.tap"
  run summarize --log "$W/amb.tap"
  assert_success
  assert_output --partial '(ambiguous name)'
  assert_output --partial 'Tests not attributable to a file | 1'
}

@test "summarize: failing tests are listed and counted" {
  cat > "$W/fail.tap" <<'EOF'
1..3
ok 1 alpha one in 10ms
not ok 2 beta one in 2500ms
# (in test file x.bats, line 3)
not ok 3 mystery test in 5ms
EOF
  run summarize --log "$W/fail.tap"
  assert_success
  assert_output --partial '(1 passed, 2 failed, 0 skipped)'
  assert_output --partial '### Failed tests'
  assert_output --partial '- 20-beta.bats: beta one'
  assert_output --partial '- (unmapped): mystery test'
}

@test "summarize: a log without timings says so and still counts results" {
  printf '1..2\nok 1 alpha one\nnot ok 2 beta one\n' > "$W/untimed.tap"
  run summarize --log "$W/untimed.tap" --timeout-minutes 25
  assert_success
  assert_output --partial 'Tests reported | 2 (1 passed, 1 failed, 0 skipped)'
  assert_output --partial 'No per-test timings were present'
  assert_output --partial 'ACQ_BATS_TIMING=1'
  refute_output --partial 'Slowest 15 tests'
}

@test "summarize: empty input and a missing log degrade to a clear message and exit 0" {
  : > "$W/empty.tap"
  run summarize --log "$W/empty.tap"
  assert_success
  assert_output --partial 'No bats test results were found in the log.'

  run summarize --log "$W/does-not-exist.tap"
  assert_success
  assert_output --partial 'No bats log was found'

  run bash -c ': | python3 "$1" --tests-dir "$2" --log -' _ "$SUMMARIZE" "$TESTS"
  assert_success
  assert_output --partial 'No bats test results were found'
}

@test "summarize: bad arguments never fail the job" {
  run summarize --no-such-flag
  assert_success
  assert_output --partial 'Invalid arguments'
  run summarize --timeout-minutes notanumber
  assert_success
  assert_output --partial 'Invalid arguments'
}

@test "summarize: partial output from a cancelled run is flagged as incomplete" {
  printf '1..400\nok 1 alpha one in 30ms\nok 2 alpha two in 40ms\n' > "$W/partial.tap"
  run summarize --log "$W/partial.tap" --timeout-minutes 25
  assert_success
  assert_output --partial 'Run incomplete | 2 of 400 planned tests reported'
}

@test "summarize: names with pipes, markup and control characters cannot break the Markdown" {
  local tap="$W/evil.tap"
  {
    printf '1..3\n'
    printf 'ok 1 a | b <img src=x onerror=1> [link](http://x) `tick` *bold* in 900ms\n'
    printf 'ok 2 tab\there and \033[31mcolor\033[0m in 800ms\n'
    printf 'ok 3 %s in 700ms\n' "$(printf 'x%.0s' $(seq 1 600))"
  } > "$tap"
  run summarize --log "$tap"
  assert_success
  assert_output --partial 'a &#124; b &lt;img src=x onerror=1&gt; \[link\]'
  assert_output --partial '\`tick\` \*bold\*'
  refute_output --partial '<img'
  refute_output --partial $'\033'
  refute_output --partial 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
  # every table row keeps exactly the header's column count
  run bash -c 'python3 "$1" --tests-dir "$2" --log "$3" | grep -E "^\| [0-9]+ \| [0-9.ms ]+ \| " | awk -F"[|]" "{print NF}" | sort -u' _ "$SUMMARIZE" "$TESTS" "$tap"
  assert_success
  assert_output '6'
}

@test "summarize: log text can never become a workflow command" {
  local tap="$W/inject.tap"
  {
    printf '::set-output name=pwn::1\n'
    printf '1..4\n'
    printf 'ok 1 ::error::boom in 100ms\n'
    printf 'ok 2 ::add-mask::secret in 200ms\n'
    printf 'not ok 3 ::set-env name=X::y in 300ms\n'
    printf 'ok 4 \n::stop-commands::tok in 400ms\n'
    printf '::warning::injected\n'
  } > "$tap"
  run summarize --log "$tap" --timeout-minutes 1 --wall-seconds 55
  assert_success
  # the only line allowed to start with :: is our own numeric warning
  run bash -c 'python3 "$1" --tests-dir "$2" --log "$3" --timeout-minutes 1 --wall-seconds 55 | grep -c "^::"' _ "$SUMMARIZE" "$TESTS" "$tap"
  assert_output '1'
  run bash -c 'python3 "$1" --tests-dir "$2" --log "$3" --timeout-minutes 1 --wall-seconds 55 | grep "^::"' _ "$SUMMARIZE" "$TESTS" "$tap"
  assert_output --regexp '^::warning title=bats suite slow::suite wall time [0-9a-z ]+ is [0-9]+% of the [0-9.]+ minute job timeout$'
  # and the same text written to a summary file never starts a line with ::
  run summarize --log "$tap" --summary-file "$W/summary.md"
  assert_success
  run grep -c '^::' "$W/summary.md"
  assert_output '0'
}

@test "summarize: warning annotation fires only above the configured fraction" {
  printf '1..1\nok 1 alpha one in 10ms\n' > "$W/w.tap"
  run summarize --log "$W/w.tap" --timeout-minutes 10 --wall-seconds 419
  refute_output --partial '::warning'
  run summarize --log "$W/w.tap" --timeout-minutes 10 --wall-seconds 421
  assert_output --partial '::warning title=bats suite slow::suite wall time 7m 01s is 70% of the 10 minute job timeout'
  run summarize --log "$W/w.tap" --timeout-minutes 10 --wall-seconds 421 --warn-fraction 0
  refute_output --partial '::warning'
  run summarize --log "$W/w.tap" --timeout-minutes 10 --wall-seconds 100 --warn-fraction 0.1
  assert_output --partial '::warning'
}

@test "summarize: writes a machine-readable record and appends Markdown to the summary file" {
  printf '1..2\nok 1 alpha one in 1200ms\nok 2 beta one in 3400ms\n' > "$W/j.tap"
  printf 'existing\n' > "$W/summary.md"
  run summarize --log "$W/j.tap" --timeout-minutes 25 --wall-seconds 100 --shard 'shard 2/4;x' --json "$W/t.json" --summary-file "$W/summary.md"
  assert_success
  assert_output ''
  run head -1 "$W/summary.md"
  assert_output 'existing'
  run grep -F '## bats timing (shard: shard_2_4_x)' "$W/summary.md"
  assert_success
  run python3 - "$W/t.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == 1 and d["shard"] == "shard_2_4_x", d["shard"]
assert d["tests"] == 2 and d["sum_ms"] == 4600 and d["wall_seconds"] == 100.0
assert d["timeout_minutes"] == 25.0 and d["wall_fraction"] == round(100 / 1500, 4)
assert [t["name"] for t in d["slowest_tests"]] == ["beta one", "alpha one"]
assert d["files"][0] == {"file": "20-beta.bats", "tests": 1, "ms": 3400, "max_ms": 3400}
print("json ok")
PY
  assert_success
  assert_output 'json ok'
}

@test "summarize: the shard label defaults to ACQ_SHARD_ID, then to all" {
  printf '1..1\nok 1 alpha one in 10ms\n' > "$W/s.tap"
  run env ACQ_SHARD_ID=3 python3 "$SUMMARIZE" --tests-dir "$TESTS" --log "$W/s.tap"
  assert_output --partial '(shard: 3)'
  run env -u ACQ_SHARD_ID python3 "$SUMMARIZE" --tests-dir "$TESTS" --log "$W/s.tap"
  assert_output --partial '(shard: all)'
}

@test "summarize: wall time comes from the start-epoch file and log mtime" {
  printf '1..1\nok 1 alpha one in 10ms\n' > "$W/m.tap"
  touch -d '2026-01-01 00:10:00 UTC' "$W/m.tap" 2>/dev/null || touch -t 202601010010 "$W/m.tap"
  local end
  end="$(python3 -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$W/m.tap")"
  printf '%s\n' "$((end - 300))" > "$W/start"
  run summarize --log "$W/m.tap" --start-epoch-file "$W/start" --timeout-minutes 10
  assert_success
  assert_output --partial '5m 00s wall'
  assert_output --partial '5m 00s left, suite used 50%'
}

@test "summarize: a very large log is summarized quickly and keeps bounded output" {
  python3 - "$W/big.tap" <<'PY'
import sys
with open(sys.argv[1], "w") as fh:
    fh.write("1..60000\n")
    for i in range(1, 60001):
        fh.write("ok %d generated test %d in %dms\n" % (i, i % 997, (i * 7919) % 5000))
    fh.write("x" * 1000000 + "\n")
PY
  run summarize --log "$W/big.tap" --timeout-minutes 25 --wall-seconds 60 --json "$W/big.json"
  assert_success
  assert_output --partial 'Tests reported | 60000 (60000 passed'
  assert_output --partial 'Slowest 15 tests'
  [ "${#lines[@]}" -lt 80 ]
  run wc -c < "$W/big.json"
  [ "$output" -lt 200000 ]
}

@test "summarize: reads a timestamped CI log and derives wall time from its timestamps" {
  cat > "$W/ci.log" <<'EOF'
2026-10-28T22:46:39.5248848Z test-acq-bats: workers=4; per-test timings include setup and teardown
2026-10-28T22:46:57.2065672Z 1..2
2026-10-28T22:47:06.8428017Z ok 1 alpha one in 913ms
2026-10-28T22:50:09.5005398Z ok 2 beta one in 859ms
EOF
  run summarize --log "$W/ci.log" --timeout-minutes 25
  assert_success
  assert_output --partial '3m 30s wall'
  assert_output --partial '(4 workers)'
}

@test "summarize: an absurd duration or non-finite argument never discards the summary or fails" {
  local big
  big="$(printf '9%.0s' $(seq 1 400))"
  printf '1..2\nok 1 alpha one in %sms\nok 2 alpha two in 5ms\n' "$big" > "$W/huge.tap"
  run summarize --log "$W/huge.tap"
  assert_success
  assert_output --partial 'Tests reported | 2'
  for v in inf nan -5 1e999 abc; do
    run summarize --log "$W/huge.tap" --wall-seconds "$v"
    assert_success
    assert_output --partial 'Invalid arguments'
  done
  run summarize --help
  assert_success
  assert_output --partial 'Invalid arguments'
}

@test "summarize: invalid-argument and failure notes land in the summary file, not just stdout" {
  run summarize --bogus --summary-file "$W/s.md"
  assert_success
  assert_output ''
  run grep -F 'Invalid arguments' "$W/s.md"
  assert_success
}

@test "summarize: unwritable outputs and a closed stdout still exit 0" {
  printf '1..1\nok 1 alpha one in 10ms\n' > "$W/u.tap"
  run summarize --log "$W/u.tap" --json "$W/no/such/dir/t.json" --summary-file "$W/no/such/dir/s.md"
  assert_success
  run bash -c 'python3 "$1" --tests-dir "$2" --log "$3" >&-' _ "$SUMMARIZE" "$TESTS" "$W/u.tap"
  assert_success
  run bash -c 'python3 "$1" --tests-dir "$2" --log "$3" | true' _ "$SUMMARIZE" "$TESTS" "$W/u.tap"
  assert_success
  run summarize --log "$W"
  assert_success
}

@test "summarize: bidi/zero-width characters are neutralized and autolinks are broken up" {
  {
    printf '1..1\n'
    printf 'ok 1 evil \xe2\x80\xae gnp.txt http://evil.example www.evil.example @someone in 100ms\n'
  } > "$W/b.tap"
  run summarize --log "$W/b.tap"
  assert_success
  refute_output --partial $'\xe2\x80\xae'
  refute_output --partial 'http://evil'
  refute_output --partial 'www.evil'
  refute_output --partial '@someone'
}

# --- real bats output -------------------------------------------------------
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
  run summarize --log "$W/a.tap" --json "$W/a.json"
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
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["timed"] >= 2 and d["sum_ms"] > 0 else 1)' "$W/$f.json"
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
