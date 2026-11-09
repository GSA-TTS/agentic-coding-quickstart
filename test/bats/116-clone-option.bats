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
teardown() {
  # Undo any mode a test stripped from the repo's .git, so the stub dir can be
  # removed.
  chmod u+rwx "$CLONEPROJ/.git" "$CLONEPROJ/.git/hooks" 2>/dev/null || true
  acq_teardown_stubs
}

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
# A create that must abort before the backend runs. The preflight's
# `msb --version` proves the stub recorder wrote $CALLS at all (an empty file
# would make the refute pass vacuously), so the refute means what it says.
# Use --version, not `msb doctor`: the doctor probe is skipped whenever
# ACQ_SKIP_MSB_DOCTOR is set, which the harness inherits from the caller, so a
# developer who exports it would see every converted test fail spuriously.
_refute_backend_create() {
  assert_regex "$(cat "$CALLS")" 'msb --version'
  refute_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(msb): --clone mounts a scratch clone at the original path and registers the sandbox remote" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  load_acq
  local repo scratch line
  repo=$(canonicalize_path "$CLONEPROJ")
  scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  line=$(_create_line msb)

  # The primary mount is scratch -> original path, rw; the raw path never
  # mounts, and the acq-owned flag never reaches the backend argv. The mount
  # SOURCE is the host form and the TARGET the guest form (ADR-0029).
  assert_regex "$line" "--volume $(host_path "$scratch"):${repo}( |\$)"
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

@test "clone(msb): records original host checkout, not scratch, for github-scope" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  local repo; load_acq; repo=$(canonicalize_path "$CLONEPROJ")
  run acq_workspace_record_read msb shell-cloneproj
  assert_success
  assert_output "$repo"
  refute_output --partial '/clones/'
}

@test "clone(msb): a non-git workspace fails the create before the backend runs" {
  local plain="$STUBDIR/plainproj"; mkdir -p "$plain"
  GIT_CEILING_DIRECTORIES="$STUBDIR" _msb_clone -- create shell --clone "$plain"
  assert_failure
  assert_output --partial 'not a git repository'
  _refute_backend_create
}

@test "clone(msb): a subdirectory of a repo is rejected, naming the toplevel" {
  mkdir -p "$CLONEPROJ/sub"
  _msb_clone -- create shell --clone "$CLONEPROJ/sub"
  assert_failure
  assert_output --partial 'repository root'
  assert_output --partial 'cloneproj'
  _refute_backend_create
}

@test "clone(msb): --clone with no workspace positional fails with guidance" {
  _msb_clone -- create shell --clone
  assert_failure
  assert_output --partial '--clone requires a workspace path'
  _refute_backend_create
}

@test "clone(msb): a dirty working tree gets a notice but the create proceeds" {
  echo two >> "$CLONEPROJ/file.txt"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_output --partial 'uncommitted changes'
  assert_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(msb): the dirty-tree notice covers untracked-only changes ('git add' hint)" {
  # An untracked file also makes `git status --porcelain` non-empty, and it too
  # is invisible to the clone — but "commit first" alone is incomplete advice
  # there (the file must be added first).
  echo new > "$CLONEPROJ/untracked.txt"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_output --partial 'uncommitted changes'
  assert_output --partial 'git add'
  assert_regex "$(cat "$CALLS")" 'msb create'
}

@test "clone(msb): a path-unsafe explicit --name is rejected before any host path is built" {
  # An explicit --name bypasses slugify and lands verbatim in the scratch path
  # (mkdir/git clone/rm -rf under clones/<name>) and the sandbox-<name> remote,
  # all BEFORE msb's own name validation runs. A traversal-shaped name must
  # fail closed with nothing created.
  _msb_clone -- create shell --name '../evil' --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'invalid sandbox name'
  _refute_backend_create
  [ ! -e "$STUBDIR/state/evil" ]
  run git -C "$CLONEPROJ" remote
  assert_success
  assert_output ''

  _msb_clone -- create shell --name '..' --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'invalid sandbox name'
}

@test "clone(msb): secondary workspaces keep their direct mounts" {
  local second="$STUBDIR/secondlib"; mkdir -p "$second"
  _msb_clone -- create shell --clone "$CLONEPROJ" "$second:ro"
  load_acq
  local line sec sechost repo
  line=$(_create_line msb); sec=$(canonicalize_path "$second"); sechost=$(host_path "$second"); repo=$(canonicalize_path "$CLONEPROJ")
  assert_regex "$line" "--volume ${sechost}:${sec}:ro"
  refute_regex "$line" "--volume ${sec}:${sec}( |\$)"
  refute_regex "$line" "--volume ${repo}:${repo}"
}

@test "clone(msb): acq rm removes the scratch clone and the host remote" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj"
  [ -d "$scratch" ]
  _msb_clone -- rm shell-cloneproj
  assert_success
  refute_output --partial 'unfetched'
  [ ! -d "$scratch" ]
  run git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj
  assert_failure
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

@test "clone(msb): rm never executes git inside the guest-writable scratch" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  # Agent work the host never fetched, with the refs packed so both loose and
  # packed lookups are exercised.
  echo agent-work > "$scratch/agent.txt"
  git -C "$scratch" add agent.txt
  git -C "$scratch" -c user.email=a@example.com -c user.name=a -c commit.gpgsign=false commit -q -m agent-work
  git -C "$scratch" pack-refs --all
  # A hostile guest controls scratch/.git — corrupt its config so ANY host git
  # invocation inside the scratch dies. The unfetched-commit warning must still
  # fire: the host reads ref files directly, never runs git in the scratch.
  printf '[broken\n' >> "$scratch/.git/config"
  _msb_clone -- rm shell-cloneproj
  assert_success
  assert_output --partial 'unfetched commits'
  [ ! -d "$STUBDIR/state/clones/shell-cloneproj" ]
}

