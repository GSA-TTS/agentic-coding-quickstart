#!/usr/bin/env bats
#
# 158-bash32-relevance-paths.bats — pin the relevance list of the bash 3.2 gate.
#
# WHY THIS EXISTS
#
# .github/workflows/bash32-compat.yml decides in its `changes` job whether the
# expensive real-bash-3.2 suite runs, by `git diff --name-only <base> -- <paths>`.
# The required `gate` check reports success when that job finds nothing relevant,
# so a file the suite reads but the list omits lets a PR skip the only real 3.2
# lane while the gate stays green. These tests fail (never skip) when a required
# entry is missing, so dropping one is a visible, named failure.
#
# The list is parsed from the workflow text (one source of truth) and is robust
# to YAML re-wrapping: the whole `git diff` command is joined across line
# continuations and every single-quoted token is taken as a pathspec.
#
# shellcheck shell=bats

load 'helper'

WORKFLOW_REL='.github/workflows/bash32-compat.yml'

# Every path the build + suite job reads, and why it is required.
#   acq acq.backends acq.cmd acq.ps1 install.* README.md AGENTS.md
#                         the code under test, and files the suite reads directly
#   scripts/test-acq-*    the runner, the stub library, and the 3.2 launcher
#   scripts/bats*         bats sharding and timing helpers exercised by tests
#   scripts/<tool>        scripts the suite executes, sources, or greps
#   provider-input-validator-requirements*.txt
#                         pip-installed by the job and grepped by tests
#   test/bats test/vendor the tests, and the pinned bats-core + helpers
#   .gitmodules           where `submodules: true` takes the bats URLs from
#   .github/keys/...asc   the key that authenticates the bash 3.2.57 source
#   release.yml           read by 06-windows-install.bats
#   bash32-compat.yml     the job itself
REQUIRED_PATHSPECS='
acq
acq.backends
acq.cmd
acq.ps1
install.sh
install.ps1
README.md
AGENTS.md
scripts/test-acq-lib.sh
scripts/test-acq-bats
scripts/test-acq-bash32
scripts/bats-shard
scripts/fetch-bash32-oci.py
scripts/scan-heredoc-subst.py
scripts/bats_timing_core.py
scripts/bats_timing_render.py
scripts/summarize-bats-timing
scripts/run-shellcheck
scripts/fix-exec-bits
scripts/verify-backends
scripts/qualify-msb-ro-mount
scripts/rotate-apikey
scripts/probe-msb-node-startup
scripts/test-probe-msb-node-startup.py
scripts/setup-provider-input-validator
scripts/install-provider-input-wheelhouse
scripts/provider-input-validator-requirements.txt
scripts/provider-input-validator-requirements-linux.txt
scripts/provider-input-validator-requirements-macos.txt
scripts/provider-input-validator-requirements-windows.txt
test/bats
test/vendor
.gitmodules
.github/keys/chet-ramey-bash-release-signing-key.asc
.github/workflows/release.yml
.github/workflows/bash32-compat.yml
'

# TEMPORARY ALLOWLIST — delete this variable (and the `pending` handling in the
# existence test) once the file below has landed on main.
# These pathspecs are listed ahead of time (a git pathspec that matches no file
# is harmless) for a script that only exists on the open bats-sharding change.
# While absent, the existence check must not demand it. As soon as it EXISTS it
# must leave this list (see the existence test), so the allowlist cannot outlive
# the file it covers.
PENDING_PATHSPECS='
scripts/bats-shard
'

# Tracked files that the real suite does NOT read, so they correctly stay out of
# the relevance list. A tracked path is either covered by a listed pathspec or
# named here (exact path, or a directory prefix ending in "/"); a new file that
# is neither fails the coverage test, forcing a conscious decision. Reasons:
#   docs/ checklists/ governance/     prose; no test reads them (README/AGENTS are listed)
#   .github (other than the listed)   templates, linters, other workflows
#   repo metadata / lint config       not read by any @test
#   other scripts/verify-* and probes live or manual tools, never run by the suite
NOT_INPUTS='
docs/
checklists/
governance/
.github/ISSUE_TEMPLATE/
.github/linters/
.github/CODEOWNERS
.github/dependabot.yml
.github/pull_request_template.md
.github/release.yml
.github/workflows/markdown-quality.yml
.github/workflows/pr-lint.yml
.github/workflows/pre-commit.yml
.gitattributes
.gitignore
.gitleaks.repo.toml
.gitleaks.toml
.markdown-link-check.json
.markdownlint-cli2.yaml
.markdownlint.jsonc
.markdownlintignore
.pre-commit-config.yaml
.prettierrc
.release-please-manifest.json
.shellcheckrc
CHANGELOG.md
CODE_OF_CONDUCT.md
CONTEXT-GUIDE.md
CONTRIBUTING.md
LICENSE
SECURITY.md
SUPPORT.md
package.json
release-please-config.json
scripts/diagnose-host-egress-diff
scripts/diagnose-tls-intercept
scripts/probe-macos-keychain-stdin
scripts/probe-msb-posthoc-ports
scripts/probe-msb-startup
scripts/test-probe-msb-startup.py
scripts/verify-git-https-secret-msb
scripts/verify-image-override
scripts/verify-issue-320
scripts/verify-msb-pin
scripts/verify-net-default-egress
scripts/verify-ports-live
scripts/verify-sbx-startup-barrier
'

