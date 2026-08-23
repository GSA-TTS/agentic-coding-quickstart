#!/usr/bin/env bash
#
# 105-ports-background — neutral publishedPorts + background (ADR-0014)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 10a4. ADR-0014: neutral publishedPorts + background vocabulary
# ===========================================================================
# Promotes publishedPorts to a NEUTRAL top-level list and background to a
# commands[] flag, consumed by BOTH backends. Covers: neutral parse -> sbx-v2 +
# msb -p; deprecated backend_extras.sbx fallback WITH warning; background emitted
# detached on both backends; invalid port/protocol/name/background dropped+warned;
# absence is a no-op.

# 10a4a. Neutral publishedPorts parses to guest/proto/name/host (host defaults to
#        guest), and msb maps each to `-p HOST:GUEST`.
make_stubs; load_acq
ppkit="$STUBDIR/ppkit"; mkdir -p "$ppkit"
cat >"$ppkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: pp-kit
displayName: PP Kit
description: neutral publishedPorts
publishedPorts:
  - guest: 3000
    host: 8080
    protocol: tcp
    name: ui
  - guest: 4096
    protocol: tcp
    name: api
SPEC
pp_parse=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$ppkit/spec.yaml" 2>/dev/null )
assert_contains "pp: neutral parse maps guest 3000 -> host 8080" "$pp_parse" "$(printf '3000\ttcp\tui\t8080')"
assert_contains "pp: neutral host defaults to guest when omitted" "$pp_parse" "$(printf '4096\ttcp\tapi\t4096')"
# msb consumer: -p HOST:GUEST flags into the create array.
pp_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_port_flags_into arr "$ppkit/spec.yaml"; printf '%s\n' "${arr[@]}"
)
assert_contains "pp: msb emits -p 8080:3000 (explicit host)" "$pp_flags" "8080:3000"
assert_contains "pp: msb emits -p 4096:4096 (host defaults to guest)" "$pp_flags" "4096:4096"
assert_contains "pp: msb emits a -p flag token" "$pp_flags" "-p"
# sbx-v2 synthesis: the neutral source produces the top-level ports block.
ppout="$STUBDIR/ppout"
( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_translate_to_sbx "$ppkit" "$ppout" >/dev/null ) 2>/dev/null
ppspec=$(cat "$ppout/spec.yaml" 2>/dev/null || true)
assert_contains "pp: sbx-v2 emits ports block from neutral source" "$ppspec" "ports:"
assert_not_contains "pp: sbx-v2 omits unsupported publishedPorts key" "$ppspec" "publishedPorts:"
assert_contains "pp: sbx-v2 emits port from neutral source" "$ppspec" "- container: 3000"
assert_contains "pp: sbx-v2 emits second neutral port" "$ppspec" "- container: 4096"
cleanup_stubs

# 10a4b. Legacy backend_extras.sbx.publishedPorts STILL translates (one release)
#        but emits a DEPRECATION warning to stderr. sbx-v2 shape remains ports.
make_stubs; load_acq
lpkit="$STUBDIR/lpkit"; mkdir -p "$lpkit"
cat >"$lpkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: legacy-pp-kit
displayName: Legacy PP Kit
description: deprecated sbx-only ports
backend_extras:
  sbx:
    publishedPorts:
      - container: 3000
        protocol: tcp
        name: web
SPEC
lp_out=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$lpkit/spec.yaml" 2>/dev/null )
lp_warn=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$lpkit/spec.yaml" 2>&1 >/dev/null )
assert_contains "pp: legacy backend_extras.sbx still translates" "$lp_out" "$(printf '3000\ttcp\tweb\t3000')"
assert_contains "pp: legacy path warns DEPRECATION" "$lp_warn" "DEPRECATION"
assert_contains "pp: legacy warning names backend_extras.sbx.publishedPorts" "$lp_warn" "backend_extras.sbx.publishedPorts"
# msb consumer honors the legacy fallback too (-p HOST:GUEST for the sbx block).
lp_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_port_flags_into arr "$lpkit/spec.yaml" 2>/dev/null; printf '%s\n' "${arr[@]}"
)
assert_contains "pp: msb -p from legacy fallback" "$lp_flags" "3000:3000"
cleanup_stubs

# 10a4c. A neutral list SUPPRESSES the deprecated fallback (no warning when the
#        neutral field is present, even if a stray backend_extras.sbx also is).
make_stubs; load_acq
bothkit="$STUBDIR/bothkit"; mkdir -p "$bothkit"
cat >"$bothkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: both-kit
displayName: Both Kit
description: neutral wins over legacy
publishedPorts:
  - guest: 5000
    name: neutral-port
