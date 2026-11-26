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
  export ACQ_INSTALL_CHANNEL=python ACQ_INSTALL_VERSION=5.0.0-rc.1
  unset ACQ_INSTALL_DIR ACQ_INSTALL_BIN_DIR ACQ_INSTALL_SOURCE
}

teardown() {
  acq_teardown_stubs
}

_install_dir() {
  printf '%s/acq-python-preview' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

_tty_install() {
  run env SHELL=/bin/sh python3 "$BATS_TEST_DIRNAME/install-tty.py" "$@" "$REPO_ROOT/install.sh" \
    --source "$REPO_ROOT/test/fixtures/installer" --install-dir "$STUBDIR/inst" \
    --bin-dir "$STUBDIR/acq-bin"
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
  [ ! -e "$HOME/.local/bin/acq" ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "installer: a checksum mismatch fails closed (exit 1, no install)" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer-bad" --yes
  assert_failure
  assert_output --partial 'checksum mismatch'
  [ ! -e "$(_install_dir)" ]
}

@test "installer: a SHA256SUMS entry must name the archive exactly" {
  # A decoy whose name only contains the archive's name (a signature, another
  # build) comes first; its hash must not be taken for the archive's.
  local src="$STUBDIR/assets-decoy" zeros
  zeros=$(printf '0%.0s' $(seq 64))
  cp -R "$REPO_ROOT/test/fixtures/installer" "$src"
  awk -v z="$zeros" '{ print z "  " $2 ".sig"; print z "  x-" $2; print }' \
    "$REPO_ROOT/test/fixtures/installer/SHA256SUMS" > "$src/SHA256SUMS"
  run sh "$REPO_ROOT/install.sh" --source "$src" --yes
  assert_success
  assert_output --regexp 'verified acq-(macos|linux)-(arm64|x86_64|aarch64)\.tar\.gz'
  # CRLF line endings (a SHA256SUMS saved on Windows) still match exactly.
  awk '{ printf "%s\r\n", $0 }' "$REPO_ROOT/test/fixtures/installer/SHA256SUMS" > "$src/SHA256SUMS"
  rm -rf "$(_install_dir)"; rm -f "$HOME/.local/bin/acq-python"
  run sh "$REPO_ROOT/install.sh" --source "$src" --yes
  assert_success
  # With only decoys left, the archive has no entry and nothing is installed.
  awk -v z="$zeros" '{ print z "  " $2 ".sig"; print z "  x-" $2 }' \
    "$REPO_ROOT/test/fixtures/installer/SHA256SUMS" > "$src/SHA256SUMS"
  rm -rf "$(_install_dir)"; rm -f "$HOME/.local/bin/acq-python"
  run sh "$REPO_ROOT/install.sh" --source "$src" --yes
  assert_failure
  [ ! -e "$(_install_dir)/py-acq" ]
}

@test "preview: refuses an unowned mount-like existing root before writes" {

  mkdir -p "$(_install_dir)"
  printf 'keep\n' > "$(_install_dir)/mount-content"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 'without a matching preview receipt'
  [ "$(cat "$(_install_dir)/mount-content")" = keep ]
}

@test "installer: provenance.json is verified against SHA256SUMS" {
  local src="$STUBDIR/assets-prov"
  cp -R "$REPO_ROOT/test/fixtures/installer" "$src"
  printf '{"tampered": true}\n' > "$src/provenance.json"
  run sh "$REPO_ROOT/install.sh" --source "$src" --yes
  assert_failure
  assert_output --partial "checksum mismatch for provenance.json"
  [ ! -e "$(_install_dir)" ]
  cp "$REPO_ROOT/test/fixtures/installer/provenance.json" "$src/provenance.json"
  grep -v ' provenance.json$' "$REPO_ROOT/test/fixtures/installer/SHA256SUMS" > "$src/SHA256SUMS"
  run sh "$REPO_ROOT/install.sh" --source "$src" --yes
  assert_failure
  assert_output --partial "no entry for provenance.json"
  [ ! -e "$(_install_dir)" ]
}

@test "installer: consent is never inferred non-interactively" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer"
  assert_success
  assert_output --partial 'PATH and shell profiles were not changed'
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
  (cd "$out" && for a in *.tar.gz provenance.json; do
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$a"; else shasum -a 256 "$a"; fi
  done) > "$out/SHA256SUMS"
  printf '%s' "$out"
}

@test "preview: owned reinstall preserves unrelated content" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/secrets" "$dir/provider-input-validator"
  printf 'keep\n' > "$dir/secrets/acq.usai"
  printf 'keep\n' > "$dir/provider-input-validator/marker"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/secrets/acq.usai")" = keep ]
  [ "$(cat "$dir/provider-input-validator/marker")" = keep ]
  grep -q 'channel=python' "$dir/.acq-python-preview-receipt"
  ! grep -q 'secrets' "$dir/.acq-python-preview-files"
}

