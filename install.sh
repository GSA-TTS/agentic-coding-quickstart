#!/bin/sh
# install.sh — user-scoped installer for the acq v1 Python replacement (ADR-0042m).
#
# Downloads a checksum-verified, per-platform release archive — the enumerated
# offline asset set (readable source + bundled managed CPython runtime + exact-hash
# wheelhouse + launcher scripts + SHA256SUMS + provenance manifest) — extracts it
# under your home directory, and links a launcher onto a user-writable PATH dir.
#
# Guarantees (ADR-0042m, ADR-0038m):
#   * dry-run       --dry-run            prints actions, makes no writes, no network
#   * consent       PATH edits are consent-gated (default NO; --yes skips the prompt)
#   * checksum      the archive is verified against SHA256SUMS; a mismatch fails
#                   closed before anything is written
#   * user-scope    installs only under $HOME; never elevates (no sudo)
#   * update        re-running against a pinned, checksum-verified release is the
#                   only update path — there is no `acq update` command and ordinary
#                   operation never reaches the network for acq's own assets
#
# Exit codes mirror acq (ADR-0038m §1): 0 success, 2 usage error, 1 failure.
#
# Usage:
#   curl -fsSL <release>/install.sh | sh            # interactive (prompts for PATH)
#   sh install.sh --dry-run                         # preview, no changes
#   sh install.sh --source DIR --install-dir DIR --yes   # offline / non-interactive
#
#   sh install.sh [--install-dir DIR] [--bin-dir DIR] [--source URL|DIR]
#                 [--ref VER] [--dry-run] [--yes] [--non-interactive]
#                 [--help] [--version|-V]

set -eu
# M1 channel dispatcher. The stable body is retained inline so curl|sh
# never depends on an adjacent helper or a second downloaded identity.
stable_bash_install() (
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
#                 [--non-interactive]
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
DEFAULT_RELEASE_VERSION="4.2.1" # x-release-please-version
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
# line cannot read. Install a pinned latest-known-good release when acq needs to
# install or repair msb, and keep refusing that historical blocked range. See
# ADR-0032.
MSB_MIN_VERSION="0.6.9"
MSB_PINNED_VERSION="0.7.7"
MSB_ROLLBACK_VERSION="0.6.18"
MSB_BLOCKED_VERSION_MIN="0.7.0"
MSB_BLOCKED_VERSION_MAX="0.7.2"

# First release carrying the upstream cross-version compatibility fix. Moving
# FORWARD to this is strictly safer than rolling back to the pin: the migration
# sets are additive, so this line reads a catalog an earlier 0.7.x already
# migrated with no rollback, no data-affecting step, and no snapshot refusal.
# Prefer it whenever the host can reach it; the install pin is newer, but this
# remains the first fixed threshold for policy checks and recovery guidance.
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
NON_INTERACTIVE="${ACQ_INSTALL_NON_INTERACTIVE:-0}"
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
  --non-interactive    Decline consent-gated actions without reading /dev/tty.
  --help               Show this help.

Environment overrides:
  ACQ_INSTALL_METHOD, ACQ_INSTALL_REF, ACQ_INSTALL_SHA, ACQ_INSTALL_REPO_URL,
  ACQ_INSTALL_CLONE_DIR, ACQ_INSTALL_BIN_DIR, ACQ_INSTALL_NON_INTERACTIVE

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
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$METHOD" in
  auto|brew|npm|clone) : ;;
  *) die "invalid --method '$METHOD' (expected: brew, npm, or clone)" ;;
esac

case "$NON_INTERACTIVE" in
  0|1) : ;;
  *) die "ACQ_INSTALL_NON_INTERACTIVE must be 0 or 1" ;;
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
  [ "$NON_INTERACTIVE" = 1 ] && return 1
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

msb_version_final() {
  case "$1" in
    *[-+]* ) return 1 ;;
    * ) return 0 ;;
  esac
}

