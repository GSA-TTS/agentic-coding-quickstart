#!/usr/bin/env bats
# scripts/test-acq-bash32: interpreter resolution (fail closed), PATH shimming,
# bats argument pass-through, syntax preflight, and the heredoc-in-substitution
# scan. A fake interpreter shim stands in for bash 3.2.57 wherever the test is
# about the runner's logic; the tests that need genuine 3.2 parser behavior run
# only when a real 3.2.57 is reachable and skip with a reason otherwise.

load 'helper'

setup() {
  acq_setup_stubs
  RUNNER="$REPO_ROOT/scripts/test-acq-bash32"
  REAL_BASH="$(command -v bash)"
  # A shim that reports $FAKE_VERSION for the version probe and otherwise
  # delegates to the real bash (absolute path, so the PATH shim cannot recurse).
  make_fake_bash() { # <version> -> path
    local v="$1" p="$STUBDIR/fake-bash-$1"
    {
      printf '#!/bin/sh\n'
      printf 'if [ "$1" = -c ]; then printf %%s "%s(1)-release"; exit 0; fi\n' "$v"
      printf 'exec "%s" "$@"\n' "$REAL_BASH"
    } > "$p"
    chmod +x "$p"
    printf '%s' "$p"
  }
  # Remember the caller's real-interpreter settings, then point resolution at an
  # empty prefix so a developer's install cannot leak into resolution tests.
  OUTER_BASH32="${ACQ_BASH32:-}"
  OUTER_PREFIX="${ACQ_BASH32_PREFIX:-}"
  export ACQ_BASH32_PREFIX="$STUBDIR/no-prefix"
  unset ACQ_BASH32
}

teardown() { acq_teardown_stubs; }

# Success only when the caller's environment resolves a genuine 3.2.57; used to
# gate the tests that depend on real bash 3.2 parsing.
need_real_bash32() {
  local real
  real="$(
    unset ACQ_BASH32 ACQ_BASH32_PREFIX
    [ -z "$OUTER_BASH32" ] || export ACQ_BASH32="$OUTER_BASH32"
    [ -z "$OUTER_PREFIX" ] || export ACQ_BASH32_PREFIX="$OUTER_PREFIX"
    "$RUNNER" --which 2>/dev/null
  )" || skip "no real GNU Bash 3.2.57 available (set ACQ_BASH32=/path/to/bash or run scripts/test-acq-bash32 --install)"
  REAL32="${real%% *}"
}

@test "bash32: rejects an ACQ_BASH32 interpreter with the wrong version (fail closed)" {
  local fake
  fake="$(make_fake_bash 5.2.37)"
  run env ACQ_BASH32="$fake" "$RUNNER" --which
  assert_failure 2
  assert_output --partial "reports BASH_VERSION '5.2.37', need exactly 3.2.57"
}

@test "bash32: rejects a different 3.2.x patch level" {
  local fake
  fake="$(make_fake_bash 3.2.48)"
  run env ACQ_BASH32="$fake" "$RUNNER" --which
  assert_failure 2
  assert_output --partial "need exactly 3.2.57"
}

@test "bash32: an unusable ACQ_BASH32 is fatal and is not silently replaced by autodiscovery" {
  run env ACQ_BASH32="$STUBDIR/does-not-exist" "$RUNNER" --which
  assert_failure 2
  assert_output --partial "is not an executable file"
}

@test "bash32: accepts an ACQ_BASH32 interpreter reporting 3.2.57" {
  local fake
  fake="$(make_fake_bash 3.2.57)"
  run env ACQ_BASH32="$fake" "$RUNNER" --which
  assert_success
  assert_output "$fake (3.2.57)"
}

@test "bash32: cache prefix interpreter is used when it reports 3.2.57" {
  mkdir -p "$ACQ_BASH32_PREFIX/bin"
  cp "$(make_fake_bash 3.2.57)" "$ACQ_BASH32_PREFIX/bin/bash"
  run "$RUNNER" --which
  assert_success
  assert_output "$ACQ_BASH32_PREFIX/bin/bash (3.2.57)"
}

