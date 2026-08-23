#!/usr/bin/env bash
#
# 35-image-override — backend-neutral --image / ACQ_IMAGE (ADR-0022)
#
# Part of the acq offline unit suite. SOURCED by scripts/test-acq after
# scripts/test-acq-lib.sh; shares the PASS/FAIL counters and harness helpers.
# Do not run directly. See scripts/test-acq-lib.sh for the harness.
#
# shellcheck shell=bash
# shellcheck source=scripts/test-acq-lib.sh

# ===========================================================================
# 3y. Backend-neutral --image / ACQ_IMAGE (ADR-0022)
# ===========================================================================
# A neutral base image knob resolves flag > ACQ_IMAGE env > backend var/default.
# On msb it becomes the trailing `msb create` image positional; on sbx it becomes
# `sbx create --template <ref>`. `--image` is acq-owned: it must NOT survive as a
# raw flag on the backend argv, and must not corrupt the workspace positional.
# Workspace must be a real dir (pre-flight aborts otherwise); use a temp dir.
_imgproj=$(mktemp -d "${TMPDIR:-/tmp}/acq-imgproj.XXXXXX")

# --- msb: ACQ_IMAGE env reaches `msb create` as the image positional ----------
make_stubs
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-env-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_IMAGE="localhost/acq-custom:test" ACQ_BACKEND=msb "$ACQ" \
    create shell "$_imgproj" >/dev/null 2>&1
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): ACQ_IMAGE env reaches msb create positional" "$create_line" "localhost/acq-custom:test"
assert_not_contains "image(msb): default image suppressed by ACQ_IMAGE" "$create_line" "docker.io/docker/sandbox-templates:shell-docker"
assert_not_contains "image(msb): --image not forwarded raw to backend" "$create_line" "--image"
cleanup_stubs

# --- msb: --image FLAG reaches `msb create` (flag path == env path) -----------
make_stubs
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-flag-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_BACKEND=msb "$ACQ" create shell --image localhost/acq-flag:test "$_imgproj" >/dev/null 2>&1
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): --image flag reaches msb create positional" "$create_line" "localhost/acq-flag:test"
assert_not_contains "image(msb): --image flag not left on backend argv" "$create_line" "--image"
assert_contains "image(msb): workspace positional survives --image" "$create_line" "$(canonicalize_path "$_imgproj")"
cleanup_stubs

# --- msb: --image=<ref> equals form is also intercepted -----------------------
make_stubs
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-eq-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_BACKEND=msb "$ACQ" create shell --image=localhost/acq-eq:test "$_imgproj" >/dev/null 2>&1
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): --image=<ref> equals form intercepted" "$create_line" "localhost/acq-eq:test"
assert_not_contains "image(msb): --image= not left raw" "$create_line" "--image=localhost/acq-eq:test"
cleanup_stubs

# --- msb: GLOBAL --image (BEFORE the subcommand) is intercepted ----------------
# `acq --backend msb --image REF create shell …` — the position the live verifier
# uses. The pre-subcommand global parser must consume --image so it never reaches
# the backend CLI (regression: msb rejected a forwarded `--image`).
make_stubs
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-global-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  "$ACQ" --backend msb --image localhost/acq-global:test create shell --name gimg "$_imgproj" >/dev/null 2>&1
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): global --image reaches msb create positional" "$create_line" "localhost/acq-global:test"
assert_not_contains "image(msb): global --image not forwarded raw to backend" "$create_line" "--image"
cleanup_stubs

# --- msb: ACQ_MSB_PULL maps to `msb create --pull <policy>` --------------------
# A locally-loaded image (no registry behind it) needs --pull never so msb uses
# its cache instead of trying to pull the un-pullable ref. acq forwards a valid
# ACQ_MSB_PULL to `msb create --pull`; an invalid value is ignored with a notice.
make_stubs
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-pull-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_MSB_PULL=never ACQ_IMAGE=localhost/acq-cached:test ACQ_BACKEND=msb "$ACQ" \
    create shell --name pimg "$_imgproj" >/dev/null 2>&1
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): ACQ_MSB_PULL=never -> msb create --pull never" "$create_line" "--pull never"
assert_contains "image(msb): cached image still passed with --pull never" "$create_line" "localhost/acq-cached:test"
cleanup_stubs

