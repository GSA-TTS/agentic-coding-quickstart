#!/usr/bin/env bats

load './helper.bash'

setup() {
  acq_setup_stubs
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$STUBDIR/bin"
  export PATH="$STUBDIR/bin:$PATH"
  export ACQ_INSTALL_CLONE_DIR="$BATS_TEST_TMPDIR/acq-clone"
  export ACQ_INSTALL_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  # Derive the expected default version from install.sh itself rather than
  # hardcoding it here: release-please bumps DEFAULT_RELEASE_VERSION on every
  # release (the x-release-please-version annotation), and a hardcoded
  # assertion in this file would silently go stale on the next release with
  # no test catching it -- exactly what happened (v2.0.0 -> v3.0.0).
  DEFAULT_VERSION_TAG="v$(sed -n 's/^DEFAULT_RELEASE_VERSION="\([^"]*\)".*/\1/p' "$REPO_ROOT/install.sh")"
}

teardown() {
  acq_teardown_stubs
}

_write_git_stub() {
  cat >"$STUBDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
set -eu
log=${GIT_STUB_LOG:?}
printf '%s\n' "$*" >>"$log"

case "$1" in
  --version)
    printf 'git version 2.40.0\n'
    ;;
  clone)
    # shellcheck disable=SC2124
    dest=${@: -1}
    mkdir -p "$dest/.git"
    printf '#!/bin/sh\n' >"$dest/acq"
    chmod +x "$dest/acq"
    ;;
  -C)
    repo=$2
    shift 2
    case "$1" in
      checkout)
        mkdir -p "$repo/.git"
        if [ "${GIT_STUB_FAIL_FIRST_CHECKOUT_SHA:-}" = "$2" ] \
           && [ ! -e "$repo/.git/checkout-failed-once" ]; then
          : >"$repo/.git/checkout-failed-once"
          exit 1
        fi
        printf '%s\n' "$2" >"$repo/.git/head"
        ;;
      rev-parse)
        cat "$repo/.git/head"
        ;;
      fetch|pull|symbolic-ref)
        ;;
      *)
        printf 'unexpected git -C command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'unexpected git command: %s\n' "$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$STUBDIR/bin/git"
}

_write_brew_stub() {
  cat >"$STUBDIR/bin/brew" <<'STUB'
#!/usr/bin/env sh
exit 0
STUB
  chmod +x "$STUBDIR/bin/brew"
}

# Logs each brew invocation's argv (one per line) so tests can assert ordering.
_write_brew_logging_stub() {
  cat >"$STUBDIR/bin/brew" <<'STUB'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"${BREW_STUB_LOG:?}"
exit 0
STUB
  chmod +x "$STUBDIR/bin/brew"
}

# Records one stdin line; empty marker `ate:[]` proves run() detached child stdin.
_write_stdin_eating_brew_stub() {
  cat >"$STUBDIR/bin/brew" <<'STUB'
#!/usr/bin/env bash
line=""
IFS= read -r line || true
printf 'ate:[%s]\n' "$line" >>"${BREW_STUB_LOG:?}"
exit 0
STUB
  chmod +x "$STUBDIR/bin/brew"
}

_write_npm_stub() {
  cat >"$STUBDIR/bin/npm" <<'STUB'
#!/usr/bin/env sh
case "$1" in
  prefix) printf '/tmp/npm-global\n' ;;
esac
exit 0
STUB
  chmod +x "$STUBDIR/bin/npm"
}

_write_msb_stub() { # PATH VERSION
  mkdir -p "$(dirname "$1")"
  printf '%s\n' \
    '#!/usr/bin/env sh' \
    'case "$1" in' \
    "  --version|-V) printf 'msb %s\\n' '$2' ;;" \
    '  *) exit 0 ;;' \
    'esac' >"$1"
  chmod +x "$1"
}

