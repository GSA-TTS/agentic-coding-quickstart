#!/usr/bin/env bats
#
# 90-sbx-startup-kit.bats — bats port of scripts/test-acq.d/90-sbx-startup-kit.sh
# (ADR-0025)
#
# sbx 0.38 startup-kit refusal handling, stale-probe footprint, and the
# host-authoritative extra-kit record. All offline via the stubbed sbx. Each @test
# plants a purpose-built sbx stub, so the stubs live inline.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# Plant an sbx stub whose `kit add` FAILS with the 0.38 startup-refusal error and
# whose feature-probe reports ABSENT so the heal attempts the add.
_plant_refusal_stub() {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit)
    if [ "${2:-}" = "add" ]; then
      printf 'ERROR: kit "agentic-coding-playbook" declares setup.startup, which the kit-add recreate flow does not yet apply; recreate the sandbox from scratch via `sbx rm` + `sbx create --kit` to use this kit\n' >&2
      exit 1
    fi
    exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
}

# Seed a STALE provenance record (see 85-kit-provenance) for the kit update test.
_seed_stale_provenance() {
  local backend="$1" name="$2" f
  acq_provenance_write "$backend" "$name"
  f=$(_acq_provenance_file "$backend" "$name")
  awk '/^applied_ref=/ { print "applied_ref=oldoldoldoldoldoldoldoldoldoldoldoldoldo"; next } { print }' \
    "$f" > "$f.seed" && mv -f "$f.seed" "$f"
}

# Record all three heal-consulted built-in kits as applied at the current pinned
# refs in the host config store (what create / a successful heal writes).
_record_builtin_kits() {
  acq_host_config_write sbx "$1" builtin-kits "zscaler-ca-certificate ${ZSCALER_KIT}
${USAI_PROVIDER_KIT_NAME} ${USAI_KIT}
agentic-coding-playbook ${PLAYBOOK_KIT}"
}

# Plant an sbx stub that reports EVERY feature probe as present (what a sudo guest
# that touched the probed files would answer) and accepts `kit add`.
_plant_all_present_stub() {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      *"echo ok"*) printf 'ok\n' ;;
      *present*) printf 'present\n' ;;
      *) exit 0 ;;
    esac ;;
  kit) exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
}

@test "heal(sbx 0.38): a startup refusal yields consolidated recreate guidance, status unknown" {
  _plant_refusal_stub
  printf 'refusebox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied refusebox
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  assert_output --partial "acq rm 'refusebox' && acq run"
  refute_output --partial 'Recover with: sbx kit add'
  assert_equal "$(acq_provenance_status sbx refusebox)" "unknown"
}

@test "heal(sbx 0.38): the recreate notice prints exactly once" {
  _plant_refusal_stub
  printf 'oncebox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied oncebox
  local n; n=$(printf '%s\n' "$output" | grep -c 'cannot extend a live sandbox with startup-bearing kits')
  assert_equal "$n" "1"
}

@test "heal(sbx 0.38, set -e): a refusal does not abort the heal at the first kit" {
  _plant_refusal_stub
  printf 'sebox\n' > "$STUBDIR/.sandbox_list"
  # Reproduce the live path: a fresh subshell that sources acq (set -e active),
  # resolves the backend, and runs the forced heal with the refusal stub on PATH.
  run bash -c '
    export CALLS="'"$CALLS"'" STUBDIR="'"$STUBDIR"'" ACQ_FORCE_KIT_REAPPLY=1
    PATH="'"$STUBDIR"':$PATH"
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    acq_resolve_backend sbx >/dev/null 2>&1
    acq_backend_ensure_kits_applied sebox 2>&1
  '
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  assert_output --partial 'missing the Zscaler CA kit'
  assert_output --partial 'missing the provider kit'
  assert_output --partial 'missing the playbook kit'
}

@test "kit update(sbx 0.38): a refusal fails fast with recreate guidance, stays stale" {
  _plant_refusal_stub
  printf 'updbox\n' > "$STUBDIR/.sandbox_list"
  _seed_stale_provenance sbx updbox
  run env ACQ_BACKEND=sbx "$ACQ" kit update updbox --yes
  assert_failure
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  assert_equal "$(acq_provenance_status sbx updbox)" "stale"
}

