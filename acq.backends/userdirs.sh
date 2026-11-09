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
#     password database, looked up by uid (on Git Bash/Cygwin, USERPROFILE in
#     POSIX form). When no absolute home can be found, resolution fails rather
#     than guessing.
#   - ACQ_STATE_DIR: an empty value counts as unset; a relative one is refused.
#     It is an explicit override, so silently replacing it would hide the
#     misconfiguration.
#   - The per-path overrides (the secret-store directories, ACQ_PROVENANCE_DIR,
#     the msb/sbx kit caches, the msb ssh/ports/clones/staging paths and the
#     others listed in _acq_userdirs_override_problem): refused when relative,
#     for the same reason. py-acq refuses the ones it honours with the same
#     message (userdirs.PATH_OVERRIDES).
#
# Bash keeps more under these directories than Python does (the file-fallback
# secret store and kit caches under XDG_DATA_HOME / XDG_CACHE_HOME, provenance
# under XDG_STATE_HOME even when ACQ_STATE_DIR is set), so acq_userdirs_check
# also requires those to resolve, with a remediation that names them.
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

# acq_quote_value VALUE — print VALUE quoted the way Python's repr() quotes a
# string, so a diagnostic can never carry raw newlines or control characters:
# single quotes (double quotes when VALUE holds a single quote and no double
# quote), with backslash, the chosen quote, \n, \r, \t and other control bytes
# escaped. Bytes >= 0x80 are passed through unchanged.
acq_quote_value() {
  local v="${1-}" q="'" out="" c i n code
  case "$v" in
    *"'"*) case "$v" in *'"'*) ;; *) q='"' ;; esac ;;
  esac
  n=${#v}
  i=0
  while [ "$i" -lt "$n" ]; do
    c="${v:$i:1}"
    case "$c" in
      \\) out="$out\\\\" ;;
      "$q") out="$out\\$q" ;;
      $'\n') out="$out\\n" ;;
      $'\r') out="$out\\r" ;;
      $'\t') out="$out\\t" ;;
      *)
        code=$(LC_ALL=C printf '%d' "'$c" 2>/dev/null) || code=0
        if [ "$code" -ge 0 ] && { [ "$code" -lt 32 ] || [ "$code" -eq 127 ]; }; then
          out="$out$(printf '\\x%02x' "$code")"
        else
          out="$out$c"
        fi
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s%s%s\n' "$q" "$out" "$q"
}

# _acq_posix_profile_path VALUE — USERPROFILE (C:\Users\x) in the shell's POSIX
# form: cygpath -u where present, else the MSYS text form (/c/Users/x).
_acq_posix_profile_path() {
  local p="${1:-}" drive rest out=""
  if command -v cygpath >/dev/null 2>&1; then
    out=$(cygpath -u "$p" 2>/dev/null) || out=""
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  case "$p" in
    [A-Za-z]:[\\/]*)
      drive=$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')
      rest=$(printf '%s' "${p#?:}" | tr '\\' '/')
      printf '/%s%s\n' "$drive" "$rest"
      ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# _acq_account_home — the account's home directory, ignoring HOME. Prints it and
# returns 0 only when it is absolute.
_acq_account_home() {
  local uid="" user="" home=""
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      if acq_path_is_absolute "${USERPROFILE:-}"; then
        home=$(_acq_posix_profile_path "$USERPROFILE")
        if acq_path_is_absolute "$home"; then
          printf '%s\n' "$home"
          return 0
        fi
      fi
      home=""
      ;;
  esac
  if command -v getent >/dev/null 2>&1; then
    # Keyed by uid, like Python's pwd.getpwuid, so directory-service (SSSD/AD)
    # accounts whose names are not plain identifiers still resolve.
    uid=$(id -u 2>/dev/null) || uid=""
    case "$uid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    home=$(getent passwd "$uid" 2>/dev/null | cut -d: -f6) || home=""
  else
    # No getent (macOS): ~NAME is looked up in the password database and never
    # reads HOME. The name reaches eval, so only a plain identifier that cannot
    # be read as a number or an option is accepted. An unknown name stays a
    # literal "~NAME", which the absolute test rejects.
    user=$(id -un 2>/dev/null) || user=""
    case "$user" in
      [A-Za-z_]*) ;;
      *) return 1 ;;
    esac
    case "$user" in
      *[!A-Za-z0-9._-]*) return 1 ;;
    esac
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

