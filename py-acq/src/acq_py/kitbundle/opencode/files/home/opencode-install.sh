#!/bin/sh
# opencode-install.sh — install the pinned OpenCode CLI binary into the sandbox.
#
# Runs at CREATE time as ROOT (install phase). Detects the guest architecture,
# fetches the matching pinned OpenCode v2 platform tarball from npm's registry,
# verifies its sha256, extracts the single `opencode` binary, and installs it
# on PATH for every user. FAIL-CLOSED on integrity, FAIL-SOFT on availability:
# any download/network/extraction failure degrades to "opencode absent, agent
# unavailable this boot" (never a dead sandbox, matching the kit-library
# convention — see openchamber-start.sh and pi-coding-agent-install.sh), but a
# SHA-256 MISMATCH refuses to install the mismatched bytes and does NOT fall
# back to any other install path. There is no unpinned fallback for this kit
# to fall back to — see docs/decisions/fail-closed-on-integrity.md for why that
# matters here specifically, unlike the optional-capability kits in this
# family.
#
# WHY create-time (install phase): OpenCode v2's CLI wrapper package
# (@opencode/cli) uses a postinstall script to select and copy an optional
# architecture-specific binary package. To keep installation deterministic and
# non-interactive, this kit skips that lifecycle script entirely and downloads
# the pinned platform package tarball directly from npm. The tarball already
# contains the real binary, so the create-time install is still plain
# curl+verify+extract with no native build or toolchain.
#
# ARCHITECTURE: microVM/container guests are aarch64 on Apple Silicon hosts and
# x86-64 on amd64 hosts (same lesson as the goose-server and mcp-gateway kits).
# Installing a fixed x64 binary on an aarch64 guest fails at runtime with "Exec
# format error", so we SELECT the package by `uname -m`. OpenCode v2's Linux
# platform packages are named `@opencode/cli-linux-<arch>` where <arch> is x64
# or arm64, with a baseline x64 package for hosts without AVX2.
#
# INTEGRITY: npm package tarballs are immutable artifacts for a published
# version, so we pin each ARCHIVE's sha256 directly and verify before
# extracting. Pins arrive via the environment ONLY — this script has NO literal
# fallback values (unlike pi-coding-agent-install.sh's
# ${PI_CODING_AGENT_VERSION:-0.84.3} pattern): the kit's spec.yaml install
# command is the single source of truth for these values, and an unset
# value fails soft to "agent absent" below rather than installing anything
# unpinned. A literal fallback here would be a second copy of the pin that
# could silently drift from spec.yaml's — deliberately not duplicated.
#   OPENCODE_VERSION                    — npm package version, e.g. 2.0.22 (NOT "latest")
#   OPENCODE_SHA256_LINUX_X64            — sha256 of cli-linux-x64-<version>.tgz
#   OPENCODE_SHA256_LINUX_X64_BASELINE   — sha256 of cli-linux-x64-baseline-<version>.tgz
#   OPENCODE_SHA256_LINUX_ARM64          — sha256 of cli-linux-arm64-<version>.tgz
# To bump: change the version + hashes in spec.yaml's install command,
# re-verify against the real npm tarballs (download + `shasum -a 256`, not
# copied from any third party).
#
# WHY WE DO NOT USE THE opencode.ai/install SCRIPT: that script resolves
# "latest" by default (an explicit --version flag is required to pin at all),
# downloads via a redirect chain this script instead resolves and allow-lists
# explicitly, and is designed for interactive/CI use, not a non-interactive,
# SHA-pinned create-time install. For v2, we fetch the same underlying platform
# package tarball that @opencode/cli's postinstall would select, with our own
# pin and verification.

set -u

# NON-INTERACTIVE: no terminal at create time.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

ver_raw="${OPENCODE_VERSION:-}"
ver="${ver_raw#v}"
sha_x64="${OPENCODE_SHA256_LINUX_X64:-}"
sha_x64_baseline="${OPENCODE_SHA256_LINUX_X64_BASELINE:-}"
sha_arm64="${OPENCODE_SHA256_LINUX_ARM64:-}"
# Install into a system PATH dir (root at create time). /usr/local/bin is on
# PATH for every user in the base image (same destination as the goose-server
# and openchamber kits' root-installed binaries).
dest_dir="/usr/local/bin"
dest_path="$dest_dir/opencode"

warn() { echo "opencode-kit(install): $*" >&2; }

remove_existing_non_pinned() {
  # If anything else is present at this kit-owned path, remove it before any
  # degraded exit. Otherwise a failed v2 upgrade could leave a stale v1 binary
  # runnable and satisfy the sandbox readiness gate incorrectly.
  if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
    if rm -f "$dest_path" 2>/dev/null; then
      echo "opencode-kit(install): removed existing non-pinned opencode at $dest_path before replacement."
    else
      warn "SECURITY: could not remove existing non-pinned opencode at $dest_path; refusing to continue with a stale binary present."
      exit 1
    fi
  fi
}

