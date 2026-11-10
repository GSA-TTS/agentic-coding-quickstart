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
# Both backends fetch locally through kit_translate_fetch so acq's ref and
# payload checks always run. The sbx adapter then synthesizes an sbx-v2 kit
# directory for `sbx --kit`; if the fetch fails it does not apply the kit, and
# never hands sbx the raw remote ref. The msb backend has no native kit
# mechanism, so it drives the parsed operations itself.
#
# ---------------------------------------------------------------------------
# Parsed-spec accessor functions (all take the kit's local spec.yaml path)
# ---------------------------------------------------------------------------
#   kit_spec_field       SPEC KEY            -> top-level scalar (name, kind, …)
#   kit_spec_net_allow   SPEC                -> one host[:port] per line
#   kit_spec_published_ports SPEC            -> one "guest<TAB>proto<TAB>name<TAB>host" per line
#   kit_spec_volumes     SPEC                -> one "path<TAB>type<TAB>size" per line
#   kit_spec_files       SPEC                -> one "path|mode|phase|source|readonly" per line
#   kit_spec_commands    SPEC                -> command records (see format below)
#   kit_spec_env         SPEC                -> one "NAME<TAB>value" per line
#   kit_spec_has_shortcut SPEC BACKEND       -> 0 if backend_shortcuts.<backend>
#                                               is present AND non-empty
#   kit_spec_shortcut_val SPEC BACKEND KEY   -> value of a shortcut key
#
# These read the spec file each call (kits are tiny; simplicity over caching).

# _kit_git_isolate — unset the environment variables that point git at a
# repository, work tree, index, object store or ref namespace other than the one
# found from the current directory or -C, or that inject configuration. Call it
# inside a subshell before running git on the kit cache: an inherited GIT_DIR
# (set by a hook, an editor or a parent git command) would otherwise make
# `git init`, `remote`, `config` and `fetch` rewrite that repository, GIT_CONFIG
# would redirect `git config` writes to another file, and GIT_CONFIG_PARAMETERS
# or GIT_CONFIG_COUNT/KEY_n/VALUE_n could set core.worktree and move the
# checkout. The fixed list is a superset of `git rev-parse --local-env-vars`
# (git 2.53), plus GIT_NAMESPACE; a test checks it against the installed git.
# GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM are kept: they select the user's own
# config files, which the authenticated retry reads for credential helpers.
# The msb clone mode (msb.sh) uses it for its host-side git calls too.
_kit_git_isolate() {
  local _v
  _kit_git_isolate_repo
  unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  for _v in $(compgen -v GIT_CONFIG_KEY_) $(compgen -v GIT_CONFIG_VALUE_); do
    unset "$_v"
  done
}

# _kit_git_isolate_repo — the part of _kit_git_isolate that keeps the command
# scope: unset the variables that point git at another repository, work tree,
# index, object store or ref namespace, or send `git config` to another file,
# but keep GIT_CONFIG_PARAMETERS and GIT_CONFIG_COUNT/KEY_n/VALUE_n. Only for a
# caller that reads the user's command-scope config on purpose and runs
# nothing that config could name (a `git config` read); everything else calls
# _kit_git_isolate.
_kit_git_isolate_repo() {
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_OBJECT_DIRECTORY \
    GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE \
    GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE \
    GIT_COMMON_DIR GIT_NAMESPACE
}

# _kit_anon_protocols — the GIT_ALLOW_PROTOCOL value for the anonymous kit
# fetch: https, the only transport a kit URL may name. An inherited
# GIT_ALLOW_PROTOCOL only narrows it; when it leaves nothing, a name no
# transport has allows nothing.
_kit_anon_protocols() {
  local want="https"
  if [ -z "${GIT_ALLOW_PROTOCOL+x}" ]; then
    printf '%s\n' "$want"
    return 0
  fi
  case ":$GIT_ALLOW_PROTOCOL:" in
    *":$want:"*) printf '%s\n' "$want" ;;
    *) printf 'acq-none\n' ;;
  esac
}

