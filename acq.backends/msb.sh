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
# sbx's meaning). msb 0.6.6 has NO post-hoc ports command — ports are published
# only at create/run time via `-p HOST:GUEST` — so this is 0. acq_backend_ports
# accordingly prints the create/run-time mechanism instead of forwarding.
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_PORT_FORWARD=0        # msb publishes ports at create/run only (-p HOST:GUEST), no post-hoc verb
# shellcheck disable=SC2034
ACQ_BACKEND_SUPPORTS_SNAPSHOTS=1           # msb snapshot create/export/import
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

# _acq_msb_service_binding SERVICE -> "ENVVAR<TAB>HOST" for services the msb
# adapter binds via `--secret ENV@HOST`, or empty for services it does not bind.
# Single source of truth for the bind (provision), rotate (set), and unbind
# (secret rm) paths.
#
# NOTE (quickstart#226, gap C): this is still a fixed table (usai + github), not
# generic. An arbitrary stored custom endpoint (`acq secret set SANDBOX --host
# api.example.com --env API_KEY`) is NOT yet bound on msb — closing that requires
# the acq secret store to persist the per-service host/env pair (msb's
# `acq_backend_secret_set` does not yet accept/store --host/--env) and this
# function to read it back. Tracked in #226; out of scope for this PR, which
# generalized the re-feed/rotate machinery and added github via the REST path.
_acq_msb_service_binding() {
  case "$1" in
    usai)   printf '%s\t%s\n' "USAI_API_KEY" "$ACQ_MSB_USAI_HOST" ;;
    github) printf '%s\t%s\n' "GITHUB_TOKEN" "$ACQ_MSB_GITHUB_HOST" ;;
    *)      printf '\t\n' ;;
  esac
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

  local phase="" user="" argv=() reading=0 _i
  for _i in ${_lines[@]+"${!_lines[@]}"}; do
    line="${_lines[$_i]}"
    case "$line" in
      "__CMD__"*)
        # __CMD__<TAB>phase<TAB>user
        phase=$(printf '%s' "$line" | cut -f2)
        user=$(printf '%s' "$line" | cut -f3)
        argv=()
        reading=1
        ;;
      "__END__")
        reading=0
        _acq_msb_exec_command "$name" "$phase" "$user" \
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
# Args: NAME PHASE USER [NAME=value ...] -- ARGV...
# The optional NAME=value tokens before the literal `--` are the kit's
# environment[] entries; each is threaded to `msb exec` as `-e NAME=value`.
# kit_spec_env already validated the names, so they are safe to pass here.
_acq_msb_exec_command() {
  local name="$1" phase="$2" user="$3"
  shift 3

  # Split leading NAME=value env tokens (up to the `--` sentinel) from argv.
  local _kit_env=() _tok
  while [ "$#" -gt 0 ]; do
    _tok="$1"; shift
    if [ "$_tok" = "--" ]; then break; fi
    _kit_env+=("$_tok")
  done

  [ "$#" -gt 0 ] || return 0

  # The kits express the unprivileged agent as uid "1000" (the sbx agent-template
  # contract). On a plain OCI base uid 1000 may be a DIFFERENT user (e.g. `node`
  # in node:22-bookworm), so address our provisioned agent by NAME instead, and
  # set HOME=/home/agent so `$HOME`-relative kit logic resolves correctly.
  local uflag=() eflag=()
  case "$user" in
    ""|0|root)
      [ -n "$user" ] && uflag=(-u "$user")
      ;;
    1000|agent)
      uflag=(-u agent)
      eflag=(-e "HOME=/home/agent")
      ;;
    *)
      uflag=(-u "$user")
      ;;
  esac

  # Append the kit's declared guest env as additional `-e NAME=value` flags.
  local _ev
  for _ev in ${_kit_env[@]+"${_kit_env[@]}"}; do
    eflag+=(-e "$_ev")
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
  case " ${_kit_env[*]-} " in
    *" GIT_TERMINAL_PROMPT="*) : ;;
    *) eflag+=(-e "GIT_TERMINAL_PROMPT=0" -e "GIT_ASKPASS=/bin/false" -e "SSH_ASKPASS=/bin/false") ;;
  esac

  if [ "$phase" = "install" ]; then
    # Idempotency marker keyed by a hash of the argv. The marker lives under
    # /var/lib/acq (root-owned) and is both TESTED and WRITTEN as uid 0, so the
    # gate is independent of the install command's own user — a non-root install
    # phase is still run-once (the command's uid may not be able to read a
    # root-created marker, which would otherwise re-run it every apply).
    local marker
    marker="/var/lib/acq/install-$(printf '%s\0' "$@" | cksum | cut -d' ' -f1)"
    if msb exec "$name" -u 0 -- sh -c "test -f '$marker'" </dev/null >/dev/null 2>&1; then
      acq_debug "msb cmd[install] already done (marker hit): $*"
      return 0
    fi
    acq_debug "msb cmd[install] START (user=${user:-0}): $*"
    msb exec "$name" "${uflag[@]}" ${eflag[@]+"${eflag[@]}"} -- "$@" </dev/null || {
      acq_debug "msb cmd[install] FAILED: $*"
      echo "acq(msb): warning: install command failed for '$name'" >&2
      return 0
    }
    acq_debug "msb cmd[install] DONE: $*"
    msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" </dev/null >/dev/null 2>&1 || true
  else
    # initFiles / startup — run every apply (they are written idempotent).
    acq_debug "msb cmd[${phase}] START (user=${user:-0}): $*"
    msb exec "$name" "${uflag[@]}" ${eflag[@]+"${eflag[@]}"} -- "$@" </dev/null || {
      acq_debug "msb cmd[${phase}] FAILED: $*"
      echo "acq(msb): warning: ${phase} command failed for '$name'" >&2
    }
    acq_debug "msb cmd[${phase}] DONE: $*"
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

