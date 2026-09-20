#!/usr/bin/env bats
#
# 135-configure.bats — interactive `acq configure` + config.yaml + prompt widgets
# (ADR-0028; issue GSA-TTS/agentic-coding-quickstart#499).
#
# Covers, offline (no TTY, no backend CLI, no network):
#   - the generalized config.yaml reader/writer (multi-key, preserve-others)
#   - the opt-in kit catalog + ref expansion
#   - the prompt widgets driven via ACQ_PROMPT_TEST_INPUT
#   - `acq configure` dispatch, --help, and the non-interactive fail-open path
#   - configured-default extra-kit application with env-wins precedence
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

# _cfg — source acq (definitions only) + the sbx adapter, so the configure/config
# helpers are in scope for in-process assertions. Mirrors 20-backend-resolution.
_cfg_src() {
  # shellcheck source=acq
  ACQ_SOURCE_ONLY=1 . "$ACQ"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/acq.backends/sbx.sh"
}

# ---------------------------------------------------------------------------
# config.yaml reader / writer
# ---------------------------------------------------------------------------

@test "config: write then read a flat key round-trips" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    _acq_config_write_field backend msb
    _acq_config_read_field backend
  '
  assert_success
  assert_output 'msb'
}

@test "config: writing one key preserves the others" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    _acq_config_write_field backend msb
    _acq_config_write_field extra_kits "openchamber paseo"
    _acq_config_write_field scope_github_token yes
    # Rewriting extra_kits must not disturb backend / scope.
    _acq_config_write_field extra_kits "paseo"
    printf "b=%s\n" "$(_acq_config_read_field backend)"
    printf "k=%s\n" "$(_acq_config_read_field extra_kits)"
    printf "s=%s\n" "$(_acq_config_read_field scope_github_token)"
  '
  assert_success
  assert_line 'b=msb'
  assert_line 'k=paseo'
  assert_line 's=yes'
}

@test "config: empty value removes the key but keeps the rest" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    _acq_config_write_field backend msb
    _acq_config_write_field extra_kits "openchamber"
    _acq_config_write_field extra_kits ""
    printf "b=%s\n" "$(_acq_config_read_field backend)"
    printf "k=[%s]\n" "$(_acq_config_read_field extra_kits)"
  '
  assert_success
  assert_line 'b=msb'
  assert_line 'k=[]'
}

@test "config: an unsafe key name is rejected (fail closed)" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    set +e
    _acq_config_write_field "bad key" value ; echo "write-rc=$?"
    _acq_config_read_field "bad/key" ; echo "read-rc=$?"
    true
  '
  assert_success
  assert_line 'write-rc=1'
  assert_line 'read-rc=0'
}

# ---------------------------------------------------------------------------
# opt-in kit catalog + ref expansion
# ---------------------------------------------------------------------------

@test "catalog: opt-in kit ref is pinned to PATTERNS_KIT_REF/DIR" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    _acq_optin_kit_ref openchamber
  '
  assert_success
  assert_output --partial 'agentic-coding-patterns.git#ref='
  assert_output --partial 'dir=integrations/isolation/acq-kits/openchamber'
}

@test "catalog: prime-agent is intentionally NOT offered (skeleton at pin)" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    printf "%s\n" "${ACQ_OPTIN_KIT_NAMES[@]}"
  '
  assert_success
  assert_line 'openchamber'
  assert_line 'paseo'
  refute_line 'prime-agent'
}

# ---------------------------------------------------------------------------
# prompt widgets (driven by ACQ_PROMPT_TEST_INPUT)
# ---------------------------------------------------------------------------

@test "prompt: multiselect toggles the cursor item and returns its index" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    ACQ_PROMPT_TEST_INPUT="SPACE ENTER" \
      acq_prompt_multiselect "" "openchamber" "descA" "paseo" "descB" 2>/dev/null
  '
  assert_success
  assert_output '1'
}

@test "prompt: multiselect can DOWN then toggle the second item" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    ACQ_PROMPT_TEST_INPUT="DOWN SPACE ENTER" \
      acq_prompt_multiselect "" "a" "d" "b" "d" 2>/dev/null
  '
  assert_success
  assert_output '2'
}

@test "prompt: multiselect defaults pre-check, and can be toggled off" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    # default-checked index 2; move to it and toggle it off -> empty result
    ACQ_PROMPT_TEST_INPUT="DOWN SPACE ENTER" \
      acq_prompt_multiselect "2" "a" "d" "b" "d" 2>/dev/null
  '
  assert_success
  assert_output ''
}

@test "prompt: multiselect QUIT yields CANCELLED (no change sentinel)" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    ACQ_PROMPT_TEST_INPUT="QUIT" \
      acq_prompt_multiselect "1" "a" "d" "b" "d" 2>/dev/null
  '
  assert_success
  assert_output 'CANCELLED'
}

