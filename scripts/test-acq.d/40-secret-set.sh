#!/usr/bin/env bash
#
# 40-secret-set — acq-owned store + backend feed, scope required
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 5. acq secret set — acq-owned store + backend feed, scope required
# ===========================================================================
# Credentials live in the acq secret store (secret-store.sh); `acq secret set`
# writes there AND feeds the active backend's proxy per the real sbx CLI
# contract:
#   - built-in services (github, ...) : value piped to `sbx secret set` (stdin);
#     acq pre-checks `sbx secret ls` and stops with an rm hint if it exists.
#   - custom endpoints (usai)         : `sbx secret set-custom` has no stdin, so
#     non-interactively acq stores in the acq store and prints the exact sbx
#     command (value never forced onto argv); interactively sbx prompts.
# make_stubs points ACQ_SECRET_STORE_DIR at a throwaway file store, and the sbx
# stub's `secret ls` returns empty (absent) so the feed path runs.

# 5a. No scope → error, no sbx call, nothing stored.
make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" secret set usai 2>&1 || true)
assert_contains "secret: no scope -> error" "$out" "scope required"
log=$(cat "$CALLS")
assert_not_contains "secret: no scope -> sbx not called" "$log" "sbx secret set"
cleanup_stubs

# 5b. `-g github` (built-in, absent) -> `sbx secret set github` via stdin + stored.
#     sbx global scope is now the DEFAULT (no `-g`); the flag was deprecated.
make_stubs
(printf 'ghp_x\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g github) >/dev/null 2>/dev/null || true
log=$(cat "$CALLS")
assert_contains "secret: -g github -> sbx secret set github" "$log" "sbx secret set github"
assert_not_contains "secret: -g github -> no deprecated -g flag" "$log" "sbx secret set -g github"
if [ -f "$STUBDIR/secrets/acq.github" ]; then
  pass "secret: -g github stored in acq store"
else
  fail "secret: -g github stored in acq store" "acq.github not found in store"
fi
cleanup_stubs

# 5c. `my-sandbox github` -> built-in feed scoped to sandbox + stored scoped.
#     sbx sandbox scope is `--sandbox NAME` now.
make_stubs
(printf 'ghp_x\n' | ACQ_BACKEND=sbx "$ACQ" secret set my-sandbox github) >/dev/null 2>/dev/null || true
log=$(cat "$CALLS")
assert_contains "secret: sandbox github -> sbx secret set --sandbox my-sandbox" "$log" "sbx secret set --sandbox my-sandbox github"
if [ -f "$STUBDIR/secrets/acq.my-sandbox.github" ]; then
  pass "secret: sandbox github stored scoped in acq store"
else
  fail "secret: sandbox github stored scoped in acq store" "acq.my-sandbox.github not found"
fi
cleanup_stubs

# 5d. `-g github` when it ALREADY exists (in the GLOBAL scope) -> stop with rm
#     hint, no set call. The fixture mirrors `sbx secret ls` layout (leading
#     SCOPE column) so the scope-aware existence check matches the global row.
make_stubs
printf 'SCOPE      TYPE      NAME     SECRET\n(global)   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
out=$(printf 'ghp_x\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g github 2>&1 || true)
unset SBX_LS_FIXTURE
log=$(cat "$CALLS")
assert_contains "secret: existing github -> rm hint" "$out" "sbx secret rm github"
assert_not_contains "secret: existing github -> no set call" "$log" "sbx secret set github"
cleanup_stubs

# 5d1. Scope-awareness regression: github existing under a DIFFERENT
#      scope must NOT block seeding the target scope. Previously a blind substring
#      match over the whole `sbx secret ls` produced a false "already exists"
#      whenever any other sandbox had github (the verify-backends sbx seed skip).
#      The fixture has github under `otherbox` only; setting `-g github` (global
#      scope) must PROCEED to the feed call.
make_stubs
printf 'SCOPE      TYPE      NAME     SECRET\notherbox   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
out=$(printf 'ghp_x\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g github 2>&1 || true)
unset SBX_LS_FIXTURE
log=$(cat "$CALLS")
assert_contains "secret: github under other scope does NOT block -g (feeds sbx)" "$log" "sbx secret set github"
assert_not_contains "secret: github under other scope -> no false rm hint" "$out" "sbx secret rm github"
cleanup_stubs

# 5d2. Same, sandbox-scoped: setting `mybox github` when github exists only under
#      `otherbox` must proceed (this is exactly the verify-backends seed case,
#      and a token scoped to sandbox A must not block sandbox B).
make_stubs
printf 'SCOPE      TYPE      NAME     SECRET\notherbox   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
out=$(printf 'ghp_x\n' | ACQ_BACKEND=sbx "$ACQ" secret set mybox github 2>&1 || true)
unset SBX_LS_FIXTURE
log=$(cat "$CALLS")
assert_contains "secret: sandbox github not blocked by other scope (feeds sbx)" "$log" "sbx secret set --sandbox mybox github"
cleanup_stubs

# 5d2b. Positive case: the SAME sandbox already having github IS a
#       real collision -> stop with a sandbox-scoped rm hint, no set call.
make_stubs
printf 'SCOPE                     TYPE      NAME     SECRET\nopencode-agentic-coding   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
out=$(printf 'ghp_x\n' | ACQ_BACKEND=sbx "$ACQ" secret set opencode-agentic-coding github 2>&1 || true)
unset SBX_LS_FIXTURE
log=$(cat "$CALLS")
assert_contains "secret: same-sandbox github -> scoped rm hint" "$out" "sbx secret rm github --sandbox opencode-agentic-coding"
assert_not_contains "secret: same-sandbox github -> no set call" "$log" "sbx secret set --sandbox opencode-agentic-coding github"
cleanup_stubs

# 5d3. Section-awareness: a BUILT-IN service (github) must be matched in the
#      built-in table only, and a CUSTOM service (usai) in the CUSTOM SECRETS
#      table only — never cross-section. Fixture has BOTH tables populated.
make_stubs
cat > "$STUBDIR/sbx_ls" <<'LS'
SCOPE      TYPE      NAME     SECRET
(global)   service   github   (stored)

CUSTOM SECRETS
SCOPE      TARGETS            ENV            PLACEHOLDER               SECRET
(global)   api.gsa.usai.gov   USAI_API_KEY   sbx-cs-0lrfssn3YnvE8P2j   api-ke***tJ63
LS
export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
# github IS present in the built-in table at (global) -> should block with rm hint.
gh_out=$(printf 'ghp_x\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g github 2>&1 || true)
# usai IS present in the CUSTOM table at (global) -> should block with rm hint.
usai_out=$(printf 'x\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai 2>&1 || true)
unset SBX_LS_FIXTURE
assert_contains "secret: github found in built-in section (blocks)" "$gh_out" "sbx secret rm github"
assert_contains "secret: usai found in custom section (blocks)" "$usai_out" "already has"
cleanup_stubs

# 5e. `-g usai` (custom, non-interactive/piped) -> stored + prints sbx command,
#     value NEVER on argv, and set-custom is NOT invoked (no stdin support).
make_stubs
out=$(printf 'SUPERSECRETVALUE123\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai 2>&1 || true)
log=$(cat "$CALLS")
assert_contains "secret: -g usai stored msg" "$out" "stored 'usai' in the acq secret store"
assert_contains "secret: -g usai prints set-custom cmd" "$out" "sbx secret set-custom --host api.gsa.usai.gov --env USAI_API_KEY"
assert_not_contains "secret: -g usai value never in argv (stdout)" "$out" "SUPERSECRETVALUE123"
assert_not_contains "secret: -g usai value never in sbx argv" "$log" "SUPERSECRETVALUE123"
if [ -f "$STUBDIR/secrets/acq.usai" ]; then
  pass "secret: -g usai stored in acq store"
else
  fail "secret: -g usai stored in acq store" "acq.usai not found"
fi
cleanup_stubs

# 5e2. masked secret entry (_acq_read_secret_masked): echoes one '*' per char to
#       stderr for visual feedback, captures the real value on stdout, and never
#       echoes the actual characters. Driven over a pipe (read -rsn1 works on a
#       non-tty too), so it is deterministic offline. Also checks that backspace
#       erases a char and an empty line yields an empty value.
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  set +e
  v=$(printf 'sk-SECRET\n' | _acq_read_secret_masked 2>"$STUBDIR/stars")
  stars=$(cat "$STUBDIR/stars")
  assert_eq "mask: captures the entered value" "sk-SECRET" "$v"
  assert_contains "mask: shows a star per char (feedback)" "$stars" "*"
  assert_not_contains "mask: never echoes the plaintext" "$stars" "sk-SECRET"
  vb=$(printf 'ab\177c\n' | _acq_read_secret_masked 2>/dev/null)
  assert_eq "mask: backspace erases last char" "ac" "$vb"
  ve=$(printf '\n' | _acq_read_secret_masked 2>/dev/null)
  assert_eq "mask: empty entry yields empty value" "" "$ve"
) 2>/dev/null; pass "mask: masked secret entry (feedback + capture + backspace)"
cleanup_stubs

# 5f. `my-sandbox usai` (custom, piped) -> stored scoped + prints sandbox-scoped cmd.
make_stubs
out=$(printf 'k\n' | ACQ_BACKEND=sbx "$ACQ" secret set my-sandbox usai 2>&1 || true)
assert_contains "secret: sandbox usai prints set-custom --sandbox my-sandbox" "$out" "sbx secret set-custom --sandbox my-sandbox --host api.gsa.usai.gov"
if [ -f "$STUBDIR/secrets/acq.my-sandbox.usai" ]; then
  pass "secret: sandbox usai stored scoped in acq store"
else
  fail "secret: sandbox usai stored scoped in acq store" "acq.my-sandbox.usai not found"
fi
cleanup_stubs

# 5g. Custom usai on the MSB backend (piped) -> stored, msb binds at provision,
#     NO sbx set-custom command printed (msb reads the acq store directly).
make_stubs
out=$(printf 'k\n' | ACQ_BACKEND=msb "$ACQ" secret set -g usai 2>&1 || true)
assert_contains "secret(msb): usai stored" "$out" "acq secret store"
assert_not_contains "secret(msb): usai does not print sbx set-custom" "$out" "sbx secret set-custom"
# REGRESSION: `acq secret set` must EXIT 0 on success. The msb guidance helper
# ended its usai/github arm with a bare `[ "$applied" -gt 0 ] && echo …`; when
# no running sandbox was re-fed (applied=0) that test is false, so under the
# dispatcher's `set -e` the whole `acq secret set` exited 1 even though the key
# was stored — which made every scripted seed (incl. verify-backends) treat a
# successful set as a failure. Assert a zero exit explicitly.
make_stubs
printf 'k\n' | ACQ_BACKEND=msb "$ACQ" secret set -g usai >/dev/null 2>&1; set_rc=$?
assert_eq "secret(msb): 'secret set' exits 0 on success (set -e regression)" "0" "$set_rc"
cleanup_stubs

# 5g2. `acq secret has [-g|SANDBOX] SERVICE` — silent predicate mirroring the
#      create-time key-present gate (acq_secret_has AND, when the backend defines
#      it, acq_backend_key_present, via the shared common.sh acq_key_injectable).
#      Tested through the REAL dispatch with the stubbed backends.
#
#   - present in the acq store + backend can inject -> rc 0
#   - absent from the store                          -> rc 1
#   - store-present but the BACKEND injector is missing (sbx: acq store has usai
#     but the sbx proxy CUSTOM SECRETS table has no binding) -> rc 1
#      (this is the case only a backend that DEFINES acq_backend_key_present can
#      distinguish; msb has no such hook so store-present == injectable.)

# 5g2a. msb: store-present usai (msb has no acq_backend_key_present, so the store
#       alone is authoritative) -> rc 0.
make_stubs; load_acq
mkdir -p "$STUBDIR/secrets"
printf 'k\n' > "$STUBDIR/secrets/acq.usai"
ACQ_BACKEND=msb "$ACQ" secret has -g usai >/dev/null 2>&1; has_rc=$?
assert_eq "secret has(msb): store-present usai -> rc 0" "0" "$has_rc"
# Absent service -> rc 1.
ACQ_BACKEND=msb "$ACQ" secret has -g nope >/dev/null 2>&1; has_rc=$?
assert_eq "secret has(msb): absent service -> rc 1" "1" "$has_rc"
# Silent by default: no output on either exit.
has_out=$(ACQ_BACKEND=msb "$ACQ" secret has -g usai 2>&1 || true)
assert_eq "secret has(msb): silent on success" "" "$has_out"
has_out=$(ACQ_BACKEND=msb "$ACQ" secret has -g nope 2>&1 || true)
assert_eq "secret has(msb): silent on failure" "" "$has_out"
cleanup_stubs

# 5g2b. sbx: acq store HAS usai but the sbx proxy CUSTOM SECRETS table does NOT
#       bind it (no fixture) -> acq_backend_key_present fails -> rc 1. This is the
#       store-present-but-backend-absent split the predicate must catch.
make_stubs; load_acq
mkdir -p "$STUBDIR/secrets"
printf 'k\n' > "$STUBDIR/secrets/acq.usai"
# No seed_sbx_usai_proxy_fixture -> `sbx secret ls` shows an empty custom table.
ACQ_BACKEND=sbx "$ACQ" secret has -g usai >/dev/null 2>&1; has_rc=$?
assert_eq "secret has(sbx): store-present but proxy-absent -> rc 1" "1" "$has_rc"
cleanup_stubs

# 5g2c. sbx: acq store HAS usai AND the sbx proxy binds it (fixture present) ->
#       both checks pass -> rc 0.
make_stubs; load_acq
mkdir -p "$STUBDIR/secrets"
printf 'k\n' > "$STUBDIR/secrets/acq.usai"
seed_sbx_usai_proxy_fixture
ACQ_BACKEND=sbx "$ACQ" secret has -g usai >/dev/null 2>&1; has_rc=$?
unset SBX_LS_FIXTURE
assert_eq "secret has(sbx): store-present + proxy-bound -> rc 0" "0" "$has_rc"
cleanup_stubs

# 5g2d. Missing service name -> usage error on stderr, non-zero (rc 2).
make_stubs; load_acq
has_out=$(ACQ_BACKEND=msb "$ACQ" secret has -g 2>&1); has_rc=$?
assert_contains "secret has: missing service -> usage" "$has_out" "missing service name"
assert_eq "secret has: missing service -> rc 2" "2" "$has_rc"
cleanup_stubs

