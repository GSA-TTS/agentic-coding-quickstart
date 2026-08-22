#!/bin/bash
#
# acq.backends/kit-translate.sh — neutral hybrid/v1 kit translation layer
#
# Sourced by common.sh. Given a neutral kit (a directory containing a
# hybrid/v1 spec.yaml plus a files/ payload tree) and the active backend name,
# this module parses the spec once and exposes it in a shell-consumable form so
# each backend adapter can emit its native operations. It is the SHARED parser +
# shortcut/extras dispatcher; the real per-backend work stays in each adapter
# (sbx.sh, msb.sh). See docs/adr/0011-msb-backend-and-neutral-kits.md and the
# acq-design.md exploration (§5, §7).
#
# NO NEW RUNTIME DEPENDENCIES: the spec is parsed with awk (already used across
# this repo), not yq/python. The parser is intentionally scoped to the exact
# hybrid/v1 shape the four acq kits use (see the schema in the patterns repo:
# schemas/kit-hybrid-v1.schema.json). It is not a general YAML parser.
#
# ---------------------------------------------------------------------------
# Kit-source model
# ---------------------------------------------------------------------------
# A kit is referenced two ways:
#   1. A remote git ref (git+https://…#ref=<sha>&dir=<path>) — the built-in four
#      and any ACQ_EXTRA_KITS. kit_translate_fetch() materializes it locally.
#   2. A local directory path — used by `acq kit validate PATH` and tests.
#
# The sbx backend can still hand remote refs to `sbx --kit` directly (it fetches
# + parses spec.yaml natively), so sbx does NOT need a local fetch. The msb
# backend has no native kit mechanism, so it fetches the kit locally and drives
# the parsed operations itself.
#
# ---------------------------------------------------------------------------
# Parsed-spec accessor functions (all take the kit's local spec.yaml path)
# ---------------------------------------------------------------------------
#   kit_spec_field       SPEC KEY            -> top-level scalar (name, kind, …)
#   kit_spec_net_allow   SPEC                -> one host[:port] per line
#   kit_spec_published_ports SPEC            -> one "guest<TAB>proto<TAB>name<TAB>host" per line
#   kit_spec_volumes     SPEC                -> one "path<TAB>type<TAB>size" per line
#   kit_spec_files       SPEC                -> one "path|mode|phase|source" per line
#   kit_spec_commands    SPEC                -> command records (see format below)
#   kit_spec_env         SPEC                -> one "NAME<TAB>value" per line
#   kit_spec_has_shortcut SPEC BACKEND       -> 0 if backend_shortcuts.<backend>
#                                               is present AND non-empty
#   kit_spec_shortcut_val SPEC BACKEND KEY   -> value of a shortcut key
#
# These read the spec file each call (kits are tiny; simplicity over caching).

# ---------------------------------------------------------------------------
# kit_translate_fetch KITREF DESTDIR
# ---------------------------------------------------------------------------
# Materialize a kit's directory locally. KITREF is either:
#   - git+https://HOST/REPO.git#ref=SHA&dir=PATH  (remote, sparse-checked-out)
#   - /absolute/or/relative/local/path            (used verbatim)
# On success prints the local kit directory path to stdout and returns 0.
kit_translate_fetch() {
  local kitref="$1" destdir="$2"

  case "$kitref" in
    git+http*)
      local url ref dir frag
      url="${kitref#git+}"
      frag="${url#*#}"
      url="${url%%#*}"
      # Parse &-separated fragment params ref= and dir=.
      ref=""; dir=""
      local IFS='&'
      # shellcheck disable=SC2086
      set -- $frag
      unset IFS
      local p
      for p in "$@"; do
        case "$p" in
          ref=*) ref="${p#ref=}" ;;
          dir=*) dir="${p#dir=}" ;;
        esac
      done
      if [ -z "$ref" ] || [ -z "$dir" ]; then
        echo "kit-translate: malformed kit ref (need #ref=&dir=): $kitref" >&2
        return 1
      fi
      # Defense-in-depth: reject a hostile dir= (path traversal / metachars).
      # `dir` is a repo-relative subpath; it must not escape via `..` or carry
      # anything but a safe path charset. Matches the hardening in kit_spec_files.
      case "$dir" in
        /*|*..*)
          echo "kit-translate: unsafe kit dir (no absolute paths or '..'): $dir" >&2
          return 1
          ;;
      esac
      if printf '%s' "$dir" | LC_ALL=C grep -q '[^A-Za-z0-9._/-]'; then
        echo "kit-translate: unsafe kit dir (illegal characters): $dir" >&2
        return 1
      fi
      command -v acq_debug >/dev/null 2>&1 && acq_debug "fetch: $url ref=$ref dir=$dir -> $destdir"
      mkdir -p "$destdir"
      # Fetch NON-INTERACTIVELY. We MUST NOT drop into an interactive git
      # credential prompt (which hangs, or fails on GitHub's disabled password
      # auth) just because the user has a global git credential helper or a
      # url.<x>.insteadOf rewrite — `gh auth login` authenticates the gh CLI,
      # not plain git. See #207 / KNOWN_FAILURE_MODES.
      #
      # Attempt 1 (anonymous): prompts disabled + inherited credential helper and
      # github.com insteadOf rewrite neutralized, so an unauthenticated fetch
      # proceeds without prompting.
      # Attempt 2 (authed retry): if attempt 1 genuinely fails (a source that
      # needs auth / egress-restricted enterprise mirror that needs the rewrite),
      # retry with the system git config intact but STILL prompt-disabled, so a
      # configured credential helper can supply creds without ever hanging.
      _kit_git_fetch() {
        # $1 = extra git -c flags (as a single string, word-split intentionally)
        local _cfg="$1"
        (
          cd "$destdir" || exit 1
          export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo GCM_INTERACTIVE=never
          rm -rf .git 2>/dev/null
          git init -q
          git remote add origin "$url" 2>/dev/null || git remote set-url origin "$url"
          git config core.sparseCheckout true
          # `git init` does not always create .git/info/ (platform-dependent),
          # so create it before writing the sparse-checkout file — otherwise the
          # redirect fails with ".git/info/sparse-checkout: No such file or
          # directory" (harmless-but-noisy; fetch still fell back). See #211-adjacent.
          mkdir -p .git/info
          printf '%s/*\n' "$dir" > .git/info/sparse-checkout
          # shellcheck disable=SC2086
          git $_cfg fetch --depth 1 origin "$ref" 2>&1 || exit 1
          git checkout -q FETCH_HEAD 2>&1 || exit 1
        )
      }
      local _ferr _anon_cfg
      _anon_cfg="-c credential.helper= -c url.https://github.com/.insteadOf="
      if _ferr=$(_kit_git_fetch "$_anon_cfg"); then
        :
      elif _ferr=$(_kit_git_fetch ""); then
        # authed retry (system config) succeeded
        :
      else
        echo "kit-translate: failed to fetch $kitref" >&2
        [ -n "$_ferr" ] && printf '%s\n' "$_ferr" | sed 's/^/kit-translate:   /' >&2
        cat >&2 <<'EOM'
kit-translate: If you saw a "Username for 'https://github.com'" prompt, plain git
kit-translate:   (not gh) is trying to authenticate. gh auth authenticates the gh
kit-translate:   CLI, not git. Fixes:
kit-translate:     - run once:  gh auth setup-git
kit-translate:     - or check for a rewrite:  git config --global --get-regexp 'url\..*insteadOf'
kit-translate:   If the kit source requires auth, ensure your git credential
kit-translate:   helper is configured (a prompt-less helper).
EOM
        return 1
      fi
      printf '%s/%s\n' "$destdir" "$dir"
      ;;
    *)
      # Local path — use as-is.
      if [ ! -d "$kitref" ]; then
        echo "kit-translate: local kit path not found: $kitref" >&2
        return 1
      fi
      printf '%s\n' "$kitref"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# kit_spec_field SPEC KEY
# ---------------------------------------------------------------------------
# Echo a top-level scalar string value (name, kind, displayName, schemaVersion).
# Handles `key: value` and quoted values. Also handles a folded/literal block
# (`key: >` or `key: |`) by collapsing its indented continuation lines into a
# single space-joined string (used for `description:`).
kit_spec_field() {
  local spec="$1" key="$2"
  [ -f "$spec" ] || return 1
  awk -v key="$key" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    # Collecting a folded/literal block for the requested key.
    collecting {
      if ($0 ~ /^[[:space:]]/ || $0 ~ /^[[:space:]]*$/) {
        if ($0 !~ /^[[:space:]]*$/) {
          t=trim($0)
          buf = (buf=="" ? t : buf " " t)
        }
        next
      } else {
        print buf; done=1; exit
      }
    }
    /^[A-Za-z][A-Za-z0-9_]*:/ {
      k=$0; sub(/:.*/,"",k)
      if (k == key) {
        v=$0; sub(/^[^:]*:[[:space:]]*/,"",v)
        if (v == ">" || v == "|" || v ~ /^[|>][0-9+-]*$/) { collecting=1; buf=""; next }
        gsub(/^"|"$/,"",v); gsub(/^'\''|'\''$/,"",v)
        if (v != "") { print v; done=1; exit }
      }
    }
    END { if (collecting && !done) print buf }
  ' "$spec"
}