@test "prompt: confirm honors scripted y/n and the default" {
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    set +e
    ACQ_PROMPT_TEST_INPUT="y" acq_prompt_confirm "ok?" "no";  echo "y=$?"
    ACQ_PROMPT_TEST_INPUT="n" acq_prompt_confirm "ok?" "yes"; echo "n=$?"
    ACQ_NO_PROMPT=1 acq_prompt_confirm "ok?" "yes";           echo "dy=$?"
    ACQ_NO_PROMPT=1 acq_prompt_confirm "ok?" "no";            echo "dn=$?"
    true
  '
  assert_success
  assert_line 'y=0'
  assert_line 'n=1'
  assert_line 'dy=0'
  assert_line 'dn=1'
}

@test "prompt: a multi-token script drives multiselect THEN confirm in one flow" {
  # This mirrors how acq_configure calls the widgets in-process (no subshell
  # between them), so the shared scripted-input cursor advances across both.
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    export ACQ_PROMPT_TEST_INPUT="SPACE ENTER y"
    # Do NOT command-substitute the multiselect (that would fork a subshell and
    # lose the cursor advance); redirect its stdout to a file instead.
    acq_prompt_multiselect "" "a" "d" "b" "d" >/dev/null 2>&1
    acq_prompt_confirm "scope?" "no"; echo "confirm=$?"
    true
  '
  assert_success
  assert_line 'confirm=0'
}

# ---------------------------------------------------------------------------
# `acq configure` dispatch + help + non-interactive fail-open
# ---------------------------------------------------------------------------

@test "configure: --help documents the command" {
  run env ACQ_BACKEND=sbx "$ACQ" configure --help
  assert_success
  assert_output --partial 'acq configure'
  assert_output --partial 'ADR-0028'
}

@test "configure: help banner lists the configure verb" {
  run env ACQ_BACKEND=sbx "$ACQ" help
  assert_success
  assert_output --partial 'configure'
}

@test "configure: non-interactive makes NO changes and just prints current" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg2"
  run env ACQ_BACKEND=sbx ACQ_NO_PROMPT=1 "$ACQ" configure
  assert_success
  assert_output --partial 'current configuration'
  assert_output --partial 'configuration unchanged'
  # No config file should have been written by the non-interactive path.
  [ ! -f "$XDG_CONFIG_HOME/acq/config.yaml" ]
}

@test "configure: interactive selection persists to config.yaml" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg3"
  # multiselect: SPACE toggles item 1 (openchamber), ENTER confirms; then the
  # token-scoping confirm reads the next token (n).
  run env ACQ_BACKEND=sbx ACQ_PROMPT_TEST_INPUT="SPACE ENTER n" "$ACQ" configure
  assert_success
  run cat "$XDG_CONFIG_HOME/acq/config.yaml"
  assert_line 'extra_kits: openchamber'
  assert_line 'scope_github_token: no'
}

@test "configure: preserves an existing backend key when saving kits" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg4"
  mkdir -p "$XDG_CONFIG_HOME/acq"
  printf 'backend: sbx\n' > "$XDG_CONFIG_HOME/acq/config.yaml"
  run env ACQ_BACKEND=sbx ACQ_PROMPT_TEST_INPUT="SPACE ENTER y" "$ACQ" configure
  assert_success
  run cat "$XDG_CONFIG_HOME/acq/config.yaml"
  assert_line 'backend: sbx'
  assert_line 'extra_kits: openchamber'
  assert_line 'scope_github_token: yes'
}

# ---------------------------------------------------------------------------
# configured-default extra-kit application + env precedence
# ---------------------------------------------------------------------------

@test "apply: configured extra_kits expand to pinned refs" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg5"
  mkdir -p "$XDG_CONFIG_HOME/acq"
  printf 'extra_kits: openchamber paseo\n' > "$XDG_CONFIG_HOME/acq/config.yaml"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    ACQ_EXTRA_KITS=""; ACQ_EXTRA_KITS_FROM_ENV=""
    _acq_apply_configured_extra_kits
    printf "%s\n" "$ACQ_EXTRA_KITS"
  '
  assert_success
  assert_output --partial 'dir=integrations/isolation/acq-kits/openchamber'
  assert_output --partial 'dir=integrations/isolation/acq-kits/paseo'
}

@test "apply: an env-supplied ACQ_EXTRA_KITS wins over the configured default" {
  export XDG_CONFIG_HOME="$STUBDIR/xdg6"
  mkdir -p "$XDG_CONFIG_HOME/acq"
  printf 'extra_kits: openchamber\n' > "$XDG_CONFIG_HOME/acq/config.yaml"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "'"$ACQ"'" >/dev/null 2>&1
    ACQ_EXTRA_KITS="./mine"; ACQ_EXTRA_KITS_FROM_ENV=1
    _acq_apply_configured_extra_kits
    printf "%s\n" "$ACQ_EXTRA_KITS"
  '
  assert_success
  assert_output './mine'
}
