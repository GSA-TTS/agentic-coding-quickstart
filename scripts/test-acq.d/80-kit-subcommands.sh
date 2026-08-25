#!/usr/bin/env bash
#
# 80-kit-subcommands — acq kit list/validate/apply
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 9. acq kit subcommands
# ===========================================================================

# 9a. `acq kit list` shows the pinned neutral kits.
make_stubs
out=$("$ACQ" kit list 2>&1)
# Assert the CONFIGURED pin (not a hardcoded SHA) so this survives pin bumps.
# shellcheck disable=SC1090
_want_ref=$(ACQ_SOURCE_ONLY=1 ACQ_SCRIPT_DIR="$REPO_ROOT" . "$ACQ" >/dev/null 2>&1; printf '%s' "$PATTERNS_KIT_REF")
assert_contains "kit: list shows patterns ref" "$out" "$_want_ref"
assert_contains "kit: list shows acq-kits dir" "$out" "acq-kits"
assert_contains "kit: list shows usai-provider" "$out" "usai-provider"
assert_contains "kit: list shows git-ssh-sign" "$out" "git-ssh-sign"
cleanup_stubs

# 9b. `acq kit validate` accepts a well-formed local neutral kit.
make_stubs
kitdir="$STUBDIR/goodkit"
mkdir -p "$kitdir/files/home"
printf 'hello\n' > "$kitdir/files/home/thing"
cat >"$kitdir/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: sample-kit
displayName: Sample Kit
description: A sample neutral kit for the offline test.
caps:
  network:
    allow:
      - example.com
files:
  - path: /home/agent/thing
    mode: "0644"
    source: files/home/thing
commands:
  - phase: startup
    user: "1000"
    command:
      - sh
      - -c
      - echo hi
SPEC
out=$("$ACQ" kit validate "$kitdir" 2>&1); rc=$?
assert_eq "kit: validate good kit exits 0" "0" "$rc"
assert_contains "kit: validate good kit OK" "$out" "OK"
cleanup_stubs

# 9c. `acq kit validate` rejects a kit with a bad schemaVersion + missing source.
make_stubs
badkit="$STUBDIR/badkit"
mkdir -p "$badkit"
cat >"$badkit/spec.yaml" <<'SPEC'
schemaVersion: "2"
kind: mixin
name: Bad_Name
displayName: Bad
description: bad kit
files:
  - path: relative/path
    mode: "0644"
    source: files/missing.txt
commands:
  - phase: bogusphase
    command:
      - true
SPEC
out=$("$ACQ" kit validate "$badkit" 2>&1); rc=$?
assert_eq "kit: validate bad kit exits 1" "1" "$rc"
assert_contains "kit: validate flags schemaVersion" "$out" "hybrid/v1"
assert_contains "kit: validate flags bad name" "$out" "kebab-case"
assert_contains "kit: validate flags absolute path" "$out" "absolute"
assert_contains "kit: validate flags missing source" "$out" "source not found"
assert_contains "kit: validate flags bad phase" "$out" "unknown command phase"
cleanup_stubs

# 9d. `acq kit apply NAME KITREF` on the msb backend calls msb exec (translated).
make_stubs
applykit="$STUBDIR/applykit"
mkdir -p "$applykit"
cat >"$applykit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: apply-kit
displayName: Apply Kit
description: kit applied mid-life
commands:
  - phase: startup
    user: "1000"
    command:
      - sh
      - -c
      - echo applied
SPEC
out=$(ACQ_BACKEND=msb "$ACQ" kit apply mybox "$applykit" 2>/dev/null || true)
log=$(cat "$CALLS")
assert_contains "kit: apply (msb) runs msb exec" "$log" "msb exec mybox"
# ADR-0017 REGRESSION: mid-life `acq kit apply` is a create-time-flag-free path —
# a --script-path cannot register into an already-running sandbox, so mid-life
# apply must NEVER stage a create-time startup script (it stays 100% exec-based).
assert_not_contains "0017: mid-life apply does NOT stage a create-time script" "$log" "--script-path acq-startup"
assert_not_contains "0017: mid-life apply runs no msb create" "$log" "msb create"
cleanup_stubs
