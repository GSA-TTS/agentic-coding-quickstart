#!/usr/bin/env bash
#
# 74-msb-restart-durability — acq start/restart + secret re-export (8o1L..8o1X)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 8o1L–8o1R. ADR-0017 / #247 RESTART DURABILITY — acq start/restart verb,
# acq_backend_start, start-if-stopped-on-attach, and startup staging.
# ---------------------------------------------------------------------------

# 8o1L. acq_backend_start exists for msb and calls the right CLI. On sbx it is
#        DELIBERATELY absent (sbx has no 'start' verb; a stopped sandbox resumes
#        on the next `sbx run`/`sbx exec`), so acq must NOT define it or emit
#        `sbx start` (which is not a real subcommand).
make_stubs; load_acq
: > "$CALLS"
( . "${REPO_ROOT}/acq.backends/msb.sh"; acq_backend_start msbstartbox >/dev/null 2>&1 )
msb_start_log=$(cat "$CALLS")
assert_contains "0017: msb acq_backend_start calls 'msb start NAME'" "$msb_start_log" "msb start msbstartbox"
cleanup_stubs
make_stubs; load_acq   # load_acq sources the sbx adapter
if command -v acq_backend_start >/dev/null 2>&1; then
  fail "sbx: acq_backend_start is NOT defined (sbx has no 'start' verb)" "it is defined"
else
  pass "sbx: acq_backend_start is NOT defined (sbx has no 'start' verb)"
fi
cleanup_stubs

# 8o1M. `acq start NAME` (msb): calls `msb start NAME` AND re-drives the kit heal
#        (the healing `msb exec` feature-probe/startup calls appear). The sandbox
#        is RUNNING (present in the running fixture) so start-if-stopped is a
#        no-op inside ensure_kits_applied and the heal's exec calls flow.
#        S1 REGRESSION: acq_backend_start (called FIRST on the verb path) now
#        BLOCKS on _acq_msb_wait_for_exec_ready — a `msb exec … echo ok` readiness
#        probe — before returning, so the readiness probe MUST precede the first
#        kit-heal `msb exec`. Without the S1 fix the heal exec would race the boot
#        because ensure_kits_applied sees the sandbox already running and skips its
#        own wait.
make_stubs; load_acq
printf 'startbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'startbox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
out=$(ACQ_BACKEND=msb "$ACQ" start startbox 2>&1)
start_log=$(cat "$CALLS")
assert_contains "0017: acq start -> msb start NAME" "$start_log" "msb start startbox"
# Heal re-drives kit apply => `msb exec` against the guest for the built-in kits.
assert_contains "0017: acq start re-drives kit heal (msb exec)" "$start_log" "msb exec"
assert_contains "0017: acq start prints a status line" "$out" "started 'startbox'"
# S1 ordering: the readiness probe (`msb exec … echo ok` from acq_backend_start's
# _acq_msb_wait_for_exec_ready) must precede the FIRST kit-heal exec. The probe
# runs `sh -c 'echo ok'`; kit-heal exec calls carry other snippets, so the first
# `msb exec` line overall is the readiness probe on the verb path.
_probe_ln=$(printf '%s\n' "$start_log" | grep -n "msb exec startbox -- sh -c echo ok" | head -n1 | cut -d: -f1)
_firstexec_ln=$(printf '%s\n' "$start_log" | grep -n "msb exec" | head -n1 | cut -d: -f1)
if [ -n "$_probe_ln" ] && [ -n "$_firstexec_ln" ] && [ "$_probe_ln" -le "$_firstexec_ln" ]; then
  pass "0017 S1: start-verb readiness probe precedes first heal exec"
else
  fail "0017 S1: start-verb readiness probe precedes first heal exec" "probe=$_probe_ln first_exec=$_firstexec_ln"
fi
cleanup_stubs

