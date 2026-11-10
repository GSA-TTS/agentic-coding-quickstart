#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2154,SC2034
# Runner part (bounded execution, cleanup, recording, helpers) of scripts/verify-host-authority-live: sourced by it, never run alone. It shares
# that script's global variables (OUT, REVISION, TO, the counters), so it is split out only
# to keep each file within the repository size limit.
# --- bounded execution core ---------------------------------------------------
# Nothing here ever reads a pipe that a descendant of the command could hold open. The
# command's output goes to a FILE, it runs in the background, and this shell waits for
# that one PID only, polling against a wall-clock deadline. At the deadline it records
# hang diagnostics, TERMs the command and every descendant (found with pgrep -P), then
# KILLs whatever ignored it. timeout(1) (-k) stays as an outer backstop only.
POLL=1
if sleep 0.1 2>/dev/null; then POLL=0.1; fi
STEP_DEADLINE=0; STEP_TIMED_OUT=0; CUR_PID=""; STUCK_PID=""; B_LIVE=0; B_SHOWN=0; IN_DIAG=0
PROBE_F="$OUT/.probe-out"

descendants() { # PID -> PID and every descendant, one per line
  local c
  echo "$1"
  if command -v pgrep >/dev/null 2>&1; then
    for c in $(pgrep -P "$1" 2>/dev/null); do descendants "$c"; done
  else
    for c in $(ps -axo pid=,ppid= 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'); do descendants "$c"; done
  fi
}
any_alive() { local p; for p in "$@"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
reap_tree() { # PID : TERM the tree, wait KILL_GRACE, KILL survivors (and fresh children)
  local list p t
  list=$(descendants "$1")
  for p in $list; do kill -TERM "$p" 2>/dev/null; done
  t=$((SECONDS + KILL_GRACE))
  # shellcheck disable=SC2086
  while [ "$SECONDS" -le "$t" ] && any_alive $list; do sleep "$POLL"; done
  if kill -0 "$1" 2>/dev/null; then list="$list
$(descendants "$1")"; fi
  for p in $list; do kill -KILL "$p" 2>/dev/null; done
  sleep "$POLL"
  return 0
}

b_show() { # OUTFILE : echo the bytes not yet shown to the terminal and the transcript
  local f="$1" size n
  [ "$B_LIVE" -eq 1 ] || return 0
  size=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
  [ -n "$size" ] || return 0
  n=$((size - B_SHOWN))
  [ "$n" -gt 0 ] || return 0
  tail -c +$((B_SHOWN + 1)) "$f" 2>/dev/null | head -c "$n" >"$OUT/.chunk"
  cat "$OUT/.chunk"
  cat "$OUT/.chunk" >>"$TRANSCRIPT"
  B_SHOWN=$size
}

hang_diag() { # called with the stuck command still alive
  local f="$OUT/.diag" s_pid="$CUR_PID" s_shown="$B_SHOWN" s_live="$B_LIVE" s_rc="$LAST_RC" s_to="$STEP_TIMED_OUT" s_dl="$STEP_DEADLINE" l
  [ "$HANG_DIAG" -eq 1 ] && [ "$IN_DIAG" -eq 0 ] || return 0
  IN_DIAG=1; STEP_DEADLINE=0; B_LIVE=0; STUCK_PID="$s_pid"
  say "--- hang diagnostics $(date -u +%Y-%m-%dT%H:%M:%SZ): ps (acq|msb|sbx|socat|sleep), msb ls, sbx ls ---"
  run_bounded 15 "$f" "" ps -axo pid,ppid,etime,stat,command
  grep -E 'acq|msb|sbx|socat|sleep' "$f" 2>/dev/null | grep -v 'grep -E' >"$f.sel"
  while IFS= read -r l; do say "  $(printf '%s' "$l" | cut -c1-200)"; done <"$f.sel"
  if command -v msb >/dev/null 2>&1; then
    run_bounded 15 "$f" "" msb ls; say "  msb ls (rc $LAST_RC):"
    while IFS= read -r l; do say "    $l"; done <"$f"
  fi
  if command -v sbx >/dev/null 2>&1; then
    run_bounded 15 "$f" "" sbx ls; say "  sbx ls (rc $LAST_RC):"
    while IFS= read -r l; do say "    $l"; done <"$f"
  fi
  say "--- end hang diagnostics ---"
  CUR_PID="$s_pid"; B_SHOWN="$s_shown"; B_LIVE="$s_live"; LAST_RC="$s_rc"; STEP_TIMED_OUT="$s_to"; STEP_DEADLINE="$s_dl"; IN_DIAG=0; STUCK_PID=""
}

# run_bounded SECS OUTFILE ERRFILE CMD... : stdin closed, stdout (and stderr, unless
# ERRFILE is given) go to OUTFILE. LAST_RC is the exit status; 124 means timed out, or
# the step's wall-clock budget was exhausted (the command is then not started).
run_bounded() {
  local secs="$1" outf="$2" errf="$3" pid dl left rc=0 timedout=0
  shift 3
  if [ "$STEP_DEADLINE" -gt 0 ]; then
    left=$((STEP_DEADLINE - SECONDS))
    if [ "$left" -le 0 ]; then
      say "[step wall-clock budget (${STEP_BUDGET}s) exhausted; not running: $*]"
      : >"$outf"; STEP_TIMED_OUT=1; LAST_RC=124; return 0
    fi
    [ "$secs" -le "$left" ] || secs=$left
  fi
  : >"$outf"; B_SHOWN=0
  if [ -n "$errf" ]; then
    : >"$errf"
    "${TO[@]}" -k "$KILL_GRACE" "$((secs + KILL_GRACE + 5))" "$@" </dev/null >"$outf" 2>"$errf" &
  else
    "${TO[@]}" -k "$KILL_GRACE" "$((secs + KILL_GRACE + 5))" "$@" </dev/null >"$outf" 2>&1 &
  fi
  pid=$!; CUR_PID=$pid; dl=$((SECONDS + secs))
  while kill -0 "$pid" 2>/dev/null; do
    b_show "$outf"
    if [ "$SECONDS" -gt "$dl" ]; then
      timedout=1
      say "[timed out after ${secs}s: $*]"
      hang_diag
      reap_tree "$pid"
      break
    fi
    sleep "$POLL"
  done
  if kill -0 "$pid" 2>/dev/null; then
    say "[could not kill pid $pid; abandoning it]"; rc=137
  else
    wait "$pid" 2>/dev/null; rc=$?
  fi
  b_show "$outf"
  CUR_PID=""
  if [ "$timedout" -eq 1 ]; then rc=124; fi
  if [ "$rc" -eq 124 ]; then STEP_TIMED_OUT=1; fi
  LAST_RC=$rc
  return 0
}

# run_cmd SECS CMD... : run bounded, stdin closed, output shown live and appended to the
# transcript; the output is also kept in $CAP and the exit status lands in LAST_RC.
run_cmd() {
  local secs="$1"; shift
  say "\$ $*"
  B_LIVE=1
  run_bounded "$secs" "$CAP" "" "$@"
  B_LIVE=0
  return 0
}
last_out() { tr -d '\r' <"$CAP"; }
last_has() { last_out | grep -Fq -- "$1"; }
last_count() { last_out | grep -Fc -- "$1"; }

hc_dir() { # BACKEND NAME
  # shellcheck disable=SC1090
  ( ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO" . "$ACQ_LIB" >/dev/null 2>&1; acq_host_config_dir "$1" "$2" ) 2>/dev/null
}
prov_file() { # BACKEND NAME
  # shellcheck disable=SC1090
  ( ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO" . "$ACQ_LIB" >/dev/null 2>&1; _acq_provenance_file "$1" "$2" ) 2>/dev/null
}

track_sandbox() {
  case "
$CREATED" in *"
$1:$2
"*) return 0 ;; esac
  CREATED="${CREATED}$1:$2
"
}

remove_sandbox() { # BACKEND NAME
  local f="$OUT/.rm-out"
  STEP_DEADLINE=0
  run_bounded 120 "$f" "" "$ACQ" --backend "$1" rm "$2"
  say "cleanup: acq rm $2 rc=$LAST_RC"
  case "$1" in
    msb) run_bounded 60 "$f" "" msb remove --force "$2" ;;
    sbx) run_bounded 60 "$f" "" sbx rm --force "$2" ;;
  esac
  say "cleanup: $1 remove $2 rc=$LAST_RC"
}

ANY_FAIL=0
CLEANED=0
cleanup() {
  local line b n
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ "$KEEP" -eq 1 ] && [ "$ANY_FAIL" -eq 1 ]; then
    say "keeping sandboxes (--keep and a step failed):"
    printf '%s' "$CREATED" | while IFS= read -r line; do [ -n "$line" ] && say "  $line"; done
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    b=${line%%:*}; n=${line#*:}
    say "cleanup: removing $b sandbox $n"
    remove_sandbox "$b" "$n"
  done <<CLEAN
$CREATED
CLEAN
  case "$WS_ROOT" in
    "$OUT"/ws.?*) [ -d "$WS_ROOT" ] && rm -rf -- "$WS_ROOT" ;;
  esac
}
SUMMARY_DONE=0
INTERRUPTED=0
MSB_VER=""; SBX_VER=""
n_pass=0; n_fail=0; n_blocked=0
# finish runs on every exit path (normal, usage error after setup, interrupt): cleanup is
# bounded, then the summary is printed exactly once.
finish() {
  local rc=$?
  trap '' INT TERM
  [ "$SUMMARY_DONE" -eq 0 ] || return 0
  SUMMARY_DONE=1
  B_LIVE=0
  if [ "$INTERRUPTED" -eq 1 ]; then rc=130; fi
  cleanup
  say ""
  if [ "$INTERRUPTED" -eq 0 ]; then print_manual | while IFS= read -r l; do printf '%s\n' "$l" >>"$TRANSCRIPT"; printf '%s\n' "$l"; done; say ""; fi
  say "SUMMARY: PASS=$n_pass FAIL=$n_fail BLOCKED=$n_blocked   revision=$REVISION$DIRTY msb=${MSB_VER:-none} sbx=${SBX_VER:-none}$( [ "$INTERRUPTED" -eq 1 ] && printf '   INTERRUPTED' )"
  say "results : $RESULTS"
  say "transcript: $TRANSCRIPT"
  if [ "$INTERRUPTED" -eq 1 ]; then exit 130; fi
  say "Paste the results rows into the Host Authority Live Validation Record in docs/VERIFY_PROVIDER_ADOPTION.md."
  if [ $((n_pass + n_fail + n_blocked)) -eq 0 ]; then say "no steps ran (empty selection): nothing was verified"; exit 2; fi
  if [ "$n_fail" -gt 0 ]; then exit 1; fi
  if [ "$n_blocked" -gt 0 ]; then exit 2; fi
  exit "$rc"
}

trap 'finish' EXIT
trap 'on_signal' INT TERM
on_signal() {
  trap '' INT TERM
  INTERRUPTED=1
  B_LIVE=0
  echo; say "interrupted: stopping the running command, removing throwaway sandboxes"
  if [ -n "$CUR_PID" ]; then reap_tree "$CUR_PID"; fi
  if [ -n "$STUCK_PID" ]; then reap_tree "$STUCK_PID"; fi
  exit 130
}

# --- recording ---------------------------------------------------------------

record() { # ID RESULT DETAIL
  local id="$1" res="$2" detail="$3" b ver
  b=$(step_backend "$id")
  case "$b" in msb) ver="$MSB_VER" ;; sbx) ver="$SBX_VER" ;; *) ver="" ;; esac
  if [ "$STEP_TIMED_OUT" -eq 1 ] && [ "$res" != BLOCKED ]; then
    detail="BLOCKED(timeout): a command in this step timed out, so the $res verdict is withheld. Was: $detail"; res=BLOCKED
  fi
  detail=$(printf '%s' "$detail" | tr '\t\r\n' '   ')
  case "$res" in
    PASS) n_pass=$((n_pass + 1)) ;;
    FAIL) n_fail=$((n_fail + 1)); ANY_FAIL=1 ;;
    *) n_blocked=$((n_blocked + 1)); : ;;
  esac
  say ""
  say "==> $res  $id: $detail"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$b" "${ver:-unknown}" "$REVISION$DIRTY" "$RUN_DATE" "$res" "$detail" "$TRANSCRIPT" >>"$RESULTS"
}


