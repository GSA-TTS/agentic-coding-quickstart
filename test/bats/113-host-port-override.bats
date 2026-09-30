#!/usr/bin/env bats
#
# 113-host-port-override.bats — create-time HOST port selection (ADR-0034)
#
# Part A (the collision fix): a kit entry that omits `host:` must get a FREE
# loopback host port PER SANDBOX, so two sandboxes from one kit do not both
# request the guest port and silently fight over it. An explicitly requested
# host port that is already taken must FAIL loudly, never be substituted.
#
# The host-listener probe is stubbed (acq_setup_stubs exports
# ACQ_MSB_HOST_PROBE_STUB=1, and ACQ_MSB_HOST_PORTS_BUSY names the busy ports),
# so nothing here binds a socket or depends on what the host is listening on.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Write a mixin kit that publishes GUEST (optionally pinned to HOST) and echo its
# directory. Usage: _pp_kit NAME GUEST [HOST]
_pp_kit() {
  local _dir="$STUBDIR/$1" _guest="$2" _host="${3:-}"
  mkdir -p "$_dir"
  {
    printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: %s\n' "$1"
    printf 'displayName: %s\ndescription: publishes a port\n' "$1"
    printf 'publishedPorts:\n  - guest: %s\n' "$_guest"
    [ -n "$_host" ] && printf '    host: %s\n' "$_host"
  } > "$_dir/spec.yaml"
  printf '%s\n' "$_dir"
}

# Provision SANDBOX on msb with KITDIR as its only CLI kit, in an isolated
# subshell, and echo the resulting `msb create` argv line. Extra `KEY=VAL` env
# assignments may precede the `--`. Usage:
#   _provision_line [KEY=VAL...] -- SANDBOX KITDIR
_provision_line() {
  local _env=() ; while [ "$1" != "--" ]; do _env+=("$1"); shift; done; shift
  local _name="$1" _kit="$2"
  : > "$CALLS"
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/sec-$_name"
    export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/stage-$_name"
    local _kv; for _kv in ${_env[@]+"${_env[@]}"}; do export "${_kv?}"; done
    # shellcheck source=acq.backends/secret-store.sh
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    # shellcheck source=acq.backends/msb.sh
    . "${REPO_ROOT}/acq.backends/msb.sh"
    ACQ_CLI_KITS=("$_kit")
    _acq_msb_fetch_kit() { printf '%s\n' "$_kit"; }
    acq_backend_provision "$_name" shell /tmp ) >/dev/null 2>&1 || true
  grep '^msb create' "$CALLS" | head -n1
}

@test "hostport(A): an omitted kit host: no longer defaults to the guest port" {
  local k; k=$(_pp_kit nohostkit 6767)
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    arr=(); _acq_msb_port_flags_into arr "'"$k"'/spec.yaml"; printf "%s\n" "${arr[@]}"
  '
  assert_success
  refute_output --partial '6767:6767'
  assert_regex "$output" '(^|
)-p(
|$)'
  assert_regex "$output" '[0-9]{5}:6767'
}

@test "hostport(A): two sandboxes from the SAME kit get DIFFERENT host ports" {
  local k; k=$(_pp_kit parkit 6767)
  local one two hone htwo
  one=$(_provision_line -- parone "$k")
  two=$(_provision_line -- partwo "$k")
  # Both must publish guest 6767 ...
  assert_regex "$one" '\-p [0-9]+:6767'
  assert_regex "$two" '\-p [0-9]+:6767'
  # ... on DIFFERENT host ports. Before ADR-0034 both were `-p 6767:6767` and the
  # second sandbox's UI was silently unreachable.
  hone=$(printf '%s\n' "$one" | sed -n 's/.*-p \([0-9]*\):6767.*/\1/p')
  htwo=$(printf '%s\n' "$two" | sed -n 's/.*-p \([0-9]*\):6767.*/\1/p')
  assert [ -n "$hone" ]
  assert [ -n "$htwo" ]
  assert_not_equal "$hone" "$htwo"
}

@test "hostport(A): a kit's explicit host: is still honored verbatim" {
  local k; k=$(_pp_kit pinkit 3000 8080)
  local line; line=$(_provision_line -- pinbox "$k")
  assert_regex "$line" '\-p 8080:3000'
}

@test "hostport(A): a contended explicit host port FAILS and is not substituted" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    export ACQ_MSB_HOST_PORTS_BUSY=8080
    arr=()
    _acq_msb_port_flags_from_records arr <<REC
$(printf "3000\t\t\t8080")
REC
    echo "rc=$?"
    printf "%s\n" "${arr[@]:-}"
  '
  assert_output --partial 'rc=1'
  assert_output --partial 'already'
  refute_output --partial '8080:3000'
  # No silent fallback to some other host port for an EXPLICIT request.
  refute_regex "$output" '[0-9]+:3000'
}

