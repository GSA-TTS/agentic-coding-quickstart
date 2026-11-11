#!/usr/bin/env bats
#
# 40-secret-set.bats — bats port of scripts/test-acq.d/40-secret-set.sh (ADR-0025)
#
# `acq secret set` writes the acq secret store AND feeds the active backend's
# proxy per the real CLI contract (built-in services via `sbx secret set` stdin;
# custom endpoints like usai print the set-custom command, value never on argv).
# Also: scope-aware existence checks, `acq secret has`, and masked entry.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "secret set: no scope errors, calls no backend, stores nothing" {
  run env ACQ_BACKEND=sbx "$ACQ" secret set usai
  assert_output --partial 'scope required'
  refute_regex "$(cat "$CALLS")" 'sbx secret set'
}

@test "secret set: -g github feeds sbx (no deprecated -g flag) and stores it" {
  run bash -c 'printf "ghp_x\n" | ACQ_BACKEND=sbx "$1" secret set -g github' _ "$ACQ"
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sbx secret set github'
  refute_regex "$log" 'sbx secret set -g github'
  assert [ -f "$STUBDIR/secrets/acq.github" ]
}

@test "secret set: sandbox github feeds --sandbox scope and stores scoped" {
  run bash -c 'printf "ghp_x\n" | ACQ_BACKEND=sbx "$1" secret set my-sandbox github' _ "$ACQ"
  assert_regex "$(cat "$CALLS")" 'sbx secret set --sandbox my-sandbox github'
  assert [ -f "$STUBDIR/secrets/acq.my-sandbox.github" ]
}

@test "secret set: -g github already in the global scope stops with an rm hint" {
  printf 'SCOPE      TYPE      NAME     SECRET\n(global)   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'sbx secret rm github'
  refute_regex "$(cat "$CALLS")" 'sbx secret set github'
}

@test "secret set: github under a DIFFERENT scope does not block -g (global feeds)" {
  printf 'SCOPE      TYPE      NAME     SECRET\notherbox   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_regex "$(cat "$CALLS")" 'sbx secret set github'
  refute_output --partial 'sbx secret rm github'
}

@test "secret set: sandbox github not blocked by another sandbox's github" {
  printf 'SCOPE      TYPE      NAME     SECRET\notherbox   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set mybox github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_regex "$(cat "$CALLS")" 'sbx secret set --sandbox mybox github'
}

@test "secret set: the SAME sandbox already having github is a real collision" {
  printf 'SCOPE                     TYPE      NAME     SECRET\nopencode-agentic-coding   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set opencode-agentic-coding github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'sbx secret rm github --sandbox opencode-agentic-coding'
  refute_regex "$(cat "$CALLS")" 'sbx secret set --sandbox opencode-agentic-coding github'
}

@test "secret set: section-aware existence — built-in vs custom tables don't cross" {
  cat > "$STUBDIR/sbx_ls" <<'LS'
SCOPE      TYPE      NAME     SECRET
(global)   service   github   (stored)

CUSTOM SECRETS
SCOPE      TARGETS            ENV            PLACEHOLDER               SECRET
(global)   api.gsa.usai.gov   USAI_API_KEY   sbx-cs-0lrfssn3YnvE8P2j   api-ke***tJ63
LS
  run bash -c 'printf "ghp_x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g github' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'sbx secret rm github'
  run bash -c 'printf "x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g usai' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_output --partial 'already has'
}

@test "secret set: -g usai (custom, piped) stores + prints the command, value never on argv" {
  run bash -c 'printf "SUPERSECRETVALUE123\n" | ACQ_BACKEND=sbx "$1" secret set -g usai' _ "$ACQ"
  assert_output --partial "stored 'usai' in the acq secret store"
  assert_output --partial 'sbx secret set-custom --host api.gsa.usai.gov --env USAI_API_KEY'
  refute_output --partial 'SUPERSECRETVALUE123'
  refute_regex "$(cat "$CALLS")" 'SUPERSECRETVALUE123'
  assert [ -f "$STUBDIR/secrets/acq.usai" ]
}

