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
# agentic-coding-patterns v1.17.0 release SHA. It supplies the versioned
# provider-input schemas and validator consumed below.
PATTERNS_KIT_REF="a1206c52ec82ae7ce080ad44a6e6ac6f951e6d20"
PATTERNS_KIT_DIR="integrations/isolation/acq-kits"

USAI_PROVIDER_KIT_NAME="usai-provider"
# shellcheck disable=SC2034  # consumed by _acq_builtin_kit_ref after sourcing
USAI_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/${USAI_PROVIDER_KIT_NAME}"
# shellcheck disable=SC2034  # consumed by _acq_builtin_kit_ref after sourcing
PLAYBOOK_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/agentic-coding-playbook"
# shellcheck disable=SC2034  # consumed by _acq_builtin_kit_ref after sourcing
ZSCALER_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/zscaler-ca-certificate"
# shellcheck disable=SC2034  # consumed by _acq_builtin_kit_ref after sourcing
GITSSHSIGN_KIT="${PATTERNS_KIT_REPO}#ref=${PATTERNS_KIT_REF}&dir=${PATTERNS_KIT_DIR}/git-ssh-sign"

# Neutral kit directory names (relative to PATTERNS_KIT_DIR), in apply order.
# kit-translate.sh resolves a kit's spec.yaml + files/ from these names.
#
# ORDER MATTERS: zscaler-ca-certificate is applied FIRST so its CA trust is in
# place before any later kit makes an outbound HTTPS request. Behind a
# TLS-intercepting proxy (e.g. Zscaler), a kit that fetches over the network
# (the playbook kit clones from api.github.com; the USAi provider validates
# against api.gsa.usai.gov) fails with a TLS 'unexpected eof' unless the
# intercepting CA is already trusted. Establishing trust first makes the rest
# of the bundle succeed on corporate networks.
# shellcheck disable=SC2034  # consumed by `acq kit list` in the acq entry point
ACQ_KIT_NAMES=(zscaler-ca-certificate "$USAI_PROVIDER_KIT_NAME" agentic-coding-playbook git-ssh-sign)

# One-line descriptions for the built-in kits, parallel to ACQ_KIT_NAMES, shown
# as the frozen ("always applied") rows in the `acq configure` picker (ADR-0031).
# shellcheck disable=SC2034  # consumed by acq_configure / create_time_kit_picker
ACQ_KIT_DESCS=(
  "Zscaler/corporate CA trust so TLS-intercepting proxies don't break fetches"
  "USAi provider + model config for OpenCode (endpoints, key wiring)"
  "Federal agent rules and skills from the agentic-coding playbook"
  "SSH-based git commit signing for the agent's commits"
)

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

# Provider kits are selected independently from support and extra kits. Unset
# preserves the historical default; an explicitly set empty value is authoritative.
# `--no-provider-kits` supplies a shell-independent spelling of that empty set.
if [ -z "${_ACQ_PROVIDER_KITS_INITIALIZED:-}" ]; then
  if [ "${ACQ_PROVIDER_KITS+x}" = x ]; then
    ACQ_PROVIDER_KITS_FROM_ENV=1
  else
    ACQ_PROVIDER_KITS_FROM_ENV=""
  fi
  ACQ_PROVIDER_KITS="${ACQ_PROVIDER_KITS:-}"
  _ACQ_PROVIDER_KITS_INITIALIZED=1
fi
ACQ_PROVIDER_KITS_FROM_CLI=""

# Record whether ACQ_EXTRA_KITS came from the ENVIRONMENT (vs. being empty or set
# later by acq itself). The configured-default and create-time picker paths honor
# env > config > interactive: a user who exported ACQ_EXTRA_KITS gets it verbatim
# and is never re-prompted or overridden (ADR-0031). Captured once at load time.
if [ -n "${ACQ_EXTRA_KITS:-}" ]; then
  ACQ_EXTRA_KITS_FROM_ENV=1
else
  ACQ_EXTRA_KITS_FROM_ENV=""
fi

# ---------------------------------------------------------------------------
# Opt-in kit catalog (for `acq configure`; ADR-0031)
# ---------------------------------------------------------------------------
# The OPT-IN community kits acq can offer in the interactive picker, sourced from
# the SAME pinned patterns bundle as the built-ins (PATTERNS_KIT_REF /
# PATTERNS_KIT_DIR) so their refs stay pinned in lockstep. The four built-in kits
# above are always applied and are NOT listed here (the picker shows them as
# locked/pre-checked, informational only).
#
# Parallel arrays (bash 3.2 safe — no associative arrays): NAME[i] is the kit
# directory under PATTERNS_KIT_DIR; DESC[i] is the one-line picker description.
# `prime-agent` is intentionally omitted: it is a skeleton at the current pin
# (see the patterns kits.yaml parity note) and would be non-functional if
# offered. Add it here once it is functional. Heavier kits such as `oci-engine`
# still belong here when they are functional; the picker description must make
# their create-time cost clear.
# shellcheck disable=SC2034  # consumed by `acq configure` (cross-function reader)
ACQ_OPTIN_KIT_NAMES=(openchamber paseo oci-engine)
# shellcheck disable=SC2034
ACQ_OPTIN_KIT_DESCS=(
  "Browser UI for OpenCode alongside the terminal TUI (publishes ports 3000/4096)"
  "Self-hosted Paseo browser web UI for coding agents (one port, loopback only)"
  "Rootless podman for docker run / docker compose inside the sandbox (installs packages)"
)

# _acq_optin_kit_ref NAME — echo the fully-pinned git+https kit ref for an opt-in
# kit NAME, built exactly like the built-in *_KIT refs (same repo/ref/dir), so a
# picked kit is pinned to the same patterns bundle as everything else.
_acq_optin_kit_ref() {
  printf '%s#ref=%s&dir=%s/%s\n' \
    "$PATTERNS_KIT_REPO" "$PATTERNS_KIT_REF" "$PATTERNS_KIT_DIR" "${1:?kit name required}"
}

# _acq_apply_configured_extra_kits — fold the configured-default extra kits
# (config.yaml `extra_kits:`, written by `acq configure`) into ACQ_EXTRA_KITS for
# this invocation, so a durable default behaves like an env-supplied extra. An
# env-supplied ACQ_EXTRA_KITS is authoritative and is NOT overridden (env > config,
# matching the backend-resolution precedence and the `--kit`/env layering). No-op
# when nothing is configured. Idempotent (guarded so a second call is cheap).
_ACQ_CONFIGURED_KITS_APPLIED=""
_acq_apply_configured_extra_kits() {
  [ -z "$_ACQ_CONFIGURED_KITS_APPLIED" ] || return 0
  # Env wins: if the user exported ACQ_EXTRA_KITS, respect it verbatim.
  if [ -n "${ACQ_EXTRA_KITS_FROM_ENV:-}" ]; then
    _ACQ_CONFIGURED_KITS_APPLIED=1
    return 0
  fi
  local configured names ref
  configured=$(_acq_config_read_field extra_kits)
  if [ -z "$configured" ]; then
    _ACQ_CONFIGURED_KITS_APPLIED=1
    return 0
  fi
  # The stored value is a list of opt-in kit NAMES. Raw refs are intentionally
  # not accepted from durable config; use ACQ_EXTRA_KITS or --kit for those.
  names="$configured"
  local out="" tok known k
  for tok in $names; do
    known=""
    for k in ${ACQ_OPTIN_KIT_NAMES[@]+"${ACQ_OPTIN_KIT_NAMES[@]}"}; do
      [ "$k" = "$tok" ] && { known=1; break; }
    done
    if [ -z "$known" ]; then
      echo "acq: config extra_kits contains unknown kit '${tok}'" >&2
      echo "     Run 'acq configure' to choose catalog kits, or use ACQ_EXTRA_KITS/--kit for custom refs." >&2
      return 1
    fi
    ref=$(_acq_optin_kit_ref "$tok")
    out="${out:+$out }$ref"
  done
  if [ -z "$out" ]; then
    _ACQ_CONFIGURED_KITS_APPLIED=1
    return 0
  fi
  ACQ_EXTRA_KITS="$out"
  _ACQ_CONFIGURED_KITS_APPLIED=1
  acq_debug "config: applied configured extra_kits: $out"
  return 0
}

# Update-check opt-out. When ACQ_UPDATE_CHECK=0, `acq run` never
# runs the stale-sandbox check (no provenance comparison, no prompt). The
# explicit `acq kit check` / `acq kit update` commands still work — the opt-out
# only silences the automatic per-run check. `acq run --no-update-check` sets
# this for a single invocation (parsed in the acq entry point).
ACQ_UPDATE_CHECK="${ACQ_UPDATE_CHECK:-1}"

# Human-owned activation contract: acq can detect direnv/devenv workspaces and
# print guidance, but does not evaluate project-provided activation files unless
# the user explicitly opts in for the current invocation/session.
ACQ_ACTIVATE_PROJECT_ENV="${ACQ_ACTIVATE_PROJECT_ENV:-0}"
# In-process marker set only by acq dispatch before user-facing exec/shell/attach.
# Ignore inherited environment values so internal helper probes cannot be wrapped
# by setting ACQ_SESSION_KIND outside acq.
ACQ_SESSION_KIND=""

# Kits supplied on the command line via `--kit <ref>` (repeatable) on
# run/create. These are extracted from the arg list by extract_kit_flags (below)
# BEFORE the args reach the backend, so a neutral kit ref is translated by acq
# rather than passed raw to the backend CLI (which would fail to parse the
# neutral schema). Folded into the kit list by _build_kit_list, alongside
# ACQ_EXTRA_KITS. One ref per element.
ACQ_CLI_KITS=()
ACQ_BUILTIN_KIT_COUNT=0
ACQ_BUILTIN_SUPPORT_KIT_COUNT=0
ACQ_AGENT_KIT_READY_CACHE=""

# Host-port overrides supplied on the command line via `--publish HOST:GUEST`
# (repeatable) on run/create, one `HOST:GUEST` pair per element (ADR-0034).
# Extracted by extract_publish_flags BEFORE the args reach the backend: `msb
# create` has its own `-p` that the adapter synthesizes from kit records, and sbx
# has no host-port knob at all, so the raw flag must never reach either CLI. The
# msb adapter folds these into its published-port records at provision time,
# where they override a kit's mapping for the same guest port.
ACQ_PUBLISH_FLAGS=()

# Fetch allowlist, derived from the trusted kit-source registry (see
# acq_kit_source_prefixes). Populated by _build_kit_list.
# shellcheck disable=SC2034  # consumed by the sbx allowlist sync
KIT_SOURCE_PREFIXES=()

# Latched provider-selection error. acq_resolve_backend builds the kit list for
# EVERY verb, so a bad `provider_kit:`/`kit_sources:` must not lock the user out of
# the verbs that repair it (configure, kit-source, backend, doctor, help). The
# failure is recorded here and turned into a hard stop by
# _acq_require_provider_selection, which only create/run call.
# shellcheck disable=SC2034  # read by _acq_require_provider_selection
ACQ_PROVIDER_SELECTION_ERROR="" 

# Transitional fallback defaults for the pinned usai-provider kit. ADR-0030's
# target state is for the kit to export these provider facts as static metadata
# consumable before sandbox creation. acq keeps these defaults only for backend
# credential binding, key validation, and offline tests until that artifact exists.
# These values are not authoritative once the artifact is available.
USAI_PROVIDER_HOST="api.gsa.usai.gov"
USAI_PROVIDER_BASE_URL="https://${USAI_PROVIDER_HOST}/api/v1"
USAI_PROVIDER_KEY_ENV="USAI_API_KEY"
# shellcheck disable=SC2034  # consumed by the sbx adapter (sbx.sh)
USAI_PROVIDER_MODELS_URL="${USAI_PROVIDER_BASE_URL}/models"
# shellcheck disable=SC2034  # consumed by the sbx and msb adapters
USAI_PROVIDER_BIND_HOSTS="${USAI_PROVIDER_HOST}"

# Source the shared agent catalog (single source of truth for agent tokens and
# the sandbox-template image naming convention; issue #377). Both adapters also
# source it defensively so they work when loaded without common.sh (some tests
# source an adapter directly). Guard so a re-source is cheap.
if ! command -v acq_is_known_agent >/dev/null 2>&1; then
  if [ -n "${ACQ_SCRIPT_DIR:-}" ] && [ -f "${ACQ_SCRIPT_DIR}/acq.backends/agents.sh" ]; then
    # shellcheck disable=SC1091
    . "${ACQ_SCRIPT_DIR}/acq.backends/agents.sh"
  else
    # shellcheck source=acq.backends/agents.sh
    . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/agents.sh"
  fi
fi

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

# Source the TTY-aware interactive prompt widgets (acq_prompt_multiselect /
# acq_prompt_confirm) used by `acq configure` and the create-time picker (see
# ADR-0031). Like progress.sh, all chrome is stderr-only and gated on an
# interactive TTY; non-interactive callers take documented defaults and never
# block. If the file is missing (older partial checkout), define no-op fallbacks
# so `acq configure` degrades to "take defaults" rather than breaking.
if [ -n "${ACQ_SCRIPT_DIR:-}" ] && [ -f "${ACQ_SCRIPT_DIR}/acq.backends/prompt.sh" ]; then
  # shellcheck disable=SC1091
  . "${ACQ_SCRIPT_DIR}/acq.backends/prompt.sh"
fi
if ! command -v acq_prompt_confirm >/dev/null 2>&1; then
  # Fallback: echo nothing selected / honor the passed default (arg 2 = yes|no).
  acq_prompt_multiselect() { printf '\n'; }
  acq_prompt_confirm()     { [ "${2:-no}" = "yes" ] && return 0 || return 1; }
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
# PROVIDERS are no longer listed here: they are registry-driven (see the
# provider credential bindings section), so `usai` is a provider like any other
# and only non-provider HOST services remain compiled in.
ACQ_MANAGED_SECRET_SERVICES=" github gitlab "

# _acq_import_env_vars_for SERVICE — echo the host environment variable name(s)
# that `acq secret import` reads to populate SERVICE, most-preferred first (space
# separated). These mirror the env vars each backend already honors when binding
# the service (see the sbx/msb adapters and the kits' env expectations):
#   usai   <- USAI_API_KEY
#   github <- GITHUB_TOKEN, then GH_TOKEN (gh CLI's variable)
#   gitlab <- GITLAB_TOKEN
# Only acq-managed services are importable; an unknown service echoes nothing.
_acq_import_env_vars_for() {
  local provider_key_env=""
  case "$1" in
    usai)   printf '%s\n' "$USAI_PROVIDER_KEY_ENV" ;;
    github) printf 'GITHUB_TOKEN GH_TOKEN\n' ;;
    gitlab) printf 'GITLAB_TOKEN\n' ;;
    *)
      # A provider kit declared in acq's credential-bindings registry is
      # importable from the ENV var that registry names, so a non-USAi provider
      # needs no per-provider entry here.
      if command -v acq_provider_credential_key_env >/dev/null 2>&1; then
        provider_key_env=$(acq_provider_credential_key_env "$1" 2>/dev/null) || provider_key_env=""
      fi
      printf '%s\n' "$provider_key_env"
      ;;
  esac
}

_acq_provider_fact_safe_host() {
  case "$1" in
    ""|*://*|*/*|*..*|*[^A-Za-z0-9.,:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

_acq_provider_fact_safe_env() {
  case "$1" in
    ""|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

_acq_provider_fact_safe_url() {
  case "$1" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
  esac
  # Keep provider facts data-only: allow RFC 3986 URL punctuation needed by
  # configured endpoints, but reject shell syntax before facts reach a backend.
  if ! printf '%s' "$1" | LC_ALL=C grep -qE '^https://[A-Za-z0-9._~:/?%&=+,@#-]+$'; then
    return 1
  fi
  local suffix hex
  suffix="$1"
  while [ "${suffix#*%}" != "$suffix" ]; do
    suffix="${suffix#*%}"
    [ "${#suffix}" -ge 2 ] || return 1
    hex="${suffix:0:2}"
    case "$hex" in *[!0-9A-Fa-f]*) return 1 ;; esac
    suffix="${suffix:2}"
  done
  return 0
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
# Besides the built-in services, any provider declared in acq's
# credential-bindings registry is managed: `acq secret set -g <providerId>` then
# stores (and the adapters inject) that provider's credential.
_acq_is_managed_service() {
  case "$ACQ_MANAGED_SECRET_SERVICES" in
    *" $1 "*) return 0 ;;
  esac
  command -v acq_provider_credential_key_env >/dev/null 2>&1 || return 1
  [ -n "$(acq_provider_credential_key_env "$1" 2>/dev/null)" ]
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
      --service)
        echo "acq: secret import: --service needs a value" >&2
        return 1
        ;;
      --service=*)
        only_service="${arg#--service=}"
        if ! _acq_is_importable_service "$only_service"; then
          echo "acq: secret import: unknown service '$only_service' for --service" >&2
          return 1
        fi
        ;;
      -*)
        echo "acq: secret import: unknown flag '$arg'" >&2
        echo "     usage: acq secret import [SERVICE] [-g | SANDBOX] [--all] [--force] [--dry-run]" >&2
        return 1
        ;;
      *)
        # A BARE token is a service when acq knows it as importable (a built-in
        # managed service, or a provider reachable through the trust anchor /
        # credential registry). That keeps `acq secret import usai` working after
        # usai stopped being a compiled-in service. Anything else is the SANDBOX
        # scope.
        if _acq_is_importable_service "$arg"; then
          if [ -z "$only_service" ]; then
            only_service="$arg"
          elif [ "$only_service" != "$arg" ]; then
            echo "acq: secret import: unexpected extra argument '$arg'" >&2
            return 1
          fi
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

# _acq_is_importable_service SERVICE — a built-in managed service, or a provider
# acq can import for (trust anchor, config.yaml, or ACQ_PROVIDER_CREDENTIAL_BINDINGS).
_acq_is_importable_service() {
  case "$ACQ_MANAGED_SECRET_SERVICES" in
    *" ${1:-} "*) return 0 ;;
  esac
  _acq_provider_credential_id_ok "${1:-}" || return 1
  command -v acq_provider_credential_key_env >/dev/null 2>&1 || return 1
  [ -n "$(acq_provider_credential_key_env "$1" 2>/dev/null)" ]
}

# acq_importable_services — every service `acq secret import` may scan for,
# deduped and in a stable order: the built-in host services, then the providers
# acq knows (trust anchor first, then config/env).
acq_importable_services() {
  {
    for _svc in $ACQ_MANAGED_SECRET_SERVICES; do
      printf '%s\n' "$_svc"
    done
    acq_provider_trusted_ids
    acq_provider_registry_ids
  } 2>/dev/null | awk 'NF && !seen[$0]++'
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

  # Which services to consider: a single named one, or every importable service
  # (built-ins plus the providers acq knows through its trust anchor/registry).
  local services
  services=$(acq_importable_services)
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
  # A provider pinned in the credential-bindings registry is acq-managed too, so
  # `acq secret rm <providerId>` routes to the acq-store removal path.
  if command -v acq_provider_credential_key_env >/dev/null 2>&1 \
      && [ -n "$(acq_provider_credential_key_env "$svc" 2>/dev/null)" ]; then
    return 0
  fi
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
  local _name="$1" _val="$2" _had_noglob=0
  # Save/restore ONLY noglob. Capturing the full option state with
  # `_oldopts=$(set +o)` is a trap: a command-substitution subshell runs with
  # errexit CLEARED (pre-inherit_errexit bash, incl. macOS 3.2), so the captured
  # state says `set +o errexit` and the eval restore silently turned `set -e`
  # OFF in the caller for the rest of the run (found via #381: it also disabled
  # bats' failure detection whenever ACQ_EXTRA_KITS was set).
  case "$-" in *f*) _had_noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2086
  set -- $_val
  if [ "$_had_noglob" -eq 0 ]; then set +f; fi
  eval "$_name=(\"\$@\")"
}

_acq_builtin_kit_ref() {
  case "${1:-}" in
    zscaler-ca-certificate) printf '%s\n' "$ZSCALER_KIT" ;;
    "$USAI_PROVIDER_KIT_NAME") printf '%s\n' "$USAI_KIT" ;;
    agentic-coding-playbook) printf '%s\n' "$PLAYBOOK_KIT" ;;
    git-ssh-sign) printf '%s\n' "$GITSSHSIGN_KIT" ;;
    *) return 1 ;;
  esac
}

_acq_builtin_support_kit_names() {
  printf '%s\n' zscaler-ca-certificate "$USAI_PROVIDER_KIT_NAME" agentic-coding-playbook git-ssh-sign
}

_acq_selected_provider_kit_refs() {
  local provider_refs=() ref resolved
  if [ -z "${ACQ_PROVIDER_KITS_FROM_ENV:-}" ] && [ -z "${ACQ_PROVIDER_KITS_FROM_CLI:-}" ]; then
    # The default provider kit is DATA (`provider_kit:` in config.yaml), so a new
    # provider needs no code change here.
    resolved=$(acq_provider_kit_ref) || return 1
    provider_refs=("$resolved")
  elif [ -n "$ACQ_PROVIDER_KITS" ]; then
    split_noglob provider_refs "$ACQ_PROVIDER_KITS"
  fi
  for ref in ${provider_refs[@]+"${provider_refs[@]}"}; do
    printf '%s\n' "$ref"
  done
}

acq_provider_kit_selected() {
  local wanted="$1" name
  while IFS= read -r name; do
    [ "$name" = "$wanted" ] && return 0
  done < <(_acq_selected_provider_kit_refs)
  return 1
}

acq_usai_provider_selected() {
  acq_provider_kit_selected "$USAI_KIT"
}

acq_provider_selection_load() {
  local backend="$1" name="$2" mode kits
  mode=$(acq_provenance_field "$backend" "$name" provider_selection)
  kits=$(acq_provenance_field "$backend" "$name" provider_kits)
  case "$mode" in
    default) ACQ_PROVIDER_KITS=""; ACQ_PROVIDER_KITS_FROM_ENV=""; ACQ_PROVIDER_KITS_FROM_CLI="" ;;
    explicit) ACQ_PROVIDER_KITS="$kits"; ACQ_PROVIDER_KITS_FROM_ENV=1; ACQ_PROVIDER_KITS_FROM_CLI="" ;;
    # Legacy records predate provider selection and therefore retain the
    # historical default rather than inheriting a later host environment choice.
    "") ACQ_PROVIDER_KITS=""; ACQ_PROVIDER_KITS_FROM_ENV=""; ACQ_PROVIDER_KITS_FROM_CLI="" ;;
    *) return 1 ;;
  esac
}

_acq_agent_builtin_kit_ref() {
  local kit_name
  kit_name=$(acq_agent_builtin_kit_name "$1") || return 1
  if [ -n "${BATS_TEST_NAME:-}" ] && [ -n "${ACQ_TEST_AGENT_KIT:-}" ]; then
    printf '%s\n' "$ACQ_TEST_AGENT_KIT"
    return 0
  fi
  printf '%s#ref=%s&dir=%s/%s\n' "$PATTERNS_KIT_REPO" "$PATTERNS_KIT_REF" "$PATTERNS_KIT_DIR" "$kit_name"
}

