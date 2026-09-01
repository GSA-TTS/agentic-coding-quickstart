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
#   - `msb exec [FLAGS] <NAME> [-u USER] -- CMD…` — msb 0.6.7 accepts the option
#      flags (`-u`, `-t`, `-w`, `-e`) either BEFORE or AFTER <NAME> (getopt-style,
#      order-independent, verified via `msb --tree` / the live openchamber-on-msb
#      verify). This adapter uses flags-after-NAME for the kit-command/marker
#      paths and flags-before-NAME for the interactive attach + `acq exec` paths;
#      both are valid. (A future cleanup could normalize to one order once
#      re-checked against a newer msb; both forms work on the pinned msb.)
#   - `msb list|ls [-q] [--running]`, `msb stop`, `msb remove|rm [-f]`,
#     `msb copy|cp SRC DST`, `msb ssh [SANDBOX] [-- CMD…]`, `msb ssh authorize`,
#     `msb run … -p HOST:GUEST` (published ports), `msb doctor`.
#   - Volume surface (ADR-0023): `msb create … --mount-named
#     NAME:PATH:kind=disk,size=SIZE` (create-or-reuse disk-backed named volume),
#     `--tmpfs PATH:SIZE`, and `msb volume ls -q` / `msb volume rm NAME` for the
#     terminate-time cleanup of derived volumes. LIVE-VERIFIED end-to-end on
#     msb 0.6.12 (macOS HVF) via `scripts/verify-backends --only msb` (17/17):
#     the derived disk volume mounts at boot on a dedicated virtio-blk device
#     of the declared size, and is removed again on `acq rm`. NOTE: msb refuses
#     tiny ext4 disk images ("image size is too small for ext4 formatting";
#     floor 128M on 0.6.12) — kits should stay well above it (~256m floor).
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
ACQ_BACKEND_SUPPORTS_SNAPSHOTS=0           # msb HAS `msb snapshot`, but acq exposes NO `snapshot` verb; wiring one is beyond sbx parity (sbx has none), so this flag reflects what acq surfaces (0), not what msb can do
# shellcheck disable=SC2034
ACQ_BACKEND_CAN_RESUME=1                   # msb stop / msb start preserve state
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_CREDENTIAL_REWRITE=1  # msb --secret ENV@HOST + --tls-intercept

# Shared agent catalog (issue #377). common.sh normally sources this, but some
# tests source this adapter directly; guard so a re-source is cheap and so the
# catalog helpers (acq_is_known_agent, acq_agent_template_image, …) are always
# defined when this file's functions run.
if ! command -v acq_is_known_agent >/dev/null 2>&1; then
  # shellcheck source=acq.backends/agents.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/agents.sh"
fi

# Minimum msb version required. Two reasons pin this to 0.6.9:
#   1. 0.6.8 is the first release with the `--net-default-egress` /
#      `--net-default-ingress` split that the balanced-egress baseline (on by
#      default, ADR-0018/0019) relies on — earlier 0.6.x had the neutral net
#      rules, --trust-host-cas, and --secret used here, but only the symmetric
#      `--net-default`, so a plain `acq create` would pass an unknown flag to a
#      0.6.0-0.6.7 binary and clap would hard-error.
#   2. 0.6.9 is the first release where the semantic `allow@dns` macro parses
#      correctly on release builds (the upstream release-build parser fix). On
#      <= 0.6.8 that macro hard-failed on release binaries, so the gateway-DNS
#      grant had to be emitted as an expanded udp/tcp:53 pair. The baseline
#      emitter now uses `allow@dns` directly (see ADR-0018), which requires 0.6.9.
# Fail closed on the floor instead (acq_backend_prepare) so the failure mode is a
# clear version message, not a raw clap error or DNS parse failure mid-create.
MIN_MSB_VERSION="0.6.9"

# Default OCI image for provisioned sandboxes. We default to the SAME image
# family sbx uses: `docker/sandbox-templates:shell-docker`, an Ubuntu-based
# agent template. It ALREADY ships the non-root `agent` user (with passwordless
# sudo), node, git, curl, and ca-certificates (the four kits' runtime
# prerequisites), AND an agent-writable npm global prefix
# (/usr/local/share/npm-global) — so `npm install -g` by the agent user works
# without sudo and without EACCES. Defaulting here makes msb match sbx by
# construction and removes the need to synthesize the agent user / sudo on a
# plain OCI base. It is pullable from Docker Hub without registry auth.
#
# We deliberately do NOT apt-install prerequisites at runtime: the kit net-rules
# lock egress to only the kits' own hosts (api.gsa.usai.gov, github.com, ...),
# so a package mirror is unreachable during provision. This still matters for a
# custom base — bake the tools into the image rather than expecting a runtime
# install. Override with ACQ_MSB_IMAGE to bring your own (e.g. a lighter or
# org-internal image, or a plain OCI base) — a custom image must still provide
# the prerequisites; see the prerequisite contract below.
#
# ADR-0022 (neutral --image / ACQ_IMAGE): the backend-agnostic image knob resolves
# to this variable when ACQ_MSB_IMAGE is not itself set. Precedence: an explicitly
# set ACQ_MSB_IMAGE (the most-specific, backend-scoped var) WINS over the neutral
# ACQ_IMAGE, with a one-time notice, so a user who deliberately set the msb var is
# never silently overridden. The resolution runs at provision time (not here at
# source time) via _acq_msb_resolve_image, because the neutral value may be set by
# the `--image` flag after this file is sourced.
ACQ_MSB_IMAGE="${ACQ_MSB_IMAGE:-}"
_ACQ_MSB_DEFAULT_IMAGE="docker.io/docker/sandbox-templates:shell-docker"
_ACQ_MSB_IMAGE_NOTICE_SHOWN=0

# _acq_msb_resolve_image AGENT — set the OCI image `msb create` should use,
# applying the ADR-0022 precedence: explicit ACQ_MSB_IMAGE > neutral
# --image/ACQ_IMAGE > agent-derived sandbox-template image > built-in default.
# Prints a one-time notice if BOTH the backend var and the neutral image are set
# (backend var wins). Idempotent notice (once per process).
_ACQ_MSB_RESOLVED_IMAGE=""
_ACQ_MSB_RESOLVED_IMAGE_SOURCE=""
_acq_msb_resolve_image() {
  local agent="${1:-shell}"
  local neutral=""
  if command -v acq_resolve_neutral_image >/dev/null 2>&1; then
    neutral=$(acq_resolve_neutral_image)
  fi
  if [ -n "${ACQ_MSB_IMAGE:-}" ]; then
    if [ -n "$neutral" ] && [ "$neutral" != "$ACQ_MSB_IMAGE" ] \
       && [ "${_ACQ_MSB_IMAGE_NOTICE_SHOWN:-0}" != "1" ]; then
      _ACQ_MSB_IMAGE_NOTICE_SHOWN=1
      echo "acq(msb): both ACQ_MSB_IMAGE and a neutral image (--image/ACQ_IMAGE) are set;" >&2
      echo "acq(msb):   using the backend-specific ACQ_MSB_IMAGE='$ACQ_MSB_IMAGE'" >&2
      echo "acq(msb):   (most-specific wins; see ADR-0022). Unset ACQ_MSB_IMAGE to use the" >&2
      echo "acq(msb):   neutral image '$neutral'." >&2
    fi
    _ACQ_MSB_RESOLVED_IMAGE="$ACQ_MSB_IMAGE"
    _ACQ_MSB_RESOLVED_IMAGE_SOURCE="backend"
    return 0
  fi
  if [ -n "$neutral" ]; then
    _ACQ_MSB_RESOLVED_IMAGE="$neutral"
    _ACQ_MSB_RESOLVED_IMAGE_SOURCE="neutral"
    return 0
  fi
  if _ACQ_MSB_RESOLVED_IMAGE=$(acq_agent_template_image "$agent" 2>/dev/null) \
     && [ "$_ACQ_MSB_RESOLVED_IMAGE" != "$_ACQ_MSB_DEFAULT_IMAGE" ]; then
    _ACQ_MSB_RESOLVED_IMAGE_SOURCE="agent-default"
    return 0
  fi
  _ACQ_MSB_RESOLVED_IMAGE="$_ACQ_MSB_DEFAULT_IMAGE"
  _ACQ_MSB_RESOLVED_IMAGE_SOURCE="builtin-default"
}

# _acq_msb_image_not_found_error STDERR — 0 if `msb create`'s error text means
# the image REF does not exist (so an agent-derived default may fall back to the
# shell image), 1 otherwise. Live-verified against msb on Docker Hub and ghcr.io:
# BOTH a nonexistent Docker Hub tag AND a private/nonexistent ghcr.io repo report
#   error: image error: registry error: ... OCI API errors: [OCI API error: manifest unknown]
# i.e. the registry returns `manifest unknown` for not-found regardless of
# whether the repo is private. We therefore treat `manifest unknown` (and the
# other classic not-found phrasings) as fall-back-eligible, but NOT auth/network
# failures (`unauthorized`, TLS, connection refused, …): those are real problems
# with the requested image that must surface, not be papered over by a fallback.
# The auth/network deny-list is checked FIRST so a message that somehow carries
# both never falls back.
_acq_msb_image_not_found_error() {
  case "$1" in
    *unauthorized*|*Unauthorized*|*authentication\ required*|*denied*|*Denied*|*forbidden*|*Forbidden*|*TLS*|*tls*|*timeout*|*connection\ refused*|*no\ route*) return 1 ;;
    *manifest\ unknown*|*name\ unknown*|*not\ found*|*Not\ found*|*No\ such\ image*|*repository\ does\ not\ exist*) return 0 ;;
    *) return 1 ;;
  esac
}

# Prerequisite tools the pinned four kits need at runtime, expected to be
# PRESENT IN THE BASE IMAGE (the default sandbox-templates:shell-docker provides
# all four):
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

# GitHub credential hosts for the msb --secret binding. Bind the REST API and
# git-transport hosts so both API calls and HTTPS git clone/push can substitute
# the token on the wire. The env var name is GITHUB_TOKEN (the neutral
# service->env mapping; kits also accept GH_TOKEN).
ACQ_MSB_GITHUB_HOST="${ACQ_MSB_GITHUB_HOST:-github.com,api.github.com,codeload.github.com}"

# _acq_msb_service_binding SERVICE [SANDBOX] -> "ENVVAR<TAB>HOST" for services
# the msb adapter binds via `--secret ENV@HOST`, or empty for services it does
# not bind. Single source of truth for the bind (provision), rotate (set), and
# unbind (secret rm) paths.
#
# GENERIC custom endpoints: usai + github keep their
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
  # Sidecar FIRST (#384): an explicit `--host` recorded at `acq secret set`
  # must win over the compiled-in usai/github mapping — the sbx backend gives
  # the user's host the same precedence, and a compiled-in short-circuit here
  # silently re-bound a self-hosted token to the default endpoint. Absent
  # sidecar => compiled-in mapping for usai/github, empty (no binding) for
  # anything else — prior behavior unchanged.
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
  case "$_service" in
    usai)   printf '%s\t%s\n' "USAI_API_KEY" "$ACQ_MSB_USAI_HOST"; return 0 ;;
    github) printf '%s\t%s\n' "GITHUB_TOKEN" "$ACQ_MSB_GITHUB_HOST"; return 0 ;;
  esac
  printf '\t\n'
}

# The kits expect an unprivileged `agent` user with HOME=/home/agent (the sbx
# agent-template contract). The default image already provides it; but a plain
# OCI base override (e.g. node:22-bookworm) does not, so the adapter creates it
# at provision (see _acq_msb_ensure_agent_user), addressing it by NAME — the uid
# is whatever the base image leaves free (1000 is often taken by a pre-existing
# user, e.g. `node` on node:22-bookworm).

# Guest memory and vCPU allocation.
# ---------------------------------------------------------------------------
# msb 0.6.x defaults a sandbox to 512 MiB RAM and 1 vCPU (see the microsandbox
# config defaults DEFAULT_MEMORY_MIB=512 / DEFAULT_CPUS=1). The microVM has NO
# swap, so a process that exceeds guest RAM is OOM-killed by the guest kernel and
# simply prints "Killed". A Node.js agent TUI like opencode blows past 512 MiB
# immediately, so a create with no memory flag left the user with an agent that
# started and was instantly killed. sbx sizes its
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

# ---------------------------------------------------------------------------
# TLS-interception UPSTREAM trust (corporate MITM proxy, e.g. Zscaler)
# ---------------------------------------------------------------------------
# SCOPE: this block is defense-in-depth for the case where a corporate
# TLS-intercepting proxy GENUINELY TERMINATES an outbound endpoint (presents its
# own corporate-signed leaf). It is NOT a cure-all for "the guest can't reach the
# network"; see docs/KNOWN_FAILURE_MODES.md §30, which separates that broad-egress
# failure (stale msb state; fixed by a data wipe + reinstall) and the USAi
# split-horizon DNS failure (needs a resolver that can see the internal zone) from
# this genuine-interception case.
#
# acq enables msb `--tls-intercept` so msb can substitute injected secrets on the
# wire (see the --tls-intercept block in acq_backend_provision). That runs a
# HOST-SIDE TLS proxy which re-originates an outbound TLS connection to the real
# server. Behind a terminating corporate proxy that "real server" is the proxy
# itself, presenting a corporate-signed leaf, so msb's proxy must trust the
# CORPORATE ROOT on its UPSTREAM leg.
#
# msb verifies that upstream leg against the host's native trust store. Crucially,
# `--trust-host-cas` does NOT help here — it only ships host CAs into the GUEST,
# not into the proxy's upstream verifier. When the host's native-cert enumeration
# does not surface the corporate root (uneven on macOS: it depends on which
# keychain / trust-settings domain the root lives in), the upstream handshake
# fails AFTER the guest-facing TLS already completed, and the guest client sees
# `curl: (56) … unexpected eof` for every terminated host — not a 401.
#
# FIX: pass the corporate root explicitly to msb's UPSTREAM verifier via
# `--tls-upstream-ca-cert <PEM>` (msb ADDS it to the native roots; the flag is
# repeatable / a file may bundle multiple certs). Two ways to supply it:
#
#   1. ACQ_MSB_UPSTREAM_CA_CERT — explicit path(s) to PEM file(s) (colon- or
#      space-separated). Highest precedence; passed through verbatim. Use this
#      when you already have the corporate root on disk, or on non-macOS hosts.
#
#   2. Auto-detect (macOS default, on). When no explicit path is set, acq exports
#      the host's search-list root CAs to a PEM under its state dir and passes
#      THAT. This captures the corporate root exactly as the host trusts it,
#      sidestepping the native-cert loader's keychain/trust-settings gaps. Toggle
#      off with ACQ_MSB_UPSTREAM_CA_AUTODETECT=0.
#
# Normalized like the other on/off toggles. Auto-detect only runs on macOS (it
# uses the `security` tool); elsewhere it is a no-op and only the explicit path
# (option 1) applies.
ACQ_MSB_UPSTREAM_CA_CERT="${ACQ_MSB_UPSTREAM_CA_CERT:-}"
ACQ_MSB_UPSTREAM_CA_AUTODETECT="${ACQ_MSB_UPSTREAM_CA_AUTODETECT-1}"
case "$(printf '%s' "$ACQ_MSB_UPSTREAM_CA_AUTODETECT" | tr '[:upper:]' '[:lower:]')" in
  ""|0|false|no|off) ACQ_MSB_UPSTREAM_CA_AUTODETECT="" ;;
  *)                 ACQ_MSB_UPSTREAM_CA_AUTODETECT="1" ;;
esac

# Where the auto-detected host CA bundle is written for the upstream verifier.
ACQ_MSB_UPSTREAM_CA_FILE="${ACQ_MSB_UPSTREAM_CA_FILE:-${ACQ_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/acq}/msb/host-upstream-cas.pem}"

# REPRODUCTION / TESTING toggle. A host whose corporate proxy does NOT intercept
# api.gsa.usai.gov / github.com (e.g. those domains are on a proxy bypass list)
# cannot locally reproduce the upstream-trust failure, because the msb proxy talks
# straight to the real endpoints. Setting ACQ_MSB_NO_UPSTREAM_CA=1 SUPPRESSES the
# fix (emits no --tls-upstream-ca-cert even when one is available), so the sandbox
# behaves as an environment where native-cert loading misses the corporate root.
# Use it to confirm the failure and that the fix resolves it. Off by default.
ACQ_MSB_NO_UPSTREAM_CA="${ACQ_MSB_NO_UPSTREAM_CA:-}"

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
# Balanced egress baseline (ADR-0018)
# ---------------------------------------------------------------------------
# msb defaults guest egress to NONE, so without a baseline an msb sandbox is far
# more locked down than an sbx one (whose "balanced" policy allows a broad set of
# dev hosts: AI services, package registries, code/container hosts, cloud infra,
# OS packages, cert-validation hosts). To reach parity, acq applies the SAME host
# set as the sbx "balanced" policy by default: it emits `--net-default-egress deny`
# plus an `allow@<host>:tcp:<port>` rule per entry in the vendored host list, on top
# of the kits' own caps.network.allow. Egress is therefore restricted TO the balanced
# set (deny-by-default + allowlist), matching sbx "balanced". The deny-default is
# scoped to EGRESS only (ADR-0019): ingress keeps msb's baseline `allow` so
# create-time `-p HOST:GUEST` published ports stay reachable (a symmetric
# `--net-default deny` would RST inbound to them).
#
# Network egress posture is selected by the NEUTRAL tier vocabulary
# `ACQ_NETWORK_TIER` (strict|balanced|open, default balanced), which the patterns
# network-tiers contract (agentic-coding-patterns ADR-0002) defines for all
# backends. This adapter maps the tier to msb's native egress primitive at
# provision time (see acq_backend_provision):
#
#   strict   = deny-by-default egress, kit caps.network.allow ONLY (no baseline).
#              The most locked-down posture; recommended for GFE / high-assurance.
#   balanced = deny-by-default egress + the curated baseline (the sbx "balanced"
#              mirror in msb-balanced-hosts.txt, ADR-0018) UNIONED with the kits'
#              own allow rules. The default when unspecified.
#   open     = unrestricted egress (no deny-default). Testing only, never GFE;
#              gated behind an explicit confirmation (see ACQ_NETWORK_TIER below).
#
# ALL tiers keep deny-by-default EXCEPT open; the tier only sizes the baseline
# allowlist. This normalizes to a lowercase enum, fail-closed to `balanced` on an
# invalid value (matching ACQ_MSB_SHORT_NAME_MODE's validator).
#
# DEPRECATED ALIAS — `ACQ_MSB_BALANCED_EGRESS` predates the neutral tier and is
# retained for one deprecation window. It maps into the tier fail-safe (tighter,
# never looser): a "1"/on value -> `balanced`; a "0"/off/empty value -> `strict`
# (NOT the old permissive no-deny-default behavior — an upgrade must never
# silently loosen egress). `ACQ_NETWORK_TIER` wins when both are set. A one-time
# notice points the user at the neutral selector. The alias is removed in a
# future major (the msb-emitter rename is tracked separately).
_acq_msb_balanced_egress_alias=""    # "" = unset, "balanced"/"strict" once resolved
if [ "${ACQ_MSB_BALANCED_EGRESS+set}" = set ]; then
  case "$(printf '%s' "$ACQ_MSB_BALANCED_EGRESS" | tr '[:upper:]' '[:lower:]')" in
    ""|0|false|no|off) _acq_msb_balanced_egress_alias="strict" ;;
    *)                 _acq_msb_balanced_egress_alias="balanced" ;;
  esac
fi

if [ -n "${ACQ_NETWORK_TIER+set}" ] && [ -n "$ACQ_NETWORK_TIER" ]; then
  # Neutral selector present and non-empty: it wins outright.
  _acq_net_tier_source="$ACQ_NETWORK_TIER"
elif [ -n "$_acq_msb_balanced_egress_alias" ]; then
  # Only the deprecated alias is set: honor it (fail-safe mapping above) and warn
  # once. Kept a plain guarded stderr note (no reusable warn-once helper exists).
  _acq_net_tier_source="$_acq_msb_balanced_egress_alias"
  if [ -z "${_ACQ_NETWORK_TIER_ALIAS_WARNED:-}" ]; then
    printf 'acq(msb): notice: ACQ_MSB_BALANCED_EGRESS is deprecated; use ACQ_NETWORK_TIER (strict|balanced|open).\n' >&2
    printf 'acq(msb):   mapped ACQ_MSB_BALANCED_EGRESS=%s -> ACQ_NETWORK_TIER=%s. A former "off" now means strict\n' "$ACQ_MSB_BALANCED_EGRESS" "$_acq_msb_balanced_egress_alias" >&2
    printf 'acq(msb):   (deny-by-default, kit hosts only) — set ACQ_NETWORK_TIER=open if you truly need unrestricted egress.\n' >&2
    _ACQ_NETWORK_TIER_ALIAS_WARNED=1
  fi
else
  _acq_net_tier_source="balanced"
fi

ACQ_NETWORK_TIER="$(printf '%s' "$_acq_net_tier_source" | tr '[:upper:]' '[:lower:]')"
case "$ACQ_NETWORK_TIER" in
  strict|balanced|open) ;;
  *)
    printf 'acq(msb): WARNING: invalid ACQ_NETWORK_TIER=%s (expected strict|balanced|open); falling back to balanced\n' "$_acq_net_tier_source" >&2
    ACQ_NETWORK_TIER="balanced"
    ;;
esac
unset _acq_net_tier_source _acq_msb_balanced_egress_alias

# The `open` tier disables deny-by-default egress entirely — an explicit,
# audited escape hatch, never a default and never appropriate for GFE. It is
# gated like `--privileged`: it requires an explicit confirmation token
# (ACQ_NETWORK_TIER_CONFIRM_OPEN=1) or acq fails closed at provision time. This
# is validated in acq_backend_provision (not here) so a stale env var that is
# never used to provision cannot abort an unrelated acq invocation.
ACQ_NETWORK_TIER_CONFIRM_OPEN="${ACQ_NETWORK_TIER_CONFIRM_OPEN:-}"

# ---------------------------------------------------------------------------
# OCI container engine (podman) — ensure agents can run OCI images (ADR-0020)
# ---------------------------------------------------------------------------
# Agents frequently need to run OCI images inside the sandbox (e.g. `docker run`,
# bringing up a docker-compose.yaml). The default image ships the Docker CLI +
# compose plugin, but msb's microVM init (/init.krun) never starts dockerd, so
# the Docker socket is dead; and dockerd's overlay2 storage driver cannot sit on
# the sandbox's already-overlay root without a disk-backed data volume. Rather
# than retrofit the msb docker:dind entrypoint recipe (a daemon we would have to
# start and keep alive across restarts, plus a per-sandbox disk-backed volume),
# the adapter provisions **podman** — a daemonless engine that forks runc/crun
# per invocation (no socket, no restart lifecycle), uses fuse-overlayfs on the
# overlay root (no disk-backed volume), and needs no nested virtualization. We
# run podman ROOTLESS as the agent user: the install step installs the rootless
# prerequisites (uidmap for newuidmap/newgidmap, passt + slirp4netns for rootless
# networking) from the same mirror in the same step as podman itself, and grants
# the agent access to /dev/net/tun (group-scoped) so rootless networking can set
# up. Rootless keeps containers unprivileged (defense-in-depth), aligns container/
# host UIDs, and lets the agent invoke podman directly (no sudo wrapper). See
# ADR-0020 and _acq_msb_ensure_oci.
#
# podman is CLI-compatible with docker for the run/build/compose workflows this
# targets, and the bundled Docker CLI is non-functional here anyway (dead
# socket), so we alias `docker` -> podman (in /usr/local/bin, ahead of /usr/bin)
# so both `docker run …` and `docker compose …` route to podman. `docker compose`
# resolves to `podman compose`, which drives the installed podman-compose
# provider — this is what makes docker-compose.yaml files usable (the standalone
# `docker-compose` CLI is deprecated in favour of the `docker compose`
# subcommand, so we do not provide a separate `docker-compose` binary).
#
# We also make unadorned image names resolve to Docker Hub by default (stock
# podman sends many short names to quay.io and has no default search registry),
# to reduce migration burden for users whose code assumes `docker run <name>`
# means Docker Hub. See _acq_msb_ensure_oci step 4 and ADR-0020.
#
# Toggle: on by default. Set ACQ_MSB_ENSURE_OCI=0 (or empty) to skip the step
# entirely (e.g. a base image that bakes its own working engine, or a lean
# sandbox that needs no OCI support). Normalized to exactly "1" (on) or "" (off):
# an unset value defaults on; "0"/"false"/"no"/"off"/empty are off
# (case-insensitive); anything else is on.
ACQ_MSB_ENSURE_OCI="${ACQ_MSB_ENSURE_OCI-1}"
case "$(printf '%s' "$ACQ_MSB_ENSURE_OCI" | tr '[:upper:]' '[:lower:]')" in
  ""|0|false|no|off) ACQ_MSB_ENSURE_OCI="" ;;
  *)                 ACQ_MSB_ENSURE_OCI="1" ;;
esac

