#!/bin/bash
#
# Experimental OpenShell lifecycle adapter. OpenShell 0.1.4 was inspected locally;
# this adapter intentionally covers only the local Docker gateway lifecycle.

# shellcheck disable=SC2034
ACQ_BACKEND_NAME="openshell"
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_PORT_FORWARD=0
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_SNAPSHOTS=0
# shellcheck disable=SC2034
ACQ_BACKEND_CAN_RESUME=1
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE=0
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_PROVIDERS=0
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_KITS=0

MIN_OPENSHELL_VERSION="0.1.4"
ACQ_OPENSHELL_DRIVER="${ACQ_OPENSHELL_DRIVER:-docker}"
ACQ_OPENSHELL_WORKSPACE_MODE="${ACQ_OPENSHELL_WORKSPACE_MODE:-bind}"
ACQ_OPENSHELL_ALLOW_BIND_MOUNTS="${ACQ_OPENSHELL_ALLOW_BIND_MOUNTS:-}"
ACQ_OPENSHELL_IMAGE="${ACQ_OPENSHELL_IMAGE:-docker.io/docker/sandbox-templates:shell-docker}"
ACQ_OPENSHELL_READY_TIMEOUT="${ACQ_OPENSHELL_READY_TIMEOUT:-60}"
ACQ_OPENSHELL_CLONES_DIR="${ACQ_OPENSHELL_CLONES_DIR:-${ACQ_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/acq}/openshell-clones}"

_acq_openshell_cli() {
  openshell "$@"
}

_acq_openshell_safe_name() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

_acq_openshell_safe_path() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  return 0
}

_acq_openshell_version() {
  _acq_openshell_cli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

acq_backend_check_version() {
  if ! command -v openshell >/dev/null 2>&1; then
    echo "error: openshell CLI not found on PATH; install OpenShell $MIN_OPENSHELL_VERSION." >&2
    exit 1
  fi
  local version
  version=$(_acq_openshell_version)
  if [ "$version" != "$MIN_OPENSHELL_VERSION" ]; then
    echo "error: acq experimental OpenShell support requires openshell $MIN_OPENSHELL_VERSION, found ${version:-unknown}." >&2
    echo "       Refusing an unverified CLI/gateway contract." >&2
    exit 1
  fi
}

acq_backend_prepare() {
  acq_backend_check_version
  if ! _acq_openshell_cli status --output json >/dev/null 2>&1; then
    echo "acq(openshell): no usable selected gateway." >&2
    echo "  Select a reviewed local gateway with 'openshell gateway select NAME'." >&2
    echo "  Remote gateways and non-Docker drivers are unsupported by this adapter." >&2
    return 1
  fi
  case "$ACQ_OPENSHELL_WORKSPACE_MODE" in
    bind)
      if [ "$ACQ_OPENSHELL_DRIVER" != "docker" ] || [ "$ACQ_OPENSHELL_ALLOW_BIND_MOUNTS" != "1" ]; then
        echo "acq(openshell): bind mode requires ACQ_OPENSHELL_DRIVER=docker and" >&2
        echo "  ACQ_OPENSHELL_ALLOW_BIND_MOUNTS=1 after local-gateway mount enablement." >&2
        echo "  Set ACQ_OPENSHELL_WORKSPACE_MODE=upload only for the explicit copy fallback." >&2
        return 1
      fi
      ;;
    upload) ;;
    *) echo "acq(openshell): invalid ACQ_OPENSHELL_WORKSPACE_MODE='$ACQ_OPENSHELL_WORKSPACE_MODE' (bind|upload)." >&2; return 1 ;;
  esac
}

acq_backend_exists() {
  local name="$1" result
  _acq_openshell_safe_name "$name" || return 1
  result=$(_acq_openshell_cli sandbox get "$name" --output json 2>/dev/null) || return 1
  printf '%s' "$result" | grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"${name}\""
}

_acq_openshell_wait_ready() {
  local name="$1" deadline
  deadline=$(( $(date +%s) + ACQ_OPENSHELL_READY_TIMEOUT ))
  while :; do
    if _acq_openshell_cli sandbox exec "$name" --no-login-shell -- true </dev/null >/dev/null 2>&1; then
      return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 2
  done
  echo "acq(openshell): sandbox '$name' did not become ready within ${ACQ_OPENSHELL_READY_TIMEOUT}s." >&2
  return 1
}

