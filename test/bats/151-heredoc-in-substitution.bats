#!/usr/bin/env bats
# bash 3.2 does not understand a here-document inside a command or process
# substitution: it scans the heredoc body for quote and parenthesis balance and
# fails with "bad substitution" at parse time. Newer bash accepts the same text,
# so only the bash 3.2 job would notice. These tests catch the hazard under any
# bash.

load 'helper'

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

@test "no heredoc inside a command or process substitution has an unsafe body" {
  run python3 "$BATS_TEST_DIRNAME/heredoc-scan.py" "$REPO_ROOT/acq" "$REPO_ROOT"/acq.backends/*.sh "$REPO_ROOT"/scripts/*
  assert_success
}

@test "the scan flags an unsafe heredoc in a process substitution and passes a safe one" {
  local unsafe="$STUBDIR/unsafe.sh" safe="$STUBDIR/safe.sh"
  printf '%s\n' 'while read -r v; do :; done < <(python3 - <<'"'"'PY'"'"'' "# it's unsafe" 'PY' ')' > "$unsafe"
  printf '%s\n' 'while read -r v; do :; done < <(python3 - <<'"'"'PY'"'"'' 'print(1)' 'PY' ')' > "$safe"
  run python3 "$BATS_TEST_DIRNAME/heredoc-scan.py" "$unsafe"
  assert_failure
  assert_output --partial 'odd single quotes'
  run python3 "$BATS_TEST_DIRNAME/heredoc-scan.py" "$safe"
  assert_success
}

@test "facts reader output carries no carriage return" {
  local record="$STUBDIR/facts.json" out
  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov","modelsUrl":"https://alpha.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' > "$record"
  out=$(acq_provider_facts_json_fields "$record"; echo END)
  [ "${out#*$'\r'}" = "$out" ]
  case "$out" in alpha*END) ;; *) false ;; esac
}
