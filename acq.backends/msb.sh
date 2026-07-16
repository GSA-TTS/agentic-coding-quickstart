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
#   [:<proto>[:<ports>]]`. For a literal hostname the target is `domain=HOST`
#   (a bare `domain:HOST` reads "domain" as a single-label host — ambiguous),
#   e.g. `allow@domain=api.gsa.usai.gov`.
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

# USAi models path (matches common.sh USAI_MODELS_URL host) for --secret host.
ACQ_MSB_USAI_HOST="api.gsa.usai.gov"

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
    # The target for a literal hostname is the bare domain (e.g. api.gsa.usai.gov);
    # a `:` after the target is the PROTO separator, so "allow@domain:HOST" makes
    # msb read the target as the single label "domain" (ambiguous) — wrong. Use
    # the explicit `domain=HOST` target form to force a literal-hostname match.
    # Strip any :port the neutral spec may carry (msb keys on the domain).
    _host="${_host%%:*}"
    eval "$_arr+=(--net-rule \"allow@domain=${_host}\")"
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
  local fline path mode phase source src
  while IFS= read -r fline; do
    [ -n "$fline" ] || continue
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
      # Ensure the parent dir exists in the guest, then copy and chmod.
      msb exec "$name" -- sh -c "mkdir -p '$(dirname "$path")'" >/dev/null 2>&1 || true
      msb copy "$src" "${name}:${path}" >/dev/null 2>&1 || {
        echo "acq(msb): warning: failed to copy kit file to ${name}:${path}" >&2
      }
      [ -n "$mode" ] && msb exec "$name" -- sh -c "chmod $mode '$path'" >/dev/null 2>&1 || true
    fi
  done <<EOF
$(kit_spec_files "$spec")
EOF

  # 2) Run commands[]. Reassemble each argv record and exec it as the given uid.
  #    install → run once (idempotent, marker-gated); initFiles/startup → every
  #    apply. msb has no create-time-only hook, so install collapses to a
  #    marker-gated exec (design §3 lifecycle table).
  _acq_msb_run_commands "$name" "$spec"
}

# Parse and execute a kit spec's commands[] against sandbox NAME.
_acq_msb_run_commands() {
  local name="$1" spec="$2"
  local phase="" user="" argv=() reading=0 line

  while IFS= read -r line; do
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
        _acq_msb_exec_command "$name" "$phase" "$user" "${argv[@]}"
        ;;
      *)
        if [ "$reading" -eq 1 ]; then
          # argv tokens are base64-encoded (one per line) so multi-line block
          # scalars survive as a single token. Decode back to the raw string.
          argv+=("$(printf '%s' "$line" | base64 -d)")
        fi
        ;;
    esac
  done <<EOF
$(kit_spec_commands "$spec")
EOF
}

