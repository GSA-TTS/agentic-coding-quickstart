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
  export GIT_CEILING_DIRECTORIES="$STUBDIR"
  _id "$WT/wsB"
  assert_output --partial 'workspace root is not a git repo'
  assert_output --partial 'wsB/sub1'
  refute_output --partial 'symlinked'
}

@test "identity (c): empty dir gets the new-workspace onboarding note" {
  export GIT_CEILING_DIRECTORIES="$STUBDIR"
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

# Workspace positionals are PATH[:ro]. A ':' anywhere but the ':ro' suffix is
# read as a separator (by workspace_path and by msb's SOURCE:DEST[:OPTIONS]
# volume spec), and a control character splits the line-oriented workspace list
# and reaches the terminal when the path is echoed. Both are refused up front.
_ws_safe() { # ARGS...
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    acq_workspace_specs_safe "$@" 2>&1
  ' _ "$@"
}

@test "workspace specs: a ':' in a workspace path is refused with a clear message" {
  mkdir -p "$WT/a:b"
  _ws_safe opencode "$WT/a:b"
  assert_failure
  assert_output --partial "contains ':'"
  _ws_safe opencode "$WT/okdir" "$WT/a:b:ro"
  assert_failure
  assert_output --partial "contains ':'"
  _ws_safe opencode 'C:/Users/me/proj'
  assert_failure
  assert_output --partial '/c/... form'
}

@test "workspace specs: plain paths, ':ro' suffixes and flags are accepted" {
  _ws_safe opencode "$WT/okdir" "$WT/wsC:ro"
  assert_success
  assert_output ''
  _ws_safe --name x opencode --kit k "$WT/okdir"
  assert_success
  _ws_safe opencode
  assert_success
}

@test "workspace specs: newline and escape characters in a path are refused, never echoed raw" {
  local nl="$WT/"$'new\nline' esc="$WT/"$'esc\033]0;pwn\007dir'
  mkdir -p "$nl" "$esc"
  _ws_safe opencode "$nl"
  assert_failure
  assert_output --partial 'control character'
  _ws_safe opencode "$esc"
  assert_failure
  assert_output --partial 'control character'
  refute_output --partial $'\033'
  refute_output --partial $'\007'
}

@test "workspace specs: a symlink whose target contains ':' is refused, naming the target" {
  mkdir -p "$WT/real:dir"
  ln -s "$WT/real:dir" "$WT/plainlink"
  _ws_safe opencode "$WT/plainlink"
  assert_failure
  assert_output --partial "contains ':'"
  assert_output --partial "resolves to"
  assert_output --partial "real:dir"
}

@test "workspace specs: with no path argument the current directory is checked" {
  mkdir -p "$WT/cwd:colon" "$WT/"$'cwd\nnl'
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    cd "$1" && acq_workspace_specs_safe opencode 2>&1
  ' _ "$WT/cwd:colon"
  assert_failure
  assert_output --partial "contains ':'"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    cd "$1" && acq_workspace_specs_safe --name x opencode 2>&1
  ' _ "$WT/"$'cwd\nnl'
  assert_failure
  assert_output --partial 'control character'
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    cd "$1" && acq_workspace_specs_safe opencode 2>&1
  ' _ "$WT/okdir"
  assert_success
}

@test "workspace specs: '.' is checked as the logical cwd, so a ':' symlink on the way is refused" {
  mkdir -p "$WT/real/proj"
  ln -s "$WT/real" "$WT/c:link"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    cd -L "$1" || exit 9
    for p in . ./ sub/..; do acq_workspace_specs_safe opencode "$p" 2>&1 && echo "accepted $p"; done
    acq_workspace_specs_safe opencode "$2" 2>&1 && echo "accepted physical"
  ' _ "$WT/c:link/proj" "$WT/real/proj"
  assert_output --partial "contains ':'"
  refute_output --partial 'accepted .'
  refute_output --partial 'accepted ./'
  refute_output --partial 'accepted sub/..'
  assert_output --partial 'accepted physical'
}

@test "create(msb): no path argument from a ':' cwd fails before any backend create" {
  mkdir -p "$WT/cwdproj:z"
  cd "$WT/cwdproj:z"
  run env ACQ_BACKEND=msb ACQ_NO_PROMPT=1 "$ACQ" create opencode --no-provider-kits
  assert_failure
  assert_output --partial "contains ':'"
  refute_regex "$(cat "$CALLS")" '^msb create'
}

@test "preflight: a missing path with escape characters is reported without raw control bytes" {
  _pf_out "$WT/"$'gone\033]0;pwn\007'
  assert_output --partial 'does not exist'
  refute_output --partial $'\033'
  refute_output --partial $'\007'
}

@test "create(msb): a workspace path with ':' fails before any backend create" {
  mkdir -p "$WT/proj:x"
  run env ACQ_BACKEND=msb ACQ_NO_PROMPT=1 "$ACQ" create opencode --no-provider-kits "$WT/proj:x"
  assert_failure
  assert_output --partial "contains ':'"
  refute_regex "$(cat "$CALLS")" '^msb create'
}

@test "run(msb): a fresh create with a ':' workspace path fails before any backend create" {
  mkdir -p "$WT/proj:y"
  run env ACQ_BACKEND=msb ACQ_NO_PROMPT=1 "$ACQ" run opencode --no-provider-kits "$WT/proj:y"
  assert_failure
  assert_output --partial "contains ':'"
  refute_regex "$(cat "$CALLS")" '^msb create'
}

@test "create(msb): an explicit --name with a newline fails before any backend call" {
  mkdir -p "$WT/proj"
  run env ACQ_BACKEND=msb ACQ_NO_PROMPT=1 "$ACQ" create opencode --no-provider-kits --name $'x\nbox' "$WT/proj"
  assert_failure
  assert_output --partial 'invalid sandbox name'
  refute_regex "$(cat "$CALLS")" '^msb create'
}

@test "advisory: the project-env notice never echoes raw control bytes from the path" {
  local d="$WT/"$'env\033]0;pwn\007proj'
  mkdir -p "$d"; : >"$d/.envrc"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    advise_project_env_activation "$1" 2>&1
  ' _ "$d"
  assert_output --partial 'project environment detected (direnv)'
  refute_output --partial $'\033'
}
