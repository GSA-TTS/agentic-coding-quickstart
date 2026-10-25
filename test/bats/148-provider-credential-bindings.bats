#!/usr/bin/env bats
#
# 148-provider-credential-bindings.bats — acq-owned provider credential bindings
# and generic (non-USAi) provider credential injection.
#
# A provider kit is data: validated facts.json names its providerId, keyEnv,
# host, modelsUrl, and apiProtocol. acq owns the providerId -> KEY_ENV registry so
# a provider kit hosted outside the pinned Patterns release (
# `--kit git+https://…`) validates and is injected with no per-provider code.
#
# shellcheck shell=bats

load 'helper'

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

# _make_generation PROVIDER KEY_ENV [HOST] — build a materialized generation
# directory holding one provider's validated facts.json, and echo its path.
_make_generation() {
  local provider_id="$1" key_env="$2" host="${3:-$1.example.gov}"
  local generation="$STUBDIR/generation.$provider_id"
  mkdir -p "$generation/models/providers/$provider_id"
  printf '{"schemaVersion":"acq-provider-facts/v1","providerId":"%s","apiProtocol":"openai-compatible","host":"%s","baseUrl":"https://%s/v1","modelsUrl":"https://%s/v1/models","keyEnv":"%s"}\n' \
    "$provider_id" "$host" "$host" "$host" "$key_env" \
    > "$generation/models/providers/$provider_id/facts.json"
  printf '%s\n' "$generation"
}

# _provider_release ROOT — a stand-in pinned Patterns release: a validator stub
# that records the argv it received and a base credential-bindings table.
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
  printf '{"providers":{"alpha":"ALPHA_KEY","beta":"BETA_KEY"}}\n' \
    > "$root/integrations/isolation/schemas/provider-credential-bindings.json"
  cat > "$root/scripts/validate_provider_input_contract.py" <<'PY'
import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ['VALIDATOR_LOG']).write_text('\n'.join(args))
bindings = [args[i + 1] for i, value in enumerate(args) if value == '--credential-bindings'][0]
pathlib.Path(os.environ['VALIDATOR_BINDINGS_PATH']).write_text(bindings)
pathlib.Path(os.environ['VALIDATOR_BINDINGS_COPY']).write_text(
    pathlib.Path(bindings).read_text()
)
for bundle_path in [args[i + 1] for i, value in enumerate(args) if value == '--bundle']:
    json.loads(pathlib.Path(bundle_path).read_text())
PY
}

# _provider_kit ROOT NAME PROVIDER_ID KEY_ENV — a provider-role kit fixture.
_provider_kit() {
  local release="$1" name="$2" provider_id="${3:-$2}" key_env="$4"
  local kit="$release/integrations/isolation/acq-kits/$name"
  mkdir -p "$kit/provider-input" "$kit/scripts" "$kit/files"
  printf '{"providerId":"%s","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/%s","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json","credentialEnvNames":["%s"]}\n' \
    "$provider_id" "$provider_id" "$key_env" > "$kit/provider-input.json"
  printf '{"providerId":"%s"}\n' "$provider_id" > "$kit/provider-input/facts.json"
  printf '#!/bin/sh\n' > "$kit/scripts/normalize"; chmod 755 "$kit/scripts/normalize"
  printf '{"providerId":"%s","models":[]}\n' "$provider_id" > "$kit/files/snapshot.json"
  printf 'caps:\n  network:\n    allow:\n      - %s.example.gov\n' "$provider_id" > "$kit/spec.yaml"
}

# ---------------------------------------------------------------------------
# acq provider-credential set | ls | rm
# ---------------------------------------------------------------------------

@test "provider-credential set persists a binding that ls reports" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY
  assert_success
  grep -Fq 'provider_credential_bindings: opencode-go=OPENCODE_GO_API_KEY' \
    "$XDG_CONFIG_HOME/acq/config.yaml"

  run "$ACQ" provider-credential ls
  assert_success
  assert_output --partial 'opencode-go'
  assert_output --partial 'OPENCODE_GO_API_KEY'
  assert_output --partial 'config.yaml'
}

