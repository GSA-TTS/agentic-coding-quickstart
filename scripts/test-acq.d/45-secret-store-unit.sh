#!/usr/bin/env bash
#
# 45-secret-store-unit — secret-store.sh direct unit tests
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 5h. acq secret store unit tests (secret-store.sh directly)
# ===========================================================================
make_stubs
store_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/unit-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'GLOBALV\n' | acq_secret_store "$(_acq_secret_key usai)"
  printf 'SBXV\n'    | acq_secret_store "$(_acq_secret_key usai mybox)"
  printf 'resolve-global=%s\n' "$(acq_secret_resolve usai)"
  printf 'resolve-scoped=%s\n' "$(acq_secret_resolve usai mybox)"
  printf 'resolve-fallback=%s\n' "$(acq_secret_resolve usai otherbox)"
  acq_secret_has usai && printf 'has-usai=yes\n' || printf 'has-usai=no\n'
  acq_secret_has nope && printf 'has-nope=yes\n' || printf 'has-nope=no\n'
)
assert_contains "store: global resolve" "$store_out" "resolve-global=GLOBALV"
assert_contains "store: sandbox scope precedence" "$store_out" "resolve-scoped=SBXV"
assert_contains "store: sandbox falls back to global" "$store_out" "resolve-fallback=GLOBALV"
assert_contains "store: has present service" "$store_out" "has-usai=yes"
assert_contains "store: has absent service" "$store_out" "has-nope=no"
# File-backend entries must be 0600.
perms=$(stat -c '%a' "$STUBDIR/unit-secrets/acq.usai" 2>/dev/null || stat -f '%Lp' "$STUBDIR/unit-secrets/acq.usai" 2>/dev/null || echo "?")
assert_eq "store: file entry is 0600" "600" "$perms"
cleanup_stubs

# 5h1. acq_secret_delete: removes an entry, is idempotent, and scoped.
make_stubs
del_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/del-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'GV\n' | acq_secret_store "$(_acq_secret_key github)"
  printf 'SV\n' | acq_secret_store "$(_acq_secret_key github mybox)"
  # Delete the sandbox-scoped one; global must remain. Check the KEY directly
  # (acq_secret_get on the scoped key) rather than acq_secret_has, which would
  # fall back to the global entry by design.
  acq_secret_delete "$(_acq_secret_key github mybox)" && printf 'del-scoped-rc=0\n'
  acq_secret_get "$(_acq_secret_key github mybox)" >/dev/null 2>&1 && printf 'scoped-still=yes\n' || printf 'scoped-still=no\n'
  acq_secret_get "$(_acq_secret_key github)" >/dev/null 2>&1 && printf 'global-still=yes\n' || printf 'global-still=no\n'
  # Deleting an absent key is success (idempotent).
  acq_secret_delete "$(_acq_secret_key github mybox)" && printf 'del-absent-rc=0\n'
  # Delete global too.
  acq_secret_delete "$(_acq_secret_key github)" && printf 'del-global-rc=0\n'
  acq_secret_get "$(_acq_secret_key github)" >/dev/null 2>&1 && printf 'global-after=yes\n' || printf 'global-after=no\n'
)
assert_contains "delete: removes scoped entry (rc 0)" "$del_out" "del-scoped-rc=0"
assert_contains "delete: scoped gone after delete" "$del_out" "scoped-still=no"
assert_contains "delete: global untouched by scoped delete" "$del_out" "global-still=yes"
assert_contains "delete: absent key is idempotent success" "$del_out" "del-absent-rc=0"
assert_contains "delete: global removed" "$del_out" "del-global-rc=0"
assert_contains "delete: global gone after delete" "$del_out" "global-after=no"
cleanup_stubs

