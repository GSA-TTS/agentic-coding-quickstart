#!/bin/bash
#
# acq.backends/secret-store.sh — acq-owned, backend-neutral secret store
#
# Sourced by common.sh. This is the acq-level secret abstraction the design
# (docs/explorations/acq-design.md §7.5) calls for: ONE store that both the sbx
# and msb adapters read from, so credentials are no longer sbx-specific. It is a
# deliberately THIN bash subset of §7.5 (no Go/go-keyring, no age, no MITM
# CredentialRewriteRule dataclass — those remain the larger future effort). What
# it provides now:
#
#   - A host-side store keyed as `acq.<service>` (global) or
#     `acq.<sandbox>.<service>` (sandbox-scoped), with sandbox-scope taking
#     precedence over global — mirroring §7.5 and the Phase-1 sbx global/sandbox
#     scope that acq already lifted into its abstraction.
#   - Storage in the OS keychain when available (macOS `security`, Linux
#     `secret-tool`), with a 0600 file fallback under
#     $XDG_DATA_HOME/acq/secrets/ when no keychain backend exists.
#   - Read access for adapters at provision time: each backend pulls the real
#     value from here and feeds it to its native injection path (sbx proxy /
#     msb --secret), so the value never enters the guest and never appears in
#     argv (values move via stdin / transient env only).
#
# Trust hygiene (from §7.5, enforced here):
#   - The real value is NEVER passed as a command-line argument (keychain writes
#     read it on stdin; the file fallback writes with a restrictive umask).
#   - The store NEVER prints secret values; acq_debug traces keys only.
#   - Entries are host-only (keychain ACL / 0600 file); nothing is serialized
#     into kit specs, sandbox config, or logs.
#
# Service name conventions (the value stored is the raw secret):
#   usai   — the USAi API key         (host api.gsa.usai.gov, env USAI_API_KEY)
#   github — a GitHub token           (hosts github.com/api.github.com)
# Additional services are accepted verbatim; the adapters decide how to bind.

# acq_debug may not be defined if this file is sourced standalone (e.g. a unit
# test). Provide a no-op fallback so traces never break the store.
if ! command -v acq_debug >/dev/null 2>&1; then
  acq_debug() { [ -n "${ACQ_DEBUG:-}" ] && printf 'acq[debug]: %s\n' "$*" >&2 || true; }
fi

# Keychain "service"/account naming. macOS `security` uses -s SERVICE -a ACCOUNT;
# we put the full acq key in the account and a constant service label so entries
# group under one keychain item type.
ACQ_KEYCHAIN_LABEL="acq-secret-store"

# File-fallback location (used only when no OS keychain tool is present).
ACQ_SECRET_FILE_DIR="${ACQ_SECRET_FILE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/acq/secrets}"

# Offline-test escape hatch: when ACQ_SECRET_STORE_DIR is set, force the file
# backend rooted there (no real keychain touched). Used by scripts/test-acq.
if [ -n "${ACQ_SECRET_STORE_DIR:-}" ]; then
  ACQ_SECRET_FILE_DIR="$ACQ_SECRET_STORE_DIR"
  ACQ_SECRET_FORCE_FILE=1
fi

# ---------------------------------------------------------------------------
# _acq_secret_backend — which store mechanism is active: keychain-macos |
# keychain-linux | file. Respects ACQ_SECRET_FORCE_FILE.
# ---------------------------------------------------------------------------
_acq_secret_backend() {
  if [ -n "${ACQ_SECRET_FORCE_FILE:-}" ]; then
    printf 'file\n'; return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) command -v security >/dev/null 2>&1 && { printf 'keychain-macos\n'; return 0; } ;;
    *)      command -v secret-tool >/dev/null 2>&1 && { printf 'keychain-linux\n'; return 0; } ;;
  esac
  printf 'file\n'
}

# ---------------------------------------------------------------------------
# _acq_secret_key SERVICE [SANDBOX] — compute the store key.
#   acq.<service>              (global)
#   acq.<sandbox>.<service>    (sandbox-scoped)
# ---------------------------------------------------------------------------
_acq_secret_key() {
  local service="$1" sandbox="${2:-}"
  if [ -n "$sandbox" ]; then
    printf 'acq.%s.%s\n' "$sandbox" "$service"
  else
    printf 'acq.%s\n' "$service"
  fi
}

# Sanitize a key into a filesystem-safe filename for the file backend.
_acq_secret_file_for() {
  local key="$1"
  printf '%s/%s\n' "$ACQ_SECRET_FILE_DIR" "$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
}

