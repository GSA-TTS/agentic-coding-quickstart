#!/usr/bin/env bats
# Provider inputs are validated as one set, published as immutable generations,
# and mounted without exposing the shared host-config directory.

setup() { acq_setup_stubs; unset ACQ_TEST_STUB_PROVIDER_INPUT; load_acq; }
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

  run acq_provider_input_project sbx incompatiblebox
  assert_failure 2
  root=$(acq_provider_input_root sbx incompatiblebox)
  [ ! -e "$root/current" ]
  [ ! -e "$STUBDIR/validator-invoked" ]
}

@test "projection validates all candidates once and publishes immutable generation" {
  local release="$STUBDIR/release" root current
  _provider_release "$release"; _provider_kit "$release" alpha; _provider_kit "$release" beta
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha" "$release/integrations/isolation/acq-kits/beta")

  run acq_provider_input_project msb projectionbox
  assert_success
  root=$(acq_provider_input_root msb projectionbox)
  [ -L "$root/current" ]
  current=$(readlink "$root/current")
  [ -f "$root/$current/models/providers/alpha/facts.json" ]
  [ -x "$root/$current/models/providers/beta/normalizer" ]
  assert_equal "$(grep -c -- '--bundle' "$VALIDATOR_LOG")" 2
  [ ! -w "$root/$current/models/providers/alpha/facts.json" ]
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
  local root before
  root=$(acq_provider_input_root sbx publishbox)
  mkdir -p "$root/generations/old/models/providers" "$root/generations/new/models/providers"
  ln -s generations/old "$root/current"
  before=$(readlink "$root/current")
  _acq_provider_input_atomic_replace() { return 1; }

  run _acq_provider_input_publish "$root" "$root/generations/new"
  assert_failure
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

@test "publication reports stale-generation cleanup failure without rolling back current" {
  local root old new
  root=$(acq_provider_input_root sbx cleanupbox)
  mkdir -p "$root/generations/generation.old/models/providers" "$root/generations/generation.new/models/providers"
  old="$root/generations/generation.old"; new="$root/generations/generation.new"
  ln -s generations/generation.old "$root/current"
  _acq_provider_input_remove_tree() { [ "$1" != "$old" ]; }
  run _acq_provider_input_publish "$root" "$new"
  assert_success
  assert_output --partial "could not clean old generation"
  assert_equal "$(readlink "$root/current")" "generations/generation.new"
}

@test "failed backend create removes the orphan projection root" {
  local root
  root=$(acq_provider_input_root sbx orphanbox)
  _acq_provider_input_safe_mkdir "$root/generations/one/models/providers"
  chmod -R a-w "$root/generations/one"
  ln -s generations/one "$root/current"
  sbx() { [ "$1" != create ]; }
  acq_backend_exists() { return 1; }
  acq_provider_input_project() { return 0; }
  _build_kit_list() { return 0; }
  _acq_sbx_kit_flags() { :; }
  _acq_sbx_startup_barrier_kit() { printf '%s\n' fixture; }
  run _acq_backend_provision_unlocked orphanbox shell /tmp
  assert_failure
  [ ! -e "$root" ]
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
acq_provider_input_project() {
  _acq_provider_input_safe_mkdir "$root/generations/one/models/providers"
  ln -s generations/one "$root/current"
}
sbx() { [ "\$1" != create ]; }
acq_backend_exists() { return 1; }
_build_kit_list() { return 0; }
_acq_sbx_kit_flags() { :; }
_acq_sbx_startup_barrier_kit() { printf '%s\n' fixture; }
acq_backend_provision errexitbox shell /tmp
EOF
  chmod +x "$script"
  run "$script"
  assert_failure
  [ ! -e "$root" ]
  [ ! -e "${root}.lock" ]
}

@test "projection root and backend mount contracts expose no shared host config" {
  local sbx_root msb_root hcfg
  sbx_root=$(acq_provider_input_root sbx mountbox)
  msb_root=$(acq_provider_input_root msb mountbox)
  hcfg=$(acq_host_config_dir sbx mountbox)
  assert_equal "$(acq_provider_input_sbx_mount mountbox)" "${sbx_root}:ro"
  assert_equal "$(acq_provider_input_guest_root sbx mountbox)" "${sbx_root}/current"
  assert_equal "$(acq_provider_input_msb_mount mountbox)" "${msb_root}:${ACQ_PROVIDER_INPUT_GUEST_DIR}:ro"
  assert_equal "$(acq_provider_input_guest_root msb mountbox)" "${ACQ_PROVIDER_INPUT_GUEST_DIR}/current"
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
  run acq_provider_input_project msb traversalbox
  assert_failure
  root=$(acq_provider_input_root msb traversalbox); [ ! -e "$root/current" ]

  _provider_kit "$release" alpha
  rm "$release/integrations/isolation/acq-kits/alpha/provider-input/facts.json"
  ln -s "$outside" "$release/integrations/isolation/acq-kits/alpha/provider-input/facts.json"
  run acq_provider_input_project msb symlinkbox
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
