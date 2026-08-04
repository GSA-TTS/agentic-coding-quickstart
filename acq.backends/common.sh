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
# PATTERNS_KIT_REF is pinned to an agentic-coding-patterns commit that provides
# the neutral acq-kits, the hybrid/v1 schema (including the kit-bundle
# `provenance` block that the currency check below reads), and the playbook
# kit's REST-tarball fetch. The pinned release also carries the openchamber kit
# republished against the neutral `publishedPorts`/`background` schema, so
# ADR-0014's cross-repo gate is satisfied: the neutral port/background fields
# light up end-to-end rather than being read only defensively against an
# unreleased schema.
# ============================================================================
PATTERNS_KIT_REPO="git+https://github.com/GSA-TTS/agentic-coding-patterns.git"
# Full 40-char SHA (not an abbreviation): this ref drives a credential-bearing
# cross-repo kit fetch, so pin it unambiguously for reproducibility. It is also
# the bundle-version anchor recorded in a sandbox's host-side provenance record
# (see ACQ_BUILTIN_BUNDLE below + the provenance helpers) so acq can tell a
# stale sandbox from a current one.
PATTERNS_KIT_REF="f5fb88759aa3007e24186a25e5f2d5d4a8b6e573"  # agentic-coding-patterns v1.8.0
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

# Built-in bundle identity. This mirrors the `provenance` block the usai-provider
# kit declares at the pinned PATTERNS_KIT_REF. acq records these in a sandbox's
# record so a later `acq run` / `acq kit check` can tell whether an existing
# sandbox was built from the CURRENTLY pinned bundle. The bundle name + repo are
# stable identity; the applied SHA (PATTERNS_KIT_REF) is the currency signal.
# shellcheck disable=SC2034  # consumed by the provenance helpers below
ACQ_BUILTIN_BUNDLE="acq-builtin"
# shellcheck disable=SC2034
ACQ_BUILTIN_BUNDLE_REPO="GSA-TTS/agentic-coding-patterns"

# Additional user-supplied kits. Set ACQ_EXTRA_KITS to a whitespace-separated
# list of kit references. Set ACQ_EXTRA_KIT_SOURCES for their allowlist prefixes.
ACQ_EXTRA_KITS="${ACQ_EXTRA_KITS:-}"
ACQ_EXTRA_KIT_SOURCES="${ACQ_EXTRA_KIT_SOURCES:-}"

# Update-check opt-out. When ACQ_UPDATE_CHECK=0, `acq run` never
# runs the stale-sandbox check (no provenance comparison, no prompt). The
# explicit `acq kit check` / `acq kit update` commands still work — the opt-out
# only silences the automatic per-run check. `acq run --no-update-check` sets
# this for a single invocation (parsed in the acq entry point).
ACQ_UPDATE_CHECK="${ACQ_UPDATE_CHECK:-1}"

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
# leave in — it never prints secret VALUES, only command shapes. Each line is
# timestamped (HH:MM:SS) so that when a step hangs, the LAST debug line shows
# both which sub-call was entered and when — the gap to the wall clock is the
# stall. (verify-backends -x relies on this to localize a hang.)
acq_debug() {
  [ -n "${ACQ_DEBUG:-}" ] || return 0
  printf 'acq[debug %s]: %s\n' "$(date +%H:%M:%S 2>/dev/null || printf '??:??:??')" "$*" >&2
}

# Services acq manages in its own secret store (and knows how to inject). Used to
# decide whether `acq secret rm` should route to the acq-owned removal path vs.
# pass a raw placeholder token through to the backend secret CLI.
ACQ_MANAGED_SECRET_SERVICES=" usai github gitlab "

# _acq_is_managed_secret_rm ARGS... -> 0 if the `acq secret rm` args name an
# acq-managed secret (scope + known service), else 1 (pass through to backend).
# Recognizes:  -g SERVICE  |  --global SERVICE  |  SANDBOX SERVICE
_acq_is_managed_secret_rm() {
  local a1="${1:-}" a2="${2:-}" svc=""
  case "$a1" in
    -g|--global) svc="$a2" ;;
    -*)          return 1 ;;              # some other flag/placeholder
    *)
      # SANDBOX SERVICE form only (two positionals); a lone token is a raw
      # placeholder for the backend to handle.
      [ -n "$a2" ] || return 1
      case "$a2" in -*) return 1 ;; esac
      svc="$a2"
      ;;
  esac
  [ -n "$svc" ] || return 1
  case "$ACQ_MANAGED_SECRET_SERVICES" in
    *" $svc "*) return 0 ;;
    *) return 1 ;;
  esac
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

# List ALL workspace positionals in an AGENT-form create/run arg list: every
# non-flag positional AFTER the agent (primary workspace first, then any extra
# mounts). Each is emitted on its own line, VERBATIM (including any `:ro`
# suffix) so a caller can preserve read-only intent. Mirrors sbx's
# multi-workspace syntax: `acq run opencode ~/app ~/lib:ro`.
workspace_paths() {
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
      printf '%s\n' "$arg"
    fi
    prev="$arg"
  done
}

