#!/usr/bin/env bats
#
# 71-msb-provision-secrets.bats — bats port of
# scripts/test-acq.d/71-msb-provision-secrets.sh (ADR-0025)
#
# msb provision binds USAi/GitHub/custom endpoints via --secret ENV@HOST (values
# never on argv), the TLS-intercept upstream-CA handling, the ACQ_MSB_IMAGE
# override, dotted-name collision guards, legacy sidecar compat, and `acq secret
# ls`. Each provision runs in an isolated subshell; assertions read $CALLS.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Run a provision in a subshell: source common (which chains kit-translate,
# secret-store, and progress via ACQ_SCRIPT_DIR) + msb, seed the store, stub the
# kit fetch to a local no-op kit, and provision NAME. PRE is extra shell run
# before provision (store seeding / env). Captures stderr+stdout via `run`.
_provision() { # NAME PRE_SNIPPET
  local name="$1" pre="$2"
  : > "$CALLS"
  run bash -c '
    name="$1"; pre="$2"
    export ACQ_SCRIPT_DIR="'"$REPO_ROOT"'"
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    eval "$pre"
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    mkdir -p "'"$STUBDIR"'/nokit"
    printf "schemaVersion: \"hybrid/v1\"\nkind: mixin\nname: x\ndisplayName: X\ndescription: x\n" > "'"$STUBDIR"'/nokit/spec.yaml"
    _acq_msb_fetch_kit() { printf "%s\n" "'"$STUBDIR"'/nokit"; }
    acq_backend_provision "$name" shell /tmp 2>&1 >/dev/null
  ' _ "$name" "$pre"
}

@test "msb: provision binds USAi + GitHub via --secret with --tls-intercept, no value leak" {
  _provision provbox '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/prov-secrets"
    printf "USAI-REAL-VALUE\n" | acq_secret_store "$(_acq_secret_key usai)"
    printf "GH-REAL-VALUE\n"   | acq_secret_store "$(_acq_secret_key github)"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '--tls-intercept'
  assert_regex "$log" '--secret USAI_API_KEY@api\.gsa\.usai\.gov'
  assert_regex "$log" "--secret $MSB_GITHUB_SECRET_BINDING"
  refute_regex "$log" 'USAI-REAL-VALUE'
  refute_regex "$log" 'GH-REAL-VALUE'
  # Workspace mounted at the same canonical guest path (sbx-parity), default image.
  load_acq
  local ws; ws=$(canonicalize_path /tmp)
  assert_regex "$log" "--volume ${ws}:${ws}"
  refute_regex "$log" "--volume ${ws}:/home/agent/workspace"
  assert_regex "$log" 'msb create --name provbox'
  assert_regex "$log" 'docker\.io/docker/sandbox-templates:shell-docker'
  refute_regex "$log" 'docker\.io/library/node:22-bookworm'
}

@test "msb: an explicit upstream CA PEM is emitted with --tls-upstream-ca-cert (interception on)" {
  printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root.pem"
  _provision upcabox '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/upca-secrets"
    export ACQ_MSB_UPSTREAM_CA_CERT="'"$STUBDIR"'/corp-root.pem"
  '
  assert_regex "$(cat "$CALLS")" "--tls-upstream-ca-cert $STUBDIR/corp-root.pem"
}

@test "msb: no --tls-intercept / upstream-CA when interception is disabled" {
  printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root2.pem"
  _provision upca2box '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/upca2-secrets"
    export ACQ_MSB_UPSTREAM_CA_CERT="'"$STUBDIR"'/corp-root2.pem"
    export ACQ_MSB_NO_TLS_INTERCEPT=1
  '
  local log; log=$(cat "$CALLS")
  refute_regex "$log" '--tls-intercept'
  refute_regex "$log" '--tls-upstream-ca-cert'
}

@test "msb: ACQ_MSB_NO_UPSTREAM_CA suppresses the CA flag but keeps interception" {
  printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUBDIR/corp-root3.pem"
  _provision upca3box '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/upca3-secrets"
    export ACQ_MSB_UPSTREAM_CA_CERT="'"$STUBDIR"'/corp-root3.pem"
    export ACQ_MSB_NO_UPSTREAM_CA=1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '--tls-intercept'
  refute_regex "$log" '--tls-upstream-ca-cert'
}

@test "msb: ACQ_MSB_IMAGE override is passed through, suppressing the default" {
  _provision imgoverbox '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/imgover-secrets"
    export ACQ_MSB_IMAGE="docker.io/library/node:22-bookworm"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'docker\.io/library/node:22-bookworm'
  refute_regex "$log" 'docker\.io/docker/sandbox-templates:shell-docker'
}

