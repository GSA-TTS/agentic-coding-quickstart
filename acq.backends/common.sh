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
PATTERNS_KIT_REF="f60a805f9a3efb8596043d11d8d508859d80d9b4"  # agentic-coding-patterns main as of PR #386 merging
PATTERNS_KIT_DIR="integrations/isolation/acq-kits"

USAI_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/usai-provider"
PLAYBOOK_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/agentic-coding-playbook"
ZSCALER_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/zscaler-ca-certificate"
GITSSHSIGN_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/git-ssh-sign"

# Neutral kit directory names (relative to PATTERNS_KIT_DIR), in apply order.
# kit-translate.sh resolves a kit's spec.yaml + files/ from these names. The
# built-in kit set maps 1:1 to the four *_KIT refs above.
#
# ORDER MATTERS: zscaler-ca-certificate is applied FIRST so its CA trust is in
# place before any later kit makes an outbound HTTPS request. Behind a
# TLS-intercepting proxy (e.g. Zscaler), a kit that fetches over the network
# (the playbook kit clones from api.github.com; the USAi provider validates
# against api.gsa.usai.gov) fails with a TLS 'unexpected eof' unless the
# intercepting CA is already trusted. Establishing trust first makes the rest
# of the bundle succeed on corporate networks.
# shellcheck disable=SC2034  # consumed by `acq kit list` in the acq entry point
ACQ_KIT_NAMES=(zscaler-ca-certificate usai-provider agentic-coding-playbook git-ssh-sign)

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

# Source the TTY-aware progress helpers (acq_status / acq_spin_start /
# acq_spin_stop). Used by the backend adapters to give friendly feedback during
# the long, quiet provision/heal/rotate phases. Animation is TTY-gated and never
# leaks into a captured/piped stream (see progress.sh). If the file is missing
# (e.g. an older partial checkout), define no-op fallbacks so callers never break.
if [ -n "${ACQ_SCRIPT_DIR:-}" ] && [ -f "${ACQ_SCRIPT_DIR}/acq.backends/progress.sh" ]; then
  # shellcheck disable=SC1091
  . "${ACQ_SCRIPT_DIR}/acq.backends/progress.sh"
fi
if ! command -v acq_status >/dev/null 2>&1; then
  acq_status()     { printf 'acq: %s\n' "$*" >&2; }
  acq_spin_start() { acq_status "$*"; }
  acq_spin_stop()  { :; }
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

# _acq_import_env_vars_for SERVICE — echo the host environment variable name(s)
# that `acq secret import` reads to populate SERVICE, most-preferred first (space
# separated). These mirror the env vars each backend already honors when binding
# the service (see the sbx/msb adapters and the kits' env expectations):
#   usai   <- USAI_API_KEY
#   github <- GITHUB_TOKEN, then GH_TOKEN (gh CLI's variable)
#   gitlab <- GITLAB_TOKEN
# Only acq-managed services are importable; an unknown service echoes nothing.
_acq_import_env_vars_for() {
  case "$1" in
    usai)   printf 'USAI_API_KEY\n' ;;
    github) printf 'GITHUB_TOKEN GH_TOKEN\n' ;;
    gitlab) printf 'GITLAB_TOKEN\n' ;;
    *)      printf '\n' ;;
  esac
}

# _acq_import_detect_var SERVICE -> prints the NAME of the FIRST of SERVICE's
# candidate env vars that is set and non-empty; empty output (rc 1) if none is
# set. Returns the variable NAME ONLY — never the value — so the secret value is
# never packed into a string that is later re-parsed or echoed (which previously
# truncated multi-line values and leaked a fragment to stderr). Callers read the
# value directly from the named variable at the point of use and pipe it straight
# to the store.
_acq_import_detect_var() {
  local service="$1" var val
  for var in $(_acq_import_env_vars_for "$service"); do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
      printf '%s\n' "$var"
      return 0
    fi
  done
  return 1
}

# _acq_import_value_is_storable ENVVAR -> 0 if the value in ENVVAR is safe to
# store in acq's single-line secret store; 1 otherwise. The store persists a
# single line, so a value containing a newline or TAB cannot round-trip intact —
# storing it would silently truncate the credential. Fail closed on such values
# (the caller reports the rejection WITHOUT ever printing the value). Reads the
# value by name; never echoes or copies it into argv.
_acq_import_value_is_storable() {
  local val nl tab
  eval "val=\${$1:-}"
  nl=$(printf '\n_'); nl=${nl%_}   # a literal newline (command subst strips it otherwise)
  tab=$(printf '\t')
  case "$val" in
    *"$nl"*) return 1 ;;
    *"$tab"*) return 1 ;;
    *) return 0 ;;
  esac
}

# _acq_secret_last4_of ENVVAR -> a masked preview "…WXYZ" (last 4 chars) of the
# value held in ENVVAR, for a Y/n prompt. Reads the value BY NAME (never via
# argv) and prints at most the last 4 characters; a short value is fully masked.
# Used only for interactive confirmation feedback. A newline/tab in the value is
# irrelevant here (such values are rejected before this is called), but the
# last-4 slice is inherently bounded regardless.
_acq_secret_last4_of() {
  local v n
  eval "v=\${$1:-}"
  n=${#v}
  if [ "$n" -le 4 ]; then
    printf '…%s\n' "$(printf '%*s' "$n" '' | tr ' ' '*')"
  else
    printf '…%s\n' "${v#"${v%????}"}"
  fi
}

# _acq_is_managed_service SERVICE -> 0 if SERVICE is an acq-managed service.
_acq_is_managed_service() {
  case "$ACQ_MANAGED_SECRET_SERVICES" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# _acq_import_decide MODE DRY_RUN EXISTS -> prints one of "import", "skip", or
# "prompt" on stdout: the decision for a single detected service under MODE
# (interactive|all|force), whether this is a DRY_RUN (1/0), and whether an entry
# already EXISTS (1/0). Keeps acq_secret_import's per-service loop small (≤50
# lines) and the mode/overwrite policy in one testable place. Never touches the
# secret value.
_acq_import_decide() {
  local mode="$1" dry_run="$2" exists="$3"
  case "$mode" in
    all)   [ "$exists" -eq 1 ] && { printf 'skip\n'; return 0; }; printf 'import\n' ;;
    force) printf 'import\n' ;;
    *)     printf 'prompt\n' ;;   # interactive
  esac
}