# Canonicalize a filesystem path to its real, symlink-free absolute form.
# Echoes the resolved path, or the input unchanged if it cannot be resolved
# (e.g. a nonexistent path, or no realpath/readlink available). Pure stdout;
# never mutates the filesystem. Used so a backend mounts the REAL host path —
# e.g. on macOS $TMPDIR is a /var -> /private/var symlink, and msb cannot mount
# the symlinked form (see docs/BACKEND_GUIDE.md, msb workspace mounting).
canonicalize_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 0
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null && return 0
  fi
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null && return 0
  fi
  printf '%s\n' "$p"
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
# Scanning STOPS at the first `--` separator: everything after it is agent args
# (which may legitimately contain their own `--kit`) and is forwarded verbatim.
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
  while [ "$#" -gt 0 ]; do
    arg="$1"
    if [ "$expect_kit" -eq 1 ]; then
      ACQ_CLI_KITS+=("$arg")
      expect_kit=0
      shift
      continue
    fi
    case "$arg" in
      # Stop scanning at the first `--` separator: everything after it is
      # agent args (which may legitimately contain their own `--kit`) and MUST
      # pass through untouched. Append the separator and the rest verbatim.
      --)      ACQ_KIT_REMAINING+=("$@"); break ;;
      --kit)   expect_kit=1 ;;
      --kit=*) ACQ_CLI_KITS+=("${arg#--kit=}") ;;
      *)       ACQ_KIT_REMAINING+=("$arg") ;;
    esac
    shift
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

# _sbx_has_sandboxes — 0 if the sbx CLI reports at least one existing sandbox.
# Used only on the both-installed auto-detect path to keep users on sbx when
# they already have sbx sandboxes. Runs BEFORE any adapter is sourced, so it
# calls `sbx ls -q` directly rather than acq_backend_exists. Fail-open: any
# error (sbx missing, not logged in, transient) is treated as "no sandboxes".
_sbx_has_sandboxes() {
  command -v sbx >/dev/null 2>&1 || return 1
  [ -n "$(sbx ls -q 2>/dev/null)" ]
}

# Auto-detect an available backend when nothing is explicitly pinned. Sets, IN
# THE CURRENT SHELL, ACQ_AUTODETECT_BACKEND (the chosen backend) and
# ACQ_AUTODETECT_REASON (consumed by _announce_autodetect_backend) to one of:
#   msb-only           — only msb installed (the default; no nudge needed)
#   sbx-only           — only sbx installed (nudge toward the msb default)
#   both-msb           — both installed, no existing sbx sandboxes -> msb
#   both-sbx           — both installed, existing sbx sandboxes -> keep sbx
# msb is the default: it wins unless the user already has sbx sandboxes to
# preserve. Returns non-zero (both vars empty) when no backend is installed.
#
# NOTE: this MUST run in the current shell (not `$( … )`) so the two globals it
# sets are visible to the caller — auto-detect's nudge depends on the reason.
ACQ_AUTODETECT_BACKEND=""
ACQ_AUTODETECT_REASON=""
_auto_detect_backend() {
  ACQ_AUTODETECT_BACKEND=""
  ACQ_AUTODETECT_REASON=""
  local have_msb=0 have_sbx=0
  command -v msb >/dev/null 2>&1 && have_msb=1
  command -v sbx >/dev/null 2>&1 && have_sbx=1

  if [ "$have_msb" -eq 1 ] && [ "$have_sbx" -eq 1 ]; then
    if _sbx_has_sandboxes; then
      ACQ_AUTODETECT_BACKEND="sbx"; ACQ_AUTODETECT_REASON="both-sbx"; return 0
    fi
    ACQ_AUTODETECT_BACKEND="msb"; ACQ_AUTODETECT_REASON="both-msb"; return 0
  fi
  if [ "$have_msb" -eq 1 ]; then
    ACQ_AUTODETECT_BACKEND="msb"; ACQ_AUTODETECT_REASON="msb-only"; return 0
  fi
  if [ "$have_sbx" -eq 1 ]; then
    ACQ_AUTODETECT_BACKEND="sbx"; ACQ_AUTODETECT_REASON="sbx-only"; return 0
  fi
  return 1
}

# Emit a one-time stderr nudge toward the msb default when the backend was
# auto-detected (no --backend, ACQ_BACKEND, or saved config). msb is now the
# default backend and the best-supported option going forward, so every
# auto-detect case that isn't already on msb steers the user there and shows how
# to pin their choice (which also silences the notice). No notice on msb-only —
# already on the default, nothing to nudge.
_announce_autodetect_backend() {
  case "$ACQ_AUTODETECT_REASON" in
    both-sbx)
      echo "acq: using sbx (you have existing sbx sandboxes). msb is now the default backend." >&2
      echo "     Pin your choice: 'acq backend set sbx' (keep sbx) or 'acq backend set msb' (switch)." >&2
      ;;
    both-msb)
      echo "acq: using msb, the default backend. Pin with 'acq backend set msb' to silence this." >&2
      ;;
    sbx-only)
      echo "acq: using sbx. msb is now the default backend and the recommended option going forward —" >&2
      echo "     consider 'acq backend set msb'. Pin sbx with 'acq backend set sbx' to silence this." >&2
      ;;
    *) : ;;  # msb-only (or unset): already on the default — no nudge.
  esac
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
  local autodetected=0

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
      _auto_detect_backend || {
        echo "acq: error: no backend detected. Install msb (>= 0.6.0) or sbx (>= 0.35.0)," >&2
        echo "     or set ACQ_BACKEND." >&2
        echo "     Run 'acq doctor' for installation hints." >&2
        exit 1
      }
      name="$ACQ_AUTODETECT_BACKEND"
      autodetected=1
    fi
  fi

  # Nudge toward the msb default ONLY when the backend was auto-detected — an
  # explicit --backend / ACQ_BACKEND / saved config is the user's pin and stays
  # silent.
  [ "$autodetected" -eq 1 ] && _announce_autodetect_backend

  _load_backend_adapter "$name"
  _build_kit_list
}

