#!/usr/bin/env bats
#
# 170-kit-ref-shape.bats — a remote kit ref (git+…) whose transport URL has a
# query string, or whose '#' fragment has a parameter other than ref= and dir=,
# is refused where it enters (--kit, ACQ_EXTRA_KITS), by the fetch itself, and
# when a sandbox's kit record is reloaded. The refusal never repeats the URL or
# the offending value, and nothing is fetched, recorded or handed to a backend.
# Canonical refs and local paths holding '?' or '#' keep working.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

_PIN=0123456789abcdef0123456789abcdef01234567
_QUERY_REF="git+https://example.test/kits.git?private_token=s3cr3t-tok#ref=${_PIN}&dir=k"
_FRAG_REF="git+https://example.test/kits.git#ref=${_PIN}&dir=k&token=s3cr3t-tok"

_seed_usai() {
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
}

@test "kit_ref_shape_check: a query string before '#' is refused without naming it" {
  load_acq
  run kit_ref_shape_check "$_QUERY_REF"
  assert_failure
  assert_output --partial 'remote kit ref refused: its URL has a query string'
  refute_output --partial 's3cr3t-tok'
  refute_output --partial 'private_token'
  refute_output --partial 'example.test'
}

@test "kit_ref_shape_check: a fragment parameter other than ref= and dir= is refused" {
  load_acq
  local ref
  for ref in "$_FRAG_REF" "git+https://example.test/kits.git#ref=${_PIN}&&dir=k" \
      "git+https://example.test/kits.git#token=s3cr3t-tok&ref=${_PIN}&dir=k"; do
    run kit_ref_shape_check "$ref" "--kit"
    assert_failure
    assert_output --partial "acq: --kit: remote kit ref refused: its '#' fragment has a parameter other than ref= and dir="
    refute_output --partial 's3cr3t-tok'
    refute_output --partial 'token='
  done
}

@test "kit_ref_shape_check and kit_ref_display agree with the shared probes" {
  # test/fixtures/kit-ref-probes.tsv is also read by py-acq/tests/test_kit_fetch.py.
  load_acq
  local verdict shown ref got n=0
  while IFS="$(printf '\t')" read -r verdict shown ref; do
    case "$verdict" in '#'* | '') continue ;; esac
    n=$((n + 1))
    if kit_ref_shape_check "$ref" 2>"$STUBDIR/probe.err"; then got=pass; else got=refuse; fi
    assert_equal "$got $ref" "$verdict $ref"
    assert_equal "$(kit_ref_display "$ref")" "$shown"
    run cat "$STUBDIR/probe.err"
    refute_output --partial 'SEKRIT'
  done < "$REPO_ROOT/test/fixtures/kit-ref-probes.tsv"
  [ "$n" -ge 20 ]
}

@test "kit_ref_shape_check: a ref= or dir= value with an odd character, or a repeat, is refused" {
  load_acq
  local ref
  for ref in "git+https://example.test/kits.git#ref=${_PIN}?token=s3cr3t-tok&dir=k" \
      "git+https://example.test/kits.git#ref=${_PIN};token=s3cr3t-tok&dir=k" \
      "git+https://example.test/kits.git#ref=${_PIN}#token=s3cr3t-tok&dir=k" \
      "git+https://example.test/kits.git#ref=${_PIN}&ref=s3cr3t-tok&dir=k" \
      "git+https://example.test/kits.git#ref=${_PIN}&dir=k?x=s3cr3t-tok"; do
    run kit_ref_shape_check "$ref" "--kit"
    assert_failure
    assert_output --partial 'acq: --kit: remote kit ref refused'
    refute_output --partial 's3cr3t-tok'
  done
}

@test "kit_ref_shape_check: a ref= or dir= value starting with '-' is refused" {
  load_acq
  local ref
  for ref in "git+https://example.test/kits.git#ref=-oupload-pack=s3cr3t-tok&dir=k" \
      "git+https://example.test/kits.git#ref=${_PIN}&dir=-s3cr3t-tok"; do
    run kit_ref_shape_check "$ref" "--kit"
    assert_failure
    assert_output --partial "starts with '-'"
    refute_output --partial 's3cr3t-tok'
  done
}

@test "the fetch passes -- before the ref, so git never reads it as an option" {
  run grep -c 'fetch --depth 1 origin -- "\$ref"' "$REPO_ROOT/acq.backends/kit-translate.sh"
  assert_output '2'
}

