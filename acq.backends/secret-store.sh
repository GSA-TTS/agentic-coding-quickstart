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
#   - Storage in the OS keychain when available (macOS `security -i`, Linux
#     `secret-tool`), Windows DPAPI (Keychain-equivalent, user-scoped) via
#     in-box PowerShell, and a 0600 file fallback under
#     $XDG_DATA_HOME/acq/secrets/ when no protected backend exists. The Windows
#     backend wraps each value in a versioned envelope and migrates a legacy
#     plaintext value on first read, so switching backends never mis-reads the
#     shared file path in either direction (see the keychain-windows notes).
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

# Versioned envelope header for values written by the Windows DPAPI backend. That
# backend shares the plaintext file fallback's path, so this header (the file's
# first line — see the keychain-windows notes below) is what tells a DPAPI
# ciphertext apart from a legacy plaintext value. Bump the version suffix if the
# envelope format ever changes.
ACQ_SECRET_DPAPI_HEADER="acq-dpapi-v1"

# File-fallback location (used only when no OS keychain tool is present).
ACQ_SECRET_FILE_DIR="${ACQ_SECRET_FILE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/acq/secrets}"

# Offline-test escape hatch: when ACQ_SECRET_STORE_DIR is set, force the file
# backend rooted there (no real keychain touched). Used by the offline test suite.
if [ -n "${ACQ_SECRET_STORE_DIR:-}" ]; then
  ACQ_SECRET_FILE_DIR="$ACQ_SECRET_STORE_DIR"
  ACQ_SECRET_FORCE_FILE=1
fi

# ---------------------------------------------------------------------------
# _acq_secret_backend — which store mechanism is active: keychain-macos |
# keychain-linux | keychain-windows | file. Respects ACQ_SECRET_FORCE_FILE.
# ---------------------------------------------------------------------------
_acq_secret_security_bin() {
  if [ -n "${ACQ_SECRET_STORE_DIR:-}" ] && [ -n "${ACQ_SECRET_SECURITY_BIN:-}" ]; then
    printf '%s\n' "$ACQ_SECRET_SECURITY_BIN"
    return 0
  fi
  printf '/usr/bin/security\n'
}

# PowerShell drives the Windows DPAPI backend (see _acq_secret_store_windows).
# Like the macOS security override, ACQ_SECRET_POWERSHELL_BIN is a test-only
# escape hatch honored only alongside ACQ_SECRET_STORE_DIR, so production never
# honors it.
_acq_secret_powershell_bin() {
  if [ -n "${ACQ_SECRET_STORE_DIR:-}" ] && [ -n "${ACQ_SECRET_POWERSHELL_BIN:-}" ]; then
    printf '%s\n' "$ACQ_SECRET_POWERSHELL_BIN"
    return 0
  fi
  printf 'powershell.exe\n'
}

_acq_secret_backend() {
  if [ -n "${ACQ_SECRET_FORCE_FILE:-}" ]; then
    printf 'file\n'; return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) [ -x "$(_acq_secret_security_bin)" ] && { printf 'keychain-macos\n'; return 0; } ;;
    MINGW*|MSYS*|CYGWIN*)
      # Git Bash on Windows has neither a keychain nor secret-tool, so the plain
      # file fallback would leave secrets in cleartext on NTFS (which cannot
      # enforce 0600). Use Windows DPAPI via in-box PowerShell instead
      # (ADR-0028); fall back to the file backend only if PowerShell is absent.
      command -v "$(_acq_secret_powershell_bin)" >/dev/null 2>&1 && { printf 'keychain-windows\n'; return 0; } ;;
    *)      command -v secret-tool >/dev/null 2>&1 && { printf 'keychain-linux\n'; return 0; } ;;
  esac
  printf 'file\n'
}

# ---------------------------------------------------------------------------
# _acq_secret_key SERVICE [SANDBOX] — compute the store key.
#   acq.<service>              (global)
#   acq.<sandbox>.<service>    (sandbox-scoped)
#
# The key format uses '.' as the scope separator, so SERVICE and SANDBOX must be
# simple acq slugs. Sandbox names are always slugified upstream (common.sh
# slugify -> [a-z0-9-]) and acq's own service names are slug-like. We enforce
# that invariant here — the single choke point both the value store and the meta
# sidecar share — so no caller can smuggle a separator/control-character-bearing
# name past the store and silently alias another scope or affect a keychain
# command stream. Fail closed rather than emit an ambiguous key.
_acq_secret_key() {
  local service="$1" sandbox="${2:-}"
  # Keep both segments to the existing acq/service slug alphabet. A '.' would
  # break the acq.<sandbox>.<service> separator; control characters could split a
  # macOS `security -i` command stream; other punctuation is unnecessary for the
  # supported services and sandbox slugs. Emit no key and return non-zero so the
  # caller fails visibly rather than reading/writing an aliased or injected entry.
  case "$service" in
    ""|*[!A-Za-z0-9_-]*)
      acq_debug "secret key: refusing unsafe service name '$service'"
      return 1
      ;;
  esac
  case "$sandbox" in
    *[!A-Za-z0-9_-]*)
      acq_debug "secret key: refusing unsafe sandbox name '$sandbox'"
      return 1
      ;;
  esac
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