# Point the workspace repo's own config at a recorder script (fsmonitor, a
# filter driver applied to every file, an index hook, and a ref hook that
# `remote remove` runs when it deletes remote-tracking refs), and leave a
# tracked file stat-dirty (an mtime that cannot match the index) so a status
# would have to hash it. Host-side git in clone mode must start none of these.
# FILTER names the driver (default `rec`).
_arm_repo_config() { # REPO RECORDER_OUT [FILTER]
  local repo="$1" out="$2" filter="${3:-rec}" rec="$STUBDIR/recorder.sh"
  printf '#!/bin/sh\necho "$0 $*" >> "%s"\ncat\n' "$out" > "$rec"
  chmod +x "$rec"
  mkdir -p "$repo/.git/hooks"
  cp "$rec" "$repo/.git/hooks/post-index-change"
  cp "$rec" "$repo/.git/hooks/reference-transaction"
  git -C "$repo" config core.fsmonitor "$rec"
  git -C "$repo" config "filter.${filter}.clean" "$rec"
  git -C "$repo" config "filter.${filter}.smudge" "$rec"
  git -C "$repo" config "filter.${filter}.process" "$rec"
  printf '* filter=%s\n' "$filter" > "$repo/.git/info/attributes"
  touch -t 200001010000 "$repo/file.txt"
}

# Commit a new file in the scratch clone, as the agent would.
_agent_commit() { # SCRATCH NAME
  echo "$2" > "$1/$2.txt"
  git -C "$1" add "$2.txt"
  git -C "$1" -c user.email=a@example.com -c user.name=a -c commit.gpgsign=false commit -q -m "$2"
}

@test "clone(msb): create starts no program named by the workspace repo's config" {
  _arm_repo_config "$CLONEPROJ" "$STUBDIR/ran"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  [ -d "$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git" ]
  [ ! -e "$STUBDIR/ran" ]
}

@test "clone(msb): rm starts no program named by the workspace repo's config" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  # A fetched commit gives the host remote-tracking refs, so the rm-time
  # `remote remove` deletes refs and would run the reference-transaction hook
  # if it were not wrapped. A second, unfetched commit keeps the rm-time
  # cat-file check exercised.
  _agent_commit "$scratch" agent-work
  git -C "$CLONEPROJ" fetch -q sandbox-shell-cloneproj
  [ -n "$(git -C "$CLONEPROJ" for-each-ref refs/remotes/sandbox-shell-cloneproj)" ]
  _agent_commit "$scratch" agent-work-2
  _arm_repo_config "$CLONEPROJ" "$STUBDIR/ran"
  _msb_clone -- rm shell-cloneproj
  assert_success
  assert_output --partial 'unfetched commits'
  [ ! -e "$STUBDIR/ran" ]
}

@test "clone(msb): a workspace that borrows objects via alternates is refused" {
  local other="$STUBDIR/otherrepo"
  _mk_repo "$other"
  printf '%s\n' "$other/.git/objects" > "$CLONEPROJ/.git/objects/info/alternates"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'borrows objects from other repositories'
  _refute_backend_create
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
}

@test "clone(msb): a read-only primary is rejected before any state is created" {
  _msb_clone -- create shell --clone "$CLONEPROJ:ro"
  assert_failure
  assert_output --partial 'read-only'
  _refute_backend_create
  [ ! -d "$STUBDIR/state/clones/shell-cloneproj" ]
  run git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj
  assert_failure
}

@test "clone(msb): a missing secondary fails the create without leaking the scratch" {
  _msb_clone -- create shell --clone "$CLONEPROJ" "$STUBDIR/missinglib"
  assert_failure
  assert_output --partial 'does not exist'
  _refute_backend_create
  # No abandoned state: a corrected re-run must not be refused over a stale
  # scratch clone or a dangling sandbox-<name> remote.
  [ ! -d "$STUBDIR/state/clones/shell-cloneproj" ]
  run git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj
  assert_failure
  mkdir -p "$STUBDIR/missinglib"
  _msb_clone -- create shell --clone "$CLONEPROJ" "$STUBDIR/missinglib"
  assert_success
}

@test "clone(msb): stale scratch advice matches sandbox liveness" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  # Sandbox still exists: the scratch is its live mount source, so the advice
  # must be 'acq rm' (warns + cleans up), never manual directory deletion.
  printf 'shell-cloneproj\n' > "$STUBDIR/.msb_sandbox_list"
  run bash -c '
    export ACQ_STATE_DIR="'"$STUBDIR"'/state" ACQ_MSB_CLONES_DIR="'"$STUBDIR"'/state/clones"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_clone_setup shell-cloneproj "$1"
  ' _ "$CLONEPROJ"
  assert_failure
  assert_output --partial "acq rm shell-cloneproj"
  refute_output --partial 'remove the directory'
  # Sandbox gone, scratch orphaned: manual recovery advice applies.
  rm -f "$STUBDIR/.msb_sandbox_list"
  run bash -c '
    export ACQ_STATE_DIR="'"$STUBDIR"'/state" ACQ_MSB_CLONES_DIR="'"$STUBDIR"'/state/clones"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_clone_setup shell-cloneproj "$1"
  ' _ "$CLONEPROJ"
  assert_failure
  assert_output --partial 'remove the directory'
}

@test "clone(reattach): --clone on an existing sandbox notes it applies only at create" {
  printf 'clnreattach\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'clnreattach\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  _msb_clone -- run shell --clone --name clnreattach "$CLONEPROJ"
  assert_output --partial 'applies only at create'
  # The suggested removal must be the acq-owned verb: 'acq msb rm' dispatches
  # through the passthrough as 'msb msb rm' (doubled verb) and a raw backend rm
  # would bypass the clone cleanup anyway.
  assert_output --partial "'acq rm clnreattach'"
  refute_output --partial 'acq msb rm'
  _refute_backend_create
}