# The packages installed to provide the OCI engine (space-separated). Override
# for a different set or an internal mirror's package names. podman-compose is
# the `docker compose` / `podman compose` provider. fuse-overlayfs lets podman
# use the `overlay` graph driver on msb's overlay ROOT filesystem (the kernel
# `overlay` driver refuses to stack on overlayfs); without it the adapter falls
# back to the `vfs` driver, which works everywhere but is disk-heavy. uidmap
# (newuidmap/newgidmap), passt, and slirp4netns are the ROOTLESS prerequisites:
# uidmap provides the setuid helpers rootless podman needs to map the subuid/
# subgid ranges (already present for `agent`), and passt/slirp4netns provide
# rootless container networking. See ADR-0020 and _acq_msb_ensure_oci. The install
# uses the OS package mirror (apt/dnf/apk), which under the default balanced egress
# baseline (ADR-0018) is already reachable (archive.ubuntu.com / ports.ubuntu.com
# / security.ubuntu.com / *.debian.org are in the vendored host list). With
# ACQ_NETWORK_TIER=strict (kit hosts only), or a base whose egress is otherwise
# narrowed, the mirror is unreachable and the install fails soft (a clear warning;
# provision continues; OCI is simply unavailable).
ACQ_MSB_PODMAN_PKGS="${ACQ_MSB_PODMAN_PKGS:-podman podman-compose fuse-overlayfs uidmap passt slirp4netns}"

# podman short-name resolution mode written into the docker-first registries
# drop-in (/etc/containers/registries.conf.d/00-acq-docker-first.conf). This
# governs what happens when the agent runs an UNQUALIFIED image name (e.g.
# `docker run nginx`) that is not already fully qualified to a registry.
#
# DEFAULT: "enforcing" (least-privilege / prompt-injection defense). Per the
# PR #302 review (3-model consensus + reviewer), "permissive" is the WRONG
# default for a federal sandbox running a prompt-injectable agent: it silently
# resolves ambiguous short names, which removes the defense against image
# substitution / typosquatting (an injected `docker run nginx` could resolve to
# docker.io/<attacker>/nginx without any prompt). We KEEP
# unqualified-search-registries = ["docker.io"] below, so unqualified names
# still resolve deterministically to Docker Hub and migration ergonomics are
# preserved; "enforcing" only fails closed on interactively-ambiguous short
# names instead of silently resolving them. Because there is a single search
# registry, "enforcing" costs essentially no day-to-day ergonomics.
#
# Setting ACQ_MSB_SHORT_NAME_MODE=permissive is an EXPLICIT operator override
# that REMOVES the typosquatting / image-substitution guardrail. Only podman's
# accepted values are allowed: enforcing | permissive | disabled. Any other
# value (including empty) is rejected and falls back to "enforcing"
# (fail-closed), with a warning.
ACQ_MSB_SHORT_NAME_MODE="${ACQ_MSB_SHORT_NAME_MODE:-enforcing}"
_acq_msb_short_name_mode_lc="$(printf '%s' "$ACQ_MSB_SHORT_NAME_MODE" | tr '[:upper:]' '[:lower:]')"
case "$_acq_msb_short_name_mode_lc" in
  enforcing|permissive|disabled) ACQ_MSB_SHORT_NAME_MODE="$_acq_msb_short_name_mode_lc" ;;
  *)
    printf 'msb: WARNING: invalid ACQ_MSB_SHORT_NAME_MODE=%s (expected enforcing|permissive|disabled); falling back to enforcing\n' "$ACQ_MSB_SHORT_NAME_MODE" >&2
    ACQ_MSB_SHORT_NAME_MODE="enforcing"
    ;;
esac
unset _acq_msb_short_name_mode_lc

# Path to the vendored host list (a verbatim mirror of `sbx policy inspect
# local-policy`; see acq.backends/msb-balanced-hosts.txt). Override to point at a
# site-specific list. ACQ_SCRIPT_DIR is exported by the acq entry point (and set
# by the offline test harness before this adapter is sourced).
ACQ_MSB_BALANCED_HOSTS_FILE="${ACQ_MSB_BALANCED_HOSTS_FILE:-${ACQ_SCRIPT_DIR:-.}/acq.backends/msb-balanced-hosts.txt}"

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
ACQ_MSB_CLONES_DIR="${ACQ_MSB_CLONES_DIR:-${ACQ_STATE_DIR}/clones}"
# Create-time startup-script staging state (ADR-0017). The staged host file list
# is reset per provision; declare it at module scope so cleanup references are
# always defined even if provision is not the entry point.
_ACQ_MSB_STARTUP_STAGE_FILES=()
_ACQ_MSB_STARTUP_STAGED=""
# SSH user for the serve listener. `msb ssh serve` authorizes a key host-wide;
# the login user on the loopback listener defaults to root (override if a
# deployment's msb serve expects a different account).
ACQ_MSB_SSH_USER="${ACQ_MSB_SSH_USER:-root}"