msb_version_of() {
  _raw=$("$1" --version 2>/dev/null) || return 0
  printf '%s\n' "$_raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([+-][^[:space:]]*)?' | head -n1 || true
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
  # Homebrew (since 6.0.0) requires explicit trust for non-official taps before
  # it will load a formula. Installing a FULLY-QUALIFIED name (what $BREW_FORMULA
  # is) auto-trusts ONLY that one formula — not the whole tap, and not any other
  # formula in the same tap, even one it depends on. acq.rb's `depends_on
  # "GSA-TTS/tap/microsandbox-acq"` is exactly that: a second formula from the
  # SAME tap that Homebrew does not auto-trust just because `acq` itself was.
  # Without this, `brew install "$BREW_FORMULA"` fails here with:
  #   Error: Refusing to load formula gsa-tts/tap/microsandbox-acq from
  #   untrusted tap gsa-tts/tap.
  # Trust the known dependency explicitly, by name, rather than the whole tap
  # (narrower: future formulae added to the tap stay untrusted until a user
  # opts in to them directly). `brew trust --formula` is safe to call before
  # the tap is cloned — verified live: it records the trust decision without
  # tapping or installing anything, and the subsequent `brew install` tap-clones
  # as normal and then finds the dependency already trusted. Routed through
  # `run` (not a bare call) so --dry-run shows it rather than silently skipping
  # it, consistent with the `brew install` call below.
  run brew trust --formula "GSA-TTS/tap/microsandbox-acq"
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
  # --yes and --non-interactive never inspect the controlling terminal. In the
  # remaining interactive path, probe /dev/tty so piped invocations can still
  # guide a human without treating the script stream as an answer.
  can_reach_tty=0
  if [ "$ASSUME_YES" -ne 1 ] && [ "$NON_INTERACTIVE" != 1 ]; then
    if [ -t 0 ] || ( : >/dev/tty ) 2>/dev/null; then
      can_reach_tty=1
    fi
  fi
  if [ "$ASSUME_YES" -eq 1 ] || [ "$can_reach_tty" -eq 0 ]; then
    die "git is required but the macOS Command Line Tools are not installed.
This installer can set them up interactively, but it is running non-interactively
(--yes, --non-interactive, or no terminal), so it will not launch the GUI installer
and wait. Install
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

install_provider_validator_wheelhouse() {
  case "$METHOD" in
    brew) return 0 ;;
    clone) target="$CLONE_DIR/scripts/provider-input-validator-wheelhouse" ;;
    npm) return 0 ;; # npm runs its package-local postinstall hook.
  esac
  case "$REF" in
    v[0-9]*.[0-9]*.[0-9]*) : ;;
    *) warn "  provider validator wheelhouse is only published for release tags; this development ref will fail closed for provider-backed creates."; return 0 ;;
  esac
  [ "$DRY_RUN" -eq 1 ] && { printf '  [dry-run] install verified provider validator wheelhouse into %s\n' "$target"; return 0; }
  "$CLONE_DIR/scripts/install-provider-input-wheelhouse" --target "$target" --version "${REF#v}" \
    || die "could not install the verified offline provider validator wheelhouse"
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
  active="$(command -v msb 2>/dev/null || true)"
  candidates=$(msb_unique_candidates)
  [ -n "$candidates" ] || return 0

  # Count first: with one candidate there is no PATH-order ambiguity to report,
  # and probing `--version` on it would be wasted work.
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    count=$((count + 1))
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
# and msb then refuses catalog-opening commands from every version until that
# operation reaches `phase: complete`:
#
#   error: self_downgrade_recovery_required: resume the active downgrade
#   recorded at .../db/self-downgrade/<id>/journal.json
#
# The refusal is unconditional for commands that open local backend state: msb
# checks for it before it opens the database. When the journal records a
# transition that cannot complete — which is exactly what a too-old binary leaves
# behind, because it stages a target it then cannot roll the database back to —
# the demand is unsatisfiable and the install is wedged. Verified against msb
# 0.6.18/0.7.2/0.7.3: catalog-opening retries with the journal's own target, with
# a different target, and from each of the three binaries all fail identically,
# and `self downgrade` exposes no abort or clear flag. Non-catalog probes such as
# `msb --version` can still work, but they cannot clear the journal or read
# sandbox state. The only exit is removing the journal directory, after which a
# correctly-ordered downgrade succeeds normally.
msb_stale_downgrade_journal() {
  for journal in "$MSB_HOME_DIR"/db/self-downgrade/*/journal.json; do
    [ -f "$journal" ] || continue
    printf '%s\n' "$journal"
    return 0
  done
}

# Clear a wedged downgrade journal, with consent.
#
# Upstream's migration guide says: "Do not delete the catalog or edit migration
# history to bypass the refusal." That instruction is correct, and this does not
# violate it. The paths look similar, so the distinction is worth being explicit
# about:
#
#   NOT touched: the catalog database ($MSB_HOME/db/*.db), the applied-migrations
#                history inside it, the retained downgrade backups, and every
#                sandbox, snapshot, and image.
#   Removed:     $MSB_HOME/db/self-downgrade/<id>/ — the journal of ONE operation
#                that never finished.
#
# The journal is a lock, not a record of schema state: `phase != complete` means
# "an operation is in flight", and msb's own downgrade path RETIRES the journal on
# success rather than keeping it. Removing it abandons an operation that never
# began mutating the database, so the catalog left behind is bit-identical and no
# schema check is bypassed. What upstream is warning against is the other thing —
# deleting the database, or editing the applied-migrations table, to force an
# older binary to accept a newer catalog. acq never does that.
clear_stale_downgrade_journal() {
  journal="$1"
  opdir=$(dirname "$journal")

  step "An interrupted msb downgrade is blocking msb catalog access"
  warn "  msb records an in-progress 'self downgrade' here:"
  info "    $journal"
  warn "  Until that operation finishes, msb refuses catalog-opening commands —"
  warn "  including read-only state commands, and including from a different msb"
  warn "  version. If the recorded transition cannot complete (a too-old msb"
  warn "  leaves exactly that behind), there is no way to resume it and no flag"
  warn "  to abandon it."
  info "  Removing that operation directory clears the block. It removes only the"
  info "  record of that unfinished operation — NOT your catalog database, NOT its"
  info "  migration history, NOT your retained downgrade backups, and NOT any"
  info "  sandbox, snapshot, or image. See ADR-0032 for why that is the safe cut."

  if ! confirm "  Remove $opdir now?"; then
    warn "  Leaving it in place. msb will keep refusing catalog access. To do it"
    warn "  yourself:"
    info  "    rm -rf \"$opdir\""
    return 1
  fi

  run rm -rf "$opdir" || { warn "  Could not remove $opdir."; return 1; }
  ok "  Cleared the interrupted downgrade; msb catalog access should work again."
}

# Roll a 0.7.x-migrated catalog back so a supported msb can read it again.
#
# This MUST be driven by the currently-installed 0.7.x binary: `msb self
# downgrade` builds its rollback plan from the running binary's own migration
# metadata, takes a database backup, and reverts the migrations the older line
# does not know. Upstream states the same requirement — run the downgrade from the
# newer CLI BEFORE replacing it, because only that CLI carries the rollback steps.
# Installing the older binary first strands the catalog instead — an older msb
# answers `local database was updated by a newer msb or does not contain a valid
# migration prefix`, AND leaves a wedging journal behind (see
# msb_stale_downgrade_journal). It mutates sandbox state, so it is consent-gated
# and never implied by --yes alone being absent.
#
# The rollback can also be refused outright for reasons this installer cannot fix:
# snapshot groups (which every 0.7 capture creates by default) block a downgrade
# to a release without group support, even when empty. That is a second reason to
# prefer moving FORWARD (see update_msb_to_fixed): it needs no rollback at all.
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
    warn "  an older one leaves an interrupted-downgrade record that blocks later"
    warn "  catalog-opening msb commands afterwards."
    info "  Get the msb that migrated this catalog, run the downgrade with IT, then"
    info "  re-run this installer. A keg-only formula gets you that exact version"
    info "  without disturbing your current msb:"
    info "    brew install ${MSB_BREW_VERSIONED_PREFIX}<version>"
    info "    \"\$(brew --prefix microsandbox-acq@<version>)/bin/msb\" self downgrade $MSB_ROLLBACK_VERSION"
    return 1
  fi

  step "Existing sandbox state was migrated by msb $blocked_version"
  warn "  msb $blocked_version already upgraded the local sandbox catalog in"
  warn "  $MSB_HOME_DIR. A supported msb cannot read it, so installing one now"
  warn "  would leave you with 'database schema is newer than this msb binary'."
  info "  'msb self downgrade $MSB_ROLLBACK_VERSION' rolls that catalog back. It is run by the"
  info "  currently-installed msb $blocked_version (which owns the rollback steps), takes a"
  info "  database backup first, and reports exactly what it will change before"
  info "  doing it. It alters sandbox state, so it needs your approval."

  if ! confirm "  Run 'msb self downgrade $MSB_ROLLBACK_VERSION' now?"; then
    warn "  Skipping catalog rollback. acq will keep refusing msb $blocked_version, and a"
    warn "  supported msb will not be able to read this catalog. To do it yourself:"
    info  "    msb self downgrade $MSB_ROLLBACK_VERSION"
    return 1
  fi

  # --yes authorizes this installer's ordinary consent gates, but never msb's
  # separate rollback-plan prompt. Refuse rather than borrowing /dev/tty in a
  # non-interactive invocation; the human must run this state-changing command.
  if [ "$ASSUME_YES" -eq 1 ] || [ "$NON_INTERACTIVE" = 1 ]; then
    warn "  This catalog rollback needs interactive review of msb's own plan."
    info "  Run this yourself, then re-run this installer:"
    info "    msb self downgrade $MSB_ROLLBACK_VERSION"
    return 1
  fi

  # Interactive on purpose: msb prints the plan (including any user-data
  # warnings) and prompts. Do not pass --yes; the user is approving msb's plan,
  # not just our question. stdin is wired to the terminal because a piped
  # `curl | sh` leaves fd 0 pointing at the script. The --yes and
  # --non-interactive paths returned above, so neither borrows /dev/tty.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s self downgrade %s\n' "$blocked_msb" "$MSB_ROLLBACK_VERSION"
    return 0
  fi

  if [ -t 0 ]; then
    "$blocked_msb" self downgrade "$MSB_ROLLBACK_VERSION"
  elif [ -e /dev/tty ]; then
    "$blocked_msb" self downgrade "$MSB_ROLLBACK_VERSION" </dev/tty
  else
    warn "  No terminal is available to confirm msb's own downgrade prompt."
    info  "  Run this yourself, then re-run this installer:"
    info  "    msb self downgrade $MSB_ROLLBACK_VERSION"
    return 1
  fi || {
    warn "  'msb self downgrade $MSB_ROLLBACK_VERSION' did not complete. msb's message above is"
    warn "  authoritative — it refuses rather than discarding data it cannot roll"
    warn "  back (grouped or duplicate snapshots are the usual cause). Resolve"
    warn "  what it reports, or move forward to msb $MSB_FIXED_VERSION instead, then re-run"
    warn "  this installer."
    return 1
  }

  ok "  Sandbox catalog rolled back for msb $MSB_ROLLBACK_VERSION."
}

# Move a blocked msb FORWARD to the fixed line instead of rolling it back.
#
# This is the preferred recovery, and upstream agrees: its migration guide says to
# upgrade to the fixed release and retry FIRST, because a blocked-version database
# can upgrade directly with no downgrade to 0.6 needed.
#
# The migration sets are additive — every migration an earlier 0.7.x applied is
# also known to the fixed line — so the fixed binary opens an already-migrated
# catalog directly. No rollback plan, no database backup dance, no
# `affects_user_data` step, and none of the refusals a downgrade can hit (grouped
# or duplicate snapshots).
#
# `msb self update` is still the right tool here when recovering from the blocked
# range because it targets a release on or after the fixed threshold. The result is
# checked, not assumed, so any future unsupported release still fails closed.
update_msb_to_fixed() {
  blocked_msb="$1"
  blocked_version="$2"

  step "msb $blocked_version can be fixed by moving forward, not back"
  info "  msb $MSB_FIXED_VERSION carries the upstream cross-version compatibility fix, and it"
  info "  reads the catalog msb $blocked_version already migrated — the migration sets are"
  info "  additive, so nothing has to be rolled back and no sandbox state is"
  info "  rewritten. This is safer than downgrading to msb $MSB_ROLLBACK_VERSION, which has to"
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
  if [ -z "$updated_version" ] || ! msb_version_final "$updated_version" \
     || msb_version_blocked "$updated_version" \
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
# Returns 0 when the active msb is acceptable — either the forward update landed
# on the fixed line, or the pinned version was installed. Order matters
# throughout: a catalog rollback needs the binary that performed the migration to
# still be installed, so nothing may be uninstalled before that step.
replace_active_msb() {
  active="$1"
  active_version="$2"

  # A wedged downgrade journal blocks catalog-opening msb commands, so clear it
  # before any state probe — otherwise msb_catalog_ahead misreads the
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
    #
    # update_msb_to_fixed has already re-checked the resulting version, so a
    # success here needs nothing further installed.
    update_msb_to_fixed "$active" "$active_version" && return 0
    recover_migrated_catalog "$active" "$active_version" || return 1
  fi
  remove_upstream_brew_msb || return 1
  install_msb_pinned
}

# Confirm the active msb is one acq accepts, after any install or repair. Fails
# closed via die(): an msb this installer cannot vouch for is worse than none,
# because acq would refuse it later with a less obvious message.
#
# Deliberately does not name a single expected version: this runs after the
# forward-update path (which lands on the fixed line) as well as after a pinned
# install, and claiming "$MSB_PINNED_VERSION was installed" would be wrong in the
# first case.
verify_active_msb_supported() {
  # Nothing was installed in a dry run, so there is nothing to verify and the
  # absence of an msb is expected rather than a failure. Without this, a plain
  # `--dry-run --yes` on a host with no msb reports success for every step and
  # then dies at the last one — the loudest possible false alarm, on the exact
  # command a cautious user runs first. (install.ps1's Assert-MsbSupported has
  # always guarded this; the shell side did not.)
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] verify the active msb is a version acq accepts\n'
    return 0
  fi

  # A brew install or a fresh symlink may not be visible to a shell that cached
  # PATH lookups. Clear the cache so the check sees what was just installed.
  hash -r 2>/dev/null || true

  active="$(command -v msb 2>/dev/null || true)"
  if [ -z "$active" ]; then
    die "msb was installed, but no msb is active on PATH.
Add $BIN_DIR to PATH, open a new terminal, and re-run this installer."
  fi
  ver=$(msb_version_of "$active")
  if [ -z "$ver" ] || ! msb_version_final "$ver"; then
    die "active msb at $active did not report a supported final version. Check that PATH
points at an msb final release, then re-run this installer."
  fi
  if ! version_ge "$ver" "$MSB_MIN_VERSION"; then
    die "active msb is still too old: $ver at $active.
Use msb $MSB_PINNED_VERSION, or upgrade to msb $MSB_FIXED_VERSION or newer."
  fi
  if msb_version_blocked "$ver"; then
    die "active msb is still blocked version $ver at $active.
A supported msb was installed, but another msb is shadowing it on PATH. Remove
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

install_provider_validator_wheelhouse

# ---------------------------------------------------------------------------
# Optionally install the msb sandbox runtime
# ---------------------------------------------------------------------------

if [ "$INSTALL_MSB" -eq 1 ]; then
  msb_report_candidates
  active_msb="$(command -v msb 2>/dev/null || true)"
  active_msb_version=""
  [ -n "$active_msb" ] && active_msb_version=$(msb_version_of "$active_msb")

  if [ -n "$active_msb" ] && { [ -z "$active_msb_version" ] || ! msb_version_final "$active_msb_version"; }; then
    step "The active msb version is not a supported final release"
    warn "  Found msb at $active_msb, but its version output was not a supported final release."
    warn "  Install msb $MSB_PINNED_VERSION so acq can verify a supported version."
    if confirm "  Install/downgrade msb to $MSB_PINNED_VERSION now?"; then
      if replace_active_msb "$active_msb" "$active_msb_version"; then
        verify_active_msb_supported
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
        verify_active_msb_supported
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
    info "  already-migrated catalog as-is), or roll back to msb $MSB_ROLLBACK_VERSION. You will be"
    info "  offered the forward path first, and asked before anything changes."
    if confirm "  Fix the active msb now?"; then
      if replace_active_msb "$active_msb" "$active_msb_version"; then
        verify_active_msb_supported
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
        verify_active_msb_supported
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
    info  "  ('msb self update' targets the newest release; acq re-checks that it lands"
    info  "  on msb $MSB_FIXED_VERSION or newer before accepting it.)"
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

)
acq_channel="${ACQ_INSTALL_CHANNEL-bash}"
acq_scan_channel() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --channel) [ "$#" -ge 2 ] || { echo "--channel needs a value" >&2; exit 2; }; acq_channel="$2"; shift 2 ;;
      --channel=*) acq_channel="${1#--channel=}"; shift ;;
      *) shift ;;
    esac
  done
}
acq_scan_channel "$@"
case "$acq_channel" in bash|python) ;; *) echo "unknown channel '$acq_channel'" >&2; exit 2 ;; esac
acq_stable_args() {
  if [ "$#" -eq 0 ]; then stable_bash_install; return; fi
  case "$1" in
    --channel) shift 2; acq_stable_args "$@" ;;
    --channel=*) shift; acq_stable_args "$@" ;;
    *) acq_stable_collect "$@" ;;
  esac
}
# Recursion retains exact positional arguments without eval or string reparse.
acq_stable_collect() {
  acq_stable_filter "$#" "$@"
}
acq_stable_filter() {
  acq_left="$1"; shift
  if [ "$acq_left" -eq 0 ]; then stable_bash_install "$@"; return; fi
  case "$1" in
    --channel) acq_left=$((acq_left - 2)); shift 2; acq_stable_filter "$acq_left" "$@" ;;
    --channel=*) acq_left=$((acq_left - 1)); shift; acq_stable_filter "$acq_left" "$@" ;;
    *) acq_arg="$1"; shift; acq_stable_filter "$((acq_left - 1))" "$@" "$acq_arg" ;;
  esac
}
if [ "$acq_channel" = bash ]; then acq_stable_args "$@"; exit $?; fi

# ---------------------------------------------------------------------------
# Defaults (overridable by flags / environment)
# ---------------------------------------------------------------------------

# release-please updates this version in release PRs. Release automation publishes
# an install.sh asset for each release; the version pins the release it installs.
DEFAULT_VERSION="0.1.0" # x-release-please-version

RELEASE_BASE_URL="https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download"
SHA256SUMS_NAME="SHA256SUMS"
PROVENANCE_NAME="provenance.json"

# User directories. Like acq itself (acq.backends/userdirs.sh, not sourced here:
# this script runs before acq is installed), XDG_DATA_HOME and HOME count only
# when they hold absolute paths, as the XDG Base Directory specification
# requires; a relative value would resolve against the current directory. A
# relative or unset HOME falls back to the account's home from the password
# database. With no absolute home the defaults stay empty and the run stops
# after option parsing, so --help and --version still work.
is_abs_path() {
  case "${1:-}" in /*) return 0 ;; *) return 1 ;; esac
}

account_home() {
  ah=""
  if command -v getent >/dev/null 2>&1; then
    ah_uid="$(id -u 2>/dev/null)" || return 1
    case "$ah_uid" in ''|*[!0-9]*) return 1 ;; esac
    ah="$(getent passwd "$ah_uid" 2>/dev/null | cut -d: -f6)" || ah=""
  else
    # No getent (macOS): ~NAME reads the password database, never HOME. Only a
    # plain identifier reaches eval.
    ah_user="$(id -un 2>/dev/null)" || return 1
    case "$ah_user" in [A-Za-z_]*) ;; *) return 1 ;; esac
    case "$ah_user" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    eval "ah=~$ah_user"
  fi
  is_abs_path "$ah" || return 1
  printf '%s\n' "$ah"
}

if is_abs_path "${HOME:-}"; then
  USER_HOME="$HOME"
else
  USER_HOME="$(account_home)" || USER_HOME=""
fi
if is_abs_path "${XDG_DATA_HOME:-}"; then
  DATA_HOME="$XDG_DATA_HOME"
else
  DATA_HOME="${USER_HOME:+$USER_HOME/.local/share}"
fi

VERSION="${ACQ_INSTALL_VERSION:-$DEFAULT_VERSION}"
SOURCE="${ACQ_INSTALL_SOURCE:-}"
INSTALL_DIR="${ACQ_INSTALL_DIR:-${DATA_HOME:+$DATA_HOME/acq}}"
INSTALL_DIR_FROM="${ACQ_INSTALL_DIR:+ACQ_INSTALL_DIR}"
BIN_DIR="${ACQ_INSTALL_BIN_DIR:-${USER_HOME:+$USER_HOME/.local/bin}}"
BIN_DIR_FROM="${ACQ_INSTALL_BIN_DIR:+ACQ_INSTALL_BIN_DIR}"
CHANNEL="${ACQ_INSTALL_CHANNEL-python}"
VERSION_GIVEN="${ACQ_INSTALL_VERSION+1}"
PREVIEW_REMOVE=0

DRY_RUN=0
ASSUME_YES=0
NEED_PATH_HELP=0
SHA256_PIN=""
SHA256_PIN_GIVEN=0
NO_PREREQ_CHECK=0
NON_INTERACTIVE="${ACQ_INSTALL_NON_INTERACTIVE:-0}"

# ---------------------------------------------------------------------------
# Output helpers (no color when not a TTY)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  B="$(printf '\033[1m')"; R="$(printf '\033[0m')"
  GRN="$(printf '\033[32m')"; RED="$(printf '\033[31m')"; YEL="$(printf '\033[33m')"
else
  B=""; R=""; GRN=""; RED=""; YEL=""
fi

info() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
warn() { printf '%s%s%s\n' "$YEL" "$*" "$R" >&2; }
ok()   { printf '%s%s%s\n' "$GRN" "$*" "$R"; }
die()  { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
# shown VALUE — VALUE with every non-printable byte replaced by '?', so a value
# echoed back in a message cannot carry control characters to the terminal.
shown() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' '?'; }
usage_err() { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; exit 2; }

# In dry-run, show what would run; otherwise run it. Child stdin is detached so a
# child never consumes the `curl | sh` script pipe (fd 0).
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@" </dev/null
  fi
}

usage() {
  cat <<'EOF'
install.sh — install acq (explicit Python preview)

It downloads the checksum-verified release archive for this host (the enumerated
offline asset set: readable source + bundled managed CPython runtime + wheelhouse
+ launchers), installs it separately, and links only `acq-python`.
Update by re-running this installer against a pinned release.

Options:
  --install-dir <dir>   Preview root (default: $XDG_DATA_HOME/acq-python-preview).
  --bin-dir <dir>       Where to link acq-python (default: ~/.local/bin).
  --source <url|dir>    Release source. A URL fetches SHA256SUMS, the provenance
                        manifest, and the archive; a local directory (the offline
                        asset set) is read in place.
  --ref <ver>           Required explicit X.Y.Z-rc.N preview pin.
  --channel <name>      bash (default, stable methods) or python (explicit preview).
  --remove-preview     Remove matching owned preview files; preserve modifications.
  --sha256 <digest>    Expected SHA-256 of SHA256SUMS (64 hex characters).
  --no-prereq-check     Skip the post-install sandbox prerequisite report.
  --dry-run             Print what would happen; make no changes, no network.
  --yes, -y             Assume "yes" to the PATH prompt (non-interactive/CI).
  --non-interactive     Decline consent-gated actions without reading /dev/tty.
  --help                Show this help.
  --version, -V         Show the installer version.

Environment overrides:
  ACQ_INSTALL_VERSION, ACQ_INSTALL_SOURCE, ACQ_INSTALL_DIR, ACQ_INSTALL_BIN_DIR,
  ACQ_INSTALL_CHANNEL, ACQ_INSTALL_NON_INTERACTIVE=1 (same as --non-interactive),
  ACQ_INSTALL_NO_ATTESTATION=1 (skip attestation)

The preview uses no sudo, and does not change PATH, shell profiles or backends.
Use the printed absolute acq-python command, or add its bin directory yourself.
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --install-dir) [ $# -ge 2 ] || usage_err "--install-dir needs a value"; INSTALL_DIR="$2"; INSTALL_DIR_FROM="--install-dir"; shift 2 ;;
    --install-dir=*) INSTALL_DIR="${1#--install-dir=}"; INSTALL_DIR_FROM="--install-dir"; shift ;;
    --bin-dir) [ $# -ge 2 ] || usage_err "--bin-dir needs a value"; BIN_DIR="$2"; BIN_DIR_FROM="--bin-dir"; shift 2 ;;
    --bin-dir=*) BIN_DIR="${1#--bin-dir=}"; BIN_DIR_FROM="--bin-dir"; shift ;;
    --source) [ $# -ge 2 ] || usage_err "--source needs a value"; SOURCE="$2"; shift 2 ;;
    --source=*) SOURCE="${1#--source=}"; shift ;;
    --ref) [ $# -ge 2 ] || usage_err "--ref needs a value"; VERSION="$2"; VERSION_GIVEN=1; shift 2 ;;
    --ref=*) VERSION="${1#--ref=}"; VERSION_GIVEN=1; shift ;;
    --channel) [ $# -ge 2 ] || usage_err "--channel needs a value"; CHANNEL="$2"; shift 2 ;;
    --channel=*) CHANNEL="${1#--channel=}"; shift ;;
    --sha256) [ $# -ge 2 ] || usage_err "--sha256 needs a value"; SHA256_PIN="$2"; SHA256_PIN_GIVEN=1; shift 2 ;;
    --sha256=*) SHA256_PIN="${1#--sha256=}"; SHA256_PIN_GIVEN=1; shift ;;
    --no-prereq-check) NO_PREREQ_CHECK=1; shift ;;
    --remove-preview) PREVIEW_REMOVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --version|-V) printf 'acq install.sh %s\n' "$VERSION"; exit 0 ;;
    *) usage_err "unknown option: $1 (try --help)" ;;
  esac
done

if [ "$SHA256_PIN_GIVEN" -eq 1 ]; then
  [ "${#SHA256_PIN}" -eq 64 ] || usage_err "--sha256 requires exactly 64 hex characters"
  case "$SHA256_PIN" in *[!0-9a-fA-F]*) usage_err "--sha256 requires exactly 64 hex characters" ;; esac
  SHA256_PIN="$(printf '%s' "$SHA256_PIN" | tr 'A-F' 'a-f')"
fi

# The `--channel` flag is the update-channel seam (ADR-0047m). On this fork the
# only channel is `python` (the default), so any other value fails closed.
case "$NON_INTERACTIVE" in
  0|1) : ;;
  *) usage_err "ACQ_INSTALL_NON_INTERACTIVE must be 0 or 1" ;;
esac

case "$CHANNEL" in
  python) ;;
  *) usage_err "unknown channel '$CHANNEL' (only 'python' is supported on this fork)" ;;
esac

# M1 preview selection never follows latest or the stable installer's baked pin.
if [ "$PREVIEW_REMOVE" -eq 0 ]; then
  [ "$VERSION_GIVEN" = 1 ] || usage_err "Python preview requires an explicit --ref X.Y.Z-rc.N pin"
  printf '%s\n' "$VERSION" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' \
    || usage_err "Python preview requires an explicit --ref X.Y.Z-rc.N pin"
fi
if [ -z "$INSTALL_DIR_FROM" ]; then INSTALL_DIR="$DATA_HOME/acq-python-preview"; fi

# Refuse traversal through links (including dangling ones) before any download or
# write. The preview never adopts Bash's data root or legacy ownership marker.
preview_real_path() {
  pp="$1"
  is_abs_path "$pp" || die "preview path must be an absolute path"
  case "$pp" in /|*/../*|*/./*|*/..|*/.) die "preview path must not contain dot components" ;; esac
  while [ "$pp" != / ]; do
    [ ! -L "$pp" ] || die "preview path contains a symlink: $(shown "$pp")"
    pp="${pp%/*}"; [ -n "$pp" ] || pp=/
  done
}
while [ "$INSTALL_DIR" != / ] && [ "${INSTALL_DIR%/}" != "$INSTALL_DIR" ]; do INSTALL_DIR="${INSTALL_DIR%/}"; done
is_abs_path "$INSTALL_DIR" || die "${INSTALL_DIR_FROM:-preview install directory} must be an absolute path, got '$(shown "$INSTALL_DIR")'"
is_abs_path "$BIN_DIR" || die "${BIN_DIR_FROM:-preview bin directory} must be an absolute path, got '$(shown "$BIN_DIR")'"
preview_real_path "$INSTALL_DIR"
preview_real_path "$BIN_DIR"
[ "$INSTALL_DIR" != "$DATA_HOME/acq" ] || die "Python preview cannot use Bash's shared install root"
PREVIEW_RECEIPT="$INSTALL_DIR/.acq-python-preview-receipt"
PREVIEW_MANIFEST="$INSTALL_DIR/.acq-python-preview-files"
PREVIEW_BACKUP="$INSTALL_DIR.acq-python-preview-previous"