@test "clone(sbx): --clone forwards to the native sbx create --clone" {
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
  env ACQ_BACKEND=sbx "$ACQ" create opencode --clone "$CLONEPROJ" >/dev/null 2>&1
  assert_regex "$(_create_line sbx)" '--clone'
}

# Neutralize the host git identity so only the source checkout's values (or
# their absence) can reach the scratch.
_msb_clone_isolated() { # ARGS...
  _msb_clone HOME="$STUBDIR/nohome" XDG_CONFIG_HOME="$STUBDIR/noconfig" GIT_CONFIG_NOSYSTEM=1 -- "$@"
}

# Put a `git` on PATH that fails every call whose argv matches the case PATTERN
# with exit code RC and passes everything else through to the real git.
_stub_git() { # PATTERN RC
  local real; real=$(command -v git)
  printf '#!/usr/bin/env bash\ncase " $* " in %s) echo "fatal: stubbed git failure" >&2; exit %s;; esac\nexec %s "$@"\n' \
    "$1" "$2" "$real" > "$STUBDIR/git"
  chmod +x "$STUBDIR/git"
}

@test "clone(msb #438): the scratch carries the source checkout's effective git identity, repo-locally" {
  git -C "$CLONEPROJ" config user.name "Repo User"
  git -C "$CLONEPROJ" config user.email "repo@example.gov"
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  [ "$(git config --file "$scratch/.git/config" user.name)" = "Repo User" ]
  [ "$(git config --file "$scratch/.git/config" user.email)" = "repo@example.gov" ]
}

@test "clone(msb #438): no effective source identity writes nothing into the scratch" {
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  [ -d "$scratch/.git" ]
  run git config --file "$scratch/.git/config" user.name
  assert_failure
  run git config --file "$scratch/.git/config" user.email
  assert_failure
}

@test "clone(msb #453): the scratch's origin is the source checkout's origin URL, not the host path" {
  git -C "$CLONEPROJ" remote add origin https://github.com/example/cloneproj.git
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  [ "$(git config --file "$scratch/.git/config" remote.origin.url)" = "https://github.com/example/cloneproj.git" ]
  # An absent source value is not invented alongside the carried one.
  run git config --file "$scratch/.git/config" remote.origin.pushurl
  assert_failure
  # The fetch-back remote on the host still points at the scratch.
  [ "$(canonicalize_path "$(git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj)")" = "$(canonicalize_path "$scratch")" ]
}

@test "clone(msb #453): a separate push URL on the source origin is carried too" {
  git -C "$CLONEPROJ" remote add origin https://github.com/example/cloneproj.git
  git -C "$CLONEPROJ" remote set-url --push origin git@github.com:example/cloneproj.git
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  [ "$(git config --file "$scratch/.git/config" remote.origin.url)" = "https://github.com/example/cloneproj.git" ]
  [ "$(git config --file "$scratch/.git/config" remote.origin.pushurl)" = "git@github.com:example/cloneproj.git" ]
}

@test "clone(msb #453): the origin URL is carried raw; host insteadOf rewrites are not baked in" {
  git -C "$CLONEPROJ" remote add origin https://github.com/example/cloneproj.git
  git -C "$CLONEPROJ" config url.git@github.com:.insteadOf https://github.com/
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  [ "$(git config --file "$scratch/.git/config" remote.origin.url)" = "https://github.com/example/cloneproj.git" ]
}

@test "clone(msb #467): a source with no origin leaves the scratch with no origin URL" {
  # `git clone` points origin at the host path, where the guest mounts the
  # scratch itself: a push there would land in the scratch and look successful.
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  assert_success
  run git config --file "$scratch/.git/config" remote.origin.url
  assert_failure
  run git config --file "$scratch/.git/config" remote.origin.pushurl
  assert_failure
  run git -C "$scratch" push origin HEAD
  assert_failure
}

# --- Origin-carry gaps (GSA-TTS/agentic-coding-quickstart#467) ---

@test "clone(msb #467): a multi-valued origin URL is carried in full and in order" {
  # `git remote set-url --add` (push-to-two-forges) is legal; `config --get`
  # returns the LAST value while `git fetch` uses the FIRST.
  git -C "$CLONEPROJ" remote add origin https://github.com/example/cloneproj.git
  git -C "$CLONEPROJ" remote set-url --add origin https://gitlab.com/example/cloneproj.git
  git -C "$CLONEPROJ" remote set-url --add --push origin git@github.com:example/cloneproj.git
  git -C "$CLONEPROJ" remote set-url --add --push origin git@gitlab.com:example/cloneproj.git
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  [ "$(git config --file "$scratch/.git/config" --get-all remote.origin.url)" = \
    "$(printf '%s\n%s' https://github.com/example/cloneproj.git https://gitlab.com/example/cloneproj.git)" ]
  [ "$(git config --file "$scratch/.git/config" --get-all remote.origin.pushurl)" = \
    "$(printf '%s\n%s' git@github.com:example/cloneproj.git git@gitlab.com:example/cloneproj.git)" ]
}

@test "clone(msb #467): the scratch's state dir is private (0700) regardless of umask" {
  # The copied .git/config may hold a credential-bearing origin URL.
  umask 022
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  local dir="$STUBDIR/state/clones/shell-cloneproj" perms
  perms=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir" 2>/dev/null || echo '?')
  [ "$perms" = 700 ]
}

@test "clone(msb #467): a scratch dir that cannot be made private fails the create" {
  # chmod runs as a non-final `&&` link inside a function called as an `if !`
  # condition, where errexit does not apply: without an explicit status check a
  # failure here clones the credential-bearing config in at the ambient umask.
  local real_chmod; real_chmod=$(command -v chmod)
  printf '#!/usr/bin/env bash\ncase " $* " in *"/clones/"*) echo "chmod: operation not permitted" >&2; exit 1;; esac\nexec %s "$@"\n' "$real_chmod" > "$STUBDIR/chmod"
  "$real_chmod" +x "$STUBDIR/chmod"
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'private scratch dir'
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
  _refute_backend_create
}