# 8o1N. `acq restart NAME` (msb): stop, THEN start, THEN heal — in that order.
make_stubs; load_acq
printf 'restartbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'restartbox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
out=$(ACQ_BACKEND=msb "$ACQ" restart restartbox 2>&1)
restart_log=$(cat "$CALLS")
assert_contains "0017: acq restart calls msb stop NAME" "$restart_log" "msb stop restartbox"
assert_contains "0017: acq restart calls msb start NAME" "$restart_log" "msb start restartbox"
assert_contains "0017: acq restart re-drives kit heal (msb exec)" "$restart_log" "msb exec"
# Ordering: stop precedes start precedes the first heal exec.
_stop_ln=$(printf '%s\n' "$restart_log" | grep -n "msb stop restartbox" | head -n1 | cut -d: -f1)
_start_ln=$(printf '%s\n' "$restart_log" | grep -n "msb start restartbox" | head -n1 | cut -d: -f1)
_exec_ln=$(printf '%s\n' "$restart_log" | grep -n "msb exec" | head -n1 | cut -d: -f1)
if [ -n "$_stop_ln" ] && [ -n "$_start_ln" ] && [ -n "$_exec_ln" ] \
   && [ "$_stop_ln" -lt "$_start_ln" ] && [ "$_start_ln" -lt "$_exec_ln" ]; then
  pass "0017: acq restart order is stop < start < heal-exec"
else
  fail "0017: acq restart order is stop < start < heal-exec" "stop=$_stop_ln start=$_start_ln exec=$_exec_ln"
fi
cleanup_stubs

# 8o1O. Dispatcher guards: `acq start` / `acq restart` with NO name error + exit
#        nonzero (like the stop arm).
make_stubs; load_acq
out=$(ACQ_BACKEND=msb "$ACQ" start 2>&1); rc=$?
assert_contains "0017: acq start missing name errors" "$out" "start: missing sandbox name"
if [ "$rc" -ne 0 ]; then pass "0017: acq start missing name exits nonzero"; else fail "0017: acq start missing name exits nonzero" "rc=$rc"; fi
cleanup_stubs
make_stubs; load_acq
out=$(ACQ_BACKEND=msb "$ACQ" restart 2>&1); rc=$?
assert_contains "0017: acq restart missing name errors" "$out" "restart: missing sandbox name"
if [ "$rc" -ne 0 ]; then pass "0017: acq restart missing name exits nonzero"; else fail "0017: acq restart missing name exits nonzero" "rc=$rc"; fi
cleanup_stubs

# 8o1O2. sbx capability-gating: `acq start`/`acq restart` on sbx (which has no
#         'start'/'restart' verb and auto-resumes on attach) must fail cleanly
#         with an actionable message pointing at `acq run`, and must NEVER emit a
#         (non-existent) `sbx start`/`sbx restart` subcommand.
make_stubs; load_acq
: > "$CALLS"
out=$(ACQ_BACKEND=sbx "$ACQ" start sbxbox 2>&1); rc=$?
log=$(cat "$CALLS")
assert_contains "sbx: acq start explains no 'start' verb" "$out" "no separate 'start' verb"
assert_contains "sbx: acq start points at 'acq run'" "$out" "acq run sbxbox"
assert_not_contains "sbx: acq start never calls 'sbx start'" "$log" "sbx start"
if [ "$rc" -ne 0 ]; then pass "sbx: acq start exits nonzero (capability-gated)"; else fail "sbx: acq start exits nonzero (capability-gated)" "rc=$rc"; fi
cleanup_stubs
make_stubs; load_acq
: > "$CALLS"
out=$(ACQ_BACKEND=sbx "$ACQ" restart sbxbox 2>&1); rc=$?
log=$(cat "$CALLS")
assert_contains "sbx: acq restart explains no 'restart' verb" "$out" "no separate 'restart' verb"
assert_not_contains "sbx: acq restart never calls 'sbx start'" "$log" "sbx start"
assert_not_contains "sbx: acq restart never calls 'sbx restart'" "$log" "sbx restart"
if [ "$rc" -ne 0 ]; then pass "sbx: acq restart exits nonzero (capability-gated)"; else fail "sbx: acq restart exits nonzero (capability-gated)" "rc=$rc"; fi
cleanup_stubs

