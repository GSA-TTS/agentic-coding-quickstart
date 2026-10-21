#!/usr/bin/env bats
#
# 155-git-fixture-isolation.bats — the suite's own git fixtures must never be
# redirected at another repository by an inherited Git environment.
#
# Git exports its repository-local variables (GIT_DIR, GIT_WORK_TREE,
# GIT_INDEX_FILE, ...) to hooks. A suite run from a pre-commit hook therefore
# inherits a GIT_DIR pointing at the invoking repository, and `git -C <fixture>`
# does NOT override it: the -C only changes directory. Without clearing that
# environment, every fixture `git init`/`commit` in this suite targets the
# invoking repository instead of the fixture — committing throwaway fixture
# identities onto a real branch, and writing core.worktree into the real
# repository's config, which then redirects later Git commands (including a real
# kit fetch's checkout) at the wrong tree.
#
# These tests assert the harness clears that environment, and that the
# kit-fetch destination guard refuses a destination inside a real repository.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# _mk_sentinel_repo — a real repo standing in for "the repository that invoked
# the hook". Its HEAD, identity, config and tracked file are the things a
# redirected fixture would damage.
_mk_sentinel_repo() { # PATH
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'sentinel\n' > "$1/sentinel.txt"
  git -C "$1" add sentinel.txt
  git -C "$1" -c user.email=real@example.gov -c user.name=real \
    -c commit.gpgsign=false commit -q -m parent-sentinel
}

@test "git-fixture-isolation: setup clears Git's repository-local env vars" {
  # acq_setup_stubs already ran. Every variable git would have exported to a
  # hook must be absent, or a fixture `git -C` would resolve to the wrong repo.
  local v
  for v in $(git rev-parse --local-env-vars); do
    refute [ -n "${!v:-}" ]
  done
}

@test "git-fixture-isolation: inherited GIT_DIR cannot redirect a fixture repo" {
  local sentinel="$STUBDIR/sentinel" fixture="$STUBDIR/fixture"
  _mk_sentinel_repo "$sentinel"
  local head_before count_before
  head_before=$(git -C "$sentinel" rev-parse HEAD)
  count_before=$(git -C "$sentinel" rev-list --count HEAD)

  # Export exactly what Git hands a hook, then re-run the harness clear and
  # create a fixture the way the suite does.
  export GIT_DIR="$sentinel/.git"
  export GIT_WORK_TREE="$sentinel"
  export GIT_INDEX_FILE="$sentinel/.git/index"
  acq_clear_git_local_env

  mkdir -p "$fixture"
  git -C "$fixture" init -q
  printf 'one\n' > "$fixture/file.txt"
  git -C "$fixture" add file.txt
  git -C "$fixture" -c user.email=t@example.com -c user.name=t \
    -c commit.gpgsign=false commit -q -m init

  # The fixture is its own repository, not the sentinel.
  assert [ -d "$fixture/.git" ]
  assert_equal "$(git -C "$fixture" rev-parse --show-toplevel)" \
    "$(cd "$fixture" && pwd -P)"

  # The sentinel is untouched: same HEAD, same commit count, no fixture
  # identity on its log, and no core.worktree written into its config.
  assert_equal "$(git -C "$sentinel" rev-parse HEAD)" "$head_before"
  assert_equal "$(git -C "$sentinel" rev-list --count HEAD)" "$count_before"
  run git -C "$sentinel" log --format='%ae' -1
  assert_output 'real@example.gov'
  run git -C "$sentinel" config --local --get core.worktree
  assert_failure
}

@test "git-fixture-isolation: a hook-inherited GIT_DIR WOULD capture an uncleared fixture" {
  # Negative control. Without the clear, `git -C` resolves to the inherited
  # GIT_DIR — so this test fails if the hazard ever stops being real and the
  # two tests above start passing vacuously.
  local sentinel="$STUBDIR/sentinel2" fixture="$STUBDIR/fixture2"
  _mk_sentinel_repo "$sentinel"

  export GIT_DIR="$sentinel/.git"
  export GIT_WORK_TREE="$sentinel"
  export GIT_INDEX_FILE="$sentinel/.git/index"

  mkdir -p "$fixture"
  git -C "$fixture" init -q 2>/dev/null || true
  # The fixture got no .git of its own, and resolves to the sentinel.
  refute [ -d "$fixture/.git" ]
  assert_equal "$(git -C "$fixture" rev-parse --show-toplevel)" \
    "$(cd "$sentinel" && pwd -P)"

  acq_clear_git_local_env
}

@test "kit fetch: refuses a destination inside a git repository" {
  local repo="$STUBDIR/destrepo"
  _mk_sentinel_repo "$repo"
  local head_before
  head_before=$(git -C "$repo" rev-parse HEAD)

  run kit_translate_fetch \
    'git+https://example.invalid/x.git#ref=deadbeef&dir=kits/a' "$repo"
  assert_failure
  assert_output --partial 'refusing to fetch into a git repository'

  # The guard ran before any destructive step: metadata and tracked file intact.
  assert [ -d "$repo/.git" ]
  assert_equal "$(git -C "$repo" rev-parse HEAD)" "$head_before"
  assert [ -f "$repo/sentinel.txt" ]
}

@test "kit fetch: refuses a subdirectory of a git repository" {
  local repo="$STUBDIR/destrepo2"
  _mk_sentinel_repo "$repo"
  mkdir -p "$repo/nested/deeper"

  run kit_translate_fetch \
    'git+https://example.invalid/x.git#ref=deadbeef&dir=kits/a' "$repo/nested/deeper"
  assert_failure
  assert_output --partial 'refusing to fetch into a git repository'
  assert [ -d "$repo/.git" ]
  assert [ -f "$repo/sentinel.txt" ]
}

@test "kit fetch: refuses an empty destination" {
  run kit_translate_fetch \
    'git+https://example.invalid/x.git#ref=deadbeef&dir=kits/a' ''
  assert_failure
  assert_output --partial 'refusing to fetch into an empty destination'
}

@test "kit fetch: refuses / as a destination" {
  run kit_translate_fetch \
    'git+https://example.invalid/x.git#ref=deadbeef&dir=kits/a' '/'
  assert_failure
  assert_output --partial 'refusing to fetch into /'
}

@test "kit fetch: still accepts a clean scratch destination" {
  # The guard must not break the normal path. A non-repo scratch dir gets past
  # the destination checks and fails later, on the unreachable network host.
  local scratch="$STUBDIR/scratch"
  run kit_translate_fetch \
    'git+https://example.invalid/x.git#ref=deadbeef&dir=kits/a' "$scratch"
  assert_failure
  refute_output --partial 'refusing to fetch into'
  assert [ -d "$scratch" ]
}
