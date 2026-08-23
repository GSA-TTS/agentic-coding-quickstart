#!/usr/bin/env bash
#
# 110-volumes — neutral volumes vocabulary (ADR-0022)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 10a5. ADR-0022: neutral volumes vocabulary
# ===========================================================================
# Adds a neutral top-level `volumes:` list ({path, type?(""|tmpfs), size}),
# consumed by BOTH backends: sbx-v2 passes entries through 1:1 (kit-spec v2
# §5.7); msb maps a block entry to a derived named disk volume (--mount-named
# acq-<sandbox>-<pathslug>:<path>:kind=disk,size=<size>, removed again on
# terminate) and a tmpfs entry to `--tmpfs <path>:<size>`. Invalid entries are
# dropped+warned and reported by kit validate; absence is a no-op.

# 10a5a. Neutral volumes parse to path/type/size records; msb emits
#        --mount-named (block, derived name) + --tmpfs flags; sbx-v2 emits the
#        volumes block with the fields passed through 1:1.
make_stubs; load_acq
vkit="$STUBDIR/vkit"; mkdir -p "$vkit"
cat >"$vkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: vol-kit
displayName: Vol Kit
description: neutral volumes
volumes:
  - path: /var/lib/docker
    size: 20G
  - path: /scratch
    type: tmpfs
    size: 2G
SPEC
v_parse=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_volumes "$vkit/spec.yaml" 2>/dev/null )
assert_contains "vol: neutral parse emits block record" "$v_parse" "$(printf '/var/lib/docker\t\t20G')"
assert_contains "vol: neutral parse emits tmpfs record" "$v_parse" "$(printf '/scratch\ttmpfs\t2G')"
v_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_volume_flags_into arr "$vkit/spec.yaml" volbox; printf '%s\n' "${arr[@]}"
)
assert_contains "vol: msb emits --mount-named flag token" "$v_flags" "--mount-named"
# The derived name carries a POSIX-cksum CRC of the raw path (the slug alone is
# lossy); cksum's CRC algorithm is POSIX-specified, so this is portable.
vck=$(printf '%s' "/var/lib/docker" | cksum | cut -d' ' -f1)
assert_contains "vol: msb block entry derives per-sandbox disk volume" "$v_flags" "acq-volbox-var-lib-docker-${vck}:/var/lib/docker:kind=disk,size=20G"
assert_contains "vol: msb emits --tmpfs flag token" "$v_flags" "--tmpfs"
assert_contains "vol: msb tmpfs entry emits path:size" "$v_flags" "/scratch:2G"
vout="$STUBDIR/vout"
( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_translate_to_sbx "$vkit" "$vout" >/dev/null ) 2>/dev/null
vspec=$(cat "$vout/spec.yaml" 2>/dev/null || true)
assert_contains "vol: sbx-v2 emits volumes block" "$vspec" "volumes:"
assert_contains "vol: sbx-v2 passes block path through" "$vspec" "- path: /var/lib/docker"
assert_contains "vol: sbx-v2 passes size through" "$vspec" "    size: 20G"
assert_contains "vol: sbx-v2 passes tmpfs type through" "$vspec" "    type: tmpfs"
cleanup_stubs

# 10a5b. Validation (SI-10): a relative path, unsafe path, bad type, missing
#        size, metacharacter size, and pathless entry are DROPPED with a stderr
#        warning; the valid entry survives; `acq kit validate` REPORTS each
#        (not silently dropped).
make_stubs; load_acq
badvkit="$STUBDIR/badvkit"; mkdir -p "$badvkit"
cat >"$badvkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bad-vol-kit
displayName: Bad Vol Kit
description: invalid volumes dropped and reported
volumes:
  - path: relative/path
    size: 2G
  - path: /has space
    size: 2G
  - path: /badtype
    type: bind
    size: 2G
  - path: /nosize
  - path: /badsize
    size: 2G; rm -rf /
  - size: 1G
  - path: /nonportable-ib
    size: 2gib
  - path: /nonportable-b
    size: 256MB
  - path: /zero
    size: "0"
  - path: /normdot/.
    size: 1G
  - path: //normslash
    size: 1G
  - path: /normup/../etc
    size: 1G
  - path: /normtrail/
    size: 1G
  - path: /norm/..hidden
    size: 1G
  - path: /ok
    size: 512m
