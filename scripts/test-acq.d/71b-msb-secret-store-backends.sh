#!/usr/bin/env bash
#
# 71b-msb-secret-store-backends — keychain-linux list/heal, file-backend parity (8m0h..)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 8m0h. acq_secret_list_keys on a keychain-linux backend. The bug: list_keys
#       enumerated ONLY the file directory, but on keychain-linux the values live
#       in the Linux keychain (via secret-tool), never the file dir — so `ls`
#       showed no rows. The fix makes list_keys backend-aware and enumerates the
#       keychain store via an acq-maintained NON-SECRET key index.
#
#       We simulate keychain-linux fully offline with a `secret-tool` STUB that
#       stores attr/value to a stub dir and looks them up, plus overriding
#       _acq_secret_backend to return keychain-linux (the harness otherwise
#       forces the file backend via ACQ_SECRET_STORE_DIR — we keep that env for
#       the index/meta paths, but the value store routes through the stub).
make_stubs; load_acq
# Stub secret-tool: store attr+value under a per-key file (value contents are
# opaque to enumeration — the fix relies on the acq key index, not on scraping
# secret-tool), lookup returns the stored value, clear removes it.
cat >"$STUBDIR/secret-tool" <<'STSTUB'
#!/usr/bin/env bash
# Minimal libsecret-like stub. Store keys under $STUBDIR/st-store keyed by the
# acq_key attribute value. Values are held only to answer lookup — the acq fix
# does NOT enumerate via this stub, so no wildcard/search enumeration is needed.
_dir="${STUBDIR}/st-store"
mkdir -p "$_dir" 2>/dev/null || true
_keyfile() {
  # $1 = acq_key value; make it filesystem-safe.
  printf '%s/%s' "$_dir" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}
case "${1:-}" in
  store)
    # secret-tool store --label=… acq_key <key>   (value on stdin)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    [ -n "$_k" ] || exit 1
    cat > "$(_keyfile "$_k")"
    exit 0 ;;
  lookup)
    # secret-tool lookup acq_key <key>
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    _f="$(_keyfile "$_k")"
    [ -f "$_f" ] || exit 1
    cat "$_f"; exit 0 ;;
  clear)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    rm -f "$(_keyfile "$_k")" 2>/dev/null || true
    exit 0 ;;
  *) exit 0 ;;
esac
STSTUB
chmod +x "$STUBDIR/secret-tool"

kl_out=$(
  # Keep the harness's throwaway index/meta dirs, but force the keychain-linux
  # value path: override _acq_secret_backend to return keychain-linux and unset
  # the file-backend forcing so store/get/delete/list route through the stub.
  export ACQ_SECRET_STORE_DIR="$STUBDIR/kl-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  # The escape hatch above rooted the index/meta beside the (unused) file store;
  # override the backend so values go to the secret-tool stub, not a file.
  unset ACQ_SECRET_FORCE_FILE
  _acq_secret_backend() { printf 'keychain-linux\n'; }
  export STUBDIR

  # Store a GLOBAL built-in (usai) and a SANDBOX-SCOPED built-in (github). The
  # github case is the key regression: a built-in has no endpoint sidecar, so a
  # meta-only enumeration would miss it — the index must carry it.
  ACQ_SECRET_TEST_VALUE='KL-USAI-VALUE'   acq_secret_set_interactive usai '' >/dev/null 2>&1
  ACQ_SECRET_TEST_VALUE='KL-GITHUB-VALUE' acq_secret_set_interactive github klbox >/dev/null 2>&1

  printf 'listing=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"

  # Delete the scoped github secret; it must drop out of the listing (stale-index
  # verification: even if the index still held it, the value no longer resolves).
  acq_secret_delete "$(_acq_secret_key github klbox)" >/dev/null 2>&1
  printf 'after-del=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"
)
assert_contains "keychain-linux ls: lists global usai key"        "$kl_out" "acq.usai"
assert_contains "keychain-linux ls: lists scoped github key (no sidecar — regression)" "$kl_out" "acq.klbox.github"
# The values must NEVER appear in the listing output.
assert_not_contains "keychain-linux ls: never prints usai value"   "$kl_out" "KL-USAI-VALUE"
assert_not_contains "keychain-linux ls: never prints github value" "$kl_out" "KL-GITHUB-VALUE"
# After delete, the github key is gone but usai remains.
assert_contains     "keychain-linux ls: deleted github key removed" "$kl_out" "after-del=[acq.usai ]"
cleanup_stubs

