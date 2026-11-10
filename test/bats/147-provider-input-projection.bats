#!/usr/bin/env bats
# Provider inputs are validated as one set, published as immutable generations,
# and mounted without exposing the shared host-config directory.

setup() { acq_setup_stubs; unset ACQ_PROVIDER_INPUT_PYTHON; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "projection lock waits for missing or empty fresh owner metadata" {
  local kind root lock
  for kind in missing empty; do
    root=$(acq_provider_input_root sbx "fresh-$kind"); lock="${root}.lock"
    _acq_provider_input_safe_mkdir "$lock"
    [ "$kind" != empty ] || : > "$lock/owner"
    # Release at the first poll, deterministically modeling the holder's exit.
    sleep() { printf 'waited\n' > "$STUBDIR/waited"; rm -f "$lock/owner"; rmdir "$lock"; }
    ACQ_PROVIDER_INPUT_LOCK_RETRIES=3 run acq_provider_input_lock_acquire sbx "fresh-$kind"
    assert_success
    [ -f "$STUBDIR/waited" ]
    acq_provider_input_lock_release "$lock"
    rm "$STUBDIR/waited"
  done
}

@test "projection lock fresh empty metadata still exhausts its retry budget" {
  local root lock
  root=$(acq_provider_input_root sbx fresh-budget); lock="${root}.lock"
  _acq_provider_input_safe_mkdir "$lock"
  : > "$lock/owner"
  _acq_config_lock_age() { echo 0; }
  sleep() { :; }
  ACQ_PROVIDER_INPUT_LOCK_RETRIES=2 run acq_provider_input_lock_acquire sbx fresh-budget
  assert_failure
  assert_output --partial 'gave up waiting'
  [ -f "$lock/owner" ]
}

@test "lock tokens are written with noclobber still enabled" {
  local take lock
  for take in _acq_provider_input_lock_take _acq_config_lock_take; do
    lock="$STUBDIR/$take"
    run bash -c '
      ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1
      printf() { case "$-" in *C*) builtin printf "$@" ;; *) return 1 ;; esac; }
      "$2" "$3" "1 token"
    ' _ "$ACQ" "$take" "$lock"
    assert_success
    assert_equal "$(cat "$lock/owner")" '1 token'
  done
}

@test "lock takes refuse owner symlinks to devices and FIFOs before opening" {
  local take target lock
  mkfifo "$STUBDIR/owner-fifo"
  _racy_mkdir
  for take in _acq_provider_input_lock_take _acq_config_lock_take; do
    for target in /dev/null "$STUBDIR/owner-fifo"; do
      lock="$STUBDIR/link-lock"
      mkdir -p "$lock"
      ln -s "$target" "$lock/owner"
      run timeout 5 bash -c 'ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1; "$2" "$3" token' _ "$ACQ" "$take" "$lock"
      assert_failure 1
      [ -L "$lock/owner" ]
      rm "$lock/owner"; rmdir "$lock"
    done
  done
}

@test "lock takes refuse an owner replaced by a symlink during the write" {
  local take lock
  for take in _acq_provider_input_lock_take _acq_config_lock_take; do
    lock="$STUBDIR/$take"
    run bash -c '
      ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1
      lock=$3
      printf() { builtin printf "$@"; rm "$lock/owner"; ln -s /dev/null "$lock/owner"; }
      "$2" "$lock" token
    ' _ "$ACQ" "$take" "$lock"
    assert_failure 1
    [ -L "$lock/owner" ]
  done
}

@test "spinner draws no frame through a symlinked draw lock" {
  local dir="$STUBDIR/spin-link"
  mkdir "$dir"
  ln -s /dev/null "$dir/draw"
  run timeout 5 bash -c '
    ACQ_SCRIPT_DIR=$1
    . "$1/acq.backends/progress.sh"
    spin_fixture=$2
    _acq_progress_enabled() { return 0; }
    mktemp() { echo "$spin_fixture"; }
    sleep() { : > "$dir/stop"; }
    acq_spin_start SYMLINK-FRAME
    wait "$_ACQ_SPIN_PID"
    acq_spin_stop SAFE-END
  ' _ "$REPO_ROOT" "$dir"
  assert_success
  refute_output --partial SYMLINK-FRAME
}

@test "spinner shutdown refuses a symlinked draw lock" {
  local dir="$STUBDIR/spin-end-link"
  mkdir "$dir"
  ln -s /dev/null "$dir/draw"
  run timeout 5 bash -c '
    ACQ_SCRIPT_DIR=$1
    . "$1/acq.backends/progress.sh"
    _ACQ_SPIN_DIR=$2 _ACQ_SPIN_PID=999999 _ACQ_SPIN_FORKED=1
    kill() { [ -z "$_ACQ_SPIN_LOCKED" ] || echo UNSAFE-TAKE; return 1; }
    _acq_spin_end_animator
  ' _ "$REPO_ROOT" "$dir"
  assert_success
  refute_output --partial UNSAFE-TAKE
}

_provider_release() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/integrations/isolation/schemas"
  cat > "$root/provider-python" <<'PYTHON'
#!/bin/sh
[ "${1:-}" = -I ] && shift  # acq runs python -I (no cwd/env on sys.path)
if [ "$1" = -c ]; then exit 0; fi
exec /usr/bin/python3 "$@"
PYTHON
  chmod +x "$root/provider-python"
  export ACQ_PROVIDER_INPUT_PYTHON="$root/provider-python"
  printf '{"providers":{"alpha":"ALPHA_KEY","beta":"BETA_KEY"}}\n' > "$root/integrations/isolation/schemas/provider-credential-bindings.json"
  cat > "$root/scripts/validate_provider_input_contract.py" <<'PY'
import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ['VALIDATOR_LOG']).write_text('\n'.join(args))
bundles = [args[i + 1] for i, value in enumerate(args) if value == '--bundle']
providers = []
for bundle_path in bundles:
    bundle = json.loads(pathlib.Path(bundle_path).read_text())
    if bundle.get('marker') == 'REJECT': raise SystemExit(1)
    provider = bundle['providerId']
    if provider in providers: raise SystemExit(1)
    providers.append(provider)
PY
}

_provider_kit() {
  local release="$1" name="$2" marker="${3:-OK}" provider_id="${4:-$2}"
  local kit="$release/integrations/isolation/acq-kits/$name"
  mkdir -p "$kit/provider-input" "$kit/scripts" "$kit/files"
  printf '{"providerId":"%s","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/%s","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json","credentialEnvNames":["%s_KEY"],"marker":"%s"}\n' "$provider_id" "$provider_id" "$(printf '%s' "$provider_id" | tr '[:lower:]-' '[:upper:]_')" "$marker" > "$kit/provider-input.json"
  printf '{"providerId":"%s"}\n' "$provider_id" > "$kit/provider-input/facts.json"
  printf '#!/bin/sh\n' > "$kit/scripts/normalize"; chmod 755 "$kit/scripts/normalize"
  printf '{"providerId":"%s","models":[]}\n' "$provider_id" > "$kit/files/snapshot.json"
  printf 'caps:\n  network:\n    allow:\n      - %s.example.gov\n' "$provider_id" > "$kit/spec.yaml"
}

_use_release() {
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  _acq_provider_input_control_plane() { printf '%s\n' "$1"; }
}

@test "projection selects a configured validator runtime and rejects a missing one" {
  local python="$STUBDIR/provider-python" log="$STUBDIR/provider-python.log"
  cat > "$python" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$log"
exit 0
EOF
  chmod +x "$python"

  ACQ_PROVIDER_INPUT_PYTHON="$python" run _acq_provider_input_python
  assert_success
  assert_output "$python"
  grep -F -- '-c import importlib.metadata as m, sys' "$log"

  ACQ_PROVIDER_INPUT_PYTHON="$STUBDIR/missing-python" run _acq_provider_input_python
  assert_failure 2
  assert_output --partial 'configured provider-input Python is not executable'
}

@test "projection prefers the user-data validator runtime over a read-only install root" {
  local original_data_dir="${ACQ_PROVIDER_INPUT_DATA_DIR:-}" install_root="$STUBDIR/homebrew/libexec"
  export ACQ_PROVIDER_INPUT_DATA_DIR="$STUBDIR/user-data"
  mkdir -p "$install_root"; chmod 555 "$install_root"
  local runtime="$ACQ_PROVIDER_INPUT_DATA_DIR/provider-input-validator.current/bin"
  mkdir -p "$runtime"
  cat > "$runtime/python3" <<'EOF'
#!/bin/sh
[ "${1:-}" = -I ] && shift  # acq runs python -I (no cwd/env on sys.path)
if [ "$1" = -c ]; then exit 0; fi
exit 1
EOF
  chmod +x "$runtime/python3"

  run _acq_provider_input_python
  assert_success
  assert_output "$runtime/python3"
  ACQ_PROVIDER_INPUT_DATA_DIR="$original_data_dir"
}

@test "setup validator runtime is dry-run by default and pins dependencies" {
  run "$REPO_ROOT/scripts/setup-provider-input-validator"
  assert_success
  assert_output --partial '[dry-run]'
  grep -Fq 'PyYAML==6.0.3' "$REPO_ROOT/scripts/provider-input-validator-requirements-linux.txt"
  grep -Fq 'jsonschema==4.26.0' "$REPO_ROOT/scripts/provider-input-validator-requirements-linux.txt"
  grep -Fq -- '--hash=sha256:' "$REPO_ROOT/scripts/provider-input-validator-requirements-linux.txt"
  grep -Fq -- '--require-hashes' "$REPO_ROOT/scripts/setup-provider-input-validator"
}

@test "setup validator honors explicit bootstrap Python and online hash install" {
  local tools="$STUBDIR/online-data" fakebin="$STUBDIR/online-bin" log="$STUBDIR/online.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/python-custom" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$VALIDATOR_SETUP_LOG"
[ "${1:-}" = -I ] && shift  # acq runs python -I (no cwd/env on sys.path)
if [ "$1" = -c ]; then printf '3.14\n'; exit 0; fi
if [ "$1" = -m ] && [ "$2" = venv ]; then
  mkdir -p "$3/bin"; cp "$0" "$3/bin/python3"; exit 0
fi
if [ "$1" = -m ] && [ "$2" = pip ]; then exit 0; fi
if [ "$1" = - ] && [ "$#" -eq 3 ]; then exec /usr/bin/python3 "$@"; fi
if [ "$1" = - ]; then exit 0; fi
exit 0
EOF
  cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac
EOF
  chmod +x "$fakebin/python-custom" "$fakebin/uname"

  ACQ_PROVIDER_INPUT_BOOTSTRAP_PYTHON="$fakebin/python-custom" \
    ACQ_PROVIDER_INPUT_HOST_OS=Darwin ACQ_PROVIDER_INPUT_HOST_ARCH=arm64 \
    ACQ_PROVIDER_INPUT_DATA_DIR="$tools" VALIDATOR_SETUP_LOG="$log" \
    PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply --online
  assert_success
  [ -L "$tools/provider-input-validator.current" ]
  grep -Fq -- '--require-hashes' "$log"
  ! grep -Fq -- '--no-index' "$log"
}

@test "setup validator prefers a supported versioned Python before python3" {
  local fakebin="$STUBDIR/versioned-bin" log="$STUBDIR/versioned.log" tools="$STUBDIR/versioned-data"
  mkdir -p "$fakebin"
  cat > "$fakebin/python3.14" <<'EOF'
#!/bin/sh
printf 'selected-3.14 %s\n' "$*" >> "$VALIDATOR_SETUP_LOG"
[ "${1:-}" = -I ] && shift  # acq runs python -I (no cwd/env on sys.path)
if [ "$1" = -c ]; then printf '3.14\n'; exit 0; fi
if [ "$1" = -m ] && [ "$2" = venv ]; then
  mkdir -p "$3/bin"; cp "$0" "$3/bin/python3"; exit 0
fi
if [ "$1" = -m ] && [ "$2" = pip ]; then exit 0; fi
if [ "$1" = - ] && [ "$#" -eq 3 ]; then exec /usr/bin/python3 "$@"; fi
if [ "$1" = - ]; then exit 0; fi
exit 0
EOF
  cat > "$fakebin/python3" <<'EOF'
#!/bin/sh
printf 'wrong-python3\n' >> "$VALIDATOR_SETUP_LOG"
exit 1
EOF
  cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac
EOF
  chmod +x "$fakebin/python3.14" "$fakebin/python3" "$fakebin/uname"

  ACQ_PROVIDER_INPUT_HOST_OS=Darwin ACQ_PROVIDER_INPUT_HOST_ARCH=arm64 \
    ACQ_PROVIDER_INPUT_BOOTSTRAP_CANDIDATES=python3.14 \
    ACQ_PROVIDER_INPUT_DATA_DIR="$tools" VALIDATOR_SETUP_LOG="$log" \
    PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply --online
  assert_success
  [ -L "$tools/provider-input-validator.current" ]
  grep -Fq 'selected-3.14' "$log"
  ! grep -Fq 'wrong-python3' "$log"
}

@test "setup validator skips unsupported newer Python on Linux" {
  local fakebin="$STUBDIR/linux-versioned-bin" log="$STUBDIR/linux-versioned.log" tools="$STUBDIR/linux-data"
  mkdir -p "$fakebin"
  cat > "$fakebin/python3.14" <<'EOF'
#!/bin/sh
printf 'wrong-3.14\n' >> "$VALIDATOR_SETUP_LOG"
exit 1
EOF
  cat > "$fakebin/python3.12" <<'EOF'
#!/bin/sh
printf 'selected-3.12 %s\n' "$*" >> "$VALIDATOR_SETUP_LOG"
[ "${1:-}" = -I ] && shift  # acq runs python -I (no cwd/env on sys.path)
if [ "$1" = -c ]; then printf '3.12\n'; exit 0; fi
if [ "$1" = -m ] && [ "$2" = venv ]; then
  mkdir -p "$3/bin"; cp "$0" "$3/bin/python3"; exit 0
fi
if [ "$1" = -m ] && [ "$2" = pip ]; then exit 0; fi
if [ "$1" = - ] && [ "$#" -eq 3 ]; then exec /usr/bin/python3 "$@"; fi
if [ "$1" = - ]; then exit 0; fi
exit 0
EOF
  chmod +x "$fakebin/python3.14" "$fakebin/python3.12"

  ACQ_PROVIDER_INPUT_HOST_OS=Linux ACQ_PROVIDER_INPUT_HOST_ARCH=x86_64 \
    ACQ_PROVIDER_INPUT_DATA_DIR="$tools" VALIDATOR_SETUP_LOG="$log" \
    PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply --online
  assert_success
  grep -Fq 'selected-3.12' "$log"
  ! grep -Fq 'wrong-3.14' "$log"
}

@test "setup validator rejects invalid arguments without changing a runtime" {
  local target="$STUBDIR/user-data/provider-input-validator.current"
  mkdir -p "$target"
  printf 'working\n' > "$target/sentinel"
  ACQ_PROVIDER_INPUT_DATA_DIR="$STUBDIR/user-data" run "$REPO_ROOT/scripts/setup-provider-input-validator" --unexpected
  assert_failure 2
  [ -f "$target/sentinel" ]
}

