#!/usr/bin/env bash
#
# 70-msb-backend — resolution, dispatch, doctor/list, secret set
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 8. msb backend — resolution, dispatch, doctor/list, version
# ===========================================================================

# 8a. Auto-detect prefers msb when both present (no existing sbx sandboxes).
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
  rm -f "$STUBDIR/.sandbox_list"    # sbx ls -q empty -> no sbx sandboxes to keep
  PATH="$STUBDIR:$PATH"; export PATH   # stub sbx (for `sbx ls -q`) wins
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  _auto_detect_backend
  assert_eq "msb: auto-detect prefers msb over sbx" "msb" "$ACQ_AUTODETECT_BACKEND"
  assert_eq "msb: auto-detect reason both-msb" "both-msb" "$ACQ_AUTODETECT_REASON"
) 2>/dev/null; pass "msb: auto-detect order msb>sbx (both stubbed)"
cleanup_stubs

# 8b. Auto-detect falls back to sbx when only sbx is present.
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  # Pin which backends auto-detect "sees" via the test override rather than
  # PATH: a real msb on the developer's PATH (esp. beside Homebrew coreutils)
  # would otherwise leak in and flip this sbx-only case to both-*.
  export ACQ_TEST_INSTALLED_BACKENDS="sbx"
  # shellcheck disable=SC1090
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  # shellcheck source=acq.backends/sbx.sh
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  set +e
  _auto_detect_backend
  assert_eq "msb: auto-detect falls back to sbx" "sbx" "$ACQ_AUTODETECT_BACKEND"
  assert_eq "msb: auto-detect reason sbx-only" "sbx-only" "$ACQ_AUTODETECT_REASON"
) 2>/dev/null; pass "msb: auto-detect fallback to sbx (msb absent)"
cleanup_stubs

# 8c. --backend msb resolves and loads the msb adapter.
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  # shellcheck disable=SC1090
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  # shellcheck source=acq.backends/msb.sh
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  acq_resolve_backend "msb"
  assert_eq "msb: --backend msb resolves" "msb" "$ACQ_RESOLVED_BACKEND"
) 2>/dev/null; pass "msb: --backend msb accepted"
cleanup_stubs

# 8c1. Capability flags: msb advertises SUPPORTS_SNAPSHOTS=0. msb DOES have
#      a `msb snapshot` verb, but acq exposes no `snapshot` command and wiring one
#      is beyond sbx parity — so the matrix reflects what acq surfaces, not what
#      msb can do. Load the adapter in a subshell and read the declared flag.
make_stubs; load_acq
snap_flag=$(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  printf '%s' "$ACQ_BACKEND_SUPPORTS_SNAPSHOTS"
)
assert_eq "msb: SUPPORTS_SNAPSHOTS=0 (matches acq's surfaced verbs, #225)" "0" "$snap_flag"
cleanup_stubs