# Quote one token for macOS `security -i`'s command stream. We terminate the
# stream with EOF, not a literal `quit`; the latter fails on some macOS releases.
_acq_secret_security_i_quote() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

_acq_secret_value_is_storable() {
  local value="$1" nl tab
  nl=$(printf '\n_'); nl=${nl%_}
  tab=$(printf '\t')
  case "$value" in
    *"$nl"*) return 1 ;;
    *"$tab"*) return 1 ;;
    *) return 0 ;;
  esac
}

_acq_secret_store_keychain_macos() {
  local key="$1" value="$2" cmd security_bin
  security_bin=$(_acq_secret_security_bin)
  cmd="add-generic-password -U -s $(_acq_secret_security_i_quote "$ACQ_KEYCHAIN_LABEL") -a $(_acq_secret_security_i_quote "$key") -w $(_acq_secret_security_i_quote "$value")"
  printf '%s\n' "$cmd" | "$security_bin" -i >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Windows DPAPI (keychain-windows): encrypt/decrypt a value with the Windows
# Data Protection API scoped to the CURRENT USER, via in-box Windows PowerShell
# (`powershell.exe`, 5.1 — its System.Security assembly exposes ProtectedData
# with no added dependency). Plaintext moves over stdin and ciphertext/base64
# over stdout, so the value never reaches argv. This is the Windows analogue of
# a keychain: the ciphertext lives in the same file layout as the plaintext
# fallback but is readable only by the same Windows account, removing the
# NTFS-cannot-enforce-0600 weakness (see ADR-0028).
#
# ENVELOPE: because the file path is shared with the plaintext `file` backend,
# the raw bytes alone cannot distinguish a DPAPI ciphertext from a legacy
# plaintext value. Every value this backend writes is therefore wrapped in a
# versioned envelope — first line ACQ_SECRET_DPAPI_HEADER, second line the base64
# ciphertext. Stored plaintext is always a single line (acq_secret_store reads
# exactly one line), so a first line equal to the header can never be a plaintext
# value and the two shapes are unambiguous. That makes a backend switch safe in
# both directions:
#   - Windows reading an UNMARKED file = a legacy plaintext value the file
#     backend left behind. It is returned as-is and re-encrypted in place, so an
#     upgrade neither loses the secret nor leaves the plaintext at rest.
#   - `file` reading a MARKED file = ciphertext it cannot decrypt; it fails
#     closed (_acq_secret_get_file) rather than exporting the blob as the secret.
# ---------------------------------------------------------------------------
_acq_secret_windows_encrypt() {
  local ps; ps=$(_acq_secret_powershell_bin)
  "$ps" -NoLogo -NoProfile -Command '$ErrorActionPreference="Stop"; Add-Type -AssemblyName System.Security; $i=[Console]::In.ReadToEnd(); $b=[Text.Encoding]::UTF8.GetBytes($i); [Console]::Out.Write([Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)))' 2>/dev/null
}

_acq_secret_windows_decrypt() {
  local ps; ps=$(_acq_secret_powershell_bin)
  "$ps" -NoLogo -NoProfile -Command '$ErrorActionPreference="Stop"; Add-Type -AssemblyName System.Security; $i=[Console]::In.ReadToEnd(); $e=[Convert]::FromBase64String($i.Trim()); [Console]::Out.Write([Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($e,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)))' 2>/dev/null
}

# _acq_secret_file_is_dpapi_envelope FILE -> 0 if FILE's first line is the DPAPI
# envelope header. Stored plaintext is a single line, so an unmarked file cannot
# be mistaken for an envelope (see the ENVELOPE note above).
_acq_secret_file_is_dpapi_envelope() {
  local header
  IFS= read -r header < "$1" 2>/dev/null || true
  [ "$header" = "$ACQ_SECRET_DPAPI_HEADER" ]
}

# Encrypt VALUE and write the header + base64 ciphertext to the key's file path.
# The file is written with umask 077 like the plaintext fallback (defense in
# depth), but the DPAPI envelope is what actually protects it on NTFS.
_acq_secret_store_windows() {
  local key="$1" value="$2" f enc
  f=$(_acq_secret_file_for "$key")
  enc=$(printf '%s' "$value" | _acq_secret_windows_encrypt) || {
    echo "acq: secret store: Windows DPAPI encryption failed for '$key'." >&2; return 1; }
  [ -n "$enc" ] || {
    echo "acq: secret store: Windows DPAPI produced no ciphertext for '$key'." >&2; return 1; }
  ( umask 077; mkdir -p "$ACQ_SECRET_FILE_DIR" ) || return 1
  ( umask 077; printf '%s\n%s' "$ACQ_SECRET_DPAPI_HEADER" "$enc" > "$f" ) || {
    echo "acq: secret store: file write failed for '$key'." >&2; return 1; }
  return 0
}

# Best-effort migration of a legacy plaintext value to a DPAPI envelope. Writes
# atomically (hidden temp + rename) with umask 077, so a failure never damages
# the still-readable legacy value and never fails the read that triggered it (a
# later read retries). The temp name's leading dot keeps it out of the `acq.*`
# glob the file lister uses.
_acq_secret_migrate_windows() {
  local key="$1" value="$2" f tmp enc
  f=$(_acq_secret_file_for "$key")
  enc=$(printf '%s' "$value" | _acq_secret_windows_encrypt) || return 0
  [ -n "$enc" ] || return 0
  tmp="$(dirname "$f")/.${key}.tmp.$$"
  ( umask 077; printf '%s\n%s' "$ACQ_SECRET_DPAPI_HEADER" "$enc" > "$tmp" ) || {
    rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  return 0
}

# Read the key's value. A marked file is decrypted; an unmarked file is a legacy
# plaintext value that is returned as-is and migrated in place (see the ENVELOPE
# note above). A missing file, an undecryptable envelope (wrong user/machine, or
# corruption), or a lost DPAPI key all surface as a non-zero return so callers
# treat the secret as absent rather than using a truncated value.
_acq_secret_get_windows() {
  local key="$1" f value
  f=$(_acq_secret_file_for "$key")
  [ -f "$f" ] || return 1
  if _acq_secret_file_is_dpapi_envelope "$f"; then
    value=$(tail -n +2 "$f" | _acq_secret_windows_decrypt) || return 1
  else
    value=$(cat "$f") || return 1
    _acq_secret_migrate_windows "$key" "$value"
  fi
  [ -n "$value" ] || return 1
  printf '%s' "$value"
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
      # `security add-generic-password -w VALUE` puts VALUE on argv. Use
      # `security -i` instead: the command stream is stdin, terminated by EOF, so
      # the secret never appears in the process table. If that path fails, fail
      # closed rather than silently downgrading a keychain-capable host to a
      # plaintext file.
      _acq_secret_store_keychain_macos "$key" "$value" || {
        echo "acq: secret store: macOS keychain write failed for '$key'." >&2
        value=""
        return 1
      }
      value=""
      _acq_secret_delete_file "$key" || return 1
      _acq_secret_index_add "$key"
      return 0
      ;;
    keychain-linux)
      # secret-tool reads the secret from STDIN — never argv. Ideal.
      printf '%s' "$value" | secret-tool store --label="$ACQ_KEYCHAIN_LABEL" \
        acq_key "$key" >/dev/null 2>&1 || {
          echo "acq: secret store: keychain write failed for '$key'." >&2; value=""; return 1; }
      value=""
      # Record the key in the enumeration index so `acq secret ls` can list it:
      # secret-tool cannot enumerate items by attribute name alone (see the
      # ACQ_SECRET_INDEX_FILE note), so the keychain store is otherwise opaque.
      _acq_secret_index_add "$key"
      return 0
      ;;
    file)
      _acq_secret_store_file "$key" "$value"; local rc=$?; value=""; return $rc
      ;;
    keychain-windows)
      # Encrypt with DPAPI and write the ciphertext to the key's file path (see
      # _acq_secret_store_windows). No index is needed: the file lister
      # enumerates the encrypted files directly.
      _acq_secret_store_windows "$key" "$value" || { value=""; return 1; }
      value=""
      return 0
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
  local key="$1" backend value security_bin
  backend=$(_acq_secret_backend)
  case "$backend" in
    keychain-macos)
      # Prefer the Keychain. Fall back to the old 0600 file location so existing
      # macOS installs that wrote before the `security -i` path keep working until
      # the user re-saves or removes those entries.
      security_bin=$(_acq_secret_security_bin)
      value=$("$security_bin" find-generic-password -s "$ACQ_KEYCHAIN_LABEL" -a "$key" -w 2>/dev/null || true)
      if [ -n "$value" ]; then printf '%s' "$value"; return 0; fi
      _acq_secret_get_file "$key"; return $?
      ;;
    keychain-linux)
      value=$(secret-tool lookup acq_key "$key" 2>/dev/null) || return 1
      [ -n "$value" ] || return 1
      printf '%s' "$value"
      ;;
    file)
      _acq_secret_get_file "$key"; return $?
      ;;
    keychain-windows)
      _acq_secret_get_windows "$key"; return $?
      ;;
  esac
}