@test "installer: refuses to overwrite an entry it did not create (legacy clone)" {
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.git"
  printf '#!/bin/sh\necho legacy\n' > "$dir/acq"
  printf 'local change\n' > "$dir/mine.txt"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 'without a matching preview receipt'
  [ ! -e "$(_install_dir)/py-acq" ]
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
  assert_output --partial 'contains a symlink'
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --install-dir "$dir/" --yes
  assert_failure
  assert_output --partial 'contains a symlink'
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
  [ -e "$dir/py-acq/stale-from-old-release" ]
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
  assert_output --partial 'unknown entry: secrets'
  [ "$(cat "$dir/secrets/acq.usai")" = REAL-USER-SECRET ]
}

@test "preview: interrupted first publication is retryable" {

  local shim="$STUBDIR/fail-mv"; mkdir "$shim"
  printf '#!/bin/sh\ncase "$1" in */publish) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$shim/mv"
  chmod +x "$shim/mv"
  PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  [ ! -e "$(_install_dir)" ]
  [ ! -L "$HOME/.local/bin/acq-python" ]
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ -f "$(_install_dir)/.acq-python-preview-receipt" ]
}

@test "preview: preserves unknown legacy leftover .acq-previous.mine" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-previous.mine"
  printf 'unknown\n' > "$dir/.acq-previous.mine/preserve"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-previous.mine/preserve")" = unknown ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "preview: preserves unknown legacy leftover .acq-v1-install.tmp.12345" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-v1-install.tmp.12345"
  printf 'unknown\n' > "$dir/.acq-v1-install.tmp.12345/preserve"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-v1-install.tmp.12345/preserve")" = unknown ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "preview: preserves unknown legacy leftover .acq-v1-install.tmp.mine" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-v1-install.tmp.mine"
  printf 'unknown\n' > "$dir/.acq-v1-install.tmp.mine/preserve"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-v1-install.tmp.mine/preserve")" = unknown ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

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
@test "preview: preserves unknown legacy leftover .acq-previous.12345" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-previous.12345"
  printf 'unknown\n' > "$dir/.acq-previous.12345/preserve"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-previous.12345/preserve")" = unknown ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "preview: preserves unknown legacy leftover .acq-previous.1" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-previous.1"
  printf 'unknown\n' > "$dir/.acq-previous.1/preserve"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-previous.1/preserve")" = unknown ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "preview: preserves unknown legacy leftover .acq-stage.12345.AbCdEf" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-stage.12345.AbCdEf"
  printf 'unknown\n' > "$dir/.acq-stage.12345.AbCdEf/preserve"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-stage.12345.AbCdEf/preserve")" = unknown ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

@test "preview: preserves unknown legacy leftover .acq-stage.readonly" {
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  local dir; dir="$(_install_dir)"
  mkdir -p "$dir/.acq-stage.readonly"
  printf 'unknown\n' > "$dir/.acq-stage.readonly/preserve"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ "$(cat "$dir/.acq-stage.readonly/preserve")" = unknown ]
  [ -L "$HOME/.local/bin/acq-python" ]
}

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
  assert_output --partial 'contains a symlink'
  [ ! -e "$STUBDIR/tar-ran" ]
  [ -z "$(find "$XDG_DATA_HOME" -maxdepth 1 -name '.acq-stage.*')" ]
}

@test "preview: failed atomic publication leaves no public command" {

  local shim="$STUBDIR/fail-mv"; mkdir "$shim"
  printf '#!/bin/sh\ncase "$1" in */publish) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$shim/mv"
  chmod +x "$shim/mv"
  PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  [ ! -e "$(_install_dir)" ]
  [ ! -L "$HOME/.local/bin/acq-python" ]
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ -f "$(_install_dir)/.acq-python-preview-receipt" ]
}

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

@test "preview: a failed link enumeration refuses publication" {
  local shim; shim="$STUBDIR/find-failure"; mkdir -p "$shim"
  cat > "$shim/find" <<'SHIM'
#!/bin/sh
case " $* " in *' -type l '*) printf 'injected link enumeration failure\n' >&2; exit 1 ;; esac
exec /usr/bin/find "$@"
SHIM
  chmod +x "$shim/find"
  PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 'could not enumerate preview archive links'
  [ ! -e "$(_install_dir)" ]
  [ ! -e "$HOME/.local/bin/acq-python" ]
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