@test "heal(sbx): a non-refusal kit-add failure surfaces sbx's own stderr" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit) [ "${2:-}" = "add" ] && { printf 'ERROR: some other transient failure\n' >&2; exit 1; }; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'otherbox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied otherbox
  assert_output --partial 'some other transient failure'
  refute_output --partial 'cannot extend a live sandbox'
}

@test "heal(sbx): a reworded 0.38 refusal is still classified as recreate" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  kit)
    if [ "${2:-}" = "add" ]; then
      printf 'Error: this kit declares startup commands; recreate the sandbox to apply it\n' >&2
      exit 1
    fi
    exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'absent\n' ;; *) exit 0 ;; esac ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'rewordbox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied rewordbox
  assert_output --partial 'cannot extend a live sandbox with startup-bearing kits'
  refute_output --partial 'declares startup commands; recreate the sandbox to apply it'
}

@test "heal(sbx): the playbook stale-probe uses the AGENTS.md footprint, not .git" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'present\n' ;; *) exit 0 ;; esac ;;
  kit) exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'probebox\n' > "$STUBDIR/.sandbox_list"
  _record_builtin_kits probebox
  (
    unset EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
    unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    # The probe is a non-authoritative diagnostic: it only runs under ACQ_DEBUG.
    ACQ_DEBUG=1 HOME="$STUBDIR/nohome" XDG_CONFIG_HOME="$STUBDIR/noconfig" \
      acq_backend_ensure_kits_applied probebox >/dev/null 2>&1 || true
  )
  local log; log=$(cat "$CALLS")
  assert_regex "$log" '\.agentic-coding-playbook/AGENTS\.md'
  refute_regex "$log" '\.agentic-coding-playbook/\.git'
  refute_regex "$log" 'sbx kit add probebox'
}

@test "provision(sbx): host global git identity is emitted as a create-time env kit" {
  local home="$STUBDIR/git-home"
  mkdir -p "$home"
  git -c "safe.directory=*" config --file "$home/.gitconfig" user.name "Global User"
  git -c "safe.directory=*" config --file "$home/.gitconfig" user.email global@example.gov

  run bash -c '
    export HOME="'"$home"'" GIT_CONFIG_NOSYSTEM=1
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/kit-translate.sh"
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    _acq_sbx_git_identity_kit
  '
  assert_success
  local kitdir="$output"
  [ -n "$kitdir" ]
  local spec="$kitdir/spec.yaml"
  [ -f "$spec" ]
  assert_regex "$(cat "$spec")" 'kind: mixin'
  assert_regex "$(cat "$spec")" "EMAIL: '?global@example\\.gov'?"
  assert_regex "$(cat "$spec")" 'ACQ_GIT_USER_NAME: Global User'
  assert_regex "$(cat "$spec")" "ACQ_GIT_USER_EMAIL: '?global@example\\.gov'?"
  assert_regex "$(cat "$spec")" 'git config --global user.name'
  refute_regex "$(cat "$spec")" 'GIT_AUTHOR_NAME: Global User'
}

@test "provision(sbx): shared projection boundary generation passes the mount contract" {
  local generation
  generation=$(acq_provider_input_prepare sbx boundarybox)
  assert_regex "$generation" '/generations/generation\.'
  run acq_provider_input_sbx_mount boundarybox "$generation"
  assert_success
  assert_output "${generation}:ro"
}

@test "rc.d(sbx): neutral kit files materialize as home rc snippets" {
  local kit="$STUBDIR/rcd-kit" out="$STUBDIR/rcd-sbx-v2"
  mkdir -p "$kit/files/home/agent/.rc.d"
  cat > "$kit/spec.yaml" <<'SPEC'
schemaVersion: "hybrid/v1"
kind: mixin
name: rc-hook
displayName: RC Hook
description: shell rc hook fixture
files:
  - path: /home/agent/.rc.d/10-team.sh
    mode: "0644"
    source: files/home/agent/.rc.d/10-team.sh
SPEC
  printf 'export TEAM_TOOL=1\n' > "$kit/files/home/agent/.rc.d/10-team.sh"

  run kit_translate_to_sbx "$kit" "$out"
  assert_success
  [ -f "$out/files/home/agent/.rc.d/10-team.sh" ]
  assert_equal "$(cat "$out/files/home/agent/.rc.d/10-team.sh")" "export TEAM_TOOL=1"
  assert_regex "$(cat "$out/spec.yaml")" '/home/agent/.rc.d/10-team.sh'
  assert_regex "$(cat "$out/spec.yaml")" 'chmod 0644'
  refute_regex "$(cat "$out/spec.yaml")" 'direnv allow|USAI_API_KEY|GITHUB_TOKEN'
}