@test "setup validator atomically replaces only a validated temporary runtime" {
  local tools="$STUBDIR/user-data" target="$STUBDIR/user-data/provider-input-validator.current"
  local fakebin="$STUBDIR/python-bin" log="$STUBDIR/python.log"
  local first_runtime second_runtime
  mkdir -p "$fakebin"
  mkdir -p "$STUBDIR/wheelhouse"
  : > "$STUBDIR/wheelhouse/placeholder.whl"
  (cd "$STUBDIR/wheelhouse" && sha256sum placeholder.whl > SHA256SUMS)
  cat > "$fakebin/python3" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$VALIDATOR_SETUP_LOG"
 [ "${1:-}" = -I ] && shift  # acq runs python -I (no cwd/env on sys.path)
 if [ "$1" = -c ]; then
   printf '3.12\n'
   exit 0
 fi
 if [ "$1" = -m ] && [ "$2" = venv ]; then
  mkdir -p "$3/bin"
  cp "$0" "$3/bin/python3"
  exit 0
fi
if [ "$1" = -m ] && [ "$2" = pip ]; then
  [ "${VALIDATOR_SETUP_FAIL:-}" != 1 ]
  exit
fi
 if [ "$1" = - ] && [ "$#" -eq 3 ]; then exec /usr/bin/python3 "$@"; fi
  if [ "$1" = - ]; then [ "${VALIDATOR_VALIDATE_FAIL:-}" != 1 ]; exit; fi
exit 0
EOF
  chmod +x "$fakebin/python3"

  ACQ_PROVIDER_INPUT_BOOTSTRAP_PYTHON="$fakebin/python3" ACQ_PROVIDER_INPUT_HOST_OS=Darwin ACQ_PROVIDER_INPUT_HOST_ARCH=arm64 ACQ_PROVIDER_INPUT_DATA_DIR="$tools" ACQ_PROVIDER_INPUT_WHEELHOUSE="$STUBDIR/wheelhouse" VALIDATOR_SETUP_LOG="$log" PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_success
  [ -L "$target" ]
  [ -x "$target/bin/python3" ]
  grep -Fq -- '--require-hashes' "$log"
  first_runtime=$(readlink "$target")

  ACQ_PROVIDER_INPUT_BOOTSTRAP_PYTHON="$fakebin/python3" ACQ_PROVIDER_INPUT_HOST_OS=Darwin ACQ_PROVIDER_INPUT_HOST_ARCH=arm64 ACQ_PROVIDER_INPUT_DATA_DIR="$tools" ACQ_PROVIDER_INPUT_WHEELHOUSE="$STUBDIR/wheelhouse" VALIDATOR_SETUP_LOG="$log" PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_success
  second_runtime=$(readlink "$target")
  [ "$second_runtime" != "$first_runtime" ]
  [ -x "$target/bin/python3" ]
  [ ! -e "$tools/$first_runtime" ]

  ACQ_PROVIDER_INPUT_BOOTSTRAP_PYTHON="$fakebin/python3" ACQ_PROVIDER_INPUT_HOST_OS=Darwin ACQ_PROVIDER_INPUT_HOST_ARCH=arm64 ACQ_PROVIDER_INPUT_DATA_DIR="$tools" ACQ_PROVIDER_INPUT_WHEELHOUSE="$STUBDIR/wheelhouse" VALIDATOR_SETUP_LOG="$log" VALIDATOR_VALIDATE_FAIL=1 PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_failure
  [ "$second_runtime" = "$(readlink "$target")" ]
  [ -x "$target/bin/python3" ]

}

@test "runtime resolver recognizes Windows venv layout" {
  local original_data_dir="${ACQ_PROVIDER_INPUT_DATA_DIR:-}" runtime
  export ACQ_PROVIDER_INPUT_DATA_DIR="$STUBDIR/windows-user-data"
  runtime="$ACQ_PROVIDER_INPUT_DATA_DIR/provider-input-validator.current/Scripts"
  mkdir -p "$runtime"
  cat > "$runtime/python.exe" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$runtime/python.exe"
  run _acq_provider_input_python
  assert_success
  assert_output "$runtime/python.exe"
  ACQ_PROVIDER_INPUT_DATA_DIR="$original_data_dir"
}

@test "validator lock files cover every released host and require hashes" {
  for lock in "$REPO_ROOT"/scripts/provider-input-validator-requirements-*.txt; do
    grep -Fq 'rpds-py==' "$lock"
    grep -Fq -- '--hash=sha256:' "$lock"
  done
  grep -Fq 'Linux x86_64/aarch64 Python 3.12' "$REPO_ROOT/scripts/provider-input-validator-requirements.txt"
  grep -Fq 'macOS Python 3.12-3.14' "$REPO_ROOT/scripts/provider-input-validator-requirements-macos.txt"
  grep -Fq 'Windows x86_64/arm64 Python 3.12' "$REPO_ROOT/scripts/provider-input-validator-requirements.txt"
}

@test "adapter projection seam contains unsafe names before cleanup" {
  local raw_parent sentinel root
  raw_parent="$ACQ_PROVENANCE_DIR/provider-input/msb"
  sentinel="$ACQ_PROVENANCE_DIR/provider-input/evil"
  mkdir -p "$raw_parent" "$sentinel"
  printf 'must-survive\n' > "$sentinel/sentinel"

  acq_test_stub_provider_input_boundary
  root=$(acq_provider_input_root msb '../evil')
  [[ "$root" == "$raw_parent/.._evil."* ]]
    acq_provider_input_prepare msb '../evil' >/dev/null
  acq_provider_input_remove msb '../evil'

  [ -f "$sentinel/sentinel" ]
  [ ! -e "$root" ]
}

@test "adapter projection seam is available in a child shell through BASH_ENV" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    root=$(acq_provider_input_root msb childbox) || exit 1
    generation=$(acq_provider_input_prepare msb childbox) || exit 1
    [ -d "$generation" ] || exit 1
    case "$(acq_provider_input_guest_root sbx childbox "$generation")" in */generations/generation.*) ;; *) exit 1 ;; esac
    host_path() { printf "%s\n" "/host$1"; }
    [ "$(acq_provider_input_msb_mount childbox "$generation")" = "/host$generation:/var/lib/acq/provider-input/${generation##*/}:ro" ]
  '

  assert_success
}

@test "failed validator dependency probe publishes nothing" {
  local release="$STUBDIR/release" root python="$STUBDIR/incompatible-python"
  _provider_release "$release"; _provider_kit "$release" alpha
  cat > "$python" <<EOF
#!/bin/sh
[ "\${1:-}" = -I ] && shift  # acq runs python -I (no cwd/env on sys.path)
if [ "\$1" = -c ]; then exit 2; fi
printf 'validator unexpectedly invoked\n' >> "$STUBDIR/validator-invoked"
exit 0
EOF
  chmod +x "$python"
  export ACQ_PROVIDER_INPUT_PYTHON="$python"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha")

  run acq_provider_input_prepare sbx incompatiblebox
  assert_failure 2
  root=$(acq_provider_input_root sbx incompatiblebox)
  [ ! -e "$root/current" ]
  [ ! -e "$STUBDIR/validator-invoked" ]
}

@test "projection prepares immutable generation without changing current" {
  local release="$STUBDIR/release" root current
  _provider_release "$release"; _provider_kit "$release" alpha; _provider_kit "$release" beta
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha" "$release/integrations/isolation/acq-kits/beta")

  run acq_provider_input_prepare msb projectionbox
  assert_success
  root=$(acq_provider_input_root msb projectionbox)
  current="${output#$root/}"
  [ ! -e "$root/current" ]
  [ -f "$root/$current/models/providers/alpha/facts.json" ]
  [ -x "$root/$current/models/providers/beta/normalizer" ]
  assert_equal "$(grep -c -- '--bundle' "$VALIDATOR_LOG")" 2
  [ ! -w "$root/$current/models/providers/alpha/facts.json" ]
}

@test "projection: explicit empty selection creates a provider-free generation" {
  local root generation
  # shellcheck disable=SC2034 # _build_kit_list reads these globals
  ACQ_PROVIDER_KITS=""
  # shellcheck disable=SC2034 # _build_kit_list reads these globals
  ACQ_PROVIDER_KITS_FROM_ENV=1
  # shellcheck disable=SC2034 # _build_kit_list reads these globals
  ACQ_PROVIDER_KITS_FROM_CLI=""
  _build_kit_list opencode

  run acq_provider_input_prepare sbx emptyproviders
  assert_success
  generation="$output"
  root=$(acq_provider_input_root sbx emptyproviders)
  [ -d "$generation/models/providers" ]
  [ -z "$(ls -A "$generation/models/providers")" ]
  refute_regex "$(printf '%s\n' "${KITS[@]}")" 'usai-provider'
  refute [ -e "$generation/models/providers/usai" ]
  [[ "$generation" == "$root/generations/"* ]]
}

@test "candidate snapshot preserves spec.yaml for host allowlist validation" {
  local release="$STUBDIR/release" candidate="$STUBDIR/candidate"
  _provider_release "$release"; _provider_kit "$release" alpha
  _acq_provider_input_snapshot "$release/integrations/isolation/acq-kits/alpha" "$candidate"
  [ -f "$candidate/spec.yaml" ]
  grep -Fq 'alpha.example.gov' "$candidate/spec.yaml"
}

@test "candidate snapshot rejects malformed provider input manifest with actionable error" {
  local release="$STUBDIR/release"
  local kit="$release/integrations/isolation/acq-kits/alpha"
  _provider_release "$release"; _provider_kit "$release" alpha
  printf '{this-is-not-json\n' > "$kit/provider-input.json"

  run _acq_provider_input_snapshot "$kit" "$STUBDIR/malformed-candidate"
  assert_failure
  assert_output --partial 'acq: invalid provider input manifest: provider-input.json: invalid JSON'
  refute_output --partial 'Traceback'
}

@test "pinned Patterns validator rejects facts host outside snapshotted kit allowlist" {
  [ -n "${ACQ_TEST_PATTERNS_REPO:-}" ] || skip "pinned Patterns checkout is provided by required CI"
  [ -n "${ACQ_TEST_PROVIDER_INPUT_PYTHON:-}" ] || skip "pinned validator Python is provided by required CI"
  local release="$ACQ_TEST_PATTERNS_REPO" kit="$STUBDIR/real-validator-kit"
  local candidate="$STUBDIR/real-validator-candidate" python
  [ "$(git -C "$release" rev-parse HEAD)" = "$PATTERNS_KIT_REF" ]
  mkdir -p "$kit/provider-input" "$kit/scripts" "$kit/files"
  cat > "$kit/provider-input.json" <<'JSON'
{"providerId":"alpha","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/alpha","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json","credentialEnvNames":["ALPHA_KEY"]}
JSON
  cat > "$kit/provider-input/facts.json" <<'JSON'
{"schemaVersion":"acq-provider-facts/v1","providerId":"alpha","apiProtocol":"openai-compatible","host":"models.example.gov","baseUrl":"https://models.example.gov/v1","modelsUrl":"https://models.example.gov/v1/models","keyEnv":"ALPHA_KEY"}
JSON
  cat > "$kit/files/snapshot.json" <<'JSON'
{"schemaVersion":"acq-neutral-model-catalog/v1","providerId":"alpha","models":[]}
JSON
  printf '#!/bin/sh\nexit 0\n' > "$kit/scripts/normalize"
  chmod 755 "$kit/scripts/normalize"
  cat > "$kit/spec.yaml" <<'YAML'
schemaVersion: "hybrid/v1"
kind: mixin
name: alpha
displayName: Alpha
description: Alpha provider test fixture
caps:
  network:
    allow:
      - other.example.gov
YAML
  _acq_provider_input_snapshot "$kit" "$candidate"
  printf '{"providers":{"alpha":"ALPHA_KEY"}}\n' > "$STUBDIR/bindings.json"
  python="$ACQ_TEST_PROVIDER_INPUT_PYTHON"

  run "$python" \
    "$release/scripts/validate_provider_input_contract.py" \
    --schema-dir "$release/integrations/isolation/schemas" \
    --credential-bindings "$STUBDIR/bindings.json" \
    --bundle "$candidate/provider-input.json"
  assert_failure
  assert_output --partial 'facts.host must be in the kit network allowlist'
}

@test "full preparation with pinned validator returns exactly one generation path" {
  [ -n "${ACQ_TEST_PATTERNS_REPO:-}" ] || skip "pinned Patterns checkout is provided by required CI"
  [ -n "${ACQ_TEST_PROVIDER_INPUT_PYTHON:-}" ] || skip "pinned validator Python is provided by required CI"
  local release="$ACQ_TEST_PATTERNS_REPO" kit="$STUBDIR/valid-real-kit" root
  mkdir -p "$kit/provider-input" "$kit/scripts" "$kit/files"
  cat > "$kit/provider-input.json" <<'JSON'
{"providerId":"usai","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/usai","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json","credentialEnvNames":["USAI_API_KEY"]}
JSON
  cat > "$kit/provider-input/facts.json" <<'JSON'
{"schemaVersion":"acq-provider-facts/v1","providerId":"usai","apiProtocol":"openai-compatible","host":"api.gsa.usai.gov","baseUrl":"https://api.gsa.usai.gov/api/v1","modelsUrl":"https://api.gsa.usai.gov/api/v1/models","keyEnv":"USAI_API_KEY"}
JSON
  printf '{"schemaVersion":"acq-neutral-model-catalog/v1","providerId":"usai","models":[]}\n' > "$kit/files/snapshot.json"
  printf '#!/bin/sh\nexit 0\n' > "$kit/scripts/normalize"; chmod 755 "$kit/scripts/normalize"
  cat > "$kit/spec.yaml" <<'YAML'
schemaVersion: "hybrid/v1"
kind: mixin
name: usai
displayName: USAi
description: USAi provider test fixture
caps:
  network:
    allow:
      - api.gsa.usai.gov
YAML
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$kit")
  ACQ_PROVIDER_INPUT_PYTHON="$ACQ_TEST_PROVIDER_INPUT_PYTHON" \
    acq_provider_input_prepare sbx realprepare \
    > "$STUBDIR/prepare.stdout" 2> "$STUBDIR/prepare.stderr"
  output=$(cat "$STUBDIR/prepare.stdout")
  [ "$(wc -l < "$STUBDIR/prepare.stdout" | tr -d ' ')" -eq 1 ]
  grep -Fq 'validated 1 bundle' "$STUBDIR/prepare.stderr"
  root=$(acq_provider_input_root sbx realprepare)
  case "$output" in "$root"/generations/generation.*) ;; *) false ;; esac
  [ -f "$output/models/providers/usai/facts.json" ]
}

@test "pinned Patterns validator accepts and projects neutral catalog capability fields" {
  [ -n "${ACQ_TEST_PATTERNS_REPO:-}" ] || skip "pinned Patterns checkout is provided by required CI"
  [ -n "${ACQ_TEST_PROVIDER_INPUT_PYTHON:-}" ] || skip "pinned validator Python is provided by required CI"
  local release="$ACQ_TEST_PATTERNS_REPO" kit="$STUBDIR/capability-real-kit" root
  [ "$(git -C "$release" rev-parse HEAD)" = "$PATTERNS_KIT_REF" ]
  mkdir -p "$kit/provider-input" "$kit/scripts" "$kit/files"
  cat > "$kit/provider-input.json" <<'JSON'
{"providerId":"usai","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/usai","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json","credentialEnvNames":["USAI_API_KEY"]}
JSON
  cat > "$kit/provider-input/facts.json" <<'JSON'
{"schemaVersion":"acq-provider-facts/v1","providerId":"usai","apiProtocol":"openai-compatible","host":"api.gsa.usai.gov","baseUrl":"https://api.gsa.usai.gov/api/v1","modelsUrl":"https://api.gsa.usai.gov/api/v1/models","keyEnv":"USAI_API_KEY"}
JSON
  cat > "$kit/files/snapshot.json" <<'JSON'
{"schemaVersion":"acq-neutral-model-catalog/v1","providerId":"usai","models":[{"id":"reasoner","name":"Reasoner","reasoning":true,"inputModalities":["text","image"]},{"id":"plain","name":"Plain","reasoning":false,"inputModalities":["text"]},{"id":"unknown","name":"Unknown"}]}
JSON
  printf '#!/bin/sh\nexit 0\n' > "$kit/scripts/normalize"; chmod 755 "$kit/scripts/normalize"
  cat > "$kit/spec.yaml" <<'YAML'
schemaVersion: "hybrid/v1"
kind: mixin
name: usai
displayName: USAi
description: USAi provider capability fixture
caps:
  network:
    allow:
      - api.gsa.usai.gov
YAML
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$kit")
  ACQ_PROVIDER_INPUT_PYTHON="$ACQ_TEST_PROVIDER_INPUT_PYTHON" \
    acq_provider_input_prepare sbx capabilityprepare \
    > "$STUBDIR/prepare.stdout" 2> "$STUBDIR/prepare.stderr"
  output=$(cat "$STUBDIR/prepare.stdout")
  grep -Fq 'validated 1 bundle' "$STUBDIR/prepare.stderr"
  root=$(acq_provider_input_root sbx capabilityprepare)
  case "$output" in "$root"/generations/generation.*) ;; *) false ;; esac
  grep -Fq '"inputModalities":["text","image"]' "$output/models/providers/usai/snapshot.json"
  grep -Fq '"reasoning":true' "$output/models/providers/usai/snapshot.json"
}

