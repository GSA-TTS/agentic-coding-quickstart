#!/bin/bash
#
# acq.backends/common.sh — backend-agnostic logic for acq
#
# Sourced by the acq entry point. Provides:
#   - Kit constants (neutral hybrid/v1 acq kits from agentic-coding-patterns)
#   - Backend resolution (flag > env > XDG config > auto-detect)
#   - Backend dispatch (call acq_backend_* functions from the loaded adapter)
#   - Shared utilities: slugify, derive_name, split_noglob, advisories, key check
#
# Does NOT contain any backend-specific CLI knowledge — that lives in the
# per-backend adapters (sbx.sh, msb.sh). Neutral-kit parsing/translation lives
# in kit-translate.sh, which this file sources.

# ============================================================================
# KITS — the four neutral hybrid/v1 acq kits from agentic-coding-patterns.
#
# Phase 2 (1.2.x) moves from the sbx-only `sbx-kits/` tree to the neutral
# `acq-kits/` tree (schemaVersion: "hybrid/v1"), so both the sbx and msb
# backends share one kit vocabulary. Each backend adapter consumes these via
# acq.backends/kit-translate.sh, which fetches a kit's neutral spec.yaml and
# emits the active backend's native operations.
#
# PATTERNS_KIT_REF is pinned to the agentic-coding-patterns v1.7.0 release commit
# on main. v1.7.0 adds the `environment` vocabulary to the hybrid/v1 schema
# (patterns #227, consumed by kit-translate.sh's kit_spec_env), on top of the
# Part A neutral acq-kits + schema (#221) and the openchamber conversion (#224).
# Pinning to a release tag mirrors Phase 1 (which pinned patterns v1.5.0). The
# acq-kits and the kit-hybrid-v1 schema (with `environment`) are present at this
# commit (verified).
# ============================================================================
PATTERNS_KIT_REPO="git+https://github.com/GSA-TTS/agentic-coding-patterns.git"
PATTERNS_KIT_REF="9c277c09ed4ad45fd11709d6b048a58adc785443"   # patterns v1.7.0 (adds environment vocabulary / #227)
PATTERNS_KIT_DIR="integrations/isolation/acq-kits"

USAI_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/usai-provider"
PLAYBOOK_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/agentic-coding-playbook"
ZSCALER_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/zscaler-ca-certificate"
GITSSHSIGN_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/git-ssh-sign"

# Neutral kit directory names (relative to PATTERNS_KIT_DIR), in apply order.
# kit-translate.sh resolves a kit's spec.yaml + files/ from these names. The
# built-in kit set maps 1:1 to the four *_KIT refs above.
# shellcheck disable=SC2034  # consumed by `acq kit list` in the acq entry point
ACQ_KIT_NAMES=(usai-provider agentic-coding-playbook zscaler-ca-certificate git-ssh-sign)

# Additional user-supplied kits. Set ACQ_EXTRA_KITS to a whitespace-separated
# list of kit references. Set ACQ_EXTRA_KIT_SOURCES for their allowlist prefixes.
ACQ_EXTRA_KITS="${ACQ_EXTRA_KITS:-}"
ACQ_EXTRA_KIT_SOURCES="${ACQ_EXTRA_KIT_SOURCES:-}"

# Kits supplied on the command line via `--kit <ref>` (repeatable) on
# run/create. These are extracted from the arg list by extract_kit_flags (below)
# BEFORE the args reach the backend, so a neutral kit ref is translated by acq
# rather than passed raw to the backend CLI (which would fail to parse the
# neutral schema). Folded into the kit list by _build_kit_list, alongside
# ACQ_EXTRA_KITS. One ref per element.
ACQ_CLI_KITS=()

KIT_SOURCE_PREFIX="github.com/GSA-TTS/"
KIT_SOURCE_PREFIXES=("$KIT_SOURCE_PREFIX")

# USAi endpoint constants
USAI_MODELS_URL="https://api.gsa.usai.gov/api/v1/models"
KEY_MGMT_URL="https://console.gsa.usai.gov/key-management"

# Source the neutral-kit translation layer (spec.yaml parser + shortcut
# dispatch). ACQ_SCRIPT_DIR is exported by the acq entry point; in the offline
# test harness it is set before common.sh is sourced.
if [ -n "${ACQ_SCRIPT_DIR:-}" ] && [ -f "${ACQ_SCRIPT_DIR}/acq.backends/kit-translate.sh" ]; then
  # shellcheck disable=SC1091
  . "${ACQ_SCRIPT_DIR}/acq.backends/kit-translate.sh"
