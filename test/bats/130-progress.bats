#!/usr/bin/env bats
#
# 130-progress.bats — bats port of scripts/test-acq.d/130-progress.sh (ADR-0025)
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

@test "progress: Ctrl-C guards INT through the prior handler, so a re-raise cannot recurse" {
  export PRIOR_COUNT="$STUBDIR/prior-count"
  _prog 'prior() { echo ran >> "$PRIOR_COUNT"; [ "$(wc -l < "$PRIOR_COUNT")" -ge 3 ] || kill -s INT $$; }
    trap "echo PRIOR_EXIT=\$?" EXIT
    trap prior INT
    _acq_spin_install_traps
    _acq_spin_cleanup_signal INT
    printf "NOT_REACHED\n"'
  assert_equal "$status" 130
  assert_line 'PRIOR_EXIT=130'
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

@test "progress: the prior INT/TERM handler runs with \$? set to 130/143" {
  # The TERM case runs in its own subshell, which installs the traps itself: the
  # handlers act only in the shell that installed them (next test).
  _prog 'h() { echo "STATUS_$1=$?"; }
    ( trap "h TERM" TERM; _acq_spin_install_traps; _acq_spin_cleanup_signal TERM )
    trap "h INT" INT; trap "h TERM" TERM
    _acq_spin_install_traps
    _acq_spin_cleanup_signal INT'
  assert_line 'STATUS_TERM=143'
  assert_line 'STATUS_INT=130'
}

# A child forked while the spinner's traps are set can run them: a signal that
# reaches it before Bash resets its inherited handlers is handled with the
# parent's trap commands, and Bash 5 then also runs the parent's EXIT trap. The
# spinner TERMs its animator straight after forking it, so this happened under
# load and ran the caller's EXIT cleanup twice. Call the handlers from a child
# directly, as that window does: the child must exit without running any prior
# handler or touching the owner's animator, and the owner's own exit must still
# run the prior EXIT handler exactly once with its status.
@test "progress: a child that inherits the spinner traps never runs the prior handlers" {
  # The animator PID is one known to be dead (a reaped child), so a regression
  # that signalled it from the child could never reach a live process.
  _prog '( : ) & dead=$!; wait "$dead"
    trap "echo PRIOR_EXIT=\$?" EXIT
    trap "echo PRIOR_TERM; exit 143" TERM
    trap "echo PRIOR_INT; exit 130" INT
    _acq_spin_install_traps
    _ACQ_SPIN_ACTIVE=1 _ACQ_SPIN_PID=$dead
    ( _acq_spin_cleanup_signal TERM; echo NOT_REACHED_TERM ); echo "CHILD_TERM_RC=$?"
    ( _acq_spin_cleanup_signal INT; echo NOT_REACHED_INT ); echo "CHILD_INT_RC=$?"
    ( _acq_spin_cleanup_exit 3; echo "CHILD_EXIT_RET=$?" )
    [ "$_ACQ_SPIN_PID" = "$dead" ] && echo OWNER_STATE_KEPT
    _ACQ_SPIN_ACTIVE="" _ACQ_SPIN_PID=""
    exit 3'
  assert_failure 3
  assert_line 'CHILD_TERM_RC=143'
  assert_line 'CHILD_INT_RC=130'
  assert_line 'CHILD_EXIT_RET=0'
  assert_line 'OWNER_STATE_KEPT'
  assert_line 'PRIOR_EXIT=3'
  assert_equal "$(grep -c PRIOR_EXIT <<<"$output")" 1
  refute_output --partial 'PRIOR_TERM'
  refute_output --partial 'PRIOR_INT'
  refute_output --partial 'NOT_REACHED'
}

# On Bash 3.2 the owner check learns its PID by forking `sh`. If that fork fails
# (a process limit), the PID is unknown, and the shell that installed the traps
# must still count as the owner and run the caller's EXIT cleanup. The failed
# lookup is modelled by a _acq_spin_self_pid that finds nothing.
@test "progress: an unknown PID counts as the owner, so the caller's EXIT cleanup still runs" {
  _prog 'trap "echo PRIOR_EXIT=\$?" EXIT
    _acq_spin_install_traps
    _acq_spin_self_pid() { _ACQ_SPIN_SELF_PID=""; }
    _acq_spin_is_owner && echo OWNER
    exit 4'
  assert_failure 4
  assert_line 'OWNER'
  assert_line 'PRIOR_EXIT=4'
}

# With no prior handler the subshell must die BY the signal, not merely exit
# 128+N. Bash makes that observable: it prints a "Terminated" notice for a
# foreground child killed by TERM, `wait` reports 128+N for a background one,
# and a `$(...)` killed by SIGINT makes the parent take SIGINT too (here, run
# its INT trap).
@test "progress: the re-raise is a real death by signal" {
  _prog '( _acq_spin_install_traps; _acq_spin_cleanup_signal TERM )
    echo "FG_RC=$?"
    ( _acq_spin_install_traps; _acq_spin_cleanup_signal TERM ) &
    wait "$!"; echo "WAIT_RC=$?"
    trap "echo PARENT_INT" INT
    out=$(trap - INT; _acq_spin_install_traps; _acq_spin_cleanup_signal INT)
    echo "COMSUB_RC=$?"'
  assert_output --partial 'Terminated'
  assert_line 'FG_RC=143'
  assert_line 'WAIT_RC=143'
  assert_line 'PARENT_INT'
  assert_line 'COMSUB_RC=130'
}

# Bash 5.2 can lose a child that exits while a trap runs, so `wait <animator>`
# in the Ctrl-C cleanup could block forever (seen as create-signal.py's sbx
# Ctrl-C case timing out under load). Stopping the animator must therefore not
# use the `wait` builtin, on the normal stop path or in the signal cleanup, and
# must still return only once the animator is gone, with no "Terminated" job
# notice for it (Bash 3.2 prints one for a child killed by TERM).
@test "progress: stopping the animator never uses the wait builtin, and it is gone afterwards" {
  local pids="$STUBDIR/animators"
  _prog '_acq_progress_enabled() { return 0; }
    wait() { echo "WAIT-BUILTIN $*"; builtin wait "$@"; }
    acq_spin_start "phase one"
    printf "%s\n" "$_ACQ_SPIN_PID" >> "'"$pids"'"
    sleep 0.3
    acq_spin_stop
    kill -0 "$(tail -n 1 "'"$pids"'")" 2>/dev/null && echo "ANIMATOR-ALIVE-AFTER-STOP"
    sleep 0.3
    acq_spin_start "phase two"
    printf "%s\n" "$_ACQ_SPIN_PID" >> "'"$pids"'"
    sleep 0.3
    _acq_spin_cleanup_signal TERM'
  assert_equal "$status" 143
  refute_output --partial 'WAIT-BUILTIN'
  refute_output --partial 'ANIMATOR-ALIVE'
  refute_output --partial 'Terminated'
  local pid
  while IFS= read -r pid; do
    run kill -0 "$pid"
    assert_failure
  done < "$pids"
}

# An animator that is not scheduled for a while can be in the middle of a draw
# with the TERM still pending, and write its frame whenever it next runs. If
# the stop returned before that, the frame would land on whatever acq printed
# next (an attached session). Model the unscheduled animator by stopping it
# (SIGSTOP) inside its first draw for three seconds, longer than the stop's
# two-second wait for an exit: the stop must not return while the animator
# can still draw, nothing may be drawn after it returns, and the spinner's
# private directory must be gone afterwards.
@test "progress: a stop never returns while a suspended animator can still draw" {
  local mark="$STUBDIR/animator-stopped" spintmp="$STUBDIR/spintmp"
  mkdir -p "$spintmp"
  _prog '_acq_progress_enabled() { return 0; }
    export TMPDIR="'"$spintmp"'"
    printf() {
      if [ "$1" = "\r%s %s" ] && mkdir "'"$mark"'" 2>/dev/null; then
        sh -c "kill -STOP \$PPID"
      fi
      builtin printf "$@"
    }
    acq_spin_start "phase one"
    anim=$_ACQ_SPIN_PID
    i=0
    while [ ! -d "'"$mark"'" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
    sleep 0.3
    ( sleep 3; echo "CONTINUED" >&2; kill -CONT "$anim" ) &
    resume=$!
    acq_spin_stop
    echo "STOP-RETURNED" >&2
    builtin wait "$resume"
    sleep 0.5
    kill -0 "$anim" 2>/dev/null && echo "ANIMATOR-ALIVE"
    ls "'"$spintmp"'"'
  assert_success
  [ -d "$mark" ]
  [[ "$output" == *CONTINUED*STOP-RETURNED* ]]
  local after="${output##*STOP-RETURNED}"
  [[ "$after" != *"phase one"* ]]
  refute_output --partial 'ANIMATOR-ALIVE'
  refute_output --partial 'acq-spin.'
}

# The same guarantee where mkdir is not exclusive (uutils coreutils mkdir 0.10
# reports success to concurrent callers; KNOWN_FAILURE_MODES section 92). The
# mkdir first on PATH here reports success for a directory that already exists,
# so a draw lock decided by mkdir would let the stop take it while the
# suspended animator still holds it, and return early.
@test "progress: a non-exclusive mkdir never lets the stop share the draw lock" {
  local mark="$STUBDIR/animator-stopped" spintmp="$STUBDIR/spintmp" real
  real=$(command -v mkdir)
  mkdir -p "$spintmp" "$STUBDIR/racy-mkdir"
  printf '#!/bin/sh\n"%s" "$@" 2>/dev/null && exit 0\nfor last; do :; done\n[ -d "$last" ]\n' "$real" \
    > "$STUBDIR/racy-mkdir/mkdir"
  chmod +x "$STUBDIR/racy-mkdir/mkdir"
  _prog '_acq_progress_enabled() { return 0; }
    export TMPDIR="'"$spintmp"'" PATH="'"$STUBDIR"'/racy-mkdir:$PATH"
    printf() {
      if [ "$1" = "\r%s %s" ] && "'"$real"'" "'"$mark"'" 2>/dev/null; then
        sh -c "kill -STOP \$PPID"
      fi
      builtin printf "$@"
    }
    acq_spin_start "phase one"
    anim=$_ACQ_SPIN_PID
    i=0
    while [ ! -d "'"$mark"'" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
    sleep 0.3
    ( sleep 3; echo "CONTINUED" >&2; kill -CONT "$anim" ) &
    resume=$!
    acq_spin_stop
    echo "STOP-RETURNED" >&2
    builtin wait "$resume"
    sleep 0.5
    kill -0 "$anim" 2>/dev/null && echo "ANIMATOR-ALIVE"
    ls "'"$spintmp"'"'
  assert_success
  [ -d "$mark" ]
  [[ "$output" == *CONTINUED*STOP-RETURNED* ]]
  local after="${output##*STOP-RETURNED}"
  [[ "$after" != *"phase one"* ]]
  refute_output --partial 'ANIMATOR-ALIVE'
  refute_output --partial 'acq-spin.'
}

# The shell snippet shared by the next tests: an animated spinner whose animator
# suspends itself (SIGSTOP) inside its first draw, holding the draw lock. It
# leaves the animator's PID in $anim. $1 is the marker directory, $2 TMPDIR.
_suspended_spinner() {
  printf '%s' '_acq_progress_enabled() { return 0; }
    export TMPDIR="'"$2"'"
    printf() {
      if [ "$1" = "\r%s %s" ] && mkdir "'"$1"'" 2>/dev/null; then
        sh -c "kill -STOP \$PPID"
      fi
      builtin printf "$@"
    }
    acq_spin_start "phase one"
    anim=$_ACQ_SPIN_PID
    i=0
    while [ ! -d "'"$1"'" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
    sleep 0.3
'
}

# A signal that lands while the stop waits for the draw lock runs the stop again
# from the trap. That second run must wait as well, not find the spinner state
# already cleared and return at once; and the trap's output (the caller's
# handler, the cursor restore) must still reach the terminal.
@test "progress: a signal during the stop's wait still waits for the draw lock" {
  local mark="$STUBDIR/animator-stopped" spintmp="$STUBDIR/spintmp"
  mkdir -p "$spintmp"
  _prog 'trap "echo PRIOR_INT >&2; exit 130" INT
    '"$(_suspended_spinner "$mark" "$spintmp")"'
    self=$(exec sh -c "echo \$PPID")
    ( sleep 1; kill -INT "$self"; sleep 2; echo "CONTINUED" >&2; kill -CONT "$anim" ) &
    acq_spin_stop
    echo "NOT-REACHED" >&2'
  assert_equal "$status" 130
  [ -d "$mark" ]
  [[ "$output" == *CONTINUED*PRIOR_INT* ]]
  [[ "$output" == *$'\033[?25h'* ]]
  local after="${output##*PRIOR_INT}"
  [[ "$after" != *"phase one"* ]]
  refute_output --partial 'NOT-REACHED'
}

# An animator suspended for good while holding the lock must not hang the stop:
# the wait is capped (about 30 s; `sleep` is shadowed here to advance SECONDS so
# the cap arrives at once). Resumed later, the animator ends by itself and
# removes its directory.
@test "progress: the stop's wait for a suspended animator is capped" {
  local mark="$STUBDIR/animator-stopped" spintmp="$STUBDIR/spintmp"
  mkdir -p "$spintmp"
  run timeout 60 bash -c '
    . "'"$REPO_ROOT"'/acq.backends/progress.sh"
    '"$(_suspended_spinner "$mark" "$spintmp")"'
    sleep() { SECONDS=$((SECONDS + 10)); command sleep "$@"; }
    acq_spin_stop
    echo "STOP-RETURNED" >&2
    unset -f sleep
    kill -0 "$anim" 2>/dev/null && echo "ANIMATOR-STILL-SUSPENDED"
    kill -CONT "$anim"
    i=0
    while kill -0 "$anim" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    kill -0 "$anim" 2>/dev/null && echo "ANIMATOR-ALIVE"
    ls "'"$spintmp"'"' 2>&1
  assert_success
  assert_output --partial 'STOP-RETURNED'
  assert_output --partial 'ANIMATOR-STILL-SUSPENDED'
  refute_output --partial 'ANIMATOR-ALIVE'
  refute_output --partial 'acq-spin.'
}

# A signal after the directory is recorded but before the animator is forked
# leaves no PID. With no animator possible the cleanup removes the directory;
# once an animator may exist (forked, PID not yet recorded) it takes the draw
# lock, sets the stop marker and leaves the directory for the animator to remove.
# Bash 5 runs the INT trap again for a second Ctrl-C during the first one's wait
# for the animator. The nested run must return and leave the outer one to run
# the prior INT handler (in acq, the provisioning subshell's handler, which
# stops the backend child before the lock is released).
@test "progress: a second Ctrl-C during the stop's wait still runs the prior INT handler" {
  local mark="$STUBDIR/animator-stopped" spintmp="$STUBDIR/spintmp"
  mkdir -p "$spintmp"
  _prog 'trap "echo PRIOR_INT >&2; exit 130" INT
    trap "echo PRIOR_EXIT=\$? >&2" EXIT
    '"$(_suspended_spinner "$mark" "$spintmp")"'
    self=$(exec sh -c "echo \$PPID")
    ( sleep 1; kill -INT "$self"; sleep 0.3; kill -INT "$self"; sleep 1.5
      echo "CONTINUED" >&2; kill -CONT "$anim" ) &
    acq_spin_stop
    echo "NOT-REACHED" >&2'
  assert_equal "$status" 130
  [ -d "$mark" ]
  assert_output --partial 'PRIOR_INT'
  assert_line 'PRIOR_EXIT=130'
  [[ "$output" == *CONTINUED*PRIOR_INT* ]]
  refute_output --partial 'NOT-REACHED'
}

# The animator quits when it sees the stop marker. If the marker cannot be
# written (here, the directory is made read-only), only a TERM can end it, so
# the stop sends one rather than wait out its cap and leave the animator
# polling for the rest of the session.
@test "progress: the stop sends TERM when it cannot write the stop marker" {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) skip "chmod cannot make a directory read-only here" ;;
  esac
  [ "$(id -u)" != 0 ] || skip "root writes into a read-only directory"
  _prog '_acq_progress_enabled() { return 0; }
    acq_spin_start "phase one"
    anim=$_ACQ_SPIN_PID d=$_ACQ_SPIN_DIR
    sleep 0.3
    chmod 500 "$d"
    SECONDS=0
    acq_spin_stop
    echo "STOP-SECONDS=$SECONDS"
    i=0
    while kill -0 "$anim" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
    kill -0 "$anim" 2>/dev/null && { echo "ANIMATOR-ALIVE"; kill "$anim"; }
    chmod 700 "$d"; rm -rf "$d"'
  assert_success
  refute_output --partial 'ANIMATOR-ALIVE'
  assert_regex "$output" 'STOP-SECONDS=[0-3]'$'\n'
}

# A hangup reaches the animator too (it is in the terminal's process group): it
# must end through its own cleanup and remove its private directory.
@test "progress: a hangup ends the animator and removes its directory" {
  _prog '_acq_progress_enabled() { return 0; }
    acq_spin_start "phase one"
    anim=$_ACQ_SPIN_PID d=$_ACQ_SPIN_DIR
    sleep 0.3
    kill -HUP "$anim"
    i=0
    while kill -0 "$anim" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
    kill -0 "$anim" 2>/dev/null && echo "ANIMATOR-ALIVE"
    [ -e "$d" ] && echo "DIR-LEFT"
    acq_spin_stop 2>/dev/null'
  assert_success
  refute_output --partial 'ANIMATOR-ALIVE'
  refute_output --partial 'DIR-LEFT'
}

@test "progress: the cleanup removes the directory when no animator was started" {
  _prog '_acq_spin_install_traps
    d=$(mktemp -d "'"$STUBDIR"'/acq-spin.XXXXXX")
    _ACQ_SPIN_DIR=$d _ACQ_SPIN_ACTIVE=1
    _acq_spin_stop_animation 2>/dev/null
    [ -e "$d" ] && echo "UNSTARTED-KEPT"
    d=$(mktemp -d "'"$STUBDIR"'/acq-spin.XXXXXX")
    _ACQ_SPIN_DIR=$d _ACQ_SPIN_ACTIVE=1 _ACQ_SPIN_FORKED=1
    _acq_spin_stop_animation 2>/dev/null
    [ -f "$d/draw" ] && [ -e "$d/stop" ] && echo "FORKED-LOCKED"
    echo "STATE=[$_ACQ_SPIN_DIR$_ACQ_SPIN_FORKED$_ACQ_SPIN_LOCKED$_ACQ_SPIN_ACTIVE]"
    _acq_spin_restore_traps'
  assert_success
  refute_output --partial 'UNSTARTED-KEPT'
  assert_line 'FORKED-LOCKED'
  assert_line 'STATE=[]'
}

# Without its private directory the animator could not be stopped with that
# guarantee, so the spinner announces the phase instead and leaves the caller's
# traps as they were.
@test "progress: with no directory for the draw lock the spinner degrades to a status line" {
  _prog '_acq_progress_enabled() { return 0; }
    export TMPDIR="'"$STUBDIR"'/no-such-dir"
    trap "echo PRIOR_EXIT" EXIT
    acq_spin_start "phase one"
    echo "PID=[$_ACQ_SPIN_PID] ACTIVE=[$_ACQ_SPIN_ACTIVE]"
    trap -p EXIT
    acq_spin_stop'
  assert_success
  assert_line 'acq: phase one'
  assert_line 'PID=[] ACTIVE=[]'
  assert_line "trap -- 'echo PRIOR_EXIT' EXIT"
  refute_output --partial $'\r'
  refute_output --partial 'done'
}

@test "progress: a signal during mktemp removes the directory before running caller cleanup" {
  local sig
  for sig in INT TERM HUP; do
    _prog '_acq_progress_enabled() { return 0; }
      export TMPDIR="'"$STUBDIR"'"
      trap '\''echo PRIOR_EXIT=$?; test ! -d "$TMPDIR/allocated" || echo DIR-LEFT'\'' EXIT
      mktemp() {
        command mkdir "$TMPDIR/allocated"
        kill -s '"$sig"' "$_ACQ_SPIN_OWNER"
        builtin printf "%s\n" "$TMPDIR/allocated"
      }
      acq_spin_start "phase"
      echo NOT-REACHED'
    case "$sig" in
      INT) assert_failure 130 ;;
      TERM) assert_failure 143 ;;
      HUP) assert_failure 129 ;;
    esac
    assert_output --partial 'PRIOR_EXIT='
    refute_output --partial DIR-LEFT
    refute_output --partial NOT-REACHED
    [ ! -d "$STUBDIR/allocated" ]
  done
}