preview_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1;
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1;
  else die "SHA-256 tool required for preview ownership"; fi
}
preview_validate_tree() {
  pv_root="$1"
  preview_real_path "$pv_root/.acq-python-preview-receipt"
  preview_real_path "$pv_root/.acq-python-preview-files"
  [ -f "$pv_root/.acq-python-preview-receipt" ] && [ -f "$pv_root/.acq-python-preview-files" ] \
    && grep -Fxq 'channel=python' "$pv_root/.acq-python-preview-receipt" \
    && grep -Fxq "root=$INSTALL_DIR" "$pv_root/.acq-python-preview-receipt" \
    && grep -Fxq "command=$BIN_DIR/acq-python" "$pv_root/.acq-python-preview-receipt" \
    || die "preview root already exists without a matching preview receipt"
  while IFS=' ' read -r digest rel; do
    case "$digest" in ''|*[!0-9a-f]*) die "invalid preview digest" ;; esac
    [ "${#digest}" -eq 64 ] || die "invalid preview digest"
    case "$rel" in py-acq/runtime/bin/python3@python3.14)
      [ -L "$pv_root/py-acq/runtime/bin/python3" ] && [ "$(readlink "$pv_root/py-acq/runtime/bin/python3")" = python3.14 ] \
        && [ "$(preview_sha256 "$pv_root/py-acq/runtime/bin/python3.14")" = "$digest" ] || die "invalid preview runtime link"
      continue ;;
      ''|/*|*../*|*/..|*[!A-Za-z0-9_./+-]*) die "invalid preview receipt path" ;;
    esac
    preview_real_path "$pv_root/$rel"
    if [ "$PREVIEW_REMOVE" -eq 0 ]; then
      [ -f "$pv_root/$rel" ] && [ "$(preview_sha256 "$pv_root/$rel")" = "$digest" ] \
        || die "preview owned file is missing or modified: $rel"
    fi
  done < "$pv_root/.acq-python-preview-files"
  pv_runtime_link="$pv_root/py-acq/runtime/bin/python3"
  if [ -L "$pv_runtime_link" ]; then
    [ "$(readlink "$pv_runtime_link")" = python3.14 ] && [ -f "$pv_root/py-acq/runtime/bin/python3.14" ] \
      || die "invalid preview runtime link"
  fi
}