# ver_ge A B : dotted numeric A >= B
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".");
    for (i = 1; i <= 3; i++) { xv = (i <= na) ? x[i] + 0 : 0; yv = (i <= nb) ? y[i] + 0 : 0;
      if (xv > yv) exit 0; if (xv < yv) exit 1 }
    exit 0 }'
}

mk_workspace() { # TAG -> path of a fresh git workspace (canonical, under $HOME)
  local d="$WS_ROOT/$1"
  mkdir -p "$d" || return 1
  ( cd "$d" && git init -q && git config user.email hal@example.invalid \
      && git config user.name "acq verify" && echo hi > README.md ) >/dev/null 2>&1 || true
  ( cd "$d" && pwd -P )
}

# --- msb fixture kit: one readonly startup file + one install-phase file -------
FIXTURE="$OUT/fixture-ro-kit"
write_fixture() {
  mkdir -p "$FIXTURE/files" || return 1
  printf '#!/bin/sh\nprintf "%%s\\n" "$0" >> /home/agent/.hal-ro-proof\n' >"$FIXTURE/files/ro-proof.sh"
  printf '#!/bin/sh\nprintf "run\\n" >> /home/agent/.hal-install-proof\n' >"$FIXTURE/files/install-proof.sh"
  {
    printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: hal-ro-fixture\n'
    printf 'displayName: HAL RO Fixture\ndescription: readonly startup file plus install file\n'
    printf 'files:\n  - path: /home/agent/hal/ro-proof.sh\n    mode: "0755"\n    source: files/ro-proof.sh\n    readonly: true\n'
    printf '  - path: /home/agent/hal/install-proof.sh\n    mode: "0755"\n    source: files/install-proof.sh\n'
    printf 'commands:\n  - phase: install\n    user: "0"\n    command:\n      - sh\n      - /home/agent/hal/install-proof.sh\n'
    printf '  - phase: startup\n    user: "0"\n    command:\n      - sh\n      - /home/agent/hal/ro-proof.sh\n'
  } >"$FIXTURE/spec.yaml"
}

