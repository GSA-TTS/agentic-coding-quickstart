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

@test "msys: an ACQ_MSB_WORKSPACE override is canonicalized to the guest form" {
  _plant_cygpath_stub
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_MSB_WORKSPACE="C:/Users/me/proj"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    printf "ws=%s\n" "$(_acq_msb_workspace_for somebox)"
  '
  assert_success
  assert_output 'ws=/c/Users/me/proj'
}

@test "msys: the run path passes the guest form of ACQ_MSB_WORKSPACE to -w" {
  _plant_cygpath_stub
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_MSB_WORKSPACE="C:/Users/me/proj"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run somebox true >/dev/null 2>&1 || true
    grep -o -- "-w [^ ]*" "'"$CALLS"'" | tail -n1
  '
  assert_success
  assert_output '-w /c/Users/me/proj'
}

@test "msys: msb copy gets the host form for its SRC and keeps the guest DST" {
  _plant_cygpath_stub
  mkdir -p "$STUBDIR/copy"
  printf 'payload\n' >"$STUBDIR/copy/f.txt"
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_copy_file_verified somebox "'"$STUBDIR"'/copy/f.txt" /home/agent/f.txt 0600 >/dev/null 2>&1 || true
    got=$(grep -o -- "copy [^ ]* [^ ]*" "'"$CALLS"'" | tail -n1)
    src="${got#copy }"; src="${src% *}"
    host=$(host_path "'"$STUBDIR"'/copy/f.txt")
    [ "$src" = "$host" ] && echo "src-host-form-ok" || echo "bad-src: $got"
    [ "$host" != "'"$STUBDIR"'/copy/f.txt" ] && echo "forms-differ" || echo "forms-same"
    grep -q -- "somebox:/home/agent/f.txt" "'"$CALLS"'" && echo "dst-guest-form-ok"
  '
  assert_output --partial 'src-host-form-ok'
  assert_output --partial 'forms-differ'
  assert_output --partial 'dst-guest-form-ok'
}

@test "msys: ssh authorize --file gets the host form of the public key" {
  _plant_cygpath_stub
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ACQ_MSB_SSH_KEY="'"$STUBDIR"'/state/ssh/msb_id_ed25519"
    _acq_msb_ssh_authorize >/dev/null 2>&1
    got=$(grep -o -- "--file [^ ]*" "'"$CALLS"'" | tail -n1)
    host=$(host_path "$ACQ_MSB_SSH_KEY.pub")
    [ "$got" = "--file $host" ] && echo "host-form-ok" || echo "bad: $got"
    [ "$host" != "$ACQ_MSB_SSH_KEY.pub" ] && echo "forms-differ" || echo "forms-same"
  '
  assert_output --partial 'host-form-ok'
  assert_output --partial 'forms-differ'
}

@test "msys: --tls-upstream-ca-cert gets the host form of the PEM" {
  _plant_cygpath_stub
  printf '%s\n' '-----BEGIN CERTIFICATE-----' >"$STUBDIR/ca.pem"
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_MSB_UPSTREAM_CA_CERT="'"$STUBDIR"'/ca.pem"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    arr=()
    _acq_msb_upstream_ca_flags_into arr
    got="${arr[*]}"
    host=$(host_path "'"$STUBDIR"'/ca.pem")
    [ "$got" = "--tls-upstream-ca-cert $host" ] && echo "host-form-ok" || echo "bad: $got"
    [ "$host" != "'"$STUBDIR"'/ca.pem" ] && echo "forms-differ" || echo "forms-same"
  '
  assert_output --partial 'host-form-ok'
  assert_output --partial 'forms-differ'
}

@test "msys: --vsock gets the host form of the socket" {
  _plant_cygpath_stub
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_host_socket_forwards() { printf "%s\t%s\t%s\t%s\n" "'"$STUBDIR"'/agent.sock" 3552 stream ssh-agent; }
    arr=()
    _acq_msb_vsock_flags_into arr
    got="${arr[*]}"
    host=$(host_path "'"$STUBDIR"'/agent.sock")
    [ "$got" = "--vsock $host:3552/stream" ] && echo "host-form-ok" || echo "bad: $got"
    [ "$host" != "'"$STUBDIR"'/agent.sock" ] && echo "forms-differ" || echo "forms-same"
  '
  assert_output --partial 'host-form-ok'
  assert_output --partial 'forms-differ'
}

@test "msys: --script-path gets the host form of the staged script" {
  _plant_cygpath_stub
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/stage"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_generate_startup_script() { printf "#!/bin/sh\n" > "$2"; return 0; }
    arr=()
    _acq_msb_stage_startup_script spec arr
    got="${arr[*]}"
    hostd=$(host_path "'"$STUBDIR"'/stage")
    case "$got" in "--script-path acq-startup:$hostd/"*) echo "host-dir-ok" ;; *) echo "bad: $got" ;; esac
    [ "$hostd" != "'"$STUBDIR"'/stage" ] && echo "forms-differ" || echo "forms-same"
  '
  assert_output --partial 'host-dir-ok'
  assert_output --partial 'forms-differ'
}

@test "msys: snapshot output and restore archive paths get the host form" {
  _plant_cygpath_stub
  : > "$STUBDIR/saved.msb"
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_snapshot somebox "'"$STUBDIR"'/saved.msb" >/dev/null 2>&1
    acq_backend_restore "'"$STUBDIR"'/saved.msb" --name restored >/dev/null 2>&1 || true
    host=$(host_path "'"$STUBDIR"'/saved.msb")
    grep -q -- "-o $host" "'"$CALLS"'" && echo "snapshot-host-form-ok"
    grep -q -- "restore $host --name restored" "'"$CALLS"'" && echo "restore-host-form-ok"
    [ "$host" != "'"$STUBDIR"'/saved.msb" ] && echo "forms-differ" || echo "forms-same"
  '
  assert_output --partial 'snapshot-host-form-ok'
  assert_output --partial 'restore-host-form-ok'
  assert_output --partial 'forms-differ'
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
