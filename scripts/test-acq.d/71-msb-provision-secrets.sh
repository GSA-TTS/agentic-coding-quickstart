#!/usr/bin/env bash
#
# 71-msb-provision-secrets — bind USAi + GitHub, custom endpoints, secret ls (8m..8m0g)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# 8m. msb provision binds USAi and GitHub via --secret ENV@HOST (with
#     --tls-intercept), and the real secret VALUES never appear in the msb
#     command line.
make_stubs; load_acq
: > "$CALLS"
prov_leaks=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/prov-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  printf 'GH-REAL-VALUE\n'   | acq_secret_store "$(_acq_secret_key github)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  # Avoid a real network kit fetch: resolve built-in kits to local dirs.
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision provbox shell /tmp >/dev/null 2>&1
  # Report whether real values leaked into the recorded msb calls.
  if grep -q 'USAI-REAL-VALUE\|GH-REAL-VALUE' "$CALLS"; then echo LEAK; else echo CLEAN; fi
)
prov_log=$(cat "$CALLS")
assert_contains "msb: provision enables --tls-intercept (needed for substitution)" "$prov_log" "--tls-intercept"
assert_contains "msb: provision binds USAi via --secret" "$prov_log" "--secret USAI_API_KEY@api.gsa.usai.gov"
# GitHub binds to both REST and git-transport hosts so msb can substitute for
# API calls, HTTPS clones, and HTTPS pushes.
assert_contains "msb: provision binds github to API and git hosts" "$prov_log" "--secret $MSB_GITHUB_SECRET_BINDING"
assert_eq "msb: provision never leaks secret values to argv" "CLEAN" "$prov_leaks"
# Workspace is mounted at the SAME absolute path in the guest (sbx-parity), not
# Workspace is mounted at the SAME absolute path in the guest (sbx-parity), not
# remapped under /home/agent (which fails to mount pre-user-create). acq
# canonicalizes the host path first (macOS /tmp -> /private/tmp symlink), so the
# assertion must compare against the canonicalized form, not the literal /tmp.
_prov_ws=$(canonicalize_path /tmp)
assert_contains "msb: workspace mounted at same guest path (sbx-parity)" "$prov_log" "--volume ${_prov_ws}:${_prov_ws}"
assert_not_contains "msb: workspace NOT remapped under /home/agent" "$prov_log" "--volume ${_prov_ws}:/home/agent/workspace"
# Default base image: msb defaults to the sbx agent-template image (which ships
# the `agent` user, sudo, prereqs, and an agent-writable npm prefix), matching
# sbx by construction. The image is the trailing positional on `msb create`.
assert_contains "msb: create uses the sbx agent-template default image" "$prov_log" "msb create --name provbox"
assert_contains "msb: default image is docker/sandbox-templates:shell-docker" "$prov_log" "docker.io/docker/sandbox-templates:shell-docker"
assert_not_contains "msb: default image is NOT plain node:22-bookworm" "$prov_log" "docker.io/library/node:22-bookworm"
cleanup_stubs

# 8m0a. TLS-intercept UPSTREAM CA trust (defense-in-depth). With an explicit
#        ACQ_MSB_UPSTREAM_CA_CERT PEM and interception ON (default), provision
#        emits `--tls-upstream-ca-cert <PEM>` so msb's host-side proxy trusts a
#        corporate root on its upstream leg. Uses an explicit path (portable;
#        avoids the macOS-only keychain auto-export).
make_stubs; load_acq
: > "$CALLS"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root.pem"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/upca-secrets"
  export ACQ_MSB_UPSTREAM_CA_CERT="$STUBDIR/corp-root.pem"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision upcabox shell /tmp >/dev/null 2>&1
)
upca_log=$(cat "$CALLS")
assert_contains "msb: emits --tls-upstream-ca-cert for explicit PEM (interception on)" "$upca_log" "--tls-upstream-ca-cert $STUBDIR/corp-root.pem"
cleanup_stubs

