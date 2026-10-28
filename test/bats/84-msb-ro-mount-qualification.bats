#!/usr/bin/env bats
#
# 84-msb-ro-mount-qualification.bats — ADR-0035 Mechanism 2 authority. Trusted
# execution from the read-only host-config mount is permitted only on an msb version
# that appears on a checked-in list of versions a HOST-observed canary has qualified.
# A guest-run probe can never unlock it (a guest with root controls `sh`/`test`).
# Also covers scripts/qualify-msb-ro-mount against a stubbed msb.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

_ro_kit() { # DIR
  local k="$1"; mkdir -p "$k/files"
  printf 'console.log("merge");\n' > "$k/files/merge.mjs"
  cat >"$k/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: ro-code-kit
displayName: RO Code Kit
description: trusted startup code
files:
  - path: /home/agent/cfg/merge.mjs
    mode: "0755"
    source: files/merge.mjs
    readonly: true
commands:
  - phase: startup
    user: "1000"
    command:
      - node
      - /home/agent/cfg/merge.mjs
SPEC
}

# Apply KITDIR to NAME with a host ro-host-config record, under an msb version and
# qualified list. The probe stub is left in its default state: it forges "all good".
_apply_ver() { # NAME KITDIR VERSION QUALIFIED_LIST
  local name="$1" kit="$2" ver="$3" qual="$4"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-'"$name"'" STUB_MSB_VERSION="'"$ver"'"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    MSB_RO_MOUNT_QUALIFIED_VERSIONS="'"$qual"'"
    acq_host_config_write msb "'"$name"'" ro-host-config 1
    _acq_msb_apply_kit_dir "'"$name"'" "'"$kit"'" 2>&1
  '
}

@test "qualified list: ships empty, so no msb version is trusted for readonly code today" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; printf "[%s]\n" "$MSB_RO_MOUNT_QUALIFIED_VERSIONS"'
  assert_success
  assert_output '[]'
}

@test "qualified list: a forged zero-exit probe does not unlock staging on an unlisted version" {
  local k="$STUBDIR/k1"; _ro_kit "$k"
  _apply_ver unlisted "$k" 0.7.7 ""
  assert_failure
  assert_output --partial "'/home/agent/cfg/merge.mjs'"
  assert_output --partial 'msb 0.7.7 is not on acq'
  assert_output --partial 'scripts/qualify-msb-ro-mount'
  assert_output --partial 'No guest-copy fallback is taken'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'node '
  refute_regex "$log" 'msb copy .*unlisted:/home/agent/cfg/merge\.mjs'
  run bash -c 'ls "'"$ACQ_PROVENANCE_DIR"'"/msb/unlisted.*.config/kit-files 2>&1'
  assert_failure
}

@test "qualified list: a version that is not the listed one is refused" {
  local k="$STUBDIR/k2"; _ro_kit "$k"
  _apply_ver otherver "$k" 0.7.8 "0.7.7"
  assert_failure
  assert_output --partial 'msb 0.7.8 is not on acq'
}

@test "qualified list: a listed version stages and runs from the mount" {
  local k="$STUBDIR/k3"; _ro_kit "$k"
  _apply_ver listed "$k" 0.7.7 "0.7.7"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'node /var/lib/acq/host/kit-files/'
  refute_regex "$log" 'msb copy .*listed:/home/agent/cfg/merge\.mjs'
}

@test "qualified list: a listed version is still refused when the guest says the mount is writable" {
  local k="$STUBDIR/k4"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-lw" STUB_MSB_VERSION=0.7.7 STUB_HOST_CONFIG_WRITABLE=1
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    MSB_RO_MOUNT_QUALIFIED_VERSIONS="0.7.7"
    acq_host_config_write msb listedwritable ro-host-config 1
    _acq_msb_apply_kit_dir listedwritable "'"$k"'" 2>&1
  '
  assert_failure
  assert_output --partial 'WRITABLE'
  refute_regex "$(cat "$CALLS")" 'node '
}

