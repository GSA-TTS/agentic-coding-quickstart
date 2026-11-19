#!/bin/bash
# Narrow filesystem and credential cleanup for the offline wizard (ADR-0042).
# Variables are initialized by uninstall_paths in the companion module.
# shellcheck disable=SC2154

uninstall_error() { printf 'Removal incomplete: %s\n' "$*" >&2; return 1; }

# Resolve existing ancestors without following any symlink, including dangling
# links. Only narrowly named, user-owned roots below HOME can be deleted.
uninstall_validate_root() {
  local path="$1" allowed="$2" part walk="" relative
  case "$path" in "$HOME"/*) ;; *) uninstall_error "unsafe location: $path"; return 1 ;; esac
  case "$path" in *$'\n'*|*$'\r'*|*'//'*) return 1 ;; esac
  relative="${path#/}"
  while [ -n "$relative" ]; do
    part="${relative%%/*}"
    case "$part" in ''|.|..) uninstall_error "unsafe location: $path"; return 1 ;; esac
    walk="$walk/$part"
    [ ! -L "$walk" ] || { uninstall_error "symlinked location: $walk"; return 1; }
    if [ -e "$walk" ] && [ "$walk" != "$HOME" ] && [[ "$walk" == "$HOME/"* ]]; then
      [ -O "$walk" ] || { uninstall_error "location is not owned by you: $walk"; return 1; }
    fi
    [ "$relative" != "$part" ] || break
    relative="${relative#*/}"
  done
  case "/$allowed/" in *"/$(basename "$path")/"*) ;; *)
    uninstall_error "custom location needs manual review: $path"; return 1 ;;
  esac
}

uninstall_remove_root() {
  uninstall_validate_root "$1" "$2" || return 1
  [ -e "$1" ] || return 0
  # Pin the parent as the working directory. rm never follows symlinks inside
  # its operand; replacing an ancestor after cd cannot redirect this deletion.
  (
    cd -P -- "$(dirname "$1")" || exit 1
    [ "$(pwd -P)" = "$(dirname "$1")" ] || exit 1
    [ ! -L "${1##*/}" ] || exit 1
    # Published generations are intentionally read-only. Change only owned real
    # directories, never symlink targets, before bounded recursive removal.
    if [ -d "${1##*/}" ]; then
      find "${1##*/}" -type d -user "$(id -u)" -exec chmod u+rwx {} + || exit 1
    fi
    rm -rf -- "${1##*/}"
  ) || { uninstall_error "could not remove $1"; return 1; }
  [ ! -e "$1" ] || uninstall_error "still present: $1"
}