# ============================================================================
# Kit-bundle provenance + staleness
# ============================================================================
# When acq applies the built-in kit bundle to a sandbox it records, HOST-SIDE, a
# small provenance record naming the bundle and the exact PATTERNS_KIT_REF that
# was applied. A later `acq run` / `acq kit check` compares that recorded ref
# against the local checkout's CURRENT PATTERNS_KIT_REF: if they differ (or no
# record exists), the sandbox is "stale/legacy" and acq offers a safe in-place
# refresh.
#
# Design:
#   - Host-side only. The record lives under XDG_STATE_HOME on the machine
#     running acq, keyed by backend + sandbox name. No guest exec is needed to
#     read it, so the check is fast and works even for a stopped sandbox. If the
#     host state is lost, the sandbox reads as "unknown" and acq simply re-offers
#     a refresh — never a destructive default.
#   - The LOCAL checkout's PATTERNS_KIT_REF is the source of truth (never the
#     mutable patterns `main`).
#   - Staleness = exact-ref mismatch (or missing record). No git ancestry / no
#     network call: deterministic and offline-safe. A newer-but-different local
#     pin correctly offers a refresh.
#   - Written ONLY after a successful apply (the caller gates the write on the
#     apply's exit status); a partial/failed apply must not claim currency.
#   - Fail-open: any read/parse/detect error is treated as "cannot determine" and
#     never blocks a run.
#
# Record format: a tiny, dependency-free `key=value` file (one pair per line).
# We deliberately avoid a JSON/YAML dependency in the shell path — the fields are
# flat scalars and this matches the awk-parsed acq config convention.

# Provenance state directory (host-side). Overridable via ACQ_PROVENANCE_DIR for
# tests and for users who relocate XDG state. Mirrors _acq_config_file's style.
_acq_provenance_dir() {
  if [ -n "${ACQ_PROVENANCE_DIR:-}" ]; then
    printf '%s\n' "$ACQ_PROVENANCE_DIR"
    return 0
  fi
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/acq/provenance"
}

# Path to one sandbox's provenance record. Keyed by backend + sandbox name so the
# same name under two backends never collides. The sandbox name is sanitized to a
# safe filename charset (defense-in-depth: a name reaches a filesystem path here).
# A short checksum of the RAW name is appended so two distinct names that sanitize
# to the same string (e.g. "a/b" and "a_b") do not alias onto one record.
_acq_provenance_file() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  local safe_backend safe_name name_sum
  safe_backend=$(printf '%s' "$backend" | tr -c 'A-Za-z0-9._-' '_')
  safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
  # cksum of the raw name disambiguates sanitizer collisions (fail-open: if cksum
  # is somehow unavailable the name still resolves, just without the suffix).
  name_sum=$(printf '%s' "$name" | cksum 2>/dev/null | cut -d' ' -f1 2>/dev/null || echo 0)
  printf '%s/%s/%s.%s.env\n' "$(_acq_provenance_dir)" "$safe_backend" "$safe_name" "$name_sum"
}

# Write (or overwrite) a sandbox's provenance record. Call ONLY after a
# successful bundle apply. Records the bundle identity + the exact applied ref +
# an ISO-8601 UTC timestamp + the backend. Best-effort: a write failure warns
# (debug) and returns non-zero but never aborts the caller (fail-open).
# Usage: acq_provenance_write BACKEND SANDBOX_NAME
acq_provenance_write() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  local file dir ts
  file=$(_acq_provenance_file "$backend" "$name") || return 1
  dir=$(dirname "$file")
  if ! mkdir -p "$dir" 2>/dev/null; then
    acq_debug "provenance: could not create state dir: $dir"
    return 1
  fi
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  # Write atomically via a temp file + mv so a crash mid-write can't leave a
  # half-written record that later parses as a bogus "current" ref.
  local tmp="${file}.tmp.$$"
  {
    printf 'schema=1\n'
    printf 'bundle=%s\n' "$ACQ_BUILTIN_BUNDLE"
    printf 'repo=%s\n' "$ACQ_BUILTIN_BUNDLE_REPO"
    printf 'applied_ref=%s\n' "$PATTERNS_KIT_REF"
    printf 'backend=%s\n' "$backend"
    printf 'applied_at=%s\n' "$ts"
  } > "$tmp" 2>/dev/null || { acq_debug "provenance: write failed: $tmp"; rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { acq_debug "provenance: mv failed: $file"; rm -f "$tmp" 2>/dev/null; return 1; }
  acq_debug "provenance: recorded $backend/$name applied_ref=$PATTERNS_KIT_REF"
  return 0
}

