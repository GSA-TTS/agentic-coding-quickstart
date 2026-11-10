#!/usr/bin/env bats

# Tests for the acq v1 installer (install.sh) — ADR-0042m. The installer is the
# Python-v1 front door: a checksum-verified, user-scoped install of the enumerated
# offline asset set (readable source + bundled managed runtime + wheelhouse), with
# dry-run, consent, and update-by-reinstall. These tests run the real script
# against the checked-in offline fixture (test/fixtures/installer) and assert the
# fail-closed checksum/dry-run/consent behavior.

load './helper.bash'

setup() {
  acq_setup_stubs
  export XDG_DATA_HOME="$STUBDIR/xdg-data"
  unset ACQ_INSTALL_DIR ACQ_INSTALL_BIN_DIR ACQ_INSTALL_SOURCE
}

teardown() {
  acq_teardown_stubs
}

_install_dir() {
  printf '%s/acq' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

@test "installer: --help exits 0 and prints usage" {
  run sh "$REPO_ROOT/install.sh" --help
  assert_success
  assert_output --partial 'install acq'
}

@test "installer: --version exits 0" {
  run sh "$REPO_ROOT/install.sh" --version
  assert_success
  assert_output --partial 'install.sh'
}

@test "installer: an unknown option is a usage error (exit 2)" {
  run sh "$REPO_ROOT/install.sh" --bogus
  assert_failure 2
  assert_output --partial 'unknown option'
}

@test "installer: --dry-run prints a plan and performs no writes" {
  run sh "$REPO_ROOT/install.sh" --dry-run
  assert_success
  assert_output --partial '[dry-run]'
  # No install dir, no bin dir, no launcher link.
  [ ! -e "$(_install_dir)" ]
  [ ! -e "$HOME/.local/bin" ]
}

@test "installer: installs offline from the enumerated asset set" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  assert_output --regexp 'verified acq-(macos|linux)-(arm64|x86_64|aarch64)\.tar\.gz'
  # The bundled runtime and the launcher are laid down.
  [ -e "$(_install_dir)/py-acq/runtime/bin/python3" ]
  [ -L "$HOME/.local/bin/acq" ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "installer: a checksum mismatch fails closed (exit 1, no install)" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer-bad" --yes
  assert_failure
  assert_output --partial 'checksum mismatch'
  [ ! -e "$(_install_dir)" ]
}

@test "installer: consent is never inferred non-interactively" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer"
  assert_success
  assert_output --partial 'Not changing your PATH'
  [ ! -e "$HOME/.bash_profile" ]
  [ ! -e "$HOME/.profile" ]
}

# _elevation_in TEXT — succeeds when TEXT invokes privilege elevation: an
# elevation command followed by an argument anywhere a command can start
# (line start, after `run`, `;`, `&&`, `$(`), or osascript "with administrator
# privileges". Prose such as "no sudo," or "(no sudo)" is not followed by
# whitespace and does not match.
_elevation_in() {
  # Regexes in variables: bash 3.2 and 4+ treat a quoted =~ operand differently.
  local cmd_re='(^|[^[:alnum:]_-])(sudo|doas|pkexec|runas)[[:space:]]'
  local osa_re='osascript .*with administrator privileges'
  [[ $1 =~ $cmd_re ]] || [[ $1 =~ $osa_re ]]
}

@test "installer: never elevates (no elevation invocation)" {
  # The installer documents non-elevation ("no sudo") in comments and --help
  # prose; that wording must not read as an invocation, but a real elevation
  # command must be caught, including one wrapped in run() or done via doas.
  grep -q 'no sudo' "$REPO_ROOT/install.sh" || fail "documentation of non-elevation missing"

  local code
  code="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/install.sh")"
  ! _elevation_in "$code" || fail "install.sh invokes privilege elevation"
  # Positive controls: the guard catches each form it claims to.
  _elevation_in "$code"$'\nsudo true' || fail "a bare sudo line was not caught"
  _elevation_in "$code"$'\nrun sudo mkdir -p "$BIN_DIR"' || fail "run sudo was not caught"
  _elevation_in "$code"$'\nrun doas ln -s a b' || fail "doas was not caught"
  _elevation_in "$code"$'\nx="$(pkexec true)"' || fail "a command substitution was not caught"
}

@test "installer: never dumps the environment or hardcodes a secret" {
  run grep -E 'printenv|API_KEY=|TOKEN=|PASSWORD=|SECRET=' "$REPO_ROOT/install.sh"
  assert_failure
}