# Release bundle basename for this host — mirrors msb_bundle_name() in install.sh.
# Deriving it (rather than hardcoding one platform's name) keeps these tests
# meaningful on both linux-* and darwin-aarch64 runners.
_msb_bundle_name() {
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64)  arch=x86_64 ;;
    *) return 1 ;;
  esac
  case "$(uname -s)" in
    Darwin) [ "$arch" = aarch64 ] || return 1; printf 'microsandbox-darwin-aarch64.tar.gz' ;;
    Linux)  printf 'microsandbox-linux-%s.tar.gz' "$arch" ;;
    *) return 1 ;;
  esac
}

# Build a stand-in release bundle plus a matching checksums.sha256, with the same
# shape install_msb_pinned_tarball parses: an `msb` binary and exactly one
# versioned libkrunfw whose name carries the ABI. The library filename differs by
# platform on purpose -- install.sh derives the ABI from the artifact rather than
# hardcoding a version (upstream's own formula had that bug), so the fixture has
# to exercise the real name shape.
#
# Echoes the directory holding <bundle> and checksums.sha256.
_make_msb_bundle_fixture() { # VERSION
  local version="$1" bundle dir libname
  bundle=$(_msb_bundle_name) || return 1
  dir="$BATS_TEST_TMPDIR/msb-release"
  mkdir -p "$dir/stage"

  printf '%s\n' \
    '#!/usr/bin/env sh' \
    'case "$1" in' \
    "  --version|-V) printf 'msb %s\\n' '$version' ;;" \
    '  *) exit 0 ;;' \
    'esac' >"$dir/stage/msb"
  chmod +x "$dir/stage/msb"

  case "$(uname -s)" in
    Darwin) libname="libkrunfw.5.dylib" ;;
    *)      libname="libkrunfw.so.5.6.1" ;;
  esac
  printf 'not-a-real-library\n' >"$dir/stage/$libname"

  ( cd "$dir/stage" && tar -czf "../$bundle" msb "$libname" ) || return 1

  # Same two-space format as the real published checksums.sha256.
  ( cd "$dir" && printf '%s  %s\n' "$(_sha256_of "$bundle")" "$bundle" >checksums.sha256 )
  printf '%s' "$dir"
}

_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# curl stub serving the pinned release bundle and its checksums from a local
# fixture. Anything else is a hard error, so a test cannot pass by accident if
# install.sh starts fetching a different URL -- which is exactly how the removed
# upstream-installer path would have slipped through.
_write_curl_msb_bundle_stub() { # FIXTURE_DIR
  cat >"$STUBDIR/bin/curl" <<STUB
#!/usr/bin/env sh
fixture='$1'
STUB
  cat >>"$STUBDIR/bin/curl" <<'STUB'
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out=$arg; fi
  prev=$arg
done
[ -n "$out" ] || { printf 'curl stub: no -o in: %s\n' "$*" >&2; exit 1; }

case "$*" in
  *releases/download/v0.6.18/checksums.sha256*)
    cp "$fixture/checksums.sha256" "$out" ;;
  *releases/download/v0.6.18/microsandbox-*.tar.gz*)
    cp "$fixture"/microsandbox-*.tar.gz "$out" ;;
  *)
    printf 'curl stub: unexpected URL: %s\n' "$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$STUBDIR/bin/curl"
}