@test "msb#226: a custom endpoint binds generically; usai/github still bind; no bogus flag; no leak" {
  _provision genbox '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/gen-secrets"
    ACQ_SECRET_TEST_VALUE="SBX-REAL-VALUE" acq_secret_set_interactive SBX "" "api.example.com" "API_KEY" >/dev/null 2>&1
    printf "USAI-REAL-VALUE\n" | acq_secret_store "$(_acq_secret_key usai)"
    printf "GH-REAL-VALUE\n"   | acq_secret_store "$(_acq_secret_key github)"
    printf "NOMAP-VALUE\n"     | acq_secret_store "$(_acq_secret_key nomap)"
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '--secret API_KEY@api\.example\.com'
  assert_regex "$log" '--secret USAI_API_KEY@api\.gsa\.usai\.gov'
  assert_regex "$log" "--secret $MSB_GITHUB_SECRET_BINDING"
  refute_regex "$log" '--secret @'
  refute_regex "$log" 'nomap'
  refute_regex "$log" 'SBX-REAL-VALUE|USAI-REAL-VALUE|GH-REAL-VALUE|NOMAP-VALUE'
}

@test "#384(msb): a --host sidecar overrides the compiled-in usai binding" {
  _provision altbox '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/alt-secrets"
    ACQ_SECRET_TEST_VALUE="USAI-ALT-VALUE" acq_secret_set_interactive usai "" "usai.alt.example.gov" "USAI_API_KEY" >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '--secret USAI_API_KEY@usai\.alt\.example\.gov'
  refute_regex "$log" '--secret USAI_API_KEY@api\.gsa\.usai\.gov'
}

@test "progress#287: provision emits plain phase markers on stderr, no animation" {
  _provision progbox '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/prog-secrets"
    printf "USAI-REAL-VALUE\n" | acq_secret_store "$(_acq_secret_key usai)"
  '
  # NB: _provision runs `acq_backend_provision NAME shell /tmp`; progress markers
  # print regardless of agent type.
  assert_output --partial 'Creating sandbox'
  assert_output --partial 'Waiting for the sandbox to finish booting'
  refute_output --partial '⠋'
  refute_output --partial "$(printf '\r')"
}

@test "msb#226: the endpoint sidecar is non-secret (host/env only) and 0600" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/side-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    ACQ_SECRET_TEST_VALUE="SIDE-SECRET-VALUE" acq_secret_set_interactive SBX "" "api.example.com" "API_KEY" >/dev/null 2>&1
    printf "meta=%s\n" "$(acq_secret_meta_resolve SBX | tr "\t" "/")"
    metafile="'"$STUBDIR"'/side-secrets/meta/acq.SBX"
    if [ -f "$metafile" ] && grep -q "SIDE-SECRET-VALUE" "$metafile"; then echo VALUE_IN_META; else echo META_CLEAN; fi
    stat -c "%a" "$metafile" 2>/dev/null || stat -f "%Lp" "$metafile" 2>/dev/null || echo "?"
  '
  assert_output --partial 'meta=api.example.com/API_KEY'
  assert_output --partial 'META_CLEAN'
  assert_output --partial '600'
}

@test "msb#226: setting a custom endpoint (msb) live-binds a running sandbox, no value on argv" {
  load_acq
  printf 'genrunbox\n' > "$STUBDIR/.msb_sandbox_list"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/genrun-secrets"
    export ACQ_SECRET_TEST_VALUE="GENRUN-SECRET"
    ACQ_BACKEND=msb "'"$ACQ"'" secret set genrunbox SBX --host api.example.com --env API_KEY >/dev/null 2>&1
  '
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'msb modify genrunbox --secret API_KEY@api\.example\.com'
  refute_regex "$log" 'GENRUN-SECRET'
}

@test "#234: dotted service/sandbox names are refused at the key layer and public set path" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/dot-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    if _acq_secret_key "foo.bar" >/dev/null 2>&1; then printf "key-dotted-svc=allowed\n"; else printf "key-dotted-svc=refused\n"; fi
    if _acq_secret_key "svc" "my.box" >/dev/null 2>&1; then printf "key-dotted-sb=allowed\n"; else printf "key-dotted-sb=refused\n"; fi
    printf "key-ok=%s\n" "$(_acq_secret_key "svc" "mybox")"
    ACQ_SECRET_TEST_VALUE="V" acq_secret_set_interactive "foo.bar" "" "api.example.com" "API_KEY" >/dev/null 2>&1 \
      && printf "set-dotted=stored\n" || printf "set-dotted=refused\n"
    acq_secret_meta_store "foo.bar" "" "api.example.com" "API_KEY" >/dev/null 2>&1 \
      && printf "meta-dotted=stored\n" || printf "meta-dotted=refused\n"
    ACQ_SECRET_TEST_VALUE="GV" acq_secret_set_interactive "gsvc" ""         "api.g.com" "GKEY" >/dev/null 2>&1
    ACQ_SECRET_TEST_VALUE="FV" acq_secret_set_interactive "svc"  "foo"      "api.f.com" "FKEY" >/dev/null 2>&1
    ACQ_SECRET_TEST_VALUE="OV" acq_secret_set_interactive "svc"  "otherbox" "api.o.com" "OKEY" >/dev/null 2>&1
    printf "list-foo=[%s]\n"  "$(acq_secret_meta_list foo | sort | tr "\n" " ")"
    printf "list-none=[%s]\n" "$(acq_secret_meta_list    | sort | tr "\n" " ")"
    agree=yes
    while IFS= read -r s; do [ -n "$s" ] || continue; acq_secret_meta_resolve "$s" foo >/dev/null 2>&1 || agree=no; done <<LIST
