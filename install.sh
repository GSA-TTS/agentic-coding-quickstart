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
# release commit so the default clone path is content-addressed.
DEFAULT_RELEASE_VERSION="3.0.0" # x-release-please-version
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

# In dry-run, show what would run; otherwise run it.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
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
  --sha <commit>       Pin to a full 40-char commit SHA and verify HEAD matches
                       it after checkout (content-addressed integrity check).
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
# integrity-verified the same way). Reject anything else up front.
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
# their own packages). A release asset's baked SHA is used when clone is selected,
# but does not by itself override package-manager auto-selection.
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

  # --- Integrity check: HEAD must equal the pinned SHA (content-addressed) ---
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
  if command -v msb >/dev/null 2>&1; then
    ok "  msb is already installed ($(command -v msb))."
  else
    step "The msb sandbox runtime is not installed"
    info "  acq runs your agent inside an msb microVM. It is a separate, open-source tool."
    if confirm "  Install msb now?"; then
      if command -v brew >/dev/null 2>&1; then
        info "  Installing via Homebrew..."
        run brew install superradcompany/tap/microsandbox
      else
        info "  Homebrew not found; using the microsandbox install script."
        info "  (This downloads and runs https://install.microsandbox.dev.)"
        if [ "$DRY_RUN" -eq 1 ]; then
          printf '  [dry-run] curl -fsSL https://install.microsandbox.dev | sh\n'
        else
          curl -fsSL https://install.microsandbox.dev | sh
        fi
      fi
    else
      warn "  Skipping msb. Install it later with one of:"
      info  "    brew install superradcompany/tap/microsandbox"
      info  "    curl -fsSL https://install.microsandbox.dev | sh"
    fi
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