# ---------------------------------------------------------------------------
# Host ssh-agent / socket forwarding over msb --vsock (ADR-0021)
# ---------------------------------------------------------------------------
# msb >= 0.6.9 exposes a HOST unix socket at guest AF_VSOCK CID 2:PORT via a
# create-time `--vsock HOST_PATH:PORT[/stream|/dgram]` flag. git/ssh in the guest
# speak a unix socket path (SSH_AUTH_SOCK), not vsock, so an in-guest socat
# bridge translates the vsock route back to a unix socket. See ADR-0021.
#
# Fixed guest vsock port for the ssh-agent route (avoids msb's reserved 123).
# SINGLE SOURCE OF TRUTH for the port: the neutral helper in common.sh emits the
# --vsock route on this port and the in-guest socat bridge connects to it, so
# they must never diverge. If a user overrides ACQ_SSH_AGENT_VSOCK_PORT (the
# neutral name common.sh reads), honor it here too so the route and the bridge
# stay in lockstep; otherwise both default to 3552.
ACQ_MSB_SSH_AGENT_VSOCK_PORT="${ACQ_MSB_SSH_AGENT_VSOCK_PORT:-${ACQ_SSH_AGENT_VSOCK_PORT:-3552}}"
# Where SSH_AUTH_SOCK points inside the guest — the unix socket the socat bridge
# listens on and forwards to the host agent over vsock.
ACQ_MSB_SSH_AGENT_GUEST_SOCK="${ACQ_MSB_SSH_AGENT_GUEST_SOCK:-/home/agent/.acq/ssh-agent.sock}"
# Defense-in-depth: the guest sock path is interpolated into a root/agent `sh -c`
# string when starting the socat bridge and writing the marker. It is acq's own
# constant, but a user MAY override it — reject anything but an absolute path in a
# word-safe charset so a stray quote/space can never break out of the `sh -c`.
# Validate the WHOLE string with a negated character class (a `/[chars]*` glob
# would only check the second character), and require a leading slash.
case "$ACQ_MSB_SSH_AGENT_GUEST_SOCK" in
  /*) : ;;  # must be absolute
  *)
    echo "acq(msb): warning: ignoring non-absolute ACQ_MSB_SSH_AGENT_GUEST_SOCK='$ACQ_MSB_SSH_AGENT_GUEST_SOCK'; using default." >&2
    ACQ_MSB_SSH_AGENT_GUEST_SOCK="/home/agent/.acq/ssh-agent.sock"
    ;;
esac
case "$ACQ_MSB_SSH_AGENT_GUEST_SOCK" in
  *[!A-Za-z0-9._/-]*)
    echo "acq(msb): warning: ignoring unsafe ACQ_MSB_SSH_AGENT_GUEST_SOCK='$ACQ_MSB_SSH_AGENT_GUEST_SOCK'; using default." >&2
    ACQ_MSB_SSH_AGENT_GUEST_SOCK="/home/agent/.acq/ssh-agent.sock"
    ;;
esac
# The ssh-agent forward feature needs msb >= 0.6.9 (first release with --vsock).
# The global MIN_MSB_VERSION floor stays 0.6.8; this gates ONLY the forward.
MIN_MSB_VSOCK_VERSION="0.6.9"
# Share the ssh-agent guest port with common.sh's neutral helper so both sides
# agree on the port (the helper emits it, this adapter translates it). This is
# the SAME value as ACQ_MSB_SSH_AGENT_VSOCK_PORT above by construction, so the
# published --vsock route and the socat bridge's VSOCK-CONNECT target match.
ACQ_SSH_AGENT_VSOCK_PORT="${ACQ_SSH_AGENT_VSOCK_PORT:-$ACQ_MSB_SSH_AGENT_VSOCK_PORT}"
# Module-scope flag: set to 1 during provision when an ssh-agent forward is
# emitted, so provision knows to start the bridge and record the marker. Reset
# per provision. acq_backend_start reads the persisted marker instead.
_ACQ_MSB_SSH_AGENT_FORWARDING=0
# Module-scope flag: set to 1 once the ssh-agent trust-boundary notice has been
# printed, so the "forwarding host ssh-agent" notice appears at most once per
# process even if the vsock-flag helper runs more than once. See ADR-0021.
_ACQ_MSB_SSH_AGENT_NOTICE_SHOWN=0

# Module-level monotonic counter for ephemeral serve-port selection. The call
# site is `sport=$(_acq_msb_pick_ephemeral_port)` — a COMMAND SUBSTITUTION, which
# runs in a subshell, so a plain shell variable incremented inside the helper
# would never persist back to the caller (every publish would recompute the same
# value — exactly the bug this avoids). The counter is therefore persisted in a small
# file under the ports state dir so consecutive publishes in one process read
# distinct, increasing values. Seeded from a per-process random base.
_ACQ_MSB_PORT_SEQ_FILE="${ACQ_MSB_PORTS_DIR}/.port-seq"

# Per-process random base offset for ephemeral serve-port selection, evaluated
# ONCE when this file is sourced (not per call). Spreads different processes
# across the range while the persisted per-call counter provides distinct
# offsets WITHIN a process. $$, $RANDOM (bash; empty under POSIX sh,
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
  # Run the readiness check FOR the user (so the happy path needs no manual `msb
  # doctor` step and shows nothing). Only speak up when the host is NOT ready:
  # try an automatic `msb doctor --fix`, re-check, and — if still unfit — surface
  # an actionable message with where to get help. Do not hard-fail here:
  # provision fails closed with msb's own error if the host is truly unusable,
  # and ACQ_SKIP_MSB_DOCTOR=1 opts out entirely (e.g. an environment where the
  # check is unreliable). The check itself is best-effort (any error running it
  # is treated as "cannot determine" and stays silent).
  [ -n "${ACQ_SKIP_MSB_DOCTOR:-}" ] && return 0
  command -v msb >/dev/null 2>&1 || return 0
  # All `msb doctor` invocations redirect stdin from /dev/null (file convention):
  # `msb doctor --fix` may prompt, and acq holds stdin open, so an un-redirected
  # call would hang indefinitely on the exact unfit-host path this targets.
  if msb doctor </dev/null >/dev/null 2>&1; then
    return 0
  fi
  # Not ready — attempt the fix automatically, then re-check. `msb doctor --fix`
  # MUTATES host state (kvm group, device permissions), so announce it on stderr
  # BEFORE running rather than mutating silently (AGENTS.md classifies infra
  # changes as approval-worthy; ACQ_SKIP_MSB_DOCTOR=1 opts out entirely).
  echo "acq: host not ready for microVMs — running 'msb doctor --fix' to set it up" >&2
  echo "      (set ACQ_SKIP_MSB_DOCTOR=1 to skip this and fix it yourself)." >&2
  msb doctor --fix </dev/null >/dev/null 2>&1 || true
  if msb doctor </dev/null >/dev/null 2>&1; then
    acq_debug "msb doctor: host ready after --fix"
    return 0
  fi
  echo "acq: your machine isn't ready to run microVMs yet." >&2
  echo "      msb needs host virtualization (KVM on Linux, Apple Silicon's" >&2
  echo "      hypervisor on macOS, or the Windows Hypervisor Platform on Windows)." >&2
  echo "      acq tried 'msb doctor --fix' automatically but the host is still not" >&2
  echo "      ready. For details run 'msb doctor', see docs/howto/acq.md#msb-host-setup," >&2
  echo "      or ask us for help at agentic-coding@gsa.gov." >&2
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
# _acq_msb_is_running NAME — 0 if the named sandbox is currently RUNNING, else 1
# ---------------------------------------------------------------------------
# `msb list --running -q` prints one RUNNING sandbox name per line (the `-q`
# name-only contract from acq_backend_exists, plus the `--running` filter
# documented at the top of this file: `msb list|ls [-q] [--running]`). A sandbox
# that exists (acq_backend_exists) but is absent from the running list is stopped.
# We reuse the SAME `msb list -q` line-match pattern acq_backend_exists uses (no
# new probe shape is invented — only the `--running` filter is added), so the
# stopped-state detection tracks the established inspection convention.
# NOTE: like acq_backend_exists, the `--running` column contract is from the CLI
# help and is not live-verified against a running daemon; if the layout differs on
# a real host, adjust here and in acq_backend_exists together.
_acq_msb_is_running() {
  msb list --running -q 2>/dev/null | grep -Fxq -- "$1"
}

# ---------------------------------------------------------------------------
# _acq_msb_bind_one ARRVAR NAMESVAR SVC NAME ENV HOST — resolve one service's
# secret value (acq store, scoped→global) and, if found, export it into the ENV
# host var (transient) + collect a `--secret ENV@HOST` flag. Returns 0 if a
# store value was bound, 1 otherwise (so the caller can try an env fallback).
# The real value moves via a TRANSIENT exported env var, never argv.
_acq_msb_bind_one() {
  local _arrn="$1" _namesn="$2" _svc="$3" _name="$4" _env="$5" _host="$6" _val
  _val=$(acq_secret_resolve "$_svc" "$_name" 2>/dev/null) && [ -n "$_val" ] || return 1
  # shellcheck disable=SC2163  # dynamic export of the resolved binding env var
  export "$_env=$_val"; _val=""
  eval "$_namesn+=(\"\$_env\")"
  eval "$_arrn+=(--secret \"\${_env}@\${_host}\")"
  acq_debug "msb secret: binding ${_env}@${_host} for '$_svc' (from acq store)"
  return 0
}

# _acq_msb_bind_secrets_into ARRVAR NAMESVAR NAME — resolve + export the secret
# values a sandbox needs, and collect the matching `--secret ENV@HOST` flags.
# ---------------------------------------------------------------------------
# Single source of truth for WHICH secrets a sandbox binds and HOW their real
# values reach the msb child process. Both `msb create` (provision) and
# `msb start` (resume) read each bound secret's value from a HOST environment
# variable named in the persisted `--secret ENV@HOST` binding; msb never keeps
# the value, so the value must be present in the environment at BOTH create and
# every start. Provision used to inline this; resume (acq_backend_start) omitted
# it entirely, which made `msb start` fail with "host environment variable
# USAI_API_KEY is not set". Factoring it here guarantees start binds the
# identical set create did.
#
# The caller passes the NAMES of two arrays by reference: ARRVAR receives the
# `--secret ENV@HOST` flag tokens (for create; start ignores them since msb
# already persisted the bindings), and NAMESVAR receives the exported env-var
# names so the caller can unset them after the msb child has read them. The real
# value moves via a TRANSIENT exported env var (never argv, never the kit spec),
# exactly as before.
#
# SCOPE: usai (always, if a value resolves or is pre-exported), github
# (conditionally), and any generic custom endpoint recorded via
# `acq secret set SVC --host H --env E` (enumerated from the non-secret sidecar).
# This mirrors the SCOPE notes at the top of this file; see also
# _acq_msb_service_binding and _acq_msb_bind_one (the per-service primitive).
_acq_msb_bind_secrets_into() {
  local _arrn="$1" _namesn="$2" _name="$3"

  if command -v acq_secret_resolve >/dev/null 2>&1; then
    # usai/github hosts resolve through the SAME binding table set/rm/refeed use
    # (_acq_msb_service_binding), so a `--host` sidecar recorded at `acq secret
    # set` overrides the compiled-in endpoint here too (#384) instead of being
    # written-but-ignored at provision.
    local _usai_binding _usai_env _usai_host
    _usai_binding=$(_acq_msb_service_binding usai "$_name")
    _usai_env=$(printf '%s' "$_usai_binding" | cut -f1)
    _usai_host=$(printf '%s' "$_usai_binding" | cut -f2)

    # USAi: acq store first, else a pre-exported USAI_API_KEY (e.g. CI).
    if ! _acq_msb_bind_one "$_arrn" "$_namesn" usai "$_name" "$_usai_env" "$_usai_host"; then
      if [ -n "${USAI_API_KEY:-}" ]; then
        eval "$_arrn+=(--secret \"\${_usai_env}@\${_usai_host}\")"
        acq_debug "msb secret: binding ${_usai_env}@${_usai_host} (from env)"
      fi
    fi

    # GitHub: bind the token to the API and git-transport hosts. acq store first,
    # then a pre-exported GITHUB_TOKEN, then GH_TOKEN (CI). Absent token => no
    # binding; the playbook kit then degrades gracefully (warns, no rules/skills).
    local _gh_binding _gh_env _gh_host
    _gh_binding=$(_acq_msb_service_binding github "$_name")
    _gh_env=$(printf '%s' "$_gh_binding" | cut -f1)
    _gh_host=$(printf '%s' "$_gh_binding" | cut -f2)
    if ! _acq_msb_bind_one "$_arrn" "$_namesn" github "$_name" "$_gh_env" "$_gh_host"; then
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        eval "$_arrn+=(--secret \"\${_gh_env}@\${_gh_host}\")"
        acq_debug "msb secret: binding ${_gh_env}@${_gh_host} (from env)"
      elif [ -n "${GH_TOKEN:-}" ]; then
        export GITHUB_TOKEN="$GH_TOKEN"
        eval "$_namesn+=(\"GITHUB_TOKEN\")"
        eval "$_arrn+=(--secret \"\${_gh_env}@\${_gh_host}\")"
        acq_debug "msb secret: binding ${_gh_env}@${_gh_host} (from GH_TOKEN env)"
      fi
    fi

    # GENERIC custom endpoints. usai + github were bound explicitly above. Any
    # OTHER service stored via `acq secret set SVC --host H --env E` recorded a
    # non-secret (host, env) sidecar; bind each such service generically here so
    # it is no longer stored-but-inert. Iterate the endpoint sidecars for this
    # sandbox scope + global, deduping by env var (a scoped mapping shadows the
    # global; usai/github are skipped — already bound).
    if command -v acq_secret_meta_list >/dev/null 2>&1; then
      local _svc _binding _env _host _names_snapshot
      while IFS= read -r _svc; do
        [ -n "$_svc" ] || continue
        case "$_svc" in usai|github) continue ;; esac  # bound explicitly above
        _binding=$(_acq_msb_service_binding "$_svc" "$_name")
        _env=$(printf '%s' "$_binding" | cut -f1)
        _host=$(printf '%s' "$_binding" | cut -f2)
        [ -n "$_env" ] && [ -n "$_host" ] || continue
        # Skip if this env var was already collected (e.g. usai/github, or a dup).
        eval "_names_snapshot=\" \${${_namesn}[*]-} \""
        case "$_names_snapshot" in *" $_env "*) continue ;; esac
        _acq_msb_bind_one "$_arrn" "$_namesn" "$_svc" "$_name" "$_env" "$_host" || true
      done <<EOF
$(acq_secret_meta_list "$_name")
EOF
    fi
  elif [ -n "${USAI_API_KEY:-}" ]; then
    eval "$_arrn+=(--secret \"USAI_API_KEY@\${ACQ_MSB_USAI_HOST}\")"
  fi
}

# ---------------------------------------------------------------------------
# acq_backend_start NAME — start (resume) a stopped sandbox (ADR-0017)
# ---------------------------------------------------------------------------
# `msb start` resumes a stopped sandbox, preserving its persisted state
# (ACQ_BACKEND_CAN_RESUME=1). Microsandbox's `start_detached` replays only a
# persisted `runtime.entrypoint`/`runtime.cmd` on start — NOT a bare
# `--script-path`-registered script (source-verified; see ADR-0017 and
# _acq_msb_stage_startup_script). So starting alone does NOT deterministically
# bring kit `startup`/`background` services back up; that restoration is done by
# the acq `start`/`restart` verb re-driving acq_backend_ensure_kits_applied
# (which re-runs startup via the idempotent exec path). This function is the thin
# resume primitive; the dispatcher owns the heal that follows.
#
# PORT SYMMETRY: acq_backend_stop tears down post-hoc `msb ssh serve` + `ssh -L`
# port tunnels (ADR-0015) because a stopped guest can no longer serve them. There
# is NO matching re-establish primitive here: those tunnels are created on demand
# by `acq ports --publish` against a RUNNING sandbox and are not persisted, so a
# resumed sandbox simply has no post-hoc tunnels until the user re-publishes.
# (Create-time `-p HOST:GUEST` NAT mappings are part of the sandbox config and
# are restored by msb itself on start.) Left as a deliberate no-op with this note.
#
# READINESS (S1 fix): `msb start` returns as soon as the resume is registered,
# but the guest boots asynchronously — so the FIRST `msb exec` after a start can
# race the boot (same failure mode as post-create). We therefore BLOCK on
# _acq_msb_wait_for_exec_ready here so that EVERY caller (the acq start/restart
# verb, the start-if-stopped block inside acq_backend_ensure_kits_applied, and
# any future caller) gets a booted, exec-ready guest — the heal's first exec can
# never race the boot regardless of entry path. On the verb path,
# acq_backend_start runs BEFORE ensure_kits_applied's _acq_msb_is_running check;
# without a wait here that check would see the sandbox already running and skip
# its own readiness wait, letting the first heal exec race the boot. Encapsulating
# the wait in the resume primitive keeps the dispatcher backend-neutral (no
# msb-specific readiness logic leaks into acq). _acq_msb_wait_for_exec_ready is
# defined below in this file (single source, reused by the post-create and the
# start-if-stopped paths). The wait is best-effort: a timeout emits a warning
# rather than aborting, mirroring the start-if-stopped path.
#
# SECRETS (fix): `msb start` re-reads the sandbox's persisted `--secret ENV@HOST`
# bindings and REQUIRES each named value to be present in the host environment at
# start time — msb does not retain the value across a stop. Provision exported
# these before `msb create`; resume must do the SAME before `msb start`, or msb
# fails with "host environment variable USAI_API_KEY is not set". We re-derive
# the identical binding set from the acq store via _acq_msb_bind_secrets_into
# (shared with provision), export the values transiently, run `msb start`, then
# unset them so the values never linger. The collected --secret flags are unused
# here (msb already persisted the bindings at create); only the exported values
# matter for start.
acq_backend_start() {
  local _name="$1"
  local _start_secret_flags=() _start_secret_names=()
  _acq_msb_bind_secrets_into _start_secret_flags _start_secret_names "$_name"
  local _start_rc=0
  msb start "$_name" || _start_rc=$?
  # Clear the transient secret env vars immediately after `msb start` read them
  # (runs on both success and failure so no exported value lingers).
  local _sev
  for _sev in ${_start_secret_names[@]+"${_start_secret_names[@]}"}; do
    unset "$_sev"
  done
  [ "$_start_rc" -eq 0 ] || return "$_start_rc"
  _acq_msb_wait_for_exec_ready "$_name" || \
    echo "acq(msb): warning: $_name did not become exec-ready after start." >&2
  # Re-grant the rootless-podman device nodes (/dev/net/tun, /dev/fuse): /dev is a
  # devtmpfs re-created each boot, so the provision-time grant is lost across
  # restart. Cheap + idempotent; no-op when ENSURE_OCI is disabled or absent.
  _acq_msb_grant_oci_devs "$_name"
  # The host ssh-agent forward's --vsock route persists in the sandbox config
  # across stop/start, but the in-guest socat bridge process dies on stop, so it
  # must be (re)started here too. Gated on the persisted marker (no provision ran
  # this path, so _ACQ_MSB_SSH_AGENT_FORWARDING is not set). See ADR-0021.
  _acq_msb_start_ssh_agent_bridge "$_name"
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
# DESIGN NOTE — the staging boundary: create-time `--script-path` for the
# startup phase, `msb exec` for install and every mid-life apply (ADR-0017).
# ---------------------------------------------------------------------------
# msb 0.6.7 offers first-class script registration on `create`/`run`:
#   --script NAME=BODY        (inline; escape-decoded; shebang from --shell)
#   --script-raw NAME=BODY    (exact bytes, no shebang)
#   --script-path NAME:PATH   (body read verbatim from a host file)
# Registered scripts land executable at /.msb/scripts/<name>, on the guest PATH.
#
# An earlier revision of this adapter kept ALL kit-command staging on `msb exec`
# and treated `--script*` as net-negative, on the grounds that kit commands run
# both at create AND mid-life and that the exec path never interpolates kit
# bytes into a shell string. Both of those observations are still true — but they
# do NOT apply to one specific slice, and ADR-0017 carves that slice out:
#
#   THE ONE CLEAN WIN IS THE CREATE-TIME, RE-RUNNABLE STARTUP BODY.
#   A kit's `startup`-phase commands are re-run on EVERY apply (they carry no
#   run-once marker — unlike install), and they are exactly what a microsandbox-
#   native restart (`msb stop`+`msb start`, or a reboot that restarts the guest)
#   must replay to bring kit background supervisors back up. microsandbox can
#   replay them itself only if it holds them as a registered startup script. So
#   we now STAGE the startup phase as a single create-time script registered via
#   `--script-path` (see _acq_msb_stage_startup_script). That is a genuinely
#   create-time-only, re-runnable command body whose natural form is a script
#   file — the narrow case the older note itself named as the clean win, which
#   ADR-0017 confirms now exists in the pinned vocabulary (the `startup` phase).
#
#   WHY `--script-path` (not --script / --script-raw): the body is read VERBATIM
#   from a host file, so we never hand microsandbox a shell string assembled from
#   kit content, and we do not depend on shebang derivation from --shell — the
#   generated body carries its own `#!/bin/sh`. The generated file emits each kit
#   argv token single-quote-escaped (SI-10): kit bytes become quoted data inside
#   a here-shaped command line, never an interpolated program fragment.
#
# THE BOUNDARY — what stays on `msb exec`, and WHY it MUST:
#
#   1) INSTALL PHASE stays exec-based. install commands are run-once, gated by a
#      root-owned marker keyed on a hash of the argv
#      (_acq_msb_exec_install: /var/lib/acq/install-<cksum>), tested+written as
#      uid 0 so the gate is independent of the command's own user. A create-time
#      script re-runs on every restart by design — the OPPOSITE of run-once — so
#      folding install into the startup script would break its idempotency
#      contract. install therefore stays out of the staged script entirely.
#
#   2) MID-LIFE APPLY stays exec-based. _acq_msb_apply_kit_dir is also driven
#      long after create by acq_backend_apply_kit (`acq kit apply NAME KITREF`)
#      and by acq_backend_ensure_kits_applied (the re-attach heal loop). A
#      create-time flag cannot register a script into an ALREADY-RUNNING sandbox,
#      so the mid-life path MUST stay exec-based regardless. Create-time staging
#      owns the reboot/`msb start` replay path; exec owns the in-place kit-add /
#      heal path. They are complementary, not a fork: do not collapse one into
#      the other.
#
#   3) FILE STAGING IS ORTHOGONAL. files[] stage via `msb copy` + verify + chown
#      (_acq_msb_copy_file_verified); paths are charset-validated and never
#      interpolated. `--script-path` covers only the startup COMMAND body, not
#      files[], so it does not subsume that path.
#
# INCREMENT BOUNDARY (ADR-0017 delivers this in two steps). This adapter now
# implements BOTH the create-time startup-script staging AND the restart-durable
# behavior that consumes it:
#
#   * The acq `start`/`restart` verb calls acq_backend_start (`msb start`) then
#     re-drives acq_backend_ensure_kits_applied, which re-applies the pinned kits
#     idempotently and RE-RUNS the startup phase via `msb exec` — restoring kit
#     `startup`/`background` services on resume. A stopped sandbox is also started
#     automatically at the TOP of ensure_kits_applied, so `acq run
#     <stopped-sandbox>` heals then attaches. This is the deterministic path and
#     needs no native persistence.
#
# A native `msb start` OUTSIDE acq is intentionally NOT supported: microsandbox's
# start_detached replays only runtime.entrypoint/runtime.cmd (not the
# --script-path-registered script), AND — more fundamentally — `msb start`
# requires the sandbox's `--secret ENV@HOST` host env vars to be present, which
# only acq injects (see acq_backend_start). So a raw `msb start` of a
# secret-bound sandbox fails before any startup question arises. Always resume
# via `acq start`/`acq restart`.
#
# The `--script-path` registration itself is runtime-neutral: it only stages the
# body on the guest PATH (/.msb/scripts/acq-startup) so a kit author or the exec
# heal can invoke it by name; microsandbox does not auto-run it at start.
# install + mid-life apply stay exec-based.

# Fetch a kit ref into the cache and echo its local dir. Returns 1 on failure.
_acq_msb_fetch_kit() {
  local kitref="$1" slug dest
  # Offline/test escape hatch: when ACQ_MSB_KIT_LOCAL_DIR is set, resolve REMOTE
  # (git+) kit refs to that local directory instead of fetching. Mirrors the sbx
  # adapter's ACQ_SBX_KIT_PASSTHROUGH: it keeps the offline unit harness fully
  # network-free even when acq is invoked as a CHILD process (e.g. `acq start`),
  # where a test cannot shadow this function. LOCAL kit paths are still used
  # as-is (a test that passes an explicit local kit dir must get THAT dir), so
  # the hatch only diverts refs that would otherwise hit the network. Never set
  # in production — a real kit body is required there.
  if [ -n "${ACQ_MSB_KIT_LOCAL_DIR:-}" ]; then
    case "$kitref" in
      git+*|*://*) printf '%s\n' "$ACQ_MSB_KIT_LOCAL_DIR"; return 0 ;;
    esac
  fi
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

# _acq_msb_balanced_target HOST — echo the msb `--net-rule` TARGET for one sbx
# "balanced" host token, or nothing (rc 1) if it must be dropped. Translates the
# wildcard forms (ADR-0018):
#   - `**.h`  (sbx multi-label glob) -> msb suffix `*.h` (apex + any depth)
#   - `crl*.h` (intra-label glob msb can't express) -> broadened to `*.<parent>`;
#     the CALLER emits the one-time widening warning (keyed off the `crl*.` input)
#   - anything else -> the host unchanged (exact domain)
# The result is charset-guarded ([A-Za-z0-9.*_-]) and single-label `*.` suffixes
# (which msb rejects for blast radius) are dropped, so the value is safe to place
# in an argv via the caller's eval-by-name append (SI-10).
_acq_msb_balanced_target() {
  local _host="$1" _target
  case "$_host" in
    "**."*)   _target="*.${_host#**.}" ;;
    "crl*."*) _target="*.${_host#crl*.}" ;;
    *)        _target="$_host" ;;
  esac

  # Charset-guard the FINAL target (defense-in-depth before any eval append).
  case "$_target" in
    ""|*[!A-Za-z0-9.*_-]*)
      echo "acq(msb): warning: skipping non-hostname balanced entry: ${_host}" >&2
      return 1
      ;;
  esac

  # Reject a single-label suffix (`*.com`): msb refuses it (accidental blast
  # radius), so drop it here rather than let `msb create` hard-fail on the set.
  case "$_target" in
    "*."*)
      case "${_target#*.}" in
        *.*) : ;;  # two+ labels after `*.` -> OK
        *)
          echo "acq(msb): warning: skipping single-label suffix (msb rejects it): ${_target}" >&2
          return 1
          ;;
      esac
      ;;
  esac

  printf '%s\n' "$_target"
}

# _acq_msb_balanced_port_ok PORT — 0 if PORT is a valid TCP port (integer
# 1..65535, no leading zero), else 1. An empty PORT means "any port" and is
# handled by the caller (not passed here). Guards a kit-derived value before it
# reaches an argv. Rejects a leading zero (e.g. `0443`) so a custom hosts file
# can't emit an octal-looking `:tcp:0443` token.
_acq_msb_balanced_port_ok() {
  case "$1" in
    ""|0*|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# _acq_msb_balanced_parse_line LINE HOSTVAR PORTVAR — strip a trailing comment,
# trim surrounding whitespace, and split the remaining `host[:port]` into the
# named HOSTVAR/PORTVAR (port empty when absent). Returns 1 (host set empty) for
# a blank/comment-only line so the caller can `continue`. Keeps the parse out of
# _acq_msb_balanced_rules_into so that stays under the 50-line limit.
_acq_msb_balanced_parse_line() {
  local _l="$1" _hn="$2" _pn="$3"
  _l="${_l%%#*}"                          # strip trailing comment
  _l="${_l#"${_l%%[![:space:]]*}"}"       # ltrim
  _l="${_l%"${_l##*[![:space:]]}"}"       # rtrim
  if [ -z "$_l" ]; then
    eval "$_hn=''"; eval "$_pn=''"
    return 1
  fi
  # Split host/port on the LAST colon (hosts have no other colon).
  case "$_l" in
    *:*) eval "$_pn=\"\${_l##*:}\""; eval "$_hn=\"\${_l%:*}\"" ;;
    *)   eval "$_hn=\"\$_l\""; eval "$_pn=''" ;;
  esac
  return 0
}

# _acq_msb_balanced_rules_into ARRVAR — append the sbx-"balanced" egress baseline
# (ADR-0018) as msb `--net-rule` tokens to the array named ARRVAR. Reads the
# vendored host list (ACQ_MSB_BALANCED_HOSTS_FILE, a verbatim mirror of `sbx
# policy inspect local-policy`) and translates each `host:port` line into a rule,
# per the msb grammar (`allow[:egress]@<target>[:<proto>[:<ports>]]`):
#   - PORT: trailing `:port` -> `:tcp:<port>` (sbx "balanced" is TCP; a host on
#     both :80 and :443 yields TWO rules, one per line, preserved).
#   - WILDCARD / intra-label glob: see _acq_msb_balanced_target.
#   - Also emits a gateway-DNS rule FIRST so the guest can resolve the allowed
#     hosts: under `--net-default-egress deny` the high-level DNS auto-grant does
#     not apply, so a low-level rule must grant it explicitly. We use msb's
#     semantic `allow@dns` macro, which acq can rely on because it requires
#     msb >= 0.6.9 (the upstream release-build parser fix). Pairs with
#     --dns-nameserver. (See the DNS block below and ADR-0018.)
# A missing/unreadable file is a non-fatal warning (kits still add their egress).
# Uses the eval-by-name array pattern (macOS bash 3.2 compat), like the siblings.
_acq_msb_balanced_rules_into() {
  local _arr="$1" _file="${ACQ_MSB_BALANCED_HOSTS_FILE}"
  eval "$_arr=()"

  if [ ! -r "$_file" ]; then
    echo "acq(msb): warning: balanced-egress host list not readable: ${_file}" >&2
    echo "acq(msb):   msb sandbox egress will be limited to the kits' own hosts." >&2
    return 0
  fi

  # DNS first: without it the guest cannot resolve any allowed host under
  # --net-default-egress deny, since the high-level gateway-DNS auto-grant only
  # fires for the `--net` PROFILES (public/private/host), not for a rule-only deny
  # default.
  #
  # We use msb's semantic `allow@dns` macro, which expands to the gateway `host`
  # group on port 53 for both UDP and TCP. This macro was broken on released msb
  # builds up to and including 0.6.8: its parser guarded the target token with a
  # `debug_assert_eq!` that is compiled OUT of release binaries, so the iterator
  # was never advanced past the `dns` target and the same token was re-read as the
  # protocol slot, hard-failing with `the dns target supports tcp, udp, or any,
  # not dns`. microsandbox 0.6.9 fixed this (the upstream release-build parser fix
  # now advances the target iterator before the assert), and acq requires
  # msb >= 0.6.9 (MIN_MSB_VERSION), so the macro is safe to use here. See ADR-0018.
  eval "$_arr+=(--net-rule \"allow@dns\")"

  local _line _host _port _target _warned_crl=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _acq_msb_balanced_parse_line "$_line" _host _port || continue

    # One-time widening warning for the intra-label glob (keyed off the input).
    case "$_host" in
      "crl*."*)
        if [ "$_warned_crl" -eq 0 ]; then
          echo "acq(msb): note: broadening 'crl*.' balanced entries to a parent domain" >&2
          echo "acq(msb):   suffix (msb has no intra-label glob; widens vs. sbx 'balanced')." >&2
          _warned_crl=1
        fi
        ;;
    esac

    _target=$(_acq_msb_balanced_target "$_host") || continue

    if [ -n "$_port" ]; then
      if ! _acq_msb_balanced_port_ok "$_port"; then
        echo "acq(msb): warning: skipping balanced entry with bad port: ${_line}" >&2
        continue
      fi
      eval "$_arr+=(--net-rule \"allow@\${_target}:tcp:\${_port}\")"
    else
      eval "$_arr+=(--net-rule \"allow@\${_target}\")"
    fi
  done < "$_file"
}

# Emit the create-time `-p HOST:GUEST` flags for a kit's published ports into the
# named array. Usage: _acq_msb_port_flags_into ARRVAR SPEC
#
# ADR-0014: kit_spec_published_ports reads the NEUTRAL top-level
# `publishedPorts` first (deprecated backend_extras.sbx fallback) and emits
# validated `guest<TAB>proto<TAB>name<TAB>host` records (ports are ints 1..65535,
# so they cannot smuggle shell metacharacters). host defaults to guest. We map
# each to a plain `-p HOST:GUEST` — msb's create/run-time NAT publish. msb -p also
# accepts BIND_ADDR:HOST:GUEST and /udp, but the neutral schema stays TCP +
# default loopback bind for sbx parity, so bind-addr and /udp are deliberately
# NOT emitted. Uses the eval-by-name array pattern (macOS bash 3.2 compat), like
# _acq_msb_net_rules_into. Absence of publishedPorts is a silent no-op: the
# neutral field is read DEFENSIVELY so a kit that omits it — or an older pinned
# kit predating the neutral schema — is a clean no-op rather than an error. The
# schema and a consuming kit are released at the current PATTERNS_KIT_REF, so the
# field lights up end-to-end (see ADR-0014).
_acq_msb_port_flags_into() {
  local _arr="$1" _spec="$2" _rec _guest _host
  eval "$_arr=()"
  # Parse fields with cut, NOT `IFS=<tab> read`: tab is IFS whitespace, so a
  # bare read COLLAPSES adjacent empty fields — an entry with guest + host but
  # no protocol/name ("3000<TAB><TAB><TAB>8080") would read the host column
  # into the protocol position and emit `-p 3000:3000` instead of `-p 8080:3000`
  # (same pitfall as the kit_spec_files consumer in _acq_msb_apply_kit_dir).
  while IFS= read -r _rec; do
    [ -n "$_rec" ] || continue
    _guest=$(printf '%s' "$_rec" | cut -f1)
    _host=$(printf '%s' "$_rec" | cut -f4)
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

# Emit create-time storage flags from `path<TAB>type<TAB>size` volume records
# on STDIN into the named array. Usage:
#   _acq_msb_volume_flags_from_records ARRVAR SANDBOX <<EOF ... records ... EOF
#
# ADR-0023: records come from kit_spec_volumes (path absolute + charset-safe,
# type ""|tmpfs, size byte-size grammar), UNIONED across kits by
# _acq_msb_volume_records_dedupe before reaching here. Mapping, mirroring the
# sbx kit-spec v2 §5.7 semantics:
#   block (type "")  -> --mount-named acq-<sandbox>-<pathslug>-<crc>:<path>:kind=disk,size=<size>
#   tmpfs            -> --tmpfs <path>:<size>
# The named volume is derived DETERMINISTICALLY from sandbox name + path slug +
# a POSIX-cksum CRC of the raw path, so acq_backend_terminate can find and
# remove it by prefix — msb named volumes otherwise persist independently under
# ~/.microsandbox/volumes/ and would silently accumulate (sbx kit volumes die
# with `sbx rm`; the derived name + terminate cleanup restores that lifecycle).
# The CRC is required for identity, not just readability: the slug is LOSSY
# (/data/app and /data.app both slug to data-app), so without it two distinct
# volumes could derive the same name and silently share one disk. --mount-named
# is create-or-reuse: a leftover same-name volume with incompatible settings
# fails the create loudly rather than silently changing the volume. Mounts land
# at boot, before any exec is possible — the same no-race-with-startup
# guarantee as sbx volumes. Like the sbx side, mounts land UNSEEDED (msb named
# volumes shadow image content at the path). Records are parsed with cut, not
# `IFS=<tab> read` (tab is IFS whitespace, so a bare read collapses the empty
# type field into size). Uses the eval-by-name array pattern (macOS bash 3.2
# compat), like _acq_msb_port_flags_into.
_acq_msb_volume_flags_from_records() {
  local _arr="$1" _name="$2" _rec _path _type _size _slug _ck
  eval "$_arr=()"
  while IFS= read -r _rec; do
    [ -n "$_rec" ] || continue
    _path=$(printf '%s' "$_rec" | cut -f1)
    _type=$(printf '%s' "$_rec" | cut -f2)
    _size=$(printf '%s' "$_rec" | cut -f3)
    [ -n "$_path" ] || continue
    # Defense-in-depth: the validator already guarantees an absolute path and
    # safe charsets, but re-check before the values reach an argv via eval.
    case "$_path" in
      /*) ;;
      *)
        echo "acq(msb): warning: skipping volume with non-absolute path: ${_path}" >&2
        continue
        ;;
    esac
    if printf '%s%s' "$_path" "$_size" | LC_ALL=C grep -q '[^A-Za-z0-9._/-]'; then
      echo "acq(msb): warning: skipping volume with unsafe path/size: ${_path}:${_size}" >&2
      continue
    fi
    if [ "$_type" = "tmpfs" ]; then
      eval "$_arr+=(--tmpfs \"\${_path}:\${_size}\")"
    else
      # Slug: strip the leading /, map everything outside [A-Za-z0-9] to '-',
      # squeeze runs (e.g. /var/lib/docker -> var-lib-docker); the CRC suffix
      # disambiguates paths the lossy slug would collapse together.
      _slug=$(printf '%s' "${_path#/}" | tr -c 'A-Za-z0-9' '-' | tr -s '-')
      _slug="${_slug%-}"
      _ck=$(printf '%s' "$_path" | cksum | cut -d' ' -f1)
      eval "$_arr+=(--mount-named \"acq-\${_name}-\${_slug}-\${_ck}:\${_path}:kind=disk,size=\${_size}\")"
    fi
  done
}

# Spec-based convenience wrapper: emit one kit's volume flags. Usage:
#   _acq_msb_volume_flags_into ARRVAR SPEC SANDBOX
# Provision does NOT use this — it unions records across ALL kits first (see
# _acq_msb_volume_records_dedupe) so same-path declarations cannot emit
# conflicting flags.
_acq_msb_volume_flags_into() {
  local _spec="$2"
  _acq_msb_volume_flags_from_records "$1" "$3" <<EOF
$(kit_spec_volumes "$_spec")
EOF
}

# Union volume records by path, LAST WINS — the same composition rule sbx
# applies to its own volumes (kit-spec v2 §5.7), so a kit combination that
# works on sbx works identically on msb instead of emitting two conflicting
# --mount-named flags for one path (create-or-reuse would fail the create on
# the size mismatch). stdin -> stdout; blank lines dropped; surviving records
# keep the position of their LAST occurrence.
_acq_msb_volume_records_dedupe() {
  awk -F'\t' '
    $1 != "" { recs[NR]=$0; last[$1]=NR }
    END { for (i=1;i<=NR;i++) if (i in recs) { split(recs[i],f,"\t"); if (last[f[1]]==i) print recs[i] } }
  '
}

# Remove the named volumes acq derived for SANDBOX's kit `volumes:` entries
# (acq-<sandbox>-<pathslug>, see _acq_msb_volume_flags_into). Best-effort and
# always returns 0: a host with no derived volumes is a quiet no-op. Volume
# names are read into an array FIRST — `msb volume rm` inside a piped while
# would drain the loop's stdin (the recorded loop-stdin-consumption pitfall).
# NOTE: prefix-matched, so a sandbox name that is itself a prefix of another
# sandbox's name + '-' (e.g. `web` vs `web-2`) could match the longer sandbox's
# volumes; accepted for now — see ADR-0023.
_acq_msb_remove_derived_volumes() {
  local _name="$1" _vol _vols=()
  while IFS= read -r _vol; do
    case "$_vol" in
      "acq-${_name}-"*) _vols+=("$_vol") ;;
    esac
  done <<EOF
$(msb volume ls -q 2>/dev/null)
EOF
  local _i
  for _i in ${_vols[@]+"${!_vols[@]}"}; do
    if msb volume rm "${_vols[$_i]}" >/dev/null 2>&1 </dev/null; then
      acq_debug "removed derived volume ${_vols[$_i]}"
    else
      echo "acq(msb): warning: could not remove derived volume: ${_vols[$_i]}" >&2
    fi
  done
  return 0
}

# Apply a single fetched kit directory to a running sandbox NAME.
# Honors backend_shortcuts.msb (currently: zscaler trust_host_cas, handled at
# provision time — see acq_backend_provision; here we skip the file/command
# path for a shortcut kit). Drops files and runs install/initFiles/startup
# commands via `msb exec`.
#
# RESOLVED (agentic-coding-playbook kit on msb): the playbook kit fetches private
# GitHub content via a pinned source tarball for reproducibility. Current msb
# also substitutes the GitHub token on the wire for the API and HTTPS
# git-transport hosts bound above, so direct HTTPS clone/push is eligible too.
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

  # 2) Persist environment[] for session replay. Threading `-e NAME=value` onto
  #    the kit's own commands (step 3) covers provisioning only; the block exists
  #    for agent-runtime config (see ADR-0011: OPENCODE_CONFIG-style vars), so
  #    the validated entries are also appended to a root-owned guest marker that
  #    run/attach/shell read back and replay as `-e` flags (same marker pattern
  #    as /var/lib/acq/agent and /var/lib/acq/ssh-auth-sock). Entries are passed
  #    as argv to a fixed `sh -c` body — kit bytes are never interpolated into
  #    shell syntax (SI-10).
  local _kit_env=()
  _acq_msb_collect_kit_env_into _kit_env "$spec"
  if [ "${#_kit_env[@]}" -gt 0 ]; then
    msb exec -u 0 "$name" -- sh -c \
      'mkdir -p /var/lib/acq && printf "%s\n" "$@" >> /var/lib/acq/kit-env' \
      sh "${_kit_env[@]}" </dev/null >/dev/null 2>&1 || \
      echo "acq(msb): warning: could not persist kit env for '$name'; its environment[] will not reach agent sessions" >&2
  fi

  # 3) Run commands[]. Reassemble each argv record and exec it as the given uid.
  #    install → run once (idempotent, marker-gated); initFiles/startup → every
  #    apply. msb has no create-time-only hook, so install collapses to a
  #    marker-gated exec (design §3 lifecycle table). The kit's environment[]
  #    entries are threaded onto every command as `msb exec -e NAME=value` (msb's
  #    native per-exec env flag), so the kit's declared guest env is present when
  #    its lifecycle commands run.
  _acq_msb_run_commands "$name" "$spec"
}

# _acq_msb_reset_kit_env NAME — remove the persisted kit-env marker so a
# FULL-set kit application (provision, heal) rebuilds it from the current kits'
# environment[] only. Without this, the per-kit append in _acq_msb_apply_kit_dir
# would retain entries a kit no longer declares — removed runtime config
# (feature toggles, host selectors) silently surviving every heal. The
# single-kit `acq kit apply` verb deliberately does NOT reset: a mid-life add
# is additive, and replay's last-value-wins handles its overrides. Best-effort:
# a failed reset degrades to the previous stale-retention behavior, never
# aborts the apply.
_acq_msb_reset_kit_env() {
  msb exec -u 0 "$1" -- sh -c 'rm -f /var/lib/acq/kit-env' \
    </dev/null >/dev/null 2>&1 || true
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
      # The parent chain was created as root above (mkdir -p as -u 0), so the
      # intermediate dirs this file introduced under the home (e.g. .local,
      # .local/bin for ~/.local/bin/opencode) are root-owned. A later kit
      # startup command runs AS THE AGENT USER and its `mkdir -p ~/.local/...`
      # then hits EACCES, killing a `set -eu` detached startup silently. Chown
      # the TOP-MOST created subdir under /home/agent recursively so the whole
      # chain (dirs + file) is agent-owned — not merely the leaf file. Do NOT
      # chown /home/agent itself (already agent-owned; recursing all of home
      # would stomp other kits' intentional root-owned drops). By NAME (agent),
      # never a numeric uid — the agent uid is provisioned, not necessarily 1000.
      local rel top
      rel=${path#/home/agent/}   # e.g. .local/bin/opencode  (or FILE if dropped in ~)
      top=${rel%%/*}             # e.g. .local               (or FILE)
      # top must be a real, non-traversing component. (The entry-point charset
      # check permits `.`, so `..` could slip through; guard it explicitly so we
      # never chown outside the home, e.g. /home/agent/.. == /home.)
      case "$top" in
        ''|.|..) : ;;
        *)
          # -P (no-dereference, the chown default but stated explicitly): never
          # follow a symlink a kit may have staged under the tree, so `chown -R`
          # cannot be redirected to chown files OUTSIDE /home/agent. Defense in
          # depth — the tree is inside the ephemeral guest and the top component
          # is already ../. guarded above.
          msb exec "$name" -u 0 -- chown -R -P agent "/home/agent/$top" >/dev/null 2>&1 || true
          ;;
      esac
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
  local _kit_env=()
  _acq_msb_collect_kit_env_into _kit_env "$spec"

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
  # contract). On a plain OCI base override uid 1000 may be a DIFFERENT user (e.g.
  # `node` in node:22-bookworm), so address our provisioned agent by NAME instead,
  # and set HOME=/home/agent so `$HOME`-relative kit logic resolves correctly.
  case "$_user" in
    ""|0|root)
      [ -n "$_user" ] && eval "$_uflag=(-u \"\$_user\")"
      ;;
    1000|agent)
      eval "$_uflag=(-u agent)"
      eval "$_eflag=(-e \"HOME=/home/agent\")"
      # When host ssh-agent forwarding is active, also point the agent user's
      # kit commands at the in-guest bridge socket. The git-ssh-sign kit resolves
      # the signing key via `ssh-add -L` in its initFiles/startup commands, which
      # need SSH_AUTH_SOCK to reach the forwarded agent. This is belt-and-
      # suspenders (git signing itself runs as a child of the attached agent
      # process, which already gets SSH_AUTH_SOCK via attach/run). See ADR-0021.
      if [ "${_ACQ_MSB_SSH_AGENT_FORWARDING:-0}" = "1" ]; then
        eval "$_eflag+=(-e \"SSH_AUTH_SOCK=\$ACQ_MSB_SSH_AGENT_GUEST_SOCK\")"
      fi
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
# Create-time startup-script staging (ADR-0017)
# ---------------------------------------------------------------------------
# These helpers GENERATE a single host-side `/bin/sh` script that reproduces the
# semantics the exec path applies to STARTUP-phase kit commands, and stage it as
# a `--script-path acq-startup:<hostpath>` create flag. See the DESIGN NOTE above
# for the boundary: only the `startup` phase is staged here; install and mid-life
# apply stay exec-based. A bare `--script-path` registration is runtime-neutral
# (staged on the guest PATH, not auto-run at boot); the acq `start`/`restart`
# verb re-runs startup via the exec heal.
#
# TRANSLATION from the exec path to an IN-GUEST script:
#   - The exec path picks run-as-user via `msb exec -u agent`/`-u <user>`. Inside
#     the guest the script cannot use `msb exec`, so it runs each command through
#     `su`/`runuser` (whichever exists) for the agent/uid-1000 case, and directly
#     for root. HOME=/home/agent is set for the agent case exactly as the exec
#     path sets `-e HOME=/home/agent`.
#   - The kit environment[] vars and the non-interactive git guards
#     (GIT_TERMINAL_PROMPT=0, GIT_ASKPASS/SSH_ASKPASS=/bin/false unless the kit
#     set GIT_TERMINAL_PROMPT) are emitted as an `env NAME=value …` prefix on the
#     command — the in-guest equivalent of the exec path's `-e` flags. The prefix
#     uses the portable, busybox-safe `env NAME=value … sh -c 'exec "$@"' sh ARGV`
#     form: NO `--` terminator (unsupported by busybox/alpine `env`); see
#     _acq_msb_startup_emit_command for the full rationale.
#   - A `background:true` startup command is detached with the SAME nohup wrapper
#     the exec path uses (`nohup … >/dev/null 2>&1 & exit-through`), so a
#     never-exiting supervisor does not block the script.
#
# SI-10 / ESCAPING: kit-provided argv tokens and env values are NEVER interpolated
# as shell fragments. Each argv token and each env value is single-quote-escaped
# by _acq_msb_sq (embedded single quotes become '\'' ) before it is written to
# the file, so kit bytes are emitted as inert quoted DATA, not executable syntax.
# The body is a FILE read verbatim by `--script-path`; acq never assembles a
# shell string from kit content and hands it to msb.

# _acq_msb_sq STRING — echo STRING single-quote-escaped for safe emission into a
# generated /bin/sh script line. Embedded single quotes become the classic
# '\'' close/escape/reopen sequence.
_acq_msb_sq() {
  local _s="$1" _q="'\\''"
  # Replace every ' with '\'' then wrap the whole thing in single quotes.
  printf "'%s'" "${_s//\'/$_q}"
}

# _acq_msb_startup_env_prefix_into PREFIX_ARRVAR USER KITENV_ARRVAR — build the
# in-guest `env NAME=value …` prefix tokens for one startup command: HOME for the
# agent user, the kit env vars, and the git non-interactive guards (unless the
# kit set GIT_TERMINAL_PROMPT). Mirrors _acq_msb_exec_flags_into's -e set, but as
# `env` argv rather than `msb exec -e`. Tokens are RAW here (NAME=value); the
# caller single-quote-escapes each before writing it to the script.
_acq_msb_startup_env_prefix_into() {
  local _prefixn="$1" _user="$2" _envarrn="$3"
  eval "$_prefixn=()"

  case "$_user" in
    1000|agent) eval "$_prefixn+=(\"HOME=/home/agent\")" ;;
  esac

  # Kit-declared env vars (already NAME-validated by kit_spec_env).
  local _ev
  eval "set -- \${${_envarrn}[@]+\"\${${_envarrn}[@]}\"}"
  for _ev in "$@"; do
    eval "$_prefixn+=(\"\$_ev\")"
  done

  # Non-interactive git guards, unless the kit set GIT_TERMINAL_PROMPT itself.
  local _kit_env_str
  eval "_kit_env_str=\" \${${_envarrn}[*]-} \""
  case "$_kit_env_str" in
    *" GIT_TERMINAL_PROMPT="*) : ;;
    *) eval "$_prefixn+=(\"GIT_TERMINAL_PROMPT=0\" \"GIT_ASKPASS=/bin/false\" \"SSH_ASKPASS=/bin/false\")" ;;
  esac
}

# _acq_msb_startup_emit_command USER BACKGROUND PREFIX_ARRVAR ARGV_ARRVAR — echo
# one /bin/sh line that runs one startup command in the guest with the correct
# run-as-user, env prefix, and (if background) nohup detach. Every kit-derived
# token is single-quote-escaped (SI-10); the run-as-user/su/nohup scaffolding is
# adapter-owned fixed text.
_acq_msb_startup_emit_command() {
  local _user="$1" _background="$2" _prefixn="$3" _argvn="$4"

  # PORTABLE ENV PREFIX (busybox/alpine-safe). The exec path threads env via
  # `msb exec -e NAME=value`; the in-guest equivalent is the shell/POSIX `env`
  # utility. We MUST NOT use the `env NAME=value -- argv` form: the `--`
  # end-of-options terminator is a GNU coreutils >= 8.30 extension and is NOT
  # accepted by busybox `env` (alpine) or older coreutils — there
  # `env FOO=bar -- echo hi` fails with `env: '--': No such file or directory`.
  # Since the git non-interactive guards are injected into nearly every command
  # and the adapter supports plain-OCI base images (alpine/node), the emitted
  # body must be portable.
  #
  # Portable construct: `env NAME=value … sh -c 'exec "$@"' sh ARGV…`. Per POSIX,
  # `env` consumes only the leading NAME=value operands and treats the first
  # non-assignment operand (`sh`) as the utility to run; no `--` is needed and
  # none is emitted. Passing the kit argv as positional parameters to
  # `sh -c 'exec "$@"' sh …` (rather than as bare `env` operands) means an env
  # value or an argv token that *looks* like an option is never re-interpreted
  # as one — `exec "$@"` runs argv[0] as the program with the rest as its args,
  # verbatim. Every env token and argv token is single-quote-escaped by
  # _acq_msb_sq (SI-10), so kit bytes stay inert quoted DATA.
  local _payload="" _tok
  eval "set -- \${${_prefixn}[@]+\"\${${_prefixn}[@]}\"}"
  if [ "$#" -gt 0 ]; then
    _payload="env"
    for _tok in "$@"; do
      _payload="$_payload $(_acq_msb_sq "$_tok")"
    done
  fi
  # Argv follows via `sh -c 'exec "$@"' sh ARGV…`: this is the utility `env` runs
  # (or, when there is no env prefix, the command itself). The literal
  # `sh -c 'exec "$@"' sh` is adapter-owned fixed text; only the argv tokens are
  # kit-derived and escaped. `sh` (argv0 for the -c shell, then $0 placeholder)
  # is never a flag, so `env` always has a valid non-assignment utility operand.
  eval "set -- \${${_argvn}[@]+\"\${${_argvn}[@]}\"}"
  [ "$#" -gt 0 ] || return 0
  _payload="$_payload sh -c 'exec \"\$@\"' sh"
  for _tok in "$@"; do
    _payload="$_payload $(_acq_msb_sq "$_tok")"
  done

  # background:true -> detach under nohup so a supervisor loop doesn't block.
  if [ "$_background" = "true" ]; then
    _payload="nohup sh -c $(_acq_msb_sq "$_payload") >/dev/null 2>&1 & :"
  fi

  # Run-as-user: root runs directly; the agent/uid-1000 contract runs via
  # su/runuser (whichever the guest has) as the `agent` user. The inner command
  # is passed to `sh -c` so the env prefix / nohup form is honored.
  case "$_user" in
    ""|0|root)
      printf '%s\n' "$_payload"
      ;;
    1000|agent)
      # Prefer runuser (util-linux) if present, else su. Both invoke the agent
      # user's login-ish shell with our command. The command string is single-
      # quote-escaped so kit content stays inert.
      printf 'if command -v runuser >/dev/null 2>&1; then runuser -u agent -- sh -c %s; else su agent -c %s; fi\n' \
        "$(_acq_msb_sq "$_payload")" "$(_acq_msb_sq "$_payload")"
      ;;
    *)
      # A named non-root user: run via su as that user (name already validated by
      # kit_spec_commands to ^[A-Za-z0-9_-]+$, but escape defensively anyway).
      printf 'su %s -c %s\n' "$(_acq_msb_sq "$_user")" "$(_acq_msb_sq "$_payload")"
      ;;
  esac
}

# _acq_msb_collect_kit_env_into ARRVAR SPEC — read SPEC's environment[] entries
# (via kit_spec_env, same validation as the exec path) and append each as a
# NAME=value element to the array named ARRVAR.
_acq_msb_collect_kit_env_into() {
  local _arrn="$1" _spec="$2" eline ekey eval_v
  while IFS= read -r eline; do
    [ -n "$eline" ] || continue
    ekey=$(printf '%s' "$eline" | cut -f1)
    eval_v=$(printf '%s' "$eline" | cut -f2-)
    [ -n "$ekey" ] || continue
    eval "$_arrn+=(\"\${ekey}=\${eval_v}\")"
  done <<EOF
$(kit_spec_env "$_spec")
EOF
}

# _acq_msb_startup_body_into BODYVAR SPEC — parse SPEC's __CMD__/base64-argv
# command stream (the same stream _acq_msb_run_commands consumes) and append one
# guest command line per STARTUP-phase record to the variable named BODYVAR.
# Returns 0 iff at least one startup command line was emitted. Non-startup phases
# are ignored here (install/initFiles stay on the exec path — ADR-0017).
_acq_msb_startup_body_into() {
  local _bodyn="$1" _spec="$2"

  local _kit_env=()
  _acq_msb_collect_kit_env_into _kit_env "$_spec"

  # Buffer the command stream first (kit_spec_commands runs its own subshell).
  local _lines=() line
  while IFS= read -r line; do
    _lines+=("$line")
  done <<EOF
$(kit_spec_commands "$_spec")
EOF

  local _emitted=0
  local phase="" user="" argv=() reading=0 _i background="false"
  for _i in ${_lines[@]+"${!_lines[@]}"}; do
    line="${_lines[$_i]}"
    case "$line" in
      "__CMD__"*)
        phase=$(printf '%s' "$line" | cut -f2)
        user=$(printf '%s' "$line" | cut -f3)
        background=$(printf '%s' "$line" | cut -f4)
        [ -n "$background" ] || background="false"
        argv=()
        reading=1
        ;;
      "__END__")
        reading=0
        if [ "$phase" = "startup" ] && [ "${#argv[@]}" -gt 0 ]; then
          local _prefix=() _cmdline
          _acq_msb_startup_env_prefix_into _prefix "$user" _kit_env
          _cmdline=$(_acq_msb_startup_emit_command "$user" "$background" _prefix argv)
          if [ -n "$_cmdline" ]; then
            # Append "<cmdline>\n" by name; $'\n' is a literal newline (ANSI-C).
            eval "$_bodyn=\${$_bodyn}\$_cmdline\$'\\n'"
            _emitted=1
          fi
        fi
        ;;
      *)
        if [ "$reading" -eq 1 ]; then
          argv+=("$(printf '%s' "$line" | base64 -d)")
        fi
        ;;
    esac
  done

  [ "$_emitted" -eq 1 ]
}

# _acq_msb_generate_startup_script SPEC OUTFILE — write the guest startup script
# for one kit spec's STARTUP-phase commands into OUTFILE. Returns 0 and writes a
# non-empty script iff the kit HAS at least one startup command; returns 1 (and
# writes nothing) when there are none, so the caller registers no empty script.
_acq_msb_generate_startup_script() {
  local _spec="$1" _out="$2" _body=""

  _acq_msb_startup_body_into _body "$_spec" || return 1

  # Emit the file: a self-contained /bin/sh with its own shebang (so --script-path
  # reads a complete verbatim body; no --shell shebang derivation dependency).
  {
    printf '#!/bin/sh\n'
    printf '# acq-generated msb startup script (ADR-0017). Reproduces kit startup\n'
    printf '# commands so microsandbox can replay them on a native restart.\n'
    printf '# Generated verbatim into a host file and registered via --script-path;\n'
    printf '# kit argv/env tokens are single-quote-escaped (SI-10), never interpolated.\n'
    printf '%s' "$_body"
  } > "$_out"
  return 0
}

# _acq_msb_stage_startup_script SPEC ARRVAR — generate the startup script for one
# kit SPEC and, if non-empty, append a `--script-path acq-startup:<hostfile>`
# entry into the create-flags array named ARRVAR. The host file is created under
# ACQ_MSB_STARTUP_STAGE_DIR (a private 0700 dir under the acq state tree, so kit
# content is never world-readable) and recorded in _ACQ_MSB_STARTUP_STAGE_FILES
# for cleanup by the caller after create. A kit with no startup commands stages
# nothing (no empty script is registered).
#
# NOTE (single-stake): only the FIRST kit that contributes startup commands stakes
# the fixed `acq-startup` script name; if multiple kits carried startup commands
# they would need a merged/uniquely-named script — but the pinned built-in kits
# put startup commands in a single kit, and multi-kit merging is deferred. Guarded
# here so a second contributing kit does not silently overwrite the first's
# registration; the exec-based apply path still runs EVERY kit's startup after
# create, so nothing is dropped at runtime.
#
# VERIFIED NEUTRALITY ASSUMPTION (ADR-0017): registering a script via
# `--script-path acq-startup:<file>` only STAGES the body on the guest PATH (as
# /.msb/scripts/acq-startup) — it does NOT enroll the script in microsandbox's
# persisted startup, so microsandbox does NOT auto-run it at guest boot. This was
# confirmed against microsandbox source: `crates/cli/lib/commands/start.rs` and
# `restart.rs` re-run a persisted startup command derived from
# runtime.entrypoint/runtime.cmd on `Sandbox::start_detached()`, NOT from
# runtime.scripts. So a bare `--script-path` registration is present but inert at
# boot. Restart durability is therefore provided by the acq `start`/`restart`
# verb + start-if-stopped-on-`acq run`, which re-runs the startup phase via the
# exec heal (the deterministic mechanism). A native `msb start` OUTSIDE acq
# cannot re-run startup on its own — and, more fundamentally, cannot even boot a
# secret-bound sandbox, because `msb start` requires the `--secret` host env vars
# that only acq injects (see acq_backend_start). Native-restart-outside-acq is
# therefore out of scope by construction; go through `acq start`/`acq restart`.
#
# This inertness is load-bearing and unverifiable from this repo, so it MUST be
# re-verified on each msb version bump — if a future msb auto-runs a registered
# `--script-path` at boot, kit startup would double-run (boot replay + acq heal).
# See docs/KNOWN_FAILURE_MODES.md ("msb May Auto-Run a --script-path-Registered
# Script at Boot") for the re-verification procedure and remediation.
ACQ_MSB_STARTUP_SCRIPT_NAME="acq-startup"
_acq_msb_stage_startup_script() {
  local _spec="$1" _arrn="$2"

  # One staged script per sandbox provision. If we already staged one, skip
  # (increment-1 scope; see NOTE above).
  if [ -n "${_ACQ_MSB_STARTUP_STAGED:-}" ]; then
    return 0
  fi

  # Private staging dir (0700) under the acq state tree — not a world-readable
  # /tmp. Mirrors how ssh keys/state are kept under ACQ_STATE_DIR.
  local _dir="${ACQ_MSB_STARTUP_STAGE_DIR:-${ACQ_STATE_DIR}/msb-startup}"
  mkdir -p "$_dir" 2>/dev/null || true
  chmod 700 "$_dir" 2>/dev/null || true

  local _file
  _file=$(mktemp "${_dir}/acq-startup.XXXXXX" 2>/dev/null) || {
    # Staging is best-effort (the script is inert until a later increment
    # invokes it), but a silent no-op would be undiagnosable — warn so the
    # cause is visible rather than a mysteriously missing --script-path.
    echo "acq(msb): warning: could not create startup-script staging file in ${_dir}; skipping --script-path." >&2
    return 0
  }
  chmod 600 "$_file" 2>/dev/null || true

  if _acq_msb_generate_startup_script "$_spec" "$_file"; then
    eval "$_arrn+=(--script-path \"${ACQ_MSB_STARTUP_SCRIPT_NAME}:\$_file\")"
    _ACQ_MSB_STARTUP_STAGE_FILES+=("$_file")
    _ACQ_MSB_STARTUP_STAGED=1
    acq_debug "msb startup-script staged: --script-path ${ACQ_MSB_STARTUP_SCRIPT_NAME}:${_file}"
  else
    # No startup commands in this kit — remove the empty temp file.
     rm -f "$_file" 2>/dev/null || true
   fi
 }

# ---------------------------------------------------------------------------
# _acq_msb_upstream_ca_flags_into ARRVAR — TLS-intercept upstream CA trust
# ---------------------------------------------------------------------------
# Emit `--tls-upstream-ca-cert <PEM>` create flags (one per resolved PEM) into
# the named array so msb's host-side interception proxy trusts a corporate MITM
# proxy's root on its UPSTREAM leg. See the ACQ_MSB_UPSTREAM_CA_* block near the
# top of this file for the full rationale.
#
# Scope: this helps ONLY the genuinely-terminated-endpoint case (a corporate
# proxy terminates the domain and presents its own leaf). It is defense-in-depth;
# it does not help a broad-egress failure (stale msb state) or USAi split-horizon
# DNS. See docs/KNOWN_FAILURE_MODES.md §30.
#
# Precedence:
#   0. ACQ_MSB_NO_UPSTREAM_CA — suppress entirely (reproduction/testing toggle).
#   1. ACQ_MSB_UPSTREAM_CA_CERT — explicit path(s), colon- or space-separated;
#      each existing, non-empty, readable file is passed through verbatim.
#   2. Auto-detect (macOS only, on unless ACQ_MSB_UPSTREAM_CA_AUTODETECT=0): export
#      the host search-list root CAs to a single PEM and pass THAT one file.
#
# Non-fatal throughout: any failure warns and emits nothing (the sandbox still
# creates; msb falls back to its own native-cert loading, i.e. today's behavior).
_acq_msb_upstream_ca_flags_into() {
  local _arr="$1"
  eval "$_arr=()"

  # (0) Reproduction/testing override: behave as if no upstream CA is available.
  if [ -n "${ACQ_MSB_NO_UPSTREAM_CA:-}" ]; then
    acq_debug "msb upstream-CA: suppressed via ACQ_MSB_NO_UPSTREAM_CA (reproduction mode)"
    return 0
  fi

  # (1) Explicit path(s) win. Split on ':' and whitespace; keep only readable,
  # non-empty files. A configured-but-missing path is a warning, not silent.
  if [ -n "${ACQ_MSB_UPSTREAM_CA_CERT:-}" ]; then
    local _p _added=0 _oldifs="$IFS" _nl
    # Split on ':' plus every whitespace char (space, tab, newline). Build the
    # separator set with printf into a variable so no literal trailing space/tab
    # sits on a source line (the trailing-whitespace pre-commit hook would strip
    # it and silently break the split). $(...) drops trailing newlines, so append
    # the newline separately via a dedicated _nl.
    _nl=$(printf '\n_')   # capture a real newline (the trailing _ survives $(...) )
    _nl=${_nl%_}          # ... then strip the guard char, leaving just "\n"
    IFS=":$(printf ' \t')${_nl}"
    # shellcheck disable=SC2086  # deliberate split of the path list on IFS
    set -- $ACQ_MSB_UPSTREAM_CA_CERT
    IFS="$_oldifs"
    for _p in "$@"; do
      [ -n "$_p" ] || continue
      if [ -r "$_p" ] && [ -s "$_p" ]; then
        eval "$_arr+=(--tls-upstream-ca-cert \"\$_p\")"
        _added=$((_added + 1))
        acq_debug "msb upstream-CA: trusting explicit PEM ${_p}"
      else
        echo "acq(msb): warning: ACQ_MSB_UPSTREAM_CA_CERT path not readable, skipping: ${_p}" >&2
      fi
    done
    [ "$_added" -gt 0 ] && return 0
    # Fall through to auto-detect if every explicit path was unusable.
  fi

  # (2) Auto-detect the host trust store (macOS only). Exports every root CA on
  # the default keychain search list to one PEM and trusts that on the upstream
  # leg — capturing the corporate root exactly as the host trusts it, whether or
  # not msb's own native-cert loader would have surfaced it. This covers the
  # genuine-interception case only (see docs/KNOWN_FAILURE_MODES.md §30), not a
  # broad-egress or split-horizon-DNS failure. Unprivileged (roots are readable
  # without sudo, which would otherwise trigger a PIV-PIN loop on managed Macs).
  [ -n "${ACQ_MSB_UPSTREAM_CA_AUTODETECT:-}" ] || return 0
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
  command -v security >/dev/null 2>&1 || return 0

  local _out="$ACQ_MSB_UPSTREAM_CA_FILE" _dir
  _dir=$(dirname -- "$_out")
  if ! mkdir -p "$_dir" 2>/dev/null; then
    echo "acq(msb): warning: cannot create upstream-CA dir ${_dir}; skipping auto-detect" >&2
    return 0
  fi

  # `security find-certificate -a -p` emits every search-list cert as PEM. Write
  # to a temp file first, then atomically move into place, and only keep it if it
  # actually contains a certificate (an empty/garbled dump must not be trusted).
  local _tmp
  _tmp=$(mktemp "${_out}.XXXXXX" 2>/dev/null) || {
    echo "acq(msb): warning: cannot create temp file for upstream-CA bundle; skipping auto-detect" >&2
    return 0
  }
  if security find-certificate -a -p >"$_tmp" 2>/dev/null && grep -q 'BEGIN CERTIFICATE' "$_tmp"; then
    chmod 0644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_out" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 0; }
    eval "$_arr+=(--tls-upstream-ca-cert \"\$_out\")"
    acq_debug "msb upstream-CA: exported host search-list roots to ${_out} and trusting them upstream"
  else
    rm -f "$_tmp" 2>/dev/null
    echo "acq(msb): note: could not export host CAs for the TLS-intercept upstream verifier;" >&2
    echo "acq(msb):   msb will fall back to its own native-cert loading. If egress fails with" >&2
    echo "acq(msb):   a TLS 'unexpected eof' behind a corporate proxy that terminates the" >&2
    echo "acq(msb):   endpoint, set ACQ_MSB_UPSTREAM_CA_CERT to your proxy's root CA PEM." >&2
    echo "acq(msb):   See docs/KNOWN_FAILURE_MODES.md §30." >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Neutral --clone emulation (ADR-0027) — disposable primary on msb
# ---------------------------------------------------------------------------
# sbx's --clone runs the agent on an isolated in-container clone; msb workspaces
# are direct host mounts. Emulate the semantics with a managed host-side scratch
# clone: `git clone --no-hardlinks` the primary into
# ACQ_MSB_CLONES_DIR/<sandbox>/<basename>, mount THAT rw at the ORIGINAL
# workspace path in the guest (verified msb 0.6.15 mounts --volume src:dst with
# src != dst), and register a `sandbox-<name>` remote in the host checkout so
# recovery is sbx-parity: `git fetch sandbox-<name>`. --no-hardlinks is
# load-bearing — a same-filesystem clone hardlinks object files by default, so a
# guest with rw access to the scratch .git could modify inodes shared with the
# real repo's object store. Deliberate divergences from sbx (both git-native and
# documented in the ADR): gitignored/untracked files and uncommitted changes to
# tracked files do NOT enter the clone — commit first, or `acq cp` them in.

# _acq_msb_clone_setup NAME WSPATH — create the scratch clone + fetch-back
# remote for NAME's primary workspace WSPATH. On success sets
# _ACQ_MSB_CLONE_DIR to the canonicalized scratch path (the mount source).
# Fails (return 1) without touching the backend when WSPATH is not a git
# repository root or a previous scratch is still present.
_acq_msb_clone_setup() {
  local name="$1" ws="$2" top=""
  # NAME lands verbatim in host paths (mkdir/git clone, and rm -rf at cleanup)
  # under the clones root, and in the sandbox-<name> remote — and an EXPLICIT
  # --name bypasses slugify, reaching here before msb's own name validation
  # ever runs. Fail closed on anything that is not a single safe path
  # component, so a traversal-shaped name can never build a path outside the
  # clones root.
  case "$name" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      echo "acq(msb): error: --clone: invalid sandbox name '$name' for the scratch clone" >&2
      echo "acq(msb):   (allowed: letters, digits, '.', '_', '-')." >&2
      return 1
      ;;
  esac
  if ! top=$(git -C "$ws" rev-parse --show-toplevel 2>/dev/null); then
    echo "acq(msb): error: --clone: workspace is not a git repository: $ws" >&2
    echo "acq(msb):   --clone runs the agent on a clone of the primary workspace's repo." >&2
    return 1
  fi
  local ws_canon top_canon
  ws_canon=$(canonicalize_path "$ws")
  top_canon=$(canonicalize_path "$top")
  if [ "$ws_canon" != "$top_canon" ]; then
    echo "acq(msb): error: --clone: workspace must be the repository root: $top_canon" >&2
    return 1
  fi
  local dir="${ACQ_MSB_CLONES_DIR}/${name}" scratch
  scratch="${dir}/$(basename "$ws_canon")"
  if [ -e "$dir" ]; then
    echo "acq(msb): error: --clone: a scratch clone for '$name' already exists: $dir" >&2
    if acq_backend_exists "$name"; then
      # The scratch is the LIVE mount source of an existing sandbox — advising
      # manual deletion here would destroy its workspace and skip the rm-time
      # unfetched-commit warning.
      echo "acq(msb):   sandbox '$name' still exists and mounts it. Remove the sandbox with" >&2
      echo "acq(msb):   'acq rm $name' (it warns about unfetched work and cleans up), then re-run." >&2
    else
      echo "acq(msb):   it may hold unfetched work from an earlier sandbox. Recover it" >&2
      echo "acq(msb):   ('git fetch sandbox-${name}') and remove the directory, then re-run." >&2
    fi
    return 1
  fi
  if [ -n "$(git -C "$ws_canon" status --porcelain 2>/dev/null)" ]; then
    echo "acq(msb): note: the workspace has uncommitted changes; a git clone carries" >&2
    echo "acq(msb):   committed state only. Commit first ('git add' untracked files)," >&2
    echo "acq(msb):   or copy files in with 'acq cp'." >&2
  fi
  mkdir -p "$dir"
  printf '%s\n' "$ws_canon" > "${dir}/.origin"
  if ! git clone --quiet --no-hardlinks -- "$ws_canon" "$scratch"; then
    echo "acq(msb): error: --clone: git clone of $ws_canon failed" >&2
    rm -rf "$dir"
    return 1
  fi
  _acq_msb_clone_copy_identity "$ws_canon" "$scratch"
  # Fetch-back remote in the host checkout (replace a stale same-name remote —
  # its scratch dir was just verified absent, so it cannot hold unfetched work).
  git -C "$ws_canon" remote remove "sandbox-${name}" >/dev/null 2>&1 || true
  if ! git -C "$ws_canon" remote add "sandbox-${name}" "$scratch" >/dev/null 2>&1; then
    echo "acq(msb): warning: could not register the 'sandbox-${name}' remote in $ws_canon;" >&2
    echo "acq(msb):   fetch agent work directly: git fetch $scratch" >&2
  fi
  echo "acq(msb): agent runs on a disposable clone; the real checkout is untouched." >&2
  echo "acq(msb):   Recover agent branches with: git fetch sandbox-${name}" >&2
  _ACQ_MSB_CLONE_DIR=$(canonicalize_path "$scratch")
  return 0
}

# _acq_msb_clone_copy_identity SRC SCRATCH — write SRC's EFFECTIVE git
# identity (user.name/user.email) repo-locally into the scratch. A clone drops
# .git/config, and a per-forge identity often lives only there or behind a
# gitdir-scoped includeIf; the guest's synced global tier cannot express a
# per-repo value, so without this the first in-guest commit fails with "Author
# identity unknown". `git -C SRC config --get` resolves the value exactly as
# the user's own commits do. Running git inside the scratch is safe HERE only:
# acq just created it and it is not yet guest-exposed (see the rm-time rule in
# _acq_msb_clone_warn_unfetched). Best-effort, always returns 0.
_acq_msb_clone_copy_identity() {
  local src="$1" scratch="$2" key val
  for key in user.name user.email; do
    val=$(git -C "$src" config --get "$key" 2>/dev/null) || continue
    [ -n "$val" ] || continue
    git -C "$scratch" config "$key" "$val" >/dev/null 2>&1 \
      || echo "acq(msb): warning: --clone: could not set $key in the scratch clone." >&2
  done
  return 0
}

# _acq_msb_clone_warn_unfetched NAME — warn (sbx-parity, never blocks) when
# NAME's scratch clone holds commits absent from the origin checkout's object
# store. Branch tips are checked with cat-file -e; a fetch transfers exactly
# those objects, so tip-present == nothing to lose.
_acq_msb_clone_warn_unfetched() {
  # NOTE: `local a="$1" b="…${a}"` is a trap — the whole statement's words
  # expand BEFORE `local` assigns, so ${a} is unbound under set -u. Split them.
  local name="$1" origin="" scratch="" d t
  local dir="${ACQ_MSB_CLONES_DIR}/${name}"
  [ -d "$dir" ] || return 0
  origin=$(cat "${dir}/.origin" 2>/dev/null) || origin=""
  [ -n "$origin" ] && [ -d "$origin" ] || return 0
  for d in "$dir"/*/; do [ -d "${d}.git" ] && scratch="${d%/}"; done
  [ -n "$scratch" ] || return 0
  # Branch tips are read straight from the ref files (loose + packed). The
  # scratch is guest-writable, so the host must NEVER execute git inside it —
  # repo-local config (core.fsmonitor, pagers, ...) would let the guest run
  # commands on the host at rm time.
  local tips=""
  if [ -d "${scratch}/.git/refs/heads" ]; then
    tips=$(find "${scratch}/.git/refs/heads" -type f -exec cat {} + 2>/dev/null) || tips=""
  fi
  if [ -f "${scratch}/.git/packed-refs" ]; then
    tips="${tips}
