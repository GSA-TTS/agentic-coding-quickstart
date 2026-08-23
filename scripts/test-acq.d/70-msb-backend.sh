#!/usr/bin/env bash
#
# 70-msb-backend — resolution, dispatch, doctor/list, provision
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

# 8m. msb provision binds USAi and GitHub via --secret ENV@HOST (with
#     --tls-intercept), and the real secret VALUES never appear in the msb
#     command line.
make_stubs; load_acq
: > "$CALLS"
prov_leaks=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/prov-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  printf 'GH-REAL-VALUE\n'   | acq_secret_store "$(_acq_secret_key github)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Avoid a real network kit fetch: resolve built-in kits to local dirs.
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision provbox shell /tmp >/dev/null 2>&1
  # Report whether real values leaked into the recorded msb calls.
  if grep -q 'USAI-REAL-VALUE\|GH-REAL-VALUE' "$CALLS"; then echo LEAK; else echo CLEAN; fi
)
prov_log=$(cat "$CALLS")
assert_contains "msb: provision enables --tls-intercept (needed for substitution)" "$prov_log" "--tls-intercept"
assert_contains "msb: provision binds USAi via --secret" "$prov_log" "--secret USAI_API_KEY@api.gsa.usai.gov"
# GitHub binds to both REST and git-transport hosts so msb can substitute for
# API calls, HTTPS clones, and HTTPS pushes.
assert_contains "msb: provision binds github to API and git hosts" "$prov_log" "--secret $MSB_GITHUB_SECRET_BINDING"
assert_eq "msb: provision never leaks secret values to argv" "CLEAN" "$prov_leaks"
# Workspace is mounted at the SAME absolute path in the guest (sbx-parity), not
# Workspace is mounted at the SAME absolute path in the guest (sbx-parity), not
# remapped under /home/agent (which fails to mount pre-user-create). acq
# canonicalizes the host path first (macOS /tmp -> /private/tmp symlink), so the
# assertion must compare against the canonicalized form, not the literal /tmp.
_prov_ws=$(canonicalize_path /tmp)
assert_contains "msb: workspace mounted at same guest path (sbx-parity)" "$prov_log" "--volume ${_prov_ws}:${_prov_ws}"
assert_not_contains "msb: workspace NOT remapped under /home/agent" "$prov_log" "--volume ${_prov_ws}:/home/agent/workspace"
# Default base image: msb defaults to the sbx agent-template image (which ships
# the `agent` user, sudo, prereqs, and an agent-writable npm prefix), matching
# sbx by construction. The image is the trailing positional on `msb create`.
assert_contains "msb: create uses the sbx agent-template default image" "$prov_log" "msb create --name provbox"
assert_contains "msb: default image is docker/sandbox-templates:shell-docker" "$prov_log" "docker.io/docker/sandbox-templates:shell-docker"
assert_not_contains "msb: default image is NOT plain node:22-bookworm" "$prov_log" "docker.io/library/node:22-bookworm"
cleanup_stubs

# 8m0a. TLS-intercept UPSTREAM CA trust (defense-in-depth). With an explicit
#        ACQ_MSB_UPSTREAM_CA_CERT PEM and interception ON (default), provision
#        emits `--tls-upstream-ca-cert <PEM>` so msb's host-side proxy trusts a
#        corporate root on its upstream leg. Uses an explicit path (portable;
#        avoids the macOS-only keychain auto-export).
make_stubs; load_acq
: > "$CALLS"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root.pem"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/upca-secrets"
  export ACQ_MSB_UPSTREAM_CA_CERT="$STUBDIR/corp-root.pem"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision upcabox shell /tmp >/dev/null 2>&1
)
upca_log=$(cat "$CALLS")
assert_contains "msb: emits --tls-upstream-ca-cert for explicit PEM (interception on)" "$upca_log" "--tls-upstream-ca-cert $STUBDIR/corp-root.pem"
cleanup_stubs

# 8m0b. The upstream CA is emitted ONLY when interception is on. With
#        ACQ_MSB_NO_TLS_INTERCEPT=1 there is no upstream leg to verify, so neither
#        --tls-intercept nor --tls-upstream-ca-cert appears — even with an
#        explicit PEM configured.
make_stubs; load_acq
: > "$CALLS"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root2.pem"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/upca2-secrets"
  export ACQ_MSB_UPSTREAM_CA_CERT="$STUBDIR/corp-root2.pem"
  export ACQ_MSB_NO_TLS_INTERCEPT=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision upca2box shell /tmp >/dev/null 2>&1
)
upca2_log=$(cat "$CALLS")
assert_not_contains "msb: no --tls-intercept when disabled" "$upca2_log" "--tls-intercept"
assert_not_contains "msb: no --tls-upstream-ca-cert when interception disabled" "$upca2_log" "--tls-upstream-ca-cert"
cleanup_stubs

# 8m0c. ACQ_MSB_NO_UPSTREAM_CA=1 suppresses the upstream CA even when a PEM is
#        configured and interception is on (reproduction/testing toggle).
make_stubs; load_acq
: > "$CALLS"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root3.pem"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/upca3-secrets"
  export ACQ_MSB_UPSTREAM_CA_CERT="$STUBDIR/corp-root3.pem"
  export ACQ_MSB_NO_UPSTREAM_CA=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision upca3box shell /tmp >/dev/null 2>&1
)
upca3_log=$(cat "$CALLS")
assert_contains "msb: interception still on under NO_UPSTREAM_CA" "$upca3_log" "--tls-intercept"
assert_not_contains "msb: NO_UPSTREAM_CA suppresses the upstream CA flag" "$upca3_log" "--tls-upstream-ca-cert"
cleanup_stubs


# 8m00. ACQ_MSB_IMAGE override: a user-supplied image is passed through verbatim
#       to `msb create` (plain-OCI overrides remain supported; the agent-user /
#       sudo synthesis handles them). Assert the override, not the default.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/imgover-secrets"
  export ACQ_MSB_IMAGE="docker.io/library/node:22-bookworm"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision imgoverbox shell /tmp >/dev/null 2>&1
)
imgover_log=$(cat "$CALLS")
assert_contains "msb: ACQ_MSB_IMAGE override passed through to create" "$imgover_log" "docker.io/library/node:22-bookworm"
assert_not_contains "msb: override suppresses the default image" "$imgover_log" "docker.io/docker/sandbox-templates:shell-docker"
cleanup_stubs

# 8m0. GENERIC custom endpoint binding: a service stored
#      via `acq secret set SVC --host H --env E` records a non-secret endpoint
#      sidecar; msb provision must then bind it generically via `--secret E@H`,
#      the real value never touching argv — mirroring usai/github which stay
#      bound exactly as before. A service with NO recorded host/env must NOT emit
#      a bogus flag (the old `*)`-arm empty behavior).
make_stubs; load_acq
: > "$CALLS"
gen_leaks=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/gen-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  # A custom endpoint stored via `acq secret set -g SBX --host … --env …`.
  ACQ_SECRET_TEST_VALUE="SBX-REAL-VALUE" acq_secret_set_interactive SBX "" "api.example.com" "API_KEY" >/dev/null 2>&1
  # usai + github so their explicit bindings still fire (regression guard).
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  printf 'GH-REAL-VALUE\n'   | acq_secret_store "$(_acq_secret_key github)"
  # A service stored with NO host/env sidecar (value only) — must NOT be bound.
  printf 'NOMAP-VALUE\n'     | acq_secret_store "$(_acq_secret_key nomap)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision genbox shell /tmp >/dev/null 2>&1
  # No real secret value may appear in the recorded msb calls.
  if grep -q 'SBX-REAL-VALUE\|USAI-REAL-VALUE\|GH-REAL-VALUE\|NOMAP-VALUE' "$CALLS"; then echo LEAK; else echo CLEAN; fi
)
gen_log=$(cat "$CALLS")
assert_contains "msb#226: custom endpoint bound generically (--secret API_KEY@api.example.com)" "$gen_log" "--secret API_KEY@api.example.com"
assert_contains "msb#226: usai still bound as before"   "$gen_log" "--secret USAI_API_KEY@api.gsa.usai.gov"
assert_contains "msb#226: github still bound as before" "$gen_log" "--secret $MSB_GITHUB_SECRET_BINDING"
# A value-only service (no host/env sidecar) must not emit a bogus flag.
assert_not_contains "msb#226: no bogus flag for service without host/env" "$gen_log" "--secret @"
assert_not_contains "msb#226: value-only service 'nomap' not bound" "$gen_log" "nomap"
assert_eq "msb#226: no secret value ever leaks to argv" "CLEAN" "$gen_leaks"
# Progress feedback (issue #287): the real provision path emits plain status
# lines on stderr even under the harness (non-TTY -> no animation, but the
# acq_status phase markers still print). Capture provision stderr and assert a
# couple of the phase markers are present, and that NO animation leaked.
make_stubs; load_acq
: > "$CALLS"
prog_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/prog-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision progbox opencode /tmp 2>&1 >/dev/null
)
assert_contains     "progress#287: provision announces sandbox creation" "$prog_err" "Creating sandbox"
assert_contains     "progress#287: provision announces the boot wait"     "$prog_err" "Waiting for the sandbox to finish booting"
assert_not_contains "progress#287: provision leaks no spinner frame"      "$prog_err" "⠋"
assert_not_contains "progress#287: provision leaks no carriage return"    "$prog_err" "$(printf '\r')"
cleanup_stubs

# 8m0b. The endpoint sidecar is NON-SECRET (host + env only) and 0600. Setting a
#       custom endpoint must NOT persist the value in the sidecar file.
make_stubs; load_acq
side_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/side-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  ACQ_SECRET_TEST_VALUE="SIDE-SECRET-VALUE" acq_secret_set_interactive SBX "" "api.example.com" "API_KEY" >/dev/null 2>&1
  # Resolve the sidecar back (host<TAB>env) and show it (safe — non-secret).
  printf 'meta=%s\n' "$(acq_secret_meta_resolve SBX | tr '\t' '/')"
  # The sidecar file itself must not contain the secret value.
  metafile="$STUBDIR/side-secrets/meta/acq.SBX"
  if [ -f "$metafile" ] && grep -q 'SIDE-SECRET-VALUE' "$metafile"; then echo VALUE_IN_META; else echo META_CLEAN; fi
  # Perms are 0600.
  stat -c '%a' "$metafile" 2>/dev/null || stat -f '%Lp' "$metafile" 2>/dev/null || echo "?"
)
assert_contains "msb#226: sidecar resolves host/env" "$side_out" "meta=api.example.com/API_KEY"
assert_contains "msb#226: sidecar never stores the secret value" "$side_out" "META_CLEAN"
assert_contains "msb#226: sidecar file is 0600" "$side_out" "600"
cleanup_stubs

# 8m0c. `acq secret set -g SBX --host … --env …` on the msb backend (through the
#       real dispatcher) records the sidecar AND live-binds a running sandbox via
#       `msb modify <box> --secret API_KEY@api.example.com`, value never on argv.
make_stubs; load_acq
printf 'genrunbox\n' > "$STUBDIR/.msb_sandbox_list"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/genrun-secrets"
  export ACQ_SECRET_TEST_VALUE="GENRUN-SECRET"
  ACQ_BACKEND=msb "$ACQ" secret set genrunbox SBX --host api.example.com --env API_KEY >/dev/null 2>&1
)
genrun_log=$(cat "$CALLS")
assert_contains "msb#226: custom endpoint live-binds running sandbox" "$genrun_log" "msb modify genrunbox --secret API_KEY@api.example.com"
if grep -q 'GENRUN-SECRET' "$CALLS"; then
  fail "msb#226: custom endpoint value must NOT appear in msb argv" "leaked into $CALLS"
else
  pass "msb#226: custom endpoint value never leaks to msb argv (passed via env)"
