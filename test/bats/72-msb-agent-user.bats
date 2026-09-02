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
  assert_regex "$log" '-w /home/agent execbox'
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

# msb session parity: sbx is a full session transport, so
# cwd/terminal identity/login shell come free; msb exposes only raw `msb exec`,
# so the adapter must synthesize each piece on its session paths.

@test "msb #421: acq exec passes -w with the recorded workspace" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" '\-u agent -e HOME=/home/agent -w /tmp/myrepo wsbox -- git status'
}

@test "msb #421: acq exec honors ACQ_MSB_WORKSPACE and falls back to /home/agent" {
  : > "$CALLS"
  run bash -c '
    export ACQ_MSB_WORKSPACE=/tmp/override STUB_RECORDED_WORKSPACE=/tmp/myrepo
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" '\-w /tmp/override wsbox'
  : > "$CALLS"
  run bash -c '
    unset ACQ_MSB_WORKSPACE STUB_RECORDED_WORKSPACE
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" '\-w /home/agent wsbox'
}

@test "msb #425: attach and shell forward the host TERM/COLORTERM when set" {
  _attach 'export TERM=xterm-256color COLORTERM=truecolor STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1 STUB_RECORDED_WORKSPACE=/tmp/wsp' termbox
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec -t -u agent -w /tmp/wsp -e TERM=xterm-256color -e COLORTERM=truecolor'
  : > "$CALLS"
  run bash -c '
    export TERM=xterm-256color COLORTERM=truecolor
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_shell_exec termbox </dev/null >/dev/null 2>&1 )
  '
  assert_regex "$(cat "$CALLS")" '\-e TERM=xterm-256color -e COLORTERM=truecolor'
}

@test "msb #425: unset TERM/COLORTERM are not invented on interactive paths" {
  _attach 'unset TERM COLORTERM; export STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1 STUB_RECORDED_WORKSPACE=/tmp/wsp' termbox
  local log; log=$(cat "$CALLS")
  refute_regex "$log" '\-e TERM='
  refute_regex "$log" '\-e COLORTERM='
}

@test "msb #425: non-interactive acq exec does not forward TERM/COLORTERM" {
  : > "$CALLS"
  run bash -c '
    export TERM=xterm-256color COLORTERM=truecolor
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run termbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  refute_regex "$log" '\-e TERM='
  refute_regex "$log" '\-e COLORTERM='
}

@test "msb #426: provision sets the agent passwd shell to bash when the image has it" {
  _provision bashshbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/bashsh-secrets"'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'command -v bash'
  assert_regex "$log" 'acq-login-profile.* sh /bin/bash'
  refute_regex "$log" 'acq-login-profile.* sh /bin/sh$'
}

@test "msb #426: a bash-less image keeps the /bin/sh passwd shell" {
  _provision noshbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/nosh-secrets" STUB_GUEST_BASH=0'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'acq-login-profile.* sh /bin/sh'
  refute_regex "$log" 'sh /bin/bash'
}

@test "msb #426: the login-profile bridge exports SHELL and sources .bashrc under bash" {
  _provision bridgebox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/bridge-secrets"'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'usermod -s'
  assert_regex "$log" 'BASH_VERSION'
  assert_regex "$log" '\.bashrc'
  # The bridge must export the shell passwd ACTUALLY holds after the sync
  # attempt (re-read), not the requested target: on an image with bash but no
  # usermod/chsh the passwd shell stays /bin/sh and SHELL must not lie.
  assert_regex "$log" 'export SHELL=\$current'
  refute_regex "$log" 'export SHELL=\$target'
}

@test "msb #426: the heal only rewrites a .profile acq owns outright (appended lines survive)" {
  # Tools like rustup append to ~/.profile below acq's bridge. The rewrite
  # condition must be marker-present AND still just the bridge (line-count
  # bound), so a marker+appended file is left alone instead of clobbered on
  # every heal.
  _provision profguard shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/profguard-secrets"'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'acq-login-profile "\$profile"'
  assert_regex "$log" '\-le 3'
}

@test "msb: repeated acq exec reads the workspace marker once per process (cached)" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run cachebox -- git status >/dev/null 2>&1
    acq_backend_run cachebox -- git log >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_equal "$(grep -c 'cat /var/lib/acq/workspace' "$CALLS")" "1"
  assert_equal "$(grep -c -- '-w /tmp/myrepo cachebox' "$CALLS")" "2"
}

@test "msb #426: heal upgrades an existing /bin/sh agent user (marker hit still syncs the shell)" {
  : > "$CALLS"
  printf 'healshbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'healshbox\n' > "$STUBDIR/.msb_running_list"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/healsh-secrets" STUB_AGENT_USER_READY=1
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    # shellcheck disable=SC2034  # consumed by the sourced acq_backend_ensure_kits_applied
    ACQ_CLI_KITS=()
    acq_backend_ensure_kits_applied healshbox >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" "test -f '/var/lib/acq/agent-user-ready'"
  assert_regex "$log" 'acq-login-profile.* sh /bin/bash'
  refute_regex "$log" 'useradd'
}

@test "msb #426: shell and attach exec the agent passwd shell and set SHELL to match" {
  : > "$CALLS"
  run bash -c '
    export STUB_AGENT_PASSWD_SHELL=/bin/bash
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_shell_exec pshbox </dev/null >/dev/null 2>&1 )
  '
  assert_regex "$(cat "$CALLS")" '\-e SHELL=/bin/bash pshbox -- /bin/bash -l'
  _attach 'export STUB_AGENT_PASSWD_SHELL=/bin/bash STUB_RECORDED_AGENT=opencode STUB_AGENT_PRESENT=1 STUB_RECORDED_WORKSPACE=/tmp/wsp' pshbox
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '\-e SHELL=/bin/bash'
  assert_regex "$log" 'pshbox -- opencode'
}

@test "msb #426: a garbage passwd shell falls back to /bin/sh" {
  : > "$CALLS"
  run bash -c '
    export STUB_AGENT_PASSWD_SHELL="bad shell; rm -rf /"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    ( _acq_msb_shell_exec badshbox </dev/null >/dev/null 2>&1 )
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '\-e SHELL=/bin/sh badshbox -- /bin/sh -l'
  refute_regex "$log" 'rm -rf'
}