_acq_secret_get_file() {
  local key="$1" f
  f=$(_acq_secret_file_for "$1")
  [ -f "$f" ] || return 1
  # A DPAPI envelope here means the Windows backend wrote it but this (plaintext)
  # backend is active — PowerShell became unavailable, or the store moved between
  # hosts/users. We cannot decrypt it, and returning the base64 blob would make
  # callers treat ciphertext as the secret (exporting or binding it), so fail
  # closed. See the keychain-windows ENVELOPE note.
  _acq_secret_file_is_dpapi_envelope "$f" && return 1
  cat "$f"
}

# ---------------------------------------------------------------------------
# Per-service ENDPOINT METADATA (host/env) — non-secret sidecar
# ---------------------------------------------------------------------------
# The value store above holds only the raw secret. To bind a CUSTOM-endpoint
# service generically (e.g. `msb --secret ENV@HOST`) both backends need to know
# WHICH host(s) and env var a stored service maps to. Built-ins (usai, github)
# have a compiled-in table (_acq_service_hosts_env / _acq_msb_service_binding);
# an arbitrary `acq secret set SVC --host H --env E` had nowhere to record H/E.
#
# We persist that mapping as a NON-SECRET sidecar (host + env only — never the
# value) under $ACQ_SECRET_META_DIR, keyed like the value store
# (acq.<service> / acq.<sandbox>.<service>). It is deliberately a plain file
# (not the keychain): it carries no secret, and both backends must read it at
# provision. Format is a single line "HOST<TAB>ENV" (HOST may be a
# comma-separated multi-host list, mirroring sbx set-custom breadth).
#
# BACKWARD COMPATIBILITY: absence of a sidecar => no metadata => callers fall
# back to their existing built-in table / prior behavior. Existing stored
# secrets (value-only, no sidecar) are unaffected.
ACQ_SECRET_META_DIR="${ACQ_SECRET_META_DIR:-${ACQ_SECRET_FILE_DIR%/secrets}/secret-meta}"
if [ -n "${ACQ_SECRET_STORE_DIR:-}" ]; then
  # Offline-test escape hatch: keep metadata beside the forced file store.
  ACQ_SECRET_META_DIR="${ACQ_SECRET_STORE_DIR%/}/meta"
