#!/usr/bin/env bash
#
# 72-msb-agent-user — agent-user creation + uid-1000 kit command (8n)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 8n. msb provision creates the agent user and runs a uid-1000 kit command as
#     `agent` with HOME=/home/agent (NOT as a plain-OCI base's uid-1000 user,
#     e.g. `node` on a node:22-bookworm override), and chowns staged /home/agent
#     files to agent. Uses a kit fixture whose startup command runs as user
#     "1000" and reads a /home/agent file. (The synthesis is a short-circuit on
#     the default image, which already ships `agent`; this exercises the
#     plain-OCI-override path it must still handle.)
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/agent-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # A one-kit fixture: a /home/agent file + a startup command as user 1000.
  aok="${STUBDIR}/agentkit"
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
  _acq_msb_fetch_kit() { printf '%s\n' "$aok"; }
  acq_backend_provision agentbox shell /tmp >/dev/null 2>&1
)
agent_log=$(cat "$CALLS")
assert_contains "msb: provision creates agent user" "$agent_log" "agent"
# The uid-1000 startup command must run as `agent` with HOME=/home/agent,
# never as `-u 1000` (which would be a plain-OCI base's `node` user). acq also
# injects non-interactive git guards (GIT_TERMINAL_PROMPT=0 etc.) between the
# HOME env and the argv, so assert the stable prefix rather than the full line.
assert_contains "msb: uid-1000 kit cmd runs as agent" "$agent_log" "msb exec agentbox -u agent -e HOME=/home/agent"
assert_not_contains "msb: uid-1000 kit cmd not run as -u 1000" "$agent_log" "msb exec agentbox -u 1000 -- node"
# Non-interactive enforcement: kit execs get stdin-free git prompt guards so a
# kit that would prompt (e.g. private `git clone`) fails fast instead of hanging
# provision. Assert the guard env is threaded onto the startup command.
assert_contains "msb: kit cmd gets GIT_TERMINAL_PROMPT=0 guard" "$agent_log" "-e GIT_TERMINAL_PROMPT=0"
# The staged /home/agent file must end up agent-owned — but as of the home-dir
# ownership fix acq chowns the TOP-MOST created subdir under the home
# recursively (so intermediate dirs it created as root become agent-owned too),
# not merely the leaf file. For ~/usai-config/merge-global-config.mjs the top
# is `usai-config`, so `chown -R -P agent /home/agent/usai-config` covers the dir
# AND the file. By NAME (agent), never a numeric uid.
assert_contains "msb: chowns staged /home/agent subtree to agent" "$agent_log" "chown -R -P agent /home/agent/usai-config"
# Agent-user setup must create the user WITHOUT pinning uid 1000 (which collides
# with a plain-OCI base's pre-existing uid-1000 user, e.g. node) and must chown the
# home to agent so it is writable — otherwise every agent-user kit fails with
# Permission denied (the playbook silent-fetch-failure regression).
assert_not_contains "msb: agent user NOT created with a fixed -u 1000" "$agent_log" "useradd -m -d /home/agent -s /bin/sh -u 1000"
assert_contains "msb: chowns /home/agent to the agent user" "$agent_log" 'chown "agent:'
assert_contains "msb: verifies /home/agent is writable by agent" "$agent_log" "test -w /home/agent"
cleanup_stubs

# 8n0. Agent-user setup is FATAL when /home/agent is not writable by agent (a
#      root-owned home silently broke every agent-user kit). Model the su-test
#      probe FAILING and assert provision aborts (rc != 0) rather than degrading.
make_stubs; load_acq
homefail_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/homefail-secrets"
  export STUB_HOME_NOT_WRITABLE=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision homefailbox shell /tmp >/dev/null 2>&1; printf 'RC=%s\n' "$?"
)
assert_contains "msb: unwritable agent home aborts provision (rc!=0)" "$homefail_out" "RC=1"
cleanup_stubs

