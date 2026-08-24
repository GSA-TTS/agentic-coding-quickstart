#!/usr/bin/env bash
#
# 50-kit-list-completeness — built-in kits + doc count-drift guard
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 6. Kit list completeness (the built-in kits) + doc count-drift guard
# ===========================================================================

make_stubs; load_acq
kits_joined=$(printf '%s\n' "${KITS[@]}")
assert_contains "kits: usai-provider" "$kits_joined" "acq-kits/usai-provider"
assert_contains "kits: playbook" "$kits_joined" "acq-kits/agentic-coding-playbook"
assert_contains "kits: zscaler" "$kits_joined" "acq-kits/zscaler-ca-certificate"
assert_contains "kits: git-ssh-sign" "$kits_joined" "acq-kits/git-ssh-sign"
# ORDER: zscaler-ca-certificate MUST be first so CA trust is established before
# any later kit makes a network request (matters on sbx, whose kits apply
# sequentially; harmless on msb, where trust is a create-time flag).
assert_contains "kits: zscaler applied first" "${KITS[0]}" "acq-kits/zscaler-ca-certificate"
# Count-drift guard (#278): the authority is ACQ_KIT_NAMES in common.sh. If a
# doc still spells out a hardcoded English count ("four kits"), it will silently
# lie the moment the built-in set changes size. Prefer countless prose ("its
# built-in kits"); this asserts no such stale English-number count survives in
# the user-facing docs.
_kit_count="${#ACQ_KIT_NAMES[@]}"
assert_eq "kit count is the documented set" "4" "$_kit_count"
for _doc in "$REPO_ROOT/README.md" "$REPO_ROOT/AGENTS.md"; do
  _bad=$(grep -Eic "\b(four|five|three|six|two) (built-in |mixin )?kits\b" "$_doc" || true)
  assert_eq "no hardcoded English kit count in $(basename "$_doc")" "0" "$_bad"
done
cleanup_stubs
