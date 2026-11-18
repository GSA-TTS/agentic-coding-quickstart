#!/bin/bash
# Offline, backend-independent uninstall entry point. See ADR-0036.
# The release builder embeds uninstall-files.sh; do not source host state.

uninstall_paths() {
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ ! -L "$HOME" ] && [ -O "$HOME" ] || {
    uninstall_error 'A real, user-owned home directory is required.'; return 1; }
  [ "$(id -u)" != 0 ] || { uninstall_error 'Run as your normal user, not with sudo.'; return 1; }
  uninstall_data="${XDG_DATA_HOME:-$HOME/.local/share}/acq"
  uninstall_state="${ACQ_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/acq}"
  uninstall_config="${XDG_CONFIG_HOME:-$HOME/.config}/acq"
  uninstall_cache="${XDG_CACHE_HOME:-$HOME/.cache}/acq"
  uninstall_clone="${ACQ_INSTALL_CLONE_DIR:-$uninstall_data}"
  uninstall_msb_home="${MSB_HOME:-$HOME/.microsandbox}"
  uninstall_bin="${ACQ_INSTALL_BIN_DIR:-$HOME/.local/bin}"
  uninstall_ports="${ACQ_MSB_PORTS_DIR:-$uninstall_state/ports}"
  uninstall_clones="${ACQ_MSB_CLONES_DIR:-$uninstall_state/clones}"
  uninstall_secrets="${ACQ_SECRET_FILE_DIR:-$uninstall_data/secrets}"
  uninstall_meta="${ACQ_SECRET_META_DIR:-${uninstall_secrets%/secrets}/secret-meta}"
  uninstall_index="${ACQ_SECRET_INDEX_FILE:-${uninstall_secrets%/secrets}/secret-index}"
  uninstall_standard_paths || return 1
  local path
  for path in "$uninstall_data" "$uninstall_state" "$uninstall_config" "$uninstall_cache" "$uninstall_clone"; do
    uninstall_validate_root "$path" acq || return 1
  done
  uninstall_validate_root "$uninstall_msb_home" '.microsandbox/microsandbox' || return 1
  uninstall_validate_root "$uninstall_bin" bin || return 1
  uninstall_validate_root "$uninstall_ports" ports || return 1
  uninstall_validate_root "$uninstall_clones" clones || return 1
  uninstall_validate_root "$uninstall_secrets" secrets || return 1
  uninstall_validate_root "$uninstall_meta" secret-meta || return 1
  uninstall_validate_root "$uninstall_index" secret-index || return 1
}

# Names alone cannot prove a custom directory is disposable. Recognize overrides
# but block nonstandard roots before any action, rather than deleting a project
# that happens to be called acq. This also covers custom key/cache/provenance data.
uninstall_standard_paths() {
  local setting expected actual pair
  for pair in \
    "XDG_DATA_HOME:$HOME/.local/share" "XDG_STATE_HOME:$HOME/.local/state" \
    "XDG_CONFIG_HOME:$HOME/.config" "XDG_CACHE_HOME:$HOME/.cache" \
    "ACQ_STATE_DIR:$HOME/.local/state/acq" "MSB_HOME:$HOME/.microsandbox" \
    "ACQ_INSTALL_CLONE_DIR:$HOME/.local/share/acq" "ACQ_INSTALL_BIN_DIR:$HOME/.local/bin" \
    "ACQ_MSB_PORTS_DIR:$HOME/.local/state/acq/ports" "ACQ_MSB_CLONES_DIR:$HOME/.local/state/acq/clones" \
    "ACQ_MSB_SSH_DIR:$HOME/.local/state/acq/ssh" "ACQ_MSB_SSH_KEY:$HOME/.local/state/acq/ssh/msb_id_ed25519" \
    "ACQ_MSB_SSH_KNOWN_HOSTS:$HOME/.local/state/acq/ssh/known_hosts" \
    "ACQ_MSB_SSH_AGENT_LINK_DIR:$HOME/.local/state/acq/msb/ssh-agent" \
    "ACQ_MSB_KIT_CACHE:$HOME/.cache/acq/kits" "ACQ_SBX_KIT_CACHE:$HOME/.cache/acq/sbx-kits" \
    "ACQ_SECRET_FILE_DIR:$HOME/.local/share/acq/secrets" "ACQ_SECRET_META_DIR:$HOME/.local/share/acq/secret-meta" \
    "ACQ_SECRET_INDEX_FILE:$HOME/.local/share/acq/secret-index" \
    "ACQ_PROVIDER_INPUT_DATA_DIR:$HOME/.local/share/acq/provider-input-validator" \
    "ACQ_PROVIDER_FACTS_CACHE_DIR:$HOME/.local/state/acq/provider-facts" \
    "ACQ_PROVENANCE_DIR:$HOME/.local/state/acq/provenance" \
    "ACQ_MSB_STARTUP_STAGE_DIR:$HOME/.local/state/acq/msb-startup" \
    "ACQ_MSB_UPSTREAM_CA_FILE:$HOME/.local/state/acq/msb/host-upstream-cas.pem"; do
    setting="${pair%%:*}"; expected="${pair#*:}"; actual="${!setting-}"
    [ -z "$actual" ] || [ "$actual" = "$expected" ] || {
      uninstall_error "$setting uses a custom location. Review and remove that installation manually; no files removed."; return 1; }
  done
  [ -z "${ACQ_SECRET_STORE_DIR:-}" ] || { uninstall_error 'Custom secret store requires manual review.'; return 1; }
}