@test "rc.d(sbx): provision installs the ~/.rc.d login bridge (backend parity)" {
  # Parity with msb (ADR-0030): sbx DELIVERS ~/.rc.d files but nothing sources
  # them at login without this create-time bridge. The bridge text is the ONE
  # shared block from common.sh (acq_login_profile_rc_block), so the assertions
  # below (C-collation ordering, bash gate, guards) hold for BOTH backends.
  : > "$CALLS"
  (
    acq_backend_provision rcdbridgebox shell /tmp
  ) >/dev/null 2>&1 || true
  local log; log=$(cat "$CALLS")
  # The bridge is written via a post-create `sbx exec` (not a startup kit).
  assert_regex "$log" 'acq-login-profile-rc'
  # Deterministic lexical order: an LC_ALL=C command ls list, NOT a locale-dependent glob.
  assert_regex "$log" 'LC_ALL=C command ls'
  assert_regex "$log" 'for _acq_rc in'
  assert_regex "$log" 'SC1090'
  assert_regex "$log" 'unset _acq_rc'
  # bash-only ~/.profile gate preserved; zsh uses native startup files in images
  # that support it.
  assert_regex "$log" 'BASH_VERSION'
  refute_regex "$log" 'ZSH_VERSION'
  # The readiness probe must happen before the bridge install, so a freshly
  # created sandbox does not silently miss the hook while exec is still starting.
  assert_regex "$log" 'echo ok.*acq-login-profile-rc'
}

@test "rc.d(sbx): the login bridge does not use a startup-bearing kit (no live-extend refusal)" {
  # The bridge must NOT be delivered via `sbx kit add` of a setup.startup kit —
  # that path is refused on sbx >= 0.38 (see _acq_sbx_kit_add). It runs as a
  # plain `sbx exec`, so provision must never emit a `kit add` for the bridge.
  : > "$CALLS"
  (
    acq_backend_provision rcdnostartupbox shell /tmp
  ) >/dev/null 2>&1 || true
  local log; log=$(cat "$CALLS")
  # The rc-bridge exec line carries the marker; no `sbx kit add` line should.
  local bridgelines; bridgelines=$(printf '%s\n' "$log" | grep 'acq-login-profile-rc' || true)
  [ -n "$bridgelines" ]
  refute_regex "$bridgelines" 'kit add'
}

@test "provision(sbx): ACQ_EXTRA_KITS is recorded in host config at create" {
  : > "$CALLS"
  # Subshell, NOT `bash -c`: acq_backend_provision is a sourced function, which
  # a fresh bash never sees (the pre-#381 suite masked the resulting 127).
  (
    export ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit"
    acq_test_stub_provider_input_boundary
    acq_backend_provision markerbox shell /tmp
  ) >/dev/null 2>&1 || true
  local record; record=$(acq_host_config_read sbx markerbox extra-kits)
  assert_regex "$record" 'some-extra-kit'
  refute_regex "$(cat "$CALLS")" '\.acq-extra-kits'
}

@test "provision(sbx): a CLI --kit ref (ACQ_CLI_KITS) is also recorded at create" {
  : > "$CALLS"
  # Subshell, NOT `bash -c` (see the ACQ_EXTRA_KITS marker test above).
  (
    # shellcheck disable=SC2034  # consumed by the sourced acq_backend_provision
    ACQ_CLI_KITS=("git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=cli-kit-x")
    acq_test_stub_provider_input_boundary
    acq_backend_provision climarkerbox shell /tmp
  ) >/dev/null 2>&1 || true
  assert_regex "$(acq_host_config_read sbx climarkerbox extra-kits)" 'cli-kit-x'
}