# 8n1. msb provision satisfies the Docker base-image contract for the agent user:
#      passwordless sudo (sudoers.d drop-in) AND HTTP proxy env preserved across
#      sudo (env_keep). See docs.docker.com kit-reference "Base image requirements".
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/basereq-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision basereqbox shell /tmp >/dev/null 2>&1
)
basereq_log=$(cat "$CALLS")
assert_contains "msb: agent gets passwordless sudo (sudoers.d)" "$basereq_log" "sudoers.d/90-acq-agent"
assert_contains "msb: NOPASSWD rule for agent" "$basereq_log" "NOPASSWD:ALL"
assert_contains "msb: proxy env preserved across sudo (env_keep)" "$basereq_log" "env_keep"
assert_contains "msb: proxy env_keep names HTTPS_PROXY" "$basereq_log" "HTTPS_PROXY"
cleanup_stubs

# 8n2. msb provision INSTALLS the requested agent (opencode) when it is not
#      already present — the reported bug was that opencode was never installed.
#      Install is `npm install -g opencode-ai` as root, and the create call
#      allow-lists the npm registry host so the (default-deny) egress permits it.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inst-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  # Default stub: agent ABSENT -> install runs; npm succeeds.
  acq_backend_provision instbox opencode /tmp >/dev/null 2>&1
)
inst_log=$(cat "$CALLS")
assert_contains "msb: installs opencode via npm -g" "$inst_log" "npm install -g --no-fund --no-audit opencode-ai"
assert_contains "msb: allow-lists npm registry host at create" "$inst_log" "--net-rule allow@registry.npmjs.org"
assert_contains "msb: records the agent for attach" "$inst_log" "/var/lib/acq/agent"
cleanup_stubs

# 8n3. Idempotent install: if the agent binary is already present (e.g. baked
#      into ACQ_MSB_IMAGE), provision does NOT run npm install again.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inst2-secrets" STUB_AGENT_PRESENT=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision inst2box opencode /tmp >/dev/null 2>&1
)
assert_not_contains "msb: skips npm install when agent already present" "$(cat "$CALLS")" "npm install"
cleanup_stubs

# 8n4. `shell` sandbox: no agent binary install, and — under the `strict` tier
#       (empty baseline) — no npm registry allow-list. The npm host is
#       added ONLY for an agent with an install recipe (ADR-0011); a `shell`
#       sandbox needs no npm egress. This test pins that agent-conditional gate,
#       so it runs under `strict` (empty baseline): under `balanced`,
#       registry.npmjs.org is in the sbx-"balanced" set and IS allow-listed for
#       every sandbox by design (see 10b1j6 and ADR-0018) — a separate concern
#       from the agent-install gate exercised here.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/shell-secrets"
  export ACQ_NETWORK_TIER=strict
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision shellbox shell /tmp >/dev/null 2>&1
)
shell_log=$(cat "$CALLS")
assert_not_contains "msb: shell agent does not npm install" "$shell_log" "npm install"
assert_not_contains "msb: shell agent adds no npm net-rule (strict tier)" "$shell_log" "allow@registry.npmjs.org"
cleanup_stubs

# 8n4a. #321: a FAILED npm install is DISAMBIGUATED, not conflated. When npm is
#        present in-guest but the registry is UNREACHABLE (TLS cut), acq must say
#        "not reachable / network" and point at KNOWN_FAILURE_MODES §30 — and must
#        NOT imply npm is missing (the misdiagnosis that sent #305's reporter to
#        reinstall node on the host).
make_stubs; load_acq
: > "$CALLS"
npm_unreach_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmunreach-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=unreachable
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmunreachbox opencode /tmp 2>&1
)
assert_contains "msb #321: unreachable registry reported as NOT REACHABLE" "$npm_unreach_out" "NOT REACHABLE"
assert_contains "msb #321: unreachable registry points at KFM §30" "$npm_unreach_out" "KNOWN_FAILURE_MODES.md §30"
assert_not_contains "msb #321: unreachable registry does NOT claim npm is missing" "$npm_unreach_out" "npm is not present"
cleanup_stubs