SPEC
badv_out=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_volumes "$badvkit/spec.yaml" 2>/dev/null )
badv_warn=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_volumes "$badvkit/spec.yaml" 2>&1 >/dev/null )
assert_contains "vol: valid entry survives validation" "$badv_out" "/ok"
assert_not_contains "vol: relative path dropped" "$badv_out" "relative/path"
assert_not_contains "vol: unsafe path dropped" "$badv_out" "/has space"
assert_not_contains "vol: bad type entry dropped" "$badv_out" "/badtype"
assert_not_contains "vol: missing-size entry dropped" "$badv_out" "/nosize"
assert_not_contains "vol: metacharacter size dropped" "$badv_out" "rm -rf"
assert_not_contains "vol: sbx-only ib-suffix size dropped (msb rejects it)" "$badv_out" "nonportable-ib"
assert_not_contains "vol: sbx-only b-suffix size dropped (msb rejects it)" "$badv_out" "nonportable-b"
assert_not_contains "vol: zero size dropped" "$badv_out" "/zero"
assert_not_contains "vol: dot-segment path dropped (would shadow guest root)" "$badv_out" "normdot"
assert_not_contains "vol: empty-segment path dropped" "$badv_out" "normslash"
assert_not_contains "vol: dot-dot traversal path dropped" "$badv_out" "normup"
assert_not_contains "vol: trailing-slash path dropped" "$badv_out" "normtrail"
assert_contains "vol: dot-PREFIXED segment name stays legal" "$badv_out" "/norm/..hidden"
assert_contains "vol: warns unsafe path" "$badv_warn" "unsafe path"
assert_contains "vol: warns invalid type" "$badv_warn" "invalid type"
assert_contains "vol: warns missing size" "$badv_warn" "missing size"
assert_contains "vol: warns invalid size" "$badv_warn" "invalid size"
assert_contains "vol: warns zero size" "$badv_warn" "zero size"
assert_contains "vol: warns non-normalized path" "$badv_warn" "non-normalized path"
assert_contains "vol: warns missing path" "$badv_warn" "missing path"
val_vol=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_validate "$badvkit/spec.yaml" 2>&1 )
assert_contains "vol: kit validate reports non-absolute path" "$val_vol" "volume path must be absolute"
assert_contains "vol: kit validate reports illegal path characters" "$val_vol" "volume path has illegal characters"
assert_contains "vol: kit validate reports bad type" "$val_vol" "volume type must be"
assert_contains "vol: kit validate reports missing size" "$val_vol" "volume size is required"
assert_contains "vol: kit validate reports non-portable size" "$val_vol" "volume size must be a portable byte-size"
assert_contains "vol: kit validate reports zero size" "$val_vol" "volume size must be non-zero"
assert_contains "vol: kit validate reports non-normalized path" "$val_vol" "volume path must be normalized"
assert_contains "vol: kit validate reports missing path" "$val_vol" "volume path is required"
cleanup_stubs

# 10a5b2. A valid-but-small block size passes validate (sbx-only kits are
#         legitimate) but WARNS about msb's 128M ext4 floor.
make_stubs; load_acq
smallvkit="$STUBDIR/smallvkit"; mkdir -p "$smallvkit"
cat >"$smallvkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: small-vol-kit
displayName: Small Vol Kit
description: sub-floor block volume warns but validates
volumes:
  - path: /small
    size: 64m
SPEC
val_small=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_validate "$smallvkit/spec.yaml" 2>&1 )
assert_contains "vol: sub-floor block size still validates OK" "$val_small" "kit: validate: OK"
assert_contains "vol: sub-floor block size warns about msb 128M floor" "$val_small" "below msb's 128M ext4 floor"
cleanup_stubs