# Read one field from a sandbox's provenance record. Echoes the value (empty if
# absent/unreadable). Defensive flat key=value parse (no YAML/JSON dep), matching
# the acq config awk convention. Only the first match wins.
# Usage: acq_provenance_field BACKEND SANDBOX_NAME FIELD
acq_provenance_field() {
  local backend="${1:-}" name="${2:-}" field="${3:-}"
  [ -n "$backend" ] && [ -n "$name" ] && [ -n "$field" ] || return 0
  local file
  file=$(_acq_provenance_file "$backend" "$name") || return 0
  [ -f "$file" ] || return 0
  awk -F= -v k="$field" '
    $1 == k { sub(/^[^=]*=/, ""); print; exit }
  ' "$file" 2>/dev/null || true
}

# Classify a sandbox's currency against the LOCAL pinned PATTERNS_KIT_REF.
# Echoes exactly one of: current | stale | unknown.
#   current — record exists and applied_ref == local PATTERNS_KIT_REF.
#   stale   — record exists and applied_ref != local PATTERNS_KIT_REF.
#   unknown — no record (legacy sandbox, or host state lost) or unreadable.
# Fail-open: on any doubt it returns "unknown", which callers treat as "offer a
# refresh" — never as "force" and never as a launch blocker.
# Usage: acq_provenance_status BACKEND SANDBOX_NAME
acq_provenance_status() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || { printf 'unknown\n'; return 0; }
  local applied
  applied=$(acq_provenance_field "$backend" "$name" applied_ref)
  if [ -z "$applied" ]; then
    printf 'unknown\n'
    return 0
  fi
  if [ "$applied" = "$PATTERNS_KIT_REF" ]; then
    printf 'current\n'
  else
    printf 'stale\n'
  fi
  return 0
}

# Reapply the built-in bundle to an existing sandbox and, on success, refresh its
# host-side provenance record. Uses the backend's heal path
# (acq_backend_ensure_kits_applied) with ACQ_FORCE_KIT_REAPPLY=1 so a
# present-but-stale kit is actually re-applied (the sbx feature-probe would
# otherwise skip a kit that is present but built from an older ref). msb already
# re-applies all kits idempotently; the force flag is a no-op there. After a usai
# refresh the kit's own startup global-merge re-runs on next attach, so the
# refreshed model catalog reaches the config. State (sessions, secrets, unrelated
# config, project overrides) is preserved: this is an in-place kit reapply, never
# a sandbox delete/recreate.
# Returns 0 on success (bundle applied + provenance updated by the heal path),
# non-zero on apply failure (record left untouched, so the sandbox correctly
# stays "stale/unknown").
# Usage: acq_bundle_reapply BACKEND SANDBOX_NAME
acq_bundle_reapply() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  if ! command -v acq_backend_ensure_kits_applied >/dev/null 2>&1; then
    echo "acq: error: backend '$backend' cannot reapply kits (no ensure_kits_applied)." >&2
    return 1
  fi
  echo "acq: refreshing the built-in kit bundle in '$name' (in place; state preserved)..." >&2
  # ensure_kits_applied writes provenance itself on full success and returns
  # non-zero on any built-in-kit failure, so we do not double-write here.
  if ACQ_FORCE_KIT_REAPPLY=1 acq_backend_ensure_kits_applied "$name"; then
    echo "acq: '$name' refreshed to patterns ref ${PATTERNS_KIT_REF}." >&2
    echo "      Restart the agent (or re-run 'acq run') to pick up refreshed config." >&2
    return 0
  fi
  echo "acq: warning: kit refresh for '$name' did not complete cleanly; leaving it as-is." >&2
  echo "      The sandbox and its state are untouched. Re-run 'acq kit update $name' to retry," >&2
  echo "      or 'acq rm $name && acq run ...' for a clean rebuild." >&2
  return 1
}

# Automatic stale-sandbox advisory for `acq run` on an EXISTING sandbox. Compares
# the sandbox's recorded bundle ref against the local pinned PATTERNS_KIT_REF and,
# when they differ (or no record exists), OFFERS an in-place refresh. Contract:
#   - Opt-out: ACQ_UPDATE_CHECK=0 (or `acq run --no-update-check`) skips entirely.
#   - Interactive only. Non-interactive (no TTY on stdin) NEVER blocks: it prints
#     one concise advisory and returns 0 so the run continues.
#   - Default is No. A bare Enter, EOF (Ctrl-D / closed stdin), or anything other
#     than an explicit yes declines — and a decline never prevents launch.
#   - Fail-open: "unknown" status (legacy/lost record) is advisory, not forced.
# The caller MUST pass the status captured BEFORE the pre-attach heal, because the
# heal rewrites provenance to "current" — reading status here would then always
# see "current" and never offer. $3 is that pre-heal status (current|stale|
# unknown); when omitted we read it live (used by unit tests that seed a record).
# This function always returns 0 (it must never abort a run); the refresh itself
# is best-effort.
# Usage: maybe_offer_bundle_refresh BACKEND SANDBOX_NAME [PRE_HEAL_STATUS]
maybe_offer_bundle_refresh() {
  local backend="${1:-}" name="${2:-}" status="${3:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 0

  # Opt-out short-circuits the entire check.
  [ "${ACQ_UPDATE_CHECK:-1}" = "0" ] && return 0

  [ -n "$status" ] || status=$(acq_provenance_status "$backend" "$name")
  # Nothing to do when the sandbox is already on the pinned bundle.
  [ "$status" = "current" ] && return 0

  case "$status" in
    stale)
      echo "acq: note — '$name' was built from an older kit bundle than your pinned" >&2
      echo "      version (local patterns ref ${PATTERNS_KIT_REF})." >&2
      ;;
    *)
      # unknown: legacy sandbox (pre-provenance) or lost host record.
      echo "acq: note — acq cannot confirm '$name' is on your pinned kit bundle" >&2
      echo "      (no provenance record; it may predate provenance tracking)." >&2
      ;;
  esac
  echo "      A refresh updates the built-in kits (USAi config, playbook, Zscaler CA," >&2
  echo "      git-ssh-sign) in place. Your sessions, secrets, and project files are kept." >&2

  # Non-interactive: advise how to do it explicitly, then continue. Never block.
  if [ ! -t 0 ]; then
    echo "      To refresh later: acq kit update $name" >&2
    echo "      To silence this check: ACQ_UPDATE_CHECK=0 (or acq run --no-update-check)." >&2
    return 0
  fi

  local ans=""
  printf 'acq: refresh the kit bundle in %s now? [y/N] ' "$name" >&2
  read -r ans 2>/dev/null || ans=""
  case "$ans" in
    y|Y|yes|YES)
      acq_bundle_reapply "$backend" "$name" || true
      ;;
    *)
      echo "acq: continuing without refreshing (run 'acq kit update $name' anytime)." >&2
      ;;
  esac
  return 0
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