fi
cleanup_stubs

# 8m0d. Dotted service/sandbox names cannot make the
#       shared `acq.<sandbox>.<service>` key non-injective. A GLOBAL service
#       literally named "foo.bar" and a SCOPED service "bar" in sandbox "foo"
#       would BOTH map to the key `acq.foo.bar` — colliding in the value store
#       and mis-scoped by meta_list's old "split on the first dot". The store
#       now fails closed on a dotted name (the choke point both stores share),
#       and meta_list anchors scope on the requested sandbox rather than
#       guessing from the first dot. These prove: (a) a dotted name is refused
#       at the store boundary — the public `acq secret set` path cannot reach a
#       collision; (b) meta_list + meta_resolve AGREE on scope; (c) scoped vs
#       global services never collide.
make_stubs
dot_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dot-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"

  # (a) _acq_secret_key fails closed on a dotted service or sandbox — the single
  # choke point both the value store and the meta sidecar route through.
  if _acq_secret_key 'foo.bar' >/dev/null 2>&1; then printf 'key-dotted-svc=allowed\n'; else printf 'key-dotted-svc=refused\n'; fi
  if _acq_secret_key 'svc' 'my.box' >/dev/null 2>&1; then printf 'key-dotted-sb=allowed\n'; else printf 'key-dotted-sb=refused\n'; fi
  # A normal (dot-free) name still works.
  printf 'key-ok=%s\n' "$(_acq_secret_key 'svc' 'mybox')"

  # (a') The public set path (acq_secret_set_interactive) refuses a dotted
  # service and stores NOTHING (no aliased value, no sidecar).
  ACQ_SECRET_TEST_VALUE='V' acq_secret_set_interactive 'foo.bar' '' 'api.example.com' 'API_KEY' >/dev/null 2>&1 \
    && printf 'set-dotted=stored\n' || printf 'set-dotted=refused\n'
  # meta_store directly also refuses it (defense in depth).
  acq_secret_meta_store 'foo.bar' '' 'api.example.com' 'API_KEY' >/dev/null 2>&1 \
    && printf 'meta-dotted=stored\n' || printf 'meta-dotted=refused\n'

  # (b) + (c): a GLOBAL service "gsvc", a service "svc" scoped to sandbox "foo",
  # and a service "svc" scoped to a DIFFERENT sandbox "otherbox". meta_list for
  # sandbox "foo" must show the global + foo-scoped services and NOT otherbox's;
  # meta_resolve must agree for each listed entry, and the scoped/global "svc"
  # values must NOT collide.
  ACQ_SECRET_TEST_VALUE='GV'  acq_secret_set_interactive 'gsvc' ''         'api.g.com' 'GKEY' >/dev/null 2>&1
  ACQ_SECRET_TEST_VALUE='FV'  acq_secret_set_interactive 'svc'  'foo'      'api.f.com' 'FKEY' >/dev/null 2>&1
  ACQ_SECRET_TEST_VALUE='OV'  acq_secret_set_interactive 'svc'  'otherbox' 'api.o.com' 'OKEY' >/dev/null 2>&1

  printf 'list-foo=[%s]\n'   "$(acq_secret_meta_list foo | sort | tr '\n' ' ')"
  printf 'list-none=[%s]\n'  "$(acq_secret_meta_list    | sort | tr '\n' ' ')"

  # meta_list(foo) lists a service iff meta_resolve(service, foo) finds it: agreement.
  agree=yes
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    acq_secret_meta_resolve "$s" foo >/dev/null 2>&1 || agree=no
  done <<LIST
$(acq_secret_meta_list foo)
LIST
  printf 'list-resolve-agree=%s\n' "$agree"

  # scoped vs global "svc" resolve to their OWN hosts — no collision.
  printf 'resolve-foo-svc=%s\n'    "$(acq_secret_meta_resolve svc foo | cut -f1)"
  printf 'resolve-global-svc=%s\n' "$(acq_secret_meta_resolve svc | cut -f1 || echo NONE)"
  # A global "svc" was never set (only scoped) — meta_resolve svc (no sandbox)
  # must NOT leak foo's or otherbox's scoped sidecar.
  acq_secret_meta_resolve svc >/dev/null 2>&1 && printf 'global-svc-exists=yes\n' || printf 'global-svc-exists=no\n'

  # Value store must NOT collide either: global "foo.bar" was refused, so the
  # scoped ("svc"@"foo") and global ("gsvc") values stand alone.
  printf 'val-foo-svc=%s\n' "$(acq_secret_resolve svc foo)"
  printf 'val-gsvc=%s\n'    "$(acq_secret_resolve gsvc)"
)
assert_contains "234: dotted service name refused at key layer"        "$dot_out" "key-dotted-svc=refused"
assert_contains "234: dotted sandbox name refused at key layer"        "$dot_out" "key-dotted-sb=refused"
assert_contains "234: dot-free name still keys as acq.<sandbox>.<svc>" "$dot_out" "key-ok=acq.mybox.svc"
assert_contains "234: public set refuses dotted service (nothing stored)" "$dot_out" "set-dotted=refused"
assert_contains "234: meta_store refuses dotted service"               "$dot_out" "meta-dotted=refused"
assert_contains "234: meta_list(foo) shows global service"             "$dot_out" "gsvc"
assert_contains "234: meta_list(foo) shows foo-scoped service"         "$dot_out" "list-foo=[gsvc svc ]"
assert_contains "234: meta_list(none) shows only global service"       "$dot_out" "list-none=[gsvc ]"
assert_contains "234: meta_list and meta_resolve agree on scope"       "$dot_out" "list-resolve-agree=yes"
assert_contains "234: foo-scoped svc resolves to foo host"             "$dot_out" "resolve-foo-svc=api.f.com"
assert_contains "234: no global svc leaks from a scoped-only service"  "$dot_out" "global-svc-exists=no"
assert_contains "234: value store — foo-scoped svc value intact"       "$dot_out" "val-foo-svc=FV"
assert_contains "234: value store — global gsvc value intact"          "$dot_out" "val-gsvc=GV"
cleanup_stubs

# 8m0e. Backward-compat: a LEGACY dotted-global sidecar written
#       by an OLDER build (e.g. the file `acq.foo.bar`, from before the store
#       rejected dotted names) must never crash meta_list and must never be
#       mis-bound. Under the requested sandbox "mybox" (which does not match the
#       leading "foo" segment) it is simply not listed — the old "split on first
#       dot" would have mis-scoped it as sandbox=foo/service=bar for ANY caller;
#       now it is inert unless a caller explicitly targets that exact prefix.
make_stubs
legacy_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/legacy-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  mkdir -p "$ACQ_SECRET_META_DIR"
  # Plant a legacy dotted-global sidecar directly (bypassing the new guard).
  printf 'api.example.com\tAPI_KEY\n' > "$ACQ_SECRET_META_DIR/acq.foo.bar"
  # Also a normal current-build global so we prove listing still works.
  ACQ_SECRET_TEST_VALUE='V' acq_secret_set_interactive 'clean' '' 'api.clean.com' 'CKEY' >/dev/null 2>&1
  # meta_list for an unrelated sandbox: no crash, legacy dotted key not surfaced
  # as a bogus composite, clean global still listed.
  printf 'list-mybox=[%s]\n' "$(acq_secret_meta_list mybox | sort | tr '\n' ' ')"
  printf 'list-none=[%s]\n'  "$(acq_secret_meta_list       | sort | tr '\n' ' ')"
)
assert_contains "234(compat): legacy dotted global not mis-listed for unrelated sandbox" "$legacy_out" "list-mybox=[clean ]"
assert_contains "234(compat): legacy dotted global not mis-listed globally"             "$legacy_out" "list-none=[clean ]"
cleanup_stubs

# 8m0f. `acq secret ls` (msb): lists acq-managed secrets — scope, service, whether
#       a VALUE is present, and the ENV@HOST binding — and NEVER prints a value.
#       Covers a global built-in (usai), a global custom endpoint (its sidecar
#       binding), and a scoped built-in (github). Also checks scope filtering.
make_stubs; load_acq
ls_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ls-secrets"
  export ACQ_SECRET_TEST_VALUE="LS-SECRET-VALUE"
  ACQ_BACKEND=msb "$ACQ" secret set -g usai >/dev/null 2>&1
  ACQ_BACKEND=msb "$ACQ" secret set -g myapi --host api.example.com --env API_KEY >/dev/null 2>&1
  ACQ_BACKEND=msb "$ACQ" secret set lsbox github >/dev/null 2>&1
  echo "=== all ==="
  ACQ_BACKEND=msb "$ACQ" secret ls 2>&1
  echo "=== global ==="
  ACQ_BACKEND=msb "$ACQ" secret ls -g 2>&1
  echo "=== scoped ==="
  ACQ_BACKEND=msb "$ACQ" secret ls lsbox 2>&1
)
assert_contains "secret ls(msb): header present"              "$ls_out" "SCOPE"
assert_contains "secret ls(msb): global usai binding shown"   "$ls_out" "USAI_API_KEY@api.gsa.usai.gov"
assert_contains "secret ls(msb): global custom endpoint shown" "$ls_out" "API_KEY@api.example.com"
assert_contains "secret ls(msb): scoped github row shown"     "$ls_out" "$MSB_GITHUB_SECRET_BINDING"
# The value must NEVER be printed by `ls`.
assert_not_contains "secret ls(msb): never prints a secret value" "$ls_out" "LS-SECRET-VALUE"
# Scope filtering: `-g` excludes the scoped github row; `lsbox` includes only it.
g_only=$(printf '%s\n' "$ls_out" | sed -n '/=== global ===/,/=== scoped ===/p')
assert_not_contains "secret ls -g(msb): excludes scoped github" "$g_only" "$MSB_GITHUB_SECRET_BINDING"
s_only=$(printf '%s\n' "$ls_out" | sed -n '/=== scoped ===/,$p')
assert_contains     "secret ls SANDBOX(msb): includes scoped github" "$s_only" "$MSB_GITHUB_SECRET_BINDING"
assert_not_contains "secret ls SANDBOX(msb): excludes global usai"   "$s_only" "USAI_API_KEY@api.gsa.usai.gov"
cleanup_stubs

# 8m0g. `acq secret ls` with an empty store prints just the header (exit 0, no
#       rows, no crash).
make_stubs; load_acq
empty_ls=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/empty-ls-secrets"
  ACQ_BACKEND=msb "$ACQ" secret ls 2>&1
)
empty_rc=$?
assert_contains "secret ls(msb): empty store still prints header" "$empty_ls" "SCOPE"
assert_eq "secret ls(msb): empty store exits 0" "0" "$empty_rc"
cleanup_stubs

# 8m0h. acq_secret_list_keys on a keychain-linux backend. The bug: list_keys
#       enumerated ONLY the file directory, but on keychain-linux the values live
#       in the Linux keychain (via secret-tool), never the file dir — so `ls`
#       showed no rows. The fix makes list_keys backend-aware and enumerates the
#       keychain store via an acq-maintained NON-SECRET key index.
#
#       We simulate keychain-linux fully offline with a `secret-tool` STUB that
#       stores attr/value to a stub dir and looks them up, plus overriding
#       _acq_secret_backend to return keychain-linux (the harness otherwise
#       forces the file backend via ACQ_SECRET_STORE_DIR — we keep that env for
#       the index/meta paths, but the value store routes through the stub).
make_stubs; load_acq
# Stub secret-tool: store attr+value under a per-key file (value contents are
# opaque to enumeration — the fix relies on the acq key index, not on scraping
# secret-tool), lookup returns the stored value, clear removes it.
cat >"$STUBDIR/secret-tool" <<'STSTUB'
#!/usr/bin/env bash
# Minimal libsecret-like stub. Store keys under $STUBDIR/st-store keyed by the
# acq_key attribute value. Values are held only to answer lookup — the acq fix
# does NOT enumerate via this stub, so no wildcard/search enumeration is needed.
_dir="${STUBDIR}/st-store"
mkdir -p "$_dir" 2>/dev/null || true
_keyfile() {
  # $1 = acq_key value; make it filesystem-safe.
  printf '%s/%s' "$_dir" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}
