#!/bin/bash
#
# acq.backends/sbx.sh — sbx backend adapter for acq
#
# Implements the adapter contract defined in
# docs/adr/0010-acq-pluggable-backends.md ("Adapter contract"). Each
# acq_backend_* function maps the acq contract to the sbx CLI.
#
# ---------------------------------------------------------------------------
# Neutral-kit consumption (Phase 2 / 1.2.x)
# ---------------------------------------------------------------------------
# Kits are now authored in the neutral hybrid/v1 vocabulary (acq-kits/ in the
# patterns repo). sbx cannot consume that schema natively (it expects its own
# schemaVersion "2" spec), so this adapter fetches each neutral kit and uses
# kit-translate.sh to SYNTHESIZE an equivalent sbx-v2 kit directory locally,
# then hands the local dir to `sbx --kit` / `sbx kit add`. The payloads and
# behavior are carried verbatim, so the observable result for an sbx user is
# identical to Phase 1. See docs/adr/0011-msb-backend-and-neutral-kits.md.

# Capability flags (per the ADR-0010 contract). common.sh may gate features on
# these once multiple backends coexist.
# shellcheck disable=SC2034
ACQ_BACKEND_NAME="sbx"
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_PORT_FORWARD=1
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_SNAPSHOTS=0
# shellcheck disable=SC2034
ACQ_BACKEND_CAN_RESUME=1
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE=1

# Minimum sbx version required.
MIN_SBX_VERSION="0.35.0"

# Max seconds to wait for `sbx exec` to become usable.
ACQ_EXEC_READY_TIMEOUT="${ACQ_EXEC_READY_TIMEOUT:-60}"

# Absolute path where the usai-provider kit stages its OpenCode config.
USAI_KIT_CONFIG_PATH="/home/agent/usai-config/opencode.jsonc"

# Where synthesized sbx-v2 kits (translated from the neutral hybrid/v1 kits)
# are materialized for this run.
ACQ_SBX_KIT_CACHE="${ACQ_SBX_KIT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/acq/sbx-kits}"

# Agents recognized by `sbx run`.
KNOWN_AGENTS=" claude codex copilot cursor docker-agent droid gemini kiro opencode shell "

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------

version_ge() {
  local a="$1" b="$2" i a_part b_part
  local -a a_arr b_arr
  IFS='.' read -r -a a_arr <<EOF
$a
EOF
  IFS='.' read -r -a b_arr <<EOF
$b
EOF
  for i in 0 1 2; do
    a_part=${a_arr[i]:-0}; b_part=${b_arr[i]:-0}
    a_part=${a_part%%[!0-9]*}; b_part=${b_part%%[!0-9]*}
    a_part=${a_part:-0}; b_part=${b_part:-0}
    if [ "$a_part" -gt "$b_part" ]; then echo 0; return; fi
    if [ "$a_part" -lt "$b_part" ]; then echo 1; return; fi
  done
  echo 0
}

# ---------------------------------------------------------------------------
# acq_backend_prepare — sbx version floor check
# ---------------------------------------------------------------------------

