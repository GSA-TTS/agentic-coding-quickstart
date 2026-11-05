#!/usr/bin/env bats
#
# 91-sbx-readonly-warning.bats — ADR-0037 interim state (Option D): sbx has no
# trusted read-only mount for kit `readonly: true` files, so the sbx translation
# path must warn visibly (stderr) that those files are guest-resident copies.
# The kit must still translate and apply unchanged. Offline; no sbx needed.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; unset ACQ_SBX_KIT_PASSTHROUGH; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Same shape as the Patterns v1.18.0 oci-engine kit: two readonly root-startup
# files plus ordinary staged files.
_make_ro_kit() {
  local kit="$1"
  mkdir -p "$kit/files/home/oci-engine-config"
  printf '#!/bin/sh\n' > "$kit/files/home/oci-engine-grant-devs.sh"
  printf 'x=1\n' > "$kit/files/home/oci-engine-config/oci-engine-storage-driver.sh"
  printf '#!/bin/sh\n' > "$kit/files/home/oci-engine-install.sh"
  cat > "$kit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: oci-engine
displayName: OCI Engine
description: readonly warning fixture
files:
  - path: /home/agent/oci-engine-install.sh
    mode: "0755"
    source: files/home/oci-engine-install.sh
  - path: /home/agent/oci-engine-grant-devs.sh
    mode: "0755"
    source: files/home/oci-engine-grant-devs.sh
    readonly: true
  - path: /home/agent/oci-engine-config/oci-engine-storage-driver.sh
    mode: "0644"
    source: files/home/oci-engine-config/oci-engine-storage-driver.sh
    readonly: true
SPEC
}

@test "sbx readonly warning: names the kit and both guest paths on stderr, kit still translates" {
  local kit="$STUBDIR/ro-kit" errf="$STUBDIR/ro.err" out
  _make_ro_kit "$kit"
  out=$(_acq_sbx_translate_kit "$kit" 2>"$errf")
  # stdout stays machine-parseable: exactly the translated kit dir.
  [ -f "$out/spec.yaml" ]
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ]
  run cat "$errf"
  assert_output --partial "WARNING: kit 'oci-engine'"
  assert_output --partial "/home/agent/oci-engine-grant-devs.sh"
  assert_output --partial "/home/agent/oci-engine-config/oci-engine-storage-driver.sh"
  assert_output --partial "guest-resident copies"
  assert_output --partial "docs/adr/0037-sbx-trusted-startup-parity.md"
  # The non-readonly file is not named in the warning.
  refute_output --partial "oci-engine-install.sh"
  # Exactly one warning block per translation.
  [ "$(grep -c 'WARNING: kit' "$errf")" = "1" ]
  # Behavior unchanged: both guest paths are still staged in the sbx-v2 kit.
  assert_regex "$(cat "$out/spec.yaml")" 'oci-engine-grant-devs.sh'
  [ -f "$out/files/home/oci-engine-grant-devs.sh" ]
}

@test "sbx readonly warning: silent for a kit with no readonly files" {
  local kit="$STUBDIR/plain-kit" errf="$STUBDIR/plain.err" out
  mkdir -p "$kit/files/home"
  printf 'x\n' > "$kit/files/home/tool.sh"
  cat > "$kit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: plain-kit
displayName: Plain
description: no readonly files
files:
  - path: /home/agent/tool.sh
    mode: "0755"
    source: files/home/tool.sh
SPEC
  out=$(_acq_sbx_translate_kit "$kit" 2>"$errf")
  [ -f "$out/spec.yaml" ]
  run cat "$errf"
  refute_output --partial "readonly"
  refute_output --partial "WARNING"
}
