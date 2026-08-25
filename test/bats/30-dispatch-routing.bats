#!/usr/bin/env bats
#
# 30-dispatch-routing.bats — bats port of scripts/test-acq.d/30-dispatch-routing.sh
# (ADR-0025)
#
# Each subcommand must call the right adapter function, and the create/run key
# gates (ensure_key_present pre-create, ensure_valid_key post-create) must fail
# closed as specified. All CLI-driven via `run`, inspecting $CALLS for dispatch
# shape and $STUBDIR markers for provisioning side effects.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Store a global usai key + seed the sbx proxy fixture (the common precondition
# for create/run flows). Uses the harness's seed_sbx_usai_proxy_fixture.
_seed_usai() {
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
}

@test "dispatch: ls -> sbx ls" {
  run env ACQ_BACKEND=sbx "$ACQ" ls
  assert_regex "$(cat "$CALLS")" 'sbx ls'
}

@test "dispatch: version reports backend and script path" {
  run env ACQ_BACKEND=sbx "$ACQ" version
  assert_output --partial 'backend:'
  assert_output --partial "$REPO_ROOT/acq"
}

@test "dispatch: create -> sbx create with --name, --kit, usai kit, workspace positional" {
  local proj="$STUBDIR/proj"; mkdir -p "$proj"
  _seed_usai
  run env ACQ_BACKEND=sbx "$ACQ" create opencode "$proj"
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sbx create --name'
  assert_regex "$log" -- '--kit'
  assert_regex "$log" 'acq-kits/usai-provider'
  local create_line; create_line=$(printf '%s\n' "$log" | grep '^sbx create')
  assert_regex "$create_line" "$proj"
}