# 8n4b. #321: when npm is present but the registry NXDOMAINs (curl exit 6), acq
#        reports it as DNS (split-horizon) and points at ACQ_MSB_DNS_NAMESERVER —
#        again NOT "npm missing".
make_stubs; load_acq
: > "$CALLS"
npm_unres_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmunres-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=unresolved
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmunresbox opencode /tmp 2>&1
)
assert_contains "msb #321: unresolved registry reported as did not RESOLVE" "$npm_unres_out" "did not RESOLVE"
assert_contains "msb #321: unresolved registry points at ACQ_MSB_DNS_NAMESERVER" "$npm_unres_out" "ACQ_MSB_DNS_NAMESERVER"
cleanup_stubs

# 8n4c. #321: when npm is genuinely MISSING in-guest, acq says so (the one case
#        where "use a base image that ships node/npm" is the right advice).
make_stubs; load_acq
: > "$CALLS"
npm_missing_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmmissing-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_MISSING=1
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmmissingbox opencode /tmp 2>&1
)
assert_contains "msb #321: genuinely-missing npm reported as not present" "$npm_missing_out" "npm is not present"
assert_not_contains "msb #321: missing-npm case does not claim unreachable" "$npm_missing_out" "NOT REACHABLE"
cleanup_stubs

# 8n4d. #321: guard against classification BLEED. When npm is present AND the
#        registry RESPONDED (an HTTP error — connection completed), the failure
#        is a real npm/registry error, not a network path problem. acq must give
#        the NEUTRAL guidance and must NOT emit a DNS hint (ACQ_MSB_DNS_NAMESERVER
#        / "did not RESOLVE") or a TLS/reachability hint ("NOT REACHABLE") — those
#        belong only to the unresolved/unreachable branches. This pins the
#        boundary so a future edit can't let the DNS/TLS advice bleed into the
#        neutral case.
make_stubs; load_acq
: > "$CALLS"
npm_responded_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/npmresp-secrets"
  export STUB_NPM_FAIL=1 STUB_NPM_REGISTRY=responded
  . "${REPO_ROOT}/acq.backends/common.sh"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision npmrespbox opencode /tmp 2>&1
)
assert_contains "msb #321: responded registry -> neutral 'appears reachable' branch" "$npm_responded_out" "registry appears reachable"
assert_not_contains "msb #321: neutral branch emits NO DNS resolver hint" "$npm_responded_out" "ACQ_MSB_DNS_NAMESERVER"
assert_not_contains "msb #321: neutral branch does NOT say 'did not RESOLVE'" "$npm_responded_out" "did not RESOLVE"
assert_not_contains "msb #321: neutral branch emits NO TLS/reachability hint" "$npm_responded_out" "NOT REACHABLE"
assert_not_contains "msb #321: neutral branch does not claim npm is missing" "$npm_responded_out" "npm is not present"
cleanup_stubs

# 8n5. Attach LAUNCHES the recorded agent as the `agent` user in the workspace,
#      with a PTY — NOT a bare root shell (the reported bug) and NOT msb's Node
#      REPL default. Uses `msb exec -t -u agent -w <ws>` (not `msb ssh`, which has
#      no tty flag and hung the TUI).
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_RECORDED_AGENT="opencode"
  export STUB_RECORDED_WORKSPACE="/tmp/myrepo"
  export STUB_AGENT_PRESENT=1     # opencode binary present -> attach execs it
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach attachbox >/dev/null 2>&1
)
attach_log=$(cat "$CALLS")
assert_contains "msb: attach allocates a PTY (msb exec -t)" "$attach_log" "msb exec -t -u agent"
assert_contains "msb: attach runs as the agent user" "$attach_log" "-u agent -w /tmp/myrepo"
assert_contains "msb: attach sets a sane SHELL" "$attach_log" "-e SHELL=/bin/sh"
assert_contains "msb: attach execs the recorded agent in the workspace" "$attach_log" "attachbox -- opencode"
assert_not_contains "msb: attach does NOT use msb ssh (no PTY / TUI hang)" "$attach_log" "msb ssh"
assert_not_contains "msb: attach does NOT su - agent (msb exec -u handles it)" "$attach_log" "su - agent"
cleanup_stubs