@test "qualified list: an unparsable or prerelease msb version fails closed even if listed" {
  local k="$STUBDIR/k5"; _ro_kit "$k"
  _apply_ver prerel "$k" 0.7.7-rc1 "0.7.7 0.7.7-rc1"
  assert_failure
  assert_output --partial 'not on acq'
  refute_regex "$(cat "$CALLS")" 'node '
  _apply_ver garbled "$k" "banana" "banana"
  assert_failure
  refute_regex "$(cat "$CALLS")" 'node '
}

@test "qualified list: no host record keeps the guest-copy compatibility path regardless of version" {
  local k="$STUBDIR/k6"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-nr" STUB_MSB_VERSION=0.7.7
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_apply_kit_dir norecordver "'"$k"'" 2>&1
  '
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb copy .*norecordver:/home/agent/cfg/merge\.mjs'
}

@test "qualified list: the create-time startup script keeps the guest path when the version is unlisted" {
  local k="$STUBDIR/k7"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-ss" STUB_MSB_VERSION=0.7.7
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/ss-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    MSB_RO_MOUNT_QUALIFIED_VERSIONS=""
    _acq_msb_fetch_kit() { printf "%s\n" "'"$k"'"; }
    acq_backend_provision stagebox shell /tmp >/dev/null 2>&1
  '
  local body; body=$(cat "$(find "$STUBDIR/ss-stage" -type f 2>/dev/null | head -n1)" 2>/dev/null)
  [ -n "$body" ]
  assert_regex "$body" '/home/agent/cfg/merge\.mjs'
  refute_regex "$body" '/var/lib/acq/host/kit-files'
}

# --- scripts/qualify-msb-ro-mount against a stubbed msb --------------------------

# Stub msb for the canary. STUB_RO_ENFORCED=1: attempts are denied on the ro volume.
# STUB_RO_ENFORCED=0: the "guest" really writes into the host directory behind the ro
# volume and reports WROTE. STUB_QUAL_FORGE_DENIED=1 (with ENFORCED=0): the guest lies
# and reports DENIED while changing the host directory. STUB_QUAL_NO_LOG=1: the guest
# never writes its log (positive control fails).
_plant_canary_msb() {
  mkdir -p "$STUBDIR/canary-bin"
  cat >"$STUBDIR/canary-bin/msb" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-V) printf 'msb %s\n' "${STUB_MSB_VERSION:-0.7.7}"; exit 0 ;;
  create)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --volume) case "$2" in
                    *:/mnt/qual-ro:ro) printf '%s\n' "${2%%:/mnt/qual-ro:ro}" >"$STUBDIR/.qual_ro" ;;
                    *:/mnt/qual-rw) printf '%s\n' "${2%%:/mnt/qual-rw}" >"$STUBDIR/.qual_rw" ;;
                  esac; shift ;;
      esac
      shift
    done
    exit 0 ;;
  remove) : >"$STUBDIR/.qual_removed"; exit 0 ;;
  exec)
    all="$*"
    case "$all" in
      *"echo ok"*) echo ok; exit 0 ;;
      *"qual-ro"*)
        ro=$(cat "$STUBDIR/.qual_ro"); rw=$(cat "$STUBDIR/.qual_rw")
        [ "${STUB_QUAL_NO_LOG:-0}" = 1 ] && exit 0
        {
          echo "uid=${STUB_QUAL_UID:-0}"; echo "READ-OK"
          [ "${STUB_QUAL_CONTROL_BROKEN:-0}" = 1 ] && echo "CONTROL-BROKEN" || echo "CONTROL-OK"
          echo "MOUNT-BEFORE ro: tmpfs /mnt/qual-ro virtiofs ro 0 0"
        } >"$rw/attempts.log"
        # Remount attempts are informational. STUB_QUAL_REMOUNT=accepted models the
        # guest kernel accepting `mount -o remount,rw` (exit 0), which is not a write.
        if [ "${STUB_QUAL_REMOUNT:-denied}" = accepted ]; then
          { echo "REMOUNT-ACCEPTED remount-rw"; echo "REMOUNT-ACCEPTED remount-bind"; } >>"$rw/attempts.log"
          echo "MOUNT-AFTER ro: tmpfs /mnt/qual-ro virtiofs rw 0 0" >>"$rw/attempts.log"
        else
          { echo "REMOUNT-DENIED remount-rw"; echo "REMOUNT-DENIED remount-bind"; } >>"$rw/attempts.log"
          echo "MOUNT-AFTER ro: tmpfs /mnt/qual-ro virtiofs ro 0 0" >>"$rw/attempts.log"
        fi
        if [ "${STUB_RO_ENFORCED:-1}" = 1 ]; then
          echo "DENIED create-file" >>"$rw/attempts.log"
          echo "DENIED create-after-remount" >>"$rw/attempts.log"
        else
          : >"$ro/qual-new-file"
          if [ "${STUB_QUAL_FORGE_DENIED:-0}" = 1 ]; then echo "DENIED create-file" >>"$rw/attempts.log"
          else echo "WROTE create-file" >>"$rw/attempts.log"; fi
        fi
        # STUB_QUAL_REPORT_WROTE=1 with an enforced mount: the guest REPORTS a data write
        # but the host directory is untouched (a lying or mistaken guest).
        [ "${STUB_QUAL_REPORT_WROTE:-0}" = 1 ] && echo "WROTE overwrite" >>"$rw/attempts.log"
        echo "READ-AFTER-OK" >>"$rw/attempts.log"
        echo "DONE" >>"$rw/attempts.log"
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUBDIR/canary-bin/msb"
}