# 8m0b. The upstream CA is emitted ONLY when interception is on. With
#        ACQ_MSB_NO_TLS_INTERCEPT=1 there is no upstream leg to verify, so neither
#        --tls-intercept nor --tls-upstream-ca-cert appears — even with an
#        explicit PEM configured.
make_stubs; load_acq
: > "$CALLS"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root2.pem"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/upca2-secrets"
  export ACQ_MSB_UPSTREAM_CA_CERT="$STUBDIR/corp-root2.pem"
  export ACQ_MSB_NO_TLS_INTERCEPT=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision upca2box shell /tmp >/dev/null 2>&1
)
upca2_log=$(cat "$CALLS")
assert_not_contains "msb: no --tls-intercept when disabled" "$upca2_log" "--tls-intercept"
assert_not_contains "msb: no --tls-upstream-ca-cert when interception disabled" "$upca2_log" "--tls-upstream-ca-cert"
cleanup_stubs

# 8m0c. ACQ_MSB_NO_UPSTREAM_CA=1 suppresses the upstream CA even when a PEM is
#        configured and interception is on (reproduction/testing toggle).
make_stubs; load_acq
: > "$CALLS"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root3.pem"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/upca3-secrets"
  export ACQ_MSB_UPSTREAM_CA_CERT="$STUBDIR/corp-root3.pem"
  export ACQ_MSB_NO_UPSTREAM_CA=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision upca3box shell /tmp >/dev/null 2>&1
)
upca3_log=$(cat "$CALLS")
assert_contains "msb: interception still on under NO_UPSTREAM_CA" "$upca3_log" "--tls-intercept"
assert_not_contains "msb: NO_UPSTREAM_CA suppresses the upstream CA flag" "$upca3_log" "--tls-upstream-ca-cert"
cleanup_stubs


# 8m00. ACQ_MSB_IMAGE override: a user-supplied image is passed through verbatim
#       to `msb create` (plain-OCI overrides remain supported; the agent-user /
#       sudo synthesis handles them). Assert the override, not the default.
make_stubs; load_acq
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/imgover-secrets"
  export ACQ_MSB_IMAGE="docker.io/library/node:22-bookworm"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision imgoverbox shell /tmp >/dev/null 2>&1
)
imgover_log=$(cat "$CALLS")
assert_contains "msb: ACQ_MSB_IMAGE override passed through to create" "$imgover_log" "docker.io/library/node:22-bookworm"
assert_not_contains "msb: override suppresses the default image" "$imgover_log" "docker.io/docker/sandbox-templates:shell-docker"
cleanup_stubs