# 8n5b. Attach FALLS BACK to a shell (with notice) when the recorded agent binary
#       is missing — never leaves the user in a broken/blank session.
make_stubs; load_acq
: > "$CALLS"
missing_out=$(
  export STUB_RECORDED_AGENT="opencode"
  export STUB_RECORDED_WORKSPACE="/tmp/myrepo"
  export STUB_AGENT_PRESENT=0     # opencode absent -> fall back to /bin/sh -l
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach attachbox 2>&1
)
missing_log=$(cat "$CALLS")
assert_contains "msb: attach falls back to shell when agent binary missing" "$missing_log" "attachbox -- /bin/sh -l"
assert_contains "msb: attach warns when agent binary missing" "$missing_out" "not found in sandbox"
cleanup_stubs

# 8n6. Attach on a `shell` sandbox (or an unrecorded agent) opens a login shell
#      as the agent user with a PTY — never a root shell, never msb's Node REPL
#      (so it must pass an explicit `/bin/sh -l`, not omit the command).
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_RECORDED_AGENT="shell"
  export STUB_RECORDED_WORKSPACE="/tmp/wsp"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach shellattach >/dev/null 2>&1
)
shellattach_log=$(cat "$CALLS")
assert_contains "msb: shell attach uses msb exec -t as agent" "$shellattach_log" "msb exec -t -u agent -w /tmp/wsp"
assert_contains "msb: shell attach execs an explicit /bin/sh -l" "$shellattach_log" "shellattach -- /bin/sh -l"
assert_not_contains "msb: shell attach does not exec a named agent" "$shellattach_log" "shellattach -- shell"
assert_not_contains "msb: shell attach does NOT use msb ssh" "$shellattach_log" "msb ssh"
cleanup_stubs

# 8n6b. `acq exec` (acq_backend_run) runs the command as the unprivileged `agent`
#       user with HOME=/home/agent — NOT root with HOME unset (the reported bug).
#       A bare `msb exec NAME -- CMD` runs as root; the `~`/$HOME-relative probes
#       downstream (e.g. openchamber verify's `~/.local/bin/opencode`) then miss
#       the files staged into /home/agent. Flags precede NAME; the `-- CMD…`
#       passthrough survives after NAME unchanged.
make_stubs; load_acq
: > "$CALLS"
(
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_run execbox -- sh -c 'ls ~/.local/bin/opencode' >/dev/null 2>&1
)
execrun_log=$(cat "$CALLS")
assert_contains "msb: exec runs as the agent user (-u agent)" "$execrun_log" "msb exec -u agent"
assert_contains "msb: exec sets HOME=/home/agent" "$execrun_log" "-u agent -e HOME=/home/agent"
assert_contains "msb: exec places flags before the sandbox name" "$execrun_log" "-e HOME=/home/agent execbox"
assert_contains "msb: exec preserves the -- CMD passthrough" "$execrun_log" "execbox -- sh -c ls ~/.local/bin/opencode"
assert_not_contains "msb: exec does NOT run as root (bare msb exec NAME)" "$execrun_log" "msb exec execbox --"
cleanup_stubs

