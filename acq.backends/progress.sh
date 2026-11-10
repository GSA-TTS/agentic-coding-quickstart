#!/bin/bash
#
# acq.backends/progress.sh — TTY-aware progress feedback for acq
#
# Sourced by common.sh. Provides friendly, always-safe progress output for the
# long, quiet phases of `acq run` (booting a microVM, installing the agent,
# fetching/applying kits) so a user — especially a novice — can tell that work
# is happening and acq has not hung. See issue #287.
#
# Three public functions, ALL writing to STDERR only (so a user intentionally
# piping stdout gets a clean stream):
#
#   acq_status "message"            One-line phase announcement. ALWAYS prints
#                                   (interactive AND piped/CI), so a captured
#                                   log still shows the phase markers. No
#                                   animation, no carriage returns.
#
#   acq_spin_start "message"        Begin an animated spinner for a long, quiet
#                                   wait. Animates ONLY when interactive (see the
#                                   gate below); otherwise it degrades to a
#                                   single acq_status line and animates nothing.
#
#   acq_spin_stop [final-status]    Stop the spinner started by acq_spin_start,
#                                   clear the animated line, and (interactive
#                                   only) print a "done" marker. Safe to call
#                                   when no spinner is running, and safe to call
#                                   twice (idempotent) — the EXIT/INT/TERM trap
#                                   also calls it so an error or Ctrl-C never
#                                   leaves an orphaned spinner or a hidden cursor.
#
# DESIGN — why a tiny in-repo helper and not a library:
#   acq is a thin, dependency-light wrapper the user clones and runs; pulling in
#   a spinner package (or pv/whiptail) would add a pinned, CVE-scanned,
#   license-checked host dependency for purely cosmetic output — disproportionate
#   and contrary to the "one clone, no extra deps" onboarding this repo exists to
#   provide. Mature installers (Homebrew, rustup, nvm) hand-roll the same ~40
#   lines. This module is modeled on the existing acq_debug (common.sh): stderr
#   only, gated, secret-free (it only ever prints caller-supplied phase labels,
#   never a secret value).
#
# TEST-SAFETY (issue #287 acceptance criteria):
#   The animation is gated on stderr being a TTY (`[ -t 2 ]`). The offline test
#   suite captures stderr into a variable (a pipe, not a TTY) and asserts on it,
#   so the spinner NEVER starts there and no frame bytes or carriage returns leak
#   into the captured output. acq_status lines DO print
#   under the harness (by design), so tests may assert on the plain phase text.

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
# PID of the running spinner subshell ("" when none). The animated message is
# retained so acq_spin_stop can render the final "done" line for the same label.
_ACQ_SPIN_PID=""
_ACQ_SPIN_MSG=""
# Private directory holding the animator's draw lock and stop marker ("" when
# no animated spinner is running). See _acq_spin_end_animator.
_ACQ_SPIN_DIR=""
# Non-empty once this shell may have forked the animator for _ACQ_SPIN_DIR, and
# once this shell holds that directory's draw lock.
_ACQ_SPIN_FORKED=""
_ACQ_SPIN_LOCKED=""
# Non-empty while this shell handles a signal in _acq_spin_cleanup_signal.
_ACQ_SPIN_IN_SIGNAL=""
# Non-empty from the moment an animated spinner starts composing its traps until
# it is stopped, so cleanup also runs in the gap before _ACQ_SPIN_PID is set.
_ACQ_SPIN_ACTIVE=""
_ACQ_SPIN_SELF_PID=""
# PID of the shell that installed the spinner's traps (see _acq_spin_is_owner).
_ACQ_SPIN_OWNER=""
# PID of the shell that installed a provisioning or terminate subshell's traps
# (see acq_trap_owner_mark); "" outside such a subshell.
_ACQ_TRAP_OWNER=""

