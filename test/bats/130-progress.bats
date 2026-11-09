#!/usr/bin/env bats
#
# 130-progress.bats — bats port of scripts/test-acq.d/130-progress.sh (issue #287,
# ADR-0025)
#
# Progress-feedback helpers (acq.backends/progress.sh). bats' `run` captures
# output from a PIPE (not a TTY) — exactly the condition under which the spinner
# MUST stay silent — so we drive each helper with `run bash -c` and assert:
#   - acq_status always prints its "acq: <msg>" line
#   - acq_spin_start degrades to a plain status line off-TTY (no animation)
#   - no braille/ASCII frame, carriage return, or cursor escape leaks
#   - acq_spin_stop is a safe no-op / idempotent
#   - the frame selector picks braille for UTF-8, ASCII otherwise
#   - a caller's pre-existing EXIT trap survives install/restore and re-fires
#   - acq_status strips raw ESC control bytes
# Animation on a real TTY is verified out-of-band (a PTY harness), not here.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Run body with progress.sh sourced in a clean subshell; stderr folded into output.
_prog() { # SHELL_SNIPPET
  run bash -c '
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/progress.sh"
    '"$1"'
  ' 2>&1
}

@test "progress: acq_status always prints with the acq: prefix" {
  _prog 'acq_status "creating sandbox"'
  assert_output --partial 'creating sandbox'
  assert_output --partial 'acq: creating sandbox'
}

@test "progress: spin_start degrades to a status line off-TTY, nothing animated" {
  _prog 'unset LC_ALL LC_CTYPE; export LANG=en_US.UTF-8
    acq_spin_start "booting the sandbox"
    acq_spin_stop  "booting the sandbox"
    printf "REACHED_END"'
  assert_output --partial 'booting the sandbox'
  assert_output --partial 'REACHED_END'
  refute_output --partial '⠋'
  refute_output --partial '⠙'
  refute_output --partial "$(printf '\r')"
  refute_output --partial "$(printf '\033')[?25l"
}

@test "progress: ACQ_NO_PROGRESS shows a status line but no frames" {
  _prog 'export ACQ_NO_PROGRESS=1
    acq_spin_start "installing agent"; acq_spin_stop "installing agent"'
  assert_output --partial 'installing agent'
  refute_output --partial '⠋'
}

@test "progress: spin_stop without start is silent; double-stop is safe" {
  _prog 'acq_spin_stop'
  assert_output ''
  _prog 'export ACQ_NO_PROGRESS=1
    acq_spin_start "phase X"; acq_spin_stop "phase X"; acq_spin_stop "phase X"
    printf "OK"'
  assert_output --partial 'OK'
}

@test "progress: frame selector picks braille for UTF-8, ASCII otherwise" {
  _prog 'unset LC_ALL LC_CTYPE; export LANG=en_US.UTF-8; _acq_spin_frames'
  assert_output --partial '⠋'
  _prog 'unset LANG LC_CTYPE; export LC_ALL=C; _acq_spin_frames'
  assert_output --partial '|'
  refute_output --partial '⠋'
}

@test "progress: a pre-existing EXIT trap survives spin install/restore" {
  _prog 'trap "echo SENTINEL_CLEANUP" EXIT
    _acq_spin_install_traps
    _acq_spin_restore_traps
    trap -p EXIT'
  assert_output --partial 'SENTINEL_CLEANUP'
  refute_output --partial '_acq_spin_cleanup_exit'
}

@test "progress: composed EXIT cleanup re-invokes the caller's prior handler" {
  _prog 'trap "echo SENTINEL_RAN" EXIT
    _acq_spin_install_traps
    _acq_spin_cleanup_exit'
  assert_output --partial 'SENTINEL_RAN'
}

@test "progress: restore with no prior EXIT trap is clean" {
  _prog '_acq_spin_install_traps
    _acq_spin_restore_traps
    trap -p EXIT
    printf "NONE_OK"'
  assert_output --partial 'NONE_OK'
  refute_output --partial '_acq_spin_cleanup_exit'
}

@test "progress: acq_status strips raw ESC control bytes but keeps text" {
  _prog 'acq_status "$(printf "evil\033[2J\033[Hgotcha")"'
  refute_output --partial "$(printf '\033')"
  assert_output --partial 'gotcha'
}

# Trap capture must not depend on how `trap -p` spells the signal: bash prints
# `SIGINT`/`SIGTERM` normally (3.2 and 5.x) but `INT`/`TERM` in POSIX mode. The
# captured command is re-installed and re-invoked verbatim, so a leftover signal
# name would corrupt it (e.g. `handler 130` becoming `handler 130SIGINT`).
@test "progress: prior INT/TERM trap commands are captured without the signal name" {
  _prog 'trap "handler 130" INT; trap "handler 143" TERM
    printf "INT=[%s]\n" "$(_acq_capture_prior_trap INT)"
    printf "TERM=[%s]\n" "$(_acq_capture_prior_trap TERM)"
    set -o posix
    printf "PINT=[%s]\n" "$(_acq_capture_prior_trap INT)"
    trap - TERM
    printf "PUNSET=[%s]\n" "$(_acq_capture_prior_trap TERM)"'
  assert_line 'INT=[handler 130]'
  assert_line 'TERM=[handler 143]'
  assert_line 'PINT=[handler 130]'
  assert_line 'PUNSET=[]'
}