# --- shared helpers -----------------------------------------------------------
# name_in_use BACKEND NAME : 0 = listed, 1 = not listed, 2 = could not tell.
name_in_use() {
  case "$1" in
    msb) probe "$STEP_TIMEOUT" msb ls ;;
    sbx) probe "$STEP_TIMEOUT" sbx ls -q ;;
  esac
  [ "$PROBE_RC" -eq 0 ] || return 2
  printf '%s\n' "$PROBE_OUT" | grep -Fqw -- "$2"
}

# create_sandbox BACKEND NAME WS [extra create args...] : refuses (LAST_RC=125, nothing
# tracked or removed later) when the name is already in use or the listing fails, so the
# cleanup can only ever remove sandboxes this run created.
create_sandbox() {
  local b="$1" n="$2" ws="$3" nrc; shift 3
  name_in_use "$b" "$n"; nrc=$?
  if [ "$nrc" -ne 1 ]; then
    say "[refusing to create '$n': name already in use or the $b listing failed (rc $nrc)]"
    LAST_RC=125; : >"$CAP"; return 0
  fi
  track_sandbox "$b" "$n"
  if [ "$b" = msb ]; then
    run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend msb create shell "$ws" --name "$n" --no-provider-kits "$@"
  else
    run_cmd "$CREATE_TIMEOUT" "$ACQ" --backend sbx create opencode "$ws" --name "$n" "$@"
  fi
}