_acq_openshell_clone_setup() {
  local name="$1" workspace="$2" top scratch
  top=$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null) || {
    echo "acq(openshell): --clone requires a git workspace." >&2; return 1; }
  [ "$top" = "$workspace" ] || {
    echo "acq(openshell): --clone requires the repository root, not '$workspace'." >&2; return 1; }
  _acq_openshell_safe_name "$name" || return 1
  scratch="$ACQ_OPENSHELL_CLONES_DIR/$name/workspace"
  [ ! -e "$scratch" ] || { echo "acq(openshell): scratch clone already exists: $scratch" >&2; return 1; }
  ( umask 077; mkdir -p "${scratch%/*}" ) || return 1
  git clone --quiet --no-hardlinks -- "$workspace" "$scratch" || return 1
  git -C "$workspace" remote add "sandbox-$name" "$scratch" 2>/dev/null || {
    rm -rf "${scratch%/*}"; return 1; }
  _ACQ_OPENSHELL_CLONE_DIR="$scratch"
}

_acq_openshell_clone_cleanup() {
  local name="$1" workspace="${2:-}" scratch="${3:-}"
  [ -n "$workspace" ] || workspace=$(acq_host_config_read openshell "$name" workspace)
  [ -n "$scratch" ] || scratch=$(acq_host_config_read openshell "$name" clone-source)
  [ -n "$workspace" ] && git -C "$workspace" remote remove "sandbox-$name" >/dev/null 2>&1 || true
  [ -n "$scratch" ] && rm -rf "${scratch%/*}" 2>/dev/null || true
}

# Neutral agent kits do not yet provide OpenShell entrypoints. Keep this
# increment shell-only rather than attaching a generic shell for another agent.
acq_backend_validate_agent() {
  if [ "$1" != "shell" ]; then
    echo "acq(openshell): '$1' requires OpenShell neutral kit translation and an agent entrypoint (GSA-TTS/agentic-coding-quickstart#577)." >&2
    echo "  This lifecycle increment supports only: acq --backend openshell create shell PATH" >&2
    return 1
  fi
}

_acq_openshell_driver_config() {
  local source="$1" target="$2"
  _acq_openshell_safe_path "$source" && _acq_openshell_safe_path "$target" || return 1
  printf '{"docker":{"mounts":[{"source":"%s","target":"%s","type":"bind","read_only":false}]}}' "$source" "$target"
}