# Execute one command record. install-phase commands are gated by a per-command
# marker file so they run once per sandbox even across re-applies.
_acq_msb_exec_command() {
  local name="$1" phase="$2" user="$3"
  shift 3
  [ "$#" -gt 0 ] || return 0

  local uflag=()
  [ -n "$user" ] && uflag=(-u "$user")

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
    msb exec "$name" "${uflag[@]}" -- "$@" || {
      echo "acq(msb): warning: install command failed for '$name'" >&2
      return 0
    }
    msb exec "$name" -u 0 -- sh -c "mkdir -p /var/lib/acq && touch '$marker'" >/dev/null 2>&1 || true
  else
    # initFiles / startup — run every apply (they are written idempotent).
    msb exec "$name" "${uflag[@]}" -- "$@" || {
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

  # Translate the caller's workspace paths into --volume mounts. The agent token
  # is the first positional; each subsequent positional is a path (optionally
  # host:guest or path:ro). Mount each project path read-write (or :ro) at the
  # same absolute path inside the guest, mirroring the sbx workspace model.
  local ws
  ws=$(workspace_path "$@")
  if [ -n "$ws" ]; then
    create_flags+=(--volume "${ws}:${ws}")
  fi

  # USAi credential: bind the injected USAI_API_KEY host env var to the sandbox,
  # scoped to the USAi host, so the models API returns 200 without the real key
  # ever being inlined into the sandbox config (msb --secret ENV@HOST).
  # NOTE: acq's own secret store integration (unified swap-on-access) is out of
  # scope for Phase 2 (handoff §2); this uses msb's native host-env secret path.
  if [ -n "${USAI_API_KEY:-}" ]; then
    create_flags+=(--secret "USAI_API_KEY@${ACQ_MSB_USAI_HOST}")
  fi

  # Create the sandbox (detached; msb create boots in the background).
  acq_debug "msb create --name $name ${create_flags[*]} $ACQ_MSB_IMAGE"
  if ! msb create --name "$name" "${create_flags[@]}" "$ACQ_MSB_IMAGE"; then
    echo "acq(msb): error: 'msb create' failed for '$name'." >&2
    echo "acq(msb):   flags: ${create_flags[*]}" >&2
    echo "acq(msb):   image: $ACQ_MSB_IMAGE" >&2
    case "$ACQ_MSB_IMAGE" in
      ghcr.io/*|*.azurecr.io/*|*private*)
        echo "acq(msb):   hint: the image may require registry auth. Set ACQ_MSB_IMAGE to a" >&2
        echo "acq(msb):         pullable image (default: docker.io/library/debian:stable-slim)." >&2
        ;;
    esac
    echo "acq(msb):   (re-run with ACQ_DEBUG=1 for the full command trace)" >&2
    return 1
  fi

  # Verify the kits' runtime prerequisites are present in the base image
  # (node/git/curl/update-ca-certificates). We do NOT install them: the kit
  # net-rules lock egress to the kits' own hosts, so a package mirror is
  # unreachable during provision. Missing tools => a clear, actionable warning.
  _acq_msb_check_prereqs "$name"

  # Apply each kit's files + commands.
  local kd
  for kd in "${kitdirs[@]}"; do
    _acq_msb_apply_kit_dir "$name" "$kd"
  done
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
# acq_backend_secret_set — minimal secret wrapper (USAi to a 200)
# ---------------------------------------------------------------------------
# Phase 2 scope (handoff §2): implement only as much as msb needs for the USAi
# models API to return 200. msb's native model is `--secret ENV@HOST` at create
# time, reading the value from a host env var and never inlining it into the
# sandbox config. There is no separate `msb secret set` store to write to, so
# acq's msb secret_set validates usage and instructs the user to export the env
# var that provision binds. The full unified swap-on-access store is deferred.

acq_backend_secret_set() {
  local service="${1:-}"
  shift || true

  # Strip a leading scope token (-g / --global / a sandbox name) for parity with
  # the sbx wrapper's calling convention; msb binds secrets at create, so the
  # scope only affects the guidance we print.
  case "$service" in
    -g|--global) service="${1:-}"; shift || true ;;
    -*) ;;
    *)
      local _next="${1:-}"
      case "$_next" in
        ""|-*) ;;
        *) service="$_next"; shift || true ;;
      esac
      ;;
  esac

  if [ -z "$service" ]; then
    echo "acq(msb): secret set: missing service name" >&2
    echo "     usage: acq secret set [-g | SANDBOX] <service>" >&2
    return 1
  fi

  case "$service" in
    usai)
      echo "acq(msb): the msb backend binds the USAi key from a host environment" >&2
      echo "      variable at sandbox-create time (msb --secret ENV@HOST) — the real" >&2
      echo "      value never enters the guest. To use it:" >&2
      echo "        export USAI_API_KEY=<your-usai-key>" >&2
      echo "        acq --backend msb run opencode <path>" >&2
      echo "      provision binds USAI_API_KEY@${ACQ_MSB_USAI_HOST} automatically." >&2
      echo "      (A unified acq secret store across backends is planned; see ADR-0011.)" >&2
      return 0
      ;;
    *)
      echo "acq(msb): '$service' secret binding is not modeled by the msb adapter yet." >&2
      echo "      msb binds secrets from host env vars at create time" >&2
      echo "      (msb --secret ENV@HOST). Export the value and re-run 'acq run'." >&2
      return 1
      ;;
  esac
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