backend_extras:
  sbx:
    publishedPorts:
      - container: 9999
        name: legacy-port
SPEC
both_out=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$bothkit/spec.yaml" 2>/dev/null )
both_warn=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$bothkit/spec.yaml" 2>&1 >/dev/null )
assert_contains "pp: neutral list wins (guest 5000)" "$both_out" "5000"
assert_not_contains "pp: legacy port ignored when neutral present" "$both_out" "9999"
assert_not_contains "pp: no deprecation warning when neutral present" "$both_warn" "DEPRECATION"
cleanup_stubs

# 10a4d. Validation (SI-10): invalid port/protocol/name are DROPPED with a
#        stderr warning; only the valid entry survives.
make_stubs; load_acq
badpkit="$STUBDIR/badpkit"; mkdir -p "$badpkit"
cat >"$badpkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bad-pp-kit
displayName: Bad PP Kit
description: invalid published ports dropped
publishedPorts:
  - guest: 99999
    name: too-big
  - guest: 3000
    protocol: sctp
    name: bad-proto
  - guest: 3001
    name: "bad name!"
  - guest: 3002
    host: notanumber
  - guest: 3003
    protocol: tcp
    name: ok
SPEC
bad_out=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$badpkit/spec.yaml" 2>/dev/null )
bad_warn=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$badpkit/spec.yaml" 2>&1 >/dev/null )
assert_contains "pp: valid entry survives validation" "$bad_out" "3003"
assert_not_contains "pp: out-of-range port dropped" "$bad_out" "99999"
assert_not_contains "pp: bad protocol entry dropped" "$bad_out" "3000"
assert_not_contains "pp: unsafe name entry dropped" "$bad_out" "3001"
assert_not_contains "pp: non-integer host entry dropped" "$bad_out" "3002"
assert_contains "pp: warns invalid guest port" "$bad_warn" "invalid guest port"
assert_contains "pp: warns invalid protocol" "$bad_warn" "invalid protocol"
assert_contains "pp: warns unsafe name" "$bad_warn" "unsafe name"
assert_contains "pp: warns invalid host port" "$bad_warn" "invalid host port"
# `acq kit validate` REPORTS these (not silently dropped).
val_out=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_validate "$badpkit/spec.yaml" 2>&1 )
assert_contains "pp: kit validate reports invalid publishedPorts" "$val_out" "invalid publishedPorts entry"
cleanup_stubs

# 10a4e. Absence of publishedPorts is a NO-OP (empty output, no error) — the
#        neutral fields are read DEFENSIVELY (cross-repo gate: schema unreleased).
make_stubs; load_acq
nonekit="$STUBDIR/nonekit"; mkdir -p "$nonekit"
cat >"$nonekit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: none-kit
displayName: None Kit
description: no ports at all
SPEC
none_out=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_published_ports "$nonekit/spec.yaml" 2>&1 )
assert_eq "pp: absence of publishedPorts is a no-op" "" "$none_out"
none_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_port_flags_into arr "$nonekit/spec.yaml" 2>&1; printf '%s' "${arr[@]:-}"
)
assert_eq "pp: msb emits no -p flags when absent" "" "$none_flags"
cleanup_stubs

# 10a4f. background: a commands[] entry with background:true surfaces in the
#        __CMD__ record as the 4th field; a non-boolean is coerced to false+warn.
make_stubs; load_acq
bgkit="$STUBDIR/bgkit"; mkdir -p "$bgkit"
cat >"$bgkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bg-kit
displayName: BG Kit
description: background startup command
commands:
  - phase: startup
    user: "1000"
    background: true
    command:
      - sh
      - -c
      - |
        while true; do sleep 5; done
  - phase: startup
    user: "1000"
    background: maybe
    command:
      - node
      - /home/agent/run.mjs
SPEC
bg_cmds=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_commands "$bgkit/spec.yaml" 2>/dev/null )
assert_contains "bg: background:true surfaces in __CMD__ record" "$bg_cmds" "$(printf '__CMD__\tstartup\t1000\ttrue')"
assert_contains "bg: non-boolean coerced to false in record" "$bg_cmds" "$(printf '__CMD__\tstartup\t1000\tfalse')"
bg_warn=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_spec_commands "$bgkit/spec.yaml" 2>&1 >/dev/null )
assert_contains "bg: non-boolean background warns" "$bg_warn" "background must be true|false"
val_bg=$( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_validate "$bgkit/spec.yaml" 2>&1 )
assert_contains "bg: kit validate reports non-boolean background" "$val_bg" "command background must be true|false"
cleanup_stubs