acq_backend_provision() {
  local name="$1"; shift
  local agent workspace source image driver_config output rc=0 create_flags=()
  agent=$(first_positional "$@")
  workspace=$(workspace_path "$@")
  [ -n "$workspace" ] || workspace="$PWD"
  workspace=$(canonicalize_path "$workspace")
  _acq_openshell_safe_name "$name" && _acq_openshell_safe_path "$workspace" || {
    echo "acq(openshell): unsafe sandbox name or workspace path." >&2; return 1; }
  source="$workspace"
  if [ "${ACQ_CLONE:-0}" = "1" ]; then
    [ "$ACQ_OPENSHELL_WORKSPACE_MODE" = "bind" ] || {
      echo "acq(openshell): --clone requires controlled bind mode; upload fallback cannot provide fetch-back semantics." >&2; return 1; }
    _acq_openshell_clone_setup "$name" "$workspace" || return 1
    source="$_ACQ_OPENSHELL_CLONE_DIR"
  fi
  image=$(acq_resolve_neutral_image 2>/dev/null || true)
  [ -n "$image" ] || image="$ACQ_OPENSHELL_IMAGE"
  acq_host_config_clear_instance_state openshell "$name"
  create_flags=(sandbox create --name "$name" --from "$image" --env "ACQ_WORKSPACE=$workspace")
  [ "${ACQ_CLONE:-0}" = "1" ] && create_flags+=(--env "ACQ_CLONE=1")
  if [ "$ACQ_OPENSHELL_WORKSPACE_MODE" = "bind" ]; then
    driver_config=$(_acq_openshell_driver_config "$source" "$workspace") || return 1
    create_flags+=(--driver-config-json "$driver_config")
  else
    create_flags+=(--upload "$source:$workspace")
  fi
  output=$(_acq_openshell_cli "${create_flags[@]}" --detach --output json 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$output" >&2
    if [ "$ACQ_OPENSHELL_WORKSPACE_MODE" = "bind" ]; then
      echo "acq(openshell): bind mount creation failed; no upload/download fallback was selected." >&2
    fi
    [ -n "${_ACQ_OPENSHELL_CLONE_DIR:-}" ] && _acq_openshell_clone_cleanup "$name" "$workspace" "$_ACQ_OPENSHELL_CLONE_DIR"
    return "$rc"
  fi
  _acq_openshell_wait_ready "$name" || {
    _acq_openshell_cli sandbox delete "$name" >/dev/null 2>&1 || true
    [ -n "${_ACQ_OPENSHELL_CLONE_DIR:-}" ] && _acq_openshell_clone_cleanup "$name" "$workspace" "$_ACQ_OPENSHELL_CLONE_DIR"
    return 1
  }
  acq_host_config_write openshell "$name" agent "$agent" || true
  acq_host_config_write openshell "$name" workspace "$workspace" || true
  acq_host_config_write openshell "$name" workspace-mode "$ACQ_OPENSHELL_WORKSPACE_MODE" || true
  [ -n "${_ACQ_OPENSHELL_CLONE_DIR:-}" ] && acq_host_config_write openshell "$name" clone-source "$_ACQ_OPENSHELL_CLONE_DIR" || true
  acq_provenance_write openshell "$name" "$agent" "$workspace" || true
  echo "acq(openshell): experimental local Docker driver; no providers, secrets, kits, or public services were configured." >&2
}

acq_backend_workspace_for() { acq_host_config_read openshell "$1" workspace; }
acq_backend_recorded_agent() { acq_host_config_read openshell "$1" agent; }

acq_backend_run() {
  local name="$1"; shift
  _acq_openshell_cli sandbox exec "$name" "$@"
}

# OpenShell attach is deliberately a shell session in this increment. Do not use
# a recorded non-shell agent until #577 supplies a verified agent entrypoint.
acq_backend_attach() {
  local agent
  agent=$(acq_backend_recorded_agent "$1")
  if [ -n "$agent" ] && [ "$agent" != "shell" ]; then
    acq_backend_validate_agent "$agent"
    return 1
  fi
  exec openshell sandbox connect "$1"
}
acq_backend_shell() { exec openshell sandbox exec --tty "$1" -- sh -l; }
acq_backend_stop() { _acq_openshell_cli sandbox stop "$1"; }
acq_backend_start() { _acq_openshell_cli sandbox start "$1" && _acq_openshell_wait_ready "$1"; }

acq_backend_terminate() {
  local name="$1" rc=0
  _acq_openshell_cli sandbox delete "$name" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _acq_openshell_clone_cleanup "$name"
  acq_host_config_remove openshell "$name" || true
  return 0
}

acq_backend_list() { _acq_openshell_cli sandbox list --output json "$@"; }

acq_backend_cp() {
  local src="$1" dst="$2" name path
  if [[ "$src" =~ ^([A-Za-z0-9._-]+):(/.*)$ ]]; then
    name="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
    _acq_openshell_safe_path "$path" || return 1
    _acq_openshell_cli sandbox download "$name" "$path" "$dst"
  elif [[ "$dst" =~ ^([A-Za-z0-9._-]+):(/.*)$ ]]; then
    name="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
    _acq_openshell_safe_path "$path" || return 1
    _acq_openshell_cli sandbox upload "$name" "$src" "$path"
  else
    echo "acq(openshell): cp requires exactly one NAME:/sandbox/path endpoint." >&2
    return 1
  fi
}

acq_backend_ports() { echo "acq(openshell): ports and public service exposure are unsupported." >&2; return 1; }
acq_backend_apply_kit() { echo "acq(openshell): neutral kit application is unsupported." >&2; return 1; }
acq_backend_ensure_kits_applied() { return 0; }
acq_backend_secret_set() { echo "acq(openshell): providers and secrets are unsupported." >&2; return 1; }
acq_backend_secret_rm() { echo "acq(openshell): providers and secrets are unsupported." >&2; return 1; }
acq_backend_rotate_key() { echo "acq(openshell): providers and key rotation are unsupported." >&2; return 1; }
acq_backend_version() { _acq_openshell_version; }
acq_backend_doctor() { printf 'openshell: experimental local Docker lifecycle adapter (no providers, kits, or services)\n'; }
acq_backend_doctor_sandbox() { _acq_openshell_cli sandbox get "$1" --output json; }