# 8m0. GENERIC custom endpoint binding: a service stored
#      via `acq secret set SVC --host H --env E` records a non-secret endpoint
#      sidecar; msb provision must then bind it generically via `--secret E@H`,
#      the real value never touching argv — mirroring usai/github which stay
#      bound exactly as before. A service with NO recorded host/env must NOT emit
#      a bogus flag (the old `*)`-arm empty behavior).
make_stubs; load_acq
: > "$CALLS"
gen_leaks=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/gen-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  # A custom endpoint stored via `acq secret set -g SBX --host … --env …`.
  ACQ_SECRET_TEST_VALUE="SBX-REAL-VALUE" acq_secret_set_interactive SBX "" "api.example.com" "API_KEY" >/dev/null 2>&1
  # usai + github so their explicit bindings still fire (regression guard).
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  printf 'GH-REAL-VALUE\n'   | acq_secret_store "$(_acq_secret_key github)"
  # A service stored with NO host/env sidecar (value only) — must NOT be bound.
  printf 'NOMAP-VALUE\n'     | acq_secret_store "$(_acq_secret_key nomap)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision genbox shell /tmp >/dev/null 2>&1
  # No real secret value may appear in the recorded msb calls.
  if grep -q 'SBX-REAL-VALUE\|USAI-REAL-VALUE\|GH-REAL-VALUE\|NOMAP-VALUE' "$CALLS"; then echo LEAK; else echo CLEAN; fi
)
gen_log=$(cat "$CALLS")
assert_contains "msb#226: custom endpoint bound generically (--secret API_KEY@api.example.com)" "$gen_log" "--secret API_KEY@api.example.com"
assert_contains "msb#226: usai still bound as before"   "$gen_log" "--secret USAI_API_KEY@api.gsa.usai.gov"
assert_contains "msb#226: github still bound as before" "$gen_log" "--secret $MSB_GITHUB_SECRET_BINDING"
# A value-only service (no host/env sidecar) must not emit a bogus flag.
assert_not_contains "msb#226: no bogus flag for service without host/env" "$gen_log" "--secret @"
assert_not_contains "msb#226: value-only service 'nomap' not bound" "$gen_log" "nomap"
assert_eq "msb#226: no secret value ever leaks to argv" "CLEAN" "$gen_leaks"
# Progress feedback (issue #287): the real provision path emits plain status
# lines on stderr even under the harness (non-TTY -> no animation, but the
# acq_status phase markers still print). Capture provision stderr and assert a
# couple of the phase markers are present, and that NO animation leaked.
make_stubs; load_acq
: > "$CALLS"
prog_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/prog-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL-VALUE\n' | acq_secret_store "$(_acq_secret_key usai)"
  . "${REPO_ROOT}/acq.backends/msb.sh"
  _acq_msb_fetch_kit() { printf '%s\n' "${STUBDIR}/nokit"; }
  mkdir -p "${STUBDIR}/nokit"
  printf 'schemaVersion: "hybrid/v1"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n' > "${STUBDIR}/nokit/spec.yaml"
  acq_backend_provision progbox opencode /tmp 2>&1 >/dev/null
)
assert_contains     "progress#287: provision announces sandbox creation" "$prog_err" "Creating sandbox"
assert_contains     "progress#287: provision announces the boot wait"     "$prog_err" "Waiting for the sandbox to finish booting"
assert_not_contains "progress#287: provision leaks no spinner frame"      "$prog_err" "⠋"
assert_not_contains "progress#287: provision leaks no carriage return"    "$prog_err" "$(printf '\r')"
cleanup_stubs

# 8m0b. The endpoint sidecar is NON-SECRET (host + env only) and 0600. Setting a
#       custom endpoint must NOT persist the value in the sidecar file.
make_stubs; load_acq
side_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/side-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  ACQ_SECRET_TEST_VALUE="SIDE-SECRET-VALUE" acq_secret_set_interactive SBX "" "api.example.com" "API_KEY" >/dev/null 2>&1
  # Resolve the sidecar back (host<TAB>env) and show it (safe — non-secret).
  printf 'meta=%s\n' "$(acq_secret_meta_resolve SBX | tr '\t' '/')"
  # The sidecar file itself must not contain the secret value.
  metafile="$STUBDIR/side-secrets/meta/acq.SBX"
  if [ -f "$metafile" ] && grep -q 'SIDE-SECRET-VALUE' "$metafile"; then echo VALUE_IN_META; else echo META_CLEAN; fi
  # Perms are 0600.
  stat -c '%a' "$metafile" 2>/dev/null || stat -f '%Lp' "$metafile" 2>/dev/null || echo "?"
)
assert_contains "msb#226: sidecar resolves host/env" "$side_out" "meta=api.example.com/API_KEY"
assert_contains "msb#226: sidecar never stores the secret value" "$side_out" "META_CLEAN"
assert_contains "msb#226: sidecar file is 0600" "$side_out" "600"
cleanup_stubs

