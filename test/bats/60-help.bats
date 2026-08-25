#!/usr/bin/env bats
#
# 60-help.bats — bats port of scripts/test-acq.d/60-help.sh (ADR-0025)
#
# acq help / per-verb --help / passthrough, and the secret-verb fail-closed
# policy (set-custom rejected; import writes only the acq store; unknown subverb
# errors). All CLI-driven via `run`, inspecting $CALLS for dispatch shape.
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "help: acq help shows the banner, --backend list, and appends backend help" {
  run env ACQ_BACKEND=sbx "$ACQ" help
  assert_success
  assert_output --partial 'acq — agentic coding quickstart wrapper'
  assert_output --partial '--backend sbx|msb'
  assert_output --partial 'microsandbox (msb)'
  assert_output --partial 'SBX-TOPLEVEL-HELP'
}

@test "help: --help and -h behave like help" {
  run env ACQ_BACKEND=sbx "$ACQ" --help
  assert_output --partial 'acq — agentic coding quickstart wrapper'
  run env ACQ_BACKEND=sbx "$ACQ" -h
  assert_output --partial 'acq — agentic coding quickstart wrapper'
}

@test "help: 'help run' and 'run --help' delegate to the backend's per-subcommand help" {
  run env ACQ_BACKEND=sbx "$ACQ" help run
  assert_output --partial 'SBX-RUN-HELP'
  run env ACQ_BACKEND=sbx "$ACQ" run --help
  assert_output --partial 'SBX-RUN-HELP'
}

@test "help: a bare acq prints usage but is a usage error (exit 2)" {
  run env ACQ_BACKEND=sbx "$ACQ"
  assert_equal "$status" "2"
  assert_output --partial 'acq — agentic coding quickstart wrapper'
}

@test "help: --backend msb surfaces the msb backend's help" {
  run env ACQ_BACKEND=sbx "$ACQ" --backend msb help
  assert_output --partial 'msb'
}

@test "help: a --help after -- passes through to the inner command" {
  run env ACQ_BACKEND=sbx "$ACQ" exec mybox -- mycmd --help
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'mycmd --help'
  refute_regex "$log" 'agentic coding quickstart wrapper'
}

@test "help: acq-owned multi-word verbs print their own usage (secret/kit/backend)" {
  run env ACQ_BACKEND=sbx "$ACQ" secret --help
  assert_success
  assert_output --partial 'acq secret — manage sandbox secrets'
  assert_output --partial 'acq secret import'
  refute_output --partial 'agentic coding quickstart wrapper'

  run env ACQ_BACKEND=sbx "$ACQ" secret set --help
  assert_output --partial 'acq secret — manage sandbox secrets'
  run env ACQ_BACKEND=sbx "$ACQ" secret import --help
  assert_output --partial 'acq secret import'

  run env ACQ_BACKEND=sbx "$ACQ" kit --help
  assert_success
  assert_output --partial 'acq kit — manage neutral hybrid/v1 kits'
  run env ACQ_BACKEND=sbx "$ACQ" kit apply --help
  assert_output --partial 'acq kit — manage neutral hybrid/v1 kits'

  run env ACQ_BACKEND=sbx "$ACQ" backend --help
  assert_success
  assert_output --partial 'acq backend — select the sandbox backend'
  run env ACQ_BACKEND=sbx "$ACQ" backend set --help
  assert_output --partial 'acq backend — select the sandbox backend'
}

@test "help: every acq-owned verb prints its own per-verb usage (not the banner)" {
  local verb sub
  # verb|expected-usage-header
  local cases=(
    'run|acq run — create+attach a sandbox'
    'create|acq create — create a sandbox (detached'
    'ls|acq ls — list sandboxes'
    'stop|acq stop — stop a sandbox'
    'start|acq start — resume a stopped sandbox'
    'restart|acq restart — stop then start a sandbox'
    'rm|acq rm — remove a sandbox'
    'exec|acq exec — run a command inside a sandbox'
    'cp|acq cp — copy files in or out'
    'ports|acq ports — list or publish'
    'github-scope|acq github-scope — scope a GitHub token'
    'usai-rotate-api-key|acq usai-rotate-api-key — rotate'
    'version|acq version — show acq version'
    'doctor|acq doctor — backend health check'
  )
  for c in "${cases[@]}"; do
    verb="${c%%|*}"; sub="${c#*|}"
    run env ACQ_BACKEND=msb "$ACQ" "$verb" --help
    assert_success
    assert_output --partial "$sub"
    refute_output --partial 'Global flags (before the subcommand):'
  done
}

@test "help: backend help is suppressed for acq-only verbs, appended for shared ones" {
  run env ACQ_BACKEND=msb "$ACQ" start --help
  refute_output --partial 'msb start --help'
  refute_output --partial 'MSB-TOPLEVEL-HELP'
  assert_output --partial 'acq run'

  run env ACQ_BACKEND=msb "$ACQ" restart --help
  refute_output --partial 'msb restart --help'

  run env ACQ_BACKEND=sbx "$ACQ" run --help
  assert_output --partial 'SBX-RUN-HELP'
}

@test "secret ls: forwards a single ls token, no doubling, no passthrough notice" {
  run env ACQ_BACKEND=sbx "$ACQ" secret ls -q
  local log; log=$(cat "$CALLS")
  assert_regex "$log" 'sbx secret ls -q'
  refute_regex "$log" 'secret ls ls'
  refute_output --partial 'forwarding to'
}