preview_receipt_valid() {
  [ -f "$PREVIEW_RECEIPT" ] && [ ! -L "$PREVIEW_RECEIPT" ] \
    && [ -f "$PREVIEW_MANIFEST" ] && [ ! -L "$PREVIEW_MANIFEST" ] \
    && grep -Fxq 'channel=python' "$PREVIEW_RECEIPT" \
    && grep -Fxq "root=$INSTALL_DIR" "$PREVIEW_RECEIPT" \
    && grep -Fxq "command=$BIN_DIR/acq-python" "$PREVIEW_RECEIPT"
}
if [ -e "$PREVIEW_BACKUP" ] || [ -L "$PREVIEW_BACKUP" ]; then
  preview_real_path "$PREVIEW_BACKUP"
  preview_validate_tree "$PREVIEW_BACKUP"
  if [ ! -e "$INSTALL_DIR" ]; then
    if [ -e "$BIN_DIR/acq-python" ] || [ -L "$BIN_DIR/acq-python" ]; then
      [ -L "$BIN_DIR/acq-python" ] && [ "$(readlink "$BIN_DIR/acq-python")" = "$INSTALL_DIR/acq-python" ] \
        || die "foreign preview command prevents recovery"
    fi
    [ "$DRY_RUN" -eq 1 ] || mv "$PREVIEW_BACKUP" "$INSTALL_DIR"
  else
    die "preview recovery backup retained; move it aside after inspecting it before reinstalling"
  fi
fi
preview_remove() {
  preview_receipt_valid || die "no matching preview receipt for removal"
  # Only digest-matching regular files are removed. Modified/unknown entries,
  # configuration, credentials, backends and shared PATH are never swept.
  while IFS=' ' read -r digest rel; do
    if [ "$rel" = py-acq/runtime/bin/python3@python3.14 ]; then
      if [ -L "$INSTALL_DIR/py-acq/runtime/bin/python3" ] && [ "$(readlink "$INSTALL_DIR/py-acq/runtime/bin/python3")" = python3.14 ] \
        && [ "$(sha256_of "$INSTALL_DIR/py-acq/runtime/bin/python3.14")" = "$digest" ]; then
        [ "$DRY_RUN" -eq 1 ] || rm "$INSTALL_DIR/py-acq/runtime/bin/python3"
      else warn "preserving modified preview runtime link"; fi
      continue
    fi
    case "$rel" in ''|/*|*../*|*/..) die "invalid preview file receipt" ;; esac
    target="$INSTALL_DIR/$rel"
    preview_real_path "$target"
    if [ -f "$target" ] && [ "$(sha256_of "$target")" = "$digest" ]; then
      if [ "$DRY_RUN" -eq 0 ]; then rm "$target"; fi
    else warn "preserving modified or missing preview file: $(shown "$rel")"; fi
  done < "$PREVIEW_MANIFEST"
  runtime_link="$INSTALL_DIR/py-acq/runtime/bin/python3"
  if [ -L "$runtime_link" ] && [ "$(readlink "$runtime_link")" = python3.14 ]; then
    if [ "$DRY_RUN" -eq 0 ]; then rm "$runtime_link"; fi
  fi
  if [ -L "$BIN_DIR/acq-python" ] && [ "$(readlink "$BIN_DIR/acq-python")" = "$INSTALL_DIR/acq-python" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then rm "$BIN_DIR/acq-python"; fi
  fi
  info "Preview backout complete; unknown files, receipts and shared PATH preserved."
  exit 0
}
if [ -e "$INSTALL_DIR" ]; then
  [ -d "$INSTALL_DIR" ] || die "preview root is not a directory"
  preview_validate_tree "$INSTALL_DIR"
  pv_real="$(cd "$INSTALL_DIR" && pwd -P)"
  pv_mount="$(df -P "$INSTALL_DIR" | awk 'NR == 2 && match($0, /[0-9]+%[[:space:]]+/) { print substr($0, RSTART + RLENGTH) }')"
  [ "$pv_real" != "$pv_mount" ] || die "preview cannot atomically replace a mount-point root"
fi
if [ -e "$BIN_DIR/acq-python" ] || [ -L "$BIN_DIR/acq-python" ]; then
  preview_receipt_valid && [ -L "$BIN_DIR/acq-python" ] \
    && [ -e "$BIN_DIR/acq-python" ] \
    && [ "$(readlink "$BIN_DIR/acq-python")" = "$INSTALL_DIR/acq-python" ] \
    || die "refusing foreign or dangling acq-python command"
fi
if [ "$PREVIEW_REMOVE" -eq 1 ]; then
  sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1;
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1;
    else die "SHA-256 tool required for preview backout"; fi
  }
  preview_remove
fi

# The home directory also names the shell rc file the PATH step may edit, so it
# is required even when --install-dir and --bin-dir are given.
if [ -z "$USER_HOME" ]; then
  if [ -n "${HOME+set}" ]; then home_desc="'$(shown "$HOME")'"; else home_desc="unset"; fi
  die "cannot determine an absolute home directory (HOME is $home_desc); set HOME to an absolute path"
fi

# The install directory must be absolute, like acq's other path overrides. The
# launcher symlink points at "$INSTALL_DIR/acq", and a relative symlink target
# resolves against the link's own directory, not the one the installer ran in,
# so a relative value would leave the launcher dangling.
if ! is_abs_path "$INSTALL_DIR"; then
  die "${INSTALL_DIR_FROM:-the install directory} must be an absolute path, got '$(shown "$INSTALL_DIR")'; pass an absolute --install-dir (or unset ACQ_INSTALL_DIR to use the default)"