@test "#384: --host on a built-in routes to set-custom, not the native service" {
  run bash -c 'printf "glpat-x\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab --host gitlab.example.gov --env GITLAB_TOKEN' _ "$ACQ"
  assert_output --partial 'sbx secret set-custom --host gitlab.example.gov --env GITLAB_TOKEN'
  refute_regex "$(cat "$CALLS")" 'sbx secret set gitlab'
  assert [ -f "$STUBDIR/secrets/acq.gitlab" ]
  # The endpoint mapping is persisted as a sidecar so msb (and rm) honor it too.
  assert [ -f "$STUBDIR/secrets/meta/acq.gitlab" ]
}

@test "#384: --host on a built-in without --env is a hard error before storing" {
  run bash -c 'printf "glpat-x\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab --host gitlab.example.gov' _ "$ACQ"
  assert_failure
  assert_output --partial '--env'
  refute_regex "$(cat "$CALLS")" 'sbx secret set gitlab'
  assert [ ! -e "$STUBDIR/secrets/acq.gitlab" ]
}

@test "#384: explicit --host wins over the compiled-in usai mapping" {
  run bash -c 'printf "k\n" | ACQ_BACKEND=sbx "$1" secret set -g usai --host usai.alt.example.gov' _ "$ACQ"
  assert_output --partial 'sbx secret set-custom --host usai.alt.example.gov --env USAI_API_KEY'
  refute_output --partial 'api.gsa.usai.gov'
}

@test "#384: rm -g of a built-in does not crash (bash 3.2) and clears the native entry" {
  mkdir -p "$STUBDIR/secrets" && printf 'x\n' > "$STUBDIR/secrets/acq.azure"
  run env ACQ_BACKEND=sbx "$ACQ" secret rm -g azure
  assert_success
  assert_output --partial "removed 'azure'"
  assert_regex "$(cat "$CALLS")" 'sbx secret rm azure -f'
}

@test "#384: rm -g of a --host-routed built-in also removes the custom placeholder" {
  run bash -c 'printf "glpat-x\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab --host gitlab.example.gov --env GITLAB_TOKEN' _ "$ACQ"
  printf 'SCOPE      TYPE      NAME     SECRET\n\nCUSTOM SECRETS\nSCOPE      TARGETS  ENV     PLACEHOLDER  SECRET\n(global)   gitlab.example.gov  GITLAB_TOKEN  sbx-cs-abc123  ****\n' > "$STUBDIR/sbx_ls"
  run bash -c 'SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret rm -g gitlab' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_success
  assert_regex "$(cat "$CALLS")" 'sbx secret rm --placeholder sbx-cs-abc123'
}

@test "#384 review: re-set with --host stops on a stale NATIVE entry with an rm hint" {
  # A pre-fix run left a native gitlab service entry; the custom route must not
  # proceed past it (it would keep injecting to sbx's gitlab.com endpoint).
  printf 'SCOPE      TYPE      NAME     SECRET\n(global)   service   gitlab   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "glpat-x\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g gitlab --host gitlab.example.gov --env GITLAB_TOKEN' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_failure
  assert_output --partial 'sbx secret rm gitlab'
  refute_output --partial 'set-custom'
}

@test "#384 review: hostless re-set of a built-in clears a stale --host sidecar" {
  run bash -c 'printf "glpat-x\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab --host gitlab.example.gov --env GITLAB_TOKEN' _ "$ACQ"
  assert [ -f "$STUBDIR/secrets/meta/acq.gitlab" ]
  run bash -c 'printf "glpat-y\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab' _ "$ACQ"
  assert_regex "$(cat "$CALLS")" 'sbx secret set gitlab'
  assert [ ! -e "$STUBDIR/secrets/meta/acq.gitlab" ]
}

