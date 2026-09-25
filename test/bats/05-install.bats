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

_write_curl_msb_installer_stub() {
  cat >"$STUBDIR/bin/curl" <<'STUB'
#!/usr/bin/env sh
emit_installer() {
  cat <<'INSTALLER'
#!/usr/bin/env sh
set -eu
if [ "${MSB_INSTALLER_READS_STDIN:-0}" = "1" ]; then cat >/dev/null; fi
mkdir -p "$HOME/.microsandbox/bin" "$HOME/.local/bin"
cat >"$HOME/.microsandbox/bin/msb" <<'MSB'
#!/usr/bin/env sh
case "$1" in
  --version|-V) printf 'msb 0.6.18\n' ;;
  *) exit 0 ;;
esac
MSB
chmod +x "$HOME/.microsandbox/bin/msb"
ln -sf "$HOME/.microsandbox/bin/msb" "$HOME/.local/bin/msb"
INSTALLER
}
case "$*" in
  *github.com/superradcompany/microsandbox/releases/download/v0.6.18/install.sh*) ;;
  *) printf 'unexpected curl: %s\n' "$*" >&2; exit 1 ;;
esac
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out=$arg; break; fi
  prev=$arg
done
if [ -n "$out" ]; then
  emit_installer >"$out"
else
  emit_installer
fi
STUB
  chmod +x "$STUBDIR/bin/curl"
}

_write_unparseable_msb_stub() { # PATH
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '#!/usr/bin/env sh' 'printf "msb dev-build\\n"' >"$1"
  chmod +x "$1"
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

@test "install: missing msb installs pinned safe 0.6.18" {
  _write_npm_stub
  _write_curl_msb_installer_stub

  run env PATH="$STUBDIR/bin:$HOME/.local/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'Installing msb 0.6.18 via upstream release installer'
  assert_output --partial 'releases/download/v0.6.18/install.sh'
  run "$HOME/.local/bin/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: active msb 0.6.8 upgrades to pinned safe 0.6.18" {
  _write_npm_stub
  _write_curl_msb_installer_stub
  _write_msb_stub "$HOME/.local/bin/msb" 0.6.8

  run env PATH="$HOME/.local/bin:$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'active msb version is too old'
  assert_output --partial 'Installing msb 0.6.18 via upstream release installer'
  run "$HOME/.local/bin/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: unparseable active msb is replaced with pinned safe version" {
  _write_npm_stub
  _write_curl_msb_installer_stub
  _write_unparseable_msb_stub "$HOME/.local/bin/msb"

  run env PATH="$HOME/.local/bin:$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'active msb version could not be determined'
  run "$HOME/.local/bin/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: fetched msb installer runs from temp file with stdin detached" {
  _write_npm_stub
  _write_curl_msb_installer_stub

  run env MSB_INSTALLER_READS_STDIN=1 PATH="$STUBDIR/bin:$HOME/.local/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  run "$HOME/.local/bin/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: active local msb 0.7.2 downgrades to 0.6.18" {
  _write_npm_stub
  _write_curl_msb_installer_stub
  _write_msb_stub "$HOME/.local/bin/msb" 0.7.2

  run env PATH="$HOME/.local/bin:$STUBDIR/bin:$(_acq_coreutils_path)" \
    sh "$REPO_ROOT/install.sh" --method npm --yes

  assert_success
  assert_output --partial 'active msb version is blocked'
  assert_output --partial 'Installing msb 0.6.18 via upstream release installer'
  run "$HOME/.local/bin/msb" --version
  assert_output 'msb 0.6.18'
}

@test "install: blocked msb shadowing safe install fails closed" {
  _write_npm_stub
  _write_curl_msb_installer_stub
  _write_msb_stub "$STUBDIR/bin/msb" 0.7.2

  run env PATH="$STUBDIR/bin:$HOME/.local/bin:$(_acq_coreutils_path)" \
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
  _write_npm_stub
  _write_curl_msb_installer_stub

  # Pipe the installer plus a trailing marker (fd 0 = script bytes); a leaky
  # child would steal the marker line.
  installer="$(cat "$REPO_ROOT/install.sh"; printf 'echo STOLEN_TAIL_BYTES\n')"

  run env PATH="$STUBDIR/bin:$HOME/.local/bin:$(_acq_coreutils_path)" \
    BREW_STUB_LOG="$BREW_STUB_LOG" \
    sh -c 'printf "%s" "$1" | sh -s -- --method npm --yes' _ "$installer"

  assert_success
  run cat "$BREW_STUB_LOG"
  assert_output --partial "ate:[]"
  refute_output --partial "STOLEN"
}