# ---------------------------------------------------------------------------
# kit_spec_net_allow SPEC
# ---------------------------------------------------------------------------
# Echo each caps.network.allow entry (host or host:port), one per line.
kit_spec_net_allow() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    /^caps:/            { in_caps=1; next }
    /^[A-Za-z]/         { in_caps=0; in_net=0; in_allow=0 }   # left top-level block
    in_caps && /^[[:space:]]+network:/ { in_net=1; next }
    in_net  && /^[[:space:]]+allow:/   { in_allow=1; next }
    in_allow {
      # allow list items look like:   "      - host[:port]"
      if ($0 ~ /^[[:space:]]+-[[:space:]]*/) {
        v=$0
        sub(/^[[:space:]]*-[[:space:]]*/,"",v)
        sub(/[[:space:]]*#.*/,"",v)          # strip trailing comment
        gsub(/[[:space:]]+$/,"",v)
        gsub(/^"|"$/,"",v)
        if (v != "") print v
      } else if ($0 ~ /^[[:space:]]*#/) {
        next                                  # comment line inside allow
      } else {
        in_allow=0                            # dedent ends the list
      }
    }
  ' "$spec"
}

# ---------------------------------------------------------------------------
# kit_spec_published_ports SPEC
# ---------------------------------------------------------------------------
# Echo one record per published-port entry, tab-separated:
#   guest <TAB> protocol <TAB> name <TAB> host
# protocol/name are empty if unspecified; host defaults to guest when omitted.
#
# SOURCE PRECEDENCE (ADR-0014): the NEUTRAL top-level `publishedPorts` is read
# FIRST. Each neutral entry is `{guest, host?, protocol?(tcp|udp), name?}`:
#
#   publishedPorts:
#     - guest: 3000
#       host: 3000
#       protocol: tcp
#       name: openchamber
#
# If (and only if) no neutral list is present, this FALLS BACK for one release
# to the legacy sbx-only block `backend_extras.sbx.publishedPorts` (whose entries
# use the OLD key `container:` instead of `guest:`, and have no `host:`), emitting
# a one-time deprecation warning to stderr. That legacy fallback is removed in the
# following minor (see ADR-0014 "Tradeoff"):
#
#   backend_extras:
#     sbx:
#       publishedPorts:
#         - container: 3000
#           protocol: tcp
#           name: openchamber
#
# VALIDATION (SI-10): guest/host must be integers 1..65535; protocol must be
# tcp|udp when present; name is charset-restricted ([A-Za-z0-9._-]). Offending
# entries are DROPPED with a stderr warning (mirroring kit_spec_files/env). These
# values reach an msb `-p HOST:GUEST` argv and an sbx-v2 spec, so they are
# untrusted input.
#
# NOTE (>50 lines): this function must both parse two YAML shapes (neutral vs the
# legacy sbx block) and validate four sub-fields; splitting it would fragment the
# single-pass awk parser. It is kept as one cohesive parser + one validation gate.
kit_spec_published_ports() {
  local spec="$1"
  [ -f "$spec" ] || return 0

  # 1) Prefer the NEUTRAL top-level publishedPorts. Emit guest/proto/name/host.
  local neutral
  neutral=$(_kit_pp_parse_neutral "$spec")
  if [ -n "$neutral" ]; then
    printf '%s\n' "$neutral" | _kit_pp_validate
    return 0
  fi

  # 2) Fall back to the DEPRECATED backend_extras.sbx.publishedPorts (one release).
  local legacy
  legacy=$(_kit_pp_parse_legacy "$spec")
  if [ -n "$legacy" ]; then
    echo "kit-translate: DEPRECATION: backend_extras.sbx.publishedPorts is deprecated;" >&2
    echo "kit-translate:   move ports to the neutral top-level 'publishedPorts:' list" >&2
    echo "kit-translate:   ({guest, host?, protocol?, name?}). The sbx-only fallback is" >&2
    echo "kit-translate:   removed in the next minor release (ADR-0014)." >&2
    printf '%s\n' "$legacy" | _kit_pp_validate
  fi
}

# Parse the NEUTRAL top-level `publishedPorts:` list into raw (unvalidated)
# tab-separated `guest<TAB>proto<TAB>name<TAB>host` records. host defaults to
# guest when omitted. Reads only the top-level block (dedent ends it).
_kit_pp_parse_neutral() {
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s); return s }
    function flush(){ if (cur_g != "") printf "%s\t%s\t%s\t%s\n", cur_g, cur_p, cur_n, (cur_h==""?cur_g:cur_h); cur_g=""; cur_p=""; cur_n=""; cur_h="" }
    /^publishedPorts:[[:space:]]*$/ { in_pp=1; flush(); next }
    /^[A-Za-z]/ { if (in_pp) { flush(); in_pp=0 } }
    in_pp {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /^[[:space:]]+-[[:space:]]/) {
        flush()
        line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line)
        k=line; sub(/:.*/,"",k); k=trim(k)
        v=line; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
        if (k=="guest") cur_g=v; else if (k=="host") cur_h=v; else if (k=="protocol") cur_p=v; else if (k=="name") cur_n=v
        next
      }
      if ($0 ~ /^[[:space:]]+[A-Za-z]/) {
        k=$0; sub(/:.*/,"",k); k=trim(k)
        v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
        if (k=="guest") cur_g=v; else if (k=="host") cur_h=v; else if (k=="protocol") cur_p=v; else if (k=="name") cur_n=v
        next
      }
    }
    END { if (in_pp) flush() }
  ' "$1"
}

# Parse the DEPRECATED backend_extras.sbx.publishedPorts list into raw
# tab-separated `guest<TAB>proto<TAB>name<TAB>host` records (legacy uses the old
# `container:` key and has no `host:`, so host==guest).
_kit_pp_parse_legacy() {
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s); return s }
    function flush(){ if (cur_c != "") printf "%s\t%s\t%s\t%s\n", cur_c, cur_p, cur_n, cur_c; cur_c=""; cur_p=""; cur_n="" }
    function indent_of(s,   i){ i=match(s,/[^ ]/); return (i==0? 0 : i-1) }
    /^backend_extras:/  { in_be=1; next }
    /^[A-Za-z]/         { if (in_be) { flush(); in_be=0; in_sbx=0; in_pp=0 } }
    in_be {
      if ($0 ~ /^[[:space:]]+sbx:[[:space:]]*$/) { in_sbx=1; in_pp=0; sbx_ind=indent_of($0); next }
      if (in_sbx && $0 ~ /^[[:space:]]+[A-Za-z_]+:/ && indent_of($0) <= sbx_ind && $0 !~ /publishedPorts:/) {
        if (indent_of($0) == sbx_ind) { flush(); in_sbx=0; in_pp=0 }
      }
      if (in_sbx && $0 ~ /publishedPorts:[[:space:]]*$/) { in_pp=1; flush(); next }
      if (in_pp) {
        if ($0 ~ /^[[:space:]]+-[[:space:]]/) {
          flush()
          line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line)
          k=line; sub(/:.*/,"",k); k=trim(k)
          v=line; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
          if (k=="container") cur_c=v; else if (k=="protocol") cur_p=v; else if (k=="name") cur_n=v
          next
        }
        if ($0 ~ /^[[:space:]]+[A-Za-z]/) {
          k=$0; sub(/:.*/,"",k); k=trim(k)
          v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
          if (k=="container") cur_c=v; else if (k=="protocol") cur_p=v; else if (k=="name") cur_n=v
          if (indent_of($0) <= sbx_ind + 2 && k != "container" && k != "protocol" && k != "name") { flush(); in_pp=0 }
          next
        }
      }
    }
    END { if (in_be) flush() }
  ' "$1"
}

