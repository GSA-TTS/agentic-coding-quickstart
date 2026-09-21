#!/bin/bash
#
# acq.backends/prompt.sh — TTY-aware interactive prompt widgets for acq
#
# Sourced by common.sh (next to progress.sh). Provides a small, dependency-free
# set of interactive widgets so `acq configure` (and the create-time picker) can
# offer a friendly, colorful selection UI — modeled on the multiselect installers
# users already like — WITHOUT pinning a TUI dependency (gum/fzf/whiptail). See
# ADR-0028 and issue GSA-TTS/agentic-coding-quickstart#499.
#
# Two public functions:
#
#   acq_prompt_multiselect LOCKED_N DEFAULTS_CSV LABEL_1 DESC_1 [LABEL_2 DESC_2 ...]
#       Present a checkbox list of items. The FIRST LOCKED_N items are shown as
#       "frozen" rows: always checked, dimmed, tagged "(always applied)", skipped
#       by the cursor, never toggleable, and never included in the result. The
#       remaining items are the toggleable rows. DEFAULTS_CSV is a comma-separated
#       list of 1-based indices — RELATIVE TO THE TOGGLEABLE BLOCK (so index 1 is
#       the first toggleable item, regardless of LOCKED_N) — pre-checked on entry
#       (empty = none). Interactive: the user moves with the arrow keys (or j/k),
#       toggles with SPACE, confirms with ENTER, aborts with q/ESC. On confirm,
#       echoes the CHOSEN indices (also relative to the toggleable block) as a
#       space-separated list on STDOUT (empty line = nothing chosen; "CANCELLED"
#       on abort). All chrome is written to STDERR so a caller can capture the
#       selection cleanly. Pass LOCKED_N=0 for a plain, all-toggleable list.
#
#   acq_prompt_confirm PROMPT DEFAULT        (DEFAULT = yes|no)
#       A colorized [Y/n] / [y/N] confirm. Returns 0 for yes, 1 for no. The
#       default is used on a bare ENTER and in every non-interactive path.
#
# DESIGN — why a tiny in-repo helper and not a library (mirrors progress.sh):
#   acq is a thin, dependency-light wrapper the user clones and runs; pulling in
#   a selector package would add a pinned, CVE-scanned, license-checked host
#   dependency for cosmetic input — disproportionate and contrary to the "one
#   clone, no extra deps" onboarding this repo provides. Mature installers
#   hand-roll the same handful of escape sequences.
#
# SAFETY / CI:
#   - Interactivity is gated on STDIN being a TTY (`[ -t 0 ]`). Color is gated
#     independently on STDOUT-for-chrome (STDERR here) being a TTY (`[ -t 2 ]`),
#     matching install.sh's `[ -t 1 ]` model but for our stderr chrome stream.
#   - ACQ_NO_PROMPT (or ACQ_NO_PROGRESS) forces the non-interactive path.
#   - Non-interactive ALWAYS takes the supplied defaults and never blocks, so CI
#     and piped runs behave exactly as before.
#   - ACQ_PROMPT_TEST_INPUT feeds a scripted keystroke/answer string for the
#     offline test harness (mirrors ACQ_SECRET_TEST_VALUE), so the widgets are
#     testable without a real terminal.
#   - Caller-supplied labels are sanitized of control bytes before display, so an
#     untrusted kit description can't inject terminal escapes.

# _acq_prompt_sanitize TEXT — strip C0 control bytes + DEL from caller data, so a
# label/description can never inject raw escapes. Same technique as progress.sh's
# _acq_sanitize_msg (kept independent so prompt.sh is usable if sourced alone).
_acq_prompt_sanitize() {
  printf '%s' "$*" | LC_ALL=C tr -d '\000-\037\177'
}

