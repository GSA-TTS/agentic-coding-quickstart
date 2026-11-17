#!/bin/bash
# Installation ownership and migrated-state checks for the shared recovery engine.
# State roots are initialized by the companion uninstall module.
# shellcheck disable=SC2154

uninstall_installation_inventory() {
  local name line marker
  uninstall_install="${ACQ_INSTALL_DIR:-$uninstall_data}"
  [ "$uninstall_install" = "$uninstall_data" ] || {
    uninstall_error 'Custom ACQ_INSTALL_DIR requires manual ownership review; no files removed.'; return 1; }
  uninstall_validate_root "$uninstall_install" acq || return 1
  uninstall_owned=()
  uninstall_marked=0
  marker="$uninstall_install/.acq-v1-install"
  if { [ -e "$uninstall_install/.acq-uninstalled" ] || [ -L "$uninstall_install/.acq-uninstalled" ] ||
    [ -e "$uninstall_install/.acq-uninstall-pending" ] || [ -L "$uninstall_install/.acq-uninstall-pending" ]; } &&
    [ ! -f "$marker" ]; then
    uninstall_error 'Uninstall transaction ownership manifest is missing. Review the installation manually; no files removed.'; return 1
  fi
  if [ -e "$uninstall_install/.acq-uninstalled" ] || [ -L "$uninstall_install/.acq-uninstalled" ]; then
    uninstall_validate_root "$uninstall_install/.acq-uninstalled" .acq-uninstalled || return 1
    [ -f "$uninstall_install/.acq-uninstalled" ] || return 1
  fi
  if [ -e "$uninstall_install/.acq-uninstall-pending" ] || [ -L "$uninstall_install/.acq-uninstall-pending" ]; then
    uninstall_validate_root "$uninstall_install/.acq-uninstall-pending" .acq-uninstall-pending || return 1
    [ -d "$uninstall_install/.acq-uninstall-pending" ] || return 1
    uninstall_pending_inventory || return 1
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    uninstall_validate_root "$marker" .acq-v1-install || return 1
    [ -f "$marker" ] || return 1
    uninstall_marked=1
    IFS= read -r line < "$marker" || return 1
    case "$line" in ''|*[!0-9a-zA-Z.+-]*) return 1 ;; esac
    while IFS= read -r name || [ -n "$name" ]; do
      case "$name" in
        acq|acq-python|acq.cmd|acq.ps1|acq.backends|py-acq|wheelhouse|LICENSE|README.md|provenance.json|install.ps1|uninstall.command)
          uninstall_owned+=("$name") ;;
        *) uninstall_error "unknown owned installation entry: $name"; return 1 ;;
      esac
    done < <(tail -n +2 "$marker")
    if [ "${#uninstall_owned[@]}" = 0 ] && [ ! -f "$uninstall_install/.acq-uninstalled" ]; then
      uninstall_error 'Empty installation ownership manifest; no files removed.'; return 1
    fi
  elif [ -e "$uninstall_install/py-acq" ] || [ -L "$uninstall_install/acq-python" ]; then
    uninstall_error 'Python installation ownership marker is missing. Review its files manually.'; return 1
  fi
}

uninstall_installation_remove() {
  local name entry
  if [ "$uninstall_marked" = 1 ]; then
    for name in ${uninstall_owned[@]+"${uninstall_owned[@]}"}; do
      # Top-level symlinks are unlinked, never traversed; directories are removed
      # only if listed in the validated installer marker.
      mkdir -p "$uninstall_install/.acq-uninstall-pending" || return 1
      # Move first: a pending entry proves the original pathname was relinquished
      # even if the manifest update was interrupted. Never move it twice.
      if [ ! -e "$uninstall_install/.acq-uninstall-pending/$name" ] && [ ! -L "$uninstall_install/.acq-uninstall-pending/$name" ]; then
        if [ -e "$uninstall_install/$name" ] || [ -L "$uninstall_install/$name" ]; then
          mv -- "$uninstall_install/$name" "$uninstall_install/.acq-uninstall-pending/$name" || return 1
        else
          # An empty payload is durable evidence that the absent original name
          # was relinquished, even if the following manifest update fails.
          mkdir "$uninstall_install/.acq-uninstall-pending/$name" || return 1
        fi
      fi
      uninstall_manifest_drop "$name" || return 1
      uninstall_pending_remove "$name" || return 1
    done
    # Finish entries whose manifest claim was removed before an interrupted rm.
    for entry in "$uninstall_install/.acq-uninstall-pending"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      uninstall_pending_remove "${entry##*/}" || return 1
    done
    [ ! -d "$uninstall_install/.acq-uninstall-pending" ] || rmdir "$uninstall_install/.acq-uninstall-pending" || return 1
    # Keep exhausted ownership evidence even when no user files remain. Removing
    # it before rmdir creates an interruption window that authorizes legacy rm.
    printf 'Retained exhausted ownership markers in %s for safe retries.\n' "$uninstall_install"
  else
    uninstall_remove_root "$uninstall_install" acq || return 1
  fi
}