# 8m0i. Regression: the plain FILE backend behavior is unchanged by the
#       backend-aware split — a stored secret still lists, and an empty store
#       lists nothing.
make_stubs; load_acq
file_ls_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/file-ls-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  # ACQ_SECRET_STORE_DIR sets ACQ_SECRET_FORCE_FILE=1 -> backend is 'file'.
  ACQ_SECRET_TEST_VALUE='FILE-VALUE' acq_secret_set_interactive usai '' >/dev/null 2>&1
  printf 'listing=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"
)
empty_file_ls=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/file-empty-ls"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'listing=[%s]\n' "$(acq_secret_list_keys | tr '\n' ' ')"
)
assert_contains     "file ls: stored secret still lists"        "$file_ls_out" "acq.usai"
assert_not_contains "file ls: never prints the file value"      "$file_ls_out" "FILE-VALUE"
assert_contains     "file ls: empty store lists nothing"        "$empty_file_ls" "listing=[]"
cleanup_stubs

# 8m0j. Self-healing sidecar branch (keychain-linux). The (b) fallback in
#       _acq_secret_list_keys_keychain_linux reconstructs `acq.*` keys from the
#       endpoint sidecars when the key index is missing/stale. We store a CUSTOM
#       service (host+env => a meta sidecar is written) AND a built-in (no
#       sidecar), then DELETE the index file entirely to simulate a lost index,
#       and assert: the custom service's key STILL lists (reconstructed from its
#       sidecar), while the built-in — which has no sidecar to heal from — is
#       correctly NOT listed. This proves the fallback heals only sidecar-backed
#       keys, and does not fabricate keys with no on-disk evidence.
make_stubs; load_acq
# Reuse the same minimal secret-tool stub as 8m0h (store/lookup/clear by attr).
cat >"$STUBDIR/secret-tool" <<'STSTUB'
#!/usr/bin/env bash
_dir="${STUBDIR}/st-store"
mkdir -p "$_dir" 2>/dev/null || true
_keyfile() { printf '%s/%s' "$_dir" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
case "${1:-}" in
  store)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    [ -n "$_k" ] || exit 1
    cat > "$(_keyfile "$_k")"; exit 0 ;;
  lookup)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    _f="$(_keyfile "$_k")"; [ -f "$_f" ] || exit 1; cat "$_f"; exit 0 ;;
  clear)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    rm -f "$(_keyfile "$_k")" 2>/dev/null || true; exit 0 ;;
  *) exit 0 ;;
esac
STSTUB
chmod +x "$STUBDIR/secret-tool"

heal_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/heal-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  unset ACQ_SECRET_FORCE_FILE
  _acq_secret_backend() { printf 'keychain-linux\n'; }
  export STUBDIR

  # Custom service: HOST+ENV supplied => acq_secret_meta_store writes a sidecar.
  ACQ_SECRET_TEST_VALUE='KL-GL-VALUE' \
    acq_secret_set_interactive gitlab '' workshop.cloud.gov GITLAB_TOKEN >/dev/null 2>&1
  # Built-in: no host/env => NO sidecar written (only the index carries it).
  ACQ_SECRET_TEST_VALUE='KL-USAI-VALUE' \
    acq_secret_set_interactive usai '' >/dev/null 2>&1

  # Simulate a lost/missing index: remove it entirely. Only the sidecar-backed
  # key can now be reconstructed via the (b) self-healing branch.
  rm -f "$ACQ_SECRET_INDEX_FILE"
  [ -f "$ACQ_SECRET_INDEX_FILE" ] && printf 'INDEX-STILL-PRESENT\n'

  printf 'listing=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"
)
assert_contains     "keychain-linux self-heal: index removed but sidecar-backed key relisted" "$heal_out" "acq.gitlab"
assert_not_contains "keychain-linux self-heal: built-in w/o sidecar NOT relisted after index loss" "$heal_out" "acq.usai"
assert_not_contains "keychain-linux self-heal: index file truly removed"                       "$heal_out" "INDEX-STILL-PRESENT"
# Values never leak into the listing, even on the heal path.
assert_not_contains "keychain-linux self-heal: never prints gitlab value" "$heal_out" "KL-GL-VALUE"
cleanup_stubs