# _acq_prompt_interactive — 0 (true) when we may run an interactive widget:
# stdin is a TTY AND the user has not opted out. When ACQ_PROMPT_TEST_INPUT is
# set we ALSO treat the session as interactive (the harness drives the keys),
# so the widget logic itself is exercised offline.
_acq_prompt_interactive() {
  if [ -n "${ACQ_PROMPT_TEST_INPUT:-}" ]; then
    return 0
  fi
  [ -z "${ACQ_NO_PROMPT:-}" ] || return 1
  [ -z "${ACQ_NO_PROGRESS:-}" ] || return 1
  [ -t 0 ] || return 1
  return 0
}

# _acq_prompt_color — 0 (true) when we may emit SGR color on the chrome stream
# (stderr). Matches install.sh's TTY gate, but for fd 2. Suppressed for the test
# harness so assertions match plain text.
_acq_prompt_color() {
  [ -z "${ACQ_PROMPT_TEST_INPUT:-}" ] || return 1
  [ -t 2 ] || return 1
  return 0
}

# Populate B/R/YEL/GRN/RED/DIM/CYAN for the duration of a widget. Mirrors the
# install.sh palette (B/R/YEL/GRN/RED) plus a dim + cyan accent for the cursor
# row. Empty strings when color is disabled, so every printf is color-safe.
_acq_prompt_set_colors() {
  if _acq_prompt_color; then
    _P_B=$(printf '\033[1m');  _P_R=$(printf '\033[0m')
    _P_YEL=$(printf '\033[33m'); _P_GRN=$(printf '\033[32m'); _P_RED=$(printf '\033[31m')
    _P_DIM=$(printf '\033[2m'); _P_CYAN=$(printf '\033[36m')
  else
    _P_B=""; _P_R=""; _P_YEL=""; _P_GRN=""; _P_RED=""; _P_DIM=""; _P_CYAN=""
  fi
}

# _acq_prompt_read_key — read a single logical keypress and store the normalized
# token in the global _ACQ_PROMPT_KEY (rather than echoing it), so the caller can
# invoke it WITHOUT a command substitution. That matters for the scripted test
# path: a `$(...)` subshell would discard the advance of _ACQ_PROMPT_TEST_POS,
# so a substitution-based reader replays the first key forever. The token is one
# of UP DOWN LEFT RIGHT SPACE ENTER QUIT, or a literal char.
#
# When ACQ_PROMPT_TEST_INPUT is set, keys are consumed from that string one token
# at a time via _ACQ_PROMPT_TEST_POS; tokens there may be the literal words
# UP/DOWN/SPACE/ENTER/QUIT (whitespace-separated) OR single chars.
_ACQ_PROMPT_TEST_POS=0
_ACQ_PROMPT_KEY=""
_acq_prompt_read_key() {
  _ACQ_PROMPT_KEY=""
  if [ -n "${ACQ_PROMPT_TEST_INPUT:-}" ]; then
    # Tokenized scripted input: split on whitespace, emit the next token.
    local toks
    # shellcheck disable=SC2206  # deliberate word-split of the scripted input
    toks=(${ACQ_PROMPT_TEST_INPUT})
    if [ "$_ACQ_PROMPT_TEST_POS" -ge "${#toks[@]}" ]; then
      _ACQ_PROMPT_KEY='ENTER'   # exhausted script → confirm, so a test can never hang
      return 0
    fi
    _ACQ_PROMPT_KEY="${toks[$_ACQ_PROMPT_TEST_POS]}"
    _ACQ_PROMPT_TEST_POS=$((_ACQ_PROMPT_TEST_POS + 1))
    return 0
  fi

  local k rest
  IFS= read -rsn1 k 2>/dev/null || { _ACQ_PROMPT_KEY='QUIT'; return 0; }
  case "$k" in
    '')      _ACQ_PROMPT_KEY='ENTER'; return 0 ;;   # Enter yields empty with -n1
    ' ')     _ACQ_PROMPT_KEY='SPACE'; return 0 ;;
    q|Q)     _ACQ_PROMPT_KEY='QUIT';  return 0 ;;
    j|J)     _ACQ_PROMPT_KEY='DOWN';  return 0 ;;
    k|K)     _ACQ_PROMPT_KEY='UP';    return 0 ;;
    $'\033')
      # Possible CSI sequence: read up to two more bytes non-blocking.
      IFS= read -rsn2 -t 1 rest 2>/dev/null || rest=""
      case "$rest" in
        '[A') _ACQ_PROMPT_KEY='UP' ;;
        '[B') _ACQ_PROMPT_KEY='DOWN' ;;
        '[C') _ACQ_PROMPT_KEY='RIGHT' ;;
        '[D') _ACQ_PROMPT_KEY='LEFT' ;;
        *)    _ACQ_PROMPT_KEY='QUIT' ;;   # bare ESC (or unknown) → abort
      esac
      return 0
      ;;
    *) _ACQ_PROMPT_KEY="$k"; return 0 ;;
  esac
}

