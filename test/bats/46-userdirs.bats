#!/usr/bin/env bats
#
# 46-userdirs.bats — host user-directory resolution (acq.backends/userdirs.sh).
#
# The XDG Base Directory specification says a relative XDG_*_HOME value is
# invalid and must be ignored; acq additionally uses HOME only when it is
# absolute and refuses a relative ACQ_STATE_DIR (or secret-store directory
# override). A relative value would otherwise resolve against the current
# directory, which is normally the agent-writable workspace. These tests mirror
# py-acq's userdirs/state semantics so the two implementations agree.
#
# Every test runs from a throwaway working directory under $STUBDIR and asserts
# that nothing was created there.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  WORK="$STUBDIR/work"
  mkdir -p "$WORK"
  cd "$WORK" || return 1
}
teardown() { acq_teardown_stubs; }

load 'helper'

# Stub `id` and `getent` so the account-home fallback finds nothing (an
# account the password database does not know) and only HOME could supply a
# home.
_plant_unknown_account() {
  cat >"$STUBDIR/id" <<'IDSTUB'
#!/bin/sh
case "$1" in -u) echo 4199999 ;; *) echo acq-no-such-account-46 ;; esac
IDSTUB
  cat >"$STUBDIR/getent" <<'GESTUB'
#!/bin/sh
exit 2
GESTUB
  chmod +x "$STUBDIR/id" "$STUBDIR/getent"
}

_assert_work_empty() {
  run ls -A "$WORK"
  assert_success
  assert_output ''
}

@test "userdirs: relative or empty XDG_* values are ignored in favour of the home default" {
  run bash -c '
    . "$1/acq.backends/userdirs.sh"
    XDG_STATE_HOME=rel-state XDG_CONFIG_HOME="" XDG_DATA_HOME=./data XDG_CACHE_HOME=../cache
    acq_xdg_dir XDG_STATE_HOME .local/state
    acq_xdg_dir XDG_CONFIG_HOME .config
    acq_xdg_dir XDG_DATA_HOME .local/share
    acq_xdg_dir XDG_CACHE_HOME .cache
    XDG_STATE_HOME=/abs/state; acq_xdg_dir XDG_STATE_HOME .local/state
  ' _ "$REPO_ROOT"
  assert_success
  assert_line --index 0 "$HOME/.local/state"
  assert_line --index 1 "$HOME/.config"
  assert_line --index 2 "$HOME/.local/share"
  assert_line --index 3 "$HOME/.cache"
  assert_line --index 4 "/abs/state"
}