# msb_inspect_check NAME : 0 = msb reports the read-only host-config Bind; 1 = it does
# not (a finding); 2 = the probe itself failed, timed out or returned unusable output
# (the caller must report BLOCKED, never FAIL).
msb_inspect_check() {
  local n="$1" hc js
  hc=$(hc_dir msb "$n"); js="$OUT/inspect-$n.json"
  [ -n "$hc" ] || return 2
  run_bounded "$STEP_TIMEOUT" "$js" "$OUT/.inspect-err" msb inspect "$n" --format json
  cat "$OUT/.inspect-err" >>"$TRANSCRIPT" 2>/dev/null
  [ "$LAST_RC" -eq 0 ] || return 2
  [ -s "$js" ] || return 2
  python3 - "$js" "$hc" <<'PY'
import json, os, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
if d.get("active_config") is None:
    sys.exit(2)
mounts = (d.get("active_config") or {}).get("mounts") or []
hit = [m for m in mounts if isinstance(m, dict) and m.get("guest") == "/var/lib/acq/host"]
ok = (len(hit) == 1 and hit[0].get("type") == "Bind"
      and (hit[0].get("options") or {}).get("readonly") is True
      and os.path.realpath(hit[0].get("host", "")) == os.path.realpath(sys.argv[2]))
sys.exit(0 if ok else 1)
PY
}