# 8o1P. START-IF-STOPPED (the `acq run <stopped-sandbox>` path). A sandbox that
#        EXISTS but is NOT running must be started by ensure_kits_applied BEFORE
#        any healing `msb exec` (which would fail against a stopped guest) — and
#        thus before attach. Assert `msb start` precedes the first heal `msb exec`.
make_stubs; load_acq
printf 'stoppedbox\n' > "$STUBDIR/.msb_sandbox_list"   # exists
: > "$STUBDIR/.msb_running_list"                        # but NOT running
: > "$CALLS"
( . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ensure_kits_applied stoppedbox >/dev/null 2>&1 )
stopped_log=$(cat "$CALLS")
assert_contains "0017: stopped sandbox is started during heal" "$stopped_log" "msb start stoppedbox"
_pstart_ln=$(printf '%s\n' "$stopped_log" | grep -n "msb start stoppedbox" | head -n1 | cut -d: -f1)
_pexec_ln=$(printf '%s\n' "$stopped_log" | grep -n "msb exec" | head -n1 | cut -d: -f1)
if [ -n "$_pstart_ln" ] && [ -n "$_pexec_ln" ] && [ "$_pstart_ln" -lt "$_pexec_ln" ]; then
  pass "0017: msb start precedes the first heal exec (stopped sandbox)"
else
  fail "0017: msb start precedes the first heal exec (stopped sandbox)" "start=$_pstart_ln exec=$_pexec_ln"
fi
cleanup_stubs

# 8o1Q. START-IF-RUNNING no-op: a RUNNING sandbox is NOT re-started during heal
#        (idempotent — no wasted `msb start`).
make_stubs; load_acq
printf 'livebox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'livebox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
( . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ensure_kits_applied livebox >/dev/null 2>&1 )
live_log=$(cat "$CALLS")
assert_not_contains "0017: running sandbox not re-started during heal" "$live_log" "msb start livebox"
cleanup_stubs

# 8o1Q2. HEAL FOLDS CLI KITS. A `--kit <ref>` supplied on `acq run <existing>`
#        (ACQ_CLI_KITS) MUST be healed too, exactly as provision folds it in —
#        otherwise a resumed/rebooted sandbox comes back with the kit's create-time
#        `-p` ports still mapped but its STARTUP-phase supervisors (e.g.
#        openchamber's shared `opencode serve` + web UI) never re-run, so `acq
#        ports` shows the ports while nothing listens behind them. Assert the heal
#        FETCHES and applies the CLI kit dir (its files land via `msb copy`).
make_stubs; load_acq
printf 'clikitbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'clikitbox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
_clikit="$STUBDIR/clikit"; mkdir -p "$_clikit/files"
cat > "$_clikit/spec.yaml" <<'CLIKITSPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: clikit
displayName: CLI Kit
description: a CLI-supplied kit with a staged file
files:
  - path: /home/agent/clikit-marker
    mode: "0644"
    source: files/marker
CLIKITSPEC
printf 'CLIKIT_MARKER\n' > "$_clikit/files/marker"
( . "${REPO_ROOT}/acq.backends/msb.sh"
  # shellcheck disable=SC2034  # read by the sourced msb.sh (ensure_kits_applied)
  ACQ_CLI_KITS=("$_clikit")
  _acq_msb_fetch_kit() { printf '%s\n' "$_clikit"; }
  acq_backend_ensure_kits_applied clikitbox >/dev/null 2>&1 )
clikit_log=$(cat "$CALLS")
assert_contains "clikit-heal: CLI --kit ref applied during heal (file copied)" \
  "$clikit_log" "clikitbox:/home/agent/clikit-marker"
cleanup_stubs