# Invalid ACQ_MSB_PULL is ignored (no --pull emitted) with a warning.
make_stubs
img_pull_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-pullbad-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_MSB_PULL=bogus ACQ_BACKEND=msb "$ACQ" create shell --name pbad "$_imgproj" 2>&1 >/dev/null
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_not_contains "image(msb): invalid ACQ_MSB_PULL not forwarded" "$create_line" "--pull"
assert_contains "image(msb): invalid ACQ_MSB_PULL warns" "$img_pull_err" "invalid ACQ_MSB_PULL"
cleanup_stubs

# --- msb: GLOBAL --image=<ref> equals form (before subcommand) -----------------
make_stubs
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-globaleq-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  "$ACQ" --backend msb --image=localhost/acq-globaleq:test create shell --name gimgeq "$_imgproj" >/dev/null 2>&1
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): global --image=<ref> equals form intercepted" "$create_line" "localhost/acq-globaleq:test"
assert_not_contains "image(msb): global --image= not left raw" "$create_line" "--image="
cleanup_stubs

# --- msb: PRECEDENCE — explicit ACQ_MSB_IMAGE beats neutral ACQ_IMAGE ----------
# The most-specific backend var wins (ADR-0022), with a one-time notice.
make_stubs
img_prec_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-prec-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_MSB_IMAGE="localhost/backend-specific:test" ACQ_IMAGE="localhost/neutral:test" \
    ACQ_BACKEND=msb "$ACQ" create shell "$_imgproj" 2>&1 >/dev/null
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): ACQ_MSB_IMAGE wins over ACQ_IMAGE" "$create_line" "localhost/backend-specific:test"
assert_not_contains "image(msb): neutral image loses to backend var" "$create_line" "localhost/neutral:test"
assert_contains "image(msb): precedence conflict prints a one-time notice" "$img_prec_err" "most-specific wins"
cleanup_stubs

# --- msb: no image set -> default image is used (regression guard) -------------
make_stubs
(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-msb-def-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_BACKEND=msb "$ACQ" create shell "$_imgproj" >/dev/null 2>&1
)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^msb create')
assert_contains "image(msb): no neutral image -> default shell-docker image" "$create_line" "docker.io/docker/sandbox-templates:shell-docker"
cleanup_stubs

# --- sbx: neutral image injects `sbx create --template <ref>` -----------------
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
ACQ_IMAGE="docker.io/my-org/my-template:v1" ACQ_BACKEND=sbx "$ACQ" \
  create opencode "$_imgproj" >/dev/null 2>&1
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "image(sbx): neutral image injects --template" "$create_line" "--template docker.io/my-org/my-template:v1"
assert_not_contains "image(sbx): --image not forwarded raw" "$create_line" "--image"
cleanup_stubs

# --- sbx: --image flag path also injects --template ---------------------------
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
ACQ_BACKEND=sbx "$ACQ" create opencode --image docker.io/my-org/flag-tpl:v2 "$_imgproj" >/dev/null 2>&1
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "image(sbx): --image flag injects --template" "$create_line" "--template docker.io/my-org/flag-tpl:v2"
cleanup_stubs

# --- sbx: GLOBAL --image (before the subcommand) injects --template -----------
# Mirrors the live verifier's `acq --backend sbx --image REF create shell …`.
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
"$ACQ" --backend sbx --image docker.io/my-org/global-tpl:v3 create opencode "$_imgproj" >/dev/null 2>&1
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "image(sbx): global --image injects --template" "$create_line" "--template docker.io/my-org/global-tpl:v3"
assert_not_contains "image(sbx): global --image not forwarded raw" "$create_line" "--image"
cleanup_stubs