case "${1:-}" in
  store)
    # secret-tool store --label=… acq_key <key>   (value on stdin)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    [ -n "$_k" ] || exit 1
    cat > "$(_keyfile "$_k")"
    exit 0 ;;
  lookup)
    # secret-tool lookup acq_key <key>
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    _f="$(_keyfile "$_k")"
    [ -f "$_f" ] || exit 1
    cat "$_f"; exit 0 ;;
  clear)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    rm -f "$(_keyfile "$_k")" 2>/dev/null || true
    exit 0 ;;
  *) exit 0 ;;
esac
STSTUB
chmod +x "$STUBDIR/secret-tool"

kl_out=$(
  # Keep the harness's throwaway index/meta dirs, but force the keychain-linux
  # value path: override _acq_secret_backend to return keychain-linux and unset
  # the file-backend forcing so store/get/delete/list route through the stub.
  export ACQ_SECRET_STORE_DIR="$STUBDIR/kl-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  # The escape hatch above rooted the index/meta beside the (unused) file store;
  # override the backend so values go to the secret-tool stub, not a file.
  unset ACQ_SECRET_FORCE_FILE
  _acq_secret_backend() { printf 'keychain-linux\n'; }
  export STUBDIR

  # Store a GLOBAL built-in (usai) and a SANDBOX-SCOPED built-in (github). The
  # github case is the key regression: a built-in has no endpoint sidecar, so a
  # meta-only enumeration would miss it — the index must carry it.
  ACQ_SECRET_TEST_VALUE='KL-USAI-VALUE'   acq_secret_set_interactive usai '' >/dev/null 2>&1
  ACQ_SECRET_TEST_VALUE='KL-GITHUB-VALUE' acq_secret_set_interactive github klbox >/dev/null 2>&1

  printf 'listing=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"

  # Delete the scoped github secret; it must drop out of the listing (stale-index
  # verification: even if the index still held it, the value no longer resolves).
  acq_secret_delete "$(_acq_secret_key github klbox)" >/dev/null 2>&1
  printf 'after-del=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"
)
assert_contains "keychain-linux ls: lists global usai key"        "$kl_out" "acq.usai"
assert_contains "keychain-linux ls: lists scoped github key (no sidecar — regression)" "$kl_out" "acq.klbox.github"
# The values must NEVER appear in the listing output.
assert_not_contains "keychain-linux ls: never prints usai value"   "$kl_out" "KL-USAI-VALUE"
assert_not_contains "keychain-linux ls: never prints github value" "$kl_out" "KL-GITHUB-VALUE"
# After delete, the github key is gone but usai remains.
assert_contains     "keychain-linux ls: deleted github key removed" "$kl_out" "after-del=[acq.usai ]"
cleanup_stubs

# 8m0i. Regression: the plain FILE backend behavior is unchanged by the
#       backend-aware split — a stored secret still lists, and an empty store
#       lists nothing.
make_stubs; load_acq
file_ls_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/file-ls-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  # ACQ_SECRET_STORE_DIR sets ACQ_SECRET_FORCE_FILE=1 -> backend is 'file'.
  ACQ_SECRET_TEST_VALUE='FILE-VALUE' acq_secret_set_interactive usai '' >/dev/null 2>&1
  printf 'listing=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"
)
empty_file_ls=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/file-empty-ls"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'listing=[%s]\n' "$(acq_secret_list_keys | tr '\n' ' ')"
)
assert_contains     "file ls: stored secret still lists"        "$file_ls_out" "acq.usai"
assert_not_contains "file ls: never prints the file value"      "$file_ls_out" "FILE-VALUE"
assert_contains     "file ls: empty store lists nothing"        "$empty_file_ls" "listing=[]"
cleanup_stubs

# 8m0j. Self-healing sidecar branch (keychain-linux). The (b) fallback in
#       _acq_secret_list_keys_keychain_linux reconstructs `acq.*` keys from the
#       endpoint sidecars when the key index is missing/stale. We store a CUSTOM
#       service (host+env => a meta sidecar is written) AND a built-in (no
#       sidecar), then DELETE the index file entirely to simulate a lost index,
#       and assert: the custom service's key STILL lists (reconstructed from its
#       sidecar), while the built-in — which has no sidecar to heal from — is
#       correctly NOT listed. This proves the fallback heals only sidecar-backed
#       keys, and does not fabricate keys with no on-disk evidence.
make_stubs; load_acq
# Reuse the same minimal secret-tool stub as 8m0h (store/lookup/clear by attr).
cat >"$STUBDIR/secret-tool" <<'STSTUB'
#!/usr/bin/env bash
_dir="${STUBDIR}/st-store"
mkdir -p "$_dir" 2>/dev/null || true
_keyfile() { printf '%s/%s' "$_dir" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
case "${1:-}" in
  store)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    [ -n "$_k" ] || exit 1
    cat > "$(_keyfile "$_k")"; exit 0 ;;
  lookup)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    _f="$(_keyfile "$_k")"; [ -f "$_f" ] || exit 1; cat "$_f"; exit 0 ;;
  clear)
    _k=""; _prev=""
    for a in "$@"; do [ "$_prev" = "acq_key" ] && { _k="$a"; break; }; _prev="$a"; done
    rm -f "$(_keyfile "$_k")" 2>/dev/null || true; exit 0 ;;
  *) exit 0 ;;
esac
STSTUB
chmod +x "$STUBDIR/secret-tool"

heal_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/heal-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  unset ACQ_SECRET_FORCE_FILE
  _acq_secret_backend() { printf 'keychain-linux\n'; }
  export STUBDIR

  # Custom service: HOST+ENV supplied => acq_secret_meta_store writes a sidecar.
  ACQ_SECRET_TEST_VALUE='KL-GL-VALUE' \
    acq_secret_set_interactive gitlab '' workshop.cloud.gov GITLAB_TOKEN >/dev/null 2>&1
  # Built-in: no host/env => NO sidecar written (only the index carries it).
  ACQ_SECRET_TEST_VALUE='KL-USAI-VALUE' \
    acq_secret_set_interactive usai '' >/dev/null 2>&1

  # Simulate a lost/missing index: remove it entirely. Only the sidecar-backed
  # key can now be reconstructed via the (b) self-healing branch.
  rm -f "$ACQ_SECRET_INDEX_FILE"
  [ -f "$ACQ_SECRET_INDEX_FILE" ] && printf 'INDEX-STILL-PRESENT\n'

  printf 'listing=[%s]\n' "$(acq_secret_list_keys | sort | tr '\n' ' ')"
)
assert_contains     "keychain-linux self-heal: index removed but sidecar-backed key relisted" "$heal_out" "acq.gitlab"
assert_not_contains "keychain-linux self-heal: built-in w/o sidecar NOT relisted after index loss" "$heal_out" "acq.usai"
assert_not_contains "keychain-linux self-heal: index file truly removed"                       "$heal_out" "INDEX-STILL-PRESENT"
# Values never leak into the listing, even on the heal path.
assert_not_contains "keychain-linux self-heal: never prints gitlab value" "$heal_out" "KL-GL-VALUE"
cleanup_stubs


#       its own absolute host path (sbx-parity), a trailing :ro is preserved, and
#       the recorded start dir is the FIRST (primary) workspace regardless of how
#       many mounts are given (docs/QUICKSTART_SBX.md: "Primary workspace — the
#       first path; agent starts here").
make_stubs; load_acq
# Two real host dirs to mount (a nonexistent path would hard-fail provision).
mkdir -p "$STUBDIR/ws-app" "$STUBDIR/ws-lib"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mw-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mwbox opencode "$STUBDIR/ws-app" "$STUBDIR/ws-lib:ro" >/dev/null 2>&1
)
mw_log=$(cat "$CALLS")
# acq canonicalizes host workspace paths before mounting (macOS $TMPDIR is a
# /var -> /private/var symlink), so compare against the resolved real paths.
_ws_app=$(canonicalize_path "$STUBDIR/ws-app")
_ws_lib=$(canonicalize_path "$STUBDIR/ws-lib")
assert_contains "msb: multi-ws mounts primary at its host path" "$mw_log" "--volume ${_ws_app}:${_ws_app}"
assert_contains "msb: multi-ws mounts extra ro at its host path" "$mw_log" "--volume ${_ws_lib}:${_ws_lib}:ro"
assert_contains "msb: multi-ws start dir is the FIRST (primary) workspace" "$mw_log" "'${_ws_app}' > /var/lib/acq/workspace"
assert_not_contains "msb: multi-ws does NOT fall back to /home/agent/workspace" "$mw_log" "'/home/agent/workspace' > /var/lib/acq/workspace"

# Single workspace records that mount as the start dir.
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/sw-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  acq_backend_provision swbox opencode "$STUBDIR/ws-app" >/dev/null 2>&1
)
sw_log=$(cat "$CALLS")
assert_contains "msb: single-ws records that mount as start dir" "$sw_log" "'${_ws_app}' > /var/lib/acq/workspace"
cleanup_stubs

# 8m1c. Symlinked host workspace is canonicalized before mounting. msb cannot
#       mount a symlinked host path (macOS $TMPDIR is /var -> /private/var), so
#       acq resolves it to its real path first. Simulate with a symlink dir ->
#       real dir and assert the --volume uses the REAL target, not the link.
make_stubs; load_acq
mkdir -p "$STUBDIR/real-ws"
ln -sf "$STUBDIR/real-ws" "$STUBDIR/link-ws"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/sym-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision symbox opencode "$STUBDIR/link-ws" >/dev/null 2>&1
)
sym_log=$(cat "$CALLS")
# realpath of the symlink is the real dir; assert the mount uses it.
_real_ws=$(realpath "$STUBDIR/real-ws" 2>/dev/null || printf '%s' "$STUBDIR/real-ws")
assert_contains "msb: symlinked workspace canonicalized to real path" "$sym_log" "--volume ${_real_ws}:${_real_ws}"
assert_not_contains "msb: symlinked workspace NOT mounted via the link" "$sym_log" "--volume ${STUBDIR}/link-ws:"
cleanup_stubs

# 8m2. msb provision aborts (hard fail) when the sandbox never becomes
#      exec-ready — `msb create` returns 0 even when the guest fails to START,
#      so acq must NOT proceed against a dead sandbox.
make_stubs; load_acq
# Make the msb stub's `exec` never return "ok" (simulate a sandbox that didn't
# start), by pointing echo-ok probes at a failing exit.
cat >"$STUBDIR/msb" <<'MSBSTUB2'
#!/usr/bin/env bash
{ printf 'msb'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  --version|-V) printf 'msb %s\n' "${STUB_MSB_VERSION:-0.6.9}" ;;
  create) exit 0 ;;              # create "succeeds" but the guest never starts
  exec)   exit 1 ;;              # every exec fails -> never exec-ready
  *) exit 0 ;;
esac
MSBSTUB2
chmod +x "$STUBDIR/msb"
notready_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/nr-secrets" ACQ_MSB_EXEC_READY_TIMEOUT=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision nrbox shell /tmp 2>&1
  echo "PROVISION_RC=$?"
)
assert_contains "msb: not-ready aborts provision" "$notready_out" "did not become exec-ready"
assert_contains "msb: not-ready is a hard failure (rc!=0)" "$notready_out" "PROVISION_RC=1"
cleanup_stubs