# _kit_git_fetch_into MODE DESTDIR URL REF DIR — one attempt at fetching REF
# from URL into a fresh repository in DESTDIR, sparse-checked-out to DIR. git's
# output goes to stdout, for the caller to capture and never show.
#
# MODE anon reads no git config file at all (GIT_CONFIG_NOSYSTEM, and
# GIT_CONFIG_GLOBAL on the null device), so no credential helper, URL rewrite,
# hook path or template from the user's config applies, and git may use only
# the transports _kit_anon_protocols allows. `credential.helper=` also resets
# the helper list on a git too old to know GIT_CONFIG_GLOBAL.
# MODE user keeps the user's config files, so a configured credential helper or
# an enterprise-mirror rewrite can apply, with prompts still disabled.
# In both modes core.hooksPath names the null device, which holds no hook, so
# a hook from the user's config never runs in the kit cache.
_kit_git_fetch_into() {
  local mode="$1" destdir="$2" url="$3" ref="$4" dir="$5"
  (
    cd "$destdir" || exit 1
    _kit_git_isolate
    export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo GCM_INTERACTIVE=never
    if [ "$mode" = anon ]; then
      unset GIT_CONFIG_SYSTEM
      GIT_ALLOW_PROTOCOL=$(_kit_anon_protocols)
      export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL
    fi
    rm -rf .git 2>/dev/null
    # Stop if init fails: the cache directory may sit inside another
    # repository, and every git call below would then reconfigure and
    # fetch into that enclosing repository instead.
    if ! git init -q; then
      echo "kit-translate: git init failed in the kit cache directory: $destdir" >&2
      exit 1
    fi
    { git remote add origin "$url" 2>/dev/null || git remote set-url origin "$url"; } || exit 1
    git config core.sparseCheckout true || exit 1
    # `git init` does not always create .git/info/ (platform-dependent),
    # so create it before writing the sparse-checkout file — otherwise the
    # redirect fails with ".git/info/sparse-checkout: No such file or
    # directory" (harmless-but-noisy; fetch still fell back).
    mkdir -p .git/info
    printf '%s/*\n' "$dir" > .git/info/sparse-checkout
    if [ "$mode" = anon ]; then
      git -c credential.helper= -c core.hooksPath=/dev/null fetch --depth 1 origin "$ref" 2>&1 || exit 1
    else
      git -c core.hooksPath=/dev/null fetch --depth 1 origin "$ref" 2>&1 || exit 1
    fi
    git -c core.hooksPath=/dev/null checkout -q FETCH_HEAD 2>&1 || exit 1
  )
}

# Only full immutable commit IDs participate. Symbolic/abbreviated refs keep
# their original per-call fetch semantics. The owning acq shell creates and
# cleans this private root; command substitutions share files, not shell state.
_kit_fetch_reuse() {
  local kitref="$1" destdir="$2" url="$3" ref="$4" dir="$5"
  local key source actual
  key=$(_kit_git_isolate; printf '%s\0%s' "$url" "$ref" | git hash-object --stdin) || return 1
  source="$_ACQ_KIT_FETCH_ROOT/$key"
  if [ ! -f "$source/.git/acq-verified" ]; then
    # Fetch into a private source, never a consumer's mutable destination.
    # The empty root disables recursion without affecting the owning shell.
    _ACQ_KIT_FETCH_ROOT='' kit_translate_fetch "$kitref" "$source" >/dev/null || return 1
    actual=$(_kit_git_isolate; git -C "$source" rev-parse HEAD 2>/dev/null) || return 1
    if [ "$actual" != "$ref" ]; then
      echo 'kit-translate: failed to fetch remote kit' >&2
      echo 'kit-translate:   fetched revision does not match pinned commit' >&2
      return 1
    fi
    : > "$source/.git/acq-verified" || return 1
  fi
  _kit_fetch_materialize "$source" "$ref" "$dir" "$destdir"
}

# Read committed objects, not the source working tree. Never hand that tree to
# consumers: their edits must not contaminate later provider/agent/kit reads.
_kit_fetch_materialize() (
  set -o pipefail
  local source="$1" ref="$2" dir="$3" destdir="$4" stage tree
  _kit_git_isolate
  # Filesystem spelling permits ./ and repeated slashes; Git tree lookup does
  # not. Traversal has already been rejected by the shared source validator.
  dir=$(printf '%s' "$dir" | sed -e 's|//*|/|g' -e ':again' \
    -e 's|^\./||' -e 's|/\./|/|g' -e 't again' -e 's|/\.$||' -e 's|/$||')
  [ "$dir" != . ] || dir=''
  tree="$ref:$dir"
  if [ "$(git -C "$source" cat-file -t "$tree" 2>/dev/null)" != tree ]; then
    echo 'kit-translate: remote kit directory not found' >&2
    return 1
  fi
  stage=$(mktemp -d "$_ACQ_KIT_FETCH_ROOT/materialize.XXXXXX") || return 1
  trap 'rm -rf -- "$stage"' EXIT
  mkdir -p "$stage/payload/$dir" || return 1
  # checkout-index preserves files marked export-ignore/export-subst, unlike
  # git archive. A private index also leaves the verified source untouched.
  export GIT_INDEX_FILE="$stage/index"
  if ! git -C "$source" read-tree "$tree" 2>/dev/null ||
      ! git -C "$source" checkout-index --all --prefix="$stage/payload/$dir/" 2>/dev/null; then
    echo 'kit-translate: failed to materialize remote kit' >&2
    return 1
  fi
  rm -f -- "$stage/index" || return 1
  mkdir -p "$(dirname "$destdir")" || return 1
  rm -rf -- "$destdir" || return 1
  mv -- "$stage/payload" "$destdir" || return 1
  printf '%s/%s\n' "$destdir" "$dir"
)