uninstall_pending_inventory() {
  local entry name
  for entry in "$uninstall_install/.acq-uninstall-pending"/* \
    "$uninstall_install/.acq-uninstall-pending"/.[!.]* "$uninstall_install/.acq-uninstall-pending"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    uninstall_owned_name "$name" || { uninstall_error "Unknown pending installation entry: $name"; return 1; }
    # Payload symlinks are unlinked, never followed; other payloads must be
    # regular files or directories accepted by the same removal path checks.
    [ ! -L "$entry" ] || continue
    uninstall_validate_root "$entry" "$name" || return 1
    [ -f "$entry" ] || [ -d "$entry" ] || { uninstall_error "Unsupported pending entry: $name"; return 1; }
  done
}

uninstall_owned_name() {
  case "$1" in acq|acq-python|acq.cmd|acq.ps1|acq.backends|py-acq|wheelhouse|LICENSE|README.md|provenance.json|install.ps1|uninstall.command) return 0 ;; *) return 1 ;; esac
}

uninstall_python_available() { [ -x "$1" ]; }

uninstall_pending_remove() {
  local target="$uninstall_install/.acq-uninstall-pending/$1"
  uninstall_owned_name "$1" || return 1
  if [ -L "$target" ]; then rm -f -- "$target" || return 1
  else uninstall_remove_root "$target" "$1" || return 1; fi
}

uninstall_manifest_drop() {
  local tmp
  tmp=$(mktemp "$uninstall_install/.acq-uninstall-manifest.XXXXXX") || return 1
  awk -v removed="$1" 'NR == 1 || $0 != removed' "$uninstall_install/.acq-v1-install" > "$tmp" || return 1
  # This marker distinguishes exhausted removal from a malformed empty manifest.
  touch "$uninstall_install/.acq-uninstalled" || return 1
  mv -f -- "$tmp" "$uninstall_install/.acq-v1-install" || return 1
}

# JSON records need a parser, not shell pattern matching. Use an existing local
# interpreter before any deletion, never acquire a runtime or migrate state.
uninstall_migrated_state() {
  local file python="" candidate
  for file in "$uninstall_state/msb"/*.json "$uninstall_state/sbx"/*.json \
    "$uninstall_state/provider-credentials"/*.json "$uninstall_state/github-scope"/*/*.json \
    "$uninstall_state/msb-secret-bindings"/*.json "$uninstall_state/kit-sources"/*.json \
    "$uninstall_state/provenance"/*/*.json "$uninstall_state/kit-consent"/*/*.json \
    "$uninstall_state/kit-applied"/*/*.json "$uninstall_state/generation"; do
    [ -e "$file" ] || continue
    uninstall_validate_root "$file" "${file##*/}" || return 1
    # System parsers are independent of the user-writable installation being
    # removed. Never execute its private runtime during destructive inventory.
    if [ -z "$python" ]; then
      for candidate in /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
        uninstall_python_available "$candidate" || continue
        if "$candidate" -I -c 'import json, sys; assert json.loads("{\"schema\":1}")["schema"] == 1' </dev/null; then
          python="$candidate"; break
        fi
        uninstall_error "Python parser failed at $candidate; trying the next system parser."
      done
    fi
    [ -n "$python" ] || { uninstall_error 'JSON state needs a working system Python 3 parser at /usr/bin/python3, /usr/local/bin/python3, or /opt/homebrew/bin/python3. Repair or install one before retrying; no files removed.'; return 1; }
    "$python" -I - "$file" <<'PY' || { uninstall_error "Unknown or invalid migrated state: $file"; return 1; }
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    record = json.load(stream)
if not isinstance(record, dict) or type(record.get("schema")) is not int or record["schema"] != 1:
    sys.exit(1)
minimum = record.get("min_reader", 1)
if type(minimum) is not int or minimum > 1:
    sys.exit(1)
PY
  done
}