# The default install dir ($XDG_DATA_HOME/acq) is also where the legacy Bash acq
# keeps its file-fallback secret store and provider-input-validator runtime, and
# --install-dir can name any directory. The installer must never delete content
# it did not create.

# Copy the offline fixture and add an extra top-level entry to every archive
# (or, with "drop", remove one), regenerating SHA256SUMS: a future release that
# ships a new name, or a checksum-valid release that is incomplete.
_fixture_with_extra_entry() {
  local name="$1" mode="${2:-add}" out="$STUBDIR/assets-extra" a work
  mkdir -p "$out"
  cp "$REPO_ROOT/test/fixtures/installer/provenance.json" "$out/"
  for a in "$REPO_ROOT"/test/fixtures/installer/*.tar.gz; do
    work="$STUBDIR/repack"; rm -rf "$work"; mkdir -p "$work"
    tar -xzf "$a" -C "$work"
    if [ "$mode" = drop ]; then
      rm -rf "${work:?}/$name"
    else
      mkdir -p "$work/$name"; printf 'shipped\n' > "$work/$name/README"
    fi
    (cd "$work" && tar -czf "$out/${a##*/}" .)
  done
  (cd "$out" && for a in *.tar.gz; do
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$a"; else shasum -a 256 "$a"; fi
  done) > "$out/SHA256SUMS"
  printf '%s' "$out"
}

@test "installer: preserves unrelated content already in the install dir" {
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/secrets" "$dir/provider-input-validator"
  printf 'keep\n' > "$dir/secrets/acq.usai"
  printf 'keep\n' > "$dir/provider-input-validator/marker"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/secrets/acq.usai")" = keep ]
  [ "$(cat "$dir/provider-input-validator/marker")" = keep ]
  [ -e "$dir/py-acq/runtime/bin/python3" ]
  [ -f "$dir/provenance.json" ]
  # The marker lists exactly the names the installer owns.
  run tail -n +2 "$dir/.acq-v1-install"
  assert_output --partial 'py-acq'
  refute_output --partial 'secrets'
  refute_output --partial 'provider-input-validator'
}

@test "installer: refuses to overwrite an entry it did not create (legacy clone)" {
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.git"
  printf '#!/bin/sh\necho legacy\n' > "$dir/acq"
  printf 'local change\n' > "$dir/mine.txt"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial "already contains 'acq'"
  assert_output --partial 'nothing was changed'
  [ "$(cat "$dir/mine.txt")" = 'local change' ]
  grep -q legacy "$dir/acq"
  [ ! -e "$dir/py-acq" ]
  [ ! -e "$dir/.acq-v1-install" ]
}

@test "installer: refuses a symlinked install dir, with or without a trailing slash" {
  local dir; dir="$(_install_dir)"
  mkdir -p "$STUBDIR/elsewhere" "$(dirname "$dir")"
  printf 'keep\n' > "$STUBDIR/elsewhere/data"
  ln -s "$STUBDIR/elsewhere" "$dir"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 'is a symlink'
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --install-dir "$dir/" --yes
  assert_failure
  assert_output --partial 'is a symlink'
  [ "$(cat "$STUBDIR/elsewhere/data")" = keep ]
  [ ! -e "$STUBDIR/elsewhere/acq" ]
}

@test "installer: re-running over its own install replaces its files in place" {
  local dir; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  printf 'stale\n' > "$dir/py-acq/stale-from-old-release"
  mkdir -p "$dir/secrets"; printf 'keep\n' > "$dir/secrets/acq.usai"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ -e "$dir/py-acq/runtime/bin/python3" ]
  [ ! -e "$dir/py-acq/stale-from-old-release" ]
  [ "$(cat "$dir/secrets/acq.usai")" = keep ]
  [ -z "$(find "$dir" -maxdepth 1 -name '.acq-previous.*')" ]
}

@test "installer: a marked dir still refuses a new release name it does not own" {
  local dir assets; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  mkdir -p "$dir/secrets"; printf 'REAL-USER-SECRET\n' > "$dir/secrets/acq.usai"
  assets="$(_fixture_with_extra_entry secrets)"
  run sh "$REPO_ROOT/install.sh" --source "$assets" --yes
  assert_failure
  assert_output --partial "already contains 'secrets'"
  [ "$(cat "$dir/secrets/acq.usai")" = REAL-USER-SECRET ]
}