# Validate raw `guest<TAB>proto<TAB>name<TAB>host` records on stdin (SI-10):
# guest/host ints 1..65535; protocol tcp|udp when present; name [A-Za-z0-9._-].
# Drops offending records with a stderr warning; emits the survivors unchanged.
_kit_pp_validate() {
  awk -F'\t' '
    function is_port(p){ return (p ~ /^[0-9]+$/ && p+0 >= 1 && p+0 <= 65535) }
    {
      g=$1; p=$2; n=$3; h=$4
      if (g=="") next
      if (!is_port(g))                    { print "kit-translate: skipping published port with invalid guest port: " g > "/dev/stderr"; next }
      if (h!="" && !is_port(h))           { print "kit-translate: skipping published port with invalid host port: " h > "/dev/stderr"; next }
      if (p!="" && p!="tcp" && p!="udp")  { print "kit-translate: skipping published port with invalid protocol: " p > "/dev/stderr"; next }
      if (n!="" && n !~ /^[A-Za-z0-9._-]+$/) { print "kit-translate: skipping published port with unsafe name: " n > "/dev/stderr"; next }
      printf "%s\t%s\t%s\t%s\n", g, p, n, h
    }
  '
}

# ---------------------------------------------------------------------------
# kit_spec_volumes SPEC
# ---------------------------------------------------------------------------
# Echo one record per volumes[] entry, tab-separated:
#   path <TAB> type <TAB> size
# type is empty for the default (block-backed) volume; the only other value is
# tmpfs. size is REQUIRED — the neutral schema deliberately does not inherit
# sbx's unsized-volume default, which is still settling upstream (0.39-rc moved
# it 50G -> 512M). The neutral top-level `volumes:` list is the ONLY source (the
# field is brand new, so there is no backend_extras fallback to carry):
#
#   volumes:
#     - path: /var/lib/docker   # required, absolute
#       size: 20G               # required
#     - path: /scratch
#       type: tmpfs             # "" (block, default) | tmpfs
#       size: 2G
#
# Volumes are CREATION-TIME ONLY on both backends (`sbx kit add` skips them; msb
# mounts at create) and mount UNSEEDED: an empty filesystem shadows any image
# content at the path, so a kit needing seeded content ships its own first-boot
# copy step. Multiple kits union by path, last wins — sbx resolves that itself.
# The neutral schema carries no `mode` (msb has no equivalent; kits chmod in a
# startup step instead — see ADR-0022).
#
# VALIDATION (SI-10): these values reach a generated sbx-v2 spec and an msb
# create argv, so they are untrusted. path must be absolute, charset-restricted
# ([A-Za-z0-9._/-]), and NORMALIZED (no . or .. segments, no //, no trailing
# /) — a volume mounts a whole unseeded filesystem, so /. would shadow the
# guest root and /data/../etc would mount over /etc while reading as a /data
# path; type must be empty or tmpfs; size must
# be a non-zero byte-size in the PORTABLE grammar (e.g. 20G, 512m, 1.5G) —
# the intersection of sbx's units.RAMInBytes and msb's size parser. sbx also
# accepts b/ib suffixes (256MB, 2gib) but msb REJECTS them ("invalid digit
# found in string", verified on msb 0.6.12), so the neutral grammar excludes
# them: a size must work on every backend. Offending entries are DROPPED with
# a stderr warning (mirroring _kit_pp_validate). Absence is a silent no-op
# (defensive read, ADR-0014 precedent: the patterns schema property may lag
# the translator).
kit_spec_volumes() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  _kit_vol_parse_neutral "$spec" | _kit_vol_validate
}

# Parse the neutral top-level `volumes:` list into raw (unvalidated)
# tab-separated `path<TAB>type<TAB>size` records. Reads only the top-level
# block (dedent ends it). A record is emitted when ANY field is present so a
# pathless entry still reaches the validator (and `acq kit validate`) instead
# of vanishing silently.
_kit_vol_parse_neutral() {
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s); return s }
    function flush(){ if (cur_p != "" || cur_t != "" || cur_s != "") printf "%s\t%s\t%s\n", cur_p, cur_t, cur_s; cur_p=""; cur_t=""; cur_s="" }
    /^volumes:[[:space:]]*$/ { in_v=1; flush(); next }
    /^[A-Za-z]/ { if (in_v) { flush(); in_v=0 } }
    in_v {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /^[[:space:]]+-[[:space:]]/) {
        flush()
        line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line)
        k=line; sub(/:.*/,"",k); k=trim(k)
        v=line; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
        if (k=="path") cur_p=v; else if (k=="type") cur_t=v; else if (k=="size") cur_s=v
        next
      }
      if ($0 ~ /^[[:space:]]+[A-Za-z]/) {
        k=$0; sub(/:.*/,"",k); k=trim(k)
        v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
        if (k=="path") cur_p=v; else if (k=="type") cur_t=v; else if (k=="size") cur_s=v
        next
      }
    }
    END { if (in_v) flush() }
  ' "$1"
}

