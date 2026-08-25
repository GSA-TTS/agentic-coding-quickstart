#!/usr/bin/env bats
#
# 71b-msb-secret-store-backends.bats — bats port of
# scripts/test-acq.d/71b-msb-secret-store-backends.sh (ADR-0025)
#
# keychain-linux secret listing (index + self-heal from sidecars), file-backend
# parity, multi-workspace mounts (sbx-parity paths + primary start dir), symlink
# canonicalization, and provision failure modes. Uses an offline secret-tool
# stub + isolated subshells.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# The minimal libsecret-like secret-tool stub used by the keychain-linux tests.
_plant_secret_tool_stub() {
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
}

# Provision helper (as in 71): source common (chains deps) + msb, seed store,
# stub kit fetch, provision.
_provision() { # NAME PRE_SNIPPET WS_ARGS...
  local name="$1" pre="$2"; shift 2
  : > "$CALLS"
  run bash -c '
    name="$1"; pre="$2"; shift 2
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_provision "$name" opencode "$@" 2>&1
  ' _ "$name" "$pre" "$@"
}

@test "keychain-linux ls: lists global + scoped keys via the index, never values; delete drops one" {
  _plant_secret_tool_stub
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/kl-secrets"
    export STUBDIR="'"$STUBDIR"'"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    unset ACQ_SECRET_FORCE_FILE
    _acq_secret_backend() { printf "keychain-linux\n"; }
    ACQ_SECRET_TEST_VALUE="KL-USAI-VALUE"   acq_secret_set_interactive usai "" >/dev/null 2>&1
    ACQ_SECRET_TEST_VALUE="KL-GITHUB-VALUE" acq_secret_set_interactive github klbox >/dev/null 2>&1
    printf "listing=[%s]\n" "$(acq_secret_list_keys | sort | tr "\n" " ")"
    acq_secret_delete "$(_acq_secret_key github klbox)" >/dev/null 2>&1
    printf "after-del=[%s]\n" "$(acq_secret_list_keys | sort | tr "\n" " ")"
  '
  assert_output --partial 'acq.usai'
  assert_output --partial 'acq.klbox.github'
  refute_output --partial 'KL-USAI-VALUE'
  refute_output --partial 'KL-GITHUB-VALUE'
  assert_output --partial 'after-del=[acq.usai ]'
}

@test "file ls: a stored secret lists (no value); an empty store lists nothing" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/file-ls-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    ACQ_SECRET_TEST_VALUE="FILE-VALUE" acq_secret_set_interactive usai "" >/dev/null 2>&1
    printf "listing=[%s]\n" "$(acq_secret_list_keys | sort | tr "\n" " ")"
  '
  assert_output --partial 'acq.usai'
  refute_output --partial 'FILE-VALUE'
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/file-empty-ls"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "listing=[%s]\n" "$(acq_secret_list_keys | tr "\n" " ")"
  '
  assert_output --partial 'listing=[]'
}

@test "keychain-linux self-heal: a lost index relists sidecar-backed keys only, never values" {
  _plant_secret_tool_stub
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/heal-secrets"
    export STUBDIR="'"$STUBDIR"'"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    unset ACQ_SECRET_FORCE_FILE
    _acq_secret_backend() { printf "keychain-linux\n"; }
    ACQ_SECRET_TEST_VALUE="KL-GL-VALUE"   acq_secret_set_interactive gitlab "" workshop.cloud.gov GITLAB_TOKEN >/dev/null 2>&1
    ACQ_SECRET_TEST_VALUE="KL-USAI-VALUE" acq_secret_set_interactive usai "" >/dev/null 2>&1
    rm -f "$ACQ_SECRET_INDEX_FILE"
    [ -f "$ACQ_SECRET_INDEX_FILE" ] && printf "INDEX-STILL-PRESENT\n"
    printf "listing=[%s]\n" "$(acq_secret_list_keys | sort | tr "\n" " ")"
  '
  assert_output --partial 'acq.gitlab'
  refute_output --partial 'acq.usai'
  refute_output --partial 'INDEX-STILL-PRESENT'
  refute_output --partial 'KL-GL-VALUE'
}

@test "msb: multi-workspace mounts each at its host path; start dir is the primary" {
  mkdir -p "$STUBDIR/ws-app" "$STUBDIR/ws-lib"
  _provision mwbox 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/mw-secrets"' \
    "$STUBDIR/ws-app" "$STUBDIR/ws-lib:ro"
  load_acq
  local ws_app ws_lib log
  ws_app=$(canonicalize_path "$STUBDIR/ws-app")
  ws_lib=$(canonicalize_path "$STUBDIR/ws-lib")
  log=$(cat "$CALLS")
  assert_regex "$log" "--volume ${ws_app}:${ws_app}"
  assert_regex "$log" "--volume ${ws_lib}:${ws_lib}:ro"
  assert_regex "$log" "'${ws_app}' > /var/lib/acq/workspace"
  refute_regex "$log" "'/home/agent/workspace' > /var/lib/acq/workspace"

  # Single workspace records that mount as the start dir.
  _provision swbox 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sw-secrets"' "$STUBDIR/ws-app"
  assert_regex "$(cat "$CALLS")" "'${ws_app}' > /var/lib/acq/workspace"
}

@test "msb: a symlinked workspace is canonicalized to its real path before mounting" {
  mkdir -p "$STUBDIR/real-ws"
  ln -sf "$STUBDIR/real-ws" "$STUBDIR/link-ws"
  _provision symbox 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sym-secrets"' "$STUBDIR/link-ws"
  local real_ws log
  real_ws=$(realpath "$STUBDIR/real-ws" 2>/dev/null || printf '%s' "$STUBDIR/real-ws")
  log=$(cat "$CALLS")
  assert_regex "$log" "--volume ${real_ws}:${real_ws}"
  refute_regex "$log" "--volume ${STUBDIR}/link-ws:"
}

@test "msb: provision aborts (hard fail) when the sandbox never becomes exec-ready" {
  cat >"$STUBDIR/msb" <<'MSBSTUB'
#!/usr/bin/env bash
{ printf 'msb'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  --version|-V) printf 'msb %s\n' "${STUB_MSB_VERSION:-0.6.9}" ;;
  create) exit 0 ;;
  exec)   exit 1 ;;
  *) exit 0 ;;
esac
MSBSTUB
  chmod +x "$STUBDIR/msb"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/nr-secrets" ACQ_MSB_EXEC_READY_TIMEOUT=1
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_provision nrbox shell /tmp 2>&1
    echo "PROVISION_RC=$?"
  '
  assert_output --partial 'did not become exec-ready'
  assert_output --partial 'PROVISION_RC=1'
}

@test "msb: provision errors clearly when the host workspace path does not exist" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/mw-secrets"
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_provision mwbox shell /no/such/path/here 2>&1
    echo "RC=$?"
  '
  assert_output --partial 'workspace path does not exist'
  assert_output --partial 'RC=1'
}
