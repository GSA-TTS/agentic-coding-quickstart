#!/usr/bin/env bash
#
# 85-kit-provenance — kit-bundle provenance + staleness
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 9p. Kit-bundle provenance + staleness
# ===========================================================================
# These drive the provenance helpers directly (host-side, no sandbox exec) and
# the `acq kit check|update` subcommands via the stubbed backends. ACQ_PROVENANCE_DIR
# is isolated per-test by make_stubs.

# 9p1. Fresh (no record) reads as "unknown"; write makes it "current"; a local
#      pin bump makes it "stale".
make_stubs; load_acq
_pin=$(printf '%s' "$PATTERNS_KIT_REF")
assert_eq "provenance: no record -> unknown" "unknown" "$(acq_provenance_status sbx pbox)"
acq_provenance_write sbx pbox
assert_eq "provenance: after write -> current" "current" "$(acq_provenance_status sbx pbox)"
assert_eq "provenance: records applied_ref" "$_pin" "$(acq_provenance_field sbx pbox applied_ref)"
assert_eq "provenance: records bundle name" "acq-builtin" "$(acq_provenance_field sbx pbox bundle)"
(
  PATTERNS_KIT_REF="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  assert_eq "provenance: pin bump -> stale" "stale" "$(acq_provenance_status sbx pbox)"
)
cleanup_stubs

# 9p2. Backend keying: same name under sbx vs msb does not collide.
make_stubs; load_acq
acq_provenance_write sbx dup
assert_eq "provenance: sbx write doesn't affect msb" "unknown" "$(acq_provenance_status msb dup)"
acq_provenance_write msb dup
assert_eq "provenance: msb now current" "current" "$(acq_provenance_status msb dup)"
assert_eq "provenance: sbx still current" "current" "$(acq_provenance_status sbx dup)"
cleanup_stubs

# 9p3. Sandbox name with path metacharacters is sanitized to a safe filename
#      (no directory traversal in the state dir).
make_stubs; load_acq
acq_provenance_write sbx "evil/../../name"
_travel=$(find "$ACQ_PROVENANCE_DIR" -name '*.env' 2>/dev/null | head -n1)
# Slashes are collapsed to underscores (no path escape); the record file lives
# directly under the sbx dir, not in a traversed parent.
assert_contains "provenance: name sanitized (no slash escape)" "$_travel" "evil_.._.._name"
assert_contains "provenance: record stays under sbx dir" "$_travel" "/sbx/"
cleanup_stubs

# 9p3b. Two distinct names that sanitize to the same string do NOT alias onto one
#       record (cksum suffix disambiguates "a/b" vs "a_b").
make_stubs; load_acq
acq_provenance_write sbx "a/b"          # -> current
# "a_b" has no record of its own; it must read as unknown, not inherit "a/b".
assert_eq "provenance: sanitizer collision disambiguated" "unknown" "$(acq_provenance_status sbx "a_b")"
cleanup_stubs

# 9p4. `acq kit check` reports status without mutating the record (read-only).
make_stubs; load_acq
printf 'cbox\n' > "$STUBDIR/.sandbox_list"   # sandbox exists
acq_provenance_write sbx cbox           # seed a current record
out=$(ACQ_BACKEND=sbx "$ACQ" kit check cbox 2>&1); rc=$?
assert_eq "kit check: exits 0" "0" "$rc"
assert_contains "kit check: reports current" "$out" "current"
assert_contains "kit check: shows applied ref" "$out" "$_pin"
# Read-only: still current, and CALLS shows no sbx kit add.
log=$(cat "$CALLS")
assert_not_contains "kit check: does not add kits" "$log" "sbx kit add"
cleanup_stubs

# 9p5. `acq kit check` on a legacy sandbox (no record) reports unknown + hint.
make_stubs; load_acq
printf 'legacybox\n' > "$STUBDIR/.sandbox_list"   # sandbox exists to sbx
out=$(ACQ_BACKEND=sbx "$ACQ" kit check legacybox 2>&1)
assert_contains "kit check: unknown status" "$out" "unknown"
assert_contains "kit check: suggests update" "$out" "acq kit update legacybox"
cleanup_stubs

