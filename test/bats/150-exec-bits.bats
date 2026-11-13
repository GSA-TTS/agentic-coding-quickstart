#!/usr/bin/env bats
#
# 150-exec-bits.bats — guard for scripts/fix-exec-bits and the index-mode
# invariant it enforces.
#
# WHY THIS EXISTS
#
# A clone on a container/host shared mount cannot round-trip POSIX permissions,
# so such clones set core.fileMode=false to suppress spurious mode churn. That
# makes git BLIND to a LOST exec bit: a 100755 -> 0644 regression with identical
# content produces an empty `git status` AND an empty `git diff --summary`. Since
# nearly every editor and coding agent saves via write-temp-then-rename (a new
# inode with the ambient umask), entry points silently stop being executable.
#
# Observed consequences in one session: `./scripts/verify-backends` refusing to
# run, `acq` steps exiting 126, and — worst — the vendored bats dying several
# execs deep with "Permission denied", which the sbx preflight reported as
# "real sbx rejected acq's translated kit grammar". A permission artifact
# masquerading as kit-grammar incompatibility.
#
# These tests pin the invariant and the two properties that make it safe:
#   - the INDEX is the criterion, so sourced libs / bats files stay 644;
#   - --check fails (never silently passes) when drift exists.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

FIXER_REL='scripts/fix-exec-bits'
INDEX_VALIDATOR_REL='scripts/validate-git-executable-modes'

EXPECTED_EXECUTABLES='acq
scripts/bats-shard
scripts/diagnose-tls-intercept
scripts/fetch-bash32-oci.py
scripts/fix-exec-bits
scripts/install-provider-input-wheelhouse
scripts/probe-msb-node-startup
scripts/probe-msb-posthoc-ports
scripts/probe-msb-startup
scripts/rotate-apikey
scripts/run-shellcheck
scripts/scan-heredoc-subst.py
scripts/setup-provider-input-validator
scripts/summarize-bats-timing
scripts/test-acq-bash32
scripts/test-acq-bats
scripts/test-probe-msb-node-startup.py
scripts/test-probe-msb-startup.py
scripts/validate-git-executable-modes
scripts/verify-backends
scripts/verify-git-https-secret-msb
scripts/verify-host-authority-live
scripts/verify-image-override
scripts/verify-issue-320
scripts/verify-net-default-egress
scripts/verify-ports-live'

# _mkrepo — build a throwaway git repo mimicking the real layout: an executable
# entry point, a sourced library and a bats file (both correctly non-executable),
# and core.fileMode=false so git is blind to mode drift exactly as on a host
# shared mount.
_mkrepo() {
  REPO="$STUBDIR/fixture"
  mkdir -p "$REPO/scripts" "$REPO/acq.backends" "$REPO/test/bats"
  cd "$REPO" || return 1
  git init -q .
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false

  printf '#!/usr/bin/env bash\necho entry\n' > entry
  chmod 755 entry
  printf '#!/usr/bin/env bash\necho lib\n' > acq.backends/lib.sh
  chmod 644 acq.backends/lib.sh
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > test/bats/x.bats
  chmod 644 test/bats/x.bats

  cp "$REPO_ROOT/$FIXER_REL" scripts/fix-exec-bits
  chmod 755 scripts/fix-exec-bits

  git add -A
  git commit -qm init
  # The setting that creates the blind spot.
  git config core.fileMode false
}

_make_index_fixture() {
  REPO="$STUBDIR/index-fixture"
  mkdir -p "$REPO"
  cd "$REPO" || return 1
  git init -q .
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false
  local path
  for path in $EXPECTED_EXECUTABLES; do
    mkdir -p "$(dirname "$path")"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$path"
    chmod 755 "$path"
  done
  git add -A
  git commit -qm init
  BASE_BRANCH=$(git symbolic-ref --short HEAD)
}

@test "exec-bits: git with core.fileMode=false is BLIND to a lost exec bit" {
  _mkrepo
  # Establish the premise this whole guard exists for. If git ever starts
  # reporting this on its own, the fixer's reason for existing has changed.
  chmod 644 entry
  run git status --porcelain
  assert_success
  assert_output ''
  run git diff --summary
  assert_success
  assert_output ''
  # ...while the index still says it is an entry point.
  run git ls-files -s entry
  assert_output --regexp '^100755'
}

@test "exec-bits: the fixer restores a lost bit and is idempotent" {
  _mkrepo
  chmod 644 entry
  run bash scripts/fix-exec-bits
  assert_success
  assert_output --partial 'fixed +x   entry'
  assert [ -x entry ]

  # Second run must be a clean no-op, not a repeat "fix".
  run bash scripts/fix-exec-bits
  assert_success
  assert_output --partial 'every tracked file matches its index mode'
  refute_output --partial 'fixed +x'
}

@test "exec-bits: --check FAILS on drift (so a hook can catch it) and passes when clean" {
  _mkrepo
  chmod 644 entry
  run bash scripts/fix-exec-bits --check
  assert_failure
  assert_output --partial 'needs +x   entry'
  # --check must not mutate anything.
  assert [ ! -x entry ]

  chmod 755 entry
  run bash scripts/fix-exec-bits --check
  assert_success
}

