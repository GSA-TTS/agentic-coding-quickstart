#!/usr/bin/env bash
#
# 90-sbx-startup-kit — sbx 0.38 startup-kit refusal + markers
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 9q. sbx 0.38 startup-kit refusal + stale-probe + create-time extra-kit marker
#     (quickstart #320). All offline via the stubbed sbx.
# ===========================================================================

# Helper: plant an sbx stub whose `kit add` FAILS with the 0.38 startup-refusal
# error on stderr (exit 1), and whose feature-probe reports ABSENT so the heal
# attempts the add. Everything else no-ops. Used by the refusal tests below.
_plant_sbx_startup_refusal_stub() {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit)
    if [ "${2:-}" = "add" ]; then
      printf 'ERROR: kit "agentic-coding-playbook" declares setup.startup, which the kit-add recreate flow does not yet apply; recreate the sandbox from scratch via `sbx rm` + `sbx create --kit` to use this kit\n' >&2
      exit 1
    fi
    exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
}

# 9q1. The 0.38 startup refusal is DETECTED and surfaced as a single consolidated
#      "recreate to extend/refresh" message — NOT per-kit "Recover with" hints —
#      and provenance is left unknown (no false "current").
make_stubs; load_acq
_plant_sbx_startup_refusal_stub
printf 'refusebox\n' > "$STUBDIR/.sandbox_list"
out=$(acq_backend_ensure_kits_applied refusebox 2>&1) || true
assert_contains "heal(sbx 0.38): prints recreate guidance" "$out" "cannot extend a live sandbox with startup-bearing kits"
assert_contains "heal(sbx 0.38): recreate hint names acq rm + acq run" "$out" "acq rm 'refusebox' && acq run"
assert_not_contains "heal(sbx 0.38): no bogus per-kit Recover-with hint" "$out" "Recover with: sbx kit add"
assert_eq "heal(sbx 0.38): refusal leaves status unknown" "unknown" "$(acq_provenance_status sbx refusebox)"
cleanup_stubs

# 9q2. The consolidated recreate message is printed AT MOST ONCE per heal even
#      though multiple built-in kits are refused.
make_stubs; load_acq
_plant_sbx_startup_refusal_stub
printf 'oncebox\n' > "$STUBDIR/.sandbox_list"
out=$(acq_backend_ensure_kits_applied oncebox 2>&1) || true
_notice_count=$(printf '%s\n' "$out" | grep -c "cannot extend a live sandbox with startup-bearing kits")
assert_eq "heal(sbx 0.38): recreate notice printed exactly once" "1" "$_notice_count"
cleanup_stubs

# 9q2b. REGRESSION (live-run #3): under `set -e` — how real acq and
#       verify-issue-320 run — a refusal must NOT abort the heal at the first
#       kit. The harness normally runs `set +e`, which masked a bug where
#       `_acq_sbx_kit_add` (returning 3/1 as normal signalling) aborted the whole
#       heal before the recreate notice or the remaining kits ran. Reproduce the
#       REAL path: a fresh subshell that sources acq (which sets `set -e`),
#       resolves the backend, and runs the forced heal — with the refusal stub on
#       PATH. Assert the notice prints AND all three built-ins are attempted.
make_stubs; load_acq
_plant_sbx_startup_refusal_stub
printf 'sebox\n' > "$STUBDIR/.sandbox_list"
# Run the heal in a subshell that sources acq exactly as the live re-attach path
# does (ACQ_SOURCE_ONLY keeps `set -e` active from acq's header). Export the
# stub env in the subshell so the child `bash -c` inherits $CALLS/$STUBDIR/$PATH
# and the refusal stub is first on PATH.
out=$(
  export CALLS STUBDIR ACQ_FORCE_KIT_REAPPLY=1
  PATH="$STUBDIR:$PATH" bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    acq_resolve_backend sbx >/dev/null 2>&1
    acq_backend_ensure_kits_applied sebox
  ' 2>&1
) || true
assert_contains "heal(sbx 0.38, set -e): recreate notice still prints" "$out" "cannot extend a live sandbox with startup-bearing kits"
assert_contains "heal(sbx 0.38, set -e): Zscaler kit attempted" "$out" "missing the Zscaler CA kit"
assert_contains "heal(sbx 0.38, set -e): USAi kit still attempted (no early abort)" "$out" "missing the USAi kit"
assert_contains "heal(sbx 0.38, set -e): playbook kit still attempted (no early abort)" "$out" "missing the playbook kit"
cleanup_stubs