# _acq_prompt_in_list NEEDLE HAYSTACK... — 0 if NEEDLE is one of the remaining
# args. Used to test membership in the space-separated "checked" set.
_acq_prompt_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# acq_prompt_multiselect LOCKED_N DEFAULTS_CSV LABEL DESC [LABEL DESC ...]
# See the header for the full contract. The chosen indices (relative to the
# toggleable block) are placed in the global _ACQ_PROMPT_SELECTION (space-
# separated; "CANCELLED" on abort) AND echoed on stdout. Prefer the GLOBAL when
# composing widgets in one process (e.g. acq_configure): a `$(...)` capture forks
# a subshell, which would discard the shared scripted-input cursor advance and
# desync a following acq_prompt_confirm.
_ACQ_PROMPT_SELECTION=""
acq_prompt_multiselect() {
  _ACQ_PROMPT_SELECTION=""
  local locked_n="${1:-0}"; shift || true
  local defaults_csv="${1:-}"; shift || true
  case "$locked_n" in ''|*[!0-9]*) locked_n=0 ;; esac

  # Collect items into parallel index/label/desc arrays (bash 3.2 safe). Rows
  # 1..locked_n are frozen (always-applied); rows locked_n+1..n are toggleable.
  local labels=() descs=() n=0
  while [ "$#" -gt 0 ]; do
    labels+=("$(_acq_prompt_sanitize "${1:-}")"); shift || true
    descs+=("$(_acq_prompt_sanitize "${1:-}")"); shift || true
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { _ACQ_PROMPT_SELECTION=""; printf '\n'; return 0; }
  [ "$locked_n" -le "$n" ] || locked_n="$n"
  local first_toggle=$((locked_n + 1))   # absolute index of the first toggleable row

  # Seed the checked set (ABSOLUTE indices) from DEFAULTS_CSV, whose values are
  # RELATIVE to the toggleable block — so add locked_n to map them to absolute.
  local checked="" idx abs
  local _oldifs="$IFS"; IFS=','
  # shellcheck disable=SC2086  # intentional split on comma
  set -- $defaults_csv
  IFS="$_oldifs"
  for idx in "$@"; do
    case "$idx" in
      ''|*[!0-9]*) : ;;   # skip empties / non-numeric
      *)
        abs=$((idx + locked_n))
        [ "$abs" -ge "$first_toggle" ] && [ "$abs" -le "$n" ] && checked="$checked $abs"
        ;;
    esac
  done

  # Non-interactive: emit the defaults verbatim (relative indices) without chrome.
  if ! _acq_prompt_interactive; then
    _ACQ_PROMPT_SELECTION="$(_acq_prompt_rel_indices "$locked_n" "$checked")"
    printf '%s\n' "$_ACQ_PROMPT_SELECTION"
    return 0
  fi

  _acq_prompt_set_colors
  # A standalone multiselect starts a fresh scripted-input read. (acq_configure
  # composes multiselect+confirm in one flow and relies on the SHARED cursor, but
  # it does not pre-seed the cursor either — the first widget in a process resets
  # it here, and the following confirm continues from where this left off.)
  _ACQ_PROMPT_TEST_POS=0
  # Cursor starts on the first toggleable row (locked rows are display-only). If
  # there are no toggleable rows, cursor stays at first_toggle (== n+1) and the
  # only actions are ENTER/QUIT.
  local cursor="$first_toggle" key i mark row line

  # Hide the cursor for the duration and ensure it is restored on any exit path.
  local _prior_int _prior_term
  _prior_int=$(trap -p INT); _prior_term=$(trap -p TERM)
  # shellcheck disable=SC2064
  trap 'printf "\033[?25h" >&2; eval "${_prior_int#trap -- }" 2>/dev/null || true; trap - INT; kill -s INT $$' INT
  [ -z "${ACQ_PROMPT_TEST_INPUT:-}" ] && printf '\033[?25l' >&2

  local rendered=0
  while :; do
    # Repaint: move the cursor up over the previously rendered block (if any),
    # then redraw every row. Header is drawn once above the block.
    if [ "$rendered" -gt 0 ]; then
      printf '\033[%dA' "$rendered" >&2
    else
      printf '%s%s?%s %sSelect kits%s %s(dimmed rows are always applied · ↑/↓ move · SPACE toggle · ENTER confirm · q cancel)%s\n' \
        "$_P_B" "$_P_GRN" "$_P_R" "$_P_B" "$_P_R" "$_P_DIM" "$_P_R" >&2
    fi
    i=1
    while [ "$i" -le "$n" ]; do
      if [ "$i" -le "$locked_n" ]; then
        # Frozen row: always checked, fully dimmed, tagged, no cursor, no toggle.
        line="  ${_P_DIM}[x] ${labels[$((i-1))]}  ${descs[$((i-1))]} (always applied)${_P_R}"
      else
        if _acq_prompt_in_list "$i" $checked; then
          mark="${_P_GRN}[x]${_P_R}"
        else
          mark="[ ]"
        fi
        if [ "$i" -eq "$cursor" ]; then
          row="${_P_CYAN}${_P_B}❯ ${mark} ${labels[$((i-1))]}${_P_R}"
          line="${row}  ${_P_DIM}${descs[$((i-1))]}${_P_R}"
        else
          line="  ${mark} ${labels[$((i-1))]}  ${_P_DIM}${descs[$((i-1))]}${_P_R}"
        fi
      fi
      # Clear the line first (\033[K) so a shorter repaint can't leave residue.
      printf '\033[K%s\n' "$line" >&2
      i=$((i + 1))
    done
    rendered="$n"

    _acq_prompt_read_key
    key="$_ACQ_PROMPT_KEY"
    case "$key" in
      UP)
        # Move within the toggleable block only; wrap top<->bottom. No-op when
        # there are no toggleable rows.
        if [ "$first_toggle" -le "$n" ]; then
          cursor=$((cursor - 1)); [ "$cursor" -lt "$first_toggle" ] && cursor="$n"
        fi
        ;;
      DOWN)
        if [ "$first_toggle" -le "$n" ]; then
          cursor=$((cursor + 1)); [ "$cursor" -gt "$n" ] && cursor="$first_toggle"
        fi
        ;;
      SPACE)
        # Toggle only when the cursor is on a real toggleable row (guard locked).
        if [ "$cursor" -ge "$first_toggle" ] && [ "$cursor" -le "$n" ]; then
          if _acq_prompt_in_list "$cursor" $checked; then
            local new="" c
            for c in $checked; do [ "$c" != "$cursor" ] && new="$new $c"; done
            checked="$new"
          else
            checked="$checked $cursor"
          fi
        fi
        ;;
      ENTER)
        break
        ;;
      QUIT)
        printf '\033[?25h' >&2
        # Restore prior signal traps and abort the SELECTION (empty) — the caller
        # treats an empty line as "keep defaults / no change".
        eval "${_prior_int#trap -- }" 2>/dev/null || trap - INT
        eval "${_prior_term#trap -- }" 2>/dev/null || trap - TERM
        printf '%sacq: selection cancelled; keeping current configuration.%s\n' "$_P_DIM" "$_P_R" >&2
        _ACQ_PROMPT_SELECTION="CANCELLED"
        printf 'CANCELLED\n'
        return 0
        ;;
      *) : ;;   # ignore any other key
    esac
  done

  [ -z "${ACQ_PROMPT_TEST_INPUT:-}" ] && printf '\033[?25h' >&2
  eval "${_prior_int#trap -- }" 2>/dev/null || trap - INT
  eval "${_prior_term#trap -- }" 2>/dev/null || trap - TERM

  # Emit the chosen indices (relative to the toggleable block) in ascending order.
  _ACQ_PROMPT_SELECTION="$(_acq_prompt_rel_indices "$locked_n" "$checked")"
  printf '%s\n' "$_ACQ_PROMPT_SELECTION"
  return 0
}