kit_spec_agent_field() {
  local spec="$1" key="$2"
  [ -f "$spec" ] || return 1
  awk -v key="$key" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    /^agent:[[:space:]]*($|#)/ { in_agent=1; next }
    /^[^[:space:]#][^:]*:/ { in_agent=0 }
    in_agent {
      line=$0
      sub(/[[:space:]]*#.*/,"",line)
      if (line ~ "^  " key ":[[:space:]]*") {
        sub("^  " key ":[[:space:]]*","",line)
        line=trim(line)
        gsub(/^\"|\"$/, "", line)
        gsub(/^'\''|'\''$/, "", line)
        if (line != "") print line
        exit
      }
    }
  ' "$spec"
}

acq_validate_agent_builtin_kit_dir() {
  local agent="$1" kitdir="$2" spec schema kind kit_name agent_name entrypoint
  local expected_kit expected_entrypoint
  expected_kit=$(acq_agent_builtin_kit_name "$agent") || return 1
  expected_entrypoint=$(acq_agent_kit_entrypoint "$agent") || return 1
  spec="$kitdir/spec.yaml"
  [ -f "$spec" ] || return 1

  schema=$(kit_spec_field "$spec" schemaVersion) || schema=""
  kind=$(kit_spec_field "$spec" kind) || kind=""
  kit_name=$(kit_spec_field "$spec" name) || kit_name=""
  agent_name=$(kit_spec_agent_field "$spec" name) || agent_name=""
  entrypoint=$(kit_spec_agent_field "$spec" entrypoint) || entrypoint=""

  [ "$schema" = "hybrid/v1" ] || return 1
  [ "$kind" = "mixin" ] || return 1
  [ "$kit_name" = "$expected_kit" ] || return 1
  [ "$agent_name" = "$agent" ] || return 1
  [ "$entrypoint" = "$expected_entrypoint" ] || return 1
}

acq_validate_agent_builtin_kit_ref() {
  local agent="$1" kitref="$2" base_dir="${3:-}" kitdir
  if [ -z "$base_dir" ]; then
    base_dir="${ACQ_STATE_DIR:-${TMPDIR:-/tmp}/acq}/agent-kit-validation/$agent"
  fi
  kitdir=$(kit_translate_fetch "$kitref" "$base_dir") || return 1
  acq_validate_agent_builtin_kit_dir "$agent" "$kitdir"
}

acq_agent_builtin_kit_ready() {
  local agent="$1" kit cache_key cache_value
  acq_agent_builtin_kit_enabled "$agent" || return 1
  kit=$(_acq_agent_builtin_kit_ref "$agent") || return 1
  cache_key="${agent}:$(printf '%s' "$kit" | cksum | cut -d' ' -f1)"
  cache_value=$(printf '%s\n' "$ACQ_AGENT_KIT_READY_CACHE" | awk -F'\t' -v key="$cache_key" '$1 == key { print $2; exit }')
  case "$cache_value" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  if acq_validate_agent_builtin_kit_ref "$agent" "$kit"; then
    ACQ_AGENT_KIT_READY_CACHE="${ACQ_AGENT_KIT_READY_CACHE}${cache_key}	yes
"
    return 0
  fi
  ACQ_AGENT_KIT_READY_CACHE="${ACQ_AGENT_KIT_READY_CACHE}${cache_key}	no
"
  return 1
}

_acq_selected_support_kit_refs() {
  local skip_provider="${1:-0}" name kit provider_refs
  kit=$(_acq_builtin_kit_ref zscaler-ca-certificate) || return 1
  printf '%s\n' "$kit"
  # Captured, NOT consumed through a process substitution: a failed provider-kit
  # resolution is reported to the caller instead of silently dropping the provider
  # kit. SKIP_PROVIDER=1 yields the provider-free list, which is what the
  # management verbs get to use while a config typo still exists.
  if [ "$skip_provider" != "1" ]; then
    provider_refs=$(_acq_selected_provider_kit_refs) || {
      echo "acq: the configured provider kit could not be resolved (see above)." >&2
      echo "     Fix 'provider_kit:' / 'kit_sources:' (acq kit-source ls)," >&2
      echo "     or unset ACQ_PROVIDER_KITS." >&2
      return 1
    }
    while IFS= read -r kit; do
      [ -n "$kit" ] && printf '%s\n' "$kit"
    done <<EOF
$provider_refs
EOF
  fi
  for name in agentic-coding-playbook git-ssh-sign; do
    kit=$(_acq_builtin_kit_ref "$name") || return 1
    printf '%s\n' "$kit"
  done
}

_acq_selected_builtin_kit_refs() {
  local agent="${1:-}" kit
  _acq_selected_support_kit_refs || return 1
  if [ -n "$agent" ] && acq_is_known_agent "$agent" \
      && { [ "${#ACQ_CLI_KITS[@]}" -eq 0 ] || [ "${ACQ_REQUIRED_AGENT_KIT:-}" = "$agent" ]; } \
      && acq_agent_builtin_kit_ready "$agent"; then
    kit=$(_acq_agent_builtin_kit_ref "$agent") || return 1
    printf '%s\n' "$kit"
  fi
}

acq_selected_agent_kit_summary() {
  local agent="${1:-}" kit_name entrypoint install_owner start_owner apply_state="deferred"
  kit_name=$(acq_agent_builtin_kit_name "$agent") || return 1
  entrypoint=$(acq_agent_kit_entrypoint "$agent") || entrypoint=""
  install_owner=$(acq_agent_kit_install_owner "$agent") || install_owner=""
  start_owner=$(acq_agent_kit_start_owner "$agent") || start_owner=""
  acq_agent_builtin_kit_ready "$agent" && apply_state="enabled"
  printf 'agent=%s kit=%s entrypoint=%s install_owner=%s start_owner=%s apply=%s\n' \
    "$agent" "$kit_name" "${entrypoint:-none}" "${install_owner:-none}" \
    "${start_owner:-none}" "$apply_state"
}

acq_print_selected_agent_kit() {
  local agent="${1:-}" summary
  summary=$(acq_selected_agent_kit_summary "$agent") || return 0
  if [ "${summary##*apply=}" = "enabled" ]; then
    printf 'acq: selected built-in agent kit: %s\n' "$summary" >&2
  else
    printf 'acq: built-in agent kit candidate (deferred; no agent kit applied): %s\n' "$summary" >&2
  fi
}

# _acq_require_provider_selection — the create/run gate for a provider kit that
# could not be resolved while the kit list was built. Management verbs deliberately
# ignore the latch (they are how the user fixes the config); building a sandbox
# without the selected provider would silently ship a different environment.
_acq_require_provider_selection() {
  [ -n "${ACQ_PROVIDER_SELECTION_ERROR:-}" ] || return 0
  echo "acq: the configured provider kit could not be resolved:" >&2
  printf '%s\n' "$ACQ_PROVIDER_SELECTION_ERROR" >&2
  echo "     Fix 'provider_kit:' / 'kit_sources:' (see: acq kit-source ls)," >&2
  echo "     or unset ACQ_PROVIDER_KITS." >&2
  return 1
}

# Assemble the full kit list: selected built-ins, then extras.
# Zscaler CA trust FIRST (see ACQ_KIT_NAMES) so later network-fetching kits
# succeed behind a TLS-intercepting proxy.
# shellcheck disable=SC2120  # optional agent argument; many callers use default
_build_kit_list() {
  local agent="${1:-}" kit support_refs
  KITS=()
  # This runs for EVERY verb (acq_resolve_backend), so a provider-selection
  # failure is LATCHED here and only enforced by create/run through
  # _acq_require_provider_selection. The kit list still builds (without the
  # provider) so `acq configure`/`kit-source`/`help` can repair the config.
  if support_refs=$(_acq_selected_support_kit_refs 2>/dev/null); then
    ACQ_PROVIDER_SELECTION_ERROR=""
  else
    ACQ_PROVIDER_SELECTION_ERROR=$(_acq_selected_support_kit_refs 2>&1 >/dev/null || true)
    support_refs=$(_acq_selected_support_kit_refs 1) || return 1
  fi
  while IFS= read -r kit; do
    [ -n "$kit" ] && KITS+=("$kit")
  done <<EOF
$support_refs
EOF
  # shellcheck disable=SC2034  # read by adapters/tests after _build_kit_list
  ACQ_BUILTIN_SUPPORT_KIT_COUNT="${#KITS[@]}"
  if [ -n "${ACQ_REQUIRED_AGENT_KIT:-}" ] \
      && [ "${ACQ_REQUIRED_AGENT_KIT:-}" = "$agent" ] \
      && ! acq_agent_builtin_kit_ready "$agent"; then
    echo "acq: required built-in ${agent} kit is unavailable or has invalid agent metadata." >&2
    echo "     Refusing the generic default image because it has no bundled ${agent} binary." >&2
    return 1
  fi
  if [ -n "$agent" ] && acq_is_known_agent "$agent" \
      && { [ "${#ACQ_CLI_KITS[@]}" -eq 0 ] || [ "${ACQ_REQUIRED_AGENT_KIT:-}" = "$agent" ]; } \
      && acq_agent_builtin_kit_ready "$agent"; then
    kit=$(_acq_agent_builtin_kit_ref "$agent") || return 1
    KITS+=("$kit")
  fi
  # shellcheck disable=SC2034  # read by adapters/tests after _build_kit_list
  ACQ_BUILTIN_KIT_COUNT="${#KITS[@]}"
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

  # Also build the allowed sources list. Trusted kit sources are now DATA (the
  # kit_sources registry), so the allowlist is derived rather than hardcoded.
  KIT_SOURCE_PREFIXES=()
  local _prefix
  while IFS= read -r _prefix; do
    [ -n "$_prefix" ] && KIT_SOURCE_PREFIXES+=("$_prefix")
  done < <(acq_kit_source_prefixes)
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

# Canonicalize a filesystem path to its real, symlink-free absolute form, in the
# running shell's OWN (POSIX) vocabulary. Echoes the resolved path, or the input
# unchanged if it cannot be resolved (e.g. a nonexistent path, or no
# realpath/readlink available). Pure stdout; never mutates the filesystem. Used
# so a backend mounts the REAL host path — e.g. on macOS $TMPDIR is a
# /var -> /private/var symlink, and msb cannot mount the symlinked form (see
# docs/BACKEND_GUIDE.md, msb workspace mounting).
#
# On MSYS/Cygwin this is also the GUEST form: a native tool (git.exe) may report
# a drive-form path (C:/...), but the guest is a Linux microVM where a drive-form
# path is not absolute. `cygpath -u` maps drive-form to the shell/guest form
# (/c/...); cygpath only exists on MSYS/Cygwin, so POSIX hosts are unaffected.
# For the HOST form a native tool needs, use host_path (below). See ADR-0029.
canonicalize_path() {
  local p="${1:-}" _out=""
  [ -n "$p" ] || return 0
  if command -v realpath >/dev/null 2>&1; then
    _out=$(realpath "$p" 2>/dev/null) || _out=""
  elif command -v readlink >/dev/null 2>&1; then
    _out=$(readlink -f "$p" 2>/dev/null) || _out=""
  fi
  [ -n "$_out" ] && p="$_out"
  if command -v cygpath >/dev/null 2>&1; then
    _out=$(cygpath -u "$p" 2>/dev/null) || _out=""
    [ -n "$_out" ] && p="$_out"
  fi
  printf '%s\n' "$p"
}

# host_path — echo PATH in the form a NATIVE host tool expects: a Windows
# drive-form path (C:/...) under MSYS/Cygwin, unchanged on POSIX. Companion to
# canonicalize_path: canonicalize a value that names something INSIDE the guest
# (a mount target, a working directory, a guest env value); host_path a value a
# native host tool must resolve on the host filesystem (a mount SOURCE, a file
# to copy, a host socket, a host PEM). On POSIX the two are identical. See
# ADR-0029.
host_path() {
  local p="${1:-}" _out=""
  [ -n "$p" ] || return 0
  if command -v cygpath >/dev/null 2>&1; then
    _out=$(cygpath -m "$p" 2>/dev/null) || _out=""
    [ -n "$_out" ] && p="$_out"
  fi
  printf '%s\n' "$p"
}

acq_project_env_kind() {
  local ws="${1:-}"
  [ -n "$ws" ] && [ -d "$ws" ] || return 1
  if [ -f "$ws/.envrc" ]; then
    printf 'direnv\n'
    return 0
  fi
  if [ -f "$ws/devenv.nix" ] || [ -f "$ws/devenv.yaml" ] || [ -f "$ws/devenv.lock" ]; then
    printf 'devenv\n'
    return 0
  fi
  return 1
}

advise_project_env_activation() {
  local ws="${1:-}" kind
  kind=$(acq_project_env_kind "$ws" 2>/dev/null || true)
  [ -n "$kind" ] || return 0
  [ "${ACQ_PROJECT_ENV_NOTICE:-1}" = "0" ] && return 0
  if [ "${ACQ_ACTIVATE_PROJECT_ENV:-0}" = "1" ]; then
    echo "acq: project environment detected ($kind); ACQ_ACTIVATE_PROJECT_ENV=1 will" >&2
    echo "     use already-approved direnv export when available." >&2
    return 0
  fi
  echo "acq: project environment detected ($kind) in $ws." >&2
  echo "     acq will not run project activation, 'direnv allow', or 'devenv shell' automatically." >&2
  echo "     If you trust this repo and have approved its .envrc yourself, re-run" >&2
  echo "     this acq command with ACQ_ACTIVATE_PROJECT_ENV=1 to use direnv export." >&2
}

acq_session_is_user() {
  case "${ACQ_SESSION_KIND:-}" in
    exec|shell|attach) return 0 ;;
    *) return 1 ;;
  esac
}

acq_guest_exec_script() {
  printf '%s\n' 'set -e; if [ -n "${ACQ_WORKSPACE:-}" ] && [ -d "$ACQ_WORKSPACE" ]; then cd "$ACQ_WORKSPACE"; fi; if [ -f .envrc ]; then if command -v direnv >/dev/null 2>&1; then eval "$(direnv export sh)"; else echo "acq: .envrc found, but direnv is not installed in this sandbox; continuing without activation." >&2; fi; elif [ -f devenv.nix ] || [ -f devenv.yaml ] || [ -f devenv.lock ]; then echo "acq: devenv files found, but no .envrc/direnv activation is available; continuing without activation." >&2; fi; exec "$@"'
}

acq_guest_shell_script() {
  if [ "${ACQ_ACTIVATE_PROJECT_ENV:-0}" = "1" ]; then
    printf '%s\n' 'set -e; shell="${1:-${SHELL:-/bin/sh}}"; if [ -n "${ACQ_WORKSPACE:-}" ] && [ -d "$ACQ_WORKSPACE" ]; then cd "$ACQ_WORKSPACE"; fi; if [ -f .envrc ]; then if command -v direnv >/dev/null 2>&1; then eval "$(direnv export sh)"; else echo "acq: .envrc found, but direnv is not installed in this sandbox; continuing without activation." >&2; fi; elif [ -f devenv.nix ] || [ -f devenv.yaml ] || [ -f devenv.lock ]; then echo "acq: devenv files found, but no .envrc/direnv activation is available; continuing without activation." >&2; fi; exec "$shell" -l'
  else
    printf '%s\n' 'set -e; shell="${1:-${SHELL:-/bin/sh}}"; if [ -n "${ACQ_WORKSPACE:-}" ] && [ -d "$ACQ_WORKSPACE" ]; then cd "$ACQ_WORKSPACE"; fi; exec "$shell" -l'
  fi
}

# acq_login_profile_rc_block — emit the guest-side POSIX-sh snippet that a login
# ~/.profile uses to source the kit-owned ~/.rc.d/*.sh drop-ins. Keep this as the
# single backend-neutral source of the bridge text: msb writes it from
# _acq_msb_ensure_agent_shell, and sbx writes the same bytes from
# _acq_sbx_ensure_rc_bridge.
#
# Emitted lines are evaluated by the guest login shell. They gate to bash,
# list snippets with C collation for deterministic order, preserve the readable
# and charset guards, and clean up the loop variable after sourcing. `command ls`
# because ~/.profile sources ~/.bashrc first, which may alias or wrap ls.
acq_login_profile_rc_block() {
  printf '%s\n' 'if [ -n "$BASH_VERSION" ] && [ -d "$HOME/.rc.d" ]; then'
  printf '%s\n' '  for _acq_rc in $(LC_ALL=C command ls "$HOME"/.rc.d 2>/dev/null); do'
  printf '%s\n' '    _acq_rc="$HOME/.rc.d/$_acq_rc"'
  printf '%s\n' '    case "$_acq_rc" in *.sh) ;; *) continue ;; esac'
  printf '%s\n' '    [ -r "$_acq_rc" ] || continue'
  printf '%s\n' '    case "$_acq_rc" in *[!A-Za-z0-9._/-]*) continue ;; esac'
  printf '%s\n' '    # shellcheck disable=SC1090'
  printf '%s\n' '    . "$_acq_rc"'
  printf '%s\n' '  done'
  printf '%s\n' '  unset _acq_rc'
  printf '%s\n' 'fi'
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

# Extract the explicit empty provider selection without relying on shell export
# semantics for empty values. It is acq-owned and never reaches a backend CLI.
extract_provider_flags() {
  ACQ_PROVIDER_REMAINING=()
  local arg seen_sep=0
  for arg in "$@"; do
    if [ "$seen_sep" -eq 1 ]; then
      ACQ_PROVIDER_REMAINING+=("$arg")
      continue
    fi
    case "$arg" in
      --) seen_sep=1; ACQ_PROVIDER_REMAINING+=("$arg") ;;
      --no-provider-kits) ACQ_PROVIDER_KITS=""; ACQ_PROVIDER_KITS_FROM_CLI=1 ;;
      *) ACQ_PROVIDER_REMAINING+=("$arg") ;;
    esac
  done
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

# Extract the acq-owned boolean `--clone` (neutral disposable-primary option,
# GSA-TTS/agentic-coding-quickstart#403) from an arg list, mirroring
# extract_image_flag: ACQ_CLONE_FLAG=1 if seen before `--`, everything else in
# ACQ_CLONE_REMAINING. Acq owns the flag on both backends — sbx re-injects it
# for the native `sbx create --clone`; msb emulates with a host-side scratch
# clone — so it must never survive raw on a backend argv.
extract_clone_flag() {
  ACQ_CLONE_FLAG=""
  ACQ_CLONE_REMAINING=()
  local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    # shellcheck disable=SC2034  # ACQ_CLONE_FLAG is consumed by the sourcing acq dispatch (cross-file)
    case "$arg" in
      --)      ACQ_CLONE_REMAINING+=("$@"); break ;;
      --clone) ACQ_CLONE_FLAG=1 ;;
      *)       ACQ_CLONE_REMAINING+=("$arg") ;;
    esac
    shift
  done
}

# Extract the acq-owned `--publish HOST:GUEST` / `--publish=HOST:GUEST` flag
# (repeatable) from a run/create arg list (ADR-0034). Populates, IN THE CURRENT
# SHELL (so callers must not run this in a subshell/pipeline):
#   ACQ_PUBLISH_FLAGS      — one `HOST:GUEST` pair per element, in order
#   ACQ_PUBLISH_REMAINING  — the arg list with the --publish flags removed
#
# Returns non-zero on a malformed value, having explained what was wrong; the
# caller must abort rather than create a sandbox missing a mapping the user
# explicitly asked for. `HOST:GUEST` is REQUIRED in full: a bare `--publish 6868`
# is ambiguous (host or guest?) and the guest port belongs to the kit, not to the
# launcher, so acq refuses it instead of guessing.
#
# Like extract_kit_flags, scanning STOPS at the first `--` separator: everything
# after it is agent args and is forwarded verbatim (an inner agent may have its
# own `--publish`). The flag must never reach a backend CLI — `msb create` has a
# native `-p` that acq synthesizes itself, and sbx has no equivalent at all.
extract_publish_flags() {
  ACQ_PUBLISH_FLAGS=()
  ACQ_PUBLISH_REMAINING=()
  local expect=0 arg rc=0
  while [ "$#" -gt 0 ]; do
    arg="$1"
    if [ "$expect" -eq 1 ]; then
      _acq_validate_publish_pair "$arg" || rc=1
      ACQ_PUBLISH_FLAGS+=("$arg")
      expect=0
      shift
      continue
    fi
    case "$arg" in
      --)          ACQ_PUBLISH_REMAINING+=("$@"); break ;;
      --publish)   expect=1 ;;
      --publish=*) _acq_validate_publish_pair "${arg#--publish=}" || rc=1
                   ACQ_PUBLISH_FLAGS+=("${arg#--publish=}") ;;
      *)           ACQ_PUBLISH_REMAINING+=("$arg") ;;
    esac
    shift
  done
  if [ "$expect" -eq 1 ]; then
    echo "acq: --publish given with no value (expected HOST:GUEST)" >&2
    rc=1
  fi
  return "$rc"
}

# Validate one `HOST:GUEST` pair (SI-10) — these values become an `-p` argv on a
# backend CLI. Both sides must be integers 1..65535, spelled canonically.
#
# The digits-only `case` guard and the length cap come FIRST, deliberately:
# `[ "$p" -ge 1 ]` compares arithmetically without octal-interpreting a leading
# zero (so `0080` would silently mean 80, which is why a leading zero is refused
# outright rather than accepted), but it ABORTS the shell with status 2 on a
# wildly long digit string. Never use `$((...))` on these: `$((0080))` is a fatal
# invalid-octal error, not a comparison.
_acq_validate_publish_pair() {
  local pair="${1:-}" h g p
  case "$pair" in
    *:*) h="${pair%%:*}"; g="${pair#*:}" ;;
    *)
      echo "acq: --publish '${pair}' is not HOST:GUEST — both sides are required" >&2
      echo "     (e.g. --publish 6868:6767: reach the sandbox's guest port 6767 on" >&2
      echo "     host port 6868). The guest port is the one the kit publishes." >&2
      return 1
      ;;
  esac
  for p in "$h" "$g"; do
    case "$p" in
      ""|*[!0-9]*)
        echo "acq: --publish '${pair}': '${p}' is not a port number (1..65535)" >&2
        return 1 ;;
      0*)
        echo "acq: --publish '${pair}': '${p}' has a leading zero; write it plainly" >&2
        return 1 ;;
    esac
    if [ "${#p}" -gt 5 ]; then
      echo "acq: --publish '${pair}': '${p}' is out of range (1..65535)" >&2
      return 1
    fi
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      echo "acq: --publish '${pair}': '${p}' is out of range (1..65535)" >&2
      return 1
    fi
  done
  # A guest port is publishable exactly once, so a repeated guest side is a
  # user mistake (which of the two host ports did they mean?), not a union.
  local prev
  for prev in ${ACQ_PUBLISH_FLAGS[@]+"${ACQ_PUBLISH_FLAGS[@]}"}; do
    if [ "${prev#*:}" = "$g" ]; then
      echo "acq: --publish: guest port ${g} is already mapped to host port" \
           "${prev%%:*}; drop one of the two --publish flags" >&2
      return 1
    fi
  done
  return 0
}

# --publish is create-time only (ADR-0034): the host↔guest mapping is fixed in
# the backend's create argv, so a re-attach cannot move it. Say so on every
# re-attach path rather than drop the flag silently, and point at the post-hoc
# verb, which CAN add a mapping to a running sandbox (ADR-0015).
note_publish_ignored_on_reattach() {
  local name="$1"
  [ "${#ACQ_PUBLISH_FLAGS[@]}" -gt 0 ] || return 0
  echo "acq: note: --publish is ignored when re-attaching an existing sandbox" \
       "('$name'); the host port mapping is fixed at create. Use" \
       "'acq ports $name --publish HOST:GUEST' to add one now, or remove" \
       "the sandbox first ('acq rm $name') to recreate with it." >&2
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
  _acq_config_read_field backend
}

# _acq_config_read_field KEY — echo the value of a flat `KEY: value` line from
# config.yaml (empty if the file or key is absent). Defensive awk parse, no YAML
# dependency — the same convention as the original single-key backend reader,
# generalized to any flat scalar key (backend, extra_kits, scope_github_token).
# KEY is matched literally at column 1. Indented keys are deliberately ignored:
# this is a flat config file, not a general YAML parser. Inline comments and
# simple single/double-quoted scalars are accepted for hand-edited YAML. If
# duplicate top-level keys exist, the last one wins, matching the writer's
# replace-all behavior. A non-identifier KEY is rejected so a caller can't inject
# an awk regex.
_acq_config_read_field() {
  local key="${1:-}" cfg
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 0 ;;   # fail closed on an unexpected key name
  esac
  cfg=$(_acq_config_file)
  [ -f "$cfg" ] || return 0
  awk -v k="$key" '
    {
      # Match only a top-level flat key: key, optional space, colon.
      pat = "^" k "[[:space:]]*:"
      if ($0 ~ pat) {
        sub(pat "[[:space:]]*", "")     # strip through the colon + spaces
        line = $0
        q = sprintf("%c", 39)
        if (substr(line, 1, 1) == "\"" || substr(line, 1, 1) == q) {
          in_single = 0
          in_double = 0
          for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == q && !in_double) {
              in_single = !in_single
            } else if (c == "\"" && !in_single) {
              in_double = !in_double
            } else if (c == "#" && !in_single && !in_double && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) {
              line = substr(line, 1, i - 1)
              break
            }
          }
        } else if (line ~ /^#/) {
          line = ""
        } else {
          sub(/[[:space:]]+#.*$/, "", line)
        }
        $0 = line                         # tolerate inline comments outside quotes
        sub(/[[:space:]]*$/, "")         # strip trailing space
        q = sprintf("%c", 39)
        if ($0 ~ /^"[^"]*"$/) {
          sub(/^"/, "")
          sub(/"$/, "")
        } else if (substr($0, 1, 1) == q && substr($0, length($0), 1) == q) {
          $0 = substr($0, 2, length($0) - 2)
        }
        val = $0                         # last duplicate key wins
      }
    }
    END {
      if (val != "") print val
    }
  ' "$cfg"
}