@test "hostport(A): a busy CHOSEN port is skipped, an unknown probe warns once" {
  # The picker retries past a busy candidate. Pin the first candidate busy and
  # let the counter advance to a free one.
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    export ACQ_MSB_HOST_PORTS_BUSY=25010
    export ACQ_MSB_FORCE_SERVE_PORT=25010
    arr=(); _acq_msb_port_flags_from_records arr <<REC
$(printf "3000\t\t\t")
REC
    echo "rc=$?"
  '
  # Every candidate is the forced busy one, so the picker gives up — loudly.
  assert_output --partial 'rc=1'
  assert_output --partial 'could not find a free host port'

  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null
    export ACQ_MSB_HOST_PROBE_UNKNOWN=1
    arr=(); _acq_msb_port_flags_from_records arr <<REC
$(printf "3000\t\t\t")
$(printf "4000\t\t\t")
REC
    printf "%s\n" "${arr[@]}"
  '
  # Indeterminate probe: publish anyway (pre-ADR-0034 behavior) but say so, once.
  assert_regex "$output" '[0-9]+:3000'
  assert_regex "$output" '[0-9]+:4000'
  local n; n=$(printf '%s\n' "$output" | grep -c 'cannot probe host port availability')
  assert_equal "$n" "1"
}

@test "hostport(A): two kits publishing one guest port collapse to a single -p" {
  local a b
  a=$(_pp_kit dupa 5000 7001)
  b=$(_pp_kit dupb 5000 7002)
  : > "$CALLS"
  ( export ACQ_SECRET_STORE_DIR="$STUBDIR/sec-dup"
    export ACQ_MSB_STARTUP_STAGE_DIR="$STUBDIR/stage-dup"
    # shellcheck source=acq.backends/secret-store.sh
    . "${REPO_ROOT}/acq.backends/secret-store.sh"
    # shellcheck source=acq.backends/msb.sh
    . "${REPO_ROOT}/acq.backends/msb.sh"
    # shellcheck disable=SC2034  # consumed by the sourced acq_backend_provision
    ACQ_CLI_KITS=("$a" "$b")
    _acq_msb_fetch_kit() { case "$1" in "$a") printf '%s\n' "$a" ;; *) printf '%s\n' "$b" ;; esac; }
    acq_backend_provision dupbox shell /tmp ) >/dev/null 2>&1 || true
  local line; line=$(grep '^msb create' "$CALLS" | head -n1)
  # Last kit wins by guest port, exactly like the volumes union.
  assert_regex "$line" '\-p 7002:5000'
  refute_regex "$line" '\-p 7001:5000'
  local n; n=$(printf '%s\n' "$line" | grep -o -- '-p [0-9]*:5000' | wc -l | tr -d ' ')
  assert_equal "$n" "1"
}

# ---------------------------------------------------------------------------
# Part B — `acq run/create --publish HOST:GUEST`
# ---------------------------------------------------------------------------
# These drive the REAL acq entry point as a child process, so they also prove the
# acq-owned flag never survives onto the backend argv.

# Run acq as a child with a stored USAi key. Extra `KEY=VAL` env assignments
# precede the acq argv after a literal `--`. Usage:
#   _acq_child [KEY=VAL...] -- ARGS...
_acq_child() {
  local _env=() ; while [ "$1" != "--" ]; do _env+=("$1"); shift; done; shift
  run bash -c '
    tag="$1"; shift
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-$tag"
    export ACQ_MSB_KIT_PASSTHROUGH=1
    while [ "$1" != "--" ]; do export "$1"; shift; done; shift
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL\n" | acq_secret_store "$(_acq_secret_key usai)"
    "'"$ACQ"'" "$@" 2>&1
  ' _ "$BATS_TEST_NUMBER" ${_env[@]+"${_env[@]}"} -- "$@"
}
_msb_create_line() { grep '^msb create' "$CALLS" | head -n1; }

@test "publish(B): --publish H:G emits a create-time -p H:G and never reaches msb argv" {
  local proj="$STUBDIR/pubproj"; mkdir -p "$proj"
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- create shell --publish 6868:6767 "$proj"
  local line; line=$(_msb_create_line)
  assert_regex "$line" '\-p 6868:6767'
  # The acq-owned flag itself must never survive onto the backend argv.
  refute_regex "$line" '\-\-publish'
  refute_regex "$(cat "$CALLS")" '\-\-publish'
}

@test "publish(B): repeatable, and the =VALUE form is intercepted too" {
  local proj="$STUBDIR/pubproj2"; mkdir -p "$proj"
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- create shell --publish 6868:6767 --publish=7070:3000 "$proj"
  local line; line=$(_msb_create_line)
  assert_regex "$line" '\-p 6868:6767'
  assert_regex "$line" '\-p 7070:3000'
  refute_regex "$line" '\-\-publish'
}