# 10a5c. Absence of volumes is a NO-OP (empty output, no error) — the neutral
#        field is read DEFENSIVELY, like publishedPorts (ADR-0014 precedent).
make_stubs; load_acq
novkit="$STUBDIR/novkit"; mkdir -p "$novkit"
cat >"$novkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: no-vol-kit
displayName: No Vol Kit
description: no volumes at all
SPEC
nov_out=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_volumes "$novkit/spec.yaml" 2>&1 )
assert_eq "vol: absence of volumes is a no-op" "" "$nov_out"
nov_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_volume_flags_into arr "$novkit/spec.yaml" volbox 2>&1; printf '%s' "${arr[@]:-}"
)
assert_eq "vol: msb emits no volume flags when absent" "" "$nov_flags"
cleanup_stubs

# 10a5d. acq_backend_terminate removes the sandbox's DERIVED volumes
#        (acq-<name>-*) after a successful `msb remove`, and leaves other
#        sandboxes' derived volumes and user-created volumes alone.
make_stubs; load_acq
: > "$CALLS"
printf 'acq-volbox-var-lib-docker\nacq-other-nix\nuser-data\n' > "$STUBDIR/.msb_volume_list"
(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  acq_backend_terminate volbox
) >/dev/null 2>&1
term_log=$(cat "$CALLS")
assert_contains "vol: terminate still removes the sandbox" "$term_log" "msb remove --force volbox"
assert_contains "vol: terminate removes the derived volume" "$term_log" "msb volume rm acq-volbox-var-lib-docker"
assert_not_contains "vol: terminate leaves other sandboxes' derived volumes" "$term_log" "volume rm acq-other-nix"
assert_not_contains "vol: terminate leaves user volumes" "$term_log" "volume rm user-data"
cleanup_stubs

# 10a5e. Slug-collision hardening: the path slug is LOSSY (/data/app and
#        /data.app both slug to data-app), so the derived name carries a CRC of
#        the raw path — two colliding-slug volumes must get DISTINCT names.
make_stubs; load_acq
coll_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_volume_flags_from_records arr volbox <<EOF
$(printf '/data/app\t\t1G\n/data.app\t\t1G')
EOF
  printf '%s\n' "${arr[@]}"
)
ck_a=$(printf '%s' "/data/app" | cksum | cut -d' ' -f1)
ck_b=$(printf '%s' "/data.app" | cksum | cut -d' ' -f1)
assert_contains "vol: colliding slug /data/app gets its own CRC name" "$coll_flags" "acq-volbox-data-app-${ck_a}:/data/app:"
assert_contains "vol: colliding slug /data.app gets its own CRC name" "$coll_flags" "acq-volbox-data-app-${ck_b}:/data.app:"
if [ "$ck_a" != "$ck_b" ]; then
  pass "vol: CRC disambiguates lossy-slug collisions"
else
  fail "vol: CRC disambiguates lossy-slug collisions" "cksum collision for /data/app vs /data.app"
fi
cleanup_stubs

# 10a5f. Union by path, LAST WINS (sbx's own composition rule): two kits
#        declaring the same path must yield ONE --mount-named flag carrying the
#        later size, not two conflicting flags that fail msb's create-or-reuse.
make_stubs; load_acq
union_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_volume_flags_from_records arr volbox <<EOF
$(printf '/var/lib/docker\t\t20G\n/scratch\ttmpfs\t2G\n/var/lib/docker\t\t40G' | _acq_msb_volume_records_dedupe)
EOF
  printf '%s\n' "${arr[@]}"
)
assert_contains "vol: union keeps the LAST size for a repeated path" "$union_flags" "size=40G"
assert_not_contains "vol: union drops the earlier size for a repeated path" "$union_flags" "size=20G"
assert_contains "vol: union leaves distinct paths alone" "$union_flags" "/scratch:2G"
_mn_count=$(printf '%s\n' "$union_flags" | grep -c -- "--mount-named")
assert_eq "vol: exactly one --mount-named for the repeated path" "1" "$_mn_count"
cleanup_stubs