# Warn (do not block) if the mounted workspace has no usable git identity.
# Only a repo-local identity crosses into the sandbox (the sandbox home is empty
# and the host's global ~/.gitconfig is NOT mounted), so guidance must point at
# repo-local config. Classifies the workspace path P into four cases:
#   (a) P is itself a git repo    -> warn if effective user.email is unset
#   (b) P is not a repo but has    -> tell the user to set identity per sub-repo
#       depth-1 sub-repos              (names a capped, symlink-safe list)
#   (c) P is a dir with no repos   -> forward-looking new-workspace onboarding
#       yet (new workspace)           note (only on first create; see caller)
#   (d) P is not a directory       -> silent (the pre-flight path check owns this)
# Warn-not-block throughout. Portable across macOS (bash 3.2, BSD find) + Linux.
warn_if_no_git_identity() {
  local path="${1:-}"
  command -v git >/dev/null 2>&1 || return 0
  [ -n "$path" ] && [ -d "$path" ] || return 0   # (d) handled by pre-flight

  # (a) P is itself a git work tree.
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local email
    # Prefer EFFECTIVE identity (not just --local) so an already-resolvable
    # value doesn't false-warn.
    email=$(git -C "$path" config user.email 2>/dev/null || true)
    [ -n "$email" ] && return 0
    echo "acq: note — this repo has no git user.email set." >&2
    echo "      The sandbox home is isolated, so commits will be SIGNED but show" >&2
    echo "      'Unverified' on GitHub until you set an identity. Fix (in this repo):" >&2
    echo "        git config user.email you@verified-on-github.example" >&2
    echo "        git config user.name  \"Your Name\"" >&2
    return 0
  fi

  # (b) Not a repo itself — scan immediate children for git repos. symlink-safe
  # (! -type l, no -L), depth-1 only, prune common noise, and CAP the scan so a
  # huge/monorepo/flat root can't stall startup. `.git` may be a dir (repo) or a
  # file (submodule/worktree) -> test -e.
  local subrepos=() scanned=0 found_more=0 d base
  while IFS= read -r d; do
    case "$(basename "$d")" in
      node_modules|.venv|venv|vendor|target|dist|build) continue ;;
    esac
    scanned=$((scanned + 1))
    if [ "$scanned" -gt 200 ]; then found_more=1; break; fi
    if [ -e "$d/.git" ]; then
      if [ "${#subrepos[@]}" -lt 10 ]; then
        subrepos+=("$(basename "$d")")
      else
        found_more=1
      fi
    fi
  done < <(find "$path" -maxdepth 1 -mindepth 1 -type d ! -type l 2>/dev/null)

  if [ "${#subrepos[@]}" -gt 0 ]; then
    echo "acq: note — this workspace root is not a git repo; its subfolders are." >&2
    echo "      The sandbox home is isolated, so set identity in each sub-repo you" >&2
    echo "      commit from (commits are signed but show 'Unverified' otherwise):" >&2
    local r
    for r in "${subrepos[@]}"; do
      # %q-escape the name so odd/hostile filenames can't inject terminal control
      printf '        git -C %q config user.email you@verified-on-github.example\n' "$path/$r" >&2
    done
    [ "$found_more" -eq 1 ] && echo "        (…and more — set identity in each repo as you commit from it.)" >&2
    return 0
  fi

  # (c) A directory with no repos yet — a NEW/intended workspace. Forward-looking
  # onboarding note (emitted only on first create; the caller gates this).
  echo "acq: note — this workspace has no git repos yet." >&2
  echo "      When you clone one in, set its identity so commits are Verified:" >&2
  echo "        git -C <repo> config user.email you@verified-on-github.example" >&2
  echo "        git -C <repo> config user.name  \"Your Name\"" >&2
  echo "      (and load your signing key on the host: ssh-add ~/.ssh/id_ed25519)." >&2
  echo "      The sandbox home is isolated, so git identity is set per-repo." >&2
}

