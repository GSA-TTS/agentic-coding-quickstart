#!/usr/bin/env bash
#
# 111-balanced-egress — network-tier / balanced-egress rules (ADR-0018/0019, 10b1)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 10b1a. ADR-0018 balanced-egress: `_acq_msb_balanced_target` maps the sbx
#        multi-label glob `**.h` to msb's suffix form `*.h` (apex + any depth).
make_stubs; load_acq
bt_a=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  _acq_msb_balanced_target '**.github.com' 2>/dev/null
)
assert_eq "msb: balanced target **.h -> *.h" "*.github.com" "$bt_a"
cleanup_stubs

# 10b1b. `_acq_msb_balanced_target` broadens the intra-label glob `crl*.h`
#        (which msb cannot express) to the parent suffix `*.<parent>`.
make_stubs; load_acq
bt_b=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  _acq_msb_balanced_target 'crl*.digicert.com' 2>/dev/null
)
assert_eq "msb: balanced target crl*.h -> *.<parent>" "*.digicert.com" "$bt_b"
cleanup_stubs

# 10b1c. `_acq_msb_balanced_target` passes an exact domain through unchanged.
make_stubs; load_acq
bt_c=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  _acq_msb_balanced_target 'api.anthropic.com' 2>/dev/null
)
assert_eq "msb: balanced target exact domain unchanged" "api.anthropic.com" "$bt_c"
cleanup_stubs

# 10b1d. `_acq_msb_balanced_target` DROPS a single-label suffix `*.com` (msb
#        rejects it for blast radius): nonzero rc AND nothing on stdout.
make_stubs; load_acq
bt_d_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  out=$(_acq_msb_balanced_target '*.com' 2>/dev/null); rc=$?
  printf '%s|%s\n' "$out" "$rc"
)
bt_d_val="${bt_d_out%%|*}"
bt_d_rc="${bt_d_out##*|}"
assert_eq "msb: balanced target *.com emits nothing" "" "$bt_d_val"
assert_not_contains "msb: balanced target *.com returns nonzero" "rc-${bt_d_rc}" "rc-0"
cleanup_stubs

# 10b1e. `_acq_msb_balanced_port_ok`: 443/80 valid (rc 0); 0, 70000, "", "4a3"
#        invalid (nonzero).
make_stubs; load_acq
bp_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  _acq_msb_balanced_port_ok 443; r443=$?
  _acq_msb_balanced_port_ok 80;  r80=$?
  _acq_msb_balanced_port_ok 0;   r0=$?
  _acq_msb_balanced_port_ok 70000; rbig=$?
  _acq_msb_balanced_port_ok "";  rempty=$?
  _acq_msb_balanced_port_ok "4a3"; ralpha=$?
  printf '%s %s %s %s %s %s\n' "$r443" "$r80" "$r0" "$rbig" "$rempty" "$ralpha"
)
set -- $bp_out
assert_eq "msb: port_ok 443 valid" "0" "$1"
assert_eq "msb: port_ok 80 valid" "0" "$2"
assert_not_contains "msb: port_ok 0 invalid" "rc-$3" "rc-0"
assert_not_contains "msb: port_ok 70000 invalid" "rc-$4" "rc-0"
assert_not_contains "msb: port_ok empty invalid" "rc-$5" "rc-0"
assert_not_contains "msb: port_ok non-integer invalid" "rc-$6" "rc-0"
cleanup_stubs

# 10b1f. `_acq_msb_balanced_rules_into` on a small custom hosts file: emits the
#        `allow@dns` macro first, translates wildcards/crl*, preserves dual-port
#        hosts, emits bare (no :tcp:) for a port-less entry, and skips
#        comments/blanks.
make_stubs; load_acq
cat >"$STUBDIR/bal-hosts.txt" <<'HOSTS'
# a comment line

