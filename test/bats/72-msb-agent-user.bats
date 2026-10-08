#!/usr/bin/env bats
#
# 72-msb-agent-user.bats — bats port of scripts/test-acq.d/72-msb-agent-user.sh
# (ADR-0025)
#
# msb provision: agent-user creation + uid-1000 kit commands as `agent`, the
# Docker base-image contract (sudo + proxy env_keep), agent-kit selection, attach
# launching the recorded agent with a PTY, exec as the agent user, injection
# guards, and absence of adapter-owned OCI setup.
# Provisions run in isolated subshells; assertions read $CALLS.
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
    seed_host_config_gates msb "$name"
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

@test "msb: provision applies the opencode agent kit without native npm fallback" {
  _provision instbox opencode 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/inst-secrets" ACQ_NETWORK_TIER=strict'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'npm install'
  refute_regex "$log" 'allow@registry\.npmjs\.org'
  assert_equal "$(cat "$ACQ_PROVENANCE_DIR"/msb/instbox.*.config/agent 2>/dev/null)" "opencode"
}

@test "msb: a shell sandbox has no agent kit and adds no npm net-rule" {
  _provision shellbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/shell-secrets" ACQ_NETWORK_TIER=strict'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'npm install'
  refute_regex "$log" 'allow@registry\.npmjs\.org'
}