$(awk '$1 ~ /^[0-9a-f]+$/ && $2 ~ /^refs\/heads\//{print $1}' "${scratch}/.git/packed-refs" 2>/dev/null || true)"
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Skip non-SHA lines (e.g. a symbolic "ref: ..." loose ref) rather than
    # letting cat-file fail on them and warn spuriously.
    case "$t" in *[!0-9a-f]*) continue ;; esac
    if ! git -C "$origin" cat-file -e "$t" 2>/dev/null; then
      echo "acq(msb): warning: discarding unfetched commits in sandbox '$name''s scratch clone" >&2
      echo "acq(msb):   (they were recoverable with: git fetch sandbox-${name})." >&2
      return 0
    fi
  done <<EOF
$tips
EOF
  return 0
}

# _acq_msb_clone_cleanup NAME — delete NAME's scratch clone and drop the
# fetch-back remote from the origin checkout. Best-effort, always returns 0
# (a sandbox created without --clone has no dir: quiet no-op).
_acq_msb_clone_cleanup() {
  local name="$1" origin=""
  local dir="${ACQ_MSB_CLONES_DIR}/${name}"
  [ -d "$dir" ] || return 0
  origin=$(cat "${dir}/.origin" 2>/dev/null) || origin=""
  if [ -n "$origin" ] && [ -d "$origin" ]; then
    git -C "$origin" remote remove "sandbox-${name}" >/dev/null 2>&1 || true
  fi
  rm -rf "$dir"
  return 0
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
  local _volrecs=""

  # Resolve the OCI image ONCE per provision (ADR-0022): explicit ACQ_MSB_IMAGE
  # wins over the neutral --image/ACQ_IMAGE, which wins over an agent-derived
  # sandbox-template image, which wins over the built-in shell fallback. Use this
  # local everywhere below instead of $ACQ_MSB_IMAGE so the neutral knob and the
  # one-time precedence notice are honored consistently.
  _acq_msb_resolve_image "$agent"
  local _msb_image="$_ACQ_MSB_RESOLVED_IMAGE"
  local _msb_image_source="$_ACQ_MSB_RESOLVED_IMAGE_SOURCE"

  # Optional pull policy (ACQ_MSB_PULL): forwarded to `msb create --pull`.
  # `msb create` reads an image REF and by default pulls if-missing from a
  # registry — it does NOT read a locally-built image unless that image has been
  # imported into msb's cache with `msb image load` first. When a caller has
  # pre-loaded a local image (e.g. a locally-built tag like `localhost/…` that
  # has no registry behind it), they set ACQ_MSB_PULL=never so msb uses the cache
  # instead of attempting to pull the un-pullable ref. Accepted values match
  # msb's own: always | if-missing | never. An unset var keeps msb's default.
  case "${ACQ_MSB_PULL:-}" in
    "") : ;;  # unset — leave msb's default (if-missing)
    always|if-missing|never) create_flags+=(--pull "$ACQ_MSB_PULL") ;;
    *)
      echo "acq(msb): ignoring invalid ACQ_MSB_PULL='$ACQ_MSB_PULL'" \
           "(expected: always | if-missing | never)" >&2
      ;;
  esac

  # Create-time startup-script staging (ADR-0017, increment 1). Reset the
  # per-provision guard + staged-file list so a prior provision in the same
  # process does not leak into this one; the files are cleaned up after create.
  _ACQ_MSB_STARTUP_STAGED=""
  _ACQ_MSB_STARTUP_STAGE_FILES=()

  # Reset the host ssh-agent forwarding flag for this provision; it is set later
  # by _acq_msb_vsock_flags_into when an ssh-agent forward is emitted. See ADR-0021.
  _ACQ_MSB_SSH_AGENT_FORWARDING=0

  # Fetch each built-in kit and gather its create-time contributions.
  # Zscaler CA trust FIRST so later network-fetching kits (playbook clone, USAi
  # validation) succeed behind a TLS-intercepting proxy (e.g. Zscaler).
  local kitref kitdir
  local kits=("$ZSCALER_KIT" "$USAI_KIT" "$PLAYBOOK_KIT" "$GITSSHSIGN_KIT")
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

    # Published ports (ADR-0014) → create-time `-p HOST:GUEST` flags. The
    # neutral top-level `publishedPorts` is read first by kit_spec_published_ports
    # (with a deprecated backend_extras.sbx fallback). Each surviving record is
    # `guest<TAB>proto<TAB>name<TAB>host` (validated to ints 1..65535). msb -p also
    # accepts BIND_ADDR:HOST:GUEST and /udp, but the neutral schema stays TCP +
    # default loopback bind for sbx parity, so we emit a plain `-p HOST:GUEST`
    # (no bind-addr, no /udp — out of parity scope). Absence is a silent no-op.
    local pp=()
    _acq_msb_port_flags_into pp "$spec"
    [ "${#pp[@]}" -gt 0 ] && create_flags+=("${pp[@]}")

    # Volumes (ADR-0023): ACCUMULATE this kit's validated records; they are
    # unioned across all kits (last wins by path, matching sbx's own
    # composition rule) and emitted as create flags AFTER the loop — emitting
    # per kit here would produce conflicting --mount-named flags when two kits
    # declare the same path.
    _volrecs="${_volrecs}