# ---------------------------------------------------------------------------
# kit_ref_display REF
# ---------------------------------------------------------------------------
# Echo a kit ref safe for a terminal or CI log. Every message that names a ref
# acq could not fetch or refused goes through this, on both backends, because
# such a ref may carry a credential that kit_translate_fetch refuses but the
# message would otherwise repeat. In the part before the '#' fragment:
#   - a query string (?private_token=…) becomes ?***;
#   - URL userinfo (scheme://user:token@host) becomes scheme://***@host,
#     cutting at the last '@';
#   - without a scheme, a first path segment carrying any userinfo
#     (user:token@host, or a bare token@host) becomes ***@host.
# The fragment's first ref= and dir= are kept so the message still names the
# kit when their value is plain ([A-Za-z0-9._/-]); a repeat or any other
# fragment parameter becomes ***, and an odd value becomes ref=*** or dir=***
# (kit_ref_shape_check refuses such a ref, but a message about it must not
# repeat the value). This
# over-redacts when a path or host part legitimately contains '@' or ':',
# which is harmless.
kit_ref_display() {
  local ref="${1:-}" base frag query="" first rest p out=""
  base="${ref%%#*}"
  frag="${ref#"$base"}"
  if [ -n "$frag" ]; then
    rest="${frag#'#'}"
    local seen=" "
    while :; do
      p="${rest%%&*}"
      case "$p" in
        ref=* | dir=*)
          # The first ref= and dir= are kept when their value is plain; a
          # repeat, or a value with any other character, is hidden.
          case "$seen" in
            *" ${p%%=*} "*) out="${out}&***" ;;
            *)
              case "${p#*=}" in
                "" | *[!A-Za-z0-9._/-]*) out="${out}&${p%%=*}=***" ;;
                *) out="${out}&${p}" ;;
              esac
              ;;
          esac
          seen="${seen}${p%%=*} "
          ;;
        *) out="${out}&***" ;;
      esac
      [ "$rest" != "$p" ] || break
      rest="${rest#*&}"
    done
    frag="#${out#&}"
  fi
  case "$base" in
    *\?*) base="${base%%\?*}"; query='?***' ;;
  esac
  case "$base" in
    *://*@*) base="${base%%://*}://***@${base##*@}" ;;
    *://*) ;;
    *)
      first="${base%%/*}"
      case "$first" in
        *@*) base="***@${first##*@}${base#"$first"}" ;;
      esac
      ;;
  esac
  printf '%s%s%s\n' "$base" "$query" "$frag"
}

# ---------------------------------------------------------------------------
# kit_ref_shape_check REF [WHERE]
# ---------------------------------------------------------------------------
# Refuse a remote kit ref (one starting git+) whose transport URL, the part
# before '#', has a query string, or whose '#' fragment has any parameter other
# than ref= and dir=, names one of them twice, or gives one a value that is
# empty or holds a character outside [A-Za-z0-9._/-] (the dir= charset the
# fetch enforces). Such a part is where a token would ride, and acq would
# otherwise carry it into its records, cache paths and messages. The message
# names the problem only: never the URL, a parameter name or a value. WHERE
# (for example "--kit" or "ACQ_EXTRA_KITS") says where the ref came from. A
# local path is not checked, since '?' and '#' are ordinary characters in a
# directory name. Returns 1, with the message on stderr, on a refusal.
kit_ref_shape_check() {
  local ref="${1:-}" where="${2:-}" body rest p prefix="kit-translate:"
  case "$ref" in git+*) ;; *) return 0 ;; esac
  [ -z "$where" ] || prefix="acq: ${where}:"
  body="${ref#git+}"
  case "${body%%#*}" in
    *\?*)
      echo "${prefix} remote kit ref refused: its URL has a query string ('?' before the '#')." >&2
      echo "${prefix}   A kit ref takes no query parameters: git+https://HOST/REPO.git#ref=<commit>&dir=<path>" >&2
      return 1
      ;;
  esac
  # No fragment at all is reported by the fetch as a malformed ref.
  case "$body" in *'#'*) ;; *) return 0 ;; esac
  rest="${body#*#}"
  local seen_ref=0 seen_dir=0 problem="" val
  while :; do
    p="${rest%%&*}"
    case "$p" in
      ref=*)
        [ "$seen_ref" -eq 0 ] || problem="repeats ref= or dir="
        seen_ref=1; val="${p#ref=}"
        ;;
      dir=*)
        [ "$seen_dir" -eq 0 ] || problem="repeats ref= or dir="
        seen_dir=1; val="${p#dir=}"
        ;;
      *) problem="has a parameter other than ref= and dir=" ;;
    esac
    # A value may hold only the safe ref/dir characters (no '?', ';', '#',
    # space or the like, behind which a token could ride).
    if [ -z "$problem" ]; then
      case "$val" in
        "" | *[!A-Za-z0-9._/-]*) problem="has a ref= or dir= value that is empty or holds a character outside [A-Za-z0-9._/-]" ;;
      esac
    fi
    if [ -n "$problem" ]; then
      echo "${prefix} remote kit ref refused: its '#' fragment ${problem}." >&2
      echo "${prefix}   A kit ref names each once: git+https://HOST/REPO.git#ref=<commit>&dir=<path>" >&2
      return 1
    fi
    [ "$rest" != "$p" ] || break
    rest="${rest#*&}"
  done
  return 0
}