@test "parent exit cannot make a live transaction lock recoverable" {
  local script="$STUBDIR/lock-orchestrator.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -eu
ACQ_SCRIPT_DIR="$REPO_ROOT" ACQ_SOURCE_ONLY=1
export ACQ_PROVENANCE_DIR="$ACQ_PROVENANCE_DIR"
. "$REPO_ROOT/acq"
(
  _acq_provider_input_guardian_start
  acq_provider_input_lock_acquire sbx parentexit "\$_ACQ_PROVIDER_INPUT_GUARDIAN_PID" >/dev/null
  printf '%s\n' "\$_ACQ_PROVIDER_INPUT_GUARDIAN_PID" > "$STUBDIR/guardian.pid"
  sleep 10
) &
parent=\$!
# Wait on the published PID, not a fixed delay: sourcing acq and starting the
# guardian can take seconds on a loaded host. The ceiling only bounds a failure.
waited=0
while [ ! -s "$STUBDIR/guardian.pid" ] && kill -0 "\$parent" 2>/dev/null && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
[ -s "$STUBDIR/guardian.pid" ] || { echo "guardian never published its pid" >&2; exit 1; }
guardian_pid=\$(cat "$STUBDIR/guardian.pid")
# The guardian polls its parent once a second and, by design, exits within a
# tick of the parent's death. Stop it first so it is certainly still alive when
# the lock is probed; a probe racing that tick flaked under load. The parent is
# killed and reaped, so it is fully gone before the probe.
trap 'kill -CONT "\$guardian_pid" 2>/dev/null || true' EXIT
kill -STOP "\$guardian_pid"
kill -KILL "\$parent" 2>/dev/null || true
wait "\$parent" 2>/dev/null || true
if ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire sbx parentexit >"$STUBDIR/retry.out" 2>&1; then
  echo "lock was recovered while guardian was alive" >&2
  exit 1
fi
kill -CONT "\$guardian_pid"
grep -Fq "owned by live pid \$guardian_pid" "$STUBDIR/retry.out"
# Resumed, the guardian sees its parent gone and exits within a tick or two.
# Wait for that, with a ceiling far above the normal delay.
waited=0
while kill -0 "\$guardian_pid" 2>/dev/null && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
if kill -0 "\$guardian_pid" 2>/dev/null; then
  echo "guardian outlived its transaction parent" >&2
  exit 1
fi
lock=\$(acq_provider_input_lock_acquire sbx parentexit)
acq_provider_input_lock_release "\$lock"
echo "guardian ownership preserved"
EOF
  chmod +x "$script"
  BASH_ENV='' run bash "$script"
  assert_success
  assert_output --partial "guardian ownership preserved"
}

@test "guardian retains lock while registered backend child survives transaction" {
  local script="$STUBDIR/guardian-child.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -eu
export ACQ_PROVENANCE_DIR="$ACQ_PROVENANCE_DIR"
ACQ_SCRIPT_DIR="$REPO_ROOT" ACQ_SOURCE_ONLY=1 . "$REPO_ROOT/acq"
(
  _acq_provider_input_guardian_start
  lock=\$(acq_provider_input_lock_acquire sbx backend-child "\$_ACQ_PROVIDER_INPUT_GUARDIAN_PID")
  sleep 60 & child=\$!
  _acq_provider_input_guardian_register_child "\$child"
  printf '%s %s\n' "\$_ACQ_PROVIDER_INPUT_GUARDIAN_PID" "\$child" > "$STUBDIR/pids"
  sleep 10
) & parent=\$!
waited=0
while [ ! -s "$STUBDIR/pids" ] && kill -0 "\$parent" 2>/dev/null && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
[ -s "$STUBDIR/pids" ] || { echo "transaction never published its pids" >&2; exit 1; }
read guardian child < "$STUBDIR/pids"
kill -KILL "\$parent" 2>/dev/null || true
if ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire sbx backend-child >/dev/null 2>"$STUBDIR/retry"; then
  exit 1
fi
grep -Fq "owned by live pid \$guardian" "$STUBDIR/retry"
wait "\$parent" 2>/dev/null || true
# The registered child outlives every probe above: it is ended here rather than
# by a short sleep that a loaded host could outrun before the probe. Once it is
# gone the guardian has nothing left to wait for and exits within a tick.
kill "\$child" 2>/dev/null || true
waited=0
while kill -0 "\$child" 2>/dev/null && [ "\$waited" -lt 600 ]; do sleep 0.1; waited=\$((waited + 1)); done
waited=0
while kill -0 "\$guardian" 2>/dev/null && [ "\$waited" -lt 600 ]; do sleep 0.1; waited=\$((waited + 1)); done
if kill -0 "\$guardian" 2>/dev/null; then
  echo "guardian outlived its transaction and registered child" >&2
  exit 1
fi
lock=\$(acq_provider_input_lock_acquire sbx backend-child)
acq_provider_input_lock_release "\$lock"
echo retained
EOF
  chmod +x "$script"
  BASH_ENV='' run bash "$script"
  assert_success
  assert_output --partial retained
}

@test "unknown backend existence preserves prior projection and skips replacement" {
  local root
  root=$(acq_provider_input_root sbx unknownbox)
  _acq_provider_input_safe_mkdir "$root/generations/generation.old/models/providers"
  ln -s generations/generation.old "$root/current"
  acq_backend_exists() { return 1; }
  _acq_sbx_confirm_absent() { return 1; }
  acq_provider_input_project() { printf touched > "$STUBDIR/projected"; }
  _build_kit_list() { return 0; }

  run _acq_backend_provision_unlocked unknownbox shell /tmp
  assert_failure
  [ ! -e "$STUBDIR/projected" ]
  [ "$(readlink "$root/current")" = generations/generation.old ]
}

@test "unknown msb existence preserves prior projection and skips replacement" {
  local root
  # load_acq selects one adapter for the test process; load MSB explicitly for
  # this adapter-specific provisioning regression.
  . "$REPO_ROOT/acq.backends/msb.sh"
  root=$(acq_provider_input_root msb unknownmsb)
  _acq_provider_input_safe_mkdir "$root/generations/generation.old/models/providers"
  ln -s generations/generation.old "$root/current"
  acq_backend_exists() { return 1; }
  _acq_msb_confirm_absent() { return 1; }
  acq_provider_input_project() { printf touched > "$STUBDIR/projected-msb"; }
  _acq_msb_resolve_image() {
    _ACQ_MSB_RESOLVED_IMAGE=image
    _ACQ_MSB_RESOLVED_IMAGE_SOURCE="test"
  }

  run _acq_backend_provision_unlocked unknownmsb shell /tmp
  assert_failure
  [ ! -e "$STUBDIR/projected-msb" ]
  [ "$(readlink "$root/current")" = generations/generation.old ]
}

@test "pre-create cleanup discards SBX attempt even when absence probe is unknown" {
  local root generation
  root=$(acq_provider_input_root sbx precreate-sbx)
  generation="$root/generations/generation.precreate"
  _acq_provider_input_safe_mkdir "$generation/models/providers"
  _ACQ_SBX_ATTEMPT_NAME=precreate-sbx
  _ACQ_SBX_ATTEMPT_GENERATION="$generation"
  _ACQ_SBX_ATTEMPT_ACTIVE=1
  _ACQ_SBX_CREATE_STARTED=""
  _acq_sbx_confirm_absent() { return 1; }
  _acq_sbx_cleanup_uncreated_attempt
  [ ! -e "$generation" ]
}

@test "pre-create cleanup discards MSB attempt and clone when absence probe is unknown" {
  local root generation clone
  . "$REPO_ROOT/acq.backends/msb.sh"
  root=$(acq_provider_input_root msb precreate-msb)
  generation="$root/generations/generation.precreate"
  clone="$ACQ_MSB_CLONES_DIR/precreate-msb"
  _acq_provider_input_safe_mkdir "$generation/models/providers"
  mkdir -p "$clone"
  _ACQ_MSB_ATTEMPT_NAME=precreate-msb
  _ACQ_MSB_ATTEMPT_GENERATION="$generation"
  _ACQ_MSB_ATTEMPT_CLONE="$clone"
  _ACQ_MSB_ATTEMPT_ACTIVE=1
  _ACQ_MSB_CREATE_STARTED=""
  _acq_msb_confirm_absent() { return 1; }
  _acq_msb_clone_cleanup() { rm -rf -- "$clone"; }
  _acq_msb_cleanup_uncreated_attempt
  [ ! -e "$generation" ]
  [ ! -e "$clone" ]
}

@test "sbx confirmed-absent removal cleans orphan provider projection" {
  local root
  root=$(acq_provider_input_root sbx gonebox)
  _acq_provider_input_safe_mkdir "$root/generations/generation.old/models/providers"
  ln -s generations/generation.old "$root/current"
  sbx() { [ "$1" != rm ]; }
  _acq_sbx_confirm_absent() { return 0; }

  run _acq_backend_terminate_unlocked gonebox
  assert_failure
  [ ! -e "$root" ]
}

@test "rejected replacement preserves prior current generation" {
  local release="$STUBDIR/release" root before after
  _provider_release "$release"; _provider_kit "$release" alpha
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha")
  acq_provider_input_project sbx rollbackbox
  root=$(acq_provider_input_root sbx rollbackbox); before=$(readlink "$root/current")

  _provider_kit "$release" alpha REJECT
  run acq_provider_input_project sbx rollbackbox
  assert_failure
  after=$(readlink "$root/current")
  assert_equal "$after" "$before"
  [ -f "$root/$after/models/providers/alpha/facts.json" ]
}

@test "failed atomic swap preserves prior current generation" {
  local root before called="$STUBDIR/replacement-called"
  root=$(acq_provider_input_root sbx publishbox)
  mkdir -p "$root/generations/generation.old/models/providers" "$root/generations/generation.new/models/providers"
  ln -s generations/generation.old "$root/current"
  before=$(readlink "$root/current")
  _acq_provider_input_atomic_replace() { printf called > "$called"; return 1; }

  run _acq_provider_input_publish "$root" "$root/generations/generation.new"
  assert_failure
  [ -f "$called" ]
  assert_equal "$(readlink "$root/current")" "$before"
}

@test "empty discovery publishes authoritative empty generation" {
  local root current empty="$STUBDIR/empty"
  mkdir -p "$empty"; KITS=("$empty")
  run acq_provider_input_project msb emptybox
  assert_success
  root=$(acq_provider_input_root msb emptybox); current=$(readlink "$root/current")
  [ -d "$root/$current/models/providers" ]
  [ -z "$(ls -A "$root/$current/models/providers")" ]
}

@test "projection lock rejects a concurrent operation" {
  local lock
  lock=$(acq_provider_input_lock_acquire sbx lockbox)
  ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 run acq_provider_input_lock_acquire sbx lockbox
  assert_failure
  acq_provider_input_lock_release "$lock"
}

@test "projection lock recovery preserves an owner replaced after the stale read" {
  local root lock live
  root=$(acq_provider_input_root sbx recovery-race); lock="${root}.lock"
  _acq_provider_input_safe_mkdir "$lock"
  live="$$ $(_acq_provider_input_process_identity "$$")"
  printf '999999 stale\n' > "$lock/owner"
  _acq_pid_alive() {
    if [ "$1" = 999999 ]; then printf '%s\n' "$live" > "$lock/owner"; return 1; fi
    command kill -0 "$1" 2>/dev/null
  }
  ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 run acq_provider_input_lock_acquire sbx recovery-race
  assert_failure
  assert_equal "$(cat "$lock/owner")" "$live"
}

@test "lock takers refuse a detached live owner during recovery" {
  local lock="$STUBDIR/detached" take
  mkdir "$lock"
  printf 'new live\n' > "$lock/owner"
  mv() {
    command mv "$@" || return
    for take in _acq_config_lock_take _acq_provider_input_lock_take; do
      if "$take" "$lock" 'contender token'; then return 1; fi
    done
  }
  _racy_mkdir
  _acq_lock_remove_owner "$lock" 'old stale'
  assert_equal "$(cat "$lock/owner")" 'new live'
  [ "$(ls -A "$lock")" = owner ]
}

@test "lock recovery cleans reservations left by a dead remover" {
  local lock private take
  for take in _acq_config_lock_take _acq_provider_input_lock_take; do
    lock="$STUBDIR/$take"
    private="$lock/owner.stale.999999.example"
    mkdir -p "$private"
    printf '999999 stale\n' > "$private/owner"
    run "$take" "$lock" 'new token'
    assert_success
    [ ! -e "$private" ]
    assert_equal "$(cat "$lock/owner")" 'new token'
  done
}

@test "lock recovery retains a changed token when exclusive restoration loses" {
  local lock="$STUBDIR/restore-conflict" private
  mkdir "$lock"
  printf 'new live\n' > "$lock/owner"
  ln() { printf 'newer token\n' > "$lock/owner"; command ln "$@"; }
  run _acq_lock_remove_owner "$lock" 'old stale'
  assert_success
  assert_equal "$(cat "$lock/owner")" 'newer token'
  for private in "$lock"/owner.stale.*; do
    assert_equal "$(cat "$private/owner")" 'new live'
  done
  run _acq_config_lock_take "$lock" 'contender token'
  assert_failure
  _acq_lock_reservations "$lock" 'new live' || true
  [ "$(ls -A "$lock")" = owner ]
}

@test "lock reservation cleanup never follows a symlinked lock" {
  case "${OSTYPE:-}" in msys*|cygwin*) skip "needs native symlinks" ;; esac
  local lock="$STUBDIR/linked-lock" private="$STUBDIR/elsewhere/owner.stale.999999.example" take
  mkdir -p "$private"
  printf '999999 stale\n' > "$private/owner"
  printf '999999 stale\n' > "$STUBDIR/elsewhere/owner"
  ln -s "$STUBDIR/elsewhere" "$lock"
  for take in _acq_config_lock_take _acq_provider_input_lock_take _acq_lock_remove_owner; do
    run "$take" "$lock" '999999 stale'
    assert_failure
    assert_equal "$(cat "$private/owner")" '999999 stale'
    assert_equal "$(cat "$STUBDIR/elsewhere/owner")" '999999 stale'
  done
}

@test "lock take withdraws its token if recovery starts during its owner write" {
  local lock="$STUBDIR/postcheck"
  run bash -c '
    ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1
    lock=$2; private="$lock/owner.stale.$$.example"
    printf() {
      builtin printf "$@" || return
      case "$-" in *C*) command mkdir "$private"; command mv "$lock/owner" "$private/owner" ;; esac
    }
    _acq_config_lock_take "$lock" "self token"
  ' _ "$ACQ" "$lock"
  assert_failure
  [ ! -e "$lock" ]
}

@test "projection lock recovers a stale owner but never breaks a live owner" {
  local root lock identity
  root=$(acq_provider_input_root sbx stalebox); lock="${root}.lock"
  _acq_provider_input_safe_mkdir "$lock"
  printf '999999 stale\n' > "$lock/owner"
  run acq_provider_input_lock_acquire sbx stalebox
  assert_success
  acq_provider_input_lock_release "${lines[${#lines[@]} - 1]}"

  identity=$(_acq_provider_input_process_identity "$$")
  _acq_provider_input_safe_mkdir "$lock"
  printf '%s %s\n' "$$" "$identity" > "$lock/owner"
  ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 run acq_provider_input_lock_acquire sbx stalebox
  assert_failure
  assert_output --partial "owned by live pid $$"
  assert_output --partial "gave up waiting for the provider-input lock: $lock"
  assert_output --partial "rm -f -- '$lock/owner' && rmdir -- '$lock'"
  rm -f "$lock/owner"; rmdir "$lock"
}

@test "projection lock never removes a lock with no owner and names the recovery command" {
  local root lock
  root=$(acq_provider_input_root sbx ownerless); lock="${root}.lock"
  _acq_provider_input_safe_mkdir "$lock"
  # Under set -u, as acq itself runs: an owner-less lock once stopped acq with
  # "pid: unbound variable" before this message.
  run bash -c 'ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1; set -u; acq_provider_input_lock_acquire sbx ownerless' bash "$ACQ"
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "provider-input lock has no valid owner metadata: $lock"
  assert_output --partial "rm -f -- '$lock/owner' && rmdir -- '$lock'"
  [ -d "$lock" ]
  rm -f -- "$lock/owner" && rmdir -- "$lock"
  run acq_provider_input_lock_acquire sbx ownerless
  assert_success
  acq_provider_input_lock_release "${lines[${#lines[@]} - 1]}"
}

# _racy_mkdir — put first on PATH a mkdir that is not exclusive: it reports
# success for a directory that already exists, as uutils coreutils mkdir 0.10
# does for concurrent callers (KNOWN_FAILURE_MODES section 92). This makes the
# race the lock must survive happen every time, on any host.
_racy_mkdir() {
  local real
  real=$(command -v mkdir)
  mkdir -p "$STUBDIR/racy-mkdir"
  printf '#!/bin/sh\n"%s" "$@" 2>/dev/null && exit 0\nfor last; do :; done\n[ -d "$last" ]\n' "$real" \
    > "$STUBDIR/racy-mkdir/mkdir"
  chmod +x "$STUBDIR/racy-mkdir/mkdir"
  PATH="$STUBDIR/racy-mkdir:$PATH"
}

