#!/bin/bash
#
# acq.backends/sbx.sh — sbx backend adapter for acq
#
# Implements the adapter contract defined in docs/explorations/acq-handoff-1.1.md §5.
# Each acq_backend_* function maps the acq contract to the sbx CLI.
#
# Sourced by acq (via acq_resolve_backend) after common.sh is already loaded.
# Never run directly.

# Capability flags — reserved for multi-backend dispatch in common.sh (1.2.x+).
# Each backend adapter declares these so common.sh can gate features once a
# second backend exists. Unused by common.sh today (only one backend).
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

# Agents recognized by `sbx run` (mirrors qsbx).
KNOWN_AGENTS=" claude codex copilot cursor docker-agent droid gemini kiro opencode shell "

# ---------------------------------------------------------------------------
# Version comparison (carried from qsbx verbatim)
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
# Carried from qsbx (ensure_kit_sources_allowed / _kit_sources_manual_hint).
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

# Emit --kit flags for all kits (built-ins + extras) one token per line.
_acq_sbx_kit_flags() {
  local k
  for k in "${KITS[@]}"; do
    printf '%s\n%s\n' "--kit" "$k"
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
# a spurious kit-add rather than a hard error. This matches qsbx's behavior.
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

  if [ "${#_stripped[@]}" -gt 0 ]; then
    sbx create --name "$name" "${kf[@]}" "${_stripped[@]}"
  else
    sbx create --name "$name" "${kf[@]}"
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_run — run a command inside a sandbox
# ---------------------------------------------------------------------------

acq_backend_run() {
  local name="$1"
  shift
  # Expect `-- CMD...` separator
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
  local name="$1" kitref="$2"
  sbx kit add "$name" "$kitref"
}

# ---------------------------------------------------------------------------
# acq_backend_ensure_kits_applied — heal a pre-kit sandbox in place
# (carries ensure_kit_applied logic from qsbx)
# ---------------------------------------------------------------------------

acq_backend_ensure_kits_applied() {
  local name="$1"

  _acq_sbx_ensure_kit_sources_allowed

  # 1) USAi provider kit
  if _acq_sbx_kit_feature_absent "$name" "test -f '$USAI_KIT_CONFIG_PATH' && echo present"; then
    echo "acq: '$name' is missing the USAi kit; injecting with 'sbx kit add'..." >&2
    if sbx kit add "$name" "$USAI_KIT" </dev/null >/dev/null 2>&1; then
      sbx exec "$name" -- sh -c \
        'f="$HOME/.config/opencode/opencode.jsonc"; if [ -L "$f" ] && [ ! -e "$f" ]; then rm -f "$f"; fi' \
        </dev/null >/dev/null 2>&1 || true
      echo "acq: USAi kit injected into '$name'." >&2
    else
      echo "acq: warning: 'sbx kit add' (USAi kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$USAI_KIT'" >&2
    fi
  fi

  # 2) Playbook kit
  if _acq_sbx_kit_feature_absent "$name" 'test -e "$HOME/.agentic-coding-playbook/.git" && echo present'; then
    echo "acq: '$name' is missing the playbook kit; injecting with 'sbx kit add'..." >&2
    if sbx kit add "$name" "$PLAYBOOK_KIT" </dev/null >/dev/null 2>&1; then
      echo "acq: playbook kit injected into '$name'. Restart the agent to pick it up." >&2
    else
      echo "acq: warning: 'sbx kit add' (playbook kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$PLAYBOOK_KIT'" >&2
    fi
  fi

  # 3) Zscaler CA kit
  if _acq_sbx_kit_feature_absent "$name" 'test -e /usr/local/share/ca-certificates/zscaler-ca.crt && echo present'; then
    echo "acq: '$name' is missing the Zscaler CA kit; injecting with 'sbx kit add'..." >&2
    if sbx kit add "$name" "$ZSCALER_KIT" </dev/null >/dev/null 2>&1; then
      echo "acq: Zscaler CA kit injected into '$name'." >&2
    else
      echo "acq: warning: 'sbx kit add' (Zscaler CA kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$ZSCALER_KIT'" >&2
    fi
  fi

  # 4) Extra kits (tracked by marker file)
  local applied k
  applied=$(sbx exec "$name" -- sh -c 'cat "$HOME/.acq-extra-kits" 2>/dev/null' </dev/null 2>/dev/null || true)
  local _extras=()
  [ -n "$ACQ_EXTRA_KITS" ] && split_noglob _extras "$ACQ_EXTRA_KITS"
  for k in ${_extras[@]+"${_extras[@]}"}; do
    case "$applied" in
      *"$k"*) continue ;;
    esac
    echo "acq: applying extra kit to '$name': $k" >&2
    if sbx kit add "$name" "$k" </dev/null >/dev/null 2>&1; then
      sbx exec "$name" -- sh -c 'printf "%s\n" "$0" >> "$HOME/.acq-extra-kits"' "$k" </dev/null >/dev/null 2>&1 || true
    else
      echo "acq: warning: 'sbx kit add' (extra kit) failed for '$name'." >&2
      echo "      Recover with: sbx kit add '$name' '$k'" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# acq_backend_secret_set — thin wrapper over sbx secret CLI
# ---------------------------------------------------------------------------
#
# Built-in services use `sbx secret set -g <service>`.
# Custom endpoints (--host/--env present, or unknown service) use set-custom.
# `usai` is a known alias for the USAi custom endpoint.
# Never passes a secret as a CLI argument.

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

  # Fill in USAi defaults.
  if [ "$service" = "usai" ]; then
    [ -z "$host" ]    && host="api.gsa.usai.gov"
    [ -z "$env_var" ] && env_var="USAI_API_KEY"
  fi

  # Decide: built-in `set` form vs custom `set-custom` form.
  if [ -n "$host" ] || [ -n "$env_var" ]; then
    # Custom form. sbx set-custom reads the secret from stdin when --value is
    # omitted — keeping it out of argv entirely.
    #
    # Two modes:
    #   Interactive (TTY on stdin): prompt the user, read silently, pipe to sbx.
    #   Piped (stdin is not a TTY):  read from stdin directly, no prompt emitted,
    #                                print confirmation when done.
    local secret_value=""
    local piped=0

    # ACQ_SECRET_TEST_VALUE is an offline-test escape hatch (no TTY in CI).
    # Never set this in production use.
    if [ -n "${ACQ_SECRET_TEST_VALUE:-}" ]; then
      secret_value="$ACQ_SECRET_TEST_VALUE"
    elif [ ! -t 0 ]; then
      # Stdin is a pipe — read the secret from it, no prompt.
      read -r secret_value
      piped=1
    else
      printf 'Enter %s secret: ' "$service" >&2
      read -rs secret_value 2>/dev/null || read -r secret_value
      printf '\n' >&2
    fi

    if [ -z "$secret_value" ]; then
      echo "acq: no secret entered; aborting." >&2
      return 1
    fi

    local cmd_args=("secret" "set-custom")
    if [ -n "$scope_flag" ]; then
      cmd_args+=("$scope_flag")
    else
      cmd_args+=("$scope_name")
    fi
    cmd_args+=("--host" "${host:-}" "--env" "${env_var:-}")
    # Append any extra flags that aren't --host/--env and their values.
    local skip_next=0
    for arg in "${extra_flags[@]+"${extra_flags[@]}"}"; do
      if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
      case "$arg" in
        --host|--env) skip_next=1 ;;  # skip value too
        --host=*|--env=*) ;;          # skip inline form
        *) cmd_args+=("$arg") ;;
      esac
    done

    local exit_code
    if [ "$piped" -eq 1 ] || [ -n "${ACQ_SECRET_TEST_VALUE:-}" ]; then
      # Non-interactive: pass via --value to suppress sbx's "Enter secret:" prompt.
      sbx "${cmd_args[@]}" --value "$secret_value"
      exit_code=$?
      secret_value=""
      if [ "$exit_code" -eq 0 ]; then
        echo "acq: ${service} secret set." >&2
      fi
    else
      # Interactive TTY: pipe the value so it never appears in argv.
      printf '%s\n' "$secret_value" | sbx "${cmd_args[@]}"
      exit_code=$?
      secret_value=""
    fi

    if [ "$exit_code" -ne 0 ]; then
      echo "" >&2
      echo "acq: if the error above is 'already exists', remove the existing secret first:" >&2
      echo "       sbx secret ls                        # find the placeholder" >&2
      if [ -n "$scope_flag" ]; then
        echo "       sbx secret rm -g <placeholder>       # remove it" >&2
        echo "       acq secret set -g ${service}         # re-set" >&2
      else
        echo "       sbx secret rm ${scope_name} <placeholder>  # remove it" >&2
        echo "       acq secret set ${scope_name} ${service}    # re-set" >&2
      fi
    fi
    return "$exit_code"
  else
    # Check if this is a known built-in service.
    local builtin_scope_args=()
    if [ -n "$scope_flag" ]; then
      builtin_scope_args+=("$scope_flag")
    else
      builtin_scope_args+=("$scope_name")
    fi
    case "$_ACQ_SBX_BUILTIN_SERVICES" in
      *" $service "*)
        sbx secret set "${builtin_scope_args[@]}" "$service" "${extra_flags[@]+"${extra_flags[@]}"}"
        ;;
      *)
        echo "acq: '$service' is not a known built-in sbx service." >&2
        echo "     For custom endpoints use: acq secret set [-g | SANDBOX] $service --host HOST --env ENV" >&2
        exit 1
        ;;
    esac
  fi
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