$(kit_spec_volumes "$spec")"

    # Startup-phase commands → a create-time `--script-path acq-startup:<file>`
    # (ADR-0017). The script is REGISTERED at create; a bare registration is
    # runtime-neutral (staged on the guest PATH, not auto-run at start). Restart
    # durability is delivered by the acq `start`/`restart` verb re-running startup
    # via the exec heal. install + mid-life apply stay exec-based (see the DESIGN
    # NOTE and _acq_msb_apply_kit_dir). Only the first kit with startup commands
    # stakes the fixed script name (see _acq_msb_stage_startup_script).
    _acq_msb_stage_startup_script "$spec" create_flags
  done

  # Volumes (ADR-0023) → create-time storage flags, from the union of every
  # kit's records (last wins by path): a block entry becomes a derived named
  # disk volume (--mount-named acq-<name>-<pathslug>-<crc>:<path>:kind=disk,
  # size=<size>, removed again in acq_backend_terminate), a tmpfs entry becomes
  # --tmpfs <path>:<size>. Mounts land at boot, before any exec is possible
  # (the same no-race guarantee as sbx kit volumes). Absence is a silent no-op.
  local vf=()
  _acq_msb_volume_flags_from_records vf "$name" <<EOF
$(printf '%s\n' "$_volrecs" | _acq_msb_volume_records_dedupe)
EOF
  [ "${#vf[@]}" -gt 0 ] && create_flags+=("${vf[@]}")

  [ "$trust_host_cas" -eq 1 ] && create_flags+=(--trust-host-cas)

  # Balanced egress baseline (ADR-0018): mirror the sbx "balanced" host set so an
  # msb sandbox reaches the same dev hosts. msb defaults egress to none, so we
  # make the restriction explicit and deterministic. The NEUTRAL network tier
  # (ACQ_NETWORK_TIER; strict|balanced|open, default balanced — see the module
  # header and agentic-coding-patterns ADR-0002) selects how much egress the
  # sandbox gets, all deny-by-default except `open`:
  #   balanced -> `--net-default-egress deny` + the curated baseline
  #               (`allow@<host>:tcp:<port>` per vendored entry + gateway DNS via
  #               the `allow@dns` macro) UNIONED with the kit/npm/secret
  #               `allow@…` rules under first-match-wins.
  #   strict   -> `--net-default-egress deny` + gateway DNS, but NO baseline:
  #               egress is the kits' own `allow@…` hosts ONLY. Same deny-default
  #               posture as balanced, smaller allowlist.
  #   open     -> NO deny-default emitted; kit/npm/secret allows ride msb's own
  #               (permissive) egress default. Gated behind an explicit confirm
  #               token; validated below before we reach here.
  # The baseline rules are emitted BEFORE the npm-host rule so all allow rules sit
  # together after the deny-default.
  #
  # EGRESS-ONLY, DELIBERATELY (ADR-0019): we emit `--net-default-egress deny`, NOT
  # the symmetric `--net-default deny`. msb's `--net-default` sets BOTH directions
  # (verified in msb 0.6.8 `--help`: "Sets egress and ingress symmetrically") and
  # there is NO implicit ingress-allow for a published port — every inbound
  # connection is evaluated against the ingress default, so a symmetric deny RSTs
  # inbound traffic to a create-time `-p HOST:GUEST` port (the connection completes
  # the handshake via msb's host proxy, then resets on data → ERR_CONNECTION_RESET
  # on the host). Restricting only egress leaves the ingress default at msb's
  # baseline `allow`, so published ports stay reachable with no per-port ingress
  # rule. A future "strict" ingress profile can layer ingress deny-default + explicit
  # per-port `allow:ingress@…` rules; the tiers here intentionally set egress only.
  # Requires msb >= 0.6.8 (the `--net-default-egress`/`--net-default-ingress`
  # split); MIN_MSB_VERSION is 0.6.9, so acq_backend_prepare has already failed
  # closed on anything older before we reach here — this flag is always known.
  #
  # `open` is a privileged, audited escape hatch (never a default, never for GFE):
  # it requires ACQ_NETWORK_TIER_CONFIRM_OPEN=1 or acq fails closed here, warns on
  # every use, and is recorded via acq_debug.
  if [ "$ACQ_NETWORK_TIER" = open ]; then
    if [ "$ACQ_NETWORK_TIER_CONFIRM_OPEN" != 1 ]; then
      echo "acq(msb): error: ACQ_NETWORK_TIER=open disables deny-by-default egress and is refused" >&2
      echo "acq(msb):   without explicit confirmation. Set ACQ_NETWORK_TIER_CONFIRM_OPEN=1 to proceed" >&2
      echo "acq(msb):   (testing only; never for GFE). Prefer ACQ_NETWORK_TIER=strict or balanced." >&2
      return 1
    fi
    echo "acq(msb): WARNING: ACQ_NETWORK_TIER=open — egress is UNRESTRICTED (no deny-default)." >&2
    echo "acq(msb):   This sandbox can reach any host. Do not use for GFE or production agents." >&2
    acq_debug "msb network tier: open (deny-default NOT emitted; confirmed via ACQ_NETWORK_TIER_CONFIRM_OPEN)"
  fi
  # Track the hosts the balanced block allow-listed so the npm block below can
  # de-dupe against them (space-delimited, space-padded for whole-token match).
  local _balanced_hosts=" "
  if [ "$ACQ_NETWORK_TIER" = strict ] || [ "$ACQ_NETWORK_TIER" = balanced ]; then
    local _balanced=()
    if [ "$ACQ_NETWORK_TIER" = balanced ]; then
      # balanced: deny-default + curated baseline (+ gateway DNS from the emitter).
      _acq_msb_balanced_rules_into _balanced
    else
      # strict: deny-default + gateway DNS ONLY, no baseline hosts. Emit the same
      # gateway-DNS rule the baseline emitter prepends (the high-level DNS
      # auto-grant does not fire under a rule-only deny-default), so kit `allow@…`
      # hosts remain resolvable. Uses msb's `allow@dns` macro, safe because acq
      # requires msb >= 0.6.9 (the upstream parser fix). NOTHING else is added.
      _balanced=(--net-rule "allow@dns")
    fi
    if [ "${#_balanced[@]}" -gt 0 ]; then
      create_flags+=(--net-default-egress deny)
      create_flags+=("${_balanced[@]}")
      acq_debug "msb network tier=${ACQ_NETWORK_TIER}: added ${#_balanced[@]} --net-rule token(s) + --net-default-egress deny"
      # Record the bare host of each emitted rule (strip the `allow@` prefix and
      # any `:proto:port` suffix) for the npm de-dupe below.
      local _tok _bh
      for _tok in "${_balanced[@]}"; do
        case "$_tok" in
          allow@*)
            _bh=${_tok#allow@}; _bh=${_bh%%:*}
            _balanced_hosts="${_balanced_hosts}${_bh} "
            ;;
        esac
      done
    fi
  fi

  # Allow-list the agent installer's registry host(s) so the (default-deny) guest
  # egress permits the npm download. Only when we will actually install an agent
  # (a known recipe exists); `shell` and unknown agents add no rule.
  #
  # De-dupe against the balanced set: when the baseline is ON, registry.npmjs.org
  # is already allow-listed, so a second bare `allow@registry.npmjs.org` would be
  # dead weight (both allow; no deny to shadow). We therefore skip any npm host
  # that the balanced block ALREADY emitted a rule for, rather than skipping the
  # whole block — an operator who overrides ACQ_MSB_NPM_HOSTS to an internal
  # mirror NOT in the balanced set still gets its rule. Under the `strict` tier
  # (or `open`) the balanced set is empty, so nothing is elided.
  if _acq_msb_agent_has_install_recipe "$agent"; then
    local _npm_host
    for _npm_host in $ACQ_MSB_NPM_HOSTS; do
      case "$_npm_host" in
        ""|*[!A-Za-z0-9.*_-]*)
          echo "acq(msb): warning: skipping non-hostname npm host: $_npm_host" >&2
          continue
          ;;
      esac
      # Already covered by a balanced rule? Skip the redundant bare allow.
      case "$_balanced_hosts" in
        *" ${_npm_host} "*)
          acq_debug "msb: npm host ${_npm_host} already in balanced set; skipping redundant rule"
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

    # When interception is on and a corporate proxy genuinely terminates an
    # endpoint, msb's host-side proxy must trust the corporate root on its
    # UPSTREAM leg (defense-in-depth; see _acq_msb_upstream_ca_flags_into and
    # docs/KNOWN_FAILURE_MODES.md §30). Emitted only alongside --tls-intercept:
    # with interception off there is no upstream leg to verify.
    local _upstream_ca=()
    _acq_msb_upstream_ca_flags_into _upstream_ca
    [ "${#_upstream_ca[@]}" -gt 0 ] && create_flags+=("${_upstream_ca[@]}")
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
  # CONTRACT (matches sbx semantics — see docs/CONCEPTS.md "Multiple
  # Workspaces"): every workspace positional after the agent is mounted at its
  # SAME absolute path inside the guest (all workspaces appear inside the
  # sandbox at their absolute host paths). A trailing `:ro` marks that mount
  # read-only. `acq run opencode ~/app ~/lib:ro` therefore mounts ~/app rw and
  # ~/lib ro, each at its own host path.
  #
  # STARTING DIRECTORY (ACQ_MSB_GUEST_WORKSPACE, consumed by attach): the FIRST
  # workspace positional is the "primary" — the agent starts there — regardless
  # of how many mounts are given (docs/CONCEPTS.md: the primary workspace is the
  # first path and the agent starts there). ACQ_MSB_WORKSPACE overrides it.
  #
  # Why mount at the host path (not remapped under /home/agent): `msb create`
  # performs the mount at create time, BEFORE acq can create the `agent` user and
  # /home/agent (that happens post-create, once the guest is exec-ready). A plain
  # base override (e.g. node:22-bookworm) has no /home/agent, so mounting into it
  # failed with
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

  # Neutral --clone (ADR-0027): the PRIMARY workspace mounts a managed scratch
  # clone instead of the real checkout (see _acq_msb_clone_setup above).
  # Secondaries are untouched. Fail before any backend call: a create that
  # cannot honor --clone must not produce a sandbox with the real path rw.
  local _clone_src=""
  if [ "${ACQ_CLONE:-0}" = "1" ]; then
    if [ "${#_ws_recs[@]}" -eq 0 ]; then
      echo "acq(msb): error: --clone requires a workspace path (the repo to clone)." >&2
      return 1
    fi
    local _primary="${_ws_recs[0]}"
    case "$_primary" in *:ro)
      echo "acq(msb): error: --clone requires a writable primary workspace; '${_primary}' is read-only." >&2
      echo "acq(msb):   Drop ':ro' — the agent works on a disposable clone; the real checkout is untouched." >&2
      return 1 ;;
    esac
    # Validate EVERY workspace path before creating the scratch clone: a
    # failure past this point would leak the scratch + remote, and the
    # corrected re-run would then be refused as possibly holding unfetched work.
    local _wchk
    for _wchk in "${_ws_recs[@]}"; do
      _wchk="${_wchk%:ro}"
      if [ ! -d "$_wchk" ]; then
        echo "acq(msb): error: workspace path does not exist on the host: $_wchk" >&2
        echo "acq(msb):   msb cannot mount a nonexistent host path. Create it first." >&2
        return 1
      fi
    done
    if ! _acq_msb_clone_setup "$name" "$_primary"; then
      return 1
    fi
    _clone_src="$_ACQ_MSB_CLONE_DIR"
  fi

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
    # Under --clone, the PRIMARY's mount SOURCE is the scratch clone while the
    # guest path stays the original — the agent's cwd, kits, and docs behave
    # exactly as in a non-clone run (verified msb 0.6.15 mounts src != dst).
    if [ -n "$_clone_src" ] && [ -z "$_first_guest" ]; then
      create_flags+=(--volume "${_clone_src}:${_wpath}${_wro}")
      acq_debug "msb volume (clone): ${_clone_src} -> ${_wpath}${_wro}"
    else
      create_flags+=(--volume "${_wpath}:${_wpath}${_wro}")
      acq_debug "msb volume: ${_wpath} -> ${_wpath}${_wro}"
    fi
    [ -z "$_first_guest" ] && _first_guest="$_wpath"
  done

  # Decide the agent's starting directory (recorded for attach). Explicit
  # override wins; otherwise the FIRST (primary) workspace, matching sbx.
  if [ -n "${ACQ_MSB_WORKSPACE:-}" ]; then
    ACQ_MSB_GUEST_WORKSPACE="$ACQ_MSB_WORKSPACE"
  elif [ -n "$_first_guest" ]; then
    ACQ_MSB_GUEST_WORKSPACE="$_first_guest"
  fi

  # Host ssh-agent / socket forwarding (ADR-0021). Translate the neutral
  # host-socket forwards into msb `--vsock HOST:PORT/KIND` create flags. Gated on
  # msb >= 0.6.9; a lower version warns once and skips (forwarding is opt-in
  # convenience, never a hard failure).
  local _vsock_flags=()
  _acq_msb_vsock_flags_into _vsock_flags
  [ "${#_vsock_flags[@]}" -gt 0 ] && create_flags+=("${_vsock_flags[@]}")

  # Credentials: read from the acq-owned secret store (keychain/file), scoped to
  # this sandbox first, then global. The real value is read into a TRANSIENT env
  # var (never argv, never the kit spec) and bound with `msb --secret ENV@HOST`,
  # which puts a PLACEHOLDER ($MSB_<env>) in the guest and swaps in the real value
  # on the wire to the allowed host (requires --tls-intercept, set above). The
  # real value never enters the guest.
  #
  # SCOPE:
  #   - USAi: bind USAI_API_KEY@api.gsa.usai.gov ONLY. The USAi provider sends the
  #     key as an `Authorization: Bearer` header, which msb substitutes correctly.
  #   - GitHub: bind GITHUB_TOKEN@github.com,api.github.com,codeload.github.com.
  #     msb substitutes the token on the wire for both REST API calls and HTTPS
  #     git transport, so private tarball fetches, clones, and pushes can
  #     authenticate without the real token entering the guest.
  #
  # The resolve+export+flag-collect is shared with the resume path
  # (acq_backend_start) via _acq_msb_bind_secrets_into so create and start always
  # bind the identical set. It exports each real value into a TRANSIENT env var
  # (recorded in _secret_env_names) and appends the matching `--secret ENV@HOST`
  # flags to create_flags; we unset the env vars right after `msb create` reads
  # them.
  local _secret_env_names=()   # env vars we set transiently, cleared after create
  _acq_msb_bind_secrets_into create_flags _secret_env_names "$name"

  # Create the sandbox (detached; msb create boots in the background).
  # NOTE: acq runs under `set -euo pipefail`, so capture the status with
  # `|| _create_rc=$?` — a bare `msb create; local rc=$?` would abort the
  # function on failure BEFORE the error block and the transient-secret scrub
  # below ever run.
  acq_debug "msb create --name $name ${create_flags[*]} $_msb_image"
  local _create_rc=0
  local _create_output=""
  acq_debug "msb create: invoking (this returns fast; guest boots in background)"
  acq_spin_start "Creating sandbox '$name'"
  _create_output=$(msb create --name "$name" "${create_flags[@]}" "$_msb_image" 2>&1) || _create_rc=$?
  acq_spin_stop "Creating sandbox '$name'"
  [ -z "$_create_output" ] || printf '%s\n' "$_create_output" >&2
  if [ "$_create_rc" -ne 0 ] && [ "$_msb_image_source" = "agent-default" ] \
     && _acq_msb_image_not_found_error "$_create_output" \
     && ! acq_backend_exists "$name"; then
    echo "acq(msb): agent-specific image '$_msb_image' was not found;" >&2
    echo "acq(msb):   falling back to '$_ACQ_MSB_DEFAULT_IMAGE'." >&2
    _msb_image="$_ACQ_MSB_DEFAULT_IMAGE"
    _msb_image_source="builtin-default"
    _create_rc=0
    _create_output=""
    acq_debug "msb create --name $name ${create_flags[*]} $_msb_image"
    acq_spin_start "Creating sandbox '$name'"
    _create_output=$(msb create --name "$name" "${create_flags[@]}" "$_msb_image" 2>&1) || _create_rc=$?
    acq_spin_stop "Creating sandbox '$name'"
    [ -z "$_create_output" ] || printf '%s\n' "$_create_output" >&2
  fi
  acq_debug "msb create: returned rc=${_create_rc}"
  # Clear the transient secret env vars immediately after create reads them
  # (runs on both success and failure so the exported key never lingers).
  local _ev
  for _ev in ${_secret_env_names[@]+"${_secret_env_names[@]}"}; do
    unset "$_ev"
  done
  # Remove the staged startup-script host file(s) now that `msb create` has read
  # the --script-path body (ADR-0017). Runs on success and failure so kit content
  # never lingers in the private staging dir. The registration lives in the
  # sandbox; the host copy is transient (mirrors the transient-secret scrub).
  # ACQ_MSB_KEEP_STARTUP_STAGE=1 preserves the file (used by the offline test
  # harness to inspect the generated body; never set in normal operation).
  local _sf
  for _sf in ${_ACQ_MSB_STARTUP_STAGE_FILES[@]+"${_ACQ_MSB_STARTUP_STAGE_FILES[@]}"}; do
    [ -n "${ACQ_MSB_KEEP_STARTUP_STAGE:-}" ] || rm -f "$_sf" 2>/dev/null || true
  done
  [ -n "${ACQ_MSB_KEEP_STARTUP_STAGE:-}" ] || _ACQ_MSB_STARTUP_STAGE_FILES=()
  if [ "$_create_rc" -ne 0 ]; then
    echo "acq(msb): error: 'msb create' failed for '$name'." >&2
    echo "acq(msb):   flags: ${create_flags[*]}" >&2
    echo "acq(msb):   image: $_msb_image" >&2
    # Targeted registry-auth / local-import hint for the SPECIFIC image host
    # (registry-agnostic — not limited to a few hardcoded hosts). The raw msb
    # stderr above is printed by msb itself; this adds the acq remediation.
    if command -v acq_registry_auth_hint >/dev/null 2>&1; then
      acq_registry_auth_hint msb "$_msb_image"
    fi
    echo "acq(msb):   (re-run with ACQ_DEBUG=1 for the full command trace)" >&2
    # A fresh --clone scratch can hold no agent work yet — remove it (and the
    # fetch-back remote) so the next create doesn't refuse on a stale dir.
    [ -n "$_clone_src" ] && _acq_msb_clone_cleanup "$name"
    return 1
  fi

  # CRITICAL: `msb create` returns 0 even when the sandbox later FAILS TO START
  # (e.g. a bad mount): the boot is asynchronous. So a zero rc from create does
  # NOT mean the sandbox is usable. The ONLY reliable readiness signal is that
  # `msb exec` works. Treat a non-ready sandbox as a HARD provision failure —
  # otherwise kit application (and every downstream check) runs against a
  # sandbox that isn't really up, which looks like success but silently isn't.
  acq_debug "msb provision: waiting for exec-ready ($name)"
  acq_spin_start "Waiting for the sandbox to finish booting"
  if ! _acq_msb_wait_for_exec_ready "$name"; then
    acq_spin_stop "Waiting for the sandbox to finish booting"
    echo "acq(msb): error: sandbox '$name' did not become exec-ready within" >&2
    echo "acq(msb):   ${ACQ_MSB_EXEC_READY_TIMEOUT}s. 'msb create' returns 0 even when the" >&2
    echo "acq(msb):   sandbox VM fails to START (async boot) — a bad mount, image, or host" >&2
    echo "acq(msb):   virtualization issue. Diagnose with:" >&2
    echo "acq(msb):     msb logs --source system $name" >&2
    echo "acq(msb):     msb list          # is it running?" >&2
    echo "acq(msb):   (re-run with ACQ_DEBUG=1 for the create command trace.)" >&2
    # Leave the sandbox in place for inspection; caller decides whether to rm.
    return 1
  fi
  acq_spin_stop "Waiting for the sandbox to finish booting"
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
  # commands as that user (the sbx agent template guarantees this user, and so
  # does the default image). A plain OCI base override (e.g. node:22-bookworm) has
  # no `agent` user — and uid 1000 is already taken there — so acq creates `agent`
  # (any uid) and chowns its home. On the default image `agent` already exists, so
  # the ensure step short-circuits. A failure here is FATAL: a root-owned
  # /home/agent silently breaks every agent-user kit (playbook fetch, usai merge),
  # which is exactly how the playbook stopped fetching. Abort provision rather
  # than degrade silently.
  acq_debug "msb provision: ensuring agent user ($name)"
  if ! _acq_msb_ensure_agent_user "$name"; then
    echo "acq(msb): error: agent-user setup failed for '$name'; aborting provision." >&2
    return 1
  fi
  acq_debug "msb provision: agent user ready ($name)"

  # Ensure an OCI container engine (podman) so agents can run OCI images
  # (docker run / docker compose). Idempotent + marker-gated; FAILS SOFT (a
  # warning, never aborting provision) if the engine cannot be installed — e.g.
  # the OS package mirror is unreachable under a narrowed egress. See ADR-0020.
  acq_debug "msb provision: ensuring OCI engine ($name)"
  if [ -n "$ACQ_MSB_ENSURE_OCI" ]; then
    acq_spin_start "Ensuring an OCI engine (podman)"
    _acq_msb_ensure_oci "$name"
    acq_spin_stop "Ensuring an OCI engine (podman)"
  fi
  acq_debug "msb provision: OCI engine step done ($name)"

  # Install the requested agent binary (sbx bakes it into the template image; on
  # a plain msb base acq must install it). Idempotent + marker-gated; a no-op for
  # `shell`, a clear warning for an agent with no known recipe.
  acq_debug "msb provision: installing agent '$agent' ($name)"
  if _acq_msb_agent_has_install_recipe "$agent"; then
    acq_spin_start "Installing the '$agent' agent"
    _acq_msb_install_agent "$name" "$agent"
    acq_spin_stop "Installing the '$agent' agent"
  else
    _acq_msb_install_agent "$name" "$agent"
  fi
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
  acq_spin_start "Applying configuration kits"
  _acq_msb_reset_kit_env "$name"
  for kd in "${kitdirs[@]}"; do
    acq_debug "msb provision: applying kit dir $kd ($name)"
    if _acq_msb_apply_kit_dir "$name" "$kd"; then
      acq_debug "msb provision: applied kit dir $kd ($name)"
    else
      echo "acq(msb): warning: kit did not fully apply: $kd" >&2
      echo "acq(msb):   the sandbox is up; re-run 'acq run' to re-apply, or inspect with ACQ_DEBUG=1." >&2
    fi
  done
  acq_spin_stop "Applying configuration kits"
  acq_debug "msb provision: all kits applied; provision complete ($name)"

  # Start the in-guest socat bridge for the host ssh-agent forward (ADR-0021).
  # The --vsock route only exposes the host socket at guest AF_VSOCK CID 2:PORT;
  # git/ssh speak a unix socket path, so socat bridges the two. Only starts when
  # forwarding is active AND socat is present in the guest (checked first so a
  # missing socat is a clear warning, not a broken bridge). Fail-soft.
  _acq_msb_check_socat "$name" && _acq_msb_start_ssh_agent_bridge "$name"

  # Record host-side bundle provenance now the built-in bundle is applied.
  # Best-effort: a provenance write failure never affects the
  # sandbox. Reached only when provision did not abort earlier under set -e.
  acq_provenance_write msb "$name" || true

  # Persist the CLI (`--kit`) and extra (ACQ_EXTRA_KITS) kit refs so a later
  # `acq start`/`acq restart` can reload them and re-run their startup services
  # (see acq_cli_kits_write). Without this, a resume heals only the built-ins +
  # whatever ACQ_EXTRA_KITS the resume shell happens to export, leaving a
  # `--kit` kit's supervised daemon dead (ports mapped, nothing listening).
  # Best-effort; never affects the sandbox.
  acq_cli_kits_write msb "$name" || true
}