@test "bash32: a wrong-version cache prefix interpreter is ignored, not trusted" {
  [ ! -x /opt/bash32/bin/bash ] || skip "/opt/bash32 present on this host"
  [ "$(uname -s)" != Darwin ] || skip "macOS /bin/bash is a legitimate fallback"
  mkdir -p "$ACQ_BASH32_PREFIX/bin"
  cp "$(make_fake_bash 5.2.37)" "$ACQ_BASH32_PREFIX/bin/bash"
  run "$RUNNER" --which
  assert_failure 2
  assert_output --partial "no GNU Bash 3.2.57 interpreter found"
  assert_output --partial "ACQ_BASH32=/path/to/bash"
}

@test "bash32: with no interpreter available it fails with an actionable message" {
  [ ! -x /opt/bash32/bin/bash ] || skip "/opt/bash32 present on this host"
  [ "$(uname -s)" != Darwin ] || skip "macOS /bin/bash is a legitimate fallback"
  run "$RUNNER" --which
  assert_failure 2
  assert_output --partial "--install"
  assert_output --partial "docs/howto/bash32-testing.md"
}

@test "bash32: bats arguments pass through and PATH resolves bash to the 3.2 interpreter" {
  local root="$STUBDIR/root" fake
  mkdir -p "$root/scripts" "$root/test/vendor/bats-core/bin"
  cp "$RUNNER" "$root/scripts/test-acq-bash32"
  cp "$REPO_ROOT/scripts/test-acq-bats" "$root/scripts/test-acq-bats"
  cat > "$root/test/vendor/bats-core/bin/bats" <<'STUB'
#!/bin/sh
printf 'bats-arg:%s\n' "$@"
printf 'path-bash-version:%s\n' "$(bash -c 'printf %s "$BASH_VERSION"')"
printf 'env-bash-version:%s\n' "$(env bash -c 'printf %s "$BASH_VERSION"')"
exit "${TEST_BATS_STATUS:-0}"
STUB
  chmod +x "$root/test/vendor/bats-core/bin/bats"
  fake="$(make_fake_bash 3.2.57)"
  run env ACQ_BASH32="$fake" TEST_BATS_STATUS=7 "$root/scripts/test-acq-bash32" test/bats/72-msb-agent-user.bats 'a path.bats'
  assert_failure 7
  assert_line 'bats-arg:test/bats/72-msb-agent-user.bats'
  assert_line 'bats-arg:a path.bats'
  assert_line 'path-bash-version:3.2.57(1)-release'
  assert_line 'env-bash-version:3.2.57(1)-release'
}

@test "bash32: the interpreter check also gates the bats run" {
  local root="$STUBDIR/root" fake
  mkdir -p "$root/scripts" "$root/test/vendor/bats-core/bin"
  cp "$RUNNER" "$root/scripts/test-acq-bash32"
  cp "$REPO_ROOT/scripts/test-acq-bats" "$root/scripts/test-acq-bats"
  printf '#!/bin/sh\necho SHOULD-NOT-RUN\n' > "$root/test/vendor/bats-core/bin/bats"
  chmod +x "$root/test/vendor/bats-core/bin/bats"
  fake="$(make_fake_bash 4.4.23)"
  run env ACQ_BASH32="$fake" "$root/scripts/test-acq-bash32" test/bats/x.bats
  assert_failure 2
  refute_output --partial SHOULD-NOT-RUN
}

@test "bash32 --syntax: passes a parseable file and reports the count" {
  local fake
  fake="$(make_fake_bash 3.2.57)"
  printf '%s\n' '#!/bin/sh' 'echo ok' > "$STUBDIR/good.sh"
  run env ACQ_BASH32="$fake" "$RUNNER" --syntax "$STUBDIR/good.sh"
  assert_success
  assert_output --partial "1 files parse under bash 3.2.57"
}

@test "bash32 --syntax: names a file the interpreter cannot parse and fails" {
  local fake
  fake="$(make_fake_bash 3.2.57)"
  printf '%s\n' 'if then' > "$STUBDIR/bad.sh"
  run env ACQ_BASH32="$fake" "$RUNNER" --syntax "$STUBDIR/bad.sh"
  assert_failure 1
  assert_output --partial "cannot parse"
}

@test "bash32 --syntax: refuses to run on a wrong-version interpreter" {
  local fake
  fake="$(make_fake_bash 5.2.37)"
  printf '%s\n' 'echo ok' > "$STUBDIR/good.sh"
  run env ACQ_BASH32="$fake" "$RUNNER" --syntax "$STUBDIR/good.sh"
  assert_failure 2
  assert_output --partial "need exactly 3.2.57"
}

