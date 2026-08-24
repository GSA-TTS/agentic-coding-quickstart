#!/usr/bin/env bash
#
# 75-usai-rotate — acq usai-rotate-api-key dispatch (ADR-0012)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 8r. acq usai-rotate-api-key — backend-neutral dispatch (ADR-0012)
# ===========================================================================
# The rotate path must go through the resolved backend's acq_backend_rotate_key,
# NOT a hardcoded sbx script. On the sbx backend it preserves the placeholder
# via `sbx secret set-custom`; on the msb backend it must issue NO sbx command.

# 8r1. sbx backend: rotate dispatches to sbx secret set-custom (placeholder
#      preserved), and validates in a throwaway sandbox.
make_stubs
printf 'placeholder-token USAI_API_KEY {}\n' > "$STUBDIR/sbx_ls"
export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
ACQ_BACKEND=sbx "$ACQ" usai-rotate-api-key </dev/null >/dev/null 2>&1 || true
unset SBX_LS_FIXTURE
log=$(cat "$CALLS")
assert_contains "rotate(sbx): uses sbx secret set-custom" "$log" "sbx secret set-custom --host api.gsa.usai.gov --env USAI_API_KEY"
assert_contains "rotate(sbx): validates in a throwaway sandbox" "$log" "sbx create --name acq-keycheck-"
cleanup_stubs

# 8r2. msb backend: rotate issues NO sbx command (the reported bug), stores the
#      key in the acq store, and re-feeds running sandboxes via msb modify.
make_stubs
# Seed one running sandbox so the re-feed loop (`msb list -q` -> `msb modify`) runs.
printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
ACQ_SECRET_TEST_VALUE="new-usai-key" ACQ_BACKEND=msb "$ACQ" usai-rotate-api-key </dev/null >/dev/null 2>&1 || true
log=$(cat "$CALLS")
assert_not_contains "rotate(msb): issues NO sbx command" "$log" "sbx "
assert_contains "rotate(msb): re-feeds via msb modify --secret" "$log" "msb modify"
if [ -f "$STUBDIR/secrets/acq.usai" ]; then
  pass "rotate(msb): stored new key in acq store"
else
  fail "rotate(msb): stored new key in acq store" "acq.usai not found"
fi
cleanup_stubs

# 8r3. Both adapters define the acq_backend_rotate_key contract function.
make_stubs; load_acq
if command -v acq_backend_rotate_key >/dev/null 2>&1; then
  pass "rotate: sbx adapter defines acq_backend_rotate_key"
else
  fail "rotate: sbx adapter defines acq_backend_rotate_key" "function missing"
fi
cleanup_stubs
make_stubs; load_acq
( . "${REPO_ROOT}/acq.backends/msb.sh"
  command -v acq_backend_rotate_key >/dev/null 2>&1
) && pass "rotate: msb adapter defines acq_backend_rotate_key" \
  || fail "rotate: msb adapter defines acq_backend_rotate_key" "function missing"
cleanup_stubs

# 8r4. scripts/rotate-apikey is a thin shim with NO direct sbx call.
if grep -qE '(^|[^[:alnum:]_])sbx[[:space:]]+secret' "$REPO_ROOT/scripts/rotate-apikey"; then
  fail "rotate: scripts/rotate-apikey has no direct sbx call" "found 'sbx secret' in the shim"
else
  pass "rotate: scripts/rotate-apikey has no direct sbx call"
fi