# 8m3. msb provision errors clearly when the host workspace path does not exist
#      (msb cannot mount a nonexistent host path).
make_stubs; load_acq
missing_ws_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mw-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mwbox shell /no/such/path/here 2>&1
  echo "RC=$?"
)
assert_contains "msb: missing workspace errors" "$missing_ws_out" "workspace path does not exist"
assert_contains "msb: missing workspace is a hard failure" "$missing_ws_out" "RC=1"
cleanup_stubs

# 8n. msb provision creates the agent user and runs a uid-1000 kit command as
#     `agent` with HOME=/home/agent (NOT as a plain-OCI base's uid-1000 user,
#     e.g. `node` on a node:22-bookworm override), and chowns staged /home/agent
#     files to agent. Uses a kit fixture whose startup command runs as user
#     "1000" and reads a /home/agent file. (The synthesis is a short-circuit on
#     the default image, which already ships `agent`; this exercises the
#     plain-OCI-override path it must still handle.)
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/agent-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # A one-kit fixture: a /home/agent file + a startup command as user 1000.
  aok="${STUBDIR}/agentkit"
  mkdir -p "$aok/files/home/usai-config"
  printf 'MODULE\n' > "$aok/files/home/usai-config/merge-global-config.mjs"
  cat >"$aok/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: agent-kit
displayName: Agent Kit
description: kit whose startup runs as uid 1000
files:
  - path: /home/agent/usai-config/merge-global-config.mjs
    mode: "0755"
    source: files/home/usai-config/merge-global-config.mjs
commands:
  - phase: startup
    user: "1000"
    command:
      - node
      - /home/agent/usai-config/merge-global-config.mjs
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$aok"; }
  acq_backend_provision agentbox shell /tmp >/dev/null 2>&1
)
agent_log=$(cat "$CALLS")
assert_contains "msb: provision creates agent user" "$agent_log" "agent"
# The uid-1000 startup command must run as `agent` with HOME=/home/agent,
# never as `-u 1000` (which would be a plain-OCI base's `node` user). acq also
# injects non-interactive git guards (GIT_TERMINAL_PROMPT=0 etc.) between the
# HOME env and the argv, so assert the stable prefix rather than the full line.
assert_contains "msb: uid-1000 kit cmd runs as agent" "$agent_log" "msb exec agentbox -u agent -e HOME=/home/agent"
assert_not_contains "msb: uid-1000 kit cmd not run as -u 1000" "$agent_log" "msb exec agentbox -u 1000 -- node"
# Non-interactive enforcement: kit execs get stdin-free git prompt guards so a
# kit that would prompt (e.g. private `git clone`) fails fast instead of hanging
# provision. Assert the guard env is threaded onto the startup command.
assert_contains "msb: kit cmd gets GIT_TERMINAL_PROMPT=0 guard" "$agent_log" "-e GIT_TERMINAL_PROMPT=0"
# The staged /home/agent file must end up agent-owned — but as of the home-dir
# ownership fix acq chowns the TOP-MOST created subdir under the home
# recursively (so intermediate dirs it created as root become agent-owned too),
# not merely the leaf file. For ~/usai-config/merge-global-config.mjs the top
# is `usai-config`, so `chown -R -P agent /home/agent/usai-config` covers the dir
# AND the file. By NAME (agent), never a numeric uid.
assert_contains "msb: chowns staged /home/agent subtree to agent" "$agent_log" "chown -R -P agent /home/agent/usai-config"
# Agent-user setup must create the user WITHOUT pinning uid 1000 (which collides
# with a plain-OCI base's pre-existing uid-1000 user, e.g. node) and must chown the
# home to agent so it is writable — otherwise every agent-user kit fails with
# Permission denied (the playbook silent-fetch-failure regression).
assert_not_contains "msb: agent user NOT created with a fixed -u 1000" "$agent_log" "useradd -m -d /home/agent -s /bin/sh -u 1000"
assert_contains "msb: chowns /home/agent to the agent user" "$agent_log" 'chown "agent:'
assert_contains "msb: verifies /home/agent is writable by agent" "$agent_log" "test -w /home/agent"
cleanup_stubs

# 8n0. Agent-user setup is FATAL when /home/agent is not writable by agent (a
#      root-owned home silently broke every agent-user kit). Model the su-test
#      probe FAILING and assert provision aborts (rc != 0) rather than degrading.
make_stubs; load_acq
homefail_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/homefail-secrets"
  export STUB_HOME_NOT_WRITABLE=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision homefailbox shell /tmp >/dev/null 2>&1; printf 'RC=%s\n' "$?"
)
assert_contains "msb: unwritable agent home aborts provision (rc!=0)" "$homefail_out" "RC=1"
cleanup_stubs

# 8n1. msb provision satisfies the Docker base-image contract for the agent user:
#      passwordless sudo (sudoers.d drop-in) AND HTTP proxy env preserved across
#      sudo (env_keep). See docs.docker.com kit-reference "Base image requirements".
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/basereq-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision basereqbox shell /tmp >/dev/null 2>&1
)
basereq_log=$(cat "$CALLS")
assert_contains "msb: agent gets passwordless sudo (sudoers.d)" "$basereq_log" "sudoers.d/90-acq-agent"
assert_contains "msb: NOPASSWD rule for agent" "$basereq_log" "NOPASSWD:ALL"
assert_contains "msb: proxy env preserved across sudo (env_keep)" "$basereq_log" "env_keep"
assert_contains "msb: proxy env_keep names HTTPS_PROXY" "$basereq_log" "HTTPS_PROXY"
cleanup_stubs

# 8n2. msb provision INSTALLS the requested agent (opencode) when it is not
#      already present — the reported bug was that opencode was never installed.
#      Install is `npm install -g opencode-ai` as root, and the create call
#      allow-lists the npm registry host so the (default-deny) egress permits it.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inst-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  # Default stub: agent ABSENT -> install runs; npm succeeds.
  acq_backend_provision instbox opencode /tmp >/dev/null 2>&1
)
inst_log=$(cat "$CALLS")
assert_contains "msb: installs opencode via npm -g" "$inst_log" "npm install -g --no-fund --no-audit opencode-ai"
assert_contains "msb: allow-lists npm registry host at create" "$inst_log" "--net-rule allow@registry.npmjs.org"
assert_contains "msb: records the agent for attach" "$inst_log" "/var/lib/acq/agent"
cleanup_stubs

# 8n3. Idempotent install: if the agent binary is already present (e.g. baked
#      into ACQ_MSB_IMAGE), provision does NOT run npm install again.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inst2-secrets" STUB_AGENT_PRESENT=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision inst2box opencode /tmp >/dev/null 2>&1
)
assert_not_contains "msb: skips npm install when agent already present" "$(cat "$CALLS")" "npm install"
cleanup_stubs

# 8n4. `shell` sandbox: no agent binary install, and — under the `strict` tier
#       (empty baseline) — no npm registry allow-list. The npm host is
#       added ONLY for an agent with an install recipe (ADR-0011); a `shell`
#       sandbox needs no npm egress. This test pins that agent-conditional gate,
#       so it runs under `strict` (empty baseline): under `balanced`,
#       registry.npmjs.org is in the sbx-"balanced" set and IS allow-listed for
#       every sandbox by design (see 10b1j6 and ADR-0018) — a separate concern
#       from the agent-install gate exercised here.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/shell-secrets"
  export ACQ_NETWORK_TIER=strict
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision shellbox shell /tmp >/dev/null 2>&1
)
shell_log=$(cat "$CALLS")
assert_not_contains "msb: shell agent does not npm install" "$shell_log" "npm install"
assert_not_contains "msb: shell agent adds no npm net-rule (strict tier)" "$shell_log" "allow@registry.npmjs.org"
cleanup_stubs

# 8n4a. #321: a FAILED npm install is DISAMBIGUATED, not conflated. When npm is
#        present in-guest but the registry is UNREACHABLE (TLS cut), acq must say
#        "not reachable / network" and point at KNOWN_FAILURE_MODES §30 — and must
#        NOT imply npm is missing (the misdiagnosis that sent #305's reporter to
#        reinstall node on the host).
make_stubs; load_acq
: > "$CALLS"
npm_unreach_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmunreach-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=unreachable
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmunreachbox opencode /tmp 2>&1
)
assert_contains "msb #321: unreachable registry reported as NOT REACHABLE" "$npm_unreach_out" "NOT REACHABLE"
assert_contains "msb #321: unreachable registry points at KFM §30" "$npm_unreach_out" "KNOWN_FAILURE_MODES.md §30"
assert_not_contains "msb #321: unreachable registry does NOT claim npm is missing" "$npm_unreach_out" "npm is not present"
cleanup_stubs

# 8n4b. #321: when npm is present but the registry NXDOMAINs (curl exit 6), acq
#        reports it as DNS (split-horizon) and points at ACQ_MSB_DNS_NAMESERVER —
#        again NOT "npm missing".
make_stubs; load_acq
: > "$CALLS"
npm_unres_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmunres-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=unresolved
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmunresbox opencode /tmp 2>&1
)
assert_contains "msb #321: unresolved registry reported as did not RESOLVE" "$npm_unres_out" "did not RESOLVE"
assert_contains "msb #321: unresolved registry points at ACQ_MSB_DNS_NAMESERVER" "$npm_unres_out" "ACQ_MSB_DNS_NAMESERVER"
cleanup_stubs

# 8n4c. #321: when npm is genuinely MISSING in-guest, acq says so (the one case
#        where "use a base image that ships node/npm" is the right advice).
make_stubs; load_acq
: > "$CALLS"
npm_missing_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmmissing-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_MISSING=1
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmmissingbox opencode /tmp 2>&1
)
assert_contains "msb #321: genuinely-missing npm reported as not present" "$npm_missing_out" "npm is not present"
assert_not_contains "msb #321: missing-npm case does not claim unreachable" "$npm_missing_out" "NOT REACHABLE"
cleanup_stubs

# 8n4d. #321: guard against classification BLEED. When npm is present AND the
#        registry RESPONDED (an HTTP error — connection completed), the failure
#        is a real npm/registry error, not a network path problem. acq must give
#        the NEUTRAL guidance and must NOT emit a DNS hint (ACQ_MSB_DNS_NAMESERVER
#        / "did not RESOLVE") or a TLS/reachability hint ("NOT REACHABLE") — those
#        belong only to the unresolved/unreachable branches. This pins the
#        boundary so a future edit can't let the DNS/TLS advice bleed into the
#        neutral case.
make_stubs; load_acq
: > "$CALLS"
npm_responded_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmresp-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=responded
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmrespbox opencode /tmp 2>&1
)
assert_contains "msb #321: responded registry -> neutral 'appears reachable' branch" "$npm_responded_out" "registry appears reachable"
assert_not_contains "msb #321: neutral branch emits NO DNS resolver hint" "$npm_responded_out" "ACQ_MSB_DNS_NAMESERVER"
assert_not_contains "msb #321: neutral branch does NOT say 'did not RESOLVE'" "$npm_responded_out" "did not RESOLVE"
assert_not_contains "msb #321: neutral branch emits NO TLS/reachability hint" "$npm_responded_out" "NOT REACHABLE"
assert_not_contains "msb #321: neutral branch does not claim npm is missing" "$npm_responded_out" "npm is not present"
cleanup_stubs