@test "provider-credential set replaces one binding without dropping the others" {
  run "$ACQ" provider-credential set alpha ALPHA_KEY
  assert_success
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY
  assert_success
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_KEY_V2
  assert_success

  run "$ACQ" provider-credential ls
  assert_success
  assert_line --partial 'alpha'
  assert_line --partial 'ALPHA_KEY'
  refute_output --partial 'OPENCODE_GO_API_KEY'
  assert_line --partial 'OPENCODE_GO_KEY_V2'
}

@test "provider-credential rejects a malformed provider id" {
  run "$ACQ" provider-credential set OpenCode OPENCODE_GO_API_KEY
  assert_failure
  assert_output --partial "invalid provider id 'OpenCode'"
  refute [ -e "$XDG_CONFIG_HOME/acq/config.yaml" ]
}

@test "provider-credential rejects a malformed KEY_ENV" {
  run "$ACQ" provider-credential set opencode-go opencode_go_key
  assert_failure
  assert_output --partial "invalid KEY_ENV 'opencode_go_key'"
  refute [ -e "$XDG_CONFIG_HOME/acq/config.yaml" ]
}

@test "provider-credential rejects a provider id ending in a dash" {
  run "$ACQ" provider-credential set opencode- OPENCODE_GO_API_KEY
  assert_failure
  assert_output --partial 'invalid provider id'
}

@test "provider-credential rm removes a binding and reports an unknown one" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY
  assert_success

  run "$ACQ" provider-credential rm opencode-go
  assert_success
  run "$ACQ" provider-credential ls
  assert_success
  assert_output --partial '(none)'

  run "$ACQ" provider-credential rm opencode-go
  assert_failure
  assert_output --partial "no config.yaml binding for provider 'opencode-go'"
}

@test "provider-credential ls fails closed on a malformed env layer" {
  run env ACQ_PROVIDER_CREDENTIAL_BINDINGS='not-a-pair' \
    "$ACQ" provider-credential ls
  assert_failure
  assert_output --partial "expected '<providerId>=<KEY_ENV>'"
}

@test "provider-credential with no subcommand prints usage and is a usage error" {
  run "$ACQ" provider-credential
  assert_failure 2
  assert_output --partial 'acq provider-credential'

  run "$ACQ" provider-credential --help
  assert_success
  assert_output --partial 'ACQ_PROVIDER_CREDENTIAL_BINDINGS'
}

# ---------------------------------------------------------------------------
# Three-layer merge into the pinned validator
# ---------------------------------------------------------------------------

@test "prepare validates against the merged registry (base + config + env)" {
  local release="$STUBDIR/release" bindings_path
  _provider_release "$release"
  _provider_kit "$release" alpha alpha ALPHA_KEY
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  export VALIDATOR_BINDINGS_PATH="$STUBDIR/bindings-path"
  export VALIDATOR_BINDINGS_COPY="$STUBDIR/bindings-copy.json"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha")

  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='beta=BETA_KEY_FROM_ENV'
  run "$ACQ" provider-credential set gamma GAMMA_KEY
  assert_success

  run acq_provider_input_prepare sbx mergebox
  assert_success

  # The validator saw a MERGED file, not the pinned base file.
  bindings_path=$(cat "$VALIDATOR_BINDINGS_PATH")
  [ "$bindings_path" != \
    "$release/integrations/isolation/schemas/provider-credential-bindings.json" ]
  # Base defaults survive; config and env layers are layered on top.
  grep -Fq '"alpha": "ALPHA_KEY"' "$VALIDATOR_BINDINGS_COPY"
  grep -Fq '"beta": "BETA_KEY_FROM_ENV"' "$VALIDATOR_BINDINGS_COPY"
  grep -Fq '"gamma": "GAMMA_KEY"' "$VALIDATOR_BINDINGS_COPY"
  # The merged file lived in the staging dir, so the stage cleanup removed it.
  refute [ -e "$bindings_path" ]
}

