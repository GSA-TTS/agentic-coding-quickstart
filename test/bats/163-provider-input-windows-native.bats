#!/usr/bin/env bats
#
# 163-provider-input-windows-native.bats — the provider-input transaction under
# Git Bash with native Windows Python, on a real NTFS volume.
#
# 147-provider-input-projection.bats covers the same helpers on Linux with an
# emulated Windows interpreter. This file runs only where the emulation stops:
# Git Bash (MSYS2) or Cygwin with a native Windows CPython (the interpreter
# probe reports "nt"). It skips everywhere else. It checks what the emulation
# cannot: real junctions (made with mklink /J, which needs no privilege), the
# MSYS-to-Windows path mapping against the real mount table, the pointer file
# that stands in for the current symlink, and a stubbed `acq create` and
# `acq rm` with the Bash implementation.
#
# shellcheck shell=bats

load 'helper'

setup() {
  case "${OSTYPE:-}" in msys*|cygwin*) ;; *) skip "Git Bash, MSYS2 or Cygwin only" ;; esac
  acq_setup_stubs
  unset ACQ_PROVIDER_INPUT_PYTHON
  _acq_provider_input_path_python 2>/dev/null || skip "no usable Python 3"
  [ "$_ACQ_PROVIDER_INPUT_PATH_PY_KIND" = nt ] || skip "the Python found is not a native Windows CPython"
}
teardown() { acq_teardown_stubs; }

# _win_native PATH... — run native Python code ($1) with Windows paths, unconverted.
_win_native() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${_ACQ_PROVIDER_INPUT_PATH_PY[@]}" -I -c "$@"
}

# _junction LINK TARGET — an NTFS directory junction, which needs no privilege.
_junction() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" >/dev/null
}