acq_backend_run() {
  local name="$1"
  shift
  msb exec "$name" "$@"
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
  msb stop "$1"
}

acq_backend_terminate() {
  msb remove --force "$1"
}

acq_backend_list() {
  msb list "$@"
}

acq_backend_cp() {
  msb copy "$1" "$2"
}

acq_backend_ports() {
  # msb publishes ports at create/run time via -p HOST:GUEST; there is no
  # standalone post-hoc "ports" verb in msb 0.6.6. Surface a clear message and
  # the correct mechanism rather than silently failing.
  local name="$1"
  shift
  echo "acq(msb): msb publishes ports at create/run time, not post-hoc." >&2
  echo "      Re-create the sandbox with a published port, e.g.:" >&2
  echo "        acq --backend msb run opencode <path> -- -p 8080:8080" >&2
  echo "      (msb run/create accept -p HOST:GUEST; args after -- pass through.)" >&2
  return 1
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

acq_backend_secret_set() {
  local service="${1:-}"
  shift || true

  # Parse scope (mirrors the sbx wrapper): -g/--global -> global;
  # a leading bare token before the service -> sandbox name.
  local scope_name=""
  case "$service" in
    -g|--global)
      service="${1:-}"; shift || true
      ;;
    -*)
      ;;
    *)
      local _next="${1:-}"
      case "$_next" in
        ""|-*) ;;
        *) scope_name="$service"; service="$_next"; shift || true ;;
      esac
      ;;
  esac

  if [ -z "$service" ]; then
    echo "acq(msb): secret set: missing service name" >&2
    echo "     usage: acq secret set [-g | SANDBOX] <service>" >&2
    return 1
  fi

  if ! command -v acq_secret_set_interactive >/dev/null 2>&1; then
    echo "acq(msb): internal error: secret store not loaded" >&2
    return 1
  fi

  # Store into the acq-owned store (keychain/file); value read from TTY/stdin.
  acq_secret_set_interactive "$service" "$scope_name" || return 1

  # Live add/rotate: re-feed running sandboxes so a newly-set or rotated secret
  # takes effect without recreate (`msb modify --secret ENV@HOST`; the guest keeps
  # its placeholder, only the injected value changes). Driven off the single
  # binding table so EVERY bound service (usai, github, ...) rotates in place —
  # not just usai. A named scope targets that sandbox; a global set sweeps all
  # running sandboxes. The real value is read from the acq store into a TRANSIENT
  # env var (never argv) that `msb modify` reads, then cleared.
  #
  # SECRET NEVER ON ARGV: the value is placed in the environment via a dynamic
  # `export "$_env=$val"` (an env ENTRY, invisible to `ps`/`/proc/<pid>/cmdline`),
  # NOT via `env NAME=VAL msb …` — there NAME=VAL is an OPERAND on env(1)'s argv
  # and would leak the token to any `ps -ww` for the life of the child. The var
  # is unset immediately after each call.
  local _env _host _binding val applied=0 sb
  _binding=$(_acq_msb_service_binding "$service")
  _env=$(printf '%s' "$_binding" | cut -f1)
  _host=$(printf '%s' "$_binding" | cut -f2)
  if [ -n "$_env" ] && [ -n "$_host" ]; then
    if val=$(acq_secret_resolve "$service" "$scope_name" 2>/dev/null) && [ -n "$val" ]; then
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
    fi
  fi

  # Service-specific guidance.
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
      echo "acq(msb): stored '$service' in the acq secret store. Note: the msb adapter" >&2
      echo "      only binds known services (usai, github) at create today; other" >&2
      echo "      services are stored but not yet wired to a --secret host mapping." >&2
      ;;
  esac
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
acq_backend_secret_rm() {
  local service="${1:-}"
  shift || true

  local scope_name=""
  case "$service" in
    -g|--global)
      service="${1:-}"; shift || true ;;
    -*)
      ;;
    *)
      local _next="${1:-}"
      case "$_next" in
        ""|-*) ;;
        *) scope_name="$service"; service="$_next"; shift || true ;;
      esac
      ;;
  esac

  if [ -z "$service" ]; then
    echo "acq(msb): secret rm: missing service name" >&2
    echo "     usage: acq secret rm [-g | SANDBOX] <service>" >&2
    return 1
  fi

  if ! command -v acq_secret_delete >/dev/null 2>&1; then
    echo "acq(msb): internal error: secret store not loaded" >&2
    return 1
  fi

  # 1) Delete the acq-store value (idempotent).
  local key removed=0
  key=$(_acq_secret_key "$service" "$scope_name")
  acq_secret_delete "$key" && removed=1

  # 2) Live-unbind from running sandboxes via `msb modify --secret-rm ENV`, for
  #    services the adapter actually binds. A named scope targets that sandbox;
  #    a global rm sweeps every running sandbox. Best-effort per sandbox.
  local env_name unbound=0
  env_name=$(_acq_msb_service_binding "$service" | cut -f1)
  if [ -n "$env_name" ]; then
    local sb
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
  fi

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