# Validate raw `path<TAB>type<TAB>size` records on stdin (SI-10): path absolute
# + safe charset; type "" or tmpfs; size required, non-zero, and in the
# PORTABLE byte-size grammar (integer or decimal + optional bare k/m/g/t/p
# unit). Deliberately NO b/ib suffixes: sbx's units.RAMInBytes accepts 256MB /
# 2gib but msb's parser rejects them (verified on 0.6.12), and a neutral size
# must work on every backend. Drops offending records with a stderr warning;
# emits the survivors unchanged.
_kit_vol_validate() {
  awk -F'\t' '
    {
      p=$1; t=$2; s=$3
      if (p=="")                          { print "kit-translate: skipping volume with missing path (size: " s ")" > "/dev/stderr"; next }
      if (p !~ /^\/[A-Za-z0-9._\/-]+$/)   { print "kit-translate: skipping volume with unsafe path: " p > "/dev/stderr"; next }
      # Require a NORMALIZED path: a volume mounts a whole unseeded filesystem,
      # so /. or // would shadow the guest root outright and /data/../etc would
      # mount over /etc while reading as a /data path in review. Reject empty
      # (//) and pure-dot (. / ..) segments and a trailing slash; dot-PREFIXED
      # names like /data/..hidden remain legal.
      if (p ~ /\/\// || p ~ /\/\.\.?(\/|$)/ || p ~ /\/$/) { print "kit-translate: skipping volume with non-normalized path (no . or .. segments, no //, no trailing /): " p > "/dev/stderr"; next }
      if (t!="" && t!="tmpfs")            { print "kit-translate: skipping volume with invalid type: " t > "/dev/stderr"; next }
      if (s=="")                          { print "kit-translate: skipping volume with missing size: " p > "/dev/stderr"; next }
      if (s !~ /^[0-9]+(\.[0-9]+)?[kKmMgGtTpP]?$/) { print "kit-translate: skipping volume with invalid size (portable grammar: 20G, 512m; no b/ib suffix): " s > "/dev/stderr"; next }
      if (s ~ /^0+(\.0+)?[kKmMgGtTpP]?$/) { print "kit-translate: skipping volume with zero size: " s > "/dev/stderr"; next }
      printf "%s\t%s\t%s\n", p, t, s
    }
  '
}

# ---------------------------------------------------------------------------
# kit_spec_files SPEC
# ---------------------------------------------------------------------------
# Echo one record per files[] entry, tab-separated:
#   path <TAB> mode <TAB> phase <TAB> source
# phase is empty if unspecified (default: written before commands run).
# source is empty for inline-content files (not used by the four acq kits).
kit_spec_files() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    BEGIN { FS=":" }
    /^files:/           { in_files=1; next }
    /^[A-Za-z]/         { if (in_files) { flush(); in_files=0 } }
    in_files {
      # New list item begins with "  - " (a key on the same line).
      if ($0 ~ /^[[:space:]]+-[[:space:]]/) {
        flush()
        # The dash line carries the first key (e.g. "  - path: /x").
        line=$0
        sub(/^[[:space:]]*-[[:space:]]*/,"",line)
        parse_kv(line)
        next
      }
      if ($0 ~ /^[[:space:]]+[A-Za-z]/) { parse_kv($0) }
    }
    END { if (in_files) flush() }
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s); return s }
    function parse_kv(l,   k,v) {
      k=l; sub(/:.*/,"",k); k=trim(k)
      v=l; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
      if (k=="path")   cur_path=v
      if (k=="mode")   cur_mode=v
      if (k=="phase")  cur_phase=v
      if (k=="source") cur_source=v
      if (k=="description") cur_desc=v
    }
    function flush() {
      if (cur_path != "") {
        # Reject fields that could break out of the shell contexts these values
        # are later interpolated into. A hostile or mistyped kit spec must not
        # smuggle a command via mode, a metacharacter-bearing path, or a bad
        # source path. Drop the whole record on any violation and warn.
        # mode: octal only. path/source: no shell metacharacters or whitespace.
        if (cur_mode != "" && cur_mode !~ /^[0-7]{3,4}$/) {
          print "kit-translate: skipping file with invalid mode: " cur_mode > "/dev/stderr"
        } else if (cur_path !~ /^[A-Za-z0-9._\/-]+$/) {
          print "kit-translate: skipping file with unsafe path: " cur_path > "/dev/stderr"
        } else if (cur_source != "" && cur_source !~ /^[A-Za-z0-9._\/-]+$/) {
          print "kit-translate: skipping file with unsafe source: " cur_source > "/dev/stderr"
        } else {
          printf "%s\t%s\t%s\t%s\n", cur_path, cur_mode, cur_phase, cur_source
        }
      }
      cur_path=""; cur_mode=""; cur_phase=""; cur_source=""; cur_desc=""
    }
  ' "$spec"
}

# ---------------------------------------------------------------------------
# kit_spec_commands SPEC
# ---------------------------------------------------------------------------
# Echo one record per commands[] entry. Each record is:
#   __CMD__ <TAB> phase <TAB> user <TAB> background
#   <base64 argv token 1>
#   <base64 argv token 2>
#   ...
#   __END__
# Each argv token is base64-encoded on a single line so that multi-line literal
# block scalars (`- |`) survive as ONE token (they contain embedded newlines
# that would otherwise be indistinguishable from token boundaries). Consumers
# read between __CMD__ and __END__ and base64-decode each line to recover argv.
#
# background is "true" or "false" (default false). It marks a startup command
# that must be DETACHED (run in the background) rather than awaited — see
# ADR-0014. Validation (SI-10): any `background:` value that is not a boolean is
# treated as false with a stderr warning, and the whole command is otherwise
# preserved.
#
# Parser scope: the hybrid/v1 commands: list as the four acq kits write it —
# a sequence of `- phase:`/`user:`/`description:`/`background:`/`command:`
# mappings, where command: is an argv list of plain scalars and/or a single
# `- |` literal block. Comment lines (bare `#`) and blank lines are ignored.
kit_spec_commands() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s); return s }

    # Determine indentation (count of leading spaces).
    function indent_of(s,   i){ i=match(s,/[^ ]/); return (i==0? 0 : i-1) }

    # Is this a comment or blank line (ignoring indentation)?
    function is_noise(s){ return (s ~ /^[[:space:]]*$/ || s ~ /^[[:space:]]*#/) }

    # base64-encode a string (portable: pipe through `base64 | tr -d newline`).
    function b64(s,   cmd,out) {
      cmd = "printf %s " q(s) " | base64 | tr -d \"\\n\""
      cmd | getline out
      close(cmd)
      return out
    }
    # shell single-quote a string for safe use in the b64 command line
    function q(s) { gsub(/'\''/, "'\''\\'\'''\''", s); return "'\''" s "'\''" }

    /^commands:/  { in_cmds=1; next }
    # Any new top-level key ends the commands block.
    /^[A-Za-z]/   { if (in_cmds) { if (in_block) { argv[n++]=block; in_block=0 } end_cmd(); in_cmds=0 } }
    !in_cmds { next }

    {
      if (in_block) {
        ind = indent_of($0)
        if ($0 ~ /^[[:space:]]*$/) { block = block "\n"; next }
        if (ind >= block_min_indent) {
          txt = substr($0, block_min_indent+1)
          block = (have_block_line ? block "\n" txt : txt)
          have_block_line=1
          next
        } else {
          # dedent: block scalar is done. Fall through to re-process THIS line
          # (it may be a new "- phase:" item or a sibling key).
          argv[n++] = block
          in_block=0
        }
      }

      if (is_noise($0)) next
      ind = indent_of($0)

      # New command list item: "  - phase: ..." — a dash at the command-mapping
      # indent (shallower than argv items). This starts a new command even when
      # we were mid-argv (the prior command argv list is now complete).
      if ($0 ~ /^[[:space:]]*-[[:space:]]*phase:/) {
        in_argv=0
        end_cmd()
        have=1
        line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line)
        handle_kv(line)
        next
      }

      # A bare "- " item outside an argv list also starts a new command (covers
      # a command whose first key is not phase, though the four kits lead with
      # phase). Only when not currently reading argv items.
      if ($0 ~ /^[[:space:]]*-[[:space:]]/ && in_argv==0) {
        end_cmd()
        have=1
        line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line)
        handle_kv(line)
        next
      }

      if (in_argv) {
        # argv items are dash-led at a deeper indent than the "command:" key.
        if ($0 ~ /^[[:space:]]*-[[:space:]]*\|[[:space:]]*$/) {
          in_block=1; block=""; have_block_line=0
          block_min_indent = indent_of($0) + 2
          next
        }
        if ($0 ~ /^[[:space:]]*-[[:space:]]/) {
          t=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",t)
          sub(/[[:space:]]*$/,"",t); gsub(/^"|"$/,"",t)
          argv[n++]=t
          next
        }
        # A non-dash key at mapping indent ends the argv list (e.g. next item).
        if ($0 ~ /^[[:space:]]+[A-Za-z]/) { in_argv=0; handle_kv($0); next }
      } else {
        if ($0 ~ /^[[:space:]]+[A-Za-z]/) { handle_kv($0); next }
      }
    }

    END { if (in_block) { argv[n++]=block; in_block=0 } end_cmd() }

    function handle_kv(l,   k,v) {
      k=l; sub(/:.*/,"",k); k=trim(k)
      v=l; sub(/^[^:]*:[[:space:]]*/,"",v)
      if (k=="phase")            phase=trim(v)
      else if (k=="user")        user=trim(v)
      else if (k=="background")  background=trim(v)
      else if (k=="description") { }
      else if (k=="command")     in_argv=1
    }
    function end_cmd(   i,tok,bg) {
      if (have) {
        # Validate the fields that later reach a shell/exec context. user is
        # interpolated into `msb exec -u <user>`; phase selects the lifecycle
        # branch. A hostile or mistyped kit spec must not smuggle anything here:
        # user must be a bare uid or a safe username token; phase must be one of
        # the known lifecycle phases. Drop the whole command on violation.
        # background must be a boolean; anything else is coerced to false with a
        # warning (SI-10) — the command itself is still emitted.
        bg="false"
        if (background=="true" || background=="false") bg=background
        else if (background!="") {
          print "kit-translate: command background must be true|false (got: " background "); treating as false" > "/dev/stderr"
        }
        if (user != "" && user !~ /^[A-Za-z0-9_-]+$/) {
          print "kit-translate: skipping command with unsafe user: " user > "/dev/stderr"
        } else if (phase != "" && phase !~ /^(install|initFiles|startup)$/) {
          print "kit-translate: skipping command with unknown phase: " phase > "/dev/stderr"
        } else {
          printf "__CMD__\t%s\t%s\t%s\n", phase, user, bg
          for (i=0;i<n;i++) {
            tok = argv[i]
            # Strip a single trailing newline left by a YAML block scalar so the
            # emitted argv token matches the literal command body.
            sub(/\n$/, "", tok)
            printf "%s\n", b64(tok)
          }
          printf "__END__\n"
        }
      }
      have=0; phase=""; user=""; background=""; in_argv=0; n=0
      delete argv
    }
  ' "$spec"
}