@test "userdirs: a relative HOME falls back to the account home, never the cwd" {
  local want
  if command -v getent >/dev/null 2>&1; then
    want=$(getent passwd "$(id -u)" | cut -d: -f6)
  else
    want=$(bash -c 'eval "printf %s ~$(id -un)"')
  fi
  run env HOME=relhome bash -c '. "$1/acq.backends/userdirs.sh"; acq_home_dir' _ "$REPO_ROOT"
  assert_success
  assert_output "$want"
  case "$output" in /*) ;; *) fail "home is not absolute: $output" ;; esac
}

@test "userdirs: the account home is looked up by uid, so a numeric account name works" {
  cat >"$STUBDIR/id" <<'IDSTUB'
#!/bin/sh
case "$1" in -u) echo 4242 ;; *) echo 1234 ;; esac
IDSTUB
  cat >"$STUBDIR/getent" <<'GESTUB'
#!/bin/sh
echo "getent $*" >> "$CALLS"
[ "$1 $2" = "passwd 4242" ] && echo '1234:x:4242:4242::/abs/acct-home:/bin/sh'
GESTUB
  chmod +x "$STUBDIR/id" "$STUBDIR/getent"
  run env HOME=relhome bash -c '. "$1/acq.backends/userdirs.sh"; acq_home_dir' _ "$REPO_ROOT"
  assert_success
  assert_output '/abs/acct-home'
  run cat "$CALLS"
  assert_line 'getent passwd 4242'
}

@test "userdirs: without getent, an all-digit account name never reaches the tilde lookup" {
  local bin="$STUBDIR/nogetent" bash_bin
  bash_bin=$(command -v bash)
  mkdir -p "$bin"
  # uid/name 0: "~0" is the one all-digit tilde form bash expands (to $PWD),
  # so it must never reach the lookup.
  printf '#!/bin/sh\necho 0\n' >"$bin/id"
  chmod +x "$bin/id"
  run env HOME=relhome PATH="$bin" "$bash_bin" -c '
    . "$1/acq.backends/userdirs.sh"
    acq_home_dir || echo "no home"
  ' _ "$REPO_ROOT"
  assert_success
  assert_output 'no home'
}

@test "userdirs: no absolute home fails closed with the Python message" {
  _plant_unknown_account
  run env -u ACQ_STATE_DIR HOME=relhome XDG_STATE_HOME=rel bash -c '
    . "$1/acq.backends/userdirs.sh"
    acq_home_dir && echo "home resolved"
    acq_xdg_dir XDG_STATE_HOME .local/state && echo "xdg resolved"
    acq_userdirs_check
  ' _ "$REPO_ROOT"
  assert_failure
  refute_line 'home resolved'
  refute_line 'xdg resolved'
  assert_output "acq: cannot determine an absolute home directory (HOME is 'relhome')
set HOME to an absolute path, or set the XDG base directory variables (XDG_STATE_HOME, XDG_CONFIG_HOME) to absolute paths"
}

@test "userdirs: Bash-only scope - no home with a relative XDG_DATA_HOME names the data and cache dirs" {
  _plant_unknown_account
  run env -u ACQ_STATE_DIR HOME=relhome XDG_STATE_HOME=/s XDG_CONFIG_HOME=/c XDG_DATA_HOME=rel XDG_CACHE_HOME=/k bash -c '
    . "$1/acq.backends/userdirs.sh"
    acq_userdirs_check
  ' _ "$REPO_ROOT"
  assert_failure
  assert_output "acq: cannot determine an absolute home directory (HOME is 'relhome')
set HOME to an absolute path, or set the XDG base directory variables (XDG_STATE_HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME) to absolute paths"
}

@test "userdirs: a diagnostic quotes the value like Python repr (no raw newlines)" {
  run env ACQ_STATE_DIR="$(printf 'rel\nINJECTED\tx')" bash -c '. "$1/acq.backends/userdirs.sh"; acq_userdirs_check' _ "$REPO_ROOT"
  assert_failure
  assert_line --index 0 "acq: ACQ_STATE_DIR must be an absolute path, got 'rel\\nINJECTED\\tx'"
  refute_line 'INJECTED'
  run bash -c '. "$1/acq.backends/userdirs.sh"; acq_quote_value "it'"'"'s"; acq_quote_value "$(printf "a\001b\\\\c")"' _ "$REPO_ROOT"
  assert_line --index 0 "\"it's\""
  assert_line --index 1 "'a\\x01b\\\\c'"
}

@test "userdirs: Git Bash / Cygwin drive-rooted paths are absolute only there" {
  run bash -c '
    . "$1/acq.backends/userdirs.sh"
    OSTYPE=msys
    acq_path_is_absolute "C:/x" && echo "msys C:/x abs"
    acq_path_is_absolute "C:\\x" && echo "msys C:\\x abs"
    acq_path_is_absolute "x/C:" || echo "msys x/C: rel"
    XDG_STATE_HOME="D:\\state" acq_xdg_dir XDG_STATE_HOME .local/state
    OSTYPE=linux-gnu
    acq_path_is_absolute "C:/x" || echo "posix C:/x rel"
  ' _ "$REPO_ROOT"
  assert_success
  assert_line 'msys C:/x abs'
  assert_line 'msys C:\x abs'
  assert_line 'msys x/C: rel'
  assert_line 'D:\state'
  assert_line 'posix C:/x rel'
}

@test "userdirs: on Git Bash, USERPROFILE supplies the home in POSIX form" {
  run env HOME=relhome USERPROFILE='C:\Users\Agent Name' bash -c '
    . "$1/acq.backends/userdirs.sh"
    OSTYPE=msys
    acq_home_dir
  ' _ "$REPO_ROOT"
  assert_success
  assert_output '/c/Users/Agent Name'
}

@test "userdirs: absolute XDG_* values need no home at all" {
  _plant_unknown_account
  run env -u HOME -u ACQ_STATE_DIR XDG_STATE_HOME=/s XDG_CONFIG_HOME=/c XDG_DATA_HOME=/d XDG_CACHE_HOME=/k bash -c '
    . "$1/acq.backends/userdirs.sh"
    acq_userdirs_check && acq_state_dir
  ' _ "$REPO_ROOT"
  assert_success
  assert_output '/s/acq'
}

@test "userdirs: an empty ACQ_STATE_DIR is unset; a relative one does not resolve" {
  run env ACQ_STATE_DIR= XDG_STATE_HOME=rel bash -c '. "$1/acq.backends/userdirs.sh"; acq_state_dir' _ "$REPO_ROOT"
  assert_success
  assert_output "$HOME/.local/state/acq"
  run env ACQ_STATE_DIR=rel-state bash -c '. "$1/acq.backends/userdirs.sh"; acq_state_dir' _ "$REPO_ROOT"
  assert_failure
  assert_output ''
}

@test "cli: a relative ACQ_STATE_DIR is refused up front with the Python message" {
  run env ACQ_STATE_DIR=rel-state ACQ_BACKEND=msb "$ACQ" ls
  assert_failure 1
  assert_output "acq: ACQ_STATE_DIR must be an absolute path, got 'rel-state'
set ACQ_STATE_DIR to an absolute path, or unset it to use \$XDG_STATE_HOME/acq (default ~/.local/state/acq)"
  run env ACQ_STATE_DIR=rel-state ACQ_BACKEND=msb "$ACQ" secret set -g usai </dev/null
  assert_failure 1
  assert_line --index 0 "acq: ACQ_STATE_DIR must be an absolute path, got 'rel-state'"
  _assert_work_empty
}

@test "cli: help and version still work with a relative ACQ_STATE_DIR" {
  run env ACQ_STATE_DIR=rel-state ACQ_BACKEND=msb "$ACQ" version
  assert_success
  run env ACQ_STATE_DIR=rel-state ACQ_BACKEND=msb "$ACQ" help
  assert_success
  _assert_work_empty
}

@test "cli: a relative secret-store override is refused" {
  run env ACQ_SECRET_STORE_DIR=rel-secrets ACQ_BACKEND=msb "$ACQ" secret ls
  assert_failure 1
  assert_line --index 0 "acq: ACQ_SECRET_STORE_DIR must be an absolute path, got 'rel-secrets'"
  _assert_work_empty
}

@test "cli: no absolute home refuses state-touching verbs" {
  _plant_unknown_account
  run env HOME=relhome XDG_CONFIG_HOME=rel ACQ_BACKEND=msb "$ACQ" ls
  assert_failure 1
  assert_line --index 0 "acq: cannot determine an absolute home directory (HOME is 'relhome')"
  _assert_work_empty
}

@test "cli: backend set ignores a relative XDG_CONFIG_HOME" {
  run env XDG_CONFIG_HOME=rel-config "$ACQ" backend set msb
  assert_success
  assert [ -f "$HOME/.config/acq/config.yaml" ]
  _assert_work_empty
}

@test "secret store: a relative XDG_DATA_HOME does not place secret files under the cwd" {
  run env -u ACQ_SECRET_STORE_DIR -u ACQ_SECRET_FILE_DIR XDG_DATA_HOME=rel-data bash -c '
    . "$1/acq.backends/secret-store.sh"
    printf "%s\n" "$ACQ_SECRET_FILE_DIR" "$ACQ_SECRET_META_DIR" "$ACQ_SECRET_INDEX_FILE"
  ' _ "$REPO_ROOT"
  assert_success
  assert_line --index 0 "$HOME/.local/share/acq/secrets"
  assert_line --index 1 "$HOME/.local/share/acq/secret-meta"
  assert_line --index 2 "$HOME/.local/share/acq/secret-index"
  _assert_work_empty
}

@test "msb adapter: relative XDG_STATE_HOME/XDG_CACHE_HOME fall back to the home defaults" {
  run env -u ACQ_STATE_DIR XDG_STATE_HOME=rel-state XDG_CACHE_HOME=rel-cache bash -c '
    . "$1/acq.backends/msb.sh"
    printf "%s\n" "$ACQ_STATE_DIR" "$ACQ_MSB_SSH_DIR" "$ACQ_MSB_KIT_CACHE" "$ACQ_MSB_UPSTREAM_CA_FILE"
  ' _ "$REPO_ROOT"
  assert_success
  assert_line --index 0 "$HOME/.local/state/acq"
  assert_line --index 1 "$HOME/.local/state/acq/ssh"
  assert_line --index 2 "$HOME/.cache/acq/kits"
  assert_line --index 3 "$HOME/.local/state/acq/msb/host-upstream-cas.pem"
}

@test "msb adapter: a relative ACQ_STATE_DIR is never kept as the state root" {
  run env ACQ_STATE_DIR=rel-state bash -c '
    . "$1/acq.backends/msb.sh"
    printf "root=[%s]\n" "$ACQ_STATE_DIR"
  ' _ "$REPO_ROOT"
  assert_success
  assert_output 'root=[]'
}

@test "sbx adapter: a relative XDG_CACHE_HOME falls back to the home default" {
  run env XDG_CACHE_HOME=rel-cache bash -c '
    . "$1/acq.backends/sbx.sh"
    printf "%s\n" "$ACQ_SBX_KIT_CACHE"
  ' _ "$REPO_ROOT"
  assert_success
  assert_output "$HOME/.cache/acq/sbx-kits"
}

@test "common: config and provenance paths ignore relative XDG values" {
  run env -u ACQ_PROVENANCE_DIR XDG_CONFIG_HOME=rel-config XDG_STATE_HOME=rel-state bash -c '
    . "$1/acq.backends/common.sh"
    _acq_config_file
    _acq_provenance_dir
  ' _ "$REPO_ROOT"
  assert_success
  assert_line --index 0 "$HOME/.config/acq/config.yaml"
  assert_line --index 1 "$HOME/.local/state/acq/provenance"
}

@test "common: a relative HOME never puts a relative entry on PATH" {
  mkdir -p "$WORK/relhome/.local/bin"
  printf '#!/bin/sh\n' >"$WORK/relhome/.local/bin/acq-test-be"
  chmod +x "$WORK/relhome/.local/bin/acq-test-be"
  run env HOME=relhome bash -c '
    . "$1/acq.backends/common.sh"
    _ensure_local_bin_on_path acq-test-be >/dev/null 2>&1 || true
    printf "%s\n" "$PATH"
  ' _ "$REPO_ROOT"
  assert_success
  refute_output --partial 'relhome'
}

@test "common: kit validation never roots its scratch tree at a relative ACQ_STATE_DIR" {
  run env ACQ_STATE_DIR=rel-state bash -c '
    . "$1/acq.backends/common.sh"
    kit_translate_fetch() { printf "fetch base=%s\n" "$2" >&2; return 1; }
    acq_validate_agent_builtin_kit_ref opencode some-ref && echo validated
    echo done
  ' _ "$REPO_ROOT"
  assert_success
  refute_output --partial 'fetch base='
  assert_output 'done'
  _assert_work_empty
}

@test "common: kit-source discovery never caches under a relative XDG_CACHE_HOME" {
  run env XDG_CACHE_HOME=rel-cache bash -c '
    . "$1/acq.backends/common.sh"
    kit_translate_fetch() { printf "fetch base=%s\n" "$2" >> "$CALLS"; return 1; }
    acq_kit_source_provider_kits github.com/example/kits v1 kits
  ' _ "$REPO_ROOT"
  assert_success
  run cat "$CALLS"
  assert_output --partial "fetch base=$HOME/.cache/acq/kit-sources/"
  refute_output --partial 'rel-cache'
}

# A runtime planted under the relative XDG_DATA_HOME, which must never be used.
_plant_relative_runtime() {
  local d
  for d in "$WORK/rel-data/acq/provider-input-validator.current/bin" \
           "$WORK/rel-data/acq/provider-input-validator/provider-input-validator.current/bin"; do
    mkdir -p "$d"
    printf '#!/bin/sh\nexit 0\n' >"$d/python3"
    chmod +x "$d/python3"
  done
}

@test "common: the provider-facts interpreter comes from the absolute data dir, never a relative XDG_DATA_HOME" {
  _plant_relative_runtime
  local want="$HOME/.local/share/acq/provider-input-validator.current/bin"
  mkdir -p "$want"
  printf '#!/bin/sh\nexit 0\n' >"$want/python3"
  chmod +x "$want/python3"
  run env -u ACQ_PROVIDER_INPUT_PYTHON -u ACQ_PROVIDER_INPUT_DATA_DIR -u LOCALAPPDATA XDG_DATA_HOME=rel-data bash -c '
    . "$1/acq.backends/common.sh"
    _acq_provider_facts_python
  ' _ "$REPO_ROOT"
  assert_success
  assert_output "$want/python3"
}

@test "common: the validator runtime is looked up and bootstrapped under the absolute data dir" {
  _plant_relative_runtime
  local fake="$STUBDIR/fake-acq" want="$HOME/.local/share/acq/provider-input-validator"
  mkdir -p "$fake/scripts"
  cat >"$fake/scripts/setup-provider-input-validator" <<'SETUP'
#!/bin/sh
echo "setup data_dir=${ACQ_PROVIDER_INPUT_DATA_DIR:-}" >> "$CALLS"
mkdir -p "$ACQ_PROVIDER_INPUT_DATA_DIR/provider-input-validator.current/bin"
printf '#!/bin/sh\nexit 0\n' >"$ACQ_PROVIDER_INPUT_DATA_DIR/provider-input-validator.current/bin/python3"
chmod +x "$ACQ_PROVIDER_INPUT_DATA_DIR/provider-input-validator.current/bin/python3"
SETUP
  chmod +x "$fake/scripts/setup-provider-input-validator"
  run env -u ACQ_PROVIDER_INPUT_PYTHON -u ACQ_PROVIDER_INPUT_DATA_DIR -u LOCALAPPDATA XDG_DATA_HOME=rel-data bash -c '
    . "$1/acq.backends/common.sh"
    ACQ_SCRIPT_DIR="$2"
    _acq_provider_input_python
  ' _ "$REPO_ROOT" "$fake"
  assert_success
  assert_output "$want/provider-input-validator.current/bin/python3"
  run cat "$CALLS"
  assert_line "setup data_dir=$want"
}

@test "common: a relative ACQ_PROVIDER_INPUT_DATA_DIR is refused" {
  run env -u ACQ_PROVIDER_INPUT_PYTHON -u LOCALAPPDATA ACQ_PROVIDER_INPUT_DATA_DIR=rel-tools bash -c '
    . "$1/acq.backends/common.sh"
    _acq_provider_input_python
  ' _ "$REPO_ROOT"
  assert_failure 2
  assert_output "acq: ACQ_PROVIDER_INPUT_DATA_DIR must be an absolute path, got 'rel-tools'"
  _assert_work_empty
}

@test "setup script: the default data dir ignores a relative XDG_DATA_HOME" {
  run env -u ACQ_PROVIDER_INPUT_DATA_DIR XDG_DATA_HOME=rel-data ACQ_PROVIDER_INPUT_HOST_OS=Linux ACQ_PROVIDER_INPUT_HOST_ARCH=x86_64 \
    "$REPO_ROOT/scripts/setup-provider-input-validator"
  assert_success
  assert_line --partial "would create $HOME/.local/share/acq/provider-input-validator/provider-input-validator.current"
  refute_output --partial 'rel-data'
  run env ACQ_PROVIDER_INPUT_DATA_DIR=rel-tools ACQ_PROVIDER_INPUT_HOST_OS=Linux ACQ_PROVIDER_INPUT_HOST_ARCH=x86_64 \
    "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_failure 2
  assert_output "provider-input validator: ACQ_PROVIDER_INPUT_DATA_DIR must be an absolute path, got 'rel-tools'"
  _assert_work_empty
}

# Environment for the "no home" tests: no absolute home and relative XDG
# values, so every acq default derived from them is left empty.
_no_home_env() {
  printf '%s\n' -u ACQ_STATE_DIR -u ACQ_SECRET_STORE_DIR -u ACQ_SECRET_FILE_DIR \
    -u ACQ_MSB_KIT_LOCAL_DIR -u ACQ_MSB_STARTUP_STAGE_DIR -u ACQ_SBX_KIT_CACHE -u ACQ_SBX_KIT_PASSTHROUGH \
    HOME=relhome XDG_STATE_HOME=rel XDG_DATA_HOME=rel XDG_CACHE_HOME=rel
}

@test "no home: source-time defaults stay empty instead of root-anchored" {
  _plant_unknown_account
  local -a e=()
  while IFS= read -r l; do e+=("$l"); done < <(_no_home_env)
  run env "${e[@]}" bash -c '
    . "$1/acq.backends/secret-store.sh"
    . "$1/acq.backends/msb.sh"
    . "$1/acq.backends/sbx.sh"
    printf "[%s]\n" "$ACQ_SECRET_FILE_DIR" "$ACQ_SECRET_META_DIR" "$ACQ_SECRET_INDEX_FILE" \
      "$ACQ_STATE_DIR" "$ACQ_MSB_SSH_DIR" "$ACQ_MSB_SSH_KEY" "$ACQ_MSB_PORTS_DIR" "$ACQ_MSB_CLONES_DIR" \
      "$ACQ_MSB_SSH_AGENT_LINK_DIR" "$ACQ_MSB_KIT_CACHE" "$ACQ_MSB_UPSTREAM_CA_FILE" "$ACQ_SBX_KIT_CACHE" \
      "$_ACQ_MSB_PORT_SEQ_FILE"
    _acq_secret_file_for acq.usai || echo "no secret path"
    _acq_secret_meta_file_for acq.usai || echo "no meta path"
  ' _ "$REPO_ROOT"
  assert_success
  refute_output --partial '[/'
  assert_line 'no secret path'
  assert_line 'no meta path'
}

@test "no home: consumers of an empty base refuse or no-op, never touching / or the cwd" {
  _plant_unknown_account
  local -a e=()
  while IFS= read -r l; do e+=("$l"); done < <(_no_home_env)
  run env "${e[@]}" ERRF="$STUBDIR/consumer.err" bash -c '
    . "$1/acq.backends/common.sh"
    . "$1/acq.backends/msb.sh"
    . "$1/acq.backends/sbx.sh"
    r() { local rc=0; "$@" >/dev/null 2>"$ERRF" || rc=$?; printf "%s rc=%s %s\n" "$1" "$rc" "$(head -1 "$ERRF")"; }
    r _acq_msb_clone_cleanup box
    r _acq_msb_clone_warn_unfetched box
    r _acq_msb_ports_pidfile box
    r _acq_msb_ssh_agent_link_path box
    r _acq_msb_ssh_key_ensure
    r _acq_msb_fetch_kit "git+https://example.invalid/kits.git#ref=abc&dir=k"
    r _acq_msb_stage_startup_script "$ERRF.none.yaml" flags
    port=$(_acq_msb_pick_ephemeral_port) && echo "port=$port"
    r _acq_sbx_translate_kit "git+https://example.invalid/kits.git#ref=abc&dir=k"
    r _acq_sbx_startup_barrier_kit tok
    GIT_AUTHOR_NAME=n GIT_AUTHOR_EMAIL=e@x r _acq_sbx_git_identity_kit
    r _acq_secret_index_add acq.usai
  ' _ "$REPO_ROOT"
  assert_success
  assert_line '_acq_msb_clone_cleanup rc=1 acq: refusing to use the scratch clones dir: its directory could not be resolved to an absolute path'
  assert_line '_acq_msb_clone_warn_unfetched rc=0 '
  assert_line '_acq_msb_ports_pidfile rc=1 acq: refusing to use the ports state dir: its directory could not be resolved to an absolute path'
  assert_line '_acq_msb_ssh_agent_link_path rc=1 '
  assert_line '_acq_msb_ssh_key_ensure rc=1 acq: refusing to use the acq-managed ssh key dir: its directory could not be resolved to an absolute path'
  assert_line '_acq_msb_fetch_kit rc=1 acq: refusing to use the msb kit cache: its directory could not be resolved to an absolute path'
  assert_line '_acq_msb_stage_startup_script rc=0 acq: refusing to use the startup staging dir: its directory could not be resolved to an absolute path'
  assert_line --regexp '^port=[0-9]+$'
  assert_line '_acq_sbx_translate_kit rc=1 acq: refusing to use the sbx kit cache: its directory could not be resolved to an absolute path'
  assert_line '_acq_sbx_startup_barrier_kit rc=1 acq: refusing to use the sbx kit cache: its directory could not be resolved to an absolute path'
  assert_line '_acq_sbx_git_identity_kit rc=1 acq: refusing to use the sbx kit cache: its directory could not be resolved to an absolute path'
  assert_line '_acq_secret_index_add rc=0 '
  _assert_work_empty
}

@test "no home: macOS upstream-CA auto-detect skips instead of writing under the cwd" {
  _plant_unknown_account
  cat >"$STUBDIR/uname" <<'STUB'
#!/bin/sh
echo Darwin
STUB
  cat >"$STUBDIR/security" <<'STUB'
#!/bin/sh
echo "security $*" >> "$CALLS"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n'
STUB
  chmod +x "$STUBDIR/uname" "$STUBDIR/security"
  local -a e=()
  while IFS= read -r l; do e+=("$l"); done < <(_no_home_env)
  run env -u ACQ_MSB_NO_UPSTREAM_CA -u ACQ_MSB_UPSTREAM_CA_CERT "${e[@]}" ACQ_MSB_UPSTREAM_CA_AUTODETECT=1 bash -c '
    . "$1/acq.backends/msb.sh"
    flags=()
    _acq_msb_upstream_ca_flags_into flags
    printf "flags=[%s]\n" "${flags[*]-}"
  ' _ "$REPO_ROOT"
  assert_success
  assert_output 'flags=[]'
  # It stops before staging a temp bundle (dirname "" would be the cwd).
  run cat "$CALLS"
  refute_output --partial 'security find-certificate'
  _assert_work_empty
}

@test "cli: doctor is not refused; it reports the bad state dir as a failed check and completes" {
  run env ACQ_STATE_DIR=rel-state ACQ_BACKEND=msb "$ACQ" doctor </dev/null
  assert_success
  assert_line 'acq: backend health check'
  assert_line "  [fail] state: ACQ_STATE_DIR must be an absolute path, got 'rel-state'"
  assert_line '           set ACQ_STATE_DIR to an absolute path, or unset it to use $XDG_STATE_HOME/acq (default ~/.local/state/acq)'
  refute_output --partial 'as the default backend'
  run env ACQ_STATE_DIR=rel-state ACQ_BACKEND=msb "$ACQ" doctor somebox
  assert_failure 1
  assert_line --index 0 "acq: ACQ_STATE_DIR must be an absolute path, got 'rel-state'"
  refute_line --partial 'no such sandbox'
  _assert_work_empty
}

@test "cli: every dispatch arm is either checked or deliberately exempt from the user-dirs check" {
  local verbs verb kind
  verbs=$(awk '/^case "\$subcommand" in/{inb=1;next} inb&&/^esac/{inb=0} inb&&/^  [^ #][^)]*\)/{sub(/^  /,""); sub(/\).*/,""); print}' "$ACQ" \
    | tr '|' '\n' | sort -u)
  [ -n "$verbs" ] || fail "no dispatch arms found in $ACQ"
  # shellcheck disable=SC1090  # the acq entry point, sourced for its verb table
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  for verb in $verbs; do
    case "$verb" in
      # Exempt on purpose: no acq state, or (doctor) reports instead of refusing;
      # backend and configure are checked by their own arms of the entry check.
      '""'|'*'|-*|help|version|doctor|backend|configure) continue ;;
    esac
    kind=$(_acq_verb_backend_help_kind "$verb")
    [ -n "$kind" ] || fail "dispatch arm '$verb' is not classified by _acq_verb_backend_help_kind, so the user-dirs entry check skips it"
  done
}
