#!/usr/bin/env bats
#
# 162-verify-host-authority-live-runtime.bats — RUNTIME regression tests for the verdict
# logic of scripts/verify-host-authority-live, against STUBBED acq/sbx/msb binaries
# (HAL_ACQ_BIN and HAL_RUN_ID are the script's offline test seams). They prove that a
# step never PASSes on partial output or a failed or timed-out command, that probe
# failures are BLOCKED rather than FAIL, that the stale-refresh step makes only its own
# sandbox stale, and that cleanup removes only sandboxes this run created. They say
# nothing about real sbx or msb behavior; live evidence is recorded in
# docs/VERIFY_PROVIDER_ADOPTION.md.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  HS="$STUBDIR/hs"; mkdir -p "$HS/bin" "$HS/prov"
  export HS REPO_ROOT ACQ_PROVENANCE_DIR="$HS/prov" HAL_RUN_ID=t1 HAL_ACQ_BIN="$HS/bin/acq"
  export CUR=1111111111111111111111111111111111111111
  : > "$HS/calls"; : > "$HS/list.sbx"; : > "$HS/list.msb"
  _write_stubs
  PATH="$HS/bin:$PATH"
}
teardown() { acq_teardown_stubs; }

load 'helper'

_write_stubs() {
  cat >"$HS/bin/lib.sh" <<'LIB'
_hc() { ( ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO_ROOT" . "$REPO_ROOT/acq" >/dev/null 2>&1; acq_host_config_dir "$1" "$2" ); }
_pf() { ( ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO_ROOT" . "$REPO_ROOT/acq" >/dev/null 2>&1; _acq_provenance_file "$1" "$2" ); }
LIB
  cat >"$HS/bin/acq" <<'STUB'
#!/usr/bin/env bash
. "$HS/bin/lib.sh"
echo "acq $*" >>"$HS/calls"
[ "$1" = "--backend" ] || exit 64
b=$2; shift 2; verb=$1; shift
name=""; prev=""
for a in "$@"; do [ "$prev" = "--name" ] && name=$a; prev=$a; done
[ -n "$name" ] || name=${1:-}
case "$verb" in
  create)
    hc=$(_hc "$b" "$name"); mkdir -p "$hc"; echo "$hc" >"$HS/hcdir.$name"
    pf=$(_pf "$b" "$name"); mkdir -p "$(dirname "$pf")"; printf 'applied_ref=%s\n' "$CUR" >"$pf"
    if [ "$b" = sbx ]; then
      printf 'zscaler-ca-certificate x#ref=%s\nusai-provider y#ref=%s\nagentic-coding-playbook z#ref=%s\n' "$CUR" "$CUR" "$CUR" >"$hc/builtin-kits"
    else
      printf '1' >"$hc/install-123"
    fi
    echo "$name" >>"$HS/list.$b"
    if [ -n "${STUB_CREATE_HANG:-}" ]; then
      echo "acq: Applying configuration kits"
      ( trap '' TERM; sleep 30.42 ) &
      [ "$STUB_CREATE_HANG" = ignore ] && trap '' TERM
      sleep 60.42
    fi
    exit "${STUB_CREATE_RC:-0}" ;;
  rm) grep -vxF -- "$name" "$HS/list.$b" >"$HS/l.tmp"; mv "$HS/l.tmp" "$HS/list.$b"; exit 0 ;;
  restart)
    touch "$HS/restarted"
    if [ "${STUB_RESTART_INSTALL:-0}" = 1 ]; then echo $(( $(cat "$HS/install.count" 2>/dev/null || echo 1) + 1 )) >"$HS/install.count"; fi
    [ -n "${STUB_RESTART_SLEEP:-}" ] && sleep "$STUB_RESTART_SLEEP"
    exit "${STUB_RESTART_RC:-0}" ;;
  run)
    for x in "Zscaler CA kit" "provider kit" "playbook kit"; do
      [ "${STUB_RUN_MODE:-full}" = quiet ] && break
      [ "${STUB_RUN_MODE:-full}" = partial ] && [ "$x" = "playbook kit" ] && continue
      echo "acq: '$name' is missing the $x; injecting with 'sbx kit add'..."
    done
    exit "${STUB_RUN_RC:-0}" ;;
  kit)
    sub=$1; shift; name=$1; pf=$(_pf "$b" "$name")
    case "$sub" in
      check)
        if [ "${STUB_CHECK_FORCE:-}" = current ] || grep -q "^applied_ref=$CUR$" "$pf"; then echo "status:        current (on the pinned bundle)"
        else echo "status:        stale (does not match the pinned bundle)"; fi
        exit 0 ;;
      update)
        mode=${STUB_UPDATE_MODE:-full}
        if [ "$mode" = notice ]; then echo "acq: sbx >= 0.38 cannot extend a live sandbox"; exit 0; fi
        echo "acq: Zscaler CA kit injected into '$name'."
        echo "acq: provider kit injected into '$name'."
        if [ "$mode" != missing ] && [ "$mode" != failrc ]; then
          echo "acq: playbook kit injected into '$name'."; echo "acq: git-ssh-sign kit refreshed in '$name'."
        fi
        [ "$mode" = warn ] && echo "acq: warning: 'sbx kit add' (agent kit) failed for '$name'."
        if [ "$mode" = failrc ]; then exit 1; fi
        printf 'applied_ref=%s\n' "$CUR" >"$pf"
        exit 0 ;;
    esac ;;
