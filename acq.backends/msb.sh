#!/bin/bash
#
# acq.backends/msb.sh — microsandbox (msb) backend adapter for acq
#
# Implements the adapter contract defined in
# docs/adr/0010-acq-pluggable-backends.md ("Adapter contract"). Each
# acq_backend_* function maps the acq contract onto the microsandbox `msb` CLI.
#
# Sourced by acq (via acq_resolve_backend) after common.sh (which sources
# kit-translate.sh) is already loaded. Never run directly.
#
# ---------------------------------------------------------------------------
# CLI VERIFICATION STATUS
# ---------------------------------------------------------------------------
# The flag/subcommand shapes below were verified against the microsandbox CLI
# `msb 0.6.6` (superradcompany/microsandbox v0.6.6, linux/aarch64) via
# `msb --tree` and per-command `--help`. Confirmed present in 0.6.6:
#   - `msb create --name … --net-rule <TOKENS> --trust-host-cas --tls-intercept
#      --secret <ENV@HOST> --copy-file <SRC:DST> --env <K=V> IMAGE`
#   - `msb exec <NAME> [-u USER] -- CMD…`
#   - `msb list|ls [-q] [--running]`, `msb stop`, `msb remove|rm [-f]`,
#     `msb copy|cp SRC DST`, `msb ssh [SANDBOX] [-- CMD…]`, `msb ssh authorize`,
#     `msb run … -p HOST:GUEST` (published ports), `msb doctor`.
# net-rule grammar (verified from --help): `<action>[:<direction>]@<target>
#   [:<proto>[:<ports>]]`. For a literal hostname the target is the BARE FQDN,
#   e.g. `allow@api.gsa.usai.gov` (per the msb --help example
#   `allow@example.com:tcp:443`).
#
# NOT LIVE-VERIFIED (no /dev/kvm + no nested sandboxes in the build env — see
# ADR-0011 "Validation"): the end-to-end create→exec→attach loop, the exact
# `msb ls` column layout parsed by acq_backend_exists, and secret round-trip to
# a USAi 200. These are marked inline and deferred to a sandbox-capable host.

# Capability flags (declared per the ADR-0010 contract; values per the
# acq-design §7 msb column, corrected to what msb 0.6.6 actually offers).
# shellcheck disable=SC2034
ACQ_BACKEND_NAME="msb"
# ACQ_BACKEND_SUPPORTS_PORT_FORWARD gates the POST-HOC `acq ports` verb (matching
# sbx's meaning). msb has no post-hoc NAT publish, but it DOES have a post-hoc
# path (confirmed via `msb --tree` on msb 0.6.7): `msb ssh serve <sandbox>` opens
# a host-side SSH listener against a RUNNING sandbox, and OpenSSH `-L` local
# forwarding then tunnels a guest port to the host with no restart. acq_backend_ports
# wires that (ADR-0015), so this is now 1 — post-hoc `acq ports --publish H:G` works.
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_PORT_FORWARD=1        # post-hoc publish via `msb ssh serve` + OpenSSH -L forwarding (ADR-0015)
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_SNAPSHOTS=0           # msb HAS `msb snapshot`, but acq exposes NO `snapshot` verb; wiring one is beyond sbx parity (sbx has none), so this flag reflects what acq surfaces (0), not what msb can do (#225)
# shellcheck disable=SC2034
ACQ_BACKEND_CAN_RESUME=1                   # msb stop / msb start preserve state
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE=1  # msb --secret ENV@HOST + --tls-intercept

# Minimum msb version required. 0.6.x is the first line with the neutral net
# rules, --trust-host-cas, and --secret used here.
MIN_MSB_VERSION="0.6.0"

# Default OCI image for provisioned sandboxes. Unlike sbx (whose templates
# supply the agent image), msb runs a plain OCI image and acq layers the kits on
# top. The default is the public `node:22-bookworm` image — it is built on
# buildpack-deps:bookworm-scm, so it ALREADY ships node, git, curl, and
# ca-certificates (exactly the four kits' runtime prerequisites), and it is
# pullable from Docker Hub without registry auth.
#
# We deliberately do NOT apt-install prerequisites at runtime: the kit net-rules
# lock egress to only the kits' own hosts (api.gsa.usai.gov, github.com, ...),
# so a package mirror (deb.debian.org) is unreachable during provision. Baking
# the tools into the base image avoids both the egress hole and the runtime
# install. Override with ACQ_MSB_IMAGE to bring your own (e.g. a lighter or
# org-internal image) — see the prerequisite contract below.
ACQ_MSB_IMAGE="${ACQ_MSB_IMAGE:-docker.io/library/node:22-bookworm}"

# Prerequisite tools the pinned four kits need at runtime, expected to be
# PRESENT IN THE BASE IMAGE (the default node:22-bookworm provides all four):
#   node          — usai-provider merge-global-config.mjs
#   git           — agentic-coding-playbook clone + git-ssh-sign
#   curl          — health/verification checks
#   update-ca-certificates — zscaler-ca-certificate trust rebuild
# Before applying kits, the adapter VERIFIES these are present and warns if not
# (it does NOT install them — see the note above about locked egress). Set
# ACQ_MSB_SKIP_PREREQ_CHECK=1 to skip the check entirely.
ACQ_MSB_SKIP_PREREQ_CHECK="${ACQ_MSB_SKIP_PREREQ_CHECK:-}"

# Where fetched neutral kits are materialized for this run (msb has no native
# kit mechanism, so acq drives the parsed operations itself).
ACQ_MSB_KIT_CACHE="${ACQ_MSB_KIT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/acq/kits}"

# Max seconds to wait for `msb exec` to work after create (the guest boots in
# the background; kit application must not race it). Mirrors sbx's
# ACQ_EXEC_READY_TIMEOUT.
ACQ_MSB_EXEC_READY_TIMEOUT="${ACQ_MSB_EXEC_READY_TIMEOUT:-${ACQ_EXEC_READY_TIMEOUT:-60}}"

# USAi models path (matches common.sh USAI_MODELS_URL host) for --secret host.
ACQ_MSB_USAI_HOST="api.gsa.usai.gov"

# GitHub credential host for the msb --secret binding. We bind the github token
# to the REST API host ONLY (api.github.com), which msb substitutes on the wire
# (verified msb 0.6.7). We deliberately do NOT bind github.com/codeload.github.com
# because msb does not substitute git's smart-HTTP transport there (quickstart#203)
# and a multi-host binding also trips microsandbox #1170 (ineligible entry blocks
# eligible). Kits that need github auth must use the REST API (e.g. the playbook
# kit fetches a source tarball from api.github.com), not `git clone`. The env var
# name is GITHUB_TOKEN (the neutral service→env mapping; kits also accept GH_TOKEN).
ACQ_MSB_GITHUB_HOST="${ACQ_MSB_GITHUB_HOST:-api.github.com}"

# _acq_msb_service_binding SERVICE [SANDBOX] -> "ENVVAR<TAB>HOST" for services
# the msb adapter binds via `--secret ENV@HOST`, or empty for services it does
# not bind. Single source of truth for the bind (provision), rotate (set), and
# unbind (secret rm) paths.
#
# quickstart#226 (gap C) — GENERIC custom endpoints: usai + github keep their
# compiled-in mapping (so their behavior/tests are unchanged), but ANY OTHER
# service now resolves its (env, host) from the acq secret store's non-secret
# endpoint sidecar (acq_secret_meta_resolve, written by `acq secret set SVC
# --host H --env E`). So an arbitrary custom endpoint stored with a host/env is
# bound generically instead of being stored-but-inert. Absence of a sidecar =>
# empty (no binding), preserving prior behavior for services with no mapping.
#
# HOST may be a comma-separated multi-host list (mirroring sbx set-custom);
# msb's `--secret ENV@HOST[,HOST...]` accepts that form (verified msb 0.6.7).
# The optional SANDBOX arg gives scoped-sidecar precedence over the global one.
_acq_msb_service_binding() {
  local _service="$1" _sandbox="${2:-}" _meta _host _env
  case "$_service" in
    usai)   printf '%s\t%s\n' "USAI_API_KEY" "$ACQ_MSB_USAI_HOST"; return 0 ;;
    github) printf '%s\t%s\n' "GITHUB_TOKEN" "$ACQ_MSB_GITHUB_HOST"; return 0 ;;
  esac
  # Generic path: read the persisted (host, env) sidecar for a custom endpoint.
  if command -v acq_secret_meta_resolve >/dev/null 2>&1; then
    if _meta=$(acq_secret_meta_resolve "$_service" "$_sandbox" 2>/dev/null) && [ -n "$_meta" ]; then
      _host=$(printf '%s' "$_meta" | cut -f1)
      _env=$(printf '%s' "$_meta" | cut -f2)
      if [ -n "$_host" ] && [ -n "$_env" ]; then
        printf '%s\t%s\n' "$_env" "$_host"
        return 0
      fi
    fi
  fi
  printf '\t\n'
}

# The kits expect an unprivileged `agent` user with HOME=/home/agent (the sbx
# agent-template contract). Plain OCI bases don't provide it, so the adapter
# creates it at provision (see _acq_msb_ensure_agent_user), addressing it by
# NAME — the uid is whatever the base image leaves free (1000 is often taken by
# a pre-existing user, e.g. `node` on node:22-bookworm).

# Guest memory and vCPU allocation.
# ---------------------------------------------------------------------------
# msb 0.6.x defaults a sandbox to 512 MiB RAM and 1 vCPU (see the microsandbox
# config defaults DEFAULT_MEMORY_MIB=512 / DEFAULT_CPUS=1). The microVM has NO
# swap, so a process that exceeds guest RAM is OOM-killed by the guest kernel and
# simply prints "Killed". A Node.js agent TUI like opencode blows past 512 MiB
# immediately, so a create with no memory flag left the user with an agent that
# started and was instantly killed (quickstart#228 follow-up). sbx sizes its
# agent templates generously; msb runs a plain base and must be told, so acq
# passes a generous default here (4 GiB / 2 vCPU) and lets it be tuned.
#
# `msb create` accepts `-m/--memory SIZE` and `-c/--cpus N` (verified against the
# microsandbox SandboxOpts). SIZE takes a single-char unit suffix: `G`/`g` = GiB,
# `M`/`m` = MiB, and a bare number = MiB (there is NO multi-char MiB/GiB suffix).
# So `4G`, `4096`, and `4g` are equivalent. Set ACQ_MSB_MEMORY empty to omit the
# flag and fall back to msb's 512 MiB default (uses `-`, not `:-`, so an
# explicitly-empty value disables the flag rather than re-defaulting). Same for
# ACQ_MSB_CPUS.
ACQ_MSB_MEMORY="${ACQ_MSB_MEMORY-4G}"
ACQ_MSB_CPUS="${ACQ_MSB_CPUS-2}"

# DNS nameserver for the guest. msb hands the guest the HOST's resolvers, but a
# corporate/VPN resolver (e.g. 172.16.x, Zscaler) is typically unreachable from
# the microVM's network namespace — so the guest cannot resolve even the
# allow-listed kit hosts (api.gsa.usai.gov, github.com), and every outbound
# request fails with "Could not resolve host". A public resolver reachable from
# the microVM fixes it (verified: with --dns-nameserver 1.1.1.1 the models API
# resolves + returns 401/200 and github returns 200). Override with a resolver
# reachable from your environment, or set to empty to skip and use msb's default
# (only if the host resolver IS reachable from the guest). Uses `-` (not `:-`)
# so an explicitly-empty value disables the flag rather than re-defaulting.
ACQ_MSB_DNS_NAMESERVER="${ACQ_MSB_DNS_NAMESERVER-1.1.1.1}"

# Agents recognized by acq's run dispatch (mirrors sbx.sh KNOWN_AGENTS).
# shellcheck disable=SC2034
KNOWN_AGENTS=" claude codex copilot cursor docker-agent droid gemini kiro opencode shell "

# Agent binary install.
# ---------------------------------------------------------------------------
# Unlike sbx (whose agent templates BAKE the agent binary into the image), msb
# runs a plain OCI base, so the adapter must install the requested agent itself.
# For `opencode`, install the npm package globally (node is a base-image
# prerequisite the adapter already verifies). The registry host must be reachable
# from the guest, so the adapter allow-lists it at create (kit net-rules are
# default-deny). The install is idempotent (marker-gated + `command -v` guarded).
#
# Only agents with a known install recipe are auto-installed; `shell` is a no-op
# (there is nothing to install), and an unknown agent is a clear, non-fatal warning
# (the user can bake it into ACQ_MSB_IMAGE). Override the opencode package spec
# (e.g. to pin a version like opencode-ai@1.2.3) with ACQ_MSB_OPENCODE_PKG.
ACQ_MSB_OPENCODE_PKG="${ACQ_MSB_OPENCODE_PKG:-opencode-ai}"

# Hosts the agent installer needs to reach, allow-listed at create so egress
# (default-deny under kit net-rules) permits the npm download. registry.npmjs.org
# serves metadata; the tarballs are on the same host for the public registry.
# Override for an internal mirror via ACQ_MSB_NPM_HOSTS (space-separated).
ACQ_MSB_NPM_HOSTS="${ACQ_MSB_NPM_HOSTS:-registry.npmjs.org}"

# ---------------------------------------------------------------------------
# Post-hoc port publish state (ADR-0015)
# ---------------------------------------------------------------------------
# acq manages its OWN ssh keypair (never the user's ~/.ssh) under its state dir,
# and records the `msb ssh serve` + `ssh -L` PIDs per sandbox so `acq rm`/stop can
# tear them down. State lives under $XDG_STATE_HOME/acq (falling back to
# ~/.local/state/acq); override the whole root with ACQ_STATE_DIR (tests do).
ACQ_STATE_DIR="${ACQ_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/acq}"
ACQ_MSB_SSH_DIR="${ACQ_MSB_SSH_DIR:-${ACQ_STATE_DIR}/ssh}"
ACQ_MSB_SSH_KEY="${ACQ_MSB_SSH_KEY:-${ACQ_MSB_SSH_DIR}/msb_id_ed25519}"
ACQ_MSB_SSH_KNOWN_HOSTS="${ACQ_MSB_SSH_KNOWN_HOSTS:-${ACQ_MSB_SSH_DIR}/known_hosts}"
ACQ_MSB_PORTS_DIR="${ACQ_MSB_PORTS_DIR:-${ACQ_STATE_DIR}/ports}"
# SSH user for the serve listener. `msb ssh serve` authorizes a key host-wide;
# the login user on the loopback listener defaults to root (override if a
# deployment's msb serve expects a different account).
ACQ_MSB_SSH_USER="${ACQ_MSB_SSH_USER:-root}"

# Module-level monotonic counter for ephemeral serve-port selection. The call
# site is `sport=$(_acq_msb_pick_ephemeral_port)` — a COMMAND SUBSTITUTION, which
# runs in a subshell, so a plain shell variable incremented inside the helper
# would never persist back to the caller (every publish would recompute the same
# value — exactly the #234 bug). The counter is therefore persisted in a small
# file under the ports state dir so consecutive publishes in one process read
# distinct, increasing values. Seeded from a per-process random base.
_ACQ_MSB_PORT_SEQ_FILE="${ACQ_MSB_PORTS_DIR}/.port-seq"

# Per-process random base offset for ephemeral serve-port selection, evaluated
# ONCE when this file is sourced (not per call). Spreads different processes
# across the range while the persisted per-call counter provides distinct
# offsets WITHIN a process (#234). $$, $RANDOM (bash; empty under POSIX sh,
# handled by the ${RANDOM:-0} default), and the seconds clock give spread.
_ACQ_MSB_PORT_BASE="${_ACQ_MSB_PORT_BASE:-$(( ($$ + ${RANDOM:-0} + $(date +%s 2>/dev/null || echo 0)) % 40000 ))}"

# ---------------------------------------------------------------------------
# Version comparison (shared shape with sbx.sh; kept local to avoid coupling)
# ---------------------------------------------------------------------------

