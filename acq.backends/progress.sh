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
#   harness (scripts/test-acq) captures stderr into a variable (a pipe, not a
#   TTY) and asserts on it, so the spinner NEVER starts there and no frame bytes
#   or carriage returns leak into the captured output. acq_status lines DO print
#   under the harness (by design), so tests may assert on the plain phase text.

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
# PID of the running spinner subshell ("" when none). The animated message is
# retained so acq_spin_stop can render the final "done" line for the same label.
_ACQ_SPIN_PID=""
_ACQ_SPIN_MSG=""

# Prior EXIT/INT/TERM trap COMMANDS captured at acq_spin_start time, so the
# spinner's own cleanup traps COMPOSE with (rather than clobber) a caller's
# pre-existing handler. A caller may already have a security-relevant EXIT trap
# installed (e.g. sbx.sh removes its throwaway validation sandbox on exit); the
# spinner must run that handler too, or Ctrl-C during a long create would leak
# the sandbox. "" means no prior handler was installed for that signal.
_ACQ_SPIN_PRIOR_EXIT_TRAP=""
_ACQ_SPIN_PRIOR_INT_TRAP=""
_ACQ_SPIN_PRIOR_TERM_TRAP=""

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

# _acq_capture_prior_trap SIG — echo the COMMAND currently bound to SIG, or "".
# `trap -p SIG` prints `trap -- 'the command' SIG` (or nothing if unset). Parse
# out just 'the command'. Used so the spinner traps can re-invoke it on exit.
_acq_capture_prior_trap() {
  local line
  line=$(trap -p "$1")
  [ -n "$line" ] || { printf ''; return 0; }
  # Strip the leading `trap -- ` and the trailing ` SIG`, then unquote.
  line=${line#trap -- }
  line=${line% "$1"}
  # Bash single-quotes the command; eval to reduce it back to the raw string.
  eval "printf '%s' $line"
}

# _acq_run_prior_trap COMMAND — run a previously-captured trap COMMAND once, if
# non-empty. Errors in the prior handler must not abort our own cleanup.
_acq_run_prior_trap() {
  [ -n "$1" ] || return 0
  eval "$1" || true
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

  # Hide the cursor for the duration of the animation; the stop path (and the
  # trap) restore it. Then spawn the animator in the background.
  printf '\033[?25l' >&2
  local frames
  frames=$(_acq_spin_frames)
  (
    # The animator loop. Writes "\r<frame> <msg>" to stderr, sleeping between
    # frames. Runs until killed by acq_spin_stop. `_f` is a plain (not `local`)
    # variable: this is a subshell body, not a function, so `local` is invalid
    # here — and the subshell's own scope means it can't leak to the parent.
    # NOTE: do NOT redirect this subshell's stderr to /dev/null — the frames ARE
    # the stderr output. The "Terminated" job notice is suppressed instead by
    # reaping under `wait … 2>/dev/null` in the stop/cleanup paths.
    while :; do
      for _f in $frames; do
        printf '\r%s %s' "$_f" "$msg" >&2
        sleep 0.1
      done
    done
  ) &
  _ACQ_SPIN_PID=$!
  _acq_spin_install_traps
}

# _acq_spin_install_traps — COMPOSE the spinner's cleanup with any pre-existing
# EXIT/INT/TERM handler. We capture the caller's current trap command FIRST, then
# install our own; the cleanup functions re-invoke the captured command so a
# caller's security-relevant cleanup (e.g. `sbx rm` of a throwaway validation
# sandbox) still runs on Ctrl-C or error. acq_spin_stop restores the prior EXIT
# trap on the normal path so no lingering no-op trap is left behind (NIT 3).
_acq_spin_install_traps() {
  _ACQ_SPIN_PRIOR_EXIT_TRAP=$(_acq_capture_prior_trap EXIT)
  _ACQ_SPIN_PRIOR_INT_TRAP=$(_acq_capture_prior_trap INT)
  _ACQ_SPIN_PRIOR_TERM_TRAP=$(_acq_capture_prior_trap TERM)
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

  if [ -n "$_ACQ_SPIN_PID" ]; then
    # Kill the animator and reap it silently (suppress the shell's "Terminated"
    # job notice by waiting with output discarded).
    kill "$_ACQ_SPIN_PID" 2>/dev/null || true
    wait "$_ACQ_SPIN_PID" 2>/dev/null || true
    _ACQ_SPIN_PID=""
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

# _acq_spin_restore_traps — put back the trap commands captured at start time.
# An empty captured command means the caller had none, so we clear our trap.
_acq_spin_restore_traps() {
  if [ -n "$_ACQ_SPIN_PRIOR_EXIT_TRAP" ]; then
    # Intentional expansion now: restore the exact prior trap command captured
    # at start time, not a re-evaluation at signal time.
    # shellcheck disable=SC2064
    trap "$_ACQ_SPIN_PRIOR_EXIT_TRAP" EXIT
  else
    trap - EXIT
  fi
  if [ -n "$_ACQ_SPIN_PRIOR_INT_TRAP" ]; then
    # shellcheck disable=SC2064
    trap "$_ACQ_SPIN_PRIOR_INT_TRAP" INT
  else
    trap - INT
  fi
  if [ -n "$_ACQ_SPIN_PRIOR_TERM_TRAP" ]; then
    # shellcheck disable=SC2064
    trap "$_ACQ_SPIN_PRIOR_TERM_TRAP" TERM
  else
    trap - TERM
  fi
  _ACQ_SPIN_PRIOR_EXIT_TRAP=""
  _ACQ_SPIN_PRIOR_INT_TRAP=""
  _ACQ_SPIN_PRIOR_TERM_TRAP=""
}

# _acq_spin_cleanup_exit — EXIT trap: stop any spinner without printing a
# spurious "done" (an exit may be an error path). Clear the line + cursor, then
# re-invoke the caller's prior EXIT handler (once) so its cleanup (e.g. sbx rm of
# a throwaway validation sandbox) still runs even though we composed over it.
_acq_spin_cleanup_exit() {
  if [ -n "$_ACQ_SPIN_PID" ]; then
    kill "$_ACQ_SPIN_PID" 2>/dev/null || true
    wait "$_ACQ_SPIN_PID" 2>/dev/null || true
    _ACQ_SPIN_PID=""
    printf '\r\033[K\033[?25h' >&2
  fi
  _ACQ_SPIN_MSG=""
  local prior="$_ACQ_SPIN_PRIOR_EXIT_TRAP"
  _ACQ_SPIN_PRIOR_EXIT_TRAP=""
  _acq_run_prior_trap "$prior"
}

# _acq_spin_cleanup_signal SIG — INT/TERM trap: clean up, chain any prior handler
# for SIG (once), then re-raise the signal with the default disposition so the
# process exits with the right status.
_acq_spin_cleanup_signal() {
  _acq_spin_cleanup_exit
  local prior=""
  case "$1" in
    INT)  prior="$_ACQ_SPIN_PRIOR_INT_TRAP";  _ACQ_SPIN_PRIOR_INT_TRAP="" ;;
    TERM) prior="$_ACQ_SPIN_PRIOR_TERM_TRAP"; _ACQ_SPIN_PRIOR_TERM_TRAP="" ;;
  esac
  _acq_run_prior_trap "$prior"
  trap - "$1"
  kill -s "$1" "$$" 2>/dev/null || true
}