@test "#384 review: a scoped rm does not act on a GLOBAL sidecar's env" {
  # Global sidecar exists; sandbox 'dev' has an UNRELATED custom secret with the
  # same env. rm dev gitlab must not delete dev's placeholder off the global
  # sidecar's say-so.
  run bash -c 'printf "glpat-x\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab --host gh.agency.gov --env GITLAB_TOKEN' _ "$ACQ"
  printf 'SCOPE      TYPE      NAME     SECRET\n\nCUSTOM SECRETS\nSCOPE      TARGETS  ENV     PLACEHOLDER  SECRET\ndev   other.example.gov  GITLAB_TOKEN  sbx-cs-devx  ****\n' > "$STUBDIR/sbx_ls"
  run bash -c 'SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret rm dev gitlab' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_success
  refute_regex "$(cat "$CALLS")" 'sbx secret rm --placeholder sbx-cs-devx'
}

@test "#384 review: an unsafe --env name is rejected before storing" {
  run bash -c 'printf "glpat-x\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab --host gitlab.example.gov --env GITLAB-TOKEN' _ "$ACQ"
  assert_failure
  assert_output --partial 'env'
  assert [ ! -e "$STUBDIR/secrets/acq.gitlab" ]
}

@test "#384 review: --env alone on a built-in is an error, not a mis-scoped native set" {
  # Without this, the existence pre-check searches the CUSTOM table while the
  # native route runs, so an existing native entry's overwrite prompt would eat
  # the piped secret value.
  run bash -c 'printf "ghp_x\n" | ACQ_BACKEND=sbx "$1" secret set -g github --env GITHUB_TOKEN' _ "$ACQ"
  assert_failure
  assert_output --partial '--host'
  refute_regex "$(cat "$CALLS")" 'sbx secret set github'
}

@test "#384 review: repeated --host flags accumulate instead of last-wins" {
  run bash -c 'printf "glpat-x\n" | ACQ_BACKEND=sbx "$1" secret set -g gitlab --host gitlab.example.gov --host api.gitlab.example.gov --env GITLAB_TOKEN' _ "$ACQ"
  assert_output --partial '--host gitlab.example.gov --host api.gitlab.example.gov'
}

@test "#384 review: no unguarded scope_args expansion in sbx.sh (bash 3.2 pin)" {
  # The empty-array crash only manifests under bash 3.2 + set -u (stock macOS
  # /bin/bash); CI runners execute acq under a newer bash, so pin the guard at
  # the source level like the mawk interval guard in 100-kit-translate.bats.
  # Match only the UNGUARDED form: the safe `${scope_args[@]+"${scope_args[@]}"}`
  # guard contains the same substring but is always preceded by `+`.
  run grep -nE '(^|[^+])"\$\{scope_args\[@\]\}"' "$REPO_ROOT/acq.backends/sbx.sh"
  assert_failure
}

@test "mask: masked entry captures the value, shows a star per char, handles backspace/empty" {
  load_acq
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/secret-store.sh"
    v=$(printf "sk-SECRET\n" | _acq_read_secret_masked 2>"'"$STUBDIR"'/stars")
    printf "V=%s\n" "$v"
    printf "STARS=%s\n" "$(cat "'"$STUBDIR"'/stars")"
    printf "BS=%s\n" "$(printf "ab\177c\n" | _acq_read_secret_masked 2>/dev/null)"
    printf "EMPTY=[%s]\n" "$(printf "\n" | _acq_read_secret_masked 2>/dev/null)"
  '
  assert_line 'V=sk-SECRET'
  assert_line --partial 'STARS=*'
  refute_output --partial 'STARS=sk-SECRET'
  assert_line 'BS=ac'
  assert_line 'EMPTY=[]'
}

@test "secret set: sandbox usai (piped) stores scoped + prints sandbox-scoped command" {
  run bash -c 'printf "k\n" | ACQ_BACKEND=sbx "$1" secret set my-sandbox usai' _ "$ACQ"
  assert_output --partial 'sbx secret set-custom --sandbox my-sandbox --host api.gsa.usai.gov'
  assert [ -f "$STUBDIR/secrets/acq.my-sandbox.usai" ]
}