fi

# Source the acq-owned, backend-neutral secret store (keychain-backed; both the
# sbx and msb adapters read credentials from here at provision time).
if [ -n "${ACQ_SCRIPT_DIR:-}" ] && [ -f "${ACQ_SCRIPT_DIR}/acq.backends/secret-store.sh" ]; then
  # shellcheck disable=SC1091
  . "${ACQ_SCRIPT_DIR}/acq.backends/secret-store.sh"
fi

# ============================================================================
# Utility functions
# ============================================================================

# Debug trace. Set ACQ_DEBUG=1 to emit "acq[debug]: ..." diagnostics to stderr
# (backend CLI invocations, kit fetch/translate steps). Off by default; safe to
# leave in — it never prints secret VALUES, only command shapes.
acq_debug() {
  [ -n "${ACQ_DEBUG:-}" ] || return 0
  printf 'acq[debug]: %s\n' "$*" >&2
}

# Word-split a whitespace-separated env value into the named array WITHOUT
# filename globbing (a literal `*` in a kit ref must not expand against the cwd).
split_noglob() {
  local _name="$1" _val="$2" _oldopts
  _oldopts=$(set +o); set -f
  # shellcheck disable=SC2086
  set -- $_val
  eval "$_oldopts"
  eval "$_name=(\"\$@\")"
}

# Assemble the full kit list: built-ins, then extras.
_build_kit_list() {
  KITS=("$USAI_KIT" "$PLAYBOOK_KIT" "$ZSCALER_KIT" "$GITSSHSIGN_KIT")
  if [ -n "$ACQ_EXTRA_KITS" ]; then
    local _extra_kits=()
    split_noglob _extra_kits "$ACQ_EXTRA_KITS"
    # shellcheck disable=SC2154
    KITS+=("${_extra_kits[@]}")
  fi
  # Kits given on the command line via `--kit <ref>` (extracted by
  # extract_kit_flags before dispatch). Same treatment as ACQ_EXTRA_KITS:
  # translated by acq, source-allowlisted, never forwarded raw to the backend.
  if [ "${#ACQ_CLI_KITS[@]}" -gt 0 ]; then
    KITS+=("${ACQ_CLI_KITS[@]}")
  fi

  # Also build the allowed sources list.
  KIT_SOURCE_PREFIXES=("$KIT_SOURCE_PREFIX")
  if [ -n "$ACQ_EXTRA_KIT_SOURCES" ]; then
    local _extra_sources=()
    split_noglob _extra_sources "$ACQ_EXTRA_KIT_SOURCES"
    # shellcheck disable=SC2154
    KIT_SOURCE_PREFIXES+=("${_extra_sources[@]}")
  fi
}

# Normalize a string into a sandbox-name slug: lowercase, runs of
# non-alphanumerics collapsed to a single hyphen, leading/trailing hyphens trimmed.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//'
}

# True if PREV is a flag that consumes the next argument as its value.
_takes_value() {
  case "$1" in
    --name|--template|-t|--profile|--cpus|--memory|-m|--kit|--backend) return 0 ;;
    *) return 1 ;;
  esac
}

# Derive the sandbox name acq will own and pass to both create and the existence
# check. Honors an explicit `--name NAME`; otherwise builds "<agent>-<slug-of-basename>".
derive_name() {
  local agent="" first_path="" prev=""
  for arg in "$@"; do
    if [ "$prev" = "--name" ]; then
      printf '%s\n' "$arg"
      return 0
    fi
    case "$arg" in
      --name=*)
        printf '%s\n' "${arg#--name=}"
        return 0
        ;;
    esac
    prev="$arg"
  done

  # No explicit --name: agent is the first non-flag token, path the next one.
  # Skip --backend and its value, which the backend consumed at the acq level.
  prev=""
  for arg in "$@"; do
    if _takes_value "$prev"; then prev="$arg"; continue; fi
    case "$arg" in
      --backend=*) prev="$arg"; continue ;;
      -*) prev="$arg"; continue ;;
    esac
    if [ -z "$agent" ]; then
      agent="$arg"
    elif [ -z "$first_path" ]; then
      first_path="${arg%%:*}"
      break
    fi
    prev="$arg"
  done

  if [ -z "$agent" ]; then
    echo "error: could not determine agent for sandbox name" >&2
    return 1
  fi

  local base="."
  [ -n "$first_path" ] && base=$(basename "$first_path")
  [ "$base" = "." ] && base=$(basename "$PWD")
  printf '%s\n' "$(slugify "$agent")-$(slugify "$base")"
}