# ---------------------------------------------------------------------------
# GitHub token down-scoping (ADR-0013)
# ---------------------------------------------------------------------------
# The global `sbx secret set -g github` path injects the user's broad gh token
# into EVERY sandbox. These helpers instead detect the GitHub repos actually
# present in the mounted workspace and guide the user to a fine-grained PAT
# scoped to just those repos, stored sandbox-scoped (acq.<sandbox>.github).
# See ADR-0013 for why this is guided (no API mints a fine-grained PAT) and why
# the alternatives (token/scoped, App tokens, Jentic, firewall) were not used.

# _acq_parse_github_nwo URL -> "owner/repo" on STDOUT (empty if not github.com).
# Handles https://github.com/O/R(.git), git@github.com:O/R(.git),
# ssh://git@github.com/O/R(.git). Pure string work — no network.
_acq_parse_github_nwo() {
  local url="$1" rest=""
  case "$url" in
    https://github.com/*|http://github.com/*) rest="${url#*github.com/}" ;;
    git@github.com:*)                         rest="${url#git@github.com:}" ;;
    ssh://git@github.com/*)                   rest="${url#ssh://git@github.com/}" ;;
     git://github.com/*)                       rest="${url#git://github.com/}" ;;
    *) return 0 ;;
  esac
  rest="${rest%.git}"        # strip trailing .git
  rest="${rest%/}"           # strip trailing slash
  # Keep only owner/repo (drop any deeper path), require exactly two segments.
  local owner="${rest%%/*}" repo="${rest#*/}"
  repo="${repo%%/*}"
  [ -n "$owner" ] && [ -n "$repo" ] || return 0
  printf '%s/%s\n' "$owner" "$repo"
}

# detect_workspace_repos PATH -> newline-separated deduped "owner/repo" list on
# STDOUT for every github.com remote found. Mirrors warn_if_no_git_identity's
# capped, symlink-safe classification: the path may itself be a repo, or a
# parent whose depth-1 children are repos. Reads each repo's remote.origin.url
# (falls back to the first configured remote). No network, no side effects.
detect_workspace_repos() {
  local path="${1:-}"
  command -v git >/dev/null 2>&1 || return 0
  [ -n "$path" ] && [ -d "$path" ] || return 0

  local dirs=() d
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirs=("$path")
  else
    local scanned=0
    while IFS= read -r d; do
      case "$(basename "$d")" in
        node_modules|.venv|venv|vendor|target|dist|build) continue ;;
      esac
      scanned=$((scanned + 1))
      [ "$scanned" -gt 200 ] && break
      [ -e "$d/.git" ] && dirs+=("$d")
    done < <(find "$path" -maxdepth 1 -mindepth 1 -type d ! -type l 2>/dev/null)
  fi

  local url nwo seen="" out=""
  for d in ${dirs[@]+"${dirs[@]}"}; do
    url=$(git -C "$d" config --get remote.origin.url 2>/dev/null || true)
    if [ -z "$url" ]; then
      url=$(git -C "$d" config --get-regexp '^remote\..*\.url$' 2>/dev/null \
        | head -n1 | cut -d' ' -f2- || true)
    fi
    [ -n "$url" ] || continue
    nwo=$(_acq_parse_github_nwo "$url") || true
    [ -n "$nwo" ] || continue
    case "$seen" in *"|$nwo|"*) continue ;; esac
    seen="$seen|$nwo|"
    out="$out$nwo
"
  done
  printf '%s' "$out"
}

# URL-encode a string for a query parameter (RFC 3986 unreserved kept as-is).
_acq_urlencode() {
  local s="$1" i c out=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Build a pre-filled fine-grained-PAT creation URL for one owner. Selects the
# minimal default permissions for the normal agent loop — code (contents),
# PRs, and issues at read/write, plus actions=read so the agent can read the
# Actions workflow-run status that surfaces PR checks. Deliberately scoped to
# least privilege (ADR-0013): actions is read-only (not write — write also
# grants cancel-runs and delete logs/artifacts, working against the AU-2 audit
# goal), and no workflows scope (workflows=write grants create/edit of
# .github/workflows/* — a CI privilege-escalation vector). write implies read;
# metadata:read is always included by GitHub. Note: fine-grained PATs cannot
# call the Checks API (a GitHub limitation, see ADR-0013); actions=read covers
# the Actions workflow-run status that surfaces most PR checks. Users can widen
# scopes (e.g. actions=write to re-run, or add workflows) in the GitHub form.
# The user still picks the specific repositories in the form (fine-grained PATs
# are single-owner).
# Args: OWNER SANDBOX_NAME
_acq_github_pat_url() {
  local owner="$1" sandbox="$2" name
  name=$(_acq_urlencode "acq-${sandbox}")
  printf 'https://github.com/settings/personal-access-tokens/new?name=%s&target_name=%s&expires_in=30&contents=write&pull_requests=write&issues=write&actions=read\n' \
    "$name" "$(_acq_urlencode "$owner")"
}

# github_scope_sandbox SANDBOX WORKSPACE — guide the user through minting a
# fine-grained PAT scoped to the workspace's repos and store it sandbox-scoped.
# Warn-not-block: returns 0 even if the user declines. Never places the token in
# argv (delegates to acq_secret_set_interactive via the backend secret path).
github_scope_sandbox() {
  local sandbox="$1" ws="${2:-}"
  local repos owners="" nwo owner

  repos=$(detect_workspace_repos "$ws")
  if [ -z "$repos" ]; then
    echo "acq: no GitHub repositories detected in the workspace; nothing to scope." >&2
    return 0
  fi

  # Distinct owners.
  while IFS= read -r nwo; do
    [ -n "$nwo" ] || continue
    owner="${nwo%%/*}"
    case "$owners" in *"|$owner|"*) ;; *) owners="$owners|$owner|" ;; esac
  done <<EOF
