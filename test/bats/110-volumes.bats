#!/usr/bin/env bats
#
# 110-volumes.bats — bats port of scripts/test-acq.d/110-volumes.sh (ADR-0022,
# ADR-0025)
#
# Neutral volumes vocabulary: parse to path/type/size records, msb --mount-named
# (derived CRC name) + --tmpfs synthesis, sbx-v2 passthrough, validation, derived-
# volume cleanup on terminate, slug-collision CRC, union-last-wins, and the
# msb net-rule target form. Array-returning helpers (`_into`) are exercised in
# `run bash -c` subshells that print the array.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "vol: neutral volumes parse to records; msb emits --mount-named + --tmpfs; sbx-v2 passes through" {
  local vkit="$STUBDIR/vkit" vout="$STUBDIR/vout"
  mkdir -p "$vkit"
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
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_volumes "'"$vkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial "$(printf '/var/lib/docker\t\t20G')"
  assert_output --partial "$(printf '/scratch\ttmpfs\t2G')"

  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_volume_flags_into arr "'"$vkit"'/spec.yaml" volbox; printf "%s\n" "${arr[@]}"
  '
  local vck; vck=$(printf '%s' "/var/lib/docker" | cksum | cut -d' ' -f1)
  assert_output --partial '--mount-named'
  assert_output --partial "acq-volbox-var-lib-docker-${vck}:/var/lib/docker:kind=disk,size=20G"
  assert_output --partial '--tmpfs'
  assert_output --partial '/scratch:2G'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_translate_to_sbx "'"$vkit"'" "'"$vout"'" >/dev/null 2>&1'
  local spec; spec=$(cat "$vout/spec.yaml")
  assert_regex "$spec" 'volumes:'
  assert_regex "$spec" '- path: /var/lib/docker'
  assert_regex "$spec" '    size: 20G'
  assert_regex "$spec" '    type: tmpfs'
}

@test "vol: invalid volume entries are dropped+warned and reported by kit validate" {
  local badvkit="$STUBDIR/badvkit"; mkdir -p "$badvkit"
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
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_volumes "'"$badvkit"'/spec.yaml" 2>/dev/null'
  assert_output --partial '/ok'
  refute_output --partial 'relative/path'
  refute_output --partial '/has space'
  refute_output --partial '/badtype'
  refute_output --partial '/nosize'
  refute_output --partial 'rm -rf'
  refute_output --partial 'nonportable-ib'
  refute_output --partial 'nonportable-b'
  refute_output --partial '/zero'
  refute_output --partial 'normdot'
  refute_output --partial 'normslash'
  refute_output --partial 'normup'
  refute_output --partial 'normtrail'
  assert_output --partial '/norm/..hidden'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_volumes "'"$badvkit"'/spec.yaml" 2>&1 >/dev/null'
  assert_output --partial 'unsafe path'
  assert_output --partial 'invalid type'
  assert_output --partial 'missing size'
  assert_output --partial 'invalid size'
  assert_output --partial 'zero size'
  assert_output --partial 'non-normalized path'
  assert_output --partial 'missing path'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_validate "'"$badvkit"'/spec.yaml" 2>&1'
  assert_output --partial 'volume path must be absolute'
  assert_output --partial 'volume path has illegal characters'
  assert_output --partial 'volume type must be'
  assert_output --partial 'volume size is required'
  assert_output --partial 'volume size must be a portable byte-size'
  assert_output --partial 'volume size must be non-zero'
  assert_output --partial 'volume path must be normalized'
  assert_output --partial 'volume path is required'
}

@test "vol: a sub-floor block size validates OK but warns about msb's 128M floor" {
  local smallvkit="$STUBDIR/smallvkit"; mkdir -p "$smallvkit"
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
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_validate "'"$smallvkit"'/spec.yaml" 2>&1'
  assert_output --partial 'kit: validate: OK'
  assert_output --partial "below msb's 128M ext4 floor"
}