# Read only URLs from the original checkout's config; never run Git
# in guest-writable clones or enable config includes/hooks/fsmonitor.
uninstall_clone_remotes() {
  local dir origin config scratch name child rc
  for dir in "$uninstall_clones"/*; do
    [ -d "$dir" ] || continue
    [ ! -L "$dir" ] && [ ! -L "$dir/.origin" ] || return 1
    name="${dir##*/}"
    case "$name" in ''|-*|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    [ -f "$dir/.origin" ] || { uninstall_error "missing clone origin: $dir"; return 1; }
    IFS= read -r origin < "$dir/.origin" || [ -n "$origin" ] || return 1
    uninstall_validate_root "$origin" "$(basename "$origin")" || return 1
    [ -d "$origin" ] || continue
    config=$(uninstall_git_config "$origin") || return 1
    command -v git >/dev/null 2>&1 || { uninstall_error 'Git is needed to remove temporary project remotes.'; return 1; }
    if git config --file "$config" --no-includes --get-regexp "^remote\\.sandbox-$name\\." >/dev/null; then
      :
    else
      rc=$?
      [ "$rc" = 1 ] && continue
      return 1
    fi
    scratch=""
    for child in "$dir"/*; do
      [ -d "$child/.git" ] || continue
      [ -z "$scratch" ] && [ ! -L "$child" ] && [ ! -L "$child/.git" ] || {
        uninstall_error "ambiguous scratch clone in $dir; inspect sandbox-$name manually."; return 1; }
      scratch="$child"
    done
    [ -n "$scratch" ] &&
      uninstall_remote_urls_match "$config" "remote.sandbox-$name.url" "$scratch" required &&
      uninstall_remote_urls_match "$config" "remote.sandbox-$name.pushurl" "$scratch" optional || {
      uninstall_error "temporary remote was changed in $origin; inspect sandbox-$name manually."; return 1; }
    uninstall_validate_root "$config" config || return 1
    git config --file "$config" --no-includes --remove-section "remote.sandbox-$name" || return 1
  done
}

# NUL records preserve embedded/trailing newlines. The final record carries Git's
# status so a failed config read cannot be mistaken for an absent optional URL.
uninstall_remote_urls_match() {
  local config="$1" key="$2" scratch="$3" required="$4" record previous="" count=0
  while IFS= read -r -d '' record; do
    if [ "$count" -gt 0 ]; then
      [ "$previous" = "$scratch" ] || return 1
    fi
    previous="$record"
    count=$((count + 1))
  done < <(git config --file "$config" --no-includes --null --get-all "$key"; printf '%s\0' "$?")
  case "$previous" in
    0) [ "$count" -gt 1 ] ;;
    1) [ "$count" = 1 ] && [ "$required" = optional ] ;;
    *) return 1 ;;
  esac
}

# Linked worktrees store a gitdir pointer and a relative commondir pointer.
# Canonicalize those paths, then validate every canonical ancestor before using
# the shared config. No Git command is executed in the scratch clone.
uninstall_git_config() {
  local origin="$1" pointer gitdir common config
  if [ -d "$origin/.git" ]; then
    config="$origin/.git/config"
  else
    uninstall_validate_root "$origin/.git" .git || return 1
    [ -f "$origin/.git" ] || return 1
    IFS= read -r pointer < "$origin/.git" || return 1
    case "$pointer" in 'gitdir: '*) gitdir="${pointer#gitdir: }" ;; *) return 1 ;; esac
    case "$gitdir" in /*) ;; *) gitdir="$origin/$gitdir" ;; esac
    gitdir=$(cd -P -- "$gitdir" && pwd -P) || return 1
    uninstall_validate_root "$gitdir" "${gitdir##*/}" || return 1
    uninstall_validate_root "$gitdir/commondir" commondir || return 1
    IFS= read -r common < "$gitdir/commondir" || return 1
    case "$common" in /*) ;; *) common="$gitdir/$common" ;; esac
    common=$(cd -P -- "$common" && pwd -P) || return 1
    config="$common/config"
  fi
  uninstall_validate_root "$config" config || return 1
  [ -f "$config" ] || { uninstall_error "cannot safely inspect original project: $origin"; return 1; }
  printf '%s\n' "$config"
}

# Legacy records contain PIDs but no process start identity. Never signal a PID
# on that evidence: restart/close sessions instead of risking PID reuse.
uninstall_helpers() {
  local file serve ssh rest pid
  for file in "$uninstall_ports"/*.pids; do
    [ -f "$file" ] || continue
    [ ! -L "$file" ] || return 1
    while read -r serve ssh rest || [ -n "$serve$ssh$rest" ]; do
      for pid in "$serve" "$ssh"; do
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        [ "$pid" -gt 1 ] || return 1
        if kill -0 "$pid" 2>/dev/null; then
          uninstall_error "A recorded forwarding process ($pid) may still be running. Close sessions or restart your computer, then retry. No process was killed."; return 1
        fi
      done
    done < "$file"
    rm -f -- "$file" || return 1
  done
}

# Delete by service label, never retrieve or print a credential. Repetition also
# catches old Keychain items whose on-disk index has already been removed.
uninstall_security() { /usr/bin/security "$@"; }

uninstall_macos_secrets() {
  local rc
  printf 'macOS may ask for permission to remove saved ACQ credentials.\n'
  while :; do
    uninstall_security find-generic-password -s acq-secret-store >/dev/null 2>&1
    rc=$?
    case "$rc" in 44) return 0 ;; 0) ;; *) uninstall_error 'Keychain access failed. Unlock your login keychain and retry.'; return 1 ;; esac
    uninstall_security delete-generic-password -s acq-secret-store >/dev/null 2>&1 || {
      uninstall_error 'Keychain deletion was denied. Allow access and retry.'; return 1; }
  done
}

uninstall_secret_tool_available() { command -v secret-tool >/dev/null 2>&1; }
uninstall_secret_tool() { secret-tool "$@"; }

uninstall_linux_secret_clear() {
  local rc
  if uninstall_secret_tool clear acq_key "$1" >/dev/null 2>&1; then return 0; else rc=$?; fi
  # clear returns 1 both for no match and errors. search returns 0 on a
  # successful empty search; any item output (including locked items) blocks
  # cleanup. Consume output without logging or retaining credential values.
  if [ "$rc" = 1 ] && (
    set -o pipefail
    uninstall_secret_tool search --all acq_key "$1" 2>/dev/null | awk 'END { exit NR != 0 }'
  ); then return 0; fi
  uninstall_error 'Credential deletion or absence verification failed. Unlock the secret store and retry.'
}

uninstall_linux_secrets() {
  local key file seen=$'\n' available=0
  uninstall_secret_tool_available && available=1
  for file in "$uninstall_index" "$uninstall_meta"/acq.*; do
    [ ! -L "$file" ] || return 1
    [ -f "$file" ] || continue
    if [ "$file" = "$uninstall_index" ]; then
      while IFS= read -r key || [ -n "$key" ]; do
        case "$key" in acq.*) ;; *) return 1 ;; esac
        case "$key" in *[!A-Za-z0-9._-]*) return 1 ;; esac
        case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
        seen="$seen$key"$'\n'
        uninstall_linux_secret_record "$key" "$available" || return 1
      done < "$file"
    else
      key="${file##*/}"
      case "$key" in *[!A-Za-z0-9._-]*) return 1 ;; esac
      case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
      seen="$seen$key"$'\n'
      uninstall_linux_secret_record "$key" "$available" || return 1
    fi
  done
}