# 8n5. Attach LAUNCHES the recorded agent as the `agent` user in the workspace,
#      with a PTY — NOT a bare root shell (the reported bug) and NOT msb's Node
#      REPL default. Uses `msb exec -t -u agent -w <ws>` (not `msb ssh`, which has
#      no tty flag and hung the TUI).
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_RECORDED_AGENT="opencode"
  export STUB_RECORDED_WORKSPACE="/tmp/myrepo"
  export STUB_AGENT_PRESENT=1     # opencode binary present -> attach execs it
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach attachbox >/dev/null 2>&1
)
attach_log=$(cat "$CALLS")
assert_contains "msb: attach allocates a PTY (msb exec -t)" "$attach_log" "msb exec -t -u agent"
assert_contains "msb: attach runs as the agent user" "$attach_log" "-u agent -w /tmp/myrepo"
assert_contains "msb: attach sets a sane SHELL" "$attach_log" "-e SHELL=/bin/sh"
assert_contains "msb: attach execs the recorded agent in the workspace" "$attach_log" "attachbox -- opencode"
assert_not_contains "msb: attach does NOT use msb ssh (no PTY / TUI hang)" "$attach_log" "msb ssh"
assert_not_contains "msb: attach does NOT su - agent (msb exec -u handles it)" "$attach_log" "su - agent"
cleanup_stubs

# 8n5b. Attach FALLS BACK to a shell (with notice) when the recorded agent binary
#       is missing — never leaves the user in a broken/blank session.
make_stubs; load_acq
: > "$CALLS"
missing_out=$(
  export STUB_RECORDED_AGENT="opencode"
  export STUB_RECORDED_WORKSPACE="/tmp/myrepo"
  export STUB_AGENT_PRESENT=0     # opencode absent -> fall back to /bin/sh -l
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach attachbox 2>&1
)
missing_log=$(cat "$CALLS")
assert_contains "msb: attach falls back to shell when agent binary missing" "$missing_log" "attachbox -- /bin/sh -l"
assert_contains "msb: attach warns when agent binary missing" "$missing_out" "not found in sandbox"
cleanup_stubs

# 8n6. Attach on a `shell` sandbox (or an unrecorded agent) opens a login shell
#      as the agent user with a PTY — never a root shell, never msb's Node REPL
#      (so it must pass an explicit `/bin/sh -l`, not omit the command).
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_RECORDED_AGENT="shell"
  export STUB_RECORDED_WORKSPACE="/tmp/wsp"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach shellattach >/dev/null 2>&1
)
shellattach_log=$(cat "$CALLS")
assert_contains "msb: shell attach uses msb exec -t as agent" "$shellattach_log" "msb exec -t -u agent -w /tmp/wsp"
assert_contains "msb: shell attach execs an explicit /bin/sh -l" "$shellattach_log" "shellattach -- /bin/sh -l"
assert_not_contains "msb: shell attach does not exec a named agent" "$shellattach_log" "shellattach -- shell"
assert_not_contains "msb: shell attach does NOT use msb ssh" "$shellattach_log" "msb ssh"
cleanup_stubs

# 8n6b. `acq exec` (acq_backend_run) runs the command as the unprivileged `agent`
#       user with HOME=/home/agent — NOT root with HOME unset (the reported bug).
#       A bare `msb exec NAME -- CMD` runs as root; the `~`/$HOME-relative probes
#       downstream (e.g. openchamber verify's `~/.local/bin/opencode`) then miss
#       the files staged into /home/agent. Flags precede NAME; the `-- CMD…`
#       passthrough survives after NAME unchanged.
make_stubs; load_acq
: > "$CALLS"
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_run execbox -- sh -c 'ls ~/.local/bin/opencode' >/dev/null 2>&1
)
execrun_log=$(cat "$CALLS")
assert_contains "msb: exec runs as the agent user (-u agent)" "$execrun_log" "msb exec -u agent"
assert_contains "msb: exec sets HOME=/home/agent" "$execrun_log" "-u agent -e HOME=/home/agent"
assert_contains "msb: exec places flags before the sandbox name" "$execrun_log" "-e HOME=/home/agent execbox"
assert_contains "msb: exec preserves the -- CMD passthrough" "$execrun_log" "execbox -- sh -c ls ~/.local/bin/opencode"
assert_not_contains "msb: exec does NOT run as root (bare msb exec NAME)" "$execrun_log" "msb exec execbox --"
cleanup_stubs

# 8n7. SECURITY: a hostile agent token must never break out of the
#      `sh -c "command -v '$agent'"` single-quoting. (1) install path with a
#      metachar-laden `acq create` agent arg, and (2) attach reading a tampered
#      /var/lib/acq/agent marker — both must refuse/fall back, never emit an
#      `sh -c` string containing the injection.
make_stubs; load_acq
: > "$CALLS"
inj_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inj-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_install_agent injbox "x';touch /tmp/acq_pwn;'" 2>&1
)
inj_log=$(cat "$CALLS")
assert_contains "msb: install refuses metachar agent token" "$inj_out" "refusing agent name"
assert_not_contains "msb: install never emits the injected sh -c" "$inj_log" "touch /tmp/acq_pwn"
cleanup_stubs

# Attach with a tampered marker (returned by the stub) falls back to a shell and
# never interpolates the injection into an sh -c command-v probe.
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_RECORDED_AGENT="x';touch /tmp/acq_pwn;'"
  export STUB_RECORDED_WORKSPACE="/tmp/wsp"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach injattach >/dev/null 2>&1
)
injattach_log=$(cat "$CALLS")
assert_not_contains "msb: attach never runs the injected marker in sh -c" "$injattach_log" "touch /tmp/acq_pwn"
assert_contains "msb: attach falls back to /bin/sh on tampered marker" "$injattach_log" "injattach -- /bin/sh -l"
cleanup_stubs

# 8n8. msb provision ensures an OCI engine (podman) by default: when the
#      oci-ready marker is absent, acq runs ONE big root (`-u 0`) `sh -c` that
#      installs podman + wires the docker->podman alias, then touches the marker.
#      The install is operator config (ACQ_MSB_PODMAN_PKGS) threaded via `-e
#      PODMAN_PKGS=…`; it MUST run as root (never as `-u agent`), and the marker
#      touch confirms success was recorded (idempotence on re-provision).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/oci-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocibox shell /tmp >/dev/null 2>&1
)
oci_log=$(cat "$CALLS")
assert_contains "msb: OCI setup threads the podman packages (PODMAN_PKGS=)" "$oci_log" "PODMAN_PKGS="
assert_contains "msb: OCI setup wires the docker->podman alias" "$oci_log" "/usr/local/bin/docker"
assert_contains "msb: OCI setup marks ready (touch marker) on success" "$oci_log" "touch '/var/lib/acq/oci-ready'"
# The OCI setup MUST configure a storage driver that works on msb's overlay root:
# podman's default kernel `overlay` driver cannot stack on the overlay-backed
# sandbox FS, so the snippet writes /etc/containers/storage.conf selecting
# fuse-overlayfs (preferred) or vfs (fallback).
assert_contains "msb: OCI setup configures a storage driver (storage.conf)" "$oci_log" "/etc/containers/storage.conf"
assert_contains "msb: OCI setup includes the vfs fallback driver" "$oci_log" 'driver = \"vfs\"'
assert_contains "msb: OCI setup prefers fuse-overlayfs mount_program" "$oci_log" "mount_program"
# fuse-overlayfs + the rootless prereqs are in the default install set.
assert_contains "msb: OCI setup installs fuse-overlayfs by default" "$oci_log" "fuse-overlayfs"
assert_contains "msb: OCI setup installs rootless prereq uidmap" "$oci_log" "uidmap"
assert_contains "msb: OCI setup installs rootless prereq passt" "$oci_log" "passt"
assert_contains "msb: OCI setup installs rootless prereq slirp4netns" "$oci_log" "slirp4netns"
# The docker->podman alias must route to PLAIN podman (rootless engine runs as the
# agent user; NO sudo wrapper).
assert_contains "msb: docker alias routes to plain podman" "$oci_log" "exec podman"
assert_not_contains "msb: docker alias does NOT use sudo" "$oci_log" "exec sudo -n podman"
# Rootless device access: the agent is granted group-scoped access to BOTH
# /dev/net/tun (networking) and /dev/fuse (fuse-overlayfs storage), via
# _acq_msb_grant_oci_devs (a device loop run un-gated on every provision pass).
assert_contains "msb: OCI setup grants agent access to /dev/net/tun" "$oci_log" "/dev/net/tun"
assert_contains "msb: OCI setup grants agent access to /dev/fuse" "$oci_log" "/dev/fuse"
assert_contains "msb: OCI setup group-scopes the device to agent" "$oci_log" 'chown root:agent "$_dev"'
# Docker-Hub-first registry resolution (ADR-0020): unqualified-search + shortname
# alias override so unadorned names resolve to Docker Hub, not quay.io.
assert_contains "msb: OCI setup writes Docker-Hub-first search registry" "$oci_log" 'unqualified-search-registries = [\"docker.io\"]'
assert_contains "msb: OCI setup remaps hello-world alias to Docker Hub" "$oci_log" 'docker.io/library/hello-world'
# short-name-mode DEFAULT is "enforcing" (PR #302 review): least-privilege /
# prompt-injection defense. The single search-registry keeps unqualified names
# resolving to Docker Hub, so enforcing costs ~no ergonomics but fails closed on
# ambiguous short names (no silent typosquatting/substitution). NOT permissive.
# The written config line templates the value from the guest env var
# ($SHORT_NAME_MODE), which acq threads in via `-e SHORT_NAME_MODE=<value>`, so we
# assert on the threaded env var (that IS the effective config value).
assert_contains "msb: OCI setup templates short-name-mode from the env var" "$oci_log" 'short-name-mode = \"$SHORT_NAME_MODE\"'
assert_contains "msb: OCI setup defaults short-name-mode to enforcing" "$oci_log" "SHORT_NAME_MODE=enforcing"
assert_not_contains "msb: OCI setup does NOT default to permissive short-name-mode" "$oci_log" "SHORT_NAME_MODE=permissive"
# The package INSTALL/config MUST run as root; the engine VERIFY runs rootless as
# the agent user.
assert_contains "msb: OCI install/config runs as root (-u 0)" "$oci_log" "msb exec ocibox -u 0 -e PODMAN_PKGS="
assert_contains "msb: OCI engine verified rootless as the agent user" "$oci_log" "msb exec ocibox -u agent -e HOME=/home/agent"
# The rootless verify must exercise a real LAYER MOUNT (a FROM-scratch build),
# not just `podman info` — `podman info` doesn't open /dev/fuse, so it would pass
# even when the fuse-overlayfs mount fails. The self-test builds acq-oci-selftest.
assert_contains "msb: OCI verify does a real build (layer mount), not just info" "$oci_log" "acq-oci-selftest"
cleanup_stubs

# 8n8b. short-name-mode OPT-IN: ACQ_MSB_SHORT_NAME_MODE=permissive removes the
#       enforcing guardrail — the written config must carry the permissive value.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/oci-perm-secrets" ACQ_MSB_SHORT_NAME_MODE=permissive
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocipermbox shell /tmp >/dev/null 2>&1
)
oci_perm_log=$(cat "$CALLS")
# The config line templates $SHORT_NAME_MODE from the guest env var, so the
# effective value is carried in the threaded `-e SHORT_NAME_MODE=<value>` arg.
assert_contains "msb: ACQ_MSB_SHORT_NAME_MODE=permissive opt-in threads permissive" "$oci_perm_log" "SHORT_NAME_MODE=permissive"
assert_not_contains "msb: permissive opt-in does not also thread enforcing" "$oci_perm_log" "SHORT_NAME_MODE=enforcing"
cleanup_stubs

# 8n8c. short-name-mode FAIL-CLOSED: an invalid ACQ_MSB_SHORT_NAME_MODE value is
#       rejected (warning) and falls back to "enforcing" — never the bad value.
make_stubs; load_acq
: > "$CALLS"
oci_bad_warn=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/oci-bad-secrets" ACQ_MSB_SHORT_NAME_MODE="bogus; rm -rf /"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>&1 1>/dev/null
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocibadbox shell /tmp >/dev/null 2>&1
)
oci_bad_log=$(cat "$CALLS")
assert_contains "msb: invalid ACQ_MSB_SHORT_NAME_MODE emits a warning" "$oci_bad_warn" "invalid ACQ_MSB_SHORT_NAME_MODE"
assert_contains "msb: invalid short-name-mode falls back to enforcing" "$oci_bad_log" "SHORT_NAME_MODE=enforcing"
assert_not_contains "msb: invalid short-name-mode value is not threaded" "$oci_bad_log" "SHORT_NAME_MODE=bogus"
assert_not_contains "msb: invalid short-name-mode value is not interpolated" "$oci_bad_log" "rm -rf /"
cleanup_stubs