fi

# Enumerable KEY INDEX (keychain-backed stores) — a NON-SECRET plain file
# listing one stored `acq.*` key per line. OS keychains can look values up by
# account/attribute but cannot cheaply enumerate every acq item without already
# knowing the keys. We record each stored key here so `acq secret ls` can
# enumerate keychain-backed stores the same way the file backend enumerates its
# directory. Like the endpoint sidecar, this holds KEYS ONLY (no secret values,
# no hosts) and is a plain 0600 file, not the keychain. The file backend does NOT
# use this index — its file directory is already the authoritative on-disk
# listing.
ACQ_SECRET_INDEX_FILE="${ACQ_SECRET_INDEX_FILE:-${ACQ_SECRET_FILE_DIR%/secrets}/secret-index}"
if [ -n "${ACQ_SECRET_STORE_DIR:-}" ]; then
  # Offline-test escape hatch: keep the index beside the forced file store.
  ACQ_SECRET_INDEX_FILE="${ACQ_SECRET_STORE_DIR%/}/index"
fi

# _acq_secret_index_add KEY — record KEY in the keychain enumeration index
# (deduplicated, 0600). Non-secret (a key name only). Best-effort: a failure to
# update the index never fails the store — it only degrades later enumeration.
_acq_secret_index_add() {
  local key="$1" dir line
  dir=$(dirname "$ACQ_SECRET_INDEX_FILE")
  ( umask 077; mkdir -p "$dir" ) || return 0
  # Already present? Nothing to do (keeps the file deduplicated).
  if [ -f "$ACQ_SECRET_INDEX_FILE" ]; then
    while IFS= read -r line; do
      [ "$line" = "$key" ] && return 0
    done < "$ACQ_SECRET_INDEX_FILE"
  fi
  ( umask 077; printf '%s\n' "$key" >> "$ACQ_SECRET_INDEX_FILE" ) || true
  return 0
}

# _acq_secret_index_remove KEY — drop KEY from the keychain enumeration index
# (idempotent). Best-effort: never fails delete.
_acq_secret_index_remove() {
  local key="$1" tmp
  [ -f "$ACQ_SECRET_INDEX_FILE" ] || return 0
  tmp="${ACQ_SECRET_INDEX_FILE}.tmp.$$"
  ( umask 077
    while IFS= read -r line; do
      [ "$line" = "$key" ] && continue
      printf '%s\n' "$line"
    done < "$ACQ_SECRET_INDEX_FILE" > "$tmp"
  ) || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$ACQ_SECRET_INDEX_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

_acq_secret_meta_file_for() {
  local key="$1"
  printf '%s/%s\n' "$ACQ_SECRET_META_DIR" "$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
}

# acq_secret_meta_store SERVICE SANDBOX HOST ENV
# Persist the (host, env) endpoint mapping for a service. HOST/ENV are validated
# (charset-restricted) so a hostile value can never smuggle a flag into a later
# `--secret ENV@HOST` argv. A comma-separated multi-host HOST is allowed. Empty
# HOST or ENV => nothing stored (nothing to bind). Never touches the value store.
acq_secret_meta_store() {
  local service="$1" sandbox="${2:-}" host="$3" env="$4" key f
  [ -n "$host" ] && [ -n "$env" ] || return 0
  # Env var name must be a POSIX-ish identifier; hosts are DNS names/wildcards
  # optionally comma-separated. Reject anything else (defense before argv use).
  case "$env" in
    ""|*[!A-Za-z0-9_]*) acq_debug "secret meta: refusing unsafe env '$env' for '$service'"; return 1 ;;
  esac
  case "$host" in
    ""|*[!A-Za-z0-9.,*_-]*) acq_debug "secret meta: refusing unsafe host '$host' for '$service'"; return 1 ;;
  esac
  # _acq_secret_key fails closed (empty output, non-zero) on a name that would
  # make the key non-injective (a dotted service/sandbox).
  # Refuse to write a sidecar in that case rather than aliasing another scope.
  key=$(_acq_secret_key "$service" "$sandbox") || {
    echo "acq: secret meta: refusing to store '$service' — ambiguous scope name." >&2
    return 1
  }
  f=$(_acq_secret_meta_file_for "$key")
  ( umask 077; mkdir -p "$ACQ_SECRET_META_DIR" ) || return 1
  ( umask 077; printf '%s\t%s\n' "$host" "$env" > "$f" ) || {
    echo "acq: secret meta: write failed for '$key'." >&2; return 1; }
  acq_debug "secret meta: stored host/env for $key"
  return 0
}

