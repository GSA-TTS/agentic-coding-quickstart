#!/usr/bin/env bash
#
# 60-help — acq help / per-verb --help / passthrough
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 7b. acq help — acq's own usage + backend passthrough, and --backend {sbx,msb}
# ===========================================================================
make_stubs
# `acq help` prints acq usage, lists --backend sbx|msb, then the backend's help.
help_out=$(ACQ_BACKEND=sbx "$ACQ" help 2>&1); help_rc=$?
assert_eq "help: exits 0" "0" "$help_rc"
assert_contains "help: shows acq banner" "$help_out" "acq — agentic coding quickstart wrapper"
assert_contains "help: documents --backend sbx|msb" "$help_out" "--backend sbx|msb"
assert_contains "help: mentions msb backend" "$help_out" "microsandbox (msb)"
assert_contains "help: appends backend help" "$help_out" "SBX-TOPLEVEL-HELP"
# `acq --help` and `acq -h` behave the same.
assert_contains "help: --help form" "$(ACQ_BACKEND=sbx "$ACQ" --help 2>&1)" "acq — agentic coding quickstart wrapper"
assert_contains "help: -h form" "$(ACQ_BACKEND=sbx "$ACQ" -h 2>&1)" "acq — agentic coding quickstart wrapper"
# `acq help run` and `acq run --help` delegate to the backend's per-subcommand help.
assert_contains "help: 'help run' -> backend run --help" "$(ACQ_BACKEND=sbx "$ACQ" help run 2>&1)" "SBX-RUN-HELP"
assert_contains "help: 'run --help' -> backend run --help" "$(ACQ_BACKEND=sbx "$ACQ" run --help 2>&1)" "SBX-RUN-HELP"
# A bare `acq` (no subcommand) prints help but is a usage error (exit 2).
bare_out=$(ACQ_BACKEND=sbx "$ACQ" 2>&1); bare_rc=$?
assert_eq "help: bare acq exits 2" "2" "$bare_rc"
assert_contains "help: bare acq shows usage" "$bare_out" "acq — agentic coding quickstart wrapper"
# --backend msb surfaces the msb backend's own help under the separator.
assert_contains "help: --backend msb appends msb help" "$(ACQ_BACKEND=sbx "$ACQ" --backend msb help 2>&1)" "msb"
# A `--help`/`-h` AFTER `--` must NOT be hijacked into acq's help — it belongs to
# the agent/inner command and must pass through verbatim.
: > "$CALLS"
ACQ_BACKEND=sbx "$ACQ" exec mybox -- mycmd --help >/dev/null 2>&1 || true
afterdd_log=$(cat "$CALLS")
assert_contains "help: --help after -- passes through to backend exec" "$afterdd_log" "mycmd --help"
assert_not_contains "help: --help after -- did NOT print acq help" "$afterdd_log" "agentic coding quickstart wrapper"
cleanup_stubs

# 7b2. Per-subcommand `--help` prints acq's OWN per-verb usage for verbs acq owns
#      (secret/kit/backend), not merely the top-level banner. `acq secret set
#      --help` (a sub-subcommand) routes to the `secret` usage too. All exit 0.
make_stubs
# secret family
sec_help=$(ACQ_BACKEND=sbx "$ACQ" secret --help 2>&1); sec_rc=$?
assert_eq "help: 'secret --help' exits 0" "0" "$sec_rc"
assert_contains "help: 'secret --help' shows acq secret usage" "$sec_help" "acq secret — manage sandbox secrets"
assert_contains "help: 'secret --help' documents import" "$sec_help" "acq secret import"
assert_not_contains "help: 'secret --help' is NOT just the top banner" "$sec_help" "agentic coding quickstart wrapper"
secset_help=$(ACQ_BACKEND=sbx "$ACQ" secret set --help 2>&1)
assert_contains "help: 'secret set --help' routes to secret usage" "$secset_help" "acq secret — manage sandbox secrets"
secimp_help=$(ACQ_BACKEND=sbx "$ACQ" secret import --help 2>&1)
assert_contains "help: 'secret import --help' routes to secret usage" "$secimp_help" "acq secret import"
# kit family
kit_help=$(ACQ_BACKEND=sbx "$ACQ" kit --help 2>&1); kit_rc=$?
assert_eq "help: 'kit --help' exits 0" "0" "$kit_rc"
assert_contains "help: 'kit --help' shows acq kit usage" "$kit_help" "acq kit — manage neutral hybrid/v1 kits"
kitapply_help=$(ACQ_BACKEND=sbx "$ACQ" kit apply --help 2>&1)
assert_contains "help: 'kit apply --help' routes to kit usage" "$kitapply_help" "acq kit — manage neutral hybrid/v1 kits"
# backend family
be_help=$(ACQ_BACKEND=sbx "$ACQ" backend --help 2>&1); be_rc=$?
assert_eq "help: 'backend --help' exits 0" "0" "$be_rc"
assert_contains "help: 'backend --help' shows acq backend usage" "$be_help" "acq backend — select the sandbox backend"
beset_help=$(ACQ_BACKEND=sbx "$ACQ" backend set --help 2>&1)
assert_contains "help: 'backend set --help' routes to backend usage" "$beset_help" "acq backend — select the sandbox backend"
cleanup_stubs