**.github.com:443
github.com:443
dhi.io:443
dhi.io:80
crl*.digicert.com:80
example.org
HOSTS
bal_out=$(
  export ACQ_MSB_BALANCED_HOSTS_FILE="$STUBDIR/bal-hosts.txt"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=()
  _acq_msb_balanced_rules_into arr 2>/dev/null
  printf '%s\n' "${arr[@]}"
)
assert_contains "msb: balanced rules emit gateway DNS via allow@dns macro" "$bal_out" "allow@dns"
assert_not_contains "msb: balanced rules do not emit expanded udp/53 pair" "$bal_out" "allow@host:udp:53"
assert_not_contains "msb: balanced rules do not emit expanded tcp/53 pair" "$bal_out" "allow@host:tcp:53"
assert_contains "msb: balanced rules translate **.h wildcard" "$bal_out" "allow@*.github.com:tcp:443"
assert_contains "msb: balanced rules keep exact domain" "$bal_out" "allow@github.com:tcp:443"
assert_contains "msb: balanced rules keep dual-port :443" "$bal_out" "allow@dhi.io:tcp:443"
assert_contains "msb: balanced rules keep dual-port :80" "$bal_out" "allow@dhi.io:tcp:80"
assert_contains "msb: balanced rules broaden crl* to parent suffix" "$bal_out" "allow@*.digicert.com:tcp:80"
assert_contains "msb: balanced rules emit bare rule for port-less entry" "$bal_out" "allow@example.org"
assert_not_contains "msb: balanced rules drop comment lines" "$bal_out" "#"
assert_not_contains "msb: balanced rules never emit an empty target" "$bal_out" "allow@:"
cleanup_stubs

# 10b1g. `_acq_msb_balanced_rules_into` skips a malformed line (a host with a
#        shell metacharacter) with a warning, but still emits the gateway-DNS
#        rule. That rule is the semantic `allow@dns` macro (safe since acq
#        requires msb >= 0.6.9, the upstream release-build parser fix), NOT the
#        old expanded udp/tcp:53 pair.
make_stubs; load_acq
cat >"$STUBDIR/bal-bad.txt" <<'HOSTS'
bad;host:443
github.com:443
HOSTS
bad_out=$(
  export ACQ_MSB_BALANCED_HOSTS_FILE="$STUBDIR/bal-bad.txt"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=()
  _acq_msb_balanced_rules_into arr 2>/dev/null
  printf '%s\n' "${arr[@]}"
)
assert_not_contains "msb: balanced rules skip malformed host" "$bad_out" "bad;host"
assert_contains "msb: balanced rules still emit gateway DNS (allow@dns) after skip" "$bad_out" "allow@dns"
assert_not_contains "msb: balanced rules no longer emit the expanded DNS pair" "$bad_out" "allow@host:udp:53"
cleanup_stubs

# 10b1h. The REAL vendored balanced-hosts file parses cleanly: no "skipping"
#        warnings on stderr (the crl* broadening NOTE is expected/fine), and the
#        emitted rule set is large (> 190 tokens) — a sanity check on the mirror.
make_stubs; load_acq
real_err="$STUBDIR/bal-real.err"
real_gt=$(
  export ACQ_SCRIPT_DIR="$REPO_ROOT"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=()
  _acq_msb_balanced_rules_into arr 2>"$real_err"
  [ "${#arr[@]}" -gt 190 ] && echo GT || echo LE
)
real_stderr=$(cat "$real_err" 2>/dev/null || true)
assert_not_contains "msb: real balanced file parses with no skipped entries" "$real_stderr" "skipping"
assert_eq "msb: real balanced file yields > 190 rules" "GT" "$real_gt"
cleanup_stubs

# 10b1i. Provision (default, ACQ_MSB_BALANCED_EGRESS unset) emits the balanced
#        egress baseline: `--net-default-egress deny`, the gateway-DNS rules, and
#        a representative translated host rule appear in the recorded `msb create`
#        argv. The deny-default is EGRESS-ONLY (ADR-0019): it must NOT emit the
#        symmetric `--net-default deny` (which would RST inbound to published
#        ports) nor an ingress deny-default.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/bal-prov-secrets"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision balprovbox shell /tmp >/dev/null 2>&1
)
bal_prov_log=$(cat "$CALLS")
assert_contains "msb: default provision emits --net-default-egress deny" "$bal_prov_log" "--net-default-egress deny"
assert_not_contains "msb: default provision does NOT emit symmetric --net-default deny" "$bal_prov_log" "--net-default deny"
assert_not_contains "msb: default provision does NOT deny ingress" "$bal_prov_log" "--net-default-ingress deny"
assert_contains "msb: default provision emits gateway DNS (allow@dns)" "$bal_prov_log" "allow@dns"
assert_not_contains "msb: default provision does NOT emit expanded udp/53 pair" "$bal_prov_log" "allow@host:udp:53"
assert_contains "msb: default provision emits a balanced host rule" "$bal_prov_log" "allow@api.anthropic.com:tcp:443"
cleanup_stubs