@test "charset checks do not widen under a UTF-8 locale" {
  load_acq
  local loc="" cand
  for cand in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
    if locale -a 2>/dev/null | grep -qix "$cand"; then loc="$cand"; break; fi
  done
  [ -n "$loc" ] || skip "no UTF-8 locale installed"
  local v
  for v in "abcé" "kitsß" "ａｂｃ"; do
    run env LC_ALL="$loc" bash -c '. "$1"; LC_ALL="$2"; _kit_ref_value_plain "$3"' _ \
      "$REPO_ROOT/acq.backends/kit-translate.sh" "$loc" "$v"
    assert_failure
    run env LC_ALL="$loc" bash -c 'LC_ALL="$1"; eval "$(sed -n "/^_acq_sbx_placeholder_ok() {/,/^}/p" "$2")"; _acq_sbx_placeholder_ok "$3"' _ \
      "$loc" "$REPO_ROOT/acq.backends/sbx.sh" "sbx-cs-$v"
    assert_failure
  done
  run env LC_ALL="$loc" bash -c '. "$1"; LC_ALL="$2"; _kit_ref_value_plain "kits/one-2.x_y"' _ \
    "$REPO_ROOT/acq.backends/kit-translate.sh" "$loc"
  assert_success
}

@test "kit_translate_fetch: an unsafe dir= is refused without repeating it" {
  load_acq
  run kit_translate_fetch "git+https://example.test/kits.git#ref=${_PIN}&dir=../s3cr3t-tok" "$STUBDIR/u"
  assert_failure
  assert_output --partial 'unsafe kit dir'
  refute_output --partial 's3cr3t-tok'
}

@test "ls: a refused ACQ_EXTRA_KITS or ACQ_PROVIDER_KITS ref does not block an unrelated verb" {
  local var
  for var in ACQ_EXTRA_KITS ACQ_PROVIDER_KITS; do
    : > "$CALLS"
    run env ACQ_BACKEND=sbx "$var=$_QUERY_REF" "$ACQ" ls
    assert_success
    refute_output --partial 's3cr3t-tok'
    refute_output --partial 'remote kit ref refused'
    assert_regex "$(cat "$CALLS")" 'sbx ls'
  done
}

@test "kit list: a refused ACQ_PROVIDER_KITS ref is refused, not listed" {
  run env ACQ_BACKEND=sbx ACQ_PROVIDER_KITS="$_FRAG_REF" "$ACQ" kit list
  assert_failure
  assert_output --partial 'acq: ACQ_PROVIDER_KITS: remote kit ref refused'
  refute_output --partial 's3cr3t-tok'
}

@test "kit_ref_shape_check: canonical refs, built-in refs and local paths pass" {
  load_acq
  run kit_ref_shape_check "git+https://github.com/acme/kits.git#ref=${_PIN}&dir=kits/one"
  assert_success
  run kit_ref_shape_check "git+https://github.com/acme/kits.git#dir=kits/one&ref=${_PIN}"
  assert_success
  run kit_ref_shape_check "$USAI_KIT"
  assert_success
  run kit_ref_shape_check "$ZSCALER_KIT"
  assert_success
  run kit_ref_shape_check "$STUBDIR/kits/odd?name#1"
  assert_success
  # No fragment at all is left to the fetch, which reports it as malformed.
  run kit_translate_fetch "git+https://example.test/kits.git" "$STUBDIR/nofrag"
  assert_failure
  assert_output --partial 'malformed kit ref'
}

