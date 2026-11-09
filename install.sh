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
#                 [--ref VER] [--dry-run] [--yes] [--help] [--version|-V]

set -eu

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
CHANNEL="${ACQ_INSTALL_CHANNEL:-python}"

DRY_RUN=0
ASSUME_YES=0
NEED_PATH_HELP=0

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
install.sh — install acq (agentic-coding-quickstart, Python v1)

It downloads the checksum-verified release archive for this host (the enumerated
offline asset set: readable source + bundled managed CPython runtime + wheelhouse
+ launchers), installs it under your home directory, and links `acq` onto PATH.
Update by re-running this installer against a pinned release.

Options:
  --install-dir <dir>   Where to install (default: $XDG_DATA_HOME/acq or
                        ~/.local/share/acq).
  --bin-dir <dir>       Where to link the `acq` launcher (default: ~/.local/bin).
  --source <url|dir>    Release source. A URL fetches SHA256SUMS, the provenance
                        manifest, and the archive; a local directory (the offline
                        asset set) is read in place.
  --ref <ver>           Release version to install (default: the version baked
                        into this installer).
  --channel <name>      Update channel to install (default: python; the only
                        channel supported on this fork).
  --dry-run             Print what would happen; make no changes, no network.
  --yes, -y             Assume "yes" to the PATH prompt (non-interactive/CI).
  --help                Show this help.
  --version, -V         Show the installer version.

Environment overrides:
  ACQ_INSTALL_VERSION, ACQ_INSTALL_SOURCE, ACQ_INSTALL_DIR, ACQ_INSTALL_BIN_DIR,
  ACQ_INSTALL_CHANNEL

This installer uses no sudo, installs only under your home directory, and never
changes your PATH without asking.
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --install-dir) [ $# -ge 2 ] || usage_err "--install-dir needs a value"; INSTALL_DIR="$2"; INSTALL_DIR_FROM="--install-dir"; shift 2 ;;
    --install-dir=*) INSTALL_DIR="${1#--install-dir=}"; INSTALL_DIR_FROM="--install-dir"; shift ;;
    --bin-dir) [ $# -ge 2 ] || usage_err "--bin-dir needs a value"; BIN_DIR="$2"; shift 2 ;;
    --bin-dir=*) BIN_DIR="${1#--bin-dir=}"; shift ;;
    --source) [ $# -ge 2 ] || usage_err "--source needs a value"; SOURCE="$2"; shift 2 ;;
    --source=*) SOURCE="${1#--source=}"; shift ;;
    --ref) [ $# -ge 2 ] || usage_err "--ref needs a value"; VERSION="$2"; shift 2 ;;
    --ref=*) VERSION="${1#--ref=}"; shift ;;
    --channel) [ $# -ge 2 ] || usage_err "--channel needs a value"; CHANNEL="$2"; shift 2 ;;
    --channel=*) CHANNEL="${1#--channel=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --version|-V) printf 'acq install.sh %s\n' "$VERSION"; exit 0 ;;
    *) usage_err "unknown option: $1 (try --help)" ;;
  esac
done

# The `--channel` flag is the update-channel seam (ADR-0047m). On this fork the
# only channel is `python` (the default), so any other value fails closed.
case "$CHANNEL" in
  python) ;;
  *) usage_err "unknown channel '$CHANNEL' (only 'python' is supported on this fork)" ;;
esac

# The home directory also names the shell rc file the PATH step may edit, so it
# is required even when --install-dir and --bin-dir are given.
if [ -z "$USER_HOME" ]; then
  if [ -n "${HOME+set}" ]; then home_desc="'$HOME'"; else home_desc="unset"; fi
  die "cannot determine an absolute home directory (HOME is $home_desc); set HOME to an absolute path"
fi

# The install directory must be absolute, like acq's other path overrides. The
# launcher symlink points at "$INSTALL_DIR/acq", and a relative symlink target
# resolves against the link's own directory, not the one the installer ran in,
# so a relative value would leave the launcher dangling.
if ! is_abs_path "$INSTALL_DIR"; then
  die "${INSTALL_DIR_FROM:-the install directory} must be an absolute path, got '$INSTALL_DIR'; pass an absolute --install-dir (or unset ACQ_INSTALL_DIR to use the default)"
fi

# ---------------------------------------------------------------------------
# Platform -> release archive name (the enumerated offline asset set, ADR-0042m).
#
# Supported (ADR-0042m §platform matrix): macOS arm64 + x86_64, Linux x86_64 +
# aarch64. Windows x64 is served by install.ps1; Windows ARM64 and musl are out of
# scope. The archive name for each cell is mirrored in installer/assets.json.
# ---------------------------------------------------------------------------

platform_key() {
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64) printf 'macos-arm64\n' ;;
        x86_64) printf 'macos-x86_64\n' ;;
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
    macos-x86_64)   printf 'acq-macos-x86_64.tar.gz\n' ;;
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
sha256_expected() {
  sums="$1" name="$2"
  line="$(grep -F " $name" "$sums" 2>/dev/null | head -n1 || true)"
  [ -n "$line" ] || line="$(grep -F " *$name" "$sums" 2>/dev/null | head -n1 || true)"
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | awk '{print $1}'
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
  # A non-interactive stdin (piped or redirected) declines rather than guessing.
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$prompt"
  read -r ans || return 1
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
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

KEY="$(platform_key)" || die "unsupported platform '$(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)' (ADR-0042m supports macOS arm64/x86_64 and Linux x86_64/aarch64)"
ARCHIVE="$(archive_name "$KEY")" || die "no release archive for platform '$KEY'"

# Resolve the source: a URL (default), or a local directory holding the offline
# asset set (SHA256SUMS + the archive) so an air-gapped host can install.
if [ -z "$SOURCE" ]; then
  SOURCE="${RELEASE_BASE_URL}/v${VERSION}"
fi
case "$SOURCE" in
  http://*|https://*|file://*) SOURCE_IS_URL=1 ;;
  *) SOURCE_IS_URL=0 ;;