@test "provision(sbx): a FAILED create writes no host extra-kit record" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  create) printf 'ERROR: create failed\n' >&2; exit 1 ;;
  exec) printf 'ok\n' ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  : > "$CALLS"
  run bash -c '
    export ACQ_EXTRA_KITS="git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=fail-extra-kit"
    acq_backend_provision failbox shell /tmp >/dev/null 2>&1 || true
  '
  assert_equal "$(acq_host_config_read sbx failbox extra-kits)" ''
}

@test "heal(sbx): a forged guest extra-kit marker cannot suppress healing" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      # A sudo-capable guest can forge this old marker. The host must not query it.
      *acq-extra-kits*) printf '%s\n' "git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit" ;;
      *present*) printf 'present\n' ;;
      *) exit 0 ;;
    esac ;;
  kit) [ "${2:-}" = "add" ] && { printf 'ERROR: declares setup.startup\n' >&2; exit 1; }; exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'forgedbox\n' > "$STUBDIR/.sandbox_list"
  ACQ_EXTRA_KITS='git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit' \
    run acq_backend_ensure_kits_applied forgedbox
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sbx kit add forgedbox'
  refute_regex "$log" '\.acq-extra-kits'
}

@test "heal(sbx): a matching host extra-kit record suppresses re-apply" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in *present*) printf 'present\n' ;; *) exit 0 ;; esac ;;
  kit) [ "${2:-}" = "add" ] && { printf 'unexpected kit apply\n' >&2; exit 1; }; exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  local kit='git+https://github.com/GSA-TTS/agentic-coding-patterns.git#ref=deadbeef&dir=some-extra-kit'
  printf 'hostbox\n' > "$STUBDIR/.sandbox_list"
  acq_host_config_write sbx hostbox extra-kits "$kit"
  _record_builtin_kits hostbox
  ACQ_EXTRA_KITS="$kit" run acq_backend_ensure_kits_applied hostbox
  refute_regex "$(cat "$CALLS")" 'sbx kit add hostbox'
  refute_output --partial 'unexpected kit apply'
}

@test "heal(sbx): guest probes reporting present cannot suppress built-ins when the host record is absent" {
  _plant_all_present_stub
  printf 'nohostrec\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied nohostrec
  assert_output --partial 'missing the Zscaler CA kit'
  assert_output --partial 'missing the provider kit'
  assert_output --partial 'missing the playbook kit'
  local n; n=$(grep -c '^sbx kit add nohostrec ' "$CALLS" || true)
  [ "$n" -ge 3 ]
}

@test "heal(sbx): a stale host built-in record (older ref) re-applies despite present probes" {
  _plant_all_present_stub
  printf 'stalerec\n' > "$STUBDIR/.sandbox_list"
  acq_host_config_write sbx stalerec builtin-kits "zscaler-ca-certificate git+https://example.invalid/old.git#ref=oldoldold&dir=zscaler-ca-certificate
${USAI_PROVIDER_KIT_NAME} ${USAI_KIT}
agentic-coding-playbook ${PLAYBOOK_KIT}"
  run acq_backend_ensure_kits_applied stalerec
  assert_output --partial 'missing the Zscaler CA kit'
  refute_output --partial 'missing the provider kit'
  refute_output --partial 'missing the playbook kit'
  # The stale line is replaced, not duplicated, once the re-apply succeeds.
  assert_equal "$(acq_host_config_read sbx stalerec builtin-kits | grep -c '^zscaler-ca-certificate ')" "1"
  acq_host_config_read sbx stalerec builtin-kits | grep -Fxq -- "zscaler-ca-certificate ${ZSCALER_KIT}"
}

@test "heal(sbx): a partial host record applies only the unrecorded built-in kits" {
  _plant_all_present_stub
  printf 'partialrec\n' > "$STUBDIR/.sandbox_list"
  acq_host_config_write sbx partialrec builtin-kits "zscaler-ca-certificate ${ZSCALER_KIT}"
  run acq_backend_ensure_kits_applied partialrec
  refute_output --partial 'missing the Zscaler CA kit'
  assert_output --partial 'missing the provider kit'
  assert_output --partial 'missing the playbook kit'
}

@test "heal(sbx): a complete host record suppresses re-apply even if the guest probes report absent" {
  _plant_refusal_stub
  printf 'fullrec\n' > "$STUBDIR/.sandbox_list"
  _record_builtin_kits fullrec
  run acq_backend_ensure_kits_applied fullrec
  assert_success
  refute_regex "$(cat "$CALLS")" 'sbx kit add fullrec'
  refute_output --partial 'missing the'
}

