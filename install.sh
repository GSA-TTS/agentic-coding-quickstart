#!/bin/sh
# install.sh — hardened installer for acq (agentic-coding-quickstart)
#
# One front door that puts `acq` on your PATH, and (with your consent) installs
# the `msb` sandbox runtime it needs. You never have to choose an install
# method: this script auto-selects the best one already available on your host —
#
#   1. Homebrew  (if `brew` is present)  -> brew upgrade/uninstall semantics
#   2. npm       (if `npm`  is present)  -> npm -g upgrade/uninstall semantics
#   3. git clone (fallback)              -> always works with just curl + git
#
# It works on a bare macOS system: it uses `curl`, and `git` (which the clone
# method sets up for you by triggering the Command Line Tools install — no admin
# needed). It never uses `sudo`, installs only under your home directory, and
# never changes your PATH without asking first.
#
# Usage:
#   curl -fsSL <release-asset-url>/install.sh | sh
#   sh install.sh [--method brew|npm|clone] [--ref <tag-or-branch>]
#                 [--sha <full-commit>] [--no-msb] [--dry-run] [--yes]
#                 [--help]
#
# Running this script from a source checkout still installs from REPO_URL at the
# default release tag; it does not install the local working tree.
#
# Inspect first (recommended): download and read this file, then run it.

set -eu

# ---------------------------------------------------------------------------
# Defaults (overridable by flags / environment)
# ---------------------------------------------------------------------------

REPO_URL="${ACQ_INSTALL_REPO_URL:-https://github.com/GSA-TTS/agentic-coding-quickstart.git}"
# release-please updates this version in release PRs. Release automation also
# publishes an install.sh asset with DEFAULT_RELEASE_SHA replaced by the exact
# release commit so clone installs can verify they landed on that commit.
DEFAULT_RELEASE_VERSION="3.1.0" # x-release-please-version
DEFAULT_RELEASE_REF="v$DEFAULT_RELEASE_VERSION"
DEFAULT_RELEASE_SHA=""
REF="${ACQ_INSTALL_REF:-$DEFAULT_RELEASE_REF}"
REF_WAS_SET=0
[ "${ACQ_INSTALL_REF+x}" = x ] && REF_WAS_SET=1

# Optional: pin to an exact 40-char commit SHA. Release assets set this to the
# release commit by default; source checkouts leave it empty so local/dev installs
# can still target REF unless ACQ_INSTALL_SHA or --sha is supplied.
SHA="${ACQ_INSTALL_SHA:-$DEFAULT_RELEASE_SHA}"
SHA_WAS_SET=0
[ -n "${ACQ_INSTALL_SHA:-}" ] && SHA_WAS_SET=1

# Where the managed clone lives (preserves `acq version` git introspection).
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CLONE_DIR="${ACQ_INSTALL_CLONE_DIR:-$DATA_HOME/acq}"

# Where the `acq` launcher symlink goes (must be a user-writable PATH dir).
BIN_DIR="${ACQ_INSTALL_BIN_DIR:-$HOME/.local/bin}"

# Install method: auto (detect), or forced to brew|npm|clone via --method.
METHOD="${ACQ_INSTALL_METHOD:-auto}"

# npm package spec used by the npm method (pinned by --ref when possible).
NPM_SPEC_BASE="github:GSA-TTS/agentic-coding-quickstart"
# Homebrew formula used by the brew method.
BREW_FORMULA="GSA-TTS/tap/acq"

# msb 0.7.0-0.7.2 migrate 0.6.x sandbox state one-way into a format the 0.6.x
# line cannot read. Install a pinned last-known-good release when acq needs to
# install or repair msb, and accept the fixed line when present. See ADR-0031.
MSB_MIN_VERSION="0.6.9"
MSB_PINNED_VERSION="0.6.18"
MSB_BLOCKED_VERSION_MIN="0.7.0"
MSB_BLOCKED_VERSION_MAX="0.7.2"

# First release carrying the upstream cross-version compatibility fix. Moving
# FORWARD to this is strictly safer than rolling back to the pin: the migration
# sets are additive, so this line reads a catalog an earlier 0.7.x already
# migrated with no rollback, no data-affecting step, and no snapshot refusal.
# Prefer it whenever the host can reach it; the pin remains the fallback for a
# host that cannot move forward.
MSB_FIXED_VERSION="0.7.3"

# Where pinned msb release artifacts come from. The upstream one-line installer
# is deliberately NOT used to place a pinned version: it resolves the version at
# run time from `releases/latest` and takes no version argument, and every
# release publishes a byte-identical copy of that script as a release asset — so
# a versioned asset URL looks like a pin but installs whatever is newest. We
# therefore fetch the release bundle and its published checksum directly.
MSB_RELEASE_BASE="https://github.com/superradcompany/microsandbox/releases/download"

# Homebrew formulae. Our tap carries a version-pinned formula; upstream's tap
# formula always tracks the newest release and so cannot hold a supported
# version. Both own `bin/msb`, so only one may be linked at a time.
MSB_BREW_FORMULA="GSA-TTS/tap/microsandbox-acq"
MSB_BREW_UPSTREAM_FORMULA="superradcompany/tap/microsandbox"

# Keg-only, version-specific formulae in our tap, for reaching one exact msb
# without disturbing the linked one (e.g. to run `msb self downgrade` with the
# binary that performed a migration — only that binary can roll it back). Keg-only
# means they are never symlinked into the Homebrew prefix, so any number of them
# coexist with each other and with the linked formula above.
MSB_BREW_VERSIONED_PREFIX="GSA-TTS/tap/microsandbox-acq@"

# Where the upstream layout keeps msb (honoring MSB_HOME, as msb itself does).
MSB_HOME_DIR="${MSB_HOME:-$HOME/.microsandbox}"

INSTALL_MSB=1   # offer to install msb; --no-msb disables
DRY_RUN=0
ASSUME_YES=0
NEED_PATH_HELP=0   # set by the clone method when BIN_DIR is not on PATH

# ---------------------------------------------------------------------------
# Output helpers (no color if not a TTY)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  B="$(printf '\033[1m')"; R="$(printf '\033[0m')"
  YEL="$(printf '\033[33m')"; GRN="$(printf '\033[32m')"; RED="$(printf '\033[31m')"
else
  B=""; R=""; YEL=""; GRN=""; RED=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
warn()  { printf '%s%s%s\n' "$YEL" "$*" "$R" >&2; }
ok()    { printf '%s%s%s\n' "$GRN" "$*" "$R"; }
die()   { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

# In dry-run, show what would run; otherwise run it. Child stdin is detached so
# a child never consumes the `curl | sh` script pipe (fd 0).
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@" </dev/null
  fi
}