# _acq_import_confirm SVC ENVVAR SCOPE_DESC EXISTS PREVIEW -> 0 to proceed, 1 to
# skip. Handles the interactive Y/n gate: honors ACQ_SECRET_IMPORT_ASSUME_YES
# (test/non-interactive override), skips (rc 1) when stdin is not a TTY, else
# prompts. All prompt text is built from names/labels only — never the value.
_acq_import_confirm() {
  local svc="$1" envvar="$2" scope_desc="$3" exists="$4" preview="$5" ans=""
  if [ ! -t 0 ] && [ -z "${ACQ_SECRET_IMPORT_ASSUME_YES:-}" ]; then
    echo "acq: '$svc' detected in \$${envvar} but stdin is not a TTY; skipping (use --all/--force)." >&2
    return 1
  fi
  if [ -n "${ACQ_SECRET_IMPORT_ASSUME_YES:-}" ]; then
    return 0
  fi
  if [ "$exists" -eq 1 ]; then
    printf 'acq: overwrite stored %s (%s) with $%s (%s)? [y/N] ' "$svc" "$scope_desc" "$envvar" "$preview" >&2
  else
    printf 'acq: import %s from $%s (%s) into %s? [y/N] ' "$svc" "$envvar" "$preview" "$scope_desc" >&2
  fi
  read -r ans 2>/dev/null || ans=""
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# _acq_import_one SVC ENVVAR KEY SCOPE_DESC MODE DRY_RUN EXISTS
# ---------------------------------------------------------------------------
# Handle a single detected service: apply the mode/overwrite decision, prompt if
# interactive, and (unless --dry-run) store the value. The value is read DIRECTLY
# from the named env var ($ENVVAR) and piped straight to the store — it is never
# packed into a parsed string, never placed on argv, and never interpolated into
# a message (all user-facing text is built from $SVC/$ENVVAR/$SCOPE_DESC only).
# Prints its own progress to stderr. Echoes a single result token on stdout:
# "imported", "skipped", or "" + non-zero on a store write failure.
_acq_import_one() {
  local svc="$1" envvar="$2" key="$3" scope_desc="$4" mode="$5" dry_run="$6" exists="$7"
  local preview decision _v
  preview=$(_acq_secret_last4_of "$envvar")

  if [ "$dry_run" -eq 1 ]; then
    if [ "$exists" -eq 1 ] && [ "$mode" = "all" ]; then
      echo "acq: [dry-run] '$svc' already stored (${scope_desc}); would SKIP (use --force)." >&2
      printf 'skipped\n'
    elif [ "$exists" -eq 1 ]; then
      echo "acq: [dry-run] would OVERWRITE '$svc' (${scope_desc}) from \$${envvar} (${preview})." >&2
      printf 'imported\n'
    else
      echo "acq: [dry-run] would import '$svc' from \$${envvar} (${preview}) into ${scope_desc}." >&2
      printf 'imported\n'
    fi
    return 0
  fi

  decision=$(_acq_import_decide "$mode" "$dry_run" "$exists")
  if [ "$decision" = "skip" ]; then
    echo "acq: '$svc' already stored (${scope_desc}); skipping (use --force to overwrite)." >&2
    printf 'skipped\n'; return 0
  fi
  if [ "$decision" = "prompt" ] && ! _acq_import_confirm "$svc" "$envvar" "$scope_desc" "$exists" "$preview"; then
    # Non-TTY skip already logged its reason; an explicit "no" gets a generic note.
    [ -t 0 ] && echo "acq: skipped '$svc'." >&2
    printf 'skipped\n'; return 0
  fi

  # Store the value read DIRECTLY from the named env var (never argv, never a
  # parsed copy) piped straight to the single-line store. Read by name into a
  # local, then pipe — no command substitution (which would strip a trailing
  # newline) and no interpolation into any message.
  eval "_v=\${$envvar}"
  if printf '%s' "$_v" | acq_secret_store "$key"; then
    _v=""
    echo "acq: imported '$svc' (${scope_desc}) from \$${envvar}." >&2
    printf 'imported\n'; return 0
  fi
  _v=""
  echo "acq: error: failed to store '$svc' (${scope_desc})." >&2
  return 1
}

# _acq_import_parse_args ARGS... -> on success prints "MODE<TAB>DRY_RUN<TAB>SERVICE<TAB>SANDBOX"
# (SERVICE/SANDBOX may be empty), rc 0; on a usage error prints nothing and
# returns 1 (the caller emits the error — this parser writes the specific
# message to stderr itself before returning). MODE is interactive|all|force.
# These fields are all flags/short identifiers (never a secret), so the TAB
# framing is safe here (unlike a secret value). Recognizes: an optional leading
# managed-SERVICE, then a scope (-g/--global or a bare SANDBOX token), plus
# --all / --force|-f / --dry-run in any order.
_acq_import_parse_args() {
  local only_service="" scope_sandbox="" mode="interactive" dry_run=0 arg
  for arg in "$@"; do
    case "$arg" in
      --all)       mode="all" ;;
      --force|-f)  mode="force" ;;
      --dry-run)   dry_run=1 ;;
      -g|--global) scope_sandbox="" ;;   # global is already the default
      -*)
        echo "acq: secret import: unknown flag '$arg'" >&2
        echo "     usage: acq secret import [SERVICE] [-g | SANDBOX] [--all] [--force] [--dry-run]" >&2
        return 1
        ;;
      *)
        # First bare token that is a managed service -> restrict to it; a second
        # bare token is the SANDBOX scope (NOT a second service).
        if [ -z "$only_service" ] && _acq_is_managed_service "$arg"; then
          only_service="$arg"
        elif [ -z "$scope_sandbox" ]; then
          scope_sandbox="$arg"
        else
          echo "acq: secret import: unexpected extra argument '$arg'" >&2
          return 1
        fi
        ;;
    esac
  done
  printf '%s\t%s\t%s\t%s\n' "$mode" "$dry_run" "$only_service" "$scope_sandbox"
}

# acq_secret_import [SERVICE] [-g|--global|SANDBOX] [--all] [--force] [--dry-run]
# ---------------------------------------------------------------------------
# Scan the host environment for known acq-managed service tokens (usai, github,
# gitlab) and store each into the acq secret store — the same store `acq secret
# set` writes and both backends read at provision. This is acq's store-POPULATING
# migration helper (the inverse of the removed store-BYPASSING backend passthrough);
# see docs/BACKEND_GUIDE.md "Migration".
#
# Scope: GLOBAL by default (like sbx's global keychain — available to every
# sandbox); pass a SANDBOX name (or -g explicitly) to scope. A second bare token
# after a SERVICE is treated as the SANDBOX scope, NOT a second service. Existing
# stored entries are never overwritten silently:
#   - interactive (default): prompt Y/n per detected service (last-4 preview),
#     and prompt again before overwriting an existing entry;
#   - --all: import newly-detected services without prompting, but SKIP any that
#     already have a stored value (use --force / -f to replace);
#   - --force / -f: import unconditionally, overwriting existing entries;
#   - --dry-run: show what WOULD be imported/skipped, write nothing.
# The value moves from the environment into the store without ever appearing on
# argv (acq_secret_store reads it from stdin). A value containing a newline or TAB
# is REJECTED (fail closed) because the single-line store cannot round-trip it —
# the rejection never prints the value.
#
# Returns 0 if the run completed (even if nothing was imported), non-zero only on
# a usage error or a store write failure.
acq_secret_import() {
  local parsed mode dry_run only_service scope_sandbox
  parsed=$(_acq_import_parse_args "$@") || return 1
  mode=$(printf '%s' "$parsed" | cut -f1)
  dry_run=$(printf '%s' "$parsed" | cut -f2)
  only_service=$(printf '%s' "$parsed" | cut -f3)
  scope_sandbox=$(printf '%s' "$parsed" | cut -f4)

  if ! command -v acq_secret_store >/dev/null 2>&1; then
    echo "acq: internal error: secret store not loaded" >&2
    return 1
  fi

  # Which services to consider: a single named one, or all managed services.
  local services="$ACQ_MANAGED_SECRET_SERVICES"
  [ -n "$only_service" ] && services="$only_service"

  local scope_desc="global"
  [ -n "$scope_sandbox" ] && scope_desc="sandbox '$scope_sandbox'"
  echo "acq: scanning host environment for known service tokens (scope: ${scope_desc})…" >&2
  [ "$dry_run" -eq 1 ] && echo "acq: --dry-run: no values will be written." >&2

  local svc envvar key exists result imported=0 skipped=0 none=1
  for svc in $services; do
    envvar=$(_acq_import_detect_var "$svc") || continue
    none=0
    # Reject values the single-line store cannot round-trip (fail closed; the
    # value is never printed).
    if ! _acq_import_value_is_storable "$envvar"; then
      echo "acq: refusing '$svc' — \$${envvar} contains a newline or tab, which the acq secret store cannot store intact. Set a single-line value and retry." >&2
      skipped=$((skipped + 1))
      continue
    fi
    if ! key=$(_acq_secret_key "$svc" "$scope_sandbox"); then
      echo "acq: secret import: skipping '$svc' — ambiguous scope/service name." >&2
      skipped=$((skipped + 1))
      continue
    fi
    exists=0
    acq_secret_has "$svc" "$scope_sandbox" && exists=1
    result=$(_acq_import_one "$svc" "$envvar" "$key" "$scope_desc" "$mode" "$dry_run" "$exists") \
      || return 1
    case "$result" in
      imported) imported=$((imported + 1)) ;;
      skipped)  skipped=$((skipped + 1)) ;;
    esac
  done

  if [ "$none" -eq 1 ]; then
    echo "acq: no known service tokens found in the environment." >&2
    if [ -n "$only_service" ]; then
      echo "     '$only_service' reads: $(_acq_import_env_vars_for "$only_service")" >&2
    else
      echo "     Looked for: USAI_API_KEY, GITHUB_TOKEN/GH_TOKEN, GITLAB_TOKEN." >&2
    fi
    return 0
  fi
  echo "acq: secret import done — ${imported} imported, ${skipped} skipped." >&2
  return 0
}