# 8m0c. `acq secret set -g SBX --host … --env …` on the msb backend (through the
#       real dispatcher) records the sidecar AND live-binds a running sandbox via
#       `msb modify <box> --secret API_KEY@api.example.com`, value never on argv.
make_stubs; load_acq
printf 'genrunbox\n' > "$STUBDIR/.msb_sandbox_list"
: > "$CALLS"
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/genrun-secrets"
  export ACQ_SECRET_TEST_VALUE="GENRUN-SECRET"
  ACQ_BACKEND=msb "$ACQ" secret set genrunbox SBX --host api.example.com --env API_KEY >/dev/null 2>&1
)
genrun_log=$(cat "$CALLS")
assert_contains "msb#226: custom endpoint live-binds running sandbox" "$genrun_log" "msb modify genrunbox --secret API_KEY@api.example.com"
if grep -q 'GENRUN-SECRET' "$CALLS"; then
  fail "msb#226: custom endpoint value must NOT appear in msb argv" "leaked into $CALLS"
else
  pass "msb#226: custom endpoint value never leaks to msb argv (passed via env)"
fi
cleanup_stubs

# 8m0d. Dotted service/sandbox names cannot make the
#       shared `acq.<sandbox>.<service>` key non-injective. A GLOBAL service
#       literally named "foo.bar" and a SCOPED service "bar" in sandbox "foo"
#       would BOTH map to the key `acq.foo.bar` — colliding in the value store
#       and mis-scoped by meta_list's old "split on the first dot". The store
#       now fails closed on a dotted name (the choke point both stores share),
#       and meta_list anchors scope on the requested sandbox rather than
#       guessing from the first dot. These prove: (a) a dotted name is refused
#       at the store boundary — the public `acq secret set` path cannot reach a
#       collision; (b) meta_list + meta_resolve AGREE on scope; (c) scoped vs
#       global services never collide.
make_stubs
dot_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/dot-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"

  # (a) _acq_secret_key fails closed on a dotted service or sandbox — the single
  # choke point both the value store and the meta sidecar route through.
  if _acq_secret_key 'foo.bar' >/dev/null 2>&1; then printf 'key-dotted-svc=allowed\n'; else printf 'key-dotted-svc=refused\n'; fi
  if _acq_secret_key 'svc' 'my.box' >/dev/null 2>&1; then printf 'key-dotted-sb=allowed\n'; else printf 'key-dotted-sb=refused\n'; fi
  # A normal (dot-free) name still works.
  printf 'key-ok=%s\n' "$(_acq_secret_key 'svc' 'mybox')"

  # (a') The public set path (acq_secret_set_interactive) refuses a dotted
  # service and stores NOTHING (no aliased value, no sidecar).
  ACQ_SECRET_TEST_VALUE='V' acq_secret_set_interactive 'foo.bar' '' 'api.example.com' 'API_KEY' >/dev/null 2>&1 \
    && printf 'set-dotted=stored\n' || printf 'set-dotted=refused\n'
  # meta_store directly also refuses it (defense in depth).
  acq_secret_meta_store 'foo.bar' '' 'api.example.com' 'API_KEY' >/dev/null 2>&1 \
    && printf 'meta-dotted=stored\n' || printf 'meta-dotted=refused\n'

  # (b) + (c): a GLOBAL service "gsvc", a service "svc" scoped to sandbox "foo",
  # and a service "svc" scoped to a DIFFERENT sandbox "otherbox". meta_list for
  # sandbox "foo" must show the global + foo-scoped services and NOT otherbox's;
  # meta_resolve must agree for each listed entry, and the scoped/global "svc"
  # values must NOT collide.
  ACQ_SECRET_TEST_VALUE='GV'  acq_secret_set_interactive 'gsvc' ''         'api.g.com' 'GKEY' >/dev/null 2>&1
  ACQ_SECRET_TEST_VALUE='FV'  acq_secret_set_interactive 'svc'  'foo'      'api.f.com' 'FKEY' >/dev/null 2>&1
  ACQ_SECRET_TEST_VALUE='OV'  acq_secret_set_interactive 'svc'  'otherbox' 'api.o.com' 'OKEY' >/dev/null 2>&1

  printf 'list-foo=[%s]\n'   "$(acq_secret_meta_list foo | sort | tr '\n' ' ')"
  printf 'list-none=[%s]\n'  "$(acq_secret_meta_list    | sort | tr '\n' ' ')"

  # meta_list(foo) lists a service iff meta_resolve(service, foo) finds it: agreement.
  agree=yes
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    acq_secret_meta_resolve "$s" foo >/dev/null 2>&1 || agree=no
  done <<LIST
