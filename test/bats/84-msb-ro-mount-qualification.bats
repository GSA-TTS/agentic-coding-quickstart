#!/usr/bin/env bats
#
# 84-msb-ro-mount-qualification.bats — ADR-0035 Mechanism 2 authority. Trusted
# execution from the read-only host-config mount is permitted only when ALL hold:
# a host ro-host-config record exists; the msb version is a final release at or above
# a floor; and msb's own `inspect` record (read from the host, not the guest) shows
# the host-config mount as the one read-only Bind of acq's host config directory with
# no overlapping writable mount. A guest-run probe can never unlock it (a guest with
# root controls `sh`/`test`); it can only add refusals.
#
# Deliberate replacement: the earlier per-version allowlist
# (MSB_RO_MOUNT_QUALIFIED_VERSIONS) and the cases that pinned it were replaced by the
# cases below. Also covers scripts/qualify-msb-ro-mount (now an optional,
# non-gating verification tool) against a stubbed msb.
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

# Apply KITDIR to NAME with a host ro-host-config record. Environment (KEY=VAL ...)
# follows the positional args. Defaults: msb 0.7.7 and an inspect record showing the
# host-config mount as the read-only Bind. The guest probe stub is left in its default
# state, which forges "all good" (present and not writable).
_gate() { # NAME KITDIR [ENV...]
  local name="$1" kit="$2"; shift 2
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-'"$name"'"
    export STUB_MSB_VERSION=0.7.7 STUB_MSB_INSPECT_MODE=ro-ok ACQ_MSB_RO_INSPECT_RETRY_SLEEP=0
    for kv in '"${*:-:}"'; do export "$kv" 2>/dev/null || true; done
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    acq_host_config_write msb "'"$name"'" ro-host-config 1
    _acq_msb_apply_kit_dir "'"$name"'" "'"$kit"'" 2>&1
  '
}

_assert_refused() { # NAME [MESSAGE_FRAGMENT]
  assert_failure
  assert_output --partial "'/home/agent/cfg/merge.mjs'"
  assert_output --partial 'No guest-copy fallback is taken'
  [ -z "${2:-}" ] || assert_output --partial "$2"
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'node '
  refute_regex "$log" "msb copy .*$1:/home/agent/cfg/merge\\.mjs"
  run bash -c 'ls "'"$ACQ_PROVENANCE_DIR"'"/msb/'"$1"'.*.config/kit-files 2>&1'
  assert_failure
}

@test "gate: the version floor is 0.7.7 and no per-version allowlist remains" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh"; printf "[%s]\n" "$MSB_RO_MOUNT_MIN_VERSION"; printf "[%s]\n" "${MSB_RO_MOUNT_QUALIFIED_VERSIONS-unset}"'
  assert_success
  assert_line '[0.7.7]'
  assert_line '[unset]'
}

@test "gate: record + msb recorded ro Bind of the host config dir + floor version => unlocks staging" {
  local k="$STUBDIR/g1"; _ro_kit "$k"
  _gate unlocks "$k"
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb inspect unlocks --format json'
  assert_regex "$log" 'node /var/lib/acq/host/kit-files/'
  refute_regex "$log" 'msb copy .*unlocks:/home/agent/cfg/merge\.mjs'
}

@test "gate: a version above the floor unlocks too" {
  local k="$STUBDIR/g2"; _ro_kit "$k"
  _gate newer "$k" STUB_MSB_VERSION=0.7.9
  assert_success
  assert_regex "$(cat "$CALLS")" 'node /var/lib/acq/host/kit-files/'
}

@test "gate: a forged all-clear guest probe does not help when msb records the mount as NOT read-only" {
  local k="$STUBDIR/g3"; _ro_kit "$k"
  _gate rwrecorded "$k" STUB_MSB_INSPECT_MODE=rw
  _assert_refused rwrecorded 'does not record the mount'
}

@test "gate: no host-config mount in msb's record => refused" {
  local k="$STUBDIR/g4"; _ro_kit "$k"
  _gate nomount "$k" STUB_MSB_INSPECT_MODE=missing
  _assert_refused nomount 'lists no mount at /var/lib/acq/host'
}