# _acq_config_write_field KEY VALUE — set (or replace) a flat `KEY: VALUE` line in
# config.yaml, preserving every OTHER line (so writing extra_kits leaves backend
# untouched, and vice-versa). Creates the file + parent dir on first write. An
# empty VALUE removes the key entirely (so "no extras" is represented by absence,
# not an empty-valued line). Atomic (temp file + mv). Best-effort: a write failure
# warns via acq_debug and returns non-zero but never aborts the caller.
_acq_config_write_field() {
  local key="${1:-}" value="${2:-}" cfg dir tmp
  case "$key" in
    ''|*[!A-Za-z0-9_]*) acq_debug "config: refusing to write unsafe key '$key'"; return 1 ;;
  esac
  cfg=$(_acq_config_file)
  dir=$(dirname "$cfg")
  if ! ( umask 077; mkdir -p "$dir" ) 2>/dev/null; then
    acq_debug "config: could not create config dir: $dir"
    return 1
  fi
  chmod 700 "$dir" 2>/dev/null || { acq_debug "config: chmod failed: $dir"; return 1; }
  tmp="${cfg}.tmp.$$"
  {
    # Re-emit every existing line except the one for KEY (which we replace/drop).
    if [ -f "$cfg" ]; then
      awk -v k="$key" '
        {
          pat = "^" k "[[:space:]]*:"
          if ($0 ~ pat) next     # drop the old top-level KEY line; we re-add below
          print
        }
      ' "$cfg"
    fi
    # Append the new value only when non-empty (empty VALUE => remove the key).
    # Use an explicit if (not `[ ] &&`) so the group's exit status reflects the
    # write, not a false test when VALUE is empty.
    if [ -n "$value" ]; then
      printf '%s: %s\n' "$key" "$value"
    fi
  } > "$tmp" 2>/dev/null || { acq_debug "config: write failed: $tmp"; rm -f "$tmp" 2>/dev/null; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { acq_debug "config: chmod failed: $tmp"; rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$cfg" 2>/dev/null || { acq_debug "config: mv failed: $cfg"; rm -f "$tmp" 2>/dev/null; return 1; }
  acq_debug "config: wrote ${key}"
  return 0
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
# an ISO-8601 UTC timestamp + the backend. A third AGENT argument records the
# agent selected at create time; when omitted, an existing agent field is
# preserved across in-place refreshes. Best-effort: a write failure warns (debug)
# and returns non-zero but never aborts the caller (fail-open).
# Usage: acq_provenance_write BACKEND SANDBOX_NAME [AGENT] [WORKSPACE]
acq_provenance_write() {
  local backend="${1:-}" name="${2:-}" agent="${3:-}" workspace="${4:-}" provider_selection provider_kits
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  local file dir ts workspace_source
  file=$(_acq_provenance_file "$backend" "$name") || return 1
  workspace_source=$(acq_provenance_field "$backend" "$name" workspace_source)
  if [ -z "$workspace" ] && [ "$workspace_source" = "host" ]; then
    workspace=$(acq_provenance_field "$backend" "$name" workspace)
  fi
  dir=$(dirname "$file")
  if ! mkdir -p "$dir" 2>/dev/null; then
    acq_debug "provenance: could not create state dir: $dir"
    return 1
  fi
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  [ -n "$agent" ] || agent=$(acq_provenance_field "$backend" "$name" agent)
  case "$agent" in
    "") : ;;
    *[!a-z-]*) agent="" ;;
  esac
  case "$workspace" in
    "") : ;;
    *[!A-Za-z0-9._/-]*) workspace="" ;;
  esac
  if [ -n "${ACQ_PROVIDER_KITS_FROM_ENV:-}" ] || [ -n "${ACQ_PROVIDER_KITS_FROM_CLI:-}" ]; then
    provider_selection=explicit
    provider_kits="$ACQ_PROVIDER_KITS"
  else
    provider_selection=default
    provider_kits=""
  fi
  # Write atomically via a temp file + mv so a crash mid-write can't leave a
  # half-written record that later parses as a bogus "current" ref.
  local tmp="${file}.tmp.$$"
  {
    printf 'schema=1\n'
    printf 'bundle=%s\n' "$ACQ_BUILTIN_BUNDLE"
    printf 'repo=%s\n' "$ACQ_BUILTIN_BUNDLE_REPO"
    printf 'applied_ref=%s\n' "$PATTERNS_KIT_REF"
    printf 'backend=%s\n' "$backend"
    printf 'provider_selection=%s\n' "$provider_selection"
    [ -n "$provider_kits" ] && printf 'provider_kits=%s\n' "$provider_kits"
    [ -n "$agent" ] && printf 'agent=%s\n' "$agent"
    printf 'applied_at=%s\n' "$ts"
    if [ -n "${workspace:-}" ]; then
      printf 'workspace_source=host\n'
      printf 'workspace=%s\n' "$workspace"
    fi
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

# Remember the primary host workspace mounted into a sandbox. This is non-secret
# host-side state used by commands that take only SANDBOX later (for example,
# `acq github-scope SANDBOX`) so they do not accidentally inspect the caller's
# current directory instead of the sandbox's workspace.
acq_workspace_record_write() {
  local backend="${1:-}" name="${2:-}" workspace="${3:-}"
  [ -n "$backend" ] && [ -n "$name" ] && [ -n "$workspace" ] || return 0
  case "$workspace" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  local workspace_check
  workspace_check="$workspace"
  if [ ! -d "$workspace_check" ] && command -v cygpath >/dev/null 2>&1; then
    workspace_check=$(cygpath -u "$workspace" 2>/dev/null || printf '%s' "$workspace")
  fi
  [ -d "$workspace_check" ] || return 1
  local file dir tmp
  file=$(_acq_provenance_file "$backend" "$name") || return 1
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="${file}.workspace.$$"
  {
    if [ -f "$file" ]; then
      awk -F= '$1 != "workspace" && $1 != "workspace_source" { print }' "$file" 2>/dev/null || true
    else
      printf 'schema=1\n'
      printf 'backend=%s\n' "$backend"
    fi
    printf 'workspace_source=host\n'
    printf 'workspace=%s\n' "$workspace"
  } > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

acq_workspace_record_read() {
  local backend="${1:-}" name="${2:-}" source
  source=$(acq_provenance_field "$backend" "$name" workspace_source)
  [ "$source" = "host" ] || return 0
  acq_provenance_field "$backend" "$name" workspace
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

# ============================================================================
# Trusted kit sources (which repositories acq will fetch kits from)
# ============================================================================
# Trust here is deliberately NARROW: a trusted source may be FETCHED from, and
# its provider kits may be selected. It does NOT extend to the validation
# control plane — the provider-input validator and its schemas stay pinned to the
# Patterns release (PATTERNS_KIT_REF), so a new source can ship kits but cannot
# redefine what a valid kit is.
#
# The registry is DATA in config.yaml so the default provider is not special-cased
# in code:
#   kit_sources:  host/owner/repo[@REF][|DIR] ...   (whitespace separated)
#   provider_kit: <source-or-repo>/<kit>            (or <kit>@<repo>)
# ACQ_KIT_SOURCES overrides the source list for one invocation.
ACQ_KIT_SOURCE_CONFIG_KEY="kit_sources"
ACQ_PROVIDER_KIT_CONFIG_KEY="provider_kit"
ACQ_KIT_SOURCE_DEFAULT_REPO="github.com/GSA-TTS/agentic-coding-patterns"
ACQ_KIT_SOURCE_DEFAULT_REF="$PATTERNS_KIT_REF"
ACQ_KIT_SOURCE_DEFAULT_DIR="$PATTERNS_KIT_DIR"
# The default provider kit, expressed as data. The short source name is matched
# against the registered sources, so bumping PATTERNS_KIT_REF needs no code edit.
ACQ_PROVIDER_KIT_DEFAULT="agentic-coding-patterns/${USAI_PROVIDER_KIT_NAME}"

# _acq_kit_source_repo_ok REPO — host/owner/repo, lower-case host, no scheme.
_acq_kit_source_repo_ok() {
  local repo="${1:-}"
  [ -n "$repo" ] && [ "${#repo}" -le 200 ] || return 1
  printf '%s' "$repo" | LC_ALL=C grep -qE \
    '^[a-z0-9][a-z0-9.-]*/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

# _acq_kit_source_normalize_repo ARG — accept what a human pastes (a bare
# host/owner/repo, a clone URL, a git+https kit-style URL) and emit host/owner/repo.
# Fails closed on anything else so a typo cannot silently trust a different repo.
_acq_kit_source_normalize_repo() {
  local arg="${1:-}" repo
  repo="$arg"
  repo="${repo#git+}"
  case "$repo" in
    *://*) repo="${repo#*://}" ;;
  esac
  case "$repo" in
    *@*) return 1 ;;   # credential-bearing URLs are never a kit source
  esac
  repo="${repo%%#*}"
  repo="${repo%%\?*}"
  repo="${repo%.git}"
  repo="${repo%/}"
  _acq_kit_source_repo_ok "$repo" || return 1
  printf '%s\n' "$repo"
}

# _acq_kit_source_parse_entry ENTRY SOURCE — normalize "repo[@REF][|DIR]" into
# "repo<TAB>ref<TAB>dir". REF may be empty (the source is then registered but
# unusable for fetching, which the reader reports as unpinned). DIR defaults to
# the neutral acq-kits path.
_acq_kit_source_parse_entry() {
  local entry="${1:-}" source="${2:-kit_sources}" rest repo ref="" dir=""
  [ -n "$entry" ] || return 1
  rest="$entry"
  case "$rest" in
    *'|'*) dir="${rest#*|}"; rest="${rest%%|*}" ;;
  esac
  case "$rest" in
    *'@'*) ref="${rest#*@}"; rest="${rest%%@*}" ;;
  esac
  if ! repo=$(_acq_kit_source_normalize_repo "$rest"); then
    echo "acq: ${source}: invalid kit source '$entry'" >&2
    echo "     want host/owner/repo[@REF][|DIR] (for example github.com/acme/kits@<sha>)" >&2
    return 1
  fi
  case "$ref" in
    *[!A-Za-z0-9_.-]*)
      echo "acq: ${source}: invalid ref '$ref' for '$repo'" >&2
      return 1
      ;;
  esac
  # An entry naming the shipped default source may omit @ref: it then follows the
  # shipped PATTERNS_KIT_REF, so a future pin bump keeps applying. Only an
  # explicit --ref freezes it.
  if [ -z "$ref" ] && [ "$repo" = "$ACQ_KIT_SOURCE_DEFAULT_REPO" ]; then
    ref="$ACQ_KIT_SOURCE_DEFAULT_REF"
  fi
  [ -n "$dir" ] || dir="$ACQ_KIT_SOURCE_DEFAULT_DIR"
  case "$dir" in
    /*|*..*|*[!A-Za-z0-9._/-]*)
      echo "acq: ${source}: unsafe kit dir '$dir' for '$repo'" >&2
      return 1
      ;;
  esac
  printf '%s|%s|%s\n' "$repo" "$ref" "$dir"
}

# _acq_kit_source_default_entry — the shipped default, as a registry ENTRY.
_acq_kit_source_default_entry() {
  printf '%s@%s|%s\n' \
    "$ACQ_KIT_SOURCE_DEFAULT_REPO" "$ACQ_KIT_SOURCE_DEFAULT_REF" "$ACQ_KIT_SOURCE_DEFAULT_DIR"
}

# acq_kit_sources_entries — echo one "repo<TAB>ref<TAB>dir" per trusted source.
# Precedence: ACQ_KIT_SOURCES (this invocation) > config.yaml > shipped default.
acq_kit_sources_entries() {
  local raw tokens=() token source_label
  if [ -n "${ACQ_KIT_SOURCES:-}" ]; then
    raw="$ACQ_KIT_SOURCES"
    source_label="ACQ_KIT_SOURCES"
  else
    raw=$(_acq_config_read_field "$ACQ_KIT_SOURCE_CONFIG_KEY")
    if [ -n "$raw" ]; then
      source_label="config.yaml ${ACQ_KIT_SOURCE_CONFIG_KEY}"
    else
      raw=$(_acq_kit_source_default_entry)
      source_label="default"
    fi
  fi
  # `none` is the explicit "no trusted sources" spelling: the flat config writer
  # removes a key when its value is empty, so absence cannot express it.
  case "$raw" in
    none|NONE|None) return 0 ;;
  esac
  split_noglob tokens "$raw"
  for token in ${tokens[@]+"${tokens[@]}"}; do
    _acq_kit_source_parse_entry "$token" "$source_label" || return 1
  done
  return 0
}

# _acq_kit_source_owner_prefix REPO — the host/owner/ prefix of host/owner/repo.
# Backends that allowlist by prefix (sbx) can only express owner granularity; acq's
# own trust decisions (below) stay at exact-repository granularity.
_acq_kit_source_owner_prefix() {
  local repo="${1:-}"
  printf '%s/%s/\n' "${repo%%/*}" "$(printf '%s' "${repo#*/}" | cut -d/ -f1)"
}

# acq_kit_source_prefixes [EXCLUDE_REPO] — the BACKEND allowlist (owner prefixes),
# derived from the registry; EXCLUDE_REPO is left out so a caller can ask what
# would REMAIN after removing it. ACQ_EXTRA_KIT_SOURCES (a list of host/owner/
# prefixes) still works as a backward-compatible ADDITION so existing setups keep
# fetching their kits.
acq_kit_source_prefixes() {
  local exclude="${1:-}" entries repo rest prefix seen=""
  entries=$(acq_kit_sources_entries) || return 1
  while IFS='|' read -r repo rest; do
    [ -n "$repo" ] || continue
    [ "$repo" != "$exclude" ] || continue
    prefix=$(_acq_kit_source_owner_prefix "$repo")
    case " $seen " in *" $prefix "*) continue ;; esac
    seen="$seen $prefix"
    printf '%s\n' "$prefix"
  done <<EOF
$entries
EOF
  local _extra=() _source
  if [ -n "${ACQ_EXTRA_KIT_SOURCES:-}" ]; then
    split_noglob _extra "$ACQ_EXTRA_KIT_SOURCES"
    for _source in ${_extra[@]+"${_extra[@]}"}; do
      [ -n "$_source" ] || continue
      printf '%s\n' "$_source"
    done
  fi
  return 0
}

# _acq_kit_source_entry_for_repo REPO — echo "repo<TAB>ref<TAB>dir" for a repo that
# is registered (exact host/owner/repo), or fail.
_acq_kit_source_entry_for_repo() {
  local wanted="${1:-}" repo ref dir
  [ -n "$wanted" ] || return 1
  while IFS='|' read -r repo ref dir; do
    [ -n "$repo" ] || continue
    [ "$repo" = "$wanted" ] || continue
    printf '%s|%s|%s\n' "$repo" "$ref" "$dir"
    return 0
  done <<EOF
$(acq_kit_sources_entries)
EOF
  # The pinned Patterns release is acq's CONTROL PLANE (validator + schemas), so
  # it stays resolvable even when the registry is overridden for one invocation
  # (ACQ_KIT_SOURCES) or emptied: the default provider kit must not vanish just
  # because an extra source was added for this run.
  if [ "$wanted" = "$ACQ_KIT_SOURCE_DEFAULT_REPO" ]; then
    printf '%s|%s|%s\n' \
      "$ACQ_KIT_SOURCE_DEFAULT_REPO" "$ACQ_KIT_SOURCE_DEFAULT_REF" "$ACQ_KIT_SOURCE_DEFAULT_DIR"
    return 0
  fi
  return 1
}

# _acq_kit_source_resolve_repo WANT — accept a full repo or a unique source
# basename ("agentic-coding-patterns") and echo the full repo.
_acq_kit_source_resolve_repo() {
  local want="${1:-}" repo ref dir found="" count=0
  [ -n "$want" ] || return 1
  # The shipped default source is the pinned control plane: always resolvable.
  if [ "$want" = "${ACQ_KIT_SOURCE_DEFAULT_REPO##*/}" ]; then
    printf '%s\n' "$ACQ_KIT_SOURCE_DEFAULT_REPO"
    return 0
  fi
  case "$want" in
    */*) _acq_kit_source_entry_for_repo "$want" >/dev/null || {
           echo "acq: kit source '$want' is not trusted." >&2
           echo "     Add it first: acq kit-source add $want --ref <sha>" >&2
           return 1
         }
         printf '%s\n' "$want"
         return 0
         ;;
  esac
  while IFS='|' read -r repo ref dir; do
    [ -n "$repo" ] || continue
    [ "${repo##*/}" = "$want" ] || continue
    count=$((count + 1))
    found="$repo"
  done <<EOF
$(acq_kit_sources_entries)
EOF
  if [ "$count" -eq 0 ]; then
    echo "acq: kit source name '$want' is not registered." >&2
    echo "     See: acq kit-source ls" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "acq: kit source name '$want' is ambiguous; use host/owner/repo." >&2
    echo "     See: acq kit-source ls" >&2
    return 1
  fi
  printf '%s\n' "$found"
}

# _acq_kit_source_kit_ref REPO REF DIR KIT — the git+https ref acq fetches.
# DIR "." means the kits live at the repository root (no kits subdirectory), in
# which case the ref points straight at the kit directory.
_acq_kit_source_kit_ref() {
  local repo="$1" ref="$2" dir="$3" kit="$4" path
  if [ "$dir" = "." ]; then
    path="$kit"
  else
    path="${dir}/${kit}"
  fi
  printf 'git+https://%s.git#ref=%s&dir=%s\n' "$repo" "$ref" "$path"
}

# _acq_kit_source_ref_trusted REF — a durable (config.yaml) literal remote kit
# ref is trusted only if it names EXACTLY one repository that is registered.
# Trusting github.com/acme/trusted must not authorize github.com/acme/other, so
# the comparison is on host/owner/repo, never on the owner prefix. A ref that
# cannot be reduced to one plain https repository (credentials, extra path
# segments, a non-https scheme, odd encoding) is refused. The only owner-wide
# grant is the explicit, legacy ACQ_EXTRA_KIT_SOURCES prefix list.
_acq_kit_source_ref_trusted() {
  local ref="${1:-}" body="" repo="" token _extra=()
  case "$ref" in
    git+https://*) body="${ref#git+https://}" ;;
  esac
  body="${body%%#*}"
  # The lenient normalizer (built for what a human pastes) must not be the
  # judge here: it strips through the LAST scheme separator, so a hostile
  # authority could hide in front of a trusted-looking path. Require the body
  # to already BE host/owner/repo[.git], byte for byte.
  case "$body" in
    *@*|*%*|*\?*|*://*|*:*|*//*|*/) body="" ;;
    *[!A-Za-z0-9._/-]*) body="" ;;
    */.|*/..|*/./*|*/../*) body="" ;;
  esac
  if [ -n "$body" ]; then
    repo=$(_acq_kit_source_normalize_repo "$body") || repo=""
    [ "$repo" = "${body%.git}" ] || repo=""
  fi
  if [ -n "$repo" ]; then
    if _acq_kit_source_entry_for_repo "$repo" >/dev/null; then
      return 0
    fi
    if [ -n "${ACQ_EXTRA_KIT_SOURCES:-}" ]; then
      split_noglob _extra "$ACQ_EXTRA_KIT_SOURCES"
      for token in ${_extra[@]+"${_extra[@]}"}; do
        case "$token" in
          */) case "$repo" in "$token"*) return 0 ;; esac ;;
        esac
      done
    fi
  fi
  echo "acq: provider_kit names an untrusted remote ref: $ref" >&2
  if [ -n "$repo" ]; then
    echo "     Trust its source first: acq kit-source add $repo --ref <sha>" >&2
  else
    echo "     It must name one https repository (host/owner/repo) that is trusted." >&2
  fi
  return 1
}

# acq_provider_kit_ref [VALUE] — resolve the default provider kit (config
# provider_kit, else ACQ_PROVIDER_KIT_DEFAULT) to a fetchable kit ref.
# Accepted forms: <kit>@<source>, <source>/<kit>, host/owner/repo/<kit>.
acq_provider_kit_ref() {
  local value="${1:-}" kit="" repo="" head
  local from_config=""
  if [ -z "$value" ]; then
    value=$(_acq_config_read_field "$ACQ_PROVIDER_KIT_CONFIG_KEY")
    [ -n "$value" ] || value="$ACQ_PROVIDER_KIT_DEFAULT"
    [ -z "$value" ] || from_config=1
  fi
  # A literal kit ref (local path or git+https) is used verbatim. A REMOTE ref
  # that comes from config.yaml is additionally held to the trusted-source
  # registry, per repository: a config file is durable state acq acts on
  # automatically, unlike a ref the user typed on this command line (--kit) or
  # the test seam.
  case "$value" in
    git+http*|/*|./*|../*)
      if [ -n "$from_config" ]; then
        case "$value" in
          git+http*) _acq_kit_source_ref_trusted "$value" || return 1 ;;
        esac
      fi
      printf '%s\n' "$value"
      return 0
      ;;
  esac
  case "$value" in
    *@*)
      kit="${value%@*}"
      repo="${value#*@}"
      ;;
    */*/*/*)
      repo=$(printf '%s' "$value" | cut -d/ -f1-3)
      kit=$(printf '%s' "$value" | cut -d/ -f4-)
      ;;
    */*)
      head="${value%%/*}"
      kit="${value#*/}"
      repo="$head"
      ;;
    *)
      kit="$value"
      ;;
  esac
  if [ -z "$kit" ]; then
    echo "acq: provider_kit '$value' does not name a kit." >&2
    return 1
  fi
  case "$kit" in
    *[!A-Za-z0-9._-]*)
      echo "acq: provider_kit '$value' has an unsafe kit name '$kit'." >&2
      return 1
      ;;
  esac
  if [ -z "$repo" ]; then
    repo=$(printf '%s' "$ACQ_PROVIDER_KIT_DEFAULT" | sed 's|/.*||')
  fi
  repo=$(_acq_kit_source_resolve_repo "$repo") || return 1
  local entry ref dir
  entry=$(_acq_kit_source_entry_for_repo "$repo") || {
    echo "acq: kit source '$repo' is not trusted." >&2
    return 1
  }
  ref=$(printf '%s' "$entry" | cut -d'|' -f2)
  dir=$(printf '%s' "$entry" | cut -d'|' -f3)
  if [ -z "$ref" ]; then
    echo "acq: kit source '$repo' has no pinned ref, so it cannot be fetched." >&2
    echo "     Re-add it with an explicit ref: acq kit-source add $repo --ref <sha>" >&2
    return 1
  fi
  _acq_kit_source_kit_ref "$repo" "$ref" "$dir" "$kit"
}

# _acq_kit_source_rewrite DROP_REPO [ADD_REPO ADD_REF ADD_DIR] — rewrite the flat
# kit_sources value: drop DROP_REPO, then append the ADD_* entry when given.
# Emits "added" or "updated" on stdout. Writes "none" when the result is empty,
# because the flat writer removes a key whose value is empty (absence would
# resurrect the shipped default).
_acq_kit_source_rewrite() {
  local drop="${1:-}" add_repo="${2:-}" add_ref="${3:-}" add_dir="${4:-}"
  local entries repo ref dir updated="" seen=0
  entries=$(acq_kit_sources_entries) || return 1
  while IFS='|' read -r repo ref dir; do
    [ -n "$repo" ] || continue
    if [ "$repo" = "$drop" ]; then
      seen=1
      continue
    fi
    # Emit the default source WITHOUT @ref when it still tracks the shipped pin,
    # so the entry stays dynamic across a PATTERNS_KIT_REF bump.
    if [ "$repo" = "$ACQ_KIT_SOURCE_DEFAULT_REPO" ] && [ "$ref" = "$ACQ_KIT_SOURCE_DEFAULT_REF" ]; then
      updated="${updated:+$updated }${repo}"
    else
      updated="${updated:+$updated }${repo}@${ref}"
    fi
    case "$dir" in
      ""|"$ACQ_KIT_SOURCE_DEFAULT_DIR") : ;;
      *) updated="${updated}|${dir}" ;;
    esac
  done <<EOF
$entries
EOF
  if [ -n "$add_repo" ]; then
    updated="${updated:+$updated }${add_repo}@${add_ref}"
    case "$add_dir" in
      ""|"$ACQ_KIT_SOURCE_DEFAULT_DIR") : ;;
      *) updated="${updated}|${add_dir}" ;;
    esac
  fi
  [ -n "$updated" ] || updated="none"
  _acq_config_write_field "$ACQ_KIT_SOURCE_CONFIG_KEY" "$updated" || return 1
  if [ "$seen" -eq 1 ] && [ -n "$add_repo" ]; then
    printf 'updated\n'
  elif [ -n "$add_repo" ]; then
    printf 'added\n'
  fi
  return 0
}

