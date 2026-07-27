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

# The kits expect an unprivileged `agent` user with HOME=/home/agent (the sbx
# agent-template contract). Plain OCI bases don't provide it, so the adapter
# creates it at provision (see _acq_msb_ensure_agent_user). uid 1000 is the
# preferred id but not required — kit commands address the user by name.
ACQ_MSB_AGENT_UID="${ACQ_MSB_AGENT_UID:-1000}"

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
_acq_msb_wait_for_exec_ready() {
  local name="$1" deadline out
  deadline=$(( $(date +%s) + ACQ_MSB_EXEC_READY_TIMEOUT ))
  while :; do
    out=$(msb exec "$name" -- sh -c 'echo ok' </dev/null 2>/dev/null | tr -d '\r')
    case "$out" in
      *ok*) acq_debug "msb exec-ready: $name"; return 0 ;;
    esac
    [ "$(date +%s)" -ge "$deadline" ] && return 1
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
# KNOWN LIMITATION (agentic-coding-playbook kit on msb): the playbook kit clones
# a PRIVATE GitHub repo over HTTPS. msb 0.6.6 does not substitute the credential
# placeholder for git's HTTPS smart-transport to github.com (the request is
# blocked/unsubstituted regardless of request shape — verified extensively;
# curl's Authorization-header path to api.gsa.usai.gov DOES work). So on msb the
# clone is skipped and the kit warns (it is non-fatal by design). Tracked in
# quickstart#203 (and upstream microsandbox #756/#768/#1170). USAi, git-ssh-sign,
# and zscaler kits are unaffected.
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
  [ -n "$mode" ] && msb exec "$name" -u 0 -- chmod "$mode" "$path" >/dev/null 2>&1 || true
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
  local _kit_env=() eline ekey eval
  while IFS= read -r eline; do
    [ -n "$eline" ] || continue
    ekey=$(printf '%s' "$eline" | cut -f1)
    eval=$(printf '%s' "$eline" | cut -f2-)
    [ -n "$ekey" ] || continue
    _kit_env+=("${ekey}=${eval}")
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

  if [ "$phase" = "install" ]; then
    # Idempotency marker keyed by a hash of the argv. The marker lives under
    # /var/lib/acq (root-owned) and is both TESTED and WRITTEN as uid 0, so the
    # gate is independent of the install command's own user — a non-root install
    # phase is still run-once (the command's uid may not be able to read a
    # root-created marker, which would otherwise re-run it every apply).
    local marker
    marker="/var/lib/acq/install-$(printf '%s\0' "$@" | cksum | cut -d' ' -f1)"
    if msb exec "$name" -u 0 -- sh -c "test -f '$marker'" >/dev/null 2>&1; then
      return 0
    fi
    msb exec "$name" "${uflag[@]}" ${eflag[@]+"${eflag[@]}"} -- "$@" || {
      echo "acq(msb): warning: install command failed for '$name'" >&2
      return 0
    }
    msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" >/dev/null 2>&1 || true
  else
    # initFiles / startup — run every apply (they are written idempotent).
    msb exec "$name" "${uflag[@]}" ${eflag[@]+"${eflag[@]}"} -- "$@" || {
      echo "acq(msb): warning: ${phase} command failed for '$name'" >&2
    }
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

  # Translate the caller's workspace path into a --volume mount. The agent token
  # is the first positional; the workspace path follows. msb does NOT create the
  # host mount path and it FAILS to mount when the guest path mirrors an absolute
  # host path under /tmp (verified: identical host:guest under /tmp starts but
  # the mount silently doesn't appear). So we mount the host workspace at a fixed
  # conventional guest path under the agent home (ACQ_MSB_WORKSPACE), which works
  # reliably. The chosen guest path is exported so the run/attach path can cd there.
  local ws
  ws=$(workspace_path "$@")
  ACQ_MSB_GUEST_WORKSPACE=""
  if [ -n "$ws" ]; then
    if [ ! -d "$ws" ]; then
      echo "acq(msb): error: workspace path does not exist on the host: $ws" >&2
      echo "acq(msb):   msb cannot mount a nonexistent host path. Create it first." >&2
      return 1
    fi
    ACQ_MSB_GUEST_WORKSPACE="${ACQ_MSB_WORKSPACE:-/home/agent/workspace}"
    create_flags+=(--volume "${ws}:${ACQ_MSB_GUEST_WORKSPACE}")
    acq_debug "msb volume: ${ws} -> ${ACQ_MSB_GUEST_WORKSPACE}"
  fi

  # Credentials: read from the acq-owned secret store (keychain/file), scoped to
  # this sandbox first, then global. The real value is read into a TRANSIENT env
  # var (never argv, never the kit spec) and bound with `msb --secret ENV@HOST`,
  # which puts a PLACEHOLDER ($MSB_<env>) in the guest and swaps in the real value
  # on the wire to the allowed host (requires --tls-intercept, set above). The
  # real value never enters the guest.
  #
  # SCOPE (deliberately narrow, verified against msb 0.6.6):
  #   - USAi: bind USAI_API_KEY@api.gsa.usai.gov ONLY. The USAi provider sends the
  #     key as an `Authorization: Bearer` header, which msb substitutes correctly.
  #   - GitHub: NOT bound here. msb 0.6.6 does not substitute the placeholder for
  #     git's HTTPS clone to github.com (verified extensively: the request is
  #     blocked/unsubstituted regardless of single/multi binding or request shape;
  #     see the KNOWN LIMITATION note on _acq_msb_apply_kit_dir and the tracked
  #     issue). Binding the same placeholder across multiple github hosts also
  #     triggers microsandbox #1170 (ineligible-entry blocks eligible). So the
  #     private playbook clone is expected to be skipped on msb until upstream git
  #     substitution works; the kit is non-fatal and warns.
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
    # NOTE: GitHub token is intentionally NOT bound as an msb secret — see the
    # scope note above. It remains in the acq store for the sbx backend and for
    # a future msb path once upstream git substitution is fixed.
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
  msb create --name "$name" "${create_flags[@]}" "$ACQ_MSB_IMAGE" || _create_rc=$?
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

  # Verify the kits' runtime prerequisites are present in the base image
  # (node/git/curl/update-ca-certificates). We do NOT install them: the kit
  # net-rules lock egress to the kits' own hosts, so a package mirror is
  # unreachable during provision. Missing tools => a clear, actionable warning.
  _acq_msb_check_prereqs "$name"

  # Ensure the `agent` user (uid ACQ_MSB_AGENT_UID) with HOME=/home/agent exists.
  # The pinned kits stage files under /home/agent and run startup commands as
  # that user (the sbx agent template guarantees this user). A plain OCI base
  # (e.g. node:22-bookworm) has no `agent` user, so their `-u 1000` commands ran
  # as the wrong user against a non-existent home. Create it once, idempotently.
  _acq_msb_ensure_agent_user "$name"

  # Install the requested agent binary (sbx bakes it into the template image; on
  # a plain msb base acq must install it). Idempotent + marker-gated; a no-op for
  # `shell`, a clear warning for an agent with no known recipe.
  _acq_msb_install_agent "$name" "$agent"

  # Record which agent this sandbox runs, so acq_backend_attach (which only gets
  # the sandbox name) knows what to launch — the sbx equivalent is that
  # `sbx run --name` re-launches the agent baked in at create. Written as root to
  # a fixed guest path; validated charset (KNOWN_AGENTS tokens are word-safe).
  case "$agent" in
    *[!a-z-]*) : ;;  # defensive: never write an odd token
    *) msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && printf '%s' '$agent' > /var/lib/acq/agent" >/dev/null 2>&1 || true ;;
  esac

  # Apply each kit's files + commands.
  local kd
  for kd in "${kitdirs[@]}"; do
    _acq_msb_apply_kit_dir "$name" "$kd"
  done
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
  # Otherwise create it: prefer uid 1000, but if that uid is taken, let the tool
  # pick a free uid (the kits address the user by name via our exec translation,
  # not strictly by 1000).
  msb exec "$name" -u 0 -- sh -c '
    set -e
    if id agent >/dev/null 2>&1; then
      :
    elif command -v useradd >/dev/null 2>&1; then
      # Debian/Ubuntu/RHEL. Try uid 1000 first; fall back to auto uid.
      useradd -m -d /home/agent -s /bin/sh -u 1000 agent 2>/dev/null \
        || useradd -m -d /home/agent -s /bin/sh agent
    elif command -v adduser >/dev/null 2>&1; then
      # Alpine/BusyBox.
      adduser -h /home/agent -s /bin/sh -D -u 1000 agent 2>/dev/null \
        || adduser -h /home/agent -s /bin/sh -D agent
    else
      echo "acq(msb): no useradd/adduser in base image; cannot create agent user" >&2
      exit 1
    fi
    mkdir -p /home/agent
    chown -R agent:agent /home/agent 2>/dev/null || chown -R agent /home/agent 2>/dev/null || true

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
    echo "acq(msb): warning: could not fully satisfy the agent-user base-image contract in '$name'." >&2
    echo "acq(msb):   kit commands that run as the agent user (e.g. the usai merge)" >&2
    echo "acq(msb):   or agent commands needing passwordless sudo may fail. Use an" >&2
    echo "acq(msb):   ACQ_MSB_IMAGE built on docker/sandbox-templates:shell-docker (or one" >&2
    echo "acq(msb):   providing an 'agent' user at uid 1000 with passwordless sudo and" >&2
    echo "acq(msb):   HOME=/home/agent), or a base with useradd/adduser + sudo." >&2
    return 0
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
# acq_backend_attach — interactive attach (TTY) via SSH
# ---------------------------------------------------------------------------
# sbx's `sbx run --name NAME` re-launches the agent baked into the sandbox at
# create. msb's `msb ssh NAME` only opens a shell (as root, msb's default SSH
# user), so acq must reproduce sbx's behavior itself: drop to the `agent` user,
# cd into the workspace, and exec the recorded agent (opencode, …). A bare `acq
# run <sandbox>` re-attach (no agent token) reads the agent recorded at provision
# from /var/lib/acq/agent; `shell` (or a missing/failed agent) falls back to an
# interactive shell as `agent` — never a root shell.
#
# Post-`--` args are forwarded to the agent (e.g. `-- --task "run tests"`).
acq_backend_attach() {
  local name="$1"
  shift

  # Explicit `-- CMD…` after the sandbox name: run exactly that (advanced/escape
  # hatch), still as the agent user in the workspace.
  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
    shift
    _acq_msb_ssh_agent "$name" "$@"
    return $?
  fi
  _acq_msb_ssh_agent "$name"
}