# _acq_userdirs_override_problem — check the host path overrides acq honours
# from the environment: each must be absolute when set, since a relative value
# would resolve against the current directory (ACQ_PROVIDER_INPUT_PYTHON names
# an interpreter acq runs on the host). Then check the ACQ_MSB_UPSTREAM_CA_CERT
# and ACQ_FORWARD_HOST_SOCKETS lists. Paths inside the guest
# (ACQ_HOST_CONFIG_GUEST_DIR, ACQ_PROVIDER_INPUT_GUEST_DIR,
# ACQ_MSB_SSH_AGENT_GUEST_SOCK) are not host paths and are not checked. On a
# relative value, set ACQ_USERDIRS_MESSAGE and ACQ_USERDIRS_REMEDIATION and
# return 0; return 1 when every override set is absolute.
_acq_userdirs_override_problem() {
  local var value rest
  for var in ACQ_SECRET_STORE_DIR ACQ_SECRET_FILE_DIR \
      ACQ_PROVENANCE_DIR ACQ_PROVIDER_INPUT_DATA_DIR ACQ_PROVIDER_INPUT_PYTHON \
      ACQ_SECRET_META_DIR ACQ_SECRET_INDEX_FILE \
      ACQ_SBX_KIT_CACHE ACQ_MSB_KIT_CACHE ACQ_MSB_KIT_LOCAL_DIR ACQ_MSB_SSH_DIR ACQ_MSB_SSH_KEY \
      ACQ_MSB_SSH_KNOWN_HOSTS ACQ_MSB_PORTS_DIR ACQ_MSB_CLONES_DIR ACQ_MSB_STARTUP_STAGE_DIR \
      ACQ_MSB_UPSTREAM_CA_FILE ACQ_MSB_BALANCED_HOSTS_FILE; do
    value="${!var:-}"
    if [ -z "$value" ] || acq_path_is_absolute "$value"; then
      continue
    fi
    ACQ_USERDIRS_MESSAGE="$var must be an absolute path, got $(acq_quote_value "$value")"
    case "$var" in
      ACQ_SECRET_STORE_DIR|ACQ_SECRET_FILE_DIR) rest='the default secret store' ;;
      *) rest='the default' ;;
    esac
    ACQ_USERDIRS_REMEDIATION="set $var to an absolute path, or unset it to use $rest"
    return 0
  done
  _acq_userdirs_ca_list_problem && return 0
  _acq_userdirs_socket_list_problem
}

# _acq_userdirs_ca_list_problem — every entry of ACQ_MSB_UPSTREAM_CA_CERT must be
# an absolute POSIX path. The list is split on ':' and whitespace, as its
# consumer splits it, so a drive-letter path (C:/x.pem or C:\x.pem) would
# split into a relative "C" and a remainder; it is refused with the /c/... form
# to use instead.
_acq_userdirs_ca_list_problem() {
  local value rest="${ACQ_MSB_UPSTREAM_CA_CERT:-}" var=ACQ_MSB_UPSTREAM_CA_CERT
  while [ -n "$rest" ]; do
    value="${rest%%[:[:space:]]*}"
    if [ "$value" = "$rest" ]; then rest=""; else rest="${rest#*[:[:space:]]}"; fi
    case "$value:$rest" in
      [A-Za-z]:[\\/]*)
        value="$value:${rest%%[:[:space:]]*}"
        ACQ_USERDIRS_MESSAGE="$var entries must be absolute POSIX paths (the list is split on ':'), got $(acq_quote_value "$value")"
        ACQ_USERDIRS_REMEDIATION="use the POSIX form of a Windows path in $var, e.g. $(acq_quote_value "$(_acq_posix_profile_path "$value")")"
        return 0
        ;;
    esac
    if [ -z "$value" ] || acq_path_is_absolute "$value"; then
      continue
    fi
    ACQ_USERDIRS_MESSAGE="$var entries must be absolute paths, got $(acq_quote_value "$value")"
    ACQ_USERDIRS_REMEDIATION="list absolute PEM paths in $var, or unset it"
    return 0
  done
  return 1
}