@test "secret set(msb): usai stored, no sbx set-custom printed, exits 0 on success" {
  run bash -c 'printf "k\n" | ACQ_BACKEND=msb "$1" secret set -g usai' _ "$ACQ"
  assert_output --partial 'acq secret store'
  refute_output --partial 'sbx secret set-custom'
  # set -e regression: a successful set must exit 0 even when no running sandbox
  # was re-fed.
  run bash -c 'printf "k\n" | ACQ_BACKEND=msb "$1" secret set -g usai >/dev/null 2>&1' _ "$ACQ"
  assert_success
}

@test "secret set(msb): scoped usai propagates to matching sbx sandbox" {
  printf 'my-sandbox\n' > "$STUBDIR/.msb_sandbox_list"
  cp "$STUBDIR/.msb_sandbox_list" "$STUBDIR/.msb_running_list"
  printf 'my-sandbox\n' > "$STUBDIR/.sandbox_list"
  printf 'CUSTOM SECRETS\nmy-sandbox api.gsa.usai.gov USAI_API_KEY ph-scoped ****\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$2" ACQ_SECRET_TEST_VALUE="k" ACQ_BACKEND=msb "$1" secret set my-sandbox usai' _ "$ACQ" "$STUBDIR/sbx_ls"
  local log
  log=$(cat "$CALLS")
  assert_success
  assert_regex "$log" 'msb modify my-sandbox --secret USAI_API_KEY@api\.gsa\.usai\.gov'
  assert_regex "$log" 'sbx secret set-custom --sandbox my-sandbox --host api\.gsa\.usai\.gov --env USAI_API_KEY --placeholder ph-scoped'
}

@test "secret set(msb): non-usai sbx propagation is no-op when sbx has no secret" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'legacy-sbx\n' > "$STUBDIR/.sandbox_list"
  run bash -c 'printf "k\n" | ACQ_BACKEND=msb "$1" secret set -g github' _ "$ACQ"
  assert_success
  refute_output --partial "sbx cannot safely overwrite this secret non-interactively"
}

@test "secret set(msb): unsupported sbx propagation fails closed for existing secret" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'legacy-sbx\n' > "$STUBDIR/.sandbox_list"
  printf 'SCOPE      TYPE      NAME     SECRET\n(global)   service   github   (stored)\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$2" ACQ_BACKEND=msb "$1" secret set -g github' _ "$ACQ" "$STUBDIR/sbx_ls"
  assert_failure
  assert_output --partial "sbx cannot safely overwrite this secret non-interactively"
  assert_output --partial "acq --backend sbx secret set -g github"
}

@test "secret set(msb): usai propagation preserves sidecar host" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'legacy-sbx\n' > "$STUBDIR/.sandbox_list"
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY ph-default ****\n(global) usai.alt.example.gov USAI_API_KEY ph-alt ****\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$2" ACQ_SECRET_TEST_VALUE="k" ACQ_BACKEND=msb "$1" secret set -g usai --host usai.alt.example.gov --env USAI_API_KEY' _ "$ACQ" "$STUBDIR/sbx_ls"
  local log
  log=$(cat "$CALLS")
  assert_success
  assert_regex "$log" 'sbx secret set-custom --host usai\.alt\.example\.gov --env USAI_API_KEY --placeholder ph-alt'
  refute_regex "$log" 'sbx secret set-custom --host api\.gsa\.usai\.gov --env USAI_API_KEY --placeholder ph-default'
}

@test "secret propagate(msb): missing store value fails closed" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  cp "$STUBDIR/.msb_sandbox_list" "$STUBDIR/.msb_running_list"
  run env ACQ_PROPAGATING_SECRET=1 ACQ_BACKEND=msb "$ACQ" secret _propagate -g usai
  assert_failure
  assert_output --partial "no value is present in the acq secret store"
}

@test "secret has(msb): store-present -> rc 0; absent -> rc 1; silent both ways" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  run env ACQ_BACKEND=msb "$ACQ" secret has -g usai
  assert_success
  assert_output ''
  run env ACQ_BACKEND=msb "$ACQ" secret has -g nope
  assert_failure
  assert_output ''
}

