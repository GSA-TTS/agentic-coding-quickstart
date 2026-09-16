#!/usr/bin/env bats
#
# 117-msys-path-forms.bats — host-form vs guest-form path boundary (ADR-0029)
#
# Under MSYS/Cygwin acq must hand msb TWO different forms of a workspace path:
# the native HOST form for the mount source / copied file / host socket
# (host_path → C:/...), and the POSIX GUEST form for the mount target, the
# start dir, and the ACQ_WORKSPACE env (canonicalize_path → /c/...). A single
# value for both is the GSA-TTS/agentic-coding-quickstart#463 regression.
#
# MSYS is simulated with a fake `cygpath` (STUBDIR is prepended to PATH) that
# implements a stable, invertible POSIX<->drive bijection, so these assertions
# run on any POSIX CI host. `MSYS2_ARG_CONV_EXCL=*` is separately asserted on
# the msb boundary, since the real argv rewrite only happens on MSYS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# The single logged `msb create` line from the stub call log.
_create_line() { printf '%s\n' "$(cat "$CALLS")" | grep "^$1 create"; }

# Minimal cygpath: -u maps a drive form to POSIX, -m maps an absolute POSIX path
# to C: drive form. Distinct and invertible, which is all the split needs.
_plant_cygpath_stub() {
  cat >"$STUBDIR/cygpath" <<'CYGSTUB'
#!/usr/bin/env bash
mode="${1:-}"; shift || true
case "$mode" in
  -u)
    for p in "$@"; do
      case "$p" in
        [A-Za-z]:/*) d=$(printf '%s' "${p%%:*}" | tr 'A-Z' 'a-z'); printf '/%s%s\n' "$d" "${p#*:}" ;;
        *) printf '%s\n' "$p" ;;
      esac
    done ;;
  -m)
    for p in "$@"; do
      case "$p" in
        /?/*) d=$(printf '%s' "$p" | cut -c2 | tr 'a-z' 'A-Z')
              case "$d" in
                [A-Z]) printf '%s:%s\n' "$d" "${p#/?}" ;;
                *) printf 'C:%s\n' "$p" ;;
              esac ;;
        /*) printf 'C:%s\n' "$p" ;;
        *) printf '%s\n' "$p" ;;
      esac
    done ;;
  *) exit 0 ;;
esac
CYGSTUB
  chmod +x "$STUBDIR/cygpath"
}

# Provision on msb with a pinned workspace, isolated in a subshell (as in 71b).
_msys_provision() { # NAME WS
  local name="$1" ws="$2"
  run bash -c '
    name="$1"; ws="$2"
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/msys-secrets"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_provision "$name" opencode "$ws" 2>&1
  ' _ "$name" "$ws"
}

@test "msys: canonicalize_path is the guest (POSIX) form and host_path the native host form" {
  _plant_cygpath_stub
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    printf "guest=%s\nhost=%s\n" "$(canonicalize_path "C:/Users/me/proj")" "$(host_path "/c/Users/me/proj")"
  '
  assert_success
  assert_line 'guest=/c/Users/me/proj'
  assert_line 'host=C:/Users/me/proj'
}

@test "msys: a mount uses the host form for SOURCE and the guest form for TARGET" {
  _plant_cygpath_stub
  mkdir -p "$STUBDIR/msysws"
  _msys_provision msysbox "$STUBDIR/msysws"
  load_acq
  local guest host line
  guest=$(canonicalize_path "$STUBDIR/msysws")
  host=$(host_path "$STUBDIR/msysws")
  line=$(_create_line msb)

  # The two forms must actually differ here, or the assertion proves nothing.
  [ "$host" != "$guest" ]
  assert_regex "$line" "--volume ${host}:${guest}( |\$)"
  # The regression was a drive-form path reaching the GUEST.
  refute_regex "$line" "--volume ${host}:${host}"
  # ACQ_WORKSPACE is a guest-side value: it must stay POSIX.
  assert_regex "$line" "--env ACQ_WORKSPACE=${guest}( |\$)"
  refute_regex "$line" "ACQ_WORKSPACE=${host}( |\$)"
}

@test "msys: msb is invoked with MSYS argument rewriting disabled" {
  cat >"$STUBDIR/msb" <<'MSBENVSTUB'
#!/usr/bin/env bash
printf 'EXCL=%s\n' "${MSYS2_ARG_CONV_EXCL:-unset}"
MSBENVSTUB
  chmod +x "$STUBDIR/msb"
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_cli --version
  '
  assert_success
  assert_output 'EXCL=*'
}
