#!/usr/bin/env bats
#
# 35-image-override.bats — bats port of scripts/test-acq.d/35-image-override.sh
# (ADR-0022 / ADR-0025)
#
# Backend-neutral --image / ACQ_IMAGE resolves flag > ACQ_IMAGE env > backend
# var/default. On msb it becomes the trailing `msb create` image positional; on
# sbx it becomes `sbx create --template <ref>`. --image is acq-owned: it must
# never survive raw on the backend argv or corrupt the workspace positional.
# Also: ACQ_MSB_PULL, precedence, re-attach warning, and registry-auth hints.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  IMGPROJ="$STUBDIR/imgproj"; mkdir -p "$IMGPROJ"
}
teardown() { acq_teardown_stubs; }

load 'helper'

# Provision on msb with a stored USAi key, in an isolated subshell. Extra env
# assignments (KEY=VAL) precede the create argv after a literal `--`.
_msb_create() { # [ENV KEY=VAL...] -- CREATE_ARGS...
  local env_kv=() ; while [ "$1" != "--" ]; do env_kv+=("$1"); shift; done; shift
  run bash -c '
    tag="$1"; shift
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/sec-$tag"
    export ACQ_MSB_KIT_PASSTHROUGH=1
    n=0; while [ "$1" != "--" ]; do export "$1"; n=$((n+1)); shift; done; shift
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL\n" | acq_secret_store "$(_acq_secret_key usai)"
    ACQ_BACKEND=msb "'"$ACQ"'" "$@" 2>&1 >/dev/null
  ' _ "$BATS_TEST_NUMBER" "${env_kv[@]}" -- "$@"
}
_create_line() { printf '%s\n' "$(cat "$CALLS")" | grep "^$1 create"; }

@test "image(msb): ACQ_IMAGE env reaches the msb create positional, default suppressed" {
  _msb_create ACQ_IMAGE=localhost/acq-custom:test -- create shell "$IMGPROJ"
  local line; line=$(_create_line msb)
  assert_regex "$line" 'localhost/acq-custom:test'
  refute_regex "$line" 'docker\.io/docker/sandbox-templates:shell-docker'
  refute_regex "$line" -- '--image'
}

@test "image(msb): --image flag path equals the env path; workspace survives" {
  _msb_create -- create shell --image localhost/acq-flag:test "$IMGPROJ"
  local line; line=$(_create_line msb)
  assert_regex "$line" 'localhost/acq-flag:test'
  refute_regex "$line" -- '--image'
  load_acq
  assert_regex "$line" "$(canonicalize_path "$IMGPROJ")"
}

@test "image(msb): --image=<ref> equals form is intercepted" {
  _msb_create -- create shell --image=localhost/acq-eq:test "$IMGPROJ"
  local line; line=$(_create_line msb)
  assert_regex "$line" 'localhost/acq-eq:test'
  refute_regex "$line" -- '--image=localhost/acq-eq:test'
}

@test "image(msb): a global --image (before the subcommand) is intercepted" {
  _msb_create -- --backend msb --image localhost/acq-global:test create shell --name gimg "$IMGPROJ"
  local line; line=$(_create_line msb)
  assert_regex "$line" 'localhost/acq-global:test'
  refute_regex "$line" -- '--image'
}

@test "image(msb): ACQ_MSB_PULL maps to --pull; invalid is ignored with a warning" {
  _msb_create ACQ_MSB_PULL=never ACQ_IMAGE=localhost/acq-cached:test -- create shell --name pimg "$IMGPROJ"
  local line; line=$(_create_line msb)
  assert_regex "$line" -- '--pull never'
  assert_regex "$line" 'localhost/acq-cached:test'

  : > "$CALLS"
  _msb_create ACQ_MSB_PULL=bogus -- create shell --name pbad "$IMGPROJ"
  assert_output --partial 'invalid ACQ_MSB_PULL'
  refute_regex "$(_create_line msb)" -- '--pull'
}

@test "image(msb): global --image=<ref> equals form is intercepted" {
  _msb_create -- --backend msb --image=localhost/acq-globaleq:test create shell --name gimgeq "$IMGPROJ"
  local line; line=$(_create_line msb)
  assert_regex "$line" 'localhost/acq-globaleq:test'
  refute_regex "$line" -- '--image='
}

@test "image(msb): explicit ACQ_MSB_IMAGE beats neutral ACQ_IMAGE (with notice)" {
  _msb_create ACQ_MSB_IMAGE=localhost/backend-specific:test ACQ_IMAGE=localhost/neutral:test -- create shell "$IMGPROJ"
  local line; line=$(_create_line msb)
  assert_regex "$line" 'localhost/backend-specific:test'
  refute_regex "$line" 'localhost/neutral:test'
  assert_output --partial 'most-specific wins'
}

@test "image(msb): no image set -> default shell-docker image" {
  _msb_create -- create shell "$IMGPROJ"
  assert_regex "$(_create_line msb)" 'docker\.io/docker/sandbox-templates:shell-docker'
}

# sbx image tests: store a global usai key + seed the proxy fixture.
_sbx_create() { # CREATE_ARGS... (with optional leading ENV via `env`)
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture
  run env "$@"
}

@test "image(sbx): neutral image injects --template, not raw --image" {
  _sbx_create ACQ_IMAGE=docker.io/my-org/my-template:v1 ACQ_BACKEND=sbx "$ACQ" create opencode "$IMGPROJ"
  local line; line=$(_create_line sbx)
  assert_regex "$line" -- '--template docker\.io/my-org/my-template:v1'
  refute_regex "$line" -- '--image'
}

