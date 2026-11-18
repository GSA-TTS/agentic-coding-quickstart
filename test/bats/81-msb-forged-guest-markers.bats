#!/usr/bin/env bats
#
# 81-msb-forged-guest-markers.bats — forged legacy guest markers cannot change
# MSB acq behavior (ADR-0035).
#
# A sandbox's agent has passwordless sudo, so any file under the guest's
# /var/lib/acq/ is attacker-writable. ADR-0035 moved every acq decision that used
# to read those legacy markers onto the host-authoritative config store. These
# tests plant ATTACKER-CHOSEN values behind every legacy guest marker path (the
# `msb` stub below answers any guest read of them) and assert the decisions still
# come from the host store, provenance, or acq's own defaults:
#   agent, workspace, SSH_AUTH_SOCK, kit environment[], the install-phase run-once
#   gate, and the agent-user-ready gate.
# Each decision is checked both ways: host value present (forged value ignored) and
# host value absent (forged value still never imported). This mirrors the SBX
# extra-kit forged-marker test in 90-sbx-startup-kit.bats.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

FORGED_AGENT=claude
FORGED_WS=/tmp/forged-workspace
FORGED_SOCK=/tmp/forged-agent.sock
FORGED_ENV_LINE=FORGED_KIT_VAR=pwned

# Legacy guest paths whose reads must never influence acq. /var/lib/acq/host and
# /var/lib/acq/provider-input are the host-authored read-only mounts and are
# deliberately NOT in this set.
LEGACY_MARKER_RE='/var/lib/acq/(agent|workspace|ssh-auth-sock|kit-env|install-|agent-installed|agent-user-ready|oci-ready|oci-engine-ready)'

# Wrap the shared msb stub so a guest read of any legacy marker returns a forged
# value (content markers) or "exists" (presence gates). Everything else is
# delegated unchanged to the shared stub, which does its own call logging.
_install_forging_msb() {
  mv "$STUBDIR/msb" "$STUBDIR/msb-real"
  cat >"$STUBDIR/msb" <<'FORGER'
#!/usr/bin/env bash
_forged() {
  { _l="msb"; for a in "$@"; do _l="$_l $a"; done; printf '%s\n' "$_l" >>"$CALLS"; }
  [ -t 0 ] || cat >/dev/null 2>&1 || true
}
if [ "${1:-}" = "exec" ]; then
  all="$*"
  case "$all" in
    *"/var/lib/acq/agent-user-ready"*|*"/var/lib/acq/agent-installed-"*|*"/var/lib/acq/install-"*|*"/var/lib/acq/oci-ready"*|*"/var/lib/acq/oci-engine-ready"*)
      _forged "$@"; exit 0 ;;
    *"/var/lib/acq/agent"*)          _forged "$@"; printf '%s' "$FORGED_AGENT"; exit 0 ;;
    *"/var/lib/acq/workspace"*)      _forged "$@"; printf '%s' "$FORGED_WS"; exit 0 ;;
    *"/var/lib/acq/ssh-auth-sock"*)  _forged "$@"; printf '%s' "$FORGED_SOCK"; exit 0 ;;
    *"/var/lib/acq/kit-env"*)        _forged "$@"; printf '%s\n' "$FORGED_ENV_LINE"; exit 0 ;;
  esac
fi
exec "$(dirname "$0")/msb-real" "$@"
FORGER
  chmod +x "$STUBDIR/msb"
  export FORGED_AGENT FORGED_WS FORGED_SOCK FORGED_ENV_LINE
}

# Run a snippet in a fresh shell with msb.sh sourced and the forging stub in place.
_forged_run() { # SNIPPET
  : > "$CALLS"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    eval "$1"
  ' _ "$1"
}