@test "secret has(sbx): store-present but proxy-absent -> rc 1; proxy-bound -> rc 0" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  run env ACQ_BACKEND=sbx "$ACQ" secret has -g usai
  assert_failure
  seed_sbx_usai_proxy_fixture
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_BACKEND=sbx "$ACQ" secret has -g usai
  assert_success
}

@test "secret has(sbx): the provider key env drives the proxy lookup" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  # usai is no longer special-cased: its KEY_ENV comes from the shipped trust
  # anchor (USAI_API_KEY), and that name is what the proxy table is searched for.
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY ph-kit ****\n' > "$STUBDIR/sbx_ls"
  export SBX_LS_FIXTURE="$STUBDIR/sbx_ls"
  run acq_backend_key_present usai

  assert_success
}

@test "secret has: a missing service name is a usage error (rc 2)" {
  load_acq
  run env ACQ_BACKEND=msb "$ACQ" secret has -g
  assert_equal "$status" "2"
  assert_output --partial 'missing service name'
}

# Two global custom secrets for the USAi env var and host: acq cannot tell which
# placeholder the running sandboxes hold, so every path refuses, names each
# placeholder with its removal command, and removes nothing.
_seed_duplicate_usai() {
  printf 'CUSTOM SECRETS\nSCOPE TARGETS ENV PLACEHOLDER SECRET\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupa ****\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupb ****\n' > "$STUBDIR/sbx_ls"
}

@test "secret set(sbx): -g usai with duplicate global entries is refused before storing" {
  _seed_duplicate_usai
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g usai' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_failure
  assert_output --partial 'sbx holds 2 custom secrets for USAI_API_KEY on api.gsa.usai.gov'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupa -f'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupb -f'
  assert_output --partial 'a running sandbox may hold one of these placeholders'
  assert_output --partial 'nothing was stored'
  refute_regex "$(cat "$CALLS")" 'sbx secret (rm|set)'
  assert [ ! -e "$STUBDIR/secrets/acq.usai" ]
}

@test "secret set(sbx): a same-env entry on another host is not a duplicate" {
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupa ****\n(global) usai.alt.example.gov USAI_API_KEY sbx-cs-alt ****\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g usai' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_failure
  refute_output --partial 'custom secrets for USAI_API_KEY'
  assert_output --partial 'already has'
}

@test "secret set(msb): usai propagation to sbx refuses duplicate global entries" {
  printf 'runningbox\n' > "$STUBDIR/.msb_sandbox_list"
  printf 'legacy-sbx\n' > "$STUBDIR/.sandbox_list"
  _seed_duplicate_usai
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$2" ACQ_SECRET_TEST_VALUE="k" ACQ_BACKEND=msb "$1" secret set -g usai' _ "$ACQ" "$STUBDIR/sbx_ls"
  assert_failure
  assert_output --partial 'sbx-cs-dupa'
  assert_output --partial 'sbx-cs-dupb'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupb -f'
  assert_output --partial 'the sbx sandboxes were not updated'
  # The advice must not be `acq --backend sbx secret set`, which would refuse on
  # the entry that is kept.
  assert_output --partial 'then re-run: acq usai-rotate-api-key to update the entry you keep'
  refute_output --partial 'acq --backend sbx secret set'
  refute_regex "$(cat "$CALLS")" 'sbx secret (rm|set)'
}

@test "secret rm(sbx): duplicate usai entries are refused and nothing is removed" {
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  printf 'CUSTOM SECRETS\n(global) other.example.gov USAI_API_KEY sbx-cs-other ****\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupa ****\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-dupb ****\n' > "$STUBDIR/sbx_ls"
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_BACKEND=sbx "$ACQ" secret rm -g usai
  assert_failure
  assert_output --partial 'sbx holds 2 custom secrets for USAI_API_KEY on api.gsa.usai.gov'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupa -f'
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-dupb -f'
  assert_output --partial 'nothing was removed'
  refute_output --partial 'sbx-cs-other'
  refute_regex "$(cat "$CALLS")" 'sbx secret rm'
  assert [ -f "$STUBDIR/secrets/acq.usai" ]
}