acq_backend_prepare() {
  if ! command -v sbx >/dev/null 2>&1; then
    echo "error: sbx CLI not found on PATH. Install sbx >= $MIN_SBX_VERSION." >&2
    echo "       See README.md (Step 2: Install sbx CLI)." >&2
    exit 1
  fi

  local raw current
  raw=$(sbx version 2>/dev/null || true)
  current=$(printf '%s\n' "$raw" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed 's/^v//')

  if [ -z "$current" ]; then
    echo "acq: warning: could not determine sbx version (need >= $MIN_SBX_VERSION); continuing." >&2
    return 0
  fi

  if [ "$(version_ge "$current" "$MIN_SBX_VERSION")" -ne 0 ]; then
    local os arch
    os=$(uname -s 2>/dev/null || echo unknown)
    arch=$(uname -m 2>/dev/null || echo unknown)
    if [ "$os" = "Linux" ] && { [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; }; then
      echo "error: acq requires sbx >= $MIN_SBX_VERSION, but found $current, and" >&2
      echo "       sbx $MIN_SBX_VERSION.x publishes NO Linux/ARM64 build (deferred to" >&2
      echo "       0.36.x per the sbx release notes). On Linux/ARM64 you cannot yet" >&2
      echo "       install a version that satisfies this floor. Options:" >&2
      echo "         - run acq on an x86_64 host (sbx has a 0.35.x build there), or" >&2
      echo "         - wait for the sbx 0.36.x release, which restores ARM64 builds." >&2
      exit 1
    fi
    echo "error: acq requires sbx >= $MIN_SBX_VERSION, but found $current." >&2
    echo "       sbx 0.35.0 is required so that 'sbx kit add' recreates the sandbox" >&2
    echo "       preserving state when healing pre-kit sandboxes." >&2
    echo "       Upgrade sbx (see README.md, Step 2) and retry." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_exists — check if a named sandbox exists
# ---------------------------------------------------------------------------

acq_backend_exists() {
  sbx ls -q 2>/dev/null | grep -Fxq -- "$1"
}

# ---------------------------------------------------------------------------
# Ensure kit source prefixes are on sbx's kit.allowedSources allowlist.
# ---------------------------------------------------------------------------

_acq_sbx_kit_sources_manual_hint() {
  local reason="$1" cmd cur
  echo "acq: warning: $reason." >&2
  if command -v jq >/dev/null 2>&1; then
    cur=$(sbx settings get kit.allowedSources 2>/dev/null || true)
    printf '%s' "$cur" | jq -e 'type == "array"' >/dev/null 2>&1 || cur='["docker.io/"]'
    cmd=$(printf '%s' "$cur" | jq -c --args \
      'reduce $ARGS.positional[] as $p (.; if index($p) then . else . + [$p] end)' \
      "${KIT_SOURCE_PREFIXES[@]}" 2>/dev/null)
  fi
  [ -z "${cmd:-}" ] && cmd='["docker.io/","github.com/GSA-TTS/"]'
  echo "      If kit resolution fails, review the current value and run:" >&2
  echo "        sbx settings set kit.allowedSources '${cmd}'" >&2
}

_acq_sbx_ensure_kit_sources_allowed() {
  local current desired

  if ! command -v jq >/dev/null 2>&1; then
    _acq_sbx_kit_sources_manual_hint "jq not found; cannot safely update the allowlist"
    return 0
  fi

  current=$(sbx settings get kit.allowedSources 2>/dev/null || true)

  if ! printf '%s' "$current" | jq -e 'type == "array"' >/dev/null 2>&1; then
    _acq_sbx_kit_sources_manual_hint "could not read kit.allowedSources as a JSON array"
    return 0
  fi

  desired=$(printf '%s' "$current" | jq -c --args \
    'reduce $ARGS.positional[] as $p (.; if index($p) then . else . + [$p] end)' \
    "${KIT_SOURCE_PREFIXES[@]}" 2>/dev/null)
  if [ -z "$desired" ]; then
    _acq_sbx_kit_sources_manual_hint "failed to compute updated allowlist"
    return 0
  fi

  if [ "$(printf '%s' "$current" | jq -cS .)" = "$(printf '%s' "$desired" | jq -cS .)" ]; then
    return 0
  fi

  if sbx settings set kit.allowedSources "$desired" </dev/null >/dev/null 2>&1; then
    echo "acq: updated sbx kit.allowedSources to: $(printf '%s' "$desired" | jq -r '.[]' | tr '\n' ' ')" >&2
  else
    _acq_sbx_kit_sources_manual_hint "could not write kit.allowedSources"
  fi
}

# ---------------------------------------------------------------------------
# Neutral-kit → sbx-v2 translation
# ---------------------------------------------------------------------------
# Given a neutral kit ref (remote git+https or local dir), fetch it and
# synthesize a local sbx-v2 kit directory. Echoes the local sbx-v2 kit dir.
# Falls back to passing the ref through unchanged if translation is unavailable
# (e.g. an extra kit that is already an sbx-v2 kit), so existing extra-kit
# workflows keep working.
_acq_sbx_translate_kit() {
  local kitref="$1" slug fetchdir kitdir out
  # Offline/test escape hatch: pass the ref through unchanged. Used by the
  # offline unit harness (no network) and by any environment that pre-resolves
  # kits. Never set this in production — sbx would then receive a neutral
  # hybrid/v1 ref it cannot parse.
  if [ -n "${ACQ_SBX_KIT_PASSTHROUGH:-}" ]; then
    printf '%s\n' "$kitref"
    return 0
  fi
  # If kit-translate isn't loaded (shouldn't happen), pass through unchanged.
  if ! command -v kit_translate_fetch >/dev/null 2>&1; then
    printf '%s\n' "$kitref"
    return 0
  fi

  slug=$(printf '%s' "$kitref" | tr -c 'A-Za-z0-9._-' '_')
  fetchdir="${ACQ_SBX_KIT_CACHE}/fetch/${slug}"
  out="${ACQ_SBX_KIT_CACHE}/v2/${slug}"

  kitdir=$(kit_translate_fetch "$kitref" "$fetchdir") || {
    # #208: make this loud + actionable rather than a terse warning. For a
    # git+https ref, a failure here (after kit-translate's non-interactive
    # anonymous+authed retries) is a real fetch problem, not a prompt hang.
    # Passing the ref through lets sbx try its own fetch (and keeps pre-resolved
    # extra-kit workflows working), but the user needs to know WHY it failed.
    case "$kitref" in
      git+http*)
        echo "acq(sbx): WARNING: could not fetch kit: $kitref" >&2
        echo "acq(sbx):   If git prompted for a GitHub username/password, run 'gh auth" >&2
        echo "acq(sbx):   setup-git' once (gh auth != git auth), or check for a rewrite:" >&2
        echo "acq(sbx):   git config --global --get-regexp 'url\\..*insteadOf'." >&2
        echo "acq(sbx):   Passing the ref through to sbx to attempt its own fetch." >&2
        ;;
      *)
        echo "acq(sbx): warning: could not fetch kit; passing ref through: $kitref" >&2
        ;;
    esac
    printf '%s\n' "$kitref"
    return 0
  }

  # Only translate kits that are neutral hybrid/v1. If the fetched kit is
  # already an sbx-v2 kit (an extra kit authored for sbx), pass its dir through.
  local schema
  schema=$(kit_spec_field "${kitdir}/spec.yaml" schemaVersion 2>/dev/null || true)
  case "$schema" in
    hybrid/v1)
      acq_debug "translate(sbx): $kitref -> $out"
      rm -rf "$out"
      kit_translate_to_sbx "$kitdir" "$out" >/dev/null || {
        echo "acq(sbx): warning: kit translation failed; passing ref through: $kitref" >&2
        printf '%s\n' "$kitref"
        return 0
      }
      printf '%s\n' "$out"
      ;;
    *)
      # Not a neutral kit — use the fetched dir (or the original ref) as-is.
      printf '%s\n' "$kitdir"
      ;;
  esac
}

# Emit --kit flags for all kits (built-ins + extras), translating each neutral
# hybrid/v1 kit to a local sbx-v2 kit dir first. One token per line.
_acq_sbx_kit_flags() {
  local k local_kit
  for k in "${KITS[@]}"; do
    local_kit=$(_acq_sbx_translate_kit "$k")
    printf '%s\n%s\n' "--kit" "$local_kit"
  done
}

# ---------------------------------------------------------------------------
# Wait for sbx exec to become ready in a sandbox (after create or restart).
# ---------------------------------------------------------------------------

_acq_sbx_wait_for_exec_ready() {
  local name="$1" deadline out
  deadline=$(( $(date +%s) + ACQ_EXEC_READY_TIMEOUT ))
  while :; do
    out=$(sbx exec "$name" -- sh -c 'echo ok' </dev/null 2>/dev/null | tr -d '\r')
    case "$out" in
      *ok*) return 0 ;;
    esac
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 2
  done
}

# Probe a feature inside a sandbox. Returns 0=absent, 1=present, 2=probe failed.
# IMPORTANT: `snippet` MUST end with " && echo present" — e.g.:
#   "test -f '/path/to/file' && echo present"
# The %% strip removes that suffix to build the if-condition; a snippet that
# does not include it will produce a malformed wrapped command silently.
# Note: >/dev/null 2>&1 suppresses the test's stderr, so a probe that fails
# for an unexpected reason (e.g. bad path syntax) returns "absent" and triggers
# a spurious kit-add rather than a hard error.
_acq_sbx_kit_feature_absent() {
  local name="$1" snippet="$2" out tries=0
  # Defensive: catch callers that forget the " && echo present" suffix.
  if [ "${snippet}" = "${snippet%% && echo present}" ]; then
    echo "acq: internal error: _acq_sbx_kit_feature_absent: snippet must end with ' && echo present': ${snippet}" >&2
    return 2
  fi
  local wrapped="if ${snippet%% && echo present}"' >/dev/null 2>&1; then echo present; else echo absent; fi'
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    out=$(sbx exec "$name" -- sh -c "$wrapped" </dev/null 2>/dev/null | tr -d '\r')
    case "$out" in
      *present*) return 1 ;;
      *absent*)  return 0 ;;
    esac
    sleep 2
  done
  return 2
}