# acq_provider_kit_candidates — "value<TAB>label" per selectable provider kit:
# the shipped default first, then every provider kit discovered in a trusted
# source. Values are unambiguous `<host/owner/repo>/<kit>` so a stored
# `provider_kit:` never depends on a basename being unique.
acq_provider_kit_candidates() {
  local entries repo ref dir kits kit ksource kref seen
  printf '%s\t%s\n' "$ACQ_PROVIDER_KIT_DEFAULT" "$ACQ_PROVIDER_KIT_DEFAULT (shipped)"
  seen=" $ACQ_PROVIDER_KIT_DEFAULT "
  entries=$(acq_kit_sources_entries) || return 1
  while IFS='|' read -r repo ref dir; do
    [ -n "$repo" ] && [ -n "$ref" ] || continue
    kits=$(acq_kit_source_provider_kits "$repo" "$ref" "$dir")
    [ -n "$kits" ] || continue
    while IFS="$(printf '\t')" read -r kit ksource kref _; do
      [ -n "$kit" ] || continue
      case " $seen " in
        *" $ksource/$kit "*) continue ;;
      esac
      seen="$seen $ksource/$kit"
      printf '%s\t%s\n' "$ksource/$kit" "$ksource/$kit (@${kref})"
    done <<EOF
$kits
EOF
  done <<EOF
$entries
EOF
  return 0
}

# acq_kit_source_set REPO --ref REF [--dir DIR] — persist (or replace) one source.
acq_kit_source_set() {
  local repo_arg="${1:-}" ref="" dir="" arg repo summary
  if [ "$#" -ge 1 ]; then shift; fi
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --ref)
        [ "$#" -ge 2 ] || { echo "acq: kit-source add: --ref needs a value" >&2; return 1; }
        ref="$2"; shift 2
        ;;
      --dir)
        [ "$#" -ge 2 ] || { echo "acq: kit-source add: --dir needs a value" >&2; return 1; }
        dir="$2"; shift 2
        ;;
      *)
        echo "acq: kit-source add: unexpected argument '$arg'" >&2
        echo "     usage: acq kit-source add REPO --ref REF [--dir DIR]" >&2
        return 1
        ;;
    esac
  done
  repo=$(_acq_kit_source_normalize_repo "$repo_arg") || {
    echo "acq: kit-source add: invalid repository '$repo_arg'" >&2
    echo "     want host/owner/repo (for example github.com/acme/kits)" >&2
    return 1
  }
  if [ -z "$ref" ]; then
    echo "acq: kit-source add: --ref <sha> is required." >&2
    echo "     A trusted source is fetched at a pinned commit for reproducibility." >&2
    return 1
  fi
  [ -n "$dir" ] || dir="$ACQ_KIT_SOURCE_DEFAULT_DIR"
  # Validate the entry before persisting it (same rules the reader enforces).
  _acq_kit_source_parse_entry "${repo}@${ref}|${dir}" "kit-source add" >/dev/null || return 1
  summary=$(_acq_kit_source_rewrite "$repo" "$repo" "$ref" "$dir") || {
    echo "acq: kit-source add: could not write $(_acq_config_file)" >&2
    return 1
  }
  case "$summary" in
    updated) echo "acq: updated kit source '${repo}' (@${ref})." >&2 ;;
    *)       echo "acq: added kit source '${repo}' (@${ref})." >&2 ;;
  esac
  return 0
}

# acq_kit_source_rm REPO — drop one source (the shipped default included; with no
# sources left acq fetches nothing instead of silently reinstating it).
acq_kit_source_rm() {
  local repo_arg="${1:-}" repo summary
  if [ -z "$repo_arg" ]; then
    echo "acq: kit-source rm: missing repository" >&2
    echo "     usage: acq kit-source rm REPO" >&2
    return 1
  fi
  repo=$(_acq_kit_source_normalize_repo "$repo_arg") || {
    echo "acq: kit-source rm: invalid repository '$repo_arg'" >&2
    return 1
  }
  if ! _acq_kit_source_entry_for_repo "$repo" >/dev/null; then
    echo "acq: kit source '${repo}' is not registered." >&2
    return 1
  fi
  # Reconcile the BACKEND allowlist first. If it cannot be brought in line, stop
  # with the registry untouched: nothing is reported as removed, the source stays
  # listed, and re-running this command after fixing the backend retries cleanly.
  # (The reverse order would leave acq saying "removed" while the backend still
  # permits the whole owner.)
  if ! _acq_kit_source_revoke_in_backend "$repo"; then
    echo "acq: kit source '${repo}' was NOT removed (still registered)." >&2
    return 1
  fi
  summary=$(_acq_kit_source_rewrite "$repo") || {
    echo "acq: kit-source rm: could not write $(_acq_config_file)" >&2
    return 1
  }
  echo "acq: removed kit source '${repo}'." >&2
  return 0
}

# _acq_kit_source_revoke_in_backend REPO — ask the active backend (when it keeps
# its own source allowlist) to drop what no source remaining AFTER removing REPO
# needs. NO
# acq_backend_prepare: this is a config-only verb, and on msb a prepare can run
# `msb doctor --fix` (host mutation). acq_resolve_backend has already loaded the
# active adapter, so the hook exists when the backend implements one.
_acq_kit_source_revoke_in_backend() {
  command -v acq_backend_kit_source_revoked >/dev/null 2>&1 || return 0
  acq_backend_kit_source_revoked "$1"
}

# acq_kit_source_provider_kits ENTRY — list the provider kits a source publishes.
# Best-effort and OFFLINE-SAFE: a failed fetch yields nothing (callers say so)
# rather than failing the whole listing or a create.
acq_kit_source_provider_kits() {
  local repo="${1:-}" ref="${2:-}" dir="${3:-}" cache seed root kit manifest
  [ -n "$repo" ] && [ -n "$ref" ] && [ -n "$dir" ] || return 0
  command -v kit_translate_fetch >/dev/null 2>&1 || return 0
  seed=$(printf '%s@%s' "$repo" "$ref" | cksum 2>/dev/null | cut -d' ' -f1)
  cache="${XDG_CACHE_HOME:-${HOME:-}/.cache}/acq/kit-sources/${seed:-0}"
  root=$(kit_translate_fetch "git+https://${repo}.git#ref=${ref}&dir=${dir}" "$cache" 2>/dev/null) || {
    acq_debug "kit-source: could not fetch $repo@$ref for discovery"
    return 0
  }
  [ -d "$root" ] || return 0
  for manifest in "$root"/*/provider-input.json; do
    [ -f "$manifest" ] || continue
    kit="${manifest%/provider-input.json}"
    kit="${kit##*/}"
    printf '%s\t%s\t%s\t%s\n' "$kit" "$repo" "$ref" "$dir"
  done
  return 0
}

# acq_kit_source_ls — sources, their pinned state, and the provider kits each
# publishes (discovery is best-effort; see acq_kit_source_provider_kits).
acq_kit_source_ls() {
  local entries repo ref dir pinned kits kit ksource kref printed
  entries=$(acq_kit_sources_entries) || return 1
  printf '%-52s %-12s %s\n' SOURCE REF KITS-DIR
  while IFS='|' read -r repo ref dir; do
    [ -n "$repo" ] || continue
    if [ -n "$ref" ]; then pinned="$ref"; else pinned="<unpinned>"; fi
    printf '%-52s %-12s %s\n' "$repo" "$pinned" "$dir"
  done <<EOF
$entries
EOF
  echo ""
  echo "Provider kits published by these sources:"
  printed=0
  while IFS='|' read -r repo ref dir; do
    [ -n "$repo" ] && [ -n "$ref" ] || continue
    kits=$(acq_kit_source_provider_kits "$repo" "$ref" "$dir")
    [ -n "$kits" ] || continue
    while IFS="$(printf '\t')" read -r kit ksource kref _; do
      [ -n "$kit" ] || continue
      printed=1
      printf '  %-34s %s (@%s)\n' "$kit" "$ksource" "$kref"
    done <<EOF2
$kits
EOF2
  done <<EOF
$entries
EOF
  if [ "$printed" -eq 0 ]; then
    echo "  (none discovered — sources are unreachable, or publish no provider kits)"
  fi
  echo ""
  echo "Set the default provider kit via 'acq configure', or in config.yaml:"
  echo "  provider_kit: <source>/<kit>      # e.g. agentic-coding-patterns/${USAI_PROVIDER_KIT_NAME}"
  return 0
}

# ============================================================================
# Provider credential bindings + generic provider key injection
# ============================================================================
# A provider kit is DATA: it ships `provider-input.json` and, once the pinned
# validator accepts it, a materialized `facts.json` naming its providerId,
# keyEnv, host, modelsUrl, and apiProtocol. acq owns the registry that maps a
# providerId to BOTH the ENV var its credential arrives in AND the host(s) that
# credential may be sent to, so a provider kit hosted outside the pinned Patterns
# release (a user's own git+https repo) is injected with no provider-specific
# acq code — without turning "declare someone else's providerId" into a way to
# ship a stored credential to an attacker's host.
#
# The registry is a three-layer merge, highest precedence last:
#   1. the pinned Patterns `provider-credential-bindings.json` — the trust
#      anchor, and the table the pinned validator itself checks facts against;
#   2. config.yaml `provider_credential_bindings:` — durable, user-owned;
#   3. ACQ_PROVIDER_CREDENTIAL_BINDINGS — this invocation.
# A layer entry is "providerId=KEY_ENV" or "providerId=KEY_ENV@host[,host]".
# Malformed entries fail closed: a typo must never silently bind a different
# provider's credential or a different destination host.
ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY="provider_credential_bindings"

# Providers acq trusts BY DEFAULT, as data: `id|keyEnv|host`. The pinned
# Patterns release is acq's validation+source trust anchor, so its provider comes
# pre-pinned. A new provider is pinned explicitly with
# `acq provider-credential set <id> <KEY_ENV> --host <H>`.
# shellcheck disable=SC2034  # consumed by _acq_provider_trusted_default
ACQ_PROVIDER_TRUSTED_DEFAULTS="usai|${USAI_PROVIDER_KEY_ENV}|${USAI_PROVIDER_HOST}"

# Process-critical variables a provider credential must never occupy.
ACQ_PROVIDER_FORBIDDEN_KEY_ENVS="PATH IFS LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV HOME SHELLOPTS PS4 CDPATH TMPDIR"

# Facts published by a provider kit are untrusted input until validated: they
# reach an sh -c probe and a backend --secret binding. `ACQ_PROVIDER_BINDINGS_GENERATION`
# is an INTERNAL seam only — it is reset at load so an inherited environment
# variable cannot redirect which facts acq trusts. It is declared `local` in the
# create gate, so it never outlives that one call.
ACQ_PROVIDER_BINDINGS_GENERATION=""

# providerId grammar (shared with the validator's own provider naming rule).
_acq_provider_credential_id_ok() {
  case "${1:-}" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  # Bounded, lower-case, and never starting/ending with '-'.
  printf '%s' "$1" | LC_ALL=C grep -qE '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'
}

# KEY_ENV grammar: an upper-case environment variable name.
_acq_provider_credential_env_ok() {
  case "${1:-}" in
    '') return 1 ;;
  esac
  case " $ACQ_PROVIDER_FORBIDDEN_KEY_ENVS " in
    *" $1 "*) return 1 ;;
  esac
  printf '%s' "$1" | LC_ALL=C grep -qE '^[A-Z][A-Z0-9_]*$'
}

# _acq_provider_credential_env_owner KEY_ENV — echo the built-in service that
# owns KEY_ENV, or nothing. A provider may only reuse a reserved name when it IS
# that provider (e.g. providerId `usai` + USAI_API_KEY).
_acq_provider_credential_env_owner() {
  case "${1:-}" in
    USAI_API_KEY)          printf 'usai\n' ;;
    GITHUB_TOKEN|GH_TOKEN) printf 'github\n' ;;
    GITLAB_TOKEN)          printf 'gitlab\n' ;;
  esac
}

# _acq_provider_credential_host_ok HOST — one DNS name, lower-case, no port, no
# path, no wildcard, no wildcard-cert tricks (a leading dot or '*' is rejected).
_acq_provider_credential_host_ok() {
  local host="${1:-}"
  [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
  printf '%s' "$host" | LC_ALL=C grep -qE \
    '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
}

# _acq_provider_fact_strict_url_ok URL [HOST] — provider-KIT facts are stricter
# than the shared USAi facts contract: a kit may declare any host, so its models
# URL must also be free of shell metacharacters even though acq passes it as
# positional data (defense in depth), and it must stay on the declared host.
_acq_provider_fact_strict_url_ok() {
  local url="${1:-}" host="${2:-}"
  _acq_provider_fact_safe_url "$url" || return 1
  case "$url" in
    *'&'*|*'#'*|*';'*|*'|'*|*'`'*|*'$'*|*'"'*|*"'"*|*'('*|*')'*|*'<'*|*'>'*) return 1 ;;
  esac
  if [ -n "$host" ]; then
    case "$url" in
      "https://$host/"*|"https://$host"|"https://$host:443/"*) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# _acq_provider_credential_check_env OWNER PROVIDER_ID KEY_ENV — validate a
# KEY_ENV for a provider, including the reserved/forbidden name rules.
_acq_provider_credential_check_env() {
  local source="$1" provider_id="$2" key_env="$3" owner
  if ! _acq_provider_credential_env_ok "$key_env"; then
    echo "acq: ${source}: invalid KEY_ENV '$key_env' for provider '$provider_id'" >&2
    echo "     want an upper-case env var name (for example: OPENCODE_GO_API_KEY)" >&2
    return 1
  fi
  owner=$(_acq_provider_credential_env_owner "$key_env")
  if [ -n "$owner" ] && [ "$owner" != "$provider_id" ]; then
    echo "acq: ${source}: KEY_ENV '$key_env' belongs to the '$owner' service," >&2
    echo "     so provider '$provider_id' cannot claim it. Use a provider-specific name." >&2
    return 1
  fi
  return 0
}

# _acq_provider_credential_parse_pairs SOURCE PAIRS — normalize a
# whitespace-separated list of "<providerId>=<KEY_ENV>[@<host>[,<host>]]" into one
# entry per line, validating every field. Fails closed (rc 1, nothing on stdout)
# on a malformed token.
_acq_provider_credential_parse_pairs() {
  local source="$1" pairs="$2" tokens=() token provider_id rest key_env hosts hosts_out host IFS
  [ -n "$pairs" ] || return 0
  split_noglob tokens "$pairs"
  for token in ${tokens[@]+"${tokens[@]}"}; do
    case "$token" in
      *=*) ;;
      *)
        echo "acq: ${source}: expected '<providerId>=<KEY_ENV>', got '$token'" >&2
        return 1
        ;;
    esac
    provider_id="${token%%=*}"
    rest="${token#*=}"
    case "$rest" in
      *@*) key_env="${rest%%@*}"; hosts="${rest#*@}" ;;
      *)   key_env="$rest"; hosts="" ;;
    esac
    case "$key_env" in
      *@*|*=*)
        echo "acq: ${source}: '$token' has a malformed credential name" >&2
        return 1
        ;;
    esac
    if ! _acq_provider_credential_id_ok "$provider_id"; then
      echo "acq: ${source}: invalid provider id '$provider_id'" >&2
      echo "     want ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?\$ (for example: opencode-go)" >&2
      return 1
    fi
    _acq_provider_credential_check_env "$source" "$provider_id" "$key_env" || return 1
    hosts_out=""
    if [ -n "$hosts" ]; then
      IFS=','
      for host in $hosts; do
        if ! _acq_provider_credential_host_ok "$host"; then
          echo "acq: ${source}: invalid host '$host' for provider '$provider_id'" >&2
          echo "     want a bare DNS name such as models.example.gov (no scheme, port, or path)" >&2
          return 1
        fi
        hosts_out="${hosts_out:+$hosts_out,}$host"
      done
    fi
    if [ -n "$hosts_out" ]; then
      printf '%s=%s@%s\n' "$provider_id" "$key_env" "$hosts_out"
    else
      printf '%s=%s\n' "$provider_id" "$key_env"
    fi
  done
  return 0
}

# acq_provider_credential_overrides — echo the CONFIG then ENV layers as
# normalized entries (lowest first). The pinned base layer is merged where it is
# actually available (acq_provider_input_prepare, which already fetched the
# pinned release), so this stays offline and cheap.
acq_provider_credential_overrides() {
  local configured
  configured=$(_acq_config_read_field "$ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY")
  _acq_provider_credential_parse_pairs "config.yaml ${ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY}" "$configured" || return 1
  _acq_provider_credential_parse_pairs "ACQ_PROVIDER_CREDENTIAL_BINDINGS" \
    "${ACQ_PROVIDER_CREDENTIAL_BINDINGS:-}" || return 1
}

# _acq_provider_credential_field ENTRY FIELD — read id|env|hosts out of one
# normalized entry ("id=ENV[@hosts]").
_acq_provider_credential_field() {
  local entry="$1" field="$2" rest
  case "$field" in
    id)  printf '%s' "${entry%%=*}" ;;
    env) rest="${entry#*=}"; printf '%s' "${rest%%@*}" ;;
    hosts)
      case "$entry" in
        *@*) printf '%s' "${entry#*@}" ;;
        *)   printf '' ;;
      esac
      ;;
  esac
}

# acq_provider_credential_lookup PROVIDER_ID FIELD — echo id|env|hosts for the
# highest-precedence entry naming PROVIDER_ID (ENV overrides CONFIG).
acq_provider_credential_lookup() {
  local wanted="${1:-}" field="${2:-}" pairs entry found=""
  [ -n "$wanted" ] || return 0
  # A malformed durable pin is an error, not a reason to fall back to a host a
  # kit chose: the caller can only honour the registry if it is well formed.
  pairs=$(acq_provider_credential_overrides) || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$(_acq_provider_credential_field "$entry" id)" = "$wanted" ] || continue
    found="$entry"
  done <<EOF
$pairs
EOF
  [ -n "$found" ] || {
    # Not configured by the user: fall back to the shipped trust anchor so the
    # DEFAULT provider needs no per-install configuration. A miss here is "no
    # pin", not an error — the facts may still name the provider (validated by
    # the pinned validator), and the gate decides whether a host is trusted.
    _acq_provider_trusted_default "$wanted" "$field" || return 0
    return 0
  }
  _acq_provider_credential_field "$found" "$field"
}

acq_provider_credential_key_env() {
  acq_provider_credential_lookup "${1:-}" env
}

# _acq_provider_trusted_default PROVIDER_ID FIELD — read a provider out of the
# shipped trust-anchor table (`id|keyEnv|host`). This is why the DEFAULT provider
# needs no configuration: its (keyEnv, host) pair is data, not a code branch.
_acq_provider_trusted_default() {
  local wanted="${1:-}" field="${2:-}" id key_env hosts
  [ -n "$wanted" ] || return 1
  while IFS='|' read -r id key_env hosts; do
    [ "$id" = "$wanted" ] || continue
    case "$field" in
      id)    printf '%s\n' "$id" ;;
      env)   printf '%s\n' "$key_env" ;;
      hosts) printf '%s\n' "$hosts" ;;
      *)     return 1 ;;
    esac
    return 0
  done <<EOF
$ACQ_PROVIDER_TRUSTED_DEFAULTS
EOF
  return 1
}

# True when at least one provider kit is selected. `--no-provider-kits` (or an
# explicit empty ACQ_PROVIDER_KITS) disables every provider, trusted default
# included — so no credential is bound and no prompt is shown.
acq_provider_selection_active() {
  if [ -n "${ACQ_PROVIDER_KITS_FROM_ENV:-}" ] || [ -n "${ACQ_PROVIDER_KITS_FROM_CLI:-}" ]; then
    [ -n "${ACQ_PROVIDER_KITS:-}" ] || return 1
  fi
  return 0
}

# acq_provider_trusted_ids — the provider ids shipped in the trust anchor.
# Selection-independent (used by `acq secret import`/managed-service checks).
acq_provider_trusted_ids() {
  local id rest
  while IFS='|' read -r id rest; do
    [ -n "$id" ] && printf '%s\n' "$id"
  done <<EOF
$ACQ_PROVIDER_TRUSTED_DEFAULTS
EOF
  return 0
}

# acq_provider_default_selected — 0 when the DEFAULT provider kit is among the
# selected provider refs. Guards the trust anchor so an external-provider-only
# selection does not bind/export the default provider's credential.
acq_provider_default_selected() {
  local refs default_ref ref
  refs=$(_acq_selected_provider_kit_refs) || return 1
  default_ref=$(acq_provider_kit_ref) || return 1
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ "$ref" = "$default_ref" ] && return 0
  done <<EOF
$refs
EOF
  return 1
}

# acq_provider_default_id — the id of the shipped default provider (the first
# entry of the trust-anchor table), used where a facts-free fallback needs to name
# "the default provider" without hardcoding `usai`.
acq_provider_default_id() {
  local id rest
  [ -n "$ACQ_PROVIDER_TRUSTED_DEFAULTS" ] || return 1
  IFS='|' read -r id rest <<EOF
$ACQ_PROVIDER_TRUSTED_DEFAULTS
EOF
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

acq_provider_credential_hosts() {
  acq_provider_credential_lookup "${1:-}" hosts
}

# acq_provider_credential_merge_json BASE OUT PYTHON — write the three-layer
# merge to OUT. BASE is the pinned patterns registry (read-only trust anchor),
# OUT is a temp file the caller cleans up with its staging dir. The document stays
# in the shape the pinned validator expects (`providers[providerId]` = ENV), so a
# richer trust anchor keeps working but the validator never sees acq's own host
# pins: those are enforced at injection time, not by the schema.
acq_provider_credential_merge_json() {
  local base="$1" out="$2" python="$3" overrides
  [ -n "$base" ] && [ -n "$out" ] && [ -n "$python" ] || return 1
  overrides=$(acq_provider_credential_overrides) || return 1
  # shellcheck disable=SC2086  # validated entries; word splitting is the framing
  "$python" - "$base" "$out" $overrides <<'PY'
import json, os, sys

base_path, out_path = sys.argv[1], sys.argv[2]
entries = sys.argv[3:]

try:
    with open(base_path, encoding="utf-8") as handle:
        document = json.load(handle)
except Exception as exc:  # a malformed trust anchor is fatal, never ignored
    raise SystemExit(
        "acq: cannot read pinned provider credential bindings %s: %s" % (base_path, exc)
    )

if not isinstance(document, dict):
    raise SystemExit("acq: pinned provider credential bindings must be a JSON object")

providers = document.get("providers")
if providers is None:
    providers = {}
if not isinstance(providers, dict):
    raise SystemExit("acq: pinned provider credential bindings 'providers' must be an object")

for entry in entries:
    provider_id, _, rest = entry.partition("=")
    key_env = rest.partition("@")[0]
    current = providers.get(provider_id)
    if isinstance(current, dict):
        merged = dict(current)
        merged["keyEnv"] = key_env
        providers[provider_id] = merged
    else:
        providers[provider_id] = key_env

document["providers"] = providers
temporary = out_path + ".tmp"
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, out_path)
PY
}

# acq_provider_credential_set PROVIDER_ID KEY_ENV [--host HOST[,HOST]] — persist
# one binding. The host is REQUIRED: it is the trust decision that lets acq send
# a stored credential to that destination, so it must be explicit rather than
# inherited from whatever a kit happens to declare.
acq_provider_credential_set() {
  local provider_id="${1:-}" key_env="${2:-}" hosts="" arg configured existing line updated=""
  if [ "$#" -ge 2 ]; then shift 2; else set --; fi
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --host)
        [ "$#" -ge 2 ] || {
          echo "acq: provider-credential set: --host needs a value" >&2
          return 1
        }
        hosts="${hosts:+$hosts,}$2"
        shift 2
        ;;
      --host=*)
        hosts="${hosts:+$hosts,}${arg#--host=}"
        shift
        ;;
      *)
        echo "acq: provider-credential set: unexpected argument '$arg'" >&2
        echo "     usage: acq provider-credential set PROVIDER KEY_ENV --host HOST[,HOST]" >&2
        return 1
        ;;
    esac
  done
  if ! _acq_provider_credential_id_ok "$provider_id"; then
    echo "acq: provider-credential set: invalid provider id '${provider_id}'" >&2
    echo "     want ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?\$ (for example: opencode-go)" >&2
    return 1
  fi
  _acq_provider_credential_check_env "provider-credential set" "$provider_id" "$key_env" || return 1
  if [ -z "$hosts" ]; then
    echo "acq: provider-credential set: a --host is required." >&2
    echo "     The host is the trust decision that lets acq send this credential" >&2
    echo "     to a destination, so acq never infers it from a kit's facts." >&2
    echo "     usage: acq provider-credential set $provider_id $key_env --host models.example.gov" >&2
    return 1
  fi
  configured=$(_acq_config_read_field "$ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY")
  existing=$(_acq_provider_credential_parse_pairs \
    "config.yaml ${ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY}" "$configured") || {
    echo "acq: provider-credential set: refusing to rewrite a malformed" >&2
    echo "     ${ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY} entry in $(_acq_config_file)" >&2
    echo "     Fix that line by hand, then retry." >&2
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "${provider_id}="*) continue ;;
    esac
    updated="${updated:+$updated }$line"
  done <<EOF