# ---------------------------------------------------------------------------
# acq_secret_store KEY  (value on STDIN)
# ---------------------------------------------------------------------------
# Store a secret VALUE (read from stdin, never argv) under KEY. Overwrites any
# existing entry. Returns 0 on success.
acq_secret_store() {
  local key="$1" value
  # Read exactly one line (the secret) from stdin without echoing/splitting.
  IFS= read -r value || true
  if [ -z "$value" ]; then
    echo "acq: secret store: empty value for '$key'; nothing stored." >&2
    return 1
  fi

  local backend
  backend=$(_acq_secret_backend)
  acq_debug "secret store: key=$key backend=$backend"

  case "$backend" in
    keychain-macos)
      # -U updates if present; -w reads the password... but -w VALUE would put it
      # in argv. Use -w with stdin is not supported; instead pipe via -w with a
      # here-string is still argv. macOS `security add-generic-password` has no
      # stdin password mode, so we fall back to the file backend when we must
      # avoid argv. To keep the value off argv, use the file backend on macOS
      # too UNLESS the caller accepts argv exposure. We choose safety: store to
      # keychain via a temp file is not possible; so use `security` with the
      # value only if ACQ_SECRET_ALLOW_ARGV=1, else file.
      if [ -n "${ACQ_SECRET_ALLOW_ARGV:-}" ]; then
        security add-generic-password -U \
          -s "$ACQ_KEYCHAIN_LABEL" -a "$key" -w "$value" >/dev/null 2>&1 || {
            echo "acq: secret store: keychain write failed for '$key'." >&2; return 1; }
        value=""
        return 0
      fi
      # Default macOS path: 0600 file fallback (keeps the value off argv, which
      # is the stronger guarantee; see trust hygiene rule 1).
      _acq_secret_store_file "$key" "$value"; local rc=$?; value=""; return $rc
      ;;
    keychain-linux)
      # secret-tool reads the secret from STDIN — never argv. Ideal.
      printf '%s' "$value" | secret-tool store --label="$ACQ_KEYCHAIN_LABEL" \
        acq_key "$key" >/dev/null 2>&1 || {
          echo "acq: secret store: keychain write failed for '$key'." >&2; value=""; return 1; }
      value=""
      return 0
      ;;
    file)
      _acq_secret_store_file "$key" "$value"; local rc=$?; value=""; return $rc
      ;;
  esac
}

# 0600 file write (value already in $2). Uses umask so the value is never in argv.
_acq_secret_store_file() {
  local key="$1" value="$2" f
  f=$(_acq_secret_file_for "$key")
  ( umask 077; mkdir -p "$ACQ_SECRET_FILE_DIR" ) || return 1
  ( umask 077; printf '%s' "$value" > "$f" ) || {
    echo "acq: secret store: file write failed for '$key'." >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# acq_secret_get KEY  ->  value on STDOUT (empty + non-zero if absent)
# ---------------------------------------------------------------------------
acq_secret_get() {
  local key="$1" backend value
  backend=$(_acq_secret_backend)
  case "$backend" in
    keychain-macos)
      if [ -z "${ACQ_SECRET_ALLOW_ARGV:-}" ]; then
        # Value was stored in the file fallback (see acq_secret_store note).
        _acq_secret_get_file "$key"; return $?
      fi
      value=$(security find-generic-password -s "$ACQ_KEYCHAIN_LABEL" -a "$key" -w 2>/dev/null) || return 1
      [ -n "$value" ] || return 1
      printf '%s' "$value"
      ;;
    keychain-linux)
      value=$(secret-tool lookup acq_key "$key" 2>/dev/null) || return 1
      [ -n "$value" ] || return 1
      printf '%s' "$value"
      ;;
    file)
      _acq_secret_get_file "$key"; return $?
      ;;
  esac
}

_acq_secret_get_file() {
  local key="$1" f
  f=$(_acq_secret_file_for "$1")
  [ -f "$f" ] || return 1
  cat "$f"
}

# ---------------------------------------------------------------------------
# acq_secret_resolve SERVICE [SANDBOX]  ->  value on STDOUT
# ---------------------------------------------------------------------------
# Resolve a service's secret with sandbox-scope precedence: try
# acq.<sandbox>.<service> first, then fall back to acq.<service>. Empty +
# non-zero if neither exists. This is the read path adapters use at provision.
acq_secret_resolve() {
  local service="$1" sandbox="${2:-}" v
  if [ -n "$sandbox" ]; then
    if v=$(acq_secret_get "$(_acq_secret_key "$service" "$sandbox")" 2>/dev/null) && [ -n "$v" ]; then
      printf '%s' "$v"; return 0
    fi
  fi
  if v=$(acq_secret_get "$(_acq_secret_key "$service")" 2>/dev/null) && [ -n "$v" ]; then
    printf '%s' "$v"; return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# acq_secret_has SERVICE [SANDBOX]  ->  0 if a value resolves, else 1
# ---------------------------------------------------------------------------
acq_secret_has() {
  acq_secret_resolve "$1" "${2:-}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# acq_secret_set_interactive SERVICE [SANDBOX]
# ---------------------------------------------------------------------------
# Read a secret from a TTY (silent) or piped stdin (no prompt) and store it
# under the resolved key. Never places the value in argv. Used by
# `acq secret set` in the adapters. ACQ_SECRET_TEST_VALUE is an offline-test
# escape hatch (no TTY in CI); never set it in production.
acq_secret_set_interactive() {
  local service="$1" sandbox="${2:-}" key value
  key=$(_acq_secret_key "$service" "$sandbox")

  if [ -n "${ACQ_SECRET_TEST_VALUE:-}" ]; then
    value="$ACQ_SECRET_TEST_VALUE"
  elif [ ! -t 0 ]; then
    IFS= read -r value || true
  else
    printf 'Enter %s secret: ' "$service" >&2
    # shellcheck disable=SC2162
    read -rs value 2>/dev/null || read -r value
    printf '\n' >&2
  fi

  if [ -z "$value" ]; then
    echo "acq: no secret entered; aborting." >&2
    return 1
  fi
  printf '%s' "$value" | acq_secret_store "$key"
  local rc=$?
  value=""
  if [ "$rc" -eq 0 ]; then
    echo "acq: ${service} secret stored (${key})." >&2
  fi
  return "$rc"
}