@test "publish(B): a --publish overrides a kit entry that left host: unset" {
  local proj="$STUBDIR/pubproj3"; mkdir -p "$proj"
  local k; k=$(_pp_kit ovkit 6767)
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- create shell --kit "$k" --publish 6868:6767 "$proj"
  local line; line=$(_msb_create_line)
  assert_regex "$line" '\-p 6868:6767'
  # Exactly ONE mapping for guest 6767: the override replaces the chosen port
  # rather than adding a second, conflicting -p.
  local n; n=$(printf '%s\n' "$line" | grep -o -- '-p [0-9]*:6767' | wc -l | tr -d ' ')
  assert_equal "$n" "1"
}

@test "publish(B): a --publish also overrides a kit's PINNED host: port" {
  local proj="$STUBDIR/pubproj4"; mkdir -p "$proj"
  local k; k=$(_pp_kit pinovkit 3000 8080)
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- create shell --kit "$k" --publish 9090:3000 "$proj"
  local line; line=$(_msb_create_line)
  assert_regex "$line" '\-p 9090:3000'
  refute_regex "$line" '\-p 8080:3000'
}

@test "publish(B): a guest port no kit declares is published, with a note" {
  local proj="$STUBDIR/pubproj5"; mkdir -p "$proj"
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- create shell --publish 6868:6767 "$proj"
  assert_output --partial 'no applied kit declares guest port 6767'
  assert_regex "$(_msb_create_line)" '\-p 6868:6767'
}

@test "publish(B): a contended --publish host port fails the create, no fallback" {
  local proj="$STUBDIR/pubproj6"; mkdir -p "$proj"
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb ACQ_MSB_HOST_PORTS_BUSY=6868 -- \
    create shell --publish 6868:6767 "$proj"
  assert_failure
  assert_output --partial 'host port 6868'
  assert_output --partial 'already'
  # Nothing was created, and certainly not on some other host port.
  refute_regex "$(cat "$CALLS")" '\-p [0-9]+:6767'
}

@test "publish(B): --publish AFTER the -- separator passes through to the agent" {
  local proj="$STUBDIR/pubproj7"; mkdir -p "$proj"
  : > "$CALLS"
  # STUB_AGENT_PRESENT + STUB_RECORDED_AGENT: without them the stub reports the
  # agent binary missing / unrecorded and the attach falls back to a plain login
  # shell, dropping the agent args we are here to observe.
  _acq_child ACQ_BACKEND=msb STUB_AGENT_PRESENT=1 STUB_RECORDED_AGENT=opencode -- \
    run opencode "$proj" -- --publish 6868:6767
  local log; log=$(cat "$CALLS")
  # Forwarded verbatim to the inner agent invocation ...
  assert_regex "$log" '\-\-publish 6868:6767'
  # ... and NOT interpreted as an acq host-port override.
  refute_regex "$(_msb_create_line)" '\-p 6868:6767'

  # Guard against a vacuous pass: the SAME flag placed BEFORE the separator must
  # be consumed by acq and become a mapping, so this test would notice if the
  # extraction simply never ran.
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb STUB_AGENT_PRESENT=1 STUB_RECORDED_AGENT=opencode -- \
    run opencode --publish 6868:6767 "$proj"
  assert_regex "$(_msb_create_line)" '\-p 6868:6767'
  refute_regex "$(cat "$CALLS")" '\-\-publish'
}

@test "publish(B): --publish is refused on sbx, naming the post-hoc verb" {
  local proj="$STUBDIR/pubproj8"; mkdir -p "$proj"
  : > "$CALLS"
  _acq_child ACQ_BACKEND=sbx -- create shell --publish 6868:6767 "$proj"
  assert_failure
  assert_output --partial 'not supported on the sbx backend'
  assert_output --partial 'acq ports'
  # Refused BEFORE anything was created.
  refute_regex "$(cat "$CALLS")" '^sbx create'
}

@test "publish(B): --publish on a re-attach says it is ignored (create-time only)" {
  local proj="$STUBDIR/pubproj9"; mkdir -p "$proj"
  printf 'reattachbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'reattachbox\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- run shell --name reattachbox --publish 6868:6767 "$proj"
  assert_output --partial '--publish is ignored when re-attaching'
  assert_output --partial 'acq ports reattachbox --publish'
  refute_regex "$(cat "$CALLS")" '^msb create'
}

@test "publish(B): malformed values fail with a usable message and create nothing" {
  local proj="$STUBDIR/pubprojbad"; mkdir -p "$proj"
  local bad
  for bad in 6868 abc:6767 6767:abc 99999:6767 6767:99999 0:6767 06868:6767; do
    : > "$CALLS"
    _acq_child ACQ_BACKEND=msb -- create shell --publish "$bad" "$proj"
    assert_failure
    assert_output --partial "--publish"
    refute_regex "$(cat "$CALLS")" '^msb create'
  done

  # A trailing --publish with no value at all.
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- create shell "$proj" --publish
  assert_failure
  assert_output --partial 'no value'

  # Two --publish flags fighting over one guest port.
  : > "$CALLS"
  _acq_child ACQ_BACKEND=msb -- create shell --publish 6868:6767 --publish 6869:6767 "$proj"
  assert_failure
  assert_output --partial 'already mapped to host port 6868'
}