# --- sbx: an explicit user --template is NOT double-injected -------------------
# When the user already passed --template, acq honors it and does NOT add its own
# from --image (the explicit flag wins; a doubled --template is ambiguous).
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
img_dbl_err=$(ACQ_IMAGE="docker.io/my-org/neutral:v1" ACQ_BACKEND=sbx "$ACQ" \
  create opencode --template docker.io/my-org/explicit:v9 "$_imgproj" 2>&1 >/dev/null)
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_contains "image(sbx): explicit --template preserved" "$create_line" "--template docker.io/my-org/explicit:v9"
assert_not_contains "image(sbx): neutral image not injected over explicit --template" "$create_line" "docker.io/my-org/neutral:v1"
assert_contains "image(sbx): conflict notice names the ignored --image" "$img_dbl_err" "ignoring --image"
cleanup_stubs

# --- sbx: no image set -> NO --template injected (regression guard) ------------
make_stubs
printf 'sk-test\n' | ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
seed_sbx_usai_proxy_fixture
ACQ_BACKEND=sbx "$ACQ" create opencode "$_imgproj" >/dev/null 2>&1
log=$(cat "$CALLS")
create_line=$(printf '%s\n' "$log" | grep '^sbx create')
assert_not_contains "image(sbx): no neutral image -> no --template injected" "$create_line" "--template"
cleanup_stubs

# --- re-attach with --image warns (does not silently ignore) ------------------
# --image/ACQ_IMAGE only applies at CREATE (ADR-0022). On an AGENT-form re-attach
# to an EXISTING sandbox, acq must NOT re-provision and must say the flag is
# ignored rather than pretend it re-imaged the running sandbox.
make_stubs; load_acq
printf 'imgreattach\n' > "$STUBDIR/.msb_sandbox_list"
printf 'imgreattach\n' > "$STUBDIR/.msb_running_list"
: > "$CALLS"
img_reattach_err=$(
  export ACQ_SECRET_STORE_DIR="$STUBDIR/img-reattach-secrets"
  export ACQ_MSB_KIT_PASSTHROUGH=1
  export ACQ_UPDATE_CHECK=0
  . "${REPO_ROOT}/acq.backends/secret-store.sh"
  printf 'USAI-REAL\n' | acq_secret_store "$(_acq_secret_key usai)"
  ACQ_IMAGE=localhost/ignored:test ACQ_BACKEND=msb "$ACQ" run shell --name imgreattach "$_imgproj" 2>&1 >/dev/null
)
reattach_log=$(cat "$CALLS")
assert_contains "image(reattach): warns --image ignored on existing sandbox" "$img_reattach_err" "ignored when re-attaching"
assert_not_contains "image(reattach): no msb create on re-attach" "$reattach_log" "msb create"
cleanup_stubs

rm -rf "$_imgproj"

# --- registry-auth hint helpers (ADR-0022 follow-up) --------------------------
# _acq_image_registry_host must extract a registry host only when the leading
# component looks like one (has a dot, a :port, or is localhost); Docker Hub
# short names carry no host. acq_registry_auth_hint must then emit a targeted,
# registry-agnostic remediation for the RIGHT backend surface.
make_stubs; load_acq
# Host parsing.
assert_eq "reg-host: bare Docker Hub name has no host" "" "$(_acq_image_registry_host ubuntu)"
assert_eq "reg-host: tagged Docker Hub name has no host" "" "$(_acq_image_registry_host ubuntu:22.04)"
assert_eq "reg-host: library/ path is still Docker Hub" "" "$(_acq_image_registry_host library/ubuntu)"
assert_eq "reg-host: ghcr.io detected" "ghcr.io" "$(_acq_image_registry_host ghcr.io/org/img:v1)"
assert_eq "reg-host: host:port detected" "myreg.example.com:5000" "$(_acq_image_registry_host myreg.example.com:5000/x/y)"
assert_eq "reg-host: localhost detected" "localhost" "$(_acq_image_registry_host localhost/foo:test)"
# msb hint: names the SPECIFIC private host + the msb login command, plus local import.
msb_hint=$(acq_registry_auth_hint msb ghcr.io/org/img:v1 2>&1)
assert_contains "reg-hint(msb): names msb registry login for the host" "$msb_hint" "msb registry login ghcr.io"
assert_contains "reg-hint(msb): offers local-import fallback" "$msb_hint" "msb image load"
# msb hint for a LOCAL image: no bogus 'login localhost', just the import path.
msb_local_hint=$(acq_registry_auth_hint msb localhost/foo:test 2>&1)
assert_not_contains "reg-hint(msb): no login hint for localhost" "$msb_local_hint" "registry login"
assert_contains "reg-hint(msb): local image still gets import path" "$msb_local_hint" "msb image load"
# sbx hint: names the sbx registry-secret command for the host + template load.
sbx_hint=$(acq_registry_auth_hint sbx registry.gitlab.com/g/p:1 2>&1)
assert_contains "reg-hint(sbx): names sbx secret --registry for the host" "$sbx_hint" "sbx secret set --registry registry.gitlab.com"
assert_contains "reg-hint(sbx): offers template load fallback" "$sbx_hint" "sbx template load"
# Docker Hub short name: no host-specific login line (host unknown), on either backend.
hub_hint=$(acq_registry_auth_hint msb ubuntu:22.04 2>&1)
assert_not_contains "reg-hint(msb): no login line for a Docker Hub short name" "$hub_hint" "registry login"
cleanup_stubs