$repos
EOF

  echo "acq: scoping a GitHub token for sandbox '$sandbox'." >&2
  echo "" >&2
  echo "      GitHub has no API to mint a fine-grained PAT, so create it in the" >&2
  echo "      browser. For EACH owner below, open the pre-filled link, select" >&2
  echo "      'Only select repositories' and choose the repo(s) listed below," >&2
  echo "      then generate the token and paste it back here." >&2
  echo "      Default permissions: Contents=Read/Write, Pull requests=Read/Write," >&2
  echo "      Issues=Read/Write, Actions=Read (lets the agent read the PR-check" >&2
  echo "      workflow runs). Widen in the form if you need more — e.g." >&2
  echo "      Actions=Read/Write to re-run checks, or add Workflows to edit" >&2
  echo "      .github/workflows/* files." >&2

  local o
  local _oldifs="$IFS"; IFS='|'
  # shellcheck disable=SC2086
  set -- $owners
  IFS="$_oldifs"
  for o in "$@"; do
    [ -n "$o" ] || continue
    echo "" >&2
    echo "      Owner '$o' — open:" >&2
    printf '        %s\n' "$(_acq_github_pat_url "$o" "$sandbox")" >&2
  done

  echo "" >&2
  echo "      Scope the token to just these repositories:" >&2
  while IFS= read -r nwo; do [ -n "$nwo" ] && printf '        %s\n' "$nwo" >&2; done <<EOF
$repos
EOF

  echo "" >&2
  echo "      When you have a token, paste it at the prompt (input hidden)." >&2
  echo "      To skip for now, press Enter on an empty line." >&2

  # Store sandbox-scoped via the backend secret path (feeds the sbx proxy too).
  # acq_backend_secret_set reads the value from the TTY (never argv). An empty
  # entry aborts cleanly (warn-not-block).
  if command -v acq_backend_secret_set >/dev/null 2>&1; then
    acq_backend_secret_set "$sandbox" github || {
      echo "acq: github scoping skipped or failed; continuing (you can re-run later" >&2
      echo "      with: acq github-scope $sandbox $ws)." >&2
      return 0
    }
  else
    echo "acq: internal error: backend secret path not loaded; cannot store token." >&2
    return 0
  fi
  echo "acq: stored a repo-scoped GitHub token for sandbox '$sandbox'." >&2
  return 0
}

# advise_github_scope SANDBOX WORKSPACE — on acq run, nudge toward a per-sandbox
# scoped GitHub token. Fires when the workspace has GitHub repos AND no
# sandbox-scoped github secret exists yet (regardless of whether a broad global
# one exists). Warn-not-block; interactive TTY gets a [continue/scope now]
# prompt (default: continue). No-op in CI / non-TTY beyond printing the advisory.
advise_github_scope() {
  local sandbox="${1:-}" ws="${2:-}"
  [ -n "$sandbox" ] || return 0

  # Already scoped for this sandbox? Nothing to do.
  if command -v acq_secret_get >/dev/null 2>&1 \
      && acq_secret_get "$(_acq_secret_key github "$sandbox")" >/dev/null 2>&1; then
    return 0
  fi

  local repos
  repos=$(detect_workspace_repos "$ws")
  [ -n "$repos" ] || return 0   # no GitHub repos → nothing to scope

  local has_global="no"
  if command -v acq_secret_get >/dev/null 2>&1 \
      && acq_secret_get "$(_acq_secret_key github)" >/dev/null 2>&1; then
    has_global="yes"
  fi

  echo "acq: note — this sandbox has no repo-scoped GitHub token." >&2
  if [ "$has_global" = "yes" ]; then
    echo "      A GLOBAL GitHub token is set; it grants this sandbox access to ALL" >&2
    echo "      your repositories — broader than the repos mounted here." >&2
  else
    echo "      No GitHub token is set for this sandbox." >&2
  fi
  echo "      For least privilege, scope a token to just the mounted repo(s)." >&2

  # Non-interactive (CI, piped): advise and continue.
  if [ ! -t 0 ]; then
    echo "      To scope it later: acq github-scope $sandbox $ws" >&2
    return 0
  fi

  local ans=""
  printf 'acq: scope a GitHub token for this sandbox now? [y/N] ' >&2
  read -r ans 2>/dev/null || ans=""
  case "$ans" in
    y|Y|yes|YES) github_scope_sandbox "$sandbox" "$ws" ;;
    *) echo "acq: continuing without scoping (run 'acq github-scope $sandbox $ws' anytime)." >&2 ;;
  esac
  return 0
}