usage() {
  cat <<'EOF'
install.sh — install acq (agentic-coding-quickstart)

It auto-selects the best method already on your host: Homebrew, then npm, then
a git clone. Override with --method.

When run directly from a source checkout, the clone method still installs from
the configured repository at the default release tag; it does not install your
local working tree.

Options:
  --method <m>         Force install method: brew | npm | clone (default: auto).
  --ref <tag|branch>   Version to install (default: latest release tag baked
                       into this installer).
  --sha <commit>       Force clone install, pin to a full 40-char commit SHA,
                       and verify HEAD matches it after checkout.
  --no-msb             Do not install the msb sandbox runtime.
  --dry-run            Print what would happen; make no changes.
  --yes, -y            Assume "yes" to prompts (PATH edit, msb install).
                       Intended for non-interactive/CI use.
  --help               Show this help.

Environment overrides:
  ACQ_INSTALL_METHOD, ACQ_INSTALL_REF, ACQ_INSTALL_SHA, ACQ_INSTALL_REPO_URL,
  ACQ_INSTALL_CLONE_DIR, ACQ_INSTALL_BIN_DIR

This installer uses no sudo, installs only under your home directory, and
never changes your PATH without asking.
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --method) [ $# -ge 2 ] || die "--method needs a value"; METHOD="$2"; shift 2 ;;
    --method=*) METHOD="${1#--method=}"; shift ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a value"; REF="$2"; REF_WAS_SET=1; shift 2 ;;
    --ref=*) REF="${1#--ref=}"; REF_WAS_SET=1; shift ;;
    --sha) [ $# -ge 2 ] || die "--sha needs a value"; SHA="$2"; SHA_WAS_SET=1; shift 2 ;;
    --sha=*) SHA="${1#--sha=}"; SHA_WAS_SET=1; shift ;;
    --no-msb) INSTALL_MSB=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$METHOD" in
  auto|brew|npm|clone) : ;;
  *) die "invalid --method '$METHOD' (expected: brew, npm, or clone)" ;;
esac

# A release asset's baked SHA only describes its baked default ref. If callers
# choose another ref without also choosing a SHA, install that ref normally.
if [ "$REF_WAS_SET" -eq 1 ] && [ "$SHA_WAS_SET" -eq 0 ]; then
  SHA=""
fi

# A pinned SHA must be a full 40-hex commit id (short SHAs and tags cannot be
# verified against HEAD the same way). Reject anything else up front.
if [ "$SHA_WAS_SET" -eq 1 ] && [ -z "$SHA" ]; then
  die "invalid --sha '$SHA' (expected a 40-char hex commit id)"
fi
if [ -n "$SHA" ]; then
  case "$SHA" in
    *[!0-9a-fA-F]*) die "invalid --sha '$SHA' (expected a 40-char hex commit id)" ;;
    *) [ "${#SHA}" -eq 40 ] || die "invalid --sha '$SHA' (expected a 40-char hex commit id)" ;;
  esac
fi

# Explicit SHA pinning only applies to the git-clone method (npm/brew resolve
# their own packages). A release asset's baked SHA is a clone-path consistency
# check and does not by itself override package-manager auto-selection.
if [ "$SHA_WAS_SET" -eq 1 ] && { [ "$METHOD" = "npm" ] || [ "$METHOD" = "brew" ]; }; then
  die "--sha is only supported with --method clone"
fi

# ---------------------------------------------------------------------------
# Prompt helper — yes/no, honoring --yes and non-interactive stdin
# ---------------------------------------------------------------------------
# Returns 0 for yes, 1 for no. Default is NO when there is no way to ask
# (fail-closed: never take a consent-gated action without an explicit yes).
confirm() {
  prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  # If stdin is a terminal, ask there.
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$prompt"
    read -r ans || return 1
  # Otherwise (e.g. piped `curl | sh`), try the controlling terminal. Guard the
  # write/read so an unusable /dev/tty falls through to a clean decline rather
  # than leaking errors.
  elif { printf '%s [y/N] ' "$prompt" > /dev/tty; } 2>/dev/null \
       && read -r ans < /dev/tty 2>/dev/null; then
    :
  else
    return 1
  fi
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

version_ge() {
  a=$1 b=$2 i=1
  while [ "$i" -le 3 ]; do
    a_part=$(printf '%s\n' "$a" | cut -d. -f"$i")
    b_part=$(printf '%s\n' "$b" | cut -d. -f"$i")
    a_part=${a_part%%[!0-9]*}; b_part=${b_part%%[!0-9]*}
    a_part=${a_part:-0}; b_part=${b_part:-0}
    if [ "$a_part" -gt "$b_part" ]; then return 0; fi
    if [ "$a_part" -lt "$b_part" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

msb_version_blocked() {
  v="$1"
  version_ge "$v" "$MSB_BLOCKED_VERSION_MIN" || return 1
  version_ge "$MSB_BLOCKED_VERSION_MAX" "$v" || return 1
  return 0
}

msb_version_of() {
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true
}

# Release bundle basename for this host, e.g. microsandbox-darwin-aarch64.tar.gz.
# Empty means "this platform has no published bundle we know how to place", and
# callers fall back to guidance rather than guessing an artifact name.
msb_bundle_name() {
  _os=$(uname -s 2>/dev/null || echo unknown)
  _arch=$(uname -m 2>/dev/null || echo unknown)
  case "$_arch" in
    arm64|aarch64) _arch=aarch64 ;;
    x86_64|amd64)  _arch=x86_64 ;;
    *) return 0 ;;
  esac
  case "$_os" in
    Darwin) [ "$_arch" = "aarch64" ] || return 0
            printf 'microsandbox-darwin-aarch64.tar.gz\n' ;;
    Linux)  printf 'microsandbox-linux-%s.tar.gz\n' "$_arch" ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

step "Checking your system"

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  Darwin) : ;;
  Linux)  warn "Linux detected — supported, but this installer is tuned for macOS." ;;
  *)      warn "Unrecognized OS '$OS' — proceeding, but this is untested here." ;;
esac

if [ "$OS" = "Darwin" ]; then
  ARCH="$(uname -m 2>/dev/null || echo unknown)"
  if [ "$ARCH" != "arm64" ]; then
    warn "This Mac reports arch '$ARCH'. acq's msb backend requires Apple Silicon"
    warn "(Intel Macs are not supported for microVMs). Install will continue, but"
    warn "the sandbox may not run. See the README prerequisites."
  fi
fi

command -v curl >/dev/null 2>&1 || die "curl is required but was not found."

# ---------------------------------------------------------------------------
# Method selection — auto picks brew, then npm, then clone
# ---------------------------------------------------------------------------

if [ "$METHOD" = "auto" ]; then
  if [ "$SHA_WAS_SET" -eq 1 ]; then
    METHOD="clone"
  elif command -v brew >/dev/null 2>&1 && [ "$REF_WAS_SET" -eq 0 ]; then
    METHOD="brew"
  elif command -v npm >/dev/null 2>&1; then
    METHOD="npm"
  else
    METHOD="clone"
  fi
  info "  install method: $METHOD (auto-selected)"