# 10a5g. Terminate volume-cleanup matrix on a FAILED `msb remove`: volumes are
#        cleaned only when the sandbox is confirmed GONE (already removed out
#        of band) — a failed remove of a still-existing sandbox must not touch
#        volumes that may be in use, but the gone case must still clean up or
#        the volumes orphan forever.
make_stubs; load_acq
# (a) remove fails AND the sandbox still exists -> volumes untouched.
: > "$CALLS"
printf 'acq-volbox-var-lib-docker\n' > "$STUBDIR/.msb_volume_list"
printf 'volbox\n' > "$STUBDIR/.msb_sandbox_list"
(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  export STUB_MSB_RM_FAIL=1
  acq_backend_terminate volbox
) >/dev/null 2>&1
term_fail_log=$(cat "$CALLS")
assert_not_contains "vol: failed remove of an EXISTING sandbox keeps its volumes" "$term_fail_log" "volume rm"
# (b) remove fails but the sandbox is GONE (removed out of band) -> clean up.
: > "$CALLS"
rm -f "$STUBDIR/.msb_sandbox_list"
(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  export STUB_MSB_RM_FAIL=1
  acq_backend_terminate volbox
) >/dev/null 2>&1
term_gone_log=$(cat "$CALLS")
assert_contains "vol: failed remove of a GONE sandbox still cleans its volumes" "$term_gone_log" "msb volume rm acq-volbox-var-lib-docker"
cleanup_stubs

# 10a5h. Mid-life `acq kit apply` cannot attach volumes (creation-time only) —
#        the msb apply verb must SAY so instead of silently skipping them.
make_stubs; load_acq
avkit="$STUBDIR/avkit"; mkdir -p "$avkit"
cat >"$avkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: apply-vol-kit
displayName: Apply Vol Kit
description: volumes on mid-life apply warn
volumes:
  - path: /late
    size: 1G
SPEC
apply_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  acq_backend_apply_kit volbox "$avkit" 2>&1
)
assert_contains "vol: mid-life apply warns volumes are creation-time only" "$apply_out" "CREATE time only"
cleanup_stubs


#      own --help example `allow@example.com:tcp:443`), strips any :port, and
#      does NOT use the `domain=`/`domain:` prefixes (domain= can break DNS;
#      domain: is the ambiguous single-label form msb rejects).
make_stubs; load_acq
nr_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  nkit="$STUBDIR/nkit"; mkdir -p "$nkit"
  cat >"$nkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: net-kit
displayName: Net Kit
description: net rule kit
caps:
  network:
    allow:
      - api.gsa.usai.gov
      - github.com:443
SPEC
  arr=()
  _acq_msb_net_rules_into arr "$nkit/spec.yaml"
  printf '%s\n' "${arr[@]}"
)
assert_contains "msb: net-rule uses bare FQDN target" "$nr_out" "allow@api.gsa.usai.gov"
assert_contains "msb: net-rule strips :port" "$nr_out" "allow@github.com"
assert_not_contains "msb: net-rule avoids domain= prefix" "$nr_out" "allow@domain="
assert_not_contains "msb: net-rule avoids ambiguous domain: form" "$nr_out" "allow@domain:"
cleanup_stubs

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

# 10b2. ADR-0015: post-hoc `acq ports <sandbox> --publish H:G` on the msb backend
#       authorizes the acq-managed key (once), starts `msb ssh serve … --port <n>`,
#       and opens `ssh … -L 127.0.0.1:H:127.0.0.1:G …`. The key lives under acq
#       state (NOT ~/.ssh); ports/PIDs are recorded for teardown.
make_stubs; load_acq
: > "$CALLS"
# Pin the ephemeral serve port via the test seam (ACQ_MSB_FORCE_SERVE_PORT) so
# the `msb ssh serve … --port <n>` and `ssh -p <n>` argv are deterministic and
# the assertions below don't race the counter/$RANDOM value.
(
  export ACQ_MSB_FORCE_SERVE_PORT=54321
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 >/dev/null 2>&1
  # `msb ssh serve` and `ssh -L` are BACKGROUNDED by acq; wait for the stubbed
  # children to finish appending to $CALLS before the subshell exits, else the
  # `cat "$CALLS"` below races an incomplete log (test-side flake).
  wait
)
pub_log=$(cat "$CALLS")
assert_contains "msb ports: generates the acq-managed ssh key (ssh-keygen -t ed25519)" \
  "$pub_log" "ssh-keygen -t ed25519 -N  -f $STUBDIR/state/ssh/msb_id_ed25519"
