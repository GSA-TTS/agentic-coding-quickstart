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

@test "installer: never elevates (no elevation invocation)" {
  # The installer documents non-elevation ("no sudo") in comments and --help
  # prose; that wording must not read as an invocation, but a real elevation
  # command (a line whose first word is sudo/pkexec/runas, or an osascript
  # "with administrator privileges") must be caught.
  grep -q 'no sudo' "$REPO_ROOT/install.sh" || fail "documentation of non-elevation missing"

  run grep -nE '^[[:space:]]*(sudo|pkexec|runas)[[:space:]]|osascript .*with administrator privileges' \
    "$REPO_ROOT/install.sh"
  assert_failure
}

@test "installer: never dumps the environment or hardcodes a secret" {
  run grep -E 'printenv|API_KEY=|TOKEN=|PASSWORD=|SECRET=' "$REPO_ROOT/install.sh"
  assert_failure
}

# The default install dir ($XDG_DATA_HOME/acq) is also where the legacy Bash acq
# keeps its file-fallback secret store and provider-input-validator runtime, and
# --install-dir can name any directory. The installer must never delete content
# it did not create.

# Copy the offline fixture and add an extra top-level entry to every archive,
# regenerating SHA256SUMS, to model a future release that ships a new name.
_fixture_with_extra_entry() {
  local name="$1" out="$STUBDIR/assets-extra" a work
  mkdir -p "$out"
  cp "$REPO_ROOT/test/fixtures/installer/provenance.json" "$out/"
  for a in "$REPO_ROOT"/test/fixtures/installer/*.tar.gz; do
    work="$STUBDIR/repack"; rm -rf "$work"; mkdir -p "$work"
    tar -xzf "$a" -C "$work"
    mkdir -p "$work/$name"; printf 'shipped\n' > "$work/$name/README"
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
  */acq-install.*/stage)
    t=\${last%/stage}
    ( while [ -d "\$t" ]; do sleep 0.02; done
      "$real_mkdir" -p "\$t/stage"
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