# _acq_msb_ssh_agent NAME [AGENT_ARGS...] — SSH in as `agent`, cd to the
# workspace, and launch the recorded agent (or a shell). AGENT_ARGS are appended
# to the agent invocation. Uses a login shell so PATH picks up the globally
# installed agent binary.
_acq_msb_ssh_agent() {
  local name="$1"
  shift

  local ws="${ACQ_MSB_WORKSPACE:-/home/agent/workspace}"

  # Read the agent recorded at provision. Default to `shell` if unset (older
  # sandbox, or a `shell` sandbox).
  local agent
  agent=$(msb exec "$name" -u 0 -- sh -c 'cat /var/lib/acq/agent 2>/dev/null' 2>/dev/null | tr -d '\r\n[:space:]')
  [ -n "$agent" ] || agent="shell"

  # Build the remote command run as the agent user. cd to the workspace if it
  # exists; then exec the agent (or an interactive shell). If the agent binary is
  # somehow absent, fall back to a shell rather than failing the attach — but say
  # so, so the user isn't staring at a bare prompt wondering why.
  local remote
  if [ "$agent" = "shell" ]; then
    remote="cd '$ws' 2>/dev/null; exec \$SHELL -l"
  else
    # AGENT_ARGS (already shell-safe from the user's own invocation) are joined
    # with single-quote escaping so they survive the remote sh -c.
    local extra=""
    local a
    for a in "$@"; do
      extra="$extra '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
    done
    remote="cd '$ws' 2>/dev/null; if command -v '$agent' >/dev/null 2>&1; then exec '$agent'$extra; else echo \"acq(msb): '$agent' not found in sandbox; opening a shell instead.\" >&2; exec \$SHELL -l; fi"
  fi

  # `msb ssh NAME -- CMD` runs CMD (msb's default SSH user is root); we drop to
  # the agent user via `su` so the agent runs unprivileged in its own HOME, the
  # same posture as sbx. `su - agent` gives a login environment (PATH/HOME).
  msb ssh "$name" -- su - agent -c "$remote"
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

  # Re-feed running sandboxes so a rotated secret takes effect without recreate
  # (msb modify --secret; the guest keeps its placeholder, only the injected
  # value changes). Only for services the msb adapter actually binds (usai).
  case "$service" in
    usai)
      local val
      if val=$(acq_secret_resolve usai "$scope_name" 2>/dev/null) && [ -n "$val" ]; then
        local applied=0 sb
        # Determine target sandboxes: a named scope, else all running sandboxes.
        if [ -n "$scope_name" ]; then
          if acq_backend_exists "$scope_name"; then
            USAI_API_KEY="$val" msb modify "$scope_name" --secret "USAI_API_KEY@${ACQ_MSB_USAI_HOST}" >/dev/null 2>&1 \
              && applied=$((applied + 1))
          fi
        else
          while IFS= read -r sb; do
            [ -n "$sb" ] || continue
            USAI_API_KEY="$val" msb modify "$sb" --secret "USAI_API_KEY@${ACQ_MSB_USAI_HOST}" >/dev/null 2>&1 \
              && applied=$((applied + 1))
          done <<EOF
