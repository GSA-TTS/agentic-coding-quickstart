#!/usr/bin/env bash
#
# 125-github-scope — GitHub token down-scoping helpers (ADR-0013)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 13. GitHub token down-scoping helpers (ADR-0013)
# ===========================================================================
# Pure string / filesystem logic — no backend, no network. Covers remote-URL
# parsing, pre-filled PAT URL construction, workspace repo detection, and the
# advisory gate (fires iff repos present AND no sandbox-scoped github secret,
# regardless of a global one).

gwt=$(mktemp -d "${TMPDIR:-/tmp}/acq-gh.XXXXXX")
(
  mkdir -p "$gwt/repoGH" "$gwt/wsMulti/a" "$gwt/wsMulti/b" "$gwt/wsGL" "$gwt/empty"
  ( cd "$gwt/repoGH" && git init -q && git remote add origin https://github.com/GSA-TTS/quickstart.git )
  ( cd "$gwt/wsMulti/a" && git init -q && git remote add origin git@github.com:orgOne/repo1.git )
  ( cd "$gwt/wsMulti/b" && git init -q && git remote add origin https://github.com/orgTwo/repo2 )
  ( cd "$gwt/wsGL" && git init -q && git remote add origin https://gitlab.com/x/y.git )
)

# _acq_parse_github_nwo
_pnwo() { ( export ACQ_SCRIPT_DIR="$REPO_ROOT"; . "${REPO_ROOT}/acq.backends/common.sh"; _acq_parse_github_nwo "$1" ); }
assert_eq   "gh-parse: https + .git"      "GSA-TTS/quickstart" "$(_pnwo 'https://github.com/GSA-TTS/quickstart.git')"
assert_eq   "gh-parse: scp-style ssh"     "owner/repo"         "$(_pnwo 'git@github.com:owner/repo.git')"
assert_eq   "gh-parse: ssh:// url"        "o/r"                "$(_pnwo 'ssh://git@github.com/o/r')"
assert_eq   "gh-parse: deep path trimmed" "o/r"                "$(_pnwo 'https://github.com/o/r/tree/main')"
assert_eq   "gh-parse: non-github empty"  ""                   "$(_pnwo 'https://gitlab.com/x/y.git')"

# _acq_github_pat_url
_purl() { ( export ACQ_SCRIPT_DIR="$REPO_ROOT"; . "${REPO_ROOT}/acq.backends/common.sh"; _acq_github_pat_url "$1" "$2" ); }
assert_contains "gh-url: targets the owner"       "$(_purl 'GSA-TTS' 'opencode-proj')" "target_name=GSA-TTS"
assert_contains "gh-url: names token after sandbox" "$(_purl 'GSA-TTS' 'opencode-proj')" "name=acq-opencode-proj"
assert_contains "gh-url: default contents=write"  "$(_purl 'o' 's')" "contents=write"
assert_contains "gh-url: default pull_requests=write" "$(_purl 'o' 's')" "pull_requests=write"
assert_contains "gh-url: default issues=write"     "$(_purl 'o' 's')" "issues=write"
assert_contains "gh-url: default actions=read"     "$(_purl 'o' 's')" "actions=read"
# Least-privilege guards (ADR-0013): never default to admin, never grant
# actions=write (cancel/delete-logs) or any workflows scope (edit CI files).
assert_not_contains "gh-url: never defaults to admin"      "$(_purl 'o' 's')" "admin"
assert_not_contains "gh-url: no actions=write by default"  "$(_purl 'o' 's')" "actions=write"
assert_not_contains "gh-url: no workflows scope by default" "$(_purl 'o' 's')" "workflows="

# detect_workspace_repos
_dwr() { ( export ACQ_SCRIPT_DIR="$REPO_ROOT"; . "${REPO_ROOT}/acq.backends/common.sh"; detect_workspace_repos "$1" ); }
assert_eq       "gh-detect: single repo"          "GSA-TTS/quickstart" "$(_dwr "$gwt/repoGH" | tr -d '\n')"
assert_contains "gh-detect: multi finds orgOne"   "$(_dwr "$gwt/wsMulti")" "orgOne/repo1"
assert_contains "gh-detect: multi finds orgTwo"   "$(_dwr "$gwt/wsMulti")" "orgTwo/repo2"
assert_eq       "gh-detect: non-github repo empty" ""  "$(_dwr "$gwt/wsGL" | tr -d '\n')"
assert_eq       "gh-detect: empty dir empty"      ""  "$(_dwr "$gwt/empty" | tr -d '\n')"

# advise_github_scope gate — force file secret store into a temp dir so we can
# plant/remove sandbox-scoped and global github secrets deterministically. Each
# call is given an EXPLICIT unique store dir by the caller (a shared counter
# wouldn't survive the command-substitution subshell the asserts run in, and
# $RANDOM can repeat across sequential subshells and leak a planted secret).
_advise() {
  # $1 = workspace, $2 = unique tag, $3 = "global"?, $4 = "scoped"?
  # Redirect stdin from /dev/null so advise_github_scope takes its
  # non-interactive branch (it gates on `[ ! -t 0 ]`). Without this, running the
  # suite from an interactive terminal leaves stdin as the TTY inside this
  # command substitution, so the advisory would block on its [y/N] read.
  ( export ACQ_SCRIPT_DIR="$REPO_ROOT"
    unset ACQ_SECRET_STORE_DIR
    export ACQ_SECRET_FORCE_FILE=1
    export ACQ_SECRET_FILE_DIR="$gwt/secrets.$2"
    . "${REPO_ROOT}/acq.backends/common.sh"
    [ "${3:-}" = "global" ] && printf 'gho_x\n' | acq_secret_store "$(_acq_secret_key github)" >/dev/null 2>&1
    [ "${4:-}" = "scoped" ] && printf 'ghp_x\n' | acq_secret_store "$(_acq_secret_key github sb1)" >/dev/null 2>&1
    advise_github_scope sb1 "$1" 2>&1 </dev/null )
}
assert_contains "gh-advise: fires when repos + no scoped (no global)" "$(_advise "$gwt/repoGH" t1)" "no repo-scoped GitHub token"
assert_contains "gh-advise: warns broad when global present"          "$(_advise "$gwt/repoGH" t2 global)" "grants this sandbox access to ALL"
assert_contains "gh-advise: no-global path says none set"             "$(_advise "$gwt/repoGH" t3)" "No GitHub token is set for this sandbox"
assert_eq       "gh-advise: silent when already scoped"               ""  "$(_advise "$gwt/repoGH" t4 global scoped)"
assert_eq       "gh-advise: silent when no github repos"              ""  "$(_advise "$gwt/wsGL" t5)"

rm -rf "$gwt"
unset -f _pnwo _purl _dwr _advise
