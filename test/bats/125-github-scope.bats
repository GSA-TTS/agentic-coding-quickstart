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
  mkdir -p "$GWT/wsOneOwner/a" "$GWT/wsOneOwner/b" "$GWT/wsCaseOwner/a" "$GWT/wsCaseOwner/b"
  ( cd "$GWT/repoGH" && git init -q && git remote add origin https://github.com/GSA-TTS/quickstart.git )
  ( cd "$GWT/wsMulti/a" && git init -q && git remote add origin git@github.com:orgOne/repo1.git )
  ( cd "$GWT/wsMulti/b" && git init -q && git remote add origin https://github.com/orgTwo/repo2 )
  ( cd "$GWT/wsOneOwner/a" && git init -q && git remote add origin git@github.com:orgOne/repo1.git )
  ( cd "$GWT/wsOneOwner/b" && git init -q && git remote add origin https://github.com/orgOne/repo2 )
  ( cd "$GWT/wsCaseOwner/a" && git init -q && git remote add origin git@github.com:OrgOne/repo1.git )
  ( cd "$GWT/wsCaseOwner/b" && git init -q && git remote add origin https://github.com/orgone/repo2 )
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

@test "gh-scope: refuses workspaces spanning multiple GitHub owners" {
  run env ACQ_SECRET_TEST_VALUE=ghp_fake bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    github_scope_sandbox sb1 "'"$GWT"'/wsMulti" 2>&1
  '
  assert_failure
  assert_output --partial 'multiple accounts'
  assert_output --partial 'orgOne/repo1'
  assert_output --partial 'orgTwo/repo2'
  refute_output --partial 'Enter GitHub token'
}

@test "gh-scope: accepts multiple repos from one GitHub owner" {
  run env ACQ_SECRET_FORCE_FILE=1 ACQ_SECRET_FILE_DIR="$STUBDIR/secrets" \
    ACQ_SECRET_TEST_VALUE=ghp_fake bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    github_scope_sandbox sb1 "'"$GWT"'/wsOneOwner" 2>&1
  '
  assert_success
  assert_output --partial "Owner 'orgOne'"
  assert_output --partial 'orgOne/repo1'
  assert_output --partial 'orgOne/repo2'
  refute_output --partial 'For EACH owner'
}

@test "gh-scope: treats owner case variants as the same GitHub owner" {
  run env ACQ_SECRET_FORCE_FILE=1 ACQ_SECRET_FILE_DIR="$STUBDIR/secrets" \
    ACQ_SECRET_TEST_VALUE=ghp_fake bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    github_scope_sandbox sb1 "'"$GWT"'/wsCaseOwner" 2>&1
  '
  assert_success
  assert_output --partial "Owner '"
  assert_output --partial 'OrgOne/repo1'
  assert_output --partial 'orgone/repo2'
  refute_output --partial 'multiple accounts'
}

@test "gh-record: workspace records reject newline values and keep metadata" {
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_PROVENANCE_DIR="'"$STUBDIR"'/provenance"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    acq_workspace_record_write sbx sb1 "'"$GWT"'/repoGH"
    acq_workspace_record_write sbx sb1 "'"$GWT"'/repoGH
owner=evil" || true
    acq_provenance_field sbx sb1 schema
    acq_provenance_field sbx sb1 backend
    acq_provenance_field sbx sb1 workspace_source
    acq_workspace_record_read sbx sb1
    acq_provenance_field sbx sb1 owner
  '
  assert_success
  assert_line --index 0 '1'
  assert_line --index 1 'sbx'
  assert_line --index 2 'host'
  assert_line --index 3 "$GWT/repoGH"
  refute_output --partial 'evil'
}

@test "gh-record: unmarked legacy workspace records are ignored" {
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_PROVENANCE_DIR="'"$STUBDIR"'/provenance"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    file=$(_acq_provenance_file sbx oldbox)
    mkdir -p "$(dirname "$file")"
    printf "schema=1\nbackend=sbx\nworkspace='"$GWT"'/repoGH\n" > "$file"
    acq_workspace_record_read sbx oldbox
  '
  assert_success
  assert_output ''
}

@test "gh-record: provenance refresh preserves only host-marked workspace" {
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    export ACQ_PROVENANCE_DIR="'"$STUBDIR"'/provenance"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    acq_workspace_record_write sbx goodbox "'"$GWT"'/repoGH"
    acq_provenance_write sbx goodbox
    printf "good=%s\n" "$(acq_workspace_record_read sbx goodbox)"
    file=$(_acq_provenance_file sbx oldbox)
    mkdir -p "$(dirname "$file")"
    printf "schema=1\nbackend=sbx\nworkspace='"$GWT"'/repoGH\n" > "$file"
    acq_provenance_write sbx oldbox
    printf "legacy=%s\n" "$(acq_workspace_record_read sbx oldbox)"
  '
  assert_success
  assert_line --index 0 "good=$GWT/repoGH"
  assert_line --index 1 'legacy='
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