_run_canary() { # [ENV...]
  run env "$@" PATH="$STUBDIR/canary-bin:$PATH" STUBDIR="$STUBDIR" ACQ_QUALIFY_OUT_DIR="$STUBDIR/qout" \
    STEP_TIMEOUT=20 EXEC_TIMEOUT=20 bash "$REPO_ROOT/scripts/qualify-msb-ro-mount"
}

@test "canary: host directory unchanged and controls seen => PASS" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_MSB_VERSION=0.7.7
  assert_success
  assert_output --partial 'RESULT: PASS'
  assert_output --partial 'msb version : 0.7.7'
  assert_output --partial 'MSB_RO_MOUNT_QUALIFIED_VERSIONS'
  [ -f "$STUBDIR/.qual_removed" ]
}

@test "canary: host directory changed => FAIL, even if the guest claims every write was denied" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=0 STUB_QUAL_FORGE_DENIED=1
  assert_failure 1
  assert_output --partial 'RESULT: FAIL'
  assert_output --partial 'host directory behind the :ro volume was modified'
  refute_output --partial 'Next: add'
  [ -f "$STUBDIR/.qual_removed" ]
}

@test "canary: guest reports it wrote to the mount => FAIL" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=0
  assert_failure 1
  assert_output --partial 'RESULT: FAIL'
}

@test "canary: no positive control from the guest => BLOCKED, not PASS" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_QUAL_NO_LOG=1
  assert_failure 2
  assert_output --partial 'RESULT: BLOCKED'
  assert_output --partial 'positive control failed'
}

@test "canary: msb missing => BLOCKED" {
  run env PATH="/usr/bin:/bin" ACQ_QUALIFY_OUT_DIR="$STUBDIR/qout2" bash -c 'command -v msb >/dev/null 2>&1 && exit 77; exec bash "'"$REPO_ROOT"'/scripts/qualify-msb-ro-mount"'
  [ "$status" -eq 77 ] && skip "a real msb is on the minimal PATH"
  assert_failure 2
  assert_output --partial 'RESULT: BLOCKED'
}

@test "canary: EXPECT_SHA that does not match the checkout => BLOCKED" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 EXPECT_SHA=deadbeefdeadbeef
  assert_failure 2
  assert_output --partial 'does not match EXPECT_SHA'
}

@test "canary: attempts that did not run as root => BLOCKED, not PASS" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_QUAL_UID=1000
  assert_failure 2
  assert_output --partial 'RESULT: BLOCKED'
  assert_output --partial 'did not run as root'
}

@test "canary: the same operations failing on the read-write control volume => BLOCKED" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_QUAL_CONTROL_BROKEN=1
  assert_failure 2
  assert_output --partial 'RESULT: BLOCKED'
  assert_output --partial 'read-write control volume'
}

