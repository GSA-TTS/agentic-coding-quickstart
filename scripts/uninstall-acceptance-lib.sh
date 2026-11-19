#!/usr/bin/env bash
# Sourced by scripts/test-uninstall-macos (ADR-0048). Not executable on its own.
# Seeding, keychain, and wizard-runner helpers. Every destructive step acts on
# FAKE_HOME, KC or WORK, which main creates only after the hosted-runner gate;
# each helper fails fast if that gate has not run.
# shellcheck disable=SC2034,SC2154

KC_NAME=acq-uninstall-test.keychain-db
KC_PW=acq-accept-synthetic-pw
PLACEHOLDER=SYNTHETIC-PLACEHOLDER-NOT-A-SECRET
WZ_TIMEOUT=300
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
WORK=''; FAKE_HOME=''; KC=''; WENV=(); WZ_PATH=''
WZ_OUT=''; WZ_ERR=''; WZ_RC=0
ORIG_REAL_KCS=''; ORIG_FAKE_KCS=''; ORIG_REAL_DEF=''; ORIG_FAKE_DEF=''

has_text() { grep -F -- "$1" "$2" >/dev/null 2>&1; }
path_missing() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
manifest() { python3 "$HELPER" manifest "$@"; }
gate_passed() { [ -n "$WORK" ] && [ -n "$FAKE_HOME" ] || { echo 'lib used before the CI gate' >&2; exit 3; }; }

set_wenv() { # PATH
  WZ_PATH=$1
  WENV=(env -i "HOME=$FAKE_HOME" "PATH=$WZ_PATH" TERM=dumb LANG=C LC_ALL=C
    "TMPDIR=$WORK/tmp" 'PS4=+TRACE ')
}