@test "heal(sbx): a successful heal records built-ins so the next heal skips them" {
  _plant_all_present_stub
  printf 'recordbox\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied recordbox
  assert_success
  local rec; rec=$(acq_host_config_read sbx recordbox builtin-kits)
  grep -Fxq -- "zscaler-ca-certificate ${ZSCALER_KIT}" <<<"$rec"
  grep -Fxq -- "${USAI_PROVIDER_KIT_NAME} ${USAI_KIT}" <<<"$rec"
  grep -Fxq -- "agentic-coding-playbook ${PLAYBOOK_KIT}" <<<"$rec"
  : > "$CALLS"
  run acq_backend_ensure_kits_applied recordbox
  assert_success
  refute_regex "$(cat "$CALLS")" 'sbx kit add recordbox'
}

@test "heal(sbx): a refused built-in kit add is NOT recorded as applied" {
  _plant_refusal_stub
  printf 'refusedrec\n' > "$STUBDIR/.sandbox_list"
  run acq_backend_ensure_kits_applied refusedrec
  assert_equal "$(acq_host_config_read sbx refusedrec builtin-kits)" ''
}

@test "heal(sbx): ACQ_FORCE_KIT_REAPPLY re-applies built-ins despite a complete host record" {
  _plant_all_present_stub
  printf 'forcerec\n' > "$STUBDIR/.sandbox_list"
  _record_builtin_kits forcerec
  ACQ_FORCE_KIT_REAPPLY=1 run acq_backend_ensure_kits_applied forcerec
  assert_output --partial 'missing the Zscaler CA kit'
  assert_output --partial 'missing the provider kit'
  assert_output --partial 'missing the playbook kit'
}

@test "heal(sbx): the guest probe is not even consulted without ACQ_DEBUG" {
  _plant_all_present_stub
  printf 'quietrec\n' > "$STUBDIR/.sandbox_list"
  _record_builtin_kits quietrec
  : > "$CALLS"
  run acq_backend_ensure_kits_applied quietrec
  refute_regex "$(cat "$CALLS")" 'ca-certificates/zscaler-ca\.crt'
}

@test "heal(sbx): a diagnostic probe reporting absent does not override the host record" {
  _plant_refusal_stub
  printf 'diagrec\n' > "$STUBDIR/.sandbox_list"
  _record_builtin_kits diagrec
  ACQ_DEBUG=1 run acq_backend_ensure_kits_applied diagrec
  assert_output --partial 'diagnostic only'
  refute_regex "$(cat "$CALLS")" 'sbx kit add diagrec'
}

@test "provision(sbx): built-in kits are recorded in host config at create" {
  : > "$CALLS"
  (
    acq_test_stub_provider_input_boundary
    acq_backend_provision builtinseedbox shell /tmp
  ) >/dev/null 2>&1 || true
  local rec; rec=$(acq_host_config_read sbx builtinseedbox builtin-kits)
  grep -Fxq -- "zscaler-ca-certificate ${ZSCALER_KIT}" <<<"$rec"
  grep -Fxq -- "${USAI_PROVIDER_KIT_NAME} ${USAI_KIT}" <<<"$rec"
  grep -Fxq -- "agentic-coding-playbook ${PLAYBOOK_KIT}" <<<"$rec"
}

@test "provision(sbx): the built-in kit record exists before the startup barrier is consulted" {
  : > "$CALLS"
  (
    acq_test_stub_provider_input_boundary
    # The barrier is a guest-forgeable readiness signal. Whatever it reports, the
    # built-in record must already be fixed from host-observed create status.
    _acq_sbx_wait_for_startup_barrier() {
      acq_host_config_read sbx barrierorder builtin-kits > "$STUBDIR/rec-at-barrier"
      return 0
    }
    acq_backend_provision barrierorder shell /tmp
  ) >/dev/null 2>&1 || true
  grep -Fxq -- "zscaler-ca-certificate ${ZSCALER_KIT}" "$STUBDIR/rec-at-barrier"
  grep -Fxq -- "agentic-coding-playbook ${PLAYBOOK_KIT}" "$STUBDIR/rec-at-barrier"
}