# Run a snippet inside a sandbox with retry.
_acq_sbx_exec_retry() {
  local name="$1" snippet="$2" out rc tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    out=$(sbx exec "$name" -- sh -c "$snippet" </dev/null 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && { printf '%s' "$out"; return 0; }
    sleep 2
  done
  printf '%s' "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# acq_backend_provision — create a sandbox with kits applied
# ---------------------------------------------------------------------------

acq_backend_provision() {
  _acq_sbx_ensure_kit_sources_allowed
  local name="$1"
  shift
  # Strip any user-supplied --name since we pass it explicitly.
  local _stripped=(); local skip=0
  for arg in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$arg" in
      --name) skip=1; continue ;;
      --name=*) continue ;;
    esac
    _stripped+=("$arg")
  done

  local kf=()
  while IFS= read -r line; do kf+=("$line"); done < <(_acq_sbx_kit_flags)

  acq_debug "sbx create --name $name ${kf[*]} ${_stripped[*]:-}"
  acq_spin_start "Creating sandbox '$name'"
  if [ "${#_stripped[@]}" -gt 0 ]; then
    sbx create --name "$name" "${kf[@]}" "${_stripped[@]}"
  else
    sbx create --name "$name" "${kf[@]}"
  fi
  local _rc=$?
  acq_spin_stop "Creating sandbox '$name'"
  # Record host-side bundle provenance ONLY after a successful create — a failed
  # create must not leave a record claiming the sandbox is current.
  if [ "$_rc" -eq 0 ]; then
    acq_provenance_write sbx "$name" || true
  fi
  return "$_rc"
}

# ---------------------------------------------------------------------------
# acq_backend_run — run a command inside a sandbox
# ---------------------------------------------------------------------------

acq_backend_run() {
  local name="$1"
  shift
  # Expect `-- CMD...` separator. No `-u agent` needed: sbx's agent templates
  # bake the unprivileged `agent` user (UID 1000, HOME=/home/agent) as the
  # default exec user, unlike a plain msb OCI base (which defaults to root).
  sbx exec "$name" "$@"
}

# ---------------------------------------------------------------------------
# acq_backend_attach — interactive attach
# ---------------------------------------------------------------------------