esac
exit 0
STUB
  cat >"$HS/bin/sbx" <<'STUB'
#!/usr/bin/env bash
echo "sbx $*" >>"$HS/calls"
case "$1" in
  version) echo "sbx version: v0.48.0 abc123" ;;
  ls) cat "$HS/list.sbx" ;;
  exec) all="$*"
    case "$all" in
      *"echo PRESENT"*) [ -n "${STUB_NO_PROVIDER_CFG:-}" ] || echo PRESENT ;;
      *"echo REMOVED"*) echo REMOVED ;;
      *"echo STILL-ABSENT"*) echo STILL-ABSENT ;;
    esac ;;
  rm) shift; for a in "$@"; do case "$a" in -*) ;; *) grep -vxF -- "$a" "$HS/list.sbx" >"$HS/l.tmp"; mv "$HS/l.tmp" "$HS/list.sbx" ;; esac; done ;;
esac
exit 0
STUB
  cat >"$HS/bin/msb" <<'STUB'
#!/usr/bin/env bash
echo "msb $*" >>"$HS/calls"
all="$*"
case "$1" in
  --version) [ -n "${STUB_MSB_VER_SLEEP:-}" ] && sleep "$STUB_MSB_VER_SLEEP"; echo "msb 0.7.7" ;;
  doctor) exit "${STUB_MSB_DOCTOR_RC:-0}" ;;
  ls) cat "$HS/list.msb" ;;
  remove|rm) exit 0 ;;
  inspect)
    [ -n "${STUB_INSPECT_FAIL_AFTER_RESTART:-}" ] && [ -f "$HS/restarted" ] && exit 1
    [ -n "${STUB_INSPECT_NULL:-}" ] && { echo '{"active_config":null}'; exit 0; }
    hc=$(cat "$HS/hcdir.$2" 2>/dev/null)
    printf '{"active_config":{"mounts":[{"guest":"/var/lib/acq/host","type":"Bind","host":"%s","options":{"readonly":true}}]},"config":{}}\n' "$hc" ;;
  exec)
    case "$all" in
      *".hal-install-proof"*"if [ -e"*|*"if [ -e"*".hal-install-proof"*) [ -n "${STUB_PROOF_FAIL:-}" ] && exit 1; cat "$HS/install.count" 2>/dev/null || echo 1 ;;
      *"if [ -e"*) echo 1 ;;
      *"cat /home/agent/.hal-ro-proof"*) echo "/var/lib/acq/host/kit-files/home-agent-hal-ro-proof-sh.1" ;;
      *NO-GUEST-COPY*) echo NO-GUEST-COPY ;;
      *PLAIN-COPY-OK*) echo PLAIN-COPY-OK ;;
    esac ;;