@test "forged msb stub: the legacy marker paths really answer with attacker values" {
  _install_forging_msb
  run msb exec box -u 0 -- sh -c 'cat /var/lib/acq/agent 2>/dev/null'
  assert_output "$FORGED_AGENT"
  run msb exec box -u 0 -- sh -c 'cat /var/lib/acq/workspace 2>/dev/null'
  assert_output "$FORGED_WS"
  run msb exec box -u 0 -- sh -c 'cat /var/lib/acq/ssh-auth-sock 2>/dev/null'
  assert_output "$FORGED_SOCK"
  run msb exec box -u 0 -- sh -c 'cat /var/lib/acq/kit-env 2>/dev/null'
  assert_output "$FORGED_ENV_LINE"
  run msb exec box -u 0 -- sh -c 'test -f /var/lib/acq/agent-user-ready'
  assert_success
  run msb exec box -u 0 -- sh -c 'test -f /var/lib/acq/install-123'
  assert_success
}

# --- agent ------------------------------------------------------------------

@test "forged marker(msb): attach launches the host-recorded agent, not the forged one" {
  _install_forging_msb
  _forged_run '
    export STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1
    seed_host_config msb agentbox
    ( _acq_msb_attach agentbox </dev/null >/dev/null 2>&1 )
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'agentbox -- opencode'
  refute_regex "$log" "$FORGED_AGENT"
  refute_regex "$log" "$LEGACY_MARKER_RE"
}

@test "forged marker(msb): with no host agent record attach opens a shell, never the forged agent" {
  _install_forging_msb
  _forged_run '
    export STUB_AGENT_PRESENT=1
    ( _acq_msb_attach noagentbox </dev/null >/dev/null 2>&1 )
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'noagentbox -- /bin/sh -l'
  refute_regex "$log" "$FORGED_AGENT"
  refute_regex "$log" "$LEGACY_MARKER_RE"
  _forged_run 'acq_backend_recorded_agent noagentbox'
  assert_output ''
}

@test "forged marker(msb): trusted provenance, not the forged marker, supplies a legacy sandbox's agent" {
  _install_forging_msb
  _forged_run '
    export STUB_AGENT_PRESENT=1
    acq_provenance_write msb legacyagentbox opencode /tmp/legacy-repo
    ( _acq_msb_attach legacyagentbox </dev/null >/dev/null 2>&1 )
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'legacyagentbox -- opencode'
  refute_regex "$log" "$FORGED_AGENT"
}

# --- workspace --------------------------------------------------------------

@test "forged marker(msb): run, attach and shell use the host-recorded workspace" {
  _install_forging_msb
  _forged_run '
    export STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1 STUB_RECORDED_WORKSPACE=/tmp/host-workspace
    seed_host_config msb wsbox
    acq_backend_run wsbox -- git status >/dev/null 2>&1
    ( _acq_msb_attach wsbox </dev/null >/dev/null 2>&1 )
    ( _acq_msb_shell_exec wsbox </dev/null >/dev/null 2>&1 )
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'exec -u agent -e HOME=/home/agent -w /tmp/host-workspace wsbox -- git status'
  assert_regex "$log" 'exec -t -u agent -w /tmp/host-workspace .* wsbox -- opencode'
  assert_regex "$log" 'exec -t -u agent -w /tmp/host-workspace .* wsbox -- /bin/sh -l'
  refute_regex "$log" "$FORGED_WS"
  refute_regex "$log" "$LEGACY_MARKER_RE"
}

@test "forged marker(msb): with no host workspace the session falls back to the agent home, not the forged path" {
  _install_forging_msb
  _forged_run '
    acq_backend_run nowsbox -- git status >/dev/null 2>&1
    _acq_msb_workspace_for nowsbox
  '
  assert_output '/home/agent'
  refute_regex "$(cat "$CALLS")" "$FORGED_WS"
  refute_regex "$(cat "$CALLS")" "$LEGACY_MARKER_RE"
}

@test "forged marker(msb): the host workspace record outranks the forged workspace marker" {
  _install_forging_msb
  _forged_run '
    acq_provenance_write msb legacywsbox opencode /tmp/legacy-repo
    _acq_msb_workspace_for legacywsbox
  '
  assert_output '/tmp/legacy-repo'
  refute_regex "$(cat "$CALLS")" "$LEGACY_MARKER_RE"
}