uninstall_linux_secret_record() {
  # A fallback file never proves the keyring copy is gone: migration keeps the
  # old file and the index write may have failed. Every known key (indexed or
  # metadata) is cleared or verified absent in Secret Service. Without the
  # service, the record is ambiguous and is preserved. The file's contents are
  # never read.
  if [ -e "$uninstall_secrets/$1" ] || [ -L "$uninstall_secrets/$1" ]; then
    [ -f "$uninstall_secrets/$1" ] && [ ! -L "$uninstall_secrets/$1" ] || return 1
  fi
  [ "$2" = 1 ] || {
    uninstall_error 'An unresolved credential record remains but secret-tool is missing. Restore it before removal.'; return 1; }
  uninstall_linux_secret_clear "$1"
}

# Only unlink launchers whose target is one of the inventoried installations.
uninstall_links() {
  local link target name
  for name in acq msb microsandbox; do
    link="$uninstall_bin/$name"
    if [ ! -L "$link" ]; then
      [ ! -e "$link" ] || { uninstall_error "unrecognized launcher: $link"; return 1; }
      continue
    fi
    target=$(readlink "$link") || return 1
    case "$target" in
      "$uninstall_clone/acq"|"$uninstall_msb_home/bin/msb"|"$uninstall_msb_home/bin/microsandbox")
        rm -f -- "$link" || return 1 ;;
      *) uninstall_error "unrecognized launcher target: $link"; return 1 ;;
    esac
  done
}

# Remove only exact installer-owned blocks. Keep shared PATH entries when other
# commands remain in .local/bin, and never remove user-authored PATH lines.
uninstall_shell_config() {
  local file tmp other entry
  other=0
  for entry in "$uninstall_bin"/*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || other=1
  done
  for file in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$file" ] || continue
    uninstall_validate_root "$file" "${file##*/}" || return 1
    tmp=$(mktemp "$HOME/.acq-uninstall-shell.XXXXXX") || return 1
    if ! awk -v keep_path="$other" -v bin_dir="$uninstall_bin" '
      /^# >>> microsandbox >>>$/ { if (block) exit 1; block=1; next }
      /^# <<< microsandbox <<<$/{ if (!block) exit 1; block=0; next }
      block { next }
      pending {
        if (($0 == "export PATH=\"$HOME/.local/bin:$PATH\"" || $0 == "export PATH=\"" bin_dir ":$PATH\"") && !keep_path) { pending=0; next }
        print "# Added by acq install.sh — put acq on PATH"; pending=0
      }
      /^# Added by acq install.sh — put acq on PATH$/ { pending=1; next }
      { print }
      END { if (block) exit 1; if (pending) print "# Added by acq install.sh — put acq on PATH" }
    ' "$file" > "$tmp"; then
      rm -f -- "$tmp"
      uninstall_error "unmatched installer markers in $file; review manually."; return 1
    fi
    if ! cmp -s "$file" "$tmp"; then
      uninstall_validate_root "$file" "${file##*/}" || { rm -f -- "$tmp"; return 1; }
      cat "$tmp" > "$file" || { rm -f -- "$tmp"; return 1; }
    fi
    rm -f -- "$tmp" || return 1
  done
}