# ---------------------------------------------------------------------------
# kit_spec_has_shortcut SPEC BACKEND
# ---------------------------------------------------------------------------
# Return 0 if backend_shortcuts.<BACKEND> is present AND has at least one
# key (i.e. it is not the empty `{}` placeholder). Otherwise return 1.
kit_spec_has_shortcut() {
  local spec="$1" backend="$2"
  [ -f "$spec" ] || return 1
  awk -v backend="$backend" '
    /^backend_shortcuts:/ { in_bs=1; next }
    /^[A-Za-z]/           { if (in_bs) in_bs=0 }
    in_bs {
      # backend key at one indent level:  "  msb:" or "  msb: {}"
      if ($0 ~ "^[[:space:]]+" backend ":[[:space:]]*") {
        rest=$0; sub("^[[:space:]]+" backend ":[[:space:]]*","",rest)
        sub(/[[:space:]]*#.*/,"",rest); sub(/[[:space:]]+$/,"",rest)
        if (rest == "{}" || rest == "") {
          # inline empty, OR keys may follow on subsequent indented lines
          if (rest == "{}") { found=0; exit_now=1; exit }
          in_this=1; next
        } else {
          found=1; exit
        }
      } else if (in_this) {
        # a deeper-indented key under this backend means non-empty
        if ($0 ~ /^[[:space:]][[:space:]]+[A-Za-z]/) { found=1; exit }
        else { in_this=0 }
      }
    }
    END { if (found) print "yes" }
  ' "$spec" | grep -q yes
}

# ---------------------------------------------------------------------------
# kit_spec_shortcut_val SPEC BACKEND KEY
# ---------------------------------------------------------------------------
# Echo the scalar value of backend_shortcuts.<BACKEND>.<KEY> (e.g.
# trust_host_cas). Empty if absent.
kit_spec_shortcut_val() {
  local spec="$1" backend="$2" key="$3"
  [ -f "$spec" ] || return 0
  awk -v backend="$backend" -v key="$key" '
    /^backend_shortcuts:/ { in_bs=1; next }
    /^[A-Za-z]/           { if (in_bs) in_bs=0 }
    in_bs {
      if ($0 ~ "^[[:space:]]+" backend ":[[:space:]]*$") { in_this=1; next }
      if ($0 ~ "^[[:space:]]+" backend ":") { in_this=1 }
      else if ($0 ~ /^[[:space:]]+[A-Za-z]/ && $0 !~ "^[[:space:]][[:space:]]+") { in_this=0 }
      if (in_this && $0 ~ "^[[:space:]][[:space:]]+" key ":") {
        v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
        gsub(/^"|"$/,"",v)
        print v; exit
      }
    }
  ' "$spec"
}

# ---------------------------------------------------------------------------
# kit_spec_env SPEC
# ---------------------------------------------------------------------------
# Echo each environment[] entry as a tab-separated "NAME<TAB>value" line.
# The neutral environment block is a flat map of NAME: value (both strings):
#
#   environment:
#     OPENCODE_CONFIG: /home/agent/usai-config/opencode.jsonc
#     GITLAB_HOST: gitlab.example.gov
#
# SECURITY: env var NAMES reach the guest environment and a shell/exec context
# (sbx-v2 environment.variables and `msb exec -e NAME=value`), so a name is
# validated against ^[A-Za-z_][A-Za-z0-9_]*$ and a record with an unsafe name is
# DROPPED with a stderr warning (mirroring the mode/path/user hardening in
# kit_spec_files/kit_spec_commands). Values are passed through verbatim: they are
# threaded as a single argv element (msb `-e NAME=value`) or a quoted YAML scalar
# (sbx), never re-split by a shell, so a value cannot smuggle a second variable.
# This block is for NON-SECRET config only; secrets flow through the backend
# credential path, not the kit spec.
kit_spec_env() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    /^environment:/     { in_env=1; next }
    /^[A-Za-z]/         { if (in_env) in_env=0 }   # left the top-level block
    in_env {
      if ($0 ~ /^[[:space:]]*$/) next               # blank line
      if ($0 ~ /^[[:space:]]*#/) next               # comment line
      # A NAME: value entry, one indent level under environment:.
      if ($0 ~ /^[[:space:]]+[^:[:space:]#]+:/) {
        k=$0; sub(/:.*/,"",k); k=trim(k); gsub(/^"|"$/,"",k); gsub(/^'\''|'\''$/,"",k)
        v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
        gsub(/^"|"$/,"",v); gsub(/^'\''|'\''$/,"",v)
        if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
          print "kit-translate: skipping env var with unsafe name: " k > "/dev/stderr"
        } else {
          printf "%s\t%s\n", k, v
        }
      }
    }
  ' "$spec"
}

# ---------------------------------------------------------------------------
# kit_spec_agent_context SPEC
# ---------------------------------------------------------------------------# Echo the agentContext block scalar verbatim (dedented). Empty if absent.
kit_spec_agent_context() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    /^agentContext:[[:space:]]*[|>]/ { in_ctx=1; min=-1; next }
    # A top-level key or a column-0 comment ends the block.
    /^[A-Za-z]/     { if (in_ctx) in_ctx=0 }
    /^#/            { if (in_ctx) in_ctx=0 }
    in_ctx {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      ind = match($0,/[^ ]/)-1
      if (min < 0) min = ind
      print substr($0, min+1)
    }
  ' "$spec"
}