# _acq_prompt_rel_indices LOCKED_N CHECKED_ABS — echo the checked ABSOLUTE indices
# (a space-separated set) as ascending TOGGLEABLE-RELATIVE indices (abs-LOCKED_N),
# dropping any that fall in the locked range. Keeps the caller's index→name map
# stable regardless of how many rows are frozen.
_acq_prompt_rel_indices() {
  local locked_n="$1" checked="$2" out="" j
  # Ascending sort is unnecessary if we scan positions in order:
  local total=0 c
  for c in $checked; do [ "$c" -gt "$total" ] && total="$c"; done
  j=$((locked_n + 1))
  while [ "$j" -le "$total" ]; do
    _acq_prompt_in_list "$j" $checked && out="$out $((j - locked_n))"
    j=$((j + 1))
  done
  printf '%s' "$(printf '%s' "$out" | sed 's/^ *//')"
}

# acq_prompt_confirm PROMPT DEFAULT  (DEFAULT = yes|no) — colorized [Y/n]/[y/N].
# Returns 0 for yes, 1 for no. Bare ENTER and every non-interactive path use the
# default. Honors ACQ_PROMPT_TEST_INPUT (first token: y/yes → yes, else no).
acq_prompt_confirm() {
  local prompt default="${2:-no}"
  prompt=$(_acq_prompt_sanitize "${1:-Proceed?}")

  local hint
  case "$default" in
    yes|y|Y) default="yes"; hint="[Y/n]" ;;
    *)       default="no";  hint="[y/N]" ;;
  esac

  # Scripted test input takes precedence (the harness drives the answer). Two
  # shapes are supported so tests can drive both a standalone confirm AND a
  # confirm that follows a multiselect in one flow:
  #   - a SINGLE-token script ("y"/"n") is a standalone confirm answer, consumed
  #     without advancing the shared multiselect cursor (so repeated standalone
  #     confirms in one process each see their own single token);
  #   - a MULTI-token script is a whole flow (multiselect keys THEN the confirm
  #     answer): consume the NEXT token from the shared cursor so the confirm
  #     picks up where the multiselect left off.
  # A recognized y/n token decides; anything else → default.
  if [ -n "${ACQ_PROMPT_TEST_INPUT:-}" ]; then
    local _toks answer
    # shellcheck disable=SC2206  # deliberate word-split of the scripted input
    _toks=(${ACQ_PROMPT_TEST_INPUT})
    if [ "${#_toks[@]}" -le 1 ]; then
      answer="${_toks[0]:-}"
    else
      _acq_prompt_read_key
      answer="$_ACQ_PROMPT_KEY"
    fi
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *)           [ "$default" = "yes" ] && return 0 || return 1 ;;
    esac
  fi

  # Non-interactive (CI / piped / opted-out): take the default, never block.
  if ! _acq_prompt_interactive; then
    [ "$default" = "yes" ] && return 0 || return 1
  fi

  _acq_prompt_set_colors
  local ans=""
  printf '%s%s?%s %s %s%s%s ' "$_P_B" "$_P_GRN" "$_P_R" "$prompt" "$_P_DIM" "$hint" "$_P_R" >&2
  read -r ans 2>/dev/null || ans=""
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO)   return 1 ;;
    *)           [ "$default" = "yes" ] && return 0 || return 1 ;;
  esac
}
