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
#   kit_spec_files       SPEC                -> one "path|mode|phase|source" per line
#   kit_spec_commands    SPEC                -> command records (see format below)
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
      command -v acq_debug >/dev/null 2>&1 && acq_debug "fetch: $url ref=$ref dir=$dir -> $destdir"
      mkdir -p "$destdir"
      local _ferr
      _ferr=$(
        cd "$destdir" || exit 1
        git init -q
        git remote add origin "$url" 2>/dev/null || git remote set-url origin "$url"
        git config core.sparseCheckout true
        printf '%s/*\n' "$dir" > .git/info/sparse-checkout
        git fetch --depth 1 origin "$ref" 2>&1 || exit 1
        git checkout -q FETCH_HEAD 2>&1 || exit 1
      ) || {
        echo "kit-translate: failed to fetch $kitref" >&2
        [ -n "$_ferr" ] && printf '%s\n' "$_ferr" | sed 's/^/kit-translate:   /' >&2
        return 1
      }
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
        printf "%s\t%s\t%s\t%s\n", cur_path, cur_mode, cur_phase, cur_source
      }
      cur_path=""; cur_mode=""; cur_phase=""; cur_source=""; cur_desc=""
    }
  ' "$spec"
}

# ---------------------------------------------------------------------------
# kit_spec_commands SPEC
# ---------------------------------------------------------------------------
# Echo one record per commands[] entry. Each record is:
#   __CMD__ <TAB> phase <TAB> user
#   <base64 argv token 1>
#   <base64 argv token 2>
#   ...
#   __END__
# Each argv token is base64-encoded on a single line so that multi-line literal
# block scalars (`- |`) survive as ONE token (they contain embedded newlines
# that would otherwise be indistinguishable from token boundaries). Consumers
# read between __CMD__ and __END__ and base64-decode each line to recover argv.
#
# Parser scope: the hybrid/v1 commands: list as the four acq kits write it —
# a sequence of `- phase:`/`user:`/`description:`/`command:` mappings, where
# command: is an argv list of plain scalars and/or a single `- |` literal block.
# Comment lines (bare `#`) and blank lines are ignored everywhere.
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
      else if (k=="description") { }
      else if (k=="command")     in_argv=1
    }
    function end_cmd(   i,tok) {
      if (have) {
        printf "__CMD__\t%s\t%s\n", phase, user
        for (i=0;i<n;i++) {
          tok = argv[i]
          # Strip a single trailing newline left by a YAML block scalar so the
          # emitted argv token matches the literal command body.
          sub(/\n$/, "", tok)
          printf "%s\n", b64(tok)
        }
        printf "__END__\n"
      }
      have=0; phase=""; user=""; in_argv=0; n=0
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
# kit_spec_agent_context SPEC
# ---------------------------------------------------------------------------
# Echo the agentContext block scalar verbatim (dedented). Empty if absent.
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
#   caps.network.allow[]            -> caps.network.allow[]        (identical)
#   files[] with source:            -> files/<...> static payload  (auto-mapped)
#     The whole files/ tree is copied verbatim; sbx v2 auto-maps files/home/...
#     -> /home/... at create time. The neutral `phase:` hint (e.g. initFiles) is
#     NOT re-emitted as a command — the static file-drop is sbx's create-time
#     mechanism and already lands the payload before commands run, matching the
#     former sbx kits (which likewise relied on the implicit files/ drop).
#   commands[phase=install]         -> commands.install[]
#   commands[phase=initFiles]       -> commands.initFiles[]  (command form)
#   commands[phase=startup]         -> commands.startup[]
#   agentContext                    -> agentContext            (identical)
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

    # caps.network.allow
    local hosts
    hosts=$(kit_spec_net_allow "$spec")
    if [ -n "$hosts" ]; then
      printf 'caps:\n  network:\n    allow:\n'
      printf '%s\n' "$hosts" | while IFS= read -r h; do
        [ -n "$h" ] && printf '      - %s\n' "$h"
      done
    fi
  } > "$sbxspec"

  # commands: group by phase. We stream the neutral commands and emit sbx-v2
  # command entries under commands.<phase>.
  _kit_sbx_emit_commands "$spec" "$sbxspec"

  # agentContext (verbatim block scalar).
  local ctx
  ctx=$(kit_spec_agent_context "$spec")
  if [ -n "$ctx" ]; then
    {
      printf 'agentContext: |\n'
      printf '%s\n' "$ctx" | while IFS= read -r cl; do printf '  %s\n' "$cl"; done
    } >> "$sbxspec"
  fi

  printf '%s\n' "$out"
}

