#!/usr/bin/env bash
# helpers.sh — Shared test functions for agent-sandbox test suites
# Source this file: source "$(dirname "$0")/helpers.sh"

# Source centralized config (provides PLACEHOLDER_KEY, AGE_*_REGEX, etc.)
# shellcheck source=../config.sh
source "$(dirname "$0")/../config.sh"

PASS=0
FAIL=0

# check DESC CMD [ARGS...] — Run command, report pass/fail
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf "  PASS: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n" "$desc"
        FAIL=$((FAIL + 1))
    fi
}

# check_err DESC EXPECTED_PATTERN CMD [ARGS...] — Run command, assert stderr contains pattern
check_err() {
    local desc="$1"
    local pattern="$2"
    shift 2
    local stderr_output
    stderr_output=$("$@" 2>&1 >/dev/null || true)
    if echo "$stderr_output" | grep -q "$pattern"; then
        printf "  PASS: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (expected '%s' in stderr)\n" "$desc" "$pattern"
        FAIL=$((FAIL + 1))
    fi
}

# summary — Print results and exit with appropriate code
summary() {
    echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
    if [[ "$FAIL" -gt 0 ]]; then
        exit 1
    fi
}
