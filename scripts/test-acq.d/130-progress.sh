#!/usr/bin/env bash
#
# 130-progress — progress feedback helpers (progress.sh)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 14. Progress feedback helpers (issue #287) — acq.backends/progress.sh
# ===========================================================================
# The suite captures stderr into a variable (a PIPE, not a TTY), which is
# exactly the condition under which the spinner MUST stay silent. So these run
# the helpers in-process with stderr captured and assert:
#   - acq_status ALWAYS prints its line (interactive + CI/piped)
#   - acq_spin_start degrades to a plain status line off-TTY (no animation)
#   - NO spinner frame chars, carriage returns, or cursor escapes leak
#   - acq_spin_stop is a safe no-op / idempotent (double-stop, stop-without-start)
#   - the frame selector picks braille for UTF-8 locales and ASCII otherwise
# Animation-on-a-real-TTY is verified out-of-band (a PTY harness); it cannot run
# inside this pipe-captured suite by construction.

# Load the module in a subshell so its trap installs / state don't touch the
# harness. Each helper block captures its own stderr.
_prog() { ( export ACQ_SCRIPT_DIR="$REPO_ROOT"; . "$REPO_ROOT/acq.backends/progress.sh"; "$@" ) 2>&1; }

# acq_status always prints.
_st=$(_prog acq_status "creating sandbox")
assert_contains "progress: acq_status prints its message" "$_st" "creating sandbox"
assert_contains "progress: acq_status uses the acq: prefix"  "$_st" "acq: creating sandbox"

# Off-TTY (captured), a start/stop pair emits a plain status line and NOTHING
# animated. Assert no frame chars (braille or ASCII), no carriage return, no
# ANSI cursor hide/show escape.
_run=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT"; unset LC_ALL LC_CTYPE; export LANG=en_US.UTF-8
          . "$REPO_ROOT/acq.backends/progress.sh"
          acq_spin_start "booting the sandbox"
          acq_spin_stop  "booting the sandbox"
          printf 'REACHED_END' ) 2>&1 )
assert_contains     "progress: spin_start degrades to a status line off-TTY" "$_run" "booting the sandbox"
assert_contains     "progress: start/stop returns control (no hang)"          "$_run" "REACHED_END"
assert_not_contains "progress: no braille frame leaks off-TTY"                "$_run" "⠋"
assert_not_contains "progress: no braille frame (alt) leaks off-TTY"          "$_run" "⠙"
assert_not_contains "progress: no carriage return leaks off-TTY"              "$_run" "$(printf '\r')"
assert_not_contains "progress: no cursor-hide escape leaks off-TTY"           "$_run" "$(printf '\033')[?25l"

# Explicit opt-out (ACQ_NO_PROGRESS) — same silence, even if a TTY were present.
_noprog=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT" ACQ_NO_PROGRESS=1
             . "$REPO_ROOT/acq.backends/progress.sh"
             acq_spin_start "installing agent"; acq_spin_stop "installing agent" ) 2>&1 )
assert_contains     "progress: ACQ_NO_PROGRESS still shows a status line" "$_noprog" "installing agent"
assert_not_contains "progress: ACQ_NO_PROGRESS emits no frames"           "$_noprog" "⠋"

# acq_spin_stop with no spinner running is a silent no-op (no error, no output).
_bare=$(_prog acq_spin_stop)
assert_eq "progress: spin_stop without start is silent" "" "$_bare"

# Double-stop is idempotent (no error, no stray output beyond the single line).
_dbl=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT" ACQ_NO_PROGRESS=1
          . "$REPO_ROOT/acq.backends/progress.sh"
          acq_spin_start "phase X"; acq_spin_stop "phase X"; acq_spin_stop "phase X"
          printf 'OK' ) 2>&1 )
assert_contains "progress: double spin_stop is safe" "$_dbl" "OK"