# Prior EXIT/INT/TERM trap COMMANDS captured at acq_spin_start time, so the
# spinner's own cleanup traps COMPOSE with (rather than clobber) a caller's
# pre-existing handler. A caller may already have a security-relevant EXIT trap
# installed (e.g. sbx.sh removes its throwaway validation sandbox on exit); the
# spinner must run that handler too, or Ctrl-C during a long create would leak
# the sandbox. "" means no prior handler was installed for that signal.
_ACQ_SPIN_PRIOR_EXIT_TRAP=""
_ACQ_SPIN_PRIOR_INT_TRAP=""
_ACQ_SPIN_PRIOR_TERM_TRAP=""
# The raw `trap -p SIG` lines captured at the same time. The parsed commands
# above are only for CHAINING; restore re-evals these lines, because a line is
# a complete `trap` command and keeps dispositions a bare command cannot express
# (an ignored signal, `trap '' INT`, has an empty command but must stay
# ignored).
# "" means the signal was at its default disposition.
_ACQ_SPIN_PRIOR_EXIT_LINE=""
_ACQ_SPIN_PRIOR_INT_LINE=""
_ACQ_SPIN_PRIOR_TERM_LINE=""

# _acq_sanitize_msg TEXT — echo TEXT with C0 control bytes and DEL stripped, so
# an untrusted caller-supplied label (e.g. a --name value that reaches the
# spinner BEFORE the backend validates it) cannot inject raw terminal escape
# sequences (clear-screen, cursor moves) into the animated line. Applies ONLY to
# caller data — the spinner's own fixed escapes (cursor hide/show, \r, \033[K)
# are emitted separately as literal format strings. Stripping all of \000-\037
# also drops embedded newlines/tabs, which is fine for single-line phase labels.
_acq_sanitize_msg() {
  printf '%s' "$*" | LC_ALL=C tr -d '\000-\037\177'
}

# _acq_trap_line_cmd LINE — echo the handler COMMAND from a `trap -p SIG` LINE,
# or "" when LINE is empty or the trap is at its default disposition.
# `trap -p SIG` prints `trap -- 'the command' NAME` (or nothing if unset), where
# NAME is NOT necessarily the spelling the caller asked for: bash prints `SIGINT`
# / `SIGTERM` for signals (3.2 and 5.x alike) but `INT` / `TERM` in POSIX mode,
# and `EXIT` for the pseudo-signal. So do not string-match the trailing name.
# Instead let the shell re-tokenize the line bash itself quoted: after dropping
# the leading `trap`, the words are `--`, the command, and the signal name, so
# the command is always the second word whatever the name's spelling.
# Keep in sync with _acq_prompt_trap_cmd in prompt.sh (same parser; each file
# can be sourced without the other).
_acq_trap_line_cmd() {
  [ -n "$1" ] || return 0
  # Safe to eval: the text is bash's own `trap -p` output, whose command field
  # is single-quoted (embedded quotes escaped), so it expands to literal words.
  eval "set -- ${1#trap }"
  # Newer bash in POSIX mode (seen on 5.3) lists an UNSET trap as
  # `trap -- - NAME`; an action of `-` means "default disposition", i.e. no
  # prior handler.
  [ "$2" = "-" ] || printf '%s' "$2"
}

# _acq_capture_prior_trap SIG — echo the COMMAND currently bound to SIG, or "".
_acq_capture_prior_trap() {
  _acq_trap_line_cmd "$(trap -p "$1")"
}

# _acq_restore_trap_line LINE SIG — re-install the trap captured as LINE (a
# full `trap -p SIG` line, itself a valid `trap` command), or reset SIG to its
# default disposition when LINE is empty.
_acq_restore_trap_line() {
  if [ -n "$1" ]; then
    eval "$1"
  else
    trap - "$2"
  fi
}

# _acq_return_status N — return N, so the next command sees `$?` = N.
_acq_return_status() {
  return "$1"
}

# _acq_run_prior_trap COMMAND [STATUS] — run a previously-captured trap COMMAND
# once, if non-empty, with `$?` set to STATUS (default 0). A handler written as
# `rc=$?; cleanup; exit "$rc"` (the provisioning subshells in sbx.sh and msb.sh)
# reads `$?` first, so it must see the status the shell is exiting with, not the
# status of our own cleanup commands; otherwise a failed or interrupted provision
# exits 0. Errors in the prior handler must not abort our own cleanup, so the
# whole group runs in an `||` context, where `set -e` does not apply (that also
# keeps a non-zero STATUS from tripping errexit before the handler runs). It runs
# inside the spinner's cleanup function (so it sees that function's scope); give
# it the default word splitting it was written against.
_acq_run_prior_trap() {
  [ -n "$1" ] || return 0
  local IFS=$' \t\n'
  { _acq_return_status "${2:-0}"; eval "$1"; } || true
}