_acq_msb_version_ge() {
  local a="$1" b="$2" i a_part b_part
  local -a a_arr b_arr
  IFS='.' read -r -a a_arr <<EOF
$a
EOF
  IFS='.' read -r -a b_arr <<EOF
$b
EOF
  for i in 0 1 2; do
    a_part=${a_arr[i]:-0}; b_part=${b_arr[i]:-0}
    a_part=${a_part%%[!0-9]*}; b_part=${b_part%%[!0-9]*}
    a_part=${a_part:-0}; b_part=${b_part:-0}
    if [ "$a_part" -gt "$b_part" ]; then echo 0; return; fi
    if [ "$a_part" -lt "$b_part" ]; then echo 1; return; fi
  done
  echo 0
}

# Parse `msb --version` → bare X.Y.Z.
_acq_msb_version() {
  msb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# ---------------------------------------------------------------------------
# acq_backend_prepare — CLI presence + version floor; fail closed
# ---------------------------------------------------------------------------

acq_backend_prepare() {
  if ! command -v msb >/dev/null 2>&1; then
    echo "error: msb (microsandbox) CLI not found on PATH. Install msb >= $MIN_MSB_VERSION:" >&2
    echo "         curl -fsSL https://install.microsandbox.dev | sh   # macOS / Linux" >&2
    echo "         brew install superradcompany/tap/microsandbox" >&2
    echo "       See docs/BACKEND_GUIDE.md (msb backend) for details." >&2
    exit 1
  fi

  local current
  current=$(_acq_msb_version)
  if [ -z "$current" ]; then
    echo "acq: warning: could not determine msb version (need >= $MIN_MSB_VERSION); continuing." >&2
    return 0
  fi
  if [ "$(_acq_msb_version_ge "$current" "$MIN_MSB_VERSION")" -ne 0 ]; then
    echo "error: acq requires msb >= $MIN_MSB_VERSION, but found $current." >&2
    echo "       Upgrade with 'msb self update' (see docs/BACKEND_GUIDE.md)." >&2
    exit 1
  fi

  # msb needs host virtualization (KVM on Linux, HVF on macOS, WHP on Windows).
  # `msb doctor` reports readiness; surface a clear hint but do not hard-fail
  # here (provision will fail closed with msb's own error if the host is unfit).
  if ! msb doctor >/dev/null 2>&1; then
    echo "acq: note — 'msb doctor' reports the host virtualization prerequisites are not" >&2
    echo "      fully met (e.g. /dev/kvm missing). Sandbox creation may fail. Run" >&2
    echo "      'msb doctor --fix' or see docs/BACKEND_GUIDE.md (msb requirements)." >&2
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_exists — 0 if a named sandbox exists, else 1
# ---------------------------------------------------------------------------
# `msb list -q` prints one sandbox name per line (verified via --tree: "-q
# Show only sandbox names"). Match the whole line exactly.
# NOTE: not live-verified against a running daemon; the -q contract is from the
# CLI help. If the column layout differs on a real host, adjust the parse.

acq_backend_exists() {
  msb list -q 2>/dev/null | grep -Fxq -- "$1"
}

# ---------------------------------------------------------------------------
# _acq_msb_wait_for_exec_ready NAME — block until `msb exec` works in the guest
# ---------------------------------------------------------------------------
# msb create returns as soon as the sandbox is registered, but the guest boots
# in the background. Copying files / running kit commands before exec works
# races the boot. Poll a trivial exec until it succeeds (or time out). Mirrors
# sbx.sh's _acq_sbx_wait_for_exec_ready.
#
# Each probe emits a timestamped acq_debug breadcrumb (attempt #, rc, output) so
# that if provision ever stalls in this loop it is visible which probe hung —
# use `ACQ_DEBUG=1` (or `verify-backends -x`) to see it.
_acq_msb_wait_for_exec_ready() {
  local name="$1" deadline out _rc _attempt=0 _now
  deadline=$(( $(date +%s) + ACQ_MSB_EXEC_READY_TIMEOUT ))
  while :; do
    _attempt=$(( _attempt + 1 ))
    acq_debug "msb exec-ready probe #${_attempt} for $name"
    out=$(msb exec "$name" -- sh -c 'echo ok' </dev/null 2>/dev/null | tr -d '\r')
    _rc=$?
    acq_debug "msb exec-ready probe #${_attempt}: rc=${_rc} out='${out}'"
    case "$out" in
      *ok*) acq_debug "msb exec-ready: $name (after ${_attempt} probe(s))"; return 0 ;;
    esac
    _now=$(date +%s)
    if [ "$_now" -ge "$deadline" ]; then
      acq_debug "msb exec-ready: giving up on $name after ${_attempt} probe(s) / ${ACQ_MSB_EXEC_READY_TIMEOUT}s"
      return 1
    fi
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# Kit application helpers (msb drives the neutral spec itself)
# ---------------------------------------------------------------------------
#
# DESIGN NOTE — why kit commands still stage via `msb exec`, not `--script`
# (quickstart#239, evaluated against msb 0.6.7's create/run-time script flags).
# ---------------------------------------------------------------------------
# msb 0.6.7 offers first-class script registration on `create`/`run`:
#   --script NAME=BODY        (inline; escape-decoded; shebang from --shell)
#   --script-raw NAME=BODY    (exact bytes, no shebang)
#   --script-path NAME:PATH   (body read verbatim from a host file)
# Registered scripts land executable at /.msb/scripts/<name>, on the guest PATH.
# The appeal is real: staging a kit command via --script-path passes the body as
# a FILE (no assembling a shell string from kit-provided content). We evaluated
# replacing the kit-command-injection path (_acq_msb_run_commands ->
# _acq_msb_exec_command) with it and DELIBERATELY KEPT the exec-based path. The
# refactor is not a clean net win as this adapter is currently shaped:
#
#   1) TIMING. `--script*` register ONLY at create/run time. But kit commands are
#      NOT all applied at create: _acq_msb_apply_kit_dir is also driven MID-LIFE
#      by acq_backend_apply_kit (`acq kit apply NAME KITREF`, acq:293) and by
#      acq_backend_ensure_kits_applied (the re-attach heal loop, acq:434/461),
#      long after the sandbox was created. A create-time flag cannot register a
#      script into an already-running sandbox, so the mid-life path MUST stay
#      exec-based regardless. Introducing --script only at provision would fork
#      the code into two dissimilar command-dispatch paths (create=script,
#      mid-life=exec) — MORE surface, MORE divergence, for the same observable
#      behavior. A single exec-based path that works in both phases is simpler
#      and is what the whole apply pipeline is already built around.
#
#   2) THE STRING WE WOULD AVOID ISN'T BUILT FROM KIT CONTENT. The safety win of
#      --script is "stop interpolating kit-provided bytes into an `sh -c`
#      string." But this adapter ALREADY does not do that for kit argv: a kit
#      command is carried as base64-encoded argv tokens (kit_spec_commands ->
#      __CMD__ records), decoded into a bash array, and handed to
#      `msb exec … -- "$@"` as SEPARATE ARGV ELEMENTS. Kit content never enters
#      an interpolated shell string on this path; the only `sh -c` around it is
#      the fixed background-detach wrapper (`nohup "$@" … ` with the argv as
#      positional params — gap A, still no interpolation). So the injection risk
#      --script is designed to remove is already absent here; --script would
#      restage the same already-safe argv through a different primitive without
#      reducing attack surface.
#
#   3) IDEMPOTENCY/USER SEMANTICS LIVE IN THE EXEC PATH, NOT IN REGISTRATION.
#      install-phase commands are run-once via a root-owned marker keyed on a
#      hash of the argv (_acq_msb_exec_command: /var/lib/acq/install-<cksum>),
#      tested+written as uid 0 so the gate is independent of the command's own
#      user; initFiles/startup re-run every apply. Per-phase run-as-user
#      (install=root, 1000/agent -> `-u agent` + HOME) and the non-interactive
#      git guards (GIT_TERMINAL_PROMPT=0 …) are all applied at INVOCATION. A
#      registered /.msb/scripts/<name> still has to be INVOKED (as the right
#      user, marker-gated, with the right env) — i.e. we would keep the entire
#      exec+marker+uflag/eflag machinery AND add a registration+guard step on
#      top. Net: strictly more moving parts, identical behavior.
#
#   4) FILE STAGING IS ORTHOGONAL. files[] already stage via `msb copy` +
#      verify + chown (_acq_msb_copy_file_verified); paths are charset-validated
#      and never interpolated. --script-path would only cover the COMMAND body,
#      not files[], so it cannot subsume that path either.
#
# CONCLUSION (per the #239 decision gate): keep the exec-based kit-command
# staging. The one place --script/--script-path would be a clean, contained win
# — a create-time-ONLY, run-once command whose body is genuinely a script file —
# does not exist in the pinned neutral kit vocabulary today (kit commands are
# argv sequences across three phases, applied both at create and mid-life). If a
# future kit schema adds a create-time-only "script" concept, revisit this with
# --script-path for that narrow case only; until then a second dispatch path is
# net-negative. No behavior change; the mid-life exec path is load-bearing.

# Fetch a kit ref into the cache and echo its local dir. Returns 1 on failure.
_acq_msb_fetch_kit() {
  local kitref="$1" slug dest
  # Derive a stable cache subdir from the ref (sha + dir tail).
  slug=$(printf '%s' "$kitref" | tr -c 'A-Za-z0-9._-' '_' )
  dest="${ACQ_MSB_KIT_CACHE}/${slug}"
  if [ -d "$dest/.git" ]; then
    # Already fetched — recompute the kit subdir path from the ref's dir=.
    kit_translate_fetch "$kitref" "$dest"
    return $?
  fi
  kit_translate_fetch "$kitref" "$dest"
}

# Emit the --net-rule flags for a kit's caps.network.allow into the named array.
# Usage: _acq_msb_net_rules_into ARRVAR SPEC
# Uses the codebase's eval-by-name array pattern (see common.sh split_noglob;
# chosen over bash-4.3 namerefs for macOS bash 3.2 compatibility). Each host is
# validated to look like a DNS name/wildcard BEFORE it reaches eval, so a
# malformed or malicious spec value can't smuggle shell metacharacters in.
_acq_msb_net_rules_into() {
  local _arr="$1" _spec="$2" _host
  eval "$_arr=()"
  while IFS= read -r _host; do
    [ -n "$_host" ] || continue
    # msb net-rule grammar: `<action>[:<direction>]@<target>[:<proto>[:<ports>]]`.
    # The target for a literal hostname is the BARE FQDN — the msb --help example
    # is `allow@example.com:tcp:443`. (An earlier acq bug emitted `allow@domain:HOST`,
    # which msb read as the single-label target "domain" and rejected as ambiguous;
    # a real multi-label FQDN like api.gsa.usai.gov is unambiguous as a bare domain,
    # so no `domain=` prefix is needed — and using one can break DNS resolution.)
    # Strip any :port the neutral spec carries (msb keys on the domain; the daemon
    # handles ports/DNS for the allowed host).
    _host="${_host%%:*}"
    # Reject anything that isn't a plausible hostname/wildcard, so a malformed or
    # malicious spec value can't smuggle characters through the eval below.
    case "$_host" in
      ""|*[!A-Za-z0-9.*_-]*)
        echo "acq(msb): warning: skipping non-hostname net-allow entry: $_host" >&2
        continue
        ;;
    esac
    eval "$_arr+=(--net-rule \"allow@\${_host}\")"
  done <<EOF
$(kit_spec_net_allow "$_spec")
EOF
}

# Emit the create-time `-p HOST:GUEST` flags for a kit's published ports into the
# named array. Usage: _acq_msb_port_flags_into ARRVAR SPEC
#
# ADR-0014 (gap A): kit_spec_published_ports reads the NEUTRAL top-level
# `publishedPorts` first (deprecated backend_extras.sbx fallback) and emits
# validated `guest<TAB>proto<TAB>name<TAB>host` records (ports are ints 1..65535,
# so they cannot smuggle shell metacharacters). host defaults to guest. We map
# each to a plain `-p HOST:GUEST` — msb's create/run-time NAT publish. msb -p also
# accepts BIND_ADDR:HOST:GUEST and /udp, but the neutral schema stays TCP +
# default loopback bind for sbx parity, so bind-addr and /udp are deliberately
# NOT emitted. Uses the eval-by-name array pattern (macOS bash 3.2 compat), like
# _acq_msb_net_rules_into. Absence of publishedPorts is a silent no-op: the
# neutral field is read DEFENSIVELY (ADR-0014 cross-repo gate). PATTERNS_KIT_REF
# in common.sh is INTENTIONALLY held at its current pin and NOT bumped here — the
# `publishedPorts`/`background` schema property lives on an unreleased patterns
# branch. Reading defensively (absence = no-op, never an error) lets this consumer
# land now and light up automatically once the patterns schema is released and the
# pin is later bumped.
_acq_msb_port_flags_into() {
  local _arr="$1" _spec="$2" _rec _guest _host
  eval "$_arr=()"
  while IFS="$(printf '\t')" read -r _guest _ _ _host; do
    [ -n "$_guest" ] || continue
    [ -n "$_host" ] || _host="$_guest"
    # Defense-in-depth: the validator already guarantees integer ports, but
    # re-check before the value reaches an argv via eval.
    case "$_guest$_host" in
      *[!0-9]*)
        echo "acq(msb): warning: skipping non-integer published port: ${_host}:${_guest}" >&2
        continue
        ;;
    esac
    eval "$_arr+=(-p \"\${_host}:\${_guest}\")"
  done <<EOF
$(kit_spec_published_ports "$_spec")
EOF
}

# Apply a single fetched kit directory to a running sandbox NAME.
# Honors backend_shortcuts.msb (currently: zscaler trust_host_cas, handled at
# provision time — see acq_backend_provision; here we skip the file/command
# path for a shortcut kit). Drops files and runs install/initFiles/startup
# commands via `msb exec`.
#
# RESOLVED (agentic-coding-playbook kit on msb): the playbook kit fetches a
# PRIVATE GitHub repo. It used to `git clone` over HTTPS, but msb does not
# substitute the credential placeholder for git's smart-HTTP transport to
# github.com/codeload (quickstart#203). The kit now fetches the repo SOURCE
# TARBALL via the REST API (api.github.com/repos/<repo>/tarball/<ref>), which msb
# DOES substitute (verified msb 0.6.7), and acq binds GITHUB_TOKEN@api.github.com
# above. So the playbook now works on msb. USAi, git-ssh-sign, and zscaler kits
# are unaffected. (Upstream git-transport substitution remains unfixed —
# microsandbox #756/#768/#1170 — but the kit no longer depends on it.)
_acq_msb_apply_kit_dir() {
  local name="$1" kitdir="$2"
  local spec="${kitdir}/spec.yaml"
  if [ ! -f "$spec" ]; then
    echo "acq(msb): kit spec not found: $spec" >&2
    return 1
  fi

  # Backend shortcut: if this kit declares a non-empty backend_shortcuts.msb,
  # the native primitive was already applied at provision time — skip the
  # generic files/commands path for this kit.
  if kit_spec_has_shortcut "$spec" msb; then
    return 0
  fi

  # 1) Drop files[] (msb cp host→guest). Files are staged from the kit's files/
  #    tree via the spec's source: field.
  #    kit_spec_files emits tab-separated "path<TAB>mode<TAB>phase<TAB>source"
  #    with possibly-empty middle fields; parse each field explicitly with cut
  #    (a bare `IFS=<tab> read` collapses adjacent empty tab fields).
  #    IMPORTANT: read ALL records into an array FIRST. If we iterated the
  #    heredoc directly, the `msb copy`/`msb exec` calls inside the loop body
  #    would consume the loop's stdin and only the first file would be processed
  #    (this is exactly what dropped merge-global-config.mjs).
  local _frecs=() fline
  while IFS= read -r fline; do
    [ -n "$fline" ] && _frecs+=("$fline")
  done <<EOF
$(kit_spec_files "$spec")
EOF

  local path mode phase source src _i
  for _i in ${_frecs[@]+"${!_frecs[@]}"}; do
    fline="${_frecs[$_i]}"
    path=$(printf '%s' "$fline" | cut -f1)
    mode=$(printf '%s' "$fline" | cut -f2)
    phase=$(printf '%s' "$fline" | cut -f3)
    source=$(printf '%s' "$fline" | cut -f4)
    [ -n "$path" ] || continue
    src=""
    if [ -n "$source" ]; then
      src="${kitdir}/${source}"
    fi
    if [ -n "$src" ] && [ -f "$src" ]; then
      _acq_msb_copy_file_verified "$name" "$src" "$path" "$mode" || {
        echo "acq(msb): error: could not place kit file at ${name}:${path}" >&2
        echo "acq(msb):   subsequent kit commands that read it will fail." >&2
        return 1
      }
    fi
  done

  # 2) Run commands[]. Reassemble each argv record and exec it as the given uid.
  #    install → run once (idempotent, marker-gated); initFiles/startup → every
  #    apply. msb has no create-time-only hook, so install collapses to a
  #    marker-gated exec (design §3 lifecycle table). The kit's environment[]
  #    entries are threaded onto every command as `msb exec -e NAME=value` (msb's
  #    native per-exec env flag), so the kit's declared guest env is present when
  #    its lifecycle commands run.
  _acq_msb_run_commands "$name" "$spec"
}

