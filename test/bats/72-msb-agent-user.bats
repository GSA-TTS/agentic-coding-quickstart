#!/usr/bin/env bats
#
# 72-msb-agent-user.bats — bats port of scripts/test-acq.d/72-msb-agent-user.sh
# (ADR-0025)
#
# msb provision: agent-user creation + uid-1000 kit commands as `agent`, the
# Docker base-image contract (sudo + proxy env_keep), agent install + npm-failure
# disambiguation (#321), attach launching the recorded agent with a PTY, exec as
# the agent user, injection guards, and the OCI-engine (podman) setup. Provisions
# run in isolated subshells; assertions read $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Run a provision in a subshell: seed store, source msb, stub kit fetch (to the
# given kit dir or a no-op kit), provision NAME AGENT WS. PRE runs before it.
_provision() { # NAME AGENT PRE_SNIPPET [KITDIR]
  local name="$1" agent="$2" pre="$3" kitdir="${4:-}"
  : > "$CALLS"
  run bash -c '
    name="$1"; agent="$2"; pre="$3"; stub_kitdir="$4"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    if [ -z "$stub_kitdir" ]; then
      stub_kitdir="'"$STUBDIR"'/nokit"; mkdir -p "$stub_kitdir"
      printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "$stub_kitdir/spec.yaml"
    fi
    # NOTE: the stub must NOT read a variable named "kitdir" — provision declares
    # a `local kitdir`, which dynamically shadows it at stub-call time.
    _acq_msb_fetch_kit() { printf "%s\n" "$stub_kitdir"; }
    acq_backend_provision "$name" "$agent" /tmp 2>&1
    printf "PROVISION_RC=%s\n" "$?"
  ' _ "$name" "$agent" "$pre" "$kitdir"
}

@test "msb: a uid-1000 kit command runs as agent (HOME set, git guards), staged subtree chowned" {
  local aok="$STUBDIR/agentkit"
  mkdir -p "$aok/files/home/usai-config"
  printf 'MODULE\n' > "$aok/files/home/usai-config/merge-global-config.mjs"
  cat >"$aok/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: agent-kit
displayName: Agent Kit
description: kit whose startup runs as uid 1000
files:
  - path: /home/agent/usai-config/merge-global-config.mjs
    mode: "0755"
    source: files/home/usai-config/merge-global-config.mjs
commands:
  - phase: startup
    user: "1000"
    command:
      - node
      - /home/agent/usai-config/merge-global-config.mjs
SPEC
  _provision agentbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/agent-secrets"' "$aok"
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'agent'
  assert_regex "$log" 'msb exec agentbox -u agent -e HOME=/home/agent'
  refute_regex "$log" 'msb exec agentbox -u 1000 -- node'
  assert_regex "$log" '-e GIT_TERMINAL_PROMPT=0'
  assert_regex "$log" 'chown -R -P agent /home/agent/usai-config'
  refute_regex "$log" 'useradd -m -d /home/agent -s /bin/sh -u 1000'
  assert_regex "$log" 'chown "agent:'
  assert_regex "$log" 'test -w /home/agent'
}

@test "msb: an unwritable agent home aborts provision (fatal)" {
  _provision homefailbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/homefail-secrets" STUB_HOME_NOT_WRITABLE=1'
  assert_output --partial 'PROVISION_RC=1'
}

@test "msb: the agent gets passwordless sudo and proxy env_keep (base-image contract)" {
  _provision basereqbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/basereq-secrets"'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sudoers\.d/90-acq-agent'
  assert_regex "$log" 'NOPASSWD:ALL'
  assert_regex "$log" 'env_keep'
  assert_regex "$log" 'HTTPS_PROXY'
}

@test "msb: provision installs the requested agent via npm and allow-lists the registry" {
  _provision instbox opencode 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/inst-secrets"'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'npm install -g --no-fund --no-audit opencode-ai'
  assert_regex "$log" '--net-rule allow@registry\.npmjs\.org'
  assert_regex "$log" '/var/lib/acq/agent'
}

@test "msb: install is idempotent — skipped when the agent binary is already present" {
  _provision inst2box opencode 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/inst2-secrets" STUB_AGENT_PRESENT=1'
  refute_regex "$(cat "$CALLS")" 'npm install'
}