@test "secret rm(sbx): removes only the usai entry on the usai host" {
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  printf 'CUSTOM SECRETS\n(global) other.example.gov USAI_API_KEY sbx-cs-other ****\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-main ****\n' > "$STUBDIR/sbx_ls"
  run env SBX_LS_FIXTURE="$STUBDIR/sbx_ls" ACQ_BACKEND=sbx "$ACQ" secret rm -g usai
  assert_success
  assert_regex "$(cat "$CALLS")" 'sbx secret rm --placeholder sbx-cs-main -f'
  refute_regex "$(cat "$CALLS")" 'sbx-cs-other'
  assert [ ! -e "$STUBDIR/secrets/acq.usai" ]
}

@test "secret rm(sbx): a failed sbx listing preserves the credential and sidecar" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  acq_secret_meta_store usai "" api.gsa.usai.gov USAI_API_KEY
  local meta
  meta=$(cat "$ACQ_SECRET_META_DIR/acq.usai")
  sbx() { if [ "${1:-} ${2:-}" = "secret ls" ]; then return 1; fi; command sbx "$@"; }
  run acq_backend_secret_rm -g usai
  assert_failure
  assert_output --partial "sbx's secret list could not be read; nothing was removed"
  assert_equal "$(cat "$STUBDIR/secrets/acq.usai")" k
  assert_equal "$(cat "$ACQ_SECRET_META_DIR/acq.usai")" "$meta"
  refute_regex "$(cat "$CALLS")" 'sbx secret rm'

}

@test "secret set(sbx): the existing-entry hint names the real placeholder" {
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-real1 ****\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g usai' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_failure
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-real1 -f'
  refute_output --partial '<placeholder'
}

@test "secret set(sbx): a placeholder with unexpected characters is never printed as a command" {
  printf 'CUSTOM SECRETS\n(global) api.gsa.usai.gov USAI_API_KEY sbx-cs-ok1 ****\n(global) api.gsa.usai.gov USAI_API_KEY $(touch;x) ****\n' > "$STUBDIR/sbx_ls"
  run bash -c 'printf "k\n" | SBX_LS_FIXTURE="$1" ACQ_BACKEND=sbx "$2" secret set -g usai' _ "$STUBDIR/sbx_ls" "$ACQ"
  assert_failure
  assert_output --partial 'sbx secret rm --placeholder sbx-cs-ok1 -f'
  assert_output --partial 'one placeholder holds unexpected characters'
  refute_output --partial '$(touch'
}

@test "secret rm(sbx): unparseable listings preserve the credential and sidecar" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.usai"
  acq_secret_meta_store usai "" api.gsa.usai.gov USAI_API_KEY
  local listing meta
  meta=$(cat "$ACQ_SECRET_META_DIR/acq.usai")
  for listing in '' 'unexpected output' $'CUSTOM SECRETS\n(global) truncated' $'CUSTOM SECRETS\n(global) host 123 placeholder masked'; do
    printf '%s\n' "$listing" > "$STUBDIR/sbx_ls"
    SBX_LS_FIXTURE="$STUBDIR/sbx_ls" run acq_backend_secret_rm -g usai
    assert_failure
    assert_output --partial 'nothing was removed'
    assert_equal "$(cat "$STUBDIR/secrets/acq.usai")" k
    assert_equal "$(cat "$ACQ_SECRET_META_DIR/acq.usai")" "$meta"
    refute_regex "$(cat "$CALLS")" 'sbx secret rm'
  done
}

@test "secret rm(sbx): a builtin credential survives an unreadable listing" {
  load_acq
  mkdir -p "$STUBDIR/secrets"; printf 'k\n' > "$STUBDIR/secrets/acq.github"
  sbx() { if [ "${1:-} ${2:-}" = "secret ls" ]; then return 1; fi; command sbx "$@"; }
  run acq_backend_secret_rm -g github
  assert_failure
  assert_output --partial 'nothing was removed'
  assert_equal "$(cat "$STUBDIR/secrets/acq.github")" k
  refute_regex "$(cat "$CALLS")" 'sbx secret rm'
}