#       its own absolute host path (sbx-parity), a trailing :ro is preserved, and
#       the recorded start dir is the FIRST (primary) workspace regardless of how
#       many mounts are given (docs/QUICKSTART_SBX.md: "Primary workspace — the
#       first path; agent starts here").
make_stubs; load_acq
# Two real host dirs to mount (a nonexistent path would hard-fail provision).
mkdir -p "$STUBDIR/ws-app" "$STUBDIR/ws-lib"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mw-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mwbox opencode "$STUBDIR/ws-app" "$STUBDIR/ws-lib:ro" >/dev/null 2>&1
)
mw_log=$(cat "$CALLS")
# acq canonicalizes host workspace paths before mounting (macOS $TMPDIR is a
# /var -> /private/var symlink), so compare against the resolved real paths.
_ws_app=$(canonicalize_path "$STUBDIR/ws-app")
_ws_lib=$(canonicalize_path "$STUBDIR/ws-lib")
assert_contains "msb: multi-ws mounts primary at its host path" "$mw_log" "--volume ${_ws_app}:${_ws_app}"
assert_contains "msb: multi-ws mounts extra ro at its host path" "$mw_log" "--volume ${_ws_lib}:${_ws_lib}:ro"
assert_contains "msb: multi-ws start dir is the FIRST (primary) workspace" "$mw_log" "'${_ws_app}' > /var/lib/acq/workspace"
assert_not_contains "msb: multi-ws does NOT fall back to /home/agent/workspace" "$mw_log" "'/home/agent/workspace' > /var/lib/acq/workspace"

# Single workspace records that mount as the start dir.
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/sw-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  acq_backend_provision swbox opencode "$STUBDIR/ws-app" >/dev/null 2>&1
)
sw_log=$(cat "$CALLS")
assert_contains "msb: single-ws records that mount as start dir" "$sw_log" "'${_ws_app}' > /var/lib/acq/workspace"
cleanup_stubs

# 8m1c. Symlinked host workspace is canonicalized before mounting. msb cannot
#       mount a symlinked host path (macOS $TMPDIR is /var -> /private/var), so
#       acq resolves it to its real path first. Simulate with a symlink dir ->
#       real dir and assert the --volume uses the REAL target, not the link.
make_stubs; load_acq
mkdir -p "$STUBDIR/real-ws"
ln -sf "$STUBDIR/real-ws" "$STUBDIR/link-ws"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/sym-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision symbox opencode "$STUBDIR/link-ws" >/dev/null 2>&1
)
sym_log=$(cat "$CALLS")
# realpath of the symlink is the real dir; assert the mount uses it.
_real_ws=$(realpath "$STUBDIR/real-ws" 2>/dev/null || printf '%s' "$STUBDIR/real-ws")
assert_contains "msb: symlinked workspace canonicalized to real path" "$sym_log" "--volume ${_real_ws}:${_real_ws}"
assert_not_contains "msb: symlinked workspace NOT mounted via the link" "$sym_log" "--volume ${STUBDIR}/link-ws:"
cleanup_stubs

# 8m2. msb provision aborts (hard fail) when the sandbox never becomes
#      exec-ready — `msb create` returns 0 even when the guest fails to START,
#      so acq must NOT proceed against a dead sandbox.
make_stubs; load_acq
# Make the msb stub's `exec` never return "ok" (simulate a sandbox that didn't
# start), by pointing echo-ok probes at a failing exit.
cat >"$STUBDIR/msb" <<'MSBSTUB2'
#!/usr/bin/env bash
{ printf 'msb'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  --version|-V) printf 'msb %s\n' "${STUB_MSB_VERSION:-0.6.9}" ;;
  create) exit 0 ;;              # create "succeeds" but the guest never starts
  exec)   exit 1 ;;              # every exec fails -> never exec-ready
  *) exit 0 ;;
esac
MSBSTUB2
chmod +x "$STUBDIR/msb"
notready_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/nr-secrets" ACQ_MSB_EXEC_READY_TIMEOUT=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision nrbox shell /tmp 2>&1
  echo "PROVISION_RC=$?"
)
assert_contains "msb: not-ready aborts provision" "$notready_out" "did not become exec-ready"
assert_contains "msb: not-ready is a hard failure (rc!=0)" "$notready_out" "PROVISION_RC=1"
cleanup_stubs

# 8m3. msb provision errors clearly when the host workspace path does not exist
#      (msb cannot mount a nonexistent host path).
make_stubs; load_acq
missing_ws_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mw-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mwbox shell /no/such/path/here 2>&1
  echo "RC=$?"
)
assert_contains "msb: missing workspace errors" "$missing_ws_out" "workspace path does not exist"
assert_contains "msb: missing workspace is a hard failure" "$missing_ws_out" "RC=1"
cleanup_stubs