else
  info "  install method: $METHOD (forced)"
fi

# Homebrew versioning is controlled by the formula in the tap. Avoid pretending a
# caller-supplied git ref can affect `brew install GSA-TTS/tap/acq`.
if [ "$METHOD" = "brew" ] && [ "$REF_WAS_SET" -eq 1 ]; then
  die "--ref is not supported with --method brew; use brew update/upgrade or choose --method npm|clone"
fi
if [ "$METHOD" = "brew" ]; then
  info "  version:   Homebrew formula"
else
  info "  version:   $REF"
  [ "$METHOD" = "clone" ] && [ -n "$SHA" ] && info "  pinned commit: $SHA"
fi
[ "$DRY_RUN" -eq 1 ] && warn "  (dry-run: no changes will be made)"

# ---------------------------------------------------------------------------
# Method: Homebrew
# ---------------------------------------------------------------------------

install_via_brew() {
  step "Installing acq via Homebrew"
  info "  Homebrew gives you 'brew upgrade acq' / 'brew uninstall acq' later."
  if [ "$DRY_RUN" -eq 0 ] && ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required for --method brew. Install Homebrew or choose --method npm|clone."
  fi
  run brew install "$BREW_FORMULA"
  if [ "$DRY_RUN" -eq 0 ] && command -v acq >/dev/null 2>&1; then
    ok "  acq is installed via Homebrew ($(command -v acq))."
  elif [ "$DRY_RUN" -eq 0 ]; then
    NEED_PATH_HELP=1
    warn "  Homebrew finished, but 'acq' is not on your PATH yet. Ensure Homebrew's"
    warn "  bin directory is on PATH (usually /opt/homebrew/bin or /usr/local/bin)."
  fi
}

# ---------------------------------------------------------------------------
# Method: npm  (functional — package.json ships an `acq` bin + files)
# ---------------------------------------------------------------------------

install_via_npm() {
  step "Installing acq via npm"
  info "  npm gives you 'npm -g upgrade' / 'npm -g uninstall' later."
  spec="$NPM_SPEC_BASE"
  # Pin the git ref into the npm spec when one is set, so `npm -g` installs the
  # same version the rest of the installer targets.
  [ -n "$REF" ] && spec="$NPM_SPEC_BASE#$REF"
  run npm install -g "$spec"
  if [ "$DRY_RUN" -eq 0 ] && command -v acq >/dev/null 2>&1; then
    ok "  acq is installed via npm ($(command -v acq))."
  elif [ "$DRY_RUN" -eq 0 ]; then
    NEED_PATH_HELP=1
    npm_bin="$(npm prefix -g 2>/dev/null)"
    [ -n "$npm_bin" ] && npm_bin="$npm_bin/bin"
    warn "  npm finished, but 'acq' is not on your PATH yet. Ensure npm's global"
    warn "  bin dir is on PATH: ${npm_bin:-\$(npm prefix -g)/bin}"
  fi
}

# ---------------------------------------------------------------------------
# Method: managed git clone + launcher symlink  (fully functional fallback)
# ---------------------------------------------------------------------------

path_has_bindir() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Choose the login shell's rc file for the suggested PATH line.
rc_file_for_shell() {
  case "${SHELL:-}" in
    */zsh) printf '%s\n' "$HOME/.zshrc" ;;
    */bash) printf '%s\n' "$HOME/.bash_profile" ;;
    *) printf '%s\n' "$HOME/.profile" ;;
  esac
}

# Is `git` actually runnable? On macOS the /usr/bin/git shim exists even with no
# Command Line Tools, but invoking it errors ("no developer tools were found").
# So we probe by RUNNING git, not just `command -v`.
git_is_usable() {
  command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1
}

checkout_pinned_sha() {
  repo="$1"
  cleanup_on_fail="$2"
  git -C "$repo" checkout "$SHA" 2>/dev/null && return 0
  git -C "$repo" fetch --unshallow --tags origin \
    '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null \
    || git -C "$repo" fetch --tags origin \
      '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null \
    || true
  git -C "$repo" checkout "$SHA" && return 0
  [ "$cleanup_on_fail" = "cleanup" ] && rm -rf "$repo"
  die "pinned commit '$SHA' not found in $REPO_URL"
}

# Ensure a usable git, proactively triggering the macOS Command Line Tools
# install and waiting for it to finish. No sudo required. On non-macOS (or if
# the tools never appear) this fails closed with guidance.
ensure_git() {
  if git_is_usable; then
    return 0
  fi

  if [ "$OS" != "Darwin" ]; then
    die "git is required but was not found. Install git and re-run this installer."
  fi

  # The Command Line Tools install is an interactive, GUI-driven step: it pops a
  # dialog a human must click, then we poll for up to 30 minutes. That is useless
  # in a non-interactive context (--yes/CI, or piped stdin with no controlling
  # terminal): the dialog can't be clicked and the job would just block until the
  # timeout. Fail fast instead, with the same actionable guidance.
  #
  # "Interactive" here means: we can reach a terminal to guide the user. That is
  # true if stdin is a TTY, or if we can open the controlling terminal /dev/tty.
  # Probe /dev/tty in a subshell so a failed open can't abort this script.
  can_reach_tty=1
  [ -t 0 ] || ( : >/dev/tty ) 2>/dev/null || can_reach_tty=0
  if [ "$ASSUME_YES" -eq 1 ] || [ "$can_reach_tty" -eq 0 ]; then
    die "git is required but the macOS Command Line Tools are not installed.
This installer can set them up interactively, but it is running non-interactively
(--yes or no terminal), so it will not launch the GUI installer and wait. Install
the tools first, then re-run:

    xcode-select --install"
  fi

  step "Setting up the developer tools acq needs (git)"
  info "  macOS provides git through the Command Line Tools, which aren't installed yet."
  info "  These are also needed to run acq later, so we install them now — no admin required."

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] xcode-select --install  (then wait for git to become usable)\n'
    return 0
  fi

  # Trigger the GUI installer. It returns immediately; the install runs in a
  # separate window. A non-zero exit usually means "already installed / in
  # progress", which is fine — we verify by polling git below.
  xcode-select --install >/dev/null 2>&1 || true

  info ""
  warn "  A window titled \"Install Command Line Developer Tools\" should appear."
  warn "  Click Install and accept the license. If you don't see it, LOOK IN YOUR"
  warn "  DOCK — the window sometimes opens minimized there instead of in front."
  info ""
  info "  Waiting for the tools to finish installing... (this can take a few minutes)"

  # Poll until git is usable. Cap the wait so we never hang forever; a user who
  # cancels the dialog will hit the timeout and get actionable guidance.
  waited=0
  max_wait=1800   # 30 minutes
  while ! git_is_usable; do
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge "$max_wait" ]; then
      die "Timed out waiting for the Command Line Tools to install.