# Attach helper: source msb + run acq_backend_attach in a subshell.
_attach() { # PRE_SNIPPET NAME
  : > "$CALLS"
  run bash -c '
    pre="$1"; name="$2"
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb "$name"
    seed_host_config_gates msb "$name"
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

@test "msb: legacy sandbox uses trusted provenance for its agent and workspace" {
  : > "$CALLS"
  run bash -c '
    set -euo pipefail
    export STUB_AGENT_PRESENT=1
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_provenance_write msb legacybox opencode /tmp/legacy-repo
    _acq_msb_attach legacybox </dev/null >/dev/null 2>&1
  '
  assert_success
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb exec -t -u agent -w /tmp/legacy-repo'
  assert_regex "$log" 'legacybox -- opencode'
  refute_regex "$log" 'legacybox -- /bin/sh -l'
}

@test "msb: host-config agent overrides stale provenance" {
  run bash -c '
    set -euo pipefail
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_provenance_write msb precedencebox opencode
    acq_host_config_write msb precedencebox agent shell
    acq_backend_recorded_agent precedencebox
  '
  assert_success
  assert_output 'shell'
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

@test "msb: attach with a garbage recorded agent falls back to shell, never runs the injection" {
  _attach 'export STUB_RECORDED_AGENT="x'"'"';touch /tmp/acq_pwn;'"'"'" STUB_RECORDED_WORKSPACE=/tmp/wsp' injattach
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'touch /tmp/acq_pwn'
  assert_regex "$log" 'injattach -- /bin/sh -l'
}

@test "msb: provision without oci-engine does not install podman or grant OCI devices" {
  _provision ocibox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/oci-secrets"'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'PODMAN_PKGS='
  refute_regex "$log" '/usr/local/bin/docker'
  refute_regex "$log" 'oci-ready'
  refute_regex "$log" '/etc/containers/storage\.conf'
  refute_regex "$log" 'acq-oci-selftest'
  refute_regex "$log" '/dev/net/tun'
  refute_regex "$log" '/dev/fuse'
  refute_regex "$log" 'chown root:agent'
}

# msb session parity: sbx is a full session transport, so
# cwd/terminal identity/login shell come free; msb exposes only raw `msb exec`,
# so the adapter must synthesize each piece on its session paths.

@test "msb #421: acq exec passes -w with the recorded workspace" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb wsbox
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" '\-u agent -e HOME=/home/agent -w /tmp/myrepo wsbox -- git status'
}

@test "msb #421: acq exec honors ACQ_MSB_WORKSPACE and falls back to /home/agent" {
  : > "$CALLS"
  run bash -c '
    export ACQ_MSB_WORKSPACE=/tmp/override STUB_RECORDED_WORKSPACE=/tmp/myrepo
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb wsbox
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" '\-w /tmp/override wsbox'
  : > "$CALLS"
  run bash -c '
    unset ACQ_MSB_WORKSPACE STUB_RECORDED_WORKSPACE
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_host_config_clear msb wsbox workspace
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  assert_regex "$(cat "$CALLS")" '\-w /home/agent wsbox'
}

@test "msb #421: acq exec uses trusted provenance for a legacy workspace" {
  : > "$CALLS"
  run bash -c '
    set -euo pipefail
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_provenance_write msb legacywsbox shell /tmp/legacy-repo
    acq_backend_run legacywsbox -- git status >/dev/null 2>&1
  '
  assert_success
  assert_regex "$(cat "$CALLS")" '\-w /tmp/legacy-repo legacywsbox -- git status'
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

@test "rc.d(msb): login-profile bridge sources kit-owned shell snippets lexically" {
  _provision rcdbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/rcd-secrets"'
  local log; log=$(cat "$CALLS")
  # The bridge sources ~/.rc.d in deterministic C-collation order (ADR-0030):
  # it must iterate an `LC_ALL=C ls "$HOME"/.rc.d` list, NOT a bare locale-
  # dependent `*.sh` glob whose order can vary by guest locale.
  assert_regex "$log" 'LC_ALL=C ls'
  assert_regex "$log" '\$HOME./.rc.d'
  assert_regex "$log" 'for _acq_rc in'
  assert_regex "$log" 'SC1090'
  assert_regex "$log" 'unset _acq_rc'
  # Non-.sh files are skipped by the in-loop suffix case guard.
  assert_regex "$log" '\*.sh) ;; \*) continue'
  refute_regex "$log" 'direnv allow'
}

@test "rc.d: generated login-profile block executes snippets in byte order" {
  local home="$STUBDIR/rc-home"
  mkdir -p "$home/.rc.d"
  printf '%s\n' 'printf "%s\n" 2-b >> "$HOME/order"' > "$home/.rc.d/2-b.sh"
  printf '%s\n' 'printf "%s\n" 10-a >> "$HOME/order"' > "$home/.rc.d/10-a.sh"
  printf '%s\n' 'printf "%s\n" skipped >> "$HOME/order"' > "$home/.rc.d/30-skip.txt"
  acq_login_profile_rc_block > "$home/profile"

  run env HOME="$home" bash -c '. "$HOME/profile"; cat "$HOME/order"'

  assert_success
  assert_output $'10-a\n2-b'
}

@test "msb #426: the heal only rewrites a .profile acq owns outright (appended lines survive)" {
  # Tools like rustup append to ~/.profile below acq's bridge. The rewrite
  # condition must be marker-present AND still just the bridge (line-count
  # bound), so a marker+appended file is left alone instead of clobbered on
  # every heal.
  _provision profguard shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/profguard-secrets"'
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'acq-login-profile "\$profile"'
  # Bound = 3 header lines + the shared rc-block's line count (common.sh
  # acq_login_profile_rc_block), computed host-side and passed as $3/max_lines.
  assert_regex "$log" '\-le .\$max_lines'
}

@test "msb: repeated acq exec applies the cached host workspace" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb cachebox
    acq_backend_run cachebox -- git status >/dev/null 2>&1
    acq_backend_run cachebox -- git log >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
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
    seed_host_config_gates msb healshbox
    # shellcheck disable=SC2034  # consumed by the sourced acq_backend_ensure_kits_applied
    ACQ_CLI_KITS=()
    acq_backend_ensure_kits_applied healshbox >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
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

@test "msb #422: the recursive home chown is reserved for an acq-created agent user" {
  _provision chownbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/chown-secrets"'
  local log; log=$(cat "$CALLS")
  # The top-level dir chown stays unconditional (single inode, asserts the
  # contract on every path).
  assert_regex "$log" 'chown "agent:[^ ]* /home/agent'
  # The full write-crawl only fires when acq itself created the user; a
  # pre-existing agent user means the image baked ownership.
  assert_regex "$log" 'useradd -M -d /home/agent -s /bin/sh agent'
  assert_regex "$log" '_acq_created_agent=1'
  assert_regex "$log" 'if \[ "\$_acq_created_agent" = 1 \]; then chown -R "agent:'
  refute_regex "$log" $'\n[[:space:]]*chown -R "agent:'
  # The writability backstop survives the skip.
  assert_regex "$log" 'test -w /home/agent'
}

@test "msb #422: provision wraps the agent-user step in a progress status" {
  _provision spinusrbox shell 'export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/spinusr-secrets"'
  assert_output --partial 'Preparing the agent user'
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

@test "msb: default user exec stays direct backend argv in the primary repo" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb wsbox
    ACQ_SESSION_KIND=exec
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  local line; line=$(grep -- 'wsbox -- git status' "$CALLS")
  assert_regex "$line" '\-w /tmp/myrepo'
  assert_regex "$line" 'wsbox -- git status'
  refute_regex "$line" 'ACQ_WORKSPACE=/tmp/myrepo'
  refute_regex "$line" 'direnv export| sh -c | -lc '
}

@test "msb: opt-in user exec evaluates already-approved direnv export" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo ACQ_ACTIVATE_PROJECT_ENV=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb wsbox
    ACQ_SESSION_KIND=exec
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '-e ACQ_WORKSPACE=/tmp/myrepo wsbox -- sh -c'
  assert_regex "$log" 'direnv export sh'
  refute_regex "$log" 'direnv allow| -lc '
}

@test "msb: opt-in non-interactive exec does not use login flags" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo STUB_AGENT_PASSWD_SHELL=/bin/sh
    export ACQ_ACTIVATE_PROJECT_ENV=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb wsbox
    ACQ_SESSION_KIND=exec
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'wsbox -- sh -c'
  refute_regex "$log" '/bin/sh -lc|/bin/bash -lc'
}

@test "msb: internal exec helpers are not wrapped as user project sessions" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo ACQ_ACTIVATE_PROJECT_ENV=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    seed_host_config msb wsbox
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'wsbox -- git status'
  refute_regex "$log" 'ACQ_WORKSPACE=/tmp/myrepo'
  refute_regex "$log" 'direnv export'
}

@test "msb: inherited session marker cannot wrap internal helper exec" {
  : > "$CALLS"
  run bash -c '
    export STUB_RECORDED_WORKSPACE=/tmp/myrepo ACQ_ACTIVATE_PROJECT_ENV=1 ACQ_SESSION_KIND=exec
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    acq_backend_run wsbox -- git status >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'wsbox -- git status'
  refute_regex "$log" 'ACQ_WORKSPACE=/tmp/myrepo'
  refute_regex "$log" 'direnv export'
}
