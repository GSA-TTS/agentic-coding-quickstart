#!/usr/bin/env bats
#
# 92-sbx-kit-refusal.bats — on sbx, a kit whose payload fails acq's checks, or
# whose fetch acq refuses or cannot complete, is never handed to sbx:
# translation returns non-zero with no output, and create, mid-life apply and
# the heal stop instead of passing sbx a raw or empty ref. Runs with the offline
# passthrough disabled so the real translation runs.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; unset ACQ_SBX_KIT_PASSTHROUGH; }
teardown() { acq_teardown_stubs; }

load 'helper'

# A neutral kit whose files/ tree links to a file outside the kit.
_bad_neutral_kit() {
  local kit="$1"
  mkdir -p "$kit/files"
  printf 'x\n' > "$kit/files/ok"
  printf 'outside\n' > "$STUBDIR/outside.txt"
  ln -s "$STUBDIR/outside.txt" "$kit/files/out"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: bad\ndisplayName: Bad\ndescription: d\n' > "$kit/spec.yaml"
}

@test "sbx: translation of a refused neutral kit fails with no output" {
  local kit="$STUBDIR/badkit" errf="$STUBDIR/t.err" out rc=0
  _bad_neutral_kit "$kit"
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$kit" 2>"$errf") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$errf"
  assert_output --partial 'kit translation failed; not applying'
  refute_output --partial 'passing ref through'
}

@test "sbx: an sbx-v2 kit with a payload link outside the kit is refused" {
  local kit="$STUBDIR/v2kit" out rc=0
  mkdir -p "$kit/files"
  printf 'outside\n' > "$STUBDIR/outside.txt"
  ln -s "$STUBDIR/outside.txt" "$kit/files/out"
  printf 'schemaVersion: "2"\nname: v2\n' > "$kit/spec.yaml"
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$kit" 2>"$STUBDIR/v2.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/v2.err"
  assert_output --partial 'payload links outside the kit'
}

@test "sbx: mid-life apply of a refused kit fails without calling sbx kit add" {
  local kit="$STUBDIR/applykit" rc=0
  _bad_neutral_kit "$kit"
  : > "$CALLS"
  ACQ_SBX_KIT_CACHE="$STUBDIR/cache" acq_backend_apply_kit applybox "$kit" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
}

@test "sbx: kit add with an empty kit path fails without calling sbx" {
  : > "$CALLS"
  run _acq_sbx_kit_add emptybox ""
  assert_failure
  assert_output --partial 'no usable kit to add'
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
}

@test "sbx: provision with a refused extra kit never creates the sandbox" {
  local kit="$STUBDIR/provkit" rc=0
  _bad_neutral_kit "$kit"
  : > "$CALLS"
  (
    export ACQ_SBX_KIT_CACHE="$STUBDIR/cache" ACQ_EXTRA_KITS="$kit"
    acq_test_stub_provider_input_boundary
    acq_backend_provision provbox shell "$STUBDIR"
  ) > "$STUBDIR/prov.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  run cat "$STUBDIR/prov.out"
  assert_output --partial 'a kit could not be prepared'
  refute_regex "$(cat "$CALLS")" '^sbx (create|run)'
}

# ---------------------------------------------------------------------------
# Fetch failures: acq's own refusals and plain transport failures alike.
# ---------------------------------------------------------------------------

_CRED_REF='git+https://kituser:s3cr3t-tok@example.invalid/kits.git#ref=0123456789abcdef0123456789abcdef01234567&dir=k'