# 10a4g. msb runs a background:true startup command DETACHED (nohup … &) so it
#        does not block provision; a foreground startup command is awaited.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/bg-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  bgk="$STUBDIR/bgk2"; mkdir -p "$bgk"
  cat >"$bgk/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: bg2-kit
displayName: BG2 Kit
description: background + foreground startup
commands:
  - phase: startup
    user: "0"
    background: true
    command:
      - supervisor-loop
  - phase: startup
    user: "0"
    command:
      - foreground-cmd
SPEC
  _acq_msb_run_commands bgbox "$bgk/spec.yaml"
)
bg_log=$(cat "$CALLS")
assert_contains "bg(msb): background startup runs detached (nohup &)" "$bg_log" "nohup"
assert_contains "bg(msb): detached command is the supervisor loop" "$bg_log" "supervisor-loop"
assert_contains "bg(msb): foreground startup command still awaited (no nohup wrap)" "$bg_log" "-- foreground-cmd"
cleanup_stubs

# 10a4h. sbx path: v2 setup.startup supports `background: true`, so the
#        translator preserves the flag without wrapping the command in nohup.
make_stubs; load_acq
sbgkit="$STUBDIR/sbgkit"; mkdir -p "$sbgkit"
cat >"$sbgkit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: sbg-kit
displayName: SBG Kit
description: background startup on sbx
commands:
  - phase: startup
    user: "1000"
    background: true
    command:
      - sh
      - -c
      - |
        sh /home/agent/supervisor.sh &
SPEC
sbgout="$STUBDIR/sbgout"
( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_translate_to_sbx "$sbgkit" "$sbgout" >/dev/null ) 2>/dev/null
sbgspec=$(cat "$sbgout/spec.yaml" 2>/dev/null || true)
assert_contains "bg(sbx): setup startup phase present" "$sbgspec" "  startup:"
assert_contains "bg(sbx): self-backgrounding argv emitted as startup command" "$sbgspec" "        - sh"
assert_contains "bg(sbx): trailing & preserved in the sh -c body" "$sbgspec" "sh /home/agent/supervisor.sh &"
assert_contains "bg(sbx): background flag preserved" "$sbgspec" "background: true"
assert_not_contains "bg(sbx): translator does NOT wrap in nohup" "$sbgspec" "nohup"
assert_not_contains "bg(sbx): translator does NOT emit a double-background & &" "$sbgspec" "& &"
_amp_count=$(printf '%s\n' "$sbgspec" | grep -cE '(^|[^&])&([^&]|$)')
assert_eq "bg(sbx): exactly one backgrounding & survives translation" "1" "$_amp_count"
cleanup_stubs

# 10a4i. REGRESSION: an entry with guest + host but NO protocol/name must keep
#        the host column in place. Tab is IFS whitespace, so the former
#        `IFS=<tab> read` consumers COLLAPSED the empty middle fields of the
#        "3000<TAB><TAB><TAB>8080" record: msb emitted `-p 3000:3000` (explicit
#        host silently lost) and the sbx-v2 spec gained `protocol: 8080`. Both
#        consumers now cut fields positionally.
make_stubs; load_acq
hokit="$STUBDIR/hokit"; mkdir -p "$hokit"
cat >"$hokit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: host-only-kit
displayName: Host Only Kit
description: guest plus host with no protocol or name
publishedPorts:
  - guest: 3000
    host: 8080
SPEC
ho_flags=$(
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>/dev/null
  arr=(); _acq_msb_port_flags_into arr "$hokit/spec.yaml"; printf '%s\n' "${arr[@]}"
)
assert_contains "pp: msb keeps explicit host with no protocol/name" "$ho_flags" "8080:3000"
assert_not_contains "pp: msb does not collapse to guest:guest" "$ho_flags" "3000:3000"
hoout="$STUBDIR/hoout"
( . "${REPO_ROOT}/acq.backends/kit-translate.sh"; kit_translate_to_sbx "$hokit" "$hoout" >/dev/null ) 2>/dev/null
hospec=$(cat "$hoout/spec.yaml" 2>/dev/null || true)
assert_contains "pp: sbx-v2 emits container with no protocol/name" "$hospec" "- container: 3000"
assert_not_contains "pp: sbx-v2 does not leak host column into protocol" "$hospec" "protocol: 8080"
cleanup_stubs