# Find the workspace path in an AGENT-form create/run arg list: the SECOND
# non-flag positional (after the agent). Echoes the path with any `:ro` suffix
# stripped, or nothing if none was given.
workspace_path() {
  local agent="" prev=""
  for arg in "$@"; do
    if _takes_value "$prev"; then prev="$arg"; continue; fi
    case "$arg" in
      --backend=*) prev="$arg"; continue ;;
      -*) prev="$arg"; continue ;;
    esac
    if [ -z "$agent" ]; then
      agent="$arg"
    else
      printf '%s\n' "${arg%%:*}"
      return 0
    fi
    prev="$arg"
  done
}

# Find the first non-flag positional in a create/run arg list.
first_positional() {
  local prev=""
  for arg in "$@"; do
    if _takes_value "$prev"; then
      prev="$arg"
      continue
    fi
    case "$arg" in
      -*) prev="$arg"; continue ;;
    esac
    printf '%s\n' "$arg"
    return 0
  done
}

# Strip --backend <name> / --backend=<name> from arg list into STRIPPED_ARGS.
strip_backend_flag() {
  STRIPPED_ARGS=()
  local skip=0
  for arg in "$@"; do
    if [ "$skip" -eq 1 ]; then
      skip=0
      continue
    fi
    case "$arg" in
      --backend) skip=1; continue ;;
      --backend=*) continue ;;
    esac
    STRIPPED_ARGS+=("$arg")
  done
}

# Extract user-supplied `--kit <ref>` / `--kit=<ref>` flags from a run/create
# arg list. Populates two arrays IN THE CURRENT SHELL (so callers must not run
# this in a subshell/pipeline):
#   ACQ_CLI_KITS         — the kit refs, one per element
#   ACQ_KIT_REMAINING    — the arg list with all --kit flags removed
#
# Why acq must intercept `--kit`: the backend spells local-kit application the
# same way (`sbx create --kit <dir>`), so a user naturally writes
# `acq run opencode --kit <dir> .`. If acq forwarded that flag verbatim, the
# backend would receive a NEUTRAL hybrid/v1 kit it cannot parse. Treating it like
# an ACQ_EXTRA_KITS entry routes it through acq's translation instead.
#
# Usage:
#   extract_kit_flags "$@"
#   _build_kit_list                        # fold ACQ_CLI_KITS into KITS
#   set -- "${ACQ_KIT_REMAINING[@]}"        # args without --kit
extract_kit_flags() {
  ACQ_CLI_KITS=()
  ACQ_KIT_REMAINING=()
  local expect_kit=0 arg
  for arg in "$@"; do
    if [ "$expect_kit" -eq 1 ]; then
      ACQ_CLI_KITS+=("$arg")
      expect_kit=0
      continue
    fi
    case "$arg" in
      --kit)   expect_kit=1 ;;
      --kit=*) ACQ_CLI_KITS+=("${arg#--kit=}") ;;
      *)       ACQ_KIT_REMAINING+=("$arg") ;;
    esac
  done
  # A trailing `--kit` with no value: warn but don't crash.
  if [ "$expect_kit" -eq 1 ]; then
    echo "acq: --kit given with no value; ignoring" >&2
  fi
}

# ============================================================================
# Backend resolution
# ============================================================================
# Priority: --backend flag > ACQ_BACKEND env > XDG config > auto-detect.
# Loads the resolved backend adapter (sources acq.backends/<name>.sh) and sets
# ACQ_RESOLVED_BACKEND.

ACQ_RESOLVED_BACKEND=""

_acq_config_file() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/acq/config.yaml"
}

_read_config_backend() {
  local cfg
  cfg=$(_acq_config_file)
  [ -f "$cfg" ] || return 0
  # Parse the single `backend: <name>` key defensively with awk (no YAML dep).
  awk '/^[[:space:]]*backend[[:space:]]*:/ { gsub(/^[[:space:]]*backend[[:space:]]*:[[:space:]]*/,""); gsub(/[[:space:]]*$/,""); print; exit }' "$cfg"
}

