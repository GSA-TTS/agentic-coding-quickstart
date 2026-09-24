#!/usr/bin/env bats
#
# 79-msb-readonly-kit-files.bats — ADR-0030 Mechanism 2: trusted startup
# execution from the read-only host-config mount.
#
# A kit files[] entry marked `readonly: true` carries trusted CODE that acq must
# execute from the host-authoritative read-only mount (/var/lib/acq/host, mounted
# :ro), NOT a guest-writable copy a passwordless-sudo agent could tamper. This
# suite proves:
#   - kit_spec_files surfaces the `readonly` field (5th tab column), default empty;
#   - a readonly file is staged into the host-config dir's kit-files/ subtree and
#     is NOT `msb copy`d into the guest;
#   - the invoking startup command's argv token is rewritten to the :ro path
#     (both the exec path and the staged --script-path body);
#   - a non-readonly file still copies into the guest (unchanged behavior);
#   - only a WHOLE-token match is rewritten (a --flag value that merely mentions
#     the path is left alone).
#
# shellcheck shell=bats

setup() { acq_setup_stubs; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

# kit_spec_files field surfacing --------------------------------------------

@test "kit_spec_files: emits readonly as a 5th field; default empty" {
  local k="$STUBDIR/rokit"; mkdir -p "$k"
  cat >"$k/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: ro-kit
displayName: RO Kit
description: one readonly code file and one plain data file
files:
  - path: /home/agent/cfg/merge.mjs
    mode: "0755"
    source: files/merge.mjs
    readonly: true
  - path: /home/agent/cfg/data.jsonc
    mode: "0644"
    source: files/data.jsonc
SPEC
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"; kit_spec_files "'"$k"'/spec.yaml"'
  assert_success
  # Record 1: readonly=true in the 5th tab field.
  assert_line --index 0 "$(printf '/home/agent/cfg/merge.mjs\t0755\t\tfiles/merge.mjs\ttrue')"
  # Record 2: no readonly -> empty 5th field.
  assert_line --index 1 "$(printf '/home/agent/cfg/data.jsonc\t0644\t\tfiles/data.jsonc\t')"
}

# provision: staging + no guest copy + argv rewrite -------------------------

# A kit with a readonly code file invoked by a startup command, plus a plain
# data file the same command references via a --flag.
_ro_kit() { # DIR
  local k="$1"; mkdir -p "$k/files"
  printf 'console.log("merge");\n' > "$k/files/merge.mjs"
  printf '{}\n' > "$k/files/data.jsonc"
  cat >"$k/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: ro-code-kit
displayName: RO Code Kit
description: trusted startup code + a data file
files:
  - path: /home/agent/cfg/merge.mjs
    mode: "0755"
    source: files/merge.mjs
    readonly: true
  - path: /home/agent/cfg/data.jsonc
    mode: "0644"
    source: files/data.jsonc
commands:
  - phase: startup
    user: "1000"
    command:
      - node
      - /home/agent/cfg/merge.mjs
      - --source
      - /home/agent/cfg/data.jsonc
SPEC
}

@test "msb ro: a readonly code file is staged on the host-config dir, NOT copied into the guest" {
  local k="$STUBDIR/rocode"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/rocode-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$k"'"; }
    acq_backend_provision rocodebox shell /tmp >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  # The readonly file is staged into the per-sandbox host config dir kit-files/.
  local cfg staged
  cfg=$(ls -d "$ACQ_PROVENANCE_DIR"/msb/rocodebox.*.config 2>/dev/null | head -n1)
  [ -n "$cfg" ]
  staged=$(find "$cfg/kit-files" -type f 2>/dev/null | head -n1)
  [ -n "$staged" ]
  # The mount root must be traversable by the guest agent (0711) while flat
  # acq-internal keys stay private; kit-files must be traversable and files
  # executable/readable from the :ro mount.
  assert_equal "$(stat -c '%a' "$cfg")" "711"
  assert_equal "$(stat -c '%a' "$cfg/kit-files")" "711"
  assert_equal "$(stat -c '%a' "$staged")" "555"
  # It is NOT msb-copied into the guest at its declared guest path.
  refute_regex "$log" 'msb copy .*:/home/agent/cfg/merge\.mjs'
  # The plain data file IS copied into the guest (unchanged behavior).
  assert_regex "$log" 'msb copy .*rocodebox:/home/agent/cfg/data\.jsonc'
}

@test "msb ro: the startup argv token is rewritten to the :ro mount path (exec + staged body)" {
  local k="$STUBDIR/rocode2"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/rocode2-secrets"
    export ACQ_MSB_KEEP_STARTUP_STAGE=1 ACQ_MSB_STARTUP_STAGE_DIR="'"$STUBDIR"'/rocode2-stage"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$k"'"; }
    acq_backend_provision rocode2box shell /tmp >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  # The exec-path startup command runs node on the :ro mount path, not the guest path.
  assert_regex "$log" 'node /var/lib/acq/host/kit-files/home-agent-cfg-merge-mjs\.[0-9]+'
  refute_regex "$log" 'node /home/agent/cfg/merge\.mjs'
  # The --source DATA arg (a whole different token) is left at its guest path.
  assert_regex "$log" -- '--source /home/agent/cfg/data\.jsonc'
  # The staged --script-path body ALSO points node at the :ro copy (restart-safe).
  local body; body=$(cat "$(find "$STUBDIR/rocode2-stage" -type f 2>/dev/null | head -n1)" 2>/dev/null)
  assert_regex "$body" '/var/lib/acq/host/kit-files/home-agent-cfg-merge-mjs\.[0-9]+'
  refute_regex "$body" '/home/agent/cfg/merge\.mjs'
}

@test "msb ro: legacy sandbox without the host-config mount falls back to the guest copy" {
  local k="$STUBDIR/legacyro"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/legacyro-secrets" STUB_HOST_CONFIG_MOUNT=0
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_apply_kit_dir legacyrobox "'"$k"'" 2>&1
  '
  assert_success
  # No mount -> no :ro rewrite; preserve compatibility by copying the trusted
  # file into the guest and invoking the original path. Users can recreate the
  # sandbox to get tamper-resistant readonly startup code.
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb copy .*legacyrobox:/home/agent/cfg/merge\.mjs'
  assert_regex "$log" 'node /home/agent/cfg/merge\.mjs'
  refute_regex "$log" '/var/lib/acq/host/kit-files'
  assert_output --partial 'has no readable or read-only ADR-0030 host-config mount'
}

@test "msb ro: writable host-config mount falls back to the guest copy" {
  local k="$STUBDIR/writablero"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/writablero-secrets" STUB_HOST_CONFIG_WRITABLE=1
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_apply_kit_dir writablerobox "'"$k"'" 2>&1
  '
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb copy .*writablerobox:/home/agent/cfg/merge\.mjs'
  assert_regex "$log" 'node /home/agent/cfg/merge\.mjs'
  refute_regex "$log" '/var/lib/acq/host/kit-files'
  assert_output --partial 'has no readable or read-only ADR-0030 host-config mount'
}

@test "msb ro: the create-time host-config mount is read-only" {
  local k="$STUBDIR/romount"; _ro_kit "$k"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/romount-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$k"'"; }
    acq_backend_provision romountbox shell /tmp >/dev/null 2>&1
  '
  # The host-config dir is mounted :ro at the well-known guest path.
  assert_regex "$(cat "$CALLS")" -- '--volume [^ ]*romountbox[^ ]*\.config:/var/lib/acq/host:ro'
}