assert_contains "msb ports: authorizes the acq public key via msb ssh authorize" \
  "$pub_log" "msb ssh authorize --file $STUBDIR/state/ssh/msb_id_ed25519.pub"
assert_contains "msb ports: starts msb ssh serve on an ephemeral loopback port" \
  "$pub_log" "msb ssh serve pbox --host 127.0.0.1 --port 54321"
assert_contains "msb ports: opens ssh -L 127.0.0.1:8080:127.0.0.1:3000 tunnel" \
  "$pub_log" "-L 127.0.0.1:8080:127.0.0.1:3000"
assert_contains "msb ports: ssh uses the acq-managed key (-i)" \
  "$pub_log" "-i $STUBDIR/state/ssh/msb_id_ed25519"
assert_contains "msb ports: ssh pins a dedicated known_hosts under acq state" \
  "$pub_log" "UserKnownHostsFile=$STUBDIR/state/ssh/known_hosts"
# NIT (review): ssh uses ONLY the acq -i key and ignores the user's ssh_config,
# so a loaded agent key can't burn MaxAuthTries and ~/.ssh/config can't alter
# the hermetic loopback tunnel.
assert_contains "msb ports: ssh pins IdentitiesOnly=yes (only the acq -i key)" \
  "$pub_log" "IdentitiesOnly=yes"
assert_contains "msb ports: ssh ignores user ssh_config (-F none)" \
  "$pub_log" "-F none"
# The recorded PID/state file exists after publishing (teardown target).
[ -f "$STUBDIR/state/ports/pbox.pids" ] \
  && pass "msb ports: records serve/ssh PIDs in acq state" \
  || fail "msb ports: records serve/ssh PIDs in acq state" "pbox.pids missing"
cleanup_stubs

# 10b2a. (review S2) A backgrounded `msb ssh serve` that dies immediately (e.g.
#        cannot bind) must NOT be reported as a successful publish: acq's
#        liveness probe should fail the publish non-zero, print no "published
#        host" line, and record no PID state file (nothing was actually forwarded).
make_stubs; load_acq
: > "$CALLS"
serve_die_out=$(
  export ACQ_MSB_FORCE_SERVE_PORT=54321 STUB_MSB_SERVE_DIE=1
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 2>&1
  echo "RC=$?"
  wait
)
assert_contains "msb ports(S2): dead serve fails the publish non-zero" "$serve_die_out" "RC=1"
assert_not_contains "msb ports(S2): dead serve prints no 'published host' success" "$serve_die_out" "published host"
[ ! -f "$STUBDIR/state/ports/pbox.pids" ] \
  && pass "msb ports(S2): dead serve records no PID state file" \
  || fail "msb ports(S2): dead serve records no PID state file" "pbox.pids should not exist"
cleanup_stubs

# 10b2b. (review S2) A backgrounded `ssh -L` forward that dies immediately (e.g.
#        ExitOnForwardFailure fires) must NOT be reported as success: the publish
#        fails non-zero, tears the serve listener back down, and records no state.
make_stubs; load_acq
: > "$CALLS"
fwd_die_out=$(
  export ACQ_MSB_FORCE_SERVE_PORT=54321 STUB_SSH_DIE=1
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 2>&1
  echo "RC=$?"
  wait
)
assert_contains "msb ports(S2): dead forward fails the publish non-zero" "$fwd_die_out" "RC=1"
assert_not_contains "msb ports(S2): dead forward prints no 'published host' success" "$fwd_die_out" "published host"
[ ! -f "$STUBDIR/state/ports/pbox.pids" ] \
  && pass "msb ports(S2): dead forward records no PID state file" \
  || fail "msb ports(S2): dead forward records no PID state file" "pbox.pids should not exist"
cleanup_stubs

# 10b3. `acq ports --publish` authorizes the key ONCE — a second publish reuses
#       the existing key and the .authorized marker (no re-keygen, no re-authorize).
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports pbox --publish 8080:3000 >/dev/null 2>&1
  wait                # let the 1st publish's backgrounded serve/ssh log first
  : > "$CALLS"   # clear, then a SECOND publish
  acq_backend_ports pbox --publish 9090:4000 >/dev/null 2>&1
  wait                # drain the 2nd publish's backgrounded children before read
)
pub2_log=$(cat "$CALLS")
assert_not_contains "msb ports: 2nd publish does not re-run ssh-keygen" "$pub2_log" "ssh-keygen"
assert_not_contains "msb ports: 2nd publish does not re-authorize the key" "$pub2_log" "msb ssh authorize"
assert_contains "msb ports: 2nd publish still opens its own -L tunnel" "$pub2_log" "-L 127.0.0.1:9090:127.0.0.1:4000"
cleanup_stubs