# Frame selector: braille for UTF-8, ASCII pipe/slash otherwise.
_utf=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT"; unset LC_ALL LC_CTYPE; export LANG=en_US.UTF-8
          . "$REPO_ROOT/acq.backends/progress.sh"; _acq_spin_frames ) )
assert_contains "progress: UTF-8 locale selects braille frames" "$_utf" "⠋"
_asc=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT"; unset LANG LC_CTYPE; export LC_ALL=C
          . "$REPO_ROOT/acq.backends/progress.sh"; _acq_spin_frames ) )
assert_contains     "progress: non-UTF-8 locale selects ASCII frames" "$_asc" "|"
assert_not_contains "progress: non-UTF-8 locale has no braille"       "$_asc" "⠋"

# Trap composition: a caller's PRE-EXISTING EXIT trap must SURVIVE a
# start/stop pair. This is the regression the reviewer proved — the spinner
# used to hard-overwrite the caller's EXIT trap, leaking a validation sandbox
# on Ctrl-C. Off-TTY, acq_spin_start degrades and never installs traps, so we
# call the trap install/restore bookkeeping DIRECTLY (it is TTY-independent) to
# exercise the composition/restore logic itself. First: a sentinel EXIT trap
# survives install+restore, and no lingering spinner trap is left after restore.
_trap=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT"
           . "$REPO_ROOT/acq.backends/progress.sh"
           trap 'echo SENTINEL_CLEANUP' EXIT
           _acq_spin_install_traps       # compose over the sentinel
           _acq_spin_restore_traps       # restore on normal stop
           # Print the EXIT trap still installed after restore.
           trap -p EXIT ) 2>&1 )
assert_contains "progress: pre-existing EXIT trap survives spin install/restore" \
  "$_trap" "SENTINEL_CLEANUP"
assert_not_contains "progress: no lingering spinner EXIT trap after restore" \
  "$_trap" "_acq_spin_cleanup_exit"

# Second: while the spinner trap is composed IN (before restore), a triggered
# EXIT cleanup must still RE-INVOKE the caller's prior handler (so `sbx rm`
# runs on Ctrl-C). Install the sentinel, compose, then fire the cleanup and
# assert the sentinel command actually ran.
_trap_fire=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT"
                . "$REPO_ROOT/acq.backends/progress.sh"
                trap 'echo SENTINEL_RAN' EXIT
                _acq_spin_install_traps
                _acq_spin_cleanup_exit ) 2>&1 )
assert_contains "progress: composed EXIT cleanup re-invokes prior handler" \
  "$_trap_fire" "SENTINEL_RAN"

# And with NO prior EXIT trap, restore clears our trap (no lingering spinner
# trap, no error).
_trap_none=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT"
                . "$REPO_ROOT/acq.backends/progress.sh"
                _acq_spin_install_traps
                _acq_spin_restore_traps
                trap -p EXIT
                printf 'NONE_OK' ) 2>&1 )
assert_contains     "progress: restore with no prior trap is clean" "$_trap_none" "NONE_OK"
assert_not_contains "progress: restore with no prior trap leaves no spinner trap" \
  "$_trap_none" "_acq_spin_cleanup_exit"

# Escape sanitization: a control byte in a message (e.g. from an untrusted
# --name reaching the spinner before validation) must NOT reach the terminal
# raw. Assert the captured stderr has no ESC byte; printable letters may remain.
_esc=$( ( export ACQ_SCRIPT_DIR="$REPO_ROOT"
          . "$REPO_ROOT/acq.backends/progress.sh"
          acq_status "$(printf 'evil\033[2J\033[Hgotcha')" ) 2>&1 )
assert_not_contains "progress: acq_status strips raw ESC control byte" \
  "$_esc" "$(printf '\033')"
assert_contains     "progress: acq_status keeps printable message text" \
  "$_esc" "gotcha"

unset -f _prog
unset _st _run _noprog _bare _dbl _utf _asc _trap _trap_fire _trap_none _esc