# Try to auto-detect an available backend. Prefers sbx (the mature default),
# then msb (microsandbox). First one found wins.
_auto_detect_backend() {
  if command -v sbx >/dev/null 2>&1; then
    printf 'sbx\n'
    return 0
  fi
  if command -v msb >/dev/null 2>&1; then
    printf 'msb\n'
    return 0
  fi
  return 1
}

# Source the adapter for a named backend. Fails closed if the file is missing.
_load_backend_adapter() {
  local name="$1"
  local adapter="${ACQ_SCRIPT_DIR}/acq.backends/${name}.sh"
  if [ ! -f "$adapter" ]; then
    echo "acq: error: no backend adapter found for '${name}' (expected: ${adapter})" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$adapter"
  ACQ_RESOLVED_BACKEND="$name"
}

# Resolve and load the backend. $1 (optional) = explicit --backend value.
acq_resolve_backend() {
  local explicit="${1:-}"
  local name=""

  if [ -n "$explicit" ]; then
    name="$explicit"
  elif [ -n "${ACQ_BACKEND:-}" ]; then
    name="$ACQ_BACKEND"
  else
    local cfg_name
    cfg_name=$(_read_config_backend)
    if [ -n "$cfg_name" ]; then
      name="$cfg_name"
    else
      name=$(_auto_detect_backend) || {
        echo "acq: error: no backend detected. Install sbx (>= 0.35.0) or msb (>= 0.6.0)," >&2
        echo "     or set ACQ_BACKEND." >&2
        echo "     Run 'acq doctor' for installation hints." >&2
        exit 1
      }
    fi
  fi

  _load_backend_adapter "$name"
  _build_kit_list
}

# ============================================================================
# Advisory functions (USAi key, SSH signing, git identity)
# ============================================================================

# Probe the USAi API from inside the sandbox.
check_key() {
  local name="$1"
  acq_backend_run "$name" -- sh -c \
    "curl -sS -o /dev/null -w '%{http_code}' \
     -H \"Authorization: Bearer \$USAI_API_KEY\" \
     $USAI_MODELS_URL" 2>/dev/null || true
}

# Check USAi key in a fresh temporary sandbox (to distinguish bad key from stale
# placeholder).
check_fresh_sandbox_key() {
  local validation_name="acq-keycheck-$$"
  local status=""

  # Use the backend to create a minimal sandbox for validation.
  if ! acq_backend_provision "$validation_name" shell . </dev/null >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck disable=SC2064
  trap "acq_backend_terminate '$validation_name' </dev/null >/dev/null 2>&1 || true" EXIT
  status=$(acq_backend_run "$validation_name" -- sh -c \
    "curl -sS -o /dev/null -w '%{http_code}' \
     -H \"Authorization: Bearer \$USAI_API_KEY\" \
     $USAI_MODELS_URL" </dev/null 2>/dev/null || true)
  acq_backend_terminate "$validation_name" </dev/null >/dev/null 2>&1 || true
  trap - EXIT
  printf '%s\n' "$status"
}

# Warn (do not block) if no SSH key is loaded in the host's SSH agent.
warn_if_no_ssh_signing_key() {
  local keys=""
  if command -v ssh-add >/dev/null 2>&1; then
    keys=$(ssh-add -L 2>/dev/null || true)
  fi
  case "$keys" in
    ssh-*|ecdsa-*|sk-*)
      return 0 ;;
  esac
  echo "acq: note — no SSH key is loaded in your host's SSH agent." >&2
  echo "      This sandbox signs git commits with your forwarded SSH key, and" >&2
  echo "      commits will FAIL until a key is loaded. To fix, on your host run:" >&2
  echo "        ssh-add ~/.ssh/id_ed25519   # or your signing key" >&2
  echo "      Then commit as usual. (You can still work; only committing needs it.)" >&2
}

# Warn (do not block) if the project has no repo-local git user.email.
# Only the repo-local identity crosses into the sandbox via the workspace mount.
warn_if_no_git_identity() {
  local path="${1:-}" email=""
  command -v git >/dev/null 2>&1 || return 0
  [ -n "$path" ] && [ -d "$path" ] || return 0
  email=$(git -C "$path" config --local user.email 2>/dev/null || true)
  [ -n "$email" ] && return 0
  echo "acq: note — no repo-local git user.email is set for this project." >&2
  echo "      The sandbox has its own empty home, so your host's global git" >&2
  echo "      identity is NOT visible inside it. Commits will be SIGNED but show" >&2
  echo "      'Unverified' on GitHub until you set an identity. Fix:" >&2
  echo "        git config user.email you@verified-on-github.example" >&2
  echo "        git config user.name  \"Your Name\"" >&2
}