# _acq_signal_self SIG — send SIG to the CURRENT shell process. Inside a
# subshell or `$(...)`, `$$` is still the parent's PID, so a `kill -s SIG $$`
# re-raise would hit the parent. Use BASHPID, or on bash 3.2 (no BASHPID) the
# PPID of an `exec`ed child, which is the current shell because `exec` skips
# the extra fork. Call it directly, never inside `$(...)`, or it would name the
# command substitution's process instead.
# Keep in sync with _acq_prompt_signal_self in prompt.sh (each file can be
# sourced without the other).
_acq_signal_self() {
  local _acq_self_pid=""
  # BASHPID only from bash 4 on: bash 3.2 has no such special variable, so
  # there it is an ordinary one that the environment can set to another PID.
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    _acq_self_pid="${BASHPID:-}"
  fi
  [ -n "$_acq_self_pid" ] || _acq_self_pid=$(exec sh -c 'echo "$PPID"')
  kill -s "$1" "$_acq_self_pid" 2>/dev/null || true
}

# _acq_spin_self_pid — set _ACQ_SPIN_SELF_PID to the PID of the CURRENT shell,
# found the same way as in _acq_signal_self. It sets a variable rather than
# printing, because a `$(...)` around it would report the command
# substitution's own process.
_acq_spin_self_pid() {
  _ACQ_SPIN_SELF_PID=""
  # BASHPID only from bash 4 on: bash 3.2 has no such special variable, so
  # there it is an ordinary one that the environment can set to another PID.
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    _ACQ_SPIN_SELF_PID="${BASHPID:-}"
  fi
  [ -n "$_ACQ_SPIN_SELF_PID" ] || _ACQ_SPIN_SELF_PID=$(exec sh -c 'echo "$PPID"')
}

# _acq_spin_is_owner — true in the shell that installed the spinner's traps (or
# when none recorded an owner), false in any other process. A child forked while
# the traps are set can run them: a signal that reaches it before Bash resets
# its inherited handlers is handled with the parent's trap commands, and Bash 5
# then also runs the parent's EXIT trap there. Measured: TERMing a subshell
# straight after `( ... ) &` ran the parent's EXIT trap in 173 of 200 children
# under Bash 5.3 (none under 3.2). A terminal's or `timeout`'s group signal
# reaches the animator in exactly that way (and the spinner once TERMed it
# itself), so without this check the animator could run the caller's EXIT
# cleanup (sandbox removal, lock release) a second time, from the wrong process.
#
# An unknown PID also counts as the owner. On Bash 3.2 the PID comes from a
# forked `sh`, and that fork can fail (a process limit). Treating the shell as a
# non-owner would then skip the caller's EXIT cleanup in the one shell that must
# run it. The opposite error needs a child whose own fork also failed, inside
# the brief window described above, and costs a repeated cleanup: the lesser
# failure of the two.
_acq_spin_is_owner() {
  _acq_pid_is_self "$_ACQ_SPIN_OWNER"
}

# _acq_pid_is_self OWNER — true when OWNER is empty, when this shell's PID
# cannot be learned, or when OWNER is this shell's PID; false otherwise. The
# shared test behind _acq_spin_is_owner and acq_trap_owner_is_self (an unknown
# PID counts as the owner, for the reason given above).
_acq_pid_is_self() {
  [ -n "$1" ] || return 0
  _acq_spin_self_pid
  [ -n "$_ACQ_SPIN_SELF_PID" ] || return 0
  [ "$_ACQ_SPIN_SELF_PID" = "$1" ]
}

# acq_trap_owner_mark / acq_trap_owner_is_self — the same installer-PID guard
# for the provisioning and terminate subshells' own EXIT/HUP/INT/TERM traps
# (acq.backends/sbx.sh and msb.sh). Mark right before installing them; every
# handler then starts with acq_trap_owner_is_self, so a child forked while they
# are set, and signalled before Bash resets its inherited handlers, exits
# instead of signalling the registered backend children, discarding the
# uncreated attempt or releasing the lock on the owner's behalf. The mark lives
# in the subshell that sets it, so a nested subshell marking its own traps does
# not change the outer one's.
acq_trap_owner_mark() {
  _acq_spin_self_pid
  _ACQ_TRAP_OWNER="$_ACQ_SPIN_SELF_PID"
}

acq_trap_owner_is_self() {
  _acq_pid_is_self "${_ACQ_TRAP_OWNER:-}"
}

