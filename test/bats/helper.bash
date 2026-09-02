#!/usr/bin/env bash
#
# helper.bash — shared bats setup for the acq test suite (ADR-0025).
#
# Loaded by each *.bats file. It bridges bats to the stub library
# (scripts/test-acq-lib.sh) so tests reuse the exact sbx/msb/ssh stubs and the
# load_acq sourcing contract — the stub layer is the valuable, framework-agnostic
# part, retained when the suite migrated off the bespoke runner.
#
# What bats gives us:
#   - each @test runs in its own subshell (real isolation; no cross-test leak)
#   - setup()/teardown() replace manual make_stubs/cleanup_stubs bookkeeping
#   - bats-assert gives assert_success / assert_output / assert_line etc.
#
# Do NOT enable shellcheck -x on the suite: following the sourced stub library
# re-triggers the dataflow OOM (see .shellcheckrc / ADR-0025).

# Resolve the repo root from this helper's location (test/bats/ -> repo root).
_bats_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_bats_helper_dir}/../.." && pwd)"
export REPO_ROOT

# bats-support + bats-assert (vendored submodules, pinned in .gitmodules).
load "${REPO_ROOT}/test/vendor/bats-support/load"
load "${REPO_ROOT}/test/vendor/bats-assert/load"

# The stub library: defines make_stubs, cleanup_stubs, load_acq, the ACQ /
# REPO_ROOT paths, the offline kit-dir, and MSB_GITHUB_SECRET_BINDING.
# shellcheck source=scripts/test-acq-lib.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/scripts/test-acq-lib.sh"

# bats setup(): fresh stub sandbox per @test. make_stubs mktemps a private
# $STUBDIR and $CALLS, so isolated tests never share state.
#
# The invoking shell's acq knobs must not leak into tests: a developer who
# exports e.g. ACQ_IMAGE or ACQ_CLONE for daily use would silently change what
# the suite exercises (observed: an exported ACQ_IMAGE broke every image-default
# assertion locally while CI stayed green). Tests that need a knob set it
# explicitly per invocation.
acq_setup_stubs() {
  unset ACQ_BACKEND ACQ_IMAGE ACQ_CLONE ACQ_EXTRA_KITS ACQ_UPDATE_CHECK \
        ACQ_STATE_DIR ACQ_SECRET_STORE_DIR ACQ_NETWORK_TIER \
        ACQ_NETWORK_TIER_CONFIRM_OPEN ACQ_MSB_BALANCED_EGRESS ACQ_MSB_IMAGE \
        ACQ_MSB_PULL ACQ_MSB_WORKSPACE ACQ_MSB_CLONES_DIR
  make_stubs
  # Tests that fake HOME still leak into the developer's real git config when
  # the shell exports XDG_CONFIG_HOME: git writes --global to
  # $XDG_CONFIG_HOME/git/config whenever that file exists and ~/.gitconfig does
  # not, and reads it the same way. Point it under the stub dir so a faked HOME
  # is complete (observed: fixture identities written into ~/.config/git/config
  # after every suite run). Tests that need a config dir set their own.
  # GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM override both HOME and XDG lookups, so a
  # runner exporting them would leak through (and receive the fixture writes).
  export XDG_CONFIG_HOME="$STUBDIR/xdg"
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
  load_acq
}

# bats teardown(): remove this test's stub dir. Safe if setup partially ran.
acq_teardown_stubs() {
  cleanup_stubs || true
}

# _acq_coreutils_path — echo a ':'-joined PATH holding the directories of the
# core tools a test (and bats' own teardown, which runs `rm`) needs. Tests that
# want to prove PATH self-repair narrow PATH down to "just coreutils" so the
# backend CLI is provably absent; naively using `dirname $(command -v env)` can
# yield a directory that lacks `rm`/`cat` on hosts where coreutils are split
# across dirs (Homebrew, Nix, some distros) — which then breaks `run cat …` in
# the test AND `rm` in bats-exec-test's own teardown. Union the dirs of every
# tool we actually rely on so the narrowed PATH is complete regardless of layout.
# De-dupes while preserving first-seen order. bash 3.2 safe.
#
# Only absolute paths are unioned: `command -v` resolves shell builtins (e.g.
# printf) to a bare name with no directory, and `dirname` of a bare name yields
# ".", which would silently put the *current directory* on the narrowed PATH —
# a stray file in the CWD would then become callable and defeat the "backend
# provably absent" premise. Skipping non-/-prefixed results keeps PATH clean.
_acq_coreutils_path() {
  local _tools="env rm cat mkdir mv chmod dirname sh grep sed awk printf"
  local _t _d _seen="" _out=""
  for _t in $_tools; do
    _d=$(command -v "$_t" 2>/dev/null) || continue
    case "$_d" in /*) ;; *) continue ;; esac
    _d=$(dirname "$_d")
    case ":$_seen:" in *":$_d:"*) continue ;; esac
    _seen="${_seen:+$_seen:}$_d"
    _out="${_out:+$_out:}$_d"
  done
  printf '%s' "$_out"
}