@test "canary: a failed create still attempts to remove the sandbox" {
  _plant_canary_msb
  sed -i.bak 's|^  create)|  create) [ "${STUB_CREATE_FAIL:-0}" = 1 ] \&\& exit 1|' "$STUBDIR/canary-bin/msb"
  _run_canary STUB_CREATE_FAIL=1
  assert_failure 2
  assert_output --partial 'msb create failed'
  [ -f "$STUBDIR/.qual_removed" ]
}

@test "canary: a PASS on a non-final msb version tells the operator not to add it" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_MSB_VERSION=0.7.7-rc1
  assert_success
  assert_output --partial 'RESULT: PASS'
  assert_output --partial 'do NOT add it to the list'
  refute_output --partial 'Next: add'
}

# --- remount classification, verdict order and evidence layout -------------------

@test "canary: an ACCEPTED remount with every data write denied and the host unchanged => PASS" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_QUAL_REMOUNT=accepted
  assert_success
  assert_output --partial 'RESULT: PASS'
  assert_output --partial 'a remount was ACCEPTED'
  assert_output --partial 'every data write the guest attempted was denied'
  assert_output --partial '2 remount attempt(s) accepted, which is informational'
  refute_output --partial 'WROTE remount'
}

@test "canary: a data write reported WROTE with the host unchanged => FAIL" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_QUAL_REPORT_WROTE=1
  assert_failure 1
  assert_output --partial 'RESULT: FAIL'
  assert_output --partial 'the guest was able to write to the :ro mount'
}

@test "canary: host directory changed while the guest log says all denied => FAIL from the host snapshot" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=0 STUB_QUAL_FORGE_DENIED=1 STUB_QUAL_REMOUNT=accepted
  assert_failure 1
  assert_output --partial 'RESULT: FAIL'
  assert_output --partial 'even though the guest reported every write denied'
  assert_output --partial '--- host directory changed ---'
}

@test "canary: the guest script classifies remount separately from data writes (not a WROTE)" {
  run grep -n 'rtry remount-rw\|rtry remount-bind' "$REPO_ROOT/scripts/qualify-msb-ro-mount"
  assert_success
  run grep -n '^try remount' "$REPO_ROOT/scripts/qualify-msb-ro-mount"
  assert_failure
}

@test "canary: all output lands under the output directory, one pasteable line is printed" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1
  assert_success
  assert_output --partial "dir=$STUBDIR/qout"
  assert_regex "$output" 'RESULT PASS msb=0\.7\.7 image=[^ ]+ host=[^ ]+ [^ ]* ?rev='
  [ -f "$STUBDIR/qout/results.tsv" ]
  [ -f "$STUBDIR/qout/attempts.log" ]
  [ -f "$STUBDIR/qout/before.snapshot" ]
  [ -f "$STUBDIR/qout/after.snapshot" ]
  [ -f "$STUBDIR/qout/verdict.txt" ]
  grep -q 'MOUNT-BEFORE ro:' "$STUBDIR/qout/attempts.log"
  grep -q 'MOUNT-AFTER ro:' "$STUBDIR/qout/attempts.log"
  # PASS removes the throwaway host directories; the evidence stays.
  [ ! -d "$STUBDIR/qout/ro" ]
  [ ! -d "$STUBDIR/qout/rw" ]
}

@test "canary: FAIL and BLOCKED keep the throwaway host directories as evidence" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=0
  assert_failure 1
  [ -d "$STUBDIR/qout/ro" ]
  [ -f "$STUBDIR/qout/ro/qual-new-file" ]
  [ -f "$STUBDIR/qout/host.diff" ]
  assert_output --partial 'RESULT FAIL'
}

@test "canary: the default output directory is under the repo tmp/, which is gitignored" {
  run grep -n 'qualify-msb-ro-mount-\$STAMP' "$REPO_ROOT/scripts/qualify-msb-ro-mount"
  assert_success
  run git -C "$REPO_ROOT" check-ignore -q tmp/qualify-msb-ro-mount-x/results.tsv
  [ "$status" -eq 0 ] || skip "not a git checkout, or tmp/ not ignored here"
}