# 5h2. `acq secret rm SANDBOX github` (msb) removes the acq-store entry via the
#      backend rm path, AND live-unbinds it from the running sandbox with
#      `msb modify --secret-rm GITHUB_TOKEN`. Uses the real dispatch + stubbed msb.
make_stubs; load_acq
# Report the sandbox as "running" so the live-unbind path targets it.
printf 'rmbox\n' > "$STUBDIR/.msb_sandbox_list"
: > "$CALLS"
rm_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/rm-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'TOK\n' | acq_secret_store "$(_acq_secret_key github rmbox)"
  acq_secret_has github rmbox && printf 'before=yes\n' || printf 'before=no\n'
  ACQ_BACKEND=msb "$ACQ" secret rm rmbox github >/dev/null 2>&1
  acq_secret_has github rmbox && printf 'after=yes\n' || printf 'after=no\n'
)
rm_log=$(cat "$CALLS")
assert_contains "secret rm: present before" "$rm_out" "before=yes"
assert_contains "secret rm: removed after (msb backend rm)" "$rm_out" "after=no"
assert_contains "secret rm: live-unbinds via msb modify --secret-rm" "$rm_log" "msb modify rmbox --secret-rm GITHUB_TOKEN"
cleanup_stubs

# 5h2b. Global `acq secret rm -g usai` (msb) sweeps ALL running sandboxes with
#       msb modify --secret-rm USAI_API_KEY.
make_stubs; load_acq
printf 'boxA\nboxB\n' > "$STUBDIR/.msb_sandbox_list"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/rmg-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'K\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_BACKEND=msb "$ACQ" secret rm -g usai >/dev/null 2>&1
)
rmg_log=$(cat "$CALLS")
assert_contains "secret rm -g: unbinds boxA" "$rmg_log" "msb modify boxA --secret-rm USAI_API_KEY"
assert_contains "secret rm -g: unbinds boxB" "$rmg_log" "msb modify boxB --secret-rm USAI_API_KEY"
cleanup_stubs

# 5h2c. `acq secret set` (msb) live add/rotates into running sandboxes for EVERY
#       bound service, not just usai. github into a named running sandbox must
#       re-feed via `msb modify <box> --secret GITHUB_TOKEN@...`, and the real
#       value must NOT leak into argv.
make_stubs; load_acq
printf 'setbox\n' > "$STUBDIR/.msb_sandbox_list"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/set-secrets"
  export ACQ_SECRET_TEST_VALUE="ghp_SECRETVALUE"   # non-TTY store input
  ACQ_BACKEND=msb "$ACQ" secret set setbox github >/dev/null 2>&1
)
set_log=$(cat "$CALLS")
assert_contains "secret set: github live-rotates into running sandbox" "$set_log" "msb modify setbox --secret $MSB_GITHUB_SECRET_BINDING"
if grep -q 'ghp_SECRETVALUE' "$CALLS"; then
  fail "secret set: value must NOT appear in msb argv" "leaked into $CALLS"
else
  pass "secret set: value never leaks to msb argv (passed via env)"
fi
# The value must reach the child as an env ENTRY (export), NOT as an `env
# NAME=VAL msb …` argv operand (which `ps`/cmdline would expose). Assert the
# rotate path does not shell out through `env` with the token on argv.
assert_not_contains "secret set: no 'env NAME=VAL' argv leak (uses export)" "$set_log" "env GITHUB_TOKEN="
cleanup_stubs

# 5h2d. Global `acq secret set -g usai` (msb) sweeps ALL running sandboxes
#       (regression guard for the stdin-consumption loop bug: both boxes fed).
make_stubs; load_acq
printf 'sboxA\nsboxB\n' > "$STUBDIR/.msb_sandbox_list"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/setg-secrets"
  export ACQ_SECRET_TEST_VALUE="usai-key-value"
  ACQ_BACKEND=msb "$ACQ" secret set -g usai >/dev/null 2>&1
)
setg_log=$(cat "$CALLS")
assert_contains "secret set -g: rotates sboxA" "$setg_log" "msb modify sboxA --secret USAI_API_KEY@api.gsa.usai.gov"
assert_contains "secret set -g: rotates sboxB" "$setg_log" "msb modify sboxB --secret USAI_API_KEY@api.gsa.usai.gov"
cleanup_stubs