@test "gate: two mounts at the host-config guest path => refused" {
  local k="$STUBDIR/g5"; _ro_kit "$k"
  _gate dupmount "$k" STUB_MSB_INSPECT_MODE=dup
  _assert_refused dupmount 'more than one mount'
}

@test "gate: a writable mount overlapping the host-config guest path => refused" {
  local k="$STUBDIR/g6"; _ro_kit "$k"
  _gate overlap "$k" STUB_MSB_INSPECT_MODE=overlap-rw
  _assert_refused overlap 'overlaps'
}

@test "gate: a read-only mount backed by some other host directory => refused" {
  local k="$STUBDIR/g7"; _ro_kit "$k"
  _gate wronghost "$k" STUB_MSB_INSPECT_MODE=wrong-host
  _assert_refused wronghost "not backed by this sandbox's acq host config directory"
}

@test "gate: a mount that is not a Bind mount => refused" {
  local k="$STUBDIR/g8"; _ro_kit "$k"
  _gate notbind "$k" STUB_MSB_INSPECT_MODE=not-bind
  _assert_refused notbind 'not a Bind mount'
}

@test "gate: active_config null (after the short retry) => refused, naming the cause" {
  local k="$STUBDIR/g9"; _ro_kit "$k"
  _gate nullcfg "$k" STUB_MSB_INSPECT_MODE=null
  _assert_refused nullcfg 'active_config is null'
}

@test "gate: active_config null at first, populated on a retry => unlocks" {
  local k="$STUBDIR/g10"; _ro_kit "$k"
  _gate nullthenok "$k" STUB_MSB_INSPECT_NULL_TIMES=1
  assert_success
  assert_regex "$(cat "$CALLS")" 'node /var/lib/acq/host/kit-files/'
}

@test "gate: msb inspect failing => refused" {
  local k="$STUBDIR/g11"; _ro_kit "$k"
  rm -f "$STUBDIR/.msb_inspect_fails"
  _gate inspectfail "$k" STUB_MSB_INSPECT_FAIL_TIMES=99
  _assert_refused inspectfail "'msb inspect' failed"
}

@test "gate: unparsable inspect output => refused" {
  local k="$STUBDIR/g12"; _ro_kit "$k"
  _gate badjson "$k" STUB_MSB_INSPECT_MODE=badjson
  _assert_refused badjson 'not valid JSON'
}

@test "gate: unexpected mounts shape => refused" {
  local k="$STUBDIR/g13"; _ro_kit "$k"
  _gate noshape "$k" STUB_MSB_INSPECT_MODE=noshape
  _assert_refused noshape 'no mounts list'
}

@test "gate: without python3 the structured check cannot run => refused" {
  local k="$STUBDIR/g14"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-nopy" STUB_MSB_VERSION=0.7.7 STUB_MSB_INSPECT_MODE=ro-ok
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_ro_python() { return 1; }
    acq_host_config_write msb nopy ro-host-config 1
    _acq_msb_apply_kit_dir nopy "'"$k"'" 2>&1
  '
  _assert_refused nopy 'python3 is required'
}

@test "gate: an unreviewed platform (Windows msb backend) => refused" {
  local k="$STUBDIR/g15"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-win" STUB_MSB_VERSION=0.7.7 STUB_MSB_INSPECT_MODE=ro-ok
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    uname() { echo MINGW64_NT-10.0; }
    acq_host_config_write msb win ro-host-config 1
    _acq_msb_apply_kit_dir win "'"$k"'" 2>&1
  '
  _assert_refused win 'was not reviewed'
}

@test "gate: a version below the floor is refused" {
  local k="$STUBDIR/g16"; _ro_kit "$k"
  _gate old "$k" STUB_MSB_VERSION=0.7.6
  _assert_refused old 'below acq'"'"'s minimum'
  _gate older "$k" STUB_MSB_VERSION=0.6.9
  assert_failure
}