guest_root() { # NAME CMD... (msb): run as root in the guest, output live
  local n="$1"; shift
  run_cmd "$STEP_TIMEOUT" msb exec "$n" -u 0 -- "$@"
}

MSB_READY=0; MSB_A=""; MSB_A_OK=0
# probe SECS CMD... : quiet bounded probe (stdin closed). Sets PROBE_OUT and PROBE_RC;
# a timeout is rc 124. Never prints the output; callers decide what to say.
PROBE_OUT=""; PROBE_RC=0
probe() {
  local secs="$1"; shift
  run_bounded "$secs" "$PROBE_F" "" "$@"
  PROBE_RC=$LAST_RC
  PROBE_OUT=$(tr -d '\r' <"$PROBE_F")
  return 0
}

msb_preflight() {
  if ! command -v msb >/dev/null 2>&1; then say "msb: not on PATH"; return 0; fi
  probe "$STEP_TIMEOUT" msb --version
  if [ "$PROBE_RC" -ne 0 ]; then say "msb: 'msb --version' failed or timed out (rc $PROBE_RC)"; return 0; fi
  MSB_VER=$(printf '%s\n' "$PROBE_OUT" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([+-][^[:space:]]*)?' | head -n1)
  [ -n "$MSB_VER" ] || MSB_VER="unparsed"
  if ! command -v python3 >/dev/null 2>&1; then say "msb: python3 missing (acq's read-only gate needs it)"; return 0; fi
  probe "$STEP_TIMEOUT" msb doctor
  if [ "$PROBE_RC" -ne 0 ]; then say "msb: 'msb doctor' failed, timed out, or reports the host is not ready (rc $PROBE_RC)"; return 0; fi
  MSB_READY=1
}

block_if_not_ready() { # ID BACKEND_READY_VAR REASON
  [ "$2" -eq 1 ] || { record "$1" BLOCKED "$3"; return 1; }
  return 0
}

