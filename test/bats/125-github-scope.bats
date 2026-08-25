#!/usr/bin/env bats
#
# 125-github-scope.bats — bats port of scripts/test-acq.d/125-github-scope.sh
# (ADR-0013 / ADR-0025)
#
# Pure string / filesystem logic for GitHub token down-scoping — no backend, no
# network. Covers remote-URL parsing, pre-filled PAT URL construction, workspace
# repo detection, and the advisory gate. Each helper sources common.sh in a
# subshell (via `run bash -c`), so there are no cross-file globals (no SC2034).
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  # A throwaway workspace tree with assorted git remotes.
  GWT="$STUBDIR/gh"
  mkdir -p "$GWT/repoGH" "$GWT/wsMulti/a" "$GWT/wsMulti/b" "$GWT/wsGL" "$GWT/empty"
  ( cd "$GWT/repoGH" && git init -q && git remote add origin https://github.com/GSA-TTS/quickstart.git )
  ( cd "$GWT/wsMulti/a" && git init -q && git remote add origin git@github.com:orgOne/repo1.git )
  ( cd "$GWT/wsMulti/b" && git init -q && git remote add origin https://github.com/orgTwo/repo2 )
  ( cd "$GWT/wsGL" && git init -q && git remote add origin https://gitlab.com/x/y.git )
}
teardown() { acq_teardown_stubs; }

load 'helper'

# Run a common.sh function in a clean subshell and echo its output.
_common() { # FUNC ARGS...
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    "$@"
  ' _ "$@"
}

@test "gh-parse: _acq_parse_github_nwo handles url forms and rejects non-github" {
  _common _acq_parse_github_nwo 'https://github.com/GSA-TTS/quickstart.git'; assert_output 'GSA-TTS/quickstart'
  _common _acq_parse_github_nwo 'git@github.com:owner/repo.git';             assert_output 'owner/repo'
  _common _acq_parse_github_nwo 'ssh://git@github.com/o/r';                  assert_output 'o/r'
  _common _acq_parse_github_nwo 'https://github.com/o/r/tree/main';          assert_output 'o/r'
  _common _acq_parse_github_nwo 'https://gitlab.com/x/y.git';                assert_output ''
}

@test "gh-url: _acq_github_pat_url targets owner, names token, least-privilege defaults" {
  _common _acq_github_pat_url 'GSA-TTS' 'opencode-proj'
  assert_output --partial 'target_name=GSA-TTS'
  assert_output --partial 'name=acq-opencode-proj'

  _common _acq_github_pat_url 'o' 's'
  assert_output --partial 'contents=write'
  assert_output --partial 'pull_requests=write'
  assert_output --partial 'issues=write'
  assert_output --partial 'actions=read'
  # Least-privilege guards (ADR-0013).
  refute_output --partial 'admin'
  refute_output --partial 'actions=write'
  refute_output --partial 'workflows='
}

@test "gh-detect: detect_workspace_repos finds github repos, ignores others" {
  _common detect_workspace_repos "$GWT/repoGH"; assert_output 'GSA-TTS/quickstart'
  _common detect_workspace_repos "$GWT/wsMulti"
  assert_output --partial 'orgOne/repo1'
  assert_output --partial 'orgTwo/repo2'
  _common detect_workspace_repos "$GWT/wsGL";  assert_output ''
  _common detect_workspace_repos "$GWT/empty"; assert_output ''
}

# advise_github_scope gate: fires iff repos present AND no sandbox-scoped github
# secret (regardless of a global one). Force the file secret store into a unique
# temp dir per invocation so planted secrets don't leak between cases.
_advise() { # WORKSPACE TAG [global] [scoped]
  local ws="$1" tag="$2" global="${3:-}" scoped="${4:-}"
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    unset ACQ_SECRET_STORE_DIR
    export ACQ_SECRET_FORCE_FILE=1
    export ACQ_SECRET_FILE_DIR="'"$GWT"'/secrets.'"$tag"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    [ "'"$global"'" = "global" ] && printf "gho_x\n" | acq_secret_store "$(_acq_secret_key github)" >/dev/null 2>&1
    [ "'"$scoped"'" = "scoped" ] && printf "ghp_x\n" | acq_secret_store "$(_acq_secret_key github sb1)" >/dev/null 2>&1
    advise_github_scope sb1 "'"$ws"'" 2>&1 </dev/null
  '
}

@test "gh-advise: fires when repos present and no sandbox-scoped token" {
  _advise "$GWT/repoGH" t1
  assert_output --partial 'no repo-scoped GitHub token'
}

@test "gh-advise: warns of broad access when only a global token is present" {
  _advise "$GWT/repoGH" t2 global
  assert_output --partial 'grants this sandbox access to ALL'
}

@test "gh-advise: no-global path reports none set" {
  _advise "$GWT/repoGH" t3
  assert_output --partial 'No GitHub token is set for this sandbox'
}

@test "gh-advise: silent when already sandbox-scoped" {
  _advise "$GWT/repoGH" t4 global scoped
  assert_output ''
}

@test "gh-advise: silent when workspace has no github repos" {
  _advise "$GWT/wsGL" t5
  assert_output ''
}