# Keychain commands run with no stdin and a deadline, so a permission prompt or a
# locked keychain fails the stage instead of hanging the job.
sec_run() {
  local rc
  python3 "$HELPER" run "$WORK/sec.out" 60 --no-tty -- "$@"; rc=$?
  cat "$WORK/sec.out"
  return "$rc"
}
sec() { gate_passed; sec_run "${WENV[@]}" /usr/bin/security "$@"; }
sec_real() { gate_passed; sec_run /usr/bin/security "$@"; }
kc_status() { sec find-generic-password -s acq-secret-store >/dev/null 2>&1; echo $?; }
kc_default_of() { "$@" default-keychain -d user 2>/dev/null | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'; }
kc_list_of() { "$@" list-keychains -d user 2>/dev/null | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'; }

keychain_create() {
  gate_passed
  KC="$WORK/keychains/$KC_NAME"
  mkdir -p "$WORK/keychains" "$FAKE_HOME/Library/Preferences" "$FAKE_HOME/Library/Keychains" || return 1
  ORIG_REAL_KCS=$(kc_list_of sec_real); ORIG_FAKE_KCS=$(kc_list_of sec)
  ORIG_REAL_DEF=$(kc_default_of sec_real); ORIG_FAKE_DEF=$(kc_default_of sec)
  sec create-keychain -p "$KC_PW" "$KC" || return 1
  sec set-keychain-settings "$KC" || return 1
  sec unlock-keychain -p "$KC_PW" "$KC" || return 1
  sec list-keychains -d user -s "$KC" || return 1
  sec default-keychain -d user -s "$KC" || return 1
}

# macOS may print the search-list path through a different alias of the same
# directory, so compare the file name, and require that it is the only entry.
keychain_only_ours() {
  local list
  list=$(kc_list_of sec)
  [ -n "$list" ] && [ "$(printf '%s\n' "$list" | wc -l | tr -d ' ')" = 1 ] && [ "${list##*/}" = "$KC_NAME" ]
}

keychain_add_items() {
  local account
  for account in acq-accept-a acq-accept-b; do
    sec add-generic-password -a "$account" -s acq-secret-store -w "$PLACEHOLDER" -A "$KC" || return 1
  done
  sec set-generic-password-partition-list -S 'apple-tool:,apple:' -s acq-secret-store -k "$KC_PW" "$KC" >/dev/null 2>&1 || true
}

# Put back whatever search list existed before, in whichever environment changed it.
keychain_restore() { # runner-fn original-list original-default
  local line
  local -a args=()
  while IFS= read -r line; do [ -z "$line" ] || args+=("$line"); done <<< "$2"
  [ "${#args[@]}" -eq 0 ] || "$1" list-keychains -d user -s "${args[@]}" >/dev/null 2>&1 || true
  [ -z "$3" ] || "$1" default-keychain -d user -s "$3" >/dev/null 2>&1 || true
}

keychain_destroy() {
  [ -n "$KC" ] || return 0
  keychain_restore sec_real "$ORIG_REAL_KCS" "$ORIG_REAL_DEF"
  keychain_restore sec "$ORIG_FAKE_KCS" "$ORIG_FAKE_DEF"
  sec delete-keychain "$KC" >/dev/null 2>&1 || true
  KC=''
}

make_readonly_tree() {
  mkdir -p "$1/a/b/c" || return 1
  printf 'synthetic\n' > "$1/a/b/c/deep.txt"; printf 'synthetic\n' > "$1/a/b/top.txt"
  find "$1" -type f -exec chmod 0444 {} + && find "$1" -depth -type d -exec chmod 0555 {} +
}

# The earlier failure was "rm: Permission denied" on read-only generations. Prove
# the fixture reproduces it with plain rm before trusting the wizard to cope.
probe_readonly_reproduces() {
  make_readonly_tree "$WORK/probe" || return 1
  if rm -rf "$WORK/probe" >/dev/null 2>&1; then return 1; fi
  [ -d "$WORK/probe/a/b/c" ] || return 1
  find "$WORK/probe" -type d -exec chmod u+rwx {} + && rm -rf "$WORK/probe"
}

seed_dirs() {
  local h=$FAKE_HOME
  mkdir -p "$h/.local/state/acq/provenance" "$h/.local/share/acq/secrets" "$h/.local/share/acq/secret-meta" \
    "$h/.config/acq" "$h/.cache/acq" "$h/.microsandbox/sandboxes" "$h/.local/bin" \
    "$h/projects/myapp" "$h/.local/share/other-app" "$h/.config/other-app" || return 1
  printf '%s\n' "$PLACEHOLDER" > "$h/.local/state/acq/state-note"
  printf '%s\n' "$PLACEHOLDER" > "$h/.local/share/acq/secrets/acq.synthetic-a"
  printf '%s\n' "$PLACEHOLDER" > "$h/.local/share/acq/secret-meta/acq.synthetic-a"
  printf 'acq.synthetic-a\n' > "$h/.local/share/acq/secret-index"
  printf '#!/bin/sh\nexit 0\n' > "$h/.local/share/acq/acq"; chmod 0755 "$h/.local/share/acq/acq"
  printf '{}\n' > "$h/.config/acq/config.json"; printf 'x\n' > "$h/.cache/acq/plain.txt"
  printf 'synthetic\n' > "$h/.microsandbox/config.synthetic"
  printf 'original project work\n' > "$h/projects/myapp/keep.txt"
  printf 'other\n' > "$h/.local/share/other-app/data.txt"; printf 'other\n' > "$h/.config/other-app/settings"
  printf '#!/bin/sh\nexit 0\n' > "$h/.local/bin/other-tool"; chmod 0755 "$h/.local/bin/other-tool"
}

seed_links() {
  local h=$FAKE_HOME
  ln -s "$h/.local/share/acq/acq" "$h/.local/bin/acq" || return 1
  ln -s "$h/.microsandbox/bin/msb" "$h/.local/bin/msb" || return 1
  ln -s "$h/projects/myapp" "$h/.config/acq/project-link" || return 1
  ln -s "$h/projects/myapp/keep.txt" "$h/.local/state/acq/file-link" || return 1
}

seed_shell_rc() {
  {
    printf '# user line: keep me\nexport EDITOR=vim\n'
    printf '# >>> microsandbox >>>\nexport PATH="$HOME/.microsandbox/bin:$PATH"\n# <<< microsandbox <<<\n'
    printf '# Added by acq install.sh \xe2\x80\x94 put acq on PATH\nexport PATH="$HOME/.local/bin:$PATH"\n'
  } > "$FAKE_HOME/.zshrc"
}

seed_files() { # with_sbx_record(0|1)
  gate_passed
  seed_dirs && seed_links && seed_shell_rc || return 1
  make_readonly_tree "$FAKE_HOME/.cache/acq/kits/gen-1" || return 1
  [ "$1" != 1 ] || printf 'synthetic sbx provenance record\n' > "$FAKE_HOME/.local/state/acq/provenance/sbx"
}

seeded_manifest() {
  manifest "$FAKE_HOME/.local/share/acq" "$FAKE_HOME/.local/state/acq" "$FAKE_HOME/.config/acq" \
    "$FAKE_HOME/.cache/acq" "$FAKE_HOME/.microsandbox" "$FAKE_HOME/.zshrc" "$FAKE_HOME/.local/bin"
}

PROTECTED_REL='projects .local/share/other-app .config/other-app .local/bin/other-tool'
protected_manifest() {
  local rel args=()
  for rel in $PROTECTED_REL; do args+=("$FAKE_HOME/$rel"); done
  manifest "${args[@]}"
}

seeded_roots() { printf '%s\n' "$FAKE_HOME/.local/share/acq" "$FAKE_HOME/.local/state/acq" "$FAKE_HOME/.config/acq" "$FAKE_HOME/.cache/acq" "$FAKE_HOME/.microsandbox"; }

# Unattended run with a command trace on stderr. env -i keeps runner tokens and
# CI variables out of the subject's code.
wiz_pipe() { # label args...
  local label=$1; shift
  gate_passed
  WZ_OUT="$OUT/logs/$label.out"; WZ_ERR="$OUT/logs/$label.err"
  python3 "$HELPER" run "$WZ_OUT" "$WZ_TIMEOUT" --no-tty --stderr "$WZ_ERR" -- \
    "${WENV[@]}" /bin/bash -x "$UNINSTALLER" "$@"
  WZ_RC=$?
  no_sudo
}

# Interactive run on a pseudo-terminal. TTY_REPLIES holds "--reply EXPECT ANSWER"
# triples; the standalone wizard's trailing "Press Return" pause is answered too.
# No command trace here: it would echo prompt text before the prompt is shown.
TTY_REPLIES=()
wiz_tty() { # label args...
  local label=$1; shift
  gate_passed
  WZ_OUT="$OUT/logs/$label.out"; WZ_ERR=''
  python3 "$HELPER" run "$WZ_OUT" "$WZ_TIMEOUT" ${TTY_REPLIES[@]+"${TTY_REPLIES[@]}"} \
    --reply 'Press Return to exit.' '' -- "${WENV[@]}" /bin/bash "$UNINSTALLER" "$@"
  WZ_RC=$?
  no_sudo
}

no_sudo() {
  [ ! -e "$WORK/priv-shim-called" ] || fail_note 'a privilege-escalation stand-in was invoked'
  [ -z "$WZ_ERR" ] && return 0
  grep -q '^+TRACE ' "$WZ_ERR" || fail_note 'no command trace was captured, so the privilege check proved nothing'
  python3 "$HELPER" trace-privilege "$WZ_ERR" >/dev/null || fail_note 'privilege escalation appears in the wizard command trace'
}

# ------------------------------------------------------------ Homebrew stage

brew_run() { # label timeout args...
  local label=$1 limit=$2; shift 2
  python3 "$HELPER" run "$OUT/logs/$label.out" "$limit" --no-tty -- "${WENV[@]}" \
    HOMEBREW_NO_ASK=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$@"
}

# 0 = listed, 1 = not listed, 2 = brew itself failed (never read as "not listed").
brew_listed() {
  brew_run brew-list 120 brew list --formula || return 2
  if grep -Fx -- "$1" "$OUT/logs/brew-list.out" >/dev/null; then return 0; fi
  return 1
}

# Only the acq formula is installed explicitly, so Homebrew records
# microsandbox-acq as a dependency install: the case where uninstalling acq alone
# can autoremove it and a later explicit uninstall fails with "No such keg".
brew_prepare() {
  local tool
  BREW=$(command -v brew || true)
  [ -n "$BREW" ] || { STAGE_NOTEX='Homebrew is not installed on this runner'; return 1; }
  BREW_DIR=$(dirname "$BREW")
  set_wenv "$BREW_DIR:$BASE_PATH"
  for tool in acq msb microsandbox sbx; do
    if PATH=$WZ_PATH command -v "$tool" >/dev/null 2>&1; then
      STAGE_NOTEX="$tool is already on the runner PATH; the stage needs a clean slate"; return 1
    fi
  done
  for tool in acq microsandbox-acq; do brew_run "brew-trust-$tool" 120 brew trust --formula "GSA-TTS/tap/$tool" || true; done
  brew_run brew-tap 300 brew tap GSA-TTS/tap || { STAGE_NOTEX='brew tap GSA-TTS/tap failed (see brew-tap.out)'; return 1; }
  brew_run brew-install 900 brew install GSA-TTS/tap/acq ||
    { STAGE_NOTEX='brew install GSA-TTS/tap/acq failed (see brew-install.out)'; return 1; }
  brew_listed acq && brew_listed microsandbox-acq ||
    { STAGE_NOTEX='acq and its microsandbox-acq dependency are not both listed after brew install'; return 1; }
  set_wenv "$WORK/shims:$BREW_DIR:$BASE_PATH"
}

brew_assert() {
  local uninstall_lines
  expect_out 'Homebrew packages:' "$WZ_OUT"
  expect_out 'microsandbox-acq' "$WZ_OUT"
  expect_no_out 'No such keg' "$WZ_OUT"; expect_no_out 'No such keg' "$WZ_ERR"
  brew_listed acq; [ $? = 1 ] || fail_note 'acq formula still installed (or brew list failed)'
  brew_listed microsandbox-acq; [ $? = 1 ] || fail_note 'microsandbox-acq formula still installed (or brew list failed)'
  uninstall_lines=$(grep -E 'brew uninstall (acq|microsandbox-acq)$' "$WZ_ERR" | sed 's/.*brew uninstall //' | tr '\n' ' ')
  [ "$uninstall_lines" = 'acq microsandbox-acq ' ] ||
    fail_note "wizard did not uninstall acq then microsandbox-acq explicitly (traced: ${uninstall_lines:-none})"
  [ "$(protected_manifest)" = "$BEFORE_PROTECTED" ] || fail_note 'original project or unrelated files changed'
  [ "$(kc_status)" = 44 ] || fail_note 'keychain item still present'
}

brew_stage() {
  brew_prepare || return 0
  seed_files 0 && keychain_add_items || { fail_note 'cannot seed state for the Homebrew stage'; return 0; }
  BEFORE_PROTECTED=$(protected_manifest)
  wiz_pipe homebrew --yes
  [ "$WZ_RC" = 0 ] || fail_note "removal with Homebrew packages exited $WZ_RC"
  expect_out 'ACQ and Microsandbox have been removed.' "$WZ_OUT"
  brew_assert
}