@test "msb: a shell sandbox installs no agent and (strict tier) adds no npm net-rule" {
  _provision shellbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/shell-secrets" ACQ_NETWORK_TIER=strict'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'npm install'
  refute_regex "$log" 'allow@registry\.npmjs\.org'
}

@test "msb #321: an unreachable npm registry is reported as network, not missing npm" {
  _provision npmunreachbox opencode 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/npmunreach-secrets" STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=unreachable'
  assert_output --partial 'NOT REACHABLE'
  assert_output --partial 'KNOWN_FAILURE_MODES.md §30'
  refute_output --partial 'npm is not present'
}

@test "msb #321: an NXDOMAIN npm registry is reported as DNS, not missing npm" {
  _provision npmunresbox opencode 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/npmunres-secrets" STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=unresolved'
  assert_output --partial 'did not RESOLVE'
  assert_output --partial 'ACQ_MSB_DNS_NAMESERVER'
}

@test "msb #321: a genuinely-missing npm is reported as such" {
  _provision npmmissingbox opencode 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/npmmissing-secrets" STUB_NPM_FAIL=1 STUB_NPM_MISSING=1'
  assert_output --partial 'npm is not present'
  refute_output --partial 'NOT REACHABLE'
}

@test "msb #321: a responded-but-errored registry gets neutral guidance, no DNS/TLS bleed" {
  _provision npmrespbox opencode 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/npmresp-secrets" STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=responded'
  assert_output --partial 'registry appears reachable'
  refute_output --partial 'ACQ_MSB_DNS_NAMESERVER'
  refute_output --partial 'did not RESOLVE'
  refute_output --partial 'NOT REACHABLE'
  refute_output --partial 'npm is not present'
}

# Attach helper: source msb + run acq_backend_attach in a subshell.
_attach() { # PRE_SNIPPET NAME
  : > "$CALLS"
  run bash -c '
    pre="$1"; name="$2"
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_attach "$name" 2>&1
  ' _ "$1" "$2"
}

@test "msb: attach launches the recorded agent as agent user with a PTY (not root, not ssh)" {
  _attach 'export STUB_RECORDED_AGENT=opencode STUB_RECORDED_WORKSPACE=/tmp/myrepo STUB_AGENT_PRESENT=1' attachbox
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec -t -u agent'
  assert_regex "$log" '-u agent -w /tmp/myrepo'
  assert_regex "$log" '-e SHELL=/bin/sh'
  assert_regex "$log" 'attachbox -- opencode'
  refute_regex "$log" 'msb ssh'
  refute_regex "$log" 'su - agent'
}

@test "msb: attach falls back to a shell (with notice) when the agent binary is missing" {
  _attach 'export STUB_RECORDED_AGENT=opencode STUB_RECORDED_WORKSPACE=/tmp/myrepo STUB_AGENT_PRESENT=0' attachbox
  assert_regex "$(cat "$CALLS")" 'attachbox -- /bin/sh -l'
  assert_output --partial 'not found in sandbox'
}

@test "msb: a shell sandbox attaches to an explicit login shell as agent" {
  _attach 'export STUB_RECORDED_AGENT=shell STUB_RECORDED_WORKSPACE=/tmp/wsp' shellattach
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec -t -u agent -w /tmp/wsp'
  assert_regex "$log" 'shellattach -- /bin/sh -l'
  refute_regex "$log" 'shellattach -- shell'
  refute_regex "$log" 'msb ssh'
}

@test "msb: acq exec runs as the agent user with HOME set, passthrough preserved (not root)" {
  : > "$CALLS"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run execbox -- sh -c "ls ~/.local/bin/opencode" >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec -u agent'
  assert_regex "$log" '-u agent -e HOME=/home/agent'
  assert_regex "$log" '-e HOME=/home/agent execbox'
  assert_regex "$log" 'execbox -- sh -c ls ~/.local/bin/opencode'
  refute_regex "$log" 'msb exec execbox --'
}

@test "msb: a hostile agent token is refused on install and never emitted as sh -c" {
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/inj-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    _acq_msb_install_agent injbox "x'"'"';touch /tmp/acq_pwn;'"'"'" 2>&1
  '
  assert_output --partial 'refusing agent name'
  refute_regex "$(cat "$CALLS")" 'touch /tmp/acq_pwn'
}