# 8n9. Marker-gated skip: when /var/lib/acq/oci-ready already exists
#      (STUB_OCI_READY=1), the (network-bound) OCI setup exec is short-circuited
#      — no install block runs and the marker is not re-touched.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ociready-secrets" STUB_OCI_READY=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocirdybox shell /tmp >/dev/null 2>&1
)
ocirdy_log=$(cat "$CALLS")
assert_contains "msb: OCI marker probed when gating the skip" "$ocirdy_log" "test -f '/var/lib/acq/oci-ready'"
assert_not_contains "msb: OCI setup skipped when marker present (no PODMAN_PKGS exec)" "$ocirdy_log" "PODMAN_PKGS="
assert_not_contains "msb: OCI alias not re-wired when marker present" "$ocirdy_log" "/usr/local/bin/docker"
cleanup_stubs

# 8n10. Toggle off: with ACQ_MSB_ENSURE_OCI=0 the OCI step is skipped entirely —
#       neither the marker probe nor the setup exec appears.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ocioff-secrets" ACQ_MSB_ENSURE_OCI=0
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocioffbox shell /tmp >/dev/null 2>&1
)
ocioff_log=$(cat "$CALLS")
assert_not_contains "msb: OCI setup never runs when toggled off" "$ocioff_log" "PODMAN_PKGS="
assert_not_contains "msb: OCI marker never probed when toggled off" "$ocioff_log" "oci-ready"
cleanup_stubs

# 8n11. FAIL SOFT: when the OCI setup exec fails (STUB_OCI_SETUP_FAIL=1, modelling
#       an unreachable mirror / failed `podman info`), provision still returns
#       rc 0, a "could not provision an OCI engine" warning is emitted, and the
#       ready marker is NOT touched (so a later provision retries).
make_stubs; load_acq
ocifail_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ocifail-secrets" STUB_OCI_SETUP_FAIL=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocifailbox shell /tmp 2>&1
  echo "RC=$?"
)
ocifail_log=$(cat "$CALLS")
assert_contains "msb: OCI setup failure is fail-soft (rc 0)" "$ocifail_out" "RC=0"
assert_contains "msb: OCI setup failure warns clearly" "$ocifail_out" "could not provision an OCI engine"
assert_not_contains "msb: OCI ready marker NOT touched on setup failure" "$ocifail_log" "touch '/var/lib/acq/oci-ready'"
cleanup_stubs

# 8n12. SECURITY: ACQ_MSB_PODMAN_PKGS is charset-guarded (it is interpolated into
#       a root `sh -c`). A value with a shell metachar is refused with an "unsafe
#       characters" warning and the injected string never reaches an exec.
make_stubs; load_acq
ociinj_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ociinj-secrets"
  export ACQ_MSB_PODMAN_PKGS="podman;rm -rf"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ociinjbox shell /tmp 2>&1
)
ociinj_log=$(cat "$CALLS")
assert_contains "msb: unsafe ACQ_MSB_PODMAN_PKGS is refused" "$ociinj_out" "unsafe characters"
assert_not_contains "msb: injected pkg string never reaches an exec" "$ociinj_log" "rm -rf"
cleanup_stubs

# 8o. Regression: msb applies ALL kit files and ALL kit commands, not just the
#     first. The apply loops call `msb copy`/`msb exec`, which drain stdin (the
#     stub mimics this) — a naive `while read … done <<heredoc` would lose every
#     record after the first. Assert a two-file, two-command kit is fully applied.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/multi-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  mk="${STUBDIR}/multikit"
  mkdir -p "$mk/files/home"
  printf 'A\n' > "$mk/files/home/file_one"
  printf 'B\n' > "$mk/files/home/file_two"
  cat >"$mk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit
displayName: Multi Kit
description: two files and two startup commands
files:
  - path: /home/agent/file_one
    mode: "0644"
    source: files/home/file_one
  - path: /home/agent/file_two
    mode: "0644"
    source: files/home/file_two
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo CMD_ALPHA
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo CMD_BETA
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$mk"; }
  # Apply just this kit directly (avoid the built-in kit fetches).
  _acq_msb_apply_kit_dir multibox "$mk"
)
multi_log=$(cat "$CALLS")
assert_contains "msb: applies first kit file" "$multi_log" "msb copy ${STUBDIR}/multikit/files/home/file_one multibox:/home/agent/file_one"
assert_contains "msb: applies SECOND kit file (not dropped)" "$multi_log" "msb copy ${STUBDIR}/multikit/files/home/file_two multibox:/home/agent/file_two"
assert_contains "msb: runs first kit command" "$multi_log" "echo CMD_ALPHA"
assert_contains "msb: runs SECOND kit command (not dropped)" "$multi_log" "echo CMD_BETA"
cleanup_stubs

# 8o1. environment vocabulary on msb: the kit's environment[] entries are
#      threaded onto every command as `msb exec -e NAME=value` (msb's native
#      per-exec env flag), and an unsafe env var NAME is dropped (never reaches
#      the exec).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/env-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  ek="${STUBDIR}/envkit"; mkdir -p "$ek"
  cat >"$ek/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: env-kit
displayName: Env Kit
description: environment vars threaded to msb exec
environment:
  GITLAB_HOST: gitlab.example.gov
  "1BAD": should-be-dropped
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo CMD_WITH_ENV
SPEC
  _acq_msb_apply_kit_dir envbox "$ek"
)
env_log=$(cat "$CALLS")
assert_contains "msb env: threads -e GITLAB_HOST onto exec" "$env_log" "-e GITLAB_HOST=gitlab.example.gov"
assert_contains "msb env: command still runs with env" "$env_log" "echo CMD_WITH_ENV"
assert_not_contains "msb env: unsafe env var name dropped" "$env_log" "1BAD"
cleanup_stubs

# 8o1b. DECISION GUARD: kit commands are staged via `msb exec …
#        -- <argv>` (kit content as SEPARATE ARGV ELEMENTS), NOT registered via
#        msb 0.6.7's create-time `--script`/`--script-path` flags and NOT
#        interpolated into an `sh -c` string built from kit content. This is the
#        reason the exec-based path is kept (see the DESIGN NOTE in msb.sh): the
#        argv never enters an interpolated shell string, so the safety win
#        --script offers is already present. If someone later switches the kit-
#        command path to --script (or to an interpolated sh -c), these assertions
#        fail and force a re-read of the design rationale. Uses a kit whose command
#        body carries shell metacharacters that WOULD be dangerous if interpolated.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/noscript-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  nsk="${STUBDIR}/noscriptkit"; mkdir -p "$nsk"
  cat >"$nsk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: noscript-kit
displayName: NoScript Kit
description: command body with metachars stays argv, never --script, never interpolated
commands:
  - phase: startup
    user: "0"
    command:
      - printf
      - "%s\n"
      - "hello; rm -rf /tmp/NS_PWNED"
SPEC
  _acq_msb_apply_kit_dir noscriptbox "$nsk"
)
noscript_log=$(cat "$CALLS")
# The command is dispatched through `msb exec … -- printf …` (argv), not registered.
assert_contains "239: kit command staged via msb exec (argv path)" "$noscript_log" "msb exec noscriptbox"
assert_contains "239: kit command argv reaches exec verbatim" "$noscript_log" "-- printf"
# The metachar-bearing body travels as a single argv token AFTER the `--`, so it
# is data, not a command — the injected `rm -rf` is never its own argv word.
assert_contains "239: metachar body carried as one argv token" "$noscript_log" "hello; rm -rf /tmp/NS_PWNED"
# NEVER via msb's create-time script-registration flags (the refactor we declined).
assert_not_contains "239: kit command NOT registered via --script" "$noscript_log" "--script"
assert_not_contains "239: kit command NOT registered via --script-path" "$noscript_log" "--script-path"
# NEVER by interpolating the kit command into an `sh -c "<kit content>"` wrapper.
# This startup (non-background) kit emits a plain `msb exec … -- <argv>` with NO
# `sh -c` at all (unlike the fixed marker/mkdir helpers, whose sh -c strings are
# adapter-owned, not kit content). A regression that assembled this kit's argv
# into a shell string would surface as `sh -c … printf …` (the command name
# interpolated after `sh -c`); assert that never happens for this kit's command.
assert_not_contains "239: kit command not wrapped in sh -c interpolation" "$noscript_log" "sh -c printf"
cleanup_stubs

# 8o1c. DECISION GUARD (idempotency): an install-phase kit command
#        stays run-once via the root-owned marker in _acq_msb_exec_command — that
#        gate lives in the EXEC path (test+write /var/lib/acq/install-<cksum> as
#        uid 0), which is exactly why registering the command as a create-time
#        --script (fire-and-forget, no marker) would be a behavior change. Assert
#        the marker gate is exercised for an install command.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/instmarker-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  imk="${STUBDIR}/instmarkerkit"; mkdir -p "$imk"
  cat >"$imk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: instmarker-kit
displayName: InstMarker Kit
description: install command is marker-gated in the exec path (not fire-and-forget --script)
commands:
  - phase: install
    user: "0"
    command:
      - true
SPEC
  _acq_msb_apply_kit_dir instmarkerbox "$imk"
)
instmarker_log=$(cat "$CALLS")
# Marker gate is tested (test -f) and, on a miss, written (touch) under
# /var/lib/acq — both as `-u 0`. This machinery is the run-once semantics that a
# create-time --script registration would NOT reproduce.
assert_contains "239: install cmd is marker-gated (test -f /var/lib/acq/install-)" "$instmarker_log" "test -f '/var/lib/acq/install-"
assert_contains "239: install cmd marker is written after run (touch)" "$instmarker_log" "touch '/var/lib/acq/install-"
assert_contains "239: install marker tested/written as root" "$instmarker_log" "msb exec instmarkerbox -u 0"
cleanup_stubs

# 8o1d. ADR-0017 (increment 1): provisioning a kit that HAS a startup command
#        stages a create-time `--script-path acq-startup:<path>` flag on
#        `msb create`, AND the generated host script file exists and reproduces
#        the startup command's argv + the correct run-as-user construct. This is
#        the create-time staging plumbing; it does NOT change how startup is
#        applied via exec after create (asserted below) — it is runtime-neutral.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/su-secrets"
  # Preserve the staged host file so this test can read the generated body.
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/startup-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  suk="$STUBDIR/startupkit"; mkdir -p "$suk"
  cat >"$suk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: startup-kit
displayName: Startup Kit
description: one agent-user startup command staged as a create-time script
commands:
  - phase: startup
    user: "1000"
    command:
      - sh
      - -c
      - echo STARTUP_MARKER_ALPHA
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$suk"; }
  acq_backend_provision startupbox shell /tmp >/dev/null 2>&1
)
su_log=$(cat "$CALLS")
# (a) the create line carries a --script-path acq-startup:<path> flag.
assert_contains "0017: msb create stages --script-path acq-startup" "$su_log" "--script-path acq-startup:"
# (b) the generated host script file exists and carries the startup argv +
#     run-as-user (agent) construct.
su_file=$(find "$STUBDIR/startup-stage" -type f 2>/dev/null | head -n1)
su_body=$(cat "$su_file" 2>/dev/null)
assert_contains "0017: generated script has shebang" "$su_body" "#!/bin/sh"
assert_contains "0017: generated script includes startup command body" "$su_body" "echo STARTUP_MARKER_ALPHA"
assert_contains "0017: generated script runs uid-1000 as agent (su/runuser)" "$su_body" "runuser -u agent"
assert_contains "0017: generated script sets HOME for agent user" "$su_body" "HOME=/home/agent"
# The staged path in the create flag is the same host file that exists.
assert_contains "0017: staged path in create flag points at the generated file" "$su_log" "--script-path acq-startup:${su_file}"
cleanup_stubs