Finish the installation (look for the window, possibly in your Dock), then
re-run this installer. You can also install them manually with:

    xcode-select --install"
    fi
  done
  ok "  Command Line Tools are installed — git is ready."
}

install_via_clone() {
  ensure_git

  info "  clone dir: $CLONE_DIR"
  info "  launcher:  $BIN_DIR/acq"
  [ -n "$SHA" ] && info "  pinned to commit: $SHA"

  # What we ultimately want HEAD to be. A pinned SHA wins over the ref.
  target="${SHA:-$REF}"

  # --- Clone or update the managed clone ---
  if [ -e "$CLONE_DIR/.git" ]; then
    step "Updating existing install at $CLONE_DIR"
    run git -C "$CLONE_DIR" fetch --tags --prune origin
    if [ -n "$SHA" ] && [ "$DRY_RUN" -eq 0 ]; then
      checkout_pinned_sha "$CLONE_DIR" keep
    else
      run git -C "$CLONE_DIR" checkout "$target"
    fi
    if [ "$DRY_RUN" -eq 0 ] && [ -z "$SHA" ] \
       && git -C "$CLONE_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
      # Only fast-forward when on a branch (a pinned SHA is detached HEAD).
      run git -C "$CLONE_DIR" pull --ff-only origin "$REF"
    fi
  elif [ -e "$CLONE_DIR" ]; then
    die "$CLONE_DIR exists but is not a git clone. Move it aside and re-run."
  else
    step "Downloading acq into $CLONE_DIR"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  [dry-run] git clone --depth 1 --branch %s %s %s\n' "$REF" "$REPO_URL" "$CLONE_DIR"
      [ -n "$SHA" ] && printf '  [dry-run] git checkout %s  (then verify HEAD == SHA)\n' "$SHA"
    else
      # Try a shallow clone of the requested ref (tag or branch). If that fails
      # (e.g. a full commit SHA, which --branch can't take), fall back to a full
      # clone and then check the target out. Either way, we MUST end up on the
      # target — fail closed if we can't, and clean up any partial clone so a
      # re-run isn't wedged by a half-populated directory.
      if ! git clone --depth 1 --branch "$REF" "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
        rm -rf "$CLONE_DIR"
        git clone "$REPO_URL" "$CLONE_DIR" \
          || { rm -rf "$CLONE_DIR"; die "failed to clone $REPO_URL"; }
      fi
      if [ -n "$SHA" ]; then
        checkout_pinned_sha "$CLONE_DIR" cleanup
      else
        git -C "$CLONE_DIR" checkout "$REF" \
          || { rm -rf "$CLONE_DIR"; die "requested version '$REF' not found in $REPO_URL"; }
      fi
    fi
  fi

  # --- Clone consistency check: HEAD must equal the pinned SHA. ---
  if [ -n "$SHA" ] && [ "$DRY_RUN" -eq 0 ]; then
    head_sha="$(git -C "$CLONE_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    if [ "$head_sha" != "$SHA" ]; then
      rm -rf "$CLONE_DIR"
      die "integrity check failed: HEAD is '$head_sha', expected pinned SHA '$SHA'"
    fi
    ok "  verified HEAD matches pinned commit $SHA"
  fi


  # --- Symlink the launcher onto PATH ---
  step "Linking the acq launcher"
  run mkdir -p "$BIN_DIR"

  acq_target="$CLONE_DIR/acq"
  if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$acq_target" ]; then
    die "expected launcher not found at $acq_target (did the clone succeed?)"
  fi
  run ln -sf "$acq_target" "$BIN_DIR/acq"
  ok "  linked $BIN_DIR/acq -> $acq_target"

  # --- PATH handling — never modified without consent ---
  path_line="export PATH=\"$BIN_DIR:\$PATH\""

  if path_has_bindir; then
    ok "  $BIN_DIR is already on your PATH."
  else
    NEED_PATH_HELP=1
    rc_file="$(rc_file_for_shell)"
    step "Your PATH does not include $BIN_DIR"
    info "  To type 'acq' from anywhere, that directory needs to be on your PATH."
    if confirm "  Add it to $rc_file for you?"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] append to %s: %s\n' "$rc_file" "$path_line"
      elif [ -f "$rc_file" ] && grep -qF "$path_line" "$rc_file" 2>/dev/null; then
        ok "  $rc_file already contains the PATH line — leaving it as-is."
      else
        {
          printf '\n# Added by acq install.sh — put acq on PATH\n'
          printf '%s\n' "$path_line"
        } >> "$rc_file"
        ok "  Added the line to $rc_file."
      fi
      info "  Open a new terminal (or run: ${B}source \"$rc_file\"${R}) to pick it up."
    else
      warn "  Not changing your PATH. To do it yourself, add this line to $rc_file:"
      printf '\n    %s\n\n' "$path_line"
      info "  Then open a new terminal (or run: source \"$rc_file\")."
    fi
  fi
}

msb_candidate_paths() {
  if command -v msb >/dev/null 2>&1; then
    command -v msb
  fi

  old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || dir=.
    [ -x "$dir/msb" ] && printf '%s\n' "$dir/msb"
  done
  IFS=$old_ifs

  [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/msb" ] && printf '%s\n' "$HOME/.local/bin/msb"

  if command -v brew >/dev/null 2>&1; then
    # Only formulae that LINK bin/msb can affect which msb runs. The
    # microsandbox-acq@<version> formulae are keg-only by design — installed but
    # never symlinked into the prefix — so they cannot shadow anything and are
    # deliberately not probed here. Reporting them would turn a correct
    # side-by-side install into a spurious "multiple msb binaries" warning.
    for formula in "$MSB_BREW_UPSTREAM_FORMULA" "$MSB_BREW_FORMULA" microsandbox; do
      brew_prefix=$(brew --prefix "$formula" 2>/dev/null || true)
      [ -n "$brew_prefix" ] && [ -x "$brew_prefix/bin/msb" ] && printf '%s\n' "$brew_prefix/bin/msb"
    done
  fi
}

msb_unique_candidates() {
  seen=""
  msb_candidate_paths | while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "
$seen
" in
      *"
$candidate
"*) ;;
      *)
        seen="${seen}
${candidate}"
        printf '%s\n' "$candidate"
        ;;
    esac
  done
}

