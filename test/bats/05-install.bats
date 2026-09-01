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
