#!/usr/bin/env bats
#
# 20-backend-resolution.bats — bats pilot port of scripts/test-acq.d/20-backend-resolution.sh
#
# Pilot for ADR-0025. This is a CLI-/resolution-heavy part: it exercises acq's
# backend-resolution order (flag > env > XDG config > auto-detect) and PATH
# self-repair. Each @test runs in its own subshell (real isolation) with a fresh
# stub sandbox from setup(), and uses bats-assert for diagnostics.
#
# WHY THIS IS A BETTER SHAPE than the legacy part:
#   - The legacy tests wrap each case in `( … ) 2>/dev/null; pass "…"`, so the
#     outer `pass` fires UNCONDITIONALLY — an inner assertion failure could not
#     actually fail the suite (12 such cases in the original file). Here a failed
#     assert_* fails the @test, so the checks are real.
#   - No shared PASS/FAIL counter; bats tallies. No manual cleanup_stubs to forget.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Resolve the backend in-process and echo the result, so a `run` can assert on
# it. acq is sourced with ACQ_SOURCE_ONLY=1 (definitions only, no dispatch); the
# chosen adapter is sourced explicitly, mirroring load_acq's contract.
_resolve() { # ADAPTER EXPLICIT  -> prints "<resolved>|<stderr-note>"
  local adapter="$1" explicit="${2:-}"
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/acq.backends/${adapter}.sh"
  set +e
  acq_resolve_backend "$explicit" 2>"$STUBDIR/note"
  printf '%s' "$ACQ_RESOLVED_BACKEND"
}

@test "backend: --backend flag takes highest priority" {
  unset ACQ_BACKEND
  run _resolve sbx sbx
  assert_success
  assert_output 'sbx'
}

@test "backend: ACQ_BACKEND env var is honored" {
  export ACQ_BACKEND=sbx
  run _resolve sbx ''
  assert_success
  assert_output 'sbx'
}

@test "backend: XDG config file is honored" {
  unset ACQ_BACKEND
  export XDG_CONFIG_HOME="$STUBDIR/config"
  mkdir -p "$XDG_CONFIG_HOME/acq"
  printf 'backend: sbx\n' > "$XDG_CONFIG_HOME/acq/config.yaml"
  run _resolve sbx ''
  assert_success
  assert_output 'sbx'
}

@test "backend: auto-detect sbx-only resolves sbx and nudges toward msb" {
  unset ACQ_BACKEND
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="sbx"
  run _resolve sbx ''
  assert_success
  assert_output 'sbx'
  # The stderr notice was captured to $STUBDIR/note by _resolve.
  run cat "$STUBDIR/note"
  assert_output --partial 'msb is now the default'
}

@test "backend: auto-detect msb-only resolves msb and is silent" {
  unset ACQ_BACKEND
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb"
  run _resolve msb ''
  assert_success
  assert_output 'msb'
  run cat "$STUBDIR/note"
  refute_output --partial 'acq: using'
}

@test "backend: both installed, no sbx sandboxes -> msb + notice" {
  unset ACQ_BACKEND
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
  rm -f "$STUBDIR/.sandbox_list"
  run _resolve msb ''
  assert_success
  assert_output 'msb'
  run cat "$STUBDIR/note"
  assert_output --partial 'using msb, the default backend'
}

@test "backend: both installed, existing sbx sandboxes -> keep sbx + notice" {
  unset ACQ_BACKEND
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
  printf 'my-existing-box\n' > "$STUBDIR/.sandbox_list"
  export PATH="$STUBDIR:$PATH"
  run _resolve sbx ''
  assert_success
  assert_output 'sbx'
  run cat "$STUBDIR/note"
  assert_output --partial 'existing sbx sandboxes'
  assert_output --partial 'msb is now the default'
}

@test "backend: explicit ACQ_BACKEND is silent (no auto-detect nudge)" {
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
  printf 'my-existing-box\n' > "$STUBDIR/.sandbox_list"
  export ACQ_BACKEND=msb
  run _resolve msb ''
  assert_success
  assert_output 'msb'
  run cat "$STUBDIR/note"
  refute_output --partial 'acq: using'
}

# PATH self-repair: a backend installed ONLY in ~/.local/bin (off PATH) is
# recovered by _ensure_local_bin_on_path — added to PATH for the run with a
# one-time durable-fix hint. Regression guard for "installed but not on PATH".
@test "self-repair: backend in ~/.local/bin is detected + hinted" {
  unset ACQ_BACKEND ACQ_TEST_INSTALLED_BACKENDS
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  local fake_home="$STUBDIR/home"
  mkdir -p "$fake_home/.local/bin"
  mv "$STUBDIR/msb" "$fake_home/.local/bin/msb"
  local coreutils_path
  coreutils_path="$(_acq_coreutils_path)"
  export HOME="$fake_home"
  export PATH="$coreutils_path"
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  # shellcheck source=acq.backends/msb.sh
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _ACQ_LOCAL_BIN_ANNOUNCED=""
  set +e
  _backend_installed msb 2>"$STUBDIR/rep_note"
  assert_equal "$?" "0"
  # ~/.local/bin was prepended to PATH for this run.
  assert_equal "${PATH##*"$fake_home/.local/bin"*}" ""
  run cat "$STUBDIR/rep_note"
  assert_output --partial 'export PATH='
}

# Self-repair must NOT prepend ~/.local/bin when the backend is already on PATH
# — a user-writable copy must never shadow a system binary acq later execs.
@test "self-repair: does not shadow a system backend already on PATH" {
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  local fake_home="$STUBDIR/home4"
  mkdir -p "$fake_home/.local/bin"
  printf '#!/bin/sh\necho DECOY\n' > "$fake_home/.local/bin/msb"
  chmod +x "$fake_home/.local/bin/msb"
  export HOME="$fake_home"
  local coreutils_path
  coreutils_path="$(_acq_coreutils_path)"
  export PATH="$STUBDIR:$coreutils_path"
  export ACQ_BACKEND=msb
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  # shellcheck source=acq.backends/msb.sh
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  acq_resolve_backend "" >/dev/null 2>&1
  case ":$PATH:" in
    *":$fake_home/.local/bin:"*) resolved_shadow=yes ;;
    *) resolved_shadow=no ;;
  esac
  assert_equal "$resolved_shadow" "no"
  assert_equal "$(command -v msb)" "$STUBDIR/msb"
}