# Validate the sandbox's USAi key and walk the user through rotating it if
# needed. Best-effort: warn and continue if we cannot run the check.
ensure_valid_key() {
  local name="$1"
  shift
  local status
  status=$(check_key "$name")

  if [ "$status" = "200" ]; then
    return 0
  fi

  if [ -z "$status" ]; then
    echo "warning: could not validate USAI_API_KEY for '$name' (skipping check)" >&2
    return 0
  fi

  echo >&2
  echo "Your USAi API key looks invalid or expired (HTTP $status from the models API)." >&2
  echo "USAi keys expire every 7 days." >&2
  echo >&2
  echo "To rotate it:" >&2
  echo "  1. Open $KEY_MGMT_URL" >&2
  echo "  2. Choose 'Rotate' from the Actions menu for your key" >&2
  echo "  3. Copy the new key using the console copy button" >&2
  echo >&2

  local rotate_via_backend=1
  if ! command -v acq_backend_rotate_key >/dev/null 2>&1; then
    rotate_via_backend=0
    echo "The '${ACQ_RESOLVED_BACKEND:-active}' backend does not implement key rotation." >&2
    echo "Rotate manually, then re-run." >&2
    return 1
  fi

  printf 'Have the new key ready to paste? Rotate now? [y/N] ' >&2
  local answer=""
  read -r answer || true
  case "$answer" in
    [yY]|[yY][eE][sS])
      if [ "$rotate_via_backend" -eq 1 ]; then
        acq_backend_rotate_key || {
          echo "Rotation did not complete. Aborting attach." >&2
          return 1
        }
      fi
      status=$(check_key "$name")
      if [ "$status" = "200" ]; then
        echo "Key validated. Continuing." >&2
        return 0
      fi
      echo "Key still not working (HTTP ${status:-unknown}). Aborting attach." >&2
      return 1
      ;;
    *)
      echo "Skipping rotation. Aborting attach; re-run when your key is rotated." >&2
      return 1
      ;;
  esac
}

# ============================================================================
# acq doctor output helpers
# ============================================================================

acq_print_doctor() {
  local sbx_status msb_status

  # Check sbx
  if command -v sbx >/dev/null 2>&1; then
    local sbx_ver
    sbx_ver=$(sbx version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed 's/^v//' || echo "?")
    sbx_status="installed v${sbx_ver}"
  else
    sbx_status="not found"
  fi

  # Check msb (microsandbox).
  if command -v msb >/dev/null 2>&1; then
    local msb_ver
    msb_ver=$(msb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "?")
    msb_status="installed v${msb_ver}"
  else
    msb_status="not found"
  fi

  echo "acq: backend health check"
  echo "  [sbx: ${sbx_status}]"
  echo "  [msb: ${msb_status}]"
  echo ""

  local config_file
  config_file=$(_acq_config_file)
  if [ -f "$config_file" ]; then
    echo "  config: ${config_file}"
    local cfg_backend
    cfg_backend=$(_read_config_backend)
    [ -n "$cfg_backend" ] && echo "  default backend (from config): ${cfg_backend}"
  else
    echo "  config: ${config_file} (not found)"
  fi

  if [ -n "${ACQ_BACKEND:-}" ]; then
    echo "  ACQ_BACKEND env override: ${ACQ_BACKEND}"
  fi

  echo ""

  if [ -n "${ACQ_RESOLVED_BACKEND:-}" ]; then
    echo "  active backend: ${ACQ_RESOLVED_BACKEND}"
    if command -v acq_backend_doctor >/dev/null 2>&1; then
      echo "  $(acq_backend_doctor)"
    fi
  fi

  echo ""
  printf "  Write '%s' as the default backend to %s? [y/N] " "${ACQ_RESOLVED_BACKEND:-sbx}" "$config_file" >&2
  local answer=""
  read -r answer || true
  case "$answer" in
    [yY]|[yY][eE][sS])
      local cfg_dir
      cfg_dir=$(dirname "$config_file")
      mkdir -p "$cfg_dir"
      printf 'backend: %s\n' "${ACQ_RESOLVED_BACKEND:-sbx}" > "$config_file"
      echo "  Wrote default backend to ${config_file}." >&2
      ;;
    *)
      echo "  Not written." >&2
      ;;
  esac
}