@test "msb: attach with a tampered agent marker falls back to shell, never runs the injection" {
  _attach 'export STUB_RECORDED_AGENT="x'"'"';touch /tmp/acq_pwn;'"'"'" STUB_RECORDED_WORKSPACE=/tmp/wsp' injattach
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'touch /tmp/acq_pwn'
  assert_regex "$log" 'injattach -- /bin/sh -l'
}

@test "msb: OCI (podman) engine setup runs as root, configures storage, verifies rootless" {
  _provision ocibox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/oci-secrets"'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'PODMAN_PKGS='
  assert_regex "$log" '/usr/local/bin/docker'
  assert_regex "$log" "touch '/var/lib/acq/oci-ready'"
  assert_regex "$log" '/etc/containers/storage\.conf'
  assert_regex "$log" 'driver = ..vfs..'
  assert_regex "$log" 'mount_program'
  assert_regex "$log" 'fuse-overlayfs'
  assert_regex "$log" 'uidmap'
  assert_regex "$log" 'passt'
  assert_regex "$log" 'slirp4netns'
  assert_regex "$log" 'exec podman'
  refute_regex "$log" 'exec sudo -n podman'
  assert_regex "$log" '/dev/net/tun'
  assert_regex "$log" '/dev/fuse'
  assert_regex "$log" 'chown root:agent'
  assert_regex "$log" 'unqualified-search-registries = ...docker.io...'
  assert_regex "$log" 'docker\.io/library/hello-world'
  assert_regex "$log" 'short-name-mode = ...SHORT_NAME_MODE.'
  assert_regex "$log" 'SHORT_NAME_MODE=enforcing'
  refute_regex "$log" 'SHORT_NAME_MODE=permissive'
  assert_regex "$log" 'msb exec ocibox -u 0 -e PODMAN_PKGS='
  assert_regex "$log" 'msb exec ocibox -u agent -e HOME=/home/agent'
  assert_regex "$log" 'acq-oci-selftest'
}

@test "msb: ACQ_MSB_SHORT_NAME_MODE=permissive threads the permissive value" {
  _provision ocipermbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/oci-perm-secrets" ACQ_MSB_SHORT_NAME_MODE=permissive'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'SHORT_NAME_MODE=permissive'
  refute_regex "$log" 'SHORT_NAME_MODE=enforcing'
}

@test "msb: an invalid ACQ_MSB_SHORT_NAME_MODE warns and falls back to enforcing" {
  _provision ocibadbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/oci-bad-secrets" ACQ_MSB_SHORT_NAME_MODE="bogus; rm -rf /"'
  assert_output --partial 'invalid ACQ_MSB_SHORT_NAME_MODE'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'SHORT_NAME_MODE=enforcing'
  refute_regex "$log" 'SHORT_NAME_MODE=bogus'
  refute_regex "$log" 'rm -rf /'
}

@test "msb: the OCI setup is skipped when the ready marker already exists" {
  _provision ocirdybox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/ociready-secrets" STUB_OCI_READY=1'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "test -f '/var/lib/acq/oci-ready'"
  refute_regex "$log" 'PODMAN_PKGS='
  refute_regex "$log" '/usr/local/bin/docker'
}

@test "msb: ACQ_MSB_ENSURE_OCI=0 skips the OCI step entirely" {
  _provision ocioffbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/ocioff-secrets" ACQ_MSB_ENSURE_OCI=0'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'PODMAN_PKGS='
  refute_regex "$log" 'oci-ready'
}

@test "msb: an OCI setup failure is fail-soft (rc 0, warns, marker not touched)" {
  _provision ocifailbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/ocifail-secrets" STUB_OCI_SETUP_FAIL=1'
  assert_success
  assert_output --partial 'could not provision an OCI engine'
  refute_regex "$(cat "$CALLS")" "touch '/var/lib/acq/oci-ready'"
}

@test "msb: an unsafe ACQ_MSB_PODMAN_PKGS is refused and never reaches an exec" {
  _provision ociinjbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/ociinj-secrets" ACQ_MSB_PODMAN_PKGS="podman;rm -rf"'
  assert_output --partial 'unsafe characters'
  refute_regex "$(cat "$CALLS")" 'rm -rf'
}