@test "installer: a failed first install can be finished by re-running" {
  local dir shim; dir="$(_install_dir)"
  shim="$STUBDIR/mv-shim"; mkdir -p "$shim"
  # Fail the move of wheelhouse/ once, as a full disk would.
  cat > "$shim/mv" <<SHIM
#!/bin/sh
for last; do :; done
case "\$last" in
  */wheelhouse) if [ ! -e "$STUBDIR/mv-failed" ]; then : > "$STUBDIR/mv-failed"; exit 1; fi ;;
esac
exec /bin/mv "\$@"
SHIM
  chmod +x "$shim/mv"
  PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 're-run the installer'
  [ -f "$dir/.acq-v1-install" ]
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ -d "$dir/wheelhouse" ]
  [ -z "$(find "$dir" -maxdepth 1 -name '.acq-previous.*')" ]
}

@test "installer: a first install never sweeps move-aside-looking dirs it did not create" {
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-previous.mine"; printf 'keep\n' > "$dir/.acq-previous.mine/f"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-previous.mine/f")" = keep ]
}

# The ownership marker is written to .acq-v1-install.tmp.<pid> and renamed into
# place. A run stopped in between must not leave that file behind for good.
@test "installer: a later run sweeps temporary markers left by an interrupted one" {
  local dir dead; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  # The PID of a process that has already exited, as an interrupted run's is.
  sh -c 'exit 0' & dead=$!
  wait "$dead" || :
  printf 'old\n' > "$dir/.acq-v1-install.tmp.$dead"
  # Lookalikes that are not a temporary marker are left alone.
  printf 'keep\n' > "$dir/.acq-v1-install.tmp.mine"
  printf 'keep\n' > "$dir/.acq-v1-install.tmp.x.tmp.123"
  mkdir -p "$dir/.acq-v1-install.tmp.777"
  ln -s "$STUBDIR/elsewhere" "$dir/.acq-v1-install.tmp.888"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$dir/.acq-v1-install.tmp.$dead" ]
  [ "$(cat "$dir/.acq-v1-install.tmp.mine")" = keep ]
  [ "$(cat "$dir/.acq-v1-install.tmp.x.tmp.123")" = keep ]
  [ -d "$dir/.acq-v1-install.tmp.777" ]
  [ -L "$dir/.acq-v1-install.tmp.888" ]
}

@test "installer: a first install never sweeps temporary-marker lookalikes" {
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir"; printf 'keep\n' > "$dir/.acq-v1-install.tmp.12345"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-v1-install.tmp.12345")" = keep ]
}

# Another install into the same directory may be running: its temporary marker
# and move-aside dir are named for its live PID and must survive this run's sweep.
@test "installer: the sweep skips files of an install that is still running" {
  local dir; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  # This test's own shell stands in for the concurrent installer.
  printf 'in flight\n' > "$dir/.acq-v1-install.tmp.$$"
  mkdir -p "$dir/.acq-previous.$$"; printf 'moved aside\n' > "$dir/.acq-previous.$$/acq"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-v1-install.tmp.$$")" = 'in flight' ]
  [ "$(cat "$dir/.acq-previous.$$/acq")" = 'moved aside' ]
}

# In a fresh container PIDs repeat, so an earlier interrupted run often had this
# run's PID. Its move-aside dir is a leftover, not this run's, and must be swept
# rather than block this run's own `mkdir`. exec keeps the planting shell's PID.
@test "installer: a leftover named for this run's own PID is swept" {
  local dir; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  run sh -c 'mkdir -p "$1/.acq-previous.$$" && printf "leftover\n" > "$1/.acq-previous.$$/acq" \
    && exec sh "$2" --source "$3" --yes' _ "$dir" "$REPO_ROOT/install.sh" "$REPO_ROOT/test/fixtures/installer"
  assert_success
  [ -z "$(find "$dir" -maxdepth 1 -name '.acq-previous.*')" ]
}

# PID 1 is init on a host and in most containers, never a concurrent install.
@test "installer: a leftover named for PID 1 is swept" {
  local dir; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  mkdir -p "$dir/.acq-previous.1"; printf 'leftover\n' > "$dir/.acq-previous.1/acq"
  printf 'old\n' > "$dir/.acq-v1-install.tmp.1"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$dir/.acq-previous.1" ]
  [ ! -e "$dir/.acq-v1-install.tmp.1" ]
}