# _is_reparse PATH — true when Windows reports PATH as a link or reparse point.
_is_reparse() {
  [ "$(_win_native 'import os, stat, sys
st = os.lstat(sys.argv[1])
sys.stdout.write("1" if stat.S_ISLNK(st.st_mode) or st.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT else "0")' "$(cygpath -w "$1")")" = 1 ]
}

# _win_kit DIR ID — a provider kit with every artifact the snapshot copies.
_win_kit() {
  mkdir -p "$1/provider-input" "$1/scripts" "$1/files"
  printf '{"providerId":"%s","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/%s","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json"}\n' "$2" "$2" > "$1/provider-input.json"
  printf '{"providerId":"%s","keyEnv":"ALPHA_KEY","host":"%s.example.gov","modelsUrl":"https://%s.example.gov/v1/models","apiProtocol":"openai"}\n' \
    "$2" "$2" "$2" > "$1/provider-input/facts.json"
  printf '#!/bin/sh\n' > "$1/scripts/normalize"
  printf '{"providerId":"%s","models":[]}\n' "$2" > "$1/files/snapshot.json"
  printf 'caps: {}\n' > "$1/spec.yaml"
}

# _win_release DIR — a stand-in for the pinned Patterns control plane: a
# validator that only checks each bundle parses, and a provider-input Python
# that passes the dependency check and otherwise runs the native interpreter.
_win_release() {
  mkdir -p "$1/scripts" "$1/integrations/isolation/schemas"
  printf '{"providers":{"alpha":"ALPHA_KEY"}}\n' > "$1/integrations/isolation/schemas/provider-credential-bindings.json"
  printf '%s\n' 'import json, sys' 'args = sys.argv[1:]' \
    'for i, a in enumerate(args):' '    if a == "--bundle": json.load(open(args[i + 1], encoding="utf-8"))' \
    > "$1/scripts/validate_provider_input_contract.py"
  printf '#!/bin/sh\n[ "${1:-}" = -I ] && shift\n[ "$1" = -c ] && exit 0\nexec %s "$@"\n' \
    "$(printf '%q ' "${_ACQ_PROVIDER_INPUT_PATH_PY[@]}")" > "$1/provider-python"
  chmod +x "$1/provider-python"
  export ACQ_PROVIDER_INPUT_PYTHON="$1/provider-python"
}

@test "native Windows: snapshot and materialize copy a kit" {
  local kit="$STUBDIR/kit" candidate="$STUBDIR/candidate" providers="$STUBDIR/providers"
  _win_kit "$kit" alpha
  mkdir -p "$providers"
  run _acq_provider_input_snapshot "$kit" "$candidate"
  assert_success
  cmp "$kit/provider-input/facts.json" "$candidate/provider-input/facts.json"
  cmp "$kit/spec.yaml" "$candidate/spec.yaml"
  run _acq_provider_input_materialize "$candidate/provider-input.json" "$candidate" "$providers"
  assert_success
  cmp "$kit/files/snapshot.json" "$providers/alpha/snapshot.json"
  [ -f "$providers/alpha/normalizer" ]
}

@test "native Windows: snapshot refuses a junction anywhere in an artifact path" {
  local kit="$STUBDIR/kit" outside="$STUBDIR/outside"
  _win_kit "$kit" alpha
  mkdir -p "$outside"
  printf '{"providerId":"evil"}\n' > "$outside/facts.json"
  mv "$kit/provider-input" "$STUBDIR/provider-input.real"
  _junction "$kit/provider-input" "$outside"
  _is_reparse "$kit/provider-input"
  run _acq_provider_input_snapshot "$kit" "$STUBDIR/c1"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
  [ ! -e "$STUBDIR/c1/provider-input/facts.json" ]
  # A kit root that is a junction is refused too. Git Bash reports a junction
  # as a symlink, so rm removes the junction and leaves its target.
  rm "$kit/provider-input"; mv "$STUBDIR/provider-input.real" "$kit/provider-input"
  [ -f "$outside/facts.json" ]
  _junction "$STUBDIR/kitlink" "$kit"
  run _acq_provider_input_snapshot "$STUBDIR/kitlink" "$STUBDIR/c2"
  assert_failure
  run _acq_provider_input_snapshot "$kit" "$STUBDIR/c3"
  assert_success
}

@test "native Windows: snapshot refuses a symlinked artifact when one can be made" {
  local kit="$STUBDIR/kit"
  _win_kit "$kit" alpha
  printf 'secret\n' > "$STUBDIR/secret"
  rm "$kit/spec.yaml"
  MSYS=winsymlinks:nativestrict CYGWIN=winsymlinks:nativestrict ln -s "$STUBDIR/secret" "$kit/spec.yaml" 2>/dev/null \
    || skip "native symlinks need Developer Mode or an administrator"
  run _acq_provider_input_snapshot "$kit" "$STUBDIR/c1"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
}

@test "native Windows: snapshot refuses device names and alternate data streams" {
  local kit="$STUBDIR/kit" path i=0
  _win_kit "$kit" alpha
  for path in 'NUL' 'provider-input/facts.json:ads' 'provider-input/con.json' 'facts.json.'; do
    i=$((i + 1))
    printf '{"providerId":"alpha","factsPath":"%s","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json"}\n' "$path" > "$kit/provider-input.json"
    run _acq_provider_input_snapshot "$kit" "$STUBDIR/c$i"
    assert_failure
    assert_output --partial 'unsafe provider artifact path'
  done
}

@test "native Windows: publish writes and swaps a pointer file, and replaces a junction" {
  local root
  root=$(acq_provider_input_root msb winpublish)
  _acq_provider_input_safe_mkdir "$root/generations/generation.one/models/providers"
  _acq_provider_input_safe_mkdir "$root/generations/generation.two/models/providers"
  run _acq_provider_input_publish "$root" "$root/generations/generation.one"
  assert_success
  [ -f "$root/current" ]
  refute _is_reparse "$root/current"
  assert_equal "$(cat "$root/current")" "generations/generation.one"
  run _acq_provider_input_publish "$root" "$root/generations/generation.two"
  assert_success
  assert_equal "$(cat "$root/current")" "generations/generation.two"
  # A junction left as current (the Python acq's link has the same effect).
  rm -f "$root/current"
  _junction "$root/current" "$root/generations/generation.one"
  _is_reparse "$root/current"
  run _acq_provider_input_publish "$root" "$root/generations/generation.two"
  assert_success
  [ -f "$root/current" ]
  refute _is_reparse "$root/current"
  [ -d "$root/generations/generation.one/models/providers" ]
  [ -z "$(find "$root" -maxdepth 1 -name '.current.*')" ]
}

@test "native Windows: publish refuses a real directory left as current" {
  local root
  root=$(acq_provider_input_root msb windir)
  _acq_provider_input_safe_mkdir "$root/generations/generation.one/models/providers"
  mkdir -p "$root/current/models"
  run _acq_provider_input_publish "$root" "$root/generations/generation.one"
  assert_failure
  assert_output --partial 'it is a directory, not a file or a link'
  [ -d "$root/current/models" ]
  [ -z "$(find "$root" -maxdepth 1 -name '.current.*')" ]
}

@test "native Windows: provider-input transaction runs end to end" {
  local release="$STUBDIR/release" lock generation root mount source
  _win_release "$release"
  _win_kit "$STUBDIR/kit" alpha
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  # shellcheck disable=SC2034 # acq_provider_input_prepare reads KITS
  KITS=("$STUBDIR/kit")
  _acq_provider_input_guardian_start
  lock=$(acq_provider_input_lock_acquire msb wintx "$_ACQ_PROVIDER_INPUT_GUARDIAN_PID")
  generation=$(acq_provider_input_prepare msb wintx)
  root=$(acq_provider_input_root msb wintx)
  [[ "$generation" == "$root/generations/generation."* ]]
  [ -f "$generation/models/providers/alpha/facts.json" ]
  # The msb mount source is a drive-form path native Windows resolves.
  mount=$(acq_provider_input_msb_mount wintx "$generation")
  source=${mount%:"$ACQ_PROVIDER_INPUT_GUEST_DIR"/*}
  [[ "$source" == [A-Za-z]:/* ]]
  assert_equal "$(_win_native 'import os, sys; sys.stdout.write(str(os.path.isfile(sys.argv[1])))' "$source/models/providers/alpha/facts.json")" True
  _acq_provider_input_publish "$root" "$generation"
  assert_equal "$(cat "$root/current")" "generations/${generation##*/}"
  # After create, the key check and the credential bindings read the published
  # generation through the pointer file, with native Python writing the facts.
  # shellcheck disable=SC2034 # acq_provider_sandbox_facts reads it
  ACQ_PROVIDER_BINDINGS_GENERATION=""
  assert_equal "$(acq_provider_sandbox_provider_ids msb wintx)" alpha
  assert_equal "$(acq_provider_sandbox_facts msb wintx)" \
    "$(printf 'alpha\tALPHA_KEY\talpha.example.gov\thttps://alpha.example.gov/v1/models\topenai')"
  acq_provider_input_remove msb wintx
  [ ! -e "$root" ]
  acq_provider_input_lock_release "$lock"
  [ ! -e "$lock" ]
  _acq_provider_input_guardian_stop
}

@test "native Windows: provider facts parse from native Python's CRLF output" {
  local record="$STUBDIR/kit/provider-input/facts.json"
  [ "${#_ACQ_PROVIDER_INPUT_PATH_PY[@]}" -eq 1 ] || skip "only py -3 found; ACQ_PROVIDER_INPUT_PYTHON takes one path"
  _win_kit "$STUBDIR/kit" alpha
  ACQ_PROVIDER_INPUT_PYTHON="${_ACQ_PROVIDER_INPUT_PATH_PY[0]}" run acq_provider_facts_json_fields "$record"
  assert_success
  assert_output "$(printf 'alpha\tALPHA_KEY\talpha.example.gov\thttps://alpha.example.gov/v1/models\topenai')"
}

@test "native Windows: a pointer to a junction or outside the root falls back to recorded facts" {
  local root recorded target
  # The provider-input Python stand-in also reads the facts.
  _win_release "$STUBDIR/release"
  _win_kit "$STUBDIR/kit" alpha
  root=$(acq_provider_input_root msb winfallback)
  _acq_provider_input_safe_mkdir "$root/generations/generation.real/models/providers/alpha"
  cp "$STUBDIR/kit/provider-input/facts.json" "$root/generations/generation.real/models/providers/alpha/facts.json"
  _junction "$root/generations/generation.junction" "$root/generations/generation.real"
  recorded=$(printf 'beta\tBETA_KEY\tbeta.example.gov\thttps://beta.example.gov/v1/models\topenai')
  acq_host_config_write msb winfallback provider-credentials "$recorded"
  printf 'generations/generation.real\n' > "$root/current"
  assert_equal "$(acq_provider_sandbox_provider_ids msb winfallback)" alpha
  for target in generations/generation.junction ../generation.real "$(cygpath -m "$root/generations/generation.real")"; do
    printf '%s\n' "$target" > "$root/current"
    assert_equal "$(acq_provider_sandbox_provider_ids msb winfallback)" beta
  done
}

@test "native Windows: snapshot refuses an artifact with another hard link" {
  local kit="$STUBDIR/kit"
  _win_kit "$kit" alpha
  printf 'secret\n' > "$STUBDIR/secret"
  rm "$kit/files/snapshot.json"
  ln "$STUBDIR/secret" "$kit/files/snapshot.json"
  [ "$(stat -c %h "$STUBDIR/secret")" = 2 ]
  run _acq_provider_input_snapshot "$kit" "$STUBDIR/c1"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
  [ ! -e "$STUBDIR/c1/files/snapshot.json" ]
}

@test "native Windows: stubbed acq create and acq rm with the Bash implementation" {
  local proj="$STUBDIR/proj" root
  mkdir -p "$proj"
  # BASH_ENV would replace the provider-input transaction with the stub boundary.
  run env -u BASH_ENV ACQ_IMPL=bash ACQ_BACKEND=msb ACQ_NO_PROMPT=1 \
    "$ACQ" create shell --no-provider-kits --name winbox "$proj"
  assert_success
  root=$(acq_provider_input_root msb winbox)
  [ -f "$root/current" ]
  refute _is_reparse "$root/current"
  [ -d "$root/$(cat "$root/current")/models/providers" ]
  [ ! -e "$root.lock" ]
  run env -u BASH_ENV ACQ_IMPL=bash ACQ_BACKEND=msb ACQ_NO_PROMPT=1 "$ACQ" rm winbox
  assert_success
  [ ! -e "$root" ]
  [ ! -e "$root.lock" ]
}