@test "provision(sbx): a failed startup barrier leaves no built-in kit record" {
  : > "$CALLS"
  (
    acq_test_stub_provider_input_boundary
    _acq_sbx_wait_for_startup_barrier() { return 1; }
    acq_backend_provision barrierfail shell /tmp
  ) >/dev/null 2>&1 || true
  assert_regex "$(cat "$CALLS")" 'sbx rm --force barrierfail'
  assert_equal "$(acq_host_config_read sbx barrierfail builtin-kits)" ''
}

@test "provision(sbx): an empty provider selection seeds no USAi built-in record" {
  : > "$CALLS"
  (
    acq_test_stub_provider_input_boundary
    # shellcheck disable=SC2034 # acq_usai_provider_selected reads these globals
    ACQ_PROVIDER_KITS=""
    # shellcheck disable=SC2034
    ACQ_PROVIDER_KITS_FROM_ENV=1
    # shellcheck disable=SC2034
    ACQ_PROVIDER_KITS_FROM_CLI=""
    acq_backend_provision noproviderbox shell /tmp
  ) >/dev/null 2>&1 || true
  local rec; rec=$(acq_host_config_read sbx noproviderbox builtin-kits)
  grep -Fxq -- "zscaler-ca-certificate ${ZSCALER_KIT}" <<<"$rec"
  grep -Fxq -- "agentic-coding-playbook ${PLAYBOOK_KIT}" <<<"$rec"
  refute_regex "$rec" "${USAI_PROVIDER_KIT_NAME}"
}

@test "clear-instance-state(sbx): drops stale builtin-kits and extra-kits host keys" {
  acq_host_config_write sbx stalestate extra-kits "git+https://example.invalid/x.git#ref=abc&dir=x"
  _record_builtin_kits stalestate
  assert_regex "$(acq_host_config_read sbx stalestate builtin-kits)" 'zscaler-ca-certificate'
  assert_regex "$(acq_host_config_read sbx stalestate extra-kits)" 'example\.invalid'
  acq_host_config_clear_instance_state sbx stalestate
  assert_equal "$(acq_host_config_read sbx stalestate builtin-kits)" ''
  assert_equal "$(acq_host_config_read sbx stalestate extra-kits)" ''
}

@test "provision(sbx): a FAILED create writes no host built-in record" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  create) printf 'ERROR: create failed\n' >&2; exit 1 ;;
  exec) printf 'ok\n' ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  (
    acq_test_stub_provider_input_boundary
    acq_backend_provision failbuiltinbox shell /tmp
  ) >/dev/null 2>&1 || true
  assert_equal "$(acq_host_config_read sbx failbuiltinbox builtin-kits)" ''
}

@test "agent-kit-heal(sbx): forced refresh includes recorded agent kit" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.38.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      *"echo ok"*) printf 'ok\n' ;;
      *present*) printf 'present\n' ;;
      *) exit 0 ;;
    esac ;;
  kit) exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  printf 'agentrefreshbox\n' > "$STUBDIR/.sandbox_list"
  acq_provenance_write sbx agentrefreshbox opencode
  # Simulate a READY built-in agent kit offline. The real selection gate fetches
  # the pinned patterns bundle; this refresh-path regression test should stay
  # network-free while still proving agent-kit refresh wiring.
  acq_agent_builtin_kit_ready() { [ "$1" = "opencode" ]; }
  _acq_agent_builtin_kit_ref() { printf '%s#ref=%s&dir=%s/opencode\n' "$PATTERNS_KIT_REPO" "$PATTERNS_KIT_REF" "$PATTERNS_KIT_DIR"; }
  ACQ_FORCE_KIT_REAPPLY=1 run acq_backend_ensure_kits_applied agentrefreshbox
  assert_success
  assert_regex "$(cat "$CALLS")" 'acq-kits/opencode'
}