@test "exec-bits: a shebang is NOT the criterion — sourced libs and bats stay 644" {
  _mkrepo
  # Both files start with '#!' but the index records 100644: acq.backends/*.sh are
  # SOURCED by acq and test/bats/*.bats are read BY bats. A fixer that keyed off
  # the shebang would wrongly mark them executable.
  run bash scripts/fix-exec-bits
  assert_success
  assert [ ! -x acq.backends/lib.sh ]
  assert [ ! -x test/bats/x.bats ]
  refute_output --partial 'lib.sh'
  refute_output --partial 'x.bats'
}

@test "exec-bits: an unexpected +x is reported, never silently cleared" {
  _mkrepo
  # The author may intend to commit this as a real mode change, so the fixer must
  # surface it without destroying the local edit.
  chmod 755 acq.backends/lib.sh
  run bash scripts/fix-exec-bits
  assert_output --partial 'unexpected +x'
  assert_output --partial 'lib.sh'
  assert [ -x acq.backends/lib.sh ]
}

@test "exec-bits: THIS repo's tracked modes match the index" {
  # The invariant the pre-commit hook enforces, asserted on the real checkout so
  # a committed 644-on-an-entry-point cannot slip through.
  run bash "$REPO_ROOT/$FIXER_REL" --check
  assert_success
}

@test "exec-bits: every entry point the index marks 100755 is really executable" {
  # Belt-and-braces, phrased as the property that actually matters at runtime.
  cd "$REPO_ROOT" || return 1
  local missing=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -x "$f" ] || missing="${missing}${f} "
  done < <(git ls-files -s | awk '$1=="100755"{print $4}')
  [ -z "$missing" ] || {
    printf 'not executable: %s\n' "$missing" >&2
    return 1
  }
}

@test "exec-bits: Git-index validator accepts stage-0 100755 despite disk mode drift" {
  _make_index_fixture
  chmod 644 acq
  run bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --root "$REPO"
  assert_success
  assert_output --partial 'OK - 26 intended executables are stage-0 100755'
}

@test "exec-bits: Git-index validator rejects a staged 100644 entry point" {
  _make_index_fixture
  chmod 644 acq
  git add acq
  run bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --root "$REPO"
  assert_failure
  assert_output --partial 'acq must have one stage-0 100755 index entry'
  assert_output --partial 'got: 100644 0'
}

@test "exec-bits: Git-index validator rejects an untracked or unmerged entry point" {
  _make_index_fixture
  git rm --cached acq
  run bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --root "$REPO"
  assert_failure
  assert_output --partial 'got: missing or untracked'

  git reset --hard -q HEAD
  git checkout -q -b other
  printf '# other\n' >> acq
  git add acq
  git commit -qm other
  git checkout -q "$BASE_BRANCH"
  printf '# master\n' >> acq
  git add acq
  git commit -qm master
  git merge other >/dev/null 2>&1 || true
  run bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --root "$REPO"
  assert_failure
  assert_output --partial 'got: 100755 1'
}

@test "exec-bits: Git-index validator reports command errors" {
  _make_index_fixture
  run bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --root "$REPO/absent"
  assert_failure 2
  assert_output --partial 'not a git worktree'
}

@test "exec-bits: this repo's intended executables are 100755 in the Git index" {
  run bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --root "$REPO_ROOT"
  assert_success
}

@test "exec-bits: Git-index manifest covers every tracked executable entry point" {
  local expected actual
  expected=$(bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --print-expected | sort)
  actual=$(git -C "$REPO_ROOT" ls-files --stage | awk '$1 == "100755" { print $4 }' | sort)
  assert_equal "$actual" "$expected"
}

@test "exec-bits: vendored Bats runtime modes come from its submodule index" {
  # The superproject records bats-core as a gitlink, so its internal executables
  # belong to its own index. fix-exec-bits recursively checks that index; the
  # top-level release-entrypoint validator must not guess at vendored internals.
  run git -C "$REPO_ROOT" ls-files --stage -- test/vendor/bats-core
  assert_success
  assert_output --regexp '^160000 '

  run git -C "$REPO_ROOT/test/vendor/bats-core" ls-files --stage -- \
    bin/bats libexec/bats-core/bats libexec/bats-core/bats-exec-suite
  assert_success
  assert_output --partial $'100755 '
  assert_output --partial $'\tbin/bats'
  assert_output --partial $'\tlibexec/bats-core/bats'
  assert_output --partial $'\tlibexec/bats-core/bats-exec-suite'

  run bash "$REPO_ROOT/$INDEX_VALIDATOR_REL" --print-expected
  assert_success
  refute_output --partial 'test/vendor/'
}

@test "exec-bits: the bats runner points a lost bit at the fixer, not at submodule init" {
  # A lost bit must produce an actionable message, not the old misleading
  # "vendored bats not found" (which sent people to re-init a submodule that was
  # already initialized). Assert the distinct not-executable branch exists.
  run grep -n 'not executable' "$REPO_ROOT/scripts/test-acq-bats"
  assert_success
  run grep -n 'scripts/fix-exec-bits' "$REPO_ROOT/scripts/test-acq-bats"
  assert_success
}

@test "exec-bits: the live verifier actually INVOKES the fixer at startup" {
  # Grepping for the mere mention is too weak — the explanatory comment would
  # satisfy it even if the call were deleted. Assert the executing line.
  run grep -nE '^[[:space:]]*_fix_out=\$\(bash "\$\{REPO_ROOT\}/scripts/fix-exec-bits"' \
    "$REPO_ROOT/scripts/verify-backends"
  assert_success
}