@test "projection lock: losing the owner-file race never takes or touches the winner's lock" {
  local root lock identity
  root=$(acq_provider_input_root sbx racebox); lock="${root}.lock"
  identity=$(_acq_provider_input_process_identity "$$")
  _acq_provider_input_safe_mkdir "$lock"
  printf '%s %s\n' "$$" "$identity" > "$lock/owner"
  _racy_mkdir
  ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 run acq_provider_input_lock_acquire sbx racebox
  assert_failure
  assert_output --partial "owned by live pid $$"
  run cat "$lock/owner"
  assert_output "$$ $identity"
  rm -f "$lock/owner"; rmdir "$lock"
}

@test "projection lock: a lock released since the take is taken, not refused as unsafe" {
  local real
  real=$(command -v mkdir)
  mkdir -p "$STUBDIR/gone-mkdir"
  # The first mkdir of the lock fails as if it existed, and it is gone by the
  # time acq looks: the holder released it in between.
  printf '#!/bin/sh\nfor last; do :; done\ncase "$last" in *.lock) [ -e "%s/failed" ] || { : > "%s/failed"; exit 1; } ;; esac\nexec "%s" "$@"\n' \
    "$STUBDIR" "$STUBDIR" "$real" > "$STUBDIR/gone-mkdir/mkdir"
  chmod +x "$STUBDIR/gone-mkdir/mkdir"
  PATH="$STUBDIR/gone-mkdir:$PATH" run acq_provider_input_lock_acquire sbx gonebox
  assert_success
  refute_output --partial "unsafe"
  [ -e "$STUBDIR/failed" ]
  acq_provider_input_lock_release "${lines[${#lines[@]} - 1]}"
}

@test "projection lock: a failed token write removes the owner file it created" {
  local root lock
  root=$(acq_provider_input_root sbx fullbox); lock="${root}.lock"
  _acq_provider_input_safe_mkdir "${root%/*}"
  run bash -c 'ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1; printf() { return 1; }; _acq_provider_input_lock_take "$2" "1 x"' bash "$ACQ" "$lock"
  assert_failure 2
  [ ! -e "$lock" ]
}

# _lock_taker COUNT — take and release the provider-input lock of sandbox
# "contended" COUNT times in a fresh Bash. While it holds the lock it creates
# $STUBDIR/holder exclusively: if that file already exists another taker holds
# the lock at the same moment, and it records that in $STUBDIR/overlap.
_lock_taker() {
  timeout 600 bash -c 'ACQ_SOURCE_ONLY=1 . "$1" >/dev/null 2>&1
    held=0
    while [ "$held" -lt "$3" ]; do
      if lock=$(ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire sbx contended 2>/dev/null); then
        ( set -C; : > "$2/holder" ) 2>/dev/null || echo "bash $$ owner=[$(cat "$lock/owner" 2>/dev/null)]" >> "$2/overlap"
        sleep 0.02
        rm -f -- "$2/holder"
        acq_provider_input_lock_release "$lock" || true
        held=$((held + 1))
      else
        sleep 0.05
      fi
    done' bash "$ACQ" "$STUBDIR" "$1"
}

@test "projection lock: parallel Bash takers never hold it at once, even with a non-exclusive mkdir" {
  local pids="" pid rc=0 takers=6 count=15 t
  export ACQ_PROVENANCE_DIR="$STUBDIR/provenance"
  # Process creation is slow under Git Bash, so fewer takers there.
  case "${OSTYPE:-}" in msys*|cygwin*) takers=3 count=5 ;; esac
  _racy_mkdir
  for ((t=0; t<takers; t++)); do
    _lock_taker "$count" &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || rc=1; done
  [ "$rc" -eq 0 ]
  [ ! -e "$STUBDIR/overlap" ] || { cat "$STUBDIR/overlap" >&2; false; }
  [ ! -e "$(acq_provider_input_root sbx contended).lock" ]
}

@test "projection lock: parallel Bash and Python takers never hold it at once" {
  case "${OSTYPE:-}" in msys*|cygwin*) skip "the Python acq never takes this lock on Windows" ;; esac
  command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' ||
    skip "needs python3 >= 3.12 for the Python acq"
  local pids="" pid rc=0 t
  export ACQ_PROVENANCE_DIR="$STUBDIR/provenance"
  _racy_mkdir
  for ((t=0; t<3; t++)); do
    _lock_taker 15 &
    pids="$pids $!"
    PYTHONPATH="$REPO_ROOT/py-acq/src" timeout 600 python3 -c '
import os, sys, time
from acq_py import lock
stub, count = sys.argv[1], int(sys.argv[2])
held = 0
while held < count:
    taker = lock._BashLock("sbx", "contended")
    # A Python acq that cannot work out its own identity (ps failing under
    # load) only honours the lock and proceeds without taking it; that is not
    # a hold, so it does not count here.
    if not taker.acquire() or taker.token is None:
        time.sleep(0.05)
        continue
    try:
        os.close(os.open(stub + "/holder", os.O_WRONLY | os.O_CREAT | os.O_EXCL))
    except FileExistsError:
        with open(stub + "/overlap", "a", encoding="utf-8") as fh:
            fh.write("python %d token=[%s]\n" % (os.getpid(), taker.token))
    time.sleep(0.02)
    try:
        os.unlink(stub + "/holder")
    except FileNotFoundError:
        pass
    taker.release()
    held += 1
' "$STUBDIR" 15 &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || rc=1; done
  [ "$rc" -eq 0 ]
  [ ! -e "$STUBDIR/overlap" ] || { cat "$STUBDIR/overlap" >&2; false; }
  [ ! -e "$(acq_provider_input_root sbx contended).lock" ]
}

@test "provision interruption releases provider-input lock" {
  local script="$STUBDIR/signal-lock.sh" root
  root=$(acq_provider_input_root sbx signalbox)
  cat > "$script" <<EOF
#!/usr/bin/env bash
ACQ_SCRIPT_DIR="$REPO_ROOT"; ACQ_SOURCE_ONLY=1
. "$REPO_ROOT/acq"
. "$REPO_ROOT/acq.backends/sbx.sh"
_acq_backend_provision_unlocked() { kill -TERM "\$\$"; }
acq_backend_provision signalbox shell /tmp
EOF
  chmod +x "$script"
  run "$script"
  assert_failure 143
  [ ! -e "${root}.lock" ]
}

@test "terminate TERM holds lock while backend child runs then releases after exit" {
  local script="$STUBDIR/signal-term-child.sh" root
  root=$(acq_provider_input_root sbx termbox)
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -eu
ACQ_SCRIPT_DIR="$REPO_ROOT"; ACQ_SOURCE_ONLY=1
. "$REPO_ROOT/acq"
. "$REPO_ROOT/acq.backends/sbx.sh"
# The controlled backend child signals its actual transaction parent, then stays
# alive until the wrapper's TERM handler terminates and reaps it.
sbx() {
  [ "\$1" = rm ] || return 0
  kill -TERM "\$_ACQ_PROVIDER_INPUT_TRANSACTION_PID"
  sleep 3
}
acq_backend_terminate termbox
EOF
  chmod +x "$script"
  BASH_ENV='' run "$script"
  # Wrapper must exit 143 (TERM signal status)
  assert_failure 143
  # Lock must be gone — backend child must have exited before EXIT cleanup ran
  [ ! -e "${root}.lock" ]
}

# ---------------------------------------------------------------------------
# MSB-specific signal/lock regressions (external-executable variants)
# ---------------------------------------------------------------------------
# All three tests use an EXTERNAL EXECUTABLE for `msb` (a script placed in PATH)
# rather than a shell-function override.  The slow-msb executable traps TERM and
# stays alive for a few seconds so the test can verify that:
#   - the lock cannot be acquired while the executable is running, and
#   - the lock is released only after the executable exits.
#
# The msb create background path uses inline `MSYS2_ARG_CONV_EXCL='*' msb ...&`
# so bash exec-optimizes: the forked child becomes the msb binary/script
# directly, giving $! the real executable PID so TERM reaches it.

@test "msb remove TERM: external executable survives initial signal, second lock blocked until exit" {
  local script="$STUBDIR/msb-remove-term-${BATS_TEST_NUMBER}.sh" root msb_bin sandbox pid_file
  sandbox="msbsignalbox-${BATS_TEST_NUMBER}"
  root=$(acq_provider_input_root msb "$sandbox")
  msb_bin="$STUBDIR/slow-msb-remove"
  pid_file="$STUBDIR/slow-msb-${BATS_TEST_NUMBER}.pid"
  # Create the external slow-msb executable: traps TERM (ignores it initially),
# writes its own PID, waits until the guardian registry contains that exact PID,
# then waits for the test before killing its PPID (= the transaction subshell)
# with TERM. This handshake avoids racing child registration under Bash 3.2.
  cat > "$msb_bin" << 'MSB_SLOW'
#!/bin/sh
# Ignore the first TERM from signal_children; stay alive 2s then exit naturally.
trap '' TERM
printf '%s\n' "$$" > "$MSB_PID_FILE"
while ! grep -Fx "$$" "$_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN" >/dev/null 2>&1; do sleep 0.05; done
while [ ! -f "$MSB_SIGNAL_GO" ]; do sleep 0.05; done
kill -TERM "$PPID" 2>/dev/null || true
touch "$MSB_SIGNAL_SENT"
sleep 2
exit 0
MSB_SLOW
  chmod +x "$msb_bin"
  cat > "$script" << EOF
#!/usr/bin/env bash
set -eu
export ACQ_PROVENANCE_DIR="$ACQ_PROVENANCE_DIR"
export MSB_PID_FILE="$pid_file"
export MSB_SIGNAL_GO="$STUBDIR/slow-msb.go"
export MSB_SIGNAL_SENT="$STUBDIR/slow-msb.signalled"
# Prepend the slow-msb as \`msb\` in PATH.
mkdir -p "$STUBDIR/msb-bin"
ln -sf "$msb_bin" "$STUBDIR/msb-bin/msb"
export PATH="$STUBDIR/msb-bin:\$PATH"
export ACQ_STATE_DIR="$STUBDIR/state"
ACQ_SCRIPT_DIR="$REPO_ROOT" ACQ_SOURCE_ONLY=1 . "$REPO_ROOT/acq"
. "$REPO_ROOT/acq.backends/msb.sh"
# Stub functions that run before/after the msb remove call and are irrelevant
# to the lock/signal mechanism under test.
_acq_msb_ports_teardown() { return 0; }
_acq_msb_clone_warn_unfetched() { return 0; }
_acq_msb_remove_derived_volumes() { return 0; }
_acq_msb_clone_cleanup() { return 0; }
_acq_msb_ssh_agent_link_remove() { return 0; }
acq_host_config_remove() { return 0; }
acq_backend_exists() { return 1; }       # sandbox confirmed gone after remove
_acq_msb_confirm_absent() { return 0; }  # confirms gone for the rc-ne-0 path
# Run terminate in background so we can probe lock state while it runs.
rc=0
acq_backend_terminate "$sandbox" & tx=\$!
# Wait for slow-msb to register its PID (confirms the background executable started).
waited=0
while [ ! -s "$pid_file" ] && kill -0 "\$tx" 2>/dev/null && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
[ -s "$pid_file" ] || { echo "slow-msb never started" >&2; exit 1; }
msb_pid=\$(cat "$pid_file")
# The external child waits for its own registry entry before observing this gate.
touch "$STUBDIR/slow-msb.go"
waited=0
while [ ! -f "$STUBDIR/slow-msb.signalled" ] && kill -0 "\$msb_pid" 2>/dev/null && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
[ -f "$STUBDIR/slow-msb.signalled" ] || { echo "slow-msb never signalled" >&2; exit 1; }
kill -0 "\$msb_pid" 2>/dev/null || { echo "slow-msb exited before lock probe" >&2; exit 1; }
# Verify the lock is still held while the executable is alive.
if ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire msb "$sandbox" >"$STUBDIR/lock-retry.out" 2>&1; then
  echo "lock acquired while msb executable was alive" >&2
  exit 1
fi
grep -Fq "live pid" "$STUBDIR/lock-retry.out" || { cat "$STUBDIR/lock-retry.out" >&2; exit 1; }
# Wait for the background transaction to complete.
wait "\$tx" || rc=\$?
# After the transaction exits the lock must be released.
lock=\$(acq_provider_input_lock_acquire msb "$sandbox")
acq_provider_input_lock_release "\$lock"
printf '%s\n' "rc=\$rc lock-cleared"
EOF
  chmod +x "$script"
  BASH_ENV='' run bash "$script"
  assert_success
  assert_output --partial "rc=143"
  assert_output --partial "lock-cleared"
  [ ! -e "${root}.lock" ]
}

@test "handled signal helper reaps real children and yields 129/130/143" {
  local rc_expected script
  for rc_expected in 129 130 143; do
    script="$STUBDIR/signal-exit-${rc_expected}.sh"
    cat > "$script" << EOF
#!/usr/bin/env bash
set -eu
export ACQ_PROVENANCE_DIR="$ACQ_PROVENANCE_DIR"
ACQ_SCRIPT_DIR="$REPO_ROOT" ACQ_SOURCE_ONLY=1 . "$REPO_ROOT/acq"
_acq_provider_input_guardian_start
lock=\$(acq_provider_input_lock_acquire msb signal-$rc_expected "\$_ACQ_PROVIDER_INPUT_GUARDIAN_PID")
sh -c 'trap "" TERM; sleep 2' & child=\$!
_acq_provider_input_guardian_register_child "\$child"
trap 'code=\$?; acq_provider_input_lock_release "\$lock" || true; _acq_provider_input_guardian_stop; exit "\$code"' EXIT
_acq_provider_input_signal_exit $rc_expected
EOF
    chmod +x "$script"
    BASH_ENV='' run bash "$script"
    assert_failure "$rc_expected"
    [ ! -e "$(acq_provider_input_root msb "signal-$rc_expected").lock" ]
  done
}

@test "msb create TERM: external executable survives initial signal, lock held until exit" {
  local script="$STUBDIR/msb-create-term.sh" root msb_bin
  root=$(acq_provider_input_root msb msbcreatebox)
  msb_bin="$STUBDIR/slow-msb-create"
  cat > "$msb_bin" << 'MSB_CREATE'
#!/bin/sh
# Only slow down for 'create'; answer 'list' immediately (needed by _acq_msb_confirm_absent).
case "${1:-}" in
  create)
    trap '' TERM
    printf '%s\n' "$$" > "$MSB_PID_FILE"
    while ! grep -Fx "$$" "$_ACQ_PROVIDER_INPUT_GUARDIAN_CHILDREN" >/dev/null 2>&1; do sleep 0.05; done
    while [ ! -f "$MSB_SIGNAL_GO" ]; do sleep 0.05; done
    kill -TERM "$_ACQ_PROVIDER_INPUT_TRANSACTION_PID" 2>/dev/null || true
    touch "$MSB_SIGNAL_SENT"
    sleep 2
    exit 0 ;;
  list) exit 0 ;;    # _acq_msb_confirm_absent uses 'list -q'
  *) exit 0 ;;
esac
MSB_CREATE
  chmod +x "$msb_bin"
  cat > "$script" << EOF