@test "provision(sbx): startup barrier timeout removes the unsafe sandbox" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  create) : >"$STUBDIR/.created"; exit 0 ;;
  exec) exit 1 ;;
  rm) : >"$STUBDIR/.removed"; exit 0 ;;
  settings) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  : >"$CALLS"

  export ACQ_SBX_STARTUP_BARRIER_TIMEOUT=0
  run acq_backend_provision timeoutbox shell /tmp
  assert_failure
  assert_output --partial "startup commands did not finish"
  assert_output --partial "removing 'timeoutbox'"

  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sbx create --name timeoutbox'
  assert_regex "$log" 'sbx rm --force timeoutbox'
  assert [ -f "$STUBDIR/.removed" ]
}

@test "run(sbx): waits for the startup barrier before generic-default opencode attach" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) [ -f "$STUBDIR/.sandbox_list" ] && cat "$STUBDIR/.sandbox_list"; exit 0 ;;
  create) : >"$STUBDIR/.created"; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case " $* " in
    esac
    case "$snippet" in
      *"startup-complete"*) printf 'ready\n' ;;
      *"echo ok"*) printf 'ok\n' ;;
      *'%{http_code}'*) printf '200|0' ;;
      *) exit 0 ;;
    esac ;;
  run) exit 0 ;;
  settings) exit 0 ;;
  secret)
    [ "${2:-}" = "ls" ] && { [ -n "${SBX_LS_FIXTURE:-}" ] && [ -f "$SBX_LS_FIXTURE" ] && cat "$SBX_LS_FIXTURE"; exit 0; }
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  cat >"$STUBDIR/python3" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -c) exit 0 ;;
  */validate_provider_input_contract.py) exit 0 ;;
  *) exec /usr/bin/python3 "$@" ;;
esac
STUB
  chmod +x "$STUBDIR/python3"
  local proj="$STUBDIR/startup-race-proj"; mkdir -p "$proj"
  printf 'sk-test\n' | env ACQ_BACKEND=sbx "$ACQ" secret set -g usai >/dev/null 2>&1 || true
  seed_sbx_usai_proxy_fixture

  run env ACQ_BACKEND=sbx "$ACQ" run opencode "$proj"
  assert_success

  local log create_line barrier_line attach_line
  log=$(cat "$CALLS")
  create_line=$(printf '%s\n' "$log" | grep -n '^sbx create' | cut -d: -f1)
  barrier_line=$(printf '%s\n' "$log" | grep -n 'startup-complete' | cut -d: -f1)
  attach_line=$(printf '%s\n' "$log" | grep -n '^sbx run --name.* shell -- -lc exec.*sh opencode' | cut -d: -f1)

  assert_regex "$log" 'startup-barrier'
  assert [ "$create_line" -lt "$barrier_line" ]
  assert [ "$barrier_line" -lt "$attach_line" ]
}

@test "wait(sbx): startup barrier requires this create's token" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      *startup-complete*)
        case "$snippet" in
          *" = '$STUB_BARRIER_FILE_TOKEN'"*) printf 'ready\n' ;;
          *=*) exit 0 ;;
          *) printf 'ready\n' ;;
        esac ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"

  export STUB_BARRIER_FILE_TOKEN=fresh-token
  run _acq_sbx_wait_for_startup_barrier tokenbox fresh-token
  assert_success

  export ACQ_SBX_STARTUP_BARRIER_TIMEOUT=0
  export STUB_BARRIER_FILE_TOKEN=stale-token
  run _acq_sbx_wait_for_startup_barrier tokenbox fresh-token
  assert_failure
}

@test "run(sbx): waits for successful reattach heal before attach" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) printf 'healattach\n'; exit 0 ;;
  kit) [ "${2:-}" = "add" ] && exit 0; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      *"echo ok"*) printf 'ok\n' ;;
      *present*) printf 'absent\n' ;;
      *) exit 0 ;;
    esac ;;
  run) exit 0 ;;
  settings) exit 0 ;;
  secret) [ "${2:-}" = "ls" ] && exit 0; exit 0 ;;
  ports) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  : >"$CALLS"

  run env ACQ_BACKEND=sbx ACQ_UPDATE_CHECK=0 "$ACQ" run healattach
  assert_success

  local log kit_line wait_line attach_line
  log=$(cat "$CALLS")
  kit_line=$(printf '%s\n' "$log" | grep -n '^sbx kit add healattach' | tail -n1 | cut -d: -f1)
  wait_line=$(printf '%s\n' "$log" | grep -n 'echo ok' | tail -n1 | cut -d: -f1)
  attach_line=$(printf '%s\n' "$log" | grep -n '^sbx run --name healattach' | cut -d: -f1)

  assert [ "$kit_line" -lt "$wait_line" ]
  assert [ "$wait_line" -lt "$attach_line" ]
}