# ===========================================================================
# sbx-v2 synthesis — translate a neutral hybrid/v1 kit into an sbx "2" kit
# ===========================================================================
# The sbx backend consumes kits natively via `sbx --kit <local-dir-or-ref>`,
# parsing an sbx-schema spec.yaml itself. The neutral hybrid/v1 spec is a
# DIFFERENT schema, so sbx cannot consume it directly. kit_translate_to_sbx
# materializes an sbx-v2 kit directory (spec.yaml + files/ tree) from a fetched
# neutral kit, preserving the payloads and behavior verbatim. sbx then applies
# the synthesized local kit exactly as it applied the old sbx-kits.
#
# Mapping (neutral hybrid/v1 -> sbx schemaVersion "2"):
#   caps.network.allow[]            -> permissions.network.allow[]
#   environment{NAME:value}         -> environment.variables{NAME:value}
#     sbx v2 sets guest env via an `environment.variables` map (the mechanism
#     the pre-Phase-2 playbook-kit/openchamber kits used). The neutral flat map
#     maps 1:1 onto it.
#   files[] with source:            -> files/<...> static payload  (auto-mapped)
#     The whole files/ tree is copied verbatim; sbx v2 auto-maps files/home/...
#     -> /home/... at create time. The neutral `phase:` hint (e.g. initFiles) is
#     NOT re-emitted as a command — the static file-drop is sbx's create-time
#     mechanism and already lands the payload before setup hooks run.
#   commands[phase=install]         -> setup.install[]
#   commands[phase=initFiles]       -> setup.startup[]
#   commands[phase=startup]         -> setup.startup[]
#   agentContext                    -> agentInstructions.content
#   publishedPorts (neutral, top-level; or deprecated backend_extras.sbx) ->
#                                      ports[]                  (top-level, sbx-v2)
#   volumes (neutral, top-level)    -> volumes[]                (top-level, sbx-v2 §5.7)
#   backend_shortcuts.sbx           -> (none defined for the four kits; ignored)
#
# Usage: kit_translate_to_sbx NEUTRAL_KIT_DIR OUT_DIR
# Echoes OUT_DIR on success.
kit_translate_to_sbx() {
  local kitdir="$1" out="$2"
  local spec="${kitdir}/spec.yaml"
  if [ ! -f "$spec" ]; then
    echo "kit-translate: neutral spec not found: $spec" >&2
    return 1
  fi
  mkdir -p "$out"

  local name display desc
  name=$(kit_spec_field "$spec" name)
  display=$(kit_spec_field "$spec" displayName)
  desc=$(kit_spec_field "$spec" description)

  # Copy the entire files/ payload tree verbatim (static file drop). sbx v2
  # auto-maps files/home/... -> /home/... etc.
  if [ -d "${kitdir}/files" ]; then
    mkdir -p "${out}/files"
    cp -a "${kitdir}/files/." "${out}/files/"
  fi

  # Build the sbx-v2 spec.yaml.
  local sbxspec="${out}/spec.yaml"
  {
    printf 'schemaVersion: "2"\n'
    printf 'kind: mixin\n'
    printf 'name: %s\n' "$name"
    [ -n "$display" ] && printf 'displayName: %s\n' "$(_kit_yaml_quote "$display")"
    [ -n "$desc" ] && printf 'description: %s\n' "$(_kit_yaml_quote "$desc")"

    # caps.network.allow -> permissions.network.allow. Route each host through
    # _kit_yaml_quote: a neutral
    # allow entry may legitimately contain a YAML-special character — most
    # commonly a leading `*` for a wildcard subdomain (e.g. "*.npmjs.org"). Emit
    # it bare and YAML reads the `*` as an ALIAS, producing an invalid sbx spec
    # ("did not find expected alphabetic or numeric character"). Quoting keeps
    # plain hostnames bare and single-quotes only the special ones.
    local hosts
    hosts=$(kit_spec_net_allow "$spec")
    if [ -n "$hosts" ]; then
      printf 'permissions:\n  network:\n    allow:\n'
      printf '%s\n' "$hosts" | while IFS= read -r h; do
        [ -n "$h" ] && printf '      - %s\n' "$(_kit_yaml_quote "$h")"
      done
    fi

    # environment -> sbx-v2 environment.variables (native guest-env mechanism).
    local envrecs
    envrecs=$(kit_spec_env "$spec")
    if [ -n "$envrecs" ]; then
      printf 'environment:\n  variables:\n'
      printf '%s\n' "$envrecs" | while IFS="$(printf '\t')" read -r ekey eval; do
        [ -n "$ekey" ] || continue
        printf '    %s: %s\n' "$ekey" "$(_kit_yaml_quote "$eval")"
      done
    fi

    # publishedPorts -> sbx-v2 top-level ports. sbx maps each declared
    # CONTAINER (guest) port to an ephemeral host loopback port at create time.
    # Without this, an acq-applied kit that exposes a service is unreachable from
    # the host until the user runs `acq ports --publish`. The neutral source is
    # read FIRST by kit_spec_published_ports (with a deprecated backend_extras.sbx
    # fallback), so the emitted sbx-v2 shape is valid regardless of source.
    # Records are `guest<TAB>proto<TAB>name<TAB>host`; sbx-v2 keys on `container`
    # (the guest port), so the host column is not re-emitted here (sbx assigns the
    # host port).
    local portrecs
    portrecs=$(kit_spec_published_ports "$spec")
    if [ -n "$portrecs" ]; then
      printf 'ports:\n'
      # Parse each field with cut, NOT `IFS=<tab> read`: tab is IFS whitespace,
      # so a bare read COLLAPSES adjacent empty fields — an entry with guest +
      # host but no protocol/name ("3000<TAB><TAB><TAB>8080") would read the
      # host column into pproto and emit `protocol: 8080` (same pitfall as the
      # kit_spec_files consumer in msb.sh).
      printf '%s\n' "$portrecs" | while IFS= read -r prec; do
        pguest=$(printf '%s' "$prec" | cut -f1)
        pproto=$(printf '%s' "$prec" | cut -f2)
        pname=$(printf '%s' "$prec" | cut -f3)
        [ -n "$pguest" ] || continue
        # The neutral host column (field 4) is intentionally NOT re-emitted:
        # sbx-v2 keys on `container` (the guest port) and assigns the host port
        # itself, matching the pre-neutral observable shape.
        printf '  - container: %s\n' "$pguest"
        [ -n "$pproto" ] && printf '    protocol: %s\n' "$pproto"
        [ -n "$pname" ]  && printf '    name: %s\n' "$(_kit_yaml_quote "$pname")"
      done
    fi

    # volumes -> sbx-v2 top-level volumes (kit-spec v2 §5.7), fields passed
    # through 1:1. Creation-time only (`sbx kit add` skips them); sbx unions
    # multiple kits by path itself (last wins), so no merging happens here.
    local volrecs
    volrecs=$(kit_spec_volumes "$spec")
    if [ -n "$volrecs" ]; then
      printf 'volumes:\n'
      printf '%s\n' "$volrecs" | while IFS= read -r vrec; do
        vpath=$(printf '%s' "$vrec" | cut -f1)
        vtype=$(printf '%s' "$vrec" | cut -f2)
        vsize=$(printf '%s' "$vrec" | cut -f3)
        [ -n "$vpath" ] || continue
        printf '  - path: %s\n' "$vpath"
        [ -n "$vtype" ] && printf '    type: %s\n' "$vtype"
        printf '    size: %s\n' "$vsize"
      done
    fi
  } > "$sbxspec"

  _kit_sbx_emit_setup "$spec" "$sbxspec"

  local ctx
  ctx=$(kit_spec_agent_context "$spec")
  if [ -n "$ctx" ]; then
    {
      printf 'agentInstructions:\n  content: |\n'
      printf '%s\n' "$ctx" | while IFS= read -r cl; do printf '    %s\n' "$cl"; done
    } >> "$sbxspec"
  fi

  printf '%s\n' "$out"
}

# Emit setup.install/setup.startup blocks into an sbx-v2 spec from the neutral
# commands. v2 has no initFiles command phase, so neutral initFiles commands are
# emitted before startup commands under setup.startup.
_kit_sbx_emit_setup() {
  local spec="$1" out="$2"
  local phases="install initFiles startup"
  local phase have_setup=0 have_install=0 have_startup=0 tmp
  tmp=$(mktemp)

  for phase in $phases; do
    local cur_phase="" cur_user="" cur_bg="false" argv=() reading=0 line
    # Re-parse the neutral commands each phase (kits are tiny).
    while IFS= read -r line; do
      case "$line" in
        "__CMD__"*)
          cur_phase=$(printf '%s' "$line" | cut -f2)
          cur_user=$(printf '%s' "$line" | cut -f3)
          cur_bg=$(printf '%s' "$line" | cut -f4)
          argv=(); reading=1
          ;;
        "__END__")
          reading=0
          if [ "$cur_phase" = "$phase" ]; then
            if [ "$have_setup" -eq 0 ]; then printf 'setup:\n' >> "$tmp"; have_setup=1; fi
            if [ "$cur_phase" = "install" ] && [ "$have_install" -eq 0 ]; then
              printf '  install:\n' >> "$tmp"; have_install=1
            fi
            if [ "$cur_phase" != "install" ] && [ "$have_startup" -eq 0 ]; then
              printf '  startup:\n' >> "$tmp"; have_startup=1
            fi
            # Decode the base64 argv tokens back to raw strings.
            local decoded=() b
            for b in "${argv[@]}"; do
              decoded+=("$(printf '%s' "$b" | base64 -d)")
            done
            _kit_sbx_emit_one_setup_command "$cur_phase" "$cur_user" "$cur_bg" "$tmp" "${decoded[@]}"
          fi
          ;;
        *)
          [ "$reading" -eq 1 ] && argv+=("$line")
          ;;
      esac
    done <<EOF
$(kit_spec_commands "$spec")
EOF
  done

  cat "$tmp" >> "$out"
  rm -f "$tmp"
}