$(msb list -q 2>/dev/null)
EOF
        fi
        val=""
        [ "$applied" -gt 0 ] && acq_debug "msb modify: re-fed USAi secret to $applied sandbox(es)"
      fi
      echo "acq(msb): stored USAi key in the acq secret store. At 'acq run/create'" >&2
      echo "      the msb backend binds it via --secret USAI_API_KEY@${ACQ_MSB_USAI_HOST};" >&2
      echo "      the real value is swapped in on the wire and never enters the guest." >&2
      echo "      Running sandboxes were re-fed via 'msb modify' (no recreate needed)." >&2
      ;;
    github)
      echo "acq(msb): stored GitHub token in the acq secret store (used by the sbx" >&2
      echo "      backend). NOTE: the msb backend does NOT bind GitHub as a secret —" >&2
      echo "      msb 0.6.6 does not substitute the placeholder for git's HTTPS clone" >&2
      echo "      to github.com, so the private playbook-clone kit is skipped on msb." >&2
      echo "      Tracked for a fix (see docs/BACKEND_GUIDE.md, msb known limitations)." >&2
      ;;
    *)
      echo "acq(msb): stored '$service' in the acq secret store. Note: the msb adapter" >&2
      echo "      only auto-binds 'usai' at create today; other services are stored" >&2
      echo "      but not yet wired to a --secret host mapping." >&2
      ;;
  esac
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