# 9p6. `acq kit check` with no sandbox arg errors.
make_stubs; load_acq
out=$(ACQ_BACKEND=sbx "$ACQ" kit check 2>&1); rc=$?
assert_eq "kit check: missing arg exits 1" "1" "$rc"
assert_contains "kit check: usage on missing arg" "$out" "usage: acq kit check"
cleanup_stubs

# Helper: seed a STALE provenance record for a sandbox via the real helper path
# (so the cksum-suffixed filename matches what acq will look up), then rewrite the
# applied_ref to an older value in place.
_seed_stale_provenance() {
  local backend="$1" name="$2" f
  acq_provenance_write "$backend" "$name"
  f=$(_acq_provenance_file "$backend" "$name")
  # Replace the current applied_ref line with an obviously-old ref.
  awk '/^applied_ref=/ { print "applied_ref=oldoldoldoldoldoldoldoldoldoldoldoldoldo"; next } { print }' "$f" > "$f.seed" && mv -f "$f.seed" "$f"
}

# 9p7. `acq kit update SANDBOX --yes` reapplies the bundle and refreshes
#      provenance (stale -> current) on the sbx backend.
make_stubs; load_acq
printf 'ubox\n' > "$STUBDIR/.sandbox_list"        # sandbox exists
_seed_stale_provenance sbx ubox
assert_eq "kit update: precondition stale" "stale" "$(acq_provenance_status sbx ubox)"
out=$(ACQ_BACKEND=sbx "$ACQ" kit update ubox --yes 2>&1); rc=$?
assert_eq "kit update --yes: exits 0" "0" "$rc"
assert_eq "kit update --yes: now current" "current" "$(acq_provenance_status sbx ubox)"
cleanup_stubs

# 9p8. `acq kit update` already-current is a no-op success (no reapply).
make_stubs; load_acq
printf 'okbox\n' > "$STUBDIR/.sandbox_list"
acq_provenance_write sbx okbox          # current
out=$(ACQ_BACKEND=sbx "$ACQ" kit update okbox --yes 2>&1); rc=$?
assert_eq "kit update: current is no-op exit 0" "0" "$rc"
assert_contains "kit update: says already current" "$out" "already on the pinned bundle"
cleanup_stubs

# 9p9. `acq kit update` non-interactively WITHOUT --yes refuses (safety).
make_stubs; load_acq
printf 'nbox\n' > "$STUBDIR/.sandbox_list"
_seed_stale_provenance sbx nbox
out=$(ACQ_BACKEND=sbx "$ACQ" kit update nbox </dev/null 2>&1); rc=$?
assert_eq "kit update: no --yes non-interactive exits 1" "1" "$rc"
assert_contains "kit update: refuses without --yes" "$out" "without --yes"
cleanup_stubs

# 9p10. `acq kit update` on a missing sandbox errors clearly.
make_stubs; load_acq
: > "$STUBDIR/.sandbox_list"             # no sandboxes
out=$(ACQ_BACKEND=sbx "$ACQ" kit update ghost --yes 2>&1); rc=$?
assert_eq "kit update: missing sandbox exits 1" "1" "$rc"
assert_contains "kit update: no such sandbox" "$out" "no such sandbox"
cleanup_stubs

# 9p11. maybe_offer_bundle_refresh is silent + non-blocking when current.
make_stubs; load_acq
acq_provenance_write sbx runbox
out=$(maybe_offer_bundle_refresh sbx runbox </dev/null 2>&1); rc=$?
assert_eq "run-check: current returns 0" "0" "$rc"
assert_eq "run-check: current is silent" "" "$out"
cleanup_stubs

# 9p12. maybe_offer_bundle_refresh non-interactive on a stale sandbox advises
#       but NEVER blocks (returns 0, no prompt).
make_stubs; load_acq
_seed_stale_provenance sbx stalebox
out=$(maybe_offer_bundle_refresh sbx stalebox </dev/null 2>&1); rc=$?
assert_eq "run-check: stale non-interactive returns 0" "0" "$rc"
assert_contains "run-check: advises kit update" "$out" "acq kit update stalebox"
assert_contains "run-check: mentions opt-out" "$out" "ACQ_UPDATE_CHECK=0"
cleanup_stubs