@test "bash32 --syntax: a real bash 3.2 rejects a bash-4-only construct" {
  need_real_bash32
  printf '%s\n' 'case x in a) echo a ;& b) echo b ;; esac' > "$STUBDIR/b4.sh"
  run env ACQ_BASH32="$REAL32" "$RUNNER" --syntax "$STUBDIR/b4.sh"
  assert_failure 1
  assert_output --partial "cannot parse"
}

@test "bash32 --syntax: real bash 3.2 parses every host-side shell file in the repo" {
  need_real_bash32
  run env ACQ_BASH32="$REAL32" "$RUNNER" --syntax
  assert_success
  assert_output --partial "files parse under bash 3.2.57"
}

@test "bash32 --lint: flags a heredoc in a process substitution with an apostrophe body" {
  printf '%s\n' 'while read -r v; do :; done < <(python3 - <<'"'"'PY'"'"'' "# it's unsafe" 'PY' ')' > "$STUBDIR/unsafe.sh"
  run "$RUNNER" --lint "$STUBDIR/unsafe.sh"
  assert_failure 1
  assert_output --partial "unsafe.sh:1: odd single quotes"
}

@test "bash32 --lint: flags unbalanced parentheses and double quotes in a command-substitution heredoc" {
  printf '%s\n' 'x=$(cat <<'"'"'E'"'"'' 'a)' 'E' ')' > "$STUBDIR/paren.sh"
  printf '%s\n' 'x=$(cat <<'"'"'E'"'"'' 'say "hi' 'E' ')' > "$STUBDIR/dq.sh"
  run "$RUNNER" --lint "$STUBDIR/paren.sh"
  assert_failure 1
  assert_output --partial "unbalanced parentheses"
  run "$RUNNER" --lint "$STUBDIR/dq.sh"
  assert_failure 1
  assert_output --partial "odd double quotes"
}

@test "bash32 --lint: accepts safe bodies and heredocs outside substitutions" {
  printf '%s\n' 'x=$(cat <<'"'"'E'"'"'' 'f(a) and "b"' 'E' ')' > "$STUBDIR/safe-in.sh"
  printf '%s\n' 'cat <<E' "it's (fine" 'E' > "$STUBDIR/safe-out.sh"
  run "$RUNNER" --lint "$STUBDIR/safe-in.sh" "$STUBDIR/safe-out.sh"
  assert_success
}

@test "bash32 --lint: agrees with real bash 3.2 on the flagged construct" {
  need_real_bash32
  printf '%s\n' 'x=$(cat <<'"'"'E'"'"'' "it's" 'E' ')' > "$STUBDIR/h.sh"
  run "$REAL32" -n "$STUBDIR/h.sh"
  assert_failure
  run "$RUNNER" --lint "$STUBDIR/h.sh"
  assert_failure 1
}

@test "bash32 --lint: the repo's own host-side shell files have no unsafe heredoc-in-substitution" {
  run "$RUNNER" --lint
  assert_success
}

@test "bash32: the pinned signing-key fingerprint matches the CI workflow" {
  local ours ci
  ours="$(sed -n 's/^SIGNING_KEY_FPR="\([0-9A-F]*\)"$/\1/p' "$RUNNER")"
  ci="$(sed -n 's/^  BASH_SIGNING_KEY_FPR: "\([0-9A-F]*\)"$/\1/p' "$REPO_ROOT/.github/workflows/bash32-compat.yml")"
  [ -n "$ours" ]
  [ "$ours" = "$ci" ]
}

@test "bash32 --install: refuses to build when signature verification fails" {
  command -v gpg >/dev/null 2>&1 || skip "needs gpg on PATH"
  local mirror="$STUBDIR/mirror"
  mkdir -p "$mirror"
  printf 'not a tarball\n' > "$mirror/bash-3.2.57.tar.gz"
  printf 'not a signature\n' > "$mirror/bash-3.2.57.tar.gz.sig"
  run env ACQ_BASH32_MIRRORS="file://$mirror" TMPDIR="$STUBDIR" "$RUNNER" --install
  assert_failure 2
  assert_output --partial "signature verification FAILED"
  run compgen -G "$STUBDIR/acq-bash32.*"
  assert_failure
  [ ! -e "$ACQ_BASH32_PREFIX/bin/bash" ]
}