@test "preview: publishes complete root by same-filesystem rename" {

  _plant_logging_mv
  PATH="$STUBDIR/mv-log-shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  grep -Eq '^.*/\.acq-stage\.[0-9]+\.[A-Za-z0-9]+/publish$' "$STUBDIR/mv.log"
  [ -f "$(_install_dir)/.acq-python-preview-receipt" ]
  [ -e "$(_install_dir)/py-acq/runtime/bin/python3" ]
}

@test "preview: refuses publication without same-filesystem staging" {

  local shim="$STUBDIR/fail-stage"; mkdir "$shim"
  printf '#!/bin/sh\ncase "$*" in *acq-stage*) exit 1 ;; esac\nexec /usr/bin/mktemp "$@"\n' > "$shim/mktemp"
  chmod +x "$shim/mktemp"
  PATH="$shim:$PATH" run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_failure
  assert_output --partial 'same-filesystem staging'
  [ ! -e "$(_install_dir)" ]
}

@test "preview: piped install leaves shell profiles unchanged with consent yes" {

  _tty_install tty y
  assert_success
  assert_line 'PROMPTS=0'
  [ ! -e "$HOME/.profile" ]
  [ -L "$STUBDIR/acq-bin/acq-python" ]
  [ ! -e "$STUBDIR/acq-bin/acq" ]
}

@test "preview: piped install leaves shell profiles unchanged with consent no" {

  _tty_install tty n
  assert_success
  assert_line 'PROMPTS=0'
  [ ! -e "$HOME/.profile" ]
  [ -L "$STUBDIR/acq-bin/acq-python" ]
  [ ! -e "$STUBDIR/acq-bin/acq" ]
}

@test "preview: piped install leaves shell profiles unchanged with captured output" {

  _tty_install captured
  assert_success
  assert_line 'PROMPTS=0'
  [ ! -e "$HOME/.profile" ]
  [ -L "$STUBDIR/acq-bin/acq-python" ]
  [ ! -e "$STUBDIR/acq-bin/acq" ]
}

@test "preview: piped install leaves shell profiles unchanged with unusable terminal" {

  _tty_install notty
  assert_success
  assert_line 'PROMPTS=0'
  [ ! -e "$HOME/.profile" ]
  [ -L "$STUBDIR/acq-bin/acq-python" ]
  [ ! -e "$STUBDIR/acq-bin/acq" ]
}

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
  assert_line "  install dir: $HOME/.local/share/acq-python-preview"
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
  assert_line "  launcher:    $STUBDIR/acct-home/.local/bin/acq-python"
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
  assert_line "  launcher:    $STUBDIR/bin/acq-python"
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

@test "installer: SHA256SUMS pin matches case-insensitively for offline assets" {
  local pin
  pin=$(sha256sum "$REPO_ROOT/test/fixtures/installer/SHA256SUMS" | cut -d' ' -f1 | tr 'a-f' 'A-F')
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --sha256 "$pin" --yes
  assert_success
  assert_output --partial 'verified SHA256SUMS pin'
  [ ! -e "$HOME/.local/bin/acq" ]
}

@test "installer: SHA256SUMS pin mismatch fails before trusting manifest entries" {
  local pin
  pin=$(printf '%064d' 0)
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --sha256 "$pin" --yes
  assert_failure 1
  assert_output --partial 'SHA256SUMS pin mismatch'
  refute_output --partial 'verified acq-'
  [ ! -e "$(_install_dir)" ]
  [ ! -e "$HOME/.local/bin" ]
}

@test "installer: malformed or empty SHA256SUMS pins are usage errors" {
  local pin
  for pin in '' abc "$(printf '%065d' 0)" "g$(printf '%063d' 0)" "$(printf '%063d' 0)"; do
    run sh "$REPO_ROOT/install.sh" --sha256 "$pin" --dry-run
    assert_failure 2
    assert_output --partial '64 hex characters'
  done
  run sh "$REPO_ROOT/install.sh" --sha256
  assert_failure 2
  [ ! -e "$(_install_dir)" ]
}

_plant_attestation_gh() {
  cat > "$STUBDIR/gh" <<'SHIM'
#!/bin/sh
case "$*" in
  *--help*) [ "$GH_RESULT" = old ] && { echo 'unknown command "attestation" for "gh"' >&2; exit 1; }; exit 0 ;;