# A killed run leaves its staging dir (.acq-stage.<pid>.<random>) in the install
# dir's parent; a later run sweeps it unless its process is still running.
@test "installer: stale staging dirs in the parent are swept, live ones kept" {
  local dir dead; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  sh -c 'exit 0' & dead=$!
  wait "$dead" || :
  mkdir -p "$XDG_DATA_HOME/.acq-stage.$dead.AbCdEfGh/stage" "$XDG_DATA_HOME/.acq-stage.$$.AbCdEfGh/stage" \
    "$XDG_DATA_HOME/.acq-stage.mine"
  printf 'x\n' > "$XDG_DATA_HOME/.acq-stage.$dead.AbCdEfGh/stage/acq"
  ln -s "$STUBDIR/elsewhere" "$XDG_DATA_HOME/.acq-stage.$dead.LiNkLiNk"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$XDG_DATA_HOME/.acq-stage.$dead.AbCdEfGh" ]
  # A live process's staging dir, a lookalike and a symlink are left alone.
  [ -d "$XDG_DATA_HOME/.acq-stage.$$.AbCdEfGh/stage" ]
  [ -d "$XDG_DATA_HOME/.acq-stage.mine" ]
  [ -L "$XDG_DATA_HOME/.acq-stage.$dead.LiNkLiNk" ]
}

# Another user's killed install can leave a staging dir in a shared parent that
# this user cannot remove. The sweep is best effort, so the install still
# finishes (and so does the next one). A read-only child dir stands in for it.
@test "installer: a stale staging dir that cannot be removed does not stop the install" {
  [ "$(id -u)" != 0 ] || skip "root can remove a read-only directory"
  local dir dead stuck; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  sh -c 'exit 0' & dead=$!
  wait "$dead" || :
  stuck="$XDG_DATA_HOME/.acq-stage.$dead.StUcKdIr"
  mkdir -p "$stuck/stage/sub"
  chmod 500 "$stuck/stage"
  printf 'stale\n' > "$dir/py-acq/stale-from-old-release"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  local first=$status
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  local second=$status
  chmod 700 "$stuck/stage"
  [ "$first" -eq 0 ] && [ "$second" -eq 0 ]
  # The publish finished: the old release was replaced and nothing was left mid-way.
  [ ! -e "$dir/py-acq/stale-from-old-release" ]
  [ -e "$dir/py-acq/runtime/bin/python3" ]
  [ -z "$(find "$dir" -maxdepth 1 -name '.acq-previous.*')" ]
  [ -d "$stuck/stage/sub" ]
}

# Only leftovers this user owns are swept. An `id` that reports another uid
# makes every leftover look like someone else's, so all of them stay.
@test "installer: the sweep leaves leftovers owned by another user alone" {
  local dir dead; dir="$(_install_dir)"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  sh -c 'exit 0' & dead=$!
  wait "$dead" || :
  mkdir -p "$dir/.acq-previous.$dead" "$XDG_DATA_HOME/.acq-stage.$dead.OtHeRuSr"
  printf 'old\n' > "$dir/.acq-v1-install.tmp.$dead"
  mkdir -p "$STUBDIR/id-shim"
  printf '#!/bin/sh\ncase "$1" in -u) echo 4199999 ;; *) exec /usr/bin/id "$@" ;; esac\n' > "$STUBDIR/id-shim/id"
  chmod +x "$STUBDIR/id-shim/id"
  PATH="$STUBDIR/id-shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ -d "$dir/.acq-previous.$dead" ]
  [ -d "$XDG_DATA_HOME/.acq-stage.$dead.OtHeRuSr" ]
  [ -f "$dir/.acq-v1-install.tmp.$dead" ]
}

# The install dir refusals come before anything is extracted or staged.
@test "installer: a symlinked install dir is refused before extracting anything" {
  local dir real_tar; dir="$(_install_dir)"
  real_tar="$(command -v tar)"
  mkdir -p "$STUBDIR/elsewhere" "$STUBDIR/tar-shim" "$(dirname "$dir")"
  ln -s "$STUBDIR/elsewhere" "$dir"
  printf '#!/bin/sh\n: > "%s/tar-ran"\nexec "%s" "$@"\n' "$STUBDIR" "$real_tar" > "$STUBDIR/tar-shim/tar"
  chmod +x "$STUBDIR/tar-shim/tar"
  PATH="$STUBDIR/tar-shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 'is a symlink'
  [ ! -e "$STUBDIR/tar-ran" ]
  [ -z "$(find "$XDG_DATA_HOME" -maxdepth 1 -name '.acq-stage.*')" ]
}

