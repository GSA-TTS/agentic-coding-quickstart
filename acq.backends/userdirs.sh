#!/bin/bash
#
# acq.backends/userdirs.sh — host-side user directory resolution
#
# acq keeps host-authoritative state, config, secrets and caches under the
# user's XDG base directories. The XDG Base Directory specification requires
# those variables to hold absolute paths: "If an implementation encounters a
# relative path in any of these variables it should consider the path invalid
# and ignore it." A relative value would resolve against the current directory,
# which is normally the workspace a sandboxed agent can write to, so honoring it
# would let guest-writable files stand in for acq's host records, config and
# secrets. This file is the Bash counterpart of py-acq's userdirs/state modules
# and follows the same rules:
#
#   - XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_STATE_HOME / XDG_CACHE_HOME: used
#     only when absolute. An unset, empty or relative value falls back to the
#     documented default under the home directory.
#   - HOME: used only when absolute; otherwise the account's home from the
#     password database (on Git Bash/Cygwin, USERPROFILE). When no absolute home
#     can be found, resolution fails rather than guessing.
#   - ACQ_STATE_DIR (and the secret-store overrides ACQ_SECRET_STORE_DIR and
#     ACQ_SECRET_FILE_DIR): an empty value counts as unset; a relative one is
#     refused. It is an explicit override, so silently replacing it would hide
#     the misconfiguration.
#
# Several adapters assign their path defaults when they are sourced, so this file
# defines functions only and is sourced first by common.sh (and defensively by
# the adapters, which some tests load directly). On failure the resolvers print
# nothing and return 1; the entry point calls acq_userdirs_check before any
# state-touching verb so the user gets one actionable refusal instead.

# acq_path_is_absolute VALUE — true for a non-empty absolute path. On Git Bash /
# Cygwin a drive-rooted form (C:/x or C:\x) is absolute too; on POSIX it is a
# relative name, so it is accepted only there.
acq_path_is_absolute() {
  case "${1:-}" in
    /*) return 0 ;;
  esac
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      case "${1:-}" in
        [A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# _acq_account_home — the account's home directory, ignoring HOME. Prints it and
# returns 0 only when it is absolute.
_acq_account_home() {
  local user="" home=""
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      home="${USERPROFILE:-}"
      if acq_path_is_absolute "$home"; then
        printf '%s\n' "$home"
        return 0
      fi
      home=""
      ;;
  esac
  user=$(id -un 2>/dev/null) || user=""
  # The name reaches a tilde expansion below, so accept only a plain account
  # name (no leading '-', no shell metacharacters).
  case "$user" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  if command -v getent >/dev/null 2>&1; then
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6) || home=""
  fi
  if [ -z "$home" ]; then
    # ~NAME is looked up in the password database and never reads HOME. An
    # unknown name stays a literal "~NAME", which the absolute test rejects.
    eval "home=~$user"
  fi
  acq_path_is_absolute "$home" || return 1
  printf '%s\n' "$home"
}

# acq_home_dir — print an absolute home directory, or return 1.
acq_home_dir() {
  if acq_path_is_absolute "${HOME:-}"; then
    printf '%s\n' "$HOME"
    return 0
  fi
  _acq_account_home
}

# acq_xdg_dir VAR DEFAULT — print one XDG base directory. VAR's value is used
# only when absolute; otherwise the result is the home directory joined with
# DEFAULT (e.g. ".local/state"). Returns 1 when no absolute home exists.
acq_xdg_dir() {
  local var="${1:-}" default="${2:-}" value home
  case "$var" in
    XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_STATE_HOME|XDG_CACHE_HOME) ;;
    *) return 1 ;;
  esac
  value="${!var:-}"
  if acq_path_is_absolute "$value"; then
    printf '%s\n' "$value"
    return 0
  fi
  home=$(acq_home_dir) || return 1
  printf '%s/%s\n' "${home%/}" "$default"
}

# acq_state_dir — print the acq state root: ACQ_STATE_DIR when set (it must be
# absolute; a relative value returns 1), else $XDG_STATE_HOME/acq, else
# ~/.local/state/acq.
acq_state_dir() {
  local base
  if [ -n "${ACQ_STATE_DIR:-}" ]; then
    acq_path_is_absolute "$ACQ_STATE_DIR" || return 1
    printf '%s\n' "$ACQ_STATE_DIR"
    return 0
  fi
  base=$(acq_xdg_dir XDG_STATE_HOME .local/state) || return 1
  printf '%s/acq\n' "$base"
}

# acq_userdirs_check — refuse up front when acq's user directories cannot be
# resolved to absolute paths. Prints the same message and remediation as the
# Python implementation (acq: MESSAGE, then REMEDIATION) on stderr and returns
# 1; returns 0 when every directory resolves.
acq_userdirs_check() {
  local var value
  for var in ACQ_STATE_DIR ACQ_SECRET_STORE_DIR ACQ_SECRET_FILE_DIR; do
    value="${!var:-}"
    if [ -n "$value" ] && ! acq_path_is_absolute "$value"; then
      printf "acq: %s must be an absolute path, got '%s'\n" "$var" "$value" >&2
      case "$var" in
        ACQ_STATE_DIR)
          printf '%s\n' 'set ACQ_STATE_DIR to an absolute path, or unset it to use $XDG_STATE_HOME/acq (default ~/.local/state/acq)' >&2
          ;;
        *)
          printf 'set %s to an absolute path, or unset it to use the default secret store\n' "$var" >&2
          ;;
      esac
      return 1
    fi
  done
  for var in XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME; do
    acq_path_is_absolute "${!var:-}" && continue
    acq_home_dir >/dev/null && return 0
    if [ -n "${HOME+set}" ]; then
      printf "acq: cannot determine an absolute home directory (HOME is '%s')\n" "$HOME" >&2
    else
      printf '%s\n' 'acq: cannot determine an absolute home directory (HOME is unset)' >&2
    fi
    printf '%s\n' 'set HOME to an absolute path, or set the XDG base directory variables (XDG_STATE_HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME) to absolute paths' >&2
    return 1
  done
  return 0
}