#!/usr/bin/env bash
set -eu
export ACQ_PROVENANCE_DIR="$ACQ_PROVENANCE_DIR"
export MSB_PID_FILE="$STUBDIR/slow-msb-create.pid"
export MSB_SIGNAL_GO="$STUBDIR/slow-msb-create.go"
export MSB_SIGNAL_SENT="$STUBDIR/slow-msb-create.signalled"
mkdir -p "$STUBDIR/msb-create-bin"
ln -sf "$msb_bin" "$STUBDIR/msb-create-bin/msb"
export PATH="$STUBDIR/msb-create-bin:\$PATH"
export ACQ_STATE_DIR="$STUBDIR/state3"
ACQ_SCRIPT_DIR="$REPO_ROOT" ACQ_SOURCE_ONLY=1 . "$REPO_ROOT/acq"
. "$REPO_ROOT/acq.backends/msb.sh"
KITS=()
# Current main does not contain the macOS alias helper until the approved path
# fix merges; this adapter-focused test supplies its pass-through contract.
_acq_provider_input_canonical_path() { printf '%s\n' "\$1"; }
# Stub the complex provision helpers so execution reaches the msb create call.
acq_backend_exists() { return 1; }
_acq_msb_confirm_absent() { return 0; }
_acq_msb_resolve_image() { _ACQ_MSB_RESOLVED_IMAGE=test-image; _ACQ_MSB_RESOLVED_IMAGE_SOURCE=test; }
_acq_msb_select_kits() { return 0; }
_acq_msb_net_rules_into() { return 0; }
_acq_msb_merge_kit_env_into() { return 0; }
_acq_msb_stage_startup_script() { return 0; }
_acq_msb_volume_flags_from_records() { return 0; }
_acq_msb_balanced_rules_into() { return 0; }
_acq_msb_upstream_ca_flags_into() { return 0; }
_acq_msb_vsock_flags_into() { return 0; }
_acq_msb_bind_secrets_into() { return 0; }
_acq_msb_cleanup_uncreated_attempt() { return 0; }
_acq_msb_image_not_found_error() { return 1; }
# Provision happens synchronously — run in background to probe lock state.
rc=0
acq_backend_provision msbcreatebox shell /tmp & tx=\$!
waited=0
while [ ! -s "$STUBDIR/slow-msb-create.pid" ] && kill -0 "\$tx" 2>/dev/null && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
[ -s "$STUBDIR/slow-msb-create.pid" ] || { echo "slow-msb-create never started" >&2; exit 1; }
msb_pid=\$(cat "$STUBDIR/slow-msb-create.pid")
# The external child waits for its own registry entry before observing this gate.
touch "$STUBDIR/slow-msb-create.go"
waited=0
while [ ! -f "$STUBDIR/slow-msb-create.signalled" ] && kill -0 "\$msb_pid" 2>/dev/null && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
[ -f "$STUBDIR/slow-msb-create.signalled" ] || { echo "slow-msb-create never signalled" >&2; exit 1; }
kill -0 "\$msb_pid" 2>/dev/null || { echo "slow-msb-create exited before lock probe" >&2; exit 1; }
# While slow-msb is running the lock must not be acquirable.
if ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire msb msbcreatebox >"$STUBDIR/create-lock-retry.out" 2>&1; then
  echo "create lock acquired while msb executable was alive" >&2
  exit 1
fi
grep -Fq "live pid" "$STUBDIR/create-lock-retry.out" || { cat "$STUBDIR/create-lock-retry.out" >&2; exit 1; }
wait "\$tx" || rc=\$?
lock=\$(acq_provider_input_lock_acquire msb msbcreatebox)
acq_provider_input_lock_release "\$lock"
printf '%s\n' "rc=\$rc lock-cleared"
EOF
  chmod +x "$script"
  BASH_ENV='' run bash "$script"
  assert_success
  assert_output --partial "rc=143"
  assert_output --partial "lock-cleared"
  [ ! -e "${root}.lock" ]
}

@test "symlinked projection ancestor is rejected without outside mutation" {
  local base outside root
  base="$ACQ_PROVENANCE_DIR/provider-input"; outside="$STUBDIR/outside"
  mkdir -p "$outside" "$ACQ_PROVENANCE_DIR"
  ln -s "$outside" "$base"
  run acq_provider_input_lock_acquire sbx symlinkbox
  assert_failure
  [ -z "$(ls -A "$outside")" ]
  root=$(acq_provider_input_root sbx symlinkbox)
  [ ! -e "$root" ]
}

# ---------------------------------------------------------------------------
# safe_mkdir / safe_dir / canonical_path direct-call tests
# ---------------------------------------------------------------------------
# All alias and spelling tests call the actual production helper
# _acq_provider_input_canonical_path and the O_NOFOLLOW traversal helpers
# directly.  ACQ_TEST_HOST_OS injects a synthetic platform so Darwin-branch
# tests are portable on Linux CI; it is never set in non-test shells.

@test "safe_mkdir creates and traverses a real path with no symlinks" {
  local real_path="$STUBDIR/real/a/b/c"
  run _acq_provider_input_safe_mkdir "$real_path"
  assert_success
  [ -d "$real_path" ]
}

@test "safe_mkdir is idempotent on an already-existing real path" {
  local real_path="$STUBDIR/idempotent/x/y"
  mkdir -p "$real_path"
  run _acq_provider_input_safe_mkdir "$real_path"
  assert_success
  [ -d "$real_path" ]
}

# _walk_race_shim — put a `python3` first on PATH that runs acq's path walks
# through walk-race-python.py, which lets a rival create the component named by
# ACQ_TEST_WALK_RACE between the walk's lookup and its mkdir. One deterministic
# pass stands in for two acq processes creating the same missing directory.
_walk_race_shim() {
  local real
  real=$(command -v python3)
  mkdir -p "$STUBDIR/walk-race"
  printf '#!/bin/sh\nexec "%s" -I "%s" "$@"\n' "$real" "$BATS_TEST_DIRNAME/walk-race-python.py" \
    > "$STUBDIR/walk-race/python3"
  chmod +x "$STUBDIR/walk-race/python3"
  export PATH="$STUBDIR/walk-race:$PATH"
  export ACQ_TEST_WALK_RACE_MARK="$STUBDIR/walk-race/raced"
}

@test "safe_mkdir tolerates a rival creating a missing component mid-walk" {
  local real_path="$STUBDIR/race/shared/leaf"
  _walk_race_shim
  ACQ_TEST_WALK_RACE=shared run _acq_provider_input_safe_mkdir "$real_path"
  assert_success
  assert_equal "$(cat "$ACQ_TEST_WALK_RACE_MARK")" shared
  [ -d "$real_path" ]
  [ ! -L "$STUBDIR/race/shared" ]
}

@test "safe_mkdir still rejects a symlink a rival plants mid-walk" {
  local real_path="$STUBDIR/race-link/shared/leaf"
  mkdir -p "$STUBDIR/race-link-target"
  _walk_race_shim
  ACQ_TEST_WALK_RACE=shared ACQ_TEST_WALK_RACE_LINK="$STUBDIR/race-link-target" \
    run _acq_provider_input_safe_mkdir "$real_path"
  assert_failure
  assert_equal "$(cat "$ACQ_TEST_WALK_RACE_MARK")" shared
  [ ! -e "$STUBDIR/race-link-target/leaf" ]
}

@test "safe_dir accepts an existing real path with no symlinks" {
  local real_path="$STUBDIR/safe_dir_real/p/q"
  mkdir -p "$real_path"
  run _acq_provider_input_safe_dir "$real_path"
  assert_success
}

@test "safe_dir rejects a path whose intermediate component is a symlink (malicious ancestor)" {
  local base="$STUBDIR/evil_base" target="$STUBDIR/evil_target/sub" sym="$STUBDIR/evil_dir_check"
  mkdir -p "$base" "$target"
  ln -s "$base" "$sym"
  run _acq_provider_input_safe_dir "$sym"
  assert_failure
  # A silent predicate: refused, with no traceback or other output.
  assert_output ''
}

@test "safe_mkdir rejects a path whose intermediate component is a symlink (malicious ancestor)" {
  local real_deep="$STUBDIR/real_deep/legit"
  local evil_parent="$STUBDIR/evil_parent"
  local evil_target="$STUBDIR/evil_target_dir"
  mkdir -p "$real_deep" "$evil_target"
  ln -s "$evil_target" "$evil_parent"
  run _acq_provider_input_safe_mkdir "$evil_parent/new_child"
  assert_failure
  # One line naming the refused path, never a Python traceback.
  refute_output --partial 'Traceback'
  assert_equal "${#lines[@]}" 1
  assert_output --partial "acq: unsafe provider-input path $evil_parent/new_child:"
  [ ! -e "$evil_target/new_child" ]
}

@test "safe_mkdir refuses a component that is a file with one line, not a traceback" {
  local file="$STUBDIR/plain_file"
  : > "$file"
  run _acq_provider_input_safe_mkdir "$file/child"
  assert_failure
  refute_output --partial 'Traceback'
  assert_equal "${#lines[@]}" 1
  assert_output --partial "acq: unsafe provider-input path $file/child:"
}

@test "canonical_path aliases /var /tmp /etc on Darwin via ACQ_TEST_HOST_OS" {
  # Exercises the production _acq_provider_input_canonical_path helper directly
  # with ACQ_TEST_HOST_OS=darwin so the Darwin branch runs on Linux CI.
  local cases=(
    '/var/folders/x/y/T/acq /private/var/folders/x/y/T/acq'
    '/tmp/acq-test.XXX /private/tmp/acq-test.XXX'
    '/etc/hosts /private/etc/hosts'
    '/var /private/var'
    '/tmp /private/tmp'
    '/etc /private/etc'
    '/home/user/project /home/user/project'
    '/private/var/already /private/var/already'
    '/variably/something /variably/something'
    '/tmpfile /tmpfile'
    '/etc-extra /etc-extra'
  )
  local pair input expected got
  for pair in "${cases[@]}"; do
    input="${pair%% *}"; expected="${pair##* }"
    got=$(ACQ_TEST_HOST_OS=darwin _acq_provider_input_canonical_path "$input")
    [ "$got" = "$expected" ] || {
      printf 'FAIL canonical_path %s -> %s, want %s\n' "$input" "$got" "$expected" >&2
      return 1
    }
  done
}

@test "canonical_path leaves /var /tmp unchanged on Linux via ACQ_TEST_HOST_OS" {
  local cases=(
    '/var/folders/x/y /var/folders/x/y'
    '/tmp/test /tmp/test'
    '/etc/resolv.conf /etc/resolv.conf'
  )
  local pair input expected got
  for pair in "${cases[@]}"; do
    input="${pair%% *}"; expected="${pair##* }"
    got=$(ACQ_TEST_HOST_OS=linux _acq_provider_input_canonical_path "$input")
    [ "$got" = "$expected" ] || {
      printf 'FAIL canonical_path linux %s -> %s, want %s\n' "$input" "$got" "$expected" >&2
      return 1
    }
  done
}

@test "canonical_path normalizes //var and /./var spellings before alias match (Darwin)" {
  local got
  got=$(ACQ_TEST_HOST_OS=darwin _acq_provider_input_canonical_path '//var/folders')
  [ "$got" = '/private/var/folders' ] || { printf 'FAIL //var: %s\n' "$got" >&2; return 1; }
  got=$(ACQ_TEST_HOST_OS=darwin _acq_provider_input_canonical_path '/./var/folders')
  [ "$got" = '/private/var/folders' ] || { printf 'FAIL /./var: %s\n' "$got" >&2; return 1; }
  got=$(ACQ_TEST_HOST_OS=darwin _acq_provider_input_canonical_path '//tmp/test')
  [ "$got" = '/private/tmp/test' ] || { printf 'FAIL //tmp: %s\n' "$got" >&2; return 1; }
  got=$(ACQ_TEST_HOST_OS=darwin _acq_provider_input_canonical_path '/./tmp/test')
  [ "$got" = '/private/tmp/test' ] || { printf 'FAIL /./tmp: %s\n' "$got" >&2; return 1; }
}

@test "canonical_path with ACQ_TEST_HOST_OS=darwin enables safe_mkdir on alias-prefixed paths" {
  # Prove that safe_mkdir succeeds on a real directory (canonical form) and that
  # a user-owned symlink planted at the path root is still rejected regardless of
  # the platform override — ACQ_TEST_HOST_OS only controls the alias rewrite;
  # O_NOFOLLOW enforcement is unconditional.
  local real_dir="$STUBDIR/private_var_sim" alias_path
  mkdir -p "$real_dir/acq/state"

  # Real directory under STUBDIR succeeds — no symlinks involved.
  ACQ_TEST_HOST_OS=linux _acq_provider_input_safe_mkdir "$real_dir/new_child"

  # A path through a user-owned symlink must still fail regardless of platform.
  # bats run does not propagate inline env= prefix, so export then restore.
  alias_path="$STUBDIR/alias_link"
  ln -s "$real_dir" "$alias_path"
  export ACQ_TEST_HOST_OS=darwin
  run _acq_provider_input_safe_mkdir "$alias_path/child"
  unset ACQ_TEST_HOST_OS
  assert_failure
}

@test "safe_mkdir Darwin-alias: canonical form succeeds, symlinked form fails (regression)" {
  # Confirm that the production traversal rejects user-owned symlinks even after
  # canonical_path runs.  This is the primary regression assertion: a user symlink
  # planted at a path component is never followed regardless of the host OS.
  local real_dir="$STUBDIR/real_private_var"
  local alias_dir="$STUBDIR/var_alias_sim"
  mkdir -p "$real_dir"
  ln -s "$real_dir" "$alias_dir"

  # The real (canonical) path succeeds.
  run _acq_provider_input_safe_mkdir "$real_dir/acq/state"
  assert_success

  # A user-owned symlink at the path root fails — not a trusted OS alias.
  run _acq_provider_input_safe_mkdir "$alias_dir/acq/state"
  assert_failure
}

# ---------------------------------------------------------------------------
# safe_mkdir / safe_dir: both helpers traverse Darwin OS-level aliases
# ---------------------------------------------------------------------------
# These four tests execute the ACTUAL production _acq_provider_input_safe_mkdir
# and _acq_provider_input_safe_dir helpers through a simulated Darwin trusted
# alias using an isolated STUBDIR-local filesystem.  ACQ_TEST_ALIAS_TABLE
# injects a test-only alias pair (alias_sym -> private_real); the production
# /var|/tmp|/etc -> /private/... table is unchanged for non-test invocations.
# ACQ_TEST_HOST_OS=darwin activates the canonicalization branch.
#
# Failure mode if canonicalization is removed: each alias_sym path contains a
# user-visible symlink as its first component.  Without the canonical_path call
# in the helper, O_NOFOLLOW hits that symlink and returns ELOOP/ENOTDIR ->
# the positive-control tests below flip from assert_success to assert_failure.
#
# The user-symlink negative controls confirm that a symlink NOT in the alias
# table is still rejected, even with darwin mode active.

@test "safe_mkdir succeeds through simulated Darwin alias via ACQ_TEST_ALIAS_TABLE" {
  # Build isolated FS: private_real is a real directory; alias_sym -> private_real
  # models the macOS /var -> /private/var kernel symlink.
  local private_real="$STUBDIR/da_private/var"
  local alias_sym="$STUBDIR/da_var"
  mkdir -p "$private_real"
  ln -s "$private_real" "$alias_sym"

  # With the alias table active, canonical_path maps alias_sym -> private_real,
  # so O_NOFOLLOW traversal succeeds on the real directory.
  export ACQ_TEST_HOST_OS=darwin
  export ACQ_TEST_ALIAS_TABLE="${alias_sym}	${private_real}"
  run _acq_provider_input_safe_mkdir "$alias_sym/acq/state"
  unset ACQ_TEST_HOST_OS ACQ_TEST_ALIAS_TABLE
  assert_success
  [ -d "$private_real/acq/state" ]
}

@test "safe_dir succeeds through simulated Darwin alias via ACQ_TEST_ALIAS_TABLE" {
  # Same topology as safe_mkdir test; safe_dir only checks existence, no mkdir.
  local private_real="$STUBDIR/da_private2/var"
  local alias_sym="$STUBDIR/da_var2"
  mkdir -p "$private_real/acq/state"
  ln -s "$private_real" "$alias_sym"

  export ACQ_TEST_HOST_OS=darwin
  export ACQ_TEST_ALIAS_TABLE="${alias_sym}	${private_real}"
  run _acq_provider_input_safe_dir "$alias_sym/acq/state"
  unset ACQ_TEST_HOST_OS ACQ_TEST_ALIAS_TABLE
  assert_success
}

@test "safe_mkdir rejects user-controlled symlink not in Darwin alias table" {
  # Even with darwin mode and a custom alias table, a symlink outside the alias
  # table is still rejected by O_NOFOLLOW — it is not a trusted OS alias.
  local private_real="$STUBDIR/da_private3/var"
  local alias_sym="$STUBDIR/da_var3"
  local user_sym="$STUBDIR/da_user_sym"
  mkdir -p "$private_real"
  ln -s "$private_real" "$alias_sym"
  ln -s "$private_real" "$user_sym"

  # alias_sym is in the table (trusted); user_sym is not.
  export ACQ_TEST_HOST_OS=darwin
  export ACQ_TEST_ALIAS_TABLE="${alias_sym}	${private_real}"
  run _acq_provider_input_safe_mkdir "$user_sym/acq/state"
  unset ACQ_TEST_HOST_OS ACQ_TEST_ALIAS_TABLE
  assert_failure
}

@test "safe_dir rejects user-controlled symlink not in Darwin alias table" {
  # Mirror of safe_mkdir negative control for safe_dir.
  local private_real="$STUBDIR/da_private4/var"
  local alias_sym="$STUBDIR/da_var4"
  local user_sym="$STUBDIR/da_user_sym4"
  mkdir -p "$private_real/acq/state"
  ln -s "$private_real" "$alias_sym"
  ln -s "$private_real" "$user_sym"

  export ACQ_TEST_HOST_OS=darwin
  export ACQ_TEST_ALIAS_TABLE="${alias_sym}	${private_real}"
  run _acq_provider_input_safe_dir "$user_sym/acq/state"
  unset ACQ_TEST_HOST_OS ACQ_TEST_ALIAS_TABLE
  assert_failure
}