@test "secret set-custom: fails closed and never forwards to the backend (sbx)" {
  run env ACQ_BACKEND=sbx "$ACQ" secret set-custom -g --host h --env E
  assert_failure
  assert_output --partial 'bypass the acq secret store'
  assert_output --partial 'acq secret set [-g | SANDBOX] SERVICE --host HOST --env ENV'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'sbx secret'
}

@test "secret import --dry-run: detects service, previews last4, writes nothing, no backend" {
  local d="$STUBDIR/import-dry"
  run env GH_TOKEN=ghp_DRY1234 USAI_API_KEY='' GITHUB_TOKEN='' GITLAB_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d" ACQ_BACKEND=sbx "$ACQ" secret import --dry-run
  assert_success
  assert_output --partial "would import 'github' from \$GH_TOKEN"
  assert_output --partial '…1234'
  refute_output --partial 'ghp_DRY1234'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'sbx secret'
  assert [ ! -e "$d/acq.github" ]
}

@test "secret import --all: stores real values off argv, skips existing, --force overwrites, scopes" {
  local d="$STUBDIR/import-all"
  run env USAI_API_KEY=sk-usai-AAAA GITHUB_TOKEN=ghp_BBBB GITLAB_TOKEN='' GH_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d" ACQ_BACKEND=sbx "$ACQ" secret import --all
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'sbx secret'
  assert_equal "$(cat "$d/acq.usai" 2>/dev/null)" 'sk-usai-AAAA'
  assert_equal "$(cat "$d/acq.github" 2>/dev/null)" 'ghp_BBBB'

  # Blank every token var not under test in each step: an ambient GITLAB_TOKEN
  # (etc.) from the developer's shell would import a stray GLOBAL entry, and the
  # scoped --all step below would then skip via the global-fallback exists check.
  run env USAI_API_KEY=sk-usai-CCCC GITHUB_TOKEN=ghp_BBBB GITLAB_TOKEN='' GH_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d" ACQ_BACKEND=sbx "$ACQ" secret import --all
  assert_output --partial 'already stored'
  assert_equal "$(cat "$d/acq.usai" 2>/dev/null)" 'sk-usai-AAAA'

  run env USAI_API_KEY=sk-usai-CCCC GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d" ACQ_BACKEND=sbx "$ACQ" secret import usai --force
  assert_equal "$(cat "$d/acq.usai" 2>/dev/null)" 'sk-usai-CCCC'

  run env GITLAB_TOKEN=glpat-DDDD USAI_API_KEY='' GITHUB_TOKEN='' GH_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d" ACQ_BACKEND=sbx "$ACQ" secret import gitlab mybox --all
  assert [ -e "$d/acq.mybox.gitlab" ]
}

@test "secret import: exits 0 with a clear message when no tokens are found" {
  local d="$STUBDIR/import-none"
  run env USAI_API_KEY='' GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d" ACQ_BACKEND=sbx "$ACQ" secret import --all
  assert_success
  assert_output --partial 'no known service tokens found'
}

@test "secret import: rejects un-round-trippable values (newline/tab), leaks no fragment" {
  local d="$STUBDIR/import-int"
  run env USAI_API_KEY="$(printf 'line1\nSECRET2')" GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d/ml" ACQ_BACKEND=sbx "$ACQ" secret import --all
  assert_success
  assert_output --partial 'contains a newline or tab'
  refute_output --partial 'SECRET2'
  assert [ ! -e "$d/ml/acq.usai" ]

  run env USAI_API_KEY="$(printf 'aaa\tTABBED')" GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d/tab" ACQ_BACKEND=sbx "$ACQ" secret import --all
  assert_output --partial 'contains a newline or tab'
  refute_output --partial 'TABBED'
  assert [ ! -e "$d/tab/acq.usai" ]

  run env USAI_API_KEY='a b=c;d$e' GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d/ok" ACQ_BACKEND=sbx "$ACQ" secret import usai --force
  assert_equal "$(cat "$d/ok/acq.usai" 2>/dev/null)" 'a b=c;d$e'
}

@test "secret import (msb): never invokes 'msb secret', still writes the acq store" {
  local d="$STUBDIR/import-msb"
  run env USAI_API_KEY=sk-usai-MMMM GITHUB_TOKEN='' GH_TOKEN='' GITLAB_TOKEN='' \
    ACQ_SECRET_STORE_DIR="$d" ACQ_BACKEND=msb "$ACQ" secret import --all
  assert_success
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'msb secret'
  assert_equal "$(cat "$d/acq.usai" 2>/dev/null)" 'sk-usai-MMMM'
}

@test "secret set-custom (msb): fails closed, never reaches 'msb secret'" {
  run env ACQ_BACKEND=msb "$ACQ" secret set-custom -g --host h --env E
  assert_failure
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'msb secret'
}

@test "secret: an unknown subverb fails closed with acq's error, no backend forward" {
  run env ACQ_BACKEND=sbx "$ACQ" secret bogus-verb
  assert_failure
  assert_output --partial "unknown secret subcommand 'bogus-verb'"
  assert_output --partial 'set | rm | ls | has | import | --help'
  local log; log=$(cat "$CALLS")
  refute_regex "$log" 'sbx secret'
}