# 9p12b. A pre-heal status arg of "stale" makes the helper offer even though the
#        on-disk record now reads current (models the real acq run ordering:
#        heal writes current, but we captured stale beforehand). Non-interactive
#        so it advises + returns 0.
make_stubs; load_acq
acq_provenance_write sbx orderbox     # on-disk = current
out=$(maybe_offer_bundle_refresh sbx orderbox stale </dev/null 2>&1); rc=$?
assert_eq "run-check: pre-heal-stale arg returns 0" "0" "$rc"
assert_contains "run-check: pre-heal-stale arg still advises" "$out" "acq kit update orderbox"
cleanup_stubs

# 9p13. ACQ_UPDATE_CHECK=0 fully silences the run-check even when stale.
make_stubs; load_acq
_seed_stale_provenance sbx optout
out=$( ACQ_UPDATE_CHECK=0 maybe_offer_bundle_refresh sbx optout </dev/null 2>&1 )
assert_eq "run-check: opt-out silences advisory" "" "$out"
cleanup_stubs

# 9p13b. A failed built-in kit apply must NOT write provenance (no false
#        "current"). Force every `sbx kit add` to fail and confirm status stays
#        unknown after a heal.
make_stubs; load_acq
# Make the sbx stub report kits ABSENT (so the add path runs) but fail `kit add`.
cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  kit) [ "${2:-}" = "add" ] && exit 1 || exit 0 ;;
  exec)
    # Feature-probe wrapper prints "absent" so ensure_kits_applied tries kit add.
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBDIR/sbx"
printf 'failbox\n' > "$STUBDIR/.sandbox_list"
acq_backend_ensure_kits_applied failbox >/dev/null 2>&1 || true
assert_eq "heal(sbx): failed apply leaves status unknown" "unknown" "$(acq_provenance_status sbx failbox)"
cleanup_stubs

# 9p14. Provision records provenance on the sbx backend (write-after-success).
make_stubs; load_acq
: > "$CALLS"
acq_backend_provision provbox shell /tmp >/dev/null 2>&1 || true
assert_eq "provision(sbx): records provenance" "current" "$(acq_provenance_status sbx provbox)"
cleanup_stubs

# 9p15. ensure_kits_applied (heal) records provenance on the sbx backend.
make_stubs; load_acq
printf 'healbox\n' > "$STUBDIR/.sandbox_list"
acq_backend_ensure_kits_applied healbox >/dev/null 2>&1 || true
assert_eq "heal(sbx): records provenance" "current" "$(acq_provenance_status sbx healbox)"
cleanup_stubs

# 9p16. (review NON-BLOCKING, ADR-0021) sbx forwards the host ssh-agent
#       IMPLICITLY when SSH_AUTH_SOCK is set; acq surfaces that as a conscious
#       choice with a one-time provision notice naming the opt-out and ssh-add -c.
#       When SSH_AUTH_SOCK is UNSET, no notice fires (nothing is forwarded).
make_stubs; load_acq
sbx_note=$(
  export SSH_AUTH_SOCK="$STUBDIR/does-not-matter.sock"
  acq_backend_provision notebox shell /tmp 2>&1 >/dev/null
)
assert_contains "provision(sbx): SSH_AUTH_SOCK set prints a trust-boundary notice" "$sbx_note" "forwards your host ssh-agent"
assert_contains "provision(sbx): notice names the SSH_AUTH_SOCK opt-out" "$sbx_note" "unset SSH_AUTH_SOCK to opt out"
assert_contains "provision(sbx): notice surfaces the ssh-add -c mitigation" "$sbx_note" "ssh-add -c"
cleanup_stubs
make_stubs; load_acq
sbx_nonote=$(
  unset SSH_AUTH_SOCK
  acq_backend_provision quietbox shell /tmp 2>&1 >/dev/null
)
assert_not_contains "provision(sbx): no notice when SSH_AUTH_SOCK is unset" "$sbx_nonote" "forwards your host ssh-agent"
cleanup_stubs