fi
# The bin directory too: a relative one would put the launcher links under
# whatever directory the installer happened to run in, off the user's PATH.
if ! is_abs_path "$BIN_DIR"; then
  die "${BIN_DIR_FROM:-the bin directory} must be an absolute path, got '$(shown "$BIN_DIR")'; pass an absolute --bin-dir (or unset ACQ_INSTALL_BIN_DIR to use the default)"
fi

# ---------------------------------------------------------------------------
# Platform -> release archive name (the enumerated offline asset set, ADR-0042m).
#
# Supported: macOS arm64 (Apple Silicon), Linux x86_64 + aarch64. Windows x64 is
# served by install.ps1; Windows ARM64 and musl are out of scope. Intel Macs are
# NOT supported: acq's local runtime needs Apple Silicon virtualization, and
# Rosetta does not change that (docs/howto/acq.md), so there is no macos-x86_64
# archive and that host is refused before anything is fetched or read. The
# archive name for each cell is mirrored in installer/assets.json.
# ---------------------------------------------------------------------------

platform_key() {
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64) printf 'macos-arm64\n' ;;
        # An Intel Mac is refused by name, not reported as an unknown platform:
        # status 2 tells the caller to print the Intel-specific message.
        x86_64) return 2 ;;
        *) return 1 ;;
      esac ;;
    Linux)
      case "$arch" in
        x86_64|amd64) printf 'linux-x86_64\n' ;;
        aarch64|arm64) printf 'linux-aarch64\n' ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

archive_name() {
  key="$1"
  case "$key" in
    macos-arm64)    printf 'acq-macos-arm64.tar.gz\n' ;;
    linux-x86_64)   printf 'acq-linux-x86_64.tar.gz\n' ;;
    linux-aarch64)  printf 'acq-linux-aarch64.tar.gz\n' ;;
    *) return 1 ;;
  esac
}

# sha256 of a file via whichever tool this host has. Empty means neither exists,
# and callers MUST fail closed rather than install an unverified artifact.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

# The expected sha256 for $2 as recorded in a SHA256SUMS file ($1). Empty when the
# file has no entry for it; callers fail closed on empty. Accepts both the
# standard "HASH  name" (two spaces) form and the GNU binary "HASH *name" form.
# The name must match the whole filename field, as install.ps1 requires: a
# substring match would take the hash of "x-acq.tar.gz" or "acq.tar.gz.sig".
sha256_expected() {
  sums="$1" name="$2"
  awk -v want="$name" '
    { sub(/\r$/, "") }
    NF == 2 && length($1) == 64 && $1 !~ /[^0-9A-Fa-f]/ {
      file = $2; sub(/^\*/, "", file)
      if (file == want) { print tolower($1); exit }
    }
  ' "$sums" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Prompt helper — yes/no, honoring --yes and non-interactive stdin.
# Returns 0 for yes, 1 for no. Default is NO when there is no way to ask
# (fail-closed: a non-interactive run never infers consent, ADR-0038m §50).
# ---------------------------------------------------------------------------

confirm() {
  prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  [ "$NON_INTERACTIVE" = 1 ] && return 1
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$prompt"
    read -r ans || return 1
  # Under `curl | sh` stdin is the script pipe, so ask on the controlling
  # terminal instead. That needs someone watching the run (stdout or stderr is
  # a terminal) and a /dev/tty that opens for writing and reading; the
  # redirections sit inside braces so an unusable /dev/tty declines quietly.
  # Anything else (CI, a harness that captures the output, no controlling
  # terminal) declines rather than guessing.
  elif { [ -t 1 ] || [ -t 2 ]; } \
       && { printf '%s [y/N] ' "$prompt" > /dev/tty; } 2>/dev/null \
       && { read -r ans < /dev/tty; } 2>/dev/null; then
    :
  else
    return 1
  fi
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Only a GitHub release URL supplies a repository identity for attestations.
# Missing attestations are informational; every other verifier error fails closed,
# since an authentication, transport or signature error is not proof of absence.
verify_attestation() {
  [ "${ACQ_INSTALL_NO_ATTESTATION:-0}" = 1 ] && return 0
  # GitHub's host name is case-insensitive; normalise it so a differently cased
  # URL is not silently exempted from verification.
  repo=$(printf '%s\n' "$SOURCE" | sed 's@^[Hh][Tt][Tt][Pp][Ss]://[Gg][Ii][Tt][Hh][Uu][Bb]\.[Cc][Oo][Mm]/@https://github.com/@' | sed -n 's@^https://github\.com/\([A-Za-z0-9_.-][A-Za-z0-9_.-]*/[A-Za-z0-9_.-][A-Za-z0-9_.-]*\)/releases/download/[^?#][^?#]*$@\1@p')
  [ -n "$repo" ] || return 0
  if ! command -v gh >/dev/null 2>&1; then
    info "  attestation unavailable: gh missing; continuing"
    return 0
  fi
  # gh gained `attestation` in 2.49; an older gh (e.g. a distribution package)
  # cannot verify, which is the same as having no verifier.
  if ! gh attestation verify --help >/dev/null 2>&1; then
    info "  attestation unavailable: this gh has no 'attestation' command; continuing"
    return 0
  fi
  att_rc=0
  gh attestation verify "$1" --repo "$repo" > "$tmpdir/attestation.log" 2>&1 || att_rc=$?
  # Absence is checked first: some gh releases print "no attestations found" yet
  # exit 0. Success then needs gh's own success line, not just exit status 0.
  if LC_ALL=C grep -Eiq 'no attestations found|no attestations associated|HTTP 404: Not Found' "$tmpdir/attestation.log"; then
    info "  attestation absent for $ARCHIVE; continuing"
  elif [ "$att_rc" -eq 0 ] && LC_ALL=C grep -q 'Verification succeeded' "$tmpdir/attestation.log"; then
    ok "  verified attestation for $ARCHIVE"
  else
    cat "$tmpdir/attestation.log" >&2
    die "attestation verification failed for $ARCHIVE"
  fi
}

# Keep the policy in lockstep with acq.backends/msb.sh and ADR-0032:
# >= 0.6.9, excluding 0.7.0 through 0.7.2. Unknown versions need attention too.
msb_version_supported() {
  printf '%s\n' "$1" | awk '
    /^[0-9]+\.[0-9]+\.[0-9]+$/ {
      split($0, v, ".")
      if (v[1] == 0 && v[2] == 7 && v[3] <= 2) exit 1
      if (v[1] > 0 || v[2] > 6 || (v[2] == 6 && v[3] >= 9)) exit 0
      exit 1
    }
    !/^[0-9]+\.[0-9]+\.[0-9]+$/ { exit 1 }
  '
}

# Use the same checksum-verified bundle layout as scripts/verify-msb-pin.
# This runs only after explicit interactive consent, never from --yes.
install_pinned_msb() (
  set -e
  if command -v brew >/dev/null 2>&1; then
    brew install GSA-TTS/tap/microsandbox-acq </dev/null
    exit
  fi
  msb_root="${MSB_HOME:-$USER_HOME/.microsandbox}"
  is_abs_path "$msb_root" || die "MSB_HOME must be absolute"
  # The digests are pinned here rather than read from the release's own
  # checksums.sha256, so a tampered download host cannot supply both a bundle and
  # a matching checksum. They were checked against the v0.7.7 release's
  # checksums.sha256 and GitHub's asset digests; update them with the version.
  case "$KEY" in
    linux-x86_64) bundle=microsandbox-linux-x86_64.tar.gz
      expected=b3cc4a5e3f52dfdd938a6f67ac4a9a959ddfe304bab56de4964044b8613f01bb ;;
    linux-aarch64) bundle=microsandbox-linux-aarch64.tar.gz
      expected=8997b1ea76de58689fb6d0fa7b32af6fbe8cbc24612da40b168a5b433c7d8318 ;;
    macos-arm64) bundle=microsandbox-darwin-aarch64.tar.gz
      expected=eed5faa16217ad375ad9a4eb5e819656baeab8ccde0d3ab7e79c4af49319d403 ;;
    *) die "no pinned msb bundle for $KEY; see docs/howto/msb.md" ;;
  esac
  base=https://github.com/superradcompany/microsandbox/releases/download/v0.7.7
  msb_tmp=$(mktemp -d "$tmp_base/acq-msb.XXXXXXXX")
  trap 'rm -rf "$msb_tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  # Test hook, honoured only under bats like the KVM path override: fixture
  # bundles cannot match the real release digests.
  if [ -n "${BATS_TEST_NAME:-}" ] && [ -n "${ACQ_TEST_MSB_BUNDLE_SHA256:-}" ]; then
    expected=$ACQ_TEST_MSB_BUNDLE_SHA256
  fi
  fetch "$base/$bundle" "$msb_tmp/$bundle"
  actual=$(sha256_of "$msb_tmp/$bundle")
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "pinned msb checksum mismatch"
  tar -xzf "$msb_tmp/$bundle" -C "$msb_tmp"
  [ -f "$msb_tmp/msb" ] || die "pinned bundle missing msb"
  publish_pinned_msb
)

publish_pinned_msb() {
  libname=""
  for candidate in "$msb_tmp"/libkrunfw.so.*.*.* "$msb_tmp"/libkrunfw.*.dylib; do
    [ -f "$candidate" ] || continue
    [ -z "$libname" ] || die "pinned bundle has multiple libkrunfw libraries"
    libname=${candidate##*/}
  done
  [ -n "$libname" ] || die "pinned bundle missing libkrunfw"
  case "$libname" in
    *.dylib) abi=${libname#libkrunfw.}; abi=${abi%.dylib} ;;
    *) abi=${libname#libkrunfw.so.}; abi=${abi%%.*} ;;
  esac
  case "$abi" in ''|*[!0-9]*) die "invalid libkrunfw ABI" ;; esac
  mkdir -p "$msb_root/bin" "$msb_root/lib" "$BIN_DIR"
  install -m 755 "$msb_tmp/msb" "$msb_root/bin/msb"
  ln -sf msb "$msb_root/bin/microsandbox"
  # Rename avoids retaining macOS's code-signature cache for an overwritten vnode.
  cp "$msb_tmp/$libname" "$msb_root/lib/$libname.tmp"
  mv "$msb_root/lib/$libname.tmp" "$msb_root/lib/$libname"
  case "$libname" in
    *.dylib) ln -sf "$libname" "$msb_root/lib/libkrunfw.dylib" ;;
    *) ln -sf "$libname" "$msb_root/lib/libkrunfw.so.$abi"
       ln -sf "libkrunfw.so.$abi" "$msb_root/lib/libkrunfw.so" ;;
  esac
  for name in msb microsandbox; do
    if [ -e "$BIN_DIR/$name" ] || [ -L "$BIN_DIR/$name" ]; then
      warn "  leaving existing $BIN_DIR/$name alone"
    else ln -s "$msb_root/bin/$name" "$BIN_DIR/$name"; fi
  done
  ok "  installed pinned msb 0.7.7 into $msb_root"
}