esac
printf '%s\n' "$*" >> "$STUBDIR/gh.log"
case "$GH_RESULT" in
  success) echo 'Verification succeeded'; exit 0 ;;
  absent-ok) echo 'Warning: no attestations found' >&2; exit 0 ;;
  silent-ok) exit 0 ;;
  absent) echo 'no attestations found' >&2; exit 1 ;;
  failed) echo 'Verification FAILED: signature invalid' >&2; exit 1 ;;
  transport) echo 'connection refused' >&2; exit 1 ;;
esac
SHIM
  chmod +x "$STUBDIR/gh"
  export STUBDIR
  _plant_logging_curl
}

@test "installer: GitHub archive attestation succeeds with PATH-overridden gh" {
  _plant_attestation_gh
  GH_RESULT=success run sh "$REPO_ROOT/install.sh" --source https://github.com/example/acq/releases/download/v1 --yes
  assert_success
  assert_output --partial 'verified attestation'
  grep -Eq '^attestation verify .*acq-.*tar.gz --repo example/acq$' "$STUBDIR/gh.log"
}

@test "installer: absent GitHub archive attestation is informational" {
  _plant_attestation_gh
  local result
  # absent-ok: some gh releases warn about missing attestations yet exit 0.
  for result in absent absent-ok; do
    rm -rf "$(_install_dir)"; rm -f "$HOME/.local/bin/acq-python"
    GH_RESULT="$result" run sh "$REPO_ROOT/install.sh" --source https://github.com/example/acq/releases/download/v1 --yes
    assert_success
    assert_output --partial 'attestation absent'
    refute_output --partial 'verified attestation'
    [ -e "$(_install_dir)/acq" ]
  done
}

@test "installer: a gh without the attestation command is no verifier" {
  _plant_attestation_gh
  GH_RESULT=old run sh "$REPO_ROOT/install.sh" --source https://github.com/example/acq/releases/download/v1 --yes
  assert_success
  assert_output --partial "no 'attestation' command"
  [ ! -e "$STUBDIR/gh.log" ]
}

@test "installer: failed attestation and unknown verifier errors fail closed" {
  _plant_attestation_gh
  local result
  # silent-ok: exit 0 without gh's success line is not proof of verification.
  for result in failed transport silent-ok; do
    GH_RESULT="$result" run sh "$REPO_ROOT/install.sh" --source https://github.com/example/acq/releases/download/v1 --yes
    assert_failure 1
    assert_output --partial 'attestation verification failed'
    [ ! -e "$(_install_dir)" ]
    [ ! -e "$HOME/.local/bin" ]
  done
}

@test "installer: attestation is skipped for local assets and when opted out" {
  _plant_attestation_gh
  GH_RESULT=failed run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$STUBDIR/gh.log" ]
  ACQ_INSTALL_NO_ATTESTATION=1 GH_RESULT=failed run sh "$REPO_ROOT/install.sh" --source https://github.com/example/acq/releases/download/v1 --yes
  assert_success
  [ ! -e "$STUBDIR/gh.log" ]
}

@test "preview: does not probe or modify existing backends" {

  printf '#!/bin/sh\necho called >> "%s/backend-probed"\nexit 1\n' "$STUBDIR" > "$STUBDIR/msb"
  chmod +x "$STUBDIR/msb"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$STUBDIR/backend-probed" ]
  [ ! -e "$HOME/.microsandbox" ]
  [ ! -e "$HOME/.profile" ]
}

@test "preview: leaves out-of-policy backend untouched" {

  printf '#!/bin/sh\necho called >> "%s/backend-probed"\nexit 1\n' "$STUBDIR" > "$STUBDIR/msb"
  chmod +x "$STUBDIR/msb"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$STUBDIR/backend-probed" ]
  [ ! -e "$HOME/.microsandbox" ]
  [ ! -e "$HOME/.profile" ]
}

@test "preview: noninteractive install never installs backends" {

  printf '#!/bin/sh\necho called >> "%s/backend-probed"\nexit 1\n' "$STUBDIR" > "$STUBDIR/msb"
  chmod +x "$STUBDIR/msb"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$STUBDIR/backend-probed" ]
  [ ! -e "$HOME/.microsandbox" ]
  [ ! -e "$HOME/.profile" ]
}