# 10b3a. Two publishes in the SAME process must get DISTINCT serve ports.
#        No seam here — this exercises the real distinct-per-call selection. The
#        recorded state file has one line per publish: `<serve_pid> <ssh_pid>
#        <sport> <mapping>`; assert the two <sport> columns differ.
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports mpbox --publish 8080:3000 >/dev/null 2>&1
  acq_backend_ports mpbox --publish 9090:4000 >/dev/null 2>&1
  wait
)
mp_ports=$(awk '{print $3}' "$STUBDIR/state/ports/mpbox.pids" 2>/dev/null | sort -u | wc -l | tr -d ' ')
mp_lines=$(wc -l < "$STUBDIR/state/ports/mpbox.pids" 2>/dev/null | tr -d ' ')
{ [ "$mp_lines" = "2" ] && [ "$mp_ports" = "2" ]; } \
  && pass "msb ports: two publishes in one process get DISTINCT serve ports" \
  || fail "msb ports: two publishes in one process get DISTINCT serve ports" "lines=$mp_lines distinct-ports=$mp_ports"
cleanup_stubs

# 10b4. SI-10: invalid --publish values are REJECTED before any ssh/serve call.
#       0, 70000 (>65535), and non-integer "abc:def" all fail non-zero with no
#       ssh/serve/keygen in the call log.
for bad in "0:3000" "8080:70000" "abc:def" "8080"; do
  make_stubs; load_acq
  : > "$CALLS"
  rc=0
  bad_out=$(
    . "${REPO_ROOT}/acq.backends/msb.sh"
    acq_backend_ports badbox --publish "$bad" 2>&1
  ) || rc=$?
  bad_log=$(cat "$CALLS")
  [ "$rc" -ne 0 ] && pass "msb ports: rejects invalid --publish '$bad' (non-zero exit)" \
    || fail "msb ports: rejects invalid --publish '$bad' (non-zero exit)" "rc=$rc"
  assert_not_contains "msb ports: '$bad' reaches no ssh -L" "$bad_log" "-L 127.0.0.1"
  assert_not_contains "msb ports: '$bad' reaches no msb ssh serve" "$bad_log" "msb ssh serve"
  cleanup_stubs
done

# 10b5. Capability flag: msb now advertises post-hoc port forwarding (ADR-0015).
flag_val=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  printf '%s' "$ACQ_BACKEND_SUPPORTS_PORT_FORWARD"
)
assert_eq "msb: SUPPORTS_PORT_FORWARD is now 1 (post-hoc publish wired)" "1" "$flag_val"

# 10b6. TEARDOWN: acq_backend_terminate (rm) and acq_backend_stop both clean up
#       the recorded serve/ssh PIDs + state file for the sandbox (defensive:
#       killing dead PIDs is a no-op, and a missing state file is fine).
make_stubs; load_acq
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports rmbox --publish 8080:3000 >/dev/null 2>&1
  [ -f "$STUBDIR/state/ports/rmbox.pids" ] || exit 3
  acq_backend_terminate rmbox >/dev/null 2>&1
)
[ ! -f "$STUBDIR/state/ports/rmbox.pids" ] \
  && pass "msb ports: acq rm tears down recorded port state" \
  || fail "msb ports: acq rm tears down recorded port state" "rmbox.pids still present"
# stop path + defensive no-op on a sandbox that never published a port.
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports stopbox --publish 7000:7000 >/dev/null 2>&1
  acq_backend_stop stopbox >/dev/null 2>&1
  acq_backend_terminate neverbox >/dev/null 2>&1   # no state file -> must not error
) && pass "msb ports: stop tears down; teardown of an un-published sandbox is a no-op" \
  || fail "msb ports: stop tears down; teardown of an un-published sandbox is a no-op" "teardown errored"