@test "clone(msb #467): a failed origin carry fails the create and removes the scratch" {
  # A warn-only miss would leave origin pointing at the scratch itself, so an
  # in-guest 'git push origin' APPEARS to succeed while reaching no forge.
  git -C "$CLONEPROJ" remote add origin https://github.com/example/cloneproj.git
  local real_git; real_git=$(command -v git)
  printf '#!/usr/bin/env bash\ncase " $* " in *"/clones/"*" config "*) echo "fatal: could not lock config file" >&2; exit 255;; esac\nexec %s "$@"\n' "$real_git" > "$STUBDIR/git"
  chmod +x "$STUBDIR/git"
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'remote.origin.url'
  assert_output --partial 'push origin'
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
  _refute_backend_create
}

@test "clone(msb #467): an origin URL with an embedded newline stays one value" {
  # `--get-all` is line-oriented and git allows a newline inside a value: read
  # line by line, one value would become two push targets.
  local url; url=$(printf 'https://github.com/example/cloneproj.git\nhttps://evil.example/cloneproj.git')
  git -C "$CLONEPROJ" remote add origin https://placeholder.invalid/x.git
  git -C "$CLONEPROJ" config remote.origin.url "$url"
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  assert_success
  local cfg="$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git/config"
  [ "$(git config --file "$cfg" -z --get-all remote.origin.url | tr -dc '\0' | wc -c | tr -d ' ')" = 1 ]
  [ "$(git config --file "$cfg" --get-all remote.origin.url)" = "$url" ]
}

@test "clone(msb #467): an unreadable source origin fails the create" {
  # Exit 1 means "no such key"; anything else means the config could not be
  # read, which must not be mistaken for "nothing to carry".
  git -C "$CLONEPROJ" remote add origin https://github.com/example/cloneproj.git
  _stub_git '*" --get-all remote.origin.url "*' 128
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'could not read remote.origin.url'
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
  _refute_backend_create
}

@test "clone(msb #467): an unreadable or unwritable identity warns but does not fail the create" {
  # The identity is a convenience, not a safety property: a missing one fails
  # loudly at the first in-guest commit. Only the origin keys abort.
  git -C "$CLONEPROJ" config user.name "Repo User"
  _stub_git '*" --get-all user.email "*|*"/clones/"*" user.name "*' 128
  _msb_clone_isolated create shell --clone "$CLONEPROJ"
  assert_success
  assert_output --partial 'user.name'
  assert_output --partial 'user.email'
  refute_output --partial 'push origin'
  assert_regex "$(cat "$CALLS")" 'msb create'
}

# --- Guest-visible workspace markers (GSA-TTS/agentic-coding-quickstart#456) ---
# A kit that must act only on the disposable clone (write agent instructions,
# install a repo-local permission gate) and never on the real checkout needs a
# deliberate, backend-neutral signal: ACQ_WORKSPACE (guest path of the primary)
# on every create with a workspace, ACQ_CLONE=1 only under --clone. Both ride
# the backend's native create-time --env flag, which reaches every exec/attach
# session and survives a native restart (verified msb 0.6.17, sbx 0.42.1).

@test "clone(msb #456): the guest gets ACQ_WORKSPACE and ACQ_CLONE=1 via create --env" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  load_acq
  local repo line; repo=$(canonicalize_path "$CLONEPROJ"); line=$(_create_line msb)
  assert_regex "$line" "--env ACQ_WORKSPACE=${repo}( |\$)"
  assert_regex "$line" '--env ACQ_CLONE=1( |$)'
}

@test "clone(msb #456): a non-clone create exports ACQ_WORKSPACE but never ACQ_CLONE" {
  _msb_clone -- create shell "$CLONEPROJ"
  load_acq
  local repo line; repo=$(canonicalize_path "$CLONEPROJ"); line=$(_create_line msb)
  assert_regex "$line" "--env ACQ_WORKSPACE=${repo}( |\$)"
  refute_regex "$line" 'ACQ_CLONE'
}

@test "clone(msb #456): ACQ_MSB_WORKSPACE moves the start dir but ACQ_WORKSPACE stays on the clone's mount root" {
  # The override relocates only where the agent starts. The marker must keep
  # naming the primary mount, or a --clone kit would read ACQ_CLONE=1 next to
  # a path that is not the clone and write into the wrong tree.
  _msb_clone ACQ_MSB_WORKSPACE=/tmp/elsewhere -- create shell --clone "$CLONEPROJ"
  load_acq
  local repo line; repo=$(canonicalize_path "$CLONEPROJ"); line=$(_create_line msb)
  assert_regex "$line" "--env ACQ_WORKSPACE=${repo}( |\$)"
  refute_regex "$line" 'ACQ_WORKSPACE=/tmp/elsewhere'
  assert_regex "$line" '--env ACQ_CLONE=1( |$)'
}

@test "clone(msb #456): a workspace-less create exports neither marker" {
  # Same session, same stub: first prove the emitter fires with a workspace,
  # so the refute below cannot pass with the emitter deleted.
  _msb_clone -- create shell --name withws "$CLONEPROJ"
  assert_regex "$(_create_line msb)" '--env ACQ_WORKSPACE='
  : > "$CALLS"
  _msb_clone -- create shell
  assert_regex "$(cat "$CALLS")" 'msb create'
  refute_regex "$(_create_line msb)" 'ACQ_WORKSPACE|ACQ_CLONE'
}