# _acq_is_managed_secret_rm ARGS... -> 0 if the `acq secret rm` args name an
# acq-managed secret (scope + known service), else 1 (pass through to backend).
# Recognizes:  -g SERVICE  |  --global SERVICE  |  SANDBOX SERVICE
#
# "Managed" is EITHER a built-in service (usai/github/gitlab) OR any entry that
# actually exists in the acq store under the resolved scope. The store check
# means an entry `acq secret ls` shows can always be removed by `acq secret rm`,
# even if it was created with an arbitrary (e.g. sandbox-shaped) service name —
# otherwise such entries become un-removable orphans. A lone token with no scope
# is still NOT managed (it is a raw placeholder for a backend that has one).
_acq_is_managed_secret_rm() {
  local a1="${1:-}" a2="${2:-}" svc="" sandbox=""
  case "$a1" in
    -g|--global) svc="$a2" ;;
    -*)          return 1 ;;              # some other flag/placeholder
    *)
      # SANDBOX SERVICE form only (two positionals); a lone token is a raw
      # placeholder for the backend to handle.
      [ -n "$a2" ] || return 1
      case "$a2" in -*) return 1 ;; esac
      svc="$a2"; sandbox="$a1"
      ;;
  esac
  [ -n "$svc" ] || return 1
  case "$ACQ_MANAGED_SECRET_SERVICES" in
    *" $svc "*) return 0 ;;
  esac
  # Not a built-in: managed iff the entry exists in the acq store at this scope.
  # (Only checkable when the neutral store is loaded — the native-store backends.)
  if command -v _acq_secret_key >/dev/null 2>&1 && command -v acq_secret_get >/dev/null 2>&1; then
    local key
    key=$(_acq_secret_key "$svc" "$sandbox") || return 1
    acq_secret_get "$key" >/dev/null 2>&1 && return 0
  fi
  return 1
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
# Zscaler CA trust FIRST (see ACQ_KIT_NAMES) so later network-fetching kits
# succeed behind a TLS-intercepting proxy.
_build_kit_list() {
  KITS=("$ZSCALER_KIT" "$USAI_KIT" "$PLAYBOOK_KIT" "$GITSSHSIGN_KIT")
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
    --name|--template|-t|--profile|--cpus|--memory|-m|--kit|--backend|--image) return 0 ;;
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

# _acq_valid_vsock_port PORT — succeed (return 0) iff PORT is an integer in
# 1..4294967294 and not the reserved value 123. msb rejects port 0 and reserves
# 123 (see ADR-0021); we mirror that validation host-side so a bad port is
# skipped with a warning rather than surfacing as an opaque msb create failure.
_acq_valid_vsock_port() {
  local p="${1:-}"
  case "$p" in
    ""|*[!0-9]*) return 1 ;;
  esac
  # Numeric range check; 4294967294 is u32 max minus one (msb's upper bound).
  [ "$p" -ge 1 ] 2>/dev/null || return 1
  [ "$p" -le 4294967294 ] 2>/dev/null || return 1
  [ "$p" -ne 123 ] 2>/dev/null || return 1
  return 0
}

# acq_host_socket_forwards — emit the neutral host->guest socket forwards, one
# per line as "HOST_PATH<TAB>PORT<TAB>KIND<TAB>LABEL". This is the neutral
# vocabulary for widening the host<->guest trust boundary with a host unix
# socket (e.g. the ssh-agent). Backends translate each line to their native
# mechanism (msb: --vsock; sbx: implicit, no-op). Two sources:
#   1. AUTOMATIC ssh-agent: if the host has SSH_AUTH_SOCK set to an existing
#      socket, forward it (LABEL=ssh-agent, PORT from ACQ_SSH_AGENT_VSOCK_PORT
#      default 3552). This mirrors sbx, which forwards the agent whenever
#      SSH_AUTH_SOCK is set; unsetting SSH_AUTH_SOCK is the opt-out.
#   2. GENERAL: ACQ_FORWARD_HOST_SOCKETS="PATH:PORT[/stream|/dgram][,PATH:PORT...]"
#      for arbitrary host sockets (LABEL=custom).
# Host paths are canonicalized (symlink-free) and validated ABSOLUTE; a
# non-absolute or missing entry is skipped with a warning (fail-closed on the
# individual entry, never abort). Ports validated 1..4294967294, != 123.
# See ADR-0021.
# _acq_path_has_ctl PATH — succeed (0) iff PATH contains a TAB or newline. Such a
# path is filesystem-legal but would corrupt the TAB-separated forward records
# that acq_host_socket_forwards emits (the msb consumer re-splits with `cut -f`),
# so a matching path is rejected upstream. Uses a literal-TAB glob built with a
# real tab byte (portable across bash 3.2 and dash; a `$'\t'` glob is not).
_acq_path_has_ctl() {
  local _tab
  _tab=$(printf '\t')
  case "$1" in
    *"$_tab"*) return 0 ;;
  esac
  case "$1" in
    *"
"*) return 0 ;;
  esac
  return 1
}