acq_backend_attach() {
  local name="$1"
  shift
  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
    shift
    sbx run --name "$name" -- "$@"
  else
    sbx run --name "$name"
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_stop / acq_backend_terminate / acq_backend_list / acq_backend_cp
# ---------------------------------------------------------------------------

acq_backend_stop() {
  sbx stop "$1"
}

# NO acq_backend_start on sbx — DELIBERATELY.
#
# The sbx CLI has no `start` (or `restart`) subcommand (`sbx --help`: create,
# exec, run, stop, rm, … — no start). sbx also has no equivalent of msb's
# "start but stay detached": with no attached session, sbx auto-idles a sandbox
# to the stopped state, and it is transparently resumed by the next `sbx run` /
# `sbx exec` (verified by hand). So there is nothing for a standalone resume
# primitive to do, and an earlier `sbx start "$1"` here was calling a
# non-existent subcommand (would fail with an unknown-command error).
#
# Because this function is intentionally undefined, the acq `start`/`restart`
# dispatcher's `command -v acq_backend_start` guard capability-gates those verbs
# on sbx with a clear message. The resume-on-attach path (`acq run <stopped>`)
# still works: acq_backend_ensure_kits_applied heals via `sbx kit add`/`sbx exec`
# and attach via `sbx run`, all of which auto-start a stopped sandbox — no
# explicit start needed. See ADR-0017 for the reconciled sbx lifecycle model.

acq_backend_terminate() {
  sbx rm --force "$1"
}

acq_backend_list() {
  sbx ls "$@"
}

acq_backend_cp() {
  sbx cp "$1" "$2"
}

acq_backend_ports() {
  local name="$1"
  shift
  sbx ports "$name" "$@"
}

# ---------------------------------------------------------------------------
# acq_backend_apply_kit — inject a kit into an existing sandbox mid-life
# ---------------------------------------------------------------------------

acq_backend_apply_kit() {
  local name="$1" kitref="$2" local_kit
  local_kit=$(_acq_sbx_translate_kit "$kitref")
  sbx kit add "$name" "$local_kit"
}

# ---------------------------------------------------------------------------
# acq_backend_ensure_kits_applied — heal a pre-kit sandbox in place
# ---------------------------------------------------------------------------
# Injects any ABSENT built-in kit. When ACQ_FORCE_KIT_REAPPLY=1 (set by
# acq_bundle_reapply for a stale-bundle refresh) it re-adds ALL
# built-in kits even when present, so a kit built from an older ref is actually
# refreshed — the feature-probe alone would skip a present-but-stale kit.
# Returns 0 only if every built-in kit is present-or-successfully-applied, so a
# caller can gate a provenance write on real success (never claim currency after
# a failed apply).

acq_backend_ensure_kits_applied() {
  local name="$1"
  local force="${ACQ_FORCE_KIT_REAPPLY:-0}"
  local ok=1

  _acq_sbx_ensure_kit_sources_allowed

  # Neutral kits must be translated to local sbx-v2 kit dirs before sbx kit add.
  local usai_local playbook_local zscaler_local
  usai_local=$(_acq_sbx_translate_kit "$USAI_KIT")
  playbook_local=$(_acq_sbx_translate_kit "$PLAYBOOK_KIT")
  zscaler_local=$(_acq_sbx_translate_kit "$ZSCALER_KIT")

  # 1) Zscaler CA kit — FIRST, so its CA trust is in place before any later kit
  # makes an outbound HTTPS request. Behind a TLS-intercepting proxy (Zscaler),
  # the USAi and playbook kits fail with a TLS 'unexpected eof' unless the
  # intercepting CA is already trusted.
  if [ "$force" = "1" ] || _acq_sbx_kit_feature_absent "$name" 'test -e /usr/local/share/ca-certificates/zscaler-ca.crt && echo present'; then
    echo "acq: '$name' is missing the Zscaler CA kit; injecting with 'sbx kit add'..." >&2
    if sbx kit add "$name" "$zscaler_local" </dev/null >/dev/null 2>&1; then
      echo "acq: Zscaler CA kit injected into '$name'." >&2
    else
      echo "acq: warning: 'sbx kit add' (Zscaler CA kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$zscaler_local'" >&2
      ok=0
    fi
  fi

  # 2) USAi provider kit
  if [ "$force" = "1" ] || _acq_sbx_kit_feature_absent "$name" "test -f '$USAI_KIT_CONFIG_PATH' && echo present"; then
    echo "acq: '$name' is missing the USAi kit; injecting with 'sbx kit add'..." >&2
    if sbx kit add "$name" "$usai_local" </dev/null >/dev/null 2>&1; then
      sbx exec "$name" -- sh -c \
        'f="$HOME/.config/opencode/opencode.jsonc"; if [ -L "$f" ] && [ ! -e "$f" ]; then rm -f "$f"; fi' \
        </dev/null >/dev/null 2>&1 || true
      echo "acq: USAi kit injected into '$name'." >&2
    else
      echo "acq: warning: 'sbx kit add' (USAi kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$usai_local'" >&2
      ok=0
    fi
  fi

  # 3) Playbook kit
  if [ "$force" = "1" ] || _acq_sbx_kit_feature_absent "$name" 'test -e "$HOME/.agentic-coding-playbook/.git" && echo present'; then
    echo "acq: '$name' is missing the playbook kit; injecting with 'sbx kit add'..." >&2
    if sbx kit add "$name" "$playbook_local" </dev/null >/dev/null 2>&1; then
      echo "acq: playbook kit injected into '$name'. Restart the agent to pick it up." >&2
    else
      echo "acq: warning: 'sbx kit add' (playbook kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$playbook_local'" >&2
      ok=0
    fi
  fi

  # 3b) git-ssh-sign kit. The original heal loop omitted this built-in kit; a
  # forced reapply (stale-bundle refresh) MUST cover the whole bundle, so
  # re-add it when forcing. On a normal heal we leave the historical behavior
  # (the kit self-heals via the playbook clone) unchanged.
  if [ "$force" = "1" ]; then
    local gitsshsign_local
    gitsshsign_local=$(_acq_sbx_translate_kit "$GITSSHSIGN_KIT")
    if sbx kit add "$name" "$gitsshsign_local" </dev/null >/dev/null 2>&1; then
      echo "acq: git-ssh-sign kit refreshed in '$name'." >&2
    else
      echo "acq: warning: 'sbx kit add' (git-ssh-sign kit) failed for '$name'." >&2
      ok=0
    fi
  fi

  # 4) Extra kits (tracked by marker file). Extra kits may be neutral or already
  #    sbx-v2; _acq_sbx_translate_kit handles both. The marker uses the original
  #    ref (stable across runs), not the translated local dir. Extra-kit failures
  #    do not affect the built-in bundle's provenance verdict.
  local applied k local_extra
  applied=$(sbx exec "$name" -- sh -c 'cat "$HOME/.acq-extra-kits" 2>/dev/null' </dev/null 2>/dev/null || true)
  local _extras=()
  [ -n "$ACQ_EXTRA_KITS" ] && split_noglob _extras "$ACQ_EXTRA_KITS"
  for k in ${_extras[@]+"${_extras[@]}"}; do
    case "$applied" in
      *"$k"*) continue ;;
    esac
    echo "acq: applying extra kit to '$name': $k" >&2
    local_extra=$(_acq_sbx_translate_kit "$k")
    if sbx kit add "$name" "$local_extra" </dev/null >/dev/null 2>&1; then
      sbx exec "$name" -- sh -c 'printf "%s\n" "$0" >> "$HOME/.acq-extra-kits"' "$k" </dev/null >/dev/null 2>&1 || true
    else
      echo "acq: warning: 'sbx kit add' (extra kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$local_extra'" >&2
    fi
  done

  # Record host-side provenance ONLY if every built-in kit is present-or-applied.
  # A failed apply must not write a record claiming the sandbox
  # is current. Best-effort write: a provenance write failure never fails the run.
  if [ "$ok" -eq 1 ]; then
    acq_provenance_write sbx "$name" || true
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Service → (host, env) mapping shared by both backends' secret feeds.
# ---------------------------------------------------------------------------
# The acq secret store holds the raw value under acq.<service>. Each backend
# needs to know which HOST(s) the credential is injected for and (for the
# placeholder/env path) which ENV var. Keep this table backend-neutral here so
# sbx.sh and msb.sh agree on the mapping.
#   usai   -> api.gsa.usai.gov            USAI_API_KEY
#   github -> github.com,api.github.com   GITHUB_TOKEN (sbx built-in service)
# Echoes "host1[,host2] <TAB> ENVVAR"; empty for unknown services.
_acq_service_hosts_env() {
  case "$1" in
    usai)   printf 'api.gsa.usai.gov\tUSAI_API_KEY\n' ;;
    github) printf 'github.com,api.github.com\tGITHUB_TOKEN\n' ;;
    *)      printf '\t\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# acq_backend_secret_set — store in the acq secret store, then feed sbx's proxy
# ---------------------------------------------------------------------------
#
# Phase 2: credentials are owned by acq's backend-neutral store
# (acq.backends/secret-store.sh), not sbx's. `acq secret set` writes the value
# into the acq store (keychain / 0600 file) keyed acq.<service> or
# acq.<sandbox>.<service>, then synthesizes the equivalent sbx secret so the sbx
# proxy performs the on-the-wire injection (the sbx runtime still needs the
# value in its own proxy config; we feed it from the acq store, piped via stdin,
# never argv). msb reads the same acq store at provision (see msb.sh).
#
# Usage: acq secret set [-g | SANDBOX] <service> [--host HOST --env ENV]

# Known sbx built-in services (the proxy injects these transparently).
_ACQ_SBX_BUILTIN_SERVICES=" anthropic github gitlab google-cloud openai aws azure "

