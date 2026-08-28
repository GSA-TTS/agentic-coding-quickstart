#!/usr/bin/env bats
#
# 116-clone-option.bats — neutral --clone option (GSA-TTS/agentic-coding-quickstart#403)
#
# --clone is acq-owned neutral vocabulary: on sbx it forwards to the native
# `sbx create --clone`; on msb the adapter emulates disposable-primary semantics
# with a managed host-side scratch clone (git clone --no-hardlinks under
# ACQ_STATE_DIR/clones/<sandbox>/), mounted rw at the ORIGINAL workspace path in
# the guest, wired back via a `sandbox-<name>` remote in the host checkout.
# `acq rm` deletes the scratch and the remote, warning about unfetched commits.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  CLONEPROJ="$STUBDIR/cloneproj"
  _mk_repo "$CLONEPROJ"
}
teardown() { acq_teardown_stubs; }

load 'helper'

# Minimal real git repo with one committed file (real git; loose objects are
# what the --no-hardlinks assertion inspects).
_mk_repo() { # PATH
  mkdir -p "$1"
  git -C "$1" init -q
  echo one > "$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m init
}

# Provision on msb with a stored USAi key, in an isolated subshell, with the
# acq state root pinned inside the stub dir so the scratch clone lands there.
# Extra env assignments (KEY=VAL) precede the create argv after a literal `--`.
_msb_clone() { # [ENV KEY=VAL...] -- ARGS...
  local env_kv=(); while [ "$1" != "--" ]; do env_kv+=("$1"); shift; done; shift
  run bash -c '
    tag="$1"; shift
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-$tag"
    export ACQ_MSB_KIT_PASSTHROUGH=1 ACQ_UPDATE_CHECK=0
    export ACQ_STATE_DIR="'"$STUBDIR"'/state"
    while [ "$1" != "--" ]; do export "$1"; shift; done; shift
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL\n" | acq_secret_store "$(_acq_secret_key usai)"
    ACQ_BACKEND=msb "'"$ACQ"'" "$@" 2>&1 >/dev/null
  ' _ "$BATS_TEST_NUMBER" ${env_kv[@]+"${env_kv[@]}"} -- "$@"
}
_create_line() { printf '%s\n' "$(cat "$CALLS")" | grep "^$1 create"; }

@test "clone(msb): --clone mounts a scratch clone at the original path and registers the sandbox remote" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  load_acq
  local repo scratch line
  repo=$(canonicalize_path "$CLONEPROJ")
  scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  line=$(_create_line msb)

  # The primary mount is scratch -> original path, rw; the raw path never
  # mounts, and the acq-owned flag never reaches the backend argv.
  assert_regex "$line" "--volume $(canonicalize_path "$scratch"):${repo}( |\$)"
  refute_regex "$line" "--volume ${repo}:${repo}"
  refute_regex "$line" '--clone'

  # The scratch is a real, physical git clone: no object file shares an inode
  # with the host repo's object store (git clone --no-hardlinks).
  [ -d "$scratch/.git" ]
  [ -z "$(find "$scratch/.git/objects" -type f -links +1)" ]

  # Fetch-back wiring: the host checkout gained the sandbox-<name> remote
  # pointing at the scratch, and the user is told how to use it.
  local url; url=$(git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj)
  [ "$(canonicalize_path "$url")" = "$(canonicalize_path "$scratch")" ]
  assert_output --partial 'git fetch sandbox-shell-cloneproj'
}

@test "clone(msb): ACQ_CLONE=1 env is equivalent to the flag" {
  _msb_clone ACQ_CLONE=1 -- create shell "$CLONEPROJ"
  local repo; load_acq; repo=$(canonicalize_path "$CLONEPROJ")
  assert_regex "$(_create_line msb)" "--volume [^ ]*/clones/shell-cloneproj/cloneproj:${repo}( |\$)"
}

@test "clone(msb): a non-git workspace fails the create before the backend runs" {
  local plain="$STUBDIR/plainproj"; mkdir -p "$plain"
  _msb_clone -- create shell --clone "$plain"
  assert_failure
  assert_output --partial 'not a git repository'
  refute_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(msb): a subdirectory of a repo is rejected, naming the toplevel" {
  mkdir -p "$CLONEPROJ/sub"
  _msb_clone -- create shell --clone "$CLONEPROJ/sub"
  assert_failure
  assert_output --partial 'repository root'
  assert_output --partial 'cloneproj'
  refute_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(msb): --clone with no workspace positional fails with guidance" {
  _msb_clone -- create shell --clone
  assert_failure
  assert_output --partial '--clone requires a workspace path'
  refute_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(msb): a dirty working tree gets a notice but the create proceeds" {
  echo two >> "$CLONEPROJ/file.txt"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_output --partial 'uncommitted changes'
  assert_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(msb): secondary workspaces keep their direct mounts" {
  local second="$STUBDIR/secondlib"; mkdir -p "$second"
  _msb_clone -- create shell --clone "$CLONEPROJ" "$second:ro"
  load_acq
  local line sec repo
  line=$(_create_line msb); sec=$(canonicalize_path "$second"); repo=$(canonicalize_path "$CLONEPROJ")
  assert_regex "$line" "--volume ${sec}:${sec}:ro"
  refute_regex "$line" "--volume ${sec}:${sec}( |\$)"
  refute_regex "$line" "--volume ${repo}:${repo}"
}

@test "clone(msb): acq rm removes the scratch clone and the host remote" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj"
  [ -d "$scratch" ]
  _msb_clone -- rm shell-cloneproj
  assert_success
  [ ! -d "$scratch" ]
  run git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj
  assert_failure
  refute_output --partial 'unfetched'
}

@test "clone(msb): rm warns about unfetched commits before deleting the scratch" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  # Agent work the host never fetched: a commit that exists only in the scratch.
  echo agent-work > "$scratch/agent.txt"
  git -C "$scratch" add agent.txt
  git -C "$scratch" -c user.email=a@example.com -c user.name=a -c commit.gpgsign=false commit -q -m agent-work
  _msb_clone -- rm shell-cloneproj
  assert_success
  assert_output --partial 'unfetched commits'
  assert_output --partial 'git fetch sandbox-shell-cloneproj'
  [ ! -d "$STUBDIR/state/clones/shell-cloneproj" ]
}

@test "clone(reattach): --clone on an existing sandbox notes it applies only at create" {
  printf 'clnreattach\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'clnreattach\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  _msb_clone -- run shell --clone --name clnreattach "$CLONEPROJ"
  assert_output --partial 'applies only at create'
  refute_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(sbx): --clone forwards to the native sbx create --clone" {
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
  env ACQ_BACKEND=sbx "$ACQ" create opencode --clone "$CLONEPROJ" >/dev/null 2>&1
  assert_regex "$(_create_line sbx)" '--clone'
}