# 10b1j. Provision with the deprecated ACQ_MSB_BALANCED_EGRESS=0 now maps to the
#        `strict` tier (fail-safe: deny-by-default, kit hosts ONLY). It STILL
#        emits `--net-default-egress deny` + gateway DNS (unlike the old
#        permissive off-path), but NONE of the curated baseline host rules.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/bal-off-secrets"
  export ACQ_MSB_BALANCED_EGRESS=0
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision baloffbox shell /tmp >/dev/null 2>&1
)
bal_off_log=$(cat "$CALLS")
assert_contains "msb: deprecated =0 maps to strict — still emits deny-default" "$bal_off_log" "--net-default-egress deny"
assert_contains "msb: deprecated =0 (strict) still emits gateway DNS (allow@dns)" "$bal_off_log" "allow@dns"
assert_not_contains "msb: deprecated =0 (strict) omits balanced host rules" "$bal_off_log" "allow@api.anthropic.com"

# 10b1j2. The deprecated alias prints a one-time deprecation notice on stderr,
#         naming the neutral selector and the =0 -> strict mapping.
make_stubs; load_acq
alias_warn=$(
  export ACQ_MSB_BALANCED_EGRESS=0
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>&1 >/dev/null
)
assert_contains "msb: alias emits deprecation notice" "$alias_warn" "ACQ_MSB_BALANCED_EGRESS is deprecated"
assert_contains "msb: alias notice names the strict mapping" "$alias_warn" "ACQ_NETWORK_TIER=strict"
cleanup_stubs

# 10b1j3. ACQ_MSB_BALANCED_EGRESS=1 maps to the `balanced` tier (curated baseline
#         present), preserving pre-deprecation on-path behavior.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/alias-on-secrets"
  export ACQ_MSB_BALANCED_EGRESS=1
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision aliasonbox shell /tmp >/dev/null 2>&1
)
alias_on_log=$(cat "$CALLS")
assert_contains "msb: deprecated =1 maps to balanced (deny-default)" "$alias_on_log" "--net-default-egress deny"
assert_contains "msb: deprecated =1 maps to balanced (baseline present)" "$alias_on_log" "allow@api.anthropic.com:tcp:443"
cleanup_stubs

# 10b1j4. ACQ_NETWORK_TIER wins when BOTH it and the deprecated alias are set:
#         alias=1 (would be balanced) but tier=strict -> strict wins (no baseline).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/tier-wins-secrets"
  export ACQ_MSB_BALANCED_EGRESS=1
  export ACQ_NETWORK_TIER=strict
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision tierwinsbox shell /tmp >/dev/null 2>&1
)
tier_wins_log=$(cat "$CALLS")
assert_contains "msb: ACQ_NETWORK_TIER wins over alias — deny-default present" "$tier_wins_log" "--net-default-egress deny"
assert_not_contains "msb: ACQ_NETWORK_TIER=strict wins over alias=1 — no baseline" "$tier_wins_log" "allow@api.anthropic.com"
cleanup_stubs

# 10b1j5. ACQ_NETWORK_TIER=strict (explicit) emits deny-default + gateway DNS,
#         NO curated baseline. The strict emission path is deny-default WITHOUT
#         the baseline emitter — the core new behavior.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/strict-secrets"
  export ACQ_NETWORK_TIER=strict
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision strictbox shell /tmp >/dev/null 2>&1
)
strict_log=$(cat "$CALLS")
assert_contains "msb: strict emits deny-default" "$strict_log" "--net-default-egress deny"
assert_contains "msb: strict emits gateway DNS (allow@dns)" "$strict_log" "allow@dns"
assert_not_contains "msb: strict does NOT emit expanded udp/53 pair" "$strict_log" "allow@host:udp:53"
assert_not_contains "msb: strict omits the curated baseline" "$strict_log" "allow@api.anthropic.com"
cleanup_stubs

# 10b1j6. ACQ_NETWORK_TIER=balanced (explicit) == default: deny-default + baseline.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/balanced-secrets"
  export ACQ_NETWORK_TIER=balanced
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision balancedbox shell /tmp >/dev/null 2>&1
)
balanced_log=$(cat "$CALLS")
assert_contains "msb: explicit balanced emits deny-default" "$balanced_log" "--net-default-egress deny"
assert_contains "msb: explicit balanced emits the curated baseline" "$balanced_log" "allow@api.anthropic.com:tcp:443"
cleanup_stubs

# 10b1j7. ACQ_NETWORK_TIER=open WITHOUT the confirm token fails closed: provision
#         returns non-zero and emits NO deny-default (the sandbox is not created
#         with unrestricted egress by accident).
make_stubs; load_acq
: > "$CALLS"
open_norc=0
open_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/open-noconfirm-secrets"
  export ACQ_NETWORK_TIER=open
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision opennoconfirmbox shell /tmp 2>&1 >/dev/null
) || open_norc=$?
if [ "$open_norc" -ne 0 ]; then
  pass "msb: open without confirm token fails closed (rc != 0)"