report_virtualization() {
  kvm_path=/dev/kvm
  # Device substitution is only for bats; normal installs always probe /dev/kvm.
  if [ -n "${BATS_TEST_NAME:-}" ] && [ -n "${ACQ_TEST_KVM_PATH:-}" ]; then kvm_path=$ACQ_TEST_KVM_PATH; fi
  case "$(uname -s)" in
    Linux) if [ -e "$kvm_path" ] && [ -r "$kvm_path" ] && [ -w "$kvm_path" ]; then
      info "  hardware virtualization: found (KVM readable and writable)"
    else info "  hardware virtualization: missing (KVM unavailable or inaccessible)"; info "    Fix: msb doctor --fix"; fi ;;
    Darwin) if [ "$(sysctl -n kern.hv_support 2>/dev/null || :)" = 1 ]; then
      info "  hardware virtualization: found (Hypervisor.framework)"
    else info "  hardware virtualization: missing"; info "    Fix: msb doctor --fix"; fi ;;
  esac
}

report_prerequisites() {
  step "Next steps: sandbox prerequisites (one backend is sufficient)"
  if command -v msb >/dev/null 2>&1; then
    msb_text=$(msb --version 2>/dev/null) || msb_text=unknown
    [ -n "$msb_text" ] || msb_text=unknown
    msb_ver=$(printf '%s\n' "$msb_text" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*[^[:space:]]*\).*$/\1/p' | head -n 1)
    if [ -n "$msb_ver" ] && msb_version_supported "$msb_ver"; then
      info "  msb: found ($msb_text; supported)"
    else
      info "  msb: found ($msb_text; out-of-policy or unknown version)"
      info "    Fix: brew install GSA-TTS/tap/microsandbox-acq or scripts/verify-msb-pin --install"
    fi
  else
    info "  msb: missing"
    info "    Fix: brew install GSA-TTS/tap/microsandbox-acq or scripts/verify-msb-pin --install"
    # --yes consents only to PATH changes, never to installing a backend.
    if [ "$ASSUME_YES" -eq 0 ] && { [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; } && confirm "  Install pinned msb?"; then
      # msb is optional for acq itself: a failed backend install warns rather
      # than aborting after acq is already in place.
      install_pinned_msb || warn "  msb install failed; see docs/howto/msb.md"
    fi
  fi
  if command -v sbx >/dev/null 2>&1; then info "  sbx: found";
  else info "  sbx: missing"; info "    Fix: brew install docker/tap/sbx && sbx login"; fi
  report_virtualization
  if command -v git >/dev/null 2>&1; then info "  git: found";
  else
    info "  git: missing"
    case "$(uname -s)" in
      Darwin) info "    Fix: xcode-select --install" ;;
      *) info "    Fix: brew install git (or install git with your distribution's package manager)" ;;
    esac
  fi
}

path_has_bindir() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) return 0 ;;
    *) return 1 ;;
  esac
}

rc_file_for_shell() {
  case "${SHELL:-}" in
    */zsh) printf '%s\n' "$USER_HOME/.zshrc" ;;
    */bash) printf '%s\n' "$USER_HOME/.bash_profile" ;;
    *) printf '%s\n' "$USER_HOME/.profile" ;;
  esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

step "Checking your system"

# Before any source is resolved, read or fetched: an unusable host is refused
# here, not after a download it cannot run.
platform_status=0
KEY="$(platform_key)" || platform_status=$?
case "$platform_status" in
  0) ;;
  2) die "Intel Macs (x86_64) are not supported by acq.
acq's local sandbox runtime needs Apple Silicon virtualization, and running the
installer under Rosetta does not change that. See the host requirements in
docs/howto/acq.md. Nothing was downloaded or installed." ;;
  *) die "unsupported platform '$(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)' (supported: macOS arm64, Linux x86_64/aarch64; Windows x64 uses install.ps1)" ;;
esac
ARCHIVE="$(archive_name "$KEY")" || die "no release archive for platform '$KEY'"

# Resolve the source: a URL (default), or a local directory holding the offline
# asset set (SHA256SUMS + the archive) so an air-gapped host can install.
if [ -z "$SOURCE" ]; then
  SOURCE="${RELEASE_BASE_URL}/v${VERSION}"
fi
case "$SOURCE" in
  https://*|file://*) SOURCE_IS_URL=1 ;;
  # Plain HTTP would let anyone on the path swap both the archive and the
  # SHA256SUMS it is checked against.
  http://*) usage_err "refusing a plaintext http:// source '$(shown "$SOURCE")'; use https:// or a local directory" ;;
  *) SOURCE_IS_URL=0 ;;
esac

# Remote downloads use HTTPS with TLS 1.2 or newer only, for the first request
# and for every redirect, so a redirect cannot downgrade the transfer to plain
# HTTP. A file:// source names a local offline asset set and is fetched as is.
fetch() {
  case "$1" in
    https://*) curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "$1" -o "$2" ;;
    *) curl -fsSL "$1" -o "$2" ;;
  esac
}
case "$SOURCE" in
  https://*) CURL_SHOWN="curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2" ;;
  *) CURL_SHOWN="curl -fsSL" ;;
esac

info "  platform:    $KEY"
info "  channel:     $CHANNEL"
info "  archive:     $ARCHIVE"
info "  source:      $SOURCE"
info "  install dir: $INSTALL_DIR"
info "  launcher:    $BIN_DIR/acq-python"
[ "$DRY_RUN" -eq 1 ] && warn "  (dry-run: no changes will be made)"

if [ "$SOURCE_IS_URL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required to download the release, but was not found."
fi

# ---------------------------------------------------------------------------
# Dry run — report the whole plan with no side effects.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  step "Would install acq $VERSION"
  if [ "$SOURCE_IS_URL" -eq 1 ]; then
    printf '  [dry-run] %s %s/%s -o <tmp>/%s\n' "$CURL_SHOWN" "$SOURCE" "$SHA256SUMS_NAME" "$SHA256SUMS_NAME"
    printf '  [dry-run] %s %s/%s -o <tmp>/%s\n' "$CURL_SHOWN" "$SOURCE" "$PROVENANCE_NAME" "$PROVENANCE_NAME"
    printf '  [dry-run] %s %s/%s -o <tmp>/%s\n' "$CURL_SHOWN" "$SOURCE" "$ARCHIVE" "$ARCHIVE"
  else
    printf '  [dry-run] read %s/%s, %s/%s, and %s/%s from the offline asset set\n' \
      "$SOURCE" "$SHA256SUMS_NAME" "$SOURCE" "$PROVENANCE_NAME" "$SOURCE" "$ARCHIVE"
  fi
  [ "$SHA256_PIN_GIVEN" -eq 0 ] || info "  [dry-run] verify SHA256SUMS against --sha256 before reading entries"
  printf '  [dry-run] verify sha256 of %s against %s\n' "$ARCHIVE" "$SHA256SUMS_NAME"
  printf '  [dry-run] extract %s into %s\n' "$ARCHIVE" "$INSTALL_DIR"
  printf '  [dry-run] verify the enumerated set (launchers, backend tree, runtime, source, wheelhouse) is present\n'
  printf '  [dry-run] link %s/acq-python -> %s/acq-python\n' "$BIN_DIR" "$INSTALL_DIR"
  if path_has_bindir; then
    ok "  $BIN_DIR is already on your PATH."
  else
    printf '  [dry-run] use %s/acq-python directly; PATH and shell profiles unchanged\n' "$BIN_DIR"
  fi
  info "Dry run complete — no changes were made."
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch SHA256SUMS + archive (network, or a local offline asset set)
# ---------------------------------------------------------------------------

step "Downloading acq $VERSION"

# A private, unpredictably named work dir: the archive is verified here and
# then extracted, so another local user must not be able to pre-create or swap
# it between those steps. mktemp -d creates it 0700 and fails rather than reuse
# an existing path (a fixed name like acq-install.$$ plus `mkdir -p` would
# silently adopt an attacker's directory).
# The cleanup trap is installed first (rm -rf "" is a no-op), and signals EXIT
# rather than return: a trap that only cleaned up would let the script carry on
# after its private dir was deleted, and a later mkdir would re-create that
# now-known path, which another user could have taken in the meantime.
# The same trap removes this run's temporary ownership marker (set only while
# it exists, below), so a failure or signal between writing it and renaming it
# into place leaves no litter in the install dir.
# The staging dir beside the install dir (below) is removed the same way.
tmpdir=""
stage_root=""
marker_tmp=""
trap 'rm -rf "$tmpdir" "$stage_root"; [ -z "$marker_tmp" ] || rm -f "$marker_tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# A relative TMPDIR is ignored (it would resolve against the current directory).
tmp_base=/tmp
if is_abs_path "${TMPDIR:-}"; then tmp_base="$TMPDIR"; fi
tmpdir="$(mktemp -d "$tmp_base/acq-install.XXXXXXXX")" \
  || die "could not create a private temporary directory"
chmod 700 "$tmpdir"

if [ "$SOURCE_IS_URL" -eq 1 ]; then
  fetch "$SOURCE/$SHA256SUMS_NAME" "$tmpdir/$SHA256SUMS_NAME" \
    || die "could not download $SOURCE/$SHA256SUMS_NAME"
  fetch "$SOURCE/$PROVENANCE_NAME" "$tmpdir/$PROVENANCE_NAME" \
    || die "could not download $SOURCE/$PROVENANCE_NAME"
  fetch "$SOURCE/$ARCHIVE" "$tmpdir/$ARCHIVE" \
    || die "could not download $SOURCE/$ARCHIVE"
else
  [ -f "$SOURCE/$SHA256SUMS_NAME" ] || die "offline asset set at $SOURCE has no $SHA256SUMS_NAME"
  [ -f "$SOURCE/$PROVENANCE_NAME" ] || die "offline asset set at $SOURCE has no $PROVENANCE_NAME"
  [ -f "$SOURCE/$ARCHIVE" ] || die "offline asset set at $SOURCE has no $ARCHIVE"
  cp "$SOURCE/$SHA256SUMS_NAME" "$tmpdir/$SHA256SUMS_NAME"
  cp "$SOURCE/$PROVENANCE_NAME" "$tmpdir/$PROVENANCE_NAME"
  cp "$SOURCE/$ARCHIVE" "$tmpdir/$ARCHIVE"
fi

# ---------------------------------------------------------------------------
# Verify the archive against SHA256SUMS — fail closed on any mismatch.
# ---------------------------------------------------------------------------

step "Verifying $ARCHIVE"

if [ "$SHA256_PIN_GIVEN" -eq 1 ]; then
  sums_actual="$(sha256_of "$tmpdir/$SHA256SUMS_NAME" | tr 'A-F' 'a-f')"
  [ "$sums_actual" = "$SHA256_PIN" ] || die "SHA256SUMS pin mismatch; refusing to install"
  ok "  verified SHA256SUMS pin"
fi

expected="$(sha256_expected "$tmpdir/$SHA256SUMS_NAME" "$ARCHIVE")"
if [ -z "$expected" ]; then
  die "SHA256SUMS has no entry for $ARCHIVE; refusing to install an unverified archive"
fi
actual="$(sha256_of "$tmpdir/$ARCHIVE")"
if [ -z "$actual" ]; then
  die "neither sha256sum nor shasum is available to verify the download"
fi
if [ "$expected" != "$actual" ]; then
  die "checksum mismatch for $ARCHIVE (expected $expected, got $actual)"
fi
ok "  verified $ARCHIVE (sha256 $actual)"
verify_attestation "$tmpdir/$ARCHIVE"

# The provenance manifest travels alongside SHA256SUMS and is part of the
# enumerated offline asset set; its absence is a fail-closed gate. SHA256SUMS
# lists it too, so it is verified like the archive: an installed provenance
# record that nothing checked would be a claim, not evidence.
[ -f "$tmpdir/$PROVENANCE_NAME" ] || die "release is missing the provenance manifest ($PROVENANCE_NAME)"
prov_expected="$(sha256_expected "$tmpdir/$SHA256SUMS_NAME" "$PROVENANCE_NAME")"
[ -n "$prov_expected" ] || die "$SHA256SUMS_NAME has no entry for $PROVENANCE_NAME; refusing to install unverified provenance"
prov_actual="$(sha256_of "$tmpdir/$PROVENANCE_NAME")"
[ "$prov_expected" = "$prov_actual" ] || die "checksum mismatch for $PROVENANCE_NAME (expected $prov_expected, got $prov_actual)"

# ---------------------------------------------------------------------------
# Extract into a staging directory, then publish atomically (update-by-reinstall).
# ---------------------------------------------------------------------------

step "Installing into $INSTALL_DIR"

command -v tar >/dev/null 2>&1 || die "tar is required to extract the release archive"

# Strip trailing slashes so `[ -L ]` tests the link itself, not its target, and
# so the parent below is the real parent.
while :; do
  case "$INSTALL_DIR" in
    */) [ "$INSTALL_DIR" = / ] && break; INSTALL_DIR="${INSTALL_DIR%/}" ;;
    *) break ;;
  esac