uninstall_inventory() {
  local formula path
  uninstall_os=$(uname -s)
  case "$uninstall_os" in Darwin|Linux) ;; *) uninstall_error 'This uninstaller supports macOS and Linux only.'; return 1 ;; esac
  uninstall_paths || return 1
  # This wizard is deliberately MSB-only: shared ACQ state may still be required
  # by existing SBX sandboxes, even if MSB is also installed.
  if command -v sbx >/dev/null 2>&1; then
    uninstall_error "SBX is installed at $(command -v sbx). Check its sandbox inventory with 'sbx ls' before removing SBX. This wizard does not remove SBX or its native storage."; return 1
  fi
  uninstall_sbx_records=0
  if [ -e "$uninstall_state/provenance/sbx" ] || [ -L "$uninstall_state/provenance/sbx" ] ||
    [ -e "$uninstall_state/sbx" ] || [ -L "$uninstall_state/sbx" ]; then
    uninstall_sbx_records=1
  fi
  uninstall_msb=$(command -v msb || true)
  [ -n "$uninstall_msb" ] || { [ ! -x "$uninstall_msb_home/bin/msb" ] || uninstall_msb="$uninstall_msb_home/bin/msb"; }
  uninstall_formulas=()
  if command -v brew >/dev/null 2>&1; then
    uninstall_brew_list=$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --formula) || return 1
    while IFS= read -r formula; do
      case "$formula" in acq|microsandbox|microsandbox-acq|microsandbox-acq@[0-9]*) uninstall_formulas+=("$formula") ;; esac
    done <<< "$uninstall_brew_list"
  fi
  uninstall_npm=0
  if command -v npm >/dev/null 2>&1; then
    path=$(npm root -g) || return 1
    [ ! -f "$path/@gsa-tts/agentic-coding-quickstart/package.json" ] || uninstall_npm=1
  fi
  uninstall_names=""; uninstall_running=""
  if [ -n "$uninstall_msb" ]; then
    uninstall_names=$("$uninstall_msb" ls -q) || { uninstall_error 'MSB cannot list sandboxes. Repair its catalog before removal.'; return 1; }
    uninstall_running=$("$uninstall_msb" ls -q --running) || return 1
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      case "$path" in -*|*[!A-Za-z0-9_-]*) uninstall_error 'MSB returned an unsafe sandbox name.'; return 1 ;; esac
    done <<< "$uninstall_names
