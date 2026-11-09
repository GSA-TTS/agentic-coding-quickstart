#!/usr/bin/env bats
#
# 160-bash32-build-toolchain.bats — pin how the bash 3.2.57 gate compiles bash.
#
# WHY THIS EXISTS
#
# bash 3.2.57 (2007) is pre-ANSI K&R C. `ubuntu-latest` moved to ubuntu-26.04
# (GCC 15, default -std=gnu23), where an empty parameter list `()` means
# `(void)` and `return;` in an int function is an error, so the from-source
# build in .github/workflows/bash32-compat.yml died on every cache miss —
# which is EVERY merge-queue run (caches are per-ref). Building with
# `-std=gnu89` fixes it, but only if the flag reaches the compiler that builds
# bash's own helper tools: they use CC_FOR_BUILD=$(CC) with CFLAGS_FOR_BUILD,
# neither of which is CFLAGS. So the language must be pinned in CC.
#
# Nothing here compiles anything (the runner image has the compiler; this
# suite deliberately does not). It pins the workflow TEXT so a refactor cannot
# silently float the build back onto the toolchain's default language.
# Tests fail (never skip) when the shape is missing.
#
# shellcheck shell=bats

load 'helper'

WORKFLOW_REL='.github/workflows/bash32-compat.yml'

# _configure_command — print the logical shell command that runs ./configure in
# the build step: comment lines dropped, backslash continuations joined.
# Fails (non-zero) if the step or the configure command is not found.
_configure_command() {
  awk '
    /cd "bash-\$\{BASH32_VERSION\}"/ { on = 1; next }
    !on { next }
    /^[ \t]*#/ { next }
    {
      line = $0
      if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); buf = buf " " line; next }
      buf = buf " " line
      if (buf ~ /\.\/configure/) { print buf; found = 1; exit }
      buf = ""
    }
    END { if (!found) exit 1 }
  ' "$REPO_ROOT/$WORKFLOW_REL"
}

@test "bash32 build: ./configure is found in the build step" {
  run _configure_command
  [ "$status" -eq 0 ] || fail "no './configure' command after cd \"bash-\${BASH32_VERSION}\" in $WORKFLOW_REL"
  case "$output" in *"--prefix=/opt/bash32"*) ;; *) fail "configure command does not install to /opt/bash32: $output" ;; esac
}

@test "bash32 build: the C language is pinned to gnu89 in CC (reaches CC_FOR_BUILD)" {
  local cmd
  cmd=$(_configure_command) || fail "cannot parse the configure command in $WORKFLOW_REL"
  case "$cmd" in
    *'CC="gcc -std=gnu89"'*) ;;
    *) fail "configure must run with CC=\"gcc -std=gnu89\" so GCC 15's gnu23 default cannot break the K&R sources; got: $cmd" ;;
  esac
}

@test "bash32 build: the language pin is not left only in CFLAGS (helper tools ignore CFLAGS)" {
  local cmd flags
  cmd=$(_configure_command) || fail "cannot parse the configure command in $WORKFLOW_REL"
  case "$cmd" in
    *'CC="gcc -std=gnu89"'*) ;;
    *) fail "CC does not carry -std=gnu89: $cmd" ;;
  esac
  case "$cmd" in *'CFLAGS="'*) ;; *) return 0 ;; esac
  flags=${cmd#*CFLAGS=\"}
  flags=${flags%%\"*}
  case "$flags" in
    *-std=*) fail "-std= belongs in CC, not CFLAGS (mkbuiltins/mksyntax are built from CFLAGS_FOR_BUILD): $flags" ;;
  esac
}

@test "bash32 build: the cache key carries the build-recipe suffix" {
  grep -Eq '^[[:space:]]+key: bash32-\$\{\{ runner\.os \}\}-\$\{\{ env\.BASH32_VERSION \}\}-gnu89[[:space:]]*$' \
    "$REPO_ROOT/$WORKFLOW_REL" \
    || fail "cache key must end in -gnu89 so a binary built with the old flags is never restored: $(grep -n 'key: bash32' "$REPO_ROOT/$WORKFLOW_REL")"
}