@test "prepare fails closed on a malformed registry entry and never validates" {
  local release="$STUBDIR/release" root
  _provider_release "$release"
  _provider_kit "$release" alpha alpha ALPHA_KEY
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  export VALIDATOR_BINDINGS_PATH="$STUBDIR/bindings-path"
  export VALIDATOR_BINDINGS_COPY="$STUBDIR/bindings-copy.json"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha")
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='broken-token'

  run acq_provider_input_prepare sbx badbindings
  assert_failure
  assert_output --partial "expected '<providerId>=<KEY_ENV>'"
  refute [ -e "$STUBDIR/validator.log" ]

  root=$(acq_provider_input_root sbx badbindings)
  refute [ -e "$root/current" ]
}

@test "prepare fails closed when a provider id in the registry is unsafe" {
  local release="$STUBDIR/release"
  _provider_release "$release"
  _provider_kit "$release" alpha alpha ALPHA_KEY
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  export VALIDATOR_BINDINGS_PATH="$STUBDIR/bindings-path"
  export VALIDATOR_BINDINGS_COPY="$STUBDIR/bindings-copy.json"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  KITS=("$release/integrations/isolation/acq-kits/alpha")
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='bad/id=BAD_KEY'

  run acq_provider_input_prepare sbx badidbox
  assert_failure
  assert_output --partial 'invalid provider id'
  refute [ -e "$STUBDIR/validator.log" ]
}

# ---------------------------------------------------------------------------
# Registry drives generic provider handling
# ---------------------------------------------------------------------------

@test "a registry provider is an acq-managed service with an importable key env" {
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='opencode-go=OPENCODE_GO_API_KEY'

  run _acq_is_managed_service opencode-go
  assert_success

  run _acq_import_env_vars_for opencode-go
  assert_success
  assert_output 'OPENCODE_GO_API_KEY'

  run _acq_is_managed_service not-a-registry-provider
  assert_failure
}

@test "the env layer overrides the config layer for one provider" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY
  assert_success
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='opencode-go=OPENCODE_GO_OVERRIDE'

  run acq_provider_credential_key_env opencode-go
  assert_success
  assert_output 'OPENCODE_GO_OVERRIDE'
}

@test "configure shows the configured provider bindings" {
  _acq_config_write_field provider_credential_bindings 'opencode-go=OPENCODE_GO_API_KEY'

  run _acq_configure_show_current
  assert_success
  assert_output --partial 'provider creds:     opencode-go=OPENCODE_GO_API_KEY'
}

# ---------------------------------------------------------------------------
# facts.json is the only provider-specific input
# ---------------------------------------------------------------------------

@test "facts.json records are validated before they become backend arguments" {
  local generation record expected
  generation=$(_make_generation opencode-go OPENCODE_GO_API_KEY)
  record="$generation/models/providers/opencode-go/facts.json"

  run acq_provider_facts_json_fields "$record"
  assert_success
  expected=$(printf 'opencode-go\tOPENCODE_GO_API_KEY\topencode-go.example.gov\thttps://opencode-go.example.gov/v1/models\topenai-compatible')
  assert_output "$expected"
}

@test "facts.json with an unsafe keyEnv or a non-https models URL is rejected" {
  local generation record
  generation=$(_make_generation alpha ALPHA_KEY)
  record="$generation/models/providers/alpha/facts.json"

  printf '{"providerId":"alpha","keyEnv":"KEY; rm -rf /","host":"alpha.example.gov","modelsUrl":"https://alpha.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure

  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov","modelsUrl":"http://alpha.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure

  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov/v1","modelsUrl":"https://alpha.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure
}

@test "a missing facts.json is not an error, it is simply no provider facts" {
  run acq_provider_facts_json_fields "$STUBDIR/absent/facts.json"
  assert_failure 1
  run acq_provider_facts_list_generation "$STUBDIR/absent-generation"
  assert_success
  assert_output ''
}