@test "clone(sbx #456): the guest gets ACQ_WORKSPACE and ACQ_CLONE=1 via create --env" {
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
  env ACQ_BACKEND=sbx "$ACQ" create opencode --clone "$CLONEPROJ" >/dev/null 2>&1
  local line logical; line=$(_create_line sbx); logical=$(cd "$CLONEPROJ" && pwd)
  # sbx mounts the primary at its LOGICAL absolute host path (not realpath;
  # on macOS the bats tmpdir is /var/..., a symlink to /private/var), so the
  # marker must match that form for `cd "$ACQ_WORKSPACE"` to land.
  assert_regex "$line" "--env ACQ_WORKSPACE=${logical}( |\$)"
  local real; real=$(canonicalize_path "$CLONEPROJ")
  if [ "$real" != "$logical" ]; then
    refute_regex "$line" "ACQ_WORKSPACE=${real}( |\$)"
  fi
  assert_regex "$line" '--env ACQ_CLONE=1( |$)'
}

@test "clone(sbx #456): a relative workspace resolves against PWD (CDPATH ignored) to the logical path, no ACQ_CLONE" {
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
  # CDPATH points at a decoy holding a same-named dir: the marker must still
  # resolve the relative workspace against $PWD, as sbx does, on one line.
  mkdir -p "$STUBDIR/decoy/cloneproj"
  (cd "$STUBDIR" && CDPATH="$STUBDIR/decoy" env ACQ_BACKEND=sbx "$ACQ" create opencode cloneproj >/dev/null 2>&1)
  local line logical; line=$(_create_line sbx); logical=$(cd "$CLONEPROJ" && pwd)
  assert_regex "$line" "--env ACQ_WORKSPACE=${logical} "
  refute_regex "$line" 'decoy'
  refute_regex "$line" 'ACQ_CLONE'
}

# --- Host-side git hardening in clone mode ---

# Put a `git` on PATH that appends each call's argv to LOG and passes it
# through to the real git.
_record_git() { # LOG
  local real; real=$(command -v git)
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec %s "$@"\n' "$1" "$real" > "$STUBDIR/git"
  chmod +x "$STUBDIR/git"
}
# The wrapped calls in LOG: every one carries protocol.allow=never.
_wrapped_calls() { grep -- '-c protocol.allow=never' "$1"; }

# A create that must fail on the repository's layout, leaving nothing behind.
_assert_layout_refused() { # SANDBOX
  assert_failure
  assert_output --partial 'not an ordinary repository checkout'
  assert_output --partial 'git worktree'
  assert_output --partial 'submodule'
  _refute_backend_create
  [ ! -e "$STUBDIR/state/clones/$1" ]
}

@test "clone(msb): host-side git runs with --no-pager at create and rm" {
  _record_git "$STUBDIR/gitlog"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  _msb_clone -- rm shell-cloneproj
  assert_success
  local wrapped; wrapped=$(_wrapped_calls "$STUBDIR/gitlog")
  assert_regex "$wrapped" ' remote remove sandbox-shell-cloneproj'
  [ -z "$(printf '%s\n' "$wrapped" | grep -v -- '^--no-pager ')" ]
}

@test "clone(msb): hooks are disabled via a never-created path in acq's state dir, not /dev/null" {
  _record_git "$STUBDIR/gitlog"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  local wrapped hooks
  wrapped=$(_wrapped_calls "$STUBDIR/gitlog")
  [ -n "$wrapped" ]
  refute_regex "$wrapped" 'core\.hooksPath=/dev/null'
  # Every wrapped call names the same hooks path, under the state dir...
  hooks=$(printf '%s\n' "$wrapped" | sed 's/.*-c core\.hooksPath=\([^ ]*\) .*/\1/' | sort -u)
  [ "$(printf '%s\n' "$hooks" | wc -l | tr -d ' ')" = 1 ]
  case "$hooks" in "$STUBDIR/state/"?*) ;; *) false ;; esac
  # ...and nothing creates it.
  [ ! -e "$hooks" ]
}

@test "clone(msb): a linked worktree or a gitfile checkout is refused" {
  git -C "$CLONEPROJ" worktree add -q "$STUBDIR/wtproj"
  _msb_clone -- create shell --clone "$STUBDIR/wtproj"
  _assert_layout_refused shell-wtproj
  assert_output --partial '.git is a file pointing at another git directory'
  # A submodule checkout has the same shape: .git is a file naming a git dir
  # kept elsewhere.
  git init -q --separate-git-dir "$STUBDIR/sep.git" "$STUBDIR/subproj"
  git -C "$STUBDIR/subproj" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  [ -f "$STUBDIR/subproj/.git" ]
  _msb_clone -- create shell --clone "$STUBDIR/subproj"
  _assert_layout_refused shell-subproj
  assert_output --partial '.git is a file pointing at another git directory'
}

@test "clone(msb): a symlinked .git, a symlinked object store, or a commondir is refused" {
  mv "$CLONEPROJ/.git" "$STUBDIR/real.git"
  ln -s "$STUBDIR/real.git" "$CLONEPROJ/.git"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  _assert_layout_refused shell-cloneproj
  assert_output --partial '.git is a symlink'
  rm "$CLONEPROJ/.git"; mv "$STUBDIR/real.git" "$CLONEPROJ/.git"

  mv "$CLONEPROJ/.git/objects" "$STUBDIR/objects"
  ln -s "$STUBDIR/objects" "$CLONEPROJ/.git/objects"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  _assert_layout_refused shell-cloneproj
  assert_output --partial '.git contains a symlink'
  rm "$CLONEPROJ/.git/objects"; mv "$STUBDIR/objects" "$CLONEPROJ/.git/objects"

  printf '.\n' > "$CLONEPROJ/.git/commondir"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  _assert_layout_refused shell-cloneproj
  assert_output --partial 'commondir'
}

@test "clone(msb): an inherited GIT_COMMON_DIR is cleared, not followed to another repo" {
  # GIT_COMMON_DIR would move the common dir (objects, refs, config) while
  # .git itself still looks ordinary. Host-side git clears it, so the clone
  # and the remote are the workspace's, and the other repo is untouched.
  local other="$STUBDIR/otherrepo" before
  _mk_repo "$other"
  before=$(cat "$other/.git/config")
  _msb_clone GIT_COMMON_DIR="$other/.git" -- create shell --clone "$CLONEPROJ"
  assert_success
  [ -d "$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git" ]
  git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj
  assert_equal "$(cat "$other/.git/config")" "$before"
}