# 7b3. Every acq-OWNED verb now has its OWN per-verb usage on `--help` (exit 0),
#      NOT the generic top-level banner. This is the fix for the reported gap
#      where `acq start --help` / `acq restart --help` printed only the banner and
#      then the backend's (misleading) help. Assert each verb's own usage header.
make_stubs
_assert_verb_help() { # NAME EXPECT_SUBSTRING
  local _n="$1" _sub="$2" _out _rc
  _out=$(ACQ_BACKEND=msb "$ACQ" "$_n" --help 2>&1); _rc=$?
  assert_eq "help: '$_n --help' exits 0" "0" "$_rc"
  assert_contains "help: '$_n --help' shows acq's own $_n usage" "$_out" "$_sub"
  assert_not_contains "help: '$_n --help' is NOT the generic banner" "$_out" "Global flags (before the subcommand):"
}
_assert_verb_help run          "acq run — create+attach a sandbox"
_assert_verb_help create       "acq create — create a sandbox (detached"
_assert_verb_help ls           "acq ls — list sandboxes"
_assert_verb_help stop         "acq stop — stop a sandbox"
_assert_verb_help start        "acq start — resume a stopped sandbox"
_assert_verb_help restart      "acq restart — stop then start a sandbox"
_assert_verb_help rm           "acq rm — remove a sandbox"
_assert_verb_help exec         "acq exec — run a command inside a sandbox"
_assert_verb_help cp           "acq cp — copy files in or out"
_assert_verb_help ports        "acq ports — list or publish"
_assert_verb_help github-scope "acq github-scope — scope a GitHub token"
_assert_verb_help usai-rotate-api-key "acq usai-rotate-api-key — rotate"
_assert_verb_help version      "acq version — show acq version"
_assert_verb_help doctor       "acq doctor — backend health check"
cleanup_stubs

# 7b4. Backend-help suppression policy: for acq-ONLY verbs (start/restart/create/
#      version/doctor/github-scope/usai-rotate-api-key) the backend's own help is
#      NOT appended (it is absent or misleading — the reported `msb restart`
#      fallthrough). For SHARED verbs (run/exec/…) the backend help IS appended.
make_stubs
# acq-only: no backend separator line, no backend help body.
start_help=$(ACQ_BACKEND=msb "$ACQ" start --help 2>&1)
assert_not_contains "help: 'start --help' suppresses the backend help block" "$start_help" "msb start --help"
assert_not_contains "help: 'start --help' shows no backend top-level help" "$start_help" "MSB-TOPLEVEL-HELP"
restart_help=$(ACQ_BACKEND=msb "$ACQ" restart --help 2>&1)
assert_not_contains "help: 'restart --help' suppresses the backend help block" "$restart_help" "msb restart --help"
# start/restart usage cross-references acq run (the attach path that injects SSH_AUTH_SOCK).
assert_contains "help: 'start --help' points at acq run for an attached session" "$start_help" "acq run"
# shared verb: the backend's per-verb help IS appended (sbx run stub emits SBX-RUN-HELP).
runh=$(ACQ_BACKEND=sbx "$ACQ" run --help 2>&1)
assert_contains "help: 'run --help' still appends the backend's run help" "$runh" "SBX-RUN-HELP"
cleanup_stubs