$existing
EOF
  updated="${updated:+$updated }${provider_id}=${key_env}@${hosts}"
  # Re-parse our own candidate so a bad --host value fails before it is written.
  _acq_provider_credential_parse_pairs "provider-credential set" "$updated" >/dev/null || return 1
  if ! _acq_config_write_field "$ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY" "$updated"; then
    echo "acq: provider-credential set: could not write $(_acq_config_file)" >&2
    return 1
  fi
  echo "acq: bound provider '${provider_id}' to \$${key_env} for host(s) ${hosts}." >&2
  return 0
}

# acq_provider_credential_rm PROVIDER_ID — drop the config.yaml binding. The
# ENV layer is per-invocation, so it cannot be removed durably (and saying so is
# more useful than silently reporting success).
acq_provider_credential_rm() {
  local provider_id="${1:-}" configured existing line updated="" removed=0
  if ! _acq_provider_credential_id_ok "$provider_id"; then
    echo "acq: provider-credential rm: invalid provider id '${provider_id}'" >&2
    return 1
  fi
  configured=$(_acq_config_read_field "$ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY")
  existing=$(_acq_provider_credential_parse_pairs \
    "config.yaml ${ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY}" "$configured") || {
    echo "acq: provider-credential rm: refusing to rewrite a malformed" >&2
    echo "     ${ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY} entry in $(_acq_config_file)" >&2
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "${provider_id}="*) removed=1; continue ;;
    esac
    updated="${updated:+$updated }$line"
  done <<EOF
$existing
EOF
  if [ "$removed" -eq 0 ]; then
    echo "acq: no config.yaml binding for provider '${provider_id}'." >&2
    echo "     (An ACQ_PROVIDER_CREDENTIAL_BINDINGS entry is per-invocation only.)" >&2
    return 1
  fi
  _acq_config_write_field "$ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY" "$updated" || {
    echo "acq: provider-credential rm: could not write $(_acq_config_file)" >&2
    return 1
  }
  echo "acq: removed the '${provider_id}' binding from $(_acq_config_file)." >&2
  return 0
}

# acq_provider_credential_ls — list the USER-owned layers (config, env) with the
# host each credential may be sent to. The pinned defaults still apply underneath
# and are named in the footer rather than fetched, so `ls` never needs network.
acq_provider_credential_ls() {
  local configured from_config from_env printed
  configured=$(_acq_config_read_field "$ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY")
  from_config=$(_acq_provider_credential_parse_pairs \
    "config.yaml ${ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY}" "$configured") || return 1
  from_env=$(_acq_provider_credential_parse_pairs \
    "ACQ_PROVIDER_CREDENTIAL_BINDINGS" "${ACQ_PROVIDER_CREDENTIAL_BINDINGS:-}") || return 1
  printf '%-24s %-32s %-32s %s\n' PROVIDER KEY_ENV HOST SOURCE
  printed=0
  if [ -n "$from_config" ]; then
    _acq_provider_credential_ls_rows "$from_config" "config.yaml" && printed=1
  fi
  if [ -n "$from_env" ]; then
    _acq_provider_credential_ls_rows "$from_env" "env" && printed=1
  fi
  [ "$printed" -eq 1 ] || printf '%-24s %-32s %-32s %s\n' '(none)' '-' '-' '-'
  echo ""
  echo "HOST is the pinned destination: acq refuses to send a stored credential"
  echo "anywhere else. 'acq secret set -g <providerId>' stores the value itself."
  return 0
}

# _acq_provider_credential_ls_rows ENTRIES SOURCE — print table rows directly on
# stdout (never captured into a variable, which would strip the final newline and
# glue the config block onto the env block).
_acq_provider_credential_ls_rows() {
  local entries="$1" source="$2" line hosts
  [ -n "$entries" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    hosts=$(_acq_provider_credential_field "$line" hosts)
    printf '%-24s %-32s %-32s %s\n' \
      "$(_acq_provider_credential_field "$line" id)" \
      "$(_acq_provider_credential_field "$line" env)" \
      "${hosts:-<unpinned>}" "$source"
  done <<EOF
$entries
EOF
}

# _acq_provider_env_value NAME — echo the value of the environment variable NAME
# WITHOUT eval. Bash 3.2's indirect expansion has no default-operator form, so the
# nounset guard is toggled explicitly (the same save/restore idiom split_noglob
# uses for noglob). NAME must be an identifier: it is passed to `${!name}`, never
# into program text.
_acq_provider_env_value() {
  local name="${1:-}" had_u=0 value=""
  case "$name" in
    ''|*[!A-Za-z0-9_]*) return 0 ;;
  esac
  case "$-" in *u*) had_u=1 ;; esac
  set +u
  value="${!name}"
  if [ "$had_u" -eq 1 ]; then set -u; fi
  printf '%s' "$value"
}

# _acq_provider_credentials_validate_records RECORDS — validate the facts copied
# into a sandbox's host-config `provider-credentials` record. Host config is
# acq-owned but still on disk, and its fields reach eval-free exports, backend
# argv, and a curl probe, so every field is re-checked before use.
_acq_provider_credentials_validate_records() {
  local records="${1:-}" tab provider_id key_env host models_url api_protocol
  local IFS
  [ -n "$records" ] || return 0
  tab=$(printf '\t')
  while IFS="$tab" read -r provider_id key_env host models_url api_protocol; do
    [ -n "$provider_id" ] || continue
    _acq_provider_credential_id_ok "$provider_id" || return 1
    _acq_provider_credential_env_ok "$key_env" || return 1
    _acq_provider_credential_host_ok "$host" || return 1
    _acq_provider_fact_strict_url_ok "$models_url" "$host" || return 1
    case "$api_protocol" in
      ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done <<EOF
$records
EOF
  return 0
}

# acq_provider_recorded_facts BACKEND NAME — the sandbox's recorded facts, after
# validation. Fails closed: a tampered or half-written record is never parsed into
# a credential binding.
acq_provider_recorded_facts() {
  local backend="${1:-}" name="${2:-}" records
  [ -n "$backend" ] && [ -n "$name" ] || return 0
  records=$(acq_host_config_read "$backend" "$name" provider-credentials)
  [ -n "$records" ] || return 0
  _acq_provider_credentials_validate_records "$records" || {
    echo "acq: invalid provider-credentials record for $backend/$name (host config)." >&2
    echo "     Refusing to use it; recreate the sandbox to re-record provider facts." >&2
    return 1
  }
  printf '%s\n' "$records"
}

# _acq_provider_facts_python — resolve a Python runtime for reading facts.json
# WITHOUT bootstrapping the validator (facts are read on hot paths). Honors
# ACQ_PROVIDER_INPUT_PYTHON and the installed validator runtime first, so
# Windows (`Scripts/python.exe`) and custom interpreters work; only then PATH.
_acq_provider_facts_python() {
  local python="${ACQ_PROVIDER_INPUT_PYTHON:-}" runtime data_home
  if [ -n "$python" ] && [ -x "$python" ]; then
    printf '%s\n' "$python"
    return 0
  fi
  if [ -n "${LOCALAPPDATA:-}" ] && [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
    data_home="$LOCALAPPDATA/acq"
  else
    data_home="${XDG_DATA_HOME:-${HOME:-}/.local/share}/acq"
  fi
  runtime="${ACQ_PROVIDER_INPUT_DATA_DIR:-$data_home/provider-input-validator}.current"
  if [ -x "$runtime/bin/python3" ]; then
    printf '%s\n' "$runtime/bin/python3"
    return 0
  fi
  if [ -x "$runtime/Scripts/python.exe" ]; then
    printf '%s\n' "$runtime/Scripts/python.exe"
    return 0
  fi
  if [ -x "$runtime/python.exe" ]; then
    printf '%s\n' "$runtime/python.exe"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "python3"
    return 0
  fi
  return 1
}

# acq_provider_facts_json_fields FILE — echo one TAB-separated record:
#   providerId<TAB>keyEnv<TAB>host<TAB>modelsUrl<TAB>apiProtocol
# rc 1 when FILE is absent (no provider facts to read), 2 when it is present but
# not a usable facts document (including "no Python runtime available"). Every
# value is re-validated after parsing: these values reach an sh -c probe and a
# --secret binding, so a tampered facts.json must not be able to smuggle shell
# syntax, a cross-host models URL, or an unsafe ENV name any further.
acq_provider_facts_json_fields() {
  local file="${1:-}" python value provider_id="" key_env="" host="" models_url="" api_protocol="" count=0
  [ -n "$file" ] || return 2
  { [ -f "$file" ] && [ ! -L "$file" ]; } || return 1
  python=$(_acq_provider_facts_python) || {
    echo "acq: no Python runtime available to read provider facts ($file)." >&2
    echo "     Set ACQ_PROVIDER_INPUT_PYTHON or install the validator runtime:" >&2
    echo "       scripts/setup-provider-input-validator --apply" >&2
    return 2
  }
  while IFS= read -r value; do
    count=$((count + 1))
    case "$count" in
      1) provider_id="$value" ;;
      2) key_env="$value" ;;
      3) host="$value" ;;
      4) models_url="$value" ;;
      5) api_protocol="$value" ;;
    esac
  done < <("$python" - "$file" <<'PY'
import json, sys
from urllib.parse import urlsplit

# Windows Python translates print()'s "\n" to CRLF when stdout is a pipe, and
# the shell `read` below then keeps the trailing "\r", corrupting each value.
# Force LF so the values arrive clean on every host.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n")

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        facts = json.load(handle)
except Exception:
    raise SystemExit(2)
if not isinstance(facts, dict):
    raise SystemExit(2)
values = {}
for name in ("providerId", "keyEnv", "host", "modelsUrl", "apiProtocol"):
    value = facts.get(name)
    if not isinstance(value, str) or not value:
        raise SystemExit(2)
    if any(character in value for character in "\t\n\r"):
        raise SystemExit(2)
    values[name] = value
# The credential is only ever sent to facts.host, so a models URL naming any
# other host (or a non-https scheme) is a mismatch, not a warning.
parsed = urlsplit(values["modelsUrl"])
if parsed.scheme != "https" or parsed.hostname != values["host"]:
    raise SystemExit(2)
if parsed.port not in (None, 443):
    raise SystemExit(2)
for value in values.values():
    print(value)
PY
  )
  [ "$count" -eq 5 ] || return 2
  _acq_provider_credential_id_ok "$provider_id" || return 2
  _acq_provider_credential_env_ok "$key_env" || return 2
  _acq_provider_credential_host_ok "$host" || return 2
  _acq_provider_fact_strict_url_ok "$models_url" "$host" || return 2
  case "$api_protocol" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$provider_id" "$key_env" "$host" "$models_url" "$api_protocol"
}