@test "installer: a failed marker rename leaves no temporary marker behind" {
  local dir shim; dir="$(_install_dir)"
  shim="$STUBDIR/mv-shim"; mkdir -p "$shim"
  cat > "$shim/mv" <<'SHIM'
#!/bin/sh
for last; do :; done
case "$last" in */.acq-v1-install) exit 1 ;; esac
exec /bin/mv "$@"
SHIM
  chmod +x "$shim/mv"
  PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 'could not write'
  [ -z "$(find "$dir" -maxdepth 1 -name '.acq-v1-install.tmp.*')" ]
}

# The `acq` launcher is the Bash dispatcher and sources acq.backends/common.sh
# before it reads ACQ_IMPL, so an archive without the backend tree would install
# an `acq` that cannot start on either implementation.
@test "installer: an archive without the Bash backend tree fails closed" {
  local assets
  assets="$(_fixture_with_extra_entry acq.backends drop)"
  run sh "$REPO_ROOT/install.sh" --source "$assets" --yes
  assert_failure 1
  assert_output --partial 'missing the Bash backend tree (acq.backends/)'
  [ ! -e "$(_install_dir)" ]
  # The staging dir beside the install dir is removed on failure too.
  [ -z "$(find "$XDG_DATA_HOME" -maxdepth 1 -name '.acq-stage.*')" ]
}

# --- remote sources: HTTPS with TLS 1.2+ only; local sets stay offline ----------

# A curl stand-in that logs its arguments and serves the named file from the
# offline fixture, so a remote install runs without a network.
_plant_logging_curl() {
  cat > "$STUBDIR/curl" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >> "$STUBDIR/curl.log"
url="" out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    https://*|http://*|file://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
cp "$REPO_ROOT/test/fixtures/installer/\${url##*/}" "\$out"
SHIM
  chmod +x "$STUBDIR/curl"
}

@test "installer: a remote source is fetched over HTTPS with TLS 1.2 or newer only" {
  _plant_logging_curl
  run sh "$REPO_ROOT/install.sh" --source https://example.invalid/rel --yes
  assert_success
  [ -e "$(_install_dir)/acq" ]
  run cat "$STUBDIR/curl.log"
  assert_equal "$(grep -c . "$STUBDIR/curl.log")" 3
  # Every download restricts the protocol, redirects included, and the TLS floor.
  assert_equal "$(grep -c -- "--proto =https --proto-redir =https --tlsv1.2 https://example.invalid/rel/" "$STUBDIR/curl.log")" 3
  # The dry-run plan shows the same restriction.
  run sh "$REPO_ROOT/install.sh" --source https://example.invalid/rel --dry-run
  assert_success
  assert_output --partial "curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 https://example.invalid/rel/SHA256SUMS"
}

@test "installer: a plaintext http:// source is refused before any download" {
  _plant_logging_curl
  run sh "$REPO_ROOT/install.sh" --source http://example.invalid/rel --yes
  assert_failure 2
  assert_output --partial "refusing a plaintext http:// source 'http://example.invalid/rel'"
  [ ! -e "$STUBDIR/curl.log" ]
  [ ! -e "$(_install_dir)" ]
  ACQ_INSTALL_SOURCE=http://example.invalid/rel run sh "$REPO_ROOT/install.sh" --dry-run
  assert_failure 2
  assert_output --partial 'refusing a plaintext http:// source'
}

# file:// names a local offline set; the HTTPS-only restriction would make the
# real curl refuse it, so it must not be applied there.
@test "installer: a file:// source still installs with the real curl" {
  command -v curl >/dev/null 2>&1 || skip "curl not available"
  run sh "$REPO_ROOT/install.sh" --source "file://$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ -e "$(_install_dir)/py-acq/runtime/bin/python3" ]
}

# --- staging beside the install dir (same filesystem, so every move is a rename)

# An mv stand-in that logs each source path before running the real mv.
_plant_logging_mv() {
  mkdir -p "$STUBDIR/mv-log-shim"
  cat > "$STUBDIR/mv-log-shim/mv" <<SHIM
#!/bin/sh
printf '%s\n' "\$1" >> "$STUBDIR/mv.log"
exec /bin/mv "\$@"
SHIM
  chmod +x "$STUBDIR/mv-log-shim/mv"
}