# --- SSH_AUTH_SOCK ----------------------------------------------------------

@test "forged marker(msb): SSH_AUTH_SOCK comes from the host record on run, attach and shell" {
  _install_forging_msb
  _forged_run '
    export STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1 STUB_RECORDED_SSH_AUTH_SOCK=/run/acq/host-agent.sock
    seed_host_config msb sockbox
    acq_backend_run sockbox -- git status >/dev/null 2>&1
    ( _acq_msb_attach sockbox </dev/null >/dev/null 2>&1 )
    ( _acq_msb_shell_exec sockbox </dev/null >/dev/null 2>&1 )
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '-e SSH_AUTH_SOCK=/run/acq/host-agent\.sock .*sockbox -- git status'
  assert_regex "$log" '-e SSH_AUTH_SOCK=/run/acq/host-agent\.sock .*sockbox -- opencode'
  assert_regex "$log" '-e SSH_AUTH_SOCK=/run/acq/host-agent\.sock .*sockbox -- /bin/sh -l'
  refute_regex "$log" "$FORGED_SOCK"
  refute_regex "$log" "$LEGACY_MARKER_RE"
}

@test "forged marker(msb): with no host ssh-auth-sock record no SSH_AUTH_SOCK is injected at all" {
  _install_forging_msb
  _forged_run '
    acq_backend_run nosockbox -- git status >/dev/null 2>&1
    ( _acq_msb_attach nosockbox </dev/null >/dev/null 2>&1 )
    ( _acq_msb_shell_exec nosockbox </dev/null >/dev/null 2>&1 )
    printf "SOCK=[%s]\n" "$(_acq_msb_ssh_auth_sock_for nosockbox)"
  '
  assert_output 'SOCK=[]'
  refute_regex "$(cat "$CALLS")" 'SSH_AUTH_SOCK'
  refute_regex "$(cat "$CALLS")" "$LEGACY_MARKER_RE"
}

# --- kit environment[] ------------------------------------------------------

@test "forged marker(msb): kit environment replay uses only the host kit-env record" {
  _install_forging_msb
  _forged_run '
    export STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1
    export STUB_RECORDED_KIT_ENV="OPENCODE_CONFIG=/home/agent/oc.jsonc"
    seed_host_config msb envbox
    acq_backend_run envbox -- printenv >/dev/null 2>&1
    ( _acq_msb_attach envbox </dev/null >/dev/null 2>&1 )
    ( _acq_msb_shell_exec envbox </dev/null >/dev/null 2>&1 )
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '-e OPENCODE_CONFIG=/home/agent/oc\.jsonc .*envbox -- printenv'
  assert_regex "$log" '-e OPENCODE_CONFIG=/home/agent/oc\.jsonc .*envbox -- opencode'
  assert_regex "$log" '-e OPENCODE_CONFIG=/home/agent/oc\.jsonc .*envbox -- /bin/sh -l'
  refute_regex "$log" 'FORGED_KIT_VAR'
  refute_regex "$log" "$LEGACY_MARKER_RE"
}

@test "forged marker(msb): with no host kit-env record no forged variable reaches any session" {
  _install_forging_msb
  _forged_run '
    acq_backend_run noenvbox -- printenv >/dev/null 2>&1
    ( _acq_msb_attach noenvbox </dev/null >/dev/null 2>&1 )
    ( _acq_msb_shell_exec noenvbox </dev/null >/dev/null 2>&1 )
    _acq_msb_persisted_kit_env_into _toks noenvbox
    printf "TOKENS=%s\n" "${#_toks[@]}"
  '
  assert_output 'TOKENS=0'
  refute_regex "$(cat "$CALLS")" 'FORGED_KIT_VAR'
  refute_regex "$(cat "$CALLS")" "$LEGACY_MARKER_RE"
}

# --- install-phase run-once gate -------------------------------------------