# 7c. `acq secret ls` is a silent acq-store view (delegates to the backend on
#     sbx WITHOUT doubling the token and WITHOUT a passthrough notice — it is an
#     acq-owned verb, not an escape hatch).
make_stubs
: > "$CALLS"
ls_out=$(ACQ_BACKEND=sbx "$ACQ" secret ls -q 2>&1 || true)
ls_log=$(cat "$CALLS")
assert_contains "secret ls: forwards a single ls token" "$ls_log" "sbx secret ls -q"
assert_not_contains "secret ls: does NOT double the token" "$ls_log" "secret ls ls"
assert_not_contains "secret ls: not announced as a passthrough" "$ls_out" "forwarding to"
cleanup_stubs

# 7c2. `acq secret set-custom` FAILS CLOSED — it would bypass the acq secret
#      store (write only the backend's own table, expose the value on argv, and
#      on msb error outright). acq must NOT forward it to the backend and must
#      point the user at the acq-store-aware `acq secret set … --host … --env …`.
make_stubs
: > "$CALLS"
sc_out=$(ACQ_BACKEND=sbx "$ACQ" secret set-custom -g --host h --env E 2>&1); sc_rc=$?
sc_log=$(cat "$CALLS")
[ "$sc_rc" -ne 0 ] && pass "secret set-custom: exits non-zero" \
  || fail "secret set-custom: must exit non-zero" "rc=$sc_rc"
assert_contains "secret set-custom: says it would bypass the acq store" "$sc_out" "bypass the acq secret store"
assert_contains "secret set-custom: points at the managed equivalent" "$sc_out" "acq secret set [-g | SANDBOX] SERVICE --host HOST --env ENV"
assert_not_contains "secret set-custom: never forwards to the backend" "$sc_log" "sbx secret"
cleanup_stubs

# 7c3. `acq secret import` populates the acq store from known host env vars
#      (usai/github/gitlab) WITHOUT ever invoking the backend's `secret` CLI and
#      WITHOUT the value touching argv. --dry-run writes nothing; --all imports
#      detected services and skips existing; --force overwrites; a scope arg
#      scopes the entry. Global by default.
make_stubs
_impdir=$(mktemp -d "${TMPDIR:-/tmp}/acq-import.XXXXXX")
: > "$CALLS"
# --dry-run: detects github from GH_TOKEN, writes nothing, never calls backend.
imp_out=$(GH_TOKEN=ghp_DRY1234 USAI_API_KEY='' GITHUB_TOKEN='' GITLAB_TOKEN='' \
  ACQ_SECRET_STORE_DIR="$_impdir/dry" ACQ_BACKEND=sbx "$ACQ" secret import --dry-run 2>&1); imp_rc=$?
imp_log=$(cat "$CALLS")
assert_eq "secret import --dry-run: exits 0" "0" "$imp_rc"
assert_contains "secret import --dry-run: detects github via GH_TOKEN" "$imp_out" "would import 'github' from \$GH_TOKEN"
assert_contains "secret import --dry-run: previews only last 4 (…1234)" "$imp_out" "…1234"
assert_not_contains "secret import: value never leaks in output" "$imp_out" "ghp_DRY1234"
assert_not_contains "secret import: never invokes the backend secret CLI" "$imp_log" "sbx secret"
[ ! -e "$_impdir/dry/acq.github" ] && pass "secret import --dry-run: wrote nothing" \
  || fail "secret import --dry-run: must not write" "found acq.github"
# --all: actually imports usai + github, stores the real values off argv.
: > "$CALLS"
USAI_API_KEY=sk-usai-AAAA GITHUB_TOKEN=ghp_BBBB GITLAB_TOKEN='' GH_TOKEN='' \
  ACQ_SECRET_STORE_DIR="$_impdir/all" ACQ_BACKEND=sbx "$ACQ" secret import --all >/dev/null 2>&1
