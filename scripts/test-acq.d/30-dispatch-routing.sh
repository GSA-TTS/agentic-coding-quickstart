#!/usr/bin/env bash
#
# 30-dispatch-routing — each subcommand calls the right adapter
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 3. Dispatch routing — each subcommand calls the right adapter function
# ===========================================================================

# Verify `acq ls` calls `sbx ls`.
make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" ls 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "dispatch: ls -> sbx ls" "$log" "sbx ls"
cleanup_stubs

# Verify `acq version` prints version info including backend.
make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" version 2>&1)
assert_contains "dispatch: version reports backend" "$out" "backend:"
assert_contains "dispatch: version reports script path" "$out" "$REPO_ROOT/acq"
cleanup_stubs

# Verify `acq create opencode /proj` calls sbx create with --name and --kit flags.
make_stubs
_projdir=$(mktemp -d "${TMPDIR:-/tmp}/acq-proj.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(ACQ_BACKEND=sbx "$ACQ" create opencode "$_projdir" 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "dispatch: create -> sbx create --name" "$log" "sbx create --name"
assert_contains "dispatch: create includes --kit" "$log" "--kit"
assert_contains "dispatch: create includes usai kit" "$log" "acq-kits/usai-provider"
# The workspace positional MUST survive --name stripping in the sbx create argv.
# Regression: the provision arg scan re-appended the dropped --name VALUE, which
# left a stray positional so sbx read the name as the workspace and the real
# workspace as an extra mount (the intended workspace then looked "missing" and
# create prompted, then cancelled). Assert the real workspace path is present and
# the sandbox name is NOT sitting where sbx expects a workspace.
# NOTE: sbx.sh forwards the workspace positional to `sbx create` VERBATIM (it does
# not canonicalize on the create path — unlike the msb --volume mount path). So
# assert against the RAW $_projdir, not canonicalize_path: on macOS the temp dir
# is a /var -> /private/var symlink and the canonicalized form would not match the
# literal path in the argv. Mirrors the sibling "kit-flag: create keeps workspace
# positional" check.
sbx_create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "dispatch: create keeps workspace positional" "$sbx_create_line" "$_projdir"
rm -rf "$_projdir"
cleanup_stubs

# `acq create` must also run the github-scope advisory (same as `run`). Use a
# workspace that has a GitHub remote so advise_github_scope has something to say,
# and force the file secret store so no real global/scoped secret is consulted.
# Non-TTY here (stdout captured), so it advises + returns without prompting.
make_stubs
_ghproj=$(mktemp -d "${TMPDIR:-/tmp}/acq-ghcreate.XXXXXX")
( cd "$_ghproj" && git init -q && git remote add origin https://github.com/GSA-TTS/quickstart.git )
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(ACQ_BACKEND=sbx ACQ_SECRET_FORCE_FILE=1 ACQ_SECRET_FILE_DIR="$_ghproj/.secrets" \
  "$ACQ" create opencode "$_ghproj" </dev/null 2>&1)
assert_contains "dispatch: create runs github-scope advisory" "$out" "no repo-scoped GitHub token"
rm -rf "$_ghproj"
cleanup_stubs

# `acq create` runs a NON-BLOCKING USAi key advisory: it warns on a definitively
# invalid key but never aborts (create is detached). A key must be stored first
# (create now gates on key PRESENCE pre-provision, since msb binds at create);
# the advisory then reflects the models-API status of the stored key. Drive the
# stub's key status via STUB_KEY_STATUS. Use a bare temp workspace (no git
# remote) so the github advisory stays quiet and doesn't confuse the assertion.
make_stubs
_keyproj=$(mktemp -d "${TMPDIR:-/tmp}/acq-keycreate.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
# Bad key -> advisory fires, but create still succeeds (exit 0).
out=$(STUB_KEY_STATUS=401 ACQ_BACKEND=sbx "$ACQ" create opencode "$_keyproj" 2>&1); rc=$?
assert_contains "dispatch: create warns on invalid USAi key" "$out" "invalid or expired (HTTP 401)"
assert_eq       "dispatch: create does not abort on invalid key" "0" "$rc"
# Healthy key -> no advisory.
out=$(STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" create opencode "$_keyproj" 2>&1)
assert_not_contains "dispatch: create silent on valid USAi key" "$out" "invalid or expired"
rm -rf "$_keyproj"
cleanup_stubs

# `acq run` GATES on the USAi key: on a fresh create it FIRST requires a key to
# be stored (ensure_key_present, PRE-create, because msb binds secrets only at
# create), then post-create validates that same real sandbox (ensure_valid_key).
# A non-200 aborts unless the user sets/rotates; declining (empty answer on the
# [y/N] prompt) aborts. Drive the stub's key status via STUB_KEY_STATUS and
# decline by feeding an empty line on stdin. Bare workspace (no git remote) keeps
# the github advisory quiet.

# 3k1. No usai key stored, non-interactive stdin (piped) -> PRE-create gate emits
#      the TERSE non-tty line (no full interactive help) and aborts the run
#      (non-zero) BEFORE the sandbox is created. Piped stdin makes `[ ! -t 0 ]`
#      true, so ensure_key_present takes the terse branch — the full "Set it now"
#      prompt is TTY-only (see 3k1b).
make_stubs
_keyrun=$(mktemp -d "${TMPDIR:-/tmp}/acq-keyrun.XXXXXX")
rm -f "$STUBDIR/.created"
out=$(printf '\n' | STUB_KEY_STATUS=401 ACQ_BACKEND=sbx "$ACQ" run opencode "$_keyrun" 2>&1); rc=$?
assert_contains "run: never-set key (non-tty) names the setup case" "$out" "no USAi API key stored"
assert_not_contains "run: never-set key (non-tty) omits full interactive help" "$out" "Set it now"
assert_not_contains "run: never-set key does NOT say expired" "$out" "invalid or expired"
assert_eq "run: never-set + decline aborts run" "1" "$rc"
if [ -f "$STUBDIR/.created" ]; then
  fail "run: never-set + decline must NOT create a sandbox" "sandbox was created before key was set"
else
  pass "run: never-set + decline does not create a sandbox"
fi
rm -rf "$_keyrun"
cleanup_stubs

# 3k1a. `acq create` with an EMPTY key store + non-interactive stdin: the
#       PRE-create key gate (ensure_key_present) must abort the create WITHOUT
#       provisioning a sandbox — no `.created` marker and no `sbx create` in the
#       call log. This is the create-side mirror of 3k1: create binds the key at
#       provision time, so a create with no key must not proceed.
make_stubs
_kc=$(mktemp -d "${TMPDIR:-/tmp}/acq-keycreate-decline.XXXXXX")
rm -f "$STUBDIR/.created"
out=$(printf '\n' | ACQ_BACKEND=sbx "$ACQ" create opencode "$_kc" 2>&1); rc=$?
log=$(cat "$CALLS")
assert_contains "create: empty store (non-tty) aborts with terse gate" "$out" "no USAi API key stored"
assert_eq "create: empty store aborts (non-zero)" "1" "$rc"
assert_not_contains "create: empty store does NOT call sbx create" "$log" "sbx create"
if [ -f "$STUBDIR/.created" ]; then
  fail "create: empty store must NOT create a sandbox" "sandbox was created before key was set"
else
  pass "create: empty store does not create a sandbox"
fi
rm -rf "$_kc"
cleanup_stubs

# 3k1a2. sbx-specific split: the acq store can contain usai while the sbx proxy
#        custom secret is missing. That is NOT sufficient for a fresh sbx create:
#        the sandbox would snapshot no working USAi placeholder and later return
#        HTTP 401. Fail closed before `sbx create` so the user re-runs
#        `acq secret set -g usai` from a terminal to bind sbx's proxy table.
make_stubs
_kc=$(mktemp -d "${TMPDIR:-/tmp}/acq-keycreate-sbx-unbound.XXXXXX")
mkdir -p "$STUBDIR/secrets"
printf 'sk-stored-only\n' > "$STUBDIR/secrets/acq.usai"
rm -f "$STUBDIR/.created"
out=$(printf '' | ACQ_BACKEND=sbx "$ACQ" create opencode "$_kc" 2>&1); rc=$?
log=$(cat "$CALLS")
assert_contains "create(sbx): stored-only key says backend not configured" "$out" "backend is not configured to inject it"
assert_contains "create(sbx): stored-only key points at secret set" "$out" "acq secret set -g usai"
assert_eq "create(sbx): stored-only key aborts" "1" "$rc"
assert_not_contains "create(sbx): stored-only key does NOT call sbx create" "$log" "sbx create"
if [ -f "$STUBDIR/.created" ]; then
  fail "create(sbx): stored-only key must NOT create a sandbox" "sandbox was created without sbx proxy binding"
else
  pass "create(sbx): stored-only key does not create a sandbox"
fi
rm -rf "$_kc"
cleanup_stubs

# 3k1a3. Same acq-store state, but sbx's CUSTOM SECRETS table includes the
#        global USAI_API_KEY binding. That is backend-visible, so provisioning may
#        proceed.
make_stubs
_kc=$(mktemp -d "${TMPDIR:-/tmp}/acq-keycreate-sbx-bound.XXXXXX")
mkdir -p "$STUBDIR/secrets"
printf 'sk-stored-and-bound\n' > "$STUBDIR/secrets/acq.usai"
seed_sbx_usai_proxy_fixture
rm -f "$STUBDIR/.created"
out=$(STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" create opencode "$_kc" 2>&1); rc=$?
unset SBX_LS_FIXTURE
log=$(cat "$CALLS")
assert_not_contains "create(sbx): bound key not rejected" "$out" "backend is not configured"
assert_contains "create(sbx): bound key proceeds to sbx create" "$log" "sbx create"
assert_eq "create(sbx): bound key create succeeds" "0" "$rc"
if [ -f "$STUBDIR/.created" ]; then
  pass "create(sbx): bound key provisions a sandbox"
else
  fail "create(sbx): bound key must provision a sandbox" "no .created marker"
fi
rm -rf "$_kc"
cleanup_stubs

# 3k1b. CI host-env scenario (SHOULD-FIX): msb backend, EMPTY acq store, but a
#       host-exported USAI_API_KEY (as in CI), non-interactive stdin. msb binds
#       the host env var at provision (_acq_msb_bind_secrets_into), so the key
#       gate must treat it as PRESENT and NOT abort the create — provision must
#       proceed (`msb create` appears in the call log). This guards the
#       false-negative that would otherwise abort a create provision could
#       satisfy. sbx does NOT read host env, so the short-circuit is msb-only.
make_stubs
_kc=$(mktemp -d "${TMPDIR:-/tmp}/acq-keycreate-ci.XXXXXX")
rm -f "$STUBDIR/.msb_created"
out=$(printf '' | USAI_API_KEY="sk-ci-host" ACQ_BACKEND=msb "$ACQ" create opencode "$_kc" 2>&1); rc=$?
log=$(cat "$CALLS")
assert_not_contains "create(msb): host env key not aborted by gate" "$out" "no USAi API key stored"
assert_contains "create(msb): host env key -> provision proceeds (msb create)" "$log" "msb create"
if [ -f "$STUBDIR/.msb_created" ]; then
  pass "create(msb): host env key provisions a sandbox"
else
  fail "create(msb): host env key must provision a sandbox" "no .msb_created marker"
fi
rm -rf "$_kc"
cleanup_stubs

# 3k2. usai key PRESENT + bad status -> post-create gate says "invalid or
#      expired" + "Rotate now"; declining aborts.
make_stubs
_keyrun=$(mktemp -d "${TMPDIR:-/tmp}/acq-keyrun.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(printf '\n' | STUB_KEY_STATUS=401 ACQ_BACKEND=sbx "$ACQ" run opencode "$_keyrun" 2>&1); rc=$?
assert_contains "run: expired key names the rotate case" "$out" "invalid or expired"
assert_contains "run: expired key prompts to rotate" "$out" "Rotate now"
assert_not_contains "run: expired key does NOT say 'no USAi API key'" "$out" "No USAi API key is stored"
assert_eq "run: expired + decline aborts attach" "1" "$rc"
rm -rf "$_keyrun"
cleanup_stubs

# 3k3. Healthy status attaches regardless of store state (no gate message).
make_stubs
_keyrun=$(mktemp -d "${TMPDIR:-/tmp}/acq-keyrun.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(STUB_OPENCODE_OK=1 STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" run opencode "$_keyrun" 2>&1); rc=$?
assert_not_contains "run: healthy key -> no gate message" "$out" "Aborting attach"
assert_eq "run: healthy key attaches" "0" "$rc"
rm -rf "$_keyrun"
cleanup_stubs

# 3k4. `acq run opencode` runs opencode's postinstall when the binary is not yet
#       functional (the "postinstall script was not run" gap), then attaches.
#       The stub reports opencode broken until postinstall.mjs runs.
make_stubs
_ocrun=$(mktemp -d "${TMPDIR:-/tmp}/acq-ocrun.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" run opencode "$_ocrun" 2>&1); rc=$?
log=$(cat "$CALLS")
assert_contains "run(opencode): runs postinstall.mjs when binary not functional" "$log" "postinstall.mjs"
# The postinstall runs under a guest-side `timeout` guard so a wedged registry
# fetch cannot hang `acq run` (review SHOULD-FIX). The stub's exec log records
# the sh -c body, so the bound is observable there.
assert_contains "run(opencode): postinstall wrapped in a timeout guard" "$log" "timeout"
assert_not_contains "run(opencode): no postinstall-failure warning after fix" "$out" "does not appear runnable"
assert_eq "run(opencode): attaches after postinstall" "0" "$rc"
rm -rf "$_ocrun"
cleanup_stubs

# 3k5. When opencode is ALREADY functional, acq does NOT re-run postinstall.
make_stubs
_ocrun=$(mktemp -d "${TMPDIR:-/tmp}/acq-ocok.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(STUB_OPENCODE_OK=1 STUB_KEY_STATUS=200 ACQ_BACKEND=sbx "$ACQ" run opencode "$_ocrun" 2>&1)
log=$(cat "$CALLS")
assert_not_contains "run(opencode): skips postinstall when already runnable" "$log" "postinstall.mjs"
rm -rf "$_ocrun"
cleanup_stubs

# 3k6. USAi API UNREACHABLE (curl connection failure / HTTP 000, not a real
#       status): the gate must diagnose a NETWORK problem, must NOT claim the key
#       is invalid/expired, must NOT prompt to rotate, and must abort the run
#       (fail closed rather than attach a broken session). A stored key is
#       present, so the ONLY reason it doesn't say "invalid or expired" is the
#       unreachable classification.
make_stubs
_keyrun=$(mktemp -d "${TMPDIR:-/tmp}/acq-unreach.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(STUB_KEY_UNREACHABLE=1 ACQ_BACKEND=sbx "$ACQ" run opencode "$_keyrun" 2>&1); rc=$?
assert_contains "run: unreachable names a network problem" "$out" "could not reach the USAi API"
assert_contains "run: unreachable says not a key problem" "$out" "NOT an invalid or expired key"
assert_not_contains "run: unreachable does NOT prompt to rotate" "$out" "Rotate now"
assert_not_contains "run: unreachable does NOT print a mangled curl error" "$out" "curl:"
assert_eq "run: unreachable aborts the run (fail closed)" "1" "$rc"
rm -rf "$_keyrun"
cleanup_stubs

# 3k6a. Sig 2 "pinned public address" variant (KFM §30): the split-horizon name
#        was bypassed by pinning USAi's PUBLIC IP, so DNS resolved but the
#        TLS/connect handshake still failed (curl exit 35) — the endpoint is only
#        reachable via the corporate tunnel. This must be treated exactly like the
#        broad unreachable case (network problem, fail closed, no rotate prompt),
#        and must NOT emit the DNS "did not RESOLVE" / ACQ_MSB_DNS_NAMESERVER hint,
#        which belongs only to the NXDOMAIN (exit 6) branch. Guards against a
#        pinned-public failure being misfiled as a resolver problem.
make_stubs
_keyrun35=$(mktemp -d "${TMPDIR:-/tmp}/acq-pinned35.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out35=$(STUB_KEY_UNREACHABLE=35 ACQ_BACKEND=sbx "$ACQ" run opencode "$_keyrun35" 2>&1); rc35=$?
assert_contains "run(rc=35): pinned-public names a network problem" "$out35" "could not reach the USAi API"
assert_contains "run(rc=35): pinned-public says not a key problem" "$out35" "NOT an invalid or expired key"
assert_not_contains "run(rc=35): pinned-public does NOT prompt to rotate" "$out35" "Rotate now"
assert_not_contains "run(rc=35): pinned-public does NOT emit a DNS resolver hint" "$out35" "ACQ_MSB_DNS_NAMESERVER"
assert_not_contains "run(rc=35): pinned-public does NOT say 'did not RESOLVE'" "$out35" "did not RESOLVE"
assert_eq "run(rc=35): pinned-public aborts the run (fail closed)" "1" "$rc35"
rm -rf "$_keyrun35"
cleanup_stubs

# 3k7. check_key returns a CLEAN token even when curl output is polluted: a real
#       HTTP status classifies as that status; a connection failure classifies as
#       "unreachable"; never free-form curl error text.
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/common.sh"
  set +e
  assert_eq "classify: clean 200"          "200"         "$(_classify_key_status '200|0')"
  assert_eq "classify: clean 401"          "401"         "$(_classify_key_status '401|0')"
  assert_eq "classify: 000 -> unreachable" "unreachable" "$(_classify_key_status '000|56')"
  assert_eq "classify: nonzero exit -> unreachable" "unreachable" "$(_classify_key_status '000|7')"
  # curl exit 6 = NXDOMAIN: split-horizon-DNS tell, distinct from a broad cut.
  assert_eq "classify: exit 6 -> unresolved" "unresolved" "$(_classify_key_status '000|6')"
  # curl exit 35 = TLS/connect handshake failure. This is the Sig 2 "pinned
  # public address" variant (KFM §30): the split-horizon name was bypassed by
  # pinning USAi's PUBLIC IP, so DNS resolved but the connection still could not
  # complete (the endpoint is reachable only via the corporate tunnel). It must
  # classify as "unreachable" (a network-path problem), NOT "unresolved" and NOT
  # a bad key — the caller must not emit a DNS-resolver hint for it.
  assert_eq "classify: exit 35 (pinned-public) -> unreachable" "unreachable" "$(_classify_key_status '000|35')"
  # Polluted output (curl error leaked before the code) must not escape as text.
  polluted='curl: (56) OpenSSL SSL_read: unexpected eof000|56'
  assert_eq "classify: polluted curl error -> unreachable" "unreachable" "$(_classify_key_status "$polluted")"
) 2>/dev/null; pass "classify: key-status classification is clean (code|unresolved|unreachable|empty)"
cleanup_stubs

# 3k7a. A USAi NXDOMAIN (curl exit 6) is reported as a DNS/split-horizon problem
#        with a resolver hint — NOT as unreachable, and NOT as a bad key. Reuses
#        the sbx key-check path with STUB_KEY_UNRESOLVED=1 (same seeding as 3k6).
make_stubs
_keyrun2=$(mktemp -d "${TMPDIR:-/tmp}/acq-unres.XXXXXX")
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
unres_out=$(STUB_KEY_UNRESOLVED=1 ACQ_BACKEND=sbx "$ACQ" run opencode "$_keyrun2" 2>&1); unres_rc=$?
assert_contains "run: NXDOMAIN names a resolution problem" "$unres_out" "did not RESOLVE"
assert_contains "run: NXDOMAIN points at ACQ_MSB_DNS_NAMESERVER" "$unres_out" "ACQ_MSB_DNS_NAMESERVER"
assert_not_contains "run: NXDOMAIN does NOT prompt to rotate" "$unres_out" "Rotate now"
assert_eq "run: NXDOMAIN aborts the run (fail closed)" "1" "$unres_rc"
rm -rf "$_keyrun2"
cleanup_stubs


# Verify `acq stop mybox` calls sbx stop.
make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" stop mybox 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "dispatch: stop -> sbx stop" "$log" "sbx stop mybox"
cleanup_stubs

# Verify `acq rm mybox` calls sbx rm --force.
make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" rm mybox 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "dispatch: rm -> sbx rm --force" "$log" "sbx rm --force mybox"
cleanup_stubs

# Verify `acq exec mybox -- echo hi` calls sbx exec.
make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" exec mybox -- echo hi 2>/dev/null)
log=$(cat "$CALLS")
assert_contains "dispatch: exec -> sbx exec" "$log" "sbx exec mybox"
cleanup_stubs

# Verify unknown subcommand passes through to sbx, and that the handoff is
# ANNOUNCED on stderr (the user must know it left acq's vocabulary and that
# subsequent output/errors are the backend's, not acq's).
make_stubs
out=$(ACQ_BACKEND=sbx "$ACQ" policy init balanced 2>&1; true)
log=$(cat "$CALLS")
assert_contains "dispatch: unknown passthrough -> sbx" "$log" "sbx policy init balanced"
# Regression: the verb must NOT be doubled (`sbx policy policy init balanced`).
# The dispatch case block must shift the subcommand before forwarding.
assert_not_contains "dispatch: passthrough does NOT double the verb" "$log" "sbx policy policy"
assert_contains "dispatch: unknown passthrough is announced" "$out" "not an acq subcommand — forwarding to 'sbx'"
assert_contains "dispatch: passthrough notice attributes output to backend" "$out" "from 'sbx', not acq"
cleanup_stubs

# --kit interception: a user-supplied `--kit <ref>` on run/create MUST be
# folded into acq's translated kit list, NOT forwarded to the backend as a raw
# flag+value trailing the create args. With ACQ_SBX_KIT_PASSTHROUGH=1 kit refs
# pass through untranslated, so the ref appears in the sbx create line as a
# `--kit <ref>` token pair; the point of these tests is WHERE it appears and that
# the create positionals are clean.
#
# NOTE: the workspace positional MUST be a real, existing directory — acq's
# pre-flight aborts create/run on a nonexistent path before it ever
# reaches `sbx create`. Use a throwaway temp dir as the workspace.
_kitproj=$(mktemp -d "${TMPDIR:-/tmp}/acq-kitproj.XXXXXX")
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(ACQ_BACKEND=sbx "$ACQ" create opencode --kit /tmp/mykit "$_kitproj" 2>/dev/null)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
# The kit ref is present (folded into the kit list, emitted as a --kit flag).
assert_contains "kit-flag: create folds --kit ref into kit list (#222)" "$create_line" "--kit /tmp/mykit"
# The workspace positional survives.
assert_contains "kit-flag: create keeps workspace positional (#222)" "$create_line" "$_kitproj"
# The kit ref must NOT trail as a raw positional after the workspace (i.e. the
# create args are opencode + <workspace> only, with all --kit pairs among the
# leading translated kit flags). Assert the ref does not appear after the path.
assert_not_contains "kit-flag: --kit not left as trailing raw arg (#222)" "$create_line" "$_kitproj --kit /tmp/mykit"
assert_not_contains "kit-flag: no dangling ref after workspace (#222)" "$create_line" "$_kitproj /tmp/mykit"
cleanup_stubs

# --kit=<ref> (equals form) is also intercepted.
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(ACQ_BACKEND=sbx "$ACQ" create opencode --kit=/tmp/eqkit "$_kitproj" 2>/dev/null)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "kit-flag: create folds --kit=<ref> form (#222)" "$create_line" "--kit /tmp/eqkit"
assert_not_contains "kit-flag: --kit= not left as raw arg (#222)" "$create_line" "--kit=/tmp/eqkit"
cleanup_stubs

# Multiple --kit flags are all intercepted.
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(ACQ_BACKEND=sbx "$ACQ" create opencode --kit /tmp/k1 --kit /tmp/k2 "$_kitproj" 2>/dev/null)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "kit-flag: first repeated --kit folded (#222)" "$create_line" "--kit /tmp/k1"
assert_contains "kit-flag: second repeated --kit folded (#222)" "$create_line" "--kit /tmp/k2"
assert_contains "kit-flag: workspace still present with repeated --kit (#222)" "$create_line" "$_kitproj"
cleanup_stubs

# run form also intercepts --kit (routes through provision -> sbx create).
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(ACQ_BACKEND=sbx "$ACQ" run opencode --kit /tmp/runkit "$_kitproj" 2>/dev/null)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "kit-flag: run folds --kit ref into kit list (#222)" "$create_line" "--kit /tmp/runkit"
assert_not_contains "kit-flag: run --kit not left as trailing raw arg (#222)" "$create_line" "$_kitproj --kit /tmp/runkit"
cleanup_stubs

# A `--kit` AFTER the `--` separator belongs to the AGENT, not acq: it MUST NOT
# be hijacked into the kit list, and it MUST survive intact in the agent args.
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
out=$(ACQ_BACKEND=sbx "$ACQ" run opencode "$_kitproj" -- --kit evil-agent-arg 2>/dev/null)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
# acq must not fold the agent's --kit into the sandbox kit list.
assert_not_contains "kit-flag: agent --kit after -- not hijacked (#222)" "$create_line" "--kit evil-agent-arg"
# The agent's flag must be forwarded verbatim to the agent invocation.
assert_contains "kit-flag: agent --kit after -- forwarded intact (#222)" "$log" "--kit evil-agent-arg"
cleanup_stubs
rm -rf "$_kitproj"
