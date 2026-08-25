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
acq_setup_stubs() {
  make_stubs
  load_acq
}

# bats teardown(): remove this test's stub dir. Safe if setup partially ran.
acq_teardown_stubs() {
  cleanup_stubs || true
}
