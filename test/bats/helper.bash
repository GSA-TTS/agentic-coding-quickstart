#!/usr/bin/env bash
#
# helper.bash — shared bats setup for the acq bats pilot (ADR-0025).
#
# Loaded by each *.bats pilot file. It bridges bats to the EXISTING stub harness
# (scripts/test-acq-lib.sh) so the pilot reuses the exact sbx/msb/ssh stubs and
# the load_acq sourcing contract rather than duplicating them — the stub layer
# is the valuable, well-tested part and is framework-agnostic.
#
# What bats gives us over the bespoke runner:
#   - each @test runs in its own subshell (real isolation; no cross-test leak)
#   - setup()/teardown() replace manual make_stubs/cleanup_stubs bookkeeping
#   - bats-assert gives assert_success / assert_output / assert_line etc.
#
# Do NOT enable shellcheck -x on the pilot: following the sourced harness
# re-triggers the dataflow OOM (see .shellcheckrc / ADR-0025).

# Resolve the repo root from this helper's location (test/bats/ -> repo root).
_bats_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_bats_helper_dir}/../.." && pwd)"
export REPO_ROOT

# bats-support + bats-assert (vendored submodules, pinned in .gitmodules).
load "${REPO_ROOT}/test/vendor/bats-support/load"
load "${REPO_ROOT}/test/vendor/bats-assert/load"

# The existing stub library: defines make_stubs, cleanup_stubs, load_acq, and
# the ACQ / REPO_ROOT / counter globals. Sourcing it here means the pilot and
# the legacy suite share ONE definition of the stubs.
# shellcheck source=scripts/test-acq-lib.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/scripts/test-acq-lib.sh"

# bats setup(): fresh stub sandbox per @test. make_stubs mktemps a private
# $STUBDIR and $CALLS, so parallel/!isolated tests never share state.
acq_setup_stubs() {
  make_stubs
  load_acq
}

# bats teardown(): remove this test's stub dir. Safe if setup partially ran.
acq_teardown_stubs() {
  cleanup_stubs || true
}
