#!/usr/bin/env bats
# Provider inputs are validated as one set, published as immutable generations,
# and mounted without exposing the shared host-config directory.

setup() { acq_setup_stubs; unset ACQ_PROVIDER_INPUT_PYTHON; load_acq; }
teardown() { acq_teardown_stubs; }

load 'helper'

_provider_release() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/integrations/isolation/schemas"
  cat > "$root/provider-python" <<'PYTHON'
#!/bin/sh
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

@test "projection prefers the supported project-local validator runtime" {
  local original_script_dir="$ACQ_SCRIPT_DIR"
  ACQ_SCRIPT_DIR="$STUBDIR/project"
  local runtime="$ACQ_SCRIPT_DIR/.acq-tools/provider-input-validator/bin"
  mkdir -p "$runtime"
  cat > "$runtime/python3" <<'EOF'
#!/bin/sh
if [ "$1" = -c ]; then exit 0; fi
exit 1
EOF
  chmod +x "$runtime/python3"

  run _acq_provider_input_python
  assert_success
  assert_output "$runtime/python3"
  ACQ_SCRIPT_DIR="$original_script_dir"
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

@test "setup validator rejects invalid arguments without changing a runtime" {
  local target="$REPO_ROOT/.acq-tools/provider-input-validator.current"
  mkdir -p "$target"
  printf 'working\n' > "$target/sentinel"
  run "$REPO_ROOT/scripts/setup-provider-input-validator" --unexpected
  assert_failure 2
  [ -f "$target/sentinel" ]
  rm -rf "$REPO_ROOT/.acq-tools"
}

@test "setup validator atomically replaces only a validated temporary runtime" {
  local target="$REPO_ROOT/.acq-tools/provider-input-validator.current" legacy="$REPO_ROOT/.acq-tools/provider-input-validator"
  local fakebin="$STUBDIR/python-bin" log="$STUBDIR/python.log"
  local first_runtime second_runtime
  mkdir -p "$fakebin"
  cat > "$fakebin/python3" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$VALIDATOR_SETUP_LOG"
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

  VALIDATOR_SETUP_LOG="$log" PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_success
  [ -L "$target" ]
  [ -x "$target/bin/python3" ]
  grep -Fq -- '--require-hashes' "$log"
  first_runtime=$(readlink "$target")

  mkdir -p "$legacy"
  printf 'legacy\n' > "$legacy/sentinel"

  VALIDATOR_SETUP_LOG="$log" PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_success
  second_runtime=$(readlink "$target")
  [ "$second_runtime" != "$first_runtime" ]
  [ -x "$target/bin/python3" ]
  [ ! -e "$legacy" ]
  [ ! -e "$REPO_ROOT/.acq-tools/$first_runtime" ]

  VALIDATOR_SETUP_LOG="$log" VALIDATOR_VALIDATE_FAIL=1 PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_failure
  [ "$second_runtime" = "$(readlink "$target")" ]
  [ -x "$target/bin/python3" ]

  rm -f "$target"
  mkdir -p "$REPO_ROOT/.acq-tools/outside-runtime"
  printf 'must-survive\n' > "$REPO_ROOT/.acq-tools/outside-runtime/sentinel"
  ln -s 'provider-input-validator../outside-runtime' "$target"
  VALIDATOR_SETUP_LOG="$log" PATH="$fakebin:/usr/bin" run "$REPO_ROOT/scripts/setup-provider-input-validator" --apply
  assert_success
  [ -f "$REPO_ROOT/.acq-tools/outside-runtime/sentinel" ]
  rm -rf "$REPO_ROOT/.acq-tools"
}

@test "runtime resolver recognizes Windows venv layout" {
  local original_script_dir="$ACQ_SCRIPT_DIR" runtime
  ACQ_SCRIPT_DIR="$STUBDIR/windows-project"
  runtime="$ACQ_SCRIPT_DIR/.acq-tools/provider-input-validator.current/Scripts"
  mkdir -p "$runtime"
  cat > "$runtime/python.exe" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$runtime/python.exe"
  run _acq_provider_input_python
  assert_success
  assert_output "$runtime/python.exe"
  ACQ_SCRIPT_DIR="$original_script_dir"
}

@test "validator lock files cover every released host and require hashes" {
  for lock in "$REPO_ROOT"/scripts/provider-input-validator-requirements-*.txt; do
    grep -Fq 'rpds-py==' "$lock"
    grep -Fq -- '--hash=sha256:' "$lock"
  done
  grep -Fq 'Linux x86_64/aarch64 Python 3.12' "$REPO_ROOT/scripts/provider-input-validator-requirements.txt"
  grep -Fq 'macOS arm64 Python' "$REPO_ROOT/scripts/provider-input-validator-requirements.txt"
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

@test "candidate snapshot preserves spec.yaml for host allowlist validation" {
  local release="$STUBDIR/release" candidate="$STUBDIR/candidate"
  _provider_release "$release"; _provider_kit "$release" alpha
  _acq_provider_input_snapshot "$release/integrations/isolation/acq-kits/alpha" "$candidate"
  [ -f "$candidate/spec.yaml" ]
  grep -Fq 'alpha.example.gov' "$candidate/spec.yaml"
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
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$STUBDIR/guardian.pid" ] && break
  kill -0 "\$parent" 2>/dev/null || break
  sleep 0.1
done
[ -s "$STUBDIR/guardian.pid" ]
guardian_pid=\$(cat "$STUBDIR/guardian.pid")
kill -KILL "\$parent" 2>/dev/null || true
if ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire sbx parentexit >"$STUBDIR/retry.out" 2>&1; then
  echo "lock was recovered while guardian was alive" >&2
  exit 1
fi
grep -Fq "owned by live pid \$guardian_pid" "$STUBDIR/retry.out"
wait "\$parent" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  kill -0 "\$guardian_pid" 2>/dev/null || break
  sleep 0.1
done
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
  sleep 4 & child=\$!
  _acq_provider_input_guardian_register_child "\$child"
  printf '%s %s\n' "\$_ACQ_PROVIDER_INPUT_GUARDIAN_PID" "\$child" > "$STUBDIR/pids"
  sleep 10
) & parent=\$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$STUBDIR/pids" ] && break
  sleep 0.1
done
read guardian child < "$STUBDIR/pids"
kill -KILL "\$parent" 2>/dev/null || true
if ACQ_PROVIDER_INPUT_LOCK_RETRIES=1 acq_provider_input_lock_acquire sbx backend-child >/dev/null 2>"$STUBDIR/retry"; then
  exit 1
fi
grep -Fq "owned by live pid \$guardian" "$STUBDIR/retry"
wait "\$parent" 2>/dev/null || true
waited=0
while kill -0 "\$child" 2>/dev/null && [ "\$waited" -lt 60 ]; do sleep 0.1; waited=\$((waited + 1)); done
waited=0
while kill -0 "\$guardian" 2>/dev/null && [ "\$waited" -lt 30 ]; do sleep 0.1; waited=\$((waited + 1)); done
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
  rm -f "$lock/owner"; rmdir "$lock"
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