acq_backend_secret_set() {
  local service="${1:-}"
  shift || true

  if [ -z "$service" ]; then
    echo "acq: secret set: missing service name" >&2
    echo "     usage: acq secret set [-g | SANDBOX] <service> [--host HOST --env ENV]" >&2
    exit 1
  fi

  # Parse scope: -g or a sandbox name must be the first argument.
  local scope_flag="" scope_name=""
  case "$service" in
    -g|--global)
      scope_flag="-g"
      service="${1:-}"
      shift || true
      ;;
    -*)
      # Unknown flag before service name — fall through to error below.
      ;;
    *)
      # Could be a sandbox name or the service. Peek at remaining args to decide:
      # if the next positional looks like a service (no leading -) and this arg
      # doesn't match a known service or "usai", treat it as a sandbox name.
      local _next="${1:-}"
      case "$_next" in
        ""|-*)
          # No more positionals or next is a flag — service is already set.
          ;;
        *)
          # Two bare positionals: first is sandbox name, second is service.
          scope_name="$service"
          service="$_next"
          shift || true
          ;;
      esac
      ;;
  esac

  if [ -z "$service" ]; then
    echo "acq: secret set: missing service name" >&2
    echo "     usage: acq secret set [-g | SANDBOX] <service> [--host HOST --env ENV]" >&2
    exit 1
  fi

  if [ -z "$scope_flag" ] && [ -z "$scope_name" ]; then
    echo "acq: secret set: scope required — use -g for global or provide a sandbox name" >&2
    echo "     usage: acq secret set [-g | SANDBOX] <service> [--host HOST --env ENV]" >&2
    echo "     examples:" >&2
    echo "       acq secret set -g usai                          # global" >&2
    echo "       acq secret set my-sandbox usai                  # sandbox-scoped" >&2
    exit 1
  fi

  # Collect remaining flags; detect --host and --env presence.
  local host="" env_var="" extra_flags=()
  local prev=""
  for arg in "$@"; do
    if [ "$prev" = "--host" ]; then
      host="$arg"
      extra_flags+=("$arg")
      prev=""
      continue
    elif [ "$prev" = "--env" ]; then
      env_var="$arg"
      extra_flags+=("$arg")
      prev=""
      continue
    fi
    case "$arg" in
      --host=*) host="${arg#--host=}"; extra_flags+=("$arg") ;;
      --env=*)  env_var="${arg#--env=}"; extra_flags+=("$arg") ;;
      --host)   prev="--host"; extra_flags+=("$arg") ;;
      --env)    prev="--env";  extra_flags+=("$arg") ;;
      *)        extra_flags+=("$arg") ;;
    esac
  done

  # Fill in defaults for known custom-endpoint services. NOTE: services that are
  # sbx BUILT-INS (github, anthropic, ...) must NOT be given a host/env here —
  # they use `sbx secret set <service>` so the sbx proxy injects them natively.
  # Only non-built-in services (usai) get a host/env mapping → set-custom.
  case "$_ACQ_SBX_BUILTIN_SERVICES" in
    *" $service "*) : ;;   # built-in: leave host/env empty
    *)
      local svc_hosts svc_env
      svc_hosts=$(_acq_service_hosts_env "$service" | cut -f1)
      svc_env=$(_acq_service_hosts_env "$service" | cut -f2)
      [ -z "$host" ] && [ -n "$svc_hosts" ] && host="${svc_hosts%%,*}"   # primary host
      [ -z "$env_var" ] && [ -n "$svc_env" ] && env_var="$svc_env"
      ;;
  esac

  # --- Step 1: store the value in the acq-owned secret store (keychain/file). --
  # This is the source of truth both backends read from. The value is read from
  # a TTY (silent) or piped stdin and never appears in argv.
  local acq_sandbox=""
  [ -n "$scope_name" ] && acq_sandbox="$scope_name"
  if command -v acq_secret_set_interactive >/dev/null 2>&1; then
    # Pass the resolved host/env so a CUSTOM endpoint's mapping is persisted as a
    # non-secret sidecar; built-ins pass empty host/env (their
    # mapping is compiled in) so nothing extra is recorded.
    acq_secret_set_interactive "$service" "$acq_sandbox" "$host" "$env_var" || return 1
  else
    echo "acq: internal error: secret store not loaded" >&2
    return 1
  fi

  # --- Step 2: feed sbx's proxy from the acq store so sbx does the injection. --
  # sbx's runtime needs the value in its own proxy config to rewrite outbound
  # requests. Per the sbx CLI contract (verified against sbx 0.35.x):
  #   - `sbx secret set <service>` (built-ins: github, anthropic, ...) reads the
  #     value from STDIN. It has no stdin --force; if the secret already exists
  #     it prompts "Overwrite? (y/N)" — which would consume our piped value as
  #     the answer. So we PRE-CHECK existence and stop with an rm hint rather
  #     than piping into a prompt.
  #   - `sbx secret set-custom` (usai and other custom hosts) does NOT read
  #     stdin; the value comes via --value/--token (argv-visible) and there is
  #     no --force (it errors on "already exists"). To avoid putting the secret
  #     on argv AND to avoid the already-exists error, we DO NOT pass --value.
  #     Instead we detect an existing entry and, if absent, run set-custom
  #     interactively so sbx collects the value at its own prompt.
  #
  # In all cases the real value is already safely in the acq store; sbx is just
  # the injection runtime. We never place the value on argv.
  local exit_code=0
  local is_builtin=0
  case "$_ACQ_SBX_BUILTIN_SERVICES" in
    *" $service "*) is_builtin=1 ;;
  esac

  # Existence pre-check (idempotency): sbx errors/prompts if the secret exists.
  # We list and match by service (built-in) or env var (custom). If present,
  # stop with a precise rm hint (non-destructive per project decision).
  local scope_desc rm_scope
  if [ -n "$scope_flag" ]; then scope_desc="global"; rm_scope="-g"; else scope_desc="sandbox '$scope_name'"; rm_scope="$scope_name"; fi

  if _acq_sbx_secret_exists "$scope_flag" "$scope_name" "$service" "$env_var"; then
    echo "acq: stored '$service' in the acq secret store, but sbx already has a" >&2
    echo "     secret for it in ${scope_desc}. sbx won't overwrite non-interactively." >&2
    echo "     Remove the existing sbx secret, then re-run to re-feed the proxy:" >&2
    echo "       sbx secret ls" >&2
    if [ "$is_builtin" -eq 1 ]; then
      echo "       sbx secret rm ${rm_scope} ${service}" >&2
    else
      echo "       sbx secret rm ${rm_scope} <placeholder-for-${env_var}>" >&2
    fi
    if [ -n "$scope_flag" ]; then
      echo "       acq secret set -g ${service}" >&2
    else
      echo "       acq secret set ${scope_name} ${service}" >&2
    fi
    return 1
  fi

  if [ "$is_builtin" -eq 1 ]; then
    # Built-in service: value on STDIN (sbx's documented non-interactive form).
    local secret_value builtin_scope_args=()
    secret_value=$(acq_secret_resolve "$service" "$acq_sandbox" 2>/dev/null || true)
    if [ -z "$secret_value" ]; then
      echo "acq: warning: stored '$service' but could not read it back to feed sbx." >&2
      return 1
    fi
    if [ -n "$scope_flag" ]; then builtin_scope_args+=("$scope_flag"); else builtin_scope_args+=("$scope_name"); fi
    printf '%s\n' "$secret_value" | sbx secret set "${builtin_scope_args[@]}" "$service"
    exit_code=$?
    secret_value=""
  else
    # Custom endpoint (usai, ...): set-custom has no stdin/--force. The value
    # can only reach sbx via --value (argv-visible) — which violates the "never
    # in argv" rule — or via sbx's own interactive prompt. We choose:
    #   - interactive stdin (a TTY): run set-custom so sbx prompts once. The acq
    #     store already holds the canonical value; we do not echo it on argv.
    #   - piped stdin (no TTY, e.g. `printf ... | acq secret set -g usai`): sbx
    #     set-custom cannot read the piped value and would block on its prompt.
    #     Rather than hang or expose the value on argv, store in the acq store
    #     and tell the user the one manual sbx command to run. (The acq store is
    #     the source of truth; msb reads it directly with no sbx step.)
    if [ -z "$host" ] && [ -z "$env_var" ]; then
      echo "acq: '$service' has no host/env mapping and is not a built-in sbx service." >&2
      echo "     Provide --host HOST --env ENV, or use a known service (usai, github, ...)." >&2
      return 1
    fi
    local cmd_args=("secret" "set-custom")
    if [ -n "$scope_flag" ]; then cmd_args+=("$scope_flag"); else cmd_args+=("$scope_name"); fi
    local svc_hosts h
    svc_hosts=$(_acq_service_hosts_env "$service" | cut -f1)
    [ -z "$svc_hosts" ] && svc_hosts="$host"
    local _oldifs="$IFS"; IFS=','
    for h in $svc_hosts; do [ -n "$h" ] && cmd_args+=("--host" "$h"); done
    IFS="$_oldifs"
    cmd_args+=("--env" "${env_var:-}")
    local skip_next=0 arg
    for arg in "${extra_flags[@]+"${extra_flags[@]}"}"; do
      if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
      case "$arg" in
        --host|--env) skip_next=1 ;;
        --host=*|--env=*) ;;
        *) cmd_args+=("$arg") ;;
      esac
    done

    if [ -t 0 ] && [ -z "${ACQ_SECRET_TEST_VALUE:-}" ]; then
      # Interactive TTY: let sbx prompt for the value once.
      echo "acq: enter the SAME value at sbx's prompt to finish configuring '$service':" >&2
      sbx "${cmd_args[@]}"
      exit_code=$?
    else
      # Non-interactive (piped) or test: cannot feed sbx set-custom without argv
      # exposure. Value is safely in the acq store; print the exact sbx command.
      echo "acq: stored '$service' in the acq secret store." >&2
      if [ "${ACQ_BACKEND:-}" = "msb" ] || [ "${ACQ_RESOLVED_BACKEND:-}" = "msb" ]; then
        : # msb reads the acq store directly at provision; no sbx step needed.
      else
        echo "acq: to finish non-interactively, sbx needs the value on the command line" >&2
        echo "     (visible in shell history):" >&2
        echo "       sbx ${cmd_args[*]} --value <the-secret>" >&2
        echo "     Or run 'acq secret set ${scope_flag:-$scope_name} ${service}' from a terminal." >&2
      fi
      exit_code=0
    fi
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo "" >&2
    echo "acq: value stored in the acq secret store, but feeding the sbx proxy failed." >&2
    echo "     If sbx says 'already exists', remove it and retry:" >&2
    echo "       sbx secret ls && sbx secret rm ${rm_scope} <placeholder>" >&2
  fi
  return "$exit_code"
}