@test "image(sbx): --image flag path also injects --template" {
  _sbx_create ACQ_BACKEND=sbx "$ACQ" create opencode --image docker.io/my-org/flag-tpl:v2 "$IMGPROJ"
  assert_regex "$(_create_line sbx)" -- '--template docker\.io/my-org/flag-tpl:v2'
}

@test "image(sbx): a global --image injects --template, not raw" {
  _sbx_create "$ACQ" --backend sbx --image docker.io/my-org/global-tpl:v3 create opencode "$IMGPROJ"
  local line; line=$(_create_line sbx)
  assert_regex "$line" -- '--template docker\.io/my-org/global-tpl:v3'
  refute_regex "$line" -- '--image'
}

@test "image(sbx): an explicit user --template is not double-injected" {
  _sbx_create ACQ_IMAGE=docker.io/my-org/neutral:v1 ACQ_BACKEND=sbx "$ACQ" \
    create opencode --template docker.io/my-org/explicit:v9 "$IMGPROJ"
  local line; line=$(_create_line sbx)
  assert_regex "$line" -- '--template docker\.io/my-org/explicit:v9'
  refute_regex "$line" 'docker\.io/my-org/neutral:v1'
  assert_output --partial 'ignoring --image'
}

@test "image(sbx): no image set -> no --template injected" {
  _sbx_create ACQ_BACKEND=sbx "$ACQ" create opencode "$IMGPROJ"
  refute_regex "$(_create_line sbx)" -- '--template'
}

@test "image(reattach): --image on an existing sandbox warns and does not re-provision" {
  load_acq
  printf 'imgreattach\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'imgreattach\n' > "$STUBDIR/.msb_running_list"
  : > "$CALLS"
  run bash -c '
    export ACQ_SECRET_STORE_DIR="'"$STUBDIR"'/img-reattach-secrets"
    export ACQ_MSB_KIT_PASSTHROUGH=1 ACQ_UPDATE_CHECK=0
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    printf "USAI-REAL\n" | acq_secret_store "$(_acq_secret_key usai)"
    ACQ_IMAGE=localhost/ignored:test ACQ_BACKEND=msb "'"$ACQ"'" run shell --name imgreattach "'"$IMGPROJ"'" 2>&1 >/dev/null
  '
  assert_output --partial 'ignored when re-attaching'
  refute_regex "$(cat "$CALLS")" 'msb create'
}

@test "reg-host: _acq_image_registry_host extracts a host only when present" {
  load_acq
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; _acq_image_registry_host ubuntu'
  assert_output ''
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; _acq_image_registry_host ubuntu:22.04'
  assert_output ''
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; _acq_image_registry_host library/ubuntu'
  assert_output ''
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; _acq_image_registry_host ghcr.io/org/img:v1'
  assert_output 'ghcr.io'
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; _acq_image_registry_host myreg.example.com:5000/x/y'
  assert_output 'myreg.example.com:5000'
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; _acq_image_registry_host localhost/foo:test'
  assert_output 'localhost'
}

@test "reg-hint: acq_registry_auth_hint emits the right per-backend remediation" {
  load_acq
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_registry_auth_hint msb ghcr.io/org/img:v1 2>&1'
  assert_output --partial 'msb registry login ghcr.io'
  assert_output --partial 'msb image load'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_registry_auth_hint msb localhost/foo:test 2>&1'
  refute_output --partial 'registry login'
  assert_output --partial 'msb image load'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_registry_auth_hint sbx registry.gitlab.com/g/p:1 2>&1'
  assert_output --partial 'sbx secret set --registry registry.gitlab.com'
  assert_output --partial 'sbx template load'

  run bash -c '. "'"$REPO_ROOT"'/acq.backends/common.sh"; acq_registry_auth_hint msb ubuntu:22.04 2>&1'
  refute_output --partial 'registry login'
}

@test "image(sbx): a failed create with a custom --image surfaces the acq auth hint" {
  load_acq
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  create) printf 'ERROR: failed to pull image: unauthorized\n' >&2; exit 1 ;;
  exec) printf 'ok\n' ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  : > "$CALLS"
  local imgfail="$STUBDIR/imgfail"; mkdir -p "$imgfail"
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    ACQ_IMAGE=ghcr.io/org/priv:v1 acq_backend_provision imgfailbox shell "'"$imgfail"'" 2>&1 >/dev/null
  '
  assert_output --partial 'sbx secret set --registry ghcr.io'
  assert_output --partial 'unauthorized'
}

@test "run(#253): no agent positional fails closed without provisioning" {
  run env ACQ_BACKEND=sbx "$ACQ" run --name s2verify -- sh -lc 'echo hi'
  assert_equal "$status" "2"
  assert_output --partial 'no agent or sandbox specified'
  assert_output --partial 'Usage: acq run <agent|sandbox-name>'
  assert_output --partial 'opencode'
  assert_output --partial 'acq exec <name> -- CMD'
  refute_regex "$(cat "$CALLS")" 'sbx create'
}

@test "run(#253): an unknown first token fails closed, naming the token" {
  run env ACQ_BACKEND=sbx "$ACQ" run notanagent /some/proj
  assert_equal "$status" "2"
  assert_output --partial "'notanagent' is not a known agent"
  refute_regex "$(cat "$CALLS")" 'sbx create'
}