# Pre-flight: validate the workspace path BEFORE provisioning. Fails fast on a
# file or a missing path (with an actionable mkdir hint) rather than passing a
# bad path to `sbx create` and surfacing an opaque backend error. Never creates
# host dirs (no surprising filesystem mutations) and never prompts (CI-safe).
# Returns non-zero to abort the run. #<issue>.
preflight_workspace_path() {
  local path="${1:-}"
  [ -n "$path" ] || return 0            # no path arg -> caller's $PWD default
  if [ -e "$path" ]; then
    if [ ! -d "$path" ]; then
      echo "acq: error — workspace must be a directory: $path" >&2
      return 1
    fi
    return 0
  fi
  echo "acq: error — workspace path does not exist: $path" >&2
  echo "      If this is a new workspace, create it first, then re-run:" >&2
  printf '        mkdir -p %q && acq run …\n' "$path" >&2
  return 1
}

# Validate the sandbox's USAi key and walk the user through rotating it if
# needed. Best-effort: warn and continue if we cannot run the check.
# advise_valid_key NAME — non-blocking USAi key advisory for `acq create`.
# Unlike ensure_valid_key (which gates attach and offers interactive rotation),
# this only WARNS if the key isn't valid, then returns 0 regardless. `create`
# is detached and never attaches, so there is nothing to gate; the point is to
# give a create-only user a heads-up that their key is stale before they later
# `acq run`. Silent on a healthy key or an inconclusive check (empty status).
advise_valid_key() {
  local name="$1"
  local status
  status=$(check_key "$name")

  # 200 = healthy; empty = could not validate (network/tooling) — stay quiet in
  # both cases to avoid noise. Only speak up on a definitive non-200.
  [ "$status" = "200" ] && return 0
  [ -z "$status" ] && return 0

  echo "acq: note — your USAi API key looks invalid or expired (HTTP $status)." >&2
  echo "      USAi keys expire every 7 days. This sandbox was created, but the" >&2
  echo "      key must be valid before an agent can use it." >&2
  echo "      To rotate: acq usai-rotate-api-key   (or re-run via 'acq run', which" >&2
  echo "      validates and offers to rotate before attaching)." >&2
  return 0
}

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

  # Distinguish "no key stored yet" (first-time setup) from "key present but
  # rejected" (expired/invalid), so the guidance and prompt match reality. If
  # the store helper isn't loaded, assume a key is present so wording never
  # regresses to the wrong direction.
  local have_key=1
  if command -v acq_secret_has >/dev/null 2>&1; then
    acq_secret_has usai "$name" || have_key=0
  fi

  echo >&2
  if [ "$have_key" -eq 0 ]; then
    echo "No USAi API key is set for '$name' (HTTP $status from the models API)." >&2
    echo "USAi keys are created at $KEY_MGMT_URL and expire every 7 days." >&2
    echo >&2
    echo "To set one:" >&2
    echo "  1. Open $KEY_MGMT_URL" >&2
    echo "  2. Create a key (or copy an existing one) with the console copy button" >&2
  else
    echo "Your USAi API key looks invalid or expired (HTTP $status from the models API)." >&2
    echo "USAi keys expire every 7 days." >&2
    echo >&2
    echo "To rotate it:" >&2
    echo "  1. Open $KEY_MGMT_URL" >&2
    echo "  2. Choose 'Rotate' from the Actions menu for your key" >&2
    echo "  3. Copy the new key using the console copy button" >&2
  fi
  echo >&2

  if ! command -v acq_backend_rotate_key >/dev/null 2>&1; then
    echo "The '${ACQ_RESOLVED_BACKEND:-active}' backend does not implement key setup." >&2
    echo "Set the key manually, then re-run." >&2
    return 1
  fi

  local answer=""
  if [ "$have_key" -eq 0 ]; then
    printf 'Have your USAi key ready to paste? Set it now? [y/N] ' >&2
  else
    printf 'Have the new key ready to paste? Rotate now? [y/N] ' >&2
  fi
  read -r answer || true
  case "$answer" in
    [yY]|[yY][eE][sS])
      acq_backend_rotate_key || {
        echo "Key setup did not complete. Aborting attach." >&2
        return 1
      }
      status=$(check_key "$name")
      if [ "$status" = "200" ]; then
        echo "Key validated. Continuing." >&2
        return 0
      fi
      echo "Key still not working (HTTP ${status:-unknown}). Aborting attach." >&2
      return 1
      ;;
    *)
      echo "Skipping. Aborting attach; re-run when your USAi key is set." >&2
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
  # ACQ_RESOLVED_BACKEND is always set by acq_resolve_backend before doctor runs,
  # so the ':-msb' here is only a defensive fallback — it mirrors auto-detect's
  # default and does NOT let doctor independently pick a backend.
  printf "  Write '%s' as the default backend to %s? [y/N] " "${ACQ_RESOLVED_BACKEND:-msb}" "$config_file" >&2
  local answer=""
  read -r answer || true
  case "$answer" in
    [yY]|[yY][eE][sS])
      local cfg_dir
      cfg_dir=$(dirname "$config_file")
      mkdir -p "$cfg_dir"
      printf 'backend: %s\n' "${ACQ_RESOLVED_BACKEND:-msb}" > "$config_file"
      echo "  Wrote default backend to ${config_file}." >&2
      ;;
    *)
      echo "  Not written." >&2
      ;;
  esac
}