@test "provision(sbx): provider generation mount appears after agent, not among --kit refs" {
  # Regression: before this fix, /path/generation.XXX:ro was placed BEFORE the agent
  # positional in sbx create argv.  sbx resolves pre-agent positionals as kit paths,
  # producing "error: resolve kits: kit path .../generation.<id>:ro does not exist".
  # After the fix the mount appears AFTER the agent and is NOT a --kit value.
  : > "$CALLS"
  (
    acq_test_stub_provider_input_boundary
    acq_backend_provision mountposbox shell /tmp
  ) >/dev/null 2>&1 || true
  local log create_line
  log=$(cat "$CALLS")
  create_line=$(printf '%s\n' "$log" | grep '^sbx create')
  [ -n "$create_line" ]

  # (a) generation:ro must NOT be a --kit value — if it were, sbx tries to resolve
  #     a non-existent kit path.
  local gen_after_kit
  gen_after_kit=$(printf '%s\n' "$create_line" | awk '{
    for (i=1; i<=NF; i++) {
      if ($i == "--kit" && i+1 <= NF && $(i+1) ~ /\/generation\..*:ro/) {
        print "kit-value:" $(i+1); exit
      }
    }
  }')
  [ -z "$gen_after_kit" ]

  # (b) generation:ro must appear AFTER the selected agent token so sbx treats
  #     it as a workspace-style read-only mount, not a kit path. Avoid generic
  #     flag parsing here: SBX has both value-taking and boolean flags.
  local gen_pos agent_pos workspace_pos
  gen_pos=$(printf '%s\n' "$create_line" | awk '{
    for (i=1; i<=NF; i++) { if ($i ~ /\/generation\..*:ro$/) { print i; exit } }
  }')
  agent_pos=$(printf '%s\n' "$create_line" | awk '{
    for (i=1; i<=NF; i++) { if ($i == "shell") { print i; exit } }
  }')
  workspace_pos=$(printf '%s\n' "$create_line" | awk -v workspace="/tmp" '{
    for (i=1; i<=NF; i++) { if ($i == workspace) { print i; exit } }
  }')
  [ -n "$gen_pos" ]
  [ -n "$agent_pos" ]
  [ -n "$workspace_pos" ]
  assert [ "$agent_pos" -lt "$gen_pos" ]
  assert [ "$workspace_pos" -lt "$gen_pos" ]

  # (c) ACQ_PROVIDER_INPUT_ROOT must be in the env flags (no :ro suffix on the guest path).
  assert_regex "$create_line" 'ACQ_PROVIDER_INPUT_ROOT=[^ ]*/generation\.[^ :]*([ ]|$)'

  # (d) The :ro suffix on the generation path must be preserved intact as a single token
  #     (spaces in the path or suffix must not be split by word expansion).
  assert_regex "$create_line" '/generation\.[^ ]*:ro'
}

@test "run(sbx): refuses attach when reattach heal never becomes exec-ready" {
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.39.0 abc123\n' ;;
  ls) printf 'healblocked\n'; exit 0 ;;
  kit) [ "${2:-}" = "add" ] && exit 0; exit 0 ;;
  exec)
    snippet=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && { snippet="$a"; break; }; prev="$a"; done
    case "$snippet" in
      *"echo ok"*) exit 1 ;;
      *present*) printf 'absent\n' ;;
      *) exit 0 ;;
    esac ;;
  run) exit 0 ;;
  settings) exit 0 ;;
  secret) [ "${2:-}" = "ls" ] && exit 0; exit 0 ;;
  ports) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
  : >"$CALLS"

  run env ACQ_BACKEND=sbx ACQ_UPDATE_CHECK=0 ACQ_EXEC_READY_TIMEOUT=0 "$ACQ" run healblocked
  assert_failure
  assert_output --partial "refusing to attach to 'healblocked'"

  local log
  log=$(cat "$CALLS")
  assert grep -Fq 'sbx kit add healblocked ' "$CALLS"
  refute grep -Fxq 'sbx run --name healblocked' "$CALLS"
}
