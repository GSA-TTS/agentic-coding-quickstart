#!/usr/bin/env bats
#
# 82-msb-legacy-sandbox.bats — behavior of an msb sandbox created before ADR-0035
# moved session state from guest /var/lib/acq markers to the host config store.
#
# Such a sandbox has no host-config keys. acq never imports the old guest markers
# (a passwordless-sudo guest could forge them), so each missing key must degrade
# as documented in docs/KNOWN_FAILURE_MODES.md (section 32.1): no SSH_AUTH_SOCK
# until the forward is re-driven, and the install / agent-user gates replay once.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Heal a name that has no host-config keys, using an empty local kit so the heal
# does no network fetch. Extra shell is appended to the subshell body.
_heal_legacy() { # NAME
  local name="$1"
  printf '%s\n' "$name" >"$STUBDIR/.msb_sandbox_list"
  printf '%s\n' "$name" >"$STUBDIR/.msb_running_list"
  mkdir -p "$STUBDIR/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' >"$STUBDIR/nokit/spec.yaml"
  run bash -c '
    unset SSH_AUTH_SOCK ACQ_FORWARD_HOST_SOCKETS
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_ensure_kits_applied "'"$name"'" >/dev/null 2>&1
    acq_backend_ensure_kits_applied "'"$name"'" >/dev/null 2>&1
  '
}

@test "legacy msb: no host ssh-auth-sock key means no SSH_AUTH_SOCK and no guest marker read" {
  : > "$CALLS"
  run bash -c '
    export STUB_MSB_VERSION=0.6.9
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run legacybox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec .*legacybox'
  refute_regex "$log" 'SSH_AUTH_SOCK='
  refute_regex "$log" '/var/lib/acq/ssh-auth-sock'
}

@test "legacy msb: an install-phase command replays once, then the host gate holds" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/legacyinst-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    lk="'"$STUBDIR"'/legacyinstkit"; mkdir -p "$lk"
    cat >"$lk/spec.yaml" <<'"'"'SPEC'"'"'
schemaVersion: "hybrid/v1"
kind: mixin
name: legacy-install-kit
displayName: Legacy Install Kit
description: install command replays once on a sandbox with no host gate
commands:
  - phase: install
    user: "0"
    command:
      - printf
      - legacy-install-ran
SPEC
    _acq_msb_apply_kit_dir legacyinstbox "$lk"
    _acq_msb_apply_kit_dir legacyinstbox "$lk"
  '
  local runs; runs=$(grep -c 'legacy-install-ran' "$CALLS" || true)
  assert_equal "$runs" "1"
  local gate; gate=$(ls "$ACQ_PROVENANCE_DIR"/msb/legacyinstbox.*.config/install-* 2>/dev/null | head -n1)
  [ -n "$gate" ]
}

@test "legacy msb: the agent-user setup replays once on heal, then the host gate holds" {
  : > "$CALLS"
  _heal_legacy legacyuserbox
  local runs; runs=$(grep -c 'NOPASSWD:ALL' "$CALLS" || true)
  assert_equal "$runs" "1"
  run test -f "$(ls -d "$ACQ_PROVENANCE_DIR"/msb/legacyuserbox.*.config)/agent-user-ready"
  assert_success
}