# ---------------------------------------------------------------------------
# safe_mkdir / safe_dir under Git Bash, MSYS2 and Cygwin
# ---------------------------------------------------------------------------
# Git for Windows ships no python3 (or only the Microsoft Store alias stub), and
# native Windows CPython has no O_NOFOLLOW, O_DIRECTORY or dir_fd. These tests
# set OSTYPE the way those shells do and put emulated interpreters first on
# PATH. The emulated native Windows Python runs the real interpreter with those
# flags removed and os.name set to "nt", and its os.lstat reports
# FILE_ATTRIBUTE_REPARSE_POINT for each directory listed in FAKE_REPARSE, which
# stands in for an NTFS junction (S_ISLNK does not report one); a file listed
# there reads as some other reparse point. FAKE_SWAP_AFTER_LSTAT=leaf:target
# replaces leaf with a symlink to target right after its lstat, the race the
# snapshot's handle check exists for. The test mount table maps / to itself, so
# the Windows path the walk receives is the same POSIX path.

_win_bin() {
  local bin="$STUBDIR/winbin" real
  real=$(command -v python3)
  mkdir -p "$bin"
  printf '%s\n' "$bin"
  cat > "$bin/winpython" <<SH
#!/bin/sh
printf '%s\n' "winpython \$*" >> "$STUBDIR/py.log"
[ "\$1" = -I ] || exit 97
shift
case "\$1" in
  -c) code=\$2; shift 2 ;;
  -) code=; shift ;;
  *) exit 97 ;;
esac
exec "$real" -I -c '
import os, stat, sys
real_lstat = os.lstat
marked = set(p for p in os.environ.get("FAKE_REPARSE", "").split(":") if p)
class St:
    def __init__(self, st, attrs):
        self._st = st
        self.st_file_attributes = attrs
    def __getattr__(self, name):
        return getattr(self._st, name)
swap = os.environ.get("FAKE_SWAP_AFTER_LSTAT", "").split(":")
def lstat(path, *args, **kwargs):
    st = real_lstat(path, *args, **kwargs)
    if len(swap) == 2 and path == swap[0]:
        os.unlink(path); os.symlink(swap[1], path)
    if not stat.S_ISDIR(st.st_mode) and path not in marked: return st
    attrs = stat.FILE_ATTRIBUTE_DIRECTORY if stat.S_ISDIR(st.st_mode) else 0
    if path in marked: attrs |= stat.FILE_ATTRIBUTE_REPARSE_POINT
    return St(st, attrs)
os.lstat = lstat
del os.O_NOFOLLOW, os.O_DIRECTORY
import shutil  # loaded now: with os.name "nt" it would import the missing nt module
os.name = "nt"
code = sys.argv[1] or sys.stdin.read()
sys.argv = ["-"] + sys.argv[2:]
exec(compile(code, "<emulated-nt>", "exec"), {"__name__": "__main__"})
' "\$code" "\$@"
SH
  cat > "$bin/storestub" <<SH
#!/bin/sh
printf '%s\n' "storestub \$*" >> "$STUBDIR/py.log"
echo 'Python was not found; run without arguments to install from the Microsoft Store' >&2
exit 49
SH
  cat > "$bin/msyspython" <<SH
#!/bin/sh
printf '%s\n' "msyspython \$*" >> "$STUBDIR/py.log"
exec "$real" "\$@"
SH
  cat > "$bin/pylauncher" <<SH
#!/bin/sh
printf '%s\n' "py \$*" >> "$STUBDIR/py.log"
[ "\$1" = -3 ] || exit 98
shift
exec "$bin/winpython" "\$@"
SH
  chmod +x "$bin"/*
  printf '/ / ntfs binary,noacl,auto 1 1\n' > "$STUBDIR/mounts"
}

# _win_use BIN python3=X python=Y py=Z — link the chosen emulations.
_win_use() {
  local bin="$1" pair
  shift
  rm -f "$bin/python3" "$bin/python" "$bin/py"
  for pair in "$@"; do ln -s "$bin/${pair#*=}" "$bin/${pair%%=*}"; done
  export ACQ_TEST_MOUNTS_FILE="$STUBDIR/mounts"
}

@test "POSIX hosts run safe_dir through python3 with no interpreter probe" {
  # Exactly the two `python3 -I -` runs this helper always made (canonical_path,
  # then the walk), and no `-c` probe.
  local bin real="$STUBDIR/posix_once/a"
  bin=$(_win_bin)
  _win_use "$bin" python3=msyspython
  mkdir -p "$real"
  OSTYPE=linux-gnu PATH="$bin:$PATH" _acq_provider_input_safe_dir "$real"
  assert_equal "$(cat "$STUBDIR/py.log")" "msyspython -I - $real
msyspython -I - $real"
}

@test "Git Bash skips the python3 Store stub and walks with native Windows Python" {
  local bin real="$STUBDIR/nt_real/a/b"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$real"
  assert_success
  [ -d "$real" ]
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$real"
  assert_success
  grep -q '^storestub -I -c ' "$STUBDIR/py.log"
  grep -q "^winpython -I - mkdir $real\$" "$STUBDIR/py.log"
  grep -q "^winpython -I - check $real\$" "$STUBDIR/py.log"
}

@test "native Windows walk rejects a symlinked ancestor without outside mutation" {
  local bin outside="$STUBDIR/nt_outside" link="$STUBDIR/nt_link"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  mkdir -p "$outside/existing"
  ln -s "$outside" "$link"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$link/new/child"
  assert_failure
  assert_output --partial 'unsafe provider-input path'
  [ ! -e "$outside/new" ]
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$link/existing"
  assert_failure
}

@test "native Windows walk rejects a junction (reparse point that is not S_ISLNK)" {
  local bin junction="$STUBDIR/nt_junction"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  mkdir -p "$junction/existing"
  export FAKE_REPARSE="$junction"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$junction/new"
  assert_failure
  [ ! -e "$junction/new" ]
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$junction/existing"
  assert_failure
  # The same tree without the reparse attribute is accepted, so the rejection
  # above comes from the attribute check alone.
  unset FAKE_REPARSE
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$junction/existing"
  assert_success
}

@test "native Windows walk rejects a leaf reparse point, a file component and dot-dot" {
  local bin base="$STUBDIR/nt_misc"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  mkdir -p "$base/dir/leaf"
  : > "$base/file"
  FAKE_REPARSE="$base/dir/leaf" OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$base/dir/leaf"
  assert_failure
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$base/file/child"
  assert_failure
  [ -f "$base/file" ]
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$base/dir/../made"
  assert_failure
  [ ! -e "$base/made" ]
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$base/missing"
  assert_failure
}

@test "Git Bash falls back to py -3 when python3 and python are unusable" {
  local bin real="$STUBDIR/nt_py/a"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=storestub py=pylauncher
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$real"
  assert_success
  [ -d "$real" ]
  grep -q "^py -3 -I - mkdir $real\$" "$STUBDIR/py.log"
}

@test "Git Bash with no usable Python fails closed before touching the path" {
  local bin real="$STUBDIR/nt_none/a"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=storestub py=storestub
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$real"
  assert_failure
  assert_output --partial 'need Python 3 (python3, python or py -3)'
  [ ! -e "$STUBDIR/nt_none" ]
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$STUBDIR"
  assert_failure
}

@test "native Windows walk fails closed when the mount table cannot map the path" {
  local bin real="$STUBDIR/nt_nocyg/a"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  ACQ_TEST_MOUNTS_FILE="$STUBDIR/no-such-mounts" OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$real"
  assert_failure
  assert_output --partial 'cannot map provider-input path'
  [ ! -e "$STUBDIR/nt_nocyg" ]
}

@test "MSYS2 or Cygwin Python with POSIX primitives keeps the descriptor-relative walk" {
  local bin real="$STUBDIR/msys_real/a" outside="$STUBDIR/msys_outside" link="$STUBDIR/msys_link"
  bin=$(_win_bin)
  _win_use "$bin" python3=msyspython
  export ACQ_TEST_MOUNTS_FILE="$STUBDIR/no-such-mounts"
  mkdir -p "$outside"
  ln -s "$outside" "$link"
  OSTYPE=cygwin PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$real"
  assert_success
  [ -d "$real" ]
  OSTYPE=cygwin PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$link/new"
  assert_failure
  [ ! -e "$outside/new" ]
  grep -q "^msyspython -I - $real\$" "$STUBDIR/py.log"
}

@test "nt_path maps MSYS paths lexically through the longest mount point" {
  # The layout Git for Windows reports in /proc/mounts, octal escapes included.
  local table="$STUBDIR/gitbash-mounts" pair input expected got
  printf '%s\n' \
    'C:/Program\040Files/Git / ntfs binary,noacl,auto 1 1' \
    'C:/Program\040Files/Git/usr/bin /bin ntfs binary,noacl,auto 1 1' \
    'C:/Users/u/AppData/Local/Temp /tmp ntfs binary,noacl,posix=0,usertemp 1 1' \
    'C: /c ntfs binary,noacl,posix=0,user,noumount,auto 1 1' > "$table"
  local cases=(
    '/c/Users/u/.local/state/acq|C:/Users/u/.local/state/acq'
    '/c|C:/'
    '/C/Users/u|C:/Users/u'
    '/TMP/x|C:/Users/u/AppData/Local/Temp/x'
    '/BIN/bash|C:/Program Files/Git/BIN/bash'
    '/Usr/share|C:/Program Files/Git/Usr/share'
    '/tmp/acq-x|C:/Users/u/AppData/Local/Temp/acq-x'
    '/bin/bash|C:/Program Files/Git/usr/bin/bash'
    '/usr/share|C:/Program Files/Git/usr/share'
    '/cx/y|C:/Program Files/Git/cx/y'
    '/c/a/../b|C:/a/../b'
    'C:\Users\u|C:\Users\u'
    'D:/x|D:/x'
  )
  for pair in "${cases[@]}"; do
    input="${pair%%|*}"; expected="${pair#*|}"
    got=$(ACQ_TEST_MOUNTS_FILE="$table" _acq_provider_input_nt_path "$input") || got="<rc=$?>"
    [ "$got" = "$expected" ] || {
      printf 'FAIL nt_path %s -> %s, want %s\n' "$input" "$got" "$expected" >&2
      return 1
    }
  done
  ACQ_TEST_MOUNTS_FILE="$table" run _acq_provider_input_nt_path 'relative/x'
  assert_failure
  ACQ_TEST_MOUNTS_FILE="$table" run _acq_provider_input_nt_path '//server/share/x'
  assert_failure
  # The match leaves the caller's nocasematch setting as it was.
  ACQ_TEST_MOUNTS_FILE="$table" _acq_provider_input_nt_path '/C/x' >/dev/null
  run shopt -q nocasematch
  assert_failure
  ACQ_TEST_MOUNTS_FILE="$STUBDIR/no-such-mounts" run _acq_provider_input_nt_path '/c/x'
  assert_failure
}

@test "nt_path takes the longest mount prefix whatever the table order" {
  # / is listed last, and /usr/bin is nested in /usr with a different target, so
  # a first-match or shortest-match lookup gives a wrong answer.
  local table="$STUBDIR/nested-mounts" pair input expected got
  printf '%s\n' \
    'E:/usrbin /usr/bin ntfs binary,noacl,auto 1 1' \
    'F:/usr /usr ntfs binary,noacl,auto 1 1' \
    'C: /c ntfs binary,noacl,posix=0,user,noumount,auto 1 1' \
    'G:/root / ntfs binary,noacl,auto 1 1' > "$table"
  local cases=(
    '/usr/bin/bash|E:/usrbin/bash'
    '/usr/bin|E:/usrbin/'
    '/usr/binx/y|F:/usr/binx/y'
    '/usr/lib/x|F:/usr/lib/x'
    '/c/x|C:/x'
    '/opt/x|G:/root/opt/x'
  )
  for pair in "${cases[@]}"; do
    input="${pair%%|*}"; expected="${pair#*|}"
    got=$(ACQ_TEST_MOUNTS_FILE="$table" _acq_provider_input_nt_path "$input") || got="<rc=$?>"
    [ "$got" = "$expected" ] || {
      printf 'FAIL nt_path %s -> %s, want %s\n' "$input" "$got" "$expected" >&2
      return 1
    }
  done
}

@test "nt_path ignores ACQ_TEST_MOUNTS_FILE outside bats" {
  local table="$STUBDIR/zmounts" got
  printf 'Z:/fake / ntfs binary,noacl,auto 1 1\n' > "$table"
  got=$(ACQ_TEST_MOUNTS_FILE="$table" _acq_provider_input_nt_path /x/y)
  assert_equal "$got" 'Z:/fake/x/y'
  got=$(unset BATS_TEST_NAME; ACQ_TEST_MOUNTS_FILE="$table" _acq_provider_input_nt_path /x/y) || got="<rc=$?>"
  [ "$got" != 'Z:/fake/x/y' ]
}

@test "native Windows walk rejects names Win32 would rewrite, before touching them" {
  local bin base="$STUBDIR/nt_names" name names
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  names=('dot.' 'space ' 'c:' 'a:b' 'lt<' 'gt>' 'q"' 'pipe|' 'ask?' 'star*' "tab$(printf '\t')x")
  mkdir -p "$base"
  for name in "${names[@]}"; do
    OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$base/$name/child"
    assert_failure
    [ ! -e "$base/$name" ] || { printf 'FAIL created %s\n' "$name" >&2; return 1; }
    # An existing directory with the name is still refused by the check.
    mkdir "$base/$name"
    OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$base/$name"
    assert_failure
  done
  # The same walk accepts an ordinary name, so the refusals come from the names.
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$base/plain.name/child"
  assert_success
}

@test "native Windows walk checks the drive root itself" {
  local bin
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$STUBDIR"
  assert_success
  FAKE_REPARSE=/ OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_dir "$STUBDIR"
  assert_failure
}

@test "interpreter probe trusts only absolute command paths and runs them by path" {
  local bin
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  OSTYPE=msys PATH="$bin:$PATH" _acq_provider_input_path_python
  assert_equal "${_ACQ_PROVIDER_INPUT_PATH_PY[*]}" "$bin/python"
  assert_equal "$_ACQ_PROVIDER_INPUT_PATH_PY_KIND" nt
  # A shell function named python is not a candidate, even though it would
  # answer the probe.
  unset _ACQ_PROVIDER_INPUT_PATH_PY _ACQ_PROVIDER_INPUT_PATH_PY_KIND
  rm -f "$bin/python"
  eval "python() { \"$bin/winpython\" \"\$@\"; }"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_safe_mkdir "$STUBDIR/fn_python/a"
  unset -f python
  assert_failure
  assert_output --partial 'need Python 3'
  [ ! -e "$STUBDIR/fn_python" ]
}

@test "interpreter probe result is cached and warmed by the transaction guardian" {
  local bin probes
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  OSTYPE=msys PATH="$bin:$PATH" _acq_provider_input_guardian_start
  _acq_provider_input_guardian_stop
  assert_equal "$_ACQ_PROVIDER_INPUT_PATH_PY_KIND" nt
  # Later helpers reuse the cached interpreter: no further probe runs, even
  # inside command substitutions.
  OSTYPE=msys PATH="$bin:$PATH" _acq_provider_input_safe_mkdir "$STUBDIR/cached/a"
  : "$(OSTYPE=msys PATH="$bin:$PATH" _acq_provider_input_safe_dir "$STUBDIR/cached/a"; echo checked)"
  probes=$(grep -c -- ' -I -c ' "$STUBDIR/py.log")
  assert_equal "$probes" 2
  grep -q "^winpython -I - check $STUBDIR/cached/a\$" "$STUBDIR/py.log"
}

@test "interpreter cache inherited from the environment is ignored" {
  # An exported cache must not choose the interpreter: sourcing acq drops it, so
  # the probe runs, finds no usable Python here, and safe_dir fails closed
  # without running the planted command.
  local bin planted="$STUBDIR/planted-python" script="$STUBDIR/inherited-cache.sh"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=storestub py=storestub
  mkdir -p "$STUBDIR/inherited/a"
  cat > "$planted" <<SH
#!/bin/sh
printf '%s\n' "planted \$*" >> "$STUBDIR/planted.log"
exit 0
SH
  chmod +x "$planted"
  cat > "$script" <<SH
#!/usr/bin/env bash
ACQ_SCRIPT_DIR="$REPO_ROOT"; ACQ_SOURCE_ONLY=1
. "$REPO_ROOT/acq"
set +e
OSTYPE=msys
PATH="$bin:\$PATH"
_acq_provider_input_safe_dir "$STUBDIR/inherited/a"
SH
  chmod +x "$script"
  _ACQ_PROVIDER_INPUT_PATH_PY="$planted" _ACQ_PROVIDER_INPUT_PATH_PY_KIND=nt run "$script"
  assert_failure
  assert_output --partial 'need Python 3'
  [ ! -e "$STUBDIR/planted.log" ]
}

@test "canonical_path passes the path through unchanged for native Windows Python" {
  local bin got
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  got=$(OSTYPE=msys PATH="$bin:$PATH" _acq_provider_input_canonical_path '/c/Users/u/.local/state/acq')
  assert_equal "$got" '/c/Users/u/.local/state/acq'
}

# ---------------------------------------------------------------------------
# snapshot / materialize / publish under Git Bash with native Windows Python
# ---------------------------------------------------------------------------

@test "POSIX snapshot, materialize and swap run through python3 with unchanged arguments" {
  local bin release="$STUBDIR/release" kit candidate="$STUBDIR/posix_candidate" providers="$STUBDIR/posix_providers"
  bin=$(_win_bin)
  _win_use "$bin" python3=msyspython
  _provider_release "$release"; _provider_kit "$release" alpha
  kit="$release/integrations/isolation/acq-kits/alpha"
  mkdir -p "$providers"
  OSTYPE=linux-gnu PATH="$bin:$PATH" _acq_provider_input_snapshot "$kit" "$candidate"
  OSTYPE=linux-gnu PATH="$bin:$PATH" _acq_provider_input_materialize "$candidate/provider-input.json" "$candidate" "$providers"
  : > "$STUBDIR/swap-src"
  OSTYPE=linux-gnu PATH="$bin:$PATH" _acq_provider_input_atomic_replace "$STUBDIR/swap-src" "$STUBDIR/swap-dst"
  assert_equal "$(cat "$STUBDIR/py.log")" "msyspython -I - $kit $candidate
msyspython -I - $candidate/provider-input.json $candidate $providers
msyspython -I - $STUBDIR/swap-src $STUBDIR/swap-dst"
  [ -f "$providers/alpha/facts.json" ] && [ -f "$STUBDIR/swap-dst" ]
}

@test "Git Bash snapshot and materialize use the probed native Windows Python" {
  local bin release="$STUBDIR/release" kit candidate="$STUBDIR/nt_candidate" providers="$STUBDIR/nt_providers"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=storestub py=pylauncher
  _provider_release "$release"; _provider_kit "$release" alpha
  kit="$release/integrations/isolation/acq-kits/alpha"
  mkdir -p "$providers"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$candidate"
  assert_success
  grep -q "^py -3 -I - $kit $candidate\$" "$STUBDIR/py.log"
  cmp "$kit/provider-input.json" "$candidate/provider-input.json"
  cmp "$kit/spec.yaml" "$candidate/spec.yaml"
  cmp "$kit/provider-input/facts.json" "$candidate/provider-input/facts.json"
  [ -x "$candidate/scripts/normalize" ]
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_materialize "$candidate/provider-input.json" "$candidate" "$providers"
  assert_success
  grep -q "^py -3 -I - $candidate/provider-input.json $candidate $providers\$" "$STUBDIR/py.log"
  [ -f "$providers/alpha/facts.json" ] && [ ! -w "$providers/alpha/facts.json" ]
  [ -x "$providers/alpha/normalizer" ]
}

@test "native Windows snapshot refuses links, reparse points and swapped leaves" {
  local bin release="$STUBDIR/release" kit outside="$STUBDIR/nt_secret"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  _provider_release "$release"; _provider_kit "$release" alpha
  kit="$release/integrations/isolation/acq-kits/alpha"
  printf 'secret\n' > "$outside"
  # A symlinked leaf.
  mv "$kit/provider-input/facts.json" "$STUBDIR/facts.real"
  ln -s "$outside" "$kit/provider-input/facts.json"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$STUBDIR/c1"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
  rm "$kit/provider-input/facts.json"; mv "$STUBDIR/facts.real" "$kit/provider-input/facts.json"
  # A junction ancestor, then a leaf that is some other reparse point.
  FAKE_REPARSE="$kit/provider-input" OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$STUBDIR/c2"
  assert_failure
  FAKE_REPARSE="$kit/spec.yaml" OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$STUBDIR/c3"
  assert_failure
  # A kit root that is itself a junction.
  FAKE_REPARSE="$kit" OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$STUBDIR/c4"
  assert_failure
  # A leaf replaced with a link after its lstat: the opened handle is another file.
  FAKE_SWAP_AFTER_LSTAT="$kit/provider-input/facts.json:$outside" OSTYPE=msys PATH="$bin:$PATH" \
    run _acq_provider_input_snapshot "$kit" "$STUBDIR/c5"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
  [ ! -e "$STUBDIR/c5/provider-input/facts.json" ]
  # The untouched kit snapshots, so each refusal above came from its own cause.
  rm "$kit/provider-input/facts.json"; printf '{"providerId":"alpha"}\n' > "$kit/provider-input/facts.json"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$STUBDIR/c6"
  assert_success
}

@test "native Windows snapshot refuses artifact paths Win32 would rewrite" {
  local bin release="$STUBDIR/release" kit name i=0
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  _provider_release "$release"; _provider_kit "$release" alpha
  kit="$release/integrations/isolation/acq-kits/alpha"
  for name in 'facts.json.' 'facts.json ' 'facts.json:ads' 'sub\facts.json' 'NUL' 'com1.json' 'COM¹' 'lpt³.txt' 'a|b'; do
    i=$((i + 1))
    printf '{"providerId":"alpha","factsPath":"%s","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json"}\n' \
      "$(printf '%s' "$name" | sed 's/\\/\\\\/g')" > "$kit/provider-input.json"
    OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$STUBDIR/w$i"
    assert_failure
    assert_output --partial 'unsafe provider artifact path'
  done
  # POSIX keeps accepting the same characters as plain file names.
  printf '{}\n' > "$kit/a|b"
  printf '{"providerId":"alpha","factsPath":"a|b","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json"}\n' > "$kit/provider-input.json"
  run _acq_provider_input_snapshot "$kit" "$STUBDIR/wposix"
  assert_success
}

@test "native Windows materialize refuses unsafe provider IDs and reparse-point artifacts" {
  local bin release="$STUBDIR/release" kit candidate="$STUBDIR/m_candidate" id i=0 providers
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  _provider_release "$release"; _provider_kit "$release" alpha
  kit="$release/integrations/isolation/acq-kits/alpha"
  OSTYPE=msys PATH="$bin:$PATH" _acq_provider_input_snapshot "$kit" "$candidate"
  for id in 'nul' 'lpt²' 'alpha.' 'c:alpha' 'al*ha'; do
    i=$((i + 1)); providers="$STUBDIR/m_providers$i"; mkdir -p "$providers"
    printf '{"providerId":"%s","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/%s","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json"}\n' "$id" "$id" > "$STUBDIR/m_manifest.json"
    OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_materialize "$STUBDIR/m_manifest.json" "$candidate" "$providers"
    assert_failure
    assert_output --partial 'unsafe provider ID'
    [ -z "$(ls -A "$providers")" ]
  done
  providers="$STUBDIR/m_providers_reparse"; mkdir -p "$providers"
  FAKE_REPARSE="$candidate/files/snapshot.json" OSTYPE=msys PATH="$bin:$PATH" \
    run _acq_provider_input_materialize "$candidate/provider-input.json" "$candidate" "$providers"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
}

@test "native Windows publish writes current as a pointer file and swaps it atomically" {
  local bin root
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  root=$(acq_provider_input_root msb ntpublish)
  mkdir -p "$root/generations/generation.one/models/providers" "$root/generations/generation.two/models/providers"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_publish "$root" "$root/generations/generation.one"
  assert_success
  [ -f "$root/current" ] && [ ! -L "$root/current" ]
  assert_equal "$(cat "$root/current")" "generations/generation.one"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_publish "$root" "$root/generations/generation.two"
  assert_success
  assert_equal "$(cat "$root/current")" "generations/generation.two"
  [ -d "$root/generations/generation.one" ]
  [ ! -w "$root/generations/generation.two/models" ]
  [ -z "$(find "$root" -maxdepth 1 -name '.current.*')" ]
  grep -q "^winpython -I - $root/.current.[0-9]*.[0-9]* $root/current\$" "$STUBDIR/py.log"
}

@test "native Windows publish replaces a link left as current but never a real directory" {
  local bin root
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  root=$(acq_provider_input_root msb ntlinked)
  mkdir -p "$root/generations/generation.old/models/providers" "$root/generations/generation.new/models/providers"
  # A symlink, as the Python acq leaves with Developer Mode on.
  ln -s generations/generation.old "$root/current"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_publish "$root" "$root/generations/generation.new"
  assert_success
  [ -f "$root/current" ] && [ ! -L "$root/current" ]
  assert_equal "$(cat "$root/current")" "generations/generation.new"
  [ -d "$root/generations/generation.old/models/providers" ]
  # A junction: a directory reparse point, which os.replace cannot overwrite.
  rm "$root/current"; mkdir "$root/current"
  FAKE_REPARSE="$root/current" OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_publish "$root" "$root/generations/generation.new"
  assert_success
  [ -f "$root/current" ]
  # A real directory (the copy an older Git Bash ln -s made) is refused, kept,
  # and no temporary pointer is left behind.
  rm "$root/current"; mkdir -p "$root/current/models"
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_publish "$root" "$root/generations/generation.new"
  assert_failure
  assert_output --partial 'it is a directory, not a file or a link'
  [ -d "$root/current/models" ]
  [ -z "$(find "$root" -maxdepth 1 -name '.current.*')" ]
}

@test "native Windows swap fails closed when a path does not map" {
  local bin
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  : > "$STUBDIR/unmapped-src"
  ACQ_TEST_MOUNTS_FILE="$STUBDIR/no-such-mounts" OSTYPE=msys PATH="$bin:$PATH" \
    run _acq_provider_input_atomic_replace "$STUBDIR/unmapped-src" "$STUBDIR/unmapped-dst"
  assert_failure
  assert_output --partial 'cannot map provider-input path'
  [ -f "$STUBDIR/unmapped-src" ] && [ ! -e "$STUBDIR/unmapped-dst" ]
  refute grep -q '^winpython -I - ' "$STUBDIR/py.log"
}

@test "Git Bash provider-input transaction completes with native Windows Python" {
  local bin release="$STUBDIR/release" lock generation root mount
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  _provider_release "$release"; _provider_kit "$release" alpha
  _use_release
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha")
  # Not exported: a child bash would take the value as its own OSTYPE.
  OSTYPE=msys
  PATH="$bin:$PATH"
  lock=$(acq_provider_input_lock_acquire msb nttx)
  generation=$(acq_provider_input_prepare msb nttx)
  root=$(acq_provider_input_root msb nttx)
  [[ "$generation" == "$root/generations/generation."* ]]
  [ -f "$generation/models/providers/alpha/facts.json" ]
  mount=$(acq_provider_input_msb_mount nttx "$generation")
  assert_equal "$mount" "$generation:$ACQ_PROVIDER_INPUT_GUEST_DIR/${generation##*/}:ro"
  _acq_provider_input_publish "$root" "$generation"
  assert_equal "$(cat "$root/current")" "generations/${generation##*/}"
  acq_provider_input_remove msb nttx
  [ ! -e "$root" ]
  acq_provider_input_lock_release "$lock"
  [ ! -e "$lock" ]
  grep -q "^winpython -I - $release/integrations/isolation/acq-kits/alpha " "$STUBDIR/py.log"
  refute grep -q '^msyspython' "$STUBDIR/py.log"
}

