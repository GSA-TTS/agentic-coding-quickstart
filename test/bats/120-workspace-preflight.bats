#!/usr/bin/env bats
#
# 120-workspace-preflight.bats — bats port of
# scripts/test-acq.d/120-workspace-preflight.sh (ADR-0025)
#
# Pure filesystem/string logic for the workspace path pre-flight, the
# git-identity classifier, and the published-ports health note. No backend, no
# network. Each helper sources common.sh in a subshell (via `run bash -c`), so
# there are no cross-file globals.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  WT="$STUBDIR/ws"
  mkdir -p "$WT/fakehome" "$WT/repoA" "$WT/wsB/sub1" "$WT/wsB/sub2" \
           "$WT/wsC" "$WT/okdir" "$WT/realrepo"
  ( cd "$WT/repoA" && git init -q )
  ( cd "$WT/wsB/sub1" && git init -q ); ( cd "$WT/wsB/sub2" && git init -q )
  ( cd "$WT/realrepo" && git init -q )
  ( cd "$WT/wsB" && ln -s "$WT/realrepo" symlinked )
  touch "$WT/afile"
}
teardown() { acq_teardown_stubs; }

load 'helper'

# warn_if_no_git_identity in an isolated HOME so case (a) sees an empty identity.
_id() { # PATH
  run bash -c '
    export HOME="'"$WT"'/fakehome" GIT_CONFIG_NOSYSTEM=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    warn_if_no_git_identity "'"$1"'" 2>&1
  '
}
# preflight_workspace_path: rc only.
_pf_rc() { # PATH
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    preflight_workspace_path "'"$1"'" >/dev/null 2>&1
  '
}
# preflight_workspace_path: output.
_pf_out() { # PATH
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    preflight_workspace_path "'"$1"'" 2>&1
  '
}

@test "preflight: missing path fails and gives name + mkdir hint" {
  _pf_rc "$WT/nope";  assert_failure
  _pf_out "$WT/nope"
  assert_output --partial 'does not exist'
  assert_output --partial 'mkdir -p'
}

@test "preflight: a file path fails with 'must be a directory'" {
  _pf_rc "$WT/afile"; assert_failure
  _pf_out "$WT/afile"; assert_output --partial 'must be a directory'
}

@test "preflight: existing dir and empty arg (cwd default) pass" {
  _pf_rc "$WT/okdir"; assert_success
  _pf_rc "";          assert_success
}

@test "identity (a): repo without effective email warns; with email is silent" {
  _id "$WT/repoA"
  assert_output --partial 'this repo has no git user.email'
  ( cd "$WT/repoA" && git config user.email dev@example.gov )
  _id "$WT/repoA"
  assert_output ''
}

@test "identity: complete host env or global email suppresses repo-local warning" {
  run bash -c '
    export HOME="'"$WT"'/fakehome" GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_EMAIL=dev@example.gov GIT_COMMITTER_EMAIL=dev@example.gov
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    warn_if_no_git_identity "'"$WT"'/repoA" 2>&1
  '
  assert_output ''

  mkdir -p "$WT/globalhome"
  run bash -c '
    export HOME="'"$WT"'/globalhome" GIT_CONFIG_NOSYSTEM=1
    git config --global user.email global@example.gov
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    warn_if_no_git_identity "'"$WT"'/repoA" 2>&1
  '
  assert_output ''
}

@test "identity: incomplete explicit host env still warns" {
  run bash -c '
    export HOME="'"$WT"'/fakehome" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_EMAIL=dev@example.gov
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    warn_if_no_git_identity "'"$WT"'/repoA" 2>&1
  '
  assert_output --partial 'this repo has no git user.email'
}

@test "identity env: host git config yields author and committer env" {
  mkdir -p "$WT/idenvhome"
  run bash -c '
    export HOME="'"$WT"'/idenvhome" GIT_CONFIG_NOSYSTEM=1
    git config --global user.name "Global User"
    git config --global user.email global@example.gov
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    acq_host_git_identity_env
  '
  assert_output --partial 'EMAIL=global@example.gov'
}