# acq_secret_meta_resolve SERVICE [SANDBOX] -> "HOST<TAB>ENV" on STDOUT
# Sandbox-scope precedence (like acq_secret_resolve): try the scoped sidecar
# first, then global. Empty + non-zero if neither exists. Non-secret; safe to
# print (host + env only).
acq_secret_meta_resolve() {
  local service="$1" sandbox="${2:-}" f line key
  if [ -n "$sandbox" ]; then
    # _acq_secret_key fails closed on an ambiguous (dotted) name; skip that
    # lookup rather than probing a malformed path.
    if key=$(_acq_secret_key "$service" "$sandbox"); then
      f=$(_acq_secret_meta_file_for "$key")
      if [ -f "$f" ] && IFS= read -r line < "$f" && [ -n "$line" ]; then
        printf '%s\n' "$line"; return 0
      fi
    fi
  fi
  if key=$(_acq_secret_key "$service"); then
    f=$(_acq_secret_meta_file_for "$key")
    if [ -f "$f" ] && IFS= read -r line < "$f" && [ -n "$line" ]; then
      printf '%s\n' "$line"; return 0
    fi
  fi
  return 1
}

# acq_secret_meta_resolve_exact SERVICE [SANDBOX] -> "HOST<TAB>ENV" on STDOUT
# EXACT-scope variant of acq_secret_meta_resolve: no sandbox->global fallback.
# The sbx rm path uses it (#384 review): a GLOBAL sidecar must never steer a
# sandbox-scoped DESTRUCTIVE placeholder removal toward an entry the sidecar
# never described.
acq_secret_meta_resolve_exact() {
  local service="$1" sandbox="${2:-}" f line key
  key=$(_acq_secret_key "$service" "$sandbox") || return 1
  f=$(_acq_secret_meta_file_for "$key")
  if [ -f "$f" ] && IFS= read -r line < "$f" && [ -n "$line" ]; then
    printf '%s\n' "$line"; return 0
  fi
  return 1
}

# acq_secret_meta_delete SERVICE [SANDBOX] — remove the sidecar (idempotent).
acq_secret_meta_delete() {
  local service="$1" sandbox="${2:-}" f key
  # An ambiguous (dotted) name has no valid key, hence no sidecar to remove;
  # treat as a no-op success.
  key=$(_acq_secret_key "$service" "$sandbox") || return 0
  f=$(_acq_secret_meta_file_for "$key")
  [ -e "$f" ] && rm -f "$f" 2>/dev/null
  return 0
}