@test "clone(msb): a filter driver whose name contains '=' is blanked too" {
  # `-c filter.a=b.clean=` would set filter.a to "b.clean=", leaving the real
  # driver live; the settings must travel through GIT_CONFIG_COUNT instead.
  _arm_repo_config "$CLONEPROJ" "$STUBDIR/ran" 'a=b'
  # The attribute really selects the driver named `a=b` (fsmonitor off: the
  # recorder is armed there too).
  [ "$(git -c core.fsmonitor=false -C "$CLONEPROJ" check-attr filter file.txt)" = 'file.txt: filter: a=b' ]
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  [ -d "$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git" ]
  [ ! -e "$STUBDIR/ran" ]
}

@test "clone(msb): on git older than 2.31 a filter name containing '=' is refused" {
  _arm_repo_config "$CLONEPROJ" "$STUBDIR/ran" 'a=b'
  local real; real=$(command -v git)
  printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo "git version 2.30.2"; exit 0; }\nexec %s "$@"\n' \
    "$real" > "$STUBDIR/git"
  chmod +x "$STUBDIR/git"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial "contains '='"
  assert_output --partial '2.31'
  _refute_backend_create
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
  [ ! -e "$STUBDIR/ran" ]
}

@test "clone(msb): identity comes from global includeIf, then repo-local, never a repo-local include" {
  local home="$STUBDIR/idhome" repo
  repo=$(canonicalize_path "$CLONEPROJ")
  mkdir -p "$home"
  printf '[user]\n\tname = Forge User\n\temail = forge@example.gov\n' > "$STUBDIR/forge.inc"
  printf '[includeIf "gitdir:%s/"]\n\tpath = %s\n' "$repo" "$STUBDIR/forge.inc" > "$home/.gitconfig"
  # Repo-local wins over global for email; the repo's own include is not
  # followed, so its name never replaces the global one.
  printf '[user]\n\tname = Local Include\n' > "$STUBDIR/local.inc"
  git -C "$CLONEPROJ" config include.path "$STUBDIR/local.inc"
  git -C "$CLONEPROJ" config user.email "repo@example.gov"
  _msb_clone HOME="$home" XDG_CONFIG_HOME="$STUBDIR/noconfig" GIT_CONFIG_NOSYSTEM=1 -- \
    create shell --clone "$CLONEPROJ"
  assert_success
  local cfg="$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git/config"
  [ "$(git config --file "$cfg" user.name)" = "Forge User" ]
  [ "$(git config --file "$cfg" user.email)" = "repo@example.gov" ]
}

@test "clone(msb): a partial clone is refused before anything is created" {
  git -C "$CLONEPROJ" remote add origin https://example.invalid/cloneproj.git
  git -C "$CLONEPROJ" config remote.origin.promisor true
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'partial clone'
  _refute_backend_create
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
  run git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj
  assert_failure

  git -C "$CLONEPROJ" config --unset remote.origin.promisor
  git -C "$CLONEPROJ" config extensions.partialClone origin
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'partial clone'
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
}

@test "clone(msb): a Git LFS workspace gets a notice to run 'git lfs pull' in the guest" {
  # Dirty in both runs, so the uncommitted-changes note is printed each time;
  # only the LFS run adds the may-appear-modified caveat to it.
  echo new > "$CLONEPROJ/untracked.txt"
  _msb_clone -- create shell --name nolfs --clone "$CLONEPROJ"
  assert_success
  assert_output --partial 'uncommitted changes'
  refute_output --partial 'git lfs pull'
  refute_output --partial 'may appear modified'
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$CLONEPROJ/.gitattributes"
  git -C "$CLONEPROJ" add .gitattributes
  git -C "$CLONEPROJ" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m lfs
  _msb_clone -- create shell --name withlfs --clone "$CLONEPROJ"
  assert_success
  assert_output --partial 'Git LFS'
  assert_output --partial 'If git-lfs is available in the sandbox'
  assert_output --partial 'git lfs pull'
  assert_output --partial 'LFS-tracked files may appear modified'
}

@test "clone(msb): a symlink anywhere inside .git (except hooks) is refused" {
  # Each of these lets git read objects or refs from another repository while
  # .git itself, .git/objects and rev-parse all look ordinary.
  local other="$STUBDIR/otherrepo" p
  _mk_repo "$other"
  git -C "$other" pack-refs --all
  for p in objects/pack refs/heads packed-refs; do
    if [ -e "$CLONEPROJ/.git/$p" ]; then mv "$CLONEPROJ/.git/$p" "$STUBDIR/saved"; fi
    ln -s "$other/.git/$p" "$CLONEPROJ/.git/$p"
    _msb_clone -- create shell --clone "$CLONEPROJ"
    _assert_layout_refused shell-cloneproj
    assert_output --partial '.git contains a symlink'
    rm "$CLONEPROJ/.git/$p"
    if [ -e "$STUBDIR/saved" ]; then mv "$STUBDIR/saved" "$CLONEPROJ/.git/$p"; fi
  done
  # A symlink under .git/hooks is exempt: the wrapper never runs hooks.
  ln -s /nonexistent-hook "$CLONEPROJ/.git/hooks/pre-commit"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  [ -d "$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git" ]
}

@test "clone(msb): an existing hooks path (dir or dangling symlink) fails closed" {
  local hooks="$STUBDIR/state/.git-hooks-disabled"
  mkdir -p "$hooks"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial '.git-hooks-disabled exists'
  _refute_backend_create
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
  rmdir "$hooks"
  ln -s "$STUBDIR/nowhere" "$hooks"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial '.git-hooks-disabled exists'
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
}