@test "progress: capture round-trips a trap command with quotes and newlines" {
  # Build the awkward command outside the snippet to avoid nested shell quoting.
  export TRAP_CMD_FILE="$STUBDIR/trap-cmd"
  printf '%s\n%s' "echo \"it's\" '\$x' \"\$HOME\"" 'echo two' > "$TRAP_CMD_FILE"
  _prog 'cmd=$(cat "$TRAP_CMD_FILE"); trap "$cmd" INT
    got=$(_acq_capture_prior_trap INT)
    if [ "$got" = "$cmd" ]; then echo ROUNDTRIP_OK; else printf "GOT=[%s]\n" "$got"; fi'
  assert_output 'ROUNDTRIP_OK'
}

@test "progress: spin install/restore puts back the exact prior INT and TERM traps" {
  _prog 'trap "handler 130" INT; trap "handler 143" TERM
    _acq_spin_install_traps
    _acq_spin_restore_traps
    trap -p INT; trap -p TERM'
  assert_line --regexp "^trap -- 'handler 130' (SIG)?INT\$"
  assert_line --regexp "^trap -- 'handler 143' (SIG)?TERM\$"
}

@test "progress: Ctrl-C chains the prior INT handler with its exact arguments" {
  _prog 'handler() { printf "HANDLER_ARGS=[%s]\n" "$*"; }
    trap "handler 130" INT
    _acq_spin_install_traps
    _acq_spin_cleanup_signal INT
    printf "NOT_REACHED\n"'
  assert_equal "$status" 130
  assert_line 'HANDLER_ARGS=[130]'
  refute_output --partial 'NOT_REACHED'
}

@test "progress: spin install/restore keeps an ignored INT ignored" {
  _prog 'trap "" INT
    _acq_spin_install_traps
    _acq_spin_restore_traps
    trap -p INT'
  assert_output --regexp "^trap -- '' (SIG)?INT\$"
}

@test "progress: Ctrl-C resets INT before the prior handler, so a re-raise cannot recurse" {
  export PRIOR_COUNT="$STUBDIR/prior-count"
  _prog 'prior() { echo ran >> "$PRIOR_COUNT"; [ "$(wc -l < "$PRIOR_COUNT")" -ge 3 ] || kill -s INT $$; }
    trap prior INT
    _acq_spin_install_traps
    _acq_spin_cleanup_signal INT
    printf "NOT_REACHED\n"'
  assert_equal "$status" 130
  refute_output --partial 'NOT_REACHED'
  assert_equal "$(wc -l < "$STUBDIR/prior-count" | tr -d ' ')" 1
}

# The provisioning subshells in sbx.sh and msb.sh install an EXIT trap of the
# form `rc=$?; cleanup; exit "$rc"`. With the spinner composed over it, that
# handler must still see the status the subshell is exiting with, or a failed
# provision would be reported as a success.
@test "progress: composed EXIT cleanup hands the real exit status to the prior handler" {
  _prog '( trap '"'"'rc=$?; echo "PRIOR_RC=$rc"; exit "$rc"'"'"' EXIT
      _acq_spin_install_traps
      exit 3 )
    echo "SUB_RC=$?"'
  assert_line 'PRIOR_RC=3'
  assert_line 'SUB_RC=3'
}

@test "progress: exit status survives the composed EXIT cleanup under set -e" {
  _prog 'set -e
    ( trap '"'"'rc=$?; echo "PRIOR_RC=$rc"; exit "$rc"'"'"' EXIT
      _acq_spin_install_traps
      exit 3 ) || echo "SUB_RC=$?"'
  assert_line 'PRIOR_RC=3'
  assert_line 'SUB_RC=3'
}

# Ctrl-C inside such a subshell must run the chained INT handler (once), and its
# exit must reach the prior EXIT handler with status 130.
@test "progress: Ctrl-C in a subshell runs the prior INT handler before the EXIT cleanup" {
  _prog '( trap '"'"'rc=$?; echo "EXIT_RC=$rc"; exit "$rc"'"'"' EXIT
      trap '"'"'echo INT_HANDLER; exit 130'"'"' INT
      _acq_spin_install_traps
      kill -s INT "$(exec sh -c '"'"'echo "$PPID"'"'"')"
      echo NOT_REACHED )
    echo "SUB_RC=$?"'
  assert_line 'EXIT_RC=130'
  assert_line 'SUB_RC=130'
  assert_equal "$(grep -c INT_HANDLER <<<"$output")" 1
  refute_output --partial 'NOT_REACHED'
}

# With no prior handler the signal is re-raised. In a subshell `$$` is the
# PARENT's PID, so the re-raise must target the subshell itself.
@test "progress: the signal re-raise targets the subshell, not the parent" {
  _prog '( _acq_spin_install_traps
      _acq_spin_cleanup_signal TERM
      echo NOT_REACHED )
    echo "SUB_RC=$?"'
  # Line match: the shell's "Terminated" job notice echoes the command text.
  assert_line 'SUB_RC=143'
  refute_line 'NOT_REACHED'
}

@test "progress: re-raise with no prior INT handler still runs the prior EXIT handler once" {
  _prog '( trap '"'"'echo "EXIT_RC=$?"'"'"' EXIT
      _acq_spin_install_traps
      _acq_spin_cleanup_signal INT
      echo NOT_REACHED )
    echo "SUB_RC=$?"'
  assert_line 'EXIT_RC=130'
  assert_line 'SUB_RC=130'
  assert_equal "$(grep -c EXIT_RC <<<"$output")" 1
  refute_output --partial 'NOT_REACHED'
}