# --- sbx: a failed create with a custom --image surfaces the acq auth hint ----
# End-to-end at the provision layer (like 9q7b): the sbx create fails (modeled as
# a denied pull); acq must add its registry remediation on top of sbx's raw error
# instead of leaving the user with only the bare backend denial. Call
# acq_backend_provision directly so the USAi pre-create gate (a dispatch concern)
# is out of scope. Registry-agnostic (ghcr.io here).
make_stubs; load_acq
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
_imgfail=$(mktemp -d "${TMPDIR:-/tmp}/acq-imgfail.XXXXXX")
sbx_fail_err=$(ACQ_IMAGE=ghcr.io/org/priv:v1 acq_backend_provision imgfailbox shell "$_imgfail" 2>&1 >/dev/null) || true
assert_contains "image(sbx): failed create names the acq auth hint" "$sbx_fail_err" "sbx secret set --registry ghcr.io"
assert_contains "image(sbx): failed create still shows raw backend error" "$sbx_fail_err" "unauthorized"
rm -rf "$_imgfail"
cleanup_stubs


# 3z. `acq run` fails CLOSED on an unresolvable target (issue #253). `run` is
#     create-and-attach for a KNOWN AGENT or a re-attach to an EXISTING sandbox
#     by name. With no positional (e.g. `run --name X -- CMD`) or an unknown
#     first token, it must exit non-zero with an actionable message — never
#     silently no-op an attach (which drops the post-`--` command and creates
#     nothing).
make_stubs
# No agent positional: only a --name flag and a post-`--` command.
noagent_out=$(ACQ_BACKEND=sbx "$ACQ" run --name s2verify -- sh -lc 'echo hi' 2>&1); noagent_rc=$?
noagent_log=$(cat "$CALLS")
assert_eq "run(#253): no agent positional exits non-zero" "2" "$noagent_rc"
assert_contains "run(#253): no-agent message names the problem" "$noagent_out" "no agent or sandbox specified"
assert_contains "run(#253): message shows usage" "$noagent_out" "Usage: acq run <agent|sandbox-name>"
assert_contains "run(#253): message lists known agents" "$noagent_out" "opencode"
assert_contains "run(#253): message points at acq exec" "$noagent_out" "acq exec <name> -- CMD"
# Fail closed = no sandbox created: no `sbx create` was issued.
assert_not_contains "run(#253): no-agent does NOT provision a sandbox" "$noagent_log" "sbx create"
cleanup_stubs

# 3z1. An unknown first token (neither a known agent nor an existing sandbox)
#      also fails closed, naming the offending token.
make_stubs
unk_out=$(ACQ_BACKEND=sbx "$ACQ" run notanagent /some/proj 2>&1); unk_rc=$?
unk_log=$(cat "$CALLS")
assert_eq "run(#253): unknown target exits non-zero" "2" "$unk_rc"
assert_contains "run(#253): unknown-target message names the token" "$unk_out" "'notanagent' is not a known agent"
assert_not_contains "run(#253): unknown target does NOT provision" "$unk_log" "sbx create"
cleanup_stubs