@test "gate: a prerelease or unparsable msb version is refused" {
  local k="$STUBDIR/g17"; _ro_kit "$k"
  _gate prerel "$k" STUB_MSB_VERSION=0.7.7-rc1
  assert_failure
  assert_output --partial 'below acq'
  refute_regex "$(cat "$CALLS")" 'node '
  _gate garbled "$k" STUB_MSB_VERSION=banana
  assert_failure
  refute_regex "$(cat "$CALLS")" 'node '
}

@test "gate: msb recording the mount read-only still fails closed when the guest probe says WRITABLE" {
  local k="$STUBDIR/g18"; _ro_kit "$k"
  _gate probewrit "$k" STUB_HOST_CONFIG_WRITABLE=1
  assert_failure
  assert_output --partial 'WRITABLE'
  refute_regex "$(cat "$CALLS")" 'node '
}

@test "gate: a kit with no readonly files never consults msb inspect or the probe" {
  local k="$STUBDIR/g0"; mkdir -p "$k/files"
  printf '{}\n' > "$k/files/data.jsonc"
  cat >"$k/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: plain-kit
displayName: Plain Kit
description: data only
files:
  - path: /home/agent/cfg/data.jsonc
    mode: "0644"
    source: files/data.jsonc
SPEC
  _gate plainkit "$k" STUB_MSB_INSPECT_MODE=rw STUB_HOST_CONFIG_WRITABLE=1
  assert_success
  refute_regex "$(cat "$CALLS")" 'msb inspect plainkit'
  refute_regex "$(cat "$CALLS")" 'acq-ro-probe'
  assert_regex "$(cat "$CALLS")" 'msb copy .*plainkit:/home/agent/cfg/data\.jsonc'
}

@test "gate: the inspect check normalizes guest paths (a writable mount at //var overlaps)" {
  command -v python3 >/dev/null || skip "python3 not available"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mk() { python3 - "$1" <<PY
import json,sys
g="/var/lib/acq/host"
h={"type":"Bind","guest":g,"host":"/x/cfg","options":{"readonly":True}}
o={"type":"Bind","guest":sys.argv[1],"host":"/y","options":{"readonly":False}}
print(json.dumps({"active_config":{"mounts":[h,o]}}))
PY
    }
    for g in //var / /var/lib//acq /var/lib/acq/host/../host/sub; do
      r=$(mk "$g" | python3 -c "$_ACQ_MSB_RO_INSPECT_PY" /var/lib/acq/host /x/cfg 2>&1); printf "%s => %s\n" "$g" "$r"
    done
  '
  assert_success
  refute_output --partial '=> ok'
}

@test "gate: no host record keeps the guest-copy compatibility path, without consulting msb inspect" {
  local k="$STUBDIR/g19"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-nr" STUB_MSB_VERSION=0.7.7 STUB_MSB_INSPECT_MODE=ro-ok
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_apply_kit_dir norecordgate "'"$k"'" 2>&1
  '
  assert_success
  assert_regex "$(cat "$CALLS")" 'msb copy .*norecordgate:/home/agent/cfg/merge\.mjs'
  refute_regex "$(cat "$CALLS")" '/var/lib/acq/host/kit-files'
  refute_regex "$(cat "$CALLS")" 'msb inspect norecordgate'
}

@test "gate: the create-time startup script keeps the guest path below the version floor" {
  local k="$STUBDIR/g20"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-ss" STUB_MSB_VERSION=0.7.6 STUB_MSB_INSPECT_MODE=ro-ok
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/ss-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
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
  assert_output --partial 'corroborating evidence'
  [ -f "$STUBDIR/.qual_removed" ]
}

@test "canary: host directory changed => FAIL, even if the guest claims every write was denied" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=0 STUB_QUAL_FORGE_DENIED=1
  assert_failure 1
  assert_output --partial 'RESULT: FAIL'
  assert_output --partial 'host directory behind the :ro volume was modified'
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

@test "canary: a PASS on a non-final msb version says acq will not rely on the mount there" {
  _plant_canary_msb
  _run_canary STUB_RO_ENFORCED=1 STUB_MSB_VERSION=0.7.7-rc1
  assert_success
  assert_output --partial 'RESULT: PASS'
  assert_output --partial 'will not rely on the read-only mount'
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