# 9q3. `acq kit update` fails fast with the recreate guidance under the refusal
#      (rather than looping per-kit warnings).
make_stubs; load_acq
_plant_sbx_startup_refusal_stub
printf 'updbox\n' > "$STUBDIR/.sandbox_list"
_seed_stale_provenance sbx updbox
out=$(ACQ_BACKEND=sbx "$ACQ" kit update updbox --yes 2>&1); rc=$?
assert_eq "kit update(sbx 0.38): refusal exits nonzero" "1" "$rc"
assert_contains "kit update(sbx 0.38): shows recreate guidance" "$out" "cannot extend a live sandbox with startup-bearing kits"
assert_eq "kit update(sbx 0.38): stays stale (no false current)" "stale" "$(acq_provenance_status sbx updbox)"
cleanup_stubs

# 9q4. A NON-refusal `sbx kit add` failure surfaces sbx's own stderr (no silent
#      failure) rather than the recreate message.
make_stubs; load_acq
cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit) [ "${2:-}" = "add" ] && { printf 'ERROR: some other transient failure\n' >&2; exit 1; }; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBDIR/sbx"
printf 'otherbox\n' > "$STUBDIR/.sandbox_list"
out=$(acq_backend_ensure_kits_applied otherbox 2>&1) || true
assert_contains "heal(sbx): non-refusal failure surfaces sbx stderr" "$out" "some other transient failure"
assert_not_contains "heal(sbx): non-refusal failure is NOT the recreate message" "$out" "cannot extend a live sandbox"
cleanup_stubs

# 9q4b. A REWORDED 0.38 refusal (sbx changes its exact wording but still names
#       startup + recreate) is STILL classified as a refusal, not degraded to a
#       generic failure. Guards the heuristic pattern in _acq_sbx_kit_add against
#       upstream rewording (review finding: the match is prose-anchored).
make_stubs; load_acq
cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit)
    if [ "${2:-}" = "add" ]; then
      # Reworded refusal: no literal "setup.startup" token, but still says the
      # kit declares startup commands and must recreate the sandbox.
      printf 'Error: this kit declares startup commands; recreate the sandbox to apply it\n' >&2
      exit 1
    fi
    exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBDIR/sbx"
printf 'rewordbox\n' > "$STUBDIR/.sandbox_list"
out=$(acq_backend_ensure_kits_applied rewordbox 2>&1) || true
assert_contains "heal(sbx): reworded refusal still classified as recreate" "$out" "cannot extend a live sandbox with startup-bearing kits"
assert_not_contains "heal(sbx): reworded refusal is not surfaced as a raw failure" "$out" "declares startup commands; recreate the sandbox to apply it"
cleanup_stubs

# 9q5. STALE PLAYBOOK PROBE: the heal probes the tarball-era footprint
#      (~/.agentic-coding-playbook/AGENTS.md), NOT the git-clone-era /.git. When
#      AGENTS.md is present the playbook add is skipped; the probe snippet must
#      reference AGENTS.md and never .git.
make_stubs; load_acq
# sbx stub: feature-probe reports PRESENT for any probe (so nothing is added),
# and record the exact probe snippet(s) seen.
cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'present\n' ;; *) exit 0 ;; esac ;;
  kit) exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBDIR/sbx"
