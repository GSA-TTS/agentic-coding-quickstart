#!/usr/bin/env bats
#
# 90-sbx-startup-kit.bats — bats port of scripts/test-acq.d/90-sbx-startup-kit.sh
# (quickstart #320, ADR-0025)
#
# sbx 0.38 startup-kit refusal handling, stale-probe footprint, and the
# create-time extra-kit marker. All offline via the stubbed sbx. Each @test
# plants a purpose-built sbx stub, so the stubs live inline.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Plant an sbx stub whose `kit add` FAILS with the 0.38 startup-refusal error and
# whose feature-probe reports ABSENT so the heal attempts the add.
_plant_refusal_stub() {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit)
    if [ "${2:-}" = "add" ]; then
      printf 'ERROR: kit "agentic-coding-playbook" declares setup.startup, which the kit-add recreate flow does not yet apply; recreate the sandbox from scratch via `sbx rm` + `sbx create --kit` to use this kit\n' >&2
      exit 1
    fi
    exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
}

# Seed a STALE provenance record (see 85-kit-provenance) for the kit update test.
_seed_stale_provenance() {
  local backend="$1" name="$2" f
  acq_provenance_write "$backend" "$name"
  f=$(_acq_provenance_file "$backend" "$name")
  awk '/^applied_ref=/ { print "applied_ref=oldoldoldoldoldoldoldoldoldoldoldoldoldo"; next } { print }' \
    "$f" > "$f.seed" && mv -f "$f.seed" "$f"
}

@test "heal(sbx 0.38): a startup refusal yields consolidated recreate guidance, status unknown" {
  _plant_refusal_stub
  printf 'refusebox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied refusebox
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  assert_output --partial "acq rm 'refusebox' && acq run"
  refute_output --partial 'Recover with: sbx kit add'
  assert_equal "$(acq_provenance_status sbx refusebox)" "unknown"
}

@test "heal(sbx 0.38): the recreate notice prints exactly once" {
  _plant_refusal_stub
  printf 'oncebox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied oncebox
  local n; n=$(printf '%s\n' "$output" | grep -c 'cannot extend a live sandbox with startup-bearing kits')
  assert_equal "$n" "1"
}

@test "heal(sbx 0.38, set -e): a refusal does not abort the heal at the first kit" {
  _plant_refusal_stub
  printf 'sebox\n' > "$STUBDIR/.sandbox_list"
  # Reproduce the live path: a fresh subshell that sources acq (set -e active),
  # resolves the backend, and runs the forced heal with the refusal stub on PATH.
  run bash -c '
    export CALLS="'"$CALLS"'" STUBDIR="'"$STUBDIR"'" ACQ_FORCE_KIT_REAPPLY=1
    PATH="'"$STUBDIR"':$PATH"
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    acq_resolve_backend sbx >/dev/null 2>&1
    acq_backend_ensure_kits_applied sebox 2>&1
  '
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  assert_output --partial 'missing the Zscaler CA kit'
  assert_output --partial 'missing the USAi kit'
  assert_output --partial 'missing the playbook kit'
}

@test "kit update(sbx 0.38): a refusal fails fast with recreate guidance, stays stale" {
  _plant_refusal_stub
  printf 'updbox\n' > "$STUBDIR/.sandbox_list"
  _seed_stale_provenance sbx updbox
  run env ACQ_BACKEND=sbx "$ACQ" kit update updbox --yes
  assert_failure
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  assert_equal "$(acq_provenance_status sbx updbox)" "stale"
}

@test "heal(sbx): a non-refusal kit-add failure surfaces sbx's own stderr" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit) [ "${2:-}" = "add" ] && { printf 'ERROR: some other transient failure\n' >&2; exit 1; }; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'otherbox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied otherbox
  assert_output --partial 'some other transient failure'
  refute_output --partial 'cannot extend a live sandbox'
}

@test "heal(sbx): a reworded 0.38 refusal is still classified as recreate" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit)
    if [ "${2:-}" = "add" ]; then
      printf 'Error: this kit declares startup commands; recreate the sandbox to apply it\n' >&2
      exit 1
    fi
    exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'rewordbox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied rewordbox
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  refute_output --partial 'declares startup commands; recreate the sandbox to apply it'
}

@test "heal(sbx): the playbook stale-probe uses the AGENTS.md footprint, not .git" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'present\n' ;; *) exit 0 ;; esac ;;
  kit) exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'probebox\n' > "$STUBDIR/.sandbox_list"
  acq_backend_ensure_kits_applied probebox >/dev/null 2>&1 || true
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '\.agentic-coding-playbook/AGENTS\.md'
  refute_regex "$log" '\.agentic-coding-playbook/\.git'
  refute_regex "$log" 'sbx kit add probebox'
}

@test "provision(sbx): ACQ_EXTRA_KITS is marked into ~/.acq-extra-kits at create" {
  : > "$CALLS"
  # Subshell, NOT `bash -c`: acq_backend_provision is a sourced function, which
  # a fresh bash never sees (the pre-#381 suite masked the resulting 127).
  (
    export ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit"
    acq_backend_provision markerbox shell /tmp
  ) >/dev/null 2>&1 || true
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '\.acq-extra-kits'
  assert_regex "$log" 'some-extra-kit'
}

@test "provision(sbx): a CLI --kit ref (ACQ_CLI_KITS) is also marked at create" {
  : > "$CALLS"
  # Subshell, NOT `bash -c` (see the ACQ_EXTRA_KITS marker test above).
  (
    ACQ_CLI_KITS=("git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=cli-kit-x")
    acq_backend_provision climarkerbox shell /tmp
  ) >/dev/null 2>&1 || true
  assert_regex "$(cat "$CALLS")" 'cli-kit-x'
}

@test "provision(sbx): a FAILED create writes no extra-kit marker" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  create) printf 'ERROR: create failed\n' >&2; exit 1 ;;
  exec) printf 'ok\n' ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  : > "$CALLS"
  run bash -c '
    export ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=fail-extra-kit"
    acq_backend_provision failbox shell /tmp >/dev/null 2>&1 || true
  '
  refute_regex "$(cat "$CALLS")" '\.acq-extra-kits'
}

@test "heal(sbx): a marked extra kit is not re-applied (no refusal noise)" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      *acq-extra-kits*) printf '%s\n' "git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit" ;;
      *present*) printf 'present\n' ;;
      *) exit 0 ;;
    esac ;;
  kit) [ "${2:-}" = "add" ] && { printf 'ERROR: declares setup.startup\n' >&2; exit 1; }; exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'skipbox\n' > "$STUBDIR/.sandbox_list"
  run bash -c '
    ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit" \
      acq_backend_ensure_kits_applied skipbox 2>&1 || true
  '
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'sbx kit add skipbox'
  refute_output --partial 'cannot extend a live sandbox'
}