# A pinned version + hashes are REQUIRED. Without them we cannot install a
# verified binary; degrade to "agent absent" (non-fatal — see header) rather
# than fetch an unpinned/unverified artifact. This is the SAME non-fatal exit
# as every other failure path below (missing pin is an availability failure,
# not an integrity failure — there is nothing yet to mismatch).
if [ -z "$ver_raw" ]; then
  warn "OPENCODE_VERSION not set; refusing to install an unpinned opencode. (non-fatal)"
  remove_existing_non_pinned
  exit 0
fi

# Defensive format check on the version pin, mirroring pi-coding-agent's own
# guard: refuse anything outside a safe version-string charset before it ever
# reaches a URL or argv, rather than relying solely on the tag existing.
case "$ver" in
  [0-9]*.[0-9]*.[0-9]*)
    case "$ver" in
      *[!0-9A-Za-z.-]*)
        warn "OPENCODE_VERSION='$ver_raw' contains characters outside [0-9A-Za-z.-]; refusing to install"
        remove_existing_non_pinned
        exit 0
        ;;
    esac
    ;;
  *)
    warn "OPENCODE_VERSION='$ver_raw' doesn't look like a version (want X.Y.Z or vX.Y.Z); refusing to install"
    remove_existing_non_pinned
    exit 0
    ;;
esac

# Idempotency: if the pinned opencode is already installed AND executes, do
# nothing. Checks the FIXED destination path directly ($dest_dir/opencode),
# NOT whatever `opencode` first resolves to on PATH — a PATH lookup here would
# trust an attacker- or another-kit-controlled binary earlier on PATH as if it
# were this kit's own verified install, silently skipping this run's integrity
# gate entirely. Also rejects a symlink at that path for the same reason the
# post-extraction check below does (SECURITY, not just availability): a
# symlink masquerading at the destination path would have its target's
# `--version` output trusted as this kit's own.
if [ -f "$dest_path" ] && [ ! -L "$dest_path" ] && [ -x "$dest_path" ]; then
  installed_ver="$("$dest_path" --version 2>/dev/null || true)"
  installed_ver="${installed_ver##* }"
  installed_ver="${installed_ver#v}"
  if [ -n "$installed_ver" ] && [ "$installed_ver" = "$ver" ]; then
    echo "opencode-kit(install): opencode $ver already installed and runnable at $dest_path; skipping."
    exit 0
  fi
fi
remove_existing_non_pinned

supports_avx2() {
  [ -r /proc/cpuinfo ] && grep -qi ' avx2 ' /proc/cpuinfo
}

# Map the guest architecture to OpenCode's npm platform-package arch token +
# pick its pinned hash.
uname_m="$(uname -m 2>/dev/null || echo unknown)"
case "$uname_m" in
  x86_64|amd64)
    if supports_avx2; then
      oc_arch="x64"
      sha="$sha_x64"
    else
      oc_arch="x64-baseline"
      sha="$sha_x64_baseline"
    fi
    ;;
  aarch64|arm64)  oc_arch="arm64"; sha="$sha_arm64" ;;
  *)
    warn "unsupported guest architecture '$uname_m' (need x86_64/amd64 or aarch64/arm64)."
    warn "  opencode not installed (non-fatal)."
    exit 0
    ;;
esac

if [ -z "$sha" ]; then
  warn "no pinned sha256 for arch '$oc_arch'; refusing to install unverified. (non-fatal)"
  exit 0
fi

pkg="cli-linux-${oc_arch}"
asset="${pkg}-${ver}.tgz"
url="https://registry.npmjs.org/@opencode/${pkg}/-/${asset}"

if ! command -v curl >/dev/null 2>&1; then
  warn "curl not found in base image; cannot download opencode. Skipping (non-fatal)."
  exit 0
fi

if ! work_dir="$(mktemp -d "${TMPDIR:-/tmp}/opencode-install.XXXXXX" 2>/dev/null)"; then
  warn "could not create a private temporary directory; cannot download opencode safely. Skipping (non-fatal)."
  exit 0
fi
cleanup() { rm -rf "$work_dir" 2>/dev/null || true; }
trap cleanup EXIT

archive="$work_dir/$asset"

# Bounded fetch: explicit connect/overall timeouts so a hung registry/CDN
# response cannot stall sandbox creation indefinitely (mirrors the bounded-
# fetch convention documented in ADR 0004's models-orchestrator design).
if ! curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$archive" 2>"$work_dir/curl.log"; then
  warn "download failed for $url (non-fatal; opencode will be absent this boot)"
  [ -s "$work_dir/curl.log" ] && sed 's/^/opencode-kit(install):   /' "$work_dir/curl.log" >&2
  exit 0
fi

# --- INTEGRITY GATE: verify BEFORE extracting. FAIL CLOSED on mismatch. -----
got_sha="$( (sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive" 2>/dev/null) | cut -d' ' -f1)"
if [ -z "$got_sha" ]; then
  warn "could not compute a sha256 for the downloaded archive (no sha256sum/shasum?); refusing to install unverified. (non-fatal)"
  exit 0