# Emit one sbx-v2 setup command from a decoded neutral argv.
_kit_sbx_emit_one_setup_command() {
  local phase="$1" user="$2" background="$3" out="$4"
  shift 4

  if [ "$phase" = "install" ]; then
    # setup.install[].command => shell STRING.
    local script
    if [ "$#" -eq 3 ] && [ "$1" = "sh" ] && [ "$2" = "-c" ]; then
      script="$3"
    else
      # Fallback: join argv into a single shell line (rare; the pinned kits use
      # the sh -c form). Individual tokens are not re-quoted — acceptable since
      # this path is not exercised by the four kits.
      script="$*"
    fi
    printf '    - command: |\n' >> "$out"
    printf '%s\n' "$script" | while IFS= read -r bl; do
        printf '        %s\n' "$bl" >> "$out"
    done
    [ -n "$user" ] && printf '      user: "%s"\n' "$user" >> "$out"
    return 0
  fi

  # setup.startup[].command => argv SEQUENCE. Neutral initFiles commands also
  # land here, before startup commands, because v2 has no initFiles command list.
  printf '    - command:\n' >> "$out"
  local tok
  for tok in "$@"; do
    # A token is multi-line if it contains a newline. `case` with a literal
    # newline in the glob is the portable way to test this.
    case "$tok" in
      *"
"*)
        # Multi-line token (a YAML block scalar in the source) — re-emit as a
        # literal block scalar so the argv element preserves its newlines.
        printf '        - |\n' >> "$out"
        printf '%s\n' "$tok" | while IFS= read -r bl; do
          printf '          %s\n' "$bl" >> "$out"
        done
        ;;
      *)
        # Single-line token — quote defensively.
        printf '        - %s\n' "$(_kit_yaml_quote "$tok")" >> "$out"
        ;;
    esac
  done
  [ -n "$user" ] && printf '      user: "%s"\n' "$user" >> "$out"
  [ "$background" = "true" ] && printf '      background: true\n' >> "$out"
}

