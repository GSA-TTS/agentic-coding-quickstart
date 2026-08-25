#!/usr/bin/env bats
#
# 85-kit-provenance.bats — bats port of scripts/test-acq.d/85-kit-provenance.sh
# (ADR-0025)
#
# Kit-bundle provenance + staleness: the provenance helpers (host-side) and the
# `acq kit check|update` subcommands plus the run-check advisory. ACQ_PROVENANCE_DIR
# is isolated per @test by make_stubs.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Seed a STALE provenance record via the real helper (so the cksum-suffixed
# filename matches lookup), then rewrite applied_ref to an old value in place.
_seed_stale_provenance() { # BACKEND NAME
  local backend="$1" name="$2" f
  acq_provenance_write "$backend" "$name"
  f=$(_acq_provenance_file "$backend" "$name")
  awk '/^applied_ref=/ { print "applied_ref=oldoldoldoldoldoldoldoldoldoldoldoldoldo"; next } { print }' \
    "$f" > "$f.seed" && mv -f "$f.seed" "$f"
}

@test "provenance: unknown -> current on write; a pin bump reads stale" {
  local pin; pin=$(printf '%s' "$PATTERNS_KIT_REF")
  assert_equal "$(acq_provenance_status sbx pbox)" "unknown"
  acq_provenance_write sbx pbox
  assert_equal "$(acq_provenance_status sbx pbox)" "current"
  assert_equal "$(acq_provenance_field sbx pbox applied_ref)" "$pin"
  assert_equal "$(acq_provenance_field sbx pbox bundle)" "acq-builtin"
  # A local pin bump (in a subshell so the change is scoped) reads stale.
  local status
  status=$(PATTERNS_KIT_REF="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" acq_provenance_status sbx pbox)
  assert_equal "$status" "stale"
}

@test "provenance: backend keying — sbx and msb records do not collide" {
  acq_provenance_write sbx dup
  assert_equal "$(acq_provenance_status msb dup)" "unknown"
  acq_provenance_write msb dup
  assert_equal "$(acq_provenance_status msb dup)" "current"
  assert_equal "$(acq_provenance_status sbx dup)" "current"
}

@test "provenance: a name with path metacharacters is sanitized (no traversal)" {
  acq_provenance_write sbx "evil/../../name"
  local travel; travel=$(find "$ACQ_PROVENANCE_DIR" -name '*.env' 2>/dev/null | head -n1)
  assert_regex "$travel" 'evil_\.\._\.\._name'
  assert_regex "$travel" '/sbx/'
}

@test "provenance: names that sanitize alike are disambiguated by cksum" {
  acq_provenance_write sbx "a/b"
  assert_equal "$(acq_provenance_status sbx "a_b")" "unknown"
}

@test "kit check: reports status read-only (no kit add), shows the applied ref" {
  local pin; pin=$(printf '%s' "$PATTERNS_KIT_REF")
  printf 'cbox\n' > "$STUBDIR/.sandbox_list"
  acq_provenance_write sbx cbox
  run env ACQ_BACKEND=sbx "$ACQ" kit check cbox
  assert_success
  assert_output --partial 'current'
  assert_output --partial "$pin"
  refute_regex "$(cat "$CALLS")" 'sbx kit add'
}

@test "kit check: a legacy sandbox (no record) reads unknown with an update hint" {
  printf 'legacybox\n' > "$STUBDIR/.sandbox_list"
  run env ACQ_BACKEND=sbx "$ACQ" kit check legacybox
  assert_output --partial 'unknown'
  assert_output --partial 'acq kit update legacybox'
}

@test "kit check: a missing sandbox arg errors with usage" {
  run env ACQ_BACKEND=sbx "$ACQ" kit check
  assert_failure
  assert_output --partial 'usage: acq kit check'
}

@test "kit update --yes: reapplies and refreshes provenance stale -> current" {
  printf 'ubox\n' > "$STUBDIR/.sandbox_list"
  _seed_stale_provenance sbx ubox
  assert_equal "$(acq_provenance_status sbx ubox)" "stale"
  run env ACQ_BACKEND=sbx "$ACQ" kit update ubox --yes
  assert_success
  assert_equal "$(acq_provenance_status sbx ubox)" "current"
}

