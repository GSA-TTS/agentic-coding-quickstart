#!/usr/bin/env bats
#
# 40-secret-set.bats — bats port of scripts/test-acq.d/40-secret-set.sh (ADR-0025)
#
# `acq secret set` writes the acq secret store AND feeds the active backend's
# proxy per the real CLI contract (built-in services via `sbx secret set` stdin;
# custom endpoints like usai print the set-custom command, value never on argv).
# Also: scope-aware existence checks, `acq secret has`, and masked entry.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "secret set: no scope errors, calls no backend, stores nothing" {
  run env ACQ_BACKEND=sbx "$ACQ" secret set usai
  assert_output --partial 'scope required'
  refute_regex "$(cat "$CALLS")" 'sbx secret set'
}

@test "secret set: -g github feeds sbx (no deprecated -g flag) and stores it" {
  run bash -c 'printf "ghp_x\n" | ACQ_BACKEND=sbx "$1" secret set -g github' _ "$ACQ"
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sbx secret set github'
  refute_regex "$log" 'sbx secret set -g github'
  assert [ -f "$STUBDIR/secrets/acq.github" ]
}

@test "secret set: sandbox github feeds --sandbox scope and stores scoped" {
  run bash -c 'printf "ghp_x\n" | ACQ_BACKEND=sbx "$1" secret set my-sandbox github' _ "$ACQ"
  assert_regex "$(cat "$CALLS")" 'sbx secret set --sandbox my-sandbox github'
  assert [ -f "$STUBDIR/secrets/acq.my-sandbox.github" ]
}

@test "secret set: -g github already in the global scope stops with an rm hint" {
  printf 'SCOPE      TYPE      NAME     SECRET\n(global)   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'sbx secret rm github'
  refute_regex "$(cat "$CALLS")" 'sbx secret set github'
}

@test "secret set: github under a DIFFERENT scope does not block -g (global feeds)" {
  printf 'SCOPE      TYPE      NAME     SECRET\notherbox   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_regex "$(cat "$CALLS")" 'sbx secret set github'
  refute_output --partial 'sbx secret rm github'
}

@test "secret set: sandbox github not blocked by another sandbox's github" {
  printf 'SCOPE      TYPE      NAME     SECRET\notherbox   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set mybox github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_regex "$(cat "$CALLS")" 'sbx secret set --sandbox mybox github'
}

@test "secret set: the SAME sandbox already having github is a real collision" {
  printf 'SCOPE                     TYPE      NAME     SECRET\nopencode-agentic-coding   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set opencode-agentic-coding github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'sbx secret rm github --sandbox opencode-agentic-coding'
  refute_regex "$(cat "$CALLS")" 'sbx secret set --sandbox opencode-agentic-coding github'
}

@test "secret set: section-aware existence — built-in vs custom tables don't cross" {
  cat > "$STUBDIR/sbx_ls" <<'LS'
SCOPE      TYPE      NAME     SECRET
(global)   service   github   (stored)

CUSTOM SECRETS
SCOPE      TARGETS            ENV            PLACEHOLDER               SECRET
(global)   api.gsa.usai.gov   USAI_API_KEY   sbx-cs-0lrfssn3YnvE8P2j   api-ke***tJ63
LS
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'sbx secret rm github'
  run bash -c 'printf "x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g usai' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'already has'
}

@test "secret set: -g usai (custom, piped) stores + prints the command, value never on argv" {
  run bash -c 'printf "SUPERSECRETVALUE123\n" | ACQ_BACKEND=sbx "$1" secret set -g usai' _ "$ACQ"
  assert_output --partial "stored 'usai' in the acq secret store"
  assert_output --partial 'sbx secret set-custom --host api.gsa.usai.gov --env USAI_API_KEY'
  refute_output --partial 'SUPERSECRETVALUE123'
  refute_regex "$(cat "$CALLS")" 'SUPERSECRETVALUE123'
  assert [ -f "$STUBDIR/secrets/acq.usai" ]
}

@test "mask: masked entry captures the value, shows a star per char, handles backspace/empty" {
  load_acq
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    v=$(printf "sk-SECRET\n" | _acq_read_secret_masked 2>"'"$STUBDIR"'/stars")
    printf "V=%s\n" "$v"
    printf "STARS=%s\n" "$(cat "'"$STUBDIR"'/stars")"
    printf "BS=%s\n" "$(printf "ab\177c\n" | _acq_read_secret_masked 2>/dev/null)"
    printf "EMPTY=[%s]\n" "$(printf "\n" | _acq_read_secret_masked 2>/dev/null)"
  '
  assert_line 'V=sk-SECRET'
  assert_line --partial 'STARS=*'
  refute_output --partial 'STARS=sk-SECRET'
  assert_line 'BS=ac'
  assert_line 'EMPTY=[]'
}

@test "secret set: sandbox usai (piped) stores scoped + prints sandbox-scoped command" {
  run bash -c 'printf "k\n" | ACQ_BACKEND=sbx "$1" secret set my-sandbox usai' _ "$ACQ"
  assert_output --partial 'sbx secret set-custom --sandbox my-sandbox --host api.gsa.usai.gov'
  assert [ -f "$STUBDIR/secrets/acq.my-sandbox.usai" ]
}

@test "secret set(msb): usai stored, no sbx set-custom printed, exits 0 on success" {
  run bash -c 'printf "k\n" | ACQ_BACKEND=msb "$1" secret set -g usai' _ "$ACQ"
  assert_output --partial 'acq secret store'
  refute_output --partial 'sbx secret set-custom'
  # set -e regression: a successful set must exit 0 even when no running sandbox
  # was re-fed.
  run bash -c 'printf "k\n" | ACQ_BACKEND=msb "$1" secret set -g usai >/dev/null 2>&1' _ "$ACQ"
  assert_success
}

@test "secret has(msb): store-present -> rc 0; absent -> rc 1; silent both ways" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  run env ACQ_BACKEND=msb "$ACQ" secret has -g usai
  assert_success
  assert_output ''
  run env ACQ_BACKEND=msb "$ACQ" secret has -g nope
  assert_failure
  assert_output ''
}

@test "secret has(sbx): store-present but proxy-absent -> rc 1; proxy-bound -> rc 0" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  run env ACQ_BACKEND=sbx "$ACQ" secret has -g usai
  assert_failure
  seed_sbx_usai_proxy_fixture
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_BACKEND=sbx "$ACQ" secret has -g usai
  assert_success
}

@test "secret has: a missing service name is a usage error (rc 2)" {
  load_acq
  run env ACQ_BACKEND=msb "$ACQ" secret has -g
  assert_equal "$status" "2"
  assert_output --partial 'missing service name'
}