# curl stub that fails the msb bundle download (simulates a network/HTTP error),
# to exercise the "download failed -> Skipping msb, acq still installs" degrade.
_write_curl_msb_download_failure_stub() {
  cat >"$STUBDIR/bin/curl" <<'STUB'
#!/usr/bin/env sh
case "$*" in
  *releases/download/*) exit 22 ;;   # curl's HTTP-error exit code
esac
# Anything else this run needs (there is nothing) would pass through as success.
exit 0
STUB
  chmod +x "$STUBDIR/bin/curl"
}

_write_unparseable_msb_stub() { # PATH
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '#!/usr/bin/env sh' 'printf "msb dev-build\\n"' >"$1"
  chmod +x "$1"
}

# PATH for the pinned-bundle install path: coreutils plus the tools
# install_msb_pinned_tarball actually shells out to. _acq_coreutils_path covers
# only the tools the shared helper needs, and a missing `tar` here would make the
# install bail with "tar is required" -- a pass that proved nothing.
_msb_pin_tools_path() {
  local extra="" d t
  for t in tar install ln cp basename uname sha256sum shasum; do
    d=$(command -v "$t" 2>/dev/null) || continue
    case "$d" in /*) ;; *) continue ;; esac
    d=$(dirname "$d")
    case ":$extra:" in *":$d:"*) continue ;; esac
    extra="${extra:+$extra:}$d"
  done
  printf '%s' "$(_acq_coreutils_path)${extra:+:$extra}"
}

_no_package_manager_path() {
  core_bin="$BATS_TEST_TMPDIR/core-bin"
  mkdir -p "$core_bin"
  for tool in bash cat chmod curl dirname env grep ln mkdir mv printf rm sed sh uname; do
    tool_path=$(command -v "$tool") || continue
    case "$tool_path" in /*) ln -sf "$tool_path" "$core_bin/$tool" ;; esac
  done
  printf '%s:%s' "$STUBDIR/bin" "$core_bin"
}

@test "install: a failed msb download degrades to Skipping msb, acq still succeeds" {
  # Regression (reviewer finding): verify_active_msb_supported used to run
  # unconditionally after install_msb_pinned, so a FAILED download died in the
  # gate before reaching the "Skipping msb" degrade -- turning a successful acq
  # install into a total-failure exit. The degrade path was unreachable, and no
  # test stubbed a failing curl. This is that test.
  _write_npm_stub
  _write_curl_msb_download_failure_stub

  run env PATH="$ACQ_INSTALL_BIN_DIR:$STUBDIR/bin:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'Skipping msb'
  refute_output --partial 'Active msb is'
  refute_output --partial 'no msb is active on PATH'
  [ ! -e "$ACQ_INSTALL_BIN_DIR/msb" ]
  [ ! -e "$HOME/.microsandbox/bin/msb" ]
}

@test "install: --dry-run succeeds on a host with no msb" {
  # Regression: verify_active_msb_supported did not exempt dry runs, so
  # `--dry-run --yes` on a host with no msb printed every step as OK and then
  # died on the final check -- a false alarm on the exact command a cautious user
  # runs first. Every other dry-run test here passes --no-msb, which is why none
  # of them caught it.
  #
  # Deliberately does NOT stub curl or npm: a dry run must reach the end without
  # fetching anything.
  _write_npm_stub

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --dry-run --yes

  assert_success
  assert_output --partial 'Installing msb 0.6.18 from the pinned release bundle'
  assert_output --partial '[dry-run] verify the active msb is a version acq accepts'
  refute_output --partial 'no msb is active on PATH'
  # Nothing may be written in a dry run.
  [ ! -e "$HOME/.microsandbox" ]
  [ ! -e "$ACQ_INSTALL_BIN_DIR/msb" ]
}

@test "install: source default targets release tag without a pinned sha" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub

  run env ACQ_INSTALL_REF= ACQ_INSTALL_SHA= sh "$REPO_ROOT/install.sh" \
    --method clone --no-msb --dry-run --yes

  assert_success
  assert_output --partial "version:   $DEFAULT_VERSION_TAG"
  refute_output --partial 'pinned commit:'
}

@test "install: release asset default sha verifies clone checkout" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub
  release_sha=0123456789abcdef0123456789abcdef01234567
  release_installer="$BATS_TEST_TMPDIR/install-release.sh"
  sed "s/^DEFAULT_RELEASE_SHA=.*/DEFAULT_RELEASE_SHA=\"$release_sha\"/" \
    "$REPO_ROOT/install.sh" >"$release_installer"

  run sh "$release_installer" --method clone --no-msb --yes

  assert_success
  assert_output --partial "version:   $DEFAULT_VERSION_TAG"
  assert_output --partial "pinned commit: $release_sha"
  assert_output --partial "verified HEAD matches pinned commit $release_sha"
}