@test "clone(msb): a relative ACQ_STATE_DIR is refused before any host-side git runs" {
  # A relative core.hooksPath would resolve inside the guest-writable workspace.
  # The adapter blanks a relative ACQ_STATE_DIR when it is sourced, so the
  # refusal comes from the unresolved clones dir; the wrapper's own check is the
  # fallback if that ever changes. Either way nothing is created and no git runs.
  run bash -c '
    cd "'"$STUBDIR"'"
    export ACQ_STATE_DIR=relstate
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_clone_setup shell-cloneproj "$1"
  ' _ "$CLONEPROJ"
  assert_failure
  assert_output --regexp 'ACQ_STATE_DIR must be an absolute path|scratch clones dir: its directory could not be resolved'
  [ ! -e "$STUBDIR/relstate" ]
  run git -C "$CLONEPROJ" remote
  assert_success
  assert_output ''
}

@test "clone(msb): an unreadable workspace config is refused, not treated as filter-free" {
  _stub_git '*"--get-regexp ^filter"*' 128
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_failure
  assert_output --partial 'could not read the git config'
  _refute_backend_create
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
}

@test "clone(msb): a user-exported GIT_CONFIG_COUNT is dropped from workspace git; blanking starts at 0" {
  _arm_repo_config "$CLONEPROJ" "$STUBDIR/ran"
  local real; real=$(command -v git)
  printf '#!/usr/bin/env bash\n{ printf "CALL %%s\\n" "$*"; env | grep "^GIT_CONFIG_" | sort; } >> "%s"\nexec %s "$@"\n' \
    "$STUBDIR/gitenv" "$real" > "$STUBDIR/git"
  chmod +x "$STUBDIR/git"
  _msb_clone GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.abbrev GIT_CONFIG_VALUE_0=12 -- \
    create shell --clone "$CLONEPROJ"
  assert_success
  [ ! -e "$STUBDIR/ran" ]
  # The environment of the wrapped clone call: acq's blanking entries alone,
  # from index 0 (the host's own system/global filters, if any, alongside).
  local clone
  clone=$(awk '/^CALL /{on = / clone /} on' "$STUBDIR/gitenv")
  assert_regex "$clone" 'CALL .* clone '
  refute_regex "$clone" 'core\.abbrev'
  assert_regex "$clone" 'GIT_CONFIG_KEY_0=filter\.'
  assert_regex "$clone" 'GIT_CONFIG_KEY_[0-9]+=filter\.rec\.(clean|smudge|process)'
  # Of the clone-mode calls (wrapped, or against the scratch), only the
  # command-scope identity read keeps the user's entry.
  [ -z "$(awk '/^CALL /{c = $0} /core\.abbrev/{print c}' "$STUBDIR/gitenv" |
    grep -e '-c protocol.allow=never' -e '/clones/' | grep -v -- '--show-scope')" ]
  assert_regex "$(cat "$STUBDIR/gitenv")" "CALL --no-pager -C $STUBDIR/state/clones/[^ ]* config "
}

@test "clone(msb): identity honours GIT_CONFIG_NOSYSTEM like git and reads worktree and command scopes" {
  local sys="$STUBDIR/sys.gitconfig" cfg="$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git/config"
  printf '[user]\n\tname = System User\n\temail = system@example.gov\n' > "$sys"
  git -C "$CLONEPROJ" config user.email repo@example.gov
  git -C "$CLONEPROJ" config extensions.worktreeConfig true
  git -C "$CLONEPROJ" config --worktree user.email wt@example.gov
  # GIT_CONFIG_NOSYSTEM=2 is true to git (a non-zero integer): no system file.
  # The worktree scope overrides the local one.
  _msb_clone HOME="$STUBDIR/nohome" XDG_CONFIG_HOME="$STUBDIR/noconfig" \
    GIT_CONFIG_SYSTEM="$sys" GIT_CONFIG_NOSYSTEM=2 -- create shell --clone "$CLONEPROJ"
  assert_success
  run git config --file "$cfg" user.name
  assert_failure
  [ "$(git config --file "$cfg" user.email)" = wt@example.gov ]
  _msb_clone -- rm shell-cloneproj
  # GIT_CONFIG_NOSYSTEM=00 is false to git (the integer zero), so the system
  # file is read; an exported command-scope value comes last and wins.
  _msb_clone HOME="$STUBDIR/nohome" XDG_CONFIG_HOME="$STUBDIR/noconfig" \
    GIT_CONFIG_SYSTEM="$sys" GIT_CONFIG_NOSYSTEM=00 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=env@example.gov -- \
    create shell --clone "$CLONEPROJ"
  assert_success
  [ "$(git config --file "$cfg" user.name)" = "System User" ]
  [ "$(git config --file "$cfg" user.email)" = env@example.gov ]
}

@test "clone(msb): an execute-only .git cannot hide a symlink from the scan" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  # git still opens files by name in an execute-only directory, so a symlink
  # the scan cannot list must refuse the create rather than pass unseen.
  local other="$STUBDIR/otherrepo"
  _mk_repo "$other"
  mv "$CLONEPROJ/.git/refs/heads" "$STUBDIR/saved"
  ln -s "$other/.git/refs/heads" "$CLONEPROJ/.git/refs/heads"
  chmod 0111 "$CLONEPROJ/.git"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  chmod 0755 "$CLONEPROJ/.git"
  _assert_layout_refused shell-cloneproj
  assert_output --partial 'could not scan .git'
  rm "$CLONEPROJ/.git/refs/heads"; mv "$STUBDIR/saved" "$CLONEPROJ/.git/refs/heads"
  # An unreadable .git/hooks is pruned before it is read, so it stays exempt.
  chmod 0 "$CLONEPROJ/.git/hooks"
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  [ -d "$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git" ]
}