# 8n7. SECURITY: a hostile agent token must never break out of the
#      `sh -c "command -v '$agent'"` single-quoting. (1) install path with a
#      metachar-laden `acq create` agent arg, and (2) attach reading a tampered
#      /var/lib/acq/agent marker — both must refuse/fall back, never emit an
#      `sh -c` string containing the injection.
make_stubs; load_acq
: > "$CALLS"
inj_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/inj-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_install_agent injbox "x';touch /tmp/acq_pwn;'" 2>&1
)
inj_log=$(cat "$CALLS")
assert_contains "msb: install refuses metachar agent token" "$inj_out" "refusing agent name"
assert_not_contains "msb: install never emits the injected sh -c" "$inj_log" "touch /tmp/acq_pwn"
cleanup_stubs

# Attach with a tampered marker (returned by the stub) falls back to a shell and
# never interpolates the injection into an sh -c command-v probe.
make_stubs; load_acq
: > "$CALLS"
(
  export STUB_RECORDED_AGENT="x';touch /tmp/acq_pwn;'"
  export STUB_RECORDED_WORKSPACE="/tmp/wsp"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  acq_backend_attach injattach >/dev/null 2>&1
)
injattach_log=$(cat "$CALLS")
assert_not_contains "msb: attach never runs the injected marker in sh -c" "$injattach_log" "touch /tmp/acq_pwn"
assert_contains "msb: attach falls back to /bin/sh on tampered marker" "$injattach_log" "injattach -- /bin/sh -l"
cleanup_stubs

# 8n8. msb provision ensures an OCI engine (podman) by default: when the
#      oci-ready marker is absent, acq runs ONE big root (`-u 0`) `sh -c` that
#      installs podman + wires the docker->podman alias, then touches the marker.
#      The install is operator config (ACQ_MSB_PODMAN_PKGS) threaded via `-e
#      PODMAN_PKGS=…`; it MUST run as root (never as `-u agent`), and the marker
#      touch confirms success was recorded (idempotence on re-provision).
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/oci-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocibox shell /tmp >/dev/null 2>&1
)
oci_log=$(cat "$CALLS")
assert_contains "msb: OCI setup threads the podman packages (PODMAN_PKGS=)" "$oci_log" "PODMAN_PKGS="
assert_contains "msb: OCI setup wires the docker->podman alias" "$oci_log" "/usr/local/bin/docker"
assert_contains "msb: OCI setup marks ready (touch marker) on success" "$oci_log" "touch '/var/lib/acq/oci-ready'"
# The OCI setup MUST configure a storage driver that works on msb's overlay root:
# podman's default kernel `overlay` driver cannot stack on the overlay-backed
# sandbox FS, so the snippet writes /etc/containers/storage.conf selecting
# fuse-overlayfs (preferred) or vfs (fallback).
assert_contains "msb: OCI setup configures a storage driver (storage.conf)" "$oci_log" "/etc/containers/storage.conf"
assert_contains "msb: OCI setup includes the vfs fallback driver" "$oci_log" 'driver = \"vfs\"'
assert_contains "msb: OCI setup prefers fuse-overlayfs mount_program" "$oci_log" "mount_program"
# fuse-overlayfs + the rootless prereqs are in the default install set.
assert_contains "msb: OCI setup installs fuse-overlayfs by default" "$oci_log" "fuse-overlayfs"
assert_contains "msb: OCI setup installs rootless prereq uidmap" "$oci_log" "uidmap"
assert_contains "msb: OCI setup installs rootless prereq passt" "$oci_log" "passt"
assert_contains "msb: OCI setup installs rootless prereq slirp4netns" "$oci_log" "slirp4netns"
# The docker->podman alias must route to PLAIN podman (rootless engine runs as the
# agent user; NO sudo wrapper).
assert_contains "msb: docker alias routes to plain podman" "$oci_log" "exec podman"
assert_not_contains "msb: docker alias does NOT use sudo" "$oci_log" "exec sudo -n podman"
# Rootless device access: the agent is granted group-scoped access to BOTH
# /dev/net/tun (networking) and /dev/fuse (fuse-overlayfs storage), via
# _acq_msb_grant_oci_devs (a device loop run un-gated on every provision pass).
assert_contains "msb: OCI setup grants agent access to /dev/net/tun" "$oci_log" "/dev/net/tun"
assert_contains "msb: OCI setup grants agent access to /dev/fuse" "$oci_log" "/dev/fuse"
assert_contains "msb: OCI setup group-scopes the device to agent" "$oci_log" 'chown root:agent "$_dev"'
# Docker-Hub-first registry resolution (ADR-0020): unqualified-search + shortname
# alias override so unadorned names resolve to Docker Hub, not quay.io.
assert_contains "msb: OCI setup writes Docker-Hub-first search registry" "$oci_log" 'unqualified-search-registries = [\"docker.io\"]'
assert_contains "msb: OCI setup remaps hello-world alias to Docker Hub" "$oci_log" 'docker.io/library/hello-world'
# short-name-mode DEFAULT is "enforcing" (PR #302 review): least-privilege /
# prompt-injection defense. The single search-registry keeps unqualified names
# resolving to Docker Hub, so enforcing costs ~no ergonomics but fails closed on
# ambiguous short names (no silent typosquatting/substitution). NOT permissive.
# The written config line templates the value from the guest env var
# ($SHORT_NAME_MODE), which acq threads in via `-e SHORT_NAME_MODE=<value>`, so we
# assert on the threaded env var (that IS the effective config value).
assert_contains "msb: OCI setup templates short-name-mode from the env var" "$oci_log" 'short-name-mode = \"$SHORT_NAME_MODE\"'
assert_contains "msb: OCI setup defaults short-name-mode to enforcing" "$oci_log" "SHORT_NAME_MODE=enforcing"
assert_not_contains "msb: OCI setup does NOT default to permissive short-name-mode" "$oci_log" "SHORT_NAME_MODE=permissive"
# The package INSTALL/config MUST run as root; the engine VERIFY runs rootless as
# the agent user.
assert_contains "msb: OCI install/config runs as root (-u 0)" "$oci_log" "msb exec ocibox -u 0 -e PODMAN_PKGS="
assert_contains "msb: OCI engine verified rootless as the agent user" "$oci_log" "msb exec ocibox -u agent -e HOME=/home/agent"
# The rootless verify must exercise a real LAYER MOUNT (a FROM-scratch build),
# not just `podman info` — `podman info` doesn't open /dev/fuse, so it would pass
# even when the fuse-overlayfs mount fails. The self-test builds acq-oci-selftest.
assert_contains "msb: OCI verify does a real build (layer mount), not just info" "$oci_log" "acq-oci-selftest"
cleanup_stubs