done
# Refuse an unusable install dir before anything is written or extracted.
if [ -L "$INSTALL_DIR" ]; then
  die "$INSTALL_DIR is a symlink; refusing to install through it (pass --install-dir with a real directory)"
fi
if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
  die "$INSTALL_DIR exists and is not a directory; move it aside or pass --install-dir"
fi

# Leftovers of an earlier run are named for that run's process id. A PID that
# is still alive may be another install into the same directory, running right
# now, and sweeping its in-flight files would make it fail, so its entries are
# skipped. A process owned by another user answers kill -0 with an error, so ps
# is asked too; a reused PID only means the leftover waits for a later run. Two
# PIDs never count as alive: this run's own (an earlier run in a fresh container
# often had the same PID, and its leftovers are not this run's), and 1, which is
# init on a host and in most containers rather than an installer. The check
# sees only this PID namespace, so an install running in another container or
# on another host sharing the directory, or one running as PID 1, looks dead.
pid_alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" != "$$" ] && [ "$1" != 1 ] || return 1
  kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

# Extract into a private directory beside the install dir, in its parent, so the
# release and the install dir share a filesystem and each move into place below
# is a rename. Staged under TMPDIR, a move across filesystems would become a
# copy plus a delete, and a failure partway would leave half-copied entries. If
# the parent cannot hold a new directory (an install dir the user created under
# a parent they cannot write), stage in the private work dir as before; a failed
# run there is still finished by re-running the installer. The name carries this
# run's PID so a later run can sweep a staging dir left by one that was killed.
install_parent="${INSTALL_DIR%/*}"
[ -n "$install_parent" ] || install_parent=/
mkdir -p "$install_parent" 2>/dev/null || :
# When the install dir is itself a mount point, its parent is another filesystem
# and every move out of a parent-side staging dir would be a copy. Stage inside
# the install dir instead; its staging dir is not a release name, so the
# collision check below never sees it, and the sweep below covers both places.
stage_base="$install_parent"
if [ -d "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ]; then
  install_real="$(cd "$INSTALL_DIR" 2>/dev/null && pwd -P)" || install_real=""
  # df -P is POSIX; the mount point is everything after the capacity column
  # ("NN%"). Anchoring there keeps spaces in the filesystem name or in the mount
  # point (even several in a row) from shifting or collapsing the path.
  install_mount="$(df -P "$INSTALL_DIR" 2>/dev/null | awk 'NR == 2 && match($0, /[0-9]+%[[:space:]]+/) { print substr($0, RSTART + RLENGTH) }')" || install_mount=""
  [ -n "$install_real" ] && [ "$install_mount" = "$install_real" ] && stage_base="$INSTALL_DIR"
fi
if stage_root="$(mktemp -d "$stage_base/.acq-stage.$$.XXXXXXXX" 2>/dev/null)"; then
  chmod 700 "$stage_root"
  staging="$stage_root/stage"
else
  stage_root=""
  warn "  cannot create a staging directory in $stage_base; staging under $tmp_base instead"
  staging="$tmpdir/stage"
fi
# No -p: if the private dir has vanished, fail instead of re-creating it.
mkdir "$staging" || die "could not create the staging directory"

case "$ARCHIVE" in
  *.tar.gz) tar -xzf "$tmpdir/$ARCHIVE" -C "$staging" || die "could not extract $ARCHIVE" ;;
  *.tgz) tar -xzf "$tmpdir/$ARCHIVE" -C "$staging" || die "could not extract $ARCHIVE" ;;
  *) die "unsupported archive format for $ARCHIVE" ;;
esac

# The archive may contain a single top-level directory (e.g. built by `tar -czf`),
# or its contents at the root. Normalize to the root of the extracted tree.
if [ ! -e "$staging/acq" ] && [ ! -e "$staging/py-acq" ]; then
  top="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [ -n "$top" ] && { [ -e "$top/acq" ] || [ -e "$top/py-acq" ]; }; then
    staging="$top"
  fi
fi

# Verify every enumerated component of the offline asset set is present before
# writing (ADR-0042m). A release that passes SHA256SUMS but is missing the source
# tree, the bundled runtime, the wheelhouse, or the launcher would otherwise
# "install" and fail later — so each is a fail-closed gate. (The provenance
# manifest was fetched alongside SHA256SUMS above.)
[ -e "$staging/acq" ] || die "release archive is missing the 'acq' launcher"
[ -e "$staging/acq-python" ] || die "release archive is missing the 'acq-python' launcher"
# The `acq` launcher is the Bash dispatcher. It sources acq.backends/common.sh
# before it reads ACQ_IMPL, so without the backend tree neither the default
# Bash path nor ACQ_IMPL=python can start; only acq-python would work.
[ -e "$staging/acq.backends/common.sh" ] || die "release archive is missing the Bash backend tree (acq.backends/)"
[ -e "$staging/py-acq/runtime/bin/python3" ] || die "release archive is missing the bundled runtime (py-acq/runtime/bin/python3)"
[ -e "$staging/py-acq/src/acq_py/__init__.py" ] || die "release archive is missing the acq source tree (py-acq/src/acq_py/)"
[ -d "$staging/wheelhouse" ] || die "release archive is missing the dependency wheelhouse (wheelhouse/)"

# Publish without destroying anything this installer did not create. The default
# install dir ($XDG_DATA_HOME/acq) is also where the legacy Bash acq keeps its
# file-fallback secret store and provider-input-validator runtime, and
# --install-dir / ACQ_INSTALL_DIR can name any directory. So the installer records
# the exact top-level names it owns in a marker file, overwrites only those names,
# and refuses any other collision. The marker is written before anything moves, so
# a failed run leaves a directory the next run can finish.
OWNED_MARKER=".acq-v1-install"
cp "$tmpdir/$PROVENANCE_NAME" "$staging/$PROVENANCE_NAME"

# Preview files are owned only while their recorded digests still match. The
# legacy Bash marker is never used as evidence of preview ownership.
preview_check_files() {
  while IFS=' ' read -r digest rel; do
    case "$digest" in ''|*[!0-9a-f]*) die "invalid preview file digest" ;; esac
    [ "${#digest}" -eq 64 ] || die "invalid preview file digest"
    case "$rel" in ''|/*|*../*|*/..) die "invalid preview file receipt" ;; esac
    target="$INSTALL_DIR/$rel"
    preview_real_path "$target"
    [ -f "$target" ] && [ "$(sha256_of "$target")" = "$digest" ] \
      || die "preview owned file is missing or modified: $(shown "$rel")"
  done < "$PREVIEW_MANIFEST"
}
if [ -e "$INSTALL_DIR" ]; then preview_check_files; fi
# Capture the complete link list before validating members. The prior pipeline
# did not reliably surface a failed `find` to this shell, which does not enable
# pipefail. A malformed or inaccessible extracted tree must fail closed instead
# of looking like an archive with no links.
find "$staging" -type l -print > "$tmpdir/preview-links" \
  || die "could not enumerate preview archive links"
