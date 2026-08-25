#!/usr/bin/env bash
#
# 20-backend-resolution — backend resolution order + PATH self-repair
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 2. Backend resolution order
# ===========================================================================

# 2a. --backend flag takes highest priority.
make_stubs; load_acq
# Resolve via explicit flag.
unset ACQ_BACKEND 2>/dev/null || true
( unset ACQ_BACKEND 2>/dev/null || true
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  set +e
  acq_resolve_backend "sbx"
  assert_eq "backend: flag sets resolved" "sbx" "$ACQ_RESOLVED_BACKEND"
) 2>/dev/null; pass "backend: --backend flag accepted (sbx)"
cleanup_stubs

# 2b. ACQ_BACKEND env var.
make_stubs; load_acq
(
  ACQ_BACKEND="sbx"
  export ACQ_BACKEND
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  set +e
  unset explicit 2>/dev/null || true
  acq_resolve_backend ""
  assert_eq "backend: env var" "sbx" "$ACQ_RESOLVED_BACKEND"
) 2>/dev/null; pass "backend: ACQ_BACKEND env var accepted"
cleanup_stubs

# 2c. XDG config file.
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/config"
  mkdir -p "$XDG_CONFIG_HOME/acq"
  printf 'backend: sbx\n' > "$XDG_CONFIG_HOME/acq/config.yaml"
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  set +e
  acq_resolve_backend ""
  assert_eq "backend: XDG config" "sbx" "$ACQ_RESOLVED_BACKEND"
) 2>/dev/null; pass "backend: XDG config file accepted"
cleanup_stubs

# 2d. Auto-detect (only sbx on PATH -> sbx, with msb-nudge notice).
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  # Pin exactly which backends auto-detect "sees" via the test override, rather
  # than manipulating PATH: a developer's real msb/sbx share PATH dirs with the
  # coreutils the sourced scripts need (e.g. Homebrew's `env` sits beside
  # `msb`), so PATH tricks either leak a real backend or break the harness.
  export ACQ_TEST_INSTALLED_BACKENDS="sbx"
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  set +e
  # Run in THIS subshell (not a command-substitution) so ACQ_RESOLVED_BACKEND
  # is observable; capture the stderr notice to a file.
  acq_resolve_backend "" 2>"$STUBDIR/note"
  note=$(cat "$STUBDIR/note")
  assert_eq "backend: auto-detect sbx" "sbx" "$ACQ_RESOLVED_BACKEND"
  assert_contains "backend: sbx-only nudges toward msb" "$note" "msb is now the default"
) 2>/dev/null; pass "backend: auto-detect sbx (only sbx on PATH) + nudge"
cleanup_stubs

# 2e. Auto-detect (only msb on PATH -> msb, NO notice — already on default).
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb"   # only msb "installed" (see 2d)
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  acq_resolve_backend "" 2>"$STUBDIR/note"
  note=$(cat "$STUBDIR/note")
  assert_eq "backend: auto-detect msb" "msb" "$ACQ_RESOLVED_BACKEND"
  assert_not_contains "backend: msb-only is silent" "$note" "acq: using"
) 2>/dev/null; pass "backend: auto-detect msb (only msb on PATH) is silent"
cleanup_stubs

# 2f. Auto-detect both installed, NO existing sbx sandboxes -> msb + notice.
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
  rm -f "$STUBDIR/.sandbox_list"   # sbx ls -q returns empty -> no sbx sandboxes
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  acq_resolve_backend "" 2>"$STUBDIR/note"
  note=$(cat "$STUBDIR/note")
  assert_eq "backend: both + no sbx sandboxes -> msb" "msb" "$ACQ_RESOLVED_BACKEND"
  assert_contains "backend: both-msb notice" "$note" "using msb, the default backend"
) 2>/dev/null; pass "backend: both installed, no sbx sandboxes -> msb + notice"
cleanup_stubs