msb_report_candidates() {
  count=0
  versions=""
  active="$(command -v msb 2>/dev/null || true)"
  candidates=$(msb_unique_candidates)
  [ -n "$candidates" ] || return 0

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    count=$((count + 1))
    ver=$(msb_version_of "$candidate")
    [ -n "$ver" ] || ver="unknown"
    versions="${versions} ${ver}"
  done <<EOF
$candidates
EOF

  if [ "$count" -le 1 ]; then
    return 0
  fi

  warn "  Multiple msb binaries were found; PATH order determines which one acq uses."
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    ver=$(msb_version_of "$candidate")
    [ -n "$ver" ] || ver="unknown"
    marker=""
    [ -n "$active" ] && [ "$candidate" = "$active" ] && marker=" (active)"
    warn "    $candidate: $ver$marker"
  done <<EOF
$candidates
EOF
  warn "  Remove stale copies or adjust PATH so the intended msb appears first."
  if [ -n "$(msb_upstream_brew_prefix)" ]; then
    warn "  One of these is Homebrew's $MSB_BREW_UPSTREAM_FORMULA, which always tracks the"
    warn "  newest release and cannot hold a supported version. Remove it with:"
    warn "    brew uninstall $MSB_BREW_UPSTREAM_FORMULA"
  fi
}

# Installed prefix of upstream's always-latest brew formula, or empty. Used both
# to explain PATH shadowing and to decide whether a downgrade needs a `brew
# uninstall` first: our pinned formula also owns `bin/msb`, so the two conflict.
msb_upstream_brew_prefix() {
  command -v brew >/dev/null 2>&1 || return 0
  for formula in "$MSB_BREW_UPSTREAM_FORMULA" microsandbox; do
    prefix=$(brew --prefix "$formula" 2>/dev/null || true)
    if [ -n "$prefix" ] && [ -d "$prefix" ]; then
      printf '%s\n' "$prefix"
      return 0
    fi
  done
}

# sha256 of a file, via whichever tool this host has. Empty means neither exists,
# and callers MUST fail closed rather than install an unverified artifact.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

# Abandon a pinned-install attempt: report why, drop the scratch dir, and clear
# the cleanup trap so an unrelated later failure cannot re-run it. Always fails,
# so callers can `msb_pin_abort "..." && return 1` — see install_msb_pinned_tarball.
msb_pin_abort() {
  warn "  $1"
  [ -n "${2:-}" ] && rm -rf "$2"
  trap - EXIT HUP INT TERM
  return 1
}

# Install the pinned msb release by fetching the release bundle and verifying it
# against that release's published checksums.sha256. This deliberately does not
# reuse upstream's install.sh (see MSB_RELEASE_BASE above for why it cannot pin).
# Layout matches upstream's: $MSB_HOME_DIR/{bin,lib} plus ~/.local/bin links.
install_msb_pinned_tarball() {
  bundle=$(msb_bundle_name)
  if [ -z "$bundle" ]; then
    warn "  No pinned msb bundle is published for $(uname -s)/$(uname -m)."
    warn "  Install msb $MSB_PINNED_VERSION manually, then re-run this installer."
    return 1
  fi

  base="$MSB_RELEASE_BASE/v$MSB_PINNED_VERSION"
  info "  Installing msb $MSB_PINNED_VERSION from the pinned release bundle..."
  info "  ($base/$bundle, verified against that release's checksums.sha256.)"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] curl -fsSL %s/%s -o <tmp>/%s\n' "$base" "$bundle" "$bundle"
    printf '  [dry-run] curl -fsSL %s/checksums.sha256 -o <tmp>/checksums.sha256\n' "$base"
    printf '  [dry-run] verify sha256, extract, install into %s/{bin,lib}\n' "$MSB_HOME_DIR"
    printf '  [dry-run] link %s/msb -> %s/bin/msb\n' "$BIN_DIR" "$MSB_HOME_DIR"
    return 0
  fi

  command -v tar >/dev/null 2>&1 || { warn "  tar is required to install msb."; return 1; }

  tmpdir="${TMPDIR:-/tmp}/acq-msb-pin.$$"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir" || { warn "  Could not create $tmpdir."; return 1; }
  trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

  curl -fsSL "$base/$bundle" -o "$tmpdir/$bundle" \
    || msb_pin_abort "Could not download $base/$bundle." "$tmpdir" || return 1
  curl -fsSL "$base/checksums.sha256" -o "$tmpdir/checksums.sha256" \
    || msb_pin_abort "Could not download $base/checksums.sha256." "$tmpdir" || return 1

  expected=$(grep -F " $bundle" "$tmpdir/checksums.sha256" 2>/dev/null | cut -d' ' -f1)
  [ -n "$expected" ] \
    || msb_pin_abort "No checksum for $bundle in the release's checksums.sha256." "$tmpdir" || return 1
  actual=$(sha256_of "$tmpdir/$bundle")
  [ -n "$actual" ] \
    || msb_pin_abort "Neither sha256sum nor shasum is available to verify the download." "$tmpdir" || return 1
  [ "$expected" = "$actual" ] \
    || msb_pin_abort "Checksum mismatch for $bundle (expected $expected, got $actual)." "$tmpdir" || return 1
  ok "  Verified $bundle (sha256 $actual)."

  ( cd "$tmpdir" && tar -xzf "$bundle" ) \
    || msb_pin_abort "Could not extract $bundle." "$tmpdir" || return 1
  [ -f "$tmpdir/msb" ] \
    || msb_pin_abort "The release bundle did not contain an msb binary." "$tmpdir" || return 1

  # Derive the libkrunfw filename and ABI from the artifact rather than pinning
  # another version here; the bundle carries exactly one versioned library.
  libname=""
  for candidate in "$tmpdir"/libkrunfw.so.*.*.* "$tmpdir"/libkrunfw.*.dylib; do
    [ -f "$candidate" ] || continue
    [ -z "$libname" ] \
      || msb_pin_abort "The release bundle carried more than one libkrunfw library." "$tmpdir" || return 1
    libname=$(basename "$candidate")
  done
  [ -n "$libname" ] \
    || msb_pin_abort "The release bundle did not contain a libkrunfw library." "$tmpdir" || return 1

  # Validate the ABI BEFORE writing anything, so a malformed bundle cannot leave
  # a half-installed runtime behind.
  case "$libname" in
    *.dylib) abi=${libname#libkrunfw.}; abi=${abi%.dylib} ;;
    *)       abi=${libname#libkrunfw.so.}; abi=${abi%%.*} ;;
  esac
  case "$abi" in
    ''|*[!0-9]*) msb_pin_abort "The bundle's libkrunfw ABI version ('$abi') is not numeric." "$tmpdir" || return 1 ;;
  esac

  mkdir -p "$MSB_HOME_DIR/bin" "$MSB_HOME_DIR/lib" \
    || msb_pin_abort "Could not create $MSB_HOME_DIR." "$tmpdir" || return 1

  # install(1) unlinks first, so a running msb keeps its own inode. On macOS the
  # code signature is cached on the vnode, so the library is replaced by
  # write-then-rename rather than overwritten in place.
  install -m 755 "$tmpdir/msb" "$MSB_HOME_DIR/bin/msb" \
    || msb_pin_abort "Could not install msb into $MSB_HOME_DIR/bin." "$tmpdir" || return 1
  ln -sf msb "$MSB_HOME_DIR/bin/microsandbox"

  case "$libname" in
    *.dylib)
      cp "$tmpdir/$libname" "$MSB_HOME_DIR/lib/$libname.tmp" \
        && mv "$MSB_HOME_DIR/lib/$libname.tmp" "$MSB_HOME_DIR/lib/$libname" \
        || msb_pin_abort "Could not install $libname." "$tmpdir" || return 1
      ln -sf "$libname" "$MSB_HOME_DIR/lib/libkrunfw.dylib"
      ;;
    *)
      install -m 644 "$tmpdir/$libname" "$MSB_HOME_DIR/lib/$libname" \
        || msb_pin_abort "Could not install $libname." "$tmpdir" || return 1
      ln -sf "$libname" "$MSB_HOME_DIR/lib/libkrunfw.so.$abi"
      ln -sf "libkrunfw.so.$abi" "$MSB_HOME_DIR/lib/libkrunfw.so"
      ;;
  esac

  # Link into the same user-writable bin dir acq uses. Never clobber a real file
  # a user put there by hand; only manage our own symlink.
  mkdir -p "$BIN_DIR"
  for name in msb microsandbox; do
    if [ -e "$BIN_DIR/$name" ] && [ ! -L "$BIN_DIR/$name" ]; then
      warn "  Left $BIN_DIR/$name alone: it exists and is not a symlink."
      continue
    fi
    ln -sf "$MSB_HOME_DIR/bin/$name" "$BIN_DIR/$name"
  done

  rm -rf "$tmpdir"
  trap - EXIT HUP INT TERM
  ok "  Installed msb $MSB_PINNED_VERSION to $MSB_HOME_DIR/bin/msb."
}

