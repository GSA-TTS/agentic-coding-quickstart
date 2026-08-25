#!/usr/bin/env bash
#
# 120-workspace-preflight — workspace path + git-identity classifier
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 12. Workspace path pre-flight + git-identity classifier (host-side advisories)
# ===========================================================================
# Pure filesystem/string logic — no backend needed. Portable macOS + Linux.
# NB: source common.sh + build fixtures in a subshell, but run asserts in the
# parent so PASS/FAIL counters aren't lost (matches the kit-translate sections).

wt=$(mktemp -d "${TMPDIR:-/tmp}/acq-ws.XXXXXX")
# Isolate git identity so case (a) sees a truly-empty effective user.email.
( export HOME="$wt/fakehome" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$wt/repoA" "$wt/wsB/sub1" "$wt/wsB/sub2" "$wt/wsC" "$wt/okdir" "$wt/realrepo"
  ( cd "$wt/repoA" && git init -q )
  ( cd "$wt/wsB/sub1" && git init -q ); ( cd "$wt/wsB/sub2" && git init -q )
  ( cd "$wt/realrepo" && git init -q )
  ( cd "$wt/wsB" && ln -s "$wt/realrepo" symlinked )
  touch "$wt/afile"
)

# capture outputs (source in a subshell each time; assert in parent)
_id() { ( export HOME="$wt/fakehome" GIT_CONFIG_NOSYSTEM=1
          . "${REPO_ROOT}/acq.backends/common.sh"; warn_if_no_git_identity "$1" 2>&1 ); }
_pf() { ( . "${REPO_ROOT}/acq.backends/common.sh"; preflight_workspace_path "$1" >/dev/null 2>&1; echo $? ); }
_pfo(){ ( . "${REPO_ROOT}/acq.backends/common.sh"; preflight_workspace_path "$1" 2>&1 ); }

# --- preflight_workspace_path ---
assert_eq "preflight: missing path fails (rc=1)" "1" "$(_pf "$wt/nope")"
assert_contains "preflight: missing path names it" "$(_pfo "$wt/nope")" "does not exist"
assert_contains "preflight: missing path gives mkdir hint" "$(_pfo "$wt/nope")" "mkdir -p"
assert_eq "preflight: file path fails (rc=1)" "1" "$(_pf "$wt/afile")"
assert_contains "preflight: file path says must be a directory" "$(_pfo "$wt/afile")" "must be a directory"
assert_eq "preflight: existing dir passes (rc=0)" "0" "$(_pf "$wt/okdir")"
assert_eq "preflight: empty arg passes (cwd default, rc=0)" "0" "$(_pf "")"

# --- warn_if_no_git_identity ---
# (a) repo w/o effective identity
assert_contains "identity (a): repo w/o email warns 'this repo'" "$(_id "$wt/repoA")" "this repo has no git user.email"
# (a) repo WITH identity -> silent
( cd "$wt/repoA" && git config user.email dev@example.gov )
assert_eq "identity (a): repo with email is silent" "" "$(_id "$wt/repoA")"
# (b) non-repo root with sub-repos
assert_contains "identity (b): names workspace-root-not-a-repo" "$(_id "$wt/wsB")" "workspace root is not a git repo"
assert_contains "identity (b): points at a sub-repo path" "$(_id "$wt/wsB")" "wsB/sub1"
# (b) symlinked child must NOT be followed
assert_not_contains "identity (b): symlinked child not listed" "$(_id "$wt/wsB")" "symlinked"
# (c) empty dir = new workspace
assert_contains "identity (c): new-workspace onboarding note" "$(_id "$wt/wsC")" "no git repos yet"
# (d) non-directory -> silent
assert_eq "identity (d): non-dir is silent" "" "$(_id "$wt/does-not-exist")"

rm -rf "$wt"
unset -f _id _pf _pfo

# --- warn_if_published_ports_dead (backend-neutral health note) ---
# Pure common.sh logic: it depends only on acq_backend_ports (guest ports the
# sandbox publishes) and acq_backend_run (probe inside the guest), both stubbable
# as shell functions here. No backend, no network.
_wppd() {
  # $1 = ports-output fixture; $2 = per-port verdict ("listening"/"closed"/"unknown").
  ( . "${REPO_ROOT}/acq.backends/common.sh"
    _PORTS_OUT="$1"; _VERDICT="$2"
    acq_backend_ports() { printf '%s\n' "$_PORTS_OUT"; }
    # The probe is `acq_backend_run NAME -- sh -c '…' sh PORT`; echo the fixed
    # verdict so we exercise the parse/branch logic, not a real guest.
    acq_backend_run() { printf '%s\n' "$_VERDICT"; }
    warn_if_published_ports_dead somebox 2>&1 )
}
_PORTS_FIXTURE='sandbox 3000 -> host 127.0.0.1:3000 (create-time -p)
sandbox 4096 -> host 127.0.0.1:4096 (create-time -p)'
assert_contains "ports-dead: warns when a published port is closed" \
  "$(_wppd "$_PORTS_FIXTURE" closed)" "nothing listening inside 'somebox'"
assert_contains "ports-dead: closed warning names the dead port(s)" \
  "$(_wppd "$_PORTS_FIXTURE" closed)" "4096"
assert_contains "ports-dead: closed warning points at the failure mode doc" \
  "$(_wppd "$_PORTS_FIXTURE" closed)" "KNOWN_FAILURE_MODES.md #33"
assert_eq "ports-dead: silent when the port is listening" \
  "" "$(_wppd "$_PORTS_FIXTURE" listening)"
assert_eq "ports-dead: silent (no false warn) when the probe is indeterminate" \
  "" "$(_wppd "$_PORTS_FIXTURE" unknown)"
assert_eq "ports-dead: silent when the sandbox publishes no ports" \
  "" "$(_wppd "" closed)"
unset -f _wppd
unset _PORTS_FIXTURE