# _facts_generation DIR ID — a generation holding one provider's full facts.
_facts_generation() {
  mkdir -p "$1/models/providers/$2"
  printf '{"providerId":"%s","keyEnv":"%s_KEY","host":"%s.example.gov","modelsUrl":"https://%s.example.gov/v1/models","apiProtocol":"openai"}\n' \
    "$2" "$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')" "$2" "$2" > "$1/models/providers/$2/facts.json"
}

@test "sandbox facts read the generation a pointer-file current names" {
  local root
  root=$(acq_provider_input_root msb pointerfacts)
  _facts_generation "$root/generations/generation.one" alpha
  printf 'generations/generation.one\n' > "$root/current"
  run acq_provider_sandbox_provider_ids msb pointerfacts
  assert_success
  assert_output alpha
  run acq_provider_sandbox_facts msb pointerfacts
  assert_output "$(printf 'alpha\tALPHA_KEY\talpha.example.gov\thttps://alpha.example.gov/v1/models\topenai')"
  # The POSIX symlink and a real directory left as current are read too.
  rm "$root/current"; ln -s generations/generation.one "$root/current"
  run acq_provider_sandbox_provider_ids msb pointerfacts
  assert_output alpha
  rm "$root/current"; _facts_generation "$root/current" beta
  run acq_provider_sandbox_provider_ids msb pointerfacts
  assert_output beta
}

@test "an unusable current falls back to the recorded provider facts" {
  local root outside="$STUBDIR/outside-generation" target recorded
  root=$(acq_provider_input_root msb fallbackfacts)
  _facts_generation "$root/generations/generation.one" alpha
  _facts_generation "$outside" gamma
  ln -s "$outside" "$root/generations/generation.link"
  recorded=$(printf 'beta\tBETA_KEY\tbeta.example.gov\thttps://beta.example.gov/v1/models\topenai')
  acq_host_config_write msb fallbackfacts provider-credentials "$recorded"
  for target in '../outside-generation' "$outside" 'generations/generation.one/../generation.one' \
      'generations/generation.link' 'generations/generation.missing' 'generations/' \
      "$(printf 'generations/generation.one\r')" "$(printf 'generations/generation.one\nextra')"; do
    rm -f "$root/current"
    printf '%s\n' "$target" > "$root/current"
    run acq_provider_sandbox_provider_ids msb fallbackfacts
    assert_success
    assert_output beta
    # The same text as a symlink is refused the same way.
    rm -f "$root/current"
    ln -s "$target" "$root/current"
    run acq_provider_sandbox_provider_ids msb fallbackfacts
    assert_success
    assert_output beta
  done
  rm -f "$root/current"
  run acq_provider_sandbox_provider_ids msb fallbackfacts
  assert_output beta
}

@test "provider facts parse when the interpreter writes CRLF line endings" {
  local python="$STUBDIR/crlf-python" record
  # Native Windows Python's text-mode stdout ends each line with CRLF; this
  # interpreter does the same, then runs the program acq sends on stdin.
  printf '%s\n' 'import io, sys' \
    'sys.stdout = io.TextIOWrapper(sys.stdout.buffer, newline="\r\n")' \
    'code = sys.stdin.read()' 'sys.argv = ["-"] + sys.argv[1:]' \
    'exec(compile(code, "<stdin>", "exec"), {"__name__": "__main__"})' > "$STUBDIR/crlf-boot.py"
  printf '#!/bin/sh\n[ "$1" = -I ] && shift\n[ "$1" = - ] || exit 97\nshift\nexec "%s" -I "%s" "$@"\n' \
    "$(command -v python3)" "$STUBDIR/crlf-boot.py" > "$python"
  chmod +x "$python"
  _facts_generation "$STUBDIR/crlf" alpha
  record="$STUBDIR/crlf/models/providers/alpha/facts.json"
  ACQ_PROVIDER_INPUT_PYTHON="$python" run acq_provider_facts_json_fields "$record"
  assert_success
  assert_output "$(printf 'alpha\tALPHA_KEY\talpha.example.gov\thttps://alpha.example.gov/v1/models\topenai')"
}

@test "snapshot refuses an artifact with another hard link, POSIX and native Windows" {
  local bin release="$STUBDIR/release" kit outside="$STUBDIR/hard-secret"
  bin=$(_win_bin)
  _win_use "$bin" python3=storestub python=winpython
  _provider_release "$release"; _provider_kit "$release" alpha
  kit="$release/integrations/isolation/acq-kits/alpha"
  printf 'secret\n' > "$outside"
  rm "$kit/files/snapshot.json"
  ln "$outside" "$kit/files/snapshot.json"
  run _acq_provider_input_snapshot "$kit" "$STUBDIR/hl-posix"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
  OSTYPE=msys PATH="$bin:$PATH" run _acq_provider_input_snapshot "$kit" "$STUBDIR/hl-nt"
  assert_failure
  assert_output --partial 'unsafe provider artifact'
  [ ! -e "$STUBDIR/hl-posix/files/snapshot.json" ] && [ ! -e "$STUBDIR/hl-nt/files/snapshot.json" ]
}