# Minimal YAML scalar quoting: single-quote if the token contains YAML-special
# characters; otherwise emit bare. Doubles any embedded single quotes.
_kit_yaml_quote() {
  local s="$1"
  case "$s" in
    *[":{}[]#&*!|>'"'"'%@\`]*|-*|" "*|*" ")
      printf "'%s'" "$(printf '%s' "$s" | sed "s/'/''/g")"
      ;;
    "")
      printf "''"
      ;;
    *)
      printf '%s' "$s"
      ;;
  esac
}

# ===========================================================================
# kit_validate — validate a neutral hybrid/v1 kit spec
# ===========================================================================
# Structural validation of a kit at PATH (a kit directory or a spec.yaml).
# Checks the fields acq relies on, without a full JSON-schema engine (the
# authoritative JSON Schema lives in the patterns repo as
# schemas/kit-hybrid-v1.schema.json; the patterns CI validates against it).
# Returns 0 if valid, 1 otherwise; prints findings to stderr.
kit_validate() {
  local path="$1" spec
  if [ -d "$path" ]; then
    spec="${path}/spec.yaml"
  else
    spec="$path"
  fi
  if [ ! -f "$spec" ]; then
    echo "kit: validate: spec not found: $spec" >&2
    return 1
  fi

  local kitdir errs=0
  kitdir=$(dirname "$spec")

  # Required top-level fields.
  local schema kind name display desc
  schema=$(kit_spec_field "$spec" schemaVersion)
  kind=$(kit_spec_field "$spec" kind)
  name=$(kit_spec_field "$spec" name)
  display=$(kit_spec_field "$spec" displayName)
  desc=$(kit_spec_field "$spec" description)

  if [ "$schema" != "hybrid/v1" ]; then
    echo "kit: validate: schemaVersion must be \"hybrid/v1\" (got: '${schema:-<missing>}')" >&2
    errs=$((errs + 1))
  fi
  if [ "$kind" != "mixin" ]; then
    echo "kit: validate: kind must be \"mixin\" (got: '${kind:-<missing>}')" >&2
    errs=$((errs + 1))
  fi
  case "$name" in
    "" ) echo "kit: validate: name is required" >&2; errs=$((errs + 1)) ;;
    *[!a-z0-9-]* ) echo "kit: validate: name must be kebab-case ([a-z0-9-]): '$name'" >&2; errs=$((errs + 1)) ;;
  esac
  [ -z "$display" ] && { echo "kit: validate: displayName is required" >&2; errs=$((errs + 1)); }
  [ -z "$desc" ]    && { echo "kit: validate: description is required" >&2; errs=$((errs + 1)); }

  # files[]: each source: must exist under the kit dir; each path must be
  # absolute; mode (if present) must be octal. kit_spec_files already DROPS
  # records with an unsafe mode/path/source (defense-in-depth for the shell
  # contexts they reach), so validate also scans the RAW spec for a `mode:` that
  # isn't octal — otherwise a hostile mode would be silently dropped rather than
  # reported by `acq kit validate`.
  local fline p src
  while IFS= read -r fline; do
    [ -n "$fline" ] || continue
    p=$(printf '%s' "$fline" | cut -f1)
    src=$(printf '%s' "$fline" | cut -f4)
    [ -n "$p" ] || continue
    case "$p" in
      /*) ;;
      *) echo "kit: validate: file path must be absolute: '$p'" >&2; errs=$((errs + 1)) ;;
    esac
    if [ -n "$src" ] && [ ! -f "${kitdir}/${src}" ]; then
      echo "kit: validate: file source not found: ${src}" >&2
      errs=$((errs + 1))
    fi
  done <<EOF
$(kit_spec_files "$spec")
EOF

  # Raw-spec scan: any `mode:` value that is not 3-4 octal digits is rejected
  # (it would break out of the root `chmod $mode` in the msb adapter).
  local bad_mode
  bad_mode=$(awk '
    /^[[:space:]]+mode:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v)
      gsub(/^["'\'' ]+|["'\'' ]+$/,"",v)
      if (v !~ /^[0-7]{3,4}$/) print v
    }' "$spec")
  if [ -n "$bad_mode" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] && { echo "kit: validate: file mode must be octal (3-4 digits): '$m'" >&2; errs=$((errs + 1)); }
    done <<EOF
$bad_mode
EOF
  fi

  # commands[]: each must have a known phase. kit_spec_commands DROPS commands
  # with an unknown phase or unsafe user (defense-in-depth), so scan the RAW
  # spec here — otherwise a bad phase would be silently dropped rather than
  # reported by `acq kit validate`. A `phase:` line under commands[] must be one
  # of install|initFiles|startup; a `user:` must be a bare uid/safe username.
  local bad_phase bad_user
  bad_phase=$(awk '
    /^commands:/ { in_c=1; next }
    /^[A-Za-z]/  { in_c=0 }
    in_c && /^[[:space:]]+-?[[:space:]]*phase:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v)
      gsub(/^["'\'' ]+|["'\'' ]+$/,"",v)
      if (v !~ /^(install|initFiles|startup)$/) print v
    }' "$spec")
  if [ -n "$bad_phase" ]; then
    while IFS= read -r ph; do
      [ -n "$ph" ] && { echo "kit: validate: unknown command phase: '$ph'" >&2; errs=$((errs + 1)); }
    done <<EOF
$bad_phase
EOF
  fi
  bad_user=$(awk '
    /^commands:/ { in_c=1; next }
    /^[A-Za-z]/  { in_c=0 }
    in_c && /^[[:space:]]+-?[[:space:]]*user:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v)
      gsub(/^["'\'' ]+|["'\'' ]+$/,"",v)
      if (v != "" && v !~ /^[A-Za-z0-9_-]+$/) print v
    }' "$spec")
  if [ -n "$bad_user" ]; then
    while IFS= read -r u; do
      [ -n "$u" ] && { echo "kit: validate: unsafe command user: '$u'" >&2; errs=$((errs + 1)); }
    done <<EOF
$bad_user
EOF
  fi

  # environment[]: each key must be a valid POSIX env var NAME. kit_spec_env
  # DROPS entries with an unsafe name (defense-in-depth for the shell/exec
  # contexts they reach), so scan the RAW spec here — otherwise a bad name would
  # be silently dropped rather than reported by `acq kit validate`.
  local bad_env
  bad_env=$(awk '
    /^environment:/ { in_e=1; next }
    /^[A-Za-z]/     { in_e=0 }
    in_e {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /^[[:space:]]+[^:[:space:]#]+:/) {
        k=$0; sub(/:.*/,"",k)
        sub(/^[[:space:]]+/,"",k); sub(/[[:space:]]+$/,"",k)
        gsub(/^["'\'']|["'\'']$/,"",k)
        if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) print k
      }
    }' "$spec")
  if [ -n "$bad_env" ]; then
    while IFS= read -r en; do
      [ -n "$en" ] && { echo "kit: validate: invalid env var name (must match [A-Za-z_][A-Za-z0-9_]*): '$en'" >&2; errs=$((errs + 1)); }
    done <<EOF
$bad_env
EOF
  fi

  # publishedPorts[] (neutral top-level) + backend_extras.sbx.publishedPorts
  # (deprecated). kit_spec_published_ports DROPS entries with an invalid port /
  # protocol / name (defense-in-depth for the argv/-p they reach), so scan the RAW
  # spec here — otherwise a bad value would be silently dropped rather than
  # reported by `acq kit validate`. guest/host/container must be 1..65535 ints;
  # protocol tcp|udp; name [A-Za-z0-9._-]. (ADR-0014, SI-10)
  local bad_ports
  bad_ports=$(awk '
    function bad_port(v){ return (v !~ /^[0-9]+$/ || v+0 < 1 || v+0 > 65535) }
    function val(l,   v){ v=l; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); gsub(/^["'\'' ]+|["'\'' ]+$/,"",v); return v }
    /^publishedPorts:/  { in_pp=1; in_bpp=0; next }
    /^backend_extras:/  { in_be=1 }
    /^[A-Za-z]/         { if ($0 !~ /^publishedPorts:/) in_pp=0 }
    in_be && /^[[:space:]]+publishedPorts:/ { in_bpp=1; next }
    in_be && /^[[:space:]]+[A-Za-z_]+:[[:space:]]*$/ && $0 !~ /publishedPorts:/ { in_bpp=0 }
    (in_pp || in_bpp) {
      if ($0 ~ /^[[:space:]]+-?[[:space:]]*(guest|host|container):/) {
        v=val($0); if (bad_port(v)) print "port:" v
      } else if ($0 ~ /^[[:space:]]+-?[[:space:]]*protocol:/) {
        v=val($0); if (v!="" && v!="tcp" && v!="udp") print "protocol:" v
      } else if ($0 ~ /^[[:space:]]+-?[[:space:]]*name:/) {
        v=val($0); if (v!="" && v !~ /^[A-Za-z0-9._-]+$/) print "name:" v
      }
    }' "$spec")
  if [ -n "$bad_ports" ]; then
    while IFS= read -r bp; do
      [ -n "$bp" ] && { echo "kit: validate: invalid publishedPorts entry (${bp%%:*}='${bp#*:}'; ports 1..65535, protocol tcp|udp, name [A-Za-z0-9._-])" >&2; errs=$((errs + 1)); }
    done <<EOF
$bad_ports
EOF
  fi

  # volumes[] (neutral top-level). kit_spec_volumes DROPS entries with a
  # missing/unsafe path, bad type, or missing/invalid size (defense-in-depth for
  # the sbx-v2 spec + msb argv they reach), so validate the RAW parsed records
  # here — otherwise a bad entry would be silently dropped rather than reported
  # by `acq kit validate`. path absolute + [A-Za-z0-9._/-]; type "" | tmpfs;
  # size required, non-zero, portable grammar (no b/ib suffix — msb rejects
  # them). A valid-but-small block size additionally gets a WARNING (not an
  # error): msb refuses ext4 disk images under 128M, so a sub-floor size
  # passes validate for sbx-only use but will fail an msb create.
  # (ADR-0022, SI-10)
  local vline vp vt vs vbytes
  while IFS= read -r vline; do
    [ -n "$vline" ] || continue
    vp=$(printf '%s' "$vline" | cut -f1)
    vt=$(printf '%s' "$vline" | cut -f2)
    vs=$(printf '%s' "$vline" | cut -f3)
    if [ -z "$vp" ]; then
      echo "kit: validate: volume path is required" >&2; errs=$((errs + 1))
    else
      case "$vp" in
        /*)
          if printf '%s' "$vp" | LC_ALL=C grep -q '[^A-Za-z0-9._/-]'; then
            echo "kit: validate: volume path has illegal characters: '$vp'" >&2; errs=$((errs + 1))
          elif printf '%s' "$vp" | LC_ALL=C grep -Eq '//|/\.\.?(/|$)|/$'; then
            echo "kit: validate: volume path must be normalized (no . or .. segments, no //, no trailing /): '$vp'" >&2; errs=$((errs + 1))
          fi ;;
        *) echo "kit: validate: volume path must be absolute: '$vp'" >&2; errs=$((errs + 1)) ;;
      esac
    fi
    if [ -n "$vt" ] && [ "$vt" != "tmpfs" ]; then
      echo "kit: validate: volume type must be \"\" (block) or tmpfs: '$vt'" >&2; errs=$((errs + 1))
    fi
    if [ -z "$vs" ]; then
      echo "kit: validate: volume size is required (path: '${vp:-<missing>}')" >&2; errs=$((errs + 1))
    elif ! printf '%s' "$vs" | LC_ALL=C grep -Eq '^[0-9]+(\.[0-9]+)?[kKmMgGtTpP]?$'; then
      echo "kit: validate: volume size must be a portable byte-size (e.g. 20G, 512m; no b/ib suffix — msb rejects them): '$vs'" >&2; errs=$((errs + 1))
    elif printf '%s' "$vs" | LC_ALL=C grep -Eq '^0+(\.0+)?[kKmMgGtTpP]?$'; then
      echo "kit: validate: volume size must be non-zero: '$vs'" >&2; errs=$((errs + 1))
    elif [ "$vt" != "tmpfs" ]; then
      vbytes=$(printf '%s' "$vs" | awk '{
        n=$0; u=""
        if (n ~ /[kKmMgGtTpP]$/) { u=tolower(substr(n,length(n),1)); n=substr(n,1,length(n)-1) }
        m=1
        if (u=="k") m=1024; else if (u=="m") m=1048576; else if (u=="g") m=1073741824
        else if (u=="t") m=1099511627776; else if (u=="p") m=1125899906842624
        printf "%.0f", n*m
      }')
      if [ -n "$vbytes" ] && [ "$vbytes" -lt 134217728 ] 2>/dev/null; then
        echo "kit: validate: warning: block volume '$vp' size '$vs' is below msb's 128M ext4 floor (fails msb create; fine for sbx-only kits)" >&2
      fi
    fi
  done <<EOF
$(_kit_vol_parse_neutral "$spec")
EOF

  # commands[].background must be a boolean. kit_spec_commands coerces a
  # non-boolean to false (defense-in-depth), so scan the RAW spec to REPORT it.
  local bad_bg
  bad_bg=$(awk '
    /^commands:/ { in_c=1; next }
    /^[A-Za-z]/  { in_c=0 }
    in_c && /^[[:space:]]+-?[[:space:]]*background:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v)
      gsub(/^["'\'' ]+|["'\'' ]+$/,"",v)
      if (v != "true" && v != "false") print v
    }' "$spec")
  if [ -n "$bad_bg" ]; then
    while IFS= read -r b; do
      [ -n "$b" ] && { echo "kit: validate: command background must be true|false: '$b'" >&2; errs=$((errs + 1)); }
    done <<EOF
$bad_bg
EOF
  fi

  if [ "$errs" -eq 0 ]; then
    echo "kit: validate: OK — ${name} (${display})"
    return 0
  fi
  echo "kit: validate: ${errs} problem(s) found in ${spec}" >&2
  return 1
}