@test "kit_translate_fetch: a refused ref is never fetched" {
  load_acq
  local rc=0 out
  : > "$CALLS"
  out=$(kit_translate_fetch "$_QUERY_REF" "$STUBDIR/q" 2>"$STUBDIR/q.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  [ ! -e "$STUBDIR/q" ]
  run cat "$STUBDIR/q.err"
  assert_output --partial 'query string'
  refute_output --partial 's3cr3t-tok'
  rc=0
  out=$(kit_translate_fetch "$_FRAG_REF" "$STUBDIR/f" 2>"$STUBDIR/f.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ ! -e "$STUBDIR/f" ]
  refute_regex "$(cat "$STUBDIR/f.err")" 's3cr3t-tok'
}

@test "kit_translate_fetch: a local kit directory with '?' and '#' in its name still works" {
  load_acq
  local kit="$STUBDIR/kits/odd?name#1"
  mkdir -p "$kit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: odd\n' > "$kit/spec.yaml"
  run kit_translate_fetch "$kit" "$STUBDIR/unused"
  assert_success
  assert_output "$kit"
}

@test "kit_ref_display: a fragment parameter other than ref= and dir= is hidden" {
  load_acq
  assert_equal "$(kit_ref_display "$_FRAG_REF")" "git+https://example.test/kits.git#ref=${_PIN}&dir=k&***"
  assert_equal "$(kit_ref_display "$_QUERY_REF")" "git+https://example.test/kits.git?***#ref=${_PIN}&dir=k"
}

@test "create --kit: a refused ref stops before the sandbox, records nothing, never prints it" {
  local proj="$STUBDIR/proj" ref
  mkdir -p "$proj"
  _seed_usai
  for ref in "$_QUERY_REF" "$_FRAG_REF"; do
    : > "$CALLS"
    run env ACQ_BACKEND=sbx "$ACQ" create opencode --kit "$ref" "$proj"
    assert_failure
    assert_output --partial 'acq: --kit: remote kit ref refused'
    refute_output --partial 's3cr3t-tok'
    refute_regex "$(cat "$CALLS")" '^sbx (create|run|kit)|s3cr3t-tok'
    run grep -rl 's3cr3t-tok' "$STUBDIR/provenance" "$ACQ_STATE_DIR"
    assert_failure
  done
}

@test "run: a refused ACQ_EXTRA_KITS ref stops before the sandbox and is never printed" {
  local proj="$STUBDIR/proj2"
  mkdir -p "$proj"
  _seed_usai
  : > "$CALLS"
  run env ACQ_BACKEND=sbx ACQ_EXTRA_KITS="$_FRAG_REF" "$ACQ" run opencode "$proj"
  assert_failure
  assert_output --partial 'acq: ACQ_EXTRA_KITS: remote kit ref refused'
  refute_output --partial 's3cr3t-tok'
  refute_regex "$(cat "$CALLS")" '^sbx (create|run|kit)|s3cr3t-tok'
  run grep -rl 's3cr3t-tok' "$STUBDIR/provenance" "$ACQ_STATE_DIR"
  assert_failure
}

@test "heal(sbx): a refused extra kit is not announced, fetched or recorded" {
  load_acq
  : > "$CALLS"
  ACQ_EXTRA_KITS="$_QUERY_REF" run acq_backend_ensure_kits_applied healbox
  assert_output --partial 'remote kit ref refused'
  refute_output --partial 'applying extra kit'
  refute_output --partial 's3cr3t-tok'
  refute_regex "$(cat "$CALLS")" 's3cr3t-tok'
  assert_equal "$(acq_host_config_read sbx healbox extra-kits)" ''
}

@test "cli-kits: a recorded ref acq now refuses is skipped without being named" {
  load_acq
  local file
  file=$(_acq_cli_kits_file msb oldbox)
  mkdir -p "$(dirname "$file")"
  printf 'schema=1\nkit=%s\nextra=%s\nkit=/kits/fine\n' "$_QUERY_REF" "$_FRAG_REF" > "$file"
  ACQ_CLI_KITS=(); ACQ_EXTRA_KITS=""
  acq_cli_kits_load msb oldbox 2>"$STUBDIR/load.err"
  assert_equal "${#ACQ_CLI_KITS[@]}" "1"
  assert_equal "${ACQ_CLI_KITS[0]}" "/kits/fine"
  assert_equal "$ACQ_EXTRA_KITS" ""
  run cat "$STUBDIR/load.err"
  assert_output --partial 'ignoring a recorded remote kit ref for oldbox'
  assert_output --partial 'Recreate the sandbox to clear it'
  refute_output --partial 's3cr3t-tok'
}

@test "heal: a refused extra ref latched by the kit list stops the heal" {
  load_acq
  ACQ_EXTRA_KITS="$_QUERY_REF"
  _build_kit_list
  : > "$CALLS"
  run acq_backend_ensure_kits_applied healbox
  assert_failure
  assert_output --partial 'acq: ACQ_EXTRA_KITS: remote kit ref refused'
  assert_output --partial "the kits of sandbox 'healbox' were not re-applied"
  refute_output --partial 's3cr3t-tok'
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
}