# acq_run_signal_deferred COMMAND [ARG...] — run COMMAND (in acq, the provision
# or terminate function, whose body is a subshell with its own HUP/INT/TERM
# cleanup) so that a SIGTERM or SIGHUP for acq's own shell waits for it.
# _ACQ_DEFERRED_STEP names the step in the "stopped by" message (default
# "provisioning"; `acq rm` sets "removal").
#
# A terminal's Ctrl-C reaches the whole process group, and Bash already waits
# for a foreground child that handles SIGINT before acting on it. SIGTERM and
# SIGHUP had no handler in acq's shell, so a group SIGTERM ended acq at once,
# 143, while the subshell was still releasing the lock and discarding the
# uncreated attempt; for a moment the lock outlived acq. With a trap set, Bash
# runs it only after the foreground subshell has exited, so acq now ends after
# that cleanup, with the subshell's own status.
#
# A signal sent to acq's PID alone, not to its group, is NOT forwarded to the
# subshell. Forwarding needs the subshell running in the background while acq
# waits, and a background child of a non-interactive Bash 3.2 starts with
# SIGINT ignored, so it could no longer trap Ctrl-C at all. Terminals, `timeout`
# and service managers all signal the process group, which already reaches the
# create. A lone `kill <acq pid>` therefore lets the provisioning step finish,
# holding the lock and its backend child to the end, and acq then stops there
# with 128 + N instead of going on (run would otherwise attach). See
# docs/KNOWN_FAILURE_MODES.md section 83.
#
# COMMAND runs as a plain foreground command, never in an `if` or `||` context,
# so `set -e` keeps its meaning inside it; under `set -e` a failing COMMAND ends
# acq here with its status.
acq_run_signal_deferred() {
  local _acq_sd_term _acq_sd_hup _acq_sd_rc
  _acq_sd_term=$(trap -p TERM)
  _acq_sd_hup=$(trap -p HUP)
  _ACQ_DEFERRED_SIGNAL=""
  trap '_ACQ_DEFERRED_SIGNAL=TERM' TERM
  trap '_ACQ_DEFERRED_SIGNAL=HUP' HUP
  "$@"
  _acq_sd_rc=$?
  _acq_restore_trap_line "$_acq_sd_term" TERM
  _acq_restore_trap_line "$_acq_sd_hup" HUP
  [ -n "$_ACQ_DEFERRED_SIGNAL" ] || return "$_acq_sd_rc"
  if [ "$_acq_sd_rc" -eq 0 ]; then
    echo "acq: stopped by SIG$_ACQ_DEFERRED_SIGNAL after the ${_ACQ_DEFERRED_STEP:-provisioning} step finished" >&2
  fi
  case "$_ACQ_DEFERRED_SIGNAL" in
    HUP) exit 129 ;;
    *) exit 143 ;;
  esac
}

# _acq_progress_enabled — 0 (true) when animated progress may run, 1 otherwise.
# Animate only when ALL hold:
#   - stderr is an interactive TTY            ([ -t 2 ])
#   - the user has not opted out              (ACQ_NO_PROGRESS unset/empty)
#   - debug tracing is off                    (ACQ_DEBUG unset/empty) — the
#     timestamped acq_debug breadcrumbs already provide feedback and a spinner's
#     carriage returns would fight the scrolling trace.
_acq_progress_enabled() {
  [ -t 2 ] || return 1
  [ -z "${ACQ_NO_PROGRESS:-}" ] || return 1
  [ -z "${ACQ_DEBUG:-}" ] || return 1
  return 0
}

# _acq_spin_frames — echo the spinner frames as a single space-separated string.
# Prefer Unicode braille (smooth, compact) when the locale looks UTF-8; fall back
# to plain ASCII spinner glyphs otherwise, so a non-UTF-8 federal terminal shows
# a clean `| / - \` rather than mojibake.
_acq_spin_frames() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]8*|*[Uu][Tt][Ff]-8*)
      printf '%s' '⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏' ;;
    *)
      # ASCII fallback: | / - \  (build the backslash via printf so the literal
      # does not trip shellcheck SC1003's "did you mean to escape a quote?").
      printf '%s' "| / - $(printf '\134')" ;;
  esac
}

# ---------------------------------------------------------------------------
# acq_status MESSAGE — always-on, non-animated phase announcement (stderr).
# ---------------------------------------------------------------------------
acq_status() {
  local msg
  msg=$(_acq_sanitize_msg "$*")
  printf 'acq: %s\n' "$msg" >&2
}