# 5h3. `acq secret rm` requires a scope; a lone token is passed through (not
#      treated as a managed removal) — assert the managed-service classifier.
make_stubs
classify_out=$(
  . "${REPO_ROOT}/acq.backends/common.sh"
  _acq_is_managed_secret_rm -g github     && printf 'g-github=managed\n'  || printf 'g-github=passthru\n'
  _acq_is_managed_secret_rm mybox usai    && printf 'box-usai=managed\n'  || printf 'box-usai=passthru\n'
  _acq_is_managed_secret_rm somePlaceholder && printf 'lone=managed\n'    || printf 'lone=passthru\n'
  _acq_is_managed_secret_rm -g unknownsvc && printf 'g-unknown=managed\n' || printf 'g-unknown=passthru\n'
)
assert_contains "classify: -g github is managed" "$classify_out" "g-github=managed"
assert_contains "classify: SANDBOX usai is managed" "$classify_out" "box-usai=managed"
assert_contains "classify: lone placeholder is passthrough" "$classify_out" "lone=passthru"
assert_contains "classify: unknown service is passthrough" "$classify_out" "g-unknown=passthru"
cleanup_stubs

# 5h3a. Regression (GSA-TTS/agentic-coding-quickstart#300): a NON-built-in secret
#       that actually EXISTS in the acq store (e.g. an orphan created with a
#       sandbox-shaped service name) must be removable — the classifier treats a
#       stored entry as managed, and `acq secret rm` deletes it. Otherwise such
#       entries become un-removable orphans (`ls` shows them, `rm` refuses).
make_stubs
_orphan_store=$(mktemp -d "${TMPDIR:-/tmp}/acq-orphan.XXXXXX")
orphan_out=$(
  export ACQ_SECRET_STORE_DIR="$_orphan_store/secrets"   # force the file store
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/common.sh"
  _k=$(_acq_secret_key opencode-pic-blm-cxworks)
  printf 'orphan-value' | acq_secret_store "$_k" >/dev/null 2>&1
  # before removal: stored + classified managed
  acq_secret_get "$_k" >/dev/null 2>&1 && printf 'stored=yes\n'
  _acq_is_managed_secret_rm -g opencode-pic-blm-cxworks && printf 'orphan=managed\n' || printf 'orphan=passthru\n'
  # an absent non-built-in is still NOT managed (must not swallow a real placeholder)
  _acq_is_managed_secret_rm -g never-stored-svc && printf 'absent=managed\n' || printf 'absent=passthru\n'
  # remove it, then confirm gone
  acq_secret_delete "$_k" >/dev/null 2>&1
  acq_secret_get "$_k" >/dev/null 2>&1 && printf 'after=present\n' || printf 'after=gone\n'
)
rm -rf "$_orphan_store"
assert_contains "orphan(#300): stored" "$orphan_out" "stored=yes"
assert_contains "orphan(#300): stored entry is managed (removable)" "$orphan_out" "orphan=managed"
assert_contains "orphan(#300): absent non-builtin stays passthrough" "$orphan_out" "absent=passthru"
assert_contains "orphan(#300): removed" "$orphan_out" "after=gone"
cleanup_stubs

# 5h3b. Regression: on msb, `acq secret rm SERVICE` with NO scope (a lone token)
#       must NOT be passed through to a nonexistent `msb secret` CLI (which
#       produced a confusing "unrecognized subcommand 'secret'" from msb). Since
#       the msb backend owns the acq secret store natively (it defines
#       acq_backend_secret_ls) there is no raw-placeholder passthrough — acq must
#       fail closed with its own scope-required usage error and never invoke msb.
make_stubs; load_acq
: > "$CALLS"
lone_out=$(ACQ_BACKEND=msb "$ACQ" secret rm openchamber-setup 2>&1); lone_rc=$?
lone_log=$(cat "$CALLS")
assert_contains "secret rm(msb): lone token errors with scope-required" "$lone_out" "scope required"
[ "$lone_rc" -ne 0 ] && pass "secret rm(msb): lone token exits non-zero" \
  || fail "secret rm(msb): lone token must exit non-zero" "rc=$lone_rc"
assert_not_contains "secret rm(msb): lone token never invokes 'msb secret'" "$lone_log" "msb secret"
cleanup_stubs