@test "install: release asset default sha verifies auto clone fallback" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub
  release_sha=0123456789abcdef0123456789abcdef01234567
  release_installer="$BATS_TEST_TMPDIR/install-release.sh"
  sed "s/^DEFAULT_RELEASE_SHA=.*/DEFAULT_RELEASE_SHA=\"$release_sha\"/" \
    "$REPO_ROOT/install.sh" >"$release_installer"

  run env PATH="$(_no_package_manager_path)" \
    sh "$release_installer" --no-msb --yes

  assert_success
  assert_output --partial "install method: clone (auto-selected)"
  assert_output --partial "version:   $DEFAULT_VERSION_TAG"
  assert_output --partial "pinned commit: $release_sha"
  assert_output --partial "verified HEAD matches pinned commit $release_sha"
}

@test "install: release asset default sha does not override auto brew" {
  _write_brew_stub
  release_sha=0123456789abcdef0123456789abcdef01234567
  release_installer="$BATS_TEST_TMPDIR/install-release.sh"
  sed "s/^DEFAULT_RELEASE_SHA=.*/DEFAULT_RELEASE_SHA=\"$release_sha\"/" \
    "$REPO_ROOT/install.sh" >"$release_installer"

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$release_installer" --no-msb --dry-run --yes

  assert_success
  assert_output --partial "install method: brew (auto-selected)"
  assert_output --partial "version:   Homebrew formula"
  refute_output --partial "pinned commit: $release_sha"
}

@test "install: release asset default sha does not override auto npm" {
  _write_npm_stub
  release_sha=0123456789abcdef0123456789abcdef01234567
  release_installer="$BATS_TEST_TMPDIR/install-release.sh"
  sed "s/^DEFAULT_RELEASE_SHA=.*/DEFAULT_RELEASE_SHA=\"$release_sha\"/" \
    "$REPO_ROOT/install.sh" >"$release_installer"

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$release_installer" --no-msb --dry-run --yes

  assert_success
  assert_output --partial "install method: npm (auto-selected)"
  assert_output --partial "version:   $DEFAULT_VERSION_TAG"
  refute_output --partial "pinned commit: $release_sha"
}

@test "install: explicit sha overrides auto package manager selection" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub
  _write_brew_stub
  explicit_sha=abcdef0123456789abcdef0123456789abcdef01

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --no-msb --yes --sha "$explicit_sha"

  assert_success
  assert_output --partial "install method: clone (auto-selected)"
  assert_output --partial "pinned commit: $explicit_sha"
  assert_output --partial "verified HEAD matches pinned commit $explicit_sha"
}

@test "install: explicit ref ignores release asset default sha" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub
  release_sha=0123456789abcdef0123456789abcdef01234567
  release_installer="$BATS_TEST_TMPDIR/install-release.sh"
  sed "s/^DEFAULT_RELEASE_SHA=.*/DEFAULT_RELEASE_SHA=\"$release_sha\"/" \
    "$REPO_ROOT/install.sh" >"$release_installer"

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$release_installer" --method clone --ref main --no-msb --dry-run --yes

  assert_success
  assert_output --partial "version:   main"
  refute_output --partial "pinned commit:"
  refute_output --partial "git checkout $release_sha"
}

@test "install: explicit ref ignores malformed release asset default sha" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub
  release_installer="$BATS_TEST_TMPDIR/install-release.sh"
  sed 's/^DEFAULT_RELEASE_SHA=.*/DEFAULT_RELEASE_SHA="not-a-valid-sha"/' \
    "$REPO_ROOT/install.sh" >"$release_installer"

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$release_installer" --method clone --ref main --no-msb --dry-run --yes

  assert_success
  assert_output --partial "version:   main"
  refute_output --partial "invalid --sha"
  refute_output --partial "pinned commit:"
}