# acq_secret_meta_list [SANDBOX] -> service names (one per line) that have an
# endpoint sidecar in this SANDBOX scope OR the global scope. Used by the msb
# adapter at provision to discover every custom-endpoint service to bind
# generically. Deduplicated; order is unspecified. Non-secret.
#
# Sidecar files are named after the store key with non-[A-Za-z0-9._-] chars
# mapped to '_' (see _acq_secret_meta_file_for). We recover the service name
# from the key: global keys are `acq.<service>`; scoped keys are
# `acq.<sandbox>.<service>`. Only entries matching the requested scope (scoped
# for SANDBOX, plus all global) are emitted.
#
# ROBUSTNESS: the `acq.<sandbox>.<service>` layout uses
# '.' as the scope separator, so the old "split on the FIRST dot" mis-scoped a
# key whose scope segment itself contained a dot — a GLOBAL service literally
# named "foo.bar" (`acq.foo.bar`) was misread as sandbox="foo" service="bar".
# New writes can no longer create such a key (_acq_secret_key now rejects a
# dotted service/sandbox — see its note), so a dotted key is only reachable from
# a sidecar written by an OLDER build. We classify without guessing:
#
#   1. A key scoped to the REQUESTED sandbox is recognized by the exact
#      `acq.<sandbox>.` prefix (anchored on the known sandbox, not a blind
#      split); the remainder is the service.
#   2. A dot-free `acq.<service>` key is the (current-build) GLOBAL case.
#   3. Any OTHER dotted `acq.<rest>` key is either a DIFFERENT sandbox's scope
#      or a legacy dotted global. Both are ambiguous by filename alone, both are
#      unreachable by construction going forward, and neither should bind for
#      the requested scope — so it is SKIPPED (never mis-attributed to global,
#      never mis-scoped to this sandbox). This preserves the pre-fix semantics
#      that foreign scopes are invisible, and removes the mis-scope entirely.
#
# meta_list and meta_resolve therefore agree: meta_list emits only the global
# services meta_resolve(svc) (no sandbox) would find, plus this sandbox's scoped
# services meta_resolve(svc, sandbox) would find.
acq_secret_meta_list() {
  local sandbox="${1:-}" f base svc rest seen=" "
  [ -d "$ACQ_SECRET_META_DIR" ] || return 0
  for f in "$ACQ_SECRET_META_DIR"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    svc=""
    case "$base" in
      acq.*) rest="${base#acq.}" ;;
      *) continue ;;   # foreign file — not one of our keys
    esac
    if [ -n "$sandbox" ] && [ "${base#acq.${sandbox}.}" != "$base" ]; then
      # (1) Scoped to the requested sandbox.
      svc="${base#acq.${sandbox}.}"
    else
      case "$rest" in
        *.*) svc="" ;;   # (3) foreign/legacy dotted key — skip (see note above)
        *)   svc="$rest" ;;   # (2) dot-free global service
      esac
    fi
    [ -n "$svc" ] || continue
    case "$seen" in *" $svc "*) continue ;; esac
    seen="$seen$svc "
    printf '%s\n' "$svc"
  done
}

# acq_secret_list_keys -> every stored VALUE key (one per line), e.g.
# `acq.usai`, `acq.mybox.github`. KEYS ONLY — never the secret values. Used by
# `acq secret ls` to enumerate what the store holds. Scope/service is decoded by
# the caller (see _acq_secret_decode_key). Order is unspecified; deduplicated.
#
# Enumeration is BACKEND-AWARE, because the two store shapes are enumerated
# differently:
#
#   file: the file directory IS the authoritative listing. We glob the directory
#     for `acq.*` filenames exactly as before.
#
#   keychain-macos / keychain-linux: the secret VALUES live in the OS keychain,
#     NOT in the file dir, and neither keychain can enumerate every item by our
#     account/attribute without already knowing the keys. We therefore enumerate
#     from an acq-maintained NON-SECRET key index (ACQ_SECRET_INDEX_FILE, written
#     by acq_secret_store / acq_secret_delete), UNIONED with keys reconstructed
#     from the endpoint sidecar (belt and suspenders, in case the index lags), and
#     VERIFY each candidate still resolves via acq_secret_get before emitting it —
#     so a stale index entry for a deleted secret never shows. The keychain path
#     also scans the file fallback directory so legacy macOS plaintext entries
#     remain visible while they are still readable. This is best-effort and never
#     fails `ls`.
acq_secret_list_keys() {
  local backend
  backend=$(_acq_secret_backend)
  case "$backend" in
    keychain-macos|keychain-linux) _acq_secret_list_keys_keychain ;;
    *)                            _acq_secret_list_keys_file ;;
  esac
}

# File-backend enumeration: glob the value directory for `acq.*` filenames.
_acq_secret_list_keys_file() {
  local f base seen=" "
  [ -d "$ACQ_SECRET_FILE_DIR" ] || return 0
  for f in "$ACQ_SECRET_FILE_DIR"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in acq.*) ;; *) continue ;; esac
    case "$seen" in *" $base "*) continue ;; esac
    seen="$seen$base "
    printf '%s\n' "$base"
  done
}