_apply_install_kit() { # NAME  (msb forging stub must already be installed)
  local name="$1" ik="$STUBDIR/installkit"
  mkdir -p "$ik"
  cat >"$ik/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: forge-install-kit
displayName: Forge Install Kit
description: install command whose run-once gate must be host-side
commands:
  - phase: install
    user: "0"
    command:
      - echo
      - INSTALL_FORGE_PROBE
SPEC
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/forge-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_test_stub_provider_input_boundary
    _acq_msb_apply_kit_dir "$1" "$2"
  ' _ "$name" "$ik"
}

@test "forged marker(msb): a forged install-* marker cannot suppress the install command; the host gate then does" {
  _install_forging_msb
  : > "$CALLS"
  _apply_install_kit installgate
  assert_success
  assert_equal "$(grep -c 'INSTALL_FORGE_PROBE' "$CALLS")" 1
  # The run-once gate was recorded on the HOST, not in the guest.
  local hostkey; hostkey=$(ls "$ACQ_PROVENANCE_DIR"/msb/installgate.*.config/install-* 2>/dev/null | head -n1)
  [ -n "$hostkey" ]
  refute_regex "$(cat "$CALLS")" "$LEGACY_MARKER_RE"
  # Positive control: a second apply is suppressed by the host gate alone.
  _apply_install_kit installgate
  assert_success
  assert_equal "$(grep -c 'INSTALL_FORGE_PROBE' "$CALLS")" 1
}

@test "forged marker(msb): a forced re-apply re-runs an install command a recorded success would suppress" {
  _install_forging_msb
  : > "$CALLS"
  _apply_install_kit forcegate
  assert_success
  assert_equal "$(grep -c 'INSTALL_FORGE_PROBE' "$CALLS")" 1
  _apply_install_kit forcegate
  assert_equal "$(grep -c 'INSTALL_FORGE_PROBE' "$CALLS")" 1
  ACQ_FORCE_KIT_REAPPLY=1 _apply_install_kit forcegate
  assert_success
  assert_equal "$(grep -c 'INSTALL_FORGE_PROBE' "$CALLS")" 2
}

# --- agent-user-ready gate --------------------------------------------------

@test "forged marker(msb): a forged agent-user-ready marker cannot skip agent-user setup" {
  _install_forging_msb
  _forged_run '
    _acq_msb_ensure_agent_user gatebox
  '
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'test -w /home/agent'
  assert_regex "$log" 'NOPASSWD:ALL'
  refute_regex "$log" "$LEGACY_MARKER_RE"
  # No gate is recorded anywhere: the setup is re-verified on every call.
  run bash -c 'ls "'"$ACQ_PROVENANCE_DIR"'"/msb/gatebox.*.config/agent-user-ready 2>&1'
  assert_failure
}

# Deliberate change: this test used to assert that a host agent-user-ready key
# SKIPS the setup block. The key is a record of a guest-reported zero exit, which a
# guest can fake once, so it no longer suppresses the (idempotent, cheap) setup:
# it is re-verified on every call and a one-time false success cannot stick.
@test "forged marker(msb): a recorded agent-user success does not suppress re-verification" {
  _install_forging_msb
  _forged_run '
    acq_host_config_write msb hostgatebox agent-user-ready 1
    _acq_msb_ensure_agent_user hostgatebox
    _acq_msb_ensure_agent_user hostgatebox
  '
  assert_success
  local log; log=$(cat "$CALLS")
  assert_equal "$(grep -c 'NOPASSWD:ALL' "$CALLS")" 2
  refute_regex "$log" "$LEGACY_MARKER_RE"
}

@test "forged marker(msb): a first run that only appeared to succeed is re-run, not remembered" {
  _install_forging_msb
  _forged_run '
    _acq_msb_ensure_agent_user falsesuccess
    _acq_msb_ensure_agent_user falsesuccess
  '
  assert_success
  assert_equal "$(grep -c 'NOPASSWD:ALL' "$CALLS")" 2
  run bash -c 'ls "'"$ACQ_PROVENANCE_DIR"'"/msb/falsesuccess.*.config/agent-user-ready 2>&1'
  assert_failure
}