# _relevance_command — print the workflow's `changed="$(git diff ...)"` command
# with line continuations joined. Strict like the shell: every line but the last
# must end in exactly one backslash, and the last must end in `)"`. Fails
# (non-zero, with a reason on stderr) if absent, unterminated, or mis-continued.
_relevance_command() {
  awk '
    !on && /^[ \t]*changed="\$\(git diff --name-only "\$BASE_SHA"/ { on = 1 }
    on {
      if ($0 ~ /\)"[ \t]*$/) { out = out " " $0; done = 1; exit }
      if ($0 !~ /\\$/) {
        printf "line lacks a trailing backslash: %s\n", $0 > "/dev/stderr"
        bad = 1; exit
      }
      line = $0
      sub(/\\$/, "", line)
      out = out " " line
    }
    END { if (!done || bad) exit 1; print out }
  ' "$REPO_ROOT/$WORKFLOW_REL"
}

# _workflow_pathspecs — print the single-quoted pathspecs, one per line.
_workflow_pathspecs() {
  local cmd
  cmd=$(_relevance_command) || return 1
  printf '%s\n' "$cmd" | grep -o "'[^']*'" | tr -d "'"
}

@test "relevance: the pathspec list can be parsed from the workflow" {
  run _relevance_command
  [ "$status" -eq 0 ] || fail "no complete 'git diff --name-only \"\$BASE_SHA\" -- ...' command in $WORKFLOW_REL"
  run _workflow_pathspecs
  [ "$status" -eq 0 ] || fail "could not extract pathspecs from $WORKFLOW_REL"
  [ -n "$output" ] || fail "no single-quoted pathspecs found in $WORKFLOW_REL"
}

@test "relevance: every pathspec is single-quoted (nothing the parser could skip)" {
  local cmd residue
  cmd=$(_relevance_command) || fail "cannot parse $WORKFLOW_REL"
  # Remove the known command skeleton and every quoted token; anything left is a
  # pathspec written in a form this test cannot see (unquoted or double-quoted).
  residue=$(printf '%s\n' "$cmd" \
    | sed -e 's/changed="\$(//' \
          -e 's/git diff --name-only "\$BASE_SHA" --//' \
          -e "s/'[^']*'//g" \
          -e 's/)"//' \
          -e 's/\\//g' \
    | tr -d '[:space:]')
  [ -z "$residue" ] || fail "unparsed text in the relevance command (quote each pathspec with single quotes): $residue"
}

@test "relevance: every required path that can change the suite result is listed" {
  local have want missing=""
  have=$(_workflow_pathspecs) || fail "cannot parse $WORKFLOW_REL"
  for want in $REQUIRED_PATHSPECS; do
    grep -Fxq -- "$want" <<<"$have" || missing="${missing}${want} "
  done
  [ -z "$missing" ] || fail "bash32-compat.yml relevance list is missing: ${missing}— a PR changing only these would skip the real bash 3.2 suite while the gate reports success"
}

@test "relevance: the list has no duplicate pathspecs" {
  local dups
  dups=$(_workflow_pathspecs) || fail "cannot parse $WORKFLOW_REL"
  dups=$(printf '%s\n' "$dups" | sort | uniq -d | tr '\n' ' ')
  [ -z "$dups" ] || fail "duplicate pathspecs in $WORKFLOW_REL: $dups"
}

@test "relevance: every listed pathspec exists, or is pending and not yet on main" {
  local specs spec p pending missing="" stale=""
  specs=$(_workflow_pathspecs) || fail "cannot parse $WORKFLOW_REL"
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    pending=0
    for p in $PENDING_PATHSPECS; do
      [ "$p" = "$spec" ] && pending=1
    done
    if [ "$pending" -eq 1 ]; then
      [ -e "$REPO_ROOT/$spec" ] && stale="${stale}${spec} "
      continue
    fi
    [ -e "$REPO_ROOT/$spec" ] || missing="${missing}${spec} "
  done <<SPECS
$specs
SPECS
  [ -z "$stale" ] || fail "now present in the repo; remove from PENDING_PATHSPECS: ${stale}"
  [ -z "$missing" ] || fail "relevance pathspec(s) match no file in the repo (typo, rename, or delete?): ${missing}— if a change still has to add it, list it in PENDING_PATHSPECS with a comment"
}

@test "relevance: every tracked file is covered by the list or named in NOT_INPUTS" {
  local specs files f spec n uncovered="" hit
  specs=$(_workflow_pathspecs) || fail "cannot parse $WORKFLOW_REL"
  files=$(git -C "$REPO_ROOT" ls-files) || fail "git ls-files failed in $REPO_ROOT"
  [ -n "$files" ] || fail "git ls-files returned nothing"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=0
    while IFS= read -r spec; do
      case "$f" in "$spec"|"$spec"/*) hit=1; break ;; esac
    done <<SPECS
$specs
SPECS
    if [ "$hit" -eq 0 ]; then
      for n in $NOT_INPUTS; do
        case "$n" in
          */) case "$f" in "$n"*) hit=1; break ;; esac ;;
          *) [ "$f" = "$n" ] && { hit=1; break; } ;;
        esac
      done
    fi
    [ "$hit" -eq 1 ] || uncovered="${uncovered}${f} "
  done <<FILES
$files
FILES
  [ -z "$uncovered" ] || fail "tracked file(s) neither in the bash32-compat.yml relevance list nor in NOT_INPUTS: ${uncovered}— if the suite reads them, add them to the workflow list AND REQUIRED_PATHSPECS; if not, add them to NOT_INPUTS"
}