# A two-commit local repository plus a git wrapper that serves it offline.
# FETCH_MODE=fail makes every fetch fail; FETCH_MODE=wrong serves the second
# commit whatever was asked for. Sets PIN (first commit) and KIT_REF.
_mk_fetch_fixture() {
  local src="$STUBDIR/source"
  mkdir -p "$src/kits/one"
  printf 'schemaVersion: "2"\nname: one\n' > "$src/kits/one/spec.yaml"
  "$ACQ_TEST_REAL_GIT" -C "$src" init -q
  "$ACQ_TEST_REAL_GIT" -C "$src" add .
  "$ACQ_TEST_REAL_GIT" -C "$src" -c commit.gpgsign=false -c user.name=F -c user.email=f@example.test commit -qm one
  PIN=$("$ACQ_TEST_REAL_GIT" -C "$src" rev-parse HEAD)
  printf 'schemaVersion: "2"\nname: two\n' > "$src/kits/one/spec.yaml"
  "$ACQ_TEST_REAL_GIT" -C "$src" -c commit.gpgsign=false -c user.name=F -c user.email=f@example.test commit -qam two
  PIN2=$("$ACQ_TEST_REAL_GIT" -C "$src" rev-parse HEAD)
  export SOURCE_REPO="$src" PIN2
  KIT_REF="git+https://example.test/kits.git#ref=$PIN&dir=kits/one"
  cat > "$STUBDIR/git" <<'GIT'
#!/usr/bin/env bash
args=("$@")
while [ "${1:-}" = -c ]; do shift 2; done
if [ "${1:-}" = fetch ]; then
  [ "${FETCH_MODE:-}" != fail ] || { printf 'transport detail\n' >&2; exit 1; }
  revision="${*: -1}"
  [ "${FETCH_MODE:-}" != wrong ] || revision="$PIN2"
  exec "$ACQ_TEST_REAL_GIT" -c protocol.file.allow=always fetch --depth 1 "$SOURCE_REPO" "$revision"
fi
exec "$ACQ_TEST_REAL_GIT" "${args[@]}"
GIT
  chmod +x "$STUBDIR/git"
  hash -r
}

@test "sbx: a credential-bearing kit URL is refused and the credential is not printed" {
  local out rc=0
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$_CRED_REF" 2>"$STUBDIR/c.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/c.err"
  assert_output --partial 'credential-bearing kit URLs are not allowed'
  assert_output --partial 'could not fetch kit; not applying: git+https://***@example.invalid/kits.git#ref='
  refute_output --partial 's3cr3t-tok'
  refute_output --partial 'kituser'
  refute_output --partial 'passing'
}

@test "sbx: a kit ref with an unsafe dir= is refused" {
  local d out rc
  for d in '../escape' '/abs' 'bad;name'; do
    rc=0
    out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit \
      "git+https://example.invalid/kits.git#ref=0123456789abcdef0123456789abcdef01234567&dir=$d" \
      2>"$STUBDIR/d.err") || rc=$?
    [ "$rc" -ne 0 ]
    [ -z "$out" ]
    run cat "$STUBDIR/d.err"
    assert_output --partial 'unsafe kit dir'
    assert_output --partial 'could not fetch kit; not applying'
  done
}