# 8o1e. ADR-0017: a background:true startup command is staged into the generated
#        script in the nohup-detach form (same detach semantics the exec path
#        uses), so a never-exiting supervisor doesn't block on restart replay.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/bgsu-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/bgstartup-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  bsk="$STUBDIR/bgstartupkit"; mkdir -p "$bsk"
  cat >"$bsk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bgstartup-kit
displayName: BG Startup Kit
description: a background startup supervisor staged with nohup detach
commands:
  - phase: startup
    user: "0"
    background: true
    command:
      - supervisor-loop-0017
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$bsk"; }
  acq_backend_provision bgstartupbox shell /tmp >/dev/null 2>&1
)
bgsu_file=$(find "$STUBDIR/bgstartup-stage" -type f 2>/dev/null | head -n1)
bgsu_body=$(cat "$bgsu_file" 2>/dev/null)
assert_contains "0017: background startup staged with nohup detach" "$bgsu_body" "nohup"
assert_contains "0017: background startup command in generated script" "$bgsu_body" "supervisor-loop-0017"
cleanup_stubs

# 8o1f. ADR-0017: a kit with NO startup commands stages NO --script-path
#        acq-startup flag (no empty script is registered). Uses a kit whose only
#        command is install-phase (not startup).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/nostartup-secrets"
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/nostartup-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  nsk2="$STUBDIR/nostartupkit"; mkdir -p "$nsk2"
  cat >"$nsk2/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: nostartup-kit
displayName: NoStartup Kit
description: only an install command, no startup phase
commands:
  - phase: install
    user: "0"
    command:
      - true
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$nsk2"; }
  acq_backend_provision nostartupbox shell /tmp >/dev/null 2>&1
)
nostartup_log=$(cat "$CALLS")
assert_not_contains "0017: no startup cmd => no --script-path acq-startup flag" "$nostartup_log" "--script-path acq-startup"
cleanup_stubs

# 8o1g. ADR-0017 REGRESSION: install-phase commands still go through `msb exec`
#        (unchanged) and are NOT folded into the generated startup script. The
#        install command's run-once marker gate must still be exercised via exec,
#        and its argv must NOT appear in the staged startup script body.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mix-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/mix-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  mxk="$STUBDIR/mixkit"; mkdir -p "$mxk"
  cat >"$mxk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: mix-kit
displayName: Mix Kit
description: install stays exec-based; startup is staged
commands:
  - phase: install
    user: "0"
    command:
      - sh
      - -c
      - echo INSTALL_ONLY_0017
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo STARTUP_ONLY_0017
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$mxk"; }
  acq_backend_provision mixbox shell /tmp >/dev/null 2>&1
)
mix_log=$(cat "$CALLS")
mix_file=$(find "$STUBDIR/mix-stage" -type f 2>/dev/null | head -n1)
mix_body=$(cat "$mix_file" 2>/dev/null)
# install still runs through the exec path: marker-gated as root.
assert_contains "0017: install still exec-based (marker gate via msb exec -u 0)" "$mix_log" "test -f '/var/lib/acq/install-"
assert_contains "0017: install command body still applied via msb exec" "$mix_log" "echo INSTALL_ONLY_0017"
# The startup command IS in the generated script; the install command is NOT.
assert_contains "0017: startup command is in the generated script" "$mix_body" "echo STARTUP_ONLY_0017"
assert_not_contains "0017: install command is NOT in the generated startup script" "$mix_body" "INSTALL_ONLY_0017"
cleanup_stubs

# 8o1h. ADR-0017 SECURITY (SI-10): a startup command body carrying shell
#        metacharacters is emitted into the generated script as SINGLE-QUOTED
#        DATA (never an interpolated program fragment), so the injected `rm -rf`
#        is inert text, not executable syntax. Also confirm no secret VALUE ever
#        reaches the generated script or the create line.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inj-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/inj-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Plant a USAi secret so provision binds it; its VALUE must never leak into the
  # generated script or the create line.
  printf 'SUPER_SECRET_VALUE_0017\n' | acq_secret_store "$(_acq_secret_key usai injbox)" >/dev/null 2>&1
  injk="$STUBDIR/injstartupkit"; mkdir -p "$injk"
  cat >"$injk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: injstartup-kit
displayName: InjStartup Kit
description: metachar startup body stays quoted data (SI-10)
commands:
  - phase: startup
    user: "0"
    command:
      - printf
      - "%s\n"
      - "hello; rm -rf /tmp/STARTUP_PWNED"
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$injk"; }
  acq_backend_provision injbox shell /tmp >/dev/null 2>&1
)
inj_log=$(cat "$CALLS")
inj_file=$(find "$STUBDIR/inj-stage" -type f 2>/dev/null | head -n1)
inj_body=$(cat "$inj_file" 2>/dev/null)
# The metachar body is present but single-quoted (inert data): the quoted form
# `'hello; rm -rf /tmp/STARTUP_PWNED'` appears verbatim in the generated script.
assert_contains "0017: metachar startup body carried as single-quoted data" "$inj_body" "'hello; rm -rf /tmp/STARTUP_PWNED'"
# No secret VALUE anywhere in the generated script or the create line.
assert_not_contains "0017: secret value never in generated startup script" "$inj_body" "SUPER_SECRET_VALUE_0017"
assert_not_contains "0017: secret value never on the create line" "$inj_log" "SUPER_SECRET_VALUE_0017"
# Hermetic escaping lock-in: the generated body must be syntactically valid sh —
# a broken single-quote escape (breakout) would make `sh -n` fail. This catches
# deep-nesting/backtick/$() escaping regressions without executing the body.
if [ -n "$inj_file" ] && sh -n "$inj_file" 2>/dev/null; then
  pass "0017: generated startup body is valid sh (no quote breakout)"
else
  fail "0017: generated startup body is valid sh (no quote breakout)" "sh -n failed on $inj_file"
fi
cleanup_stubs

# 8o1i. ADR-0017 BODY FIDELITY: the generated startup body reproduces the SAME
#        semantics the exec path threads onto a startup command — the git
#        non-interactive guards (GIT_TERMINAL_PROMPT=0 + GIT_ASKPASS/SSH_ASKPASS)
#        AND any kit environment[] var — as a portable `env NAME=value …` prefix
#        (busybox-safe: no `--` terminator). Uses a kit with a declared env var so
#        both the guard and the kit var must appear in the generated file.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/fidel-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/fidel-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  fdk="$STUBDIR/fidelkit"; mkdir -p "$fdk"
  cat >"$fdk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: fidel-kit
displayName: Fidelity Kit
description: startup body carries git guards + a kit environment var
environment:
  GITLAB_HOST: gitlab.example.gov
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo FIDELITY_MARKER
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$fdk"; }
  acq_backend_provision fidelbox shell /tmp >/dev/null 2>&1
)
fidel_file=$(find "$STUBDIR/fidel-stage" -type f 2>/dev/null | head -n1)
fidel_body=$(cat "$fidel_file" 2>/dev/null)
# (a) git non-interactive guards are threaded onto the startup command body.
assert_contains "0017: startup body carries GIT_TERMINAL_PROMPT=0 guard" "$fidel_body" "GIT_TERMINAL_PROMPT=0"
assert_contains "0017: startup body carries GIT_ASKPASS guard" "$fidel_body" "GIT_ASKPASS=/bin/false"
assert_contains "0017: startup body carries SSH_ASKPASS guard" "$fidel_body" "SSH_ASKPASS=/bin/false"
# (b) the kit-declared environment[] var is emitted into the body.
assert_contains "0017: kit environment var emitted into startup body" "$fidel_body" "GITLAB_HOST=gitlab.example.gov"
# Portability: the env prefix uses NO `--` terminator (unsupported by busybox env).
assert_contains "0017: env prefix present in body (env NAME=value …)" "$fidel_body" "env "
assert_not_contains "0017: env prefix uses NO -- terminator (busybox-safe)" "$fidel_body" "env --"
cleanup_stubs

# 8o1j. ADR-0017 MULTI-KIT SINGLE-STAKE + NO-DROP: when TWO kits each carry a
#        startup command, only ONE `--script-path acq-startup` is staged at
#        create (increment-1 single-stake guard) — but the exec-based apply path
#        (unchanged, runtime-neutral) must STILL run BOTH kits' startup commands
#        after create, so nothing is dropped at runtime. Drives the REAL provision
#        with two kit dirs returned by a fetch stub keyed on the kit ref, so both
#        real kits flow through create-staging AND _acq_msb_apply_kit_dir.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/multi-secrets"
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/multi-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  mk1="$STUBDIR/multikit1"; mkdir -p "$mk1"
  cat >"$mk1/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit-one
displayName: Multi Kit One
description: first kit with a startup command
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo MULTI_STARTUP_ONE
SPEC
  mk2="$STUBDIR/multikit2"; mkdir -p "$mk2"
  cat >"$mk2/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: multi-kit-two
displayName: Multi Kit Two
description: second kit with a startup command
commands:
  - phase: startup
    user: "0"
    command:
      - sh
      - -c
      - echo MULTI_STARTUP_TWO
SPEC
  # Point the four built-in kit refs at our two fixtures (the 3rd/4th reuse the
  # empty nokit) so the REAL provision loop fetches and applies both. These are
  # consumed by acq_backend_provision's built-in kit list, then routed through the
  # _acq_msb_fetch_kit override below (indirection shellcheck cannot see).
  mkdir -p "$STUBDIR/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "$STUBDIR/nokit/spec.yaml"
  # shellcheck disable=SC2034  # all four assigned here, read by the provision loop
  USAI_KIT="k1"
  # shellcheck disable=SC2034
  PLAYBOOK_KIT="k2"
  # shellcheck disable=SC2034
  ZSCALER_KIT="k3"
  # shellcheck disable=SC2034
  GITSSHSIGN_KIT="k4"
  _acq_msb_fetch_kit() {
    case "$1" in
      k1) printf '%s\n' "$mk1" ;;
      k2) printf '%s\n' "$mk2" ;;
      *)  printf '%s\n' "$STUBDIR/nokit" ;;
    esac
  }
  acq_backend_provision multibox shell /tmp >/dev/null 2>&1
)
multi_log=$(cat "$CALLS")
# Exactly ONE --script-path acq-startup staged at create (single-stake guard).
multi_stakes=$(printf '%s\n' "$multi_log" | grep -c -- "--script-path acq-startup:")
assert_eq "0017: multi-kit stakes exactly ONE acq-startup script" "1" "$multi_stakes"
# NO-DROP: the exec-based apply path still ran BOTH kits' startup commands after
# create (nothing silently dropped at runtime). Both appear via `msb exec`.
assert_contains "0017: multi-kit runs kit-one startup via msb exec post-create" "$multi_log" "echo MULTI_STARTUP_ONE"
assert_contains "0017: multi-kit runs kit-two startup via msb exec post-create" "$multi_log" "echo MULTI_STARTUP_TWO"
cleanup_stubs

# 8o1k. ADR-0017 NAMED-USER PATH: a startup command whose `user` is a named
#        non-agent, non-root user emits the `su <user> -c` construct in the
#        generated body (the run-as-user translation for arbitrary named users).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/named-secrets"
  export ACQ_MSB_KEEP_STARTUP_STAGE=1
  export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/named-stage"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  nmk="$STUBDIR/namedkit"; mkdir -p "$nmk"
  cat >"$nmk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: named-kit