fi
if [ "$got_sha" != "$sha" ]; then
  # SECURITY: this is the one failure path that is NOT just "optional feature
  # unavailable" — a mismatched archive is either corruption or tampering, and
  # this kit deliberately has no unpinned fallback install path to degrade to
  # (contrast the quickstart-side readiness gate this kit satisfies, whose
  # OWN fallback — the unpinned `npm install -g opencode-ai` — is exactly what
  # this kit exists to retire). Refuse to extract or install the mismatched
  # bytes. Still exit 0: a bad download must not crash sandbox *creation*
  # (the agent is simply absent this boot, loudly, in the log), but it must
  # never silently proceed past this gate.
  warn "SECURITY: sha256 mismatch for $asset (got $got_sha, want $sha) at $ver;"
  warn "  refusing to install. opencode will be ABSENT this boot — this is a"
  warn "  fail-closed integrity refusal, not a transient-failure degrade."
  exit 0
fi
echo "opencode-kit(install): sha256 verified for $asset ($ver) from $url"

member="package/bin/opencode"
member_listing="$(tar -tvzf "$archive" "$member" 2>"$work_dir/tar-list.log" || true)"
if [ -z "$member_listing" ]; then
  warn "SECURITY: archive does not list a '$member' member;"
  warn "  refusing to install. This is a fail-closed integrity refusal, not a"
  warn "  transient-failure degrade — see docs/decisions/fail-closed-on-integrity.md."
  [ -s "$work_dir/tar-list.log" ] && sed 's/^/opencode-kit(install):   /' "$work_dir/tar-list.log" >&2
  exit 0
fi
bad_member=""
member_count=0
old_ifs="$IFS"
IFS='
'
for member_line in $member_listing; do
  member_count=$((member_count + 1))
  case "$member_line" in
    -*) ;;
    *)
      bad_member="$member_line"
      break
      ;;
  esac
done
IFS="$old_ifs"
if [ -n "$bad_member" ]; then
  warn "SECURITY: archive member '$member' is not a regular file;"
  warn "  refusing to install. This is a fail-closed integrity refusal, not a"
  warn "  transient-failure degrade — see docs/decisions/fail-closed-on-integrity.md."
  warn "  tar listing: $bad_member"
  [ -s "$work_dir/tar-list.log" ] && sed 's/^/opencode-kit(install):   /' "$work_dir/tar-list.log" >&2
  exit 0
fi
if [ "$member_count" -ne 1 ]; then
  warn "SECURITY: archive lists $member_count '$member' members; expected exactly one;"
  warn "  refusing to install. This is a fail-closed integrity refusal, not a"
  warn "  transient-failure degrade — see docs/decisions/fail-closed-on-integrity.md."
  exit 0
fi

if ! tar -xzf "$archive" -C "$work_dir" "$member" 2>"$work_dir/tar.log"; then
  warn "extraction failed (non-fatal; opencode will be absent this boot)"
  [ -s "$work_dir/tar.log" ] && sed 's/^/opencode-kit(install):   /' "$work_dir/tar.log" >&2
  exit 0
fi

extracted="$work_dir/$member"
if [ ! -f "$extracted" ]; then
  warn "extracted archive did not contain a '$member' binary; skipping (non-fatal)"
  exit 0
fi

# SECURITY: reject a symlink masquerading as the extracted binary. The SHA-256
# gate above only proves the DOWNLOADED ARCHIVE's bytes match the pin; it says
# nothing about what a member named "opencode" inside that archive actually
# IS. `[ -f ]` follows symlinks and reports true for whatever they resolve to,
# so without this check a pinned-but-compromised (or carelessly-cut) release
# whose "opencode" member is a symlink to an arbitrary root-readable path
# (e.g. a host secret) would have that TARGET's content silently copied by
# `install` into a new, world-readable file at $dest_dir/opencode — a real
# root-privileged disclosure primitive this kit must refuse outright, the same
# way it refuses a hash mismatch.
if [ -L "$extracted" ]; then
  warn "SECURITY: extracted '$member' member is a symlink, not a regular file;"
  warn "  refusing to install. This is a fail-closed integrity refusal, not a"
  warn "  transient-failure degrade — see docs/decisions/fail-closed-on-integrity.md."
  exit 0
fi
if [ ! -x "$extracted" ]; then
  warn "extracted '$member' binary is not executable; skipping (non-fatal)"
  exit 0
fi

mkdir -p "$dest_dir" 2>/dev/null || true
if ! install -m 0755 "$extracted" "$dest_path" 2>"$work_dir/install.log"; then
  warn "failed to install binary to $dest_dir (non-fatal; opencode will be absent this boot)"
  [ -s "$work_dir/install.log" ] && sed 's/^/opencode-kit(install):   /' "$work_dir/install.log" >&2
  exit 0
fi

if "$dest_path" --version >/dev/null 2>&1; then
  echo "opencode-kit(install): opencode $ver ($oc_arch) installed and runnable at $dest_path"
else
  warn "opencode installed to $dest_dir but is not runnable (non-fatal; check base image compatibility)"
  rm -f "$dest_path" 2>/dev/null || true
fi