# ---------------------------------------------------------------------------
# _acq_msb_agent_has_install_recipe AGENT — 0 if acq knows how to install AGENT
# ---------------------------------------------------------------------------
# `shell` needs no binary; today only `opencode` has a recipe. Others are baked
# into ACQ_MSB_IMAGE by the user (warned at install time). Keep this in sync with
# _acq_msb_install_agent's case.
_acq_msb_agent_has_install_recipe() {
  acq_agent_has_msb_install_recipe "$1"
}

# _acq_msb_safe_agent_token AGENT -> 0 if AGENT is a safe agent token to
# interpolate into a shell command. Agent tokens are short lowercase names
# (opencode, claude, shell, …); restrict to [a-z-] so a value can never break
# out of the `sh -c "command -v '$agent'"` single-quoting (defense against a
# `acq create "x';…'"` arg or a tampered /var/lib/acq/agent marker). Callers
# that build an `sh -c` string with $agent MUST gate on this first.
_acq_msb_safe_agent_token() {
  acq_agent_safe_token "$1"
}

# ---------------------------------------------------------------------------
# _acq_msb_report_npm_install_failure NAME — diagnose a failed in-guest npm
# install, distinguishing a genuinely-missing npm from an UNREACHABLE registry.
# ---------------------------------------------------------------------------
# A network-cut install (corporate TLS interception → curl (56) unexpected eof /
# HTTP 000, or a resolver that can't see the registry → NXDOMAIN) otherwise reads
# identically to "node/npm isn't installed", which sends users down the wrong
# path (reinstalling node on the HOST, which never touches the guest). Probe the
# actual cause in-guest and print the message that matches it.
#
# Branches:
#   - npm binary absent in-guest      → genuinely-missing message.
#   - npm present + registry probe:
#       unresolved (curl exit 6)       → registry name did not resolve; DNS.
#       unreachable (curl exit / 000)  → TLS/network cut; point at KFM §30.
#       responded / inconclusive       → registry rejected it or a real npm error.
# Reuses the shared _classify_key_status fingerprint so the npm path and the
# USAi path classify curl results identically.
_acq_msb_report_npm_install_failure() {
  local name="$1"
  echo "acq(msb): warning: 'npm install -g $ACQ_MSB_OPENCODE_PKG' failed in '$name'." >&2
  echo "acq(msb):   opencode will not be available on attach." >&2

  # Is npm actually present in the guest? If not, that is the cause outright.
  if ! msb exec "$name" -u 0 -- sh -c 'command -v npm' >/dev/null 2>&1; then
    echo "acq(msb):   Cause: npm is not present in the guest. Use a base image that" >&2
    echo "acq(msb):   ships node/npm, or bake opencode into ACQ_MSB_IMAGE." >&2
    return 0
  fi

  # npm exists — classify reachability of the registry from INSIDE the guest,
  # using the same curl `<http_code>|<exit>` fingerprint as the USAi key probe.
  # Probe the first configured registry host over HTTPS; any HTTP response (even
  # a 404) proves the connection completed, i.e. NOT a network cut.
  local _reg _first_host _raw _status
  _first_host=""
  for _reg in $ACQ_MSB_NPM_HOSTS; do _first_host="$_reg"; break; done
  if [ -n "$_first_host" ] && command -v _classify_key_status >/dev/null 2>&1; then
    _raw=$(msb exec "$name" -u 0 -- sh -c \
      "curl -sS -o /dev/null -w '%{http_code}' https://${_first_host}/; printf '|%s' \"\$?\"" \
      2>/dev/null || true)
    _status=$(_classify_key_status "$_raw")
    case "$_status" in
      unresolved)
        echo "acq(msb):   Cause: the npm registry host (${_first_host}) did not RESOLVE from" >&2
        echo "acq(msb):   the guest. This is DNS, not a missing npm. Point the guest at a" >&2
        echo "acq(msb):   usable resolver via ACQ_MSB_DNS_NAMESERVER, or set ACQ_MSB_NPM_HOSTS" >&2
        echo "acq(msb):   to a mirror the guest can resolve. See docs/KNOWN_FAILURE_MODES.md §30." >&2
        return 0
        ;;
      unreachable)
        echo "acq(msb):   Cause: the npm registry host (${_first_host}) is NOT REACHABLE from" >&2
        echo "acq(msb):   the guest — the connection was cut (TLS 'unexpected eof' / HTTP 000)," >&2
        echo "acq(msb):   NOT a missing npm. This is a network / TLS-interception problem." >&2
        echo "acq(msb):   See docs/KNOWN_FAILURE_MODES.md §30 for diagnosis." >&2
        return 0
        ;;
    esac
  fi

  # npm present and the registry either responded (an HTTP error) or the probe
  # was inconclusive: give neutral guidance without implying node is missing.
  echo "acq(msb):   npm is present and the registry appears reachable, so the install" >&2
  echo "acq(msb):   itself failed (registry rejected the request, disk, or a package" >&2
  echo "acq(msb):   error). Re-run with ACQ_DEBUG=1 to see npm's output, set" >&2
  echo "acq(msb):   ACQ_MSB_NPM_HOSTS for an internal mirror, or bake opencode into" >&2
  echo "acq(msb):   ACQ_MSB_IMAGE." >&2
  return 0
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
        _acq_msb_report_npm_install_failure "$name"
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
# sbx's agent templates are built on `docker/sandbox-templates:shell-docker`
# (which acq also uses as the default ACQ_MSB_IMAGE), whose PUBLISHED base-image
# requirements are (Docker kit-reference, "Base image requirements"):
#   - a non-root `agent` user at UID 1000 with PASSWORDLESS SUDO
#   - a /home/agent home directory owned by `agent`
#   - HTTP proxy env (HTTP_PROXY/HTTPS_PROXY/NO_PROXY) PRESERVED ACROSS SUDO
#   - the agent binary (baked in, or installed via commands.install)
# The default image satisfies the first three already, so this step is a
# short-circuit there (the marker/`id agent` check returns early, and the
# sudoers block merely re-asserts NOPASSWD, which is harmless). A plain OCI base
# override (e.g. node:22-bookworm, which ships `node` at uid 1000 and no `agent`,
# and no sudoers rule) meets NONE of the first three. The msb adapter therefore
# synthesizes them here so both the kits (which run as `-u 1000`) and the agent
# behave as they do on sbx. Idempotent + marker-gated; runs fully offline
# (useradd/adduser/sudoers edits need no network). The uid defaults to 1000; if
# 1000 is taken (e.g. by `node` on a plain base), `agent` is created at the next
# free uid and the kits' `-u 1000` commands still map to it by NAME (see
# _acq_msb_exec_command) with HOME exported.
_acq_msb_ensure_agent_user() {
  local name="$1"
  local marker="/var/lib/acq/agent-user-ready"
  if msb exec "$name" -u 0 -- sh -c "test -f '$marker'" >/dev/null 2>&1; then
    return 0
  fi

  acq_debug "msb: ensuring agent user + /home/agent + passwordless sudo + proxy-preserve in $name"
  # Idempotent, distro-agnostic. If an `agent` user already exists, reuse it
  # (the default image already ships one, so this is the common path).
  # Otherwise create it. NOTE: we do NOT pin uid 1000 — on a plain OCI base
  # override (node:22-bookworm) uid 1000 is already taken by a pre-existing user
  # (`node`), so requesting -u 1000 fails and, worse, can leave /home/agent
  # half-created or root-owned. The kits address the agent BY NAME (our exec
  # translation maps user 1000/agent → `-u agent`), so the uid is irrelevant.
  # What MUST hold is that /home/agent exists and is OWNED BY agent — otherwise
  # every kit command that runs as the agent user (playbook fetch, usai merge)
  # fails with Permission denied. So home creation + ownership is deterministic
  # and its failure is FATAL (previously it was best-effort `|| true`, which
  # silently degraded into a root-owned home and a playbook that never fetched).
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
    # Node REPL on node:22-bookworm as an override). acq always execs an explicit
    # shell/agent, so
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
    echo "acq(msb):   otherwise. The default image" >&2
    echo "acq(msb):   (docker/sandbox-templates:shell-docker) provides the agent user +" >&2
    echo "acq(msb):   sudo; if you overrode ACQ_MSB_IMAGE, ensure your image ships them or" >&2
    echo "acq(msb):   a base with useradd/adduser. Re-run with ACQ_DEBUG=1 for details." >&2
    return 1
  }
  msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# _acq_msb_check_prereqs NAME — verify kit prerequisites are in the base image
# ---------------------------------------------------------------------------
# The pinned kits assume node/git/curl/update-ca-certificates exist in the guest.
# The default ACQ_MSB_IMAGE (docker/sandbox-templates:shell-docker) provides all
# four. If a custom ACQ_MSB_IMAGE lacks one, warn clearly rather than fail silently later — we do
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
    echo "acq(msb):   The default image (docker/sandbox-templates:shell-docker) provides" >&2
    echo "acq(msb):   them; a custom" >&2
    echo "acq(msb):   ACQ_MSB_IMAGE must too (these are NOT installed at runtime because" >&2
    echo "acq(msb):   kit net-rules lock egress to the kits' hosts). Affected kits may" >&2
    echo "acq(msb):   not fully apply. Set ACQ_MSB_SKIP_PREREQ_CHECK=1 to silence." >&2
  else
    acq_debug "msb prereqs present (node/git/curl/update-ca-certificates) in $name"
  fi
}

# ---------------------------------------------------------------------------
# Host ssh-agent / socket forwarding over msb --vsock (ADR-0021)
# ---------------------------------------------------------------------------

# _acq_msb_vsock_flags_into ARRVAR — translate the neutral host-socket forwards
# (common.sh acq_host_socket_forwards) into msb `--vsock HOST:PORT/KIND` create
# flags appended to the named array. Gated on msb >= 0.6.9 (the first release
# with --vsock): a lower version WARNS ONCE and emits nothing, because
# forwarding is opt-in convenience and must never turn a create into a hard
# failure. Sets _ACQ_MSB_SSH_AGENT_FORWARDING=1 when an ssh-agent forward is
# emitted, so provision knows to start the in-guest socat bridge and record the
# persistence marker. See ADR-0021.
_acq_msb_vsock_flags_into() {
  local _arr="$1" _line _path _port _kind _label _current
  # Collect the requested forwards first so the version gate can decide whether
  # anything is even being asked for (only warn when a forward was requested).
  local _forwards=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && _forwards+=("$_line")
  done <<EOF
$(acq_host_socket_forwards)
EOF
  [ "${#_forwards[@]}" -gt 0 ] || return 0

  _current=$(_acq_msb_version)
  if [ "$(_acq_msb_version_ge "$_current" "$MIN_MSB_VSOCK_VERSION")" -ne 0 ]; then
    echo "acq(msb): host ssh-agent/socket forwarding needs msb >= ${MIN_MSB_VSOCK_VERSION}" \
         "(found ${_current}); skipping. Upgrade msb to forward the host ssh-agent" \
         "into the guest." >&2
    return 0
  fi

  local _f
  for _f in "${_forwards[@]}"; do
    # Each line is "HOST_PATH<TAB>PORT<TAB>KIND<TAB>LABEL" (see common.sh).
    _path=$(printf '%s' "$_f" | cut -f1)
    _port=$(printf '%s' "$_f" | cut -f2)
    _kind=$(printf '%s' "$_f" | cut -f3)
    _label=$(printf '%s' "$_f" | cut -f4)
    eval "$_arr+=(--vsock \"\${_path}:\${_port}/\${_kind}\")"
    if [ "$_label" = "ssh-agent" ]; then
      _ACQ_MSB_SSH_AGENT_FORWARDING=1
      # Make the implicit opt-in a CONSCIOUS choice (ADR-0021 trust-boundary):
      # SSH_AUTH_SOCK being set is the only trigger, so a user who always exports
      # it (tmux/screen/profile persistence) could forward their agent into a
      # guest running untrusted code without a deliberate per-run decision. Print
      # a one-time notice naming the opt-out and the ssh-add -c mitigation so the
      # forward is never silent. Guarded by a module flag so it prints once even
      # if the helper runs more than once in a process (create + a later probe).
      if [ "${_ACQ_MSB_SSH_AGENT_NOTICE_SHOWN:-0}" != "1" ]; then
        _ACQ_MSB_SSH_AGENT_NOTICE_SHOWN=1
        echo "acq(msb): forwarding your host ssh-agent into the guest because SSH_AUTH_SOCK" \
             "is set. Guest code can use every key the agent holds while the sandbox runs;" \
             "unset SSH_AUTH_SOCK to opt out, or run 'ssh-add -c' to confirm each use. See ADR-0021." >&2
      fi
    fi
  done
}

# _acq_msb_check_socat NAME — return 0 iff socat is present in the guest, else
# warn and return non-zero. Only meaningful when host ssh-agent forwarding is
# active (the socat bridge translates the --vsock route back to a unix socket).
# We warn rather than install: egress is locked to the kits' hosts, so a package
# mirror is unreachable during provision. See ADR-0021.
_acq_msb_check_socat() {
  local name="$1"
  [ "${_ACQ_MSB_SSH_AGENT_FORWARDING:-0}" = "1" ] || return 1
  if msb exec "$name" -- sh -c 'command -v socat >/dev/null 2>&1' </dev/null >/dev/null 2>&1; then
    return 0
  fi
  echo "acq(msb): warning: socat not found in the guest; host ssh-agent forwarding" \
       "needs socat to bridge the vsock route to a unix socket. Bake socat into" \
       "ACQ_MSB_IMAGE. git signing will fail until then." >&2
  return 1
}

# _acq_msb_start_ssh_agent_bridge NAME — (re)start the in-guest socat bridge that
# exposes the forwarded host ssh-agent as a unix socket at
# ACQ_MSB_SSH_AGENT_GUEST_SOCK. The --vsock route persists across msb stop/start,
# but the socat process dies on stop, so this runs on provision AND on
# acq_backend_start (mirrors _acq_msb_grant_oci_devs). Fail-soft: warns, never
# aborts. Works from EITHER the in-provision flag OR the persisted marker (start
# has no provision flag set), so the guest sock path is resolved from whichever
# source is authoritative for the call. See ADR-0021.
_acq_msb_start_ssh_agent_bridge() {
  local name="$1" _sock="" _port="$ACQ_MSB_SSH_AGENT_VSOCK_PORT"
  if [ "${_ACQ_MSB_SSH_AGENT_FORWARDING:-0}" = "1" ]; then
    _sock="$ACQ_MSB_SSH_AGENT_GUEST_SOCK"
  else
    # No provision ran this path (e.g. acq_backend_start): read the persisted
    # marker recorded at provision. Empty marker => forwarding not configured.
    _sock=$(_acq_msb_ssh_auth_sock_for "$name")
    [ -n "$_sock" ] || return 0
  fi

  # The guest sock path and port are acq's own constants (word-safe charset), so
  # there is no injection risk; still keep them as fixed literals in the sh -c.
  # A SINGLE socat under nohup (detached): the --vsock route reconnects lazily,
  # and the bridge is re-launched fresh on each provision/start, so no supervisor
  # loop is needed. `rm -f` clears any stale socket before re-listening.
  msb exec "$name" -u agent -- sh -c "
    mkdir -p \"\$(dirname '$_sock')\" 2>/dev/null || true
    rm -f '$_sock' 2>/dev/null || true
    nohup socat UNIX-LISTEN:'$_sock',fork,reuseaddr VSOCK-CONNECT:2:'$_port' >/dev/null 2>&1 &
  " </dev/null >/dev/null 2>&1 || {
    echo "acq(msb): warning: failed to start the ssh-agent bridge in '$name'." >&2
    return 0
  }

  # Record the guest sock path so attach/exec/start can resolve SSH_AUTH_SOCK
  # even when no provision flag is set. Only written when forwarding is active.
  msb exec "$name" -u 0 -- sh -c \
    "mkdir -p /var/lib/acq && printf '%s' '$_sock' > /var/lib/acq/ssh-auth-sock" \
    </dev/null >/dev/null 2>&1 || true
  acq_debug "msb: ssh-agent bridge started at $_sock (vsock port $_port) in $name"

  # Liveness probe (ADR-0021): the bridge + marker are now in place, but the
  # create-time --vsock route's HOST endpoint can be STALE — most commonly after
  # a host reboot, which restarts the host ssh-agent under a NEW socket path
  # while the sandbox's persisted route still points at the OLD one. msb start /
  # re-attach resume the sandbox with that persisted route; nothing re-derives
  # it (the route is create-time only). The bridge then connects to a dead host
  # endpoint (`socat … VSOCK-CONNECT` → "Connection reset by peer"), so the guest
  # has SSH_AUTH_SOCK set and socat running yet `ssh-add -l` fails and signing
  # breaks — a silent dead bridge behind a present marker. Probe once and, on
  # failure, surface the recreate remedy instead of failing silently (repo
  # no-silent-failure rule). Best-effort: `|| true` so a warning can NEVER abort
  # the caller (this is the last statement of the bridge starter, which is itself
  # the last statement of acq_backend_start, called bare under `set -euo
  # pipefail` by the start/restart verbs — an unguarded non-zero would abort the
  # whole verb). See ADR-0021 / docs/KNOWN_FAILURE_MODES.md §34.
  _acq_msb_warn_if_agent_unreachable "$name" "$_sock" || true
}