# ---------------------------------------------------------------------------
# acq_spin_start MESSAGE — start a spinner (interactive) or announce (otherwise).
# ---------------------------------------------------------------------------
acq_spin_start() {
  local msg
  msg=$(_acq_sanitize_msg "$*")
  # Stop any spinner still running (defensive: callers should pair start/stop,
  # but never stack two animations on one line).
  acq_spin_stop

  _ACQ_SPIN_MSG="$msg"

  if ! _acq_progress_enabled; then
    # Non-interactive / opted-out / debug: no animation. Emit one plain status
    # line so piped runs and CI logs still see the phase.
    acq_status "$msg"
    return 0
  fi

  local frames owner dir
  frames=$(_acq_spin_frames)
  # Compose the cleanup traps BEFORE the cursor is hidden or the animator
  # exists. In the other order, a Ctrl-C or SIGTERM that landed while the traps
  # were still being captured ran only the caller's handlers: the shell exited,
  # but the animator (an asynchronous child, so it ignores SIGINT) kept drawing
  # forever and the cursor stayed hidden. _ACQ_SPIN_ACTIVE tells the cleanup
  # that the cursor may be hidden even before the animator's PID is recorded.
  _ACQ_SPIN_ACTIVE=1
  _acq_spin_install_traps
  owner="$_ACQ_SPIN_OWNER"
  # A private directory for the draw lock and the stop marker (see
  # _acq_spin_end_animator), made once the cleanup traps are in place so that
  # they remove it from the moment it is recorded. A signal that lands while
  # mktemp runs, before the name is recorded, can still leave an empty
  # acq-spin.* directory behind. Without the directory the animator could not
  # be stopped with a guarantee, so animate nothing and announce the phase
  # instead.
  dir=$(mktemp -d "${TMPDIR:-/tmp}/acq-spin.XXXXXX" 2>/dev/null) || dir=""
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    _ACQ_SPIN_ACTIVE=""
    _acq_spin_restore_traps
    acq_status "$msg"
    return 0
  fi
  _ACQ_SPIN_DIR="$dir"
  # Hide the cursor for the duration of the animation; the stop path (and the
  # trap) restore it. Then spawn the animator in the background.
  printf '\033[?25l' >&2
  _ACQ_SPIN_FORKED=1
  (
    # The animator loop. Writes "\r<frame> <msg>" to stderr, sleeping between
    # frames. Runs until acq_spin_stop sets its stop marker (or a TERM or HUP
    # reaches it). `_f` is a plain (not `local`) variable: this is a subshell
    # body, not a function, so `local` is invalid here — and the subshell's own
    # scope means it can't leak to the parent.
    # It also stops by itself once the shell that started it is gone. That
    # covers a signal handled between the fork and the `$!` below (the cleanup
    # then has no PID to watch) and an owner killed by SIGKILL, which runs no
    # trap at all.
    # NOTE: do NOT redirect this subshell's stderr to /dev/null — the frames ARE
    # the stderr output. It ends on TERM or HUP with `exit 0`, removing its
    # private directory, rather than dying by the signal, so the shell prints
    # no "Terminated" job notice for it.
    # Each frame is drawn only while holding the draw lock and only when no
    # stop marker exists, so once the stopping shell holds the lock (or this
    # animator is gone) no frame can follow, however late this process runs.
    # The draw lock is the file $dir/draw, created exclusively: noclobber makes
    # Bash open it with O_EXCL, and the create runs in this shell, without a
    # fork per frame (see _acq_spin_end_animator).
    trap '_acq_spin_animator_quit "$dir"' TERM HUP
    set -C
    while :; do
      for _f in $frames; do
        kill -0 "$owner" 2>/dev/null || _acq_spin_animator_quit "$dir"
        if [ ! -L "$dir/draw" ] && { true >"$dir/draw"; } 2>/dev/null && [ ! -L "$dir/draw" ]; then
          [ ! -e "$dir/stop" ] || _acq_spin_animator_quit "$dir"
          printf '\r%s %s' "$_f" "$msg" >&2
          rm -f "$dir/draw" 2>/dev/null || true
        elif [ -e "$dir/stop" ] || [ ! -d "$dir" ]; then
          _acq_spin_animator_quit "$dir"
        fi
        sleep 0.1
      done
    done
  ) &
  _ACQ_SPIN_PID=$!
}