# ---------------------------------------------------------------------------
# kit_translate_fetch KITREF DESTDIR
# ---------------------------------------------------------------------------
# Materialize a kit's directory locally. KITREF is either:
#   - git+https://HOST/REPO.git#ref=SHA&dir=PATH  (remote, sparse-checked-out)
#   - /absolute/or/relative/local/path            (used verbatim)
# On success prints the local kit directory path to stdout and returns 0.
kit_translate_fetch() {
  local kitref="$1" destdir="$2"

  # Every caller's ref passes the shape check before anything is fetched; the
  # input points (--kit, ACQ_EXTRA_KITS) also run it before recording a ref.
  kit_ref_shape_check "$kitref" || return 1

  case "$kitref" in
    git+http*)
      local url ref dir frag authority
      url="${kitref#git+}"
      frag="${url#*#}"
      url="${url%%#*}"
      authority="${url#*://}"
      authority="${authority%%/*}"
      case "$authority" in
        *@*)
          echo "kit-translate: credential-bearing kit URLs are not allowed" >&2
          return 1
          ;;
      esac
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
        echo "kit-translate: malformed kit ref (need #ref=&dir=)" >&2
        return 1
      fi
      # Defense-in-depth: reject a hostile dir= (path traversal / metachars).
      # `dir` is a repo-relative subpath; it must not escape via `..` or carry
      # anything but a safe path charset. Matches the hardening in kit_spec_files.
      case "$dir" in
        /*|*..*)
          echo "kit-translate: unsafe kit dir (no absolute paths or '..')" >&2
          return 1
          ;;
      esac
      if printf '%s' "$dir" | LC_ALL=C grep -q '[^A-Za-z0-9._/-]'; then
        echo "kit-translate: unsafe kit dir (illegal characters)" >&2
        return 1
      fi
      if [ -n "${_ACQ_KIT_FETCH_ROOT:-}" ] && [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        _kit_fetch_reuse "$kitref" "$destdir" "$url" "$ref" "$dir"
        return $?
      fi
      command -v acq_debug >/dev/null 2>&1 && acq_debug "fetch: remote kit -> $destdir"
      mkdir -p "$destdir"
      # Fetch NON-INTERACTIVELY. We MUST NOT drop into an interactive git
      # credential prompt (which hangs, or fails on GitHub's disabled password
      # auth) just because the user has a global git credential helper or a
      # url.<x>.insteadOf rewrite — `gh auth login` authenticates the gh CLI,
      # not plain git. See docs/KNOWN_FAILURE_MODES.md.
      #
      # Attempt 1 (anonymous) reads no git config file at all and may use only
      # https; attempt 2 (authenticated retry) runs only when it fails, with the
      # user's config (credential helpers, URL rewrites) but still without
      # prompts. See _kit_git_fetch_into.
      local _ferr
      if _ferr=$(_kit_git_fetch_into anon "$destdir" "$url" "$ref" "$dir"); then
        :
      elif _ferr=$(_kit_git_fetch_into user "$destdir" "$url" "$ref" "$dir"); then
        # authed retry (system config) succeeded
        :
      else
        echo "kit-translate: failed to fetch remote kit" >&2
        # The authenticated retry inherits credential helpers and URL rewrites.
        # Their diagnostics can contain credential-bearing URLs, so never replay
        # raw git stderr into terminal or CI logs.
        [ -z "$_ferr" ] || echo "kit-translate:   git fetch failed (details suppressed)" >&2
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
        echo "kit-translate: local kit path not found: $(kit_ref_display "$kitref")" >&2
        return 1
      fi
      # A regular file with more than one hard link may be a file from
      # elsewhere on the same file system that someone who can write to the
      # kit directory linked in, so it is refused. Directories are exempt
      # (find -type f): their link count is naturally above 1. Bash reads a
      # local kit in place, so this is a check before use, not a guarantee: a
      # link made after it runs is not seen (KNOWN_FAILURE_MODES section 55).
      # -H follows the kit path itself when it is a symlink to the kit (as the
      # Python acq resolves it), but no link inside it. A find that cannot
      # read every directory fails closed: an unchecked file is not passed.
      local _linked _rel _find_rc=0
      _linked=$(find -H "$kitref" -type f -links +1 -print 2>/dev/null) || _find_rc=$?
      if [ "$_find_rc" -ne 0 ]; then
        echo "kit-translate: local kit refused: acq could not check every file in it (is a directory unreadable?)." >&2
        echo "kit-translate:   Make the kit readable, or make a plain copy of it (cp -R KIT KIT-copy) and use the copy." >&2
        return 1
      fi
      _linked=$(printf '%s\n' "$_linked" | sed -n 1p)
      if [ -n "$_linked" ]; then
        _rel="${_linked#"${kitref%/}"/}"
        _rel=$(printf '%s' "$_rel" | LC_ALL=C tr '[:cntrl:]' '?')
        echo "kit-translate: local kit refused: ${_rel} has more than one hard link." >&2
        echo "kit-translate:   Make a plain copy of the kit (for example: cp -R KIT KIT-copy) and use the copy." >&2
        return 1
      fi
      printf '%s\n' "$kitref"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# kit_source_resolve KITDIR SOURCE / kit_source_within KITDIR SOURCE
#
# A kit's files[] payload must come from the kit itself. kit_source_resolve
# prints the fully resolved path of KITDIR/SOURCE and succeeds only when that is
# a regular file inside the resolved KITDIR; callers copy from the printed path,
# so what is checked is what is copied. kit_source_within is the status-only
# form. Both fail closed when a path cannot be resolved.
kit_source_resolve() {
  local kitdir="${1:-}" src="${2:-}" root target
  case "$src" in "" | /*) return 1 ;; esac
  case "/$src/" in */../*) return 1 ;; esac
  root=$(_kit_resolve_path "$kitdir") || return 1
  target=$(_kit_resolve_path "$kitdir/$src") || return 1
  case "$target" in
    "$root"/*) [ -f "$target" ] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$target"
}

kit_source_within() {
  kit_source_resolve "$@" >/dev/null
}

# _kit_resolve_path PATH: print PATH with every symlink resolved, or fail.
# The kit root and its sources go through this same function so both sides of a
# containment check use one resolver. It prefers realpath, then readlink -f, and
# otherwise follows links with plain readlink and resolves directories with
# cd -P (older macOS has neither realpath nor readlink -f). CDPATH is ignored.
_kit_resolve_path() {
  local p="${1:-}" out="" link dir base n=0
  [ -n "$p" ] || return 1
  if command -v realpath >/dev/null 2>&1 && out=$(realpath -- "$p" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    link=$(readlink -- "$p") || return 1
    case "$link" in
      /*) p="$link" ;;
      *) p="$(dirname -- "$p")/$link" ;;
    esac
  done
  [ -e "$p" ] || return 1
  if [ -d "$p" ]; then
    (CDPATH='' cd -P -- "$p" 2>/dev/null && pwd -P)
    return
  fi
  dir=$(CDPATH='' cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || return 1
  base=$(basename -- "$p")
  printf '%s/%s\n' "$dir" "$base"
}

# kit_tree_symlinks_within KITDIR TREE: succeed when TREE has no entry whose
# name contains a newline and every symlink under it resolves inside KITDIR.
# Used before a kit's files/ tree is copied verbatim (cp -a keeps links), so a
# link cannot carry host content into a generated kit. Names are read
# NUL-delimited; a newline-bearing name is refused outright.
kit_tree_symlinks_within() {
  local kitdir="${1:-}" tree="${2:-}" root link target bad=0 nl
  [ -d "$tree" ] || return 0
  root=$(_kit_resolve_path "$kitdir") || return 1
  nl='
'
  while IFS= read -r -d '' link; do
    case "$link" in
      *"$nl"*)
        echo "kit-translate: kit payload has a file name containing a newline; refusing it" >&2
        bad=1
        continue
        ;;
    esac
    [ -L "$link" ] || continue
    if ! target=$(_kit_resolve_path "$link"); then
      echo "kit-translate: unresolvable symlink in kit payload: ${link#"$kitdir"/}" >&2
      bad=1
      continue
    fi
    case "$target" in
      "$root" | "$root"/*) ;;
      *) echo "kit-translate: kit payload symlink points outside the kit: ${link#"$kitdir"/}" >&2; bad=1 ;;
    esac
  done < <(find "$tree" -print0 2>/dev/null)
  [ "$bad" -eq 0 ]
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
# protocol/name are empty if unspecified. The host column is emitted VERBATIM —
# EMPTY when the kit did not declare `host:` — because "the kit asked for a
# specific host port" and "the kit left the host port to the backend" are
# different intents and only the consumer can act on the difference. Defaulting
# host to guest here erased that distinction and made every sandbox from one kit
# request the SAME host port, so parallel sandboxes silently collided on msb
# (see ADR-0034). sbx already ignored this column and let sbx choose; an empty
# column is the neutral spelling of that behavior.
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
# tab-separated `guest<TAB>proto<TAB>name<TAB>host` records. The host column stays
# EMPTY when the entry omits `host:` (see kit_spec_published_ports — the absence
# is meaningful and must survive to the consumer). Reads only the top-level block
# (dedent ends it).
_kit_pp_parse_neutral() {
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s); return s }
    function flush(){ if (cur_g != "") printf "%s\t%s\t%s\t%s\n", cur_g, cur_p, cur_n, cur_h; cur_g=""; cur_p=""; cur_n=""; cur_h="" }
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
# tab-separated `guest<TAB>proto<TAB>name<TAB>host` records. The legacy shape uses
# the old `container:` key and has NO `host:` key at all, so the host column is
# always EMPTY here — "unspecified" is the only host intent this shape can
# express, and encoding it as host==guest is what pinned every sandbox from one
# kit to the same host port (see kit_spec_published_ports and ADR-0034). The
# consumer, not the parser, decides what an unspecified host becomes.
_kit_pp_parse_legacy() {
  awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s); return s }
    function flush(){ if (cur_c != "") printf "%s\t%s\t%s\t\n", cur_c, cur_p, cur_n; cur_c=""; cur_p=""; cur_n="" }
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
# The neutral schema carries no volume `mode` (msb has no equivalent; kits
# chmod in a startup step instead — see ADR-0023). files[].mode is different:
# the translator synthesizes its chmod into setup.install itself (#381,
# _kit_sbx_mode_chmod_script).
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
#   path <TAB> mode <TAB> phase <TAB> source <TAB> readonly
# phase is empty if unspecified (default: written before commands run).
# source is empty for inline-content files (not used by the four acq kits).
# readonly is "true" iff the entry declares `readonly: true` — a file whose
# BYTES are trusted CODE acq must execute from a host-authoritative read-only
# mount rather than a guest-writable copy a passwordless-sudo agent could tamper
# (ADR-0035). Empty (treated as false) otherwise, so existing 4-field consumers
# and unflagged files are unaffected.
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
      if (k=="readonly") cur_readonly=v
      if (k=="description") cur_desc=v
    }
    function flush(   ro) {
      if (cur_path != "") {
        # Reject fields that could break out of the shell contexts these values
        # are later interpolated into. A hostile or mistyped kit spec must not
        # smuggle a command via mode, a metacharacter-bearing path, or a bad
        # source path. Drop the whole record on any violation and warn.
        # mode: octal only. path/source: no shell metacharacters or whitespace.
        #
        # The octal test is written longhand — /^[0-7][0-7][0-7][0-7]?$/ — NOT as
        # the interval form /^[0-7]{3,4}$/ ON PURPOSE. mawk (the DEFAULT awk on
        # Debian and Ubuntu, so most hosts that run acq) does not support POSIX
        # interval expressions in regex; gawk does. Under mawk, /^[0-7]{3,4}$/
        # matches NOTHING, so every files[] entry carrying a mode (i.e. every
        # entry in every shipped kit) is dropped here as "invalid mode" and the
        # kit stages no files at all — a silent, host-dependent failure, because
        # the warning goes to stderr and the create path treats kit failures as
        # best-effort. Do NOT "simplify" this back to an interval expression.
        ro = (cur_readonly == "true") ? "true" : ""
        if (cur_mode != "" && cur_mode !~ /^[0-7][0-7][0-7][0-7]?$/) {
          print "kit-translate: skipping file with invalid mode: " cur_mode > "/dev/stderr"
        } else if (cur_phase != "" && cur_phase !~ /^(install|initFiles|startup)$/) {
          # phase is a column of this tab-separated record: an unknown value (a
          # tab in it would shift every later column) drops the entry, as an
          # unknown command phase does in kit_spec_commands. Checked after the
          # mode and before the path, in the same order as the Python acq.
          print "kit-translate: skipping file with unknown phase: " cur_phase > "/dev/stderr"
        } else if (cur_path !~ /^[A-Za-z0-9._\/-]+$/) {
          print "kit-translate: skipping file with unsafe path: " cur_path > "/dev/stderr"
        } else if (cur_source != "" && (cur_source !~ /^[A-Za-z0-9._\/-]+$/ || cur_source ~ /^\// || cur_source ~ /(^|\/)\.\.(\/|$)/)) {
          # A source is relative to the kit directory and stays inside it: no
          # leading slash and no ".." segment (kit_source_within also resolves
          # symlinks at the point of use).
          print "kit-translate: skipping file with unsafe source: " cur_source > "/dev/stderr"
        } else {
          printf "%s\t%s\t%s\t%s\t%s\n", cur_path, cur_mode, cur_phase, cur_source, ro
        }
      }
      cur_path=""; cur_mode=""; cur_phase=""; cur_source=""; cur_readonly=""; cur_desc=""
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
    function indent_of(s,   i){ i=match(s,/[^ ]/); return (i==0? 0 : i-1) }
    /^environment:/     { in_env=1; next }
    /^[A-Za-z]/         { if (in_env) in_env=0 }   # left the top-level block
    in_env {
      # Inside a dropped block scalar: skip its body (anything indented deeper
      # than the offending key, plus blank lines). A line back at key depth is
      # processed normally below. A tab-led line is treated as still inside the
      # body: YAML forbids tabs as indentation, and indent_of() counts only
      # spaces — so a tab-indented body line would otherwise report column 0,
      # end the skip, and leak its colon-bearing lines as bogus entries.
      if (skip_blk) {
        if ($0 ~ /^[[:space:]]*$/) next
        if ($0 ~ /^\t/) next
        if (indent_of($0) > blk_ind) next
        skip_blk=0
      }
      if ($0 ~ /^[[:space:]]*$/) next               # blank line
      if ($0 ~ /^[[:space:]]*#/) next               # comment line
      # A NAME: value entry, one indent level under environment:.
      if ($0 ~ /^[[:space:]]+[^:[:space:]#]+:/) {
        k=$0; sub(/:.*/,"",k); k=trim(k); gsub(/^"|"$/,"",k); gsub(/^'\''|'\''$/,"",k)
        v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); v=trim(v)
        # A block-scalar value (|, >, optional chomp/indent modifiers) is NOT
        # supported: environment values are single-line strings (the msb
        # replay marker and `-e NAME=value` threading are line-oriented).
        # Drop the entry and its block body (skip_blk) with a warning; the
        # check runs before quote stripping, so a QUOTED "|" stays a legal
        # literal value.
        if (v ~ /^[|>][0-9+-]*$/) {
          print "kit-translate: skipping env var with unsupported block scalar value: " k > "/dev/stderr"
          skip_blk=1; blk_ind=indent_of($0)
          next
        }
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
#   files[].mode (home-staged)      -> setup.install[] combined chmod step
#     sbx pins every files/ payload to 0644 at materialization (docker/
#     sbx-releases#499), so declared modes are synthesized into one chmod
#     install command — see _kit_sbx_mode_chmod_script (#381).
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
  # cp -a keeps symlinks, so refuse a payload whose links resolve outside the
  # kit before copying it into the generated kit.
  if [ -d "${kitdir}/files" ]; then
    kit_tree_symlinks_within "$kitdir" "${kitdir}/files" || return 1
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