# Install the pinned msb. Homebrew hosts get our version-pinned formula so that
# `brew upgrade` stays meaningful and brew keeps owning what it installed;
# everyone else gets the verified release bundle.
install_msb_pinned() {
  if command -v brew >/dev/null 2>&1; then
    info "  Installing msb $MSB_PINNED_VERSION via Homebrew ($MSB_BREW_FORMULA)..."
    if run brew install "$MSB_BREW_FORMULA"; then
      return 0
    fi
    warn "  Homebrew could not install $MSB_BREW_FORMULA; falling back to the"
    warn "  pinned release bundle."
  fi
  install_msb_pinned_tarball
}

# Does this msb refuse to open the local catalog because a newer msb migrated it?
# That is the one-way 0.6.x -> 0.7.x catalog migration, and no amount of swapping
# binaries fixes it; the state itself has to be rolled back first.
msb_catalog_ahead() {
  out=$("$1" list 2>&1 </dev/null || true)
  case "$out" in
    *"schema is newer"*|*"not in this binary's migration prefix"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Path of an interrupted `msb self downgrade` journal, or empty.
#
# A failed downgrade leaves $MSB_HOME/db/self-downgrade/<id>/journal.json behind,
# and msb then refuses EVERY command from EVERY version until that operation is
# resumed:
#
#   error: self_downgrade_recovery_required: resume the active downgrade
#   recorded at .../db/self-downgrade/<id>/journal.json
#
# When the journal records a transition that cannot complete — which is exactly
# what a too-old binary leaves behind, because it stages a target it then cannot
# roll the database back to — the demand is unsatisfiable and the install is
# wedged. Verified against msb 0.6.18/0.7.2/0.7.3: resuming with the journal's
# own target, with a different target, and from each of the three binaries all
# fail identically, and `self downgrade` exposes no abort or clear flag. The only
# exit is removing the journal directory, after which a correctly-ordered
# downgrade succeeds normally.
msb_stale_downgrade_journal() {
  for journal in "$MSB_HOME_DIR"/db/self-downgrade/*/journal.json; do
    [ -f "$journal" ] || continue
    printf '%s\n' "$journal"
    return 0
  done
}

# Clear a wedged downgrade journal, with consent. Deliberately narrow: it removes
# only the self-downgrade operation directory, never the database, the backups, or
# any sandbox state.
clear_stale_downgrade_journal() {
  journal="$1"
  opdir=$(dirname "$journal")

  step "An interrupted msb downgrade is blocking every msb command"
  warn "  msb records an in-progress 'self downgrade' here:"
  info "    $journal"
  warn "  Until that operation finishes, msb refuses all commands — including"
  warn "  read-only ones, and including from a different msb version. If the"
  warn "  recorded transition cannot complete (a too-old msb leaves exactly that"
  warn "  behind), there is no way to resume it and no flag to abandon it."
  info "  Removing that operation directory clears the block. It does NOT touch"
  info "  your database, your retained downgrade backups, or any sandbox."

  if ! confirm "  Remove $opdir now?"; then
    warn "  Leaving it in place. msb will keep refusing every command. To do it"
    warn "  yourself:"
    info  "    rm -rf \"$opdir\""
    return 1
  fi

  run rm -rf "$opdir" || { warn "  Could not remove $opdir."; return 1; }
  ok "  Cleared the interrupted downgrade; msb commands should work again."
}

# Roll a 0.7.x-migrated catalog back so a supported msb can read it again.
#
# This MUST be driven by the currently-installed 0.7.x binary: `msb self
# downgrade` builds its rollback plan from the running binary's own migration
# metadata, takes a database backup, and reverts the migrations the older line
# does not know. Installing the older binary first strands the catalog instead —
# an older msb answers `local database was updated by a newer msb or does not
# contain a valid migration prefix`, AND leaves a wedging journal behind (see
# msb_stale_downgrade_journal). It mutates sandbox state, so it is consent-gated
# and never implied by --yes alone being absent.
#
# Prefer moving FORWARD (see update_msb_to_fixed): it needs no rollback at all.
# This path is for a host that cannot, or chose not to, move forward.
recover_migrated_catalog() {
  blocked_msb="$1"
  blocked_version="$2"

  # Refuse to drive the rollback with a binary that cannot perform it. Only the
  # binary whose own migration metadata covers the applied set can build the
  # plan, and an attempt by an older one wedges the install rather than failing
  # cleanly. This guard is the reason that wedge is unreachable through acq.
  if msb_version_blocked "$blocked_version" \
     || version_ge "$blocked_version" "$MSB_BLOCKED_VERSION_MIN"; then
    : # this binary is from the line that applied the migrations; it can roll back
  else
    warn "  Refusing to run 'msb self downgrade' with msb $blocked_version: only the newer"
    warn "  msb that applied these migrations can roll them back, and an attempt by"
    warn "  an older one leaves an interrupted-downgrade record that blocks every"
    warn "  msb command afterwards."
    info "  Get the msb that migrated this catalog, run the downgrade with IT, then"
    info "  re-run this installer. A keg-only formula gets you that exact version"
    info "  without disturbing your current msb:"
    info "    brew install ${MSB_BREW_VERSIONED_PREFIX}<version>"
    info "    \"\$(brew --prefix microsandbox-acq@<version>)/bin/msb\" self downgrade $MSB_PINNED_VERSION"
    return 1
  fi

  step "Existing sandbox state was migrated by msb $blocked_version"
  warn "  msb $blocked_version already upgraded the local sandbox catalog in"
  warn "  $MSB_HOME_DIR. A supported msb cannot read it, so installing one now"
  warn "  would leave you with 'database schema is newer than this msb binary'."
  info "  'msb self downgrade $MSB_PINNED_VERSION' rolls that catalog back. It is run by the"
  info "  currently-installed msb $blocked_version (which owns the rollback steps), takes a"
  info "  database backup first, and reports exactly what it will change before"
  info "  doing it. It alters sandbox state, so it needs your approval."

  if ! confirm "  Run 'msb self downgrade $MSB_PINNED_VERSION' now?"; then
    warn "  Skipping catalog rollback. acq will keep refusing msb $blocked_version, and a"
    warn "  supported msb will not be able to read this catalog. To do it yourself:"
    info  "    msb self downgrade $MSB_PINNED_VERSION"
    return 1
  fi

  # Interactive on purpose: msb prints the plan (including any user-data
  # warnings) and prompts. Do not pass --yes; the user is approving msb's plan,
  # not just our question. stdin is wired to the terminal because a piped
  # `curl | sh` leaves fd 0 pointing at the script.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s self downgrade %s\n' "$blocked_msb" "$MSB_PINNED_VERSION"
    return 0
  fi

  if [ -t 0 ]; then
    "$blocked_msb" self downgrade "$MSB_PINNED_VERSION"
  elif [ -e /dev/tty ]; then
    "$blocked_msb" self downgrade "$MSB_PINNED_VERSION" </dev/tty
  else
    warn "  No terminal is available to confirm msb's own downgrade prompt."
    info  "  Run this yourself, then re-run this installer:"
    info  "    msb self downgrade $MSB_PINNED_VERSION"
    return 1
  fi || {
    warn "  'msb self downgrade $MSB_PINNED_VERSION' did not complete. msb's message above is"
    warn "  authoritative — it refuses rather than discarding data it cannot roll"
    warn "  back (grouped or duplicate snapshots are the usual cause). Resolve"
    warn "  what it reports, or move forward to msb $MSB_FIXED_VERSION instead, then re-run"
    warn "  this installer."
    return 1
  }

  ok "  Sandbox catalog rolled back for msb $MSB_PINNED_VERSION."
}

# Move a blocked msb FORWARD to the fixed line instead of rolling it back.
#
# This is the preferred recovery. The migration sets are additive — every
# migration an earlier 0.7.x applied is also known to the fixed line — so the
# fixed binary opens an already-migrated catalog directly. No rollback plan, no
# database backup dance, no `affects_user_data` step, and none of the refusals a
# downgrade can hit (grouped or duplicate snapshots).
#
# `msb self update` is the right tool here precisely because it targets the newest
# release: during this window the newest release IS the fixed one. That coupling
# is why this is checked, not assumed — if upstream ships something newer that we
# have not cleared, the version check afterwards catches it.
update_msb_to_fixed() {
  blocked_msb="$1"
  blocked_version="$2"

  step "msb $blocked_version can be fixed by moving forward, not back"
  info "  msb $MSB_FIXED_VERSION carries the upstream cross-version compatibility fix, and it"
  info "  reads the catalog msb $blocked_version already migrated — the migration sets are"
  info "  additive, so nothing has to be rolled back and no sandbox state is"
  info "  rewritten. This is safer than downgrading to msb $MSB_PINNED_VERSION, which has to"
  info "  revert migrations and can refuse outright if you have grouped snapshots."

  if ! confirm "  Run 'msb self update' to move to msb $MSB_FIXED_VERSION now?"; then
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s self update\n' "$blocked_msb"
    return 0
  fi

  "$blocked_msb" self update </dev/null || {
    warn "  'msb self update' did not complete; msb's message above is authoritative."
    return 1
  }

  # Trust nothing: `self update` targets whatever is newest, so confirm we landed
  # on a version this installer actually accepts before calling it a success.
  hash -r 2>/dev/null || true
  updated="$(command -v msb 2>/dev/null || true)"
  updated_version=""
  [ -n "$updated" ] && updated_version=$(msb_version_of "$updated")
  if [ -z "$updated_version" ] || msb_version_blocked "$updated_version" \
     || ! version_ge "$updated_version" "$MSB_MIN_VERSION"; then
    warn "  After 'msb self update' the active msb is ${updated_version:-unreadable}, which acq"
    warn "  does not accept. Falling back to the pinned msb $MSB_PINNED_VERSION path."
    return 1
  fi

  ok "  msb is now $updated_version ($updated)."
}

# Remove upstream's always-latest brew formula when it is what is being replaced.
# Our pinned formula owns the same `bin/msb`, so Homebrew refuses to link both.
remove_upstream_brew_msb() {
  prefix=$(msb_upstream_brew_prefix)
  [ -n "$prefix" ] || return 0

  step "Homebrew's $MSB_BREW_UPSTREAM_FORMULA is installed"
  warn "  That formula always tracks the newest msb release, so it cannot hold a"
  warn "  supported version, and it owns the same 'msb' command as the pinned"
  warn "  formula — Homebrew will not link both."
  if ! confirm "  Run 'brew uninstall $MSB_BREW_UPSTREAM_FORMULA' now?"; then
    warn "  Leaving it installed. Remove it yourself before installing the pinned"
    warn "  formula, or the two will collide:"
    info  "    brew uninstall $MSB_BREW_UPSTREAM_FORMULA"
    return 1
  fi
  run brew uninstall "$MSB_BREW_UPSTREAM_FORMULA" \
    || run brew uninstall microsandbox \
    || { warn "  'brew uninstall' failed; remove it manually and re-run."; return 1; }
}

# Bring the active msb to a version acq accepts.
#
# Returns 0 when the active msb is already acceptable (the forward-update path
# succeeded and nothing further is needed) via MSB_ALREADY_SUPPORTED=1, or when
# the pinned version was installed. Order matters throughout: a catalog rollback
# needs the binary that performed the migration to still be installed, so nothing
# may be uninstalled before that step.
replace_active_msb() {
  active="$1"
  active_version="$2"
  MSB_ALREADY_SUPPORTED=0

  # A wedged downgrade journal blocks every msb command, so clear it before any
  # probe that shells out to msb — otherwise msb_catalog_ahead misreads the
  # recovery-required error as an unrelated failure.
  journal=$(msb_stale_downgrade_journal)
  if [ -n "$journal" ]; then
    clear_stale_downgrade_journal "$journal" || return 1
  fi

  if [ -n "$active_version" ] && msb_version_blocked "$active_version" \
     && msb_catalog_ahead "$active"; then
    # Forward first: it rewrites no state and cannot be refused by the snapshot
    # checks a rollback can hit. Only fall back to the rollback if the user
    # declines or the update does not land on an accepted version.
    if update_msb_to_fixed "$active" "$active_version"; then
      MSB_ALREADY_SUPPORTED=1
      return 0
    fi
    recover_migrated_catalog "$active" "$active_version" || return 1
  fi
  remove_upstream_brew_msb || return 1
  install_msb_pinned
}

verify_active_msb_pinned() {
  # A brew install or a fresh symlink may not be visible to a shell that cached
  # PATH lookups. Clear the cache so the check sees what was just installed.
  hash -r 2>/dev/null || true

  active="$(command -v msb 2>/dev/null || true)"
  if [ -z "$active" ]; then
    die "msb $MSB_PINNED_VERSION was installed, but no msb is active on PATH.
Add $BIN_DIR to PATH, open a new terminal, and re-run this installer."
  fi
  ver=$(msb_version_of "$active")
  if [ -z "$ver" ]; then
    die "active msb at $active did not report a parseable version. Check that PATH
points at the intended msb binary, then re-run this installer."
  fi
  if ! version_ge "$ver" "$MSB_MIN_VERSION"; then
    die "active msb is still too old: $ver at $active.
Use msb $MSB_PINNED_VERSION, or upgrade to msb $MSB_FIXED_VERSION or newer."
  fi
  if msb_version_blocked "$ver"; then
    die "active msb is still blocked version $ver at $active.
msb $MSB_PINNED_VERSION was installed, but another msb is shadowing it on PATH. Remove
the stale copy (if it is Homebrew's: brew uninstall $MSB_BREW_UPSTREAM_FORMULA) or put
$BIN_DIR earlier in PATH, then re-run this installer."
  fi
  ok "  Active msb is $ver ($active)."
}

# ---------------------------------------------------------------------------
# Run the selected method
# ---------------------------------------------------------------------------

case "$METHOD" in
  brew)  install_via_brew ;;
  npm)   install_via_npm ;;
  clone) install_via_clone ;;
esac

# ---------------------------------------------------------------------------
# Optionally install the msb sandbox runtime
# ---------------------------------------------------------------------------

if [ "$INSTALL_MSB" -eq 1 ]; then
  msb_report_candidates
  active_msb="$(command -v msb 2>/dev/null || true)"
  active_msb_version=""
  [ -n "$active_msb" ] && active_msb_version=$(msb_version_of "$active_msb")

  if [ -n "$active_msb" ] && [ -z "$active_msb_version" ]; then
    step "The active msb version could not be determined"
    warn "  Found msb at $active_msb, but its version output was not parseable."
    warn "  Install msb $MSB_PINNED_VERSION so acq can verify a supported version."
    if confirm "  Install/downgrade msb to $MSB_PINNED_VERSION now?"; then
      if replace_active_msb "$active_msb" "$active_msb_version"; then
        verify_active_msb_pinned
      else
        INSTALL_MSB=0
      fi
    else
      INSTALL_MSB=0
    fi
  elif [ -n "$active_msb" ] && ! version_ge "$active_msb_version" "$MSB_MIN_VERSION"; then
    step "The active msb version is too old"
    warn "  Found msb $active_msb_version at $active_msb. acq requires msb >= $MSB_MIN_VERSION."
    warn "  Install msb $MSB_PINNED_VERSION instead."
    if confirm "  Install/downgrade msb to $MSB_PINNED_VERSION now?"; then
      if replace_active_msb "$active_msb" "$active_msb_version"; then
        verify_active_msb_pinned
      else
        INSTALL_MSB=0
      fi
    else
      INSTALL_MSB=0
    fi
  elif [ -n "$active_msb" ] && msb_version_blocked "$active_msb_version"; then
    step "The active msb version is blocked"
    warn "  Found msb $active_msb_version at $active_msb."
    warn "  acq refuses msb $MSB_BLOCKED_VERSION_MIN-$MSB_BLOCKED_VERSION_MAX because those releases"
    warn "  migrate 0.6.x sandbox state one-way."
    info "  Two ways out: move FORWARD to msb $MSB_FIXED_VERSION (preferred — it reads the"
    info "  already-migrated catalog as-is), or roll back to msb $MSB_PINNED_VERSION. You will be"
    info "  offered the forward path first, and asked before anything changes."
    if confirm "  Fix the active msb now?"; then
      if replace_active_msb "$active_msb" "$active_msb_version"; then
        verify_active_msb_pinned
      else
        INSTALL_MSB=0
      fi
    else
      INSTALL_MSB=0
    fi
  elif [ -n "$active_msb" ]; then
    ok "  msb is already installed ($active_msb${active_msb_version:+, v$active_msb_version})."
  else
    step "The msb sandbox runtime is not installed"
    info "  acq runs your agent inside an msb microVM. It is a separate, open-source tool."
    if confirm "  Install msb $MSB_PINNED_VERSION now?"; then
      if install_msb_pinned; then
        verify_active_msb_pinned
      else
        INSTALL_MSB=0
      fi
    else
      INSTALL_MSB=0
    fi
  fi

  if [ "$INSTALL_MSB" -eq 0 ]; then
    warn "  Skipping msb. Install a supported version later with:"
    if command -v brew >/dev/null 2>&1; then
      info  "    brew install $MSB_BREW_FORMULA"
    fi
    info  "    ./scripts/verify-msb-pin --install   # verified pinned release bundle"
    info  "  Do NOT use 'curl -fsSL https://install.microsandbox.dev | sh' to install a"
    info  "  specific version: it always resolves to the newest release, and every"
    info  "  release publishes a byte-identical copy, so a versioned asset URL is not"
    info  "  a pin. Use msb $MSB_PINNED_VERSION, or msb $MSB_FIXED_VERSION or newer."
    info  "  ('msb self update' targets the newest release, which right now IS msb"
    info  "  $MSB_FIXED_VERSION — that is the one supported use of it during this window.)"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

step "Done"
if [ "$NEED_PATH_HELP" -eq 1 ]; then
  if [ "$METHOD" = "clone" ]; then
    info "Once $BIN_DIR is on your PATH, try:  ${B}acq version${R}"
    info "Or run it directly right now:        ${B}$BIN_DIR/acq version${R}"
  elif [ "$METHOD" = "npm" ]; then
    info "Once npm's global bin dir is on your PATH, try:  ${B}acq version${R}"
  else
    info "Once Homebrew's bin dir is on your PATH, try:  ${B}acq version${R}"
  fi
else
  info "Try it now:  ${B}acq version${R}"
fi
info "Next, start a sandbox:  ${B}acq run opencode /path/to/your/project${R}"
