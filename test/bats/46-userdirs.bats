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

# A stub `id` naming an account the password database does not know, so the
# account-home fallback finds nothing and only HOME could supply a home.
_plant_unknown_account() {
  cat >"$STUBDIR/id" <<'IDSTUB'
#!/bin/sh
echo acq-no-such-account-46
IDSTUB
  chmod +x "$STUBDIR/id"
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
  want=$(bash -c 'eval "printf %s ~$(id -un)"')
  run env HOME=relhome bash -c '. "$1/acq.backends/userdirs.sh"; acq_home_dir' _ "$REPO_ROOT"
  assert_success
  assert_output "$want"
  case "$output" in /*) ;; *) fail "home is not absolute: $output" ;; esac
}

@test "userdirs: no absolute home fails closed with the Python message" {
  _plant_unknown_account
  run env HOME=relhome XDG_STATE_HOME=rel bash -c '
    . "$1/acq.backends/userdirs.sh"
    acq_home_dir && echo "home resolved"
    acq_xdg_dir XDG_STATE_HOME .local/state && echo "xdg resolved"
    acq_userdirs_check
  ' _ "$REPO_ROOT"
  assert_failure
  refute_line 'home resolved'
  refute_line 'xdg resolved'
  assert_line "acq: cannot determine an absolute home directory (HOME is 'relhome')"
  assert_line 'set HOME to an absolute path, or set the XDG base directory variables (XDG_STATE_HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME) to absolute paths'
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