@test "identity env: partial host git config forwards configured fields" {
  mkdir -p "$WT/partialhome"
  run bash -c '
    export HOME="'"$WT"'/partialhome" GIT_CONFIG_NOSYSTEM=1
    git config --global user.email global@example.gov
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    acq_host_git_identity_env
  '
  assert_output --partial 'EMAIL=global@example.gov'
  refute_output --partial 'GIT_AUTHOR_NAME='
  refute_output --partial 'GIT_COMMITTER_NAME='
}

@test "identity env: explicit host GIT_* values override global git config" {
  mkdir -p "$WT/overridehome"
  run bash -c '
    export HOME="'"$WT"'/overridehome" GIT_CONFIG_NOSYSTEM=1
    git config --global user.name "Global User"
    git config --global user.email global@example.gov
    export GIT_AUTHOR_NAME="Env User" GIT_AUTHOR_EMAIL=env@example.gov
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    acq_host_git_identity_env
  '
  assert_output --partial 'GIT_AUTHOR_NAME=Env User'
  assert_output --partial 'GIT_AUTHOR_EMAIL=env@example.gov'
  assert_output --partial 'EMAIL=global@example.gov'
  refute_output --partial 'GIT_COMMITTER_NAME='
  refute_output --partial 'GIT_COMMITTER_EMAIL='
}

@test "identity (b): non-repo root with sub-repos, symlinked child not followed" {
  _id "$WT/wsB"
  assert_output --partial 'workspace root is not a git repo'
  assert_output --partial 'wsB/sub1'
  refute_output --partial 'symlinked'
}

@test "identity (c): empty dir gets the new-workspace onboarding note" {
  _id "$WT/wsC"
  assert_output --partial 'no git repos yet'
}

@test "identity (d): a non-directory path is silent" {
  _id "$WT/does-not-exist"
  assert_output ''
}

# warn_if_published_ports_dead: depends only on acq_backend_ports (published
# guest ports) and acq_backend_run (in-guest probe), both stubbed as shell
# functions. No backend, no network.
_wppd() { # PORTS_OUT VERDICT
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    _PORTS_OUT="$1"; _VERDICT="$2"
    acq_backend_ports() { printf "%s\n" "$_PORTS_OUT"; }
    acq_backend_run() { printf "%s\n" "$_VERDICT"; }
    warn_if_published_ports_dead somebox 2>&1
  ' _ "$1" "$2"
}

@test "ports-dead: warns, names the dead port, and cites the failure-mode doc" {
  local fixture='sandbox 3000 -> host 127.0.0.1:3000 (create-time -p)
sandbox 4096 -> host 127.0.0.1:4096 (create-time -p)'
  _wppd "$fixture" closed
  assert_output --partial "nothing listening inside 'somebox'"
  assert_output --partial '4096'
  assert_output --partial 'KNOWN_FAILURE_MODES.md #33'
}

@test "ports-dead: silent when listening, indeterminate, or no published ports" {
  local fixture='sandbox 3000 -> host 127.0.0.1:3000 (create-time -p)'
  _wppd "$fixture" listening; assert_output ''
  _wppd "$fixture" unknown;   assert_output ''
  _wppd "" closed;            assert_output ''
}

# The identity tests above fake HOME and run real `git config --global`; git
# routes that to $XDG_CONFIG_HOME/git/config when it exists and ~/.gitconfig
# does not, so the harness must isolate XDG_CONFIG_HOME or a developer shell
# exporting it gets fixture identities written into its real config. CI cannot
# see that regression (no XDG export there), hence this guard.
@test "harness: XDG_CONFIG_HOME is isolated so a faked HOME never reaches the developer's git config" {
  [[ "${XDG_CONFIG_HOME:-}" == "$STUBDIR"/* ]]
}