# 2g. Auto-detect both installed, existing sbx sandboxes -> keep sbx + notice.
make_stubs; load_acq
(
  unset ACQ_BACKEND 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
  printf 'my-existing-box\n' > "$STUBDIR/.sandbox_list"  # sbx ls -q non-empty
  PATH="$STUBDIR:$PATH"; export PATH   # ensure the stub sbx (for `sbx ls -q`) wins
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/sbx.sh"
  set +e
  acq_resolve_backend "" 2>"$STUBDIR/note"
  note=$(cat "$STUBDIR/note")
  assert_eq "backend: both + sbx sandboxes -> sbx" "sbx" "$ACQ_RESOLVED_BACKEND"
  assert_contains "backend: both-sbx notice keeps sbx" "$note" "existing sbx sandboxes"
  assert_contains "backend: both-sbx notice names msb default" "$note" "msb is now the default"
) 2>/dev/null; pass "backend: both installed, sbx sandboxes -> sbx + notice"
cleanup_stubs

# 2h. Explicit selection is silent (no auto-detect nudge) even with both present.
make_stubs; load_acq
(
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  export ACQ_TEST_INSTALLED_BACKENDS="msb sbx"
  printf 'my-existing-box\n' > "$STUBDIR/.sandbox_list"
  ACQ_BACKEND="msb"; export ACQ_BACKEND
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  acq_resolve_backend "" 2>"$STUBDIR/note"
  note=$(cat "$STUBDIR/note")
  assert_eq "backend: explicit env wins" "msb" "$ACQ_RESOLVED_BACKEND"
  assert_not_contains "backend: explicit selection is silent" "$note" "acq: using"
) 2>/dev/null; pass "backend: explicit ACQ_BACKEND is silent (no nudge)"
cleanup_stubs

# 2i. PATH self-repair: a backend installed ONLY in ~/.local/bin (not on PATH)
#     is recovered by _ensure_local_bin_on_path — acq adds ~/.local/bin to PATH
#     for the run, prints a one-time durable-fix hint, and detection succeeds.
#     Regression guard for the "installed but not on PATH -> command not found"
#     bug: acq must self-repair rather than fail.
make_stubs; load_acq
(
  unset ACQ_BACKEND ACQ_TEST_INSTALLED_BACKENDS 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  # Put the msb stub ONLY in a fake ~/.local/bin, NOT on PATH.
  fake_home="$STUBDIR/home"
  mkdir -p "$fake_home/.local/bin"
  mv "$STUBDIR/msb" "$fake_home/.local/bin/msb"
  # PATH has coreutils but neither backend dir; HOME points at the fake home.
  _coreutils_dir=$(dirname "$(command -v env)")
  HOME="$fake_home"; export HOME
  PATH="$_coreutils_dir"; export PATH
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Reset the once-per-process announce guard: on a host where an earlier
  # parent-scope backend resolve already fired the durable-fix hint (a real
  # backend reachable only via ~/.local/bin), _ACQ_LOCAL_BIN_ANNOUNCED=1 is
  # inherited here and would silence the announce this test asserts. Clearing it
  # makes the test independent of parent process state (the macOS-only flake).
  _ACQ_LOCAL_BIN_ANNOUNCED=""
  set +e
  _backend_installed msb 2>"$STUBDIR/rep_note"
  rc=$?
  note=$(cat "$STUBDIR/rep_note")
  assert_eq "self-repair: backend in ~/.local/bin is detected" "0" "$rc"
  assert_contains "self-repair: ~/.local/bin added to PATH for this run" "$PATH" "$fake_home/.local/bin"
  assert_contains "self-repair: prints a durable-fix hint" "$note" "export PATH="
) 2>/dev/null; pass "self-repair: backend recovered from ~/.local/bin"
cleanup_stubs