@test "installer: stages the release beside the install dir, not under TMPDIR" {
  _plant_logging_mv
  mkdir -p "$STUBDIR/tmp"
  TMPDIR="$STUBDIR/tmp" PATH="$STUBDIR/mv-log-shim:$PATH" \
    run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ -e "$(_install_dir)/py-acq/runtime/bin/python3" ]
  run cat "$STUBDIR/mv.log"
  # Each release entry moves from a staging dir in the install dir's parent.
  # The staging dir is named .acq-stage.<installer pid>.<random>.
  assert_line --regexp "^$XDG_DATA_HOME/\\.acq-stage\\.[0-9]+\\.[A-Za-z0-9]+/stage/(.*/)?py-acq\$"
  assert_line --regexp "^$XDG_DATA_HOME/\\.acq-stage\\.[0-9]+\\.[A-Za-z0-9]+/stage/(.*/)?acq\$"
  refute_output --partial "$STUBDIR/tmp/"
  # The staging dir is gone afterwards.
  [ -z "$(find "$XDG_DATA_HOME" -maxdepth 1 -name '.acq-stage.*')" ]
}

@test "installer: stages in the private work dir when the parent is not writable" {
  [ "$(id -u)" != 0 ] || skip "root can write a read-only directory"
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir"
  chmod 555 "$XDG_DATA_HOME"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  chmod 755 "$XDG_DATA_HOME"
  assert_success
  assert_output --partial "cannot create a staging directory in $XDG_DATA_HOME"
  [ -e "$dir/py-acq/runtime/bin/python3" ]
}

# Under `curl | sh` the installer's stdin is the script pipe. The PATH prompt then
# goes to the controlling terminal, and only when that terminal is usable;
# otherwise it declines as before. install-tty.py drives a pseudo-terminal.
_tty_install() {
  command -v python3 >/dev/null 2>&1 || skip "python3 is required to drive a pseudo-terminal"
  run env SHELL=/bin/sh python3 "$BATS_TEST_DIRNAME/install-tty.py" "$@" "$REPO_ROOT/install.sh" \
    --source "$REPO_ROOT/test/fixtures/installer" --install-dir "$STUBDIR/inst" \
    --bin-dir "$STUBDIR/acq-bin"
}

@test "installer: curl | sh asks for PATH consent on the terminal" {
  _tty_install tty y
  assert_success
  assert_line 'PROMPTS=1'
  grep -qF "export PATH=\"$STUBDIR/acq-bin:\$PATH\"" "$HOME/.profile"
}

@test "installer: curl | sh keeps PATH unchanged when the terminal answers no" {
  _tty_install tty n
  assert_success
  assert_line 'PROMPTS=1'
  assert_output --partial 'Not changing your PATH'
  [ ! -e "$HOME/.profile" ]
}

@test "installer: curl | sh never prompts when its output is captured" {
  # A controlling terminal exists, but stdout and stderr go to a file, so no one
  # is watching: the installer must decline without writing a prompt to it.
  _tty_install captured
  assert_success
  assert_line 'PROMPTS=0'
  assert_output --partial 'Not changing your PATH'
  [ ! -e "$HOME/.profile" ]
}

@test "installer: curl | sh declines without asking when /dev/tty is unusable" {
  _tty_install notty
  assert_success
  assert_line 'PROMPTS=0'
  assert_output --partial 'Not changing your PATH'
  [ ! -e "$HOME/.profile" ]
}

# The verified archive is staged in a private work dir: another local user must
# not be able to pre-create or swap it between verify and extract (a predictable
# name plus `mkdir -p` would adopt their directory).
@test "installer: verifies the archive inside a private, unpredictable work dir" {
  local shim="$STUBDIR/sum-shim" log="$STUBDIR/sum.log" real
  mkdir -p "$shim"
  for tool in sha256sum shasum; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    cat > "$shim/$tool" <<SHIM
#!/bin/sh
for f; do :; done
d=\$(dirname "\$f")
printf '%s %s\n' "\$(ls -ld "\$d" | cut -c1-10)" "\${d##*/}" >> "$log"
exec "$real" "\$@"
SHIM
    chmod +x "$shim/$tool"
  done
  PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  run cat "$log"
  assert_output --regexp '^drwx------ acq-install\.'
  # The suffix is random (mktemp), not the installer's PID.
  refute_output --regexp 'acq-install\.[0-9]+$'
}