# 8n8b. short-name-mode OPT-IN: ACQ_MSB_SHORT_NAME_MODE=permissive removes the
#       enforcing guardrail — the written config must carry the permissive value.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/oci-perm-secrets" ACQ_MSB_SHORT_NAME_MODE=permissive
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocipermbox shell /tmp >/dev/null 2>&1
)
oci_perm_log=$(cat "$CALLS")
# The config line templates $SHORT_NAME_MODE from the guest env var, so the
# effective value is carried in the threaded `-e SHORT_NAME_MODE=<value>` arg.
assert_contains "msb: ACQ_MSB_SHORT_NAME_MODE=permissive opt-in threads permissive" "$oci_perm_log" "SHORT_NAME_MODE=permissive"
assert_not_contains "msb: permissive opt-in does not also thread enforcing" "$oci_perm_log" "SHORT_NAME_MODE=enforcing"
cleanup_stubs

# 8n8c. short-name-mode FAIL-CLOSED: an invalid ACQ_MSB_SHORT_NAME_MODE value is
#       rejected (warning) and falls back to "enforcing" — never the bad value.
make_stubs; load_acq
: > "$CALLS"
oci_bad_warn=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/oci-bad-secrets" ACQ_MSB_SHORT_NAME_MODE="bogus; rm -rf /"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh" 2>&1 1>/dev/null
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocibadbox shell /tmp >/dev/null 2>&1
)
oci_bad_log=$(cat "$CALLS")
assert_contains "msb: invalid ACQ_MSB_SHORT_NAME_MODE emits a warning" "$oci_bad_warn" "invalid ACQ_MSB_SHORT_NAME_MODE"
assert_contains "msb: invalid short-name-mode falls back to enforcing" "$oci_bad_log" "SHORT_NAME_MODE=enforcing"
assert_not_contains "msb: invalid short-name-mode value is not threaded" "$oci_bad_log" "SHORT_NAME_MODE=bogus"
assert_not_contains "msb: invalid short-name-mode value is not interpolated" "$oci_bad_log" "rm -rf /"
cleanup_stubs