displayName: Named Kit
description: startup command as a named non-agent user
commands:
  - phase: startup
    user: "postgres"
    command:
      - sh
      - -c
      - echo NAMED_USER_MARKER
SPEC
  _acq_msb_fetch_kit() { printf '%s\n' "$nmk"; }
  acq_backend_provision namedbox shell /tmp >/dev/null 2>&1
)
named_file=$(find "$STUBDIR/named-stage" -type f 2>/dev/null | head -n1)
named_body=$(cat "$named_file" 2>/dev/null)
# The username is single-quote-escaped defensively (SI-10), so the construct is
# `su 'postgres' -c …` — assert the su-as-that-user shape.
assert_contains "0017: named-user startup emits su <user> -c" "$named_body" "su 'postgres' -c"
assert_contains "0017: named-user startup command body present" "$named_body" "echo NAMED_USER_MARKER"
# Not routed through the agent runuser path (that is only for the uid-1000 case).
assert_not_contains "0017: named-user startup not run as agent" "$named_body" "runuser -u agent"
cleanup_stubs

# ---------------------------------------------------------------------------
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

# 8o2. SECURITY: a hostile kit `mode` must not reach a root shell. kit_spec_files
#      drops the record; the msb chmod uses argv (no sh -c interpolation); and
#      the injected command must never appear in the recorded msb calls.
make_stubs; load_acq
inj_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  ik="${STUBDIR}/injkit"; mkdir -p "$ik/files"
  printf 'x\n' > "$ik/files/evil"
  cat >"$ik/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: inj-kit
displayName: Inj
description: hostile mode
files:
  - path: /home/agent/evil
    mode: "0644; touch /tmp/PWNED"
    source: files/evil
SPEC
  kit_spec_files "$ik/spec.yaml" 2>&1
)
assert_contains "sec: hostile mode record is dropped+warned" "$inj_out" "invalid mode"
# The rejected value is echoed in the warning; assert no actual FILE RECORD (a
# tab-separated path<TAB>mode… line) was emitted for it.
inj_records=$(printf '%s\n' "$inj_out" | grep -v '^kit-translate:' || true)
assert_eq "sec: hostile mode emits no file record" "" "$inj_records"
cleanup_stubs

# 8o3. SECURITY: the msb copy/chmod path refuses a non-octal mode and an unsafe
#      path, and never interpolates them into an sh -c (chmod is argv).
make_stubs; load_acq
: > "$CALLS"
sec_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/sec-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Directly exercise the copy helper with a hostile mode + a metachar path.
  _acq_msb_copy_file_verified secbox /etc/hostname '/home/agent/ok' '0644; touch /tmp/PWNED' 2>&1
  _acq_msb_copy_file_verified secbox /etc/hostname '/home/agent/a;b' '0644' 2>&1
)
sec_log=$(cat "$CALLS")
assert_contains "sec: non-octal mode refused" "$sec_out" "non-octal mode"
assert_contains "sec: unsafe path refused" "$sec_out" "unsafe path"
assert_not_contains "sec: chmod never via sh -c string" "$sec_log" "chmod 0644;"
assert_not_contains "sec: injected command never reaches msb argv" "$sec_log" "PWNED"
cleanup_stubs

# 8o3b. HOME-DIR OWNERSHIP: when a kit drops a file under a nested
#       agent-home path (e.g. the openchamber wrapper at ~/.local/bin/opencode),
#       acq creates the parent chain as root then must chown the TOP-MOST
#       created subdir under /home/agent RECURSIVELY to the agent user — so
#       .local, .local/bin AND the file all become agent-owned. Chowning only
#       the leaf left .local/.local/bin root-owned; the agent-user startup's
#       `mkdir -p ~/.local/state/...` then hit EACCES and (set -eu, detached)
#       died silently. Assert the subtree chown, by NAME, never a numeric uid.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/home-own-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Nested drop (the reported openchamber wrapper shape) …
  _acq_msb_copy_file_verified hobox /etc/hostname '/home/agent/.local/bin/opencode' '0755' >/dev/null 2>&1
  # … and a file dropped directly in the home (no subdir).
  _acq_msb_copy_file_verified hobox /etc/hostname '/home/agent/direct-file' '0644' >/dev/null 2>&1
)
home_own_log=$(cat "$CALLS")
# Nested: the intermediate subtree (top-most component .local) is chowned, not
# merely the leaf file — this is the actual fix.
assert_contains "234: chowns top-most created subtree under home (recursive)" \
  "$home_own_log" "chown -R -P agent /home/agent/.local"
assert_not_contains "234: does NOT chown only the leaf file" \
  "$home_own_log" "chown -R -P agent /home/agent/.local/bin/opencode"
# Never recurse all of /home/agent (would stomp other kits' root-owned drops).
assert_not_contains "234: does NOT recursively chown all of /home/agent" \
  "$home_own_log" "chown -R -P agent /home/agent "
# Ownership is by NAME (agent), never a numeric uid (provisioned uid != 1000).
assert_not_contains "234: chown uses agent by name, not numeric uid" \
  "$home_own_log" "chown -R 1000"
# Direct-in-home drop: `top` is the filename, so the chown targets that file
# (recursive chown of a file == chowning the file; correct, no regression).
assert_contains "234: file dropped directly in ~ chowns that file" \
  "$home_own_log" "chown -R -P agent /home/agent/direct-file"
cleanup_stubs

# 8o4. SECURITY: a hostile command `user` is dropped by kit_spec_commands (it is
#      interpolated into `msb exec -u <user>`), so the command never runs.
make_stubs; load_acq
usr_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  uk="${STUBDIR}/userkit"; mkdir -p "$uk"
  cat >"$uk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: user-kit
displayName: User
description: hostile user
commands:
  - phase: startup
    user: "0 -- sh -c touch/tmp/PWNED"
    command:
      - true
SPEC
  kit_spec_commands "$uk/spec.yaml" 2>&1
)
assert_contains "sec: hostile command user is dropped+warned" "$usr_out" "unsafe user"
assert_not_contains "sec: hostile user not emitted as a command record" "$usr_out" "__CMD__"
cleanup_stubs

# 8o5. `acq kit validate` REPORTS (not silently drops) a hostile mode / bad phase.
make_stubs; load_acq
val_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  vk="${STUBDIR}/valkit"; mkdir -p "$vk/files"
  printf 'x\n' > "$vk/files/f"
  cat >"$vk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: val-kit
displayName: Val
description: bad mode + bad phase
files:
  - path: /home/agent/f
    mode: "0644; rm -rf /"
    source: files/f
commands:
  - phase: bogus-phase
    user: "0"
    command:
      - true
SPEC
  kit_validate "$vk" 2>&1
  echo "RC=$?"
)
assert_contains "kit validate: reports non-octal mode" "$val_out" "mode must be octal"
assert_contains "kit validate: reports unknown phase" "$val_out" "unknown command phase"
assert_contains "kit validate: fails (RC=1)" "$val_out" "RC=1"
cleanup_stubs

# 8o5b. `acq kit validate` REPORTS (not silently drops) a bad environment var
#       NAME (env values reach the guest env and possibly a shell).
make_stubs; load_acq
env_val_out=$(
  . "${REPO_ROOT}/acq.backends/kit-translate.sh"
  evk="${STUBDIR}/envvalkit"; mkdir -p "$evk"
  cat >"$evk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: env-val-kit
displayName: Env Val
description: bad env var name
environment:
  GOOD_VAR: ok
  "1BAD": nope
SPEC
  kit_validate "$evk" 2>&1
  echo "RC=$?"
)
assert_contains "kit validate: reports invalid env var name" "$env_val_out" "invalid env var name"
assert_contains "kit validate: env-name failure (RC=1)" "$env_val_out" "RC=1"
cleanup_stubs

# 8p. msb provision passes --dns-nameserver so the guest can resolve allow-listed
#     hosts (the host's corporate resolver is unreachable from the microVM).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dns-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision dnsbox shell /tmp >/dev/null 2>&1
)
dns_log=$(cat "$CALLS")
assert_contains "msb: provision sets --dns-nameserver" "$dns_log" "--dns-nameserver 1.1.1.1"
cleanup_stubs

# 8q. ACQ_MSB_DNS_NAMESERVER override + disable (empty = omit the flag).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dns2-secrets" ACQ_MSB_DNS_NAMESERVER="9.9.9.9"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision dns2box shell /tmp >/dev/null 2>&1
)
assert_contains "msb: DNS nameserver override honored" "$(cat "$CALLS")" "--dns-nameserver 9.9.9.9"
cleanup_stubs

make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dns3-secrets" ACQ_MSB_DNS_NAMESERVER=""
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision dns3box shell /tmp >/dev/null 2>&1
)
assert_not_contains "msb: empty DNS nameserver omits the flag" "$(cat "$CALLS")" "--dns-nameserver"
cleanup_stubs

# 8q2. msb provision sizes the guest generously by default (memory + cpus).
#      msb's 512 MiB / 1 vCPU default OOM-kills a Node.js agent TUI (opencode
#      prints "Killed" on launch), so acq passes a generous default at create.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision membox shell /tmp >/dev/null 2>&1
)
mem_log=$(cat "$CALLS")
assert_contains "msb: provision sets a generous default --memory" "$mem_log" "--memory 4G"
assert_contains "msb: provision sets default --cpus" "$mem_log" "--cpus 2"
cleanup_stubs

# 8q3. ACQ_MSB_MEMORY / ACQ_MSB_CPUS overrides are honored.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem2-secrets" ACQ_MSB_MEMORY="8G" ACQ_MSB_CPUS="4"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mem2box shell /tmp >/dev/null 2>&1
)
mem2_log=$(cat "$CALLS")
assert_contains "msb: ACQ_MSB_MEMORY override honored" "$mem2_log" "--memory 8G"
assert_contains "msb: ACQ_MSB_CPUS override honored" "$mem2_log" "--cpus 4"
cleanup_stubs

# 8q4. Empty ACQ_MSB_MEMORY / ACQ_MSB_CPUS omit the flags (fall back to msb's
#      own default), and an invalid value is rejected with a warning (not passed
#      through, so it can't smuggle another flag onto the create line).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem3-secrets" ACQ_MSB_MEMORY="" ACQ_MSB_CPUS=""
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mem3box shell /tmp >/dev/null 2>&1
)
mem3_log=$(cat "$CALLS")
assert_not_contains "msb: empty ACQ_MSB_MEMORY omits the flag" "$mem3_log" "--memory"
assert_not_contains "msb: empty ACQ_MSB_CPUS omits the flag" "$mem3_log" "--cpus"
cleanup_stubs

make_stubs; load_acq
: > "$CALLS"
mem_bad_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mem4-secrets" ACQ_MSB_MEMORY="4G; rm -rf /" ACQ_MSB_CPUS="two"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mem4box shell /tmp 2>&1 >/dev/null
)
mem4_log=$(cat "$CALLS")
assert_contains "msb: invalid ACQ_MSB_MEMORY warns" "$mem_bad_out" "ignoring invalid ACQ_MSB_MEMORY"
assert_contains "msb: invalid ACQ_MSB_CPUS warns" "$mem_bad_out" "ignoring invalid ACQ_MSB_CPUS"
# The injected payload (`4G; rm -rf /`) must never reach `msb create` as a memory
# value. Assert the specific injection is absent from the create invocation rather
# than the bare substring `rm -rf` (which legitimately appears elsewhere, e.g. the
# OCI self-test's temp-dir cleanup).
assert_not_contains "msb: invalid memory value not passed to create" "$mem4_log" "rm -rf /"
assert_not_contains "msb: injected memory not on msb create" "$mem4_log" "msb create --name mem4box --memory 4G"
cleanup_stubs