all_log=$(cat "$CALLS")
assert_not_contains "secret import --all: never invokes the backend secret CLI" "$all_log" "sbx secret"
[ "$(cat "$_impdir/all/acq.usai" 2>/dev/null)" = "sk-usai-AAAA" ] && pass "secret import --all: stored usai value" \
  || fail "secret import --all: usai value wrong" "$(cat "$_impdir/all/acq.usai" 2>/dev/null)"
[ "$(cat "$_impdir/all/acq.github" 2>/dev/null)" = "ghp_BBBB" ] && pass "secret import --all: stored github value" \
  || fail "secret import --all: github value wrong" "$(cat "$_impdir/all/acq.github" 2>/dev/null)"
# Re-run --all: existing entries are SKIPPED (not overwritten).
reall_out=$(USAI_API_KEY=sk-usai-CCCC GITHUB_TOKEN=ghp_BBBB \
  ACQ_SECRET_STORE_DIR="$_impdir/all" ACQ_BACKEND=sbx "$ACQ" secret import --all 2>&1)
assert_contains "secret import --all: skips existing" "$reall_out" "already stored"
[ "$(cat "$_impdir/all/acq.usai" 2>/dev/null)" = "sk-usai-AAAA" ] && pass "secret import --all: did NOT overwrite" \
  || fail "secret import --all: overwrote without --force" "$(cat "$_impdir/all/acq.usai" 2>/dev/null)"
# --force overwrites.
USAI_API_KEY=sk-usai-CCCC ACQ_SECRET_STORE_DIR="$_impdir/all" ACQ_BACKEND=sbx "$ACQ" secret import usai --force >/dev/null 2>&1
[ "$(cat "$_impdir/all/acq.usai" 2>/dev/null)" = "sk-usai-CCCC" ] && pass "secret import --force: overwrote" \
  || fail "secret import --force: did not overwrite" "$(cat "$_impdir/all/acq.usai" 2>/dev/null)"
# SANDBOX scope writes a scoped key.
GITLAB_TOKEN=glpat-DDDD ACQ_SECRET_STORE_DIR="$_impdir/all" ACQ_BACKEND=sbx "$ACQ" secret import gitlab mybox --all >/dev/null 2>&1
[ -e "$_impdir/all/acq.mybox.gitlab" ] && pass "secret import SANDBOX: wrote scoped key" \
  || fail "secret import SANDBOX: no scoped key" "missing acq.mybox.gitlab"
# No tokens detected -> exits 0 with a clear message, no backend call.
: > "$CALLS"
none_out=$(USAI_API_KEY='' GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
  ACQ_SECRET_STORE_DIR="$_impdir/none" ACQ_BACKEND=sbx "$ACQ" secret import --all 2>&1); none_rc=$?
assert_eq "secret import (none found): exits 0" "0" "$none_rc"
assert_contains "secret import (none found): says nothing found" "$none_out" "no known service tokens found"
rm -rf "$_impdir"
cleanup_stubs

# 7c3-integrity. A secret VALUE that the single-line store cannot round-trip
#      (newline or tab) must be REJECTED (fail closed) — never truncated-and-
#      stored, and no fragment of the value may leak to stderr. Regression for
#      the review BLOCKER (framing on TAB + single-line read truncated multi-line
#      values and leaked the 2nd line).
make_stubs
_intdir=$(mktemp -d "${TMPDIR:-/tmp}/acq-int.XXXXXX")
# Multi-line value: rejected, not stored, and "SECRET2" never appears in output.
ml_out=$(USAI_API_KEY="$(printf 'line1\nSECRET2')" GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
  ACQ_SECRET_STORE_DIR="$_intdir/ml" ACQ_BACKEND=sbx "$ACQ" secret import --all 2>&1); ml_rc=$?
assert_eq "secret import (multi-line): run completes rc 0" "0" "$ml_rc"
assert_contains "secret import (multi-line): rejected with a clear reason" "$ml_out" "contains a newline or tab"
assert_not_contains "secret import (multi-line): 2nd line never leaks to stderr" "$ml_out" "SECRET2"
[ ! -e "$_intdir/ml/acq.usai" ] && pass "secret import (multi-line): nothing stored" \
  || fail "secret import (multi-line): must not store a truncated value" "found acq.usai"
