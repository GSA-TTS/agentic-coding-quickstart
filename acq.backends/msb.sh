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
    eval "$_arr+=(--net-rule \"allow@${_host}\")"
  done <<EOF
$(kit_spec_net_allow "$_spec")
EOF
}

# Apply a single fetched kit directory to a running sandbox NAME.
# Honors backend_shortcuts.msb (currently: zscaler trust_host_cas, handled at
# provision time — see acq_backend_provision; here we skip the file/command
# path for a shortcut kit). Drops files and runs install/initFiles/startup
# commands via `msb exec`.
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
  #    marker-gated exec (design §3 lifecycle table).
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
  # (which runs the startup commands) can read/execute them.
  [ -n "$mode" ] && msb exec "$name" -u 0 -- sh -c "chmod $mode '$path'" >/dev/null 2>&1 || true
  case "$path" in
    /home/agent/*)
      msb exec "$name" -u 0 -- sh -c "chown agent '$path' 2>/dev/null || true" >/dev/null 2>&1 || true
      ;;
  esac
  acq_debug "msb copy verified: ${name}:${path}"
  return 0
}

# Parse and execute a kit spec's commands[] against sandbox NAME.
_acq_msb_run_commands() {
  local name="$1" spec="$2"

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
        _acq_msb_exec_command "$name" "$phase" "$user" ${argv[@]+"${argv[@]}"}
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
_acq_msb_exec_command() {
  local name="$1" phase="$2" user="$3"
  shift 3
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

  # Collect create-time flags: net rules (union of all kit caps), --trust-host-cas
  # (if any kit declares the msb zscaler shortcut), volume mounts (from paths),
  # and the USAi secret binding.
  local create_flags=()
  local trust_host_cas=0
  local kitdirs=()

  # Fetch each built-in kit and gather its create-time contributions.
  local kitref kitdir
  local kits=("$USAI_KIT" "$PLAYBOOK_KIT" "$ZSCALER_KIT" "$GITSSHSIGN_KIT")
  # Include any extra kits.
  if [ -n "${ACQ_EXTRA_KITS:-}" ]; then
    local _extras=()
    split_noglob _extras "$ACQ_EXTRA_KITS"
    kits+=("${_extras[@]}")
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

  # Guest DNS: use a resolver reachable from the microVM. The host's resolvers
  # (often a corporate/VPN/Zscaler IP) are typically unreachable from the guest,
  # so without this the guest can't resolve even allow-listed hosts. See the
  # ACQ_MSB_DNS_NAMESERVER note above.
  if [ -n "$ACQ_MSB_DNS_NAMESERVER" ]; then
    create_flags+=(--dns-nameserver "$ACQ_MSB_DNS_NAMESERVER")
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
  # this sandbox first, then global. The real value is exported into a TRANSIENT
  # env var (never argv, never the kit spec) and bound with msb --secret
  # ENV@HOST, so it is swapped in on the wire and never inlined into the sandbox
  # config. Supports the two pinned credential services: usai and github.
  #
  # msb --secret reads the value from the NAMED host env var at create time. We
  # set that env var only for the duration of the msb create call.
  local _secret_env_names=()   # env vars we set transiently, cleared after create
  if command -v acq_secret_resolve >/dev/null 2>&1; then
    # USAi key -> USAI_API_KEY@api.gsa.usai.gov
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
    # GitHub token -> GITHUB_TOKEN@github.com and @api.github.com (git + API).
    local gh_val
    if gh_val=$(acq_secret_resolve github "$name" 2>/dev/null) && [ -n "$gh_val" ]; then
      export GITHUB_TOKEN="$gh_val"; gh_val=""
      _secret_env_names+=("GITHUB_TOKEN")
      create_flags+=(--secret "GITHUB_TOKEN@github.com" --secret "GITHUB_TOKEN@api.github.com")
      acq_debug "msb secret: binding GITHUB_TOKEN@github.com,api.github.com (from acq store)"
    fi
  elif [ -n "${USAI_API_KEY:-}" ]; then
    create_flags+=(--secret "USAI_API_KEY@${ACQ_MSB_USAI_HOST}")
  fi

  # Create the sandbox (detached; msb create boots in the background).
  acq_debug "msb create --name $name ${create_flags[*]} $ACQ_MSB_IMAGE"
  msb create --name "$name" "${create_flags[@]}" "$ACQ_MSB_IMAGE"
  local _create_rc=$?
  # Clear the transient secret env vars immediately after create reads them.
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

  # Apply each kit's files + commands.
  local kd
  for kd in "${kitdirs[@]}"; do
    _acq_msb_apply_kit_dir "$name" "$kd"
  done
}

# ---------------------------------------------------------------------------
# _acq_msb_ensure_agent_user NAME — guarantee the kits' agent/uid-1000 contract
# ---------------------------------------------------------------------------
# The neutral kits assume the sbx agent-template contract: a user named `agent`
# whose HOME is /home/agent, addressable as `-u 1000`. Plain OCI bases don't
# provide it (node:22-bookworm ships `node` at uid 1000 with HOME=/home/node).
# Create `agent` with home /home/agent, marker-gated so it runs once. Runs fully
# offline (useradd/adduser need no network). The uid is configurable but
# defaults to 1000; if 1000 is already taken by another user (e.g. `node`), we
# still create `agent` at the next free uid AND ensure the kits' `-u 1000`
# commands map to it by making `agent` own /home/agent and exporting HOME.
#
# The adapter runs kit commands via _acq_msb_exec_command, which translates a
# kit `user: "1000"` to the agent user (see that function). So the guest only
# needs: an `agent` user, /home/agent owned by it.
_acq_msb_ensure_agent_user() {
  local name="$1"
  local marker="/var/lib/acq/agent-user-ready"
  if msb exec "$name" -u 0 -- sh -c "test -f '$marker'" >/dev/null 2>&1; then
    return 0
  fi

  acq_debug "msb: ensuring agent user + /home/agent in $name"
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
  ' || {
    echo "acq(msb): warning: could not create the 'agent' user in '$name'." >&2
    echo "acq(msb):   kit commands that run as the agent user (usai merge, playbook" >&2
    echo "acq(msb):   clone) may fail. Use an ACQ_MSB_IMAGE that provides an 'agent'" >&2
    echo "acq(msb):   user with HOME=/home/agent, or a base with useradd/adduser." >&2
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

acq_backend_attach() {
  local name="$1"
  shift
  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
    shift
    msb ssh "$name" -- "$@"
  else
    msb ssh "$name"
  fi
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

  case "$service" in
    usai)
      echo "acq(msb): stored USAi key in the acq secret store. At 'acq run/create'" >&2
      echo "      the msb backend binds it via --secret USAI_API_KEY@${ACQ_MSB_USAI_HOST};" >&2
      echo "      the real value is swapped in on the wire and never enters the guest." >&2
      ;;
    github)
      echo "acq(msb): stored GitHub token in the acq secret store. At 'acq run/create'" >&2
      echo "      the msb backend binds it via --secret GITHUB_TOKEN@github.com and" >&2
      echo "      @api.github.com; the real value never enters the guest." >&2
      ;;
    *)
      echo "acq(msb): stored '$service' in the acq secret store. Note: the msb adapter" >&2
      echo "      only auto-binds 'usai' and 'github' at create today; other services" >&2
      echo "      are stored but not yet wired to a --secret host mapping." >&2
      ;;
  esac
  return 0
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