# _acq_spin_install_traps — COMPOSE the spinner's cleanup with any pre-existing
# EXIT/INT/TERM handler. We capture the caller's current trap command FIRST, then
# install our own; the cleanup functions re-invoke the captured command so a
# caller's security-relevant cleanup (e.g. `sbx rm` of a throwaway validation
# sandbox) still runs on Ctrl-C or error. acq_spin_stop restores the prior EXIT
# trap on the normal path so no lingering no-op trap is left behind (NIT 3).
_acq_spin_install_traps() {
  _acq_spin_self_pid
  _ACQ_SPIN_OWNER="$_ACQ_SPIN_SELF_PID"
  _ACQ_SPIN_PRIOR_EXIT_LINE=$(trap -p EXIT)
  _ACQ_SPIN_PRIOR_INT_LINE=$(trap -p INT)
  _ACQ_SPIN_PRIOR_TERM_LINE=$(trap -p TERM)
  _ACQ_SPIN_PRIOR_EXIT_TRAP=$(_acq_trap_line_cmd "$_ACQ_SPIN_PRIOR_EXIT_LINE")
  _ACQ_SPIN_PRIOR_INT_TRAP=$(_acq_trap_line_cmd "$_ACQ_SPIN_PRIOR_INT_LINE")
  _ACQ_SPIN_PRIOR_TERM_TRAP=$(_acq_trap_line_cmd "$_ACQ_SPIN_PRIOR_TERM_LINE")
  trap '_acq_spin_cleanup_exit' EXIT
  trap '_acq_spin_cleanup_signal INT'  INT
  trap '_acq_spin_cleanup_signal TERM' TERM
}

# ---------------------------------------------------------------------------
# acq_spin_stop [FINAL] — stop the spinner, clear the line, print a done marker.
# ---------------------------------------------------------------------------
# Idempotent: a no-op when no spinner is running. FINAL overrides the label shown
# on the completed line (defaults to the started message).
# shellcheck disable=SC2120  # FINAL is optional; callers (sbx.sh) do pass it.
acq_spin_stop() {
  local final
  final=$(_acq_sanitize_msg "${1:-$_ACQ_SPIN_MSG}")

  if [ -n "$_ACQ_SPIN_ACTIVE" ]; then
    _acq_spin_end_animator
    _ACQ_SPIN_PID=""
    _ACQ_SPIN_ACTIVE=""
    # Clear the animated line (\r + clear-to-EOL) and restore the cursor.
    printf '\r\033[K\033[?25h' >&2
    # Print a completion marker for the phase, if we have a label.
    [ -n "$final" ] && printf 'acq: %s… done\n' "$final" >&2
    # Restore the caller's prior EXIT/INT/TERM traps so we do not leave a
    # lingering composed spinner trap behind (NIT 3). Only meaningful when the
    # spinner actually installed traps (i.e. it was animating).
    _acq_spin_restore_traps
  fi
  _ACQ_SPIN_MSG=""
}

# _acq_spin_restore_traps — put back the traps captured at start time, exactly
# (handler, ignore, or default), by re-evaluating the saved `trap -p` lines.
_acq_spin_restore_traps() {
  _acq_restore_trap_line "$_ACQ_SPIN_PRIOR_EXIT_LINE" EXIT
  _acq_restore_trap_line "$_ACQ_SPIN_PRIOR_INT_LINE" INT
  _acq_restore_trap_line "$_ACQ_SPIN_PRIOR_TERM_LINE" TERM
  _ACQ_SPIN_PRIOR_EXIT_TRAP=""
  _ACQ_SPIN_PRIOR_INT_TRAP=""
  _ACQ_SPIN_PRIOR_TERM_TRAP=""
  _ACQ_SPIN_PRIOR_EXIT_LINE=""
  _ACQ_SPIN_PRIOR_INT_LINE=""
  _ACQ_SPIN_PRIOR_TERM_LINE=""
  _ACQ_SPIN_OWNER=""
}