@test "sbx maps a registry provider to its facts host and key env" {
  local generation expected
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"

  run _acq_service_hosts_env alpha
  assert_success
  expected=$(printf 'alpha.example.gov\tALPHA_KEY')
  assert_output "$expected"

  # An unknown service keeps its previous (empty) mapping.
  run _acq_service_hosts_env not-a-provider
  assert_success
  expected=$(printf '\t')
  assert_output "$expected"
}

@test "sbx reports a registry provider injectable only once its key env is bound" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  _acq_sbx_secret_exists() { return 1; }

  run acq_backend_key_present alpha
  assert_failure

  _acq_sbx_secret_exists() { return 0; }
  run acq_backend_key_present alpha
  assert_success

  # Services acq does not model keep the documented permissive default.
  run acq_backend_key_present some-raw-placeholder
  assert_success
}

# ---------------------------------------------------------------------------
# Generic key validation + create-time gate
# ---------------------------------------------------------------------------

@test "check_provider_key probes facts.modelsUrl with the provider key env" {
  local generation probe
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  probe="$STUBDIR/probe.sh"
  acq_backend_run() {
    printf '%s\n' "$5" > "$probe"
    printf '200|0\n'
  }

  run check_provider_key probe-box alpha
  assert_success
  assert_output '200'
  grep -Fq 'https://alpha.example.gov/v1/models' "$probe"
  grep -Fq 'Bearer $ALPHA_KEY' "$probe"
}

@test "check_provider_key reports an unauthorized provider key" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  acq_backend_run() { printf '401|0\n'; }

  run check_provider_key probe-box alpha
  assert_success
  assert_output '401'
}

@test "ensure_valid_provider_keys fails closed on a rejected provider key" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  mkdir -p "$generation/models/providers"
  acq_provider_sandbox_provider_ids() { printf 'alpha\n'; }
  check_provider_key() { printf '401\n'; }

  run ensure_valid_provider_keys probe-box
  assert_failure
  assert_output --partial "provider 'alpha' rejected the stored key (HTTP 401)"
  assert_output --partial 'acq secret set -g alpha'
}

@test "ensure_valid_provider_keys treats an unreachable endpoint as a network problem" {
  acq_provider_sandbox_provider_ids() { printf 'alpha\n'; }
  check_provider_key() { printf 'unreachable\n'; }

  run ensure_valid_provider_keys probe-box
  assert_failure
  assert_output --partial 'That is a network problem, not a credential one.'
}

@test "ensure_valid_provider_keys is silent for usai and for an inconclusive probe" {
  acq_provider_sandbox_provider_ids() { printf 'usai\nalpha\n'; }
  check_provider_key() { printf '\n'; }

  run ensure_valid_provider_keys probe-box
  assert_success
  assert_output ''
}

@test "credentials gate records provider facts and never gates usai" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  mkdir -p "$generation/models/providers/usai"
  printf '{"providerId":"usai","apiProtocol":"openai-compatible","host":"api.gsa.usai.gov","modelsUrl":"https://api.gsa.usai.gov/api/v1/models","keyEnv":"USAI_API_KEY"}\n' \
    > "$generation/models/providers/usai/facts.json"
  export ALPHA_KEY='exported-by-ci'

  # USAI_API_KEY is deliberately unset: USAi keeps its own pre-create gate, so
  # the generic gate must not demand it (and must not prompt for it).
  run acq_provider_credentials_gate msb credbox "$generation"
  assert_success
  refute_output --partial 'USAI_API_KEY'

  run acq_host_config_read msb credbox provider-credentials
  assert_success
  assert_output --partial 'alpha'
}

@test "credentials gate fails closed non-interactively when a provider key is missing" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)

  run acq_provider_credentials_gate msb credbox "$generation"
  assert_failure
  assert_output --partial "no injectable key for provider 'alpha' (\$ALPHA_KEY)"
  assert_output --partial 'acq secret set -g alpha'
}

@test "credentials gate is a no-op for a generation with no providers" {
  local generation="$STUBDIR/empty-generation"
  mkdir -p "$generation/models/providers"

  run acq_provider_credentials_gate msb credbox "$generation"
  assert_success
  run acq_host_config_read msb credbox provider-credentials
  assert_success
  assert_output ''
}
