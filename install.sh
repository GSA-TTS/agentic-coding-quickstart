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
BIN_DIR_FROM="${ACQ_INSTALL_BIN_DIR:+ACQ_INSTALL_BIN_DIR}"
CHANNEL="${ACQ_INSTALL_CHANNEL:-python}"

DRY_RUN=0
ASSUME_YES=0
NEED_PATH_HELP=0
SHA256_PIN=""
SHA256_PIN_GIVEN=0
NO_PREREQ_CHECK=0

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
  --sha256 <digest>    Expected SHA-256 of SHA256SUMS (64 hex characters).
  --no-prereq-check     Skip the post-install sandbox prerequisite report.
  --dry-run             Print what would happen; make no changes, no network.
  --yes, -y             Assume "yes" to the PATH prompt (non-interactive/CI).
  --help                Show this help.
  --version, -V         Show the installer version.

Environment overrides:
  ACQ_INSTALL_VERSION, ACQ_INSTALL_SOURCE, ACQ_INSTALL_DIR, ACQ_INSTALL_BIN_DIR,
  ACQ_INSTALL_CHANNEL, ACQ_INSTALL_NO_ATTESTATION=1 (skip attestation)

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
    --bin-dir) [ $# -ge 2 ] || usage_err "--bin-dir needs a value"; BIN_DIR="$2"; BIN_DIR_FROM="--bin-dir"; shift 2 ;;
    --bin-dir=*) BIN_DIR="${1#--bin-dir=}"; BIN_DIR_FROM="--bin-dir"; shift ;;
    --source) [ $# -ge 2 ] || usage_err "--source needs a value"; SOURCE="$2"; shift 2 ;;
    --source=*) SOURCE="${1#--source=}"; shift ;;
    --ref) [ $# -ge 2 ] || usage_err "--ref needs a value"; VERSION="$2"; shift 2 ;;
    --ref=*) VERSION="${1#--ref=}"; shift ;;
    --channel) [ $# -ge 2 ] || usage_err "--channel needs a value"; CHANNEL="$2"; shift 2 ;;
    --channel=*) CHANNEL="${1#--channel=}"; shift ;;
    --sha256) [ $# -ge 2 ] || usage_err "--sha256 needs a value"; SHA256_PIN="$2"; SHA256_PIN_GIVEN=1; shift 2 ;;
    --sha256=*) SHA256_PIN="${1#--sha256=}"; SHA256_PIN_GIVEN=1; shift ;;
    --no-prereq-check) NO_PREREQ_CHECK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
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
case "$CHANNEL" in
  python) ;;
  *) usage_err "unknown channel '$CHANNEL' (only 'python' is supported on this fork)" ;;
esac

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

KEY="$(platform_key)" || die "unsupported platform '$(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)' (ADR-0042m supports macOS arm64/x86_64 and Linux x86_64/aarch64)"
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