# _acq_msb_warn_if_agent_unreachable NAME SOCK — probe the forwarded agent from
# inside the guest and, if it is unreachable, print an actionable warning naming
# the stale-route-after-reboot cause and the recreate remedy. Returns 0 when the
# agent is reachable (or the probe cannot run), non-zero when it warned, so
# tests can distinguish; every PRODUCTION caller MUST `|| true` this so the
# warn-return can never abort a verb under `set -e`.
#
# The authoritative probe is `ssh-add -l` over the guest sock. Its exit code
# alone is NOT enough to classify the reboot case: when the socat listener socket
# EXISTS (the bridge is running) but its vsock backend is dead, ssh-add connects,
# the agent protocol then fails, and ssh-add exits **1** with
# "error fetching identities: communication with agent failed" — the SAME exit
# code as a healthy-but-empty agent ("The agent has no identities."). Exit 2 is
# only produced when the socket path itself cannot be opened, which is not this
# scenario (the bridge socket is present). So we classify on the MESSAGE:
#   - exit 0                                  -> reachable, has keys        (quiet)
#   - "no identities" / "has no identities"   -> reachable, empty keyring   (quiet)
#   - anything else on failure (incl. the
#     "communication with agent failed" text
#     and a bare exit 2)                      -> dead bridge/route          (WARN)
# A path-compare against the create-time host_socket is deliberately NOT used:
# the host agent socket path is platform-dependent (launchd may keep it stable;
# a plain ssh-agent rotates it), so only a live connect is authoritative. See
# ADR-0021.
_acq_msb_warn_if_agent_unreachable() {
  local name="$1" _sock="$2"
  # Need ssh-add in the guest to probe; if it is absent, skip silently (the
  # forward may still be fine — we simply cannot assert it here).
  msb exec "$name" -u agent -- sh -c 'command -v ssh-add >/dev/null 2>&1' \
    </dev/null >/dev/null 2>&1 || return 0
  # Capture combined output AND exit status. Give the freshly-started socat a
  # brief moment to establish its listener before probing (a fresh create can
  # race the probe); a short bounded wait, not a fixed 1s tax on the common
  # already-running reattach where the listener is already up.
  local _out="" _rc=0
  _out=$(msb exec "$name" -u agent -- sh -c \
    "for _i in 1 2 3; do SSH_AUTH_SOCK='$_sock' ssh-add -l 2>&1 && exit 0; sleep 0.3; done; SSH_AUTH_SOCK='$_sock' ssh-add -l 2>&1" \
    </dev/null 2>/dev/null) || _rc=$?
  # Reachable with keys => quiet.
  [ "$_rc" = "0" ] && return 0
  # Reachable but empty keyring (exit 1 with the "no identities" message) => quiet.
  case "$_out" in
    *"no identities"*) return 0 ;;
  esac
  # Otherwise: cannot talk to the agent (dead bridge/route — the reboot case,
  # whose message is "communication with agent failed", exit 1; or a bare
  # "cannot open a connection" exit 2). Warn with the recreate remedy.
  echo "acq(msb): warning: the forwarded host ssh-agent is UNREACHABLE from the guest" \
       "in '$name' (the create-time --vsock route's host endpoint is stale — most" \
       "commonly after a HOST REBOOT, which gives the host ssh-agent a new socket" \
       "path while the sandbox keeps the old one). SSH_AUTH_SOCK is set but git" \
       "signing will fail. The --vsock route is create-time only, so recreate the" \
       "sandbox to refresh it: 'acq rm $name' then re-run your 'acq run …' (with" \
       "SSH_AUTH_SOCK set). See ADR-0021 / docs/KNOWN_FAILURE_MODES.md §34." >&2
  return 1
}

# _acq_msb_ssh_auth_sock_for NAME — echo the recorded guest ssh-agent sock path
# (the SSH_AUTH_SOCK value git/ssh should use in the guest), or empty when
# forwarding was never configured for this sandbox. Read from the persisted
# marker so run/attach on a name-only re-entry still find it. See ADR-0021.
_acq_msb_ssh_auth_sock_for() {
  local name="$1"
  # Failure-guarded: with the marker absent (forwarding never configured), the
  # in-guest `cat` exits 1 and — under acq's `set -euo pipefail` — the pipeline
  # would otherwise propagate that into the caller's command substitution and
  # kill the whole session verb (the trailing `tr` does NOT mask it: pipefail
  # takes the failing stage's status).
  { msb exec "$name" -u 0 -- sh -c 'cat /var/lib/acq/ssh-auth-sock 2>/dev/null' \
    </dev/null 2>/dev/null || true; } | tr -d '[:space:]'
}

_acq_msb_git_identity_env_flags_into() {
  local _arrn="$1" _line _flag_e _flag_val
  eval "$_arrn=()"
  command -v acq_host_git_identity_env >/dev/null 2>&1 || return 0
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _flag_e="-e"
    _flag_val="$_line"
    eval "$_arrn+=(\"\$_flag_e\" \"\$_flag_val\")"
  done <<EOF
$(acq_host_git_identity_env)
EOF
}

_acq_msb_apply_host_git_global_config() {
  local name="$1" _flags=() _line _flag_e _flag_val
  command -v acq_host_git_global_config_env >/dev/null 2>&1 || return 0
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _flag_e="-e"
    _flag_val="$_line"
    eval "_flags+=(\"\$_flag_e\" \"\$_flag_val\")"
  done <<EOF
$(acq_host_git_global_config_env)
EOF
  [ "${#_flags[@]}" -gt 0 ] || return 0
  msb exec -u agent -e HOME=/home/agent ${_flags[@]+"${_flags[@]}"} "$name" -- sh -c '
    [ -n "${ACQ_GIT_USER_NAME:-}" ] && git config --global user.name "$ACQ_GIT_USER_NAME" 2>/dev/null || true
    [ -n "${ACQ_GIT_USER_EMAIL:-}" ] && git config --global user.email "$ACQ_GIT_USER_EMAIL" 2>/dev/null || true
  ' </dev/null >/dev/null 2>&1 || true
}

# _acq_msb_kit_env_flags_into ARRVAR NAME — build the `-e NAME=value` flag array
# for the kit environment[] entries persisted at /var/lib/acq/kit-env by
# _acq_msb_apply_kit_dir, so every session path (run/attach/shell) sees the env
# the kits declared for agent runtime (see ADR-0011). Empty array when no kit
# declared environment[]. Array passed by name (bash 3.2 compat).
#
# The marker is root-owned but its content is kit-derived guest data: re-validate
# each NAME (same ^[A-Za-z_][A-Za-z0-9_]*$ charset kit_spec_env enforces) so a
# tampered line cannot smuggle an option-shaped or quote-bearing token, and keep
# the LAST value for a duplicate name (kits append in application order, so a
# later kit overrides an earlier one).
_acq_msb_kit_env_flags_into() {
  local _arrn="$1" _name="$2"
  eval "$_arrn=()"
  # Failure-guarded: an absent marker (pre-kit-env sandbox, or no kit declared
  # environment[]) must yield an empty result, not kill the session verb — see
  # _acq_msb_ssh_auth_sock_for.
  local _kvs
  _kvs=$(msb exec "$_name" -u 0 -- sh -c 'cat /var/lib/acq/kit-env 2>/dev/null' \
    </dev/null 2>/dev/null) || _kvs=""
  [ -n "$_kvs" ] || return 0
  local _line
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    eval "$_arrn+=(-e \"\$_line\")"
  done <<EOF
$(printf '%s\n' "$_kvs" | awk '
  {
    i = index($0, "=")
    if (i < 2) next
    k = substr($0, 1, i - 1)
    if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
    v[k] = substr($0, i + 1)
    if (!(k in seen)) { seen[k] = 1; order[++n] = k }
  }
  END { for (j = 1; j <= n; j++) printf "%s=%s\n", order[j], v[order[j]] }
')
EOF
}

# _acq_msb_ensure_ssh_agent_forward NAME — (re)establish the host ssh-agent
# forward on a RUNNING sandbox that acq is re-attaching to. See ADR-0021.
#
# WHY THIS EXISTS: the provision path wires the forward (emit --vsock, start the
# socat bridge, write the /var/lib/acq/ssh-auth-sock marker), and the
# stopped→resume path (acq_backend_start) restarts the bridge from that marker.
# But re-attaching to an ALREADY-RUNNING sandbox goes through neither: the heal
# loop skips acq_backend_start (the sandbox is already running), so nothing
# re-drives forwarding. That left two live gaps where the guest process env got
# NO `SSH_AUTH_SOCK` on re-attach (attach/exec/kit only inject it when the marker
# is non-empty):
#   1. the marker had never been written (sandbox created before forwarding was
#      configured, or provision skipped the bridge), yet the host agent is now
#      available and the create-time --vsock route is present; and
#   2. the bridge process had died in-flight on a long-lived running sandbox.
# Re-driving here, keyed off the SAME opt-in signal as provision (a host
# SSH_AUTH_SOCK that yields a forward), closes both.
#
# Gated so it is a cheap no-op in the common case:
#   - host forward requested? (acq_host_socket_forwards emits an ssh-agent line)
#   - guest actually has the create-time --vsock route? (the route is create-time
#     only — it cannot be added to a running sandbox, so if it is absent, a bridge
#     would be inert and we must NOT write a misleading marker)
# When both hold, flip the module forwarding flag (so _acq_msb_check_socat and
# the bridge starter resolve the guest sock from the constant, not a possibly
# empty marker), verify socat, then start the bridge + write the marker — exactly
# the provision sequence. Fail-soft throughout: this is convenience, never fatal.
_acq_msb_ensure_ssh_agent_forward() {
  local name="$1"
  # Cheap opt-out: no host forward requested => nothing to do. Reuse the neutral
  # emitter's decision so this tracks the SSH_AUTH_SOCK opt-in exactly (a set,
  # existing host socket on a supported port). Suppress the emitter's advisory
  # stderr here; provision/attach already surface the trust-boundary notice.
  local _fwd
  _fwd=$(acq_host_socket_forwards 2>/dev/null)
  # Each emitted line is TAB-separated "PATH<TAB>PORT<TAB>KIND<TAB>LABEL"; the
  # ssh-agent forward is the line whose LABEL is exactly "ssh-agent". Match the
  # tab+label token so a custom forward alone (LABEL=custom) does not trigger it.
  case "$_fwd" in
    *"	ssh-agent"*) : ;;             # an ssh-agent forward line was emitted
    *) return 0 ;;                     # no ssh-agent forward requested
  esac

  # The --vsock route is create-time only. If this sandbox was created WITHOUT
  # it, a socat bridge would be inert and the marker would falsely advertise a
  # working agent, so require the route to actually be present before wiring.
  _acq_msb_has_ssh_agent_vsock_route "$name" || return 0

  # From here, treat forwarding as active: point the bridge starter at the guest
  # sock constant (not the possibly-empty marker) and gate on socat as provision
  # does. Set the module flag so _acq_msb_check_socat / the bridge starter both
  # resolve from the constant. It is process-scoped and already reset per run.
  _ACQ_MSB_SSH_AGENT_FORWARDING=1
  _acq_msb_check_socat "$name" && _acq_msb_start_ssh_agent_bridge "$name"
}

