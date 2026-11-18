#!/usr/bin/env bats
# scripts/bats-shard: deterministic, balanced, fail-closed selection of shard I/N.

load 'helper'

setup() {
  acq_setup_stubs
  SHARD="$REPO_ROOT/scripts/bats-shard"
  FAKE="$STUBDIR/fake-bats"
  mkdir -p "$FAKE"
  # Uneven sizes so weighting matters: big=5 tests, mid=3, small*=1, empty=0 (weight floor 1).
  make_fake big 5
  make_fake mid 3
  make_fake small-a 1
  make_fake small-b 1
  make_fake small-c 1
  : > "$FAKE/empty.bats"
}

teardown() { acq_teardown_stubs; }

make_fake() {
  local name="$1" count="$2" i
  : > "$FAKE/$name.bats"
  for ((i = 1; i <= count; i++)); do
    printf '@test "%s %d" {\n  true\n}\n' "$name" "$i" >> "$FAKE/$name.bats"
  done
}

# Collect the shard selections for N shards into $STUBDIR/sel.I files.
select_all() {
  local n="$1" dir="${2:-$FAKE}" i
  for ((i = 1; i <= n; i++)); do
    bash "$SHARD" "$i/$n" "$dir" > "$STUBDIR/sel.$i" || return 1
  done
}

@test "bats-shard: every file lands in exactly one shard for N=1..6" {
  local n
  for n in 1 2 3 4 5 6; do
    select_all "$n"
    cat "$STUBDIR"/sel.* | sort > "$STUBDIR/union"
    ls "$FAKE"/*.bats | sort > "$STUBDIR/all"
    diff "$STUBDIR/union" "$STUBDIR/all"
    [ -z "$(sort "$STUBDIR/union" | uniq -d)" ]
    rm -f "$STUBDIR"/sel.*
  done
}

@test "bats-shard: selection is deterministic across runs" {
  run bash "$SHARD" 2/3 "$FAKE"
  assert_success
  local first="$output"
  run bash "$SHARD" 2/3 "$FAKE"
  assert_success
  assert_output "$first"
}

@test "bats-shard: balances by @test count, not by file count" {
  # 5+3+1+1+1+(1 floor) = 12 tests -> two shards of 6.
  select_all 2
  local i total
  for i in 1 2; do
    total=0
    while IFS= read -r f; do
      c=$(grep -c '^@test' "$f" || true); [ "$c" -ge 1 ] || c=1
      total=$((total + c))
    done < "$STUBDIR/sel.$i"
    [ "$total" -eq 6 ]
  done
}

@test "bats-shard: a newly added file is picked up with no table to update" {
  make_fake brand-new 2
  select_all 3
  cat "$STUBDIR"/sel.* | grep -c 'brand-new.bats$' | grep -qx 1
  [ "$(cat "$STUBDIR"/sel.* | wc -l | tr -d ' ')" -eq 7 ]
}

@test "bats-shard: removing a file leaves a complete, duplicate-free partition" {
  rm "$FAKE/mid.bats"
  select_all 3
  cat "$STUBDIR"/sel.* | sort > "$STUBDIR/union"
  ls "$FAKE"/*.bats | sort > "$STUBDIR/all"
  diff "$STUBDIR/union" "$STUBDIR/all"
  [ -z "$(uniq -d "$STUBDIR/union")" ]
}

@test "bats-shard: paths are absolute and handle spaces" {
  make_fake 'has space' 1
  run bash "$SHARD" 1/1 "$FAKE"
  assert_success
  assert_line "$FAKE/has space.bats"
}

@test "bats-shard: malformed specs fail closed with status 2 and no output" {
  local spec
  for spec in '' 0/2 3/2 a/b 1/0 1/ /2 01/2 1/02 1/2/3 ' 1/2' '1/2;x' -1/2 1/99999 '1 /2'; do
    run bash "$SHARD" "$spec" "$FAKE"
    assert_failure 2
    refute_output --regexp '\.bats'
  done
}

@test "bats-shard: no spec argument fails closed" {
  run bash "$SHARD"
  assert_failure 2
}

@test "bats-shard: an empty shard fails closed rather than passing vacuously" {
  run bash "$SHARD" 7/7 "$FAKE"
  assert_failure 2
  assert_output --partial 'empty'
}

@test "bats-shard: missing directory and directory without .bats files fail closed" {
  run bash "$SHARD" 1/2 "$STUBDIR/nope"
  assert_failure 2
  mkdir "$STUBDIR/none"
  run bash "$SHARD" 1/2 "$STUBDIR/none"
  assert_failure 2
}

@test "bats-shard: real suite partitions completely for N=2 and N=3" {
  local n
  for n in 2 3; do
    select_all "$n" "$REPO_ROOT/test/bats"
    cat "$STUBDIR"/sel.* | sort > "$STUBDIR/union"
    ls "$REPO_ROOT"/test/bats/*.bats | sort > "$STUBDIR/all"
    diff "$STUBDIR/union" "$STUBDIR/all"
    [ -z "$(uniq -d "$STUBDIR/union")" ]
    rm -f "$STUBDIR"/sel.*
  done
}