# 8d. Dispatch: `acq --backend msb ls` calls `msb list` (or ls alias).
make_stubs
out=$(ACQ_BACKEND=msb "$ACQ" ls 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "msb: ls -> msb list" "$log" "msb list"
cleanup_stubs

# 8e. Dispatch: `acq --backend msb stop mybox` calls `msb stop`.
make_stubs
out=$(ACQ_BACKEND=msb "$ACQ" stop mybox 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "msb: stop -> msb stop" "$log" "msb stop mybox"
cleanup_stubs

# 8f. Dispatch: `acq --backend msb rm mybox` calls `msb remove --force`.
make_stubs
out=$(ACQ_BACKEND=msb "$ACQ" rm mybox 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "msb: rm -> msb remove --force" "$log" "msb remove --force mybox"
cleanup_stubs

# 8g. Dispatch: `acq --backend msb exec mybox -- echo hi` calls `msb exec` as the
#      agent user (-u agent, HOME=/home/agent) — never root (see 8n6b). Flags
#      precede NAME; the `-- CMD` passthrough follows NAME unchanged.
make_stubs
out=$(ACQ_BACKEND=msb "$ACQ" exec mybox -- echo hi 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "msb: exec -> msb exec (as agent, HOME set)" "$log" "msb exec -u agent -e HOME=/home/agent mybox -- echo hi"
cleanup_stubs

# 8h. `acq --backend msb version` reports msb backend + version.
make_stubs
out=$(ACQ_BACKEND=msb "$ACQ" version 2>&1)
assert_contains "msb: version reports backend msb" "$out" "backend:     msb"
assert_contains "msb: version reports msb ver" "$out" "0.6.9"
cleanup_stubs

# 8i. `acq backend list` shows a real msb row (not "coming in 1.2.x").
make_stubs
out=$("$ACQ" backend list 2>&1)
assert_contains "msb: backend list shows msb version" "$out" "msb  v0.6.9"
assert_not_contains "msb: backend list drops 'coming in 1.2.x'" "$out" "Coming in 1.2.x"
cleanup_stubs

# 8i2. `acq backend set NAME` persists, then `acq backend unset` clears it so
#      resolution falls back to auto-detect. Uses an isolated XDG config dir.
make_stubs
(
  export XDG_CONFIG_HOME="$STUBDIR/xdg"
  cfg="$XDG_CONFIG_HOME/acq/config.yaml"
  "$ACQ" backend set sbx >/dev/null 2>&1
  [ -f "$cfg" ] && grep -q '^backend: sbx' "$cfg" && printf 'set=yes\n' || printf 'set=no\n'
  "$ACQ" backend unset >/dev/null 2>&1
  [ -f "$cfg" ] && printf 'file-after=present\n' || printf 'file-after=gone\n'
  # unset is idempotent: a second call still succeeds.
  "$ACQ" backend unset >/dev/null 2>&1 && printf 'unset-idempotent=yes\n' || printf 'unset-idempotent=no\n'
) > "$STUBDIR/bu.out" 2>&1
bu_out=$(cat "$STUBDIR/bu.out")
assert_contains "backend set: persists to config" "$bu_out" "set=yes"
assert_contains "backend unset: removes the config" "$bu_out" "file-after=gone"
assert_contains "backend unset: idempotent" "$bu_out" "unset-idempotent=yes"
cleanup_stubs

# 8j. `acq doctor` probes msb with a real version (not the old placeholder).
make_stubs
out=$(printf 'n\n' | "$ACQ" doctor 2>&1)
assert_contains "msb: doctor shows msb installed" "$out" "msb: installed v0.6.9"
assert_not_contains "msb: doctor drops 'coming in 1.2.x'" "$out" "coming in 1.2.x"
cleanup_stubs

# 8j2. acq runs the msb host-readiness check itself (no manual `msb doctor`
#      step). Happy path: host ready -> acq_backend_prepare is SILENT.
make_stubs; load_acq
(
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  out=$(acq_backend_prepare 2>&1)
  assert_not_contains "msb: ready host -> prepare is silent" "$out" "isn't ready"
) 2>/dev/null; pass "msb: host-readiness check silent on the happy path"
cleanup_stubs

# 8j3. Host unfit but fixable: acq runs `msb doctor --fix` itself and, once the
#      re-check passes, stays SILENT (user does nothing, sees nothing).
make_stubs; load_acq
(
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  out=$(STUB_MSB_DOCTOR_FIXABLE=1 acq_backend_prepare 2>&1)
  log=$(cat "$CALLS")
  assert_contains "msb: prepare auto-runs 'msb doctor --fix'" "$log" "msb doctor --fix"
  # The host-mutating --fix must be ANNOUNCED on stderr before it runs (never a
  # silent infra change), and name the opt-out.
  assert_contains "msb: announces before running --fix" "$out" "running 'msb doctor --fix'"
  assert_contains "msb: announcement names the opt-out" "$out" "ACQ_SKIP_MSB_DOCTOR=1"
  assert_not_contains "msb: fixable host -> no not-ready message after --fix" "$out" "isn't ready"
) 2>/dev/null; pass "msb: auto-fixes a fixable host and stays silent"
cleanup_stubs

# 8j4. Host unfit and NOT fixable: after auto --fix fails, acq surfaces ONE clear
#      not-ready message pointing at help — and does not hard-fail (exit 0).
make_stubs; load_acq
(
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  out=$(STUB_MSB_DOCTOR_UNFIT=1 acq_backend_prepare 2>&1); rc=$?
  assert_contains "msb: unfit host -> clear not-ready message" "$out" "isn't ready to run microVMs"
  assert_contains "msb: unfit host -> points at help" "$out" "agentic-coding@gsa.gov"
  assert_eq "msb: readiness check does not hard-fail" "0" "$rc"
) 2>/dev/null; pass "msb: unfit host surfaces one actionable message, no hard-fail"
cleanup_stubs

# 8j5. ACQ_SKIP_MSB_DOCTOR=1 opts out of the readiness check entirely.
make_stubs; load_acq
(
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  out=$(STUB_MSB_DOCTOR_UNFIT=1 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1)
  log=$(cat "$CALLS")
  assert_not_contains "msb: skip flag -> no not-ready message" "$out" "isn't ready"
  assert_not_contains "msb: skip flag -> no doctor call" "$log" "msb doctor"
) 2>/dev/null; pass "msb: ACQ_SKIP_MSB_DOCTOR opts out of the readiness check"
cleanup_stubs

# 8j5b. Version floor (BLOCKING fix): the balanced-egress default emits
#        `--net-default-egress deny` (first in msb 0.6.8) AND relies on the
#        semantic `allow@dns` macro, which only parses correctly on release
#        builds from msb 0.6.9 onward (the upstream release-build parser fix).
#        MIN_MSB_VERSION is therefore 0.6.9, so acq_backend_prepare MUST fail
#        closed (nonzero exit + clear message) on any binary older than 0.6.9,
#        rather than letting `msb create` hit an unknown flag or DNS parse error
#        mid-create. The stub honors STUB_MSB_VERSION.
make_stubs; load_acq
(
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  # A sub-floor binary (0.6.8, previously accepted) must now be rejected before
  # any create, because the 0.6.9 floor is required for the `allow@dns` macro.
  out=$(STUB_MSB_VERSION=0.6.8 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); rc=$?
  assert_eq "msb: sub-0.6.9 binary fails the version floor" "1" "$rc"
  assert_contains "msb: sub-floor message names the required version" "$out" "0.6.9"
  # The pinned/current floor version (0.6.9) passes.
  out2=$(STUB_MSB_VERSION=0.6.9 ACQ_SKIP_MSB_DOCTOR=1 acq_backend_prepare 2>&1); rc2=$?
  assert_eq "msb: 0.6.9 binary clears the version floor" "0" "$rc2"
  assert_not_contains "msb: 0.6.9 binary emits no version-floor error" "$out2" "0.6.9"
) 2>/dev/null; pass "msb: version floor rejects sub-0.6.9, accepts 0.6.9"
cleanup_stubs

# 8j5c. sbx version floor (BLOCKING): acq's neutral-kit translator emits the sbx
#        v2 kit grammar, which only sbx >= 0.38.0 accepts; older builds fail with
#        an opaque decode error ("field permissions not found") mid-create. So
#        MIN_SBX_VERSION is 0.38.0 and acq_backend_prepare MUST fail closed with a
#        clear, self-diagnosing message on a sub-floor sbx. The sbx stub honors
#        STUB_SBX_VERSION.
make_stubs; load_acq
(
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  set +e
  # A sub-floor binary (0.37.9) must be rejected before any create.
  out=$(STUB_SBX_VERSION=0.37.9 acq_backend_prepare 2>&1); rc=$?
  assert_eq "sbx: sub-0.38.0 binary fails the version floor" "1" "$rc"
  assert_contains "sbx: sub-floor message names the required version" "$out" "0.38.0"
  assert_contains "sbx: sub-floor message explains the v2 grammar cause" "$out" "v2 kit grammar"
  # The current floor version (0.38.0) passes silently.
  out2=$(STUB_SBX_VERSION=0.38.0 acq_backend_prepare 2>&1); rc2=$?
  assert_eq "sbx: 0.38.0 binary clears the version floor" "0" "$rc2"
  assert_not_contains "sbx: 0.38.0 binary emits no version-floor error" "$out2" "requires sbx"
) 2>/dev/null; pass "sbx: version floor rejects sub-0.38.0, accepts 0.38.0"
cleanup_stubs

# 8j6. The msb doctor calls redirect stdin from /dev/null, so a prompting
#      `msb doctor`/`--fix` cannot hang acq (the reviewer reproduced a real
#      indefinite hang here). The stub READS stdin when STUB_MSB_DOCTOR_READS_STDIN
#      is set. We give the run a stdin that never reaches EOF on its own (a
#      background sleep feeding a pipe): if acq failed to redirect the doctor
#      calls to </dev/null, the stub's `cat` would read that pipe and block until
#      the sleep ends. `timeout` turns any regression into a loud failure (124)
#      rather than a hung suite. Skipped only if `timeout` is unavailable.
if command -v timeout >/dev/null 2>&1; then
  make_stubs; load_acq
  hang_rc=0
  { sleep 30; } | timeout 8 sh -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'"
    . "'"${REPO_ROOT}"'/acq.backends/msb.sh"
    STUB_MSB_DOCTOR_FIXABLE=1 STUB_MSB_DOCTOR_READS_STDIN=1 acq_backend_prepare
  ' >/dev/null 2>&1 || hang_rc=$?
  # 124 = timed out (would-be hang -> redirect regression); anything else = returned.
  assert_not_contains "msb: doctor calls do not hang on open stdin" "TIMEOUT-$hang_rc" "TIMEOUT-124"
  cleanup_stubs
else
  pass "msb: msb doctor stdin-hang guard skipped (no 'timeout' available)"
fi

# 8k. msb secret set usai stores in the acq store + confirms concisely.
make_stubs
out=$(ACQ_SECRET_TEST_VALUE="my-usai-key" ACQ_BACKEND=msb "$ACQ" secret set -g usai 2>&1 || true)
assert_contains "msb: secret set usai confirms store" "$out" "acq secret store"
if [ -f "$STUBDIR/secrets/acq.usai" ]; then
  pass "msb: secret set usai stored in acq store"
else
  fail "msb: secret set usai stored in acq store" "acq.usai not found"
fi
cleanup_stubs

# 8l. msb secret set github stores in the acq store + confirms concisely.
make_stubs
out=$(ACQ_SECRET_TEST_VALUE="ghp_x" ACQ_BACKEND=msb "$ACQ" secret set -g github 2>&1 || true)
assert_contains "msb: secret set github confirms store" "$out" "acq secret store"
if [ -f "$STUBDIR/secrets/acq.github" ]; then
  pass "msb: secret set github stored in acq store"
else
  fail "msb: secret set github stored in acq store" "acq.github not found"
fi
cleanup_stubs