# Tab value: rejected, not stored, fragment never leaks.
tab_out=$(USAI_API_KEY="$(printf 'aaa\tTABBED')" GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
  ACQ_SECRET_STORE_DIR="$_intdir/tab" ACQ_BACKEND=sbx "$ACQ" secret import --all 2>&1)
assert_contains "secret import (tab): rejected" "$tab_out" "contains a newline or tab"
assert_not_contains "secret import (tab): fragment never leaks" "$tab_out" "TABBED"
[ ! -e "$_intdir/tab/acq.usai" ] && pass "secret import (tab): nothing stored" \
  || fail "secret import (tab): must not store" "found acq.usai"
# A well-formed single-line value with shell-special chars round-trips EXACTLY.
USAI_API_KEY='a b=c;d$e' GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
  ACQ_SECRET_STORE_DIR="$_intdir/ok" ACQ_BACKEND=sbx "$ACQ" secret import usai --force >/dev/null 2>&1
[ "$(cat "$_intdir/ok/acq.usai" 2>/dev/null)" = 'a b=c;d$e' ] && pass "secret import: single-line value round-trips exactly" \
  || fail "secret import: value corrupted" "$(cat "$_intdir/ok/acq.usai" 2>/dev/null)"
rm -rf "$_intdir"
cleanup_stubs

# 7c3b. `acq secret import` on msb ALSO never invokes the backend `secret` CLI
#       (msb has none) — it writes only the acq store, same as sbx.
make_stubs
_impmdir=$(mktemp -d "${TMPDIR:-/tmp}/acq-importm.XXXXXX")
: > "$CALLS"
USAI_API_KEY=sk-usai-MMMM GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
  ACQ_SECRET_STORE_DIR="$_impmdir/store" ACQ_BACKEND=msb "$ACQ" secret import --all >/dev/null 2>&1; impm_rc=$?
impm_log=$(cat "$CALLS")
assert_eq "secret import(msb): exits 0" "0" "$impm_rc"
assert_not_contains "secret import(msb): never invokes 'msb secret'" "$impm_log" "msb secret"
[ "$(cat "$_impmdir/store/acq.usai" 2>/dev/null)" = "sk-usai-MMMM" ] && pass "secret import(msb): stored usai value" \
  || fail "secret import(msb): usai value wrong" "$(cat "$_impmdir/store/acq.usai" 2>/dev/null)"
rm -rf "$_impmdir"
cleanup_stubs

# 7c4. `acq secret set-custom` still FAILS CLOSED on msb (no `secret` CLI at all)
#      — the handoff must never even reach `msb secret`.
make_stubs
: > "$CALLS"
ACQ_BACKEND=msb "$ACQ" secret set-custom -g --host h --env E >/dev/null 2>&1; scm_rc=$?
scm_log=$(cat "$CALLS")
[ "$scm_rc" -ne 0 ] && pass "secret set-custom(msb): exits non-zero" \
  || fail "secret set-custom(msb): must exit non-zero" "rc=$scm_rc"
assert_not_contains "secret set-custom(msb): never invokes 'msb secret'" "$scm_log" "msb secret"
cleanup_stubs

# 7d. An unrecognized `secret` subverb is an acq-vocabulary mistake — acq owns
#     the `secret` verb, so it must fail closed with acq's own error and NOT
#     forward the token to the backend (which would surface a confusing raw
#     backend error, or worse, silently accept something acq never meant to
#     expose).
make_stubs
: > "$CALLS"
bad_out=$(ACQ_BACKEND=sbx "$ACQ" secret bogus-verb 2>&1); bad_rc=$?
bad_log=$(cat "$CALLS")
assert_contains "secret bogus: acq's own unknown-subcommand error" "$bad_out" "unknown secret subcommand 'bogus-verb'"
assert_contains "secret bogus: error lists the 'has' verb" "$bad_out" "set | rm | ls | has | import | --help"
[ "$bad_rc" -ne 0 ] && pass "secret bogus: exits non-zero" \
  || fail "secret bogus: must exit non-zero" "rc=$bad_rc"
assert_not_contains "secret bogus: never forwards to the backend" "$bad_log" "sbx secret"
cleanup_stubs