@test "install: explicit ref and explicit sha keep the explicit sha" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub
  release_sha=0123456789abcdef0123456789abcdef01234567
  explicit_sha=abcdef0123456789abcdef0123456789abcdef01
  release_installer="$BATS_TEST_TMPDIR/install-release.sh"
  sed "s/^DEFAULT_RELEASE_SHA=.*/DEFAULT_RELEASE_SHA=\"$release_sha\"/" \
    "$REPO_ROOT/install.sh" >"$release_installer"

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$release_installer" --method clone --ref main --no-msb --yes \
      --sha "$explicit_sha"

  assert_success
  assert_output --partial "version:   main"
  assert_output --partial "pinned commit: $explicit_sha"
  refute_output --partial "pinned commit: $release_sha"
  assert_output --partial "verified HEAD matches pinned commit $explicit_sha"
}

@test "install: empty sha environment variable is treated as unset" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub

  run env ACQ_INSTALL_REF= ACQ_INSTALL_SHA= sh "$REPO_ROOT/install.sh" \
    --method clone --no-msb --dry-run --yes

  assert_success
  assert_output --partial "version:   $DEFAULT_VERSION_TAG"
  refute_output --partial "invalid --sha"
  refute_output --partial "pinned commit:"
}

@test "install: explicit empty sha flag is rejected" {
  run sh "$REPO_ROOT/install.sh" --no-msb --dry-run --yes --sha=

  assert_failure
  assert_output --partial "invalid --sha '' (expected a 40-char hex commit id)"
}

@test "install: existing shallow clone deepens before failing pinned sha" {
  export GIT_STUB_LOG="$BATS_TEST_TMPDIR/git.log"
  _write_git_stub
  mkdir -p "$ACQ_INSTALL_CLONE_DIR/.git"
  printf '#!/bin/sh\n' >"$ACQ_INSTALL_CLONE_DIR/acq"
  chmod +x "$ACQ_INSTALL_CLONE_DIR/acq"
  release_sha=abcdef0123456789abcdef0123456789abcdef01

  run env GIT_STUB_FAIL_FIRST_CHECKOUT_SHA="$release_sha" \
    sh "$REPO_ROOT/install.sh" --method clone --no-msb --yes --sha "$release_sha"

  assert_success
  assert_output --partial "verified HEAD matches pinned commit $release_sha"
  assert_regex "$(cat "$GIT_STUB_LOG")" "fetch --unshallow --tags origin"
}

