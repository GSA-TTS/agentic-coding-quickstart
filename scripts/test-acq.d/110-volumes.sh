#!/usr/bin/env bash
#
# 110-volumes — neutral volumes vocabulary (ADR-0022, 10a5)
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