$(acq_secret_meta_list foo)
LIST
  printf 'list-resolve-agree=%s\n' "$agree"

  # scoped vs global "svc" resolve to their OWN hosts — no collision.
  printf 'resolve-foo-svc=%s\n'    "$(acq_secret_meta_resolve svc foo | cut -f1)"
  printf 'resolve-global-svc=%s\n' "$(acq_secret_meta_resolve svc | cut -f1 || echo NONE)"
  # A global "svc" was never set (only scoped) — meta_resolve svc (no sandbox)
  # must NOT leak foo's or otherbox's scoped sidecar.
  acq_secret_meta_resolve svc >/dev/null 2>&1 && printf 'global-svc-exists=yes\n' || printf 'global-svc-exists=no\n'

  # Value store must NOT collide either: global "foo.bar" was refused, so the
  # scoped ("svc"@"foo") and global ("gsvc") values stand alone.
  printf 'val-foo-svc=%s\n' "$(acq_secret_resolve svc foo)"
  printf 'val-gsvc=%s\n'    "$(acq_secret_resolve gsvc)"
)
assert_contains "234: dotted service name refused at key layer"        "$dot_out" "key-dotted-svc=refused"
assert_contains "234: dotted sandbox name refused at key layer"        "$dot_out" "key-dotted-sb=refused"
assert_contains "234: dot-free name still keys as acq.<sandbox>.<svc>" "$dot_out" "key-ok=acq.mybox.svc"
assert_contains "234: public set refuses dotted service (nothing stored)" "$dot_out" "set-dotted=refused"
assert_contains "234: meta_store refuses dotted service"               "$dot_out" "meta-dotted=refused"
assert_contains "234: meta_list(foo) shows global service"             "$dot_out" "gsvc"
assert_contains "234: meta_list(foo) shows foo-scoped service"         "$dot_out" "list-foo=[gsvc svc ]"
assert_contains "234: meta_list(none) shows only global service"       "$dot_out" "list-none=[gsvc ]"
assert_contains "234: meta_list and meta_resolve agree on scope"       "$dot_out" "list-resolve-agree=yes"
assert_contains "234: foo-scoped svc resolves to foo host"             "$dot_out" "resolve-foo-svc=api.f.com"
assert_contains "234: no global svc leaks from a scoped-only service"  "$dot_out" "global-svc-exists=no"
assert_contains "234: value store — foo-scoped svc value intact"       "$dot_out" "val-foo-svc=FV"
assert_contains "234: value store — global gsvc value intact"          "$dot_out" "val-gsvc=GV"
cleanup_stubs