links_ok=1
while IFS= read -r link; do
  rel="${link#"$staging"/}"
  case "$rel" in py-acq/runtime/bin/python3) [ "$(readlink "$link")" = python3.14 ] || links_ok=0 ;;
    *) links_ok=0 ;;
  esac
done < "$tmpdir/preview-links"
[ "$links_ok" -eq 1 ] || die "preview archive contains unsupported links"
find "$staging" -type f -print | while IFS= read -r file; do
  rel="${file#"$staging"/}"
  case "$rel" in *[!A-Za-z0-9_./+-]*|*../*) die "invalid preview archive filename" ;; esac
  case "$rel" in .acq-python-preview-*) die "archive contains reserved preview receipt" ;; esac
  preview_real_path "$INSTALL_DIR/$rel"
  if [ -e "$INSTALL_DIR/$rel" ]; then
    [ -f "$PREVIEW_MANIFEST" ] && awk -v want="$rel" '$2 == want { found=1 } END { exit !found }' "$PREVIEW_MANIFEST" \
      || die "preview archive collides with an unknown file: $rel"
  fi
  if [ -d "$INSTALL_DIR/$rel" ]; then die "preview archive file collides with a directory: $rel"; fi
done
for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
  { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
  name="${entry##*/}"
  if [ -e "$INSTALL_DIR/$name" ]; then
    awk -v want="$name" '$2 == want || index($2, want "/") == 1 { found=1 } END { exit !found }' "$PREVIEW_MANIFEST" \
      || die "preview archive collides with an unknown entry: $name"
  fi
done
find "$staging" -type f -print | while IFS= read -r file; do
  rel="${file#"$staging"/}"
  printf '%s %s\n' "$(sha256_of "$file")" "$rel"
done > "$tmpdir/preview-files"
if [ -L "$staging/py-acq/runtime/bin/python3" ]; then
  printf '%s %s\n' "$(sha256_of "$staging/py-acq/runtime/bin/python3.14")" 'py-acq/runtime/bin/python3@python3.14' >> "$tmpdir/preview-files"
fi
{
  printf 'channel=python\nversion=%s\nsource=%s\narchive=%s\nsha256=%s\n' "$VERSION" "$SOURCE" "$ARCHIVE" "$actual"
  printf 'checksums_sha256=%s\nprovenance_sha256=%s\n' "$(sha256_of "$tmpdir/$SHA256SUMS_NAME")" "$prov_actual"
  printf 'root=%s\ncommand=%s/acq-python\n' "$INSTALL_DIR" "$BIN_DIR"
} > "$tmpdir/preview-receipt"
publish="$stage_root/publish"
[ -n "$stage_root" ] || die "preview publication requires same-filesystem staging"
mkdir "$publish"
if [ -d "$INSTALL_DIR" ]; then cp -R "$INSTALL_DIR/." "$publish/"; fi
cp -R "$staging/." "$publish/"
cp "$tmpdir/preview-files" "$publish/.acq-python-preview-files"
cp "$tmpdir/preview-receipt" "$publish/.acq-python-preview-receipt"
mkdir -p "$BIN_DIR"
if [ -d "$INSTALL_DIR" ]; then mv "$INSTALL_DIR" "$PREVIEW_BACKUP"; fi
if ! mv "$publish" "$INSTALL_DIR"; then
  [ ! -d "$PREVIEW_BACKUP" ] || mv "$PREVIEW_BACKUP" "$INSTALL_DIR"
  die "preview publish failed; previous installation restored"
fi
# The backup consists only of the exact previous root copied above; it is not
# a wildcard sweep. Unknown files were retained in the newly published tree.
[ ! -d "$PREVIEW_BACKUP" ] || rm -rf "$PREVIEW_BACKUP"
if [ ! -L "$BIN_DIR/acq-python" ]; then ln -s "$INSTALL_DIR/acq-python" "$BIN_DIR/acq-python"; fi
ok "  installed Python preview; run $BIN_DIR/acq-python version"
info "  PATH and shell profiles were not changed. Back out with --channel python --remove-preview."
exit 0

mkdir -p "$INSTALL_DIR"
marker="$INSTALL_DIR/$OWNED_MARKER"
was_marked=0
[ -f "$marker" ] && was_marked=1

# Owned names are the marker's lines after the version header.
_acq_owned() {
  [ -f "$marker" ] && tail -n +2 "$marker" | grep -Fxq -- "$1"
}

for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
  { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
  name="${entry##*/}"
  if { [ -e "$INSTALL_DIR/$name" ] || [ -L "$INSTALL_DIR/$name" ]; } && ! _acq_owned "$name"; then
    die "$INSTALL_DIR already contains '$name', which this installer did not create (not listed in $OWNED_MARKER). Move it aside or pass --install-dir; nothing was changed."
  fi
done

# Every release name is now absent or already ours, so recording them as owned is
# truthful. Keep previously owned names too: leftovers from an older release are
# still ours to replace later. The marker is written to a temporary file and
# renamed into place; the EXIT trap removes the temporary file if the run stops
# in between.
marker_tmp="$marker.tmp.$$"
{
  printf '%s\n' "$VERSION"
  { [ -f "$marker" ] && tail -n +2 "$marker"; } || :
  for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
    { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
    printf '%s\n' "${entry##*/}"
  done
} | awk 'NR == 1 || !seen[$0]++' > "$marker_tmp"
mv "$marker_tmp" "$marker" || die "could not write $marker"
marker_tmp=""

# Move-aside dirs and temporary markers from an earlier interrupted run hold
# only acq's own files, but only trust that in a directory that was already
# marked before this run. A temporary marker is a regular file named for the
# marker plus ".tmp." and a process id; anything else is left alone. Staging
# dirs left in the parent by a killed run (.acq-stage.<pid>.<random>) are swept
# under the same rule, never this run's own. Entries of a live process are
# skipped (pid_alive, above). Only entries this user owns are swept, and the
# sweep is best effort: in a shared parent such as /opt or /tmp another user's
# killed install can leave a staging dir this user cannot remove, and a failed
# removal must not stop this install (or every later one) partway through.
# Ownership is read with find's -user, because test -O is not POSIX.
my_uid="$(id -u 2>/dev/null)" || my_uid=""
owned_by_me() {
  case "$my_uid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$(find "$1" -prune -user "$my_uid" -print 2>/dev/null)" ]
}
if [ "$was_marked" -eq 1 ]; then
  for stale in "$INSTALL_DIR"/.acq-previous.*; do
    pid_alive "${stale##*/.acq-previous.}" && continue
    [ -d "$stale" ] && [ ! -L "$stale" ] && owned_by_me "$stale" && rm -rf "$stale" 2>/dev/null || :
  done
  for stale in "$install_parent"/.acq-stage.*.* "$INSTALL_DIR"/.acq-stage.*.*; do
    [ "$stale" != "$stage_root" ] || continue
    stale_pid="${stale##*/.acq-stage.}"
    stale_pid="${stale_pid%%.*}"
    case "$stale_pid" in ''|*[!0-9]*) continue ;; esac
    pid_alive "$stale_pid" && continue
    [ -d "$stale" ] && [ ! -L "$stale" ] && owned_by_me "$stale" && rm -rf "$stale" 2>/dev/null || :
  done
  for stale in "$marker".tmp.*; do
    case "${stale#"$marker".tmp.}" in ''|*[!0-9]*) continue ;; esac
    pid_alive "${stale#"$marker".tmp.}" && continue
    [ -f "$stale" ] && [ ! -L "$stale" ] && owned_by_me "$stale" && rm -f "$stale" 2>/dev/null || :
  done
fi

previous="$INSTALL_DIR/.acq-previous.$$"
mkdir "$previous" || die "could not create $previous"
for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
  { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
  name="${entry##*/}"
  if [ -e "$INSTALL_DIR/$name" ] || [ -L "$INSTALL_DIR/$name" ]; then
    mv "$INSTALL_DIR/$name" "$previous/$name" || die "could not move aside $INSTALL_DIR/$name; re-run the installer to finish"
  fi
  mv "$entry" "$INSTALL_DIR/$name" || die "could not install $name; re-run the installer to finish"
done
# Only owned entries were moved into $previous, so removing it is safe.
rm -rf "$previous"

# ---------------------------------------------------------------------------
# Link the launcher onto PATH.
# ---------------------------------------------------------------------------

step "Linking the acq launcher"

run mkdir -p "$BIN_DIR"
run ln -sf "$INSTALL_DIR/acq" "$BIN_DIR/acq"
run ln -sf "$INSTALL_DIR/acq-python" "$BIN_DIR/acq-python"
ok "  linked $BIN_DIR/acq -> $INSTALL_DIR/acq"
ok "  linked $BIN_DIR/acq-python -> $INSTALL_DIR/acq-python"

# ---------------------------------------------------------------------------
# PATH handling — never modified without consent.
# ---------------------------------------------------------------------------

if path_has_bindir; then
  ok "  $BIN_DIR is already on your PATH."
else
  NEED_PATH_HELP=1
  rc_file="$(rc_file_for_shell)"
  path_line="export PATH=\"$BIN_DIR:\$PATH\""
  step "Your PATH does not include $BIN_DIR"
  info "  To type 'acq' from anywhere, that directory needs to be on your PATH."
  if confirm "  Add it to $rc_file for you?"; then
    if [ -f "$rc_file" ] && grep -qF "$path_line" "$rc_file" 2>/dev/null; then
      ok "  $rc_file already contains the PATH line — leaving it as-is."
    else
      {
        printf '\n# Added by acq install.sh — put acq on PATH\n'
        printf '%s\n' "$path_line"
      } >> "$rc_file"
      ok "  Added the line to $rc_file."
    fi
    info "  Open a new terminal (or run: source \"$rc_file\") to pick it up."
  else
    warn "  Not changing your PATH. To do it yourself, add this line to $rc_file:"
    printf '\n    %s\n\n' "$path_line"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

[ "$NO_PREREQ_CHECK" -eq 1 ] || report_prerequisites

step "Done"
if [ "$NEED_PATH_HELP" -eq 1 ]; then
  info "Once $BIN_DIR is on your PATH, try:  ${B}acq version${R}"
  info "Or run it directly right now:        ${B}$BIN_DIR/acq version${R}"
else
  info "Try it now:  ${B}acq version${R}"
fi