[ ! -f "$STUBDIR/state/ports/stopbox.pids" ] \
  && pass "msb ports: acq stop removes recorded port state" \
  || fail "msb ports: acq stop removes recorded port state" "stopbox.pids still present"
cleanup_stubs

# 10b7. Path-traversal guard: an unsafe sandbox name (slash / leading '..') must
#       NOT let the per-sandbox PID state path escape ACQ_MSB_PORTS_DIR on either
#       the record (>>) or teardown (rm -f) path. record is a fail-closed no-op;
#       teardown of an unsafe name touches no file outside the ports dir.
make_stubs; load_acq
: > "$CALLS"
mkdir -p "$STUBDIR/state/ports"
canary="$STUBDIR/state/traversal-canary.pids"
printf 'DO-NOT-DELETE\n' >"$canary"
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # record with a traversal name must write nothing outside the ports dir.
  _acq_msb_ports_record "../traversal-canary" 111 222 20001 8080:3000 >/dev/null 2>&1
  # teardown with a traversal name must not rm -f the canary above it.
  _acq_msb_ports_teardown "../traversal-canary" >/dev/null 2>&1
)
[ -f "$canary" ] \
  && pass "msb ports: unsafe sandbox name cannot escape state dir (rm -f/append guarded)" \
  || fail "msb ports: unsafe sandbox name cannot escape state dir (rm -f/append guarded)" "canary deleted"
[ ! -e "$STUBDIR/state/traversal-canary.pids.pids" ] \
  && pass "msb ports: unsafe sandbox name records no state file" \
  || fail "msb ports: unsafe sandbox name records no state file" "escaped record written"
rm -f "$canary" 2>/dev/null || true
cleanup_stubs

# 10b8. LIST mode: `acq ports <name>` with NO --publish is a QUERY, not an
#       error. It must exit 0 and print lines CONTAINING the published port
#       numbers so openchamber verify's `grep -q <port>` matches. Two sources:
#       (a) create-time `-p` NAT mappings via `msb inspect --format json`, and
#       (b) acq-recorded post-hoc ssh -L tunnels. Both surfaced together.
make_stubs; load_acq
# (a) plant a create-time published-ports JSON fixture for `msb inspect` using the
#     REAL msb 0.6.7 shape: ports live under active_config.network.ports[] as
#     {host_port, guest_port, host_bind, protocol}. host_bind carries a dotted IP
#     (127.0.0.1) that must NOT be mistaken for port digits. The third entry binds
#     host_bind to a colon-bearing "127.0.0.1:9" form (the exact shape that caused
#     the live bug) so the no-junk assert below is a TRUE regression guard: the old
#     parser split that colon and emitted `guest 9 -> host 127.0.0.1:1`, while the
#     current parser keys on the explicit *_port fields and yields 8443 correctly.
printf '%s\n' '{"active_config":{"network":{"ports":[{"guest_port":3000,"host_bind":"127.0.0.1","host_port":3000,"protocol":"tcp"},{"guest_port":4096,"host_bind":"127.0.0.1","host_port":4096,"protocol":"tcp"},{"guest_port":8443,"host_bind":"127.0.0.1:9","host_port":8443,"protocol":"tcp"}]}},"name":"listbox","status":"Running"}' \
  >"$STUBDIR/.msb_inspect_json"
list_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # (b) also seed a recorded post-hoc tunnel so both sources appear.
  _acq_msb_ports_record listbox 111 222 54321 9090:8080
  acq_backend_ports listbox
) ; list_rc=$?
assert_eq "msb ports: LIST mode (no --publish) exits 0 (query, not error)" "0" "$list_rc"
printf '%s\n' "$list_out" | grep -q 3000 \
  && pass "msb ports: LIST surfaces create-time port 3000 (grep -q 3000 matches)" \
  || fail "msb ports: LIST surfaces create-time port 3000" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -q 4096 \
  && pass "msb ports: LIST surfaces create-time port 4096 (grep -q 4096 matches)" \
  || fail "msb ports: LIST surfaces create-time port 4096" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -q 8080 \
  && pass "msb ports: LIST surfaces post-hoc recorded guest port 8080" \
  || fail "msb ports: LIST surfaces post-hoc recorded guest port 8080" "out=[$list_out]"