# _acq_msb_has_ssh_agent_vsock_route NAME — return 0 iff the sandbox's persisted
# config carries the ssh-agent --vsock route (guest AF_VSOCK CID 2:PORT for the
# ssh-agent port). The route is create-time only, so its presence is the
# authoritative signal that this sandbox CAN carry a forward. Read from
# `msb inspect NAME --format json`; best-effort (a missing tool/field returns
# non-zero, never hard-fails). See ADR-0021.
_acq_msb_has_ssh_agent_vsock_route() {
  local name="$1" json _port="$ACQ_MSB_SSH_AGENT_VSOCK_PORT"
  json=$(msb inspect "$name" --format json 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  # Require BOTH a `vsock` key AND the ssh-agent guest-port token, so a published
  # `ports:[{port:<vsock-port>}]` that merely happens to equal the (user-
  # overridable) vsock port cannot masquerade as a route on a sandbox that has no
  # vsock forwarding at all. We do not have a JSON parser here, so flatten the
  # document (strip quotes/spaces; turn structural punctuation into newlines) and
  # test the two facts independently against the whole flattened form. The real
  # shape is `"vsock":{"routes":[{…,"port":3552}]}` — after flattening, `vsock:`
  # and `port:3552` land on separate lines, so both greps must be run over the
  # full text (not a single line). The port is anchored as a whole token so 3552
  # can't match e.g. 35521. See ADR-0021; shape confirmed against msb 0.6.12.
  local _flat
  _flat=$(printf '%s' "$json" | tr -d '" ' | tr ',{}[]' '\n\n\n\n\n')
  printf '%s\n' "$_flat" | grep -Eq '(^|:)vsock:?$' 2>/dev/null || return 1
  printf '%s\n' "$_flat" | grep -Eq "port[:=]${_port}\$" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _acq_msb_grant_oci_devs NAME — grant the agent access to the device nodes
#                                rootless podman needs (/dev/net/tun, /dev/fuse)
# ---------------------------------------------------------------------------
# Rootless podman needs unprivileged access to two root-only device nodes on the
# default image:
#   - /dev/net/tun (crw------- root root): the network backend (netavark→pasta,
#     or slirp4netns) must open it to set up container networking.
#   - /dev/fuse (crw------- root root): the fuse-overlayfs storage driver (our
#     PREFERRED driver on the overlay root) must open it to mount image layers.
#     Without it `podman info` still passes but `podman run` fails at mount time
#     with "fuse: failed to open /dev/fuse: Permission denied" — the exact
#     info-OK-but-run-FAILS split seen on the host.
# Group-scope each to the agent (chown root:agent, chmod 0660) — inside the
# microVM only (the security boundary), narrower than world-writable, no new host
# attack surface.
#
# Called on EVERY provision pass (before the OCI install marker gate) AND on
# restart (acq_backend_start), because /dev is a devtmpfs re-created at each boot
# — a one-time grant would be lost after `msb start`. Idempotent, cheap, and a
# best-effort no-op for any device that is absent or when ENSURE_OCI is disabled.
_acq_msb_grant_oci_devs() {
  local name="$1"
  [ -n "$ACQ_MSB_ENSURE_OCI" ] || return 0
  msb exec "$name" -u 0 -- sh -c '
    for _dev in /dev/net/tun /dev/fuse; do
      if [ -e "$_dev" ]; then
        chown root:agent "$_dev" 2>/dev/null || true
        chmod 0660 "$_dev" 2>/dev/null || true
      fi
    done' \
    >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# _acq_msb_ensure_oci NAME — ensure an OCI container engine (podman) is usable
# ---------------------------------------------------------------------------
# Guarantee agents can run OCI images inside the sandbox (`docker run`,
# `docker compose up`, etc.). See the ACQ_MSB_ENSURE_OCI block above for the
# rationale (podman over dind; ROOTLESS podman run as the agent user; alias
# docker->podman). This step is idempotent + marker-gated and FAILS SOFT: if the
# engine cannot be provisioned (mirror unreachable under a narrowed egress,
# unknown package manager, rootless prereqs absent, etc.) it warns and returns 0
# — provision continues, OCI is simply unavailable, exactly like the
# agent-install and prereq-check steps. The package INSTALL runs as root
# (`-u 0`, needed to install), but the engine RUNS rootless as the agent user.
_acq_msb_ensure_oci() {
  local name="$1"
  [ -n "$ACQ_MSB_ENSURE_OCI" ] || return 0

  # Grant the rootless-podman device nodes (/dev/net/tun for networking,
  # /dev/fuse for the fuse-overlayfs storage driver) on EVERY provision pass,
  # BEFORE the install-marker short-circuit below. /dev is a devtmpfs re-created
  # each boot, so this must not be gated behind the (persistent) install marker,
  # and it is also re-applied on restart from acq_backend_start.
  _acq_msb_grant_oci_devs "$name"

  local marker="/var/lib/acq/oci-ready"
  if msb exec "$name" -u 0 -- sh -c "test -f '$marker'" >/dev/null 2>&1; then
    return 0
  fi

  # ACQ_MSB_PODMAN_PKGS is operator-controlled config, but it is interpolated
  # into a root `sh -c` string below, so charset-guard it (package names are
  # word-safe: letters, digits, . _ + - and spaces). Refuse anything else rather
  # than risk shell injection into the elevated install.
  case "$ACQ_MSB_PODMAN_PKGS" in
    *[!A-Za-z0-9._+\ -]*)
      echo "acq(msb): warning: ACQ_MSB_PODMAN_PKGS contains unsafe characters; skipping OCI setup." >&2
      return 0
      ;;
  esac

  acq_debug "msb: ensuring an OCI engine (podman) in $name"

  # Root setup phase: install podman if absent (distro-detected, non-interactive),
  # configure a storage driver that works on msb's overlay root, grant the agent
  # access to /dev/net/tun (rootless networking needs it), write a Docker-Hub-first
  # registries config, and wire the docker->podman alias. The engine itself RUNS
  # ROOTLESS as the agent (verified separately, below) — only this install/config
  # phase needs root. The whole block is best-effort; a non-zero exit is caught
  # below and treated as non-fatal.
  #
  # The default image ships a (non-functional) docker CLI, so rather than gate on
  # its absence we place our wrapper in /usr/local/bin (ahead of /usr/bin on the
  # default PATH) to SHADOW it — the bundled docker talks to a dead socket,
  # whereas our wrapper routes to the working podman engine. We overwrite our own
  # wrapper idempotently but never touch the base image's /usr/bin/docker.
  #
  # STORAGE DRIVER: msb's sandbox root filesystem is itself an overlay mount
  # (/.msb/rootfs/...). podman's default KERNEL `overlay` graph driver CANNOT stack
  # on an overlay root — `podman info` fails with "'overlay' is not supported over
  # overlayfs, a mount_program is required". This applies to BOTH rootful and
  # rootless. So we write /etc/containers/storage.conf (honored by rootless as its
  # lowest-precedence source) selecting a driver that works on an overlay root:
  #   - PREFER `overlay` + `mount_program=fuse-overlayfs` when fuse-overlayfs is
  #     present (msb provides /dev/fuse; this is the fast, thin-on-disk path), else
  #   - FALL BACK to `vfs`, which works everywhere with no extra package or
  #     /dev/fuse (correct but disk-heavy — full copy per layer).
  #
  # ROOTLESS NETWORKING: rootless podman's network backend (netavark→pasta, or
  # slirp4netns) must open /dev/net/tun, which is root-only (crw------- root root)
  # on the default image. We group-scope it to the agent (chown root:agent, 0660)
  # so the unprivileged agent can set up container networking. This is inside the
  # microVM only (the security boundary) — no new host attack surface. Applied on
  # EVERY provision pass (outside the install marker gate) because the device node
  # can be re-created with default perms across restarts.
  #
  # REGISTRY RESOLUTION (Docker-Hub-first, ADR-0020): stock podman resolves many
  # unadorned short names to quay.io (e.g. `hello-world` -> quay.io/podman/hello)
  # and has no default unqualified search registry. Users migrating from Docker
  # assume `docker run nginx` means Docker Hub. So we write a system
  # registries.conf setting unqualified-search-registries=["docker.io"] +
  # short-name-mode="$SHORT_NAME_MODE", and a shortnames drop-in remapping the
  # podman `hello`/`hello-world` aliases back to docker.io/library/hello-world.
  # This diverges from stock podman deliberately to reduce migration burden.
  #
  # SHORT-NAME MODE (PR #302 review): the default is "enforcing", NOT permissive.
  # Because there is a single search registry (docker.io), unqualified names STILL
  # resolve deterministically to Docker Hub — migration ergonomics are preserved.
  # "enforcing" only fails closed on interactively-ambiguous short names instead
  # of silently resolving them, which is the least-privilege / prompt-injection
  # defense a federal sandbox wants: an injected `docker run nginx` cannot be
  # silently substituted (typosquatting / image substitution) without a qualified
  # name or an explicit alias. Operators MAY opt into "permissive" (removing that
  # guardrail) via ACQ_MSB_SHORT_NAME_MODE; see the env-var comment above.
  #
  # We add fuse-overlayfs + the rootless prereqs (uidmap, passt, slirp4netns) to
  # the install set so the preferred path is available on the default (apt) image;
  # if the mirror lacks fuse-overlayfs the vfs fallback still yields a working
  # engine.
  if msb exec "$name" -u 0 -e "PODMAN_PKGS=$ACQ_MSB_PODMAN_PKGS" -e "SHORT_NAME_MODE=$ACQ_MSB_SHORT_NAME_MODE" -- sh -c '
    set -e
    # 1) Ensure the podman binary is present (idempotent).
    if ! command -v podman >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        # shellcheck disable=SC2086
        apt-get install -y --no-install-recommends $PODMAN_PKGS
      elif command -v dnf >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        dnf install -y $PODMAN_PKGS
      elif command -v apk >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        apk add --no-cache $PODMAN_PKGS
      else
        echo "acq(msb): no supported package manager (apt-get/dnf/apk) to install podman" >&2
        exit 1
      fi
    fi
    # 2) Select a storage driver that works on msb'"'"'s overlay root. Only write
    #    the config if we have not already (idempotent); do not clobber an operator
    #    file that already names a driver. Prefer fuse-overlayfs, else vfs.
    if ! grep -q '"'"'^[[:space:]]*driver'"'"' /etc/containers/storage.conf 2>/dev/null; then
      mkdir -p /etc/containers
      _fuse=""
      for _c in /usr/bin/fuse-overlayfs /usr/local/bin/fuse-overlayfs /bin/fuse-overlayfs; do
        [ -x "$_c" ] && _fuse="$_c" && break
      done
      if [ -z "$_fuse" ] && command -v fuse-overlayfs >/dev/null 2>&1; then
        _fuse=$(command -v fuse-overlayfs)
      fi
      if [ -n "$_fuse" ] && [ -e /dev/fuse ]; then
        printf "[storage]\ndriver = \"overlay\"\n[storage.options.overlay]\nmount_program = \"%s\"\n" "$_fuse" \
          > /etc/containers/storage.conf
      else
        printf "[storage]\ndriver = \"vfs\"\n" > /etc/containers/storage.conf
      fi
    fi
    # 3) Grant the agent access to /dev/net/tun + /dev/fuse for rootless podman —
    #    handled by _acq_msb_grant_oci_devs (called un-gated above AND on restart),
    #    NOT here, because /dev is a devtmpfs re-created each boot: a grant baked
    #    behind the install marker would be lost after `msb start`. (No-op here.)
    # 4) Docker-Hub-first registry resolution (ADR-0020). System-level so it
    #    applies to the rootless agent (read as the lowest-precedence source).
    #    Idempotent: overwrite our own files each pass.
    mkdir -p /etc/containers/registries.conf.d
    printf "unqualified-search-registries = [\"docker.io\"]\nshort-name-mode = \"$SHORT_NAME_MODE\"\n" \
      > /etc/containers/registries.conf.d/00-acq-docker-first.conf
    printf "[aliases]\n\"hello-world\" = \"docker.io/library/hello-world\"\n\"hello\" = \"docker.io/library/hello-world\"\n" \
      > /etc/containers/registries.conf.d/01-acq-shortnames.conf
    # 5) Alias docker -> podman in /usr/local/bin (ahead of /usr/bin on PATH), so
    #    `docker run …` and `docker compose …` route to the podman engine. A tiny
    #    exec wrapper (not a symlink) so `docker compose` -> `podman compose`
    #    dispatches through podman'"'"'s compose provider (podman-compose).
    #    Plain `podman` (NOT sudo): the engine runs ROOTLESS as the agent user, so
    #    the agent invokes podman directly. The heredoc is FLUSH-LEFT so the
    #    shebang is not indented; `\$@` is escaped so the guest writes the LITERAL
    #    `"$@"` into the wrapper.
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/docker <<EOF
#!/bin/sh
exec podman "\$@"
EOF
    chmod 0755 /usr/local/bin/docker
  ' >/dev/null 2>&1; then
    # Root setup succeeded. Now VERIFY the engine works ROOTLESS as the agent user
    # — the way agents actually use it. A bare `podman info` as root would prove
    # the wrong thing (rootful), so we probe as the agent. CRUCIALLY we do more
    # than `podman info`: info does NOT open /dev/fuse or mount a layer, so it
    # passes even when the fuse-overlayfs storage mount would fail (the exact
    # /dev/fuse-permission trap). We therefore verify with a real LAYER MOUNT: a
    # `podman build` FROM scratch (no registry pull, no egress). If it fails with
    # the configured driver, the agent forces a USER-level vfs storage.conf and
    # retries once (covers a base whose overlay+fuse combo is still rejected under
    # rootless). Only a successful build writes the ready marker.
    if msb exec "$name" -u agent -e HOME=/home/agent -- sh -c '
      _oci_selftest() {
        d=$(mktemp -d) || return 1
        printf "FROM scratch\nCOPY hi /hi\n" > "$d/Containerfile"
        echo hi > "$d/hi"
        podman build -q -t acq-oci-selftest:local "$d" >/dev/null 2>&1
        rc=$?
        podman rmi -f acq-oci-selftest:local >/dev/null 2>&1 || true
        rm -rf "$d"
        return $rc
      }
      _oci_selftest && exit 0
      # Retry once with a user-level vfs storage.conf (overlay+fuse rejected).
      mkdir -p "$HOME/.config/containers"
      printf "[storage]\ndriver = \"vfs\"\n" > "$HOME/.config/containers/storage.conf"
      _oci_selftest
    ' >/dev/null 2>&1; then
      # Best-effort: mark ready so we do not re-run the (network-bound) install on
      # every provision/restart. (The /dev/net/tun grant and config writes above
      # are cheap + idempotent and re-run each pass regardless of this marker.)
      msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" >/dev/null 2>&1 || true
      acq_debug "msb: OCI engine (rootless podman) ready in $name"
      return 0
    fi
  fi

  # Fail soft (ADR-0020 / the balanced-egress-off case). Name the mirror hosts and
  # the rootless prereqs so the operator can allow-list / bake them into ACQ_MSB_IMAGE.
  echo "acq(msb): warning: could not provision an OCI engine (rootless podman) in '$name'." >&2
  echo "acq(msb):   Agents will not be able to run OCI images (docker run / docker compose)." >&2
  echo "acq(msb):   Most likely the OS package mirror is unreachable: the default balanced" >&2
  echo "acq(msb):   egress (ADR-0018) allows it, but ACQ_NETWORK_TIER=strict or a narrowed" >&2
  echo "acq(msb):   custom base blocks archive.ubuntu.com / ports.ubuntu.com / *.debian.org," >&2
  echo "acq(msb):   or the rootless prereqs (podman, fuse-overlayfs, uidmap, passt," >&2
  echo "acq(msb):   slirp4netns) could not be installed / rootless podman could not start." >&2
  echo "acq(msb):   Bake those into ACQ_MSB_IMAGE, widen egress, or set ACQ_MSB_ENSURE_OCI=0" >&2
  echo "acq(msb):   to silence this warning." >&2
  return 0
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
  # If the host ssh-agent is forwarded, git/ssh in the guest must see
  # SSH_AUTH_SOCK pointing at the in-guest bridge socket. See ADR-0021.
  # Kit-declared environment[] entries persisted at provision are replayed the
  # same way, mirroring the flag order the provisioning execs use (HOME, sock,
  # then kit env — see _acq_msb_exec_flags_into).
  local _sock _gitident=() _kitenv=()
  _sock=$(_acq_msb_ssh_auth_sock_for "$name")
  _acq_msb_apply_host_git_global_config "$name"
  _acq_msb_git_identity_env_flags_into _gitident
  _acq_msb_kit_env_flags_into _kitenv "$name"
  if [ -n "$_sock" ]; then
    msb exec -u agent -e HOME=/home/agent -e "SSH_AUTH_SOCK=$_sock" \
      ${_gitident[@]+"${_gitident[@]}"} ${_kitenv[@]+"${_kitenv[@]}"} "$name" "$@"
  else
    msb exec -u agent -e HOME=/home/agent ${_gitident[@]+"${_gitident[@]}"} \
      ${_kitenv[@]+"${_kitenv[@]}"} "$name" "$@"
  fi
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
  # Both marker reads are failure-guarded so an absent marker takes the
  # documented fallback instead of killing the attach (see
  # _acq_msb_ssh_auth_sock_for).
  local ws="${ACQ_MSB_WORKSPACE:-}"
  if [ -z "$ws" ]; then
    ws=$({ msb exec "$name" -u 0 -- sh -c 'cat /var/lib/acq/workspace 2>/dev/null' </dev/null 2>/dev/null || true; } | tr -d '\r\n')
  fi
  [ -n "$ws" ] || ws="/home/agent"

  # Read the agent recorded at provision. Default to `shell` if unset. The value
  # comes from a guest file (/var/lib/acq/agent); charset-guard it before it
  # enters the `sh -c "command -v '$agent'"` below, since a tampered marker could
  # otherwise break the single-quoting and run as the agent user. Fall back to a
  # plain shell on anything unexpected.
  local agent
  agent=$({ msb exec "$name" -u 0 -- sh -c 'cat /var/lib/acq/agent 2>/dev/null' </dev/null 2>/dev/null || true; } | tr -d '[:space:]')
  if [ -z "$agent" ] || ! _acq_msb_safe_agent_token "$agent"; then
    agent="shell"
  fi

  # Common flags for the interactive attach: PTY, agent user, workspace cwd, and
  # a sane $SHELL (msb's default interactive shell is the base image's Node REPL).
  # exec so acq hands the terminal straight to msb (no wrapper between TTY & PTY).
  #
  # When the host ssh-agent is forwarded, also point the session at the in-guest
  # bridge socket so git signing (and any ssh) reaches the agent. Held in an
  # optional array so the flag is simply absent when forwarding is inactive; the
  # ${arr[@]+…} guard keeps it bash 3.2 + set -u safe. See ADR-0021.
  local _sock _sockflag=()
  _sock=$(_acq_msb_ssh_auth_sock_for "$name")
  [ -n "$_sock" ] && _sockflag=(-e "SSH_AUTH_SOCK=$_sock")

  # Replay the host git identity and kit environment[] so git commits and
  # agent-runtime config (OPENCODE_CONFIG-style vars, see ADR-0011) reach the session.
  local _gitident=() _kitenv=()
  _acq_msb_apply_host_git_global_config "$name"
  _acq_msb_git_identity_env_flags_into _gitident
  _acq_msb_kit_env_flags_into _kitenv "$name"

  if [ "$agent" = "shell" ]; then
    _acq_msb_shell_exec "$name" "$ws"
  fi

  # Pre-check the agent binary AS the agent user; fall back to a shell (with a
  # notice) rather than launching into a broken/blank session if it's missing.
  if ! msb exec -u agent "$name" -- sh -c "command -v '$agent'" </dev/null >/dev/null 2>&1; then
    echo "acq(msb): '$agent' not found in sandbox '$name'; opening a shell instead." >&2
    _acq_msb_shell_exec "$name" "$ws"
  fi

  exec msb exec -t -u agent -w "$ws" -e SHELL=/bin/sh ${_sockflag[@]+"${_sockflag[@]}"} \
    ${_gitident[@]+"${_gitident[@]}"} ${_kitenv[@]+"${_kitenv[@]}"} "$name" -- "$agent" "$@"
}

# _acq_msb_shell_exec NAME [WS] — exec into an interactive login shell as the
# agent user: PTY, workspace cwd, sane $SHELL, and SSH_AUTH_SOCK when the host
# ssh-agent is forwarded (a raw `msb exec` shell gets none of that). Shared by
# _acq_msb_attach's shell paths and the neutral `acq shell` verb. WS skips the
# workspace lookup when the caller already resolved it.
_acq_msb_shell_exec() {
  local name="$1" ws="${2:-}"
  if [ -z "$ws" ]; then
    ws="${ACQ_MSB_WORKSPACE:-}"
    if [ -z "$ws" ]; then
      ws=$({ msb exec "$name" -u 0 -- sh -c 'cat /var/lib/acq/workspace 2>/dev/null' </dev/null 2>/dev/null || true; } | tr -d '\r\n')
    fi
    [ -n "$ws" ] || ws="/home/agent"
  fi
  local _sock _sockflag=() _gitident=() _kitenv=()
  _sock=$(_acq_msb_ssh_auth_sock_for "$name")
  [ -n "$_sock" ] && _sockflag=(-e "SSH_AUTH_SOCK=$_sock")
  _acq_msb_apply_host_git_global_config "$name"
  _acq_msb_git_identity_env_flags_into _gitident
  _acq_msb_kit_env_flags_into _kitenv "$name"
  exec msb exec -t -u agent -w "$ws" -e SHELL=/bin/sh ${_sockflag[@]+"${_sockflag[@]}"} \
    ${_gitident[@]+"${_gitident[@]}"} ${_kitenv[@]+"${_kitenv[@]}"} "$name" -- /bin/sh -l
}

# ---------------------------------------------------------------------------
# acq_backend_shell — interactive human shell (the neutral `acq shell` verb;
# `acq run` relaunches the recorded agent, `acq exec` is non-interactive)
# ---------------------------------------------------------------------------
acq_backend_shell() {
  _acq_msb_shell_exec "$1"
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
  # Clean up derived volumes (ADR-0023) whenever the sandbox is GONE after the
  # remove attempt — not merely when remove succeeded. A failed remove of a
  # still-existing sandbox must not touch volumes that may be in use, but a
  # failed remove of an already-gone sandbox (removed via `msb rm` directly, or
  # a half-failed create that never registered) must still reach the cleanup,
  # or the volumes orphan forever under ~/.microsandbox/volumes/.
  # --clone (ADR-0027): surface unfetched agent commits BEFORE anything is deleted
  # (sbx-parity warning; rm proceeds — the scratch is disposable by contract).
  _acq_msb_clone_warn_unfetched "$1"
  local _rc=0
  msb remove --force "$1" || _rc=$?
  if [ "$_rc" -ne 0 ] && acq_backend_exists "$1"; then
    return "$_rc"
  fi
  _acq_msb_remove_derived_volumes "$1"
  # Same GONE-after-remove-attempt rule as the volumes above: delete the scratch
  # clone and drop the fetch-back remote only once the sandbox is really gone.
  _acq_msb_clone_cleanup "$1"
  return "$_rc"
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

  # 2) Start `msb ssh serve` on an ephemeral loopback port. The helper confirms
  #    the listener is actually alive before returning (dead serve => non-zero),
  #    and publishes the live PID via _ACQ_MSB_LAST_BG_PID ($! is clobbered by the
  #    helper's own liveness probe).
  local sport serve_pid
  sport=$(_acq_msb_pick_ephemeral_port)
  _acq_msb_serve_start "$name" "$sport" || return 1
  serve_pid="$_ACQ_MSB_LAST_BG_PID"

  # 3) Open the backgrounded `ssh -L` tunnel: host H -> guest (sandbox) G. The
  #    helper confirms the forward established (dead ssh => non-zero); tear the
  #    serve listener down if it did not.
  local ssh_pid
  _acq_msb_forward_start "$sport" "$hport" "$gport" || {
    kill "$serve_pid" 2>/dev/null || true
    return 1
  }
  ssh_pid="$_ACQ_MSB_LAST_BG_PID"

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
# Robustness: the previous scheme was `20000 + ($$ % 40000)`, derived
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
# Publishes the live serve PID in _ACQ_MSB_LAST_BG_PID for the caller to capture
# ($! is not reliably the helper's background job across a function boundary, so
# the caller cannot read its own $!). Returns non-zero if the backgrounded serve
# dies within the settle window (e.g. cannot bind the loopback port), so a dead
# listener is never reported as a successful publish (was: unconditional return
# 0, which made the caller's `|| return 1` guard dead for async failures). NOTE:
# this is a best-effort liveness probe, not a durable health guarantee — a serve
# that dies just AFTER the settle window will still be recorded (teardown then
# kills an already-dead pid, which is harmless).
_acq_msb_serve_start() {
  local name="$1" sport="$2"
  acq_debug "msb ssh serve $name --host 127.0.0.1 --port $sport (backgrounded)"
  msb ssh serve "$name" --host 127.0.0.1 --port "$sport" >/dev/null 2>&1 &
  local pid=$!
  # Give the listener a beat to fail fast (bind error, bad sandbox), then confirm
  # it is still alive. kill -0 probes liveness without signalling. `command sleep`
  # bypasses any shell-function `sleep` override so the settle window is real.
  command sleep "${ACQ_MSB_SERVE_SETTLE:-1}" 2>/dev/null || sleep "${ACQ_MSB_SERVE_SETTLE:-1}"
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    echo "acq(msb): ports: 'msb ssh serve' on 127.0.0.1:${sport} exited immediately (could not start listener)." >&2
    return 1
  fi
  # Publish the pid explicitly: the caller cannot read its own $! for a job this
  # function backgrounded, so hand it over by name.
  _ACQ_MSB_LAST_BG_PID="$pid"
  return 0
}

# _acq_msb_forward_start SPORT HPORT GPORT — background OpenSSH -L local forward.
# Binds host 127.0.0.1:HPORT to the SANDBOX's 127.0.0.1:GPORT (the -L destination
# resolves INSIDE the guest, per ADR-0015). Uses the acq key + a dedicated
# known_hosts under acq state (accept-new against the ephemeral loopback listener).
# Publishes the live ssh PID in _ACQ_MSB_LAST_BG_PID. Returns non-zero if the
# forward dies within the settle window (ExitOnForwardFailure makes ssh exit fast
# when the local bind/forward fails), so a failed tunnel is never reported as a
# successful publish. Best-effort liveness probe (see _acq_msb_serve_start): a
# forward that dies just after the settle window will still be recorded.
_acq_msb_forward_start() {
  local sport="$1" hport="$2" gport="$3"
  if ! command -v ssh >/dev/null 2>&1; then
    echo "acq(msb): ports: ssh not found on PATH (needed for -L forwarding)." >&2
    return 1
  fi
  acq_debug "ssh -p $sport -N -L 127.0.0.1:${hport}:127.0.0.1:${gport} ${ACQ_MSB_SSH_USER}@127.0.0.1"
  # -o IdentitiesOnly=yes: use ONLY the acq -i key, so a loaded agent/other keys
  #   can't burn MaxAuthTries before it. -F none: ignore the user's ~/.ssh/config
  #   so the loopback tunnel is hermetic and cannot be altered out from under acq.
  ssh -p "$sport" -N \
    -F none \
    -i "$ACQ_MSB_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=${ACQ_MSB_SSH_KNOWN_HOSTS}" \
    -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:${hport}:127.0.0.1:${gport}" \
    "${ACQ_MSB_SSH_USER}@127.0.0.1" >/dev/null 2>&1 &
  local pid=$!
  command sleep "${ACQ_MSB_FORWARD_SETTLE:-1}" 2>/dev/null || sleep "${ACQ_MSB_FORWARD_SETTLE:-1}"
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    echo "acq(msb): ports: ssh -L 127.0.0.1:${hport} -> 127.0.0.1:${gport} failed to establish (forward rejected or bind in use)." >&2
    return 1
  fi
  _ACQ_MSB_LAST_BG_PID="$pid"
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
    printf 'sandbox %s -> host 127.0.0.1:%s (post-hoc ssh -L)\n' \
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
    # `|| true`: acq runs under `set -euo pipefail`; a jq that emits nothing (no
    # ports) can still exit non-zero and would otherwise abort this query.
    lines=$(printf '%s' "$json" | jq -r '
      [ ((.active_config.network.ports?) // (.config.network.ports?)
          // .ports? // .portMappings? // .publishedPorts? // [])[]?
        | if type=="string" then .
          elif type=="object" then
            (((.host_port // .hostPort // .host)|tostring) + ":" +
             ((.guest_port // .guestPort // .guest // .container)|tostring))
          else empty end ]
      | .[]?' 2>/dev/null) || true
  fi
  if [ -z "$lines" ]; then
    # jq absent/failed: dependency-free. Read the ports array as flat key:value
    # tokens and pull explicit host_port/guest_port pairs. We match ONLY the
    # *_port keys so `host_bind: "127.0.0.1"` can't leak dotted-IP digits.
    # `|| true`: with no ports the `grep` matches nothing and exits 1, which under
    # `set -euo pipefail` would abort this LIST query (a query must never hard-
    # fail); swallow it so an empty result stays a clean rc=0.
    lines=$(printf '%s' "$json" \
      | tr -d '" ' \
      | tr ',{}[]' '\n\n\n\n\n' \
      | grep -E '^(host_port|guest_port):[0-9]{1,5}$' 2>/dev/null \
      | _acq_msb_pair_lines) || true
  fi
  [ -n "$lines" ] || return 0
  printf '%s\n' "$lines" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    h="${line%%:*}"; g="${line#*:}"
    case "$h" in ""|*[!0-9]*) continue ;; esac
    case "$g" in ""|*[!0-9]*) continue ;; esac
    printf 'sandbox %s -> host 127.0.0.1:%s (create-time -p)\n' "$g" "$h"
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
  # Volumes are creation-time only (ADR-0023): a mid-life apply cannot attach
  # them, so say so instead of leaving the kit's storage requirement silently
  # unmet. (Provision-time applies do not pass here — their volumes were
  # mounted at create.)
  if [ -n "$(kit_spec_volumes "${kitdir}/spec.yaml" 2>/dev/null)" ]; then
    echo "acq(msb): note: this kit declares volumes:, which apply at CREATE time only —" >&2
    echo "acq(msb):   this apply skips them. Recreate the sandbox (acq rm && acq run) to mount them." >&2
  fi
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
  # START-IF-STOPPED (ADR-0017). This heal loop drives `msb exec` against
  # the guest for every kit (feature-probe, file drops, startup re-run). Those
  # exec calls FAIL against a STOPPED guest, so a stopped sandbox must be started
  # BEFORE any healing. This is also what makes `acq run <stopped-sandbox>` work
  # end-to-end: the dispatcher's `run` path (and the `start`/`restart` verb) call
  # ensure_kits_applied BEFORE acq_backend_attach, and attach's own `msb exec`
  # would likewise fail on a stopped guest — so starting here, at the TOP of the
  # heal, covers both the heal and the subsequent attach with a single guarded
  # start. Idempotent: an already-running sandbox is a harmless no-op (guarded by
  # _acq_msb_is_running). acq_backend_start itself BLOCKS on exec-readiness before
  # returning (see its definition — the S1 readiness fix), so we do not repeat the
  # exec-ready wait here: the guest is booted and exec-ready by the time the resume
  # returns. Starting is best-effort — a start/readiness failure emits a warning
  # but does not abort the heal. We do NOT suppress acq_backend_start's stderr:
  # `msb start` diagnoses the real cause (e.g. a missing bound secret) on its own
  # stderr, and masking it with only a generic warning would hide the root cause
  # (repo Failure-Handling rule: report and diagnose, don't mask).
  if ! _acq_msb_is_running "$name"; then
    acq_debug "msb ensure_kits_applied: $name is stopped; starting before heal"
    acq_backend_start "$name" >/dev/null || \
      echo "acq(msb): warning: 'msb start $name' failed (see the error above); healing may not apply." >&2
  fi
  # Re-establish the host ssh-agent forward on THIS re-attach (ADR-0021). The
  # provision path wires it and acq_backend_start restarts the bridge on a
  # stopped→resume; but a re-attach to an ALREADY-RUNNING sandbox reaches neither
  # (the start-if-stopped block above is a no-op), so nothing would (re)start the
  # bridge or write the SSH_AUTH_SOCK marker that attach/exec/kit injection keys
  # off. Without this, re-attaching to a running sandbox left the guest process
  # env with no SSH_AUTH_SOCK even though the create-time --vsock route was
  # present — the reported "have to export SSH_AUTH_SOCK by hand" symptom. Cheap
  # no-op when no host forward is requested or the sandbox has no vsock route.
  _acq_msb_ensure_ssh_agent_forward "$name"
  local kits=("$ZSCALER_KIT" "$USAI_KIT" "$PLAYBOOK_KIT" "$GITSSHSIGN_KIT")
  local builtin_count="${#kits[@]}"
  if [ -n "${ACQ_EXTRA_KITS:-}" ]; then
    local _extras=()
    split_noglob _extras "$ACQ_EXTRA_KITS"
    kits+=("${_extras[@]}")
  fi
  # CLI-supplied `--kit <ref>` refs (ACQ_CLI_KITS) MUST be healed too, exactly as
  # the provision path folds them in (see acq_backend_provision's kit assembly).
  # These kits' STARTUP-phase commands (e.g. openchamber's supervisor loops for
  # the shared `opencode serve` and the web UI) are re-run only by this heal —
  # `msb start` alone does not replay them (ADR-0017). Omitting them here meant a
  # resumed/rebooted sandbox came back with the create-time `-p` port mappings
  # intact but NOTHING listening behind them, because the kit's startup was never
  # re-run: `acq ports` showed the ports mapped while the services were dead. Fold
  # ACQ_CLI_KITS in so `acq run --kit … <existing-sandbox>` heals its full kit set.
  if [ "${#ACQ_CLI_KITS[@]}" -gt 0 ]; then
    kits+=("${ACQ_CLI_KITS[@]}")
  fi
  local kitref kitdir i=0 ok=1
  acq_spin_start "Refreshing configuration kits"
  _acq_msb_reset_kit_env "$name"
  for kitref in "${kits[@]}"; do
    kitdir=$(_acq_msb_fetch_kit "$kitref") || {
      echo "acq(msb): warning: could not fetch kit for healing: $kitref" >&2
      # A built-in kit that can't even be fetched means we cannot claim the
      # bundle is current. Extra-kit fetch failures don't affect the verdict.
      [ "$i" -lt "$builtin_count" ] && ok=0
      i=$((i + 1))
      continue
    }
    if ! _acq_msb_apply_kit_dir "$name" "$kitdir"; then
      [ "$i" -lt "$builtin_count" ] && ok=0
    fi
    i=$((i + 1))
  done
  acq_spin_stop "Refreshing configuration kits"
  # Record host-side bundle provenance ONLY when every built-in kit applied.
  # msb re-applies all built-in kits idempotently, so on full
  # success the sandbox carries the currently pinned bundle. Best-effort write.
  if [ "$ok" -eq 1 ]; then
    acq_provenance_write msb "$name" || true
    return 0
  fi
  return 1
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
  # OPT-OUT of the live-refeed sweep. A GLOBAL `acq secret set -g <svc>` normally
  # re-feeds EVERY running sandbox so a rotated key takes effect without recreate.
  # That is correct for an operator, but destructive for an out-of-band caller
  # (notably scripts/verify-backends) that seeds a throwaway global key while the
  # user has their OWN live sandbox running: the sweep rebinds — and the paired
  # `secret rm -g` UNBINDS — the user's sandbox, breaking its USAi injection.
  # ACQ_SECRET_NO_LIVE_REFEED=1 makes set/rm store-only (no `msb modify` against
  # running VMs). The verifier sets it; interactive users never do.
  if [ -n "${ACQ_SECRET_NO_LIVE_REFEED:-}" ]; then
    acq_debug "msb modify: live refeed suppressed (ACQ_SECRET_NO_LIVE_REFEED)"
    printf '0\n'; return 0
  fi
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

# _acq_msb_secret_set_guidance SERVICE ENV HOST APPLIED — print a concise
# post-set confirmation. Storage/injection mechanics (bindings, on-the-wire
# substitution) are documented in the README and docs; the CLI only confirms
# what happened. An unmapped custom endpoint still needs the actionable
# --host/--env hint so the user can make it bindable.
_acq_msb_secret_set_guidance() {
  local service="$1" _env="$2" _host="$3" applied="$4"
  # NOTE: every `[ "$applied" -gt 0 ] && echo …` below is written as a full
  # if/then, NOT a bare `test && echo`. Under `set -e` a trailing bare `test`
  # that evaluates false makes this function return non-zero, which then
  # propagates through the caller (acq_backend_secret_set) BEFORE its `return 0`
  # — so `acq secret set` exits 1 even though the key was stored (this silently
  # broke both `acq secret set` under a strict shell and the verify-backends
  # seed). The if/then form always leaves a zero status on the false branch.
  case "$service" in
    usai|github)
      echo "acq: stored '$service' in the acq secret store." >&2
      if [ "$applied" -gt 0 ]; then
        echo "      Applied to $applied running sandbox(es); no recreate needed." >&2
      fi
      ;;
    *)
      if [ -n "$_env" ] && [ -n "$_host" ]; then
        echo "acq: stored '$service' in the acq secret store (bound as ${_env}@${_host})." >&2
        if [ "$applied" -gt 0 ]; then
          echo "      Applied to $applied running sandbox(es); no recreate needed." >&2
        fi
      else
        echo "acq: stored '$service' in the acq secret store, but it has no endpoint" >&2
        echo "      mapping, so it cannot be bound. Provide --host HOST --env ENV, e.g.:" >&2
        echo "      acq secret set -g $service --host api.example.com --env API_KEY" >&2
      fi
      ;;
  esac
  return 0
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
  # via `msb --secret ENV@HOST`. Built-ins (usai, github) need no
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
  # Symmetric opt-out with _acq_msb_secret_refeed: when live refeed is suppressed
  # (ACQ_SECRET_NO_LIVE_REFEED=1, e.g. scripts/verify-backends), do NOT reach into
  # running VMs with `msb modify --secret-rm`. Otherwise a throwaway global
  # `secret rm -g` would unbind the secret from the user's OWN live sandbox.
  if [ -n "${ACQ_SECRET_NO_LIVE_REFEED:-}" ]; then
    acq_debug "msb modify --secret-rm: live unbind suppressed (ACQ_SECRET_NO_LIVE_REFEED)"
    printf '0\n'; return 0
  fi
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
  # _acq_secret_key fails closed on an ambiguous (dotted) name;
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
  # NOTE: on msb the throwaway sandbox is NOT the sandbox the agent attaches to.
  # The real running sandbox is re-fed via `msb modify --secret`, which can apply
  # to 0 sandboxes if the real one is still booting. So a throwaway "HTTP 200"
  # here does NOT prove the real sandbox will authenticate — printing it would
  # reproduce the exact 200-then-401 split this change set out to kill. We only
  # use the throwaway to surface a hard-negative early (invalid key / network),
  # and leave the authoritative "validated" verdict to ensure_valid_key's
  # real-sandbox check_key on next attach.
  local status=""
  if command -v check_fresh_sandbox_key >/dev/null 2>&1; then
    acq_spin_start "Validating the new key in a temporary sandbox"
    status=$(check_fresh_sandbox_key)
    acq_spin_stop "Validating the new key in a temporary sandbox"
  fi

  if [ -z "$status" ] || [ "$status" = "200" ]; then
    # No throwaway result, or the throwaway accepted the key. Do NOT claim the
    # real sandbox is validated — the re-feed may not have reached it yet.
    echo "Key stored. It will be validated against the running sandbox on next attach." >&2
    return 0
  fi
  if [ "$status" = "unreachable" ]; then
    # The validation request never reached USAi — a network/egress problem, not
    # the key. Report it as such (no "double-check the key") via the shared
    # helper when available.
    if command -v _report_usai_unreachable >/dev/null 2>&1; then
      _report_usai_unreachable
    else
      echo "acq(msb): could not reach the USAi API to validate — a network/egress" >&2
      echo "      problem (proxy/Zscaler/DNS/offline), not the key itself." >&2
    fi
    return 1
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
  acq_is_known_agent "$1"
}