# Keychain-backed enumeration: union the acq-maintained key index with keys
# reconstructed from the endpoint sidecar, verify each still resolves, emit
# deduplicated `acq.*` keys. See acq_secret_list_keys for the rationale.
_acq_secret_list_keys_keychain() {
  local key seen=" " svc
  # The resolve-check below is inlined at each emit site rather than factored into
  # a nested helper: a nested function plus `unset -f` would clobber a caller's
  # same-named function if one existed. Each site: skip non-`acq.*`, skip already
  # seen, verify the value still resolves (acq_secret_get output discarded — only
  # its exit status is used; a stale index entry or sidecar-without-value is thus
  # dropped), then record and emit the raw key.

  # (a) The key index — the primary, self-maintained source of stored keys.
  if [ -f "$ACQ_SECRET_INDEX_FILE" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      case "$key" in acq.*) ;; *) continue ;; esac
      case "$seen" in *" $key "*) continue ;; esac
      acq_secret_get "$key" >/dev/null 2>&1 || continue
      seen="$seen$key "
      printf '%s\n' "$key"
    done < "$ACQ_SECRET_INDEX_FILE"
  fi

  # (b) Belt and suspenders: reconstruct `acq.*` keys from any endpoint sidecars
  # the index somehow lacks (self-healing if the index file is missing/stale).
  # Sidecar files are named after the store key (see _acq_secret_meta_file_for),
  # so the filename IS the `acq.*` key. Only real (resolving) values are emitted,
  # so a sidecar without a matching value is silently skipped.
  if [ -d "$ACQ_SECRET_META_DIR" ]; then
    for svc in "$ACQ_SECRET_META_DIR"/*; do
      [ -f "$svc" ] || continue
      key=$(basename "$svc")
      case "$key" in acq.*) ;; *) continue ;; esac
      case "$seen" in *" $key "*) continue ;; esac
      acq_secret_get "$key" >/dev/null 2>&1 || continue
      seen="$seen$key "
      printf '%s\n' "$key"
    done
  fi

  # (c) Legacy macOS fallback files: before macOS wrote through `security -i`,
  # the argv-safe default was a 0600 plaintext file. Keep those visible while the
  # read path still honors them.
  if [ -d "$ACQ_SECRET_FILE_DIR" ]; then
    for svc in "$ACQ_SECRET_FILE_DIR"/*; do
      [ -f "$svc" ] || continue
      key=$(basename "$svc")
      case "$key" in acq.*) ;; *) continue ;; esac
      case "$seen" in *" $key "*) continue ;; esac
      acq_secret_get "$key" >/dev/null 2>&1 || continue
      seen="$seen$key "
      printf '%s\n' "$key"
    done
  fi
}

# _acq_secret_decode_key KEY -> "SCOPE<TAB>SERVICE" where SCOPE is "-g" (global)
# or the sandbox name. Mirrors _acq_secret_key's layout: `acq.<service>` (global)
# vs `acq.<sandbox>.<service>` (scoped). A dotted remainder is a foreign/legacy
# ambiguous key (see acq_secret_meta_list note) and is reported as scope "?" so
# `ls` never mis-attributes it. Never emits the value.
_acq_secret_decode_key() {
  local key="$1" rest
  case "$key" in acq.*) rest="${key#acq.}" ;; *) return 1 ;; esac
  case "$rest" in
    *.*.*)
      # A multi-dot remainder cannot be produced by a current write: _acq_secret_key
      # fails closed on a dotted service/sandbox, so acq.<sandbox>.<service> has
      # exactly one dot. A multi-dot key is a foreign/legacy entry and is
      # genuinely ambiguous by filename alone. Do NOT guess a sandbox — report
      # scope "?" (matching acq_secret_meta_list, which skips such keys) so `ls`
      # never mis-attributes it into a real scope. The full remainder is the
      # service label so the row is still transparent.
      printf '%s\t%s\n' "?" "$rest"
      ;;
    *.*)
      # scoped acq.<sandbox>.<service>: split on the FIRST dot. A service or
      # sandbox can no longer contain a dot (_acq_secret_key fails closed), so a
      # single-dot remainder is unambiguously <sandbox>.<service>.
      printf '%s\t%s\n' "${rest%%.*}" "${rest#*.}"
      ;;
    *)
      printf '%s\t%s\n' "-g" "$rest"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# acq_secret_delete KEY  ->  0 if an entry was removed OR none existed
# ---------------------------------------------------------------------------
# Remove a secret from the active store backend. Idempotent: returns 0 whether
# or not the entry existed (so `rm` of an absent secret is not an error), and
# non-zero only on an actual backend failure. Removes from BOTH the keychain and
# the file fallback where relevant, since a value may have been written to the
# file backend on macOS (see the acq_secret_store note about avoiding argv).
acq_secret_delete() {
  local key="$1" backend rc=0 security_bin
  backend=$(_acq_secret_backend)
  acq_debug "secret delete: key=$key backend=$backend"
  case "$backend" in
    keychain-macos)
      # Clear both Keychain and legacy file fallback so no copy lingers.
      security_bin=$(_acq_secret_security_bin)
      "$security_bin" delete-generic-password -s "$ACQ_KEYCHAIN_LABEL" -a "$key" \
        >/dev/null 2>&1 || true
      _acq_secret_index_remove "$key"
      _acq_secret_delete_file "$key" || rc=$?
      ;;
    keychain-linux)
      # secret-tool clear removes all items matching the attribute; a no-match is
      # not an error for our idempotent contract.
      secret-tool clear acq_key "$key" >/dev/null 2>&1 || true
      _acq_secret_index_remove "$key"
      _acq_secret_delete_file "$key" || rc=$?
      ;;
    file)
      _acq_secret_delete_file "$key" || rc=$?
      ;;
    keychain-windows)
      _acq_secret_delete_file "$key" || rc=$?
      ;;
  esac
  return "$rc"
}

# 0600 file removal. Idempotent (absent file is success); non-zero only if the
# file exists but cannot be removed.
_acq_secret_delete_file() {
  local key="$1" f
  f=$(_acq_secret_file_for "$key")
  [ -e "$f" ] || return 0
  rm -f "$f" 2>/dev/null || {
    echo "acq: secret delete: file remove failed for '$key'." >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# acq_secret_resolve SERVICE [SANDBOX]  ->  value on STDOUT
# ---------------------------------------------------------------------------
# Resolve a service's secret with sandbox-scope precedence: try
# acq.<sandbox>.<service> first, then fall back to acq.<service>. Empty +
# non-zero if neither exists. This is the read path adapters use at provision.
acq_secret_resolve() {
  local service="$1" sandbox="${2:-}" v key
  # _acq_secret_key fails closed on an ambiguous (dotted) name;
  # such a name has no valid entry, so skip its lookup rather than probing an
  # empty/aliased key.
  if [ -n "$sandbox" ] && key=$(_acq_secret_key "$service" "$sandbox"); then
    if v=$(acq_secret_get "$key" 2>/dev/null) && [ -n "$v" ]; then
      printf '%s' "$v"; return 0
    fi
  fi
  if key=$(_acq_secret_key "$service"); then
    if v=$(acq_secret_get "$key" 2>/dev/null) && [ -n "$v" ]; then
      printf '%s' "$v"; return 0
    fi
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
# _acq_read_secret_masked  ->  prints the entered value on stdout
# ---------------------------------------------------------------------------
# Read a secret from the TTY WITHOUT echoing it, but print a `*` per character
# to stderr so the user gets visual feedback that their paste registered (UX:
# a fully silent prompt makes users think nothing happened and re-paste). Never
# echoes the actual characters and never places the value in argv.
#
# Reads character-by-character from STDIN in silent mode (the caller only takes
# this path when stdin is a TTY). Handles Backspace/Delete (erase one star), and
# finishes on Enter (newline) or EOF. Falls back to a plain silent line read if
# per-char reads are unavailable, then to a visible read as a last resort
# (matching the prior behavior) so a secret can always be entered.
_acq_read_secret_masked() {
  local value="" char

  # Fallback path: if the shell can't do a 1-char silent read, use the previous
  # behavior (silent line read, else visible). Detected by trying it once.
  if ! IFS= read -rsn1 char 2>/dev/null; then
    local v
    # shellcheck disable=SC2162
    read -rs v 2>/dev/null || read -r v
    printf '%s' "$v"
    return 0
  fi

  # `char` now holds the first character (empty if Enter was pressed first).
  while :; do
    case "$char" in
      ""|$'\r')  # Enter/newline (or a bare CR from an exotic pty) terminates.
        break
        ;;
      $'\177'|$'\b')  # Backspace / Delete: drop last char, erase a star.
        if [ -n "$value" ]; then
          value="${value%?}"
          printf '\b \b' >&2
        fi
        ;;
      *)
        value="$value$char"
        printf '*' >&2
        ;;
    esac
    IFS= read -rsn1 char 2>/dev/null || break
  done
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# acq_secret_set_interactive SERVICE [SANDBOX] [HOST] [ENV]
# ---------------------------------------------------------------------------
# Read a secret from a TTY (silent) or piped stdin (no prompt) and store it
# under the resolved key. Never places the value in argv. Used by
# `acq secret set` in the adapters. ACQ_SECRET_TEST_VALUE is an offline-test
# escape hatch (no TTY in CI); never set it in production.
#
# When HOST and ENV are both supplied (a custom-endpoint service), the non-secret
# (host, env) endpoint mapping is persisted alongside the value (see
# acq_secret_meta_store) so both backends can bind the service generically at
# provision. HOST/ENV are metadata only — never the value.
acq_secret_set_interactive() {
  local service="$1" sandbox="${2:-}" host="${3:-}" env="${4:-}" key value
  # _acq_secret_key fails closed on unsafe service/sandbox names before reading a
  # value, so nothing is stored under an aliased or command-stream-breaking key.
  if ! key=$(_acq_secret_key "$service" "$sandbox"); then
    echo "acq: secret set: refusing '$service'${sandbox:+ (sandbox '$sandbox')} — service and sandbox names must match [A-Za-z0-9_-]+" >&2
    return 1
  fi

  if [ -n "${ACQ_SECRET_TEST_VALUE:-}" ]; then
    value="$ACQ_SECRET_TEST_VALUE"
    if ! _acq_secret_value_is_storable "$value"; then
      echo "acq: refusing '$service' — ACQ_SECRET_TEST_VALUE contains a newline or tab, which the acq secret store cannot store intact." >&2
      value=""
      return 1
    fi
  elif [ ! -t 0 ]; then
    IFS= read -r value || true
  else
    # "usai" is the service KEY, but users think of it as their "API key", not a
    # "secret" (which in this project means the sbx/msb credential-injection
    # concept). Prompt with the friendlier term for the well-known services.
    case "$service" in
      usai)   printf 'Enter USAi API key: ' >&2 ;;
      github) printf 'Enter GitHub token: ' >&2 ;;
      *)      printf 'Enter %s API key: ' "$service" >&2 ;;
    esac
    value=$(_acq_read_secret_masked)
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
    # Persist the non-secret endpoint mapping for custom services (host/env only;
    # a no-op when either is empty, e.g. built-ins whose mapping is compiled in).
    acq_secret_meta_store "$service" "$sandbox" "$host" "$env" || true
    echo "acq: ${service} secret stored (${key})." >&2
  fi
  return "$rc"
}