@test "kit update: already-current is a no-op success" {
  printf 'okbox\n' > "$STUBDIR/.sandbox_list"
  acq_provenance_write sbx okbox
  run env ACQ_BACKEND=sbx "$ACQ" kit update okbox --yes
  assert_success
  assert_output --partial 'already on the pinned bundle'
}

@test "kit update: refuses non-interactively without --yes" {
  printf 'nbox\n' > "$STUBDIR/.sandbox_list"
  _seed_stale_provenance sbx nbox
  run bash -c 'ACQ_BACKEND=sbx "$1" kit update nbox </dev/null' _ "$ACQ"
  assert_failure
  assert_output --partial 'without --yes'
}

@test "kit update: a missing sandbox errors clearly" {
  : > "$STUBDIR/.sandbox_list"
  run env ACQ_BACKEND=sbx "$ACQ" kit update ghost --yes
  assert_failure
  assert_output --partial 'no such sandbox'
}

@test "run-check: current is silent and non-blocking" {
  acq_provenance_write sbx runbox
  # maybe_offer_bundle_refresh is defined by load_acq in this @test's shell.
  run maybe_offer_bundle_refresh sbx runbox
  assert_success
  assert_output ''
}

@test "run-check: stale non-interactive advises but never blocks" {
  _seed_stale_provenance sbx stalebox
  run maybe_offer_bundle_refresh sbx stalebox
  assert_success
  assert_output --partial 'acq kit update stalebox'
  assert_output --partial 'ACQ_UPDATE_CHECK=0'
}

@test "run-check: a pre-heal 'stale' status arg still advises" {
  acq_provenance_write sbx orderbox
  run maybe_offer_bundle_refresh sbx orderbox stale
  assert_success
  assert_output --partial 'acq kit update orderbox'
}

@test "run-check: ACQ_UPDATE_CHECK=0 silences the advisory even when stale" {
  _seed_stale_provenance sbx optout
  export ACQ_UPDATE_CHECK=0
  run maybe_offer_bundle_refresh sbx optout
  unset ACQ_UPDATE_CHECK
  assert_output ''
}

@test "heal(sbx): a failed built-in kit apply does not write provenance" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  kit) [ "${2:-}" = "add" ] && exit 1 || exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'failbox\n' > "$STUBDIR/.sandbox_list"
  acq_backend_ensure_kits_applied failbox >/dev/null 2>&1 || true
  assert_equal "$(acq_provenance_status sbx failbox)" "unknown"
}

@test "provision(sbx): records provenance on success" {
  : > "$CALLS"
  acq_backend_provision provbox shell /tmp >/dev/null 2>&1 || true
  assert_equal "$(acq_provenance_status sbx provbox)" "current"
}

@test "heal(sbx): ensure_kits_applied records provenance" {
  printf 'healbox\n' > "$STUBDIR/.sandbox_list"
  acq_backend_ensure_kits_applied healbox >/dev/null 2>&1 || true
  assert_equal "$(acq_provenance_status sbx healbox)" "current"
}

@test "provision(sbx): SSH_AUTH_SOCK set prints a one-time trust-boundary notice" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/note-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    printf "sk\n" | acq_secret_store "$(_acq_secret_key usai)"
    export SSH_AUTH_SOCK="'"$STUBDIR"'/does-not-matter.sock"
    acq_backend_provision notebox shell /tmp 2>&1 >/dev/null
  '
  assert_output --partial 'forwards your host ssh-agent'
  assert_output --partial 'unset SSH_AUTH_SOCK to opt out'
  assert_output --partial 'ssh-add -c'
}

@test "provision(sbx): no notice when SSH_AUTH_SOCK is unset" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/quiet-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    printf "sk\n" | acq_secret_store "$(_acq_secret_key usai)"
    unset SSH_AUTH_SOCK
    acq_backend_provision quietbox shell /tmp 2>&1 >/dev/null
  '
  refute_output --partial 'forwards your host ssh-agent'
}