# 8m0e. Backward-compat: a LEGACY dotted-global sidecar written
#       by an OLDER build (e.g. the file `acq.foo.bar`, from before the store
#       rejected dotted names) must never crash meta_list and must never be
#       mis-bound. Under the requested sandbox "mybox" (which does not match the
#       leading "foo" segment) it is simply not listed — the old "split on first
#       dot" would have mis-scoped it as sandbox=foo/service=bar for ANY caller;
#       now it is inert unless a caller explicitly targets that exact prefix.
make_stubs
legacy_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/legacy-secrets"
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  mkdir -p "$ACQ_SECRET_META_DIR"
  # Plant a legacy dotted-global sidecar directly (bypassing the new guard).
  printf 'api.example.com\tAPI_KEY\n' > "$ACQ_SECRET_META_DIR/acq.foo.bar"
  # Also a normal current-build global so we prove listing still works.
  ACQ_SECRET_TEST_VALUE='V' acq_secret_set_interactive 'clean' '' 'api.clean.com' 'CKEY' >/dev/null 2>&1
  # meta_list for an unrelated sandbox: no crash, legacy dotted key not surfaced
  # as a bogus composite, clean global still listed.
  printf 'list-mybox=[%s]\n' "$(acq_secret_meta_list mybox | sort | tr '\n' ' ')"
  printf 'list-none=[%s]\n'  "$(acq_secret_meta_list       | sort | tr '\n' ' ')"
)
assert_contains "234(compat): legacy dotted global not mis-listed for unrelated sandbox" "$legacy_out" "list-mybox=[clean ]"
assert_contains "234(compat): legacy dotted global not mis-listed globally"             "$legacy_out" "list-none=[clean ]"
cleanup_stubs

# 8m0f. `acq secret ls` (msb): lists acq-managed secrets — scope, service, whether
#       a VALUE is present, and the ENV@HOST binding — and NEVER prints a value.
#       Covers a global built-in (usai), a global custom endpoint (its sidecar
#       binding), and a scoped built-in (github). Also checks scope filtering.
make_stubs; load_acq
ls_out=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/ls-secrets"
  export ACQ_SECRET_TEST_VALUE="LS-SECRET-VALUE"
  ACQ_BACKEND=msb "$ACQ" secret set -g usai >/dev/null 2>&1
  ACQ_BACKEND=msb "$ACQ" secret set -g myapi --host api.example.com --env API_KEY >/dev/null 2>&1
  ACQ_BACKEND=msb "$ACQ" secret set lsbox github >/dev/null 2>&1
  echo "=== all ==="
  ACQ_BACKEND=msb "$ACQ" secret ls 2>&1
  echo "=== global ==="
  ACQ_BACKEND=msb "$ACQ" secret ls -g 2>&1
  echo "=== scoped ==="
  ACQ_BACKEND=msb "$ACQ" secret ls lsbox 2>&1
)
assert_contains "secret ls(msb): header present"              "$ls_out" "SCOPE"
assert_contains "secret ls(msb): global usai binding shown"   "$ls_out" "USAI_API_KEY@api.gsa.usai.gov"
assert_contains "secret ls(msb): global custom endpoint shown" "$ls_out" "API_KEY@api.example.com"
assert_contains "secret ls(msb): scoped github row shown"     "$ls_out" "$MSB_GITHUB_SECRET_BINDING"
# The value must NEVER be printed by `ls`.
assert_not_contains "secret ls(msb): never prints a secret value" "$ls_out" "LS-SECRET-VALUE"
# Scope filtering: `-g` excludes the scoped github row; `lsbox` includes only it.
g_only=$(printf '%s\n' "$ls_out" | sed -n '/=== global ===/,/=== scoped ===/p')
assert_not_contains "secret ls -g(msb): excludes scoped github" "$g_only" "$MSB_GITHUB_SECRET_BINDING"
s_only=$(printf '%s\n' "$ls_out" | sed -n '/=== scoped ===/,$p')
assert_contains     "secret ls SANDBOX(msb): includes scoped github" "$s_only" "$MSB_GITHUB_SECRET_BINDING"
assert_not_contains "secret ls SANDBOX(msb): excludes global usai"   "$s_only" "USAI_API_KEY@api.gsa.usai.gov"
cleanup_stubs

# 8m0g. `acq secret ls` with an empty store prints just the header (exit 0, no
#       rows, no crash).
make_stubs; load_acq
empty_ls=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/empty-ls-secrets"
  ACQ_BACKEND=msb "$ACQ" secret ls 2>&1
)
empty_rc=$?
assert_contains "secret ls(msb): empty store still prints header" "$empty_ls" "SCOPE"
assert_eq "secret ls(msb): empty store exits 0" "0" "$empty_rc"
cleanup_stubs