@test "installer: an interrupt cannot let a re-created work dir be installed" {
  # Models a local attacker: after an interrupt deletes the private work dir,
  # they re-create its (now known) path with a poisoned archive. The installer
  # must exit on the signal instead of carrying on and extracting it.
  # The attacker plants every file the installer reads after verification (the
  # archive and the public provenance manifest), so only the signal exit stops it.
  # The hook is the staging dir's creation (beside the install dir); the work dir
  # it re-creates is the private one under TMPDIR that holds the archive. The
  # attacker gives up after five seconds, so a regression fails instead of hanging.
  local shim="$STUBDIR/race-shim" evil="$STUBDIR/evil" real_mkdir real_tar a w
  real_mkdir="$(command -v mkdir)"; real_tar="$(command -v tar)"
  mkdir -p "$shim" "$evil" "$STUBDIR/tmp"
  for a in "$REPO_ROOT"/test/fixtures/installer/*.tar.gz; do
    w="$STUBDIR/repack"; rm -rf "$w"; mkdir -p "$w"
    tar -xzf "$a" -C "$w"; : > "$w/PWNED"
    (cd "$w" && tar -czf "$evil/${a##*/}" .)
  done
  cat > "$shim/mkdir" <<SHIM
#!/bin/sh
for last; do :; done
case "\$last" in
  */.acq-stage.*/stage)
    r=\${last%/stage}
    for t in "$STUBDIR/tmp"/acq-install.*; do :; done
    ( n=0
      while [ -d "\$t" ] || [ -d "\$r" ]; do
        n=\$((n + 1)); [ "\$n" -le 250 ] || exit 0
        sleep 0.02
      done
      "$real_mkdir" -p "\$t" "\$r/stage"
      cp "$evil"/*.tar.gz "$REPO_ROOT/test/fixtures/installer/provenance.json" "\$t/" ) &
    kill -INT \$PPID ;;
esac
exec "$real_mkdir" "\$@"
SHIM
  cat > "$shim/tar" <<SHIM
#!/bin/sh
sleep 0.5
exec "$real_tar" "\$@"
SHIM
  chmod +x "$shim/mkdir" "$shim/tar"
  TMPDIR="$STUBDIR/tmp" PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  [ ! -e "$(_install_dir)/PWNED" ]
  [ ! -e "$(_install_dir)/acq" ]
}

# --- relative user directories (XDG Base Directory: absolute values only) -------

# Stub `id` and `getent` so the account-home fallback resolves to $1, or finds
# nothing when $1 is empty.
_plant_account_home() {
  cat >"$STUBDIR/id" <<'IDSTUB'
#!/bin/sh
case "$1" in -u) echo 4199999 ;; *) echo acq-installer-test ;; esac
IDSTUB
  if [ -n "${1:-}" ]; then
    printf '#!/bin/sh\n[ "$1 $2" = "passwd 4199999" ] && echo "acq-installer-test:x:4199999:4199999::%s:/bin/sh"\n' "$1" >"$STUBDIR/getent"
  else
    printf '#!/bin/sh\nexit 2\n' >"$STUBDIR/getent"
  fi
  chmod +x "$STUBDIR/id" "$STUBDIR/getent"
}

@test "installer: a relative XDG_DATA_HOME is ignored for the default install dir" {
  local work="$STUBDIR/work"
  mkdir -p "$work"
  cd "$work" || return 1
  run env XDG_DATA_HOME=rel-data sh "$REPO_ROOT/install.sh" --dry-run --bin-dir "$STUBDIR/bin"
  assert_success
  assert_line "  install dir: $HOME/.local/share/acq"
  refute_output --partial 'rel-data'
  run ls -A "$work"
  assert_output ''
}

@test "installer: a relative HOME falls back to the account home" {
  local work="$STUBDIR/work"
  mkdir -p "$work"
  cd "$work" || return 1
  _plant_account_home "$STUBDIR/acct-home"
  run env -u XDG_DATA_HOME HOME=relhome sh "$REPO_ROOT/install.sh" --dry-run --install-dir "$STUBDIR/inst"
  assert_success
  assert_line "  launcher:    $STUBDIR/acct-home/.local/bin/acq"
  refute_output --partial 'relhome'
  run ls -A "$work"
  assert_output ''
}

# The launcher symlink points at "$INSTALL_DIR/acq"; a relative target would
# resolve against the bin dir, not the directory the installer ran in, so a
# relative install dir is refused before anything is written.
@test "installer: a relative --install-dir or ACQ_INSTALL_DIR is refused" {
  local work="$STUBDIR/work"
  mkdir -p "$work"
  cd "$work" || return 1
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes \
    --install-dir rel-inst --bin-dir "$STUBDIR/bin"
  assert_failure 1
  assert_output --partial "--install-dir must be an absolute path, got 'rel-inst'"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes \
    --install-dir=rel-inst --bin-dir "$STUBDIR/bin"
  assert_failure 1
  assert_output --partial "--install-dir must be an absolute path"
  run env ACQ_INSTALL_DIR=rel-inst sh "$REPO_ROOT/install.sh" \
    --source "$REPO_ROOT/test/fixtures/installer" --yes --bin-dir "$STUBDIR/bin"
  assert_failure 1
  assert_output --partial "ACQ_INSTALL_DIR must be an absolute path, got 'rel-inst'"
  # The refused value is echoed with control characters replaced.
  run sh "$REPO_ROOT/install.sh" --dry-run --install-dir $'rel\033]0;t\007x' --bin-dir "$STUBDIR/bin"
  assert_failure 1
  assert_output --partial "got 'rel?]0;t?x'"
  refute_output --partial $'\033'
  # An absolute --install-dir overrides a relative ACQ_INSTALL_DIR.
  run env ACQ_INSTALL_DIR=rel-inst sh "$REPO_ROOT/install.sh" --dry-run \
    --install-dir "$STUBDIR/inst" --bin-dir "$STUBDIR/bin"
  assert_success
  assert_line "  install dir: $STUBDIR/inst"
  [ ! -e "$STUBDIR/bin" ]
  run ls -A "$work"
  assert_output ''
}

# A relative bin dir would put the launcher links under the directory the
# installer ran in, so it is refused before anything is written.
@test "installer: a relative --bin-dir or ACQ_INSTALL_BIN_DIR is refused" {
  local work="$STUBDIR/work"
  mkdir -p "$work"
  cd "$work" || return 1
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes \
    --install-dir "$STUBDIR/inst" --bin-dir rel-bin
  assert_failure 1
  assert_output --partial "--bin-dir must be an absolute path, got 'rel-bin'"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes \
    --install-dir "$STUBDIR/inst" --bin-dir=rel-bin
  assert_failure 1
  assert_output --partial "--bin-dir must be an absolute path"
  run env ACQ_INSTALL_BIN_DIR=rel-bin sh "$REPO_ROOT/install.sh" \
    --source "$REPO_ROOT/test/fixtures/installer" --yes --install-dir "$STUBDIR/inst"
  assert_failure 1
  assert_output --partial "ACQ_INSTALL_BIN_DIR must be an absolute path, got 'rel-bin'"
  # The refused value is echoed with control characters replaced.
  run sh "$REPO_ROOT/install.sh" --dry-run --install-dir "$STUBDIR/inst" --bin-dir $'rel\033]0;t\007x'
  assert_failure 1
  assert_output --partial "got 'rel?]0;t?x'"
  refute_output --partial $'\033'
  [ ! -e "$STUBDIR/inst" ]
  # An absolute --bin-dir overrides a relative ACQ_INSTALL_BIN_DIR.
  run env ACQ_INSTALL_BIN_DIR=rel-bin sh "$REPO_ROOT/install.sh" --dry-run \
    --install-dir "$STUBDIR/inst" --bin-dir "$STUBDIR/bin"
  assert_success
  assert_line "  launcher:    $STUBDIR/bin/acq"
  run ls -A "$work"
  assert_output ''
}

@test "installer: a relative TMPDIR is ignored for the private work dir" {
  local work="$STUBDIR/work"
  mkdir -p "$work"
  cd "$work" || return 1
  run env TMPDIR=rel-tmp sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes \
    --install-dir "$STUBDIR/inst" --bin-dir "$STUBDIR/bin"
  assert_success
  [ -e "$STUBDIR/inst/py-acq/runtime/bin/python3" ]
  run ls -A "$work"
  assert_output ''
}

@test "installer: with no absolute home it stops after option parsing" {
  local work="$STUBDIR/work"
  mkdir -p "$work"
  cd "$work" || return 1
  _plant_account_home ""
  run env HOME=relhome sh "$REPO_ROOT/install.sh" --dry-run --install-dir "$STUBDIR/inst" --bin-dir "$STUBDIR/bin"
  assert_failure 1
  assert_output --partial "cannot determine an absolute home directory (HOME is 'relhome')"
  run env HOME=relhome sh "$REPO_ROOT/install.sh" --help
  assert_success
  run ls -A "$work"
  assert_output ''
}