@test "vol: absence of volumes is a no-op for parse and msb flags" {
  local novkit="$STUBDIR/novkit"; mkdir -p "$novkit"
  cat >"$novkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: no-vol-kit
displayName: No Vol Kit
description: no volumes at all
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_volumes "'"$novkit"'/spec.yaml" 2>&1'
  assert_output ''
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_volume_flags_into arr "'"$novkit"'/spec.yaml" volbox 2>&1; printf "%s" "${arr[@]:-}"
  '
  assert_output ''
}

@test "vol: terminate removes the sandbox's derived volumes, leaves others alone" {
  : > "$CALLS"
  printf 'acq-volbox-var-lib-docker\nacq-other-nix\nuser-data\n' > "$STUBDIR/.msb_volume_list"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null; acq_backend_terminate volbox >/dev/null 2>&1'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb remove --force volbox'
  assert_regex "$log" 'msb volume rm acq-volbox-var-lib-docker'
  refute_regex "$log" 'volume rm acq-other-nix'
  refute_regex "$log" 'volume rm user-data'
}

@test "vol: colliding path slugs get distinct CRC-suffixed derived names" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_volume_flags_from_records arr volbox <<EOF
$(printf "/data/app\t\t1G\n/data.app\t\t1G")
EOF
    printf "%s\n" "${arr[@]}"
  '
  local ck_a ck_b
  ck_a=$(printf '%s' "/data/app" | cksum | cut -d' ' -f1)
  ck_b=$(printf '%s' "/data.app" | cksum | cut -d' ' -f1)
  assert_output --partial "acq-volbox-data-app-${ck_a}:/data/app:"
  assert_output --partial "acq-volbox-data-app-${ck_b}:/data.app:"
  assert_not_equal "$ck_a" "$ck_b"
}

@test "vol: union by path is last-wins, one --mount-named for a repeated path" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_volume_flags_from_records arr volbox <<EOF
$(printf "/var/lib/docker\t\t20G\n/scratch\ttmpfs\t2G\n/var/lib/docker\t\t40G" | _acq_msb_volume_records_dedupe)
EOF
    printf "%s\n" "${arr[@]}"
  '
  assert_output --partial 'size=40G'
  refute_output --partial 'size=20G'
  assert_output --partial '/scratch:2G'
  local n; n=$(printf '%s\n' "$output" | grep -c -- '--mount-named')
  assert_equal "$n" "1"
}

@test "vol: terminate cleans volumes only when the sandbox is confirmed gone" {
  # (a) remove fails AND the sandbox still exists -> volumes untouched.
  : > "$CALLS"
  printf 'acq-volbox-var-lib-docker\n' > "$STUBDIR/.msb_volume_list"
  printf 'volbox\n' > "$STUBDIR/.msb_sandbox_list"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null; STUB_MSB_RM_FAIL=1 acq_backend_terminate volbox >/dev/null 2>&1'
  refute_regex "$(cat "$CALLS")" 'volume rm'
  # (b) remove fails but the sandbox is GONE out of band -> clean up.
  : > "$CALLS"
  rm -f "$STUBDIR/.msb_sandbox_list"
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null; STUB_MSB_RM_FAIL=1 acq_backend_terminate volbox >/dev/null 2>&1'
  assert_regex "$(cat "$CALLS")" 'msb volume rm acq-volbox-var-lib-docker'
}

@test "vol: mid-life kit apply warns that volumes are creation-time only" {
  local avkit="$STUBDIR/avkit"; mkdir -p "$avkit"
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
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null; acq_backend_apply_kit volbox "'"$avkit"'" 2>&1'
  assert_output --partial 'CREATE time only'
}

@test "msb: net-rule uses a bare FQDN target, strips :port, avoids domain= / domain: forms" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    nkit="'"$STUBDIR"'/nkit"; mkdir -p "$nkit"
    cat >"$nkit/spec.yaml" <<'"'"'SPEC'"'"'
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
    arr=(); _acq_msb_net_rules_into arr "$nkit/spec.yaml"; printf "%s\n" "${arr[@]}"
  '
  assert_output --partial 'allow@api.gsa.usai.gov'
  assert_output --partial 'allow@github.com'
  refute_output --partial 'allow@domain='
  refute_output --partial 'allow@domain:'
}