# Build the combined chmod script for kit-declared file modes (#381). sbx pins
# every kit files/ payload to 0644 at materialization (content-addressed,
# reproducible layers — docker/sbx-releases#499; v0.39 extended the pin to
# local/git kit loads), so a declared `mode:` only takes effect through the
# maintainer-sanctioned workaround: a setup.install chmod that runs after
# files/home/ staging. Emits one `chmod && echo || echo` line per home-staged
# mode-bearing files[] entry, in SPEC ORDER (deterministic output). Non-home
# (workspace-targeted) modes get a translate-time WARNING and no chmod:
# files/workspace/ is written AFTER install commands run, so a chmod there
# would always fail (same sbx#499 thread).
#
# VALIDATION (SI-10, mirroring _kit_vol_validate): mode reaches a generated
# sbx-v2 spec as a root shell command, so it is untrusted input. Only a
# 0-prefixed 4-digit octal string (0[0-7]{3}) is accepted — kit_spec_files
# already drops non-octal modes, and this tighter gate additionally refuses
# 3-digit and setuid/setgid/sticky (4-digit non-0-prefixed) forms; offenders
# are dropped with a stderr warning (`acq kit validate` reports them as
# errors). Paths were charset-validated by kit_spec_files ([A-Za-z0-9._/-]);
# single-quote them anyway.
_kit_sbx_mode_chmod_script() {
  local spec="$1" fline fpath fmode script=""
  while IFS= read -r fline; do
    [ -n "$fline" ] || continue
    fpath=$(printf '%s' "$fline" | cut -f1)
    fmode=$(printf '%s' "$fline" | cut -f2)
    [ -n "$fpath" ] && [ -n "$fmode" ] || continue
    case "$fpath" in
      /home/agent/*) ;;
      *)
        echo "kit-translate: warning: mode ${fmode} on ${fpath} cannot be applied on sbx (only home-staged files can be chmodded in setup.install; files/workspace/ is written after install commands — docker/sbx-releases#499)" >&2
        continue
        ;;
    esac
    case "$fmode" in
      0[0-7][0-7][0-7]) ;;
      *)
        echo "kit-translate: skipping chmod for ${fpath}: mode must be a 0-prefixed octal string like \"0755\" (got: ${fmode})" >&2
        continue
        ;;
    esac
    script="${script:+${script}
}chmod ${fmode} '${fpath}' && echo \"acq kit-modes: ${fmode} ${fpath}\" || echo \"acq kit-modes: FAILED ${fmode} ${fpath}\""
  done <<EOF
$(kit_spec_files "$spec")
EOF
  printf '%s' "$script"
}

# _kit_tmp_dir — where the translator makes its scratch files: acq_tmp_dir
# (userdirs.sh) when it is loaded, else TMPDIR when it is absolute, else /tmp.
# A relative TMPDIR would resolve against the current directory, normally the
# workspace the guest can write.
_kit_tmp_dir() {
  if declare -F acq_tmp_dir >/dev/null 2>&1; then
    acq_tmp_dir
    return
  fi
  case "${TMPDIR:-}" in
    /*) printf '%s\n' "$TMPDIR" ;;
    *) printf '/tmp\n' ;;
  esac
}

# Emit setup.install/setup.startup blocks into an sbx-v2 spec from the neutral
# commands. v2 has no initFiles command phase, so neutral initFiles commands are
# emitted before startup commands under setup.startup.
#
# The synthesized file-mode chmod (#381, _kit_sbx_mode_chmod_script) is emitted
# as ONE combined setup.install entry BEFORE the kit's own install commands, so
# an install command may exec a kit-shipped script. One line per file (no set
# -e) so a missing file doesn't skip the rest, and each line prints what it did
# — sbx install-command failures are NON-fatal at create time (sbx#499), so the
# startup log is the only place a failed chmod surfaces. Nothing is emitted for
# a mode-less kit: its generated spec must stay byte-identical.
_kit_sbx_emit_setup() {
  local spec="$1" out="$2"
  local phases="install initFiles startup"
  local phase have_setup=0 have_install=0 have_startup=0 tmp
  tmp=$(mktemp "$(_kit_tmp_dir)/acq-kit-setup.XXXXXX") || return 1

  local chmod_script
  chmod_script=$(_kit_sbx_mode_chmod_script "$spec")
  if [ -n "$chmod_script" ]; then
    printf 'setup:\n  install:\n' >> "$tmp"
    have_setup=1; have_install=1
    printf '    - command: |\n' >> "$tmp"
    printf '%s\n' "$chmod_script" | while IFS= read -r cl; do
      printf '        %s\n' "$cl" >> "$tmp"
    done
    printf '      user: "0"\n' >> "$tmp"
    printf '      description: %s\n' \
      "$(_kit_yaml_quote 'Apply kit-declared file modes (sbx pins files/ payloads to 0644 — see docker/sbx-releases#499)')" >> "$tmp"
  fi

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
    if [ -n "$src" ] && ! kit_source_within "$kitdir" "$src"; then
      if [ ! -e "${kitdir}/${src}" ] && [ ! -L "${kitdir}/${src}" ]; then
        echo "kit: validate: file source not found: ${src}" >&2
      else
        echo "kit: validate: file source must be a regular file inside the kit directory: ${src}" >&2
      fi
      errs=$((errs + 1))
    fi
  done <<EOF
$(kit_spec_files "$spec")
EOF

  # Raw-spec scan for sources kit_spec_files drops (absolute, "..", or outside
  # its path charset), so `acq kit validate` reports them instead of passing.
  local bad_src
  bad_src=$(awk '
    /^[A-Za-z]/ { in_f = ($0 ~ /^files:/) }
    in_f && /^[[:space:]]+-?[[:space:]]*source:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v)
      gsub(/^["'\'' ]+|["'\'' ]+$/,"",v)
      if (v !~ /^[A-Za-z0-9._\/-]+$/ || v ~ /^\// || v ~ /(^|\/)\.\.(\/|$)/) print v
    }' "$spec")
  if [ -n "$bad_src" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] && { echo "kit: validate: file source must be a path inside the kit directory: '$m'" >&2; errs=$((errs + 1)); }
    done <<EOF
$bad_src
EOF
  fi

  # Raw-spec scan: any `mode:` value that is not a 0-prefixed 4-digit octal
  # string is rejected — it reaches the root `chmod $mode` in the msb adapter
  # AND the synthesized sbx setup.install chmod (#381), so the accepted grammar
  # is the strict intersection both emit safely (no 3-digit shorthand, no
  # setuid/setgid/sticky leading digit).
  local bad_mode
  bad_mode=$(awk '
    /^[[:space:]]+mode:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v)
      gsub(/^["'\'' ]+|["'\'' ]+$/,"",v)
      # Longhand /^0[0-7][0-7][0-7]$/, NOT an interval ({n,m}): mawk
      # (Debian/Ubuntu default awk) has no interval expressions, so an interval
      # form matches NOTHING there. The test is INVERTED (collect modes that
      # FAIL the pattern, to reject the spec), so under mawk EVERY mode would
      # look invalid and the whole spec would be wrongly rejected. See the
      # detailed note in the files[] parser above; do not "simplify" to {n,m}.
      # Stricter than the parser gate on purpose (#381): the leading zero is
      # required and setuid/setgid/sticky forms are rejected — this value
      # reaches a root chmod in the msb adapter AND the synthesized sbx
      # setup.install chmod.
      if (v !~ /^0[0-7][0-7][0-7]$/) print v
    }' "$spec")
  if [ -n "$bad_mode" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] && { echo "kit: validate: file mode must be a 4-digit octal string with a leading zero (e.g. \"0755\"): '$m'" >&2; errs=$((errs + 1)); }
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

  # environment[] values must be single-line scalars (see kit_spec_env for the
  # rationale). kit_spec_env DROPS a block-scalar entry (defense-in-depth), so
  # scan the RAW spec here — otherwise it would be silently dropped rather
  # than reported by `acq kit validate`. Matches a value that is exactly a
  # block indicator (optional modifiers/trailing comment); a QUOTED "|" is a
  # legal literal.
  local blk_env
  blk_env=$(awk '
    /^environment:/ { in_e=1; next }
    /^[A-Za-z]/     { in_e=0 }
    in_e {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /^[[:space:]]+[^:[:space:]#]+:[[:space:]]*[|>][0-9+-]*[[:space:]]*(#.*)?$/) {
        k=$0; sub(/:.*/,"",k)
        sub(/^[[:space:]]+/,"",k); sub(/[[:space:]]+$/,"",k)
        gsub(/^["'\'']|["'\'']$/,"",k)
        print k
      }
    }' "$spec")
  if [ -n "$blk_env" ]; then
    while IFS= read -r en; do
      [ -n "$en" ] && { echo "kit: validate: environment value must be a single-line scalar (block scalars are not supported): '$en'" >&2; errs=$((errs + 1)); }
    done <<EOF
$blk_env
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
  # (ADR-0023, SI-10)
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