# acq_provider_facts_list_generation GENERATION — one validated facts record per
# provider directory of a materialized generation. FAILS CLOSED (non-zero) on the
# first record that does not validate: the generation was gated by the pinned
# validator, so anything unreadable now means tampering, not "no providers".
acq_provider_facts_list_generation() {
  local generation="${1:-}" providers_dir record
  [ -n "$generation" ] || return 0
  providers_dir="$generation/models/providers"
  [ -d "$providers_dir" ] || return 0
  for record in "$providers_dir"/*/facts.json; do
    [ -e "$record" ] || continue
    acq_provider_facts_json_fields "$record" || {
      echo "acq: invalid provider facts: $record" >&2
      return 1
    }
  done
  return 0
}

# acq_provider_credentials_write BACKEND NAME GENERATION — record the injected
# provider credentials (providerId, keyEnv, host, modelsUrl) in the sandbox's
# HOST config. Resume/heal then re-inject the identical bindings without reading
# a generation a later create may have replaced, and without re-prompting.
# Called only AFTER the gate succeeds, and best-effort (fail-open) like the
# provenance/cli-kits records.
acq_provider_credentials_write() {
  local backend="${1:-}" name="${2:-}" generation="${3:-}" records
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  records=$(acq_provider_facts_list_generation "$generation") || return 1
  if [ -z "$records" ]; then
    acq_debug "provider-credentials: no provider facts to record for $backend/$name"
    return 0
  fi
  acq_host_config_write "$backend" "$name" provider-credentials "$records"
}

# acq_provider_recorded_host BACKEND NAME PROVIDER_ID — the host recorded for a
# provider at create time (empty when nothing is recorded). Reads through
# acq_provider_recorded_facts, so a tampered record is rejected, not parsed.
acq_provider_recorded_host() {
  local backend="${1:-}" name="${2:-}" wanted="${3:-}" tab provider_id key_env host rest records
  [ -n "$wanted" ] || return 0
  records=$(acq_provider_recorded_facts "$backend" "$name") || return 1
  [ -n "$records" ] || return 0
  tab=$(printf '\t')
  while IFS="$tab" read -r provider_id key_env host rest; do
    [ -n "$provider_id" ] || continue
    [ "$provider_id" = "$wanted" ] || continue
    printf '%s\n' "$host"
    return 0
  done <<EOF
$records
EOF
  return 0
}

# acq_provider_sandbox_facts BACKEND NAME — the facts acq should act on for this
# sandbox: the generation being created (internal, create-time only), else the
# published generation, else the recorded host-config copy. Fails closed when a
# facts document exists but does not validate.
acq_provider_sandbox_facts() {
  local backend="${1:-}" name="${2:-}" generation="$ACQ_PROVIDER_BINDINGS_GENERATION" root
  if [ -n "$generation" ] && [ -d "$generation" ]; then
    acq_provider_facts_list_generation "$generation" || return 1
    return 0
  fi
  [ -n "$backend" ] && [ -n "$name" ] || return 0
  root=$(acq_provider_input_root "$backend" "$name") || return 0
  if [ -e "$root/current" ]; then
    acq_provider_facts_list_generation "$root/current" || return 1
    return 0
  fi
  acq_provider_recorded_facts "$backend" "$name"
}

# acq_provider_sandbox_provider_ids BACKEND NAME — the provider ids this sandbox
# has facts for, one per line. Fails closed on invalid facts.
acq_provider_sandbox_provider_ids() {
  local backend="${1:-}" name="${2:-}" facts tab provider_id rest
  facts=$(acq_provider_sandbox_facts "$backend" "$name") || return 1
  tab=$(printf '\t')
  while IFS="$tab" read -r provider_id rest; do
    [ -n "$provider_id" ] && printf '%s\n' "$provider_id"
  done <<EOF
$facts
EOF
  # An empty facts set is "no providers", not a failure: the loop's last command
  # is the `[ -n ]` test, which would otherwise leak status 1 to the caller.
  return 0
}

# acq_provider_registry_ids — provider ids bound in the config/env layers, plus
# the shipped trust anchor (so the default provider participates like any other).
# Empty when provider selection is explicitly off (`--no-provider-kits`).
acq_provider_registry_ids() {
  local pairs line id
  acq_provider_selection_active || return 0
  pairs=$(acq_provider_credential_overrides 2>/dev/null) || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "${line%%=*}"
  done <<EOF
$pairs
EOF
  # The trust anchor participates only when its provider is actually selected.
  if acq_provider_default_selected; then
    acq_provider_trusted_ids
  fi
  return 0
}

# acq_provider_delivery_ids NAME — every provider id acq should inject for this
# sandbox: the registry (a provider whose kit is new has no facts yet) unioned
# with the sandbox's materialized/recorded facts.
acq_provider_delivery_ids() {
  local name="${1:-}" backend="${2:-${ACQ_RESOLVED_BACKEND:-}}" facts_ids
  facts_ids=""
  if [ -n "$name" ]; then
    facts_ids=$(acq_provider_sandbox_provider_ids "$backend" "$name") || return 1
  fi
  {
    acq_provider_registry_ids
    printf '%s\n' "$facts_ids"
  } 2>/dev/null | awk 'NF && !seen[$0]++'
}

# acq_provider_binding BACKEND NAME PROVIDER_ID — echo "host<TAB>keyEnv<TAB>modelsUrl".
# The REGISTRY is authoritative for keyEnv (so a config/env override changes what
# is injected, not just what `ls` prints); facts supply host and modelsUrl. A
# registered host may stand in when no facts exist yet (a standalone
# `acq secret set`), in which case modelsUrl is empty.
acq_provider_binding() {
  local backend="${1:-}" name="${2:-}" wanted="${3:-}" tab provider_id facts_key_env host models_url api_protocol
  local key_env registry_hosts facts
  [ -n "$wanted" ] || return 1
  key_env=$(acq_provider_credential_key_env "$wanted") || return 1
  registry_hosts=$(acq_provider_credential_hosts "$wanted") || return 1
  tab=$(printf '\t')
  facts=$(acq_provider_sandbox_facts "$backend" "$name") || return 1
  while IFS="$tab" read -r provider_id facts_key_env host models_url api_protocol; do
    [ -n "$provider_id" ] || continue
    [ "$provider_id" = "$wanted" ] || continue
    [ -n "$key_env" ] || key_env="$facts_key_env"
    printf '%s\t%s\t%s\n' "$host" "$key_env" "$models_url"
    return 0
  done <<EOF
$facts
EOF
  [ -n "$registry_hosts" ] || return 1
  # Bind EVERY pinned host (both backends accept a comma-separated host list), so
  # the destination `provider-credential ls` prints is exactly what gets bound.
  printf '%s\t%s\t%s\n' "$registry_hosts" "$key_env" ""
}

# _acq_provider_is_host_service ID — 0 for the ids BOTH backends bind from
# compiled-in tables (`github` only). A host service's token must never be
# resolved from kit-supplied facts, probed at a kit-chosen host, or bound there:
# the gate skips it, and so must every later stage (see
# ensure_valid_provider_keys / check_provider_key).
_acq_provider_is_host_service() {
  case "${1:-}" in
    github) return 0 ;;
  esac
  return 1
}

# acq_provider_binding_host_env SERVICE [SANDBOX] — echo "host<TAB>keyEnv" for a
# provider service, the pair the backend adapters bind at create time. The
# sandbox is passed EXPLICITLY: resume and `acq secret rm` resolve it for an
# existing sandbox, where no create-time ambient state exists.
acq_provider_binding_host_env() {
  local service="${1:-}" sandbox="${2:-}" binding
  [ -n "$service" ] || return 1
  binding=$(acq_provider_binding "${ACQ_RESOLVED_BACKEND:-}" "$sandbox" "$service" 2>/dev/null) || return 1
  printf '%s\n' "$binding" | cut -f1-2
}

# _acq_provider_credentials_gate_trust BACKEND NAME PROVIDER_ID HOST — the trust
# check that makes providerId spoofing useless. A kit may declare any providerId
# it likes (and allow-list the host), so before acq binds a stored credential it
# requires the destination host to be pinned for that providerId, either in the
# acq-owned registry or in this sandbox's recorded credentials.
_acq_provider_credentials_gate_trust() {
  local backend="$1" name="$2" provider_id="$3" host="$4" pinned recorded
  pinned=$(acq_provider_credential_hosts "$provider_id")
  if [ -n "$pinned" ]; then
    case ",$pinned," in
      *",$host,"*) return 0 ;;
    esac
    echo "acq: provider '$provider_id' declares host '$host', which is not one of" >&2
    echo "     its pinned hosts (${pinned}). Refusing to send the stored credential there." >&2
    echo "     If that host is legitimate, re-pin it explicitly:" >&2
    echo "       acq provider-credential set $provider_id <KEY_ENV> --host $host" >&2
    return 1
  fi
  recorded=$(acq_provider_recorded_host "$backend" "$name" "$provider_id") || return 1
  if [ -n "$recorded" ]; then
    if [ "$recorded" = "$host" ]; then
      return 0
    fi
    echo "acq: provider '$provider_id' host changed for sandbox '$name':" >&2
    echo "     recorded '$recorded', kit now declares '$host'." >&2
    echo "     Refusing to silently move your credential. Re-pin the new host:" >&2
    echo "       acq provider-credential set $provider_id <KEY_ENV> --host $host" >&2
    return 1
  fi
  echo "acq: provider '$provider_id' is not pinned to a host yet (kit declares '$host')." >&2
  echo "     acq will not send a stored credential to a host chosen by the kit." >&2
  echo "     Pin it explicitly, then re-run:" >&2
  echo "       acq provider-credential set $provider_id <KEY_ENV> --host $host" >&2
  return 1
}

# _acq_provider_credentials_gate_one BACKEND NAME PROVIDER_ID KEY_ENV HOST — make
# sure one provider's credential is storable and injectable before the create.
_acq_provider_credentials_gate_one() {
  local backend="$1" name="$2" provider_id="$3" key_env="$4" host="$5" answer="" exported="" stored=0
  # An sbx compiled-in vendor service would silently use its own endpoint instead
  # of facts.host, so a provider must not shadow one.
  if [ "$backend" = "sbx" ]; then
    case " ${_ACQ_SBX_BUILTIN_SERVICES:-} " in
      *" $provider_id "*)
        echo "acq: provider id '$provider_id' collides with an sbx built-in service," >&2
        echo "     which would bind to sbx's own vendor endpoint instead of '$host'." >&2
        echo "     Rename the provider in its kit (provider-input.json)." >&2
        return 1
        ;;
    esac
  fi
  command -v acq_secret_has >/dev/null 2>&1 || return 0
  if acq_secret_has "$provider_id" "$name"; then
    acq_key_injectable "$provider_id" "$name" && return 0
    stored=1
    echo "acq: the '$provider_id' key is stored, but the active backend cannot" >&2
    echo "     inject it for '$host' yet." >&2
  fi
  # A host-exported value (CI) is bindable only where the backend reads host env
  # at create. sbx snapshots its own proxy table, so claiming success there would
  # create a sandbox with a dead credential.
  exported=$(_acq_provider_env_value "$key_env")
  if [ -n "$exported" ]; then
    case "$backend" in
      msb) return 0 ;;
      *)
        echo "acq: \$${key_env} is exported on the host, but the '$backend' backend" >&2
        echo "     cannot bind a credential from host env at create. Store it instead:" >&2
        echo "       acq secret set -g $provider_id" >&2
        return 1
        ;;
    esac
  fi
  if [ ! -t 0 ]; then
    if [ "$stored" -eq 1 ]; then
      echo "acq: no injectable key for provider '$provider_id' (\$${key_env})." >&2
      echo "     Re-store it from a terminal so the binding is created:" >&2
    else
      echo "acq: no key stored for provider '$provider_id' (\$${key_env})." >&2
      echo "     Set one with:" >&2
    fi
    echo "       acq secret set -g $provider_id" >&2
    return 1
  fi
  echo >&2
  if [ "$stored" -eq 1 ]; then
    echo "Provider '$provider_id' needs its key re-stored to bind \$${key_env} here." >&2
    echo "  sends to: ${host}" >&2
    printf 'Re-store it now? [y/N] ' >&2
  else
    echo "Store a credential for provider '$provider_id'?" >&2
    echo "  env var:  \$${key_env}" >&2
    echo "  sends to: ${host}" >&2
    printf 'Store it now? [y/N] ' >&2
  fi
  read -r answer || true
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *)
      echo "Skipping. Aborting; re-run when the '$provider_id' key is set." >&2
      return 1
      ;;
  esac
  if ! command -v acq_backend_secret_set >/dev/null 2>&1; then
    echo "acq: the '${ACQ_RESOLVED_BACKEND:-active}' backend cannot store provider keys." >&2
    return 1
  fi
  acq_backend_secret_set -g "$provider_id" || return 1
  acq_key_injectable "$provider_id" "$name" || {
    echo "acq: the '$provider_id' key is still not injectable. Aborting." >&2
    return 1
  }
  return 0
}

# acq_provider_credentials_gate BACKEND NAME GENERATION — run AFTER
# acq_provider_input_prepare and BEFORE the backend create, for the same reason
# the USAi gate exists: msb binds secrets only at create (`--secret ENV@HOST`)
# and sbx snapshots its proxy table at create, so a credential stored later never
# reaches the sandbox. USAi keeps its dedicated flow (ensure_key_present /
# ensure_valid_key); this gate covers every OTHER provider.
acq_provider_credentials_gate() {
  local backend="${1:-}" name="${2:-}" generation="${3:-}" records provider_id key_env host models_url api_protocol tab
  # Dynamic scoping: visible to the helpers below for THIS call only, so the
  # USAi throwaway-sandbox probe can never inherit another sandbox's facts.
  local ACQ_PROVIDER_BINDINGS_GENERATION
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  records=$(acq_provider_facts_list_generation "$generation") || return 1
  [ -n "$records" ] || return 0
  ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  tab=$(printf '\t')
  while IFS="$tab" read -r provider_id key_env host models_url api_protocol; do
    [ -n "$provider_id" ] || continue
    # Skip ONLY ids a backend hard-codes at its binding layer (see
    # _acq_provider_is_host_service): `usai` is routed through the generic
    # provider path like every other provider.
    _acq_provider_is_host_service "$provider_id" && continue
    _acq_provider_credentials_gate_trust "$backend" "$name" "$provider_id" "$host" || return 1
    _acq_provider_credentials_gate_one "$backend" "$name" "$provider_id" "$key_env" "$host" || return 1
  done <<EOF
$records
EOF
  # Recorded only once every provider passed, so a failed gate never leaves a
  # record implying bindings that were never applied.
  acq_provider_credentials_write "$backend" "$name" "$generation" || true
  return 0
}

# check_provider_key NAME PROVIDER_ID — probe PROVIDER_ID's models endpoint from
# inside the sandbox, mirroring check_key (USAi) for any provider whose facts
# name a modelsUrl. The URL is passed as POSITIONAL DATA, never spliced into the
# guest program text, so URL punctuation cannot become shell syntax.
check_provider_key() {
  local name="${1:-}" provider_id="${2:-}" binding key_env host models_url key_ref raw
  [ -n "$name" ] && [ -n "$provider_id" ] || return 0
  if _acq_provider_is_host_service "$provider_id"; then
    echo "acq: '$provider_id' is a host service; acq never probes it from kit facts." >&2
    return 1
  fi
  binding=$(acq_provider_binding "${ACQ_RESOLVED_BACKEND:-}" "$name" "$provider_id") || {
    echo "acq: no validated provider facts for '$provider_id' in sandbox '$name'." >&2
    return 1
  }
  host=$(printf '%s\n' "$binding" | cut -f1)
  key_env=$(printf '%s\n' "$binding" | cut -f2)
  models_url=$(printf '%s\n' "$binding" | cut -f3)
  _acq_provider_credential_env_ok "$key_env" || {
    echo "acq: provider '$provider_id' declares an unsafe credential env name." >&2
    return 1
  }
  # Enforce the same-host invariant at the probe, not just when facts were read:
  # the Bearer token must never be sent to a host other than facts.host.
  _acq_provider_fact_strict_url_ok "$models_url" "${host%%,*}" || {
    echo "acq: provider '$provider_id' models URL does not match its declared host ($host)." >&2
    return 1
  }
  command -v acq_backend_run >/dev/null 2>&1 || return 0
  key_ref="\$${key_env}"
  raw=$(acq_backend_run "$name" -- sh -c \
    "curl -sS -o /dev/null -w '%{http_code}' \
     -H \"Authorization: Bearer $key_ref\" \
     \"\$1\"; printf '|%s' \"\$?\"" sh "$models_url" 2>/dev/null || true)
  _classify_key_status "$raw"
}

# ensure_valid_provider_keys NAME — validate every selected provider's credential
# against its own facts.modelsUrl. There is no USAi branch: the default provider
# is checked exactly like any other, and its 401 remediation points at the
# dedicated rotate verb. An inconclusive probe FAILS CLOSED (silently attaching
# with an unverified credential is how a dead key reaches the agent), while
# 429/5xx are treated as transient.
ensure_valid_provider_keys() {
  local name="${1:-}" ids provider_id status
  [ -n "$name" ] || return 0
  command -v acq_backend_run >/dev/null 2>&1 || return 0
  acq_debug "provider keys: validating non-usai providers for '$name'"
  ids=$(acq_provider_sandbox_provider_ids "${ACQ_RESOLVED_BACKEND:-}" "$name") || {
    acq_debug "provider keys: provider facts are invalid for '$name'"
    return 1
  }
  acq_debug "provider keys: ids=$(printf '%s' "$ids" | tr '\n' ' ')"
  [ -n "$ids" ] || return 0
  while IFS= read -r provider_id; do
    [ -n "$provider_id" ] || continue
    # Never probe a host service: its token belongs to a compiled-in endpoint,
    # and a kit that declares the id would otherwise direct it to its own host.
    _acq_provider_is_host_service "$provider_id" && continue
    status=$(check_provider_key "$name" "$provider_id")
    case "$status" in
      "200") continue ;;
      "")
        echo "acq: could not validate the '$provider_id' provider key for '$name'" >&2
        echo "     (no models endpoint in its facts, or the probe returned no status)." >&2
        echo "     Refusing to attach with an unverified credential." >&2
        return 1
        ;;
      unreachable)
        echo "acq: the '$provider_id' models endpoint could not be reached from" >&2
        echo "     sandbox '$name'. That is a network problem, not a credential one." >&2
        return 1
        ;;
      unresolved)
        echo "acq: sandbox '$name' could not resolve the '$provider_id' provider host (DNS)." >&2
        return 1
        ;;
      3??)
        echo "acq: the '$provider_id' models endpoint redirected (HTTP ${status})." >&2
        echo "     Update the kit's facts.modelsUrl to the final endpoint." >&2
        return 1
        ;;
      401|403)
        echo "acq: provider '$provider_id' rejected the stored key (HTTP ${status})." >&2
        if [ "$(acq_provider_credential_key_env "$provider_id")" = "$USAI_PROVIDER_KEY_ENV" ]; then
          # The default provider's remediation stays the dedicated rotate verb
          # (it knows the USAi key-management console); no interactive prompt.
          echo "     Rotate it with: acq usai-rotate-api-key" >&2
          echo "     Or re-store it: acq secret set -g $provider_id" >&2
        else
          echo "     Update it with: acq secret set -g $provider_id" >&2
        fi
        return 1
        ;;
      429|5??)
        echo "acq: warning — provider '$provider_id' returned HTTP ${status} (transient);" >&2
        echo "     continuing without blocking attach." >&2
        continue
        ;;
      *)
        echo "acq: provider '$provider_id' rejected the stored key (HTTP ${status})." >&2
        echo "     Update it with: acq secret set -g $provider_id" >&2
        return 1
        ;;
    esac
  done <<EOF
$ids
EOF
  return 0
}

# ============================================================================
# Host-authoritative per-sandbox config store (ADR-0035)
# ============================================================================
# acq must NOT rely on guest-generated or guest-tamperable state to configure a
# sandbox: the in-sandbox agent has passwordless sudo, so a root-owned GUEST path
# (e.g. /var/lib/acq/agent) is NOT a trust boundary against a prompt-injected
# agent — it can sudo-rewrite any such file, and acq would then read the tampered
# value back and act on it (which agent to launch, cwd, SSH_AUTH_SOCK, kit env).
#
# The only enforceable boundary is host<->guest. This store holds acq's trusted
# per-sandbox config on the HOST (under the same state tree as provenance and the
# cli-kits record) and, where the guest legitimately needs to read a value, acq
# mounts the directory into the guest READ-ONLY (see the backend :ro mount).
# The guest can read it but cannot write it; a sudo agent cannot forge it.
#
# Layout (host):   <provenance-dir>/<backend>/<safe-name>.<sum>.config/<KEY>
# Guest mount:     ACQ_HOST_CONFIG_GUEST_DIR (read-only)  [default /var/lib/acq/host]
# One flat file per KEY (value = raw bytes, no trailing newline added), so a
# value may contain any byte a single line could not; readers get exactly what
# was written. Atomic temp+rename write; fail-soft (mirrors the marker writes
# it replaces, which were best-effort `|| true`).
#
# The sandbox config dir is chmod 0711: the guest must be able to traverse the
# read-only mount root to execute `kit-files/...` staged code, but should not be
# able to list acq-internal key names. Content-bearing flat keys remain 0600 on
# the host; readonly kit code is staged under kit-files/ with executable perms.
# The traversable dirs intentionally make known kit-file paths host-readable too;
# only non-sensitive trusted code may be staged there.
#
# KEY charset is restricted ([A-Za-z0-9._-], no slash) so a key can never escape
# the config dir; callers pass fixed literals (agent, workspace, ssh-auth-sock,
# kit-env, and the gate markers).

# The well-known guest mount point for the read-only host config dir. Overridable
# for tests / unusual images. Kept under /var/lib/acq so it sits beside the
# (being-migrated) legacy guest markers without colliding with them.
ACQ_HOST_CONFIG_GUEST_DIR="${ACQ_HOST_CONFIG_GUEST_DIR:-/var/lib/acq/host}"

# Provider inputs deliberately have a separate mount and host root.  In
# particular, never place them below host config: host config can contain
# workspace, SSH, and kit state that provider consumers must not receive.
ACQ_PROVIDER_INPUT_GUEST_DIR="${ACQ_PROVIDER_INPUT_GUEST_DIR:-/var/lib/acq/provider-input}"

# acq_provider_input_prepare — host-validate and stage provider-role kit inputs.
#
# The validator, schemas, and credential-binding registry are shipped by the
# pinned Patterns release. Do not duplicate its schema in this wrapper: fetch
# that fixed release and run its validator before
# copying any declared artifact.  A provider kit without a manifest is simply
# not a provider-role kit; a manifest which cannot be validated is fatal.
#
# Return status 0 means discovery completed (including an authoritative empty
# set).  Status 2 means the host cannot run the released validator and is a
# provisioning blocker, never an empty-set fallback.
_acq_provider_input_python() {
  local python="${ACQ_PROVIDER_INPUT_PYTHON:-}" version_check runtime data_home tools_dir setup
  if [ -n "$python" ]; then
    [ -x "$python" ] || {
      echo "acq: configured provider-input Python is not executable: $python" >&2
      return 2
    }
  else
    if [ -n "${LOCALAPPDATA:-}" ] && [[ "$(uname -s 2>/dev/null)" = MINGW* || "$(uname -s 2>/dev/null)" = MSYS* || "$(uname -s 2>/dev/null)" = CYGWIN* ]]; then
      data_home="$LOCALAPPDATA/acq"
    else
      data_home="${XDG_DATA_HOME:-${HOME:-}/.local/share}/acq"
    fi
    tools_dir="${ACQ_PROVIDER_INPUT_DATA_DIR:-$data_home/provider-input-validator}"
    runtime="$tools_dir/provider-input-validator.current"
    if [ -x "$runtime/bin/python3" ]; then python="$runtime/bin/python3"
    elif [ -x "$runtime/Scripts/python.exe" ]; then python="$runtime/Scripts/python.exe"
    elif [ -x "$runtime/python.exe" ]; then python="$runtime/python.exe"
    fi
  fi
  if [ -z "$python" ]; then
    setup="$ACQ_SCRIPT_DIR/scripts/setup-provider-input-validator"
    [ -x "$setup" ] || {
      echo "acq: provider-input validation runtime is unavailable and this install lacks its offline bootstrap" >&2
      echo "     Reinstall acq from an official release; validation remains mandatory." >&2
      return 2
    }
    # A git checkout has no release wheelhouse; name the online setup command so
    # contributors know exactly how to proceed from a working tree.
    if [ -e "$ACQ_SCRIPT_DIR/.git" ]; then
      local _wh_hint
      _wh_hint="$ACQ_SCRIPT_DIR/scripts/provider-input-validator-wheelhouse"
      # Only show the git-checkout hint when the default wheelhouse is absent.
      if ! [ -d "$_wh_hint" ]; then
        echo "     Git checkout detected: run the following once to install from PyPI with hash verification:" >&2
        echo "       scripts/setup-provider-input-validator --apply --online" >&2
        echo "     Or set ACQ_PROVIDER_INPUT_PYTHON to a Python interpreter with PyYAML 6.0.3 and jsonschema 4.26.0." >&2
      fi
    fi
    "$setup" --apply >&2 || return 2
    runtime="$tools_dir/provider-input-validator.current"
    if [ -x "$runtime/bin/python3" ]; then python="$runtime/bin/python3"
    elif [ -x "$runtime/Scripts/python.exe" ]; then python="$runtime/Scripts/python.exe"
    elif [ -x "$runtime/python.exe" ]; then python="$runtime/python.exe"
    fi
    [ -n "$python" ] || {
      echo "acq: provider-input validator bootstrap did not publish a runtime" >&2
      return 2
    }
  fi
  version_check='import importlib.metadata as m, sys
required = {"PyYAML": "6.0.3", "jsonschema": "4.26.0"}
actual = {}
for package in required:
    try:
        actual[package] = m.version(package)
    except m.PackageNotFoundError:
        actual[package] = None
if actual != required:
    print("acq: provider-input validation requires PyYAML 6.0.3 and jsonschema 4.26.0; found " + ", ".join("%s=%s" % (package, actual[package] or "missing") for package in required), file=sys.stderr)
    print("     Run: scripts/setup-provider-input-validator --apply", file=sys.stderr)
    raise SystemExit(2)'
  "$python" -c "$version_check" || return 2
  printf '%s\n' "$python"
}

acq_provider_input_prepare() {
  local backend="$1" name="$2" root kitref kitdir manifest release_root="" python=""
  local validator="" schema_dir="" bindings="" merged_bindings="" token stage generation manifests=() kitdirs=()
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  command -v kit_translate_fetch >/dev/null 2>&1 || return 2
  root=$(acq_provider_input_root "$backend" "$name") || return 1
  _acq_provider_input_safe_mkdir "$root/generations" || return 1
  chmod 755 "$root" "$root/generations" || return 1
  stage=$(mktemp -d "${TMPDIR:-/tmp}/acq-provider-input.XXXXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf "$stage"; return 1; }
  for kitref in ${KITS[@]+"${KITS[@]}"}; do
    token=$(printf '%s' "$kitref" | cksum | cut -d' ' -f1) || { rm -rf "$stage"; return 1; }
    kitdir=$(kit_translate_fetch "$kitref" "$stage/fetch-$token") || { rm -rf "$stage"; return 2; }
    manifest="$kitdir/provider-input.json"
    [ -e "$manifest" ] || continue
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || { echo "acq: unsafe provider input manifest: $manifest" >&2; rm -rf "$stage"; return 1; }
    _acq_provider_input_snapshot "$kitdir" "$stage/candidate-$token" || { rm -rf "$stage"; return 1; }
    manifests+=("$stage/candidate-$token/provider-input.json")
    kitdirs+=("$stage/candidate-$token")
  done
  # A generation is complete and immutable before an adapter mounts it. It is not
  # visible through current until that adapter reports a successful create.
  generation=$(mktemp -d "$root/generations/generation.XXXXXXXX") || { _acq_provider_input_cleanup_stage "$stage"; return 1; }
  chmod 755 "$generation" || { _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 1; }
  _acq_provider_input_safe_mkdir "$generation/models/providers" || { _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 1; }
  chmod 755 "$generation/models" "$generation/models/providers" || { _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 1; }
  # A present empty generation is authoritative; it replaces current atomically.
  if [ "${#manifests[@]}" -eq 0 ]; then
    _acq_provider_input_cleanup_stage "$stage"
    printf '%s\n' "$generation"
    return 0
  fi
  # The validator and its control-plane inputs come from the fixed, pinned
  # Patterns bundle, never from a provider-controlled candidate kit.
  release_root=$(_acq_provider_input_control_plane "$stage/control-plane") || {
    _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 2; }
  validator="$release_root/scripts/validate_provider_input_contract.py"
  schema_dir="$release_root/integrations/isolation/schemas"
  bindings="$schema_dir/provider-credential-bindings.json"
  [ -f "$validator" ] && [ ! -L "$validator" ] && [ -d "$schema_dir" ] && [ ! -L "$schema_dir" ] \
    && [ -f "$bindings" ] && [ ! -L "$bindings" ] || {
    echo "acq: pinned Patterns provider-input validator is unavailable" >&2; _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 2; }
  python=$(_acq_provider_input_python) || {
    _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 2; }
  # acq owns the provider -> KEY_ENV registry, layered over the pinned Patterns
  # defaults (its trust anchor) and then per-invocation config/env overrides, so
  # a provider kit hosted outside the pinned release validates without editing
  # that release. The merged file lives in the staging dir, so the existing
  # stage cleanup removes it with everything else. A malformed override fails
  # closed here — before the validator runs — rather than binding the wrong key.
  merged_bindings="$stage/provider-credential-bindings.json"
  acq_provider_credential_merge_json "$bindings" "$merged_bindings" "$python" || {
    _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 1; }
  local validator_args=(--schema-dir "$schema_dir" --credential-bindings "$merged_bindings")
  local i
  for i in "${!manifests[@]}"; do validator_args+=(--bundle "${manifests[$i]}"); done
  "$python" "$validator" "${validator_args[@]}" >&2 || { _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 1; }
  for i in "${!manifests[@]}"; do
    _acq_provider_input_materialize "${manifests[$i]}" "${kitdirs[$i]}" "$generation/models/providers" || { _acq_provider_input_cleanup_stage "$stage"; _acq_provider_input_cleanup_generation "$root" "$generation"; return 1; }
  done
  _acq_provider_input_cleanup_stage "$stage"
  printf '%s\n' "$generation"
}

# acq_provider_input_project is retained for callers outside backend creation.
# Adapters must use prepare, mount the returned generation, and publish only
# after their backend create succeeds.
acq_provider_input_project() {
  local backend="$1" name="$2" generation root
  generation=$(acq_provider_input_prepare "$backend" "$name") || return $?
  root=$(acq_provider_input_root "$backend" "$name") || {
    _acq_provider_input_cleanup_generation "${generation%/generations/*}" "$generation" || true
    return 1
  }
  _acq_provider_input_publish "$root" "$generation" || {
    _acq_provider_input_cleanup_generation "$root" "$generation" || true
    return 1
  }
}

# Provider inputs share the provenance base only as a parent, never as a mounted
# directory. The backend/name checksum prevents aliases after slug sanitization.
acq_provider_input_root() {
  local backend="${1:-}" name="${2:-}" safe_backend safe_name name_sum
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  safe_backend=$(printf '%s' "$backend" | tr -c 'A-Za-z0-9._-' '_')
  safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
  name_sum=$(printf '%s' "$name" | cksum 2>/dev/null | cut -d' ' -f1 2>/dev/null || echo 0)
  printf '%s/provider-input/%s/%s.%s\n' "$(_acq_provenance_dir)" "$safe_backend" "$safe_name" "$name_sum"
}

acq_provider_input_guest_root() {
  local backend="$1" generation="$3" base
  [ -n "$generation" ] || return 1
  base=${generation##*/}
  case "$base" in generation.*) ;; *) return 1 ;; esac
  case "$backend" in
    sbx) printf '%s\n' "$generation" ;;
    msb) printf '%s/%s\n' "$ACQ_PROVIDER_INPUT_GUEST_DIR" "$base" ;;
    *) return 1 ;;
  esac
}

acq_provider_input_sbx_mount() {
  case "${2:-}" in */generations/generation.*) printf '%s:ro\n' "$2" ;; *) return 1 ;; esac
}

acq_provider_input_msb_mount() {
  local generation="$2" host_generation canonical_generation
  case "$generation" in */generations/generation.*) ;; *) return 1 ;; esac
  canonical_generation=$(_acq_provider_input_canonical_path "$generation") || return 1
  if command -v host_path >/dev/null 2>&1; then
    host_generation=$(host_path "$canonical_generation") || return 1
  else
    host_generation="$canonical_generation"
  fi
  printf '%s:%s/%s:ro\n' "$host_generation" "$ACQ_PROVIDER_INPUT_GUEST_DIR" "${generation##*/}"
}

acq_provider_input_discard() {
  local backend="$1" name="$2" generation="$3" root
  root=$(acq_provider_input_root "$backend" "$name") || return 1
  _acq_provider_input_cleanup_generation "$root" "$generation"
}

# Normalize the three macOS kernel-managed path aliases to their canonical
# /private/{var,tmp,etc} spellings so O_NOFOLLOW traversal never sees a
# symlink at the first path component.  Also collapses harmless absolute
# spelling variants (//foo or /./foo) that would otherwise skip the alias
# match.  No arbitrary realpath or symlink following is performed; only the
# three OS-level prefixes are rewritten.  Linux and other platforms are
# unaffected.  Echoes the canonical path on stdout.
#
# ACQ_TEST_HOST_OS overrides sys.platform for offline CI testing only.
# ACQ_TEST_ALIAS_TABLE (offline CI only) overrides the alias pair table for
# isolated-filesystem tests.  Format: tab-separated "alias<TAB>target" pairs,
# one per line.  When set, ACQ_TEST_HOST_OS=darwin must also be set.  Production
# builds never set this variable; it is documented alongside ACQ_TEST_HOST_OS as
# a test-seam-only override.
_acq_provider_input_canonical_path() {
  python3 - "$1" <<'PY'
import os, re, sys
path = sys.argv[1]
# Collapse harmless absolute spelling variants before alias matching.
# //foo or /./foo must resolve to /foo so the alias table hits correctly.
# Only the leading segment is touched; interior components are left for the
# O_NOFOLLOW traversal to validate normally.
path = re.sub(r'^/+(?:\./+)*', '/', path)
_platform = os.environ.get('ACQ_TEST_HOST_OS', sys.platform)
if _platform == 'darwin':
    _alias_table_raw = os.environ.get('ACQ_TEST_ALIAS_TABLE', '')
    if _alias_table_raw:
        _alias_pairs = [tuple(line.split('\t', 1)) for line in _alias_table_raw.split('\n') if '\t' in line]
    else:
        _alias_pairs = (('/var', '/private/var'), ('/tmp', '/private/tmp'), ('/etc', '/private/etc'))
    for _alias, _target in _alias_pairs:
        if path == _alias or path.startswith(_alias + '/'):
            path = _target + path[len(_alias):]
            break
print(path, end='')
PY
}

# Create a path one component at a time without ever traversing a symlink.
# This protects the host-owned projection tree from a malicious pre-created
# ancestor.
#
# On macOS, /var, /tmp, and /etc are kernel-managed symlinks to
# /private/{var,tmp,etc}.  _acq_provider_input_canonical_path rewrites only
# those three OS-level prefixes (plus harmless double-slash/dot variants) so
# O_NOFOLLOW does not reject them with ELOOP.  All subsequent components —
# including every user-influenced one — still traverse with O_NOFOLLOW.
# Linux is unaffected.
_acq_provider_input_safe_mkdir() {
  local _canon
  _canon=$(_acq_provider_input_canonical_path "$1") || return 1
  python3 - "$_canon" <<'PY'
import os, stat, sys
path = sys.argv[1]
if not os.path.isabs(path): raise SystemExit('provider-input path must be absolute')
if hasattr(os, 'O_DIRECTORY') and hasattr(os, 'O_NOFOLLOW'):
    # POSIX: openat-style traversal with O_NOFOLLOW so no component follows a
    # symlink (the host-owned projection tree must not be redirected).
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in (p for p in path.split('/') if p):
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                os.mkdir(part, 0o755, dir_fd=fd)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            if not stat.S_ISDIR(os.fstat(child).st_mode): raise SystemExit('unsafe provider-input path')
            os.close(fd); fd = child
    finally:
        os.close(fd)
else:
    # Windows (native Python 3.12): no O_DIRECTORY/O_NOFOLLOW/dir_fd, and MSYS2
    # hands argv in Windows form (C:/...). Walk component by component from the
    # drive root, creating missing directories one at a time so no ancestor is
    # followed before it is validated. Reject symlinks (S_IFLNK), junctions
    # (IO_REPARSE_TAG_MOUNT_POINT), and every other reparse point at each step,
    # so a writable ancestor cannot redirect projection creation outside the
    # intended tree (os.path.islink alone silently misses junctions).
    if not hasattr(os.path, 'splitdrive'):
        raise SystemExit('unsafe provider-input path: reparse-point traversal unavailable')
    def _fatal():
        raise SystemExit('unsafe provider-input path')
    def _unsafe(st):
        # st_reparse_tag != 0 covers os.path.isjunction() (mount points) plus
        # every other reparse tag; S_IFLNK covers symlinks.
        return stat.S_ISLNK(st.st_mode) or getattr(st, 'st_reparse_tag', 0) != 0
    drive, tail = os.path.splitdrive(path)
    if not drive:
        _fatal()
    cur = drive + os.sep
    def _validate_dir(p, create):
        try:
            st = os.lstat(p)
        except FileNotFoundError:
            if not create:
                _fatal()
            try:
                os.mkdir(p, 0o755)
            except FileExistsError:
                pass
            st = os.lstat(p)
        except OSError:
            _fatal()
        if _unsafe(st) or not stat.S_ISDIR(st.st_mode):
            _fatal()
    _validate_dir(cur, False)
    for comp in tail.replace('\\', '/').split('/'):
        if comp in ('', '.'):
            continue
        if comp == '..':
            _fatal()
        cur = os.path.join(cur, comp)
        _validate_dir(cur, True)
PY
}