acq_host_socket_forwards() {
  # (1) Automatic ssh-agent forward — opt-in via the host SSH_AUTH_SOCK env.
  local _agent_port="${ACQ_SSH_AGENT_VSOCK_PORT:-3552}"
  if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    if [ -S "$SSH_AUTH_SOCK" ]; then
      local _p="$SSH_AUTH_SOCK"
      if command -v canonicalize_path >/dev/null 2>&1; then
        _p=$(canonicalize_path "$SSH_AUTH_SOCK")
      fi
      # Validate the port the SAME way as the general path (SI-10): a user may
      # override ACQ_SSH_AGENT_VSOCK_PORT, so a bad value must be rejected host-
      # side rather than surface as an opaque `msb create` failure. Reject a
      # path with a TAB/newline too: the fields are emitted TAB-separated and the
      # msb consumer re-splits with `cut -f`, so an embedded TAB would corrupt
      # the port/kind fields (a filesystem-legal but pathological socket path).
      if ! _acq_valid_vsock_port "$_agent_port"; then
        printf 'acq: ACQ_SSH_AGENT_VSOCK_PORT %s is invalid (need 1..4294967294, != 123); skipping ssh-agent forwarding\n' "$_agent_port" >&2
      elif _acq_path_has_ctl "$_p"; then
        printf 'acq: SSH_AUTH_SOCK path contains a tab/newline; skipping ssh-agent forwarding\n' >&2
      else
        case "$_p" in
          /*) printf '%s\t%s\t%s\t%s\n' "$_p" "$_agent_port" "stream" "ssh-agent" ;;
          *) printf 'acq: SSH_AUTH_SOCK path is not absolute; skipping ssh-agent forwarding\n' >&2 ;;
        esac
      fi
    else
      printf 'acq: SSH_AUTH_SOCK is set but not a socket; skipping ssh-agent forwarding\n' >&2
    fi
  fi

  # (2) General arbitrary host-socket forwards from ACQ_FORWARD_HOST_SOCKETS.
  [ -n "${ACQ_FORWARD_HOST_SOCKETS:-}" ] || return 0
  local _oldifs="$IFS" _entry
  # Disable pathname expansion while word-splitting on commas so a socket path
  # containing a glob metacharacter (*, ?, [) is treated literally, not expanded
  # against the cwd. Restored immediately after.
  set -f
  IFS=','
  # shellcheck disable=SC2086
  set -- $ACQ_FORWARD_HOST_SOCKETS
  IFS="$_oldifs"
  set +f
  for _entry in "$@"; do
    [ -n "$_entry" ] || continue
    # Optional trailing /stream|/dgram selects the socket kind (default stream).
    local _kind="stream" _spec="$_entry"
    case "$_spec" in
      */stream) _kind="stream"; _spec="${_spec%/stream}" ;;
      */dgram) _kind="dgram"; _spec="${_spec%/dgram}" ;;
    esac
    # PATH is everything before the LAST colon; PORT is the trailing field.
    # Unix socket paths rarely contain colons, and splitting on the last colon
    # keeps ":PORT" unambiguous.
    local _port="${_spec##*:}" _path="${_spec%:*}"
    if [ "$_path" = "$_spec" ]; then
      printf 'acq: malformed host-socket forward %s (expected PATH:PORT); skipping\n' "$_entry" >&2
      continue
    fi
    if command -v canonicalize_path >/dev/null 2>&1; then
      _path=$(canonicalize_path "$_path")
    fi
    case "$_path" in
      /*) : ;;
      *) printf 'acq: host-socket path %s is not absolute; skipping\n' "$_path" >&2; continue ;;
    esac
    if _acq_path_has_ctl "$_path"; then
      printf 'acq: host-socket path contains a tab/newline; skipping\n' >&2; continue
    fi
    if [ ! -S "$_path" ]; then
      printf 'acq: host-socket path %s is not an existing socket; skipping\n' "$_path" >&2
      continue
    fi
    if ! _acq_valid_vsock_port "$_port"; then
      printf 'acq: host-socket port %s is invalid (need 1..4294967294, != 123); skipping\n' "$_port" >&2
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$_path" "$_port" "$_kind" "custom"
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

# Extract a user-supplied `--image <ref>` / `--image=<ref>` flag from a run/create
# arg list (ADR-0022). Populates two things IN THE CURRENT SHELL (so callers must
# not run this in a subshell/pipeline):
#   ACQ_IMAGE_FLAG        — the image ref if `--image` was given (else empty)
#   ACQ_IMAGE_REMAINING   — the arg list with the --image flag removed
#
# Like extract_kit_flags, scanning STOPS at the first `--` separator: everything
# after it is agent args and is forwarded verbatim. `--image` is an acq-owned
# neutral flag (ADR-0022); it must NOT reach the backend CLI (neither `sbx create`
# nor `msb create` accepts a bare `--image`). The resolved value is exported as
# ACQ_IMAGE so the backend adapters read it through acq_resolve_neutral_image.
#
# A last-wins policy applies if `--image` is repeated (matches how most CLIs treat
# a repeated scalar flag).
extract_image_flag() {
  ACQ_IMAGE_FLAG=""
  ACQ_IMAGE_REMAINING=()
  local expect_image=0 arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    if [ "$expect_image" -eq 1 ]; then
      ACQ_IMAGE_FLAG="$arg"
      expect_image=0
      shift
      continue
    fi
    case "$arg" in
      --)        ACQ_IMAGE_REMAINING+=("$@"); break ;;
      --image)   expect_image=1 ;;
      --image=*) ACQ_IMAGE_FLAG="${arg#--image=}" ;;
      *)         ACQ_IMAGE_REMAINING+=("$arg") ;;
    esac
    shift
  done
  # A trailing `--image` with no value: warn but don't crash.
  if [ "$expect_image" -eq 1 ]; then
    echo "acq: --image given with no value; ignoring" >&2
  fi
}

# Resolve the effective NEUTRAL base image per ADR-0022 precedence:
#   --image flag  >  ACQ_IMAGE env  >  (empty)
# The `--image` flag value is captured by extract_image_flag into ACQ_IMAGE_FLAG.
# Backend-specific vars (e.g. ACQ_MSB_IMAGE) are NOT consulted here — a backend
# adapter decides whether its own var out-ranks this neutral value (ADR-0022 says
# the most-specific backend var wins, with a one-time notice). Echoes the neutral
# image (or nothing if none was requested).
acq_resolve_neutral_image() {
  if [ -n "${ACQ_IMAGE_FLAG:-}" ]; then
    printf '%s\n' "$ACQ_IMAGE_FLAG"
    return 0
  fi
  if [ -n "${ACQ_IMAGE:-}" ]; then
    printf '%s\n' "$ACQ_IMAGE"
    return 0
  fi
  return 0
}

# _acq_image_registry_host IMAGE — echo the registry host of an OCI image
# reference, or nothing if the reference has no explicit registry (Docker Hub
# short names like `ubuntu` or `library/ubuntu` carry no host). A leading path
# component is a registry only when it looks like a host: it contains a `.` or a
# `:` (port), or is exactly `localhost`. This mirrors the Docker/containers
# reference grammar closely enough to decide whether pull creds are plausibly
# needed. Used to make registry-auth hints precise instead of hardcoding a few
# known hosts.
_acq_image_registry_host() {
  local ref="${1:-}"
  [ -n "$ref" ] || return 0
  local first="${ref%%/*}"
  # No slash at all -> a bare Docker Hub name (e.g. `ubuntu`, `ubuntu:22.04`).
  [ "$first" = "$ref" ] && return 0
  case "$first" in
    localhost|localhost:*) printf '%s\n' "$first" ;;
    *.*|*:*)               printf '%s\n' "$first" ;;   # has a dot or a :port
    *)                     return 0 ;;                 # `library/…` etc. -> Docker Hub
  esac
}

# acq_registry_auth_hint BACKEND IMAGE — print, to stderr, a targeted hint for a
# failed image pull, telling the user how to store registry credentials (or
# import a local image) for the SPECIFIC registry the image came from. Backend
# argument selects the correct command surface (msb vs sbx). Emits nothing for a
# Docker Hub short name (host unknown) beyond the generic path, so callers should
# still print the raw backend error alongside. Registry-agnostic: works for any
# private host, not just a hardcoded few.
acq_registry_auth_hint() {
  local backend="$1" image="${2:-}"
  local host
  host=$(_acq_image_registry_host "$image")
  case "$backend" in
    msb)
      if [ -n "$host" ] && [ "${host%%:*}" != "localhost" ]; then
        echo "acq(msb):   hint: if the pull was denied, store credentials for this registry:" >&2
        echo "acq(msb):           msb registry login ${host} -u <user> --password-stdin" >&2
      fi
      echo "acq(msb):   hint: for a locally-built image (no registry), import it first and skip the pull:" >&2
      echo "acq(msb):           <docker|podman> save ${image:-<image>} -o /tmp/img.tar" >&2
      echo "acq(msb):           msb image load -i /tmp/img.tar -t ${image:-<image>}" >&2
      echo "acq(msb):           ACQ_MSB_PULL=never ./acq --backend msb --image ${image:-<image>} create <agent> <path>" >&2
      ;;
    sbx)
      if [ -n "$host" ] && [ "${host%%:*}" != "localhost" ]; then
        echo "acq(sbx):   hint: if the pull was denied, store credentials for this registry:" >&2
        echo "acq(sbx):           sbx secret set --registry ${host} -u <user>" >&2
      fi
      echo "acq(sbx):   hint: for a locally-built image (no registry), import it first:" >&2
      echo "acq(sbx):           <docker|podman> save ${image:-<image>} -o /tmp/img.tar && sbx template load /tmp/img.tar" >&2
      ;;
  esac
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

# _ensure_local_bin_on_path — if a backend CLI is not on PATH but IS present in
# ~/.local/bin (the default install location for `curl … | sh` installers, e.g.
# microsandbox), prepend ~/.local/bin to PATH for THIS process so acq and the
# backend adapter can find it. This spares a user who installed msb/sbx but never
# added ~/.local/bin to their shell PATH from a confusing "command not found".
# The change is process-local (not persisted); acq prints a one-time hint so the
# user can make it durable. Idempotent (announces at most once per process).
_ACQ_LOCAL_BIN_ANNOUNCED=""
_ensure_local_bin_on_path() {
  local be="$1"
  local lb="${HOME:-}/.local/bin"
  [ -n "${HOME:-}" ] || return 1
  [ -x "$lb/$be" ] || return 1

  # Already on PATH? Then nothing to do (defensive; caller only reaches here
  # after `command -v "$be"` failed, but PATH may contain the dir unreadably).
  case ":$PATH:" in
    *":$lb:"*) return 1 ;;
  esac

  PATH="$lb:$PATH"
  export PATH
  if [ -z "$_ACQ_LOCAL_BIN_ANNOUNCED" ]; then
    _ACQ_LOCAL_BIN_ANNOUNCED=1
    echo "acq: found '$be' in $lb and added it to PATH for this run." >&2
    echo "      To make this permanent, add the following to your shell startup" >&2
    echo "      file (e.g. ~/.zshrc or ~/.bashrc):" >&2
    echo "        export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
  fi
  return 0
}

# _backend_installed BACKEND — 0 if the named backend CLI is available.
# Honors a test-only override, ACQ_TEST_INSTALLED_BACKENDS, a space-separated
# allowlist (e.g. "sbx" or "msb sbx"). Tests set it to pin exactly which
# backends auto-detect "sees" — `command -v` alone can't, because a developer's
# real msb/sbx (and the coreutils the sourced scripts need) share PATH dirs, so
# restricting PATH cannot hide one backend without also breaking the harness.
# When the override is unset (production), falls back to a real `command -v`, and
# if that misses, tries to recover a copy sitting in ~/.local/bin (see
# _ensure_local_bin_on_path) before giving up.
_backend_installed() {
  local be="$1"
  if [ -n "${ACQ_TEST_INSTALLED_BACKENDS+x}" ]; then
    case " $ACQ_TEST_INSTALLED_BACKENDS " in
      *" $be "*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  command -v "$be" >/dev/null 2>&1 && return 0
  # Not on PATH — self-repair if it is installed in ~/.local/bin.
  _ensure_local_bin_on_path "$be" && command -v "$be" >/dev/null 2>&1
}

# _sbx_has_sandboxes — 0 if the sbx CLI reports at least one existing sandbox.
# Used only on the both-installed auto-detect path to keep users on sbx when
# they already have sbx sandboxes. Runs BEFORE any adapter is sourced, so it
# calls `sbx ls -q` directly rather than acq_backend_exists. Fail-open: any
# error (sbx missing, not logged in, transient) is treated as "no sandboxes".
_sbx_has_sandboxes() {
  _backend_installed sbx || return 1
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
  _backend_installed msb && have_msb=1
  _backend_installed sbx && have_sbx=1

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
  # Self-repair PATH for the RESOLVED backend regardless of how it was chosen
  # (explicit --backend, ACQ_BACKEND, saved config, or auto-detect). Auto-detect
  # already probes via _backend_installed, but the explicit/env/config paths set
  # the name directly — so a user who pinned a backend that lives only in
  # ~/.local/bin would otherwise still hit "command not found" in the adapter.
  # Only attempt the recovery when the backend is NOT already resolvable, so a
  # user-writable ~/.local/bin copy never shadows a legit system binary that the
  # agent (and everything acq subsequently execs) would otherwise use.
  command -v "$name" >/dev/null 2>&1 || _ensure_local_bin_on_path "$name" >/dev/null 2>&1 || true
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
        echo "acq: error: no backend detected (looked on PATH and in ~/.local/bin)." >&2
        echo "     Install msb (>= 0.6.0) or sbx (>= 0.35.0), or set ACQ_BACKEND." >&2
        echo "     If it is already installed elsewhere, add its directory to PATH," >&2
        echo "     e.g.:  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
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

# ============================================================================
# CLI / extra kit-reference persistence (restart durability)
# ============================================================================
# A sandbox created with `acq run … --kit <ref>` (ACQ_CLI_KITS) or with
# ACQ_EXTRA_KITS in the environment carries kits whose `startup`-phase commands
# (e.g. a supervised daemon) are re-run on a resume ONLY by acq's heal
# (acq_backend_ensure_kits_applied); the backend's own `start`/resume does NOT
# replay them. But those refs previously lived ONLY in-memory: `extract_kit_flags`
# populates ACQ_CLI_KITS in the run/create dispatch arm, and ACQ_EXTRA_KITS is a
# bare env var. So a later `acq start`/`acq restart` (which does not re-parse
# `--kit` and runs in a shell that may not have ACQ_EXTRA_KITS exported) healed
# with an EMPTY CLI/extra set and never re-ran those kits' startup — the sandbox
# came back with the create-time ports mapped but nothing listening behind them.
#
# To close that gap we persist the CLI/extra kit refs HOST-SIDE at provision
# (alongside the bundle provenance record) and reload them in the start/restart
# verbs before the heal, so kit startup services are restored deterministically
# without the user having to re-pass `--kit` or re-export ACQ_EXTRA_KITS.
#
# Design mirrors the provenance record: host-side only, keyed by backend +
# sandbox name (same sanitized-filename + raw-name-checksum scheme), a tiny
# dependency-free record, atomic temp+mv write, fail-open on any error. One kit
# ref per line under a `kit=` key so a ref may safely contain characters that a
# single-line list could not (refs are newline-free by construction). The
# record's PRESENCE is authoritative: a sandbox created with no CLI/extra kits
# writes an empty record, so reload never resurrects a stale ref, and a legacy
# sandbox with no record simply reloads nothing (the pre-fix behavior).

# Path to one sandbox's CLI/extra kit record. Same keying as the provenance file
# so the two records sit side by side and never collide across backends/names.
_acq_cli_kits_file() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  local safe_backend safe_name name_sum
  safe_backend=$(printf '%s' "$backend" | tr -c 'A-Za-z0-9._-' '_')
  safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
  name_sum=$(printf '%s' "$name" | cksum 2>/dev/null | cut -d' ' -f1 2>/dev/null || echo 0)
  printf '%s/%s/%s.%s.kits\n' "$(_acq_provenance_dir)" "$safe_backend" "$safe_name" "$name_sum"
}

# Persist the current CLI (`--kit`) and extra (ACQ_EXTRA_KITS) kit refs for a
# sandbox. Call ONLY after a successful provision. Writes an empty record when
# there are no such kits, so the record's presence is authoritative on reload.
# Best-effort: a write failure warns (debug) and returns non-zero but never
# aborts the caller (fail-open).
# Usage: acq_cli_kits_write BACKEND SANDBOX_NAME
acq_cli_kits_write() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  local file dir
  file=$(_acq_cli_kits_file "$backend" "$name") || return 1
  dir=$(dirname "$file")
  if ! mkdir -p "$dir" 2>/dev/null; then
    acq_debug "cli-kits: could not create state dir: $dir"
    return 1
  fi
  local tmp="${file}.tmp.$$" ref
  {
    printf 'schema=1\n'
    # Extra (env-supplied) kits, split on whitespace like _build_kit_list.
    if [ -n "${ACQ_EXTRA_KITS:-}" ]; then
      local _extra=()
      split_noglob _extra "$ACQ_EXTRA_KITS"
      for ref in ${_extra[@]+"${_extra[@]}"}; do
        [ -n "$ref" ] && printf 'extra=%s\n' "$ref"
      done
    fi
    # CLI (`--kit`) refs, one per array element (already un-split).
    for ref in ${ACQ_CLI_KITS[@]+"${ACQ_CLI_KITS[@]}"}; do
      [ -n "$ref" ] && printf 'kit=%s\n' "$ref"
    done
  } > "$tmp" 2>/dev/null || { acq_debug "cli-kits: write failed: $tmp"; rm -f "$tmp" 2>/dev/null; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file" 2>/dev/null || { acq_debug "cli-kits: mv failed: $file"; rm -f "$tmp" 2>/dev/null; return 1; }
  acq_debug "cli-kits: recorded $backend/$name (kit=$(printf '%s ' ${ACQ_CLI_KITS[@]+"${ACQ_CLI_KITS[@]}"}))"
  return 0
}

# Reload a sandbox's persisted CLI (`--kit`) and extra kit refs into ACQ_CLI_KITS
# / ACQ_EXTRA_KITS for the CURRENT shell, so a subsequent heal re-runs their
# startup. Called by the start/restart verbs before ensure_kits_applied. No-op
# (leaves the in-memory values untouched) when no record exists — a legacy
# sandbox reloads nothing, exactly the pre-fix behavior. Fail-open.
# Usage: acq_cli_kits_load BACKEND SANDBOX_NAME
acq_cli_kits_load() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 0
  local file
  file=$(_acq_cli_kits_file "$backend" "$name") || return 0
  [ -f "$file" ] || return 0
  # A record exists: it is authoritative for this sandbox. Reset both to reflect
  # exactly what was persisted (an empty record clears them).
  ACQ_CLI_KITS=()
  local _extras="" line val
  while IFS= read -r line; do
    case "$line" in
      kit=*)   ACQ_CLI_KITS+=("${line#kit=}") ;;
      extra=*) val="${line#extra=}"; [ -n "$val" ] && _extras="${_extras:+$_extras }$val" ;;
    esac
  done < "$file"
  # Only overwrite ACQ_EXTRA_KITS from the record if the record carried extras;
  # otherwise leave any env-supplied value in place (do not clobber the env).
  [ -n "$_extras" ] && ACQ_EXTRA_KITS="$_extras"
  acq_debug "cli-kits: reloaded $backend/$name (${#ACQ_CLI_KITS[@]} cli kit(s))"
  return 0
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

# Ensure opencode's postinstall has run inside the sandbox.
#
# Since opencode v1.15.1 the `opencode-ai` npm package fetches its actual binary
# in a postinstall step. Some sandbox images (notably the prebuilt sbx
# opencode-docker template) install the package with lifecycle scripts skipped,
# so the first launch fails with:
#   Error: opencode-ai's postinstall script was not run.
# This is backend-agnostic (the msb npm install can hit the same gap), so run
# the fix on any backend before attaching an opencode agent.
#
# Idempotent and cheap: if opencode already runs (`opencode --version`), do
# nothing. Otherwise locate the installed package via `npm root -g` and run its
# postinstall.mjs. Best-effort — never aborts the run; a genuinely broken
# install still surfaces its own error on attach. Runs as the sandbox's default
# exec user (acq_backend_run), matching how the agent itself is launched.
ensure_opencode_postinstall() {
  local name="$1"

  # Already functional? Nothing to do.
  if acq_backend_run "$name" -- opencode --version >/dev/null 2>&1; then
    return 0
  fi

  acq_debug "opencode not runnable in '$name'; attempting postinstall"
  # Run the package's own postinstall from its global install dir. `npm root -g`
  # resolves the global node_modules; the package dir is opencode-ai within it.
  # Both the cd and node invocation happen in one sh -c so the resolved path is
  # used atomically. Output is suppressed; we re-probe below to decide success.
  #
  # BOUND THE WAIT: postinstall.mjs fetches a platform binary over the network, so
  # a wedged/slow registry could otherwise hang `acq run` before attach. Wrap it
  # in a guest-side `timeout` when available (fall back to an unbounded run if the
  # guest has no `timeout`, e.g. a minimal base). ACQ_OPENCODE_POSTINSTALL_TIMEOUT
  # tunes the bound (default 120s). This is belt-and-suspenders: the create-time
  # egress allow-list already limits where the fetch can go.
  local _pi_timeout="${ACQ_OPENCODE_POSTINSTALL_TIMEOUT:-120}"
  acq_backend_run "$name" -- sh -c \
    'cd "$(npm root -g)/opencode-ai" 2>/dev/null || exit 0
     if command -v timeout >/dev/null 2>&1; then
       timeout '"$_pi_timeout"' node postinstall.mjs
     else
       node postinstall.mjs
     fi' \
    >/dev/null 2>&1 || true

  if acq_backend_run "$name" -- opencode --version >/dev/null 2>&1; then
    acq_debug "opencode postinstall succeeded in '$name'"
    return 0
  fi

  # Still not runnable — warn but don't block; attach will surface the real
  # error, and the user has the manual recovery in docs/KNOWN_FAILURE_MODES.md.
  echo "acq: warning: opencode does not appear runnable in '$name' yet." >&2
  echo "      Tried its postinstall automatically; if attach still fails with" >&2
  echo "      \"postinstall script was not run\", see docs/KNOWN_FAILURE_MODES.md." >&2
  return 0
}

# Probe the USAi API from inside the sandbox. Emits ONE clean token on stdout:
#   - a 3-digit HTTP status (e.g. 200, 401) on a real HTTP response,
#   - "unresolved" when the guest resolver returned no answer for the name
#     (curl exit 6 / NXDOMAIN) — the split-horizon-DNS tell,
#   - the literal "unreachable" when curl could not complete a request at all
#     (TLS reset, DNS failure, proxy/Zscaler interception, offline — curl exits
#     non-zero and writes http_code 000), or
#   - "" (empty) only when the probe is genuinely indeterminate.
# The caller distinguishes these: "unreachable" is a NETWORK problem, NOT a bad
# key, so it must never be reported as "invalid or expired" or trigger a rotate.
#
# Sanitize hard: curl's stderr can leak through the backend exec (which may merge
# streams), so we emit the raw curl output as `<http_code>|<exit>` and reduce it
# to a bare code here. Only ^[0-9]{3}$ or "unreachable" or "" can ever escape —
# no free-form error text can splice into the caller's "(HTTP …)" message.
check_key() {
  local name="$1"
  local raw code exit_code
  raw=$(acq_backend_run "$name" -- sh -c \
    "curl -sS -o /dev/null -w '%{http_code}' \
     -H \"Authorization: Bearer \$USAI_API_KEY\" \
     $USAI_MODELS_URL; printf '|%s' \"\$?\"" 2>/dev/null || true)
  _classify_key_status "$raw"
}

# Reduce a raw `<http_code>|<curl_exit>` probe result (possibly polluted with
# curl error text) to a clean status token: a 3-digit HTTP code, "unresolved"
# (DNS did not resolve the name — curl exit 6), "unreachable" (resolved but the
# connection never completed — TLS reset / connect refused / HTTP 000), or "".
# Shared by check_key and check_fresh_sandbox_key.
#
# WHY "unresolved" is split out from "unreachable": a curl exit 6 means the guest
# resolver returned NXDOMAIN for the name. For a split-horizon host like
# api.gsa.usai.gov (whose real address lives in an internal, tunnel-only zone the
# guest's public resolver can't see), that is the diagnostic tell — a distinct
# remedy (a resolver that can reach the internal zone) from a broad TLS/egress
# cut. Keeping them separate lets the caller give the right advice instead of a
# generic "network problem". See docs/KNOWN_FAILURE_MODES.md §30.
_classify_key_status() {
  local raw="$1" code exit_code
  # The curl exit code is the last field after the final '|'. Keep only digits.
  exit_code="${raw##*|}"
  exit_code=$(printf '%s' "$exit_code" | tr -cd '0-9')
  # The http_code is the last 3-digit run before that '|' (curl's %{http_code}).
  code="${raw%%|*}"
  code=$(printf '%s' "$code" | tr -cd '0-9')
  # Keep only the trailing 3 digits (guards against any leading leaked digits).
  code="${code: -3}"

  # curl succeeded (exit 0) AND returned a plausible non-000 HTTP code.
  if [ "$exit_code" = "0" ] && [ -n "$code" ] && [ "$code" != "000" ]; then
    printf '%s\n' "$code"
    return 0
  fi
  # curl exit 6 = "couldn't resolve host": DNS returned no answer for the name.
  # This is the split-horizon-DNS signature (the public guest resolver can't see
  # an internal-only zone), NOT a broad connection cut — report it distinctly.
  if [ "$exit_code" = "6" ]; then
    printf 'unresolved\n'
    return 0
  fi
  # curl failed to get any response (nonzero exit, or http_code 000): the request
  # never reached USAi — treat as a network reachability problem, not a key one.
  if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
    printf 'unreachable\n'
    return 0
  fi
  if [ "$code" = "000" ]; then
    printf 'unreachable\n'
    return 0
  fi
  # Indeterminate (no exit code captured, no usable http_code): stay silent.
  printf '\n'
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
  local raw
  raw=$(acq_backend_run "$validation_name" -- sh -c \
    "curl -sS -o /dev/null -w '%{http_code}' \
     -H \"Authorization: Bearer \$USAI_API_KEY\" \
     $USAI_MODELS_URL; printf '|%s' \"\$?\"" </dev/null 2>/dev/null || true)
  status=$(_classify_key_status "$raw")
  acq_backend_terminate "$validation_name" </dev/null >/dev/null 2>&1 || true
  trap - EXIT
  printf '%s\n' "$status"
}

# Warn (do not block) if a sandbox has published ports with nothing listening
# behind them inside the guest. This is a backend-NEUTRAL diagnostic: it uses
# only `acq_backend_ports` (to learn the guest ports the sandbox publishes) and
# `acq_backend_run` (to probe inside the guest), both of which every adapter
# implements — so it adds no backend-specific health logic to acq.
#
# WHY: a kit that publishes ports and supervises services in its `startup` phase
# (e.g. openchamber's shared `opencode serve` + web UI) can end up with the port
# MAPPED but the service DEAD — most visibly after a resume where the heal failed
# to re-run the kit's startup (see docs/KNOWN_FAILURE_MODES.md #33). The port map
# then looks healthy while `opencode attach` / the browser fail with "Unable to
# connect". Surfacing "port published but nothing listening" at attach time turns
# that silent, confusing failure into an actionable note.
#
# Never blocks, never prompts, always returns 0. Best-effort throughout: any
# probe that cannot run (no ports published, no `ss`/`curl`/`nc` in the guest,
# an exec miss) is treated as "cannot tell" and stays silent rather than emitting
# a false warning — we only warn when a listen-probe DEFINITIVELY finds the guest
# port closed. Bounded: probes a small, capped number of ports with short guest-
# side timeouts so it can never stall the attach.
warn_if_published_ports_dead() {
  local name="${1:-}"
  [ -n "$name" ] || return 0
  command -v acq_backend_ports >/dev/null 2>&1 || return 0
  command -v acq_backend_run   >/dev/null 2>&1 || return 0

  # Collect the GUEST port numbers this sandbox publishes. acq_backend_ports
  # prints human lines like "sandbox 4096 -> host 127.0.0.1:5xxxx (…)"; the guest
  # port is the first integer token after "sandbox". Parse defensively — an
  # unexpected format simply yields no ports (silent).
  local ports_out guest_ports="" line g
  ports_out=$(acq_backend_ports "$name" 2>/dev/null) || return 0
  [ -n "$ports_out" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      sandbox\ *)
        # Second whitespace-delimited field is the guest port.
        g=$(printf '%s\n' "$line" | awk '{print $2}')
        case "$g" in
          ''|*[!0-9]*) continue ;;
        esac
        # Dedupe.
        case " $guest_ports " in *" $g "*) continue ;; esac
        guest_ports="$guest_ports $g"
        ;;
    esac
  done <<EOF
$ports_out
EOF
  [ -n "$guest_ports" ] || return 0

  # Probe each guest port from INSIDE the sandbox. Prefer `ss`, then a bounded
  # `curl`, then `nc` — whichever the guest has. Emit exactly one of:
  #   listening   — something is bound to the port (healthy)
  #   closed      — the probe ran and the port is definitively not listening
  #   unknown     — no probe tool available / indeterminate (stay silent)
  # The whole probe is one `sh -c` so it runs in a single guest exec per port.
  local dead="" checked=0 p verdict
  for p in $guest_ports; do
    # Cap the number of ports probed so a pathological kit can't stall attach.
    checked=$((checked + 1))
    [ "$checked" -gt 8 ] && break
    verdict=$(acq_backend_run "$name" -- sh -c '
      port="$1"
      if command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | grep -Eq "[:.]$port[[:space:]]"; then
          echo listening; exit 0
        fi
        echo closed; exit 0
      fi
      if command -v curl >/dev/null 2>&1; then
        # A refused connection => closed; any HTTP response (even an error
        # status) => something is listening. --max-time bounds the probe.
        # Capture the curl exit status directly (NOT via a preceding if-test,
        # which would overwrite the status with the if-test result): exit 7 ==
        # connection refused (nothing listening); any other outcome (0, or an
        # HTTP-level failure like 22/52) still proves a listener answered.
        curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null
        _rc=$?
        [ "$_rc" -eq 7 ] && { echo closed; exit 0; }
        echo listening; exit 0
      fi
      if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 127.0.0.1 "$port" 2>/dev/null; then echo listening; else echo closed; fi
        exit 0
      fi
      echo unknown
    ' sh "$p" 2>/dev/null | tr -d '[:space:]')
    case "$verdict" in
      closed) dead="$dead $p" ;;
    esac
  done

  [ -n "$dead" ] || return 0
  echo "acq: note — published port(s) with nothing listening inside '$name':${dead}." >&2
  echo "      The port(s) are mapped to your host, but no service is answering them" >&2
  echo "      in the sandbox yet. If a kit is supposed to run a server there, its" >&2
  echo "      startup may still be coming up — or, after a resume/reboot, may not" >&2
  echo "      have been re-run. Re-run with the SAME '--kit …' you created it with" >&2
  echo "      to re-apply kit startup, or check the kit's server log." >&2
  echo "      See docs/KNOWN_FAILURE_MODES.md #33." >&2
  return 0
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
  echo "      When you have a token, paste it at the prompt (shown as *)." >&2
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

  if [ "$status" = "unreachable" ]; then
    _report_usai_unreachable
    return 0
  fi

  if [ "$status" = "unresolved" ]; then
    _report_usai_unresolved
    return 0
  fi

  echo "acq: note — your USAi API key looks invalid or expired (HTTP $status)." >&2
  echo "      USAi keys expire every 7 days. This sandbox was created, but the" >&2
  echo "      key must be valid before an agent can use it." >&2
  echo "      To rotate: acq usai-rotate-api-key   (or re-run via 'acq run', which" >&2
  echo "      validates and offers to rotate before attaching)." >&2
  return 0
}

# Print a network-oriented diagnosis when the USAi models API could not be
# reached from the sandbox at all (curl connection failure / HTTP 000). This is
# a reachability problem — NOT an invalid or expired key — so it deliberately
# does not mention rotating the key. The point is an accurate diagnosis, not a
# prescription: it states what failed and the signal to look for, and points at
# the docs rather than guessing the user's network fix.
_report_usai_unreachable() {
  echo >&2
  echo "acq: could not reach the USAi API ($USAI_MODELS_URL) from the sandbox." >&2
  echo "      The request did not complete (no HTTP response) — this is a network" >&2
  echo "      reachability problem, NOT an invalid or expired key, so rotating the" >&2
  echo "      key will not help." >&2
  echo "      If the playbook/kit fetch also failed with a TLS 'unexpected eof'," >&2
  echo "      both outbound connections are being cut — a strong sign of a network" >&2
  echo "      or TLS-interception (e.g. corporate proxy) issue rather than USAi." >&2
  echo "      See docs/KNOWN_FAILURE_MODES.md for diagnosis steps." >&2
  echo >&2
}

# Print a DNS-oriented diagnosis when the USAi models API name did not RESOLVE
# from the sandbox (curl exit 6 / NXDOMAIN). This is distinct from the broad
# "unreachable" cut: the tell is that the name has no answer for the guest
# resolver, while other public hosts (GitHub, npm) resolve and connect fine.
#
# The usual cause on GFE is split-horizon DNS — the USAi host resolves to an
# INTERNAL address that only exists in the corporate/tunnel zone, which the
# guest's default public resolver (ACQ_MSB_DNS_NAMESERVER, 1.1.1.1) cannot see.
# A key rotation cannot fix this, and neither can a msb data wipe; the remedy is
# a resolver that can reach the internal USAi zone. State the signal and point
# at the docs rather than guessing the user's network fix.
_report_usai_unresolved() {
  echo >&2
  echo "acq: the USAi API host in $USAI_MODELS_URL did not RESOLVE from the sandbox" >&2
  echo "      (DNS returned no address). This is a name-resolution problem, NOT an" >&2
  echo "      invalid or expired key, so rotating the key will not help." >&2
  echo "      If other public hosts (GitHub, npm) work from the sandbox but only" >&2
  echo "      USAi fails to resolve, USAi is likely a split-horizon name whose" >&2
  echo "      address lives in an internal/tunnel-only zone the guest's default" >&2
  echo "      resolver cannot see. Point the guest at a resolver that can reach the" >&2
  echo "      internal USAi zone via ACQ_MSB_DNS_NAMESERVER." >&2
  echo "      See docs/KNOWN_FAILURE_MODES.md §30 (USAi-only NXDOMAIN)." >&2
  echo >&2
}

# acq_key_injectable SERVICE [SANDBOX] -> 0 if the ACTIVE BACKEND can inject
# SERVICE for that scope, else 1. Single source of truth for the "is this
# credential actually usable at provision?" predicate, composed of two checks:
#   1. acq_secret_has SERVICE SANDBOX     — a value resolves in the acq store, and
#   2. acq_backend_key_present SERVICE SANDBOX (when the backend defines it) — the
#      BACKEND (not just the acq store) can inject it. sbx defines this (checks its
#      proxy table); msb does NOT (it binds from the acq store at create, so
#      store-present == injectable), in which case check 1 alone is authoritative.
# Silent (a predicate). Both `ensure_key_present` (the pre-create gate) and the
# `acq secret has` subcommand call this so they can never drift.
acq_key_injectable() {
  local service="$1" scope_sandbox="${2:-}"
  command -v acq_secret_has >/dev/null 2>&1 || return 1
  acq_secret_has "$service" "$scope_sandbox" || return 1
  if command -v acq_backend_key_present >/dev/null 2>&1; then
    acq_backend_key_present "$service" "$scope_sandbox" || return 1
  fi
  return 0
}

# ensure_key_present — pre-create gate: make sure a USAi API key is available to
# the active backend BEFORE the sandbox is created. This must run before
# acq_backend_provision on a fresh run because msb binds secrets only at create
# time (--secret ENV@HOST), and sbx snapshots custom secret placeholders from its
# proxy table at create time. A sandbox created without the backend-visible key
# binding carries no working USAi credential.
#
# Returns 0 if a key is present (already, or after the user pastes one), 1 if the
# user declines or setup fails. A no-op (returns 0) when the store helper isn't
# loaded — the post-create ensure_valid_key gate still catches a bad key.
ensure_key_present() {
  local scope_sandbox="${1:-}"
  if ! command -v acq_secret_has >/dev/null 2>&1; then
    return 0
  fi
  if acq_secret_has usai "$scope_sandbox"; then
    # acq_key_injectable composes the store check (already true here) with the
    # backend-inject check; it is the shared predicate `acq secret has` also uses.
    acq_key_injectable usai "$scope_sandbox" && return 0

    echo "acq: USAi API key is stored, but the active backend is not configured to inject it." >&2
    echo "     Run 'acq secret set -g usai' from a terminal so the backend can bind it, then retry." >&2
    return 1
  fi

  # Backend mismatch: msb provision also accepts a host-exported USAI_API_KEY and
  # binds it at create time (see _acq_msb_bind_secrets_into in msb.sh), so an empty
  # acq store is NOT a blocker under msb when the env var is set (e.g. CI). Treat
  # that as present to avoid prompting/aborting a create msb would have satisfied.
  # sbx does NOT read host env at provision, so this short-circuit is msb-only.
  if [ "${ACQ_RESOLVED_BACKEND:-}" = "msb" ] && [ -n "${USAI_API_KEY:-}" ]; then
    return 0
  fi

  # Non-interactive (CI / piped stdin): no one can answer the prompt below, so
  # emit a single terse line and fail closed rather than the full interactive
  # help (mirrors the non-tty guard in the kit-update path above).
  if [ ! -t 0 ]; then
    echo "acq: no USAi API key stored; set one with 'acq secret set -g usai' (see $KEY_MGMT_URL). Aborting." >&2
    return 1
  fi

  echo >&2
  echo "No USAi API key is stored yet." >&2
  echo "USAi keys are created at $KEY_MGMT_URL and expire every 7 days." >&2
  echo >&2
  echo "To set one:" >&2
  echo "  1. Open $KEY_MGMT_URL" >&2
  echo "  2. Create a key (or copy an existing one) with the console copy button" >&2
  echo >&2

  if ! command -v acq_backend_secret_set >/dev/null 2>&1; then
    echo "The '${ACQ_RESOLVED_BACKEND:-active}' backend does not implement key setup." >&2
    echo "Set the key manually (acq secret set -g usai), then re-run." >&2
    return 1
  fi

  local answer=""
  printf 'Have your USAi API key ready to paste? Set it now? [y/N] ' >&2
  read -r answer || true
  case "$answer" in
    [yY]|[yY][eE][sS])
      # Store the key in the acq store (read from the TTY; never argv). This does
      # NOT create a sandbox — the value just needs to be present before create.
      acq_backend_secret_set -g usai || {
        echo "Key setup did not complete. Aborting." >&2
        return 1
      }
      if acq_secret_has usai; then
        return 0
      fi
      echo "No USAi API key was stored. Aborting." >&2
      return 1
      ;;
    *)
      echo "Skipping. Aborting; re-run when your USAi API key is set." >&2
      return 1
      ;;
  esac
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

  # The request never reached USAi (TLS reset / DNS / proxy interception /
  # offline) — a NETWORK problem, not a key problem. Rotating a key cannot fix
  # this, so DO NOT prompt to rotate. Fail closed (attaching would just fail on
  # the first USAi call) with a network-oriented diagnosis.
  if [ "$status" = "unreachable" ]; then
    _report_usai_unreachable
    return 1
  fi

  # DNS returned no address for the USAi host (curl exit 6). Distinct from a
  # broad cut: the split-horizon-DNS case, where only USAi fails to resolve. A
  # rotation cannot fix it, so fail closed with a resolver-oriented diagnosis.
  if [ "$status" = "unresolved" ]; then
    _report_usai_unresolved
    return 1
  fi

  # A key IS stored (ensure_key_present gated create on that) but the models API
  # rejected it: it is expired or invalid. Offer an in-place rotation, then
  # re-validate THIS sandbox — the same one the agent will attach to, so a 200
  # here is truthful (no throwaway-sandbox result stands in for the real one).
  echo >&2
  echo "Your USAi API key looks invalid or expired (HTTP $status from the models API)." >&2
  echo "USAi keys expire every 7 days." >&2
  echo >&2
  echo "To rotate it:" >&2
  echo "  1. Open $KEY_MGMT_URL" >&2
  echo "  2. Choose 'Rotate' from the Actions menu for your key" >&2
  echo "  3. Copy the new key using the console copy button" >&2
  echo >&2

  if ! command -v acq_backend_rotate_key >/dev/null 2>&1; then
    echo "The '${ACQ_RESOLVED_BACKEND:-active}' backend does not implement key setup." >&2
    echo "Set the key manually, then re-run." >&2
    return 1
  fi

  local answer=""
  printf 'Have the new API key ready to paste? Rotate now? [y/N] ' >&2
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
      echo "Skipping. Aborting attach; re-run when your USAi API key is set." >&2
      return 1
      ;;
  esac
}

# ============================================================================
# acq doctor output helpers
# ============================================================================

acq_print_doctor() {
  local sbx_status msb_status

  # Recover a backend installed in ~/.local/bin but not on PATH, so doctor's
  # verdict matches what `acq run` will actually find (self-repair parity).
  _ensure_local_bin_on_path sbx >/dev/null 2>&1 || true
  _ensure_local_bin_on_path msb >/dev/null 2>&1 || true

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