# ---------------------------------------------------------------------------
# acq_backend_secret_rm [-g | SANDBOX] SERVICE  (sbx backend)
# ---------------------------------------------------------------------------
# Remove a secret acq owns: delete it from the acq store AND clear sbx's proxy
# entry, so no injected value lingers. Idempotent (absent secret is success).
# Scope parsing mirrors acq_backend_secret_set: -g/--global, or a leading bare
# sandbox name before the service. This is the counterpart to `acq secret set`;
# for a raw sbx placeholder removal the user can still call `sbx secret rm`
# directly (that path is passed through by the acq dispatcher).
acq_backend_secret_rm() {
  local service="${1:-}"
  shift || true

  local scope_flag="" scope_name=""
  case "$service" in
    -g|--global)
      scope_flag="-g"; service="${1:-}"; shift || true ;;
    -*)
      ;;
    *)
      local _next="${1:-}"
      case "$_next" in
        ""|-*) ;;
        *) scope_name="$service"; service="$_next"; shift || true ;;
      esac
      ;;
  esac

  if [ -z "$service" ]; then
    echo "acq: secret rm: missing service name" >&2
    echo "     usage: acq secret rm [-g | SANDBOX] <service>" >&2
    return 1
  fi
  if [ -z "$scope_flag" ] && [ -z "$scope_name" ]; then
    echo "acq: secret rm: scope required — use -g for global or provide a sandbox name" >&2
    echo "     usage: acq secret rm [-g | SANDBOX] <service>" >&2
    return 1
  fi

  local acq_sandbox=""
  [ -n "$scope_name" ] && acq_sandbox="$scope_name"

  # 1) Remove from the acq store (source of truth). Idempotent.
  local removed_store=0
  if command -v acq_secret_delete >/dev/null 2>&1; then
    local key
    # _acq_secret_key fails closed on an ambiguous (dotted) name; such a name
    # could never have been stored, so treat rm as a no-op success
    # (the `|| key=""` keeps `set -e` from aborting the rm path).
    key=$(_acq_secret_key "$service" "$acq_sandbox") || key=""
    [ -n "$key" ] && acq_secret_delete "$key" && removed_store=1
  fi
  # Also drop the non-secret endpoint sidecar for this service/scope (idempotent).
  command -v acq_secret_meta_delete >/dev/null 2>&1 && \
    acq_secret_meta_delete "$service" "$acq_sandbox" || true

  # 2) Clear sbx's proxy entry so it stops injecting. Built-in services are
  #    removed by service name; custom services (usai, ...) by their placeholder.
  #    ALWAYS pass -f: `sbx secret rm` otherwise prompts "Remove? (y/N)" on a TTY
  #    and BLOCKS waiting for input (observed hanging verify-backends). acq's rm
  #    is non-interactive by contract. Also </dev/null as belt-and-suspenders so
  #    no sbx prompt can ever consume our stdin. Best-effort — a missing sbx
  #    entry is not an error.
  local is_builtin=0
  case "$_ACQ_SBX_BUILTIN_SERVICES" in
    *" $service "*) is_builtin=1 ;;
  esac
  local scope_arg
  if [ -n "$scope_flag" ]; then scope_arg="-g"; else scope_arg="$scope_name"; fi

  if [ "$is_builtin" -eq 1 ]; then
    sbx secret rm "$scope_arg" "$service" -f </dev/null >/dev/null 2>&1 || true
  else
    # Custom endpoint (usai, ...): sbx removes a custom secret by its PLACEHOLDER
    # (there is no --host on `secret rm`). Look up the placeholder from the custom
    # secrets table for this scope + env var, then remove it by --placeholder.
    local env_var placeholder
    env_var=$(_acq_service_hosts_env "$service" | cut -f2)
    placeholder=$(_acq_sbx_custom_placeholder "$scope_flag" "$scope_name" "$env_var")
    if [ -n "$placeholder" ]; then
      sbx secret rm "$scope_arg" --placeholder "$placeholder" -f </dev/null >/dev/null 2>&1 || true
    fi
  fi

  local where="global"
  [ -n "$scope_name" ] && where="sandbox '$scope_name'"
  if [ "$removed_store" -eq 1 ]; then
    echo "acq: removed '$service' secret (${where}) from the acq store and sbx proxy." >&2
  else
    echo "acq: no '$service' secret found in the acq store (${where}); cleared sbx proxy anyway." >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _acq_sbx_secret_exists SCOPE_FLAG SCOPE_NAME SERVICE ENV_VAR -> 0 if present