$(acq_secret_meta_list foo)
LIST
    printf "list-resolve-agree=%s\n" "$agree"
    printf "resolve-foo-svc=%s\n" "$(acq_secret_meta_resolve svc foo | cut -f1)"
    acq_secret_meta_resolve svc >/dev/null 2>&1 && printf "global-svc-exists=yes\n" || printf "global-svc-exists=no\n"
    printf "val-foo-svc=%s\n" "$(acq_secret_resolve svc foo)"
    printf "val-gsvc=%s\n"    "$(acq_secret_resolve gsvc)"
  '
  assert_line 'key-dotted-svc=refused'
  assert_line 'key-dotted-sb=refused'
  assert_line 'key-ok=acq.mybox.svc'
  assert_line 'set-dotted=refused'
  assert_line 'meta-dotted=refused'
  assert_line 'list-foo=[gsvc svc ]'
  assert_line 'list-none=[gsvc ]'
  assert_line 'list-resolve-agree=yes'
  assert_line 'resolve-foo-svc=api.f.com'
  assert_line 'global-svc-exists=no'
  assert_line 'val-foo-svc=FV'
  assert_line 'val-gsvc=GV'
}

@test "#234(compat): a legacy dotted-global sidecar is inert, not mis-listed" {
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/legacy-secrets"
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    mkdir -p "$ACQ_SECRET_META_DIR"
    printf "api.example.com\tAPI_KEY\n" > "$ACQ_SECRET_META_DIR/acq.foo.bar"
    ACQ_SECRET_TEST_VALUE="V" acq_secret_set_interactive "clean" "" "api.clean.com" "CKEY" >/dev/null 2>&1
    printf "list-mybox=[%s]\n" "$(acq_secret_meta_list mybox | sort | tr "\n" " ")"
    printf "list-none=[%s]\n"  "$(acq_secret_meta_list       | sort | tr "\n" " ")"
  '
  assert_line 'list-mybox=[clean ]'
  assert_line 'list-none=[clean ]'
}

@test "secret ls(msb): lists managed secrets + bindings, never a value, with scope filtering" {
  load_acq
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/ls-secrets"
    export ACQ_SECRET_TEST_VALUE="LS-SECRET-VALUE"
    ACQ_BACKEND=msb "'"$ACQ"'" secret set -g usai >/dev/null 2>&1
    ACQ_BACKEND=msb "'"$ACQ"'" secret set -g myapi --host api.example.com --env API_KEY >/dev/null 2>&1
    ACQ_BACKEND=msb "'"$ACQ"'" secret set lsbox github >/dev/null 2>&1
    echo "=== all ==="
    ACQ_BACKEND=msb "'"$ACQ"'" secret ls 2>&1
    echo "=== global ==="
    ACQ_BACKEND=msb "'"$ACQ"'" secret ls -g 2>&1
    echo "=== scoped ==="
    ACQ_BACKEND=msb "'"$ACQ"'" secret ls lsbox 2>&1
  '
  assert_output --partial 'SCOPE'
  assert_output --partial 'USAI_API_KEY@api.gsa.usai.gov'
  assert_output --partial 'API_KEY@api.example.com'
  assert_output --partial "$MSB_GITHUB_SECRET_BINDING"
  refute_output --partial 'LS-SECRET-VALUE'
  local g_only s_only
  g_only=$(printf '%s\n' "$output" | sed -n '/=== global ===/,/=== scoped ===/p')
  refute [ -n "$(printf '%s' "$g_only" | grep -F "$MSB_GITHUB_SECRET_BINDING")" ]
  s_only=$(printf '%s\n' "$output" | sed -n '/=== scoped ===/,$p')
  assert [ -n "$(printf '%s' "$s_only" | grep -F "$MSB_GITHUB_SECRET_BINDING")" ]
  refute [ -n "$(printf '%s' "$s_only" | grep -F 'USAI_API_KEY@api.gsa.usai.gov')" ]
}

@test "secret ls(msb): an empty store prints just the header (exit 0)" {
  load_acq
  run env ACQ_SECRET_STORE_DIR="$STUBDIR/empty-ls-secrets" ACQ_BACKEND=msb "$ACQ" secret ls
  assert_success
  assert_output --partial 'SCOPE'
}