$uninstall_running"
  elif [ -d "$uninstall_msb_home/sandboxes" ]; then
    for path in "$uninstall_msb_home/sandboxes"/* "$uninstall_msb_home/sandboxes"/.[!.]*; do
      [ ! -e "$path" ] || { uninstall_error 'MSB is missing but sandbox data remains. Restore MSB to stop and remove it safely.'; return 1; }
    done
  fi
}

uninstall_preview() {
  local path
  printf '\nACQ Uninstaller\n\n'
  printf 'Removes ACQ, Microsandbox, ALL MSB sandboxes, saved ACQ credentials,\nsettings, caches, and temporary project clones. SBX is not removed.\n\n'
  printf 'Your original project folders, Homebrew, npm, and Git will be kept.\nWork saved only in a sandbox or temporary clone will be LOST.\nQuit your coding-agent sessions before continuing.\n\n'
  if [ "$uninstall_sbx_records" = 1 ]; then
    printf 'Historical ACQ records for SBX were found under:\n  %s\n  %s\n' "$uninstall_state/provenance/sbx" "$uninstall_state/sbx"
    printf 'These are ACQ records, not sandbox disks. SBX is missing, so sandbox\nstatus cannot be checked. Confirm there are no remaining SBX sandboxes\nbefore removal. SBX native storage and daemon are NOT removed.\n\n'
  fi
  if [ -n "$uninstall_names" ]; then printf 'Sandboxes found:\n%s\n\n' "$uninstall_names"; fi
  for path in "$uninstall_clones"/*; do
    [ -d "$path" ] || continue
    printf 'WARNING: temporary clone %s may contain unfetched work.\nRecover needed work before confirming.\n' "${path##*/}"
  done
  printf 'Locations to remove (when present):\n'
  printf '  %s\n' "$uninstall_data" "$uninstall_state" "$uninstall_config" "$uninstall_cache" "$uninstall_clone" "$uninstall_msb_home"
  if [ "${#uninstall_formulas[@]}" -gt 0 ]; then printf 'Homebrew packages: %s\n' "${uninstall_formulas[*]}"; fi
  [ "$uninstall_npm" = 0 ] || printf 'npm package: @gsa-tts/agentic-coding-quickstart\n'
}

uninstall_confirm() {
  local answer
  if [ "$uninstall_sbx_records" = 1 ] && [ "$uninstall_sbx_confirmed" = 0 ]; then
    [ -t 0 ] && [ "$uninstall_yes" = 0 ] || {
      uninstall_error 'SBX sandbox absence is unverified. After verifying no SBX sandboxes remain, use --confirm-no-sbx-sandboxes; --yes alone is not sufficient.'; return 1; }
    printf '\nHave you confirmed there are no remaining SBX sandboxes? [y/N]: '
    IFS= read -r answer || return 1
    case "$answer" in y|Y|yes|YES) ;; *) printf 'Cancelled. Nothing removed.\n'; return 2 ;; esac
  fi
  [ "$uninstall_yes" = 0 ] || return 0
  [ -t 0 ] || { uninstall_error 'No interactive terminal. Use --yes only after reviewing --dry-run.'; return 1; }
  printf '\nPermanently remove ACQ and Microsandbox? [y/N]: '
  IFS= read -r answer || return 1
  case "$answer" in y|Y|yes|YES) return 0 ;; *) printf 'Cancelled. Nothing removed.\n'; return 2 ;; esac
}

uninstall_sandboxes() {
  local name remaining
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! "$uninstall_msb" stop --timeout 30 "$name"; then
      uninstall_error "Could not stop $name. No sandbox data will be deleted. Stop it manually and retry."; return 1
    fi
  done <<< "$uninstall_running"
  uninstall_helpers || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    "$uninstall_msb" rm "$name" || { uninstall_error "Could not remove $name. State has been preserved."; return 1; }
  done <<< "$uninstall_names"
  if [ -n "$uninstall_msb" ]; then
    remaining=$("$uninstall_msb" ls -q) || return 1
    [ -z "$remaining" ] || { uninstall_error 'Sandboxes remain. Close agent sessions and retry.'; return 1; }
  fi
  uninstall_clone_remotes || return 1
  printf '✓ Removed sandboxes, forwarding helpers, and temporary project remotes.\n'
}