# _acq_spin_end_animator — stop the animator (if any) so that it can draw no
# further frame, without the `wait` builtin.
#
# Bash 5.2 can lose track of a child that exits while a trap runs: in the
# Ctrl-C cleanup, `wait <animator>` then never returned although the animator
# had exited and been reaped, and acq hung until it was killed. Measured with
# test/bats/create-signal.py's sbx Ctrl-C case, six at a time on four CPUs:
# 5 hangs in 80 runs under Bash 5.2.21, none in 60 under 5.3. Polling with
# `kill -0` cannot hang that way. The `sleep` between polls makes the shell reap
# an exited animator, which then no longer answers `kill -0`.
#
# A TERM alone would not stop the drawing in time: an animator that is not
# scheduled for a while can be past its checks, with the TERM still pending,
# and write one more frame whenever it next runs, over whatever this shell has
# printed since (an attached agent session). So the animator draws only while
# holding a draw lock and only when no stop marker exists, and it quits by itself at its next check (within
# one frame) once the marker is set. This function writes the stop marker, then
# waits until it holds the draw lock itself or the animator is gone; from either
# point on no frame can be drawn. The lock is held only for the moment of one
# draw, so this waits beyond that moment only for an animator that is alive and
# in the middle of a draw. That wait is capped at about 30 seconds, for an
# animator suspended (SIGSTOP) while holding the lock: after that the stop
# returns, and such an animator, if it is ever resumed, can still draw that one
# frame. Once the lock is held, it waits up to about two seconds more for the
# animator to exit; one still running then ends at its next check.
#
# The draw lock is the file $dir/draw, and whoever creates it exclusively holds
# it (noclobber, which makes Bash open it with O_EXCL). It is not a directory
# made with mkdir: uutils coreutils mkdir 0.10 reports success to concurrent
# callers (KNOWN_FAILURE_MODES section 92), which would let both sides hold it.
# The animator creates it in its own shell, so taking it costs no fork per
# frame; releasing it costs the one rm that the rmdir it replaces did.
#
# The animator is not sent TERM (unless the stop marker cannot be written,
# when only a TERM can end it). A TERM that reached it before it set its own
# trap would kill it by the signal, and Bash 3.2 then prints a "Terminated" job
# notice; hiding that needed stderr on /dev/null around the whole wait, which
# also hid the output of a trap that ran during it (the cursor restore, a
# caller's interrupt message). The private directory is removed here once the
# animator is gone or was never started, or otherwise by the animator as it
# quits (_acq_spin_animator_quit).
#
# The spinner state is cleared only after the wait, so a signal that arrives
# during it runs this same wait again from the trap (writing the marker and
# taking the lock are idempotent) instead of skipping it.
_acq_spin_end_animator() {
  local pid="$_ACQ_SPIN_PID" dir="$_ACQ_SPIN_DIR" tries=0 held=0 gone=0 deadline
  if [ -z "$dir" ]; then
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    return 0
  fi
  [ -z "$_ACQ_SPIN_LOCKED" ] || held=1
  deadline=$((SECONDS + 30))
  if [ -z "$pid" ] && [ -z "$_ACQ_SPIN_FORKED" ]; then
    # No animator was ever started for this directory.
    gone=1
  else
    # The animator quits by itself once it sees the marker. Only if the marker
    # cannot be written is it sent TERM instead (the job notice that may then
    # follow is the lesser harm than an animator polling for the whole session).
    if ! : 2>/dev/null >"$dir/stop" && [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  while [ "$gone" -eq 0 ]; do
    if [ "$held" -eq 0 ] && [ ! -L "$dir/draw" ] &&
        ( set -C; : >"$dir/draw" ) 2>/dev/null && [ ! -L "$dir/draw" ]; then
      _ACQ_SPIN_LOCKED=1
      held=1
    fi
    # The animator removes the directory as it quits, and draws nothing after.
    if [ ! -d "$dir" ]; then gone=1; break; fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then gone=1; break; fi
    # Without a PID (a signal landed between the fork and recording it), the
    # lock is all this shell can hold; the animator ends at its next check.
    if [ "$held" -eq 1 ] && { [ -z "$pid" ] || [ "$tries" -ge 100 ]; }; then
      break
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.02
    tries=$((tries + 1))
  done
  if [ "$gone" -eq 1 ]; then
    rm -f "$dir/stop" "$dir/draw" 2>/dev/null || true
    rmdir "$dir" 2>/dev/null || true
  fi
  _ACQ_SPIN_DIR=""
  _ACQ_SPIN_FORKED=""
  _ACQ_SPIN_LOCKED=""
  return 0
}

# _acq_spin_animator_quit DIR — the animator's way out: remove its private
# directory (the stopping shell may hold the draw lock inside it; that no longer
# matters once the animator is ending) and exit 0.
_acq_spin_animator_quit() {
  rm -f "$1/stop" "$1/draw" 2>/dev/null || true
  rmdir "$1" 2>/dev/null || true
  exit 0
}

# _acq_spin_stop_animation — stop the animator (if any), then clear the line
# and restore the cursor. Prints no "done" marker.
_acq_spin_stop_animation() {
  if [ -n "$_ACQ_SPIN_ACTIVE" ]; then
    _acq_spin_end_animator
    _ACQ_SPIN_PID=""
    _ACQ_SPIN_ACTIVE=""
    printf '\r\033[K\033[?25h' >&2
  fi
  _ACQ_SPIN_MSG=""
}

# _acq_spin_cleanup_exit [STATUS] — EXIT trap: stop any spinner without printing
# a spurious "done" (an exit may be an error path). Clear the line + cursor, then
# re-invoke the caller's prior EXIT handler (once) so its cleanup (e.g. sbx rm of
# a throwaway validation sandbox) still runs even though we composed over it.
# The prior handler sees the exit status in `$?`: STATUS when given (the signal
# path), otherwise the `$?` this trap was entered with. Capture it before any
# other command runs. Locals carry a prefix so they cannot shadow a variable the
# prior handler reads.
_acq_spin_cleanup_exit() {
  local _acq_spin_rc="${1:-$?}"
  # Only the owner runs the cleanup; a child that inherited the trap just exits.
  _acq_spin_is_owner || return 0
  _acq_spin_stop_animation
  local _acq_spin_prior="$_ACQ_SPIN_PRIOR_EXIT_TRAP"
  _ACQ_SPIN_PRIOR_EXIT_TRAP=""
  _acq_run_prior_trap "$_acq_spin_prior" "$_acq_spin_rc"
}

# _acq_spin_cleanup_signal SIG — INT/TERM trap. Order matters:
#   1. Stop the animation, and reset SIG to its default disposition so a prior
#      handler that re-raises SIG ends the process instead of re-entering here.
#   2. Run the prior SIG handler (once) with `$?` = 128+signal. If it exits (the
#      provisioning subshells chain `_acq_provider_input_signal_exit 130`), the
#      EXIT trap, still ours, chains the prior EXIT handler with that status, so
#      the shell exits 130/143 and the EXIT cleanup runs exactly once.
#   3. If it returned, or there was none, run the EXIT cleanup with the signal
#      status, drop the EXIT trap, and re-raise SIG at THIS process (see
#      _acq_signal_self) so the parent sees a death by signal. Should the
#      re-raise not end the process (SIG ignored), exit with the status instead.
#
# Bash 5 runs this trap again for a second INT or TERM that arrives while the
# first is still being handled (during the stop's wait for the animator, which
# can last up to its cap). The nested run returns at once, so the outer one
# finishes: it, not the nested run, holds the prior handler, and that handler
# (the provisioning subshells' `_acq_provider_input_signal_exit`) must run
# before the EXIT cleanup releases the provider-input lock.
_acq_spin_cleanup_signal() {
  local _acq_spin_sig="$1" _acq_spin_status=1 _acq_spin_prior=""
  case "$_acq_spin_sig" in
    INT)  _acq_spin_status=130 ;;
    TERM) _acq_spin_status=143 ;;
  esac
  # A child that inherited this trap (see _acq_spin_is_owner) was being asked
  # to stop: it ends here, without touching the owner's animator, cursor or
  # handlers.
  if ! _acq_spin_is_owner; then
    trap - EXIT INT TERM
    exit "$_acq_spin_status"
  fi
  [ -z "$_ACQ_SPIN_IN_SIGNAL" ] || return 0
  _ACQ_SPIN_IN_SIGNAL=1
  case "$_acq_spin_sig" in
    INT)  _acq_spin_prior="$_ACQ_SPIN_PRIOR_INT_TRAP";  _ACQ_SPIN_PRIOR_INT_TRAP="" ;;
    TERM) _acq_spin_prior="$_ACQ_SPIN_PRIOR_TERM_TRAP"; _ACQ_SPIN_PRIOR_TERM_TRAP="" ;;
  esac
  _acq_spin_stop_animation
  trap - "$_acq_spin_sig"
  _acq_run_prior_trap "$_acq_spin_prior" "$_acq_spin_status"
  _acq_spin_cleanup_exit "$_acq_spin_status"
  trap - EXIT
  _acq_signal_self "$_acq_spin_sig"
  exit "$_acq_spin_status"
}