@test "install: missing msb installs the pinned 0.6.18 release bundle" {
  _write_npm_stub
  fixture=$(_make_msb_bundle_fixture 0.6.18) || skip "no msb bundle name for $(uname -s)/$(uname -m)"
  _write_curl_msb_bundle_stub "$fixture"

  run env PATH="$ACQ_INSTALL_BIN_DIR:$STUBDIR/bin:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'Installing msb 0.6.18 from the pinned release bundle'
  assert_output --partial 'releases/download/v0.6.18'
  assert_output --partial 'Active msb is 0.6.18'
  # The upstream one-line installer cannot pin a version, so it must not be the
  # thing that placed msb -- not even via a versioned install.sh asset URL, whose
  # per-release copies are byte-identical and still resolve releases/latest.
  refute_output --partial 'install.sh | sh'
  refute_output --partial 'v0.6.18/install.sh'
  run "$ACQ_INSTALL_BIN_DIR/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: pinned bundle install fails closed on a checksum mismatch" {
  _write_npm_stub
  fixture=$(_make_msb_bundle_fixture 0.6.18) || skip "no msb bundle name for $(uname -s)/$(uname -m)"
  # Corrupt the artifact AFTER the checksum was recorded: the published checksum
  # stays valid, the bytes do not. This is the tamper/truncation case, and it must
  # not install anything.
  printf 'corrupted\n' >>"$fixture"/microsandbox-*.tar.gz
  _write_curl_msb_bundle_stub "$fixture"

  run env PATH="$ACQ_INSTALL_BIN_DIR:$STUBDIR/bin:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  # acq still installs; only msb is skipped, with the reason stated.
  assert_success
  assert_output --partial 'Checksum mismatch'
  assert_output --partial 'Skipping msb'
  refute_output --partial 'Active msb is'
  [ ! -e "$ACQ_INSTALL_BIN_DIR/msb" ]
  [ ! -e "$HOME/.microsandbox/bin/msb" ]
}

@test "install: pinned bundle install fails closed when the release has no checksum for it" {
  _write_npm_stub
  fixture=$(_make_msb_bundle_fixture 0.6.18) || skip "no msb bundle name for $(uname -s)/$(uname -m)"
  # A checksums.sha256 that covers other assets but not ours. Verification has
  # nothing to compare against, so it must refuse rather than install unverified.
  printf '%s  some-other-asset.tar.gz\n' "$(printf 0 | _sha256_of /dev/stdin)" \
    >"$fixture/checksums.sha256"
  _write_curl_msb_bundle_stub "$fixture"

  run env PATH="$ACQ_INSTALL_BIN_DIR:$STUBDIR/bin:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'No checksum for'
  assert_output --partial 'Skipping msb'
  [ ! -e "$ACQ_INSTALL_BIN_DIR/msb" ]
}

@test "install: active msb 0.6.8 upgrades to the pinned 0.6.18" {
  _write_npm_stub
  fixture=$(_make_msb_bundle_fixture 0.6.18) || skip "no msb bundle name for $(uname -s)/$(uname -m)"
  _write_curl_msb_bundle_stub "$fixture"
  _write_msb_stub "$HOME/.local/bin/msb" 0.6.8

  run env PATH="$ACQ_INSTALL_BIN_DIR:$HOME/.local/bin:$STUBDIR/bin:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'active msb version is too old'
  assert_output --partial 'Installing msb 0.6.18 from the pinned release bundle'
  assert_output --partial 'Active msb is 0.6.18'
  run "$ACQ_INSTALL_BIN_DIR/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: unparseable active msb is replaced with the pinned version" {
  _write_npm_stub
  fixture=$(_make_msb_bundle_fixture 0.6.18) || skip "no msb bundle name for $(uname -s)/$(uname -m)"
  _write_curl_msb_bundle_stub "$fixture"
  _write_unparseable_msb_stub "$HOME/.local/bin/msb"

  run env PATH="$ACQ_INSTALL_BIN_DIR:$HOME/.local/bin:$STUBDIR/bin:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'active msb version could not be determined'
  assert_output --partial 'Active msb is 0.6.18'
  run "$ACQ_INSTALL_BIN_DIR/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: never fetches and executes an msb installer script" {
  # The removed upstream-installer path fetched msb's install.sh and ran it.
  # Nothing may reintroduce that: a remote script cannot be pinned (upstream's
  # per-release install.sh assets are byte-identical and resolve releases/latest at
  # run time), so running one places an unverifiable version.
  #
  # Asserted over CODE only. install.sh deliberately *names* the unpinnable
  # one-liner in its guidance text ("Do NOT use ... | sh"), and acq's own
  # `curl | sh` bootstrap is documented in the header -- a whole-file regex would
  # match that prose and prove nothing. Strip comments and the output helpers that
  # print guidance, then assert on what is left.
  code=$(grep -vE '^[[:space:]]*#' "$REPO_ROOT/install.sh" \
         | grep -vE '^[[:space:]]*(info|warn|step|ok|printf)[[:space:]]')

  # No fetched artifact is handed to a shell.
  refute_regex "$code" '\|[[:space:]]*(sh|bash)([[:space:]]|$)'
  refute_regex "$code" '(sh|bash)[[:space:]]+"?\$\{?tmp'
  # The only msb release assets fetched are the bundle and its checksum file.
  refute_regex "$code" 'curl[^\n]*install\.sh'
  refute_regex "$code" 'curl[^\n]*install\.microsandbox\.dev'
  assert_regex "$code" 'curl -fsSL "\$base/\$bundle"'
  assert_regex "$code" 'curl -fsSL "\$base/checksums\.sha256"'
  # And verification gates the write.
  assert_regex "$code" 'Checksum mismatch'
}

@test "install: active local msb 0.7.2 is replaced by the pinned 0.6.18" {
  _write_npm_stub
  fixture=$(_make_msb_bundle_fixture 0.6.18) || skip "no msb bundle name for $(uname -s)/$(uname -m)"
  _write_curl_msb_bundle_stub "$fixture"
  # A blocked msb whose catalog is NOT ahead (the stub answers `list` cleanly), so
  # there is nothing to recover and the rollback/forward prompts do not apply.
  _write_msb_stub "$HOME/.local/bin/msb" 0.7.2

  run env PATH="$ACQ_INSTALL_BIN_DIR:$HOME/.local/bin:$STUBDIR/bin:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'active msb version is blocked'
  assert_output --partial 'Installing msb 0.6.18 from the pinned release bundle'
  assert_output --partial 'Active msb is 0.6.18'
  run "$ACQ_INSTALL_BIN_DIR/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: blocked msb shadowing the pinned install fails closed" {
  _write_npm_stub
  fixture=$(_make_msb_bundle_fixture 0.6.18) || skip "no msb bundle name for $(uname -s)/$(uname -m)"
  _write_curl_msb_bundle_stub "$fixture"
  # The blocked binary sits EARLIER on PATH than where the pinned install lands,
  # so the install succeeds and is then shadowed. That must be fatal, not a
  # reassuring "installed" message over a host that still runs the blocked msb.
  _write_msb_stub "$STUBDIR/bin/msb" 0.7.2

  run env PATH="$STUBDIR/bin:$ACQ_INSTALL_BIN_DIR:$(_msb_pin_tools_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_failure
  assert_output --partial 'active msb is still blocked version 0.7.2'
  assert_output --partial 'another msb is shadowing it on PATH'
}

@test "install: blocked msb downgrade can be declined" {
  _write_npm_stub
  _write_msb_stub "$STUBDIR/bin/msb" 0.7.1

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh -c 'printf "n\n" | sh "$1" --method npm' _ "$REPO_ROOT/install.sh"

  assert_success
  assert_output --partial 'Found msb 0.7.1'
  assert_output --partial 'Skipping msb'
  refute_output --partial 'msb is already installed'
}

@test "install: duplicate msb paths are reported with active marker" {
  _write_npm_stub
  _write_msb_stub "$STUBDIR/bin/msb" 0.6.18
  mkdir -p "$HOME/.local/bin"
  _write_msb_stub "$HOME/.local/bin/msb" 0.7.2

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'Multiple msb binaries were found'
  assert_output --partial "$STUBDIR/bin/msb: 0.6.18 (active)"
  assert_output --partial "$HOME/.local/bin/msb: 0.7.2"
}

@test "install: run() detaches child stdin so piped script tail survives" {
  export BREW_STUB_LOG="$BATS_TEST_TMPDIR/brew.log"
  _write_stdin_eating_brew_stub

  # Drive the brew path for acq itself, with --no-msb. Any run() child proves the
  # contract, and this one needs no msb fixture: what is under test is that run()
  # gives the child /dev/null, not which command it happens to be.
  #
  # Pipe the installer plus a trailing marker (fd 0 = script bytes); a leaky
  # child would steal the marker line.
  installer="$(cat "$REPO_ROOT/install.sh"; printf 'echo STOLEN_TAIL_BYTES\n')"

  run env PATH="$STUBDIR/bin:$(_acq_coreutils_path)" \
    BREW_STUB_LOG="$BREW_STUB_LOG" \
    sh -c 'printf "%s" "$1" | sh -s -- --method brew --no-msb --yes' _ "$installer"

  assert_success
  run cat "$BREW_STUB_LOG"
  assert_output --partial "ate:[]"
  refute_output --partial "STOLEN"
}