@test "sbx: a fetched commit that does not match the pin is refused" {
  local out rc=0
  _mk_fetch_fixture
  _ACQ_KIT_FETCH_ROOT=$(mktemp -d "$STUBDIR/reuse.XXXXXX")
  out=$(FETCH_MODE=wrong ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$KIT_REF" 2>"$STUBDIR/p.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/p.err"
  assert_output --partial 'fetched revision does not match pinned commit'
  assert_output --partial 'could not fetch kit; not applying'
  # The same ref translates once the right commit is served.
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$KIT_REF" 2>/dev/null)
  [ "$(cat "$out/spec.yaml")" = "$(printf 'schemaVersion: "2"\nname: one')" ]
}

@test "sbx: a plain network failure is not passed through to sbx either" {
  local out rc=0
  _mk_fetch_fixture
  out=$(FETCH_MODE=fail ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$KIT_REF" 2>"$STUBDIR/n.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/n.err"
  assert_output --partial 'failed to fetch remote kit'
  assert_output --partial 'gh auth setup-git'
  assert_output --partial 'could not fetch kit; not applying'
  refute_output --partial 'transport detail'
}

@test "sbx: a missing local kit path is refused" {
  local out rc=0
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$STUBDIR/no-such-kit" 2>"$STUBDIR/l.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/l.err"
  assert_output --partial 'local kit path not found'
}

@test "sbx: translation fails closed when the kit translator is not loaded" {
  local out rc=0
  mkdir -p "$STUBDIR/okkit"
  out=$(unset -f kit_translate_fetch; ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$STUBDIR/okkit" 2>"$STUBDIR/u.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/u.err"
  assert_output --partial 'kit translator is not loaded; not applying the kit'
}

@test "sbx: mid-life apply of a kit whose fetch is refused never calls sbx" {
  local rc=0
  : > "$CALLS"
  ACQ_SBX_KIT_CACHE="$STUBDIR/cache" acq_backend_apply_kit applybox "$_CRED_REF" 2>"$STUBDIR/a.err" || rc=$?
  [ "$rc" -ne 0 ]
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
  refute_regex "$(cat "$STUBDIR/a.err")" 's3cr3t-tok'
}

@test "sbx: provision with an extra kit whose fetch is refused never creates the sandbox" {
  local rc=0
  : > "$CALLS"
  (
    export ACQ_SBX_KIT_CACHE="$STUBDIR/cache" ACQ_EXTRA_KITS="$_CRED_REF"
    acq_test_stub_provider_input_boundary
    acq_backend_provision credbox shell "$STUBDIR"
  ) > "$STUBDIR/prov.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  run cat "$STUBDIR/prov.out"
  assert_output --partial 'a kit could not be prepared'
  refute_output --partial 's3cr3t-tok'
  refute_regex "$(cat "$CALLS")" '^sbx (create|run)'
  refute_regex "$(cat "$CALLS")" 'example\.invalid'
}

@test "sbx: heal never adds or records an extra kit whose fetch is refused" {
  : > "$CALLS"
  ACQ_SBX_KIT_CACHE="$STUBDIR/cache" ACQ_EXTRA_KITS="$_CRED_REF" \
    run acq_backend_ensure_kits_applied healbox
  assert_output --partial 'acq: applying extra kit to '"'healbox'"': git+https://***@example.invalid/'
  assert_output --partial 'could not fetch kit; not applying'
  refute_output --partial 's3cr3t-tok'
  refute_regex "$(cat "$CALLS")" 'example\.invalid'
  assert_equal "$(acq_host_config_read sbx healbox extra-kits)" ''
}

_NOGIT_REF='https://kituser:s3cr3t-tok@github.com/o/r.git#ref=0123456789abcdef0123456789abcdef01234567&dir=k'

@test "sbx: a credential URL without the git+ prefix is refused and not printed" {
  local out rc=0
  out=$(ACQ_SBX_KIT_CACHE="$STUBDIR/cache" _acq_sbx_translate_kit "$_NOGIT_REF" 2>"$STUBDIR/g.err") || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  run cat "$STUBDIR/g.err"
  assert_output --partial 'local kit path not found: https://***@github.com/o/r.git#ref='
  assert_output --partial 'could not fetch kit; not applying: https://***@github.com/o/r.git#ref='
  refute_output --partial 's3cr3t-tok'
  refute_output --partial 'kituser'
}

@test "sbx: apply and heal never print a credential from a ref without git+" {
  local rc=0
  : > "$CALLS"
  ACQ_SBX_KIT_CACHE="$STUBDIR/cache" acq_backend_apply_kit applybox "$_NOGIT_REF" 2>"$STUBDIR/ga.err" || rc=$?
  [ "$rc" -ne 0 ]
  refute_regex "$(cat "$STUBDIR/ga.err")" 's3cr3t-tok|kituser'
  ACQ_SBX_KIT_CACHE="$STUBDIR/cache" ACQ_EXTRA_KITS="$_NOGIT_REF" \
    run acq_backend_ensure_kits_applied healbox
  assert_output --partial 'local kit path not found: https://***@github.com/'
  refute_output --partial 's3cr3t-tok'
  refute_output --partial 'kituser'
  refute_regex "$(cat "$CALLS")" 's3cr3t-tok|sbx kit add (applybox|healbox) https://'
}

@test "kit_ref_display redacts userinfo and query strings and leaves other refs alone" {
  assert_equal "$(kit_ref_display 'git+https://u:p@h.example/r.git#ref=a&dir=b')" 'git+https://***@h.example/r.git#ref=a&dir=b'
  assert_equal "$(kit_ref_display 'https://u:p@h.example/r.git#ref=a&dir=b')" 'https://***@h.example/r.git#ref=a&dir=b'
  assert_equal "$(kit_ref_display 'git+https://h.example/r.git?private_token=tok#ref=a&dir=b')" 'git+https://h.example/r.git?***#ref=a&dir=b'
  assert_equal "$(kit_ref_display 'https://h.example/r.git?token=a@b&x=1')" 'https://h.example/r.git?***'
  assert_equal "$(kit_ref_display 'u:tok@h.example/o/r.git#ref=a')" '***@h.example/o/r.git#ref=a'
  assert_equal "$(kit_ref_display 'git+https://h.example/r.git#ref=a&dir=b@c')" 'git+https://h.example/r.git#ref=a&dir=b@c'
  assert_equal "$(kit_ref_display '/kits/local@1')" '/kits/local@1'
  assert_equal "$(kit_ref_display './kits/a:b')" './kits/a:b'
  # A bare token@host (no scheme, no password part) is userinfo too.
  assert_equal "$(kit_ref_display 'ghp_tok@h.example/o/r.git#ref=a')" '***@h.example/o/r.git#ref=a'
}

@test "kit-source: an invalid entry is named without its credential" {
  run _acq_kit_source_parse_entry 'https://kituser:s3cr3t-tok@github.com/acme/kits@abc' kit_sources
  assert_failure
  assert_output --partial "invalid kit source 'https://***@"
  refute_output --partial 's3cr3t-tok'
  refute_output --partial 'kituser'
}

@test "sbx: the extra-kit record warning redacts the ref" {
  local ref='https://kituser:s3cr3t-tok@github.com/o/r.git#ref=abc&dir=x'
  _acq_sbx_translate_kit() { printf '%s\n' "$STUBDIR/translated"; }
  _acq_sbx_kit_add() { return 0; }
  acq_host_config_append() { return 1; }
  ACQ_EXTRA_KITS="$ref" run acq_backend_ensure_kits_applied recwarnbox
  assert_output --partial "could not record extra kit 'https://***@github.com/"
  refute_output --partial 's3cr3t-tok'
}

@test "sbx: the translate debug line names the ref only through kit_ref_display" {
  local ref='https://kituser:s3cr3t-tok@github.com/o/r.git#ref=abc&dir=x'
  kit_translate_fetch() { mkdir -p "$STUBDIR/fetched"; printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\n' > "$STUBDIR/fetched/spec.yaml"; printf '%s\n' "$STUBDIR/fetched"; }
  kit_translate_to_sbx() { mkdir -p "$2"; }
  _acq_sbx_warn_readonly_files() { :; }
  # stdout is the translated dir the caller consumes; only stderr reaches a log.
  local rc=0
  ACQ_DEBUG=1 ACQ_SBX_KIT_PASSTHROUGH="" ACQ_SBX_KIT_CACHE="$STUBDIR/cache" \
    _acq_sbx_translate_kit "$ref" >/dev/null 2>"$STUBDIR/translate.err" || rc=$?
  assert_equal "$rc" "0"
  run cat "$STUBDIR/translate.err"
  assert_output --partial 'translate(sbx): https://***@github.com/'
  refute_output --partial 's3cr3t-tok'
}

@test "heal(sbx): recorded built-in kits are not fetched or translated" {
  printf 'offlinebox\n' > "$STUBDIR/.sandbox_list"
  acq_host_config_write sbx offlinebox builtin-kits "zscaler-ca-certificate ${ZSCALER_KIT}
${USAI_PROVIDER_KIT_NAME} ${USAI_KIT}
agentic-coding-playbook ${PLAYBOOK_KIT}"
  # An offline fetch: every translation fails and says so.
  kit_translate_fetch() { echo "FETCH-ATTEMPT $1" >&2; return 1; }
  ACQ_SBX_KIT_PASSTHROUGH="" ACQ_SBX_KIT_CACHE="$STUBDIR/cache" run acq_backend_ensure_kits_applied offlinebox
  assert_success
  refute_output --partial 'FETCH-ATTEMPT'
  refute_output --partial 'could not fetch kit'
  # An unrecorded kit is still fetched, and its failed translation is a failed add.
  acq_host_config_write sbx offlinebox builtin-kits "zscaler-ca-certificate ${ZSCALER_KIT}
${USAI_PROVIDER_KIT_NAME} ${USAI_KIT}"
  ACQ_SBX_KIT_PASSTHROUGH="" ACQ_SBX_KIT_CACHE="$STUBDIR/cache" run acq_backend_ensure_kits_applied offlinebox
  assert_output --partial 'missing the playbook kit'
  assert_output --partial 'FETCH-ATTEMPT'
  assert_output --partial "'sbx kit add' (playbook kit) failed"
  refute_regex "$(printf '%s\n' "$output" | grep FETCH-ATTEMPT)" 'zscaler'
}