@test "dispatch: create runs the github-scope advisory" {
  local ghproj="$STUBDIR/ghproj"; mkdir -p "$ghproj"
  ( cd "$ghproj" && git init -q && git remote add origin https://github.com/GSA-TTS/quickstart.git )
  _seed_usai
  run env ACQ_BACKEND=sbx ACQ_SECRET_FORCE_FILE=1 ACQ_SECRET_FILE_DIR="$ghproj/.secrets" \
    "$ACQ" create opencode "$ghproj"
  assert_output --partial 'no repo-scoped GitHub token'
}

@test "dispatch: create runs a non-blocking USAi key advisory (warns but never aborts)" {
  local proj="$STUBDIR/keyproj"; mkdir -p "$proj"
  _seed_usai
  run env STUB_KEY_STATUS=401 ACQ_BACKEND=sbx "$ACQ" create opencode "$proj"
  assert_success
  assert_output --partial 'invalid or expired (HTTP 401)'
  run env STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" create opencode "$proj"
  refute_output --partial 'invalid or expired'
}

@test "run: no key stored (non-tty) emits the terse gate and aborts before create" {
  local proj="$STUBDIR/keyrun"; mkdir -p "$proj"
  rm -f "$STUBDIR/.created"
  run bash -c 'printf "\n" | STUB_KEY_STATUS=401 ACQ_BACKEND=sbx "$1" run opencode "$2"' _ "$ACQ" "$proj"
  assert_failure
  assert_output --partial 'no USAi API key stored'
  refute_output --partial 'Set it now'
  refute_output --partial 'invalid or expired'
  assert [ ! -f "$STUBDIR/.created" ]
}

@test "create: empty store (non-tty) aborts before sbx create" {
  local proj="$STUBDIR/kc"; mkdir -p "$proj"
  rm -f "$STUBDIR/.created"
  run bash -c 'printf "\n" | ACQ_BACKEND=sbx "$1" create opencode "$2"' _ "$ACQ" "$proj"
  assert_failure
  assert_output --partial 'no USAi API key stored'
  refute_regex "$(cat "$CALLS")" 'sbx create'
  assert [ ! -f "$STUBDIR/.created" ]
}

@test "create(sbx): acq-store-only key (proxy unbound) fails closed before sbx create" {
  local proj="$STUBDIR/kc-unbound"; mkdir -p "$proj"
  mkdir -p "$STUBDIR/secrets"; printf 'sk-stored-only\n' > "$STUBDIR/secrets/acq.usai"
  rm -f "$STUBDIR/.created"
  run bash -c 'printf "" | ACQ_BACKEND=sbx "$1" create opencode "$2"' _ "$ACQ" "$proj"
  assert_failure
  assert_output --partial 'backend is not configured to inject it'
  assert_output --partial 'acq secret set -g usai'
  refute_regex "$(cat "$CALLS")" 'sbx create'
  assert [ ! -f "$STUBDIR/.created" ]
}

@test "create(sbx): acq-store key WITH proxy binding proceeds to sbx create" {
  local proj="$STUBDIR/kc-bound"; mkdir -p "$proj"
  mkdir -p "$STUBDIR/secrets"; printf 'sk-stored-and-bound\n' > "$STUBDIR/secrets/acq.usai"
  seed_sbx_usai_proxy_fixture
  rm -f "$STUBDIR/.created"
  run env STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" create opencode "$proj"
  assert_success
  refute_output --partial 'backend is not configured'
  assert_regex "$(cat "$CALLS")" 'sbx create'
  assert [ -f "$STUBDIR/.created" ]
}

@test "create(msb): host-exported USAI_API_KEY counts as present; provision proceeds" {
  local proj="$STUBDIR/kc-ci"; mkdir -p "$proj"
  rm -f "$STUBDIR/.msb_created"
  run bash -c 'printf "" | USAI_API_KEY="sk-ci-host" ACQ_BACKEND=msb "$1" create opencode "$2"' _ "$ACQ" "$proj"
  refute_output --partial 'no USAi API key stored'
  assert_regex "$(cat "$CALLS")" 'msb create'
  assert [ -f "$STUBDIR/.msb_created" ]
}

@test "run: present key + bad status -> post-create gate offers rotate; decline aborts" {
  local proj="$STUBDIR/keyrun2"; mkdir -p "$proj"
  _seed_usai
  run bash -c 'printf "\n" | STUB_KEY_STATUS=401 ACQ_BACKEND=sbx "$1" run opencode "$2"' _ "$ACQ" "$proj"
  assert_failure
  assert_output --partial 'invalid or expired'
  assert_output --partial 'Rotate now'
  refute_output --partial 'No USAi API key is stored'
}

@test "run: healthy status attaches with no gate message" {
  local proj="$STUBDIR/keyrun3"; mkdir -p "$proj"
  _seed_usai
  run env STUB_OPENCODE_OK=1 STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" run opencode "$proj"
  assert_success
  refute_output --partial 'Aborting attach'
}

@test "run(opencode): runs postinstall under a timeout guard when binary not functional" {
  local proj="$STUBDIR/ocrun"; mkdir -p "$proj"
  _seed_usai
  run env STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" run opencode "$proj"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'postinstall\.mjs'
  assert_regex "$log" 'timeout'
  refute_output --partial 'does not appear runnable'
}

@test "run(opencode): skips postinstall when already runnable" {
  local proj="$STUBDIR/ocok"; mkdir -p "$proj"
  _seed_usai
  run env STUB_OPENCODE_OK=1 STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" run opencode "$proj"
  refute_regex "$(cat "$CALLS")" 'postinstall\.mjs'
}

@test "run: unreachable USAi API is a network problem, not a key problem; fail closed" {
  local proj="$STUBDIR/unreach"; mkdir -p "$proj"
  _seed_usai
  run env STUB_KEY_UNREACHABLE=1 ACQ_BACKEND=sbx "$ACQ" run opencode "$proj"
  assert_failure
  assert_output --partial 'could not reach the USAi API'
  assert_output --partial 'NOT an invalid or expired key'
  refute_output --partial 'Rotate now'
  refute_output --partial 'curl:'
}

@test "run: pinned-public TLS failure (curl 35) is unreachable, no DNS hint; fail closed" {
  local proj="$STUBDIR/pinned35"; mkdir -p "$proj"
  _seed_usai
  run env STUB_KEY_UNREACHABLE=35 ACQ_BACKEND=sbx "$ACQ" run opencode "$proj"
  assert_failure
  assert_output --partial 'could not reach the USAi API'
  assert_output --partial 'NOT an invalid or expired key'
  refute_output --partial 'Rotate now'
  refute_output --partial 'ACQ_MSB_DNS_NAMESERVER'
  refute_output --partial 'did not RESOLVE'
}

@test "classify: _classify_key_status yields clean tokens (code|unresolved|unreachable)" {
  load_acq
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    _classify_key_status "200|0"; echo
    _classify_key_status "401|0"; echo
    _classify_key_status "000|56"; echo
    _classify_key_status "000|7"; echo
    _classify_key_status "000|6"; echo
    _classify_key_status "000|35"; echo
    _classify_key_status "curl: (56) OpenSSL SSL_read: unexpected eof000|56"; echo
  '
  assert_line --index 0 '200'
  assert_line --index 1 '401'
  assert_line --index 2 'unreachable'
  assert_line --index 3 'unreachable'
  assert_line --index 4 'unresolved'
  assert_line --index 5 'unreachable'
  assert_line --index 6 'unreachable'
}

@test "run: NXDOMAIN (curl 6) is a resolver problem with a DNS hint; fail closed" {
  local proj="$STUBDIR/unres"; mkdir -p "$proj"
  _seed_usai
  run env STUB_KEY_UNRESOLVED=1 ACQ_BACKEND=sbx "$ACQ" run opencode "$proj"
  assert_failure
  assert_output --partial 'did not RESOLVE'
  assert_output --partial 'ACQ_MSB_DNS_NAMESERVER'
  refute_output --partial 'Rotate now'
}

@test "dispatch: stop/rm/exec route to the sbx adapter" {
  run env ACQ_BACKEND=sbx "$ACQ" stop mybox
  assert_regex "$(cat "$CALLS")" 'sbx stop mybox'
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" rm mybox
  assert_regex "$(cat "$CALLS")" 'sbx rm --force mybox'
  : > "$CALLS"
  run env ACQ_BACKEND=sbx "$ACQ" exec mybox -- echo hi
  assert_regex "$(cat "$CALLS")" 'sbx exec mybox'
}

@test "dispatch: an unknown subcommand passes through to the backend, announced, not doubled" {
  run env ACQ_BACKEND=sbx "$ACQ" policy init balanced
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sbx policy init balanced'
  refute_regex "$log" 'sbx policy policy'
  assert_output --partial "not an acq subcommand — forwarding to 'sbx'"
  assert_output --partial "from 'sbx', not acq"
}

@test "kit-flag: --kit on create is folded into the kit list, workspace positional clean" {
  local proj="$STUBDIR/kitproj"; mkdir -p "$proj"
  _seed_usai
  run env ACQ_BACKEND=sbx "$ACQ" create opencode --kit /tmp/mykit "$proj"
  local create_line; create_line=$(printf '%s\n' "$(cat "$CALLS")" | grep '^sbx create')
  assert_regex "$create_line" -- '--kit /tmp/mykit'
  assert_regex "$create_line" "$proj"
  refute_regex "$create_line" "$proj --kit /tmp/mykit"
  refute_regex "$create_line" "$proj /tmp/mykit"
}

@test "kit-flag: --kit=<ref> equals form is intercepted" {
  local proj="$STUBDIR/kitproj2"; mkdir -p "$proj"
  _seed_usai
  run env ACQ_BACKEND=sbx "$ACQ" create opencode --kit=/tmp/eqkit "$proj"
  local create_line; create_line=$(printf '%s\n' "$(cat "$CALLS")" | grep '^sbx create')
  assert_regex "$create_line" -- '--kit /tmp/eqkit'
  refute_regex "$create_line" -- '--kit=/tmp/eqkit'
}

@test "kit-flag: multiple --kit flags are all intercepted" {
  local proj="$STUBDIR/kitproj3"; mkdir -p "$proj"
  _seed_usai
  run env ACQ_BACKEND=sbx "$ACQ" create opencode --kit /tmp/k1 --kit /tmp/k2 "$proj"
  local create_line; create_line=$(printf '%s\n' "$(cat "$CALLS")" | grep '^sbx create')
  assert_regex "$create_line" -- '--kit /tmp/k1'
  assert_regex "$create_line" -- '--kit /tmp/k2'
  assert_regex "$create_line" "$proj"
}

@test "kit-flag: run form also intercepts --kit" {
  local proj="$STUBDIR/kitproj4"; mkdir -p "$proj"
  _seed_usai
  run env ACQ_BACKEND=sbx "$ACQ" run opencode --kit /tmp/runkit "$proj"
  local create_line; create_line=$(printf '%s\n' "$(cat "$CALLS")" | grep '^sbx create')
  assert_regex "$create_line" -- '--kit /tmp/runkit'
  refute_regex "$create_line" "$proj --kit /tmp/runkit"
}

@test "kit-flag: a --kit after -- belongs to the agent, not the kit list" {
  local proj="$STUBDIR/kitproj5"; mkdir -p "$proj"
  _seed_usai
  run env ACQ_BACKEND=sbx "$ACQ" run opencode "$proj" -- --kit evil-agent-arg
  local log; log=$(cat "$CALLS")
  local create_line; create_line=$(printf '%s\n' "$log" | grep '^sbx create')
  refute_regex "$create_line" -- '--kit evil-agent-arg'
  assert_regex "$log" -- '--kit evil-agent-arg'
}