# _acq_userdirs_socket_list_problem — the PATH of every ACQ_FORWARD_HOST_SOCKETS
# entry (PATH:PORT[/stream|/dgram], comma-separated) must be absolute, checked
# on the raw value as given, before any symlink resolution.
_acq_userdirs_socket_list_problem() {
  local entry path rest="${ACQ_FORWARD_HOST_SOCKETS:-}"
  while [ -n "$rest" ]; do
    entry="${rest%%,*}"
    if [ "$entry" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    entry="${entry%/stream}"
    entry="${entry%/dgram}"
    path="${entry%:*}"
    if [ -z "$entry" ] || [ "$path" = "$entry" ] || acq_path_is_absolute "$path"; then
      continue
    fi
    ACQ_USERDIRS_MESSAGE="ACQ_FORWARD_HOST_SOCKETS paths must be absolute, got $(acq_quote_value "$path")"
    ACQ_USERDIRS_REMEDIATION='give each ACQ_FORWARD_HOST_SOCKETS entry as /absolute/path.sock:PORT, or unset it'
    return 0
  done
  return 1
}

# _acq_userdirs_need_home VAR... — true when any named XDG variable is not
# absolute (so the home directory is needed) and no absolute home exists.
_acq_userdirs_need_home() {
  local var
  for var in "$@"; do
    acq_path_is_absolute "${!var:-}" && continue
    acq_home_dir >/dev/null && return 1
    return 0
  done
  return 1
}

# _acq_userdirs_no_home_message — the Python "no absolute home" message.
_acq_userdirs_no_home_message() {
  if [ -n "${HOME+set}" ]; then
    printf 'cannot determine an absolute home directory (HOME is %s)' "$(acq_quote_value "$HOME")"
  else
    printf '%s' 'cannot determine an absolute home directory (HOME is unset)'
  fi
}

# acq_userdirs_problem — check that acq's user directories resolve to absolute
# paths, in the Python implementation's order: ACQ_STATE_DIR, then the state
# and config bases. On a problem, set ACQ_USERDIRS_MESSAGE and
# ACQ_USERDIRS_REMEDIATION (the same text Python uses) and return 0; return 1
# when every directory resolves. The path overrides and the Bash-only
# directories (data, cache, and the state base used for provenance) are checked
# last.
acq_userdirs_problem() {
  ACQ_USERDIRS_MESSAGE=""
  ACQ_USERDIRS_REMEDIATION=""
  if [ -n "${ACQ_STATE_DIR:-}" ] && ! acq_path_is_absolute "$ACQ_STATE_DIR"; then
    ACQ_USERDIRS_MESSAGE="ACQ_STATE_DIR must be an absolute path, got $(acq_quote_value "$ACQ_STATE_DIR")"
    ACQ_USERDIRS_REMEDIATION='set ACQ_STATE_DIR to an absolute path, or unset it to use $XDG_STATE_HOME/acq (default ~/.local/state/acq)'
    return 0
  fi
  if { [ -z "${ACQ_STATE_DIR:-}" ] && _acq_userdirs_need_home XDG_STATE_HOME; } \
      || _acq_userdirs_need_home XDG_CONFIG_HOME; then
    ACQ_USERDIRS_MESSAGE=$(_acq_userdirs_no_home_message)
    ACQ_USERDIRS_REMEDIATION='set HOME to an absolute path, or set the XDG base directory variables (XDG_STATE_HOME, XDG_CONFIG_HOME) to absolute paths'
    return 0
  fi
  _acq_userdirs_override_problem && return 0
  if _acq_userdirs_need_home XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME; then
    ACQ_USERDIRS_MESSAGE=$(_acq_userdirs_no_home_message)
    ACQ_USERDIRS_REMEDIATION='set HOME to an absolute path, or set the XDG base directory variables (XDG_STATE_HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME) to absolute paths'
    return 0
  fi
  return 1
}

# acq_require_base LABEL VALUE — guard for a consumer of a resolved directory:
# return 0 when VALUE is non-empty; otherwise say which directory is missing and
# return 1. Defaults derived from an unresolvable user directory are left empty
# (never root-anchored), so every consumer that would build a path, create a
# directory or delete under one calls this first and fails closed.
acq_require_base() {
  [ -n "${2:-}" ] && return 0
  printf 'acq: refusing to use the %s: its directory could not be resolved to an absolute path\n' "${1:-acq directory}" >&2
  printf '%s\n' '     set HOME, or the XDG base directory variables, to absolute paths (see: acq doctor)' >&2
  return 1
}

# acq_userdirs_check — refuse when acq's user directories cannot be resolved:
# print "acq: MESSAGE" and the remediation on stderr (as Python does) and return
# 1; return 0 when every directory resolves.
acq_userdirs_check() {
  acq_userdirs_problem || return 0
  printf 'acq: %s\n%s\n' "$ACQ_USERDIRS_MESSAGE" "$ACQ_USERDIRS_REMEDIATION" >&2
  return 1
}