# The create-time lines must be EXACT (no host_bind dotted-IP or SocketAddr digits
# leaking in as ports). The old numeric-pairing parser split the colon in the
# third entry's host_bind ("127.0.0.1:9") and emitted `guest 9 -> host 127.0.0.1:1`
# instead of the real 8443:8443 mapping — these asserts fail against that old code.
printf '%s\n' "$list_out" | grep -q 'sandbox 3000 -> host 127.0.0.1:3000 (create-time -p)' \
  && pass "msb ports: LIST prints exact create-time mapping for 3000 (no host_bind leak)" \
  || fail "msb ports: LIST exact create-time mapping for 3000" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -q 'sandbox 8443 -> host 127.0.0.1:8443 (create-time -p)' \
  && pass "msb ports: LIST maps colon-bearing host_bind entry to real port 8443 (not split)" \
  || fail "msb ports: LIST exact create-time mapping for 8443 (colon-bearing host_bind)" "out=[$list_out]"
printf '%s\n' "$list_out" | grep -Eq '127\.0\.0\.1:(1|9|16|00|256)( |$)' \
  && fail "msb ports: LIST must NOT emit host_bind-derived junk ports" "out=[$list_out]" \
  || pass "msb ports: LIST emits no host_bind-derived junk ports (IP/SocketAddr not split)"
cleanup_stubs

# 10b9. LIST mode is graceful when there are NO ports at all (no inspect fixture,
#       no recorded tunnel): exit 0, no crash, empty (or portless) output.
make_stubs; load_acq
# none_out captures output only to confirm no crash; we assert on the exit code.
# shellcheck disable=SC2034
none_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports emptybox
) ; none_rc=$?
assert_eq "msb ports: LIST with zero ports exits 0 (empty list not an error)" "0" "$none_rc"
cleanup_stubs

# 10b10. LIST mode degrades gracefully when msb's JSON has NO recognizable port
#        field (defensive: unknown field name / jq absent). Must NOT crash; still
#        exit 0. Here inspect returns JSON with an unrelated shape.
make_stubs; load_acq
printf '{"name":"absentbox","state":"running"}\n' >"$STUBDIR/.msb_inspect_json"
absent_rc=0
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports absentbox
) >/dev/null 2>&1 || absent_rc=$?
assert_eq "msb ports: LIST exits 0 when no port field found in msb JSON" "0" "$absent_rc"
cleanup_stubs

# 10b10a. LIST mode under the REAL `set -euo pipefail` acq runs with. This is the
#         regression guard for the live-host bug: when inspect has no ports, the
#         dependency-free `grep` (and jq) emit nothing and exit non-zero, which
#         under `set -e` aborted _acq_msb_ports_from_inspect BEFORE its return 0,
#         unwinding out of acq_backend_ports past its `return 0` and surfacing
#         rc=1 to the caller. The rest of test-acq runs WITHOUT -e, so it could
#         not catch this — assert it explicitly here with errexit ON.
make_stubs; load_acq
printf '{"active_config":{"network":{"ports":[]}}}\n' >"$STUBDIR/.msb_inspect_json"
strict_rc=0
(
  set -euo pipefail
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports emptybox
) >/dev/null 2>&1 || strict_rc=$?
assert_eq "msb ports: LIST exits 0 under set -euo pipefail with empty ports (live-host regression)" "0" "$strict_rc"
cleanup_stubs

# 10b11. Genuinely bad args still error (unsupported argument), LIST mode does
#        NOT swallow a bogus flag like --frobnicate.
make_stubs; load_acq
bad_rc=0
bad_out=$(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_ports badargbox --frobnicate 2>&1
) || bad_rc=$?
[ "$bad_rc" -ne 0 ] \
  && pass "msb ports: unsupported arg (--frobnicate) still errors non-zero" \
  || fail "msb ports: unsupported arg (--frobnicate) still errors non-zero" "rc=$bad_rc"
assert_contains "msb ports: unsupported arg names the offending flag" "$bad_out" "unsupported argument"
cleanup_stubs