# ---------------------------------------------------------------------------
# Scope- AND section-AWARE existence check against `sbx secret ls`. The listing
# has TWO tables:
#
#   SCOPE      TYPE     NAME    SECRET                 <- built-in services
#   <scope>    service  github  (stored)
#
#   CUSTOM SECRETS
#   SCOPE      TARGETS  ENV     PLACEHOLDER  SECRET    <- custom secrets
#   <scope>    <host>   USAI_…  sbx-cs-…     ****
#
# A built-in service (github, ...) is identified by its NAME in the built-in
# table; a custom service (usai, ...) by its ENV var in the CUSTOM table. We must
# match in the CORRECT section, and only when the row's SCOPE column equals the
# request scope — an earlier version blind-substring-matched the whole listing,
# so github under ANY scope (or a stray token in either table) produced a false
# positive that wrongly refused to seed the target scope.
#
# Args: SCOPE_FLAG (`-g` or empty), SCOPE_NAME (sandbox, or empty for global),
#       SERVICE, ENV_VAR (empty for a built-in service).
# Target scope string: `(global)` for -g, else the sandbox name.
# Returns 0 only on a scoped, section-correct match; 1 otherwise / on ls failure.
_acq_sbx_secret_exists() {
  local scope_flag="$1" scope_name="$2" service="$3" env_var="$4"
  local listing want_scope
  listing=$(sbx secret ls 2>/dev/null) || return 1
  if [ -n "$scope_flag" ]; then want_scope="(global)"; else want_scope="$scope_name"; fi

  # want_section: "builtin" (match NAME) for a built-in service, else "custom"
  # (match ENV). needle is the token to find in that section's row.
  local want_section needle
  if [ -n "$env_var" ]; then want_section="custom"; needle="$env_var"
  else want_section="builtin"; needle="$service"; fi

  printf '%s\n' "$listing" | awk \
    -v scope="$want_scope" -v needle="$needle" -v want="$want_section" '
    # Section tracking: everything before the "CUSTOM SECRETS" marker is the
    # built-in table; everything after is the custom table.
    /^CUSTOM SECRETS/ { section = "custom"; next }
    NF == 0 { next }
    # Skip each table header row (starts with the literal SCOPE column label).
    $1 == "SCOPE" { next }
    {
      cur = (section == "custom") ? "custom" : "builtin"
      if (cur == want && $1 == scope) {
        # Built-in: NAME is field 3 (SCOPE TYPE NAME). Custom: ENV is field 3
        # (SCOPE TARGETS ENV). Both live at $3 given single-token scope/target;
        # also scan remaining fields defensively in case of extra spacing.
        for (i = 2; i <= NF; i++) if ($i == needle) { found = 1; exit }
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

acq_backend_key_present() {
  local service="${1:-}" scope_sandbox="${2:-}"
  case "$service" in
    usai)
      if [ -n "$scope_sandbox" ] && _acq_sbx_secret_exists "" "$scope_sandbox" usai USAI_API_KEY; then
        return 0
      fi
      _acq_sbx_secret_exists -g "" usai USAI_API_KEY
      ;;
    *)
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _acq_sbx_custom_placeholder SCOPE_FLAG SCOPE_NAME ENV_VAR -> placeholder|empty
# ---------------------------------------------------------------------------
# Look up the PLACEHOLDER of a CUSTOM secret (from the CUSTOM SECRETS table of
# `sbx secret ls`) for a given scope + env var, so `sbx secret rm --placeholder`
# can target it. Echoes the placeholder (e.g. sbx-cs-…) or nothing if absent.
_acq_sbx_custom_placeholder() {
  local scope_flag="$1" scope_name="$2" env_var="$3"
  [ -n "$env_var" ] || return 0
  local listing want_scope
  listing=$(sbx secret ls 2>/dev/null) || return 0
  if [ -n "$scope_flag" ]; then want_scope="(global)"; else want_scope="$scope_name"; fi

  # CUSTOM table columns: SCOPE TARGETS ENV PLACEHOLDER SECRET. Find the row in
  # the custom section whose SCOPE == want_scope and ENV == env_var, print its
  # PLACEHOLDER. We locate ENV by value (not fixed index) and take the NEXT field
  # as the placeholder, robust to a multi-token TARGETS cell.
  printf '%s\n' "$listing" | awk \
    -v scope="$want_scope" -v env="$env_var" '
    /^CUSTOM SECRETS/ { in_custom = 1; next }
    !in_custom { next }
    NF == 0 { next }
    $1 == "SCOPE" { next }
    $1 == scope {
      for (i = 2; i < NF; i++) if ($i == env) { print $(i+1); exit }
    }
  '
}

# ---------------------------------------------------------------------------
# acq_backend_rotate_key — rotate the global USAi key (per ADR-0012)
# ---------------------------------------------------------------------------
# Rotate the global USAI_API_KEY custom secret in sbx, PRESERVING its proxy
# placeholder so existing sandboxes keep resolving to the new value. Carried
# verbatim from the former scripts/rotate-apikey (which is now a thin shim that
# calls `acq usai-rotate-api-key`). Never places the secret value on argv — sbx
# prompts for the new key at its own prompt. Returns non-zero on failure.
acq_backend_rotate_key() {
  local usai_host="api.gsa.usai.gov"
  local usai_models_url="https://${usai_host}/api/v1/models"

  # Read the current secret table once (avoids a TOCTOU window + a second call).
  local secret_ls
  secret_ls=$(sbx secret ls -g) || {
    echo "acq(sbx): could not read the sbx secret table ('sbx secret ls -g')." >&2
    return 1
  }

  # Grab the existing placeholder, anchoring on the USAI_API_KEY token rather
  # than a fixed column, taking only the FIRST match so a duplicated state can't
  # produce a multi-line value. Preserved across rotation so running sandboxes
  # that already injected it keep resolving to the new secret.
  local placeholder
  placeholder=$(printf '%s\n' "$secret_ls" \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "USAI_API_KEY") { print $(i+1); exit } }')

  if [ -z "$placeholder" ]; then
    echo "acq(sbx): USAI_API_KEY not found. Run 'acq secret ls' to check." >&2
    return 1
  fi

  # Count USAI_API_KEY rows. More than one means a previous rotation (before the
  # fix in ADR-0008) left duplicate/ghost entries; the proxy can then resolve the
  # placeholder to an empty entry and validation fails with 401.
  local row_count
  row_count=$(printf '%s\n' "$secret_ls" \
    | grep -cE '[[:space:]]USAI_API_KEY[[:space:]]' || true)

  if [ "${row_count:-0}" -gt 1 ]; then
    # --- Cleanup path for data corrupted by the pre-fix rotation bug ----------
    # Only taken when duplicates exist. We must remove every custom secret for
    # the host (`sbx secret rm -g --host` deletes ALL matching entries) and
    # recreate a single one — there's no in-place "dedupe". This is destructive
    # and non-atomic: between the rm and the set-custom the host has NO USAi
    # secret, so a Ctrl-C or a failed/cancelled set-custom would leave the host
    # with no key at all. Guard that window with a trap that prints exact
    # recovery steps, and disarm it once set-custom succeeds.
    echo "Found $row_count USAI_API_KEY entries; consolidating to a single secret." >&2

    local _ph="$placeholder" _host="$usai_host"
    # shellcheck disable=SC2064
    trap "{
      echo '' >&2
      echo 'ERROR: rotation was interrupted while the USAI_API_KEY secret was removed' >&2
      echo 'but before the new value was set. Your sandboxes currently have NO USAi key.' >&2
      echo 'Recover by re-running this rotation, or manually:' >&2
      echo '  sbx secret set-custom -g --host ${_host} --env USAI_API_KEY --placeholder ${_ph}' >&2
    }" EXIT

    local rm_err
    if ! rm_err=$(sbx secret rm -g --host "$usai_host" -f 2>&1); then
      trap - EXIT
      echo "acq(sbx): failed to remove existing secrets: $rm_err" >&2
      return 1
    fi

    # Recreate the single secret with the preserved placeholder. Omitting
    # --value makes sbx prompt for the new key (keeps it out of shell history).
    sbx secret set-custom -g --host "$usai_host" \
          --env USAI_API_KEY --placeholder "$placeholder" || {
      echo "acq(sbx): 'sbx secret set-custom' failed. See recovery steps above." >&2
      return 1
    }

    trap - EXIT
  else
    # Healthy single-row case: set-custom updates the existing entry in place, so
    # there's no need for the destructive rm (which would only add risk here).
    # Omitting --value makes sbx prompt for the new key (no shell-history leak).
    sbx secret set-custom -g --host "$usai_host" \
          --env USAI_API_KEY --placeholder "$placeholder" || {
      echo "acq(sbx): 'sbx secret set-custom' failed." >&2
      return 1
    }
  fi

  # Validate the new key in a throwaway sandbox so we don't depend on any
  # particular pre-existing sandbox. Created here, removed on exit.
  local validation_sbx="acq-keycheck-$$"
  # shellcheck disable=SC2064
  trap "sbx rm '$validation_sbx' -f >/dev/null 2>&1 || true" EXIT

  # `sbx create` needs an authenticated sbx session. If it has expired, sbx
  # triggers an interactive browser login — and if its output is swallowed and
  # it's unbounded, rotation appears to hang with no explanation (quickstart
  # #211). Two guards: (1) do NOT silence stderr, so any login prompt is
  # visible; (2) bound the create with a timeout so an interactive-login
  # handshake can never hang indefinitely. sbx has no non-interactive
  # auth-status probe, so the timeout is the safety net.
  local create_timeout="${ROTATE_VALIDATE_TIMEOUT:-120}"
  local rc=0
  acq_spin_start "Validating the new key in a temporary sandbox"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$create_timeout" sbx create --name "$validation_sbx" shell . >/dev/null || rc=$?
  else
    sbx create --name "$validation_sbx" shell . >/dev/null || rc=$?
  fi
  acq_spin_stop "Validating the new key in a temporary sandbox"
  if [ "$rc" != "0" ]; then
    if [ "$rc" = "124" ]; then
      echo "Validation timed out after ${create_timeout}s — sbx likely needed an interactive login." >&2
      echo "Run 'sbx login', then 'acq run' (it validates the key on next attach)." >&2
    else
      echo "Could not create a validation sandbox; skipping check." >&2
      echo "The key was rotated. Run 'sbx login' if needed, then 'acq run' — it validates on next attach." >&2
    fi
    trap - EXIT
    return 0
  fi

  local status
  status=$(sbx exec "$validation_sbx" -- sh -c \
     "curl -sS -o /dev/null -w '%{http_code}' \
      -H \"Authorization: Bearer \$USAI_API_KEY\" \
      $usai_models_url" 2>/dev/null || true)

  acq_backend_terminate "$validation_sbx" >/dev/null 2>&1 || true
  trap - EXIT

  if [ "$status" = "200" ]; then
    echo "Key validated (HTTP 200). You're good to go." >&2
    return 0
  fi
  echo "acq(sbx): key validation failed (HTTP ${status:-unknown}). Double-check the key and rotate again." >&2
  return 1
}

# ---------------------------------------------------------------------------
# acq_backend_version / acq_backend_doctor
# ---------------------------------------------------------------------------

acq_backend_version() {
  sbx version 2>/dev/null || echo "(sbx version unknown)"
}

acq_backend_doctor() {
  local ver
  ver=$(sbx version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "?")
  printf '[sbx: installed %s]\n' "$ver"
}

# ---------------------------------------------------------------------------
# is_known_agent — used by the acq run dispatch
# ---------------------------------------------------------------------------

is_known_agent() {
  case "$KNOWN_AGENTS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}