uninstall_packages() {
  local formula installed
  for formula in ${uninstall_formulas[@]+"${uninstall_formulas[@]}"}; do
    installed=$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --formula) || return 1
    if printf '%s\n' "$installed" | grep -Fx -- "$formula" >/dev/null; then
      HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 brew uninstall "$formula" || return 1
    fi
  done
  if [ "$uninstall_npm" = 1 ]; then
    npm uninstall -g --ignore-scripts @gsa-tts/agentic-coding-quickstart || return 1
  fi
  printf '✓ Removed installed packages.\n'
}

uninstall_cleanup() {
  local path
  uninstall_sandboxes || return 1
  case "$uninstall_os" in
    Darwin) uninstall_macos_secrets || return 1 ;;
    Linux) uninstall_linux_secrets || return 1 ;;
  esac
  printf '✓ Removed saved ACQ credentials.\n'
  uninstall_packages || return 1
  uninstall_links || return 1
  uninstall_shell_config || return 1
  uninstall_remove_root "$uninstall_ports" ports || return 1
  uninstall_remove_root "$uninstall_clones" clones || return 1
  uninstall_remove_root "$uninstall_secrets" secrets || return 1
  uninstall_remove_root "$uninstall_meta" secret-meta || return 1
  uninstall_remove_root "$uninstall_index" secret-index || return 1
  uninstall_remove_root "$uninstall_msb_home" '.microsandbox/microsandbox' || return 1
  for path in "$uninstall_data" "$uninstall_state" "$uninstall_config" "$uninstall_cache" "$uninstall_clone"; do
    uninstall_remove_root "$path" acq || return 1
  done
  printf '✓ Removed ACQ and Microsandbox settings, stored files, and caches.\n'
}

uninstall_verify() {
  local command_name formulas root formula
  hash -r
  for command_name in acq msb microsandbox; do
    if command -v "$command_name" >/dev/null 2>&1; then
      uninstall_error "$command_name is still available at $(command -v "$command_name"). Remove that additional installation and retry."; return 1
    fi
  done
  if command -v brew >/dev/null 2>&1; then
    formulas=$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --formula) || return 1
    for formula in ${uninstall_formulas[@]+"${uninstall_formulas[@]}"}; do
      if printf '%s\n' "$formulas" | grep -Fx -- "$formula" >/dev/null; then return 1; fi
    done
  fi
  if [ "$uninstall_npm" = 1 ]; then
    root=$(npm root -g) || return 1
    [ ! -e "$root/@gsa-tts/agentic-coding-quickstart" ] || return 1
  fi
  printf '\nACQ and Microsandbox have been removed.\nYour original project folders were preserved.\nOpen a new Terminal window before reinstalling or checking commands.\n'
}

uninstall_main() {
  local arg rc
  uninstall_yes=0; uninstall_dry=0; uninstall_sbx_confirmed=0
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) uninstall_yes=1 ;;
      --dry-run) uninstall_dry=1 ;;
      --confirm-no-sbx-sandboxes) uninstall_sbx_confirmed=1 ;;
      --help|-h) printf 'Usage: acq uninstall [--dry-run] [--yes] [--confirm-no-sbx-sandboxes]\nRemove ACQ and all local MSB sandboxes, credentials, and installation files.\nSBX and original project folders are kept. No network downloads or sudo.\n--confirm-no-sbx-sandboxes asserts you verified no SBX sandboxes remain\nwhen only historical ACQ records remain. It does not bypass installed SBX.\n'; return 0 ;;
      *) uninstall_error "unknown option: $arg"; return 2 ;;
    esac
  done
  uninstall_inventory || return 1
  uninstall_preview
  [ "$uninstall_dry" = 0 ] || { printf '\nDry run. Nothing removed.\n'; return 0; }
  uninstall_confirm; rc=$?
  [ "$rc" != 2 ] || return 0
  [ "$rc" = 0 ] || return "$rc"
  uninstall_cleanup && uninstall_verify || {
    uninstall_error 'Review the message above and rerun. Already-removed components will be skipped.'; return 1; }
}
