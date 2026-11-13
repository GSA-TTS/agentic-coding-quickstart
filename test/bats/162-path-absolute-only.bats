#!/usr/bin/env bats
#
# 162-path-absolute-only.bats — the POSIX launchers find programs in absolute
# PATH directories only.
#
# WHY THIS EXISTS
#
# acq usually runs from inside the workspace it sandboxes, and an agent in the
# guest can write to that workspace. An empty PATH entry (a leading, trailing or
# doubled ':') or a relative one such as '.' makes the shell search the current
# directory, so a planted ./git, ./msb or ./python3 would run on the host before
# any sandbox exists. The Bash `acq` and `acq-python` therefore drop every PATH
# entry that is not absolute before they run anything, as acq_py.hostexec does
# for the Python implementation.
#
# shellcheck shell=bats

setup() {
  acq_setup_stubs
  WS="$STUBDIR/workspace"
  MARKER="$STUBDIR/hijacked"
  mkdir -p "$WS/bin"
  # Every program the launchers look up by bare name before (or while) they
  # dispatch. Each planted copy records that it ran.
  local prog
  for prog in git msb sbx python3 python dirname readlink uname; do
    printf '#!/bin/sh\necho %s >> "%s"\nexit 1\n' "$prog" "$MARKER" >"$WS/$prog"
    cp "$WS/$prog" "$WS/bin/$prog"
    chmod 755 "$WS/$prog" "$WS/bin/$prog"
  done
}
teardown() { acq_teardown_stubs; }

load 'helper'

_assert_not_hijacked() {
  if [ -e "$MARKER" ]; then
    echo "a program planted in the workspace ran: $(tr '\n' ' ' <"$MARKER")" >&2
    return 1
  fi
}

@test "_acq_path_absolute_only keeps the absolute entries in order" {
  local saved="$PATH" got
  PATH="::.:bin:/opt/a::/usr/bin:./x:/opt/b:"
  _acq_path_absolute_only
  got="$PATH"
  PATH="$saved"
  [ "$got" = "/opt/a:/usr/bin:/opt/b" ] || { echo "got PATH=$got" >&2; return 1; }
}

@test "_acq_path_absolute_only refuses a PATH with no absolute entry and leaves it alone" {
  local saved="$PATH" rc=0 got
  PATH=":.:bin"
  _acq_path_absolute_only || rc=$?
  got="$PATH"
  PATH="$saved"
  [ "$rc" -eq 1 ]
  [ "$got" = ":.:bin" ]
}

@test "acq refuses to start when PATH has no absolute entry" {
  cd "$WS"
  run env PATH=".:bin" "$BASH" "$REPO_ROOT/acq" version
  assert_failure 1
  assert_output --partial "PATH has no absolute directory"
  _assert_not_hijacked
}

@test "acq ignores programs in the current directory reached by an empty PATH entry" {
  cd "$WS"
  run env PATH=":$PATH" "$BASH" "$REPO_ROOT/acq" version
  _assert_not_hijacked
  assert_success
  assert_output --partial "clone dir:"
}

@test "acq ignores programs reached by '.' and relative PATH entries" {
  cd "$WS"
  run env PATH=".:bin:$PATH:" "$BASH" "$REPO_ROOT/acq" version
  _assert_not_hijacked
  assert_success
}

@test "ACQ_IMPL=python does not run a python3 from the current directory" {
  cd "$WS"
  run env PATH=":$PATH" ACQ_IMPL=python "$BASH" "$REPO_ROOT/acq" version --json
  _assert_not_hijacked
  assert_success
  assert_output --partial '"impl": "python"'
}

@test "acq-python does not run a python3 from the current directory" {
  cd "$WS"
  run env PATH=":.:bin:$PATH" /bin/sh "$REPO_ROOT/acq-python" version --json
  _assert_not_hijacked
  assert_success
  assert_output --partial '"impl": "python"'
}

@test "acq-python refuses to start when PATH has no absolute entry" {
  cd "$WS"
  run env PATH=".:bin" /bin/sh "$REPO_ROOT/acq-python" version
  assert_failure 1
  assert_output --partial "PATH has no absolute directory"
  _assert_not_hijacked
}