_acq_provider_input_safe_dir() {
  local _canon
  _canon=$(_acq_provider_input_canonical_path "$1") || return 1
  python3 - "$_canon" <<'PY'
import os, stat, sys
path = sys.argv[1]
if not os.path.isabs(path): raise SystemExit(1)
if hasattr(os, 'O_DIRECTORY') and hasattr(os, 'O_NOFOLLOW'):
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in (p for p in path.split('/') if p):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            if not stat.S_ISDIR(os.fstat(child).st_mode): raise SystemExit(1)
            os.close(fd); fd = child
    finally:
        os.close(fd)
else:
    # Windows (native Python 3.12): walk component by component from the drive
    # root, rejecting symlinks (S_IFLNK), junctions (IO_REPARSE_TAG_MOUNT_POINT),
    # and every other reparse point at each step so an attacker-controlled
    # ancestor cannot redirect the existence/type check (islink alone misses
    # junctions). Requires a real directory, never creating anything.
    if not hasattr(os.path, 'splitdrive'):
        raise SystemExit(1)
    def _fatal():
        raise SystemExit(1)
    def _unsafe(st):
        return stat.S_ISLNK(st.st_mode) or getattr(st, 'st_reparse_tag', 0) != 0
    drive, tail = os.path.splitdrive(path)
    if not drive:
        _fatal()
    cur = drive + os.sep
    def _validate_dir(p):
        try:
            st = os.lstat(p)
        except OSError:
            _fatal()
        if _unsafe(st) or not stat.S_ISDIR(st.st_mode):
            _fatal()
    _validate_dir(cur)
    for comp in tail.replace('\\', '/').split('/'):
        if comp in ('', '.'):
            continue
        if comp == '..':
            _fatal()
        cur = os.path.join(cur, comp)
        _validate_dir(cur)
PY
}

_acq_provider_input_cleanup_stage() {
  case "${1:-}" in "${TMPDIR:-/tmp}"/acq-provider-input.*) rm -rf -- "$1" ;; *) return 1 ;; esac
}

_acq_provider_input_cleanup_generation() {
  local root="$1" generation="$2"
  case "$root" in ""|/|/*/) return 1 ;; esac
  case "$generation" in
    "$root"/generations/generation.*)
      _acq_provider_input_safe_dir "$root/generations" || return 1
      [ -d "$generation" ] && [ ! -L "$generation" ] || return 1
      chmod -R u+w "$generation" 2>/dev/null || true
      rm -rf -- "$generation"
      ;;
    *) return 1 ;;
  esac
}

_acq_provider_input_remove_tree() {
  chmod -R u+w "$1" 2>/dev/null || return 1
  rm -rf -- "$1"
}

_acq_provider_input_atomic_replace() {
  python3 - "$1" "$2" <<'PY'
import os, sys
os.replace(sys.argv[1], sys.argv[2])
PY
}

_acq_provider_input_publish() {
  local root="$1" generation="$2" base temp current
  case "$root" in ""|/|/*/) return 1 ;; esac
  case "$generation" in "$root"/generations/generation.*) ;; *) return 1 ;; esac
  _acq_provider_input_safe_dir "$root/generations" || return 1
  [ -d "$generation" ] && [ ! -L "$generation" ] || return 1
  chmod -R a-w "$generation" || return 1
  base=${generation##*/}
  temp="$root/.current.$$.$RANDOM"
  current="$root/current"
  ln -s "generations/$base" "$temp" || return 1
  # rename is atomic within root; do not remove current first.
  _acq_provider_input_atomic_replace "$temp" "$current" || { rm -f "$temp"; return 1; }
  # Retain prior generations. A sandbox created by an older acq may still mount
  # current, and a failed concurrent create must never make that sandbox lose its
  # inputs. New sandboxes mount an exact generation and are unaffected by swaps.
}

# One mkdir lock coordinates the complete create transaction on Bash 3.2 hosts:
# discovery through argv construction, publication, backend create, and removal.
# It is intentionally rooted beside, but never inside, the guest-visible tree.
# acq_provider_input_lock_acquire backend name [tx_pid]
#
# tx_pid is the PID of the transaction subshell that owns the lock for its
# entire lifetime.  Callers pass it explicitly so the lock is not tied to the
# outer interactive shell ($$), which exits before the transaction completes.
# Bash 3.2 does not have BASHPID, so callers compute their own PID with:
#   tx_pid=$(exec sh -c 'echo $PPID')
# and supply it as the third argument.  The fallback to $$ is retained for
# tests that call lock_acquire directly (no surrounding subshell).
acq_provider_input_lock_acquire() {
  local backend="$1" name="$2" tx_pid="${3:-$$}" root parent lock owner tries=0 pid identity actual_identity
  root=$(acq_provider_input_root "$backend" "$name") || return 1
  parent=${root%/*}
  _acq_provider_input_safe_mkdir "$parent" || return 1
  lock="${root}.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    [ -d "$lock" ] && [ ! -L "$lock" ] || { echo "acq: unsafe provider-input lock: $lock" >&2; return 1; }
    owner="$lock/owner"
    IFS=' ' read -r pid identity < "$owner" 2>/dev/null || true
    actual_identity=$(_acq_provider_input_process_identity "$pid" 2>/dev/null || true)
    if [ -n "$pid" ] && [ -n "$identity" ] && [ "$actual_identity" = "$identity" ]; then
      echo "acq: provider-input lock is owned by live pid $pid: $lock" >&2
    elif [ -n "$pid" ] && { ! kill -0 "$pid" 2>/dev/null || { [ -n "$actual_identity" ] && [ "$actual_identity" != "$identity" ]; }; }; then
      echo "acq: recovering stale provider-input lock owned by pid $pid: $lock" >&2
      rm -f -- "$owner" && rmdir -- "$lock" 2>/dev/null || return 1
      continue
    else
      echo "acq: provider-input lock has no valid owner metadata: $lock" >&2
      return 1
    fi
    tries=$((tries + 1))
    [ "$tries" -lt "${ACQ_PROVIDER_INPUT_LOCK_RETRIES:-300}" ] || return 1
    sleep 1
  done
  identity=$(_acq_provider_input_process_identity "$tx_pid") || { rmdir -- "$lock"; return 1; }
  printf '%s %s\n' "$tx_pid" "$identity" > "$lock/owner" || { rmdir -- "$lock"; return 1; }
  printf '%s\n' "$lock"
}

# True (0) on MSYS2/Git-Bash (MINGW/MSYS/CYGWIN), where `ps` does not accept
# the `-o FIELD=` output-format specifier and instead prints a fixed table via
# `ps -p PID` (columns: PID PPID PGID WINPID TTY UID STIME COMMAND).
_acq_provider_input_msys_ps() {
  [ -n "${LOCALAPPDATA:-}" ] || return 1
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

# Parent PID of PID (empty on failure), portable across GNU/macOS and MSYS.
# GNU/macOS: `ps -o ppid= -p PID`. MSYS: PPID is column 2 of `ps -p PID`.
_acq_provider_input_parent_pid() {
  local pid="${1:-}"
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  if _acq_provider_input_msys_ps; then
    ps -p "$pid" 2>/dev/null | awk 'NR==2 {print $2}'
  else
    ps -o ppid= -p "$pid" 2>/dev/null
  fi | tr -d '[:space:]'
}

# Start a real process whose lifetime is tied to the transaction subshell. Bash
# 3.2 preserves $$ across subshells and has no BASHPID, so the lock records this
# guardian PID instead. The guardian exits if its transaction parent disappears,
# including after SIGKILL, making stale recovery safe.
_acq_provider_input_guardian_start() {
  _ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN=$(mktemp "${TMPDIR:-/tmp}/acq-provider-children.XXXXXX") || return 1
  export _ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN
  sh -c '
    parent=$PPID
    trap "exit 0" HUP INT TERM
    children=$1
    while :; do
      live=0
      kill -0 "$parent" 2>/dev/null && live=1
      if [ -f "$children" ]; then
        while IFS= read -r child; do
          case "$child" in ""|*[!0-9]*) continue ;; esac
          kill -0 "$child" 2>/dev/null && live=1
        done < "$children"
      fi
      [ "$live" -eq 1 ] || exit 0
      sleep 1
    done
  ' sh "$_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN" &
  _ACQ_PROVIDER_INPUT_GUARDIAN_PID=$!
  _ACQ_PROVIDER_INPUT_TRANSACTION_PID=$(_acq_provider_input_parent_pid "$_ACQ_PROVIDER_INPUT_GUARDIAN_PID")
  case "$_ACQ_PROVIDER_INPUT_TRANSACTION_PID" in ""|*[!0-9]*) _acq_provider_input_guardian_stop; return 1 ;; esac
  export _ACQ_PROVIDER_INPUT_GUARDIAN_PID
  export _ACQ_PROVIDER_INPUT_TRANSACTION_PID
}

_acq_provider_input_guardian_register_child() {
  local pid="${1:-}" registry="${_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN:-}"
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  [ -n "$registry" ] && [ -f "$registry" ] || return 1
  printf '%s\n' "$pid" >> "$registry"
}

_acq_provider_input_guardian_register_if_active() {
  [ -z "${_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN:-}" ] && return 0
  _acq_provider_input_guardian_register_child "$1"
}

_acq_provider_input_guardian_stop() {
  local pid="${_ACQ_PROVIDER_INPUT_GUARDIAN_PID:-}"
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  [ -z "${_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN:-}" ] || rm -f -- "$_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN"
  _ACQ_PROVIDER_INPUT_GUARDIAN_PID=""
  _ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN=""
  _ACQ_PROVIDER_INPUT_TRANSACTION_PID=""
}

# Signal all registered backend children and wait for them to exit before the
# caller releases the lock or stops the guardian.  Called from the signal
# handlers (TERM/INT/HUP) in provision/terminate wrappers so that a handled
# signal cannot free the lock while a synchronous backend create/remove is
# still running.
#
# Algorithm:
#   1. Send TERM to every PID listed in the children registry.
#   2. Poll until all are gone (up to ACQ_PROVIDER_INPUT_CHILD_WAIT_SECS,
#      default 60).  Each 0.1 s tick is approximated with a 1-second sleep
#      (POSIX sh: no sub-second sleep guarantee), so the effective ceiling is
#      the same but granularity is coarser on some platforms.
#   3. If any child is still live after the timeout, send KILL and poll for
#      another 10 s.
#   4. If a child still cannot be reaped (PID reuse is possible but rare in
#      this context), leave the guardian and lock in place and return 1 so the
#      wrapper can stay alive rather than permit lock overlap.
#
# Returns 0 when all children are confirmed gone; 1 when at least one
# unkillable child remains (caller must NOT release lock).
_acq_provider_input_guardian_signal_children() {
  local registry="${_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN:-}"
  [ -n "$registry" ] && [ -f "$registry" ] || return 0
  local child
  # TERM every registered child.
  while IFS= read -r child; do
    case "$child" in ""|*[!0-9]*) continue ;; esac
    kill -TERM "$child" 2>/dev/null || true
  done < "$registry"
  # Wait up to ACQ_PROVIDER_INPUT_CHILD_WAIT_SECS (default 60) for all to exit.
  local waited=0 max="${ACQ_PROVIDER_INPUT_CHILD_WAIT_SECS:-60}" any_live
  while [ "$waited" -lt "$max" ]; do
    any_live=0
    while IFS= read -r child; do
      case "$child" in ""|*[!0-9]*) continue ;; esac
      kill -0 "$child" 2>/dev/null && { any_live=1; break; }
    done < "$registry"
    [ "$any_live" -eq 1 ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
  # Escalate to KILL for anything still running.
  while IFS= read -r child; do
    case "$child" in ""|*[!0-9]*) continue ;; esac
    kill -0 "$child" 2>/dev/null && kill -KILL "$child" 2>/dev/null || true
  done < "$registry"
  waited=0
  while [ "$waited" -lt 10 ]; do
    any_live=0
    while IFS= read -r child; do
      case "$child" in ""|*[!0-9]*) continue ;; esac
      kill -0 "$child" 2>/dev/null && { any_live=1; break; }
    done < "$registry"
    [ "$any_live" -eq 1 ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
  # At least one child could not be reaped; caller must retain lock.
  return 1
}

_acq_provider_input_signal_exit() {
  local status="${1:-1}"
  if _acq_provider_input_guardian_signal_children; then
    exit "$status"
  fi
  # An unkillable registered backend child still owns the transaction. Keep the
  # guardian and lock rather than allowing EXIT cleanup to expose overlap.
  trap - EXIT
  exit 1
}

_acq_provider_input_process_identity() {
  local pid="${1:-}"
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  if _acq_provider_input_msys_ps; then
    # MSYS has no lstart; WINPID (column 4) is the stable, unique Windows
    # process id, so it distinguishes a reused MSYS PID from the original owner.
    ps -p "$pid" 2>/dev/null | awk 'NR==2 {print $4}'
  else
    ps -o lstart= -p "$pid" 2>/dev/null
  fi | tr -d '[:space:]' | grep .
}

acq_provider_input_lock_release() {
  case "${1:-}" in */provider-input/*/*.lock)
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    rm -f -- "$1/owner" && rmdir -- "$1" 2>/dev/null || return 1
    ;;
    *) return 1 ;;
  esac
}

acq_provider_input_remove() {
  local backend="$1" name="$2" root
  root=$(acq_provider_input_root "$backend" "$name") || return 1
  case "$root" in ""|/|/*/) return 1 ;; */provider-input/*/*.*) ;; *) return 1 ;; esac
  _acq_provider_input_safe_dir "${root%/*}" || return 1
  [ ! -L "$root" ] || return 1
  _acq_provider_input_remove_tree "$root"
}

_acq_provider_input_contract_kit_ref() {
  printf '%s#ref=%s&dir=%s/%s\n' \
    "$PATTERNS_KIT_REPO" "$PATTERNS_KIT_REF" "$PATTERNS_KIT_DIR" "$USAI_PROVIDER_KIT_NAME"
}

# The control plane is a full, exact Patterns checkout: a sparse kit fetch does
# not contain the repository-level validator or schemas. It remains private in
# the staging directory and is never exposed through a sandbox mount.
_acq_provider_input_control_plane() {
  local dest="$1" actual
  mkdir -p "$dest" || return 1
  (
    cd "$dest" || exit 1
    export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo GCM_INTERACTIVE=never
    git init -q || exit 1
    git remote add origin "${PATTERNS_KIT_REPO#git+}" || exit 1
    git fetch -q --depth 1 origin "$PATTERNS_KIT_REF" || exit 1
    git checkout -q --detach FETCH_HEAD || exit 1
    actual=$(git rev-parse HEAD) || exit 1
    [ "$actual" = "$PATTERNS_KIT_REF" ]
  ) || return 1
  [ ! -L "$dest/scripts" ] && [ ! -L "$dest/integrations" ] || return 1
  printf '%s\n' "$dest"
}

# Snapshot only the declared regular files with descriptor-relative, no-follow
# reads. Validation and later materialization therefore cannot observe a changed
# candidate manifest, symlink, or path outside the fetched kit.
_acq_provider_input_snapshot() {
  python3 - "$1" "$2" <<'PY'
import json, os, stat, sys
kit, target = sys.argv[1:]
def safe_path(base, rel):
    if not isinstance(rel, str) or rel.startswith('/') or not rel or any(part in ('', '.', '..') for part in rel.split('/')):
        raise SystemExit('unsafe provider artifact path')
    if hasattr(os, 'O_DIRECTORY') and hasattr(os, 'O_NOFOLLOW'):
        # POSIX: descriptor-relative, no-follow walk rejects symlinks and any
        # path outside the fetched kit.
        fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in rel.split('/'):
                nextfd = os.open(part, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd = nextfd
            if not stat.S_ISREG(os.fstat(fd).st_mode): raise SystemExit('unsafe provider artifact')
        finally:
            os.close(fd)
    else:
        # Windows (native Python 3.12): no O_NOFOLLOW/dir_fd. Walk the relative
        # path component by component under `base`, rejecting symlinks (S_IFLNK),
        # junctions, and every other reparse point at each step, and require a
        # regular file at the end. Backslash is treated as a separator here so a
        # manifest path cannot smuggle '..\\..' traversal on Windows.
        def _fatal():
            raise SystemExit('unsafe provider artifact')
        def _unsafe(st):
            return stat.S_ISLNK(st.st_mode) or getattr(st, 'st_reparse_tag', 0) != 0
        parts = rel.replace('\\', '/').split('/')
        if any(p in ('', '.', '..') for p in parts):
            _fatal()
        cur = base
        for i, part in enumerate(parts):
            cur = os.path.join(cur, part)
            try:
                st = os.lstat(cur)
            except OSError:
                _fatal()
            if _unsafe(st):
                _fatal()
            if i == len(parts) - 1:
                if not stat.S_ISREG(st.st_mode):
                    _fatal()
            elif not stat.S_ISDIR(st.st_mode):
                _fatal()
    return os.path.join(base, rel)
if os.path.islink(kit) or not os.path.isdir(kit) \
        or getattr(os.lstat(kit), 'st_reparse_tag', 0) != 0:
    raise SystemExit('unsafe provider kit path')
manifest_path = safe_path(kit, 'provider-input.json')
with open(manifest_path, encoding='utf-8') as stream: manifest_bytes = stream.read()
try:
    bundle = json.loads(manifest_bytes)
except json.JSONDecodeError as exc:
    raise SystemExit(
        'acq: invalid provider input manifest: provider-input.json: '
        f'invalid JSON at line {exc.lineno} column {exc.colno}'
    )
os.mkdir(target, 0o700)
with open(os.path.join(target, 'provider-input.json'), 'x', encoding='utf-8') as stream: stream.write(manifest_bytes)
for path in ('spec.yaml', bundle['factsPath'], bundle['normalizerPath'], bundle['snapshotPath']):
    source = safe_path(kit, path)
    destination = os.path.join(target, path)
    os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
    source_mode = stat.S_IMODE(os.stat(source).st_mode)
    with open(source, 'rb') as src, open(destination, 'xb') as dst:
        while True:
            chunk = src.read(1024 * 1024)
            if not chunk: break
            dst.write(chunk)
    os.chmod(destination, source_mode)
PY
}

# Copy only validator-approved regular files into the backend-owned readonly tree.
_acq_provider_input_materialize() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, os, shutil, sys
manifest, kit, target_root = sys.argv[1:]
bundle = json.load(open(manifest, encoding="utf-8"))
provider = bundle["providerId"]
if not isinstance(provider, str) or not provider or provider in ('.', '..') or '/' in provider or '\\' in provider:
    raise SystemExit("unsafe provider ID")
if bundle.get("schemaVersion") != "acq-provider-input-bundle/v2" or bundle.get("providerPath") != "models/providers/" + provider:
    raise SystemExit("unsafe provider bundle layout")
target = os.path.join(target_root, provider)
if os.path.lexists(target) or os.path.dirname(target) != target_root or os.path.basename(target) != provider:
    raise SystemExit("duplicate or unsafe provider target")
os.mkdir(target, 0o755)
for source, destination, mode in ((bundle["factsPath"], "facts.json", 0o444), (bundle["normalizerPath"], "normalizer", 0o555), (bundle["snapshotPath"], "snapshot.json", 0o444)):
    if not isinstance(source, str) or source.startswith('/') or any(part in ('', '.', '..') for part in source.split('/')):
        raise SystemExit("unsafe provider artifact path")
    source = os.path.join(kit, source)
    if os.path.islink(source) or not os.path.isfile(source):
        raise SystemExit("unsafe provider artifact")
    destination = os.path.join(target, destination)
    shutil.copyfile(source, destination)
    os.chmod(destination, mode)
os.chmod(target, 0o555)
PY
}

# Host directory holding one sandbox's config files. Same keying as the
# provenance/cli-kits records (sanitized name + raw-name checksum) so the three
# sit side by side and never collide across backends or sanitizer-aliased names.
acq_host_config_dir() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  local safe_backend safe_name name_sum
  safe_backend=$(printf '%s' "$backend" | tr -c 'A-Za-z0-9._-' '_')
  safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
  name_sum=$(printf '%s' "$name" | cksum 2>/dev/null | cut -d' ' -f1 2>/dev/null || echo 0)
  printf '%s/%s/%s.%s.config\n' "$(_acq_provenance_dir)" "$safe_backend" "$safe_name" "$name_sum"
}

# Validate a config KEY: fixed-literal callers only, restricted charset, never a
# path separator or traversal. Fail closed (return non-zero, emit nothing).
_acq_host_config_key_ok() {
  case "${1:-}" in
    ""|.|..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Write one KEY's VALUE for a sandbox's host config. Creates/traversabilizes the
# dir 0711 and writes the file 0600 (world-unreadable on the host; the guest sees
# only what it can traverse/read via the :ro mount).
# Atomic temp+rename. Best-effort: warns (debug) and returns non-zero on failure
# but never aborts the caller — preserving the fail-soft posture of the guest
# markers this replaces.
# Usage: acq_host_config_write BACKEND NAME KEY VALUE
acq_host_config_write() {
  local backend="${1:-}" name="${2:-}" key="${3:-}" value="${4:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  _acq_host_config_key_ok "$key" || { acq_debug "host-config: refusing unsafe key '$key'"; return 1; }
  local dir file
  dir=$(acq_host_config_dir "$backend" "$name") || return 1
  if ! mkdir -p "$dir" 2>/dev/null; then
    acq_debug "host-config: could not create config dir: $dir"
    return 1
  fi
  chmod 711 "$dir" 2>/dev/null || true
  file="$dir/$key"
  local tmp="${file}.tmp.$$"
  ( umask 077; printf '%s' "$value" > "$tmp" ) 2>/dev/null || {
    acq_debug "host-config: write failed: $tmp"; rm -f "$tmp" 2>/dev/null; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file" 2>/dev/null || {
    acq_debug "host-config: mv failed: $file"; rm -f "$tmp" 2>/dev/null; return 1; }
  acq_debug "host-config: wrote $backend/$name/$key"
  return 0
}

# Read one KEY's VALUE. Echoes the raw stored bytes (empty if absent/unreadable).
# Never fails the caller (returns 0 even when the key is absent) so a reader under
# `set -euo pipefail` behaves like the old failure-guarded guest `cat`.
# Usage: acq_host_config_read BACKEND NAME KEY
acq_host_config_read() {
  local backend="${1:-}" name="${2:-}" key="${3:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 0
  _acq_host_config_key_ok "$key" || return 0
  local dir file
  dir=$(acq_host_config_dir "$backend" "$name") || return 0
  file="$dir/$key"
  [ -f "$file" ] || return 0
  cat "$file" 2>/dev/null || true
}

# True (0) if a KEY exists for a sandbox. Replaces the guest `test -f` marker
# gates (install-*, agent-*-ready) that a sudo guest could forge.
# Usage: acq_host_config_has BACKEND NAME KEY
acq_host_config_has() {
  local backend="${1:-}" name="${2:-}" key="${3:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  _acq_host_config_key_ok "$key" || return 1
  local dir
  dir=$(acq_host_config_dir "$backend" "$name") || return 1
  [ -f "$dir/$key" ]
}

# Append VALUE (one line) to a KEY's file, creating it if needed. Used by the
# kit-env accumulator (multiple kits each contribute lines). Same fail-soft
# contract as acq_host_config_write.
# Usage: acq_host_config_append BACKEND NAME KEY VALUE
acq_host_config_append() {
  local backend="${1:-}" name="${2:-}" key="${3:-}" value="${4:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 1
  _acq_host_config_key_ok "$key" || { acq_debug "host-config: refusing unsafe key '$key'"; return 1; }
  local dir file
  dir=$(acq_host_config_dir "$backend" "$name") || return 1
  if ! mkdir -p "$dir" 2>/dev/null; then
    acq_debug "host-config: could not create config dir: $dir"; return 1
  fi
  chmod 711 "$dir" 2>/dev/null || true
  file="$dir/$key"
  if [ ! -f "$file" ]; then
    ( umask 077; : > "$file" ) 2>/dev/null || {
      acq_debug "host-config: create failed: $file"; return 1; }
  fi
  printf '%s\n' "$value" >> "$file" 2>/dev/null || {
    acq_debug "host-config: append failed: $file"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

# Remove one KEY (e.g. reset kit-env before a full re-apply). Best-effort.
# Usage: acq_host_config_clear BACKEND NAME KEY
acq_host_config_clear() {
  local backend="${1:-}" name="${2:-}" key="${3:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 0
  _acq_host_config_key_ok "$key" || return 0
  local dir
  dir=$(acq_host_config_dir "$backend" "$name") || return 0
  rm -f "$dir/$key" 2>/dev/null || true
  return 0
}

# Remove per-sandbox instance keys before provisioning a freshly-created sandbox.
# The host config dir is keyed by sandbox name, so a sandbox removed outside acq
# can leave stale state behind for a later same-named sandbox. Clear run-once
# gates and conditionally-written content keys before provision rewrites the
# current instance's authoritative values.
# Usage: acq_host_config_clear_instance_state BACKEND NAME
acq_host_config_clear_instance_state() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 0
  local dir
  dir=$(acq_host_config_dir "$backend" "$name") || return 0
  case "$dir" in ""|/|/*/) return 0 ;; esac
  rm -f "$dir"/install-* "$dir"/agent-installed-* \
        "$dir"/agent-user-ready \
        "$dir"/workspace "$dir"/ssh-auth-sock "$dir"/generic-opencode \
        "$dir"/extra-kits 2>/dev/null || true
  return 0
}