@test "publication retains old generation for existing current consumers" {
  local root old new
  root=$(acq_provider_input_root sbx cleanupbox)
  mkdir -p "$root/generations/generation.old/models/providers" "$root/generations/generation.new/models/providers"
  old="$root/generations/generation.old"; new="$root/generations/generation.new"
  ln -s generations/generation.old "$root/current"
  run _acq_provider_input_publish "$root" "$new"
  assert_success
  assert_equal "$(readlink "$root/current")" "generations/generation.new"
  [ -d "$old" ]
}

@test "failed backend create discards only its unpublished generation" {
  local root
  root=$(acq_provider_input_root sbx orphanbox)
  _acq_provider_input_safe_mkdir "$root/generations/generation.one/models/providers"
  chmod -R a-w "$root/generations/generation.one"
  ln -s generations/generation.one "$root/current"
  sbx() { [ "$1" != create ]; }
  acq_backend_exists() { return 1; }
  _acq_sbx_confirm_absent() { return 0; }
  acq_provider_input_prepare() { printf '%s\n' "$root/generations/generation.one"; }
  _build_kit_list() { return 0; }
  _acq_sbx_kit_flags() { :; }
  _acq_sbx_startup_barrier_kit() { printf '%s\n' fixture; }
  run _acq_backend_provision_unlocked orphanbox shell /tmp
  assert_failure
  [ -d "$root" ]
  [ ! -e "$root/generations/generation.one" ]
}

@test "failed sbx create under set -e still removes the projection root" {
  local script="$STUBDIR/failed-create.sh" root
  root=$(acq_provider_input_root sbx errexitbox)
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -e
ACQ_SCRIPT_DIR="$REPO_ROOT"; ACQ_SOURCE_ONLY=1
. "$REPO_ROOT/acq"
. "$REPO_ROOT/acq.backends/sbx.sh"
  acq_provider_input_prepare() {
    _acq_provider_input_safe_mkdir "$root/generations/generation.one/models/providers"
    printf '%s/generations/generation.one\n' "$root"
}
sbx() { [ "\$1" != create ]; }
acq_backend_exists() { return 1; }
_acq_sbx_confirm_absent() { return 0; }
_build_kit_list() { return 0; }
_acq_sbx_kit_flags() { :; }
_acq_sbx_startup_barrier_kit() { printf '%s\n' fixture; }
acq_backend_provision errexitbox shell /tmp
EOF
  chmod +x "$script"
  run "$script"
  assert_failure
  [ -d "$root" ]
  [ ! -e "$root/generations/generation.one" ]
  [ ! -e "${root}.lock" ]
}

@test "failed create with unknown post-state preserves projected inputs" {
  local root
  root=$(acq_provider_input_root sbx unknown-create)
  _acq_provider_input_safe_mkdir "$root/generations/generation.new/models/providers"
  ln -s generations/generation.new "$root/current"
  sbx() { [ "$1" != create ]; }
  acq_backend_exists() { return 1; }
  _acq_sbx_confirm_absent() { return 1; }
  acq_provider_input_project() { return 0; }
  _build_kit_list() { return 0; }
  _acq_sbx_kit_flags() { :; }
  _acq_sbx_startup_barrier_kit() { printf '%s\n' fixture; }

  run _acq_backend_provision_unlocked unknown-create shell /tmp
  assert_failure
  [ "$(readlink "$root/current")" = generations/generation.new ]
}

@test "attempt cleanup removes an MSB clone and generation only after absence" {
  local root generation
  . "$REPO_ROOT/acq.backends/msb.sh"
  root=$(acq_provider_input_root msb cleanup-msb)
  generation="$root/generations/generation.attempt"
  _acq_provider_input_safe_mkdir "$generation/models/providers"
  _ACQ_MSB_ATTEMPT_NAME=cleanup-msb
  _ACQ_MSB_ATTEMPT_GENERATION="$generation"
  _ACQ_MSB_ATTEMPT_CLONE=/scratch
  _ACQ_MSB_ATTEMPT_ACTIVE=1
  _acq_msb_confirm_absent() { return 0; }
  _acq_msb_clone_cleanup() { printf '%s\n' "$1" > "$STUBDIR/clone-cleanup"; }

  _acq_msb_cleanup_uncreated_attempt
  [ ! -e "$generation" ]
  [ "$(cat "$STUBDIR/clone-cleanup")" = cleanup-msb ]
}

@test "pre-create MSB cleanup removes attempt resources despite unknown backend state" {
  local root generation
  . "$REPO_ROOT/acq.backends/msb.sh"
  root=$(acq_provider_input_root msb unknown-msb)
  generation="$root/generations/generation.attempt"
  _acq_provider_input_safe_mkdir "$generation/models/providers"
  _ACQ_MSB_ATTEMPT_NAME=unknown-msb
  _ACQ_MSB_ATTEMPT_GENERATION="$generation"
  _ACQ_MSB_ATTEMPT_CLONE=/scratch
  _ACQ_MSB_ATTEMPT_ACTIVE=1
  _ACQ_MSB_CREATE_STARTED=""
  _acq_msb_confirm_absent() { return 1; }
  _acq_msb_clone_cleanup() { printf called > "$STUBDIR/clone-cleanup"; }

  _acq_msb_cleanup_uncreated_attempt
  [ ! -e "$generation" ]
  [ -e "$STUBDIR/clone-cleanup" ]
}

@test "post-create unknown MSB state preserves attempt resources" {
  local root generation
  . "$REPO_ROOT/acq.backends/msb.sh"
  root=$(acq_provider_input_root msb unknown-created-msb)
  generation="$root/generations/generation.attempt"
  _acq_provider_input_safe_mkdir "$generation/models/providers"
  _ACQ_MSB_ATTEMPT_NAME=unknown-created-msb
  _ACQ_MSB_ATTEMPT_GENERATION="$generation"
  _ACQ_MSB_ATTEMPT_CLONE=/scratch
  _ACQ_MSB_ATTEMPT_ACTIVE=1
  _ACQ_MSB_CREATE_STARTED=1
  _acq_msb_confirm_absent() { return 1; }
  _acq_msb_clone_cleanup() { printf called > "$STUBDIR/unexpected-clone-cleanup"; }

  _acq_msb_cleanup_uncreated_attempt
  [ -d "$generation" ]
  [ ! -e "$STUBDIR/unexpected-clone-cleanup" ]
}

@test "post-create MSB readiness failure preserves its generation" {
  local root generation
  . "$REPO_ROOT/acq.backends/msb.sh"
  root=$(acq_provider_input_root msb ready-msb)
  generation="$root/generations/generation.attempt"
  _acq_provider_input_safe_mkdir "$generation/models/providers"
  _ACQ_MSB_ATTEMPT_NAME=ready-msb
  _ACQ_MSB_ATTEMPT_GENERATION="$generation"
  _ACQ_MSB_ATTEMPT_ACTIVE=""
  _acq_msb_confirm_absent() { return 0; }

  _acq_msb_cleanup_uncreated_attempt
  [ -d "$generation" ]
}

@test "projection root and backend mount contracts expose no shared host config" {
  local sbx_root msb_root hcfg
  sbx_root=$(acq_provider_input_root sbx mountbox)
  msb_root=$(acq_provider_input_root msb mountbox)
  hcfg=$(acq_host_config_dir sbx mountbox)
  local sbx_generation="${sbx_root}/generations/generation.test" msb_generation="${msb_root}/generations/generation.test"
  assert_equal "$(acq_provider_input_sbx_mount mountbox "$sbx_generation")" "${sbx_generation}:ro"
  assert_equal "$(acq_provider_input_guest_root sbx mountbox "$sbx_generation")" "$sbx_generation"
  assert_equal "$(acq_provider_input_msb_mount mountbox "$msb_generation")" "${msb_generation}:${ACQ_PROVIDER_INPUT_GUEST_DIR}/generation.test:ro"
  assert_equal "$(acq_provider_input_guest_root msb mountbox "$msb_generation")" "${ACQ_PROVIDER_INPUT_GUEST_DIR}/generation.test"
  [[ "$sbx_root" != "$hcfg" ]]
  [[ "$msb_root" != *".config" ]]
}

@test "candidate traversal and symlink artifacts fail before publication" {
  local release="$STUBDIR/release" outside="$STUBDIR/outside" root
  _provider_release "$release"; _provider_kit "$release" alpha
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  printf 'outside\n' > "$outside"
  printf '{"providerId":"alpha","factsPath":"../outside","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json"}\n' > "$release/integrations/isolation/acq-kits/alpha/provider-input.json"
  # Consumed dynamically by acq_provider_input_project.
  # shellcheck disable=SC2034
  KITS=("$release/integrations/isolation/acq-kits/alpha")
  run acq_provider_input_prepare msb traversalbox
  assert_failure
  root=$(acq_provider_input_root msb traversalbox); [ ! -e "$root/current" ]

  _provider_kit "$release" alpha
  rm "$release/integrations/isolation/acq-kits/alpha/provider-input/facts.json"
  ln -s "$outside" "$release/integrations/isolation/acq-kits/alpha/provider-input/facts.json"
  run acq_provider_input_prepare msb symlinkbox
  assert_failure
}

@test "control-plane checkout is pinned to the exact Patterns release" {
  local log="$STUBDIR/git.log" dest="$STUBDIR/control"
  git() {
    printf '%s\n' "$*" >> "$log"
    case "$1" in
      rev-parse) printf '%s\n' "$PATTERNS_KIT_REF" ;;
      *) return 0 ;;
    esac
  }
  run _acq_provider_input_control_plane "$dest"
  assert_success
  grep -Fqx "fetch -q --depth 1 origin $PATTERNS_KIT_REF" "$log"
  grep -Fqx "checkout -q --detach FETCH_HEAD" "$log"
}

# _spinner_provision BACKEND NAME ACTION — run acq_backend_provision under
# `set -euo pipefail` (as acq does) with the spinner animating (progress gate
# forced on) and the unlocked provision stubbed to run ACTION while the spinner
# is active. Records cleanup and INT-handler calls in $STUBDIR/<name>.log.
_spinner_provision() {
  local backend="$1" name="$2" action="$3" script log
  script="$STUBDIR/spinner-$name.sh"
  log="$STUBDIR/$name.log"
  : > "$log"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ACQ_SCRIPT_DIR="$REPO_ROOT"; ACQ_SOURCE_ONLY=1
. "$REPO_ROOT/acq"
. "$REPO_ROOT/acq.backends/$backend.sh"
_acq_progress_enabled() { return 0; }
_acq_${backend}_cleanup_uncreated_attempt() { printf 'cleanup\n' >> "$log"; }
eval "_test_orig_signal_exit() \$(declare -f _acq_provider_input_signal_exit | sed 1d)"
_acq_provider_input_signal_exit() { printf 'handler %s\n' "\$*" >> "$log"; _test_orig_signal_exit "\$@"; }
_acq_backend_provision_unlocked() {
  acq_spin_start "Creating the sandbox"
  $action
  printf 'not-reached\n' >> "$log"
}
rc=0
acq_backend_provision "$name" shell /tmp 2>/dev/null || rc=\$?
printf 'rc=%s\n' "\$rc"
EOF
  chmod +x "$script"
  BASH_ENV='' run "$script"
}

@test "provision with the spinner active keeps a failing exit status" {
  local backend root
  for backend in sbx msb; do
    root=$(acq_provider_input_root "$backend" "spinexit-$backend")
    _spinner_provision "$backend" "spinexit-$backend" 'exit 3'
    assert_success
    assert_output 'rc=3'
    assert_equal "$(cat "$STUBDIR/spinexit-$backend.log")" cleanup
    [ ! -e "${root}.lock" ]
  done
}

@test "Ctrl-C during provision with the spinner active exits 130 via the chained handler" {
  local backend root
  for backend in sbx msb; do
    root=$(acq_provider_input_root "$backend" "spinint-$backend")
    _spinner_provision "$backend" "spinint-$backend" \
      'kill -s INT "$_ACQ_PROVIDER_INPUT_TRANSACTION_PID"; sleep 5'
    assert_success
    assert_output 'rc=130'
    assert_equal "$(cat "$STUBDIR/spinint-$backend.log")" "$(printf 'handler 130\ncleanup')"
    [ ! -e "${root}.lock" ]
  done
}

@test "HUP during provision exits 129 via the chained handler" {
  local backend root
  for backend in sbx msb; do
    root=$(acq_provider_input_root "$backend" "spinhup-$backend")
    _spinner_provision "$backend" "spinhup-$backend" \
      'kill -s HUP "$_ACQ_PROVIDER_INPUT_TRANSACTION_PID"; sleep 5'
    assert_success
    assert_output 'rc=129'
    assert_equal "$(cat "$STUBDIR/spinhup-$backend.log")" "$(printf 'handler 129\ncleanup')"
    [ ! -e "${root}.lock" ]
  done
}

# A child forked while the transaction subshell's traps are set can run them:
# a signal that reaches it before Bash resets its inherited handlers is handled
# with the subshell's trap commands, and Bash 5 then also runs the subshell's
# EXIT trap there. Call the handlers from a child directly, as that window does,
# for provision and terminate on both backends. The child must exit with the
# handler's status without signalling the registered backend child, running the
# uncreated-attempt cleanup or releasing the lock; the owner's own exit must
# still do all of that exactly once.
_owner_guard_script() { # BACKEND NAME VERB LOG
  local backend="$1" name="$2" verb="$3" log="$4" script="$STUBDIR/owner-$2.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ACQ_SCRIPT_DIR="$REPO_ROOT"; ACQ_SOURCE_ONLY=1
. "$REPO_ROOT/acq"
. "$REPO_ROOT/acq.backends/$backend.sh"
_acq_${backend}_cleanup_uncreated_attempt() { printf 'cleanup\n' >> "$log"; }
lock="\$(acq_provider_input_root $backend $name).lock"
_owner_body() {
  sleep 30 & backend_child=\$!
  _acq_provider_input_guardian_register_child "\$backend_child"
  exit_line=\$(trap -p EXIT)
  exit_cmd=\$(_acq_trap_line_cmd "\$exit_line")
  [ -n "\$exit_cmd" ] || printf 'no-exit-trap\n' >> "$log"
  ( _acq_provider_input_signal_exit 143; printf 'not-reached\n' >> "$log" ) || printf 'child-term=%s\n' "\$?" >> "$log"
  ( _acq_provider_input_signal_exit 129; printf 'not-reached\n' >> "$log" ) || printf 'child-hup=%s\n' "\$?" >> "$log"
  ( _acq_return_status 5; eval "\$exit_cmd" ) || printf 'child-exit=%s\n' "\$?" >> "$log"
  kill -0 "\$backend_child" 2>/dev/null && printf 'backend-child-alive\n' >> "$log"
  [ -d "\$lock" ] && printf 'lock-held\n' >> "$log"
  kill "\$backend_child" 2>/dev/null || true
  wait "\$backend_child" 2>/dev/null || true
  exit 3
}
_acq_backend_${verb}_unlocked() { _owner_body; }
rc=0
acq_backend_$verb "$name" shell /tmp 2>/dev/null || rc=\$?
printf 'rc=%s\n' "\$rc"
[ -d "\$lock" ] && printf 'lock-left\n'
true
EOF
  chmod +x "$script"
  BASH_ENV='' run "$script"
}

@test "a child that inherits the transaction traps never cleans up for the owner" {
  local backend verb name log want
  for backend in sbx msb; do
    for verb in provision terminate; do
      name="owner-$verb-$backend"
      log="$STUBDIR/$name.log"
      : > "$log"
      _owner_guard_script "$backend" "$name" "$verb" "$log"
      assert_success
      assert_output 'rc=3'
      want=$(printf 'child-term=143\nchild-hup=129\nchild-exit=5\nbackend-child-alive\nlock-held')
      # Only provision has an uncreated attempt to clean up; the owner runs it once.
      [ "$verb" = provision ] && want=$(printf '%s\ncleanup' "$want")
      assert_equal "$(cat "$log")" "$want"
    done
  done
}

# HUP is signal 1, so the conventional status is 129. Pin every provider-input
# transaction HUP trap (provision and terminate, both backends).
@test "provider-input transaction HUP traps exit 129" {
  local f
  for f in sbx msb; do
    assert_equal "$(grep -c "trap '_acq_provider_input_signal_exit 129' HUP" "$REPO_ROOT/acq.backends/$f.sh")" 2
    refute grep -q "_acq_provider_input_signal_exit 128" "$REPO_ROOT/acq.backends/$f.sh"
  done
}
