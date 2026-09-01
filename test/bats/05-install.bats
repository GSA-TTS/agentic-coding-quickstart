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