# Emit commands.<phase> blocks into an sbx-v2 spec from the neutral commands.
# Groups records by phase so sbx sees `commands: { install: [...], initFiles:
# [...], startup: [...] }`.
_kit_sbx_emit_commands() {
  local spec="$1" out="$2"
  local phases="install initFiles startup"
  local phase have_any=0 tmp
  tmp=$(mktemp)

  for phase in $phases; do
    local emitted_header=0
    local cur_phase="" cur_user="" argv=() reading=0 line
    # Re-parse the neutral commands each phase (kits are tiny).
    while IFS= read -r line; do
      case "$line" in
        "__CMD__"*)
          cur_phase=$(printf '%s' "$line" | cut -f2)
          cur_user=$(printf '%s' "$line" | cut -f3)
          argv=(); reading=1
          ;;
        "__END__")
          reading=0
          if [ "$cur_phase" = "$phase" ]; then
            if [ "$have_any" -eq 0 ]; then printf 'commands:\n' >> "$tmp"; have_any=1; fi
            if [ "$emitted_header" -eq 0 ]; then printf '  %s:\n' "$phase" >> "$tmp"; emitted_header=1; fi
            # Decode the base64 argv tokens back to raw strings.
            local decoded=() b
            for b in "${argv[@]}"; do
              decoded+=("$(printf '%s' "$b" | base64 -d)")
            done
            _kit_sbx_emit_one_command "$phase" "$cur_user" "$tmp" "${decoded[@]}"
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

# Emit one sbx-v2 command list entry from a decoded argv, keyed by PHASE.
#
# sbx v2 types the `command:` field DIFFERENTLY per phase (verified against the
# pre-Phase-2 sbx kits and sbx's own unmarshaler):
#   - commands.install[].command   : a shell STRING  (git-ssh-sign used `command: |`)
#   - commands.startup[].command   : a []string SEQUENCE (usai/playbook/zscaler)
#   - commands.initFiles[].command : a []string SEQUENCE (same as startup)
# Feeding a seq where sbx wants a string (or vice-versa) yields
# "cannot unmarshal !!seq into string" / "!!str into []string".
#
# So: emit install as a string, and startup/initFiles as an argv sequence. For
# the install string we unwrap a `sh -c SCRIPT` argv to just SCRIPT (its natural
# shell-string form); any other install argv is space-joined as a fallback.
_kit_sbx_emit_one_command() {
  local phase="$1" user="$2" out="$3"
  shift 3

  if [ "$phase" = "install" ]; then
    # install => shell STRING.
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

  # startup / initFiles => argv SEQUENCE.
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

  # files[]: each source: must exist under the kit dir; each path must be absolute.
  local fline p m ph src
  while IFS= read -r fline; do
    [ -n "$fline" ] || continue
    p=$(printf '%s' "$fline" | cut -f1)
    m=$(printf '%s' "$fline" | cut -f2)
    ph=$(printf '%s' "$fline" | cut -f3)
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

  # commands[]: each must have a known phase.
  local line
  while IFS= read -r line; do
    case "$line" in
      "__CMD__"*)
        local ph2
        ph2=$(printf '%s' "$line" | cut -f2)
        case "$ph2" in
          install|initFiles|startup) ;;
          *) echo "kit: validate: unknown command phase: '${ph2:-<empty>}'" >&2; errs=$((errs + 1)) ;;
        esac
        ;;
    esac
  done <<EOF
$(kit_spec_commands "$spec")
EOF

  if [ "$errs" -eq 0 ]; then
    echo "kit: validate: OK — ${name} (${display})"
    return 0
  fi
  echo "kit: validate: ${errs} problem(s) found in ${spec}" >&2
  return 1
}