# 8n9. Marker-gated skip: when /var/lib/acq/oci-ready already exists
#      (STUB_OCI_READY=1), the (network-bound) OCI setup exec is short-circuited
#      — no install block runs and the marker is not re-touched.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ociready-secrets" STUB_OCI_READY=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocirdybox shell /tmp >/dev/null 2>&1
)
ocirdy_log=$(cat "$CALLS")
assert_contains "msb: OCI marker probed when gating the skip" "$ocirdy_log" "test -f '/var/lib/acq/oci-ready'"
assert_not_contains "msb: OCI setup skipped when marker present (no PODMAN_PKGS exec)" "$ocirdy_log" "PODMAN_PKGS="
assert_not_contains "msb: OCI alias not re-wired when marker present" "$ocirdy_log" "/usr/local/bin/docker"
cleanup_stubs

# 8n10. Toggle off: with ACQ_MSB_ENSURE_OCI=0 the OCI step is skipped entirely —
#       neither the marker probe nor the setup exec appears.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ocioff-secrets" ACQ_MSB_ENSURE_OCI=0
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocioffbox shell /tmp >/dev/null 2>&1
)
ocioff_log=$(cat "$CALLS")
assert_not_contains "msb: OCI setup never runs when toggled off" "$ocioff_log" "PODMAN_PKGS="
assert_not_contains "msb: OCI marker never probed when toggled off" "$ocioff_log" "oci-ready"
cleanup_stubs

# 8n11. FAIL SOFT: when the OCI setup exec fails (STUB_OCI_SETUP_FAIL=1, modelling
#       an unreachable mirror / failed `podman info`), provision still returns
#       rc 0, a "could not provision an OCI engine" warning is emitted, and the
#       ready marker is NOT touched (so a later provision retries).
make_stubs; load_acq
ocifail_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ocifail-secrets" STUB_OCI_SETUP_FAIL=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ocifailbox shell /tmp 2>&1
  echo "RC=$?"
)
ocifail_log=$(cat "$CALLS")
assert_contains "msb: OCI setup failure is fail-soft (rc 0)" "$ocifail_out" "RC=0"
assert_contains "msb: OCI setup failure warns clearly" "$ocifail_out" "could not provision an OCI engine"
assert_not_contains "msb: OCI ready marker NOT touched on setup failure" "$ocifail_log" "touch '/var/lib/acq/oci-ready'"
cleanup_stubs

# 8n12. SECURITY: ACQ_MSB_PODMAN_PKGS is charset-guarded (it is interpolated into
#       a root `sh -c`). A value with a shell metachar is refused with an "unsafe
#       characters" warning and the injected string never reaches an exec.
make_stubs; load_acq
ociinj_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ociinj-secrets"
  export ACQ_MSB_PODMAN_PKGS="podman;rm -rf"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision ociinjbox shell /tmp 2>&1
)
ociinj_log=$(cat "$CALLS")
assert_contains "msb: unsafe ACQ_MSB_PODMAN_PKGS is refused" "$ociinj_out" "unsafe characters"
assert_not_contains "msb: injected pkg string never reaches an exec" "$ociinj_log" "rm -rf"
cleanup_stubs

