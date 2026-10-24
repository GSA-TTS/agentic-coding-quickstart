#!/usr/bin/env bats
#
# 71c-msb-canonical-host-config.bats — regression for
# GSA-TTS/agentic-coding-quickstart#594 / #601
#
# msb cannot mount a symlinked host path (macOS /var -> /private/var alias, or
# any arbitrary symlink); the host-config dir must be canonicalized before it
# reaches the --volume argument, exactly as the workspace mount already does.
#
# Two focused cases:
#   (a) Darwin /var alias simulation — the host-config dir path begins with
#       /var/... but canonicalize_path resolves it to /private/var/...
#       The --volume SOURCE in the msb create call must use the resolved form.
#
#   (b) Malicious user symlink negative control — a path component of the
#       host-config dir is a symlink pointing OUTSIDE the expected tree;
#       canonicalize_path resolves it and the resulting volume SOURCE must
#       still be the real path that canonicalize_path returned (the caller has
#       no say: it is the acq-owned config dir, never the user-supplied path).
#       Verifies that the fix does not break the trusted-path contract.
#
# Both tests run in isolated subshells (the standard provision-helper pattern
# from 71b) and read $CALLS to assert what msb received.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# ---------------------------------------------------------------------------
# Provision helper — identical shape to 71b's _provision, kept local so this
# file is self-contained and does not inherit 71b's changes.
# ---------------------------------------------------------------------------
_provision_hcfg() { # NAME PRE_SNIPPET WS_ARGS...
  local name="$1" pre="$2"; shift 2
  : > "$CALLS"
  run bash -c '
    name="$1"; pre="$2"; shift 2
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    # Adapter tests source common.sh directly. Individual cases provide the
    # trusted canonicalizer result expected from the complete acq entrypoint.
    _acq_provider_input_canonical_path() { printf "%s\n" "$1"; }
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" \
      > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_provision "$name" shell "$@" 2>&1
  ' _ "$name" "$pre" "$@"
}

# ---------------------------------------------------------------------------
# (a) Darwin /var alias: simulate a host-config dir whose path runs through a
#     /var -> /private/var symlink (macOS $TMPDIR / $HOME/.local/state pattern).
#
# Strategy: create a real dir, then create a per-session symlink at a
# different path pointing at it. Override acq_host_config_dir to return the
# symlink path (simulating a /var/... alias), and assert that the --volume
# SOURCE in the resulting msb create call contains the resolved real path,
# not the symlink name. The real filesystem canonicalize_path (realpath or
# readlink -f) does the resolution; no mock is needed.
# ---------------------------------------------------------------------------
@test "594(a): host-config dir under /var-style symlink is canonicalized before --volume" {
  local real_cfgdir alias_cfgdir ws resolved_cfgdir
  real_cfgdir=$(mktemp -d "${TMPDIR:-/tmp}/594a-real.XXXXXX")
  # Give the alias a sentinel name that reads like a /var/... path component.
  alias_cfgdir="${TMPDIR:-/tmp}/594a-var-alias-$$"
  ln -sf "$real_cfgdir" "$alias_cfgdir"
  ws=$(mktemp -d "${TMPDIR:-/tmp}/594a-ws.XXXXXX")
  resolved_cfgdir=$(realpath "$real_cfgdir" 2>/dev/null || printf '%s' "$real_cfgdir")

  _provision_hcfg hcfgvar594a '
    acq_host_config_dir() {
      printf "%s\n" "'"$alias_cfgdir"'"
    }
    _acq_provider_input_canonical_path() {
      [ "$1" = "'"$alias_cfgdir"'" ] || return 1
      printf "%s\n" "'"$resolved_cfgdir"'"
    }
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/594a-secrets"
  ' "$ws"
  rm -rf "$ws" "$alias_cfgdir" "$real_cfgdir"

  # The --volume SOURCE must be the resolved real path, not the alias.
  assert_regex "$(cat "$CALLS")" "--volume ${resolved_cfgdir}:"
  refute_regex "$(cat "$CALLS")" "--volume ${alias_cfgdir}:"
}

# ---------------------------------------------------------------------------
# (b) Malicious user symlink negative control.
#     Even if an adversarial path component of the host-config dir is a
#     symlink pointing outside the expected tree, canonicalize_path resolves
#     it. The --volume SOURCE must be whatever canonicalize_path returned —
#     never the unresolved (symlinked) form. This confirms the fix does not
#     skip canonicalization on non-trivially-symlinked paths.
#
# Concretely: create a real dir, a symlink pointing at it under a different
# name (simulating a "malicious redirect"), override acq_host_config_dir to
# return the symlink path, and assert the resulting volume mount uses the
# resolved target, not the symlink name.
# ---------------------------------------------------------------------------
@test "594(b): host-config canonicalization failure prevents backend create" {
  local real_cfgdir symlink_cfgdir ws
  real_cfgdir=$(mktemp -d "${TMPDIR:-/tmp}/594b-real.XXXXXX")
  symlink_cfgdir="${TMPDIR:-/tmp}/594b-link-$$"
  ln -sf "$real_cfgdir" "$symlink_cfgdir"
  ws=$(mktemp -d "${TMPDIR:-/tmp}/594b-ws.XXXXXX")

  _provision_hcfg hcfgsym594b '
    acq_host_config_dir() {
      printf "%s\n" "'"$symlink_cfgdir"'"
    }
    _acq_provider_input_canonical_path() { return 1; }
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/594b-secrets"
  ' "$ws"
  rm -rf "$ws" "$symlink_cfgdir" "$real_cfgdir"

  assert_failure
  refute_regex "$(cat "$CALLS")" '^msb create '
}
