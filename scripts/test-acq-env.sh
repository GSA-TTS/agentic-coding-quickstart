#!/usr/bin/env bash
# Resolve host runtime shims before fixture setup replaces HOME. No installer
# is allowed to provision tools as a side effect of running the offline suite.
acq_test_prepare_environment() {
  local runtime physical_tmp
  runtime=$(MISE_AUTO_INSTALL=0 python3 -c 'import os, sys; print(os.path.realpath(sys.executable))') || {
    echo "test-acq: a preinstalled Python 3 runtime is required" >&2
    return 1
  }
  [ -x "$runtime" ] || return 1
  physical_tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return 1
  export ACQ_TEST_HOST_PYTHON="$runtime"
  export TMPDIR="$physical_tmp"
  export PATH="${runtime%/*}:$PATH"
  export MISE_AUTO_INSTALL=0
  # Fixture repositories are local. Never turn a missing stub into an HTTPS,
  # SSH, or external-helper fetch against a developer's configured credentials.
  export GIT_ALLOW_PROTOCOL=file
}