@test "installer: --no-prereq-check skips probes and the whole report" {
  printf '#!/bin/sh\necho invoked > "%s/msb.log"\n' "$STUBDIR" > "$STUBDIR/msb"
  chmod +x "$STUBDIR/msb"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --no-prereq-check --yes
  assert_success
  refute_output --partial 'Next steps'
  [ ! -e "$STUBDIR/msb.log" ]
}

@test "preview: terminal consent never installs backends" {

  printf '#!/bin/sh\necho called >> "%s/backend-probed"\nexit 1\n' "$STUBDIR" > "$STUBDIR/msb"
  chmod +x "$STUBDIR/msb"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$STUBDIR/backend-probed" ]
  [ ! -e "$HOME/.microsandbox" ]
  [ ! -e "$HOME/.profile" ]
}

@test "preview: piped install leaves shell profiles unchanged with noninteractive" {

  run env SHELL=/bin/sh python3 "$BATS_TEST_DIRNAME/install-tty.py" tty y "$REPO_ROOT/install.sh" \
    --source "$REPO_ROOT/test/fixtures/installer" --install-dir "$STUBDIR/inst" \
    --bin-dir "$STUBDIR/acq-bin" --non-interactive
  assert_success
  assert_line 'PROMPTS=0'
  [ ! -e "$HOME/.profile" ]
  [ -L "$STUBDIR/acq-bin/acq-python" ]
  [ ! -e "$STUBDIR/acq-bin/acq" ]
}

@test "installer: --non-interactive never offers msb on a terminal," {
  command -v python3 >/dev/null 2>&1 || skip "python3 is required to drive a pseudo-terminal"
  local python
  python=$(python3 -c 'import sys; print(sys.executable)')
  run "$python" "$BATS_TEST_DIRNAME/install-tty.py" tty y \
    "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --bin-dir "$STUBDIR/acq-bin" --non-interactive
  assert_success
  assert_line 'PROMPTS=0'
  refute_output --partial 'Install pinned msb?'
  [ ! -e "$STUBDIR/brew.log" ]
}

@test "installer: ACQ_INSTALL_NON_INTERACTIVE accepts 0 or 1 and refuses other values" {
  run env ACQ_INSTALL_NON_INTERACTIVE=1 sh "$REPO_ROOT/install.sh" --dry-run
  assert_success
  run env ACQ_INSTALL_NON_INTERACTIVE=maybe sh "$REPO_ROOT/install.sh" --dry-run
  assert_failure 2
  assert_output --partial 'ACQ_INSTALL_NON_INTERACTIVE must be 0 or 1'
}

@test "installer: --yes on a terminal never offers or installs msb" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is required to drive a pseudo-terminal"
  local python
  python=$(python3 -c 'import sys; print(sys.executable)')
  run "$python" "$BATS_TEST_DIRNAME/install-tty.py" tty y \
    "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --bin-dir "$STUBDIR/acq-bin" --yes
  assert_success
  assert_line 'PROMPTS=0'
  [ ! -e "$STUBDIR/brew.log" ]
}

@test "installer: missing gh reports unavailable and continues" {
  _plant_logging_curl
  mkdir "$STUBDIR/no-gh"
  local tool
  for tool in sh uname curl mktemp chmod cp cut sha256sum tar gzip find head grep sed awk tr dirname mkdir mv rm ln; do
    ln -s "$(command -v "$tool")" "$STUBDIR/no-gh/$tool"
  done
  PATH="$STUBDIR/no-gh" run sh "$REPO_ROOT/install.sh" --source https://github.com/example/acq/releases/download/v1 --yes
  assert_success
  assert_output --partial 'gh missing; continuing'
}

@test "preview: backend test overrides do not affect install" {

  printf '#!/bin/sh\necho called >> "%s/backend-probed"\nexit 1\n' "$STUBDIR" > "$STUBDIR/msb"
  chmod +x "$STUBDIR/msb"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$STUBDIR/backend-probed" ]
  [ ! -e "$HOME/.microsandbox" ]
  [ ! -e "$HOME/.profile" ]
}

@test "preview: explicit consent remains limited to preview files" {

  printf '#!/bin/sh\necho called >> "%s/backend-probed"\nexit 1\n' "$STUBDIR" > "$STUBDIR/msb"
  chmod +x "$STUBDIR/msb"
  run sh "$REPO_ROOT/install.sh" --source "$REPO_ROOT/test/fixtures/installer" --yes
  assert_success
  [ ! -e "$STUBDIR/backend-probed" ]
  [ ! -e "$HOME/.microsandbox" ]
  [ ! -e "$HOME/.profile" ]
}
