#!/bin/bash
# Shared non-mutating catalog compatibility policy; see ADR-0032.
# Constants are also consumed by the MSB adapter and installer diagnostics.
# shellcheck disable=SC2034
MIN_MSB_VERSION="0.6.9"
MSB_BLOCKED_VERSION_MIN="0.7.0"
MSB_BLOCKED_VERSION_MAX="0.7.2"
MSB_PINNED_VERSION="0.7.7"
# Adapter diagnostics consume these constants; standalone recovery does not.
# shellcheck disable=SC2034
MSB_ROLLBACK_VERSION="0.6.18"
# shellcheck disable=SC2034
MSB_FIXED_VERSION="0.7.3"

_acq_msb_version_ge() {
  local a="$1" b="$2" i a_part b_part
  local -a a_arr b_arr
  IFS='.' read -r -a a_arr <<< "$a"
  IFS='.' read -r -a b_arr <<< "$b"
  for i in 0 1 2; do
    a_part=${a_arr[i]:-0}; b_part=${b_arr[i]:-0}
    a_part=${a_part%%[!0-9]*}; b_part=${b_part%%[!0-9]*}
    a_part=${a_part:-0}; b_part=${b_part:-0}
    if [ "$a_part" -gt "$b_part" ]; then echo 0; return; fi
    if [ "$a_part" -lt "$b_part" ]; then echo 1; return; fi
  done
  echo 0
}

_acq_msb_version_blocked() {
  [ "$(_acq_msb_version_ge "$1" "$MSB_BLOCKED_VERSION_MIN")" -eq 0 ] &&
    [ "$(_acq_msb_version_ge "$MSB_BLOCKED_VERSION_MAX" "$1")" -eq 0 ]
}

acq_msb_check_catalog_version() {
  local raw current
  raw=$("$1" --version) || { printf 'Cannot determine MSB version; catalog was not opened.\n' >&2; return 1; }
  current=$(printf '%s\n' "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([+-][^[:space:]]*)?' | head -n1) || return 1
  case "$current" in ''|*[-+]*) printf 'Unsupported or unknown MSB build; catalog was not opened.\n' >&2; return 1 ;; esac
  if [ "$(_acq_msb_version_ge "$current" "$MIN_MSB_VERSION")" -ne 0 ] || _acq_msb_version_blocked "$current"; then
    printf 'Unsupported MSB %s; use a supported final release (prefer %s). Catalog was not opened. See ADR-0032.\n' "$current" "$MSB_PINNED_VERSION" >&2
    return 1
  fi
}