else
  fail "msb: open without confirm token fails closed (rc != 0)" "provision returned 0"
fi
assert_contains "msb: open without confirm names the confirm token" "$open_err" "ACQ_NETWORK_TIER_CONFIRM_OPEN=1"
cleanup_stubs

# 10b1j8. ACQ_NETWORK_TIER=open WITH the confirm token: NO deny-default emitted
#         (unrestricted egress), a warning is printed, kit rules still ride along.
make_stubs; load_acq
: > "$CALLS"
open_ok_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/open-confirm-secrets"
  export ACQ_NETWORK_TIER=open
  export ACQ_NETWORK_TIER_CONFIRM_OPEN=1
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision openconfirmbox shell /tmp 2>&1 >/dev/null
)
open_ok_log=$(cat "$CALLS")
assert_not_contains "msb: open (confirmed) emits NO deny-default" "$open_ok_log" "--net-default-egress deny"
assert_contains "msb: open (confirmed) warns about unrestricted egress" "$open_ok_err" "UNRESTRICTED"
cleanup_stubs

# 10b1j9. An invalid ACQ_NETWORK_TIER value fails closed to `balanced` (with a
#         warning), never to open — mirrors the ACQ_MSB_SHORT_NAME_MODE validator.
make_stubs; load_acq
: > "$CALLS"
invalid_tier_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/invalid-tier-secrets"
  export ACQ_NETWORK_TIER=bogus
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>&1 >/dev/null
  acq_backend_provision invalidtierbox shell /tmp >/dev/null 2>&1
)
invalid_tier_log=$(cat "$CALLS")
assert_contains "msb: invalid tier warns" "$invalid_tier_err" "invalid ACQ_NETWORK_TIER"
assert_contains "msb: invalid tier falls back to balanced (deny-default)" "$invalid_tier_log" "--net-default-egress deny"
assert_contains "msb: invalid tier falls back to balanced (baseline)" "$invalid_tier_log" "allow@api.anthropic.com:tcp:443"
cleanup_stubs

# 10b1j10. A mixed-case tier value (e.g. StRiCt) is lowercased and honored — it
#          must NOT fall through to the invalid->balanced path.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/mixedcase-secrets"
  export ACQ_NETWORK_TIER=StRiCt
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision mixedcasebox shell /tmp >/dev/null 2>&1
)
mixedcase_log=$(cat "$CALLS")
assert_contains "msb: mixed-case StRiCt lowercased -> strict (deny-default)" "$mixedcase_log" "--net-default-egress deny"
assert_not_contains "msb: mixed-case StRiCt honored as strict (no baseline)" "$mixedcase_log" "allow@api.anthropic.com"
cleanup_stubs

# 10b1k. npm-registry de-dupe: registry.npmjs.org is IN the balanced set, so with
#        the baseline ON and an agent that has an install recipe (opencode), the
#        adapter must NOT emit a SECOND bare `allow@registry.npmjs.org` (the
#        balanced block already covers it). The balanced rule (with :tcp:443) is
#        still present. Guards against the double-emit the reviewer flagged.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npm-dedupe-secrets"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmdedupebox opencode /tmp >/dev/null 2>&1
)
npm_dedupe_log=$(cat "$CALLS")
# The balanced rule (port-qualified) is present ...
assert_contains "msb: npm de-dupe keeps the balanced registry rule" "$npm_dedupe_log" "allow@registry.npmjs.org:tcp:443"
# ... but the redundant bare rule is NOT emitted.
assert_not_contains "msb: npm de-dupe drops the redundant bare registry rule" "$npm_dedupe_log" "allow@registry.npmjs.org "
cleanup_stubs

# 10b1l. npm rule for an OVERRIDE host NOT in the balanced set is still emitted:
#        de-dupe elides only hosts the balanced block already covers, so an
#        internal-mirror override (ACQ_MSB_NPM_HOSTS) still gets its allow rule.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npm-override-secrets"
  export ACQ_MSB_NPM_HOSTS="npm.internal.example.gov"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmoverridebox opencode /tmp >/dev/null 2>&1
)
npm_override_log=$(cat "$CALLS")
assert_contains "msb: npm override host (not in balanced set) still gets a rule" "$npm_override_log" "allow@npm.internal.example.gov"
cleanup_stubs