# Copy a host file into the guest and VERIFY it is readable there before
# returning. Also chown files under /home/agent to the agent user (they are
# copied as root, but the kits' startup commands read them as the agent user;
# see _acq_msb_ensure_agent_user). The verify poll is belt-and-suspenders — msb
# copy/exec persistence is synchronous in practice, but a short readiness poll
# costs nothing and gives a clear error if a copy genuinely didn't land.
_acq_msb_copy_file_verified() {
  local name="$1" src="$2" path="$3" mode="$4"

  # Guard the guest path up front: it is interpolated into root `sh -c` strings
  # below (mkdir/test) and passed to chmod/chown. kit_spec_files already drops
  # unsafe paths, but re-check here so this function is safe regardless of caller
  # (a single-quote-bearing path would otherwise break out of the sh -c quoting).
  case "$path" in
    /*) ;;
    *) echo "acq(msb): refusing kit file with non-absolute path: '$path'" >&2; return 1 ;;
  esac
  case "$path" in
    *[!A-Za-z0-9._/-]*)
      echo "acq(msb): refusing kit file with unsafe path: '$path'" >&2
      return 1
      ;;
  esac

  local dir; dir=$(dirname "$path")

  msb exec "$name" -u 0 -- sh -c "mkdir -p '$dir'" >/dev/null 2>&1 || true
  if ! msb copy "$src" "${name}:${path}" >/dev/null 2>&1; then
    echo "acq(msb): warning: 'msb copy' failed for ${name}:${path}" >&2
  fi

  # Verify the file is present + non-empty in the guest, retrying briefly to
  # absorb copy/boot lag.
  local deadline attempt=0 ok=0
  deadline=$(( $(date +%s) + ${ACQ_MSB_COPY_SETTLE_TIMEOUT:-20} ))
  while :; do
    if msb exec "$name" -u 0 -- sh -c "test -s '$path'" >/dev/null 2>&1; then
      ok=1; break
    fi
    attempt=$((attempt + 1))
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "acq(msb): warning: ${name}:${path} not observable after copy" \
           "(${attempt} checks); retrying copy once." >&2
      msb copy "$src" "${name}:${path}" >/dev/null 2>&1 || true
      msb exec "$name" -u 0 -- sh -c "test -s '$path'" >/dev/null 2>&1 && ok=1
      break
    fi
    sleep 1
  done
  [ "$ok" -eq 1 ] || return 1

  # chmod, then chown files that live under the agent's home so the agent user
  # (which runs the startup commands) can read/execute them. The path was
  # validated at function entry; mode is re-checked octal and passed to chmod as
  # a separate argv element (never interpolated into an sh -c string).
  if [ -n "$mode" ]; then
    case "$mode" in
      [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) : ;;
      *) echo "acq(msb): refusing chmod: non-octal mode '$mode' for '$path'" >&2; mode="" ;;
    esac
  fi
  if [ -n "$mode" ]; then
    msb exec "$name" -u 0 -- chmod "$mode" "$path" >/dev/null 2>&1 || true
  fi
  case "$path" in
    /home/agent/*)
      msb exec "$name" -u 0 -- chown agent "$path" >/dev/null 2>&1 || true
      ;;
  esac
  acq_debug "msb copy verified: ${name}:${path}"
  return 0
}

# Parse and execute a kit spec's commands[] against sandbox NAME.
_acq_msb_run_commands() {
  local name="$1" spec="$2"

  # Collect the kit's environment[] entries as `NAME=value` argv-ready tokens,
  # threaded onto every command's `msb exec` as `-e NAME=value`. kit_spec_env
  # already validates each NAME (^[A-Za-z_][A-Za-z0-9_]*$) and drops unsafe ones,
  # so these are safe to pass as exec env. Values are passed as a single argv
  # element (never re-split by a shell).
  local _kit_env=() eline ekey eval_v
  while IFS= read -r eline; do
    [ -n "$eline" ] || continue
    ekey=$(printf '%s' "$eline" | cut -f1)
    eval_v=$(printf '%s' "$eline" | cut -f2-)
    [ -n "$ekey" ] || continue
    _kit_env+=("${ekey}=${eval_v}")
  done <<EOF
$(kit_spec_env "$spec")
EOF

  # Buffer the parsed command stream FIRST, then execute. The exec step calls
  # `msb exec`, which would consume this loop's stdin if we iterated the heredoc
  # directly — dropping every command after the first (same class of bug as the
  # files loop). So collect records, then run them from the array.
  local _lines=() line
  while IFS= read -r line; do
    _lines+=("$line")
  done <<EOF
$(kit_spec_commands "$spec")
EOF

  local phase="" user="" argv=() reading=0 _i background="false"
  for _i in ${_lines[@]+"${!_lines[@]}"}; do
    line="${_lines[$_i]}"
    case "$line" in
      "__CMD__"*)
        # __CMD__<TAB>phase<TAB>user<TAB>background
        phase=$(printf '%s' "$line" | cut -f2)
        user=$(printf '%s' "$line" | cut -f3)
        background=$(printf '%s' "$line" | cut -f4)
        [ -n "$background" ] || background="false"
        argv=()
        reading=1
        ;;
      "__END__")
        reading=0
        _acq_msb_exec_command "$name" "$phase" "$user" "$background" \
          ${_kit_env[@]+"${_kit_env[@]}"} -- ${argv[@]+"${argv[@]}"}
        ;;
      *)
        if [ "$reading" -eq 1 ]; then
          # argv tokens are base64-encoded (one per line) so multi-line block
          # scalars survive as a single token. Decode back to the raw string.
          argv+=("$(printf '%s' "$line" | base64 -d)")
        fi
        ;;
    esac
  done
}

# Execute one command record. install-phase commands are gated by a per-command
# marker file so they run once per sandbox even across re-applies.
#
# Args: NAME PHASE USER BACKGROUND [NAME=value ...] -- ARGV...
# The optional NAME=value tokens before the literal `--` are the kit's
# environment[] entries; each is threaded to `msb exec` as `-e NAME=value`.
# kit_spec_env already validated the names, so they are safe to pass here.
#
# BACKGROUND (ADR-0014): when "true" (only meaningful for a startup command), the
# command is DETACHED rather than awaited, so a never-exiting supervisor loop
# does not block provision. We reproduce this with the same pattern the adapter
# already uses to keep non-blocking work from stalling the guest: wrap the argv
# in `nohup sh -c '"$@"' … &` inside a single `msb exec` so the process survives
# the exec returning. (msb 0.6.x has no `exec -d`; nohup+& is the portable
# equivalent, matching how sbx's startup semantics detach a background hook.)
# _acq_msb_split_env_argv KITENV_ARRVAR ARGV_ARRVAR TOKEN... — split the leading
# NAME=value env tokens (up to the `--` sentinel) from the trailing argv, into
# the two named arrays. Uses the codebase's eval-by-name array pattern (see
# common.sh split_noglob) for macOS bash 3.2 compat, storing each token via
# `set --`/`"$@"` so no value is re-split or re-quoted.
_acq_msb_split_env_argv() {
  local _envarr="$1" _argvarr="$2"
  shift 2
  eval "$_envarr=()"
  local _tok
  while [ "$#" -gt 0 ]; do
    _tok="$1"; shift
    if [ "$_tok" = "--" ]; then break; fi
    eval "$_envarr+=(\"\$_tok\")"
  done
  eval "$_argvarr=(\"\$@\")"
}

# _acq_msb_exec_flags_into UFLAG_ARRVAR EFLAG_ARRVAR USER KITENV_ARRVAR — build
# the `msb exec` -u/-e flag arrays for one kit command. Maps the sbx uid contract
# (1000/agent) onto our by-name agent user, threads the kit's declared env as
# `-e NAME=value`, and injects git non-interactive guards unless the kit set
# GIT_TERMINAL_PROMPT itself. Arrays passed/returned by name (bash 3.2 compat).
_acq_msb_exec_flags_into() {
  local _uflag="$1" _eflag="$2" _user="$3" _envarr="$4"
  eval "$_uflag=()"
  eval "$_eflag=()"

  # The kits express the unprivileged agent as uid "1000" (the sbx agent-template
  # contract). On a plain OCI base uid 1000 may be a DIFFERENT user (e.g. `node`
  # in node:22-bookworm), so address our provisioned agent by NAME instead, and
  # set HOME=/home/agent so `$HOME`-relative kit logic resolves correctly.
  case "$_user" in
    ""|0|root)
      [ -n "$_user" ] && eval "$_uflag=(-u \"\$_user\")"
      ;;
    1000|agent)
      eval "$_uflag=(-u agent)"
      eval "$_eflag=(-e \"HOME=/home/agent\")"
      ;;
    *)
      eval "$_uflag=(-u \"\$_user\")"
      ;;
  esac

  # Append the kit's declared guest env as additional `-e NAME=value` flags.
  local _ev
  eval "set -- \${${_envarr}[@]+\"\${${_envarr}[@]}\"}"
  for _ev in "$@"; do
    eval "$_eflag+=(-e \"\$_ev\")"
  done

  # NON-INTERACTIVE ENFORCEMENT. Kit lifecycle commands run before the agent
  # attaches, with no terminal, so they MUST NOT try to read from a TTY. Docker's
  # kit-reference states startup commands are non-interactive; a kit that prompts
  # (e.g. `git clone` of a private repo with no credential -> "Username for
  # 'https://github.com':") would BLOCK provision forever (observed: the playbook
  # kit hung here). Defense-in-depth alongside the kit's own prompt-suppression:
  #   - stdin from /dev/null for every kit exec, so nothing can read the TTY.
  #   - GIT_TERMINAL_PROMPT=0 (+ GIT_ASKPASS/SSH_ASKPASS=false) so git fails fast
  #     instead of prompting. These are injected only if the kit did not already
  #     set GIT_TERMINAL_PROMPT (kits may override intentionally).
  local _kit_env_str
  eval "_kit_env_str=\" \${${_envarr}[*]-} \""
  case "$_kit_env_str" in
    *" GIT_TERMINAL_PROMPT="*) : ;;
    *) eval "$_eflag+=(-e \"GIT_TERMINAL_PROMPT=0\" -e \"GIT_ASKPASS=/bin/false\" -e \"SSH_ASKPASS=/bin/false\")" ;;
  esac
}

# _acq_msb_exec_install NAME USER UFLAG_ARRVAR EFLAG_ARRVAR -- ARGV... — run an
# install-phase command, gated by a per-command marker (hash of argv) so it runs
# once per sandbox even across re-applies. The marker lives under /var/lib/acq
# (root-owned) and is both TESTED and WRITTEN as uid 0, so the gate is
# independent of the install command's own user.
_acq_msb_exec_install() {
  local _name="$1" _user="$2" _uflagn="$3" _eflagn="$4"
  shift 4
  [ "$1" = "--" ] && shift
  # Distinct internal names (_uf/_ef) so they cannot collide with a caller array
  # named `uflag`/`eflag` (a `local uflag` would blank the caller's before the
  # eval-by-name read).
  local _uf=() _ef=()
  eval "_uf=(\${${_uflagn}[@]+\"\${${_uflagn}[@]}\"})"
  eval "_ef=(\${${_eflagn}[@]+\"\${${_eflagn}[@]}\"})"

  local marker
  marker="/var/lib/acq/install-$(printf '%s\0' "$@" | cksum | cut -d' ' -f1)"
  if msb exec "$_name" -u 0 -- sh -c "test -f '$marker'" </dev/null >/dev/null 2>&1; then
    acq_debug "msb cmd[install] already done (marker hit): $*"
    return 0
  fi
  acq_debug "msb cmd[install] START (user=${_user:-0}): $*"
  msb exec "$_name" "${_uf[@]}" ${_ef[@]+"${_ef[@]}"} -- "$@" </dev/null || {
    acq_debug "msb cmd[install] FAILED: $*"
    echo "acq(msb): warning: install command failed for '$_name'" >&2
    return 0
  }
  acq_debug "msb cmd[install] DONE: $*"
  msb exec "$_name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" </dev/null >/dev/null 2>&1 || true
}

# _acq_msb_exec_run NAME PHASE USER BACKGROUND UFLAG_ARRVAR EFLAG_ARRVAR -- ARGV...
# — run an initFiles/startup command every apply (they are written idempotent).
# A startup command marked background (ADR-0014) is DETACHED under nohup inside a
# single `msb exec` so a never-exiting supervisor loop does not block provision;
# the argv is passed as positional params to an inner `sh -c '… "$@"'` so no
# token is re-split or re-quoted (the same safety the direct-argv path has).
_acq_msb_exec_run() {
  local _name="$1" _phase="$2" _user="$3" _background="$4" _uflagn="$5" _eflagn="$6"
  shift 6
  [ "$1" = "--" ] && shift
  # Distinct internal names (_uf/_ef): see _acq_msb_exec_install.
  local _uf=() _ef=()
  eval "_uf=(\${${_uflagn}[@]+\"\${${_uflagn}[@]}\"})"
  eval "_ef=(\${${_eflagn}[@]+\"\${${_eflagn}[@]}\"})"

  if [ "$_phase" = "startup" ] && [ "$_background" = "true" ]; then
    acq_debug "msb cmd[startup:background] DETACH (user=${_user:-0}): $*"
    msb exec "$_name" "${_uf[@]}" ${_ef[@]+"${_ef[@]}"} \
      -- sh -c 'nohup "$@" >/dev/null 2>&1 & exit 0' sh "$@" </dev/null || {
      acq_debug "msb cmd[startup:background] FAILED to launch: $*"
      echo "acq(msb): warning: background startup command failed to launch for '$_name'" >&2
    }
    acq_debug "msb cmd[startup:background] LAUNCHED: $*"
  else
    acq_debug "msb cmd[${_phase}] START (user=${_user:-0}): $*"
    msb exec "$_name" "${_uf[@]}" ${_ef[@]+"${_ef[@]}"} -- "$@" </dev/null || {
      acq_debug "msb cmd[${_phase}] FAILED: $*"
      echo "acq(msb): warning: ${_phase} command failed for '$_name'" >&2
    }
    acq_debug "msb cmd[${_phase}] DONE: $*"
  fi
}

_acq_msb_exec_command() {
  local name="$1" phase="$2" user="$3" background="$4"
  shift 4

  # Split leading NAME=value env tokens (up to the `--` sentinel) from argv.
  local _kit_env=() _argv=()
  _acq_msb_split_env_argv _kit_env _argv "$@"

  [ "${#_argv[@]}" -gt 0 ] || return 0

  # Build the `msb exec` -u/-e flag arrays (uid mapping, kit env, git guards).
  local uflag=() eflag=()
  _acq_msb_exec_flags_into uflag eflag "$user" _kit_env

  if [ "$phase" = "install" ]; then
    _acq_msb_exec_install "$name" "$user" uflag eflag -- "${_argv[@]}"
  else
    _acq_msb_exec_run "$name" "$phase" "$user" "$background" uflag eflag -- "${_argv[@]}"
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_provision — create a sandbox and apply the kits
# ---------------------------------------------------------------------------
# msb create takes an IMAGE + flags. acq derives the sandbox name at the acq
# layer and passes it here; the caller's create-arg list (agent, paths, mounts)
# is translated to msb's --volume mounts. Network allow-lists and the zscaler
# --trust-host-cas shortcut are collected across all kits and applied at create.

acq_backend_provision() {
  local name="$1"
  shift

  # The AGENT token is the FIRST positional (e.g. `opencode`); the workspace path
  # follows. Unlike sbx (whose template bakes the agent in), msb must install the
  # agent itself after create — capture the token now so we know what to install
  # and, later, what to launch on attach. Defaults to `shell` (no agent binary).
  local agent
  agent=$(first_positional "$@")
  [ -n "$agent" ] || agent="shell"

  # Collect create-time flags: net rules (union of all kit caps), --trust-host-cas
  # (if any kit declares the msb zscaler shortcut), volume mounts (from paths),
  # and the USAi secret binding.
  local create_flags=()
  local trust_host_cas=0
  local kitdirs=()

  # Fetch each built-in kit and gather its create-time contributions.
  local kitref kitdir
  local kits=("$USAI_KIT" "$PLAYBOOK_KIT" "$ZSCALER_KIT" "$GITSSHSIGN_KIT")
  # Include any extra kits (env-supplied) and CLI-supplied --kit refs.
  if [ -n "${ACQ_EXTRA_KITS:-}" ]; then
    local _extras=()
    split_noglob _extras "$ACQ_EXTRA_KITS"
    kits+=("${_extras[@]}")
  fi
  if [ "${#ACQ_CLI_KITS[@]}" -gt 0 ]; then
    kits+=("${ACQ_CLI_KITS[@]}")
  fi

  for kitref in "${kits[@]}"; do
    kitdir=$(_acq_msb_fetch_kit "$kitref") || {
      echo "acq(msb): error: could not fetch kit: $kitref" >&2
      exit 1
    }
    kitdirs+=("$kitdir")
    local spec="${kitdir}/spec.yaml"
    [ -f "$spec" ] || continue

    # zscaler shortcut → --trust-host-cas at create.
    if kit_spec_has_shortcut "$spec" msb; then
      if [ "$(kit_spec_shortcut_val "$spec" msb trust_host_cas)" = "true" ]; then
        trust_host_cas=1
      fi
    fi

    # Network allow-list → --net-rule flags.
    local nr=()
    _acq_msb_net_rules_into nr "$spec"
    [ "${#nr[@]}" -gt 0 ] && create_flags+=("${nr[@]}")

    # Published ports (ADR-0014, gap A) → create-time `-p HOST:GUEST` flags. The
    # neutral top-level `publishedPorts` is read first by kit_spec_published_ports
    # (with a deprecated backend_extras.sbx fallback). Each surviving record is
    # `guest<TAB>proto<TAB>name<TAB>host` (validated to ints 1..65535). msb -p also
    # accepts BIND_ADDR:HOST:GUEST and /udp, but the neutral schema stays TCP +
    # default loopback bind for sbx parity, so we emit a plain `-p HOST:GUEST`
    # (no bind-addr, no /udp — out of parity scope). Absence is a silent no-op.
    local pp=()
    _acq_msb_port_flags_into pp "$spec"
    [ "${#pp[@]}" -gt 0 ] && create_flags+=("${pp[@]}")
  done

  [ "$trust_host_cas" -eq 1 ] && create_flags+=(--trust-host-cas)

  # Allow-list the agent installer's registry host(s) so the (default-deny) guest
  # egress permits the npm download. Only when we will actually install an agent
  # (a known recipe exists); `shell` and unknown agents add no rule.
  if _acq_msb_agent_has_install_recipe "$agent"; then
    local _npm_host
    for _npm_host in $ACQ_MSB_NPM_HOSTS; do
      case "$_npm_host" in
        ""|*[!A-Za-z0-9.*_-]*)
          echo "acq(msb): warning: skipping non-hostname npm host: $_npm_host" >&2
          continue
          ;;
      esac
      create_flags+=(--net-rule "allow@${_npm_host}")
    done
  fi

  # TLS interception is REQUIRED for secret substitution: msb only swaps a
  # placeholder for the real value on a connection it can see into (the security
  # docs: "a secret requires intercepted TLS"). Without --tls-intercept the USAi
  # placeholder would be sent literally and rejected. The interception CA is
  # auto-trusted in the guest, so no extra CA install is needed (verified: plain
  # HTTPS to an intercepted host returns 200). Toggle off only if a deployment
  # cannot use interception (secrets then won't substitute).
  if [ -z "${ACQ_MSB_NO_TLS_INTERCEPT:-}" ]; then
    create_flags+=(--tls-intercept)
  fi

  # Guest DNS: use a resolver reachable from the microVM. The host's resolvers
  # (often a corporate/VPN/Zscaler IP) are typically unreachable from the guest,
  # so without this the guest can't resolve even allow-listed hosts. See the
  # ACQ_MSB_DNS_NAMESERVER note above.
  if [ -n "$ACQ_MSB_DNS_NAMESERVER" ]; then
    create_flags+=(--dns-nameserver "$ACQ_MSB_DNS_NAMESERVER")
  fi

  # Guest RAM / vCPU. msb defaults to 512 MiB / 1 vCPU — too small for a Node.js
  # agent TUI (opencode), which the guest OOM-kills on launch (prints "Killed";
  # the microVM has no swap). Pass a generous default (tunable via ACQ_MSB_MEMORY
  # / ACQ_MSB_CPUS; empty = omit and use msb's own default). The memory value is
  # validated to msb's SIZE grammar (digits with optional single-char G/M/g/m
  # suffix) so a stray value can't smuggle another flag; cpus must be a positive
  # integer.
  if [ -n "$ACQ_MSB_MEMORY" ]; then
    case "$ACQ_MSB_MEMORY" in
      *[!0-9GMgm.]*|"")
        echo "acq(msb): warning: ignoring invalid ACQ_MSB_MEMORY='$ACQ_MSB_MEMORY'" \
             "(expected e.g. 4G, 4096, 512M)." >&2
        ;;
      *)
        create_flags+=(--memory "$ACQ_MSB_MEMORY")
        ;;
    esac
  fi
  if [ -n "$ACQ_MSB_CPUS" ]; then
    case "$ACQ_MSB_CPUS" in
      *[!0-9]*|0|"")
        echo "acq(msb): warning: ignoring invalid ACQ_MSB_CPUS='$ACQ_MSB_CPUS'" \
             "(expected a positive integer)." >&2
        ;;
      *)
        create_flags+=(--cpus "$ACQ_MSB_CPUS")
        ;;
    esac
  fi

  # Translate the caller's workspace path(s) into --volume mounts.
  #
  # CONTRACT (matches sbx semantics — see docs/QUICKSTART_SBX.md "Multiple
  # Workspaces"): every workspace positional after the agent is mounted at its
  # SAME absolute path inside the guest ("All workspaces appear inside the
  # sandbox at their absolute host paths."). A trailing `:ro` marks that mount
  # read-only. `acq run opencode ~/app ~/lib:ro` therefore mounts ~/app rw and
  # ~/lib ro, each at its own host path.
  #
  # STARTING DIRECTORY (ACQ_MSB_GUEST_WORKSPACE, consumed by attach): the FIRST
  # workspace positional is the "primary" — the agent starts there — regardless
  # of how many mounts are given (docs/QUICKSTART_SBX.md: "Primary workspace —
  # The first path; agent starts here."). ACQ_MSB_WORKSPACE overrides it.
  #
  # Why mount at the host path (not remapped under /home/agent): `msb create`
  # performs the mount at create time, BEFORE acq can create the `agent` user and
  # /home/agent (that happens post-create, once the guest is exec-ready). A plain
  # base (node:22-bookworm) has no /home/agent, so mounting into it failed with
  # "mount ...: Not a directory (os error 20)". Mounting at the host's own
  # absolute path sidesteps the ordering problem and matches sbx. NOTE: msb also
  # cannot mount a SYMLINKED host path (e.g. macOS $TMPDIR under /var ->
  # /private/var); each path is canonicalized below before the mount.
  local _ws_recs=() wline
  while IFS= read -r wline; do
    [ -n "$wline" ] && _ws_recs+=("$wline")
  done <<EOF
$(workspace_paths "$@")
EOF

  ACQ_MSB_GUEST_WORKSPACE=""
  local _wi _wspec _wpath _wro _first_guest=""
  for _wi in ${_ws_recs[@]+"${!_ws_recs[@]}"}; do
    _wspec="${_ws_recs[$_wi]}"
    # Split an optional trailing ":ro" (read-only) marker from the path.
    _wro=""
    case "$_wspec" in
      *:ro) _wpath="${_wspec%:ro}"; _wro=":ro" ;;
      *)    _wpath="$_wspec" ;;
    esac
    if [ ! -d "$_wpath" ]; then
      echo "acq(msb): error: workspace path does not exist on the host: $_wpath" >&2
      echo "acq(msb):   msb cannot mount a nonexistent host path. Create it first." >&2
      return 1
    fi
    # Canonicalize to the real, symlink-free path before mounting. msb cannot
    # mount a symlinked host path (verified on 0.6.6: a macOS $TMPDIR path under
    # the /var -> /private/var symlink fails to start with
    # "mount ...: Not a directory (os error 20)", even mapped to a shallow guest
    # target). Resolving to /private/var/... lets the mount succeed. Falls back
    # to the original path if it cannot be resolved.
    if command -v canonicalize_path >/dev/null 2>&1; then
      _wpath=$(canonicalize_path "$_wpath")
    fi
    # Mount at the same absolute path in the guest (sbx-parity), preserving :ro.
    create_flags+=(--volume "${_wpath}:${_wpath}${_wro}")
    acq_debug "msb volume: ${_wpath} -> ${_wpath}${_wro}"
    [ -z "$_first_guest" ] && _first_guest="$_wpath"
  done

  # Decide the agent's starting directory (recorded for attach). Explicit
  # override wins; otherwise the FIRST (primary) workspace, matching sbx.
  if [ -n "${ACQ_MSB_WORKSPACE:-}" ]; then
    ACQ_MSB_GUEST_WORKSPACE="$ACQ_MSB_WORKSPACE"
  elif [ -n "$_first_guest" ]; then
    ACQ_MSB_GUEST_WORKSPACE="$_first_guest"
  fi

  # Credentials: read from the acq-owned secret store (keychain/file), scoped to
  # this sandbox first, then global. The real value is read into a TRANSIENT env
  # var (never argv, never the kit spec) and bound with `msb --secret ENV@HOST`,
  # which puts a PLACEHOLDER ($MSB_<env>) in the guest and swaps in the real value
  # on the wire to the allowed host (requires --tls-intercept, set above). The
  # real value never enters the guest.
  #
  # SCOPE (verified against msb 0.6.7):
  #   - USAi: bind USAI_API_KEY@api.gsa.usai.gov ONLY. The USAi provider sends the
  #     key as an `Authorization: Bearer` header, which msb substitutes correctly.
  #   - GitHub: bind GITHUB_TOKEN@api.github.com ONLY. msb substitutes the token on
  #     the wire to the REST API (verified: an authenticated GET to
  #     api.github.com returns 5000-rate-limit headers; a private-repo tarball
  #     fetch succeeds). msb does NOT substitute git's smart-HTTP transport to
  #     github.com/codeload (a `git clone`/`gh repo clone` of a private repo fails
  #     auth/TLS there) — this is quickstart#203. So kits authenticate via the REST
  #     API, not git: the playbook kit fetches a source tarball from
  #     api.github.com. Binding a single host also avoids microsandbox #1170
  #     (multi-host binding: ineligible entry blocks eligible).
  local _secret_env_names=()   # env vars we set transiently, cleared after create
  if command -v acq_secret_resolve >/dev/null 2>&1; then
    local usai_val
    if usai_val=$(acq_secret_resolve usai "$name" 2>/dev/null) && [ -n "$usai_val" ]; then
      export USAI_API_KEY="$usai_val"; usai_val=""
      _secret_env_names+=("USAI_API_KEY")
      create_flags+=(--secret "USAI_API_KEY@${ACQ_MSB_USAI_HOST}")
      acq_debug "msb secret: binding USAI_API_KEY@${ACQ_MSB_USAI_HOST} (from acq store)"
    elif [ -n "${USAI_API_KEY:-}" ]; then
      # Fallback: a pre-exported USAI_API_KEY (e.g. CI) still works.
      create_flags+=(--secret "USAI_API_KEY@${ACQ_MSB_USAI_HOST}")
      acq_debug "msb secret: binding USAI_API_KEY@${ACQ_MSB_USAI_HOST} (from env)"
    fi

    # GitHub: bind GITHUB_TOKEN@api.github.com so kits can authenticate to the
    # REST API (the substituted path). Resolve from the acq store first, then a
    # pre-exported GITHUB_TOKEN/GH_TOKEN (CI). Absent token => no binding; the
    # playbook kit then degrades gracefully (warns, no rules/skills).
    local gh_val
    if gh_val=$(acq_secret_resolve github "$name" 2>/dev/null) && [ -n "$gh_val" ]; then
      export GITHUB_TOKEN="$gh_val"; gh_val=""
      _secret_env_names+=("GITHUB_TOKEN")
      create_flags+=(--secret "GITHUB_TOKEN@${ACQ_MSB_GITHUB_HOST}")
      acq_debug "msb secret: binding GITHUB_TOKEN@${ACQ_MSB_GITHUB_HOST} (from acq store)"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
      create_flags+=(--secret "GITHUB_TOKEN@${ACQ_MSB_GITHUB_HOST}")
      acq_debug "msb secret: binding GITHUB_TOKEN@${ACQ_MSB_GITHUB_HOST} (from env)"
    elif [ -n "${GH_TOKEN:-}" ]; then
      export GITHUB_TOKEN="$GH_TOKEN"
      _secret_env_names+=("GITHUB_TOKEN")
      create_flags+=(--secret "GITHUB_TOKEN@${ACQ_MSB_GITHUB_HOST}")
      acq_debug "msb secret: binding GITHUB_TOKEN@${ACQ_MSB_GITHUB_HOST} (from GH_TOKEN env)"
    fi

    # GENERIC custom endpoints (quickstart#226, gap C). usai + github were bound
    # explicitly above (unchanged). Any OTHER service stored via `acq secret set
    # SVC --host H --env E` recorded a non-secret (host, env) sidecar; bind each
    # such service generically here so it is no longer stored-but-inert. Iterate
    # the endpoint sidecars for this sandbox scope + global, deduping by env var
    # (a scoped mapping shadows the global; usai/github are skipped — already
    # bound). The real value moves via a TRANSIENT env var (never argv), exactly
    # like usai/github, and msb reads it from that host env var at create.
    if command -v acq_secret_meta_list >/dev/null 2>&1; then
      local _svc _binding _env _host _val
      while IFS= read -r _svc; do
        [ -n "$_svc" ] || continue
        case "$_svc" in usai|github) continue ;; esac  # bound explicitly above
        _binding=$(_acq_msb_service_binding "$_svc" "$name")
        _env=$(printf '%s' "$_binding" | cut -f1)
        _host=$(printf '%s' "$_binding" | cut -f2)
        [ -n "$_env" ] && [ -n "$_host" ] || continue
        # Skip if this env var was already bound (e.g. usai/github, or a dup).
        case " ${_secret_env_names[*]-} " in *" $_env "*) continue ;; esac
        if _val=$(acq_secret_resolve "$_svc" "$name" 2>/dev/null) && [ -n "$_val" ]; then
          # shellcheck disable=SC2163  # dynamic export of the resolved binding env var
          export "$_env=$_val"; _val=""
          _secret_env_names+=("$_env")
          create_flags+=(--secret "${_env}@${_host}")
          acq_debug "msb secret: binding ${_env}@${_host} for custom service '$_svc' (from acq store)"
        fi
      done <<EOF
$(acq_secret_meta_list "$name")
EOF
    fi
  elif [ -n "${USAI_API_KEY:-}" ]; then
    create_flags+=(--secret "USAI_API_KEY@${ACQ_MSB_USAI_HOST}")
  fi

  # Create the sandbox (detached; msb create boots in the background).
  # NOTE: acq runs under `set -euo pipefail`, so capture the status with
  # `|| _create_rc=$?` — a bare `msb create; local rc=$?` would abort the
  # function on failure BEFORE the error block and the transient-secret scrub
  # below ever run.
  acq_debug "msb create --name $name ${create_flags[*]} $ACQ_MSB_IMAGE"
  local _create_rc=0
  acq_debug "msb create: invoking (this returns fast; guest boots in background)"
  msb create --name "$name" "${create_flags[@]}" "$ACQ_MSB_IMAGE" || _create_rc=$?
  acq_debug "msb create: returned rc=${_create_rc}"
  # Clear the transient secret env vars immediately after create reads them
  # (runs on both success and failure so the exported key never lingers).
  local _ev
  for _ev in ${_secret_env_names[@]+"${_secret_env_names[@]}"}; do
    unset "$_ev"
  done
  if [ "$_create_rc" -ne 0 ]; then
    echo "acq(msb): error: 'msb create' failed for '$name'." >&2
    echo "acq(msb):   flags: ${create_flags[*]}" >&2
    echo "acq(msb):   image: $ACQ_MSB_IMAGE" >&2
    case "$ACQ_MSB_IMAGE" in
      ghcr.io/*|*.azurecr.io/*|*private*)
        echo "acq(msb):   hint: the image may require registry auth. Set ACQ_MSB_IMAGE to a" >&2
        echo "acq(msb):         pullable image (default: docker.io/library/node:22-bookworm)." >&2
        ;;
    esac
    echo "acq(msb):   (re-run with ACQ_DEBUG=1 for the full command trace)" >&2
    return 1
  fi

  # CRITICAL: `msb create` returns 0 even when the sandbox later FAILS TO START
  # (e.g. a bad mount): the boot is asynchronous. So a zero rc from create does
  # NOT mean the sandbox is usable. The ONLY reliable readiness signal is that
  # `msb exec` works. Treat a non-ready sandbox as a HARD provision failure —
  # otherwise kit application (and every downstream check) runs against a
  # sandbox that isn't really up, which looks like success but silently isn't.
  acq_debug "msb provision: waiting for exec-ready ($name)"
  if ! _acq_msb_wait_for_exec_ready "$name"; then
    echo "acq(msb): error: sandbox '$name' did not become exec-ready within" >&2
    echo "acq(msb):   ${ACQ_MSB_EXEC_READY_TIMEOUT}s. 'msb create' returns 0 even when the" >&2
    echo "acq(msb):   guest fails to START (async boot) — a bad mount, image, or host" >&2
    echo "acq(msb):   virtualization issue. Diagnose with:" >&2
    echo "acq(msb):     msb logs --source system $name" >&2
    echo "acq(msb):     msb list          # is it running?" >&2
    echo "acq(msb):   (re-run with ACQ_DEBUG=1 for the create command trace.)" >&2
    # Leave the sandbox in place for inspection; caller decides whether to rm.
    return 1
  fi
  acq_debug "msb provision: exec-ready OK ($name)"

  # Verify the kits' runtime prerequisites are present in the base image
  # (node/git/curl/update-ca-certificates). We do NOT install them: the kit
  # net-rules lock egress to the kits' own hosts, so a package mirror is
  # unreachable during provision. Missing tools => a clear, actionable warning.
  acq_debug "msb provision: checking prereqs ($name)"
  _acq_msb_check_prereqs "$name"
  acq_debug "msb provision: prereqs checked ($name)"

  # Ensure the `agent` user with HOME=/home/agent exists AND that /home/agent is
  # writable by it. The pinned kits stage files under /home/agent and run startup
  # commands as that user (the sbx agent template guarantees this user). A plain
  # OCI base (e.g. node:22-bookworm) has no `agent` user — and uid 1000 is already
  # taken there — so acq creates `agent` (any uid) and chowns its home. A failure
  # here is FATAL: a root-owned /home/agent silently breaks every agent-user kit
  # (playbook fetch, usai merge), which is exactly how the playbook stopped
  # fetching. Abort provision rather than degrade silently.
  acq_debug "msb provision: ensuring agent user ($name)"
  if ! _acq_msb_ensure_agent_user "$name"; then
    echo "acq(msb): error: agent-user setup failed for '$name'; aborting provision." >&2
    return 1
  fi
  acq_debug "msb provision: agent user ready ($name)"

  # Install the requested agent binary (sbx bakes it into the template image; on
  # a plain msb base acq must install it). Idempotent + marker-gated; a no-op for
  # `shell`, a clear warning for an agent with no known recipe.
  acq_debug "msb provision: installing agent '$agent' ($name)"
  _acq_msb_install_agent "$name" "$agent"
  acq_debug "msb provision: agent install step done ($name)"

  # Record which agent this sandbox runs, so acq_backend_attach (which only gets
  # the sandbox name) knows what to launch — the sbx equivalent is that
  # `sbx run --name` re-launches the agent baked in at create. Written as root to
  # a fixed guest path; validated charset (KNOWN_AGENTS tokens are word-safe).
  case "$agent" in
    *[!a-z-]*) : ;;  # defensive: never write an odd token
    *) msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && printf '%s' '$agent' > /var/lib/acq/agent" >/dev/null 2>&1 || true ;;
  esac

  # Record the guest workspace path too. attach only gets the sandbox NAME, so it
  # cannot recompute the host→guest mapping (which now mirrors the host path);
  # persist it so a name-only re-attach cds into the right place. The path was
  # validated as an existing host dir above; guard the charset before it enters a
  # root sh -c string.
  if [ -n "$ACQ_MSB_GUEST_WORKSPACE" ]; then
    case "$ACQ_MSB_GUEST_WORKSPACE" in
      *[!A-Za-z0-9._/-]*)
        acq_debug "msb: not recording unsafe guest workspace path: $ACQ_MSB_GUEST_WORKSPACE" ;;
      *)
        msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && printf '%s' '$ACQ_MSB_GUEST_WORKSPACE' > /var/lib/acq/workspace" >/dev/null 2>&1 || true ;;
    esac
  fi

  # Apply each kit's files + commands. Best-effort per kit: a single kit that
  # fails to fully apply (e.g. a transient `msb copy` verify failure) must NOT
  # abort provision under `set -e` and leave an already-created, agent-installed
  # sandbox half-configured with no diagnostic. Warn and continue — the kits are
  # individually non-fatal (the playbook kit already self-heals on next start),
  # matching acq_backend_ensure_kits_applied's best-effort heal loop.
  local kd
  for kd in "${kitdirs[@]}"; do
    acq_debug "msb provision: applying kit dir $kd ($name)"
    if _acq_msb_apply_kit_dir "$name" "$kd"; then
      acq_debug "msb provision: applied kit dir $kd ($name)"
    else
      echo "acq(msb): warning: kit did not fully apply: $kd" >&2
      echo "acq(msb):   the sandbox is up; re-run 'acq run' to re-apply, or inspect with ACQ_DEBUG=1." >&2
    fi
  done
  acq_debug "msb provision: all kits applied; provision complete ($name)"
}

# ---------------------------------------------------------------------------
# _acq_msb_agent_has_install_recipe AGENT — 0 if acq knows how to install AGENT
# ---------------------------------------------------------------------------
# `shell` needs no binary; today only `opencode` has a recipe. Others are baked
# into ACQ_MSB_IMAGE by the user (warned at install time). Keep this in sync with
# _acq_msb_install_agent's case.
_acq_msb_agent_has_install_recipe() {
  case "$1" in
    opencode) return 0 ;;
    *) return 1 ;;
  esac
}

# _acq_msb_safe_agent_token AGENT -> 0 if AGENT is a safe agent token to
# interpolate into a shell command. Agent tokens are short lowercase names
# (opencode, claude, shell, …); restrict to [a-z-] so a value can never break
# out of the `sh -c "command -v '$agent'"` single-quoting (defense against a
# `acq create "x';…'"` arg or a tampered /var/lib/acq/agent marker). Callers
# that build an `sh -c` string with $agent MUST gate on this first.
_acq_msb_safe_agent_token() {
  case "$1" in
    ""|*[!a-z-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# _acq_msb_install_agent NAME AGENT — install the agent binary into the guest
# ---------------------------------------------------------------------------
# sbx's agent templates ship the binary; msb runs a plain base, so acq installs
# it. For `opencode`, install the npm package globally as root (node is a
# verified base prerequisite; the registry host was allow-listed at create).
# Idempotent: skip if the binary is already present (a pre-baked ACQ_MSB_IMAGE),
# and marker-gate so a re-apply doesn't reinstall. `shell` is a no-op; an unknown
# agent is a non-fatal warning (the sandbox still comes up; the user can bake the
# binary into ACQ_MSB_IMAGE).
_acq_msb_install_agent() {
  local name="$1" agent="$2"

  case "$agent" in
    shell|"") acq_debug "msb: agent '$agent' needs no binary install"; return 0 ;;
  esac

  # Charset-guard the agent token before it enters any `sh -c "… '$agent' …"`.
  # `acq create <agent> <path>` does not go through is_known_agent, so a hostile
  # token (e.g. "x';touch /tmp/pwn;'") could otherwise break the single-quoting
  # and run as root. Refuse anything outside [a-z-].
  if ! _acq_msb_safe_agent_token "$agent"; then
    echo "acq(msb): refusing agent name with unexpected characters: '$agent'" >&2
    return 0
  fi

  if ! _acq_msb_agent_has_install_recipe "$agent"; then
    # Maybe the base image already provides it — don't warn if so.
    if msb exec "$name" -u 0 -- sh -c "command -v '$agent'" >/dev/null 2>&1; then
      acq_debug "msb: agent '$agent' already present in base image"
      return 0
    fi
    echo "acq(msb): warning: no install recipe for agent '$agent' and it is not in the" >&2
    echo "acq(msb):   base image. Attach will fail to launch it. Bake '$agent' into" >&2
    echo "acq(msb):   ACQ_MSB_IMAGE, or use an agent acq can install (e.g. opencode)." >&2
    return 0
  fi

  # Already installed (pre-baked image or a prior apply)? Then done.
  if msb exec "$name" -u 0 -- sh -c "command -v '$agent'" >/dev/null 2>&1; then
    acq_debug "msb: agent '$agent' already installed in $name"
    return 0
  fi

  local marker="/var/lib/acq/agent-installed-${agent}"
  if msb exec "$name" -u 0 -- sh -c "test -f '$marker'" >/dev/null 2>&1; then
    return 0
  fi

  case "$agent" in
    opencode)
      acq_debug "msb: installing opencode ($ACQ_MSB_OPENCODE_PKG) via npm in $name"
      # Install globally as root so the binary lands on the system PATH for every
      # user (the agent runs as `agent`). The package spec is passed as a single
      # argv element (never re-split by a shell); ACQ_MSB_OPENCODE_PKG is a
      # controlled tunable. `npm` is present (node prerequisite). npm needs the
      # registry host, allow-listed at create.
      if ! msb exec "$name" -u 0 -- npm install -g --no-fund --no-audit "$ACQ_MSB_OPENCODE_PKG" >/dev/null 2>&1; then
        echo "acq(msb): warning: 'npm install -g $ACQ_MSB_OPENCODE_PKG' failed in '$name'." >&2
        echo "acq(msb):   opencode will not be available on attach. Common causes: the npm" >&2
        echo "acq(msb):   registry host (${ACQ_MSB_NPM_HOSTS}) is not reachable/allow-listed," >&2
        echo "acq(msb):   or npm is missing. Set ACQ_MSB_NPM_HOSTS for an internal mirror," >&2
        echo "acq(msb):   or bake opencode into ACQ_MSB_IMAGE." >&2
        return 0
      fi
      ;;
  esac

  # Verify the binary is now on PATH before recording the marker.
  if msb exec "$name" -u 0 -- sh -c "command -v '$agent'" >/dev/null 2>&1; then
    msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" >/dev/null 2>&1 || true
    acq_debug "msb: agent '$agent' installed and on PATH in $name"
  else
    echo "acq(msb): warning: installed '$agent' but it is not on PATH in '$name'." >&2
  fi
}

# ---------------------------------------------------------------------------
# _acq_msb_ensure_agent_user NAME — satisfy the sbx/Docker base-image contract
# ---------------------------------------------------------------------------
# sbx's agent templates are built on `docker/sandbox-templates:shell-docker`,
# whose PUBLISHED base-image requirements are (Docker kit-reference,
# "Base image requirements"):
#   - a non-root `agent` user at UID 1000 with PASSWORDLESS SUDO
#   - a /home/agent home directory owned by `agent`
#   - HTTP proxy env (HTTP_PROXY/HTTPS_PROXY/NO_PROXY) PRESERVED ACROSS SUDO
#   - the agent binary (baked in, or installed via commands.install)
# A plain OCI base (e.g. node:22-bookworm, which ships `node` at uid 1000 and no
# `agent`, and no sudoers rule) meets NONE of the first three. The msb adapter
# therefore synthesizes them here so both the kits (which run as `-u 1000`) and
# the agent behave as they do on sbx. Idempotent + marker-gated; runs fully
# offline (useradd/adduser/sudoers edits need no network). The uid defaults to
# 1000; if 1000 is taken (e.g. by `node`), `agent` is created at the next free
# uid and the kits' `-u 1000` commands still map to it by NAME (see
# _acq_msb_exec_command) with HOME exported.
_acq_msb_ensure_agent_user() {
  local name="$1"
  local marker="/var/lib/acq/agent-user-ready"
  if msb exec "$name" -u 0 -- sh -c "test -f '$marker'" >/dev/null 2>&1; then
    return 0
  fi

  acq_debug "msb: ensuring agent user + /home/agent + passwordless sudo + proxy-preserve in $name"
  # Idempotent, distro-agnostic. If an `agent` user already exists, reuse it.
  # Otherwise create it. NOTE: we do NOT pin uid 1000 — on common bases
  # (node:22-bookworm) uid 1000 is already taken by a pre-existing user (`node`),
  # so requesting -u 1000 fails and, worse, can leave /home/agent half-created or
  # root-owned. The kits address the agent BY NAME (our exec translation maps
  # user 1000/agent → `-u agent`), so the uid is irrelevant. What MUST hold is
  # that /home/agent exists and is OWNED BY agent — otherwise every kit command
  # that runs as the agent user (playbook fetch, usai merge) fails with
  # Permission denied. So home creation + ownership is deterministic and its
  # failure is FATAL (previously it was best-effort `|| true`, which silently
  # degraded into a root-owned home and a playbook that never fetched).
  msb exec "$name" -u 0 -- sh -c '
    set -e
    if id agent >/dev/null 2>&1; then
      :
    elif command -v useradd >/dev/null 2>&1; then
      # Debian/Ubuntu/RHEL. Do NOT request a fixed uid (1000 may be taken); let
      # the tool pick a free uid. -M: do not auto-create home here; we create and
      # chown it explicitly below so ownership is unconditional.
      useradd -M -d /home/agent -s /bin/sh agent
    elif command -v adduser >/dev/null 2>&1; then
      # Alpine/BusyBox.
      adduser -h /home/agent -s /bin/sh -D -H agent
    else
      echo "acq(msb): no useradd/adduser in base image; cannot create agent user" >&2
      exit 1
    fi
    # Home MUST exist and be owned by agent. Not best-effort: a root-owned home
    # breaks every agent-user kit. `id -gn agent` resolves the primary group so
    # chown works whether or not an `agent` group exists.
    mkdir -p /home/agent
    _agrp=$(id -gn agent 2>/dev/null || echo agent)
    chown "agent:${_agrp}" /home/agent
    chown -R "agent:${_agrp}" /home/agent
    # Verify writability as the agent user (catches an exotic base where chown
    # "succeeds" but the mount is read-only, etc.). Fatal on failure.
    su agent -s /bin/sh -c "test -w /home/agent" 2>/dev/null \
      || { echo "acq(msb): /home/agent is not writable by the agent user" >&2; exit 1; }

    # Set SHELL=/bin/sh in the agent profile. The passwd shell is /bin/sh, but
    # SHELL is not populated by `msb exec`/`su -c`, and msb interactive-exec
    # ignores the passwd shell entirely (it drops to the base image default, a
    # Node REPL on node:22-bookworm). acq always execs an explicit shell/agent, so
    # this is cosmetic (tools that read SHELL) but correct and cheap. Idempotent.
    # NOTE: this whole block is a single-quoted `sh -c` string — do NOT use single
    # quotes here (they would close the outer quote). `echo` avoids both quotes
    # and printf %-escaping.
    if ! grep -qs "^export SHELL=" /home/agent/.profile 2>/dev/null; then
      echo export SHELL=/bin/sh >> /home/agent/.profile
      chown "agent:${_agrp}" /home/agent/.profile
    fi

    # Passwordless sudo for agent (base-image requirement). Only if sudo exists;
    # a base without sudo still works for our purposes (kit/agent commands that
    # need root are run by acq as -u 0 directly), so a missing sudo is non-fatal.
    if command -v sudo >/dev/null 2>&1; then
      mkdir -p /etc/sudoers.d
      printf "agent ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/90-acq-agent
      chmod 0440 /etc/sudoers.d/90-acq-agent
      # Preserve HTTP proxy env across sudo (base-image requirement). msb sets
      # HTTP_PROXY/HTTPS_PROXY/NO_PROXY for the TLS-intercepting proxy; without
      # env_keep they are stripped on sudo, breaking egress from elevated cmds.
      printf "Defaults env_keep += \"HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy\"\n" \
        > /etc/sudoers.d/91-acq-proxy-env
      chmod 0440 /etc/sudoers.d/91-acq-proxy-env
    fi
  ' || {
    echo "acq(msb): error: could not establish a writable agent home in '$name'." >&2
    echo "acq(msb):   /home/agent must exist and be owned by the 'agent' user — kit" >&2
    echo "acq(msb):   commands that run as agent (playbook fetch, usai merge) fail" >&2
    echo "acq(msb):   otherwise. Use an ACQ_MSB_IMAGE built on" >&2
    echo "acq(msb):   docker/sandbox-templates:shell-docker (agent user + sudo), or a" >&2
    echo "acq(msb):   base with useradd/adduser. Re-run with ACQ_DEBUG=1 for details." >&2
    return 1
  }
  msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# _acq_msb_check_prereqs NAME — verify kit prerequisites are in the base image
# ---------------------------------------------------------------------------
# The pinned kits assume node/git/curl/update-ca-certificates exist in the guest.
# The default ACQ_MSB_IMAGE (node:22-bookworm) provides all four. If a custom
# ACQ_MSB_IMAGE lacks one, warn clearly rather than fail silently later — we do
# NOT apt-install (egress is locked to kit hosts). Skip with
# ACQ_MSB_SKIP_PREREQ_CHECK=1.
_acq_msb_check_prereqs() {
  local name="$1"
  [ -z "$ACQ_MSB_SKIP_PREREQ_CHECK" ] || return 0

  local missing
  missing=$(msb exec "$name" -- sh -c '
    m=""
    for t in node git curl update-ca-certificates; do
      command -v "$t" >/dev/null 2>&1 || m="$m $t"
    done
    printf "%s" "$m"
  ' 2>/dev/null | tr -d '\r')

  if [ -n "$missing" ]; then
    echo "acq(msb): warning: base image is missing kit prerequisite(s):${missing}." >&2
    echo "acq(msb):   The pinned kits need node, git, curl, update-ca-certificates." >&2
    echo "acq(msb):   The default image (node:22-bookworm) provides them; a custom" >&2
    echo "acq(msb):   ACQ_MSB_IMAGE must too (these are NOT installed at runtime because" >&2
    echo "acq(msb):   kit net-rules lock egress to the kits' hosts). Affected kits may" >&2
    echo "acq(msb):   not fully apply. Set ACQ_MSB_SKIP_PREREQ_CHECK=1 to silence." >&2
  else
    acq_debug "msb prereqs present (node/git/curl/update-ca-certificates) in $name"
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_run — run a command inside a sandbox; return its exit status
# ---------------------------------------------------------------------------
# acq passes `-- CMD...`; msb exec uses the same `-- CMD...` separator.
#
# Run as the unprivileged `agent` user with HOME=/home/agent by default — never
# root. A bare `msb exec NAME -- CMD` runs as root with HOME unset (or /root),
# which broke `$HOME` / `~`-relative probes (e.g. the openchamber verify script's
# `~/.local/bin/opencode` check missed the files staged into /home/agent). This
# aligns `acq exec` with every other msb path: attach uses `-u agent` (see
# _acq_msb_attach) and kit commands map user->`-u agent -e HOME=/home/agent`
# (see _acq_msb_exec_flags_into). Flags precede NAME; the `-- CMD...` passthrough
# in "$@" follows NAME unchanged (matches the attach path's `msb exec … NAME -- CMD`).
acq_backend_run() {
  local name="$1"
  shift
  msb exec -u agent -e HOME=/home/agent "$name" "$@"
}

# ---------------------------------------------------------------------------
# acq_backend_attach — interactive attach (TTY) via `msb exec -t`
# ---------------------------------------------------------------------------
# sbx's `sbx run --name NAME` re-launches the agent baked into the sandbox at
# create. On msb we reproduce that with `msb exec`, which (unlike `msb ssh`)
# gives us everything we need in one non-interactive-safe primitive:
#   -t/--tty     allocate a PTY so a full-screen agent TUI (opencode) renders
#                (msb ssh has NO tty flag and runs -- CMD without a PTY, which
#                hung the TUI; a bare `msb ssh` tries to grab the CLIENT tty and
#                fails on piped stdin);
#   -u agent     run as the unprivileged agent user directly (no `su -` dance,
#                no landing as root);
#   -w WS        start in the workspace;
#   -e SHELL     give the session a sane $SHELL (msb's interactive default is the
#                base image's Node REPL, and the passwd shell isn't exported).
#
# A bare `acq run <sandbox>` re-attach (no agent token) reads the agent recorded
# at provision from /var/lib/acq/agent; `shell` (or a missing/failed agent binary)
# falls back to an interactive `/bin/sh -l` as `agent` — never a root shell, never
# msb's Node-REPL default. Post-`--` args are forwarded to the agent.
acq_backend_attach() {
  local name="$1"
  shift

  # Explicit `-- CMD…` after the sandbox name: run exactly that (advanced/escape
  # hatch), still as the agent user in the workspace with a PTY.
  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
    shift
    _acq_msb_attach "$name" "$@"
    return $?
  fi
  _acq_msb_attach "$name"
}

# _acq_msb_attach NAME [AGENT_ARGS...] — attach as `agent` with a PTY, cd to the
# workspace, and launch the recorded agent (or a shell). AGENT_ARGS are appended
# to the agent invocation.
_acq_msb_attach() {
  local name="$1"
  shift

  # Determine the workspace to cd into (-w). Prefer an explicit ACQ_MSB_WORKSPACE
  # override; otherwise read the guest path recorded at provision (it mirrors the
  # host mount path, so it can't be recomputed from NAME alone). Fall back to the
  # agent home if nothing was recorded (older sandbox).
  local ws="${ACQ_MSB_WORKSPACE:-}"
  if [ -z "$ws" ]; then
    ws=$(msb exec "$name" -u 0 -- sh -c 'cat /var/lib/acq/workspace 2>/dev/null' </dev/null 2>/dev/null | tr -d '\r\n')
  fi
  [ -n "$ws" ] || ws="/home/agent"

  # Read the agent recorded at provision. Default to `shell` if unset. The value
  # comes from a guest file (/var/lib/acq/agent); charset-guard it before it
  # enters the `sh -c "command -v '$agent'"` below, since a tampered marker could
  # otherwise break the single-quoting and run as the agent user. Fall back to a
  # plain shell on anything unexpected.
  local agent
  agent=$(msb exec "$name" -u 0 -- sh -c 'cat /var/lib/acq/agent 2>/dev/null' </dev/null 2>/dev/null | tr -d '[:space:]')
  if [ -z "$agent" ] || ! _acq_msb_safe_agent_token "$agent"; then
    agent="shell"
  fi

  # Common flags for the interactive attach: PTY, agent user, workspace cwd, and
  # a sane $SHELL (msb's default interactive shell is the base image's Node REPL).
  # exec so acq hands the terminal straight to msb (no wrapper between TTY & PTY).
  if [ "$agent" = "shell" ]; then
    exec msb exec -t -u agent -w "$ws" -e SHELL=/bin/sh "$name" -- /bin/sh -l
  fi

  # Pre-check the agent binary AS the agent user; fall back to a shell (with a
  # notice) rather than launching into a broken/blank session if it's missing.
  if ! msb exec -u agent "$name" -- sh -c "command -v '$agent'" </dev/null >/dev/null 2>&1; then
    echo "acq(msb): '$agent' not found in sandbox '$name'; opening a shell instead." >&2
    exec msb exec -t -u agent -w "$ws" -e SHELL=/bin/sh "$name" -- /bin/sh -l
  fi

  exec msb exec -t -u agent -w "$ws" -e SHELL=/bin/sh "$name" -- "$agent" "$@"
}

# ---------------------------------------------------------------------------
# acq_backend_stop / terminate / list / cp / ports
# ---------------------------------------------------------------------------

acq_backend_stop() {
  # Tear down any post-hoc published-port tunnels first (ADR-0015): a stopped
  # sandbox can no longer serve them, and the serve/ssh process pair would
  # otherwise linger. Defensive — no recorded ports is a no-op.
  _acq_msb_ports_teardown "$1"
  msb stop "$1"
}

acq_backend_terminate() {
  # Tear down any post-hoc published-port tunnels (serve + ssh PIDs, state file)
  # before removing the sandbox (ADR-0015). Killing a dead PID / missing state
  # file is a no-op.
  _acq_msb_ports_teardown "$1"
  msb remove --force "$1"
}

acq_backend_list() {
  msb list "$@"
}

acq_backend_cp() {
  msb copy "$1" "$2"
}

acq_backend_ports() {
  local name="$1"
  shift

  # Two modes on msb:
  #   * `acq ports <name>` (NO args)          -> LIST published ports (query).
  #   * `acq ports <name> --publish H:G`       -> post-hoc publish (ADR-0015).
  # Only --publish H:G is supported for the publish action. Parse it out.
  local mapping=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --publish=*) mapping="${1#--publish=}"; shift ;;
      --publish)   mapping="${2:-}"; shift 2 ;;
      *)
        echo "acq(msb): ports: unsupported argument '$1' (only --publish H:G)." >&2
        return 1
        ;;
    esac
  done

  # No --publish -> LIST mode. Surface create-time `-p` NAT mappings (ADR-0014)
  # plus acq's recorded post-hoc ssh -L tunnels (ADR-0015). An empty list is not
  # an error (exit 0); this is a query, matching sbx's `sbx ports <name>`.
  if [ -z "$mapping" ]; then
    _acq_msb_ports_list "$name"
    return 0
  fi

  # SI-10: validate HOST:GUEST (both ints 1..65535) BEFORE either reaches an
  # `ssh -L` argv or a listener bind. Fail closed on anything else.
  local hport gport
  hport="${mapping%%:*}"
  gport="${mapping#*:}"
  if ! _acq_msb_valid_publish "$mapping" "$hport" "$gport"; then
    return 1
  fi

  # 1) Ensure the acq-managed key exists and is authorized (idempotent).
  _acq_msb_ssh_key_ensure || return 1
  _acq_msb_ssh_authorize || return 1

  # 2) Start `msb ssh serve` on an ephemeral loopback port.
  local sport serve_pid
  sport=$(_acq_msb_pick_ephemeral_port)
  _acq_msb_serve_start "$name" "$sport" || return 1
  serve_pid=$!

  # 3) Open the backgrounded `ssh -L` tunnel: host H -> guest (sandbox) G.
  local ssh_pid
  _acq_msb_forward_start "$sport" "$hport" "$gport" || {
    kill "$serve_pid" 2>/dev/null || true
    return 1
  }
  ssh_pid=$!

  # 4) Record the serve+ssh PIDs (and the mapping) so teardown can clean up.
  _acq_msb_ports_record "$name" "$serve_pid" "$ssh_pid" "$sport" "$mapping"

  echo "acq(msb): published host 127.0.0.1:${hport} -> sandbox ${name} 127.0.0.1:${gport}" >&2
  echo "acq(msb):   via 'msb ssh serve' on 127.0.0.1:${sport} + ssh -L (ADR-0015)." >&2
  echo "acq(msb):   tear down with 'acq rm ${name}' (or 'acq stop ${name}')." >&2
}

# _acq_msb_valid_publish MAPPING HPORT GPORT — 0 if H:G is two ints 1..65535.
# SI-10 gate: unvalidated input must never reach `ssh -L` argv or a bind.
_acq_msb_valid_publish() {
  local mapping="$1" h="$2" g="$3" p
  case "$mapping" in
    *:*) ;;
    *) echo "acq(msb): ports: --publish must be HOST:GUEST, got '$mapping'." >&2; return 1 ;;
  esac
  for p in "$h" "$g"; do
    case "$p" in
      ""|*[!0-9]*)
        echo "acq(msb): ports: invalid port '$p' in '$mapping' (want integer 1..65535)." >&2
        return 1
        ;;
    esac
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      echo "acq(msb): ports: port '$p' out of range in '$mapping' (want 1..65535)." >&2
      return 1
    fi
  done
  return 0
}

# _acq_msb_ssh_key_ensure — create the acq-managed ed25519 key on first use.
# 0700 dir, 0600 key, under acq state (NOT the user's ~/.ssh). Idempotent.
_acq_msb_ssh_key_ensure() {
  if [ -f "$ACQ_MSB_SSH_KEY" ]; then
    return 0
  fi
  mkdir -p "$ACQ_MSB_SSH_DIR" || {
    echo "acq(msb): ports: cannot create key dir '$ACQ_MSB_SSH_DIR'." >&2; return 1
  }
  chmod 0700 "$ACQ_MSB_SSH_DIR" 2>/dev/null || true
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "acq(msb): ports: ssh-keygen not found on PATH (needed for the tunnel key)." >&2
    return 1
  fi
  # -N "" = no passphrase (non-interactive). We never print the key material.
  if ! ssh-keygen -t ed25519 -N "" -f "$ACQ_MSB_SSH_KEY" >/dev/null 2>&1; then
    echo "acq(msb): ports: ssh-keygen failed to create the acq tunnel key." >&2
    return 1
  fi
  chmod 0600 "$ACQ_MSB_SSH_KEY" 2>/dev/null || true
  acq_debug "msb ports: generated acq-managed ssh key (${ACQ_MSB_SSH_KEY})"
  return 0
}

# _acq_msb_ssh_authorize — seat the acq public key via `msb ssh authorize` once.
# Authorizing twice is harmless; a marker guards against re-running each publish.
_acq_msb_ssh_authorize() {
  local marker="${ACQ_MSB_SSH_DIR}/.authorized"
  if [ -f "$marker" ]; then
    return 0
  fi
  if ! msb ssh authorize --file "${ACQ_MSB_SSH_KEY}.pub" >/dev/null 2>&1; then
    echo "acq(msb): ports: 'msb ssh authorize' failed for the acq tunnel key." >&2
    return 1
  fi
  : >"$marker" 2>/dev/null || true
  acq_debug "msb ports: authorized acq tunnel public key (once)"
  return 0
}

# _acq_msb_pick_ephemeral_port — echo a loopback port for the serve listener.
#
# Robustness (#234): the previous scheme was `20000 + ($$ % 40000)`, derived
# ONLY from the shell PID. That returned the SAME value for every call in one
# process, so a second `--publish` for the same sandbox collided with the first,
# and rapid test subshells with nearby PIDs raced. The listener binds loopback
# only, so a real collision just fails serve-start — but under the stubbed test
# harness (no real listener) it produced nondeterministic pass/fail.
#
# The port is now DISTINCT per call within a process and stays in a sane high,
# loopback-only range (20000..59999):
#   * a fixed per-process random base (_ACQ_MSB_PORT_BASE, evaluated once at
#     source time from $$/$RANDOM/seconds) spreads processes across the range, and
#   * a file-backed monotonic counter adds a per-call delta. The call site uses
#     command substitution ($(...)), which runs in a subshell, so an in-memory
#     variable would not survive back to the caller — the counter is persisted in
#     _ACQ_MSB_PORT_SEQ_FILE so base+1, base+2, … never collide within a process.
#
# Test seam: if ACQ_MSB_FORCE_SERVE_PORT is set to a valid 1..65535 integer, it
# is echoed verbatim (the counter is still advanced for real callers). scripts/
# test-acq pins this so it can assert the EXACT `msb ssh serve … --port` / `ssh
# -p` argv without racing the base/counter value. Real use leaves it unset and
# gets the distinct-per-call behavior above.
_acq_msb_pick_ephemeral_port() {
  local seq
  # Read-modify-write the persisted counter (subshell-safe, see header). A
  # missing/garbage file resets to 0; failures fall back to 0 (fail-open to a
  # valid port — a same-value collision only re-fails a real serve bind, never
  # corrupts state).
  seq=$(cat "$_ACQ_MSB_PORT_SEQ_FILE" 2>/dev/null)
  case "$seq" in ""|*[!0-9]*) seq=0 ;; esac
  seq=$(( seq + 1 ))
  mkdir -p "$ACQ_MSB_PORTS_DIR" 2>/dev/null || true
  printf '%s\n' "$seq" >"$_ACQ_MSB_PORT_SEQ_FILE" 2>/dev/null || true

  # Deterministic test seam: pin the serve port for exact-shape assertions.
  case "${ACQ_MSB_FORCE_SERVE_PORT:-}" in
    "") ;;
    *[!0-9]*) ;;  # non-integer -> ignore the seam, fall through to selection
    *)
      if [ "$ACQ_MSB_FORCE_SERVE_PORT" -ge 1 ] && [ "$ACQ_MSB_FORCE_SERVE_PORT" -le 65535 ]; then
        echo "$ACQ_MSB_FORCE_SERVE_PORT"
        return 0
      fi
      ;;
  esac

  # base + counter, wrapped into a 40000-wide window at 20000. The counter is the
  # only term that varies between two calls in one process, so consecutive calls
  # are guaranteed distinct until it wraps (40000 calls — far beyond any publish
  # burst). Loopback-only listener, valid 20000..59999 range.
  echo $(( 20000 + ( (_ACQ_MSB_PORT_BASE + seq) % 40000 ) ))
}

# _acq_msb_serve_start NAME SPORT — background `msb ssh serve` on 127.0.0.1:SPORT.
# Leaves the serve PID in $! for the caller to capture.
_acq_msb_serve_start() {
  local name="$1" sport="$2"
  acq_debug "msb ssh serve $name --host 127.0.0.1 --port $sport (backgrounded)"
  msb ssh serve "$name" --host 127.0.0.1 --port "$sport" >/dev/null 2>&1 &
  return 0
}

# _acq_msb_forward_start SPORT HPORT GPORT — background OpenSSH -L local forward.
# Binds host 127.0.0.1:HPORT to the SANDBOX's 127.0.0.1:GPORT (the -L destination
# resolves INSIDE the guest, per ADR-0015). Uses the acq key + a dedicated
# known_hosts under acq state (accept-new against the ephemeral loopback listener).
# Leaves the ssh PID in $!.
_acq_msb_forward_start() {
  local sport="$1" hport="$2" gport="$3"
  if ! command -v ssh >/dev/null 2>&1; then
    echo "acq(msb): ports: ssh not found on PATH (needed for -L forwarding)." >&2
    return 1
  fi
  acq_debug "ssh -p $sport -N -L 127.0.0.1:${hport}:127.0.0.1:${gport} ${ACQ_MSB_SSH_USER}@127.0.0.1"
  ssh -p "$sport" -N \
    -i "$ACQ_MSB_SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=${ACQ_MSB_SSH_KNOWN_HOSTS}" \
    -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:${hport}:127.0.0.1:${gport}" \
    "${ACQ_MSB_SSH_USER}@127.0.0.1" >/dev/null 2>&1 &
  return 0
}

# _acq_msb_ports_pidfile NAME — echo the per-sandbox PID state file path, but ONLY
# for a safe sandbox name. The name interpolates into a filesystem path used by
# `rm -f` (teardown) and `>>` (record); a name with a slash or a leading '..'
# would escape ACQ_MSB_PORTS_DIR. Fail closed (empty output, non-zero) on anything
# outside the sandbox-name charset acq itself produces (slugify -> [a-z0-9-]).
_acq_msb_ports_pidfile() {
  local name="$1"
  case "$name" in
    ""|*[!A-Za-z0-9_-]*|-*)
      echo "acq(msb): ports: refusing unsafe sandbox name '$name' for state path." >&2
      return 1
      ;;
  esac
  printf '%s/%s.pids' "$ACQ_MSB_PORTS_DIR" "$name"
}

# _acq_msb_ports_record NAME SERVE_PID SSH_PID SPORT MAPPING — append a tracking
# record so teardown can find and kill the pair. One line per publish:
#   <serve_pid> <ssh_pid> <sport> <mapping>
_acq_msb_ports_record() {
  local name="$1" serve_pid="$2" ssh_pid="$3" sport="$4" mapping="$5" pidfile
  pidfile=$(_acq_msb_ports_pidfile "$name") || return 0
  mkdir -p "$ACQ_MSB_PORTS_DIR" 2>/dev/null || true
  printf '%s %s %s %s\n' "$serve_pid" "$ssh_pid" "$sport" "$mapping" \
    >>"$pidfile" 2>/dev/null || true
}

# _acq_msb_ports_teardown NAME — kill any recorded serve/ssh PIDs for NAME and
# remove its state file. Defensive: killing a dead PID is a no-op; a missing
# state file is fine (a sandbox with no published port has nothing to clean up).
_acq_msb_ports_teardown() {
  local name="$1" pidfile
  pidfile=$(_acq_msb_ports_pidfile "$name") || return 0
  [ -f "$pidfile" ] || return 0
  local serve_pid ssh_pid _rest
  while read -r serve_pid ssh_pid _rest; do
    [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null || true
    [ -n "$ssh_pid" ] && kill "$ssh_pid" 2>/dev/null || true
  done <"$pidfile"
  rm -f "$pidfile" 2>/dev/null || true
  acq_debug "msb ports: tore down published-port tunnels for $name"
  return 0
}

# _acq_msb_ports_list NAME — print NAME's published port mappings to stdout, one
# per line, each line CONTAINING the port digits so a `grep -q <port>` matches
# (openchamber verify relies on this). Two sources, both DEFENSIVE (a query must
# never hard-fail): (a) create-time `-p HOST:GUEST` NAT mappings known to msb,
# read from `msb inspect <name> --format json`; (b) acq's recorded post-hoc
# ssh -L tunnels from the ADR-0015 state file. Empty list -> just exit 0.
_acq_msb_ports_list() {
  local name="$1" pidfile _sport _map _serve _ssh
  # (a) create-time NAT mappings (best-effort; absent field/tool is not an error).
  _acq_msb_ports_from_inspect "$name"
  # (b) recorded post-hoc ssh -L tunnels: `<serve_pid> <ssh_pid> <sport> <H:G>`.
  pidfile=$(_acq_msb_ports_pidfile "$name") || return 0
  [ -f "$pidfile" ] || return 0
  while read -r _serve _ssh _sport _map; do
    [ -n "$_map" ] || continue
    printf 'guest %s -> host 127.0.0.1:%s (post-hoc ssh -L)\n' \
      "${_map#*:}" "${_map%%:*}"
  done <"$pidfile"
  return 0
}

# _acq_msb_ports_from_inspect NAME — extract create-time host/guest port mappings
# from `msb inspect NAME --format json` and print one per line as
# `guest <G> -> host <H> (create-time -p)`.
#
# Canonical JSON shape (do NOT re-guess this — it is defined in the microsandbox
# source, not just observed): `msb inspect --format json` emits the sandbox's
# active config under `.active_config` (with the requested config mirrored under
# `.config`), and published ports live at `<config>.network.ports[]`. Each entry
# is a `PublishedPort` struct serialized as:
#     { "host_port": <u16>, "guest_port": <u16>,
#       "protocol": "tcp"|"udp", "host_bind": "<ip>" }
# See microsandbox `crates/network/lib/config.rs` (`struct PublishedPort`) and
# `crates/cli/lib/commands/inspect.rs` (the `--format json` assembly) — pinned to
# msb 0.6.7. `host_bind` defaults to loopback (127.0.0.1).
#
# Prefer `jq`; else a dependency-free `host_port`/`guest_port` scan (which
# deliberately ignores `host_bind`, whose dotted IP would otherwise be mistaken
# for port digits). Missing tool/field or no output are silent no-ops (return 0)
# — a query must never hard-fail.
_acq_msb_ports_from_inspect() {
  local name="$1" json line h g
  json=$(msb inspect "$name" --format json 2>/dev/null) || return 0
  [ -n "$json" ] || return 0
  local lines=""
  if command -v jq >/dev/null 2>&1; then
    # msb 0.6.7 shape first; fall back to a few plausible legacy field names.
    # `?//empty` keeps a missing path from erroring; each port -> "H:G".
    lines=$(printf '%s' "$json" | jq -r '
      [ ((.active_config.network.ports?) // (.config.network.ports?)
          // .ports? // .portMappings? // .publishedPorts? // [])[]?
        | if type=="string" then .
          elif type=="object" then
            (((.host_port // .hostPort // .host)|tostring) + ":" +
             ((.guest_port // .guestPort // .guest // .container)|tostring))
          else empty end ]
      | .[]?' 2>/dev/null)
  fi
  if [ -z "$lines" ]; then
    # jq absent/failed: dependency-free. Read the ports array as flat key:value
    # tokens and pull explicit host_port/guest_port pairs. We match ONLY the
    # *_port keys so `host_bind: "127.0.0.1"` can't leak dotted-IP digits.
    lines=$(printf '%s' "$json" \
      | tr -d '" ' \
      | tr ',{}[]' '\n\n\n\n\n' \
      | grep -E '^(host_port|guest_port):[0-9]{1,5}$' 2>/dev/null \
      | _acq_msb_pair_lines)
  fi
  [ -n "$lines" ] || return 0
  printf '%s\n' "$lines" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    h="${line%%:*}"; g="${line#*:}"
    case "$h" in ""|*[!0-9]*) continue ;; esac
    case "$g" in ""|*[!0-9]*) continue ;; esac
    printf 'guest %s -> host 127.0.0.1:%s (create-time -p)\n' "$g" "$h"
  done
  return 0
}

# _acq_msb_pair_lines — read a flat stream of `<key>:<value>` port tokens on
# stdin (host_port:N, guest_port:N, …, in msb's array order) and emit "H:G" per
# host/guest pair, keyed by name so ordering variations still pair correctly.
# Dependency-free helper for the jq-absent fallback in
# _acq_msb_ports_from_inspect. A dangling host without a following guest (or
# vice versa) is dropped. bash-3.2 safe.
_acq_msb_pair_lines() {
  local h="" g="" tok k v
  while read -r tok; do
    k="${tok%%:*}"; v="${tok#*:}"
    case "$k" in
      host_port)  h="$v" ;;
      guest_port) g="$v" ;;
      *) continue ;;
    esac
    if [ -n "$h" ] && [ -n "$g" ]; then
      printf '%s:%s\n' "$h" "$g"; h=""; g=""
    fi
  done
}
# ---------------------------------------------------------------------------
# acq_backend_apply_kit — apply a kit into an existing sandbox mid-life
# ---------------------------------------------------------------------------
# msb has no native "kit add"; translate the kit → msb exec command sequence.

acq_backend_apply_kit() {
  local name="$1" kitref="$2"
  local kitdir
  kitdir=$(_acq_msb_fetch_kit "$kitref") || {
    echo "acq(msb): error: could not fetch kit: $kitref" >&2
    return 1
  }
  _acq_msb_apply_kit_dir "$name" "$kitdir"
}

# ---------------------------------------------------------------------------
# acq_backend_ensure_kits_applied — best-effort heal of a sandbox missing kits
# ---------------------------------------------------------------------------
# msb sandboxes are recreated cheaply and msb has no in-place kit-add that
# preserves state guarantees the way sbx 0.35.0 does. Rather than silently
# destroy state, re-apply the neutral kits idempotently (files are overwritten,
# commands are idempotent / install-marker-gated). If a caller needs a clean
# rebuild, they can `acq rm && acq run`.

acq_backend_ensure_kits_applied() {
  local name="$1"
  local kits=("$USAI_KIT" "$PLAYBOOK_KIT" "$ZSCALER_KIT" "$GITSSHSIGN_KIT")
  if [ -n "${ACQ_EXTRA_KITS:-}" ]; then
    local _extras=()
    split_noglob _extras "$ACQ_EXTRA_KITS"
    kits+=("${_extras[@]}")
  fi
  local kitref kitdir
  for kitref in "${kits[@]}"; do
    kitdir=$(_acq_msb_fetch_kit "$kitref") || {
      echo "acq(msb): warning: could not fetch kit for healing: $kitref" >&2
      continue
    }
    _acq_msb_apply_kit_dir "$name" "$kitdir" || true
  done
}

# ---------------------------------------------------------------------------
# acq_backend_secret_set — store in the acq secret store (msb reads it at create)
# ---------------------------------------------------------------------------
# Credentials are owned by acq's backend-neutral store
# (acq.backends/secret-store.sh). `acq secret set` on the msb backend writes the
# value into the same acq store the sbx path uses, keyed acq.<service> or
# acq.<sandbox>.<service>. At provision, acq_backend_provision reads it back and
# binds it with `msb --secret ENV@HOST` (value in a transient env var, never
# argv, never the sandbox config). No separate msb secret store is written.
#
# Usage: acq secret set [-g | SANDBOX] <service> [--host HOST --env ENV]

# _acq_msb_parse_secret_scope SERVICE_OUT SCOPE_OUT ARG... — parse the leading
# `-g/--global | SANDBOX | <service>` scope token shared by secret set/rm.
# Writes the resolved service name to the var named by SERVICE_OUT, the scope
# (sandbox name, empty for global/default) to SCOPE_OUT, and the number of
# positional args the scope+service consumed to the global
# _ACQ_MSB_SCOPE_CONSUMED so the caller can `shift` past them. (A count is passed
# via a global rather than stdout because writing the by-name out-vars must happen
# in the caller's shell, not a `$(...)` subshell.) Mirrors the sbx wrapper:
# -g/--global -> global; a leading bare token before the service -> sandbox name;
# a leading -flag or a lone token -> service itself.
_acq_msb_parse_secret_scope() {
  local _svc_out="$1" _scope_out="$2"
  shift 2
  local _service="${1:-}" _scope="" _consumed=1
  case "$_service" in
    -g|--global)
      _service="${2:-}"; _consumed=2
      ;;
    -*)
      ;;
    *)
      local _next="${2:-}"
      case "$_next" in
        ""|-*) ;;
        *) _scope="$_service"; _service="$_next"; _consumed=2 ;;
      esac
      ;;
  esac
  # Clamp to the args actually present: for `secret set` (0 args) or `secret set
  # -g` (1 arg) the scope+service is incomplete, but the caller still `shift`s
  # this count under `set -euo pipefail` — an over-shift would abort BEFORE the
  # "missing service name" usage message (the OLD code used `shift || true`).
  [ "$_consumed" -gt "$#" ] && _consumed="$#"
  eval "$_svc_out=\$_service"
  eval "$_scope_out=\$_scope"
  _ACQ_MSB_SCOPE_CONSUMED="$_consumed"
}

# _acq_msb_parse_host_env HOST_OUT ENV_OUT ARG... — parse optional --host/--env
# (a custom endpoint's mapping) from the trailing args into the named vars.
# Accepts both `--host H`/`--env E` and `--host=H`/`--env=E` forms. Built-ins
# (usai, github) need no flags — their mapping is compiled in.
_acq_msb_parse_host_env() {
  local _host_out="$1" _env_out="$2"
  shift 2
  local _host="" _env_var="" _prev="" _arg
  for _arg in "$@"; do
    if [ "$_prev" = "--host" ]; then _host="$_arg"; _prev=""; continue
    elif [ "$_prev" = "--env" ]; then _env_var="$_arg"; _prev=""; continue; fi
    case "$_arg" in
      --host=*) _host="${_arg#--host=}" ;;
      --env=*)  _env_var="${_arg#--env=}" ;;
      --host)   _prev="--host" ;;
      --env)    _prev="--env" ;;
    esac
  done
  eval "$_host_out=\$_host"
  eval "$_env_out=\$_env_var"
}

# _acq_msb_secret_refeed SERVICE SCOPE ENV HOST — live add/rotate: re-feed a
# newly-set/rotated secret to running sandboxes via `msb modify --secret ENV@HOST`
# (the guest keeps its placeholder; only the injected value changes) so it takes
# effect without recreate. A named SCOPE targets that sandbox; empty SCOPE sweeps
# all running sandboxes. Echoes the count of sandboxes re-fed.
#
# SECRET NEVER ON ARGV: the value is placed in the environment via a dynamic
# `export "$ENV=$val"` (an env ENTRY, invisible to `ps`/`/proc/<pid>/cmdline`),
# NOT via `env NAME=VAL msb …` — there NAME=VAL is an OPERAND on env(1)'s argv and
# would leak the token to any `ps -ww` for the life of the child. The var is
# unset immediately after the sweep.
_acq_msb_secret_refeed() {
  local service="$1" scope_name="$2" _env="$3" _host="$4"
  local val applied=0 sb
  [ -n "$_env" ] && [ -n "$_host" ] || { printf '0\n'; return 0; }
  val=$(acq_secret_resolve "$service" "$scope_name" 2>/dev/null) && [ -n "$val" ] || { printf '0\n'; return 0; }
  # shellcheck disable=SC2163  # dynamic export of the resolved binding env var
  export "$_env=$val"
  if [ -n "$scope_name" ]; then
    if acq_backend_exists "$scope_name"; then
      msb modify "$scope_name" --secret "${_env}@${_host}" </dev/null >/dev/null 2>&1 \
        && applied=$((applied + 1))
    fi
  else
    # stdin from /dev/null so `msb modify` can't consume the `while read`
    # heredoc (else only the first sandbox is processed — a real msb drains
    # stdin). Same trap guarded in acq_backend_secret_rm's sweep.
    while IFS= read -r sb; do
      [ -n "$sb" ] || continue
      msb modify "$sb" --secret "${_env}@${_host}" </dev/null >/dev/null 2>&1 \
        && applied=$((applied + 1))
    done <<EOF
$(msb list -q 2>/dev/null)
EOF
  fi
  unset "$_env"
  val=""
  [ "$applied" -gt 0 ] && acq_debug "msb modify: re-fed $service (${_env}@${_host}) to $applied sandbox(es)"
  printf '%s\n' "$applied"
}

# _acq_msb_secret_set_guidance SERVICE ENV HOST APPLIED — print the
# service-specific post-set guidance (built-ins get bespoke wording; a custom
# endpoint reports its ENV@HOST binding, or how to add one if unmapped).
_acq_msb_secret_set_guidance() {
  local service="$1" _env="$2" _host="$3" applied="$4"
  case "$service" in
    usai)
      echo "acq(msb): stored USAi key in the acq secret store. At 'acq run/create'" >&2
      echo "      the msb backend binds it via --secret USAI_API_KEY@${ACQ_MSB_USAI_HOST};" >&2
      echo "      the real value is swapped in on the wire and never enters the guest." >&2
      [ "$applied" -gt 0 ] && echo "      Re-fed $applied running sandbox(es) via 'msb modify' (no recreate needed)." >&2
      ;;
    github)
      echo "acq(msb): stored GitHub token in the acq secret store. At 'acq run/create'" >&2
      echo "      the msb backend binds it via --secret GITHUB_TOKEN@${ACQ_MSB_GITHUB_HOST};" >&2
      echo "      the real value is swapped in on the wire to the REST API and never enters" >&2
      echo "      the guest. Kits authenticate via the REST API (e.g. the playbook kit" >&2
      echo "      fetches a source tarball from api.github.com) — NOT 'git clone', which" >&2
      echo "      msb does not substitute for github.com/codeload (quickstart#203)." >&2
      [ "$applied" -gt 0 ] && echo "      Re-fed $applied running sandbox(es) via 'msb modify' (no recreate needed)." >&2
      ;;
    *)
      if [ -n "$_env" ] && [ -n "$_host" ]; then
        echo "acq(msb): stored '$service' in the acq secret store with endpoint" >&2
        echo "      ${_env}@${_host}. At 'acq run/create' the msb backend binds it via" >&2
        echo "      --secret ${_env}@${_host}; the real value is swapped in on the wire and" >&2
        echo "      never enters the guest." >&2
        [ "$applied" -gt 0 ] && echo "      Re-fed $applied running sandbox(es) via 'msb modify' (no recreate needed)." >&2
      else
        echo "acq(msb): stored '$service' in the acq secret store, but it has no endpoint" >&2
        echo "      mapping so the msb backend cannot bind it. Provide --host HOST --env ENV" >&2
        echo "      (e.g. 'acq secret set -g $service --host api.example.com --env API_KEY')" >&2
        echo "      so it is bound via --secret ENV@HOST at create." >&2
      fi
      ;;
  esac
}

acq_backend_secret_set() {
  local service scope_name
  _acq_msb_parse_secret_scope service scope_name "$@"
  shift "$_ACQ_MSB_SCOPE_CONSUMED"

  if [ -z "$service" ]; then
    echo "acq(msb): secret set: missing service name" >&2
    echo "     usage: acq secret set [-g | SANDBOX] <service> [--host HOST --env ENV]" >&2
    return 1
  fi

  # Parse optional --host/--env (a CUSTOM endpoint's mapping). These are recorded
  # as a non-secret sidecar so the provision path can bind the service generically
  # via `msb --secret ENV@HOST` (quickstart#226). Built-ins (usai, github) need no
  # flags — their mapping is compiled in.
  local host env_var
  _acq_msb_parse_host_env host env_var "$@"

  if ! command -v acq_secret_set_interactive >/dev/null 2>&1; then
    echo "acq(msb): internal error: secret store not loaded" >&2
    return 1
  fi

  # Store into the acq-owned store (keychain/file); value read from TTY/stdin.
  # host/env (when supplied) are persisted as a non-secret endpoint sidecar.
  acq_secret_set_interactive "$service" "$scope_name" "$host" "$env_var" || return 1

  # Live add/rotate: re-feed running sandboxes so a newly-set or rotated secret
  # takes effect without recreate. Driven off the single binding table so EVERY
  # bound service (usai, github, ...) rotates in place — not just usai.
  local _env _host _binding applied
  _binding=$(_acq_msb_service_binding "$service" "$scope_name")
  _env=$(printf '%s' "$_binding" | cut -f1)
  _host=$(printf '%s' "$_binding" | cut -f2)
  applied=$(_acq_msb_secret_refeed "$service" "$scope_name" "$_env" "$_host")

  _acq_msb_secret_set_guidance "$service" "$_env" "$_host" "$applied"
  return 0
}

# ---------------------------------------------------------------------------
# acq_backend_secret_rm [-g | SANDBOX] SERVICE  (msb backend)
# ---------------------------------------------------------------------------
# Remove a secret from the acq store AND live-unbind it from running sandboxes.
# msb binds a secret at create via `--secret ENV@HOST`; `msb modify --secret-rm
# ENV` removes that binding from a running VM (verified: msb 0.6.7 modify has
# --secret-rm <NAME>). So on rm we (1) delete the acq-store value (source of
# truth for future creates) and (2) `msb modify --secret-rm ENV` the sandbox(es)
# so the injected value stops flowing immediately — a named scope targets that
# sandbox; a global rm sweeps all running sandboxes. Idempotent (absent secret /
# absent binding are both success). Scope parsing mirrors acq_backend_secret_set.
# _acq_msb_secret_unbind SCOPE ENV — live-unbind a secret from running sandboxes
# via `msb modify --secret-rm ENV`, for services the adapter actually binds. A
# named SCOPE targets that sandbox; empty SCOPE sweeps every running sandbox.
# Best-effort per sandbox; echoes the count unbound. Empty ENV => nothing to do.
_acq_msb_secret_unbind() {
  local scope_name="$1" env_name="$2" unbound=0 sb
  [ -n "$env_name" ] || { printf '0\n'; return 0; }
  if [ -n "$scope_name" ]; then
    if acq_backend_exists "$scope_name"; then
      msb modify "$scope_name" --secret-rm "$env_name" >/dev/null 2>&1 \
        && unbound=$((unbound + 1))
    fi
  else
    # NOTE: redirect each `msb modify` stdin from /dev/null. Without it, the
    # command inside the loop consumes the heredoc that feeds `while read`, so
    # only the FIRST sandbox is processed (a real `msb` drains stdin). This is
    # the same stdin-consumption trap the test stub deliberately reproduces.
    while IFS= read -r sb; do
      [ -n "$sb" ] || continue
      msb modify "$sb" --secret-rm "$env_name" </dev/null >/dev/null 2>&1 \
        && unbound=$((unbound + 1))
    done <<EOF
$(msb list -q 2>/dev/null)
EOF
  fi
  [ "$unbound" -gt 0 ] && acq_debug "msb modify --secret-rm $env_name: unbound from $unbound sandbox(es)"
  printf '%s\n' "$unbound"
}

acq_backend_secret_rm() {
  local service scope_name
  _acq_msb_parse_secret_scope service scope_name "$@"
  shift "$_ACQ_MSB_SCOPE_CONSUMED"

  if [ -z "$service" ]; then
    echo "acq(msb): secret rm: missing service name" >&2
    echo "     usage: acq secret rm [-g | SANDBOX] <service>" >&2
    return 1
  fi

  if ! command -v acq_secret_delete >/dev/null 2>&1; then
    echo "acq(msb): internal error: secret store not loaded" >&2
    return 1
  fi

  # 1) Delete the acq-store value (idempotent). Resolve the binding's env var
  #    FIRST (for a custom endpoint it comes from the non-secret sidecar, which
  #    step 3 removes), so the live-unbind below still knows what to unbind.
  local key removed=0
  local env_name
  env_name=$(_acq_msb_service_binding "$service" "$scope_name" | cut -f1)
  # _acq_secret_key fails closed on an ambiguous (dotted) name (quickstart#234);
  # such a name could never have been stored, so treat rm as a no-op success
  # (the `|| key=""` keeps `set -e` from aborting the rm path).
  key=$(_acq_secret_key "$service" "$scope_name") || key=""
  [ -n "$key" ] && acq_secret_delete "$key" && removed=1

  # 2) Live-unbind from running sandboxes via `msb modify --secret-rm ENV`, for
  #    services the adapter actually binds (built-ins + any custom endpoint with
  #    a recorded env). A named scope targets that sandbox; a global rm sweeps
  #    every running sandbox.
  local unbound
  unbound=$(_acq_msb_secret_unbind "$scope_name" "$env_name")

  # 3) Drop the non-secret endpoint sidecar for this service/scope (idempotent),
  #    so a re-set does not resurrect a stale host/env mapping. Done AFTER the
  #    unbind above, which needed the env name it records.
  command -v acq_secret_meta_delete >/dev/null 2>&1 && \
    acq_secret_meta_delete "$service" "$scope_name" || true

  local where="global"
  [ -n "$scope_name" ] && where="sandbox '$scope_name'"
  if [ "$removed" -eq 1 ]; then
    echo "acq(msb): removed '$service' secret (${where}) from the acq store." >&2
  else
    echo "acq(msb): no '$service' secret found in the acq store (${where})." >&2
  fi
  if [ "$unbound" -gt 0 ]; then
    echo "      Live-unbound it from $unbound running sandbox(es) (msb modify --secret-rm)." >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# acq_backend_secret_ls [-g | SANDBOX] — list acq-managed secrets for msb.
# ---------------------------------------------------------------------------
# Prints one row per acq-managed secret: SCOPE, SERVICE, whether a VALUE is
# present, and the binding ENV@HOST the msb adapter would use at provision.
# NEVER prints a secret value. With no scope, lists everything acq holds; with a
# scope (-g or SANDBOX) it filters to that scope. Read-only.
#
# Sources: the value store (acq_secret_list_keys → decode scope/service). The
# ENV@HOST column comes from _acq_msb_service_binding, so it shows exactly what
# would be bound (built-in host for usai/github, or the custom-endpoint sidecar).
acq_backend_secret_ls() {
  local want_scope=""
  case "${1:-}" in
    -g|--global) want_scope="-g" ;;
    "") want_scope="" ;;
    -*) echo "acq(msb): secret ls: unknown flag '$1'" >&2; return 1 ;;
    *)  want_scope="$1" ;;
  esac
  if ! command -v acq_secret_list_keys >/dev/null 2>&1; then
    echo "acq(msb): internal error: secret store not loaded" >&2
    return 1
  fi
  printf 'SCOPE\tSERVICE\tVALUE\tBINDING\n'
  _acq_msb_secret_ls_rows "$want_scope" | LC_ALL=C sort -u
}

# _acq_msb_secret_ls_rows WANT_SCOPE — emit unsorted "scope\tservice\tvalue\tbinding"
# rows (no header). Kept separate so acq_backend_secret_ls stays <=50 lines and
# the sort/header live in one place.
_acq_msb_secret_ls_rows() {
  local want_scope="$1" key scope svc dec val binding
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    dec=$(_acq_secret_decode_key "$key") || continue
    scope=$(printf '%s' "$dec" | cut -f1)
    svc=$(printf '%s' "$dec" | cut -f2)
    [ -n "$svc" ] || continue
    case "$want_scope" in "") ;; *) [ "$scope" = "$want_scope" ] || continue ;; esac
    if [ "$scope" = "-g" ]; then
      acq_secret_has "$svc" && val="yes" || val="no"
      binding=$(_acq_msb_secret_ls_binding "$svc" "")
    else
      acq_secret_has "$svc" "$scope" && val="yes" || val="no"
      binding=$(_acq_msb_secret_ls_binding "$svc" "$scope")
    fi
    printf '%s\t%s\t%s\t%s\n' "$scope" "$svc" "$val" "$binding"
  done <<EOF
$(acq_secret_list_keys)
EOF
}

# _acq_msb_secret_ls_binding SERVICE SANDBOX -> "ENV@HOST" or "(unmapped)".
# Reuses the adapter's real binding resolver so the listing matches what would
# actually be bound. Never prints a value.
_acq_msb_secret_ls_binding() {
  local svc="$1" sandbox="${2:-}" b env host
  b=$(_acq_msb_service_binding "$svc" "$sandbox")
  env=$(printf '%s' "$b" | cut -f1)
  host=$(printf '%s' "$b" | cut -f2)
  if [ -n "$env" ] && [ -n "$host" ]; then
    printf '%s@%s\n' "$env" "$host"
  else
    printf '(unmapped)\n'
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_rotate_key — rotate the global USAi key (per ADR-0012)
# ---------------------------------------------------------------------------
# msb has no proxy-placeholder concept: the acq-owned secret store is the source
# of truth, and msb binds it at provision via `--secret ENV@HOST` and re-feeds
# running sandboxes with `msb modify --secret`. Rotation therefore = store the
# new key in the acq store + re-feed running sandboxes (exactly the `acq secret
# set -g usai` path) + validate. Never places the value on argv. Returns
# non-zero on failure.
acq_backend_rotate_key() {
  if ! command -v acq_secret_set_interactive >/dev/null 2>&1; then
    echo "acq(msb): internal error: secret store not loaded" >&2
    return 1
  fi

  echo "Rotating the USAi key in the acq secret store (msb backend)." >&2

  # Store the new key (TTY/stdin; never argv) and re-feed running sandboxes.
  # acq_backend_secret_set already stores usai + runs `msb modify --secret` for
  # every running sandbox, so reuse it rather than duplicating that logic.
  acq_backend_secret_set -g usai || {
    echo "acq(msb): failed to store the new USAi key." >&2
    return 1
  }

  # Validate the new key in a fresh throwaway sandbox (backend-neutral helper).
  echo "Validating new key in a temporary sandbox..." >&2
  local status=""
  if command -v check_fresh_sandbox_key >/dev/null 2>&1; then
    status=$(check_fresh_sandbox_key)
  fi

  if [ -z "$status" ]; then
    echo "Could not run a validation sandbox; skipping check." >&2
    echo "The key was rotated. Re-run 'acq run' to validate on next attach." >&2
    return 0
  fi
  if [ "$status" = "200" ]; then
    echo "Key validated (HTTP 200). You're good to go." >&2
    return 0
  fi
  echo "acq(msb): key validation failed (HTTP ${status}). Double-check the key and rotate again." >&2
  return 1
}

# ---------------------------------------------------------------------------
# acq_backend_version / acq_backend_doctor
# ---------------------------------------------------------------------------

acq_backend_version() {
  msb --version 2>/dev/null || echo "(msb version unknown)"
}

acq_backend_doctor() {
  local ver
  ver=$(_acq_msb_version)
  [ -n "$ver" ] || ver="?"
  printf '[msb: installed %s]\n' "$ver"
}

# ---------------------------------------------------------------------------
# is_known_agent — used by the acq run dispatch
# ---------------------------------------------------------------------------

is_known_agent() {
  case "$KNOWN_AGENTS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}