printf 'probebox\n' > "$STUBDIR/.sandbox_list"
acq_backend_ensure_kits_applied probebox >/dev/null 2>&1 || true
log=$(cat "$CALLS")
assert_contains "heal(sbx): playbook probe uses AGENTS.md footprint" "$log" ".agentic-coding-playbook/AGENTS.md"
assert_not_contains "heal(sbx): playbook probe no longer uses .git" "$log" ".agentic-coding-playbook/.git"
# All probes reported present, so no built-in kit add was attempted.
assert_not_contains "heal(sbx): present-probe skips playbook add" "$log" "sbx kit add probebox"
cleanup_stubs

# 9q6. CREATE-TIME MARKER: provisioning WITH ACQ_EXTRA_KITS writes each extra kit
#      to ~/.acq-extra-kits, so a subsequent re-attach heal sees it as applied.
make_stubs; load_acq
: > "$CALLS"
( export ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit"
  acq_backend_provision markerbox shell /tmp >/dev/null 2>&1 ) || true
log=$(cat "$CALLS")
assert_contains "provision(sbx): marks extra kit into ~/.acq-extra-kits at create" "$log" ".acq-extra-kits"
assert_contains "provision(sbx): marker records the extra kit ref" "$log" "some-extra-kit"
cleanup_stubs

# 9q7. CREATE-TIME MARKER covers CLI --kit refs (ACQ_CLI_KITS) too.
make_stubs; load_acq
: > "$CALLS"
# shellcheck disable=SC2034  # ACQ_CLI_KITS is consumed by acq_backend_provision (sourced)
( ACQ_CLI_KITS=("git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=cli-kit-x")
  acq_backend_provision climarkerbox shell /tmp >/dev/null 2>&1 ) || true
log=$(cat "$CALLS")
assert_contains "provision(sbx): marks CLI --kit ref into ~/.acq-extra-kits at create" "$log" "cli-kit-x"
cleanup_stubs

# 9q7b. CREATE FAILURE writes NO marker: if `sbx create` fails, the marker block
#       is gated behind the success check, so no ~/.acq-extra-kits write happens
#       (mirrors the provenance-write contract — a failed create claims nothing).
make_stubs; load_acq
# sbx stub whose `create` FAILS; everything else no-ops.
cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  create) printf 'ERROR: create failed\n' >&2; exit 1 ;;
  exec) printf 'ok\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBDIR/sbx"
: > "$CALLS"
( export ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=fail-extra-kit"
  acq_backend_provision failbox shell /tmp >/dev/null 2>&1 ) || true
log=$(cat "$CALLS")
assert_not_contains "provision(sbx): failed create writes NO extra-kit marker" "$log" ".acq-extra-kits"
cleanup_stubs

# 9q8. MARKER SUPPRESSES RE-APPLY: with the marker present, the re-attach heal
#      does NOT re-attempt an already-applied extra kit (so no refusal noise).
make_stubs; load_acq
# sbx stub: built-in probes report present; the marker read returns the extra
# kit ref; record calls. `kit add` would fail if reached (must NOT be reached).
cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      *acq-extra-kits*) printf '%s\n' "git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit" ;;
      *present*) printf 'present\n' ;;
      *) exit 0 ;;
    esac ;;
  kit) [ "${2:-}" = "add" ] && { printf 'ERROR: declares setup.startup\n' >&2; exit 1; }; exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBDIR/sbx"
printf 'skipbox\n' > "$STUBDIR/.sandbox_list"
out=$( ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit" \
       acq_backend_ensure_kits_applied skipbox 2>&1 ) || true
log=$(cat "$CALLS")
assert_not_contains "heal(sbx): marked extra kit is not re-applied" "$log" "sbx kit add skipbox"
assert_not_contains "heal(sbx): marked extra kit yields no refusal noise" "$out" "cannot extend a live sandbox"
cleanup_stubs