# 2j. PATH self-repair applies on the EXPLICIT path too (not just auto-detect):
#     _load_backend_adapter recovers a pinned backend that lives only in
#     ~/.local/bin, so `--backend`/ACQ_BACKEND/config users are not left with
#     "command not found".
make_stubs; load_acq
(
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  fake_home="$STUBDIR/home2"
  mkdir -p "$fake_home/.local/bin"
  mv "$STUBDIR/msb" "$fake_home/.local/bin/msb"
  _coreutils_dir=$(dirname "$(command -v env)")
  HOME="$fake_home"; export HOME
  PATH="$_coreutils_dir"; export PATH
  ACQ_BACKEND="msb"; export ACQ_BACKEND
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  acq_resolve_backend "" >/dev/null 2>&1
  assert_eq "self-repair (explicit): resolved backend is msb" "msb" "$ACQ_RESOLVED_BACKEND"
  assert_contains "self-repair (explicit): msb now resolvable on PATH" "$(command -v msb 2>/dev/null)" "$fake_home/.local/bin/msb"
) 2>/dev/null; pass "self-repair: explicit backend recovered from ~/.local/bin"
cleanup_stubs

# 2k. The durable-fix hint is announced at most ONCE per process
#     (_ACQ_LOCAL_BIN_ANNOUNCED): a second recovery in the same process is silent.
make_stubs; load_acq
(
  unset ACQ_BACKEND ACQ_TEST_INSTALLED_BACKENDS 2>/dev/null || true
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  fake_home="$STUBDIR/home3"
  mkdir -p "$fake_home/.local/bin"
  mv "$STUBDIR/msb" "$fake_home/.local/bin/msb"
  _coreutils_dir=$(dirname "$(command -v env)")
  HOME="$fake_home"; export HOME
  PATH="$_coreutils_dir"; export PATH
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Clear the inherited once-per-process announce guard so the FIRST call below
  # is guaranteed to announce regardless of parent process state (see 2i).
  _ACQ_LOCAL_BIN_ANNOUNCED=""
  set +e
  _ensure_local_bin_on_path msb 2>"$STUBDIR/n1"    # first: prepends + announces
  _ensure_local_bin_on_path msb 2>"$STUBDIR/n2"    # second: already on PATH, silent
  assert_contains "self-repair: first call announces" "$(cat "$STUBDIR/n1")" "export PATH="
  assert_eq "self-repair: second call is silent" "" "$(cat "$STUBDIR/n2")"
) 2>/dev/null; pass "self-repair: durable-fix hint announced at most once per process"
cleanup_stubs

# 2l. _load_backend_adapter must NOT prepend ~/.local/bin when the backend is
#     already resolvable on PATH — a user-writable ~/.local/bin copy must never
#     shadow a legit system binary for what acq (and the agent) subsequently exec.
make_stubs; load_acq
(
  export XDG_CONFIG_HOME="$STUBDIR/noconfig"
  # System msb: keep the stub in $STUBDIR (on PATH). ALSO plant a decoy in
  # ~/.local/bin; if the gate is wrong it would jump ahead of the system copy.
  fake_home="$STUBDIR/home4"
  mkdir -p "$fake_home/.local/bin"
  printf '#!/bin/sh\necho DECOY\n' > "$fake_home/.local/bin/msb"
  chmod +x "$fake_home/.local/bin/msb"
  HOME="$fake_home"; export HOME
  PATH="$STUBDIR:$(dirname "$(command -v env)")"; export PATH
  ACQ_BACKEND="msb"; export ACQ_BACKEND
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  set +e
  acq_resolve_backend "" >/dev/null 2>&1
  # ~/.local/bin must NOT have been prepended (system msb already resolved).
  case ":$PATH:" in
    *":$fake_home/.local/bin:"*) resolved_shadow=yes ;;
    *) resolved_shadow=no ;;
  esac
  assert_eq "self-repair: does not shadow a system backend" "no" "$resolved_shadow"
  assert_eq "self-repair: system msb still first on PATH" "$STUBDIR/msb" "$(command -v msb)"
) 2>/dev/null; pass "self-repair: gated so it never shadows a system backend"
cleanup_stubs