esac

info "  platform:    $KEY"
info "  channel:     $CHANNEL"
info "  archive:     $ARCHIVE"
info "  source:      $SOURCE"
info "  install dir: $INSTALL_DIR"
info "  launcher:    $BIN_DIR/acq"
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
    printf '  [dry-run] curl -fsSL %s/%s -o <tmp>/%s\n' "$SOURCE" "$SHA256SUMS_NAME" "$SHA256SUMS_NAME"
    printf '  [dry-run] curl -fsSL %s/%s -o <tmp>/%s\n' "$SOURCE" "$PROVENANCE_NAME" "$PROVENANCE_NAME"
    printf '  [dry-run] curl -fsSL %s/%s -o <tmp>/%s\n' "$SOURCE" "$ARCHIVE" "$ARCHIVE"
  else
    printf '  [dry-run] read %s/%s, %s/%s, and %s/%s from the offline asset set\n' \
      "$SOURCE" "$SHA256SUMS_NAME" "$SOURCE" "$PROVENANCE_NAME" "$SOURCE" "$ARCHIVE"
  fi
  printf '  [dry-run] verify sha256 of %s against %s\n' "$ARCHIVE" "$SHA256SUMS_NAME"
  printf '  [dry-run] extract %s into %s\n' "$ARCHIVE" "$INSTALL_DIR"
  printf '  [dry-run] verify the enumerated set (launcher, runtime, source, wheelhouse) is present\n'
  printf '  [dry-run] link %s/acq -> %s/acq\n' "$BIN_DIR" "$INSTALL_DIR"
  printf '  [dry-run] link %s/acq-python -> %s/acq-python\n' "$BIN_DIR" "$INSTALL_DIR"
  if path_has_bindir; then
    ok "  $BIN_DIR is already on your PATH."
  else
    printf '  [dry-run] offer to add %s to your PATH (consent required)\n' "$BIN_DIR"
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
tmpdir=""
trap 'rm -rf "$tmpdir"' EXIT
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
  curl -fsSL "$SOURCE/$SHA256SUMS_NAME" -o "$tmpdir/$SHA256SUMS_NAME" \
    || die "could not download $SOURCE/$SHA256SUMS_NAME"
  curl -fsSL "$SOURCE/$PROVENANCE_NAME" -o "$tmpdir/$PROVENANCE_NAME" \
    || die "could not download $SOURCE/$PROVENANCE_NAME"
  curl -fsSL "$SOURCE/$ARCHIVE" -o "$tmpdir/$ARCHIVE" \
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

# The provenance manifest travels alongside SHA256SUMS and is part of the
# enumerated offline asset set; its absence is a fail-closed gate.
[ -f "$tmpdir/$PROVENANCE_NAME" ] || die "release is missing the provenance manifest ($PROVENANCE_NAME)"

# ---------------------------------------------------------------------------
# Extract into a staging directory, then publish atomically (update-by-reinstall).
# ---------------------------------------------------------------------------

step "Installing into $INSTALL_DIR"

command -v tar >/dev/null 2>&1 || die "tar is required to extract the release archive"

staging="$tmpdir/stage"
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

# Strip trailing slashes so `[ -L ]` tests the link itself, not its target.
while :; do
  case "$INSTALL_DIR" in
    */) [ "$INSTALL_DIR" = / ] && break; INSTALL_DIR="${INSTALL_DIR%/}" ;;
    *) break ;;
  esac
done
if [ -L "$INSTALL_DIR" ]; then
  die "$INSTALL_DIR is a symlink; refusing to install through it (pass --install-dir with a real directory)"
fi
if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
  die "$INSTALL_DIR exists and is not a directory; move it aside or pass --install-dir"
fi
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
# still ours to replace later.
{
  printf '%s\n' "$VERSION"
  { [ -f "$marker" ] && tail -n +2 "$marker"; } || :
  for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
    { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
    printf '%s\n' "${entry##*/}"
  done
} | awk 'NR == 1 || !seen[$0]++' > "$marker.tmp.$$"
mv "$marker.tmp.$$" "$marker" || die "could not write $marker"

# Move-aside dirs from an earlier failed run hold only replaced acq files, but
# only trust that in a directory that was already marked before this run.
if [ "$was_marked" -eq 1 ]; then
  for stale in "$INSTALL_DIR"/.acq-previous.*; do
    [ -d "$stale" ] && [ ! -L "$stale" ] && rm -rf "$stale"
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

step "Done"
if [ "$NEED_PATH_HELP" -eq 1 ]; then
  info "Once $BIN_DIR is on your PATH, try:  ${B}acq version${R}"
  info "Or run it directly right now:        ${B}$BIN_DIR/acq version${R}"
else
  info "Try it now:  ${B}acq version${R}"
fi