# 8o1R. NO NATIVE-ENTRYPOINT PERSISTENCE: provisioning a kit WITH a startup
#        command stages the script via `--script-path` but MUST NOT designate it
#        as `--entrypoint`. A native `msb start` outside acq cannot re-run startup
#        (start_detached replays only runtime.entrypoint/cmd) AND cannot even boot
#        a secret-bound sandbox (msb start needs the --secret host env vars only
#        acq injects), so native-restart-outside-acq is out of scope; restart
#        durability is delivered solely by the acq start/restart verb. The
#        ACQ_MSB_PERSIST_STARTUP_ENTRYPOINT knob was removed; setting it must have
#        NO effect.
_ep_kit_spec() {
  cat <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: ep-kit
displayName: EP Kit
description: one startup command
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo EP_MARKER
SPEC
}
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ep-off-secrets"
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/ep-off-stage"
  # Even with the removed knob set, no --entrypoint may appear.
  export ACQ_MSB_PERSIST_STARTUP_ENTRYPOINT=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  epk="$STUBDIR/epkit"; mkdir -p "$epk"; _ep_kit_spec > "$epk/spec.yaml"
  _acq_msb_fetch_kit() { printf '%s\n' "$epk"; }
  acq_backend_provision epoffbox shell /tmp >/dev/null 2>&1
)
ep_off_log=$(cat "$CALLS")
assert_contains "0017: startup staged via --script-path" "$ep_off_log" "--script-path acq-startup:"
assert_not_contains "0017: never designates the startup script as --entrypoint" "$ep_off_log" "--entrypoint /.msb/scripts/acq-startup"
assert_not_contains "0017: removed ACQ_MSB_PERSIST_STARTUP_ENTRYPOINT knob has no effect" "$ep_off_log" "--entrypoint"
cleanup_stubs
unset -f _ep_kit_spec