@test "bash32: a relative ACQ_BASH32 path is made absolute for the PATH shim" {
  local root="$STUBDIR/root" fake
  mkdir -p "$root/scripts" "$root/test/vendor/bats-core/bin"
  cp "$RUNNER" "$root/scripts/test-acq-bash32"
  cp "$REPO_ROOT/scripts/test-acq-bats" "$root/scripts/test-acq-bats"
  printf '#!/bin/sh\nbash -c %s\n' "'printf %s \"\$BASH_VERSION\"'" > "$root/test/vendor/bats-core/bin/bats"
  chmod +x "$root/test/vendor/bats-core/bin/bats"
  fake="$(make_fake_bash 3.2.57)"
  cp "$fake" "$STUBDIR/relbash"
  run bash -c 'cd "$1" && ACQ_BASH32=./relbash "$2" x.bats' _ "$STUBDIR" "$root/scripts/test-acq-bash32"
  assert_success
  assert_output --partial "3.2.57"
}

@test "bash32: the PATH shim directory is removed after a successful and after a failing run" {
  local root="$STUBDIR/root" fake tmp="$STUBDIR/tmp"
  mkdir -p "$root/scripts" "$root/test/vendor/bats-core/bin" "$tmp"
  cp "$RUNNER" "$root/scripts/test-acq-bash32"
  cp "$REPO_ROOT/scripts/test-acq-bats" "$root/scripts/test-acq-bats"
  cat > "$root/test/vendor/bats-core/bin/bats" <<'STUB'
#!/bin/sh
ls "$(dirname "$(command -v bash)")" >/dev/null || exit 9
exit "${TEST_BATS_STATUS:-0}"
STUB
  chmod +x "$root/test/vendor/bats-core/bin/bats"
  fake="$(make_fake_bash 3.2.57)"
  run env TMPDIR="$tmp" ACQ_BASH32="$fake" "$root/scripts/test-acq-bash32" x.bats
  assert_success
  [ -z "$(ls -A "$tmp")" ]
  run env TMPDIR="$tmp" TEST_BATS_STATUS=5 ACQ_BASH32="$fake" "$root/scripts/test-acq-bash32" x.bats
  assert_failure 5
  [ -z "$(ls -A "$tmp")" ]
}

@test "bash32: a relative ACQ_BASH32_PREFIX is rejected" {
  run env ACQ_BASH32_PREFIX=relative/dir "$RUNNER" --which
  assert_failure 2
  assert_output --partial "must be an absolute path"
}

@test "bash32 --lint: catches hazards after case-pattern heads, arithmetic and function heads" {
  printf '%s\n' 'x=$(case $y in' "a) cat <<'E'" "it's" 'E' ';;' 'esac)' > "$STUBDIR/case.sh"
  printf '%s\n' 'if ((1)); then x=$(cat <<'"'E'" "it's" 'E' ')' 'fi' > "$STUBDIR/arith.sh"
  printf '%s\n' 'f() { x=$(' "cat <<'E'" "it's" 'E' ')' '}' > "$STUBDIR/func.sh"
  run "$RUNNER" --lint "$STUBDIR/case.sh" "$STUBDIR/arith.sh" "$STUBDIR/func.sh"
  assert_failure 1
  assert_output --partial "case.sh:2"
  assert_output --partial "arith.sh:1"
  assert_output --partial "func.sh:2"
}

@test "bash32 --lint: catches a heredoc in a double-quoted substitution that has a quoted argument" {
  printf '%s\n' 'out="$(foo "$a" <<'"'"'PY'"'"'' "it's" 'PY' ')"' > "$STUBDIR/dqsub.sh"
  run "$RUNNER" --lint "$STUBDIR/dqsub.sh"
  assert_failure 1
  assert_output --partial "dqsub.sh:1: odd single quotes"
}

@test "bash32 --lint: does not flag a heredoc that follows a closed substitution on the same line" {
  printf '%s\n' 'x=$(date); cat <<E' "it's" 'E' > "$STUBDIR/closed.sh"
  run "$RUNNER" --lint "$STUBDIR/closed.sh"
  assert_success
}

@test "bash32 --lint: reports an unterminated here-document" {
  printf '%s\n' 'x=$(cat <<E' 'body' > "$STUBDIR/open.sh"
  run "$RUNNER" --lint "$STUBDIR/open.sh"
  assert_failure 1
  assert_output --partial "unterminated here-document 'E'"
}