# True when a sandbox was created with the generic OpenCode base and its pinned
# kit. This is host-authoritative create-time state, not a per-invocation flag.
# Usage: acq_instance_uses_generic_opencode BACKEND NAME
acq_instance_uses_generic_opencode() {
  case "$(acq_host_config_read "$1" "$2" generic-opencode 2>/dev/null || true)" in
    generic-opencode|1) return 0 ;;
    *) return 1 ;;
  esac
}

# Remove a sandbox's entire host config dir (called from terminate). Best-effort.
# Usage: acq_host_config_remove BACKEND NAME
acq_host_config_remove() {
  local backend="${1:-}" name="${2:-}"
  [ -n "$backend" ] && [ -n "$name" ] || return 0
  local dir
  dir=$(acq_host_config_dir "$backend" "$name") || return 0
  # Guard against a pathological empty resolution before rm -rf.
  case "$dir" in
    ""|/|/*/) return 0 ;;
    *.config) rm -rf "$dir" 2>/dev/null || true ;;
  esac
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
# Run the fix before attaching an opencode agent so a broken packaged binary can
# recover without changing the agent launch path.
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

_acq_host_git_config_value() {
  command -v git >/dev/null 2>&1 || return 0
  HOME="${HOME:-}" git config --global --get "$1" 2>/dev/null || true
}

_acq_git_identity_value_is_safe() {
  local val="$1" nl tab
  nl=$(printf '\n_'); nl=${nl%_}
  tab=$(printf '\t')
  case "$val" in
    *"$nl"*|*"$tab"*) return 1 ;;
    *) return 0 ;;
  esac
}

acq_host_git_identity_env() {
  local email
  if [ -n "${GIT_AUTHOR_NAME:-}" ] && _acq_git_identity_value_is_safe "$GIT_AUTHOR_NAME"; then
    printf 'GIT_AUTHOR_NAME=%s\n' "$GIT_AUTHOR_NAME"
  fi
  if [ -n "${GIT_AUTHOR_EMAIL:-}" ] && _acq_git_identity_value_is_safe "$GIT_AUTHOR_EMAIL"; then
    printf 'GIT_AUTHOR_EMAIL=%s\n' "$GIT_AUTHOR_EMAIL"
  fi
  if [ -n "${GIT_COMMITTER_NAME:-}" ] && _acq_git_identity_value_is_safe "$GIT_COMMITTER_NAME"; then
    printf 'GIT_COMMITTER_NAME=%s\n' "$GIT_COMMITTER_NAME"
  fi
  if [ -n "${GIT_COMMITTER_EMAIL:-}" ] && _acq_git_identity_value_is_safe "$GIT_COMMITTER_EMAIL"; then
    printf 'GIT_COMMITTER_EMAIL=%s\n' "$GIT_COMMITTER_EMAIL"
  fi
  if [ -n "${EMAIL:-}" ] && _acq_git_identity_value_is_safe "$EMAIL"; then
    printf 'EMAIL=%s\n' "$EMAIL"
  else
    email=$(_acq_host_git_config_value user.email)
    if [ -n "$email" ] && _acq_git_identity_value_is_safe "$email"; then
      printf 'EMAIL=%s\n' "$email"
    fi
  fi
}

acq_host_git_global_config_env() {
  local name email
  name=$(_acq_host_git_config_value user.name)
  email=$(_acq_host_git_config_value user.email)
  if [ -n "$name" ] && _acq_git_identity_value_is_safe "$name"; then
    printf 'ACQ_GIT_USER_NAME=%s\n' "$name"
  fi
  if [ -n "$email" ] && _acq_git_identity_value_is_safe "$email"; then
    printf 'ACQ_GIT_USER_EMAIL=%s\n' "$email"
  fi
}

# Warn (do not block) if the mounted workspace has no usable git identity.
# A repo-local identity crosses through the mounted workspace. When present, acq
# also forwards the host's explicit GIT_* identity env or global git identity as
# standard git author/committer env vars for guest commands. Classifies the
# workspace path P into four cases:
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

  local host_email
  if [ -n "${EMAIL:-}" ] && _acq_git_identity_value_is_safe "$EMAIL"; then
    return 0
  fi
  if [ -n "${GIT_AUTHOR_EMAIL:-}" ] && [ -n "${GIT_COMMITTER_EMAIL:-}" ] \
      && _acq_git_identity_value_is_safe "$GIT_AUTHOR_EMAIL" \
      && _acq_git_identity_value_is_safe "$GIT_COMMITTER_EMAIL"; then
    return 0
  fi
  host_email=$(_acq_host_git_config_value user.email)
  if [ -n "$host_email" ] && _acq_git_identity_value_is_safe "$host_email"; then
    return 0
  fi

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
# Refuses multi-owner workspaces because acq stores one sandbox-scoped GitHub
# token today, while GitHub fine-grained PATs are single-owner. Never places the
# token in argv (delegates to acq_secret_set_interactive via the backend secret
# path).
github_scope_sandbox() {
  local sandbox="$1" ws="${2:-}"
  local repos owners="" nwo owner owner_key owner_count=0

  repos=$(detect_workspace_repos "$ws")
  if [ -z "$repos" ]; then
    echo "acq: no GitHub repositories detected in the workspace; nothing to scope." >&2
    return 0
  fi

  # Distinct owners.
  while IFS= read -r nwo; do
    [ -n "$nwo" ] || continue
    owner="${nwo%%/*}"
    owner_key=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
    case "$owners" in *"|$owner_key="*) ;; *) owners="$owners|$owner_key=$owner|"; owner_count=$((owner_count + 1)) ;; esac
  done <<EOF
$repos
EOF

  if [ "$owner_count" -gt 1 ]; then
    echo "acq: cannot create a repo-scoped GitHub token for sandbox '$sandbox'." >&2
    echo "      This workspace contains GitHub repositories owned by multiple accounts," >&2
    echo "      but acq stores one sandbox-scoped GitHub token today and GitHub" >&2
    echo "      fine-grained PATs are scoped to a single owner." >&2
    echo "" >&2
    echo "      Detected repositories:" >&2
    while IFS= read -r nwo; do [ -n "$nwo" ] && printf '        %s\n' "$nwo" >&2; done <<EOF
$repos
EOF
    echo "" >&2
    echo "      Re-run with a workspace path containing repos from only one owner:" >&2
    echo "        acq github-scope $sandbox /path/to/one-owner-workspace" >&2
    return 1
  fi

  echo "acq: scoping a GitHub token for sandbox '$sandbox'." >&2
  echo "" >&2
  echo "      GitHub has no API to mint a fine-grained PAT, so create it in the" >&2
  echo "      browser. Open the pre-filled link, select 'Only select" >&2
  echo "      repositories' and choose the repo(s) listed below," >&2
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
    o="${o#*=}"
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

  # The configured default (ADR-0031) pre-answers this prompt: `acq configure`
  # can set scope_github_token: yes|no in config.yaml. Default is "no" (a bare
  # ENTER declines), preserving the historical behavior when unset. This only
  # changes the DEFAULT answer — the actual per-sandbox fine-grained-PAT minting
  # still runs through github_scope_sandbox (ADR-0013 unchanged).
  local scope_default
  scope_default=$(_acq_config_read_field scope_github_token)
  case "$scope_default" in yes|y|Y) scope_default="yes" ;; *) scope_default="no" ;; esac

  if acq_prompt_confirm "Scope a GitHub token for this sandbox now?" "$scope_default"; then
    github_scope_sandbox "$sandbox" "$ws"
  else
    echo "acq: continuing without scoping (run 'acq github-scope $sandbox $ws' anytime)." >&2
  fi
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

# ============================================================================
# acq doctor output helpers
# ============================================================================

acq_image_contract_doctor_script() {
  cat <<'SH'
ACQ_ADR0030_IMAGE_DIAGNOSTIC=1
warns=0
ok() { printf '  ok: %s\n' "$1"; }
warn() {
  warns=$((warns + 1))
  printf '  warning: %s\n' "$1"
  printf '           fix: %s\n' "$2"
}

if [ "${HOME:-}" = "/home/agent" ]; then
  ok "HOME is /home/agent"
else
  warn "HOME is ${HOME:-unset}, not /home/agent" "run diagnostics as the agent user with HOME=/home/agent"
fi

if [ "$(id -un 2>/dev/null || true)" = "agent" ]; then
  ok "running as agent user"
else
  warn "diagnostic is not running as the agent user" "run sandbox diagnostics as the unprivileged agent user"
fi

if [ -d /nix ]; then
  ok "/nix exists"
  if [ -w /nix 2>/dev/null ]; then
    ok "/nix is writable"
  else
    warn "/nix is not writable" "mount or bake a writable Nix store at /nix for devenv/cache reuse"
  fi
else
  warn "/nix is missing" "use a devenv-capable image with its Nix store at /nix"
fi

for tool in nix devenv direnv; do
  if command -v "$tool" >/dev/null 2>&1; then
    ver=$($tool --version 2>/dev/null | head -n1 || true)
    if [ -n "$ver" ]; then
      ok "$tool is on PATH ($ver)"
    else
      ok "$tool is on PATH"
    fi
  else
    warn "$tool is not on PATH" "install $tool in the base image or a create-time kit"
  fi
done

if [ -w /home/agent ]; then
  ok "/home/agent is writable"
else
  warn "/home/agent is not writable" "make /home/agent owned/writable by the agent user"
fi

if command -v sudo >/dev/null 2>&1; then
  # Best-effort privilege probe: sudo -n may update guest-local sudo/audit state.
  if sudo -n true >/dev/null 2>&1; then
    ok "passwordless sudo probe works"
  else
    warn "sudo exists but passwordless sudo probe failed" "grant NOPASSWD sudo for declared privileged kit steps"
  fi
else
  warn "sudo is not on PATH" "install sudo and allow passwordless sudo where privileged kit features are needed"
fi

home=${HOME:-/home/agent}
if [ -d "$home/.rc.d" ]; then
  ok "~/.rc.d exists"
else
  warn "~/.rc.d is missing" "install the neutral shell hook directory at /home/agent/.rc.d"
fi

hook=0
for profile in "$home/.profile" "$home/.bashrc" "$home/.zshrc" /etc/profile /etc/bash.bashrc /etc/profile.d/acq*.sh; do
  # Match either an explicit `source/.  …rc.d…` line OR acq's own login bridge
  # marker (acq-login-profile), whose loop sources ~/.rc.d indirectly through a
  # variable — so a plain `source .rc.d` grep alone would miss it. See ADR-0030.
  if [ -f "$profile" ] \
      && grep -Eq '(^|[[:space:]])(source|\.)[[:space:]].*\.rc\.d|acq-login-profile' "$profile" 2>/dev/null; then
    hook=1
    break
  fi
done
if [ "$hook" -eq 1 ]; then
  ok "shell startup references ~/.rc.d"
else
  warn "no shell startup hook for ~/.rc.d found" "source ~/.rc.d snippets from shell startup in deterministic order"
fi

printf '  summary: %s warning(s); diagnostics only, create/run are not blocked\n' "$warns"
exit 0
SH
}

acq_print_image_contract_doctor() {
  local name="$1"
  if ! command -v acq_backend_doctor_sandbox >/dev/null 2>&1; then
    echo "acq: doctor: backend '${ACQ_RESOLVED_BACKEND:-unknown}' cannot inspect sandboxes." >&2
    return 1
  fi
  if ! acq_backend_exists "$name"; then
    echo "acq: doctor: no such sandbox '$name'." >&2
    return 1
  fi

  printf 'acq: ADR-0030 image contract diagnostics for %s (backend: %s)\n' \
    "$name" "${ACQ_RESOLVED_BACKEND:-unknown}"
  echo "  This check is non-enforcing: warnings do not change create/run behavior."
  acq_backend_doctor_sandbox "$name"
}

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
      # Write only the backend key, preserving any other config (extra_kits,
      # scope_github_token) written by `acq configure` (ADR-0031).
      _acq_config_write_field backend "${ACQ_RESOLVED_BACKEND:-msb}"
      echo "  Wrote default backend to ${config_file}." >&2
      ;;
    *)
      echo "  Not written." >&2
      ;;
  esac
}

# ============================================================================
# Interactive configuration (`acq configure`; ADR-0031)
# ============================================================================

# _acq_configure_show_current — print the current durable configuration
# (config.yaml) to stderr, so `acq configure` opens by showing what is in effect.
_acq_configure_show_current() {
  local cfg backend extras scope bindings provider_kit sources
  cfg=$(_acq_config_file)
  backend=$(_acq_config_read_field backend)
  extras=$(_acq_config_read_field extra_kits)
  scope=$(_acq_config_read_field scope_github_token)
  bindings=$(_acq_config_read_field "$ACQ_PROVIDER_CREDENTIAL_CONFIG_KEY")
  provider_kit=$(_acq_config_read_field "$ACQ_PROVIDER_KIT_CONFIG_KEY")
  sources=$(_acq_config_read_field "$ACQ_KIT_SOURCE_CONFIG_KEY")
  echo "acq: current configuration (${cfg}):" >&2
  echo "      default backend:    ${backend:-<auto-detect>}" >&2
  echo "      extra kits:         ${extras:-<none>}" >&2
  echo "      scope GitHub token: ${scope:-no}" >&2
  echo "      provider creds:     ${bindings:-<none>}   (acq provider-credential ls)" >&2
  echo "      provider kit:       ${provider_kit:-$ACQ_PROVIDER_KIT_DEFAULT}   (acq kit-source ls)" >&2
  echo "      kit sources:        ${sources:-<shipped default>}" >&2
  echo "" >&2
}

# acq_configure — the interactive configuration flow. Presents the opt-in kit
# catalog as a multiselect (pre-checked from the current config), then a confirm
# for the GitHub-token-scoping default, and persists both to config.yaml
# (preserving the `backend:` key). Non-interactive callers keep the current
# config unchanged (the widgets fail-open to defaults) and only re-print it.
#
# The kit selection is stored as a whitespace-separated list of the CHOSEN opt-in
# kit NAMES (e.g. "openchamber paseo") under extra_kits:, not the fully-expanded
# git refs — the ref is rebuilt from PATTERNS_KIT_REF at apply time so a later pin
# bump moves configured kits forward automatically. A user's own custom refs (set
# via ACQ_EXTRA_KITS) are layered separately and are not managed here.
acq_configure() {
  _acq_configure_show_current

  # Non-interactive (CI / piped / ACQ_NO_PROMPT): make NO changes — just show the
  # current config above and return. Writing here would clobber a hand-edited or
  # previously-configured file with the widget defaults.
  if ! _acq_prompt_interactive; then
    echo "acq: non-interactive; configuration unchanged." >&2
    echo "      Run 'acq configure' from a terminal to change kits/token scoping." >&2
    return 0
  fi

  local n="${#ACQ_OPTIN_KIT_NAMES[@]}"
  if [ "$n" -eq 0 ]; then
    echo "acq: no opt-in kits are available to configure." >&2
    return 0
  fi

  # Which opt-in kits are already selected (from config), as a set of names.
  local current_extras selected_names=""
  current_extras=$(_acq_config_read_field extra_kits)

  # Build the picker's argument list: the built-in kits FIRST as frozen
  # ("always applied") rows, then the toggleable opt-in kits. The defaults CSV
  # is RELATIVE to the toggleable block (index 1 = first opt-in kit), matching
  # the multiselect contract, so it is unaffected by the number of locked rows.
  local args=() defaults="" i name desc
  local locked_n="${#ACQ_KIT_NAMES[@]}"
  i=1
  while [ "$i" -le "$locked_n" ]; do
    args+=("${ACQ_KIT_NAMES[$((i-1))]}" "${ACQ_KIT_DESCS[$((i-1))]}")
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le "$n" ]; do
    name="${ACQ_OPTIN_KIT_NAMES[$((i-1))]}"
    desc="${ACQ_OPTIN_KIT_DESCS[$((i-1))]}"
    args+=("$name" "$desc")
    # Pre-check if this kit name appears in the configured extras (word match).
    case " $current_extras " in *" $name "*) defaults="${defaults:+$defaults,}$i" ;; esac
    i=$((i + 1))
  done

  # Run the picker in-process (NOT via $(...)) so the shared scripted-input
  # cursor advances into the token-scoping confirm below; read the result from
  # the _ACQ_PROMPT_SELECTION global. Chosen indices are relative to the opt-in
  # block, so the index→name mapping below is unchanged by the frozen rows.
  local chosen
  acq_prompt_multiselect "$locked_n" "$defaults" "${args[@]}" >/dev/null
  chosen="$_ACQ_PROMPT_SELECTION"

  # CANCELLED → leave config untouched.
  if [ "$chosen" = "CANCELLED" ]; then
    return 0
  fi

  # Map chosen indices back to kit names.
  local idx
  for idx in $chosen; do
    case "$idx" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ]; then
      name="${ACQ_OPTIN_KIT_NAMES[$((idx-1))]}"
      selected_names="${selected_names:+$selected_names }$name"
    fi
  done

  # Persist the kit selection (empty removes the key).
  _acq_config_write_field extra_kits "$selected_names"

  # GitHub-token-scoping default.
  local scope_current scope_default
  scope_current=$(_acq_config_read_field scope_github_token)
  case "$scope_current" in yes|y|Y) scope_default="yes" ;; *) scope_default="no" ;; esac
  if acq_prompt_confirm "Scope a per-sandbox GitHub token by default (on create)?" "$scope_default"; then
    _acq_config_write_field scope_github_token yes
  else
    _acq_config_write_field scope_github_token no
  fi

  # Provider kit (single select). Candidates are the shipped default plus every
  # provider kit discovered in a trusted source, so a user can pick
  # e.g. `opencode-go-provider` without hand-writing a git+https ref.
  local candidates=() labels=() candidate label provider_default="" provider_sel=""
  local current_provider pidx pargs=()
  while IFS="$(printf '\t')" read -r candidate label; do
    [ -n "$candidate" ] || continue
    candidates+=("$candidate")
    labels+=("$label")
  done < <(acq_provider_kit_candidates 2>/dev/null)
  current_provider=$(_acq_config_read_field "$ACQ_PROVIDER_KIT_CONFIG_KEY")
  [ -n "$current_provider" ] || current_provider="$ACQ_PROVIDER_KIT_DEFAULT"
  pidx=1
  while [ "$pidx" -le "${#candidates[@]}" ]; do
    candidate="${candidates[$((pidx-1))]}"
    pargs+=("$candidate" "${labels[$((pidx-1))]}")
    case "$candidate" in
      "$current_provider") provider_default="$pidx" ;;
    esac
    pidx=$((pidx + 1))
  done
  if [ "${#candidates[@]}" -gt 0 ]; then
    acq_prompt_multiselect 0 "$provider_default" "${pargs[@]}" >/dev/null
    if [ "$_ACQ_PROMPT_SELECTION" != "CANCELLED" ] && [ -n "$_ACQ_PROMPT_SELECTION" ]; then
      set -- $_ACQ_PROMPT_SELECTION
      if [ "$1" -ge 1 ] && [ "$1" -le "${#candidates[@]}" ] 2>/dev/null; then
        provider_sel="${candidates[$(($1 - 1))]}"
        [ -n "$provider_sel" ] && _acq_config_write_field "$ACQ_PROVIDER_KIT_CONFIG_KEY" "$provider_sel"
      fi
    fi
  fi

  echo "" >&2
  echo "acq: configuration saved to $(_acq_config_file)." >&2
  echo "      extra kits:         ${selected_names:-<none>}" >&2
  echo "      provider kit:       ${provider_sel:-$current_provider}" >&2
  return 0
}

# maybe_first_run_configure — on first run (no config.yaml yet) and interactive,
# offer to run `acq configure` once. Declining still writes a minimal config
# (an empty scope_github_token line is avoided; we write the resolved backend if
# known, else touch the file) so the offer never repeats. Fully skipped when
# non-interactive (CI / piped) — fail-open, preserving today's behavior.
maybe_first_run_configure() {
  local cfg dir
  cfg=$(_acq_config_file)
  [ -f "$cfg" ] && return 0        # already configured (or previously offered)
  _acq_prompt_interactive || return 0   # non-interactive: skip silently

  echo "acq: looks like this is your first run — let's set up your kits." >&2
  echo "      (You can re-run this anytime with 'acq configure'.)" >&2
  echo "" >&2
  if acq_prompt_confirm "Configure extra kits and token scoping now?" "yes"; then
    acq_configure
  else
    # Write a minimal config so the first-run offer does not repeat. Prefer the
    # resolved backend if one is known; otherwise create an empty file.
    if [ -n "${ACQ_RESOLVED_BACKEND:-}" ]; then
      _acq_config_write_field backend "$ACQ_RESOLVED_BACKEND"
    else
      dir=$(dirname "$cfg")
      ( umask 077; mkdir -p "$dir" && : > "$cfg" ) 2>/dev/null || true
      chmod 700 "$dir" 2>/dev/null || true
      chmod 600 "$cfg" 2>/dev/null || true
    fi
    echo "acq: skipped. Run 'acq configure' anytime to change kits/token scoping." >&2
  fi
  return 0
}

# create_time_kit_picker — at `acq create`/`run` (fresh create only), offer the
# opt-in kit picker PRE-POPULATED from the configured global defaults, so a user
# can enable/disable a kit for THIS sandbox without changing the global default.
# The selection is folded into ACQ_EXTRA_KITS for this invocation (as fully-
# expanded refs), which flows through _build_kit_list and is persisted PER-SANDBOX
# by the existing acq_cli_kits_write path (ADR-0017) — reloaded on resume by
# acq_cli_kits_load. No global config is written here (that is `acq configure`).
#
# Fail-open: non-interactive (CI / piped) makes no prompt and simply lets the
# configured defaults apply via _acq_apply_configured_extra_kits (already called
# before provisioning). Idempotent per process.
_ACQ_CREATE_PICKER_DONE=""
create_time_kit_picker() {
  [ -z "$_ACQ_CREATE_PICKER_DONE" ] || return 0
  _ACQ_CREATE_PICKER_DONE=1

  # Only prompt interactively; otherwise the configured defaults already applied.
  _acq_prompt_interactive || return 0

  local n="${#ACQ_OPTIN_KIT_NAMES[@]}"
  [ "$n" -gt 0 ] || return 0

  # Defaults = the configured global extra_kits (kit NAMES). An env-supplied
  # ACQ_EXTRA_KITS is authoritative and NOT re-prompted (env > interactive).
  [ -z "${ACQ_EXTRA_KITS_FROM_ENV:-}" ] || return 0

  local configured args=() defaults="" i name desc
  local locked_n="${#ACQ_KIT_NAMES[@]}"
  configured=$(_acq_config_read_field extra_kits)
  # Built-in kits first as frozen rows (consistent with `acq configure`).
  i=1
  while [ "$i" -le "$locked_n" ]; do
    args+=("${ACQ_KIT_NAMES[$((i-1))]}" "${ACQ_KIT_DESCS[$((i-1))]}")
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le "$n" ]; do
    name="${ACQ_OPTIN_KIT_NAMES[$((i-1))]}"
    desc="${ACQ_OPTIN_KIT_DESCS[$((i-1))]}"
    args+=("$name" "$desc")
    case " $configured " in *" $name "*) defaults="${defaults:+$defaults,}$i" ;; esac
    i=$((i + 1))
  done

  echo "acq: extra kits for this sandbox (defaults from 'acq configure'):" >&2
  # In-process (not $(...)) so the selection lands in _ACQ_PROMPT_SELECTION.
  local chosen
  acq_prompt_multiselect "$locked_n" "$defaults" "${args[@]}" >/dev/null
  chosen="$_ACQ_PROMPT_SELECTION"
  [ "$chosen" = "CANCELLED" ] && return 0

  # Map chosen indices → fully-expanded kit refs, and set ACQ_EXTRA_KITS for this
  # invocation (replacing the configured-default application, which we override
  # deliberately: the picker's result is authoritative for this create).
  local refs="" idx
  for idx in $chosen; do
    case "$idx" in ''|*[!0-9]*) continue ;; esac
    if [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ]; then
      name="${ACQ_OPTIN_KIT_NAMES[$((idx-1))]}"
      refs="${refs:+$refs }$(_acq_optin_kit_ref "$name")"
    fi
  done
  ACQ_EXTRA_KITS="$refs"
  acq_debug "create-picker: ACQ_EXTRA_KITS set to: $refs"
  return 0
}