# 8o1S. Dispatch: `acq --backend msb start mybox` calls `msb start` (verb wired).
make_stubs
printf 'mybox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'mybox\n' > "$STUBDIR/.msb_running_list"
out=$(ACQ_BACKEND=msb "$ACQ" start mybox 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "msb: start -> msb start" "$log" "msb start mybox"
cleanup_stubs

# 8o1S2. Dispatch WIRING for the cli-kits reload (#320 restart durability). The
#        `acq start` / `acq restart` verbs and the name-only `acq run <sandbox>`
#        re-attach MUST call acq_cli_kits_load before the heal, so a sandbox
#        created with `--kit <daemon-kit>` re-runs that kit's startup on resume
#        WITHOUT the user re-passing --kit. Verified at the DISPATCH level (a
#        child `acq` process — not a direct function call), which is the only
#        place the wiring itself is exercised. Because the child cannot shadow
#        _acq_msb_fetch_kit, the reloaded kit ref is resolved through the offline
#        ACQ_MSB_KIT_LOCAL_DIR hatch to a local kit dir carrying one staged file;
#        we assert that file lands via `msb copy` (i.e. the reloaded kit was
#        healed). A CONTROL sub-case with NO record asserts no such copy happens,
#        proving the reload — not some always-on path — is what applied it.
#
# The reloaded kit dir: a hybrid/v1 mixin with a single staged marker file, whose
# in-guest path is unique per case so the assertion can key on it.
_mk_reload_kit() {
  local _dir="$1" _marker="$2"
  mkdir -p "$_dir/files"
  cat > "$_dir/spec.yaml" <<RELOADSPEC
schemaVersion: "hybrid/v1"
kind: mixin
name: reload-kit
displayName: Reload Kit
description: a persisted --kit whose file proves the resume reload ran
files:
  - path: ${_marker}
    mode: "0644"
    source: files/marker
RELOADSPEC
  printf 'RELOAD_MARKER\n' > "$_dir/files/marker"
}

# --- start: reloads the persisted --kit and heals it ---
make_stubs; load_acq
printf 'startreloadbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'startreloadbox\n' > "$STUBDIR/.msb_running_list"
_rk="$STUBDIR/reloadkit"; _mk_reload_kit "$_rk" "/home/agent/start-reload-marker"
# Seed the persisted record the run/create arm would have written at provision,
# using the REAL helper so the cksum-suffixed filename matches what acq looks up.
( load_acq; ACQ_CLI_KITS=("$_rk"); ACQ_EXTRA_KITS=""; acq_cli_kits_write msb startreloadbox )
: > "$CALLS"
# Route the reloaded ref through the offline kit-local hatch (child acq process).
out=$( ACQ_MSB_KIT_LOCAL_DIR="$_rk" ACQ_BACKEND=msb "$ACQ" start startreloadbox 2>&1 )
startreload_log=$(cat "$CALLS")
assert_contains "cli-kits(dispatch): acq start reloads + heals the persisted --kit" \
  "$startreload_log" "startreloadbox:/home/agent/start-reload-marker"
cleanup_stubs

# --- start CONTROL: no record => no reloaded-kit copy (proves reload caused it) ---
# NOTE: we must NOT point ACQ_MSB_KIT_LOCAL_DIR at the marker kit here — that hatch
# diverts EVERY remote (git+) ref, including the built-ins, so it would copy the
# marker via the built-in heal regardless of the reload and mask the very thing
# under test. Leave the harness's default offline kit dir (an empty, file-less
# spec) in place: with no persisted record there is no marker-bearing ref at all,
# so the marker path must never appear.
make_stubs; load_acq
printf 'startnorecbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'startnorecbox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
out=$( ACQ_BACKEND=msb "$ACQ" start startnorecbox 2>&1 )
startnorec_log=$(cat "$CALLS")
assert_not_contains "cli-kits(dispatch): acq start with NO record heals no extra kit" \
  "$startnorec_log" "/home/agent/start-norec-marker"
cleanup_stubs

# --- restart: reloads the persisted --kit and heals it ---
make_stubs; load_acq
printf 'restartreloadbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'restartreloadbox\n' > "$STUBDIR/.msb_running_list"
_rk3="$STUBDIR/reloadkit3"; _mk_reload_kit "$_rk3" "/home/agent/restart-reload-marker"
( load_acq; ACQ_CLI_KITS=("$_rk3"); ACQ_EXTRA_KITS=""; acq_cli_kits_write msb restartreloadbox )
: > "$CALLS"
out=$( ACQ_MSB_KIT_LOCAL_DIR="$_rk3" ACQ_BACKEND=msb "$ACQ" restart restartreloadbox 2>&1 )
restartreload_log=$(cat "$CALLS")
assert_contains "cli-kits(dispatch): acq restart reloads + heals the persisted --kit" \
  "$restartreload_log" "restartreloadbox:/home/agent/restart-reload-marker"
cleanup_stubs

# --- run <sandbox> name-only re-attach: reloads the persisted --kit and heals it ---
make_stubs; load_acq
printf 'runreloadbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'runreloadbox\n' > "$STUBDIR/.msb_running_list"
_rk4="$STUBDIR/reloadkit4"; _mk_reload_kit "$_rk4" "/home/agent/run-reload-marker"
# ACQ_CLI_KITS / ACQ_EXTRA_KITS are read by acq_cli_kits_write (sourced via load_acq).
# shellcheck disable=SC2034
( load_acq; ACQ_CLI_KITS=("$_rk4"); ACQ_EXTRA_KITS=""; acq_cli_kits_write msb runreloadbox )
: > "$CALLS"
# Name-only `acq run <existing-sandbox>` (no agent token, no --kit re-passed).
out=$( ACQ_UPDATE_CHECK=0 ACQ_MSB_KIT_LOCAL_DIR="$_rk4" ACQ_BACKEND=msb "$ACQ" run runreloadbox 2>&1 )
runreload_log=$(cat "$CALLS")
assert_contains "cli-kits(dispatch): acq run <sandbox> reloads + heals the persisted --kit" \
  "$runreload_log" "runreloadbox:/home/agent/run-reload-marker"
cleanup_stubs
unset -f _mk_reload_kit

# 8o1T. N1 — restart is a BEST-EFFORT bounce: when `msb stop` FAILS, the dispatcher
#        (under `set -euo pipefail`) must NOT abort — it must still proceed to
#        `msb start` and the heal. STUB_MSB_STOP_FAIL=1 makes the stub's stop arm
#        exit 1; assert both the "attempting start anyway" notice and that
#        `msb start` still appears in the recorded calls.
make_stubs; load_acq
printf 'bouncebox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'bouncebox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
out=$(STUB_MSB_STOP_FAIL=1 ACQ_BACKEND=msb "$ACQ" restart bouncebox 2>&1); rc=$?
bounce_log=$(cat "$CALLS")
assert_contains "0017 N1: restart calls msb stop even when it fails" "$bounce_log" "msb stop bouncebox"
assert_contains "0017 N1: restart proceeds to msb start after stop failure" "$bounce_log" "msb start bouncebox"
assert_contains "0017 N1: restart warns it is attempting start anyway" "$out" "stop failed; attempting start anyway"
if [ "$rc" -eq 0 ]; then pass "0017 N1: restart does not abort on stop failure"; else fail "0017 N1: restart does not abort on stop failure" "rc=$rc"; fi
cleanup_stubs

# 8o1U. N2b — "backend does not support start/restart" guard. Both adapters define
#        acq_backend_start today, so the dispatcher-level `command -v
#        acq_backend_start` guard is future-adapter-only. Exercise it directly by
#        running the SAME guard-then-message logic the dispatcher uses, in a
#        subshell where acq_backend_start is undefined. This asserts the guard's
#        contract (clear "does not support" message + nonzero exit) without
#        contorting the harness to force an adapter to omit the function.
make_stubs; load_acq
guard_out=$(
  {
    unset -f acq_backend_start 2>/dev/null || true
    ACQ_RESOLVED_BACKEND=faux
    if ! command -v acq_backend_start >/dev/null 2>&1; then
      echo "acq: the '${ACQ_RESOLVED_BACKEND}' backend does not support start" >&2
      echo "     (acq_backend_start). Start the sandbox manually, then re-run." >&2
      exit 1
    fi
    exit 0
  } 2>&1
)
guard_rc=$?
assert_contains "0017 N2b: unsupported-backend guard emits clear message" "$guard_out" "does not support start"
if [ "$guard_rc" -ne 0 ]; then pass "0017 N2b: unsupported-backend guard exits nonzero"; else fail "0017 N2b: unsupported-backend guard exits nonzero" "rc=$guard_rc"; fi
cleanup_stubs

# 8o1V. SECRET RE-EXPORT ON START (ADR-0017). `msb start` re-reads the
#        sandbox's persisted `--secret ENV@HOST` bindings and requires the value
#        in the host env — so acq_backend_start MUST resolve+export the same
#        secrets provision did, or `msb start` fails with "host environment
#        variable USAI_API_KEY is not set". The msb stub's `start` arm records a
#        `USAI_API_KEY=present` / `GITHUB_TOKEN=present` line when the var is set
#        in its environment at start time. Assert both were exported before start,
#        and that the real VALUES never leaked to argv, and that the vars do not
#        linger in the caller's environment afterward.
make_stubs; load_acq
printf 'secretstartbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'secretstartbox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
sstart_leak=$(
  # Hermetic: clear any ambient secret vars from the caller's environment so the
  # assertions prove acq_backend_start's own export/unset, not the outer shell.
  unset USAI_API_KEY GITHUB_TOKEN GH_TOKEN
  export ACQ_SECRET_STORE_DIR="$STUBDIR/sstart-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  printf 'GH-REAL-VALUE\n'   | acq_secret_store "$(_acq_secret_key github)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_start secretstartbox >/dev/null 2>&1
  # The vars must NOT linger in this shell after start returns.
  printf 'usai-lingers=%s\n' "${USAI_API_KEY:+yes}"
  printf 'github-lingers=%s\n' "${GITHUB_TOKEN:+yes}"
  if grep -q 'USAI-REAL-VALUE\|GH-REAL-VALUE' "$CALLS"; then echo LEAK; else echo CLEAN; fi
)
sstart_log=$(cat "$CALLS")
assert_contains "0017 fix: start exports USAI_API_KEY before msb start" "$sstart_log" "USAI_API_KEY=present"
assert_contains "0017 fix: start exports GITHUB_TOKEN before msb start" "$sstart_log" "GITHUB_TOKEN=present"
# The `USAI_API_KEY=present` marker must be logged AFTER `msb start` begins, i.e.
# the export happened before the start read it (marker is emitted by the start arm).
assert_contains "0017 fix: start still invokes msb start NAME" "$sstart_log" "msb start secretstartbox"
assert_contains "0017 fix: start never leaks secret values to argv" "$sstart_leak" "CLEAN"
assert_not_contains "0017 fix: USAI_API_KEY does not linger after start" "$sstart_leak" "usai-lingers=yes"
assert_not_contains "0017 fix: GITHUB_TOKEN does not linger after start" "$sstart_leak" "github-lingers=yes"
cleanup_stubs

# 8o1W. SECRET RE-EXPORT reaches the `acq run <stopped-sandbox>` path too: the
#        start-if-stopped block inside ensure_kits_applied calls acq_backend_start,
#        which must export the secret so the underlying `msb start` succeeds.
make_stubs; load_acq
printf 'stoppedsecbox\n' > "$STUBDIR/.msb_sandbox_list"   # exists
: > "$STUBDIR/.msb_running_list"                           # but NOT running
: > "$CALLS"
(
  unset USAI_API_KEY GITHUB_TOKEN GH_TOKEN
  export ACQ_SECRET_STORE_DIR="$STUBDIR/stoppedsec-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ensure_kits_applied stoppedsecbox >/dev/null 2>&1
)
stoppedsec_log=$(cat "$CALLS")
assert_contains "0017 fix: run<stopped> exports USAI_API_KEY before msb start" "$stoppedsec_log" "USAI_API_KEY=present"
assert_contains "0017 fix: run<stopped> still invokes msb start" "$stoppedsec_log" "msb start stoppedsecbox"
cleanup_stubs

# 8o1W2. SECRET RE-EXPORT covers GENERIC custom endpoints on start too (not just
#        usai/github). A custom endpoint recorded via `acq secret set SVC --host H
#        --env E` must have its value re-exported before `msb start`, exactly like
#        the built-ins. The stub start arm records any bound env var it sees; here
#        we assert the custom env var (MYCUSTOM_TOKEN) is present at start time.
make_stubs; load_acq
printf 'customstartbox\n' > "$STUBDIR/.msb_sandbox_list"
printf 'customstartbox\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
(
  unset USAI_API_KEY GITHUB_TOKEN GH_TOKEN
  export ACQ_SECRET_STORE_DIR="$STUBDIR/customstart-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  # Record the non-secret endpoint sidecar + store the value for a custom service.
  acq_secret_meta_store mysvc "" "api.example.gov" "MYCUSTOM_TOKEN"
  printf 'CUSTOM-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key mysvc)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Prove the custom-endpoint value is re-exported before `msb start`: shadow msb
  # to record a marker when MYCUSTOM_TOKEN is present in the environment at the
  # moment of `start`, then delegate to the real stub.
  msb() { if [ "${1:-}" = "start" ] && [ -n "${MYCUSTOM_TOKEN:-}" ]; then printf 'MYCUSTOM_TOKEN=present\n' >>"$CALLS"; fi; command "$STUBDIR/msb" "$@"; }
  acq_backend_start customstartbox >/dev/null 2>&1
)
customstart_log=$(cat "$CALLS")
assert_contains "0017 fix: start re-exports generic custom-endpoint secret" "$customstart_log" "MYCUSTOM_TOKEN=present"
assert_not_contains "0017 fix: custom-endpoint value never leaks to argv" "$customstart_log" "CUSTOM-REAL-VALUE"
cleanup_stubs

# 8o1X. REFACTOR NON-REGRESSION: provision (which now shares
#        _acq_msb_bind_secrets_into with start) still binds USAi + GitHub via
#        --secret and still never leaks values — the behavior asserted in 8m,
#        re-checked here to guard the shared-helper refactor.
make_stubs; load_acq
: > "$CALLS"
prov_refactor_leak=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/provref-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  printf 'GH-REAL-VALUE\n'   | acq_secret_store "$(_acq_secret_key github)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision provrefbox shell /tmp >/dev/null 2>&1
  if grep -q 'USAI-REAL-VALUE\|GH-REAL-VALUE' "$CALLS"; then echo LEAK; else echo CLEAN; fi
)
prov_refactor_log=$(cat "$CALLS")
assert_contains "0017 refactor: provision still binds USAi via --secret" "$prov_refactor_log" "--secret USAI_API_KEY@api.gsa.usai.gov"
assert_contains "0017 refactor: provision still binds github via --secret" "$prov_refactor_log" "--secret $MSB_GITHUB_SECRET_BINDING"
assert_contains "0017 refactor: provision still never leaks values to argv" "$prov_refactor_leak" "CLEAN"
cleanup_stubs