esac
exit 0
STUB
  chmod +x "$HS/bin/acq" "$HS/bin/sbx" "$HS/bin/msb"
}

# _hal ARGS... : run the script with short timeouts into $HS/out; results in $HS/out/results.tsv
_hal() {
  run bash "$REPO_ROOT/scripts/verify-host-authority-live" --out "$HS/out" --step-timeout 5 --create-timeout 5 "$@"
}
_res() { awk -F'\t' -v id="$1" '$1 == id { print $6 }' "$HS/out/results.tsv"; }
_sbx_pf() { ( ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO_ROOT" . "$REPO_ROOT/acq" >/dev/null 2>&1; _acq_provenance_file sbx "$1" ); }

@test "runtime: sbx stale refresh PASSes only with exit 0 and all four kits reported, and touches only its own provenance" {
  mkdir -p "$HS/prov/sbx"; printf 'applied_ref=%s\n' "$CUR" > "$(_sbx_pf other-sandbox)"
  cp "$(_sbx_pf other-sandbox)" "$HS/other.before"
  _hal --backend sbx --only sbx-baseline,sbx-stale-refresh
  assert_success
  [ "$(_res sbx-stale-refresh)" = PASS ]
  cmp "$HS/other.before" "$(_sbx_pf other-sandbox)"
  assert_output --partial 'made ONLY the provenance record of hal-t1-s stale'
}

@test "runtime: stale refresh with one kit missing from the output is FAIL even though the command exited 0" {
  STUB_UPDATE_MODE=missing _hal --backend sbx --only sbx-baseline,sbx-stale-refresh
  assert_failure 1
  [ "$(_res sbx-stale-refresh)" = FAIL ]
}

@test "runtime: stale refresh that prints kits but exits non-zero is BLOCKED, never PASS" {
  STUB_UPDATE_MODE=failrc _hal --backend sbx --only sbx-baseline,sbx-stale-refresh
  [ "$(_res sbx-stale-refresh)" = BLOCKED ]
}

@test "runtime: stale refresh with a warning in the output is FAIL" {
  STUB_UPDATE_MODE=warn _hal --backend sbx --only sbx-baseline,sbx-stale-refresh
  [ "$(_res sbx-stale-refresh)" = FAIL ]
}

@test "runtime: stale refresh on an sbx that only prints the recreate notice is BLOCKED (not a refresh result)" {
  STUB_UPDATE_MODE=notice _hal --backend sbx --only sbx-baseline,sbx-stale-refresh
  [ "$(_res sbx-stale-refresh)" = BLOCKED ]
}

@test "runtime: stale refresh is BLOCKED when kit check still says current after the edit (refresh would be a no-op)" {
  STUB_CHECK_FORCE=current _hal --backend sbx --only sbx-baseline,sbx-stale-refresh
  [ "$(_res sbx-stale-refresh)" = BLOCKED ]
}

@test "runtime: record-change PASSes only when all three kits attempt kit add" {
  _hal --backend sbx --only sbx-baseline,sbx-record-change
  [ "$(_res sbx-record-change)" = PASS ]
  STUB_RUN_MODE=partial _hal --backend sbx --only sbx-baseline,sbx-record-change
  [ "$(_res sbx-record-change)" = FAIL ]
}

@test "runtime: record-change with a failing re-attach is BLOCKED" {
  STUB_RUN_RC=3 _hal --backend sbx --only sbx-baseline,sbx-record-change
  [ "$(_res sbx-record-change)" = BLOCKED ]
}

@test "runtime: a sandbox name already in use is refused, and cleanup never removes it" {
  echo hal-t1-s > "$HS/list.sbx"
  _hal --backend sbx --only sbx-baseline
  [ "$(_res sbx-baseline)" = BLOCKED ]
  run grep -E '^(acq --backend sbx (create|rm)|sbx rm)' "$HS/calls"
  assert_failure
  grep -qx hal-t1-s "$HS/list.sbx"
}

@test "runtime: cleanup removes exactly the sandbox this run created" {
  echo keep-me > "$HS/list.sbx"
  _hal --backend sbx --only sbx-baseline
  [ "$(_res sbx-baseline)" = PASS ]
  grep -q 'acq --backend sbx rm hal-t1-s' "$HS/calls"
  grep -qx keep-me "$HS/list.sbx"
  refute_output --partial 'keep-me'
  [ -z "$(find "$HS/out" -maxdepth 1 -name "ws.*" 2>/dev/null)" ]
}

@test "runtime: install-gate does not PASS when the proof counter advances but the restart times out" {
  STUB_RESTART_INSTALL=1 STUB_RESTART_SLEEP=3 _hal --backend msb --create-timeout 1 --only msb-ro-kit-create,msb-install-gate
  [ "$(_res msb-ro-kit-create)" = PASS ]
  [ "$(_res msb-install-gate)" = BLOCKED ]
  assert_output --partial 'timed out'
}

@test "runtime: install-gate PASSes when the restart exits 0 and the counter advances" {
  STUB_RESTART_INSTALL=1 _hal --backend msb --only msb-ro-kit-create,msb-install-gate
  [ "$(_res msb-install-gate)" = PASS ]
}

@test "runtime: install-gate is FAIL (not PASS) when the restart exits 0 but the counter does not advance" {
  _hal --backend msb --only msb-ro-kit-create,msb-install-gate
  [ "$(_res msb-install-gate)" = FAIL ]
}

@test "runtime: a failing proof-file probe is BLOCKED, not compared" {
  STUB_PROOF_FAIL=1 _hal --backend msb --only msb-ro-kit-create,msb-install-gate
  [ "$(_res msb-install-gate)" = BLOCKED ]
}

@test "runtime: a hanging 'msb --version' preflight is bounded and leaves msb steps BLOCKED" {
  STUB_MSB_VER_SLEEP=10 _hal --backend msb --step-timeout 1 --only msb-ro-kit-create
  [ "$(_res msb-ro-kit-create)" = BLOCKED ]
  assert_output --partial 'timed out after 1s: msb --version'
}

@test "runtime: an empty selection exits 2" {
  _hal --backend msb --only sbx-baseline
  assert_failure 2
}

@test "runtime: forged-heal PASSes with a present provider config, current record and no re-apply" {
  STUB_RUN_MODE=quiet _hal --backend sbx --only sbx-baseline,sbx-forged-heal
  [ "$(_res sbx-forged-heal)" = PASS ]
}

@test "runtime: forged-heal is BLOCKED when the provider config never existed (removal would prove nothing)" {
  STUB_RUN_MODE=quiet STUB_NO_PROVIDER_CFG=1 _hal --backend sbx --only sbx-baseline,sbx-forged-heal
  [ "$(_res sbx-forged-heal)" = BLOCKED ]
}

@test "runtime: forged-heal is FAIL when the re-attach re-applies a kit although the record is current" {
  STUB_RUN_MODE=full _hal --backend sbx --only sbx-baseline,sbx-forged-heal
  [ "$(_res sbx-forged-heal)" = FAIL ]
}

@test "runtime: heal step reports a failing msb inspect after restart as BLOCKED, not FAIL" {
  STUB_INSPECT_FAIL_AFTER_RESTART=1 _hal --backend msb --only msb-ro-kit-create,msb-ro-kit-heal
  [ "$(_res msb-ro-kit-create)" = PASS ]
  [ "$(_res msb-ro-kit-heal)" = BLOCKED ]
}

@test "runtime: a null active_config is BLOCKED for inspect-shape, never FAIL" {
  STUB_INSPECT_NULL=1 _hal --backend msb --only msb-ro-kit-create,msb-inspect-shape
  [ "$(_res msb-inspect-shape)" = BLOCKED ]
}

# --- unbounded-wait regressions: a hung create whose backgrounded, TERM-ignoring helper
# holds the output open must not keep the script alive past timeout + grace. The old
# `timeout ... | tee` pipeline returned only when the sleeper exited (~30s here).
_hang_run() { # extra script args... ; sets HANG_SECS
  local t0=$SECONDS
  HAL_KILL_GRACE=2 STUB_CREATE_HANG="$STUB_CREATE_HANG" _hal --backend msb --create-timeout 3 --step-timeout 3 "$@"
  HANG_SECS=$((SECONDS - t0))
}

@test "runtime: a hung create with a TERM-ignoring background helper returns within timeout plus grace" {
  STUB_CREATE_HANG=bg _hang_run --only msb-ro-kit-create
  [ "$HANG_SECS" -lt 20 ]
  [ "$(_res msb-ro-kit-create)" = BLOCKED ]
  assert_output --partial 'BLOCKED(timeout)'
  assert_output --partial 'timed out after 3s'
  assert_output --partial 'SUMMARY:'
}

@test "runtime: a hung create whose parent also ignores TERM is KILLed within the bound" {
  STUB_CREATE_HANG=ignore _hang_run --only msb-ro-kit-create
  [ "$HANG_SECS" -lt 20 ]
  [ "$(_res msb-ro-kit-create)" = BLOCKED ]
}

@test "runtime: a timeout writes hang diagnostics into the transcript, and --no-hang-diagnostics omits them" {
  STUB_CREATE_HANG=bg _hang_run --only msb-ro-kit-create
  grep -q -- '--- hang diagnostics' "$HS/out/transcript.log"
  grep -q 'msb ls (rc' "$HS/out/transcript.log"
  STUB_CREATE_HANG=bg _hang_run --no-hang-diagnostics --only msb-ro-kit-create
  ! grep -q -- '--- hang diagnostics' "$HS/out/transcript.log"
}

@test "runtime: cleanup after a timed-out create still removes the tracked sandbox" {
  STUB_CREATE_HANG=bg _hang_run --only msb-ro-kit-create
  grep -q 'cleanup: removing msb sandbox hal-t1-a' "$HS/out/transcript.log"
  grep -q 'acq --backend msb rm hal-t1-a' "$HS/calls"
}

@test "runtime: SIGINT during a hung command still prints the summary, cleans up and exits 130" {
  rm -rf "$HS/out"
  # set -m gives the job default signal dispositions, as a script started from a terminal
  # has (a plain background job ignores SIGINT). The harness stubs sleep, so wait with
  # `command sleep`.
  set -m
  HAL_KILL_GRACE=2 STUB_CREATE_HANG=ignore bash "$REPO_ROOT/scripts/verify-host-authority-live" --out "$HS/out" \
    --step-timeout 30 --create-timeout 60 --backend msb --only msb-ro-kit-create >"$HS/int.log" 2>&1 &
  local pid=$! i=0 rc=0
  set +m
  while [ "$i" -lt 150 ] && ! grep -q 'Applying configuration kits' "$HS/int.log" 2>/dev/null; do command sleep 0.2; i=$((i + 1)); done
  grep -q 'Applying configuration kits' "$HS/int.log"
  kill -INT "$pid"
  i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do command sleep 0.2; i=$((i + 1)); done
  ! kill -0 "$pid" 2>/dev/null
  wait "$pid" || rc=$?
  [ "$rc" -eq 130 ]
  grep -q 'interrupted' "$HS/int.log"
  grep -q 'SUMMARY:.*INTERRUPTED' "$HS/int.log"
  grep -q 'acq --backend msb rm hal-t1-a' "$HS/calls"
}