@test "clone(msb): rm reports a wrapper refusal instead of a spurious unfetched warning" {
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  # Nothing unfetched, but the wrapper now refuses to run git in the origin:
  # rm must say why, not claim every branch tip is unfetched or silently
  # leave the remote behind.
  mkdir -p "$STUBDIR/state/.git-hooks-disabled"
  _msb_clone -- rm shell-cloneproj
  assert_success
  assert_output --partial '.git-hooks-disabled exists'
  refute_output --partial 'discarding unfetched commits'
  assert_output --partial 'could not check'
  assert_output --partial 'remote remove sandbox-shell-cloneproj'
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
}

# --- Inherited git environment in clone mode ---

# A second repository with a commit the workspace lacks, standing in for the
# one an inherited GIT_DIR (set by a hook, an editor or a parent git) names.
_mk_other_repo() { # PATH
  _mk_repo "$1"
  echo other > "$1/other-only.txt"
  git -C "$1" add other-only.txt
  git -C "$1" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m other
}

@test "clone(msb): create with an inherited GIT_DIR clones the workspace and leaves that repo alone" {
  local other="$STUBDIR/otherrepo" before scratch="$STUBDIR/state/clones/shell-cloneproj/cloneproj"
  _mk_other_repo "$other"
  before=$(cat "$other/.git/config")
  _msb_clone GIT_DIR="$other/.git" -- create shell --clone "$CLONEPROJ"
  assert_success
  # The scratch is a clone of the workspace, not of the inherited repository.
  [ "$(git -C "$scratch" rev-parse HEAD)" = "$(git -C "$CLONEPROJ" rev-parse HEAD)" ]
  [ ! -e "$scratch/other-only.txt" ]
  [ "$(git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj)" = "$scratch" ]
  assert_equal "$(cat "$other/.git/config")" "$before"
  assert_equal "$(git -C "$other" remote)" ""
}

@test "clone(msb): rm with an inherited GIT_DIR removes the workspace's remote, not that repo's" {
  local other="$STUBDIR/otherrepo" before
  _mk_other_repo "$other"
  # The other repository has a same-named remote of its own (another checkout
  # with a sandbox of the same name, say); rm must not remove it.
  git -C "$other" remote add sandbox-shell-cloneproj "$STUBDIR/elsewhere"
  before=$(cat "$other/.git/config")
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  _msb_clone GIT_DIR="$other/.git" -- rm shell-cloneproj
  assert_success
  assert_equal "$(cat "$other/.git/config")" "$before"
  [ ! -e "$STUBDIR/state/clones/shell-cloneproj" ]
  run git -C "$CLONEPROJ" remote get-url sandbox-shell-cloneproj
  assert_failure
}

@test "clone(msb): a hooks path injected through GIT_CONFIG_PARAMETERS runs no hook" {
  local hooks="$STUBDIR/injected-hooks" h
  mkdir -p "$hooks"
  printf '#!/bin/sh\necho "$0" >> "%s"\ncat >/dev/null\n' "$STUBDIR/ran" > "$hooks/rec"
  chmod +x "$hooks/rec"
  for h in post-checkout reference-transaction post-index-change; do
    cp "$hooks/rec" "$hooks/$h"
  done
  _msb_clone -- create shell --clone "$CLONEPROJ"
  assert_success
  # A fetched commit gives rm remote-tracking refs to delete, which is what
  # runs the reference-transaction hook.
  _agent_commit "$STUBDIR/state/clones/shell-cloneproj/cloneproj" agent-work
  git -C "$CLONEPROJ" fetch -q sandbox-shell-cloneproj
  _msb_clone -- rm shell-cloneproj
  _msb_clone "GIT_CONFIG_PARAMETERS='core.hooksPath'='$hooks'" -- create shell --clone "$CLONEPROJ"
  assert_success
  [ -d "$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git" ]
  _agent_commit "$STUBDIR/state/clones/shell-cloneproj/cloneproj" agent-work-2
  git -C "$CLONEPROJ" fetch -q sandbox-shell-cloneproj
  _msb_clone "GIT_CONFIG_PARAMETERS='core.hooksPath'='$hooks'" -- rm shell-cloneproj
  assert_success
  [ ! -e "$STUBDIR/ran" ]
}

@test "clone(msb): a filter driver injected through GIT_CONFIG_PARAMETERS is not run" {
  # The driver is defined only on the command scope. GIT_CONFIG_PARAMETERS is
  # read after GIT_CONFIG_COUNT, so it would override acq's blanking entries.
  local rec="$STUBDIR/recorder.sh"
  printf '#!/bin/sh\necho "$0 $*" >> "%s"\ncat\n' "$STUBDIR/ran" > "$rec"
  chmod +x "$rec"
  printf '* filter=rec\n' > "$CLONEPROJ/.git/info/attributes"
  touch -t 200001010000 "$CLONEPROJ/file.txt"
  _msb_clone "GIT_CONFIG_PARAMETERS='filter.rec.clean'='$rec' 'filter.rec.smudge'='$rec'" -- \
    create shell --clone "$CLONEPROJ"
  assert_success
  [ -d "$STUBDIR/state/clones/shell-cloneproj/cloneproj/.git" ]
  [ ! -e "$STUBDIR/ran" ]
}

@test "clone(msb): host-side git refuses to run when the isolation helper is not loaded" {
  local other="$STUBDIR/otherrepo" before
  _mk_repo "$other"
  before=$(cat "$other/.git/config")
  run env GIT_DIR="$other/.git" ACQ_STATE_DIR="$STUBDIR/state" bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    unset -f _kit_git_isolate
    _acq_msb_git_ws "$1" remote add sandbox-x /nowhere
  ' _ "$CLONEPROJ"
  assert_failure
  assert_output --partial 'cannot clear the'
  assert_equal "$(cat "$other/.git/config")" "$before"
  run git -C "$CLONEPROJ" remote
  assert_output ''
}
